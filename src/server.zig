//! Servidor da sala (relay). Roda embutido no app de quem cria a sala ou como
//! servidor dedicado (server_main.zig). Todo mundo conecta nele como cliente.
//!
//! Cada conexão tem uma thread leitora e uma escritora com fila própria.
//! Frames são encaminhados só pra quem está assistindo, sem copiar o buffer.
//! Cada pessoa pode transmitir a tela e a câmera ao mesmo tempo: o que se
//! assiste é um "stream" (pessoa + tipo, ver proto.streamId).
//!
//! Controle de atraso de ponta a ponta: o servidor confirma (ack) cada frame
//! pro transmissor, e cada espectador confirma pro servidor. Assim os dois
//! sabem quanto atraso está acumulado no caminho, até dentro de túneis
//! (ngrok, bore...) cujos buffers ninguém enxerga. Um espectador que acumula
//! atraso perde os frames pendentes, espera o que já saiu chegar e recomeça
//! de um quadro completo (IDR) — ninguém trava a sala.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const udp = @import("udp.zig");
const crypto = @import("crypto.zig");
const procstat = @import("procstat.zig");
const gpa = proto.gpa;
const cio = @cImport(@cInclude("stdio.h"));

/// Mais que isso na fila de um espectador = ele está lento demais.
pub const max_viewer_backlog = 3 * 1024 * 1024;
/// ...ou se acumulou esse atraso (µs) acima do normal da conexão dele.
pub const max_viewer_excess_us = 500_000;
/// Atrasado pelo menos isso e sem escoar (a fila não diminuiu 50 ms em 1 s):
/// a taxa de bits está no limite do link dele, já pede taxa menor pro
/// transmissor antes de chegar no ponto de ter que recomeçar.
const soft_viewer_excess_us = 150_000;
/// Referência de RTT enquanto o espectador ainda não confirmou nenhum frame.
const default_base_us = 300_000;
/// Espectador "afinado" (só os quadros de referência) fica assim pelo menos
/// isso; se precisar de novo logo depois de voltar, o dobro (até 1 min).
const thin_min_ms = 10_000;
const thin_max_ms = 60_000;
/// Recém-afinado não conta como "com dificuldade" (pra pedir taxa menor pra
/// sala toda) enquanto o atraso acumulado escoa.
const thin_grace_ms = 3000;
// no máximo um IDR por segundo por transmissão (alguém entrando e saindo sem
// parar fazia a transmissão virar só IDR: banda e encoder de todo mundo)
const keyreq_interval_ms = 1000;
const handshake_timeout_ms = 10_000;
/// Alguém guardando os últimos segundos pra clipe: um IDR a cada tanto (um
/// clipe só começa num IDR, e sem isso eles só saem quando alguém entra).
pub const clip_key_interval_ms = 20_000;
/// Mensagens que quem entra na sala recebe de histórico.
pub const chat_history_len = 50;
/// Ponteiro: no máximo isso por segundo por pessoa.
const pointer_rate = 40;
/// Cursor de quem transmite (mensagem `cursor`): no máximo isso por segundo.
const cursor_rate = 130;
/// Em que tamanho a transmissão aparece (`view_size`): muda pouco.
const view_size_rate = 20;
const draw_rate = 60; // mensagens de desenho por segundo por pessoa

/// Uma transmissão (tela ou câmera) de alguém.
const StreamState = struct {
    on: bool = false,
    audio: bool = false,
    w: u16 = 0,
    h: u16 = 0,
    fps: u8 = 0,
    last_frame_ms: u64 = 0,
    last_droppable_ms: u64 = 0, // último quadro pulável (a transmissão tem camadas temporais)
    last_keyreq_ms: u64 = 0,
    last_slow_ms: u64 = 0,
    last_key_ms: u64 = 0, // último IDR que passou
    codecs_sent: u8 = 0, // codecs liberados que o transmissor já sabe (0 = ainda nada)
    features_sent: u8 = 0, // recursos (feat_*) que todo mundo que assiste entende, já avisados
    view_sent: u16 = 0, // altura pedida já avisada (0 = ainda nada)
};

/// Em que altura (pixels) quem assiste mostra uma transmissão (`view_size`).
const ViewSize = struct { stream: u32, h: u16 };

const Conn = struct {
    server: *Server,
    sock: net.Socket,
    channel: crypto.Channel = undefined,
    id: u32 = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    authed: bool = false,
    admin: bool = false,
    owner: bool = false, // entrou com o token de admin (quem criou a sala)
    client_key: u64 = 0, // aleatória, do app de quem conectou (banimento)
    app_version: [16]u8 = [_]u8{0} ** 16, // "3.0.0" (vazio = app que não conta)
    decode_codecs: u8 = proto.codecs_h264, // o que essa pessoa decodifica (H.264 sempre)
    features: u8 = 0, // o que o app dela entende (feat_*; app antigo: 0)
    view_sizes: std.ArrayList(ViewSize) = .empty, // em que tamanho ela mostra cada transmissão
    cursor_sec: u64 = 0, // limite do cursor (como o do ponteiro)
    cursor_count: u32 = 0,
    view_sec: u64 = 0,
    view_count: u32 = 0,
    udp: std.atomic.Value(?*udp.Link) = .init(null), // vídeo/som por UDP (quando o cliente abre o caminho)
    route: u8 = proto.route_unknown,
    via_tunnel: bool = false,
    ip: [16]u8 = undefined,
    ip_len: usize = 0,
    muted: bool = false, // microfone silenciado pelo admin
    no_draw: bool = false, // o admin tirou o pincel
    // log de depuração mandado pela sala (log_chunk): um por minuto
    log_id: u32 = 0,
    log_total: u32 = 0,
    log_got: u32 = 0,
    log_what: u8 = 0,
    log_last_ms: u64 = 0,
    log_refused: bool = false,
    log_buf: std.ArrayList(u8) = .empty, // só com --logs (servidor guarda em disco)
    chan: *Chan = undefined, // o canal em que a pessoa está (depois do join)
    chan_switch_ms: u64 = 0, // última troca de canal (limite)
    stats_on: bool = false, // quer as estatísticas do servidor (só o dono)
    tx_bytes: u64 = 0, // repassado pra ela (estatística)
    rx_bytes: u64 = 0, // quadro/som/voz que ela mandou
    tx_seen: u64 = 0,
    rx_seen: u64 = 0,
    mic: bool = false, // microfone ligado
    deaf: bool = false, // não quer ouvir a sala (não recebe voz)
    streams: [2]StreamState = .{ .{}, .{} },
    queue: proto.SendQueue = .{},
    watching: std.ArrayList(u32) = .empty, // streams que essa pessoa assiste
    waiting_key: std.ArrayList(u32) = .empty, // streams cujo próximo frame tem que ser IDR
    flows: std.ArrayList(Flow) = .empty, // frames a caminho, por stream assistido
    pointer_sec: u64 = 0, // limite do ponteiro: segundo atual e quantos já vieram
    pointer_count: u32 = 0,
    draw_sec: u64 = 0, // o mesmo pro desenho
    draw_count: u32 = 0,
    last_img_ms: u64 = 0, // última imagem no chat (limite)
    dismissed: bool = false, // já recebeu o aviso de saída (não manda outro)
    reader_done: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(1), // leitora (+ escritora quando existir)

    fn nameSlice(self: *const Conn) []const u8 {
        return self.name[0..self.name_len];
    }
    /// Estado do que esse espectador recebe de `stream` (cria se precisar).
    fn flow(self: *Conn, stream: u32) ?*Flow {
        for (self.flows.items) |*f| if (f.stream == stream) return f;
        self.flows.append(gpa, .{ .stream = stream }) catch return null;
        return &self.flows.items[self.flows.items.len - 1];
    }
    fn findFlow(self: *Conn, stream: u32) ?*Flow {
        for (self.flows.items) |*f| if (f.stream == stream) return f;
        return null;
    }
    fn dropFlow(self: *Conn, stream: u32) void {
        for (self.flows.items, 0..) |f, i| if (f.stream == stream) {
            _ = self.flows.swapRemove(i);
            return;
        };
    }
    /// Para de receber `stream` (saiu, parou de transmitir ou parou de assistir).
    fn forget(self: *Conn, stream: u32) void {
        remove(&self.watching, stream);
        for (self.view_sizes.items, 0..) |vs, i| if (vs.stream == stream) {
            _ = self.view_sizes.swapRemove(i);
            break;
        };
        remove(&self.waiting_key, stream);
        _ = self.queue.dropFrames(stream);
        self.dropFlow(stream);
    }
    fn retain(self: *Conn) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *Conn) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.queue.deinit();
            self.watching.deinit(gpa);
            self.view_sizes.deinit(gpa);
            self.waiting_key.deinit(gpa);
            self.log_buf.deinit(gpa);
            self.flows.deinit(gpa);
            if (self.udp.load(.acquire)) |l| l.destroy();
            net.close(self.sock);
            const srv = self.server;
            gpa.destroy(self);
            srv.release();
        }
    }
};

/// O que um espectador está recebendo de um stream.
const Flow = struct {
    stream: u32,
    clips: bool = false, // guardando os últimos segundos pra clipe (quer IDR de vez em quando)
    win: proto.AckWindow = .{}, // frames enviados e ainda não confirmados
    draining: bool = false, // atrasou: esperando o que já saiu chegar antes do IDR
    // quem vive atrasando espera cada vez mais pelo próximo IDR
    // (0,5 → 1 → 2 → 4 → 8 s), pra não fazer o transmissor mandar IDR (caro)
    // o tempo todo pra sala inteira
    resync_level: u5 = 0,
    resync_after_ms: u64 = 0,
    last_resync_ms: u64 = 0,
    // tendência do atraso, medida a cada 1 s
    trend_at_us: u64 = 0,
    trend_excess_us: u64 = 0,
    late: bool = false, // atrasado e sem escoar na última medida
    decoder_behind: bool = false, // pediu IDR porque o decoder não deu conta (vale como recomeço pro aviso)
    // "afinado": só recebe os quadros de referência (os puláveis ficam de fora)
    thin: bool = false,
    thin_since_ms: u64 = 0,
    thin_until_ms: u64 = 0,
    thin_ms: u64 = thin_min_ms,
    thin_ended_ms: u64 = 0,
    probe_until_ms: u64 = 0, // acabou de voltar a receber tudo: atrasou, afina na hora

    /// Atrasado sem escoar, ou recomeçou há menos de 10 s. Afinado: só se nem
    /// assim deu conta — continua atrasando passado o tempo de escoar, ou
    /// recomeçou de um IDR depois de afinado.
    fn struggling(f: *const Flow, now_ms: u64) bool {
        const recent_resync = f.last_resync_ms != 0 and now_ms - f.last_resync_ms < 10_000;
        if (f.thin) {
            const settled = now_ms - f.thin_since_ms >= thin_grace_ms;
            return (settled and f.late) or (recent_resync and f.last_resync_ms > f.thin_since_ms);
        }
        return f.late or recent_resync;
    }

    /// Passa a receber só os quadros de referência por um tempo: metade dos
    /// quadros, ~metade da banda e do trabalho do decoder, sem mexer na
    /// qualidade de quem está dando conta. Retorna true se começou agora.
    fn thinOut(f: *Flow, now_ms: u64) bool {
        if (f.thin) {
            f.thin_until_ms = @max(f.thin_until_ms, now_ms + f.thin_ms);
            return false;
        }
        const again = f.thin_ended_ms != 0 and now_ms - f.thin_ended_ms < 30_000;
        f.thin_ms = if (again) @min(f.thin_ms * 2, thin_max_ms) else thin_min_ms;
        f.thin = true;
        f.thin_since_ms = now_ms;
        f.thin_until_ms = now_ms + f.thin_ms;
        return true;
    }

    fn updateTrend(f: *Flow, excess: u64, now_us: u64) void {
        if (f.win.key_pending) {
            // IDR a caminho: a fila cresce atrás dele de qualquer jeito
            f.trend_at_us = 0;
            f.late = false;
        } else if (f.trend_at_us == 0) {
            f.trend_at_us = now_us;
            f.trend_excess_us = excess;
        } else if (now_us - f.trend_at_us >= 1_000_000) {
            f.late = excess > soft_viewer_excess_us and excess + 50_000 > f.trend_excess_us;
            f.trend_at_us = now_us;
            f.trend_excess_us = excess;
        }
    }

    /// Marca um recomeço. Retorna true se é repetido (menos de 10 s do anterior).
    fn backoff(f: *Flow, now_ms: u64) bool {
        if (now_ms - f.last_resync_ms > 10_000) f.resync_level = 0;
        const repeated = f.resync_level > 0;
        f.resync_after_ms = now_ms + (@as(u64, 500) << @min(f.resync_level, 4));
        f.resync_level +|= 1;
        f.last_resync_ms = now_ms;
        return repeated;
    }

    /// O atraso antigo já escoou? (desiste de esperar depois de 3 s)
    fn drained(f: *Flow, now_us: u64) bool {
        if (f.win.len == 0) return true;
        if (f.win.oldestAgeUs(now_us) > 3_000_000) {
            f.win.reset();
            return true;
        }
        return false;
    }
};

fn contains(list: *std.ArrayList(u32), v: u32) bool {
    return std.mem.findScalar(u32, list.items, v) != null;
}
fn remove(list: *std.ArrayList(u32), v: u32) void {
    if (std.mem.findScalar(u32, list.items, v)) |i| _ = list.swapRemove(i);
}
fn addUnique(list: *std.ArrayList(u32), v: u32) void {
    if (!contains(list, v)) list.append(gpa, v) catch {};
}

/// Alguém banido: não volta enquanto a sala existir (pela chave do app, pelo
/// nome ou pelo IP; quem vem pelo túnel tem o IP do túnel, aí não conta).
const Ban = struct {
    key: u64,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    ip: [16]u8 = undefined,
    ip_len: usize = 0,
};

const RecentJoin = struct {
    key: u64,
    ip: [16]u8 = undefined,
    ip_len: usize = 0,
    t_ms: u64,
};
const join_flood_window_ms = 30_000;
const join_flood_max = 6;

const ChatEntry = struct {
    id: u32,
    from: u32,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    text: []u8,
    time_us: u64,
    img: ?[]u8 = null, // quadro H.264 da imagem (proto.chat_img_h264)
    img_w: u16 = 0,
    img_h: u16 = 0,
    img_expired: bool = false, // a imagem saiu da memória (histórico grande demais)
    reacts: std.ArrayList(React) = .empty,

    const React = struct { emoji: u8, from: u32 };

    fn free(e: *ChatEntry) void {
        gpa.free(e.text);
        if (e.img) |im| gpa.free(im);
        e.reacts.deinit(gpa);
    }
};

/// Imagens guardadas no histórico do chat, no total (as mais velhas expiram).
const chat_img_budget = 24 * 1024 * 1024;
/// Imagem no chat: no máximo uma a cada tanto, por pessoa.
const chat_img_interval_ms = 1500;

/// Um canal (como no IRC): o chat dele, quem está nele e as transmissões de
/// quem está nele. Voz, "assistir", ponteiro e desenho só dentro do canal.
/// Banimento, silenciar, trancar e lotação valem pro servidor inteiro.
const Chan = struct {
    name: [proto.channel_name_max]u8 = undefined,
    name_len: usize = 0,
    fixed: bool = false, // não some quando esvazia
    chat_log: [chat_history_len]ChatEntry = undefined,
    chat_len: usize = 0,
    chat_head: usize = 0,

    fn nameSlice(ch: *const Chan) []const u8 {
        return ch.name[0..ch.name_len];
    }

    fn destroy(ch: *Chan) void {
        for (0..ch.chat_len) |i| ch.chat_log[(ch.chat_head + i) % chat_history_len].free();
        gpa.destroy(ch);
    }
};

/// Nome de canal no formato do servidor: sem espaços nas pontas e sem "#",
/// minúsculas, espaço vira "-"; só letras (inclusive acentuadas), números,
/// "-", "_" e "."; até proto.channel_name_max bytes (sem cortar letra no meio).
/// null = inválido.
pub fn normalizeChannel(raw: []const u8, out: *[proto.channel_name_max]u8) ?[]const u8 {
    var t = std.mem.trim(u8, raw, " \t\r\n");
    while (t.len > 0 and t[0] == '#') t = std.mem.trim(u8, t[1..], " ");
    if (t.len == 0) return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        const ch = t[i];
        const len: usize = if (ch < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(ch) catch return null);
        if (i + len > t.len) return null;
        if (n + len > out.len) break;
        if (len == 1) {
            const lc = std.ascii.toLower(ch);
            const ok = std.ascii.isAlphanumeric(lc) or lc == '-' or lc == '_' or lc == '.';
            if (lc == ' ') {
                if (n > 0 and out[n - 1] != '-') {
                    out[n] = '-';
                    n += 1;
                }
            } else if (ok) {
                out[n] = lc;
                n += 1;
            } else return null;
        } else {
            _ = std.unicode.utf8Decode(t[i .. i + len]) catch return null;
            @memcpy(out[n .. n + len], t[i .. i + len]);
            n += len;
        }
        i += len;
    }
    while (n > 0 and out[n - 1] == '-') n -= 1;
    if (n == 0) return null;
    return out[0..n];
}

pub const Options = struct {
    port: u16,
    password: []const u8 = "",
    room_name: []const u8 = "telinha",
    /// Quem mandar esse token no hello vira dono/admin. Vazio = ninguém.
    admin_token: []const u8 = "",
    max_members: u32 = 32,
    /// Recebe mensagens de log (servidor dedicado imprime no terminal).
    log: ?*const fn ([]const u8) void = null,
    /// Intervalo do IDR pra quem guarda clipes (testes encurtam).
    clip_key_interval_ms: u64 = clip_key_interval_ms,
    /// Pasta onde guardar os logs que mandarem pela sala (vazio = não guarda;
    /// eles vão só pra quem tem a coroa).
    logs_dir: []const u8 = "",
    /// Canais fixos, separados por vírgula ("geral,jogos,filmes"); o primeiro
    /// é o padrão (quem entra sem pedir canal cai nele). Vazio = só "geral".
    channels: []const u8 = "",
    /// Qualquer um pode criar canal novo (entrando num nome que não existe).
    new_channels: bool = true,
    /// A sala roda dentro do app (as estatísticas avisam que a CPU é do app todo).
    hosted: bool = false,
    /// Semente da identidade fixa (Ed25519; ver crypto.Identity). null = sem
    /// identidade (o app não tem como conferir quem é o servidor).
    identity_seed: ?[32]u8 = null,
};

const StatsPrev = struct {
    at_us: u64 = 0,
    cpu_us: u64 = 0,
    relayed: u64 = 0,
    received: u64 = 0,
    resyncs: u32 = 0,
    thins: u32 = 0,
    keyreqs: u32 = 0,
    slow: u32 = 0,
};

pub const Server = struct {
    listen_sock: net.Socket,
    udp_sock: ?net.Socket = null, // vídeo/som por UDP, na mesma porta (null = só TCP)
    port: u16,
    password: [128]u8 = undefined,
    password_len: usize = 0,
    room_name: [64]u8 = undefined,
    room_name_len: usize = 0,
    logs_dir: [256]u8 = undefined,
    logs_dir_len: usize = 0,
    admin_token: [64]u8 = undefined,
    admin_token_len: usize = 0,
    max_members: u32,
    clip_key_ms: u64 = clip_key_interval_ms,
    log_fn: ?*const fn ([]const u8) void,
    start_us: u64,
    /// Muda a cada vez que um servidor sobe: o cliente sabe que os ids de
    /// mensagem recomeçaram (reconectou num servidor reiniciado).
    instance: u64 = 0,
    mutex: sync.Mutex = .{},
    conns: std.ArrayList(*Conn) = .empty,
    next_id: u32 = 1,
    locked: bool = false,
    bans: std.ArrayList(Ban) = .empty,
    /// Chaves (do app) de quem o admin silenciou: quem cai e volta continua
    /// silenciado (antes voltava com o microfone liberado: "desmutou sozinho")
    muted_keys: std.ArrayList(u64) = .empty,
    /// O mesmo pro pincel tirado pelo admin.
    no_draw_keys: std.ArrayList(u64) = .empty,
    /// Entradas recentes (chave do app ou IP): quem entra e sai sem parar espera.
    recent_joins: std.ArrayList(RecentJoin) = .empty,
    chans: std.ArrayList(*Chan) = .empty, // o primeiro é o padrão
    new_channels: bool = true,
    hosted: bool = false,
    identity: ?crypto.Identity = null,
    chans_sent: [1024]u8 = undefined, // última lista de canais mandada (só manda se mudar)
    chans_sent_len: usize = 0,
    next_chat_id: u32 = 1,
    stopped: std.atomic.Value(bool) = .init(false),
    /// Dono (quem chamou start) + uma por thread do servidor + uma por conexão
    /// + o túnel: o último a soltar libera tudo (histórico do chat, imagens...).
    refs: std.atomic.Value(u32) = .init(1),
    // estatística
    relayed_bytes: std.atomic.Value(u64) = .init(0),
    received_bytes: u64 = 0, // quadro/som/voz que chegaram (com o mutex)
    n_resyncs: u32 = 0, // espectador recomeçou de um IDR (atrasou)
    n_thins: u32 = 0, // espectador passou a receber metade dos quadros
    n_keyreqs: u32 = 0, // IDRs pedidos pros transmissores
    n_slow: u32 = 0, // pedidos de taxa menor pros transmissores
    stats_prev: StatsPrev = .{},

    pub fn start(opts: Options) !*Server {
        const ls = try net.listen(opts.port);
        const s = try gpa.create(Server);
        s.* = .{ .listen_sock = ls, .port = opts.port, .max_members = opts.max_members, .clip_key_ms = opts.clip_key_interval_ms, .log_fn = opts.log, .start_us = sync.nowUs(), .new_channels = opts.new_channels, .hosted = opts.hosted };
        if (opts.identity_seed) |seed| s.identity = crypto.Identity.fromSeed(seed) catch null;
        // canais fixos (o primeiro é o padrão)
        var it = std.mem.tokenizeScalar(u8, opts.channels, ',');
        while (it.next()) |raw| {
            var nb: [proto.channel_name_max]u8 = undefined;
            const nm = normalizeChannel(raw, &nb) orelse continue;
            if (s.findChan(nm) != null or s.chans.items.len >= proto.max_channels) continue;
            _ = s.addChan(nm, true) catch break;
        }
        if (s.chans.items.len == 0) _ = s.addChan(proto.default_channel, true) catch {
            gpa.destroy(s);
            net.close(ls);
            return error.OutOfMemory;
        };
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        s.instance = std.mem.readInt(u64, &rnd, .little);
        copyInto(&s.password, &s.password_len, opts.password);
        copyInto(&s.room_name, &s.room_name_len, opts.room_name);
        copyInto(&s.logs_dir, &s.logs_dir_len, opts.logs_dir);
        copyInto(&s.admin_token, &s.admin_token_len, opts.admin_token);
        sync.hiresTimer(true); // o repasse por UDP cadencia em ms (solto no release)
        s.retain();
        sync.spawn(acceptLoop, .{s}) catch |e| {
            s.release();
            return e;
        };
        s.retain();
        sync.spawn(tickLoop, .{s}) catch s.release();
        if (std.c.getenv("TELINHA_SEM_UDP") == null) {
            if (net.udpListen(opts.port)) |us| {
                s.udp_sock = us;
                s.retain();
                sync.spawn(udpLoop, .{s}) catch {
                    s.release();
                    net.close(us);
                    s.udp_sock = null;
                };
            } else |_| {}
        }
        return s;
    }

    pub fn retain(s: *Server) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(s: *Server) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        for (s.chans.items) |ch| ch.destroy();
        s.chans.deinit(gpa);
        s.conns.deinit(gpa);
        s.bans.deinit(gpa);
        s.muted_keys.deinit(gpa);
        s.no_draw_keys.deinit(gpa);
        s.recent_joins.deinit(gpa);
        gpa.destroy(s);
        sync.hiresTimer(false);
    }

    /// Pro túnel: solta a referência que ele segurava.
    pub fn releaseCallback(ctx: *anyopaque) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        s.release();
    }

    /// Thread do UDP: recebe os datagramas de todo mundo (o token diz de quem
    /// é), e a cada ~10 ms cuida dos reenvios e de quem parou de falar.
    fn udpLoop(s: *Server) void {
        sync.nameThread("sala-udp");
        defer s.release();
        const sock = s.udp_sock.?;
        var timeout_ms: u32 = 500;
        net.setRecvTimeout(sock, timeout_ms);
        var buf: [2048]u8 = undefined;
        var from: net.UdpAddr = .{};
        var last_tick: u64 = 0;
        var any_busy = false;
        while (!s.stopped.load(.acquire)) {
            if (net.udpRecvFrom(sock, &buf, &from)) |n| {
                if (udp.peekToken(buf[0..n])) |token| if (s.connByToken(token)) |cn| {
                    defer cn.release();
                    const l = cn.udp.load(.acquire).?;
                    const before = l.ep.last_rx_ms.load(.monotonic);
                    const ev = l.ep.handle(.{ .sock = sock, .to = &from }, buf[0..n], deliverUdp, cn);
                    // decifrou: é ele mesmo. Endereço novo (NAT mudou)? passa a usar esse
                    if (ev == .hello or l.ep.last_rx_ms.load(.monotonic) != before) {
                        var cur: net.UdpAddr = .{};
                        _ = l.wire(&cur);
                        if (ev == .hello or !cur.eql(&from)) l.setAddr(&from);
                        if (ev == .hello and !l.isActive()) {
                            l.active.store(true, .release);
                            s.log("{s}: vídeo e som por UDP", .{cn.nameSlice()});
                        }
                    }
                    // ficou pedaço faltando: volta pro ritmo de 10 ms já
                    if (!any_busy and l.ep.busy()) {
                        any_busy = true;
                        timeout_ms = 10;
                        net.setRecvTimeout(sock, timeout_ms);
                    }
                };
            }
            const now = sync.nowMs();
            // sem reenvio pendente, a manutenção (quem sumiu) pode ser de 500 em 500 ms
            if (now - last_tick < (if (any_busy) @as(u64, 10) else 500)) continue;
            last_tick = now;
            any_busy = false;
            // reenvios, desistências e quem sumiu do UDP (volta pro TCP)
            var conns: [64]*Conn = undefined;
            var n_conns: usize = 0;
            s.mutex.lock();
            for (s.conns.items) |o| {
                if (n_conns == conns.len) break;
                const l = o.udp.load(.acquire) orelse continue;
                if (!l.isActive()) continue;
                o.retain();
                conns[n_conns] = o;
                n_conns += 1;
            }
            s.mutex.unlock();
            for (conns[0..n_conns]) |o| {
                defer o.release();
                const l = o.udp.load(.acquire).?;
                var a: net.UdpAddr = .{};
                l.ep.tick(l.wire(&a), deliverUdp, o);
                if (l.ep.busy()) any_busy = true;
                if (now -| l.ep.last_rx_ms.load(.monotonic) > 6000) {
                    l.active.store(false, .release);
                    l.ep.dropSent();
                    s.log("{s}: UDP parou de responder, voltando pro TCP", .{o.nameSlice()});
                }
            }
            const want: u32 = if (any_busy) 10 else 500;
            if (want != timeout_ms) {
                timeout_ms = want;
                net.setRecvTimeout(sock, timeout_ms);
            }
        }
        net.close(sock);
    }

    /// Conexão dona de um token UDP (com referência: chame release).
    fn connByToken(s: *Server, token: u32) ?*Conn {
        s.mutex.lock();
        defer s.mutex.unlock();
        for (s.conns.items) |o| {
            const l = o.udp.load(.acquire) orelse continue;
            if (l.ep.token == token) {
                o.retain();
                return o;
            }
        }
        return null;
    }

    /// Mensagem que chegou inteira pelo UDP: o mesmo tratamento do TCP
    /// (só quadro/som/voz vêm por aqui; erro não derruba a conexão).
    fn deliverUdp(ctx: *anyopaque, typ: proto.Type, payload: []const u8) void {
        const cn: *Conn = @ptrCast(@alignCast(ctx));
        switch (typ) {
            .frame, .audio, .voice => cn.server.handle(cn, typ, payload) catch {},
            else => {},
        }
    }

    /// A cada 250 ms: espectador esperando IDR de alguém com a tela parada,
    /// e IDR de vez em quando pra quem está guardando clipes.
    /// Normalmente quem pede o IDR é `forwardFrame`, quando chega o próximo
    /// quadro; mas com a tela parada (PipeWire/DXGI só mandam quando muda)
    /// ele não vem, e o espectador ficaria preso na imagem velha.
    fn tickLoop(s: *Server) void {
        sync.nameThread("sala-tick");
        defer s.release();
        var ticks: u32 = 0;
        while (!s.stopped.load(.acquire)) : (ticks +%= 1) {
            sync.sleepMs(250);
            s.mutex.lock();
            defer s.mutex.unlock();
            const now_ms = sync.nowMs();
            const now_us = sync.nowUs();
            // estatísticas pra quem pediu (o dono olhando), a cada 2 s
            if (ticks % 8 == 0) for (s.conns.items) |o| {
                if (o.stats_on) {
                    s.sendStats();
                    break;
                }
            };
            for (s.conns.items) |o| {
                for (o.flows.items) |*f| {
                    const sh = s.findConn(proto.memberOf(f.stream)) orelse continue;
                    const ss = &sh.streams[proto.kindOf(f.stream)];
                    if (!ss.on) continue;
                    if (f.clips and ss.last_key_ms != 0 and now_ms -| ss.last_key_ms > s.clip_key_ms and now_ms -| ss.last_keyreq_ms > s.clip_key_ms) {
                        s.requestKey(f.stream, false);
                        continue;
                    }
                    if (!contains(&o.waiting_key, f.stream)) continue;
                    // quadros chegando: forwardFrame cuida. IDR pedido há
                    // pouco: pode estar subindo ainda (upload lento), não pede outro
                    if (now_ms -| ss.last_frame_ms < 1000 or now_ms -| ss.last_keyreq_ms < 2000) continue;
                    if (f.draining) {
                        if (!f.drained(now_us)) continue;
                        f.draining = false;
                    }
                    if (now_ms >= f.resync_after_ms) s.requestKey(f.stream, false);
                }
            }
        }
    }

    fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
    }

    /// Relógio da sala (µs desde que o servidor subiu). Todo mundo sincroniza
    /// com ele pra medir a latência de ponta a ponta.
    pub fn nowUs(s: *const Server) u64 {
        return sync.nowUs() - s.start_us;
    }

    /// Quantos streams `id` está assistindo (testes).
    pub fn watchingCount(s: *Server, id: u32) usize {
        s.mutex.lock();
        defer s.mutex.unlock();
        const cn = s.findConn(id) orelse return 0;
        return cn.watching.items.len;
    }

    pub fn memberCount(s: *Server) usize {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.conns.items.len;
    }

    fn log(s: *Server, comptime fmt: []const u8, args: anytype) void {
        const f = s.log_fn orelse return;
        var buf: [512]u8 = undefined;
        f(std.fmt.bufPrint(&buf, fmt, args) catch return);
    }

    /// Fecha a sala: avisa todo mundo ("o dono fechou a sala", sem reconectar)
    /// e derruba. Espera no máximo ~1 s pelo aviso sair.
    pub fn stop(s: *Server) void {
        s.stopped.store(true, .release);
        net.shutdown(s.listen_sock);
        net.close(s.listen_sock);
        var list: std.ArrayList(*Conn) = .empty;
        defer list.deinit(gpa);
        s.mutex.lock();
        for (s.conns.items) |cn| {
            list.append(gpa, cn) catch continue;
            cn.retain();
            if (!cn.dismissed) pushDenied(cn, proto.deny_closed, "O dono fechou a sala.");
            cn.dismissed = true;
        }
        s.mutex.unlock();
        closeAll(list.items);
        for (list.items) |cn| cn.release();
        // a referência do dono; threads e conexões que ainda estão terminando
        // seguram as delas, e a última libera o Server
        s.release();
    }

    /// Desliga o link público: quem entrou por ele sai da sala (e fica sabendo
    /// por quê, sem tentar reconectar num link que não existe mais).
    pub fn closeTunnelConns(s: *Server) void {
        var list: std.ArrayList(*Conn) = .empty;
        defer list.deinit(gpa);
        s.mutex.lock();
        for (s.conns.items) |cn| {
            if (!cn.via_tunnel or cn.dismissed) continue;
            list.append(gpa, cn) catch continue;
            cn.retain();
            pushDenied(cn, proto.deny_link_closed, "O link público da sala foi desligado.");
            cn.dismissed = true;
            s.log("{s} saiu: o link público foi desligado", .{cn.nameSlice()});
        }
        s.mutex.unlock();
        if (list.items.len == 0) return;
        // em outra thread: a interface não espera
        const owned = list.toOwnedSlice(gpa) catch {
            closeAll(list.items);
            for (list.items) |cn| cn.release();
            return;
        };
        sync.spawn(closeOwned, .{owned}) catch {
            closeAll(owned);
            for (owned) |cn| cn.release();
            gpa.free(owned);
        };
    }

    fn closeOwned(list: []*Conn) void {
        closeAll(list);
        for (list) |cn| cn.release();
        gpa.free(list);
    }

    /// Derruba conexões sem perder o último aviso: espera as filas esvaziarem,
    /// fecha só o envio (o outro lado lê o aviso e fecha) e, se alguém não
    /// fechar a tempo, derruba de vez.
    fn closeAll(list: []*Conn) void {
        var waited: u32 = 0;
        while (waited < 600) : (waited += 10) {
            const pending = for (list) |cn| {
                if (!cn.queue.flushed()) break true;
            } else false;
            if (!pending) break;
            sync.sleepMs(10);
        }
        for (list) |cn| net.shutdownWrite(cn.sock);
        waited = 0;
        while (waited < 600) : (waited += 10) {
            const open = for (list) |cn| {
                if (!cn.reader_done.load(.acquire)) break true;
            } else false;
            if (!open) break;
            sync.sleepMs(10);
        }
        for (list) |cn| {
            net.shutdown(cn.sock);
            cn.queue.close();
        }
    }

    fn acceptLoop(s: *Server) void {
        sync.nameThread("sala-aceita");
        defer s.release();
        while (!s.stopped.load(.acquire)) {
            const sock = net.accept(s.listen_sock) catch {
                if (s.stopped.load(.acquire)) return;
                sync.sleepMs(20);
                continue;
            };
            s.adopt(sock, false);
        }
    }

    /// Recebe uma conexão já aberta. `via_tunnel`: veio pelo link público.
    pub fn adopt(s: *Server, sock: net.Socket, via_tunnel: bool) void {
        if (s.stopped.load(.acquire)) {
            net.close(sock);
            return;
        }
        const cn = gpa.create(Conn) catch {
            net.close(sock);
            return;
        };
        cn.* = .{ .server = s, .sock = sock, .via_tunnel = via_tunnel };
        if (via_tunnel) {
            cn.route = proto.route_tunnel;
        } else {
            cn.route = switch (net.peerRoute(sock)) {
                .unknown => proto.route_unknown,
                .local => proto.route_local,
                .lan => proto.route_lan,
                .internet4 => proto.route_internet,
                .internet6 => proto.route_internet6,
            };
            const ip = net.peerAddress(sock, &cn.ip);
            cn.ip_len = ip.len;
        }
        s.retain(); // solta no release da conexão
        sync.spawn(readerLoop, .{cn}) catch {
            net.close(sock);
            gpa.destroy(cn);
            s.release();
        };
    }

    /// Pro túnel (link público): `ctx` é o *Server.
    pub fn adoptCallback(ctx: *anyopaque, sock: net.Socket) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        s.adopt(sock, true);
    }

    /// Troca a senha (vale pra quem conectar daqui pra frente).
    pub fn setPassword(s: *Server, password: []const u8) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        copyInto(&s.password, &s.password_len, password);
    }

    pub fn hasPassword(s: *Server) bool {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.password_len > 0;
    }

    /// Impressão da identidade (vai no convite). null = sem identidade.
    pub fn fingerprint(s: *const Server) ?[crypto.fp_len]u8 {
        const id = s.identity orelse return null;
        return crypto.fingerprint(id.publicKey());
    }

    pub fn isLocked(s: *Server) bool {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.locked;
    }

    fn writerLoop(cn: *Conn) void {
        sync.nameThread("sala-envio");
        cn.queue.writerLoop(cn.sock, &cn.channel, &cn.udp);
        cn.release();
    }

    fn handshake(s: *Server, cn: *Conn, rb: *proto.RecvBuf) !void {
        net.setRecvTimeout(cn.sock, handshake_timeout_ms);
        var hello_buf: [crypto.hello_len]u8 = undefined;
        try net.recvAll(cn.sock, &hello_buf);
        const peer = try crypto.parseHello(&hello_buf);
        const hs = try crypto.Handshake.init();
        try net.sendAll(cn.sock, &hs.helloBytes(proto.version));
        if (peer.version != proto.version) return error.VersionMismatch; // o cliente vê nossa versão e avisa
        var pw: [128]u8 = undefined;
        s.mutex.lock();
        const pw_len = s.password_len;
        @memcpy(pw[0..pw_len], s.password[0..pw_len]);
        s.mutex.unlock();
        cn.channel = try crypto.Channel.derive(&hs, peer, false, pw[0..pw_len]);
        // quem eu sou, provado já: o app confere antes de mandar nome e token
        if (s.identity) |*id| {
            const t = crypto.transcript(peer, crypto.myHello(&hs, proto.version));
            const sig = try id.sign(t);
            const m = try proto.Msg.alloc(.identity, 96);
            @memcpy(m.payload()[0..32], &id.publicKey());
            @memcpy(m.payload()[32..96], &sig);
            try proto.sendNow(cn.sock, &cn.channel, m);
        }
        // caminho UDP (o cliente abre mandando um hello pro mesmo endereço);
        // pelo túnel público não tem UDP
        if (s.udp_sock) |us| if (!cn.via_tunnel) {
            var tk: [4]u8 = undefined;
            sync.osRandom(&tk);
            const token = std.mem.readInt(u32, &tk, .little) | 1;
            if (udp.Link.create(token, cn.channel.send_key, cn.channel.recv_key, us, true)) |l| cn.udp.store(l, .release) else |_| {}
        };

        const typ = proto.recvMsg(cn.sock, &cn.channel, rb) catch |e| {
            if (e == error.AuthFailed) {
                var marker: [4]u8 = undefined;
                std.mem.writeInt(u32, &marker, proto.wrong_password_marker, .little);
                net.sendAll(cn.sock, &marker) catch {};
                s.log("conexão recusada: senha errada", .{});
            }
            return e;
        };
        if (typ != .hello) return error.Protocol;
        net.setRecvTimeout(cn.sock, 0);

        // a partir daqui tem escritora
        _ = cn.refs.fetchAdd(1, .monotonic);
        sync.spawn(writerLoop, .{cn}) catch {
            _ = cn.refs.fetchSub(1, .monotonic);
            return error.ThreadFailed;
        };
        var r: proto.Reader = .{ .data = proto.payloadOf(rb) };
        const name = try r.str();
        const token = try r.str();
        cn.client_key = r.u64_() catch 0;
        if (r.str()) |v| {
            const n = @min(v.len, cn.app_version.len - 1);
            @memcpy(cn.app_version[0..n], v[0..n]);
        } else |_| {}
        cn.decode_codecs = (r.u8_() catch 0) | proto.codecs_h264;
        cn.features = r.u8_() catch 0;
        const want_chan = r.str() catch ""; // app antigo não manda: o canal padrão
        try s.join(cn, name, token, want_chan);
    }

    fn readerLoop(cn: *Conn) void {
        sync.nameThread("sala-leitura");
        const s = cn.server;
        var rb: proto.RecvBuf = .{};
        defer rb.deinit();
        if (s.handshake(cn, &rb)) {
            while (true) {
                const typ = proto.recvMsg(cn.sock, &cn.channel, &rb) catch break;
                s.handle(cn, typ, proto.payloadOf(&rb)) catch break;
            }
        } else |_| {}
        s.disconnect(cn);
        cn.reader_done.store(true, .release);
        // saindo por conta própria (não pelo closeAll): fecha a escritora
        if (!cn.dismissed) {
            net.shutdown(cn.sock);
            cn.queue.close();
        }
        cn.release();
    }

    fn handle(s: *Server, cn: *Conn, typ: proto.Type, payload: []const u8) !void {
        var r: proto.Reader = .{ .data = payload };
        switch (typ) {
            .log_chunk => try s.onLogChunk(cn, &r),
            .chat => {
                const text = std.mem.trim(u8, try r.str(), " \t\r\n");
                var img: ?Image = null;
                if ((r.u8_() catch proto.chat_img_none) == proto.chat_img_h264) {
                    const w = try r.u16_();
                    const h = try r.u16_();
                    const len = try r.u32_();
                    if (w < 16 or h < 16 or w > proto.chat_image_side or h > proto.chat_image_side or len == 0 or len > proto.chat_image_max) return error.BadMessage;
                    img = .{ .w = w, .h = h, .data = try r.take(len) };
                }
                if (text.len == 0 and img == null) return;
                s.mutex.lock();
                defer s.mutex.unlock();
                if (img != null) {
                    const now = sync.nowMs();
                    if (now -% cn.last_img_ms < chat_img_interval_ms) return; // rajada de imagem: ignora
                    cn.last_img_ms = now;
                }
                try s.broadcastChatImg(cn.chan, cn.id, cn.nameSlice(), text, img);
            },
            .react => {
                const id = try r.u32_();
                const emoji = try r.u8_();
                const on = (try r.u8_()) != 0;
                if (emoji >= proto.reactions) return error.BadMessage;
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.react(cn, id, emoji, on);
            },
            .stream_start => {
                const kind = try r.u8_();
                if (kind > proto.kind_camera) return error.BadMessage;
                const w = try r.u16_();
                const h = try r.u16_();
                const fps = try r.u8_();
                const flags: u8 = r.u8_() catch 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                const ss = &cn.streams[kind];
                const was = ss.on;
                ss.on = true;
                ss.audio = kind == proto.kind_screen and flags & proto.stream_audio != 0;
                ss.w = w;
                ss.h = h;
                ss.fps = fps;
                const stream = proto.streamId(cn.id, kind);
                if (!was) {
                    var tmp: [96]u8 = undefined;
                    const what = if (kind == proto.kind_camera) "ligou a câmera" else "começou a transmitir";
                    try s.broadcastChat(cn.chan, std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), what }) catch "");
                    s.log("{s} {s} ({d}x{d} @ {d} fps)", .{ cn.nameSlice(), what, w, h, fps });
                }
                // todo mundo que já assistia precisa de um IDR na resolução nova
                for (s.conns.items) |o| {
                    if (!contains(&o.watching, stream)) continue;
                    addUnique(&o.waiting_key, stream);
                    if (o.flow(stream)) |f| f.win.reset();
                }
                try s.broadcastMembers();
            },
            .stream_stop => {
                const kind: u8 = r.u8_() catch proto.kind_screen;
                if (kind > proto.kind_camera) return error.BadMessage;
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.stopStream(cn, kind);
            },
            .frame => try s.forwardFrame(cn, payload),
            .audio => try s.forwardAudio(cn, payload),
            .voice => try s.forwardVoice(cn, payload),
            .voice_state => {
                const flags = try r.u8_();
                s.mutex.lock();
                defer s.mutex.unlock();
                const mic = flags & proto.voice_mic != 0;
                const deaf = flags & proto.voice_deaf != 0;
                if (mic == cn.mic and deaf == cn.deaf) return;
                cn.mic = mic;
                cn.deaf = deaf;
                try s.broadcastMembers();
            },
            .watch => {
                const stream = try r.u32_();
                const on = (try r.u8_()) != 0;
                const opts: u8 = r.u8_() catch 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                if (on) {
                    // só quem existe (e não a si mesmo), e com limite: senão
                    // um cliente mal-intencionado enche a memória do servidor
                    const target = proto.memberOf(stream);
                    const tc = s.findConn(target) orelse return;
                    if (target == cn.id or tc.chan != cn.chan) return; // só quem está no mesmo canal
                    if (!contains(&cn.watching, stream) and cn.watching.items.len >= s.max_members * 2) return;
                    const changed = !contains(&cn.watching, stream);
                    if (!changed) {
                        // só mudou as opções (ex.: ligou os clipes)
                        if (cn.findFlow(stream)) |f| f.clips = opts & proto.watch_clips != 0;
                        return;
                    }
                    addUnique(&cn.watching, stream);
                    addUnique(&cn.waiting_key, stream);
                    _ = cn.queue.dropFrames(stream);
                    cn.dropFlow(stream);
                    if (cn.flow(stream)) |f| f.clips = opts & proto.watch_clips != 0;
                    // IDR pra quem começou a assistir, respeitando o limite: quem
                    // chegar logo depois de outro pega o próximo (o laço pede)
                    s.requestKey(stream, false);
                    try s.broadcastMembers();
                } else {
                    cn.forget(stream);
                    try s.broadcastMembers();
                }
            },
            .ack => {
                const stream = try r.u32_();
                const seq = try r.u32_();
                s.mutex.lock();
                defer s.mutex.unlock();
                if (cn.findFlow(stream)) |f| f.win.acked(seq, sync.nowUs());
            },
            .keyreq => {
                // o espectador perdeu a referência (decoder atrasou ou deu erro),
                // ou vai começar uma gravação (aí é só pedir o IDR)
                const stream = try r.u32_();
                const reason: u8 = r.u8_() catch proto.keyreq_lost;
                s.mutex.lock();
                defer s.mutex.unlock();
                if (!contains(&cn.watching, stream)) return;
                if (reason == proto.keyreq_record) {
                    s.requestKey(stream, false);
                    return;
                }
                const f = cn.flow(stream) orelse return;
                f.win.dropNewest(cn.queue.dropFrames(stream));
                addUnique(&cn.waiting_key, stream);
                const now = sync.nowMs();
                if (now >= f.resync_after_ms) s.requestKey(stream, false);
                _ = f.backoff(now);
                f.decoder_behind = true;
                // metade dos quadros alivia o decoder dele sem mexer em ninguém
                if (s.findConn(proto.memberOf(stream))) |sh| {
                    if (now -| sh.streams[proto.kindOf(stream)].last_droppable_ms < 2000 and f.thinOut(now))
                        s.log("{s} não deu conta de decodificar {s}: recebendo só metade dos quadros por {d} s", .{ cn.nameSlice(), sh.nameSlice(), f.thin_ms / 1000 });
                }
            },
            .ping => {
                const t = try r.u64_();
                const m = try proto.Msg.alloc(.pong, 16);
                std.mem.writeInt(u64, m.payload()[0..8], t, .little);
                std.mem.writeInt(u64, m.payload()[8..16], s.nowUs(), .little);
                cn.queue.pushOwned(m);
            },
            .kick => {
                const target = try r.u32_();
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.adminAction(cn, proto.admin_kick, target, 0);
            },
            .admin => {
                const action = try r.u8_();
                const target = try r.u32_();
                const value: u8 = r.u8_() catch 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.adminAction(cn, action, target, value);
            },
            .pointer => try s.forwardPointer(cn, payload),
            .draw => try s.forwardDraw(cn, payload),
            .cursor => try s.forwardCursor(cn, payload),
            .view_size => {
                const stream = try r.u32_();
                const h = try r.u16_();
                s.mutex.lock();
                defer s.mutex.unlock();
                const sec = sync.nowMs() / 1000;
                if (sec != cn.view_sec) {
                    cn.view_sec = sec;
                    cn.view_count = 0;
                }
                cn.view_count += 1;
                if (cn.view_count > view_size_rate) return;
                if (!contains(&cn.watching, stream)) return;
                for (cn.view_sizes.items) |*vs| {
                    if (vs.stream != stream) continue;
                    vs.h = h;
                    break;
                } else try cn.view_sizes.append(gpa, .{ .stream = stream, .h = h });
                s.updateCodecs();
            },
            .channel => {
                const name = try r.str();
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.switchChannel(cn, name);
            },
            .stats => {
                const on = (try r.u8_()) != 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                if (!cn.owner) return; // só quem entrou com o token de admin
                cn.stats_on = on;
                if (on) s.sendStats(); // a primeira na hora
            },
            else => {},
        }
    }

    /// Para uma transmissão de `cn` (ela parou, ou o admin mandou parar).
    /// Chamado com o mutex travado.
    fn stopStream(s: *Server, cn: *Conn, kind: u8) !void {
        const ss = &cn.streams[kind];
        if (!ss.on) return;
        ss.* = .{};
        const stream = proto.streamId(cn.id, kind);
        for (s.conns.items) |o| {
            _ = o.queue.dropFrames(stream);
            o.dropFlow(stream);
            remove(&o.waiting_key, stream);
        }
        s.log("{s} {s}", .{ cn.nameSlice(), if (kind == proto.kind_camera) "desligou a câmera" else "parou de transmitir" });
        try s.broadcastMembers();
    }

    /// Ações de admin. Quem criou a sala (dono) pode tudo; admin promovido
    /// não mexe em outro admin. Chamado com o mutex travado.
    fn adminAction(s: *Server, cn: *Conn, action: u8, target_id: u32, value: u8) !void {
        if (!cn.admin) return;
        if (action == proto.admin_lock) {
            const lock = value != 0;
            if (lock == s.locked) return;
            s.locked = lock;
            var tmp: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&tmp, "{s} {s} a sala", .{ cn.nameSlice(), if (lock) "trancou" else "destrancou" }) catch "";
            for (s.chans.items) |ch| try s.broadcastChat(ch, text);
            s.log("{s} {s} a sala", .{ cn.nameSlice(), if (lock) "trancou" else "destrancou" });
            try s.broadcastMembers();
            return;
        }
        if (target_id == cn.id) return;
        const t = s.findConn(target_id) orelse return;
        if (t.admin and !cn.owner) return;
        if (t.owner) return; // ninguém mexe no dono
        var tmp: [160]u8 = undefined;
        switch (action) {
            proto.admin_kick, proto.admin_ban => {
                const ban = action == proto.admin_ban;
                if (ban) {
                    var b: Ban = .{ .key = t.client_key };
                    copyInto(&b.name, &b.name_len, baseName(t.nameSlice()));
                    if (!t.via_tunnel and t.route != proto.route_local) copyInto(&b.ip, &b.ip_len, t.ip[0..t.ip_len]);
                    s.bans.append(gpa, b) catch {};
                }
                s.log("{s} {s} {s}", .{ cn.nameSlice(), if (ban) "baniu" else "expulsou", t.nameSlice() });
                const said = std.fmt.bufPrint(&tmp, "{s} {s} {s}", .{ cn.nameSlice(), if (ban) "baniu" else "expulsou", t.nameSlice() }) catch "";
                try s.broadcastChat(t.chan, said);
                if (cn.chan != t.chan) try s.broadcastChat(cn.chan, said);
                const reason = std.fmt.bufPrint(&tmp, "{s} {s} você da sala.", .{ cn.nameSlice(), if (ban) "baniu" else "expulsou" }) catch "Você foi removido da sala.";
                s.dismiss(t, if (ban) proto.deny_banned else proto.deny_kicked, reason);
            },
            proto.admin_mute => {
                const mute = value != 0;
                if (t.muted == mute) return;
                t.muted = mute;
                if (t.client_key != 0) {
                    for (s.muted_keys.items, 0..) |k, i| if (k == t.client_key) {
                        _ = s.muted_keys.swapRemove(i);
                        break;
                    };
                    if (mute) s.muted_keys.append(gpa, t.client_key) catch {};
                }
                s.log("{s} {s} {s}", .{ cn.nameSlice(), if (mute) "silenciou" else "liberou o microfone de", t.nameSlice() });
                const text = std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), if (mute) "silenciou seu microfone." else "liberou seu microfone." }) catch "";
                try pushNotice(t, if (mute) proto.notice_muted else proto.notice_unmuted, text, 0);
                try s.broadcastMembers();
            },
            proto.admin_stop_stream => {
                const kind = value;
                if (kind > proto.kind_camera or !t.streams[kind].on) return;
                const text = std.fmt.bufPrint(&tmp, "{s} parou sua {s}.", .{ cn.nameSlice(), if (kind == proto.kind_camera) "câmera" else "transmissão" }) catch "";
                try pushNotice(t, proto.notice_stream_stopped, text, kind);
                try s.stopStream(t, kind);
            },
            proto.admin_draw => {
                const allow = value != 0;
                if (t.no_draw == !allow) return;
                t.no_draw = !allow;
                if (t.client_key != 0) {
                    for (s.no_draw_keys.items, 0..) |k, i| if (k == t.client_key) {
                        _ = s.no_draw_keys.swapRemove(i);
                        break;
                    };
                    if (!allow) s.no_draw_keys.append(gpa, t.client_key) catch {};
                }
                s.log("{s} {s} {s}", .{ cn.nameSlice(), if (allow) "devolveu o pincel de" else "tirou o pincel de", t.nameSlice() });
                const text = std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), if (allow) "devolveu seu pincel." else "tirou seu pincel." }) catch "";
                try pushNotice(t, if (allow) proto.notice_draw_on else proto.notice_draw_off, text, 0);
                try s.broadcastMembers(); // quem vê a bandeira apaga os traços dela
            },
            proto.admin_set_admin => {
                if (!cn.owner) return; // só o dono promove/rebaixa
                const on = value != 0;
                if (t.admin == on) return;
                t.admin = on;
                s.log("{s} {s} {s}", .{ cn.nameSlice(), if (on) "deu admin pra" else "tirou o admin de", t.nameSlice() });
                const text = std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), if (on) "te deu admin na sala." else "tirou seu admin." }) catch "";
                try pushNotice(t, if (on) proto.notice_admin_on else proto.notice_admin_off, text, 0);
                try s.broadcastMembers();
            },
            else => {},
        }
    }

    /// Avisa a pessoa e tira ela da sala (sem perder o aviso). Chamado com o mutex travado.
    fn dismiss(s: *Server, t: *Conn, code: u8, reason: []const u8) void {
        _ = s;
        if (t.dismissed) return;
        t.dismissed = true;
        pushDenied(t, code, reason);
        t.retain();
        sync.spawn(closeOne, .{t}) catch {
            net.shutdown(t.sock);
            t.queue.close();
            t.release();
        };
    }

    fn closeOne(t: *Conn) void {
        var one = [_]*Conn{t};
        closeAll(&one);
        t.release();
    }

    fn pushDenied(cn: *Conn, code: u8, reason: []const u8) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.denied) catch return;
        b.str(reason) catch return;
        b.u8_(code) catch return;
        cn.queue.pushOwned(b.finish() catch return);
    }

    fn pushNotice(cn: *Conn, kind: u8, text: []const u8, extra: u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.notice);
        try b.u8_(kind);
        try b.str(text);
        try b.u8_(extra);
        cn.queue.pushOwned(try b.finish());
    }

    /// Recusa a entrada (sala cheia, trancada, banido): manda o motivo e fecha.
    fn refuse(cn: *Conn, code: u8, reason: []const u8) void {
        cn.dismissed = true;
        pushDenied(cn, code, reason);
        cn.retain();
        sync.spawn(closeOne, .{cn}) catch {
            net.shutdown(cn.sock);
            cn.queue.close();
            cn.release();
        };
    }

    /// Nome sem o " (2)" que o servidor põe em nome repetido.
    fn baseName(name: []const u8) []const u8 {
        if (name.len > 4 and name[name.len - 1] == ')') {
            if (std.mem.findScalarLast(u8, name, '(')) |i| {
                if (i > 1 and name[i - 1] == ' ') {
                    _ = std.fmt.parseInt(u32, name[i + 1 .. name.len - 1], 10) catch return name;
                    return name[0 .. i - 1];
                }
            }
        }
        return name;
    }

    /// Pedaço de log de depuração (log_chunk): repassa pra quem tem a coroa e,
    /// com `logs_dir`, guarda em disco. No fim responde a quem mandou (log_ack).
    fn onLogChunk(s: *Server, cn: *Conn, r: *proto.Reader) !void {
        const id = try r.u32_();
        const what = try r.u8_();
        const total = try r.u32_();
        const off = try r.u32_();
        const bytes = r.rest();
        if (total == 0 or total > proto.log_max or bytes.len > proto.log_chunk_max or @as(u64, off) + bytes.len > total) return;
        s.mutex.lock();
        defer s.mutex.unlock();
        const now = s.nowUs() / 1000;
        if (off == 0) {
            // log novo: no máximo um por minuto por pessoa
            cn.log_refused = cn.log_last_ms != 0 and now -| cn.log_last_ms < 60_000;
            cn.log_id = id;
            cn.log_total = total;
            cn.log_got = 0;
            cn.log_what = what;
            cn.log_buf.clearRetainingCapacity();
            if (cn.log_refused) {
                sendLogAck(cn, id, proto.log_ack_refused, 0);
                return;
            }
            cn.log_last_ms = now;
        }
        if (id != cn.log_id or cn.log_refused or off != cn.log_got) return;
        // repassa pra quem tem a coroa (menos quem mandou)
        var owners: u8 = 0;
        for (s.conns.items) |o| {
            if (!o.owner or o == cn) continue;
            owners += 1;
            var b: proto.Builder = .{};
            defer b.deinit();
            b.begin(.log_chunk) catch continue;
            b.u32_(cn.id) catch continue;
            b.str(cn.nameSlice()) catch continue;
            b.u32_(id) catch continue;
            b.u8_(what) catch continue;
            b.u32_(total) catch continue;
            b.u32_(off) catch continue;
            b.bytes(bytes) catch continue;
            o.queue.pushOwned(b.finish() catch continue);
        }
        if (s.logs_dir_len > 0) cn.log_buf.appendSlice(gpa, bytes) catch {};
        cn.log_got += @intCast(bytes.len);
        if (cn.log_got < total) return;
        // completo
        var saved = false;
        if (s.logs_dir_len > 0 and cn.log_buf.items.len == total) saved = s.saveLog(cn);
        cn.log_buf.clearAndFree(gpa);
        s.log("{s} mandou um {s} ({d} KB): {d} com a coroa receberam{s}", .{ cn.nameSlice(), if (what == proto.log_what_crash) "relatório de travamento" else "log", total / 1024, owners, if (saved) ", guardado em disco" else "" });
        const result: u8 = if (owners > 0) proto.log_ack_delivered else if (saved) proto.log_ack_saved else proto.log_ack_nobody;
        sendLogAck(cn, id, result, owners);
    }

    fn sendLogAck(cn: *Conn, id: u32, result: u8, owners: u8) void {
        const m = proto.Msg.alloc(.log_ack, 6) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], id, .little);
        m.payload()[4] = result;
        m.payload()[5] = owners;
        cn.queue.pushOwned(m);
    }

    /// Guarda o log de `cn` em logs_dir/AAAA-MM-DD_HH-MM-SS_nome_log.txt.
    fn saveLog(s: *Server, cn: *Conn) bool {
        var clean: [48]u8 = undefined;
        var n: usize = 0;
        for (cn.nameSlice()) |ch| {
            if (n == clean.len) break;
            clean[n] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80) ch else '_';
            n += 1;
        }
        const t = sync.dateTime();
        var pb: [512]u8 = undefined;
        const fp = std.fmt.bufPrintZ(&pb, "{s}/{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}_{s}_{s}.txt", .{
            s.logs_dir[0..s.logs_dir_len], t.year, t.month, t.day, t.h, t.m, t.s, clean[0..n], if (cn.log_what == proto.log_what_crash) "travou" else "log",
        }) catch return false;
        const f = cio.fopen(fp.ptr, "wb") orelse {
            s.log("não consegui criar {s}", .{fp});
            return false;
        };
        defer _ = cio.fclose(f);
        return cio.fwrite(cn.log_buf.items.ptr, 1, cn.log_buf.items.len, f) == cn.log_buf.items.len;
    }

    /// Mais de `join_flood_max` entradas em 30 s da mesma chave do app (ou do
    /// mesmo IP, pra quem não manda chave e não vem por túnel)? Senão anota.
    fn joinFlood(s: *Server, cn: *const Conn) bool {
        const now = s.nowUs() / 1000;
        var i: usize = 0;
        while (i < s.recent_joins.items.len) {
            if (now -| s.recent_joins.items[i].t_ms > join_flood_window_ms) {
                _ = s.recent_joins.swapRemove(i);
            } else i += 1;
        }
        // pelo IP só quem não manda chave, não vem por túnel e não é desta máquina
        const by_ip = cn.client_key == 0 and !cn.via_tunnel and cn.ip_len > 0 and cn.route != proto.route_local;
        if (cn.client_key == 0 and !by_ip) return false;
        var n: usize = 0;
        for (s.recent_joins.items) |j| {
            if (cn.client_key != 0 and j.key == cn.client_key) n += 1;
            if (by_ip and j.key == 0 and std.mem.eql(u8, j.ip[0..j.ip_len], cn.ip[0..cn.ip_len])) n += 1;
        }
        if (n >= join_flood_max) return true;
        if (s.recent_joins.items.len < 512) {
            var j: RecentJoin = .{ .key = cn.client_key, .t_ms = now };
            if (by_ip) {
                j.ip_len = cn.ip_len;
                @memcpy(j.ip[0..cn.ip_len], cn.ip[0..cn.ip_len]);
            }
            s.recent_joins.append(gpa, j) catch {};
        }
        return false;
    }

    fn banned(s: *Server, cn: *const Conn, name: []const u8) bool {
        for (s.bans.items) |*b| {
            if (b.key != 0 and b.key == cn.client_key) return true;
            if (std.ascii.eqlIgnoreCase(b.name[0..b.name_len], name)) return true;
            if (b.ip_len > 0 and !cn.via_tunnel and std.mem.eql(u8, b.ip[0..b.ip_len], cn.ip[0..cn.ip_len])) return true;
        }
        return false;
    }

    fn join(s: *Server, cn: *Conn, raw_name: []const u8, token: []const u8, want_chan: []const u8) !void {
        s.mutex.lock();
        defer s.mutex.unlock();
        // a sala fechou enquanto essa conexão fazia o handshake
        if (s.stopped.load(.acquire)) return error.Stopped;
        const is_owner = s.admin_token_len > 0 and std.mem.eql(u8, token, s.admin_token[0..s.admin_token_len]);
        const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
        const base = if (trimmed.len == 0) "anônimo" else trimmed[0..@min(trimmed.len, 32)];
        if (!is_owner) {
            if (s.banned(cn, base)) {
                s.log("{s} tentou entrar, mas foi banido", .{base});
                refuse(cn, proto.deny_banned, "Você foi banido dessa sala.");
                return error.Banned;
            }
            if (s.locked) {
                refuse(cn, proto.deny_locked, "A sala está trancada: ninguém novo entra agora.");
                return error.Locked;
            }
            if (s.conns.items.len >= s.max_members) {
                refuse(cn, proto.deny_full, "A sala está cheia.");
                return error.RoomFull;
            }
            if (s.joinFlood(cn)) {
                s.log("{s} entrando e saindo rápido demais: recusado por uns segundos", .{base});
                refuse(cn, proto.deny_generic, "Entrando e saindo rápido demais: espera uns segundos e tenta de novo.");
                return error.JoinFlood;
            }
        }
        // nome repetido ganha um número
        var name_buf: [48]u8 = undefined;
        var name: []const u8 = base;
        var n: u32 = 2;
        while (s.nameTaken(name)) : (n += 1) name = std.fmt.bufPrint(&name_buf, "{s} ({d})", .{ base, n }) catch base;
        cn.name_len = name.len;
        @memcpy(cn.name[0..name.len], name);
        cn.id = s.next_id;
        s.next_id += 1;
        cn.authed = true;
        cn.owner = is_owner;
        cn.admin = is_owner;
        // o canal pedido (cria se não existir e der); senão o padrão
        cn.chan = s.chans.items[0];
        var nb: [proto.channel_name_max]u8 = undefined;
        if (normalizeChannel(want_chan, &nb)) |nm| {
            if (s.findChan(nm)) |ch| {
                cn.chan = ch;
            } else if (s.canCreateChan()) {
                cn.chan = s.addChan(nm, false) catch cn.chan;
            }
        }
        try s.conns.append(gpa, cn);

        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.welcome);
        try b.u32_(cn.id);
        try b.str(s.room_name[0..s.room_name_len]);
        try b.u8_(@intFromBool(cn.admin));
        try b.u64_(s.nowUs());
        try b.u64_(s.instance);
        try b.u8_(cn.route);
        try b.str(proto.app_version);
        if (cn.udp.load(.acquire)) |l| {
            try b.u8_(1);
            try b.u32_(l.ep.token);
        } else try b.u8_(0);
        cn.queue.pushOwned(try b.finish());

        // em que canal ela está e quais existem; depois o que já foi dito nele
        s.pushChannels(cn);
        try s.pushHistory(cn);

        // silenciado pelo admin antes de cair: continua silenciado (e sem pincel)
        if (cn.client_key != 0 and !cn.owner) for (s.muted_keys.items) |k| if (k == cn.client_key) {
            cn.muted = true;
            pushNotice(cn, proto.notice_muted, "Você continua silenciado pelo admin.", 0) catch {};
            break;
        };
        if (cn.client_key != 0 and !cn.owner) for (s.no_draw_keys.items) |k| if (k == cn.client_key) {
            cn.no_draw = true;
            break;
        };

        var tmp: [96]u8 = undefined;
        try s.broadcastChat(cn.chan, std.fmt.bufPrint(&tmp, "{s} entrou na sala", .{name}) catch "");
        try s.broadcastMembers();
        s.log("{s} entrou ({d} na sala, {s}, #{s})", .{ name, s.conns.items.len, routeName(cn.route), cn.chan.nameSlice() });
    }

    pub fn routeName(route: u8) []const u8 {
        return switch (route) {
            proto.route_local => "nessa máquina",
            proto.route_lan => "rede local",
            proto.route_internet => "internet",
            proto.route_internet6 => "internet IPv6",
            proto.route_tunnel => "link público",
            else => "?",
        };
    }

    fn nameTaken(s: *Server, name: []const u8) bool {
        for (s.conns.items) |o| if (std.mem.eql(u8, o.nameSlice(), name)) return true;
        return false;
    }

    fn disconnect(s: *Server, cn: *Conn) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        const i = std.mem.findScalar(*Conn, s.conns.items, cn) orelse return;
        _ = s.conns.orderedRemove(i);
        for (s.conns.items) |o| {
            o.forget(proto.streamId(cn.id, proto.kind_screen));
            o.forget(proto.streamId(cn.id, proto.kind_camera));
        }
        s.log("{s} saiu ({d} na sala)", .{ cn.nameSlice(), s.conns.items.len });
        if (s.stopped.load(.acquire)) return;
        var tmp: [96]u8 = undefined;
        s.broadcastChat(cn.chan, std.fmt.bufPrint(&tmp, "{s} saiu da sala", .{cn.nameSlice()}) catch "") catch {};
        s.dropIfEmpty(cn.chan);
        s.broadcastMembers() catch {};
    }

    fn chatMsg(e: *const ChatEntry, flags: u8) !*proto.Msg {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.chat);
        try b.u32_(e.id);
        try b.u32_(e.from);
        try b.str(e.name[0..e.name_len]);
        try b.str(e.text);
        try b.u64_(e.time_us);
        try b.u8_(flags);
        if (e.img) |im| {
            try b.u8_(proto.chat_img_h264);
            try b.u16_(e.img_w);
            try b.u16_(e.img_h);
            try b.u32_(@intCast(im.len));
            try b.bytes(im);
        } else try b.u8_(if (e.img_expired) proto.chat_img_expired else proto.chat_img_none);
        // reações (no histórico; ao vivo elas vêm uma a uma)
        try b.u8_(@intCast(e.reacts.items.len));
        for (e.reacts.items) |rc| {
            try b.u8_(rc.emoji);
            try b.u32_(rc.from);
        }
        return b.finish();
    }

    const Image = struct { w: u16, h: u16, data: []const u8 };

    /// Aviso do sistema no chat de um canal (guarda no histórico dele e manda
    /// pra quem está nele). Chamado com o mutex travado.
    fn broadcastChat(s: *Server, ch: *Chan, text: []const u8) !void {
        return s.broadcastChatImg(ch, 0, "", text, null);
    }

    fn broadcastChatImg(s: *Server, ch: *Chan, from: u32, name: []const u8, text: []const u8, img: ?Image) !void {
        const owned = try gpa.dupe(u8, text[0..@min(text.len, 4000)]);
        var e: ChatEntry = .{ .id = s.next_chat_id, .from = from, .text = owned, .time_us = s.nowUs() };
        if (img) |im| {
            e.img = gpa.dupe(u8, im.data) catch {
                gpa.free(owned);
                return error.OutOfMemory;
            };
            e.img_w = im.w;
            e.img_h = im.h;
        }
        s.next_chat_id +%= 1;
        copyInto(&e.name, &e.name_len, name);
        const m = chatMsg(&e, 0) catch |err| {
            e.free();
            return err;
        };
        defer m.release();
        if (ch.chat_len == chat_history_len) {
            ch.chat_log[ch.chat_head].free();
            ch.chat_log[ch.chat_head] = e;
            ch.chat_head = (ch.chat_head + 1) % chat_history_len;
        } else {
            ch.chat_log[(ch.chat_head + ch.chat_len) % chat_history_len] = e;
            ch.chat_len += 1;
        }
        // memória: as imagens mais velhas expiram (o limite vale pro servidor
        // todo, contando todos os canais, do mais novo pro mais velho de cada um)
        s.expireImages();
        for (s.conns.items) |o| if (o.chan == ch) o.queue.push(m);
    }

    fn expireImages(s: *Server) void {
        var total: usize = 0;
        for (s.chans.items) |ch| {
            var i: usize = ch.chat_len;
            while (i > 0) {
                i -= 1;
                const ent = &ch.chat_log[(ch.chat_head + i) % chat_history_len];
                const im = ent.img orelse continue;
                total += im.len;
                if (total > chat_img_budget) {
                    gpa.free(im);
                    ent.img = null;
                    ent.img_expired = true;
                }
            }
        }
    }

    /// Liga/desliga uma reação numa mensagem do histórico. Mutex travado.
    fn react(s: *Server, cn: *Conn, id: u32, emoji: u8, on: bool) !void {
        const ch = cn.chan;
        const e = for (0..ch.chat_len) |i| {
            const ent = &ch.chat_log[(ch.chat_head + i) % chat_history_len];
            if (ent.id == id) break ent;
        } else return; // mensagem velha demais: ignora
        if (e.from == 0) return; // aviso do sistema não ganha reação
        const idx = for (e.reacts.items, 0..) |rc, k| {
            if (rc.emoji == emoji and rc.from == cn.id) break k;
        } else null;
        if (on == (idx != null)) return; // já estava assim
        if (on) {
            if (e.reacts.items.len >= 64) return;
            try e.reacts.append(gpa, .{ .emoji = emoji, .from = cn.id });
        } else _ = e.reacts.orderedRemove(idx.?);
        const m = try proto.Msg.alloc(.react, 10);
        defer m.release();
        const pl = m.payload();
        std.mem.writeInt(u32, pl[0..4], id, .little);
        std.mem.writeInt(u32, pl[4..8], cn.id, .little);
        pl[8] = emoji;
        pl[9] = @intFromBool(on);
        for (s.conns.items) |o| if (o.chan == ch) o.queue.push(m);
    }

    /// Chamado com o mutex travado.
    /// Codec de cada transmissão: só o que **todo mundo** que assiste decodifica
    /// (quem entra com um app sem HEVC faz a transmissão voltar pro H.264 na hora).
    /// Avisa o transmissor quando muda. Chamado com o mutex travado.
    fn updateCodecs(s: *Server) void {
        for (s.conns.items) |owner| {
            for (&owner.streams, 0..) |*ss, kind| {
                if (!ss.on) {
                    ss.codecs_sent = 0;
                    ss.features_sent = 0;
                    ss.view_sent = 0;
                    continue;
                }
                const stream = proto.streamId(owner.id, @intCast(kind));
                var mask: u8 = 0xFF;
                var feats: u8 = proto.features_mine;
                var want: u16 = 0; // maior altura em que alguém mostra (view_full = sem limite)
                var watchers: usize = 0;
                var known: usize = 0; // quantos já disseram o tamanho
                for (s.conns.items) |o| {
                    if (!contains(&o.watching, stream)) continue;
                    watchers += 1;
                    mask &= o.decode_codecs;
                    feats &= o.features;
                    var h: u16 = proto.view_full; // app antigo: tudo
                    if (o.features & proto.feat_view_size != 0) {
                        const said = for (o.view_sizes.items) |vs| {
                            if (vs.stream == stream) break vs.h;
                        } else null;
                        // começou a assistir e ainda não disse o tamanho: não mexe
                        // (antes contava como tela cheia: cada um que entrava jogava
                        // a transmissão pra resolução máxima e ela voltava logo depois)
                        h = said orelse continue;
                    }
                    known += 1;
                    want = @max(want, h);
                }
                mask |= proto.codecs_h264;
                if (watchers == 0) {
                    want = proto.view_full;
                } else if (known == 0) {
                    want = if (ss.view_sent != 0) ss.view_sent else proto.view_full;
                }
                if (mask != ss.codecs_sent or feats != ss.features_sent) {
                    ss.codecs_sent = mask;
                    ss.features_sent = feats;
                    if (proto.Msg.alloc(.codec, 3)) |m| {
                        m.payload()[0] = @intCast(kind);
                        m.payload()[1] = mask;
                        m.payload()[2] = feats;
                        owner.queue.pushOwned(m);
                    } else |_| {}
                }
                if (want != ss.view_sent and owner.features & proto.feat_view_size != 0) {
                    ss.view_sent = want;
                    if (proto.Msg.alloc(.view_size, 3)) |m| {
                        m.payload()[0] = @intCast(kind);
                        std.mem.writeInt(u16, m.payload()[1..3], want, .little);
                        owner.queue.pushOwned(m);
                    } else |_| {}
                }
            }
        }
    }

    /// Manda a lista de membros de cada canal pra quem está nele (e a lista de
    /// canais, se ela mudou). Chamado com o mutex travado.
    fn broadcastMembers(s: *Server) !void {
        s.updateCodecs();
        for (s.chans.items) |ch| try s.broadcastMembersOf(ch);
        s.broadcastChannels();
    }

    fn broadcastMembersOf(s: *Server, ch: *Chan) !void {
        var n: u16 = 0;
        for (s.conns.items) |o| {
            if (o.chan == ch) n += 1;
        }
        if (n == 0) return;
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.members);
        try b.u8_(if (s.locked) proto.room_locked else 0);
        try b.u16_(n);
        for (s.conns.items) |o| {
            if (o.chan != ch) continue;
            try b.u32_(o.id);
            try b.str(o.nameSlice());
            var flags: u8 = 0;
            const scr = &o.streams[proto.kind_screen];
            const cam = &o.streams[proto.kind_camera];
            if (scr.on) flags |= proto.member_streaming;
            if (o.admin) flags |= proto.member_admin;
            if (scr.on and scr.audio) flags |= proto.member_audio;
            if (o.mic) flags |= proto.member_mic;
            if (o.deaf) flags |= proto.member_deaf;
            if (o.muted) flags |= proto.member_muted;
            if (cam.on) flags |= proto.member_camera;
            if (o.no_draw) flags |= proto.member_no_draw;
            try b.u8_(flags);
            try b.u8_(@as(u8, if (o.owner) 0x80 else 0) | o.route);
            try b.u16_(scr.w);
            try b.u16_(scr.h);
            try b.u8_(scr.fps);
            try b.u16_(cam.w);
            try b.u16_(cam.h);
            try b.u8_(cam.fps);
            const k: u16 = @intCast(@min(o.watching.items.len, 64));
            try b.u16_(k);
            for (o.watching.items[0..k]) |id| try b.u32_(id);
        }
        // versão do app de cada um, na mesma ordem (no fim: quem não lê ignora)
        for (s.conns.items) |o| if (o.chan == ch) try b.str(std.mem.sliceTo(&o.app_version, 0));
        const m = try b.finish();
        defer m.release();
        for (s.conns.items) |o| if (o.chan == ch) o.queue.push(m);
    }

    // ------------------------------------------------------ estatísticas

    /// Estatísticas do servidor pra quem pediu (só o dono): CPU e memória do
    /// processo, banda, filas, quem está atrasando. As taxas são desde a última
    /// vez. Chamado com o mutex travado.
    fn sendStats(s: *Server) void {
        const now = sync.nowUs();
        const ps = procstat.sample();
        const relayed = s.relayed_bytes.load(.monotonic);
        const prev = s.stats_prev;
        const dt_us = if (prev.at_us == 0) 0 else now -| prev.at_us;
        const rate = struct {
            fn per_s(delta: u64, dt: u64) u32 {
                if (dt == 0) return 0;
                return @intCast(@min(std.math.maxInt(u32), delta * 1_000_000 / dt));
            }
        }.per_s;
        var b: proto.Builder = .{};
        defer b.deinit();
        const ok = blk: {
            b.begin(.stats) catch break :blk false;
            b.u32_(@intCast(@min(std.math.maxInt(u32), s.nowUs() / 1_000_000))) catch break :blk false;
            // CPU em milésimos de um núcleo (1000 = um núcleo inteiro)
            const cpu: u32 = if (dt_us == 0) 0 else @intCast(@min(std.math.maxInt(u32), (ps.cpu_us -| prev.cpu_us) * 1000 / dt_us));
            b.u32_(cpu) catch break :blk false;
            b.u8_(@intCast(@min(255, procstat.cores()))) catch break :blk false;
            b.u32_(@intCast(@min(std.math.maxInt(u32), ps.rss_kb))) catch break :blk false;
            b.u32_(rate(relayed -| prev.relayed, dt_us)) catch break :blk false;
            b.u32_(rate(s.received_bytes -| prev.received, dt_us)) catch break :blk false;
            var udp_n: u16 = 0;
            for (s.conns.items) |o| {
                if (o.udp.load(.acquire)) |l| if (l.isActive()) {
                    udp_n += 1;
                };
            }
            b.u16_(@intCast(s.conns.items.len)) catch break :blk false;
            b.u16_(udp_n) catch break :blk false;
            b.u16_(@intCast(@min(65535, s.max_members))) catch break :blk false;
            b.u8_(@intCast(s.chans.items.len)) catch break :blk false;
            b.u16_(@intCast(@min(65535, s.n_resyncs -% prev.resyncs))) catch break :blk false;
            b.u16_(@intCast(@min(65535, s.n_thins -% prev.thins))) catch break :blk false;
            b.u16_(@intCast(@min(65535, s.n_keyreqs -% prev.keyreqs))) catch break :blk false;
            b.u16_(@intCast(@min(65535, s.n_slow -% prev.slow))) catch break :blk false;
            b.u32_(@intCast(@min(std.math.maxInt(u32), dt_us / 1000))) catch break :blk false;
            var flags: u8 = 0;
            if (s.hosted) flags |= 1;
            if (s.locked) flags |= 2;
            if (s.new_channels) flags |= 4;
            b.u8_(flags) catch break :blk false;
            const n: u16 = @intCast(@min(s.conns.items.len, proto.stats_max_people));
            b.u16_(n) catch break :blk false;
            const now_ms = now / 1000;
            for (s.conns.items[0..n]) |o| {
                b.u32_(o.id) catch break :blk false;
                b.str(o.nameSlice()) catch break :blk false;
                b.str(o.chan.nameSlice()) catch break :blk false;
                b.u8_(o.route) catch break :blk false;
                var pf: u8 = 0;
                for (o.flows.items) |*f| {
                    if (f.late or f.struggling(now_ms)) pf |= proto.stats_late;
                    if (f.thin) pf |= proto.stats_thin;
                }
                if (o.streams[0].on) pf |= proto.stats_streaming;
                if (o.streams[1].on) pf |= proto.stats_camera;
                if (o.owner) pf |= proto.stats_owner;
                b.u8_(pf) catch break :blk false;
                const l = o.udp.load(.acquire);
                const udp_on = if (l) |ll| ll.isActive() else false;
                b.u8_(@intFromBool(udp_on)) catch break :blk false;
                // o servidor só responde ping: RTT só de quem ele mediu (senão 0 = não sabe)
                b.u16_(if (udp_on and l.?.ep.rtt_measured.load(.monotonic)) @intCast(@min(65535, l.?.ep.rttMs())) else 0) catch break :blk false;
                b.u32_(rate(o.tx_bytes -| o.tx_seen, dt_us)) catch break :blk false;
                b.u32_(rate(o.rx_bytes -| o.rx_seen, dt_us)) catch break :blk false;
                b.u32_(@intCast(@min(std.math.maxInt(u32), o.queue.queuedBytes()))) catch break :blk false;
                b.u16_(@intCast(@min(65535, o.watching.items.len))) catch break :blk false;
            }
            break :blk true;
        };
        for (s.conns.items) |o| {
            o.tx_seen = o.tx_bytes;
            o.rx_seen = o.rx_bytes;
        }
        s.stats_prev = .{ .at_us = now, .cpu_us = ps.cpu_us, .relayed = relayed, .received = s.received_bytes, .resyncs = s.n_resyncs, .thins = s.n_thins, .keyreqs = s.n_keyreqs, .slow = s.n_slow };
        if (!ok) return;
        const m = b.finish() catch return;
        defer m.release();
        for (s.conns.items) |o| if (o.stats_on and o.owner) o.queue.push(m);
    }

    // ------------------------------------------------------------- canais

    fn findChan(s: *Server, name: []const u8) ?*Chan {
        for (s.chans.items) |ch| if (std.mem.eql(u8, ch.nameSlice(), name)) return ch;
        return null;
    }

    fn canCreateChan(s: *Server) bool {
        return s.new_channels and s.chans.items.len < proto.max_channels;
    }

    fn addChan(s: *Server, name: []const u8, fixed: bool) !*Chan {
        const ch = try gpa.create(Chan);
        ch.* = .{ .fixed = fixed };
        copyInto(&ch.name, &ch.name_len, name);
        s.chans.append(gpa, ch) catch |e| {
            gpa.destroy(ch);
            return e;
        };
        return ch;
    }

    /// Canal criado por alguém que ficou vazio some (com o chat dele).
    fn dropIfEmpty(s: *Server, ch: *Chan) void {
        if (ch.fixed) return;
        for (s.conns.items) |o| if (o.chan == ch) return;
        const i = std.mem.findScalar(*Chan, s.chans.items, ch) orelse return;
        _ = s.chans.orderedRemove(i);
        s.log("canal #{s} vazio: fechado", .{ch.nameSlice()});
        ch.destroy();
    }

    /// Mensagem `channel` pra `cn`: em que canal ela está + a lista.
    fn pushChannels(s: *Server, cn: *Conn) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        s.buildChannels(&b, cn.chan) catch return;
        cn.queue.pushOwned(b.finish() catch return);
    }

    fn buildChannels(s: *Server, b: *proto.Builder, current: *Chan) !void {
        try b.begin(.channel);
        try b.str(current.nameSlice());
        try b.u8_(@intCast(s.chans.items.len));
        for (s.chans.items) |ch| {
            var people: u16 = 0;
            var live = false;
            for (s.conns.items) |o| {
                if (o.chan != ch) continue;
                people += 1;
                if (o.streams[0].on or o.streams[1].on) live = true;
            }
            try b.str(ch.nameSlice());
            try b.u16_(people);
            try b.u8_(@as(u8, if (live) proto.chan_live else 0) | @as(u8, if (ch.fixed) proto.chan_fixed else 0));
        }
    }

    /// A lista de canais (quantos em cada, quem está ao vivo) mudou: manda pra
    /// todo mundo. Compara com a última mandada (o "atual" de cada um fica de fora).
    fn broadcastChannels(s: *Server) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        s.buildChannels(&b, s.chans.items[0]) catch return;
        const m = b.finish() catch return;
        defer m.release();
        // montada sempre com o mesmo "atual" (o padrão): igual = nada mudou
        const body = m.data;
        if (body.len <= s.chans_sent.len and body.len == s.chans_sent_len and std.mem.eql(u8, body, s.chans_sent[0..body.len])) return;
        if (body.len <= s.chans_sent.len) {
            @memcpy(s.chans_sent[0..body.len], body);
            s.chans_sent_len = body.len;
        } else s.chans_sent_len = 0;
        for (s.conns.items) |o| s.pushChannels(o);
    }

    /// Manda o histórico do canal de `cn` (entrou na sala ou trocou de canal).
    fn pushHistory(s: *Server, cn: *Conn) !void {
        _ = s;
        const ch = cn.chan;
        for (0..ch.chat_len) |i| {
            const e = &ch.chat_log[(ch.chat_head + i) % chat_history_len];
            cn.queue.pushOwned(try chatMsg(e, proto.chat_history));
        }
    }

    /// Troca `cn` de canal (cria o canal se não existir e der). As transmissões
    /// dela seguem pro canal novo (o app anuncia de novo); quem assistia no
    /// canal velho para de receber. Chamado com o mutex travado.
    fn switchChannel(s: *Server, cn: *Conn, raw: []const u8) !void {
        var nb: [proto.channel_name_max]u8 = undefined;
        const name = normalizeChannel(raw, &nb) orelse {
            try pushNotice(cn, proto.notice_channel, "Nome de canal inválido: use letras, números, - ou _ (até 24).", 0);
            return;
        };
        if (std.mem.eql(u8, name, cn.chan.nameSlice())) return s.pushChannels(cn);
        const now = sync.nowMs();
        if (now -| cn.chan_switch_ms < 800) {
            try pushNotice(cn, proto.notice_channel, "Calma: trocando de canal rápido demais.", 0);
            return s.pushChannels(cn);
        }
        const target = s.findChan(name) orelse blk: {
            if (!s.new_channels) {
                try pushNotice(cn, proto.notice_channel, "Esse servidor não deixa criar canal novo.", 0);
                return s.pushChannels(cn);
            }
            if (s.chans.items.len >= proto.max_channels) {
                try pushNotice(cn, proto.notice_channel, "O servidor já tem canais demais.", 0);
                return s.pushChannels(cn);
            }
            break :blk try s.addChan(name, false);
        };
        cn.chan_switch_ms = now;
        const old = cn.chan;
        // quem assistia ela (no canal velho) para; ela para de assistir quem ficou lá
        for (0..2) |k| {
            const stream = proto.streamId(cn.id, @intCast(k));
            for (s.conns.items) |o| if (o != cn) o.forget(stream);
            const ss = &cn.streams[k];
            ss.codecs_sent = 0;
            ss.features_sent = 0;
            ss.view_sent = 0;
        }
        while (cn.watching.items.len > 0) cn.forget(cn.watching.items[cn.watching.items.len - 1]);
        cn.view_sizes.clearRetainingCapacity();
        var tmp: [120]u8 = undefined;
        try s.broadcastChat(old, std.fmt.bufPrint(&tmp, "{s} foi pro #{s}", .{ cn.nameSlice(), name }) catch "");
        cn.chan = target;
        s.log("{s}: #{s} → #{s}", .{ cn.nameSlice(), old.nameSlice(), name });
        s.dropIfEmpty(old); // (antes da lista: ela já sai sem o canal que esvaziou)
        // primeiro "você está no canal X" (o app limpa o chat), depois o histórico dele
        s.pushChannels(cn);
        try s.pushHistory(cn);
        try s.broadcastChat(target, std.fmt.bufPrint(&tmp, "{s} entrou no #{s}", .{ cn.nameSlice(), name }) catch "");
        try s.broadcastMembers();
    }

    /// Chamado com o mutex travado.
    fn findConn(s: *Server, id: u32) ?*Conn {
        for (s.conns.items) |o| if (o.id == id) return o;
        return null;
    }

    /// Pede um IDR pra quem transmite `stream`. Chamado com o mutex travado.
    fn requestKey(s: *Server, stream: u32, force: bool) void {
        const o = s.findConn(proto.memberOf(stream)) orelse return;
        const kind = proto.kindOf(stream);
        const ss = &o.streams[kind];
        const now = sync.nowMs();
        if (!force and now - ss.last_keyreq_ms < keyreq_interval_ms) return;
        ss.last_keyreq_ms = now;
        s.n_keyreqs +%= 1;
        const m = proto.Msg.alloc(.keyreq, 1) catch return;
        m.payload()[0] = kind;
        o.queue.pushOwned(m);
    }

    /// Áudio (da tela) vai pra quem assiste; não espera IDR e só é descartado
    /// se a fila do espectador estiver muito atrasada (som picotado é melhor
    /// que atraso).
    fn forwardAudio(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < proto.audio_header_len) return error.BadMessage;
        const stream = proto.streamId(cn.id, proto.kind_screen);
        const m = try proto.Msg.alloc(.audio, 4 + payload.len);
        defer m.release();
        m.from = stream;
        std.mem.writeInt(u32, m.payload()[0..4], stream, .little);
        @memcpy(m.payload()[4..], payload);
        s.mutex.lock();
        defer s.mutex.unlock();
        cn.rx_bytes += payload.len;
        s.received_bytes += payload.len;
        for (s.conns.items) |o| {
            if (o == cn or !contains(&o.watching, stream)) continue;
            if (o.queue.queuedBytes() > max_viewer_backlog * 2) continue;
            o.queue.pushUrgent(m); // som não espera atrás de quadro
            o.tx_bytes += m.data.len;
            _ = s.relayed_bytes.fetchAdd(m.data.len, .monotonic);
        }
    }

    /// Voz vai pra todo mundo da sala (menos quem fala e quem está surdo),
    /// furando a fila: conversa não pode esperar atrás de quadros de vídeo.
    fn forwardVoice(s: *Server, cn: *Conn, payload: []const u8) !void {
        // seq + pelo menos 1 byte de Opus (pacote vazio = 120 ms de "remendo" do lado de lá)
        if (payload.len <= 4) return error.BadMessage;
        const m = try proto.Msg.alloc(.voice, 4 + payload.len);
        defer m.release();
        m.from = cn.id;
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..], payload);
        s.mutex.lock();
        defer s.mutex.unlock();
        cn.rx_bytes += payload.len;
        s.received_bytes += payload.len;
        if (cn.muted) return; // silenciado pelo admin
        for (s.conns.items) |o| {
            if (o == cn or o.deaf or !o.authed or o.chan != cn.chan) continue;
            if (o.queue.queuedBytes() > max_viewer_backlog * 2) continue;
            o.queue.pushUrgent(m);
            o.tx_bytes += m.data.len;
            _ = s.relayed_bytes.fetchAdd(m.data.len, .monotonic);
        }
    }

    /// Ponteiro "olha aqui": vai pra quem assiste o stream e pra quem transmite.
    fn forwardPointer(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < 9) return error.BadMessage;
        const stream = std.mem.readInt(u32, payload[0..4], .little);
        s.mutex.lock();
        defer s.mutex.unlock();
        // limite por pessoa (mais que isso é lixo ou bug)
        const sec = sync.nowMs() / 1000;
        if (sec != cn.pointer_sec) {
            cn.pointer_sec = sec;
            cn.pointer_count = 0;
        }
        cn.pointer_count += 1;
        if (cn.pointer_count > pointer_rate) return;
        const owner = proto.memberOf(stream);
        if (owner != cn.id and !contains(&cn.watching, stream)) return;
        const m = try proto.Msg.alloc(.pointer, 4 + 9);
        defer m.release();
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..13], payload[0..9]);
        for (s.conns.items) |o| {
            if (o == cn or o.chan != cn.chan) continue;
            if (o.id != owner and !contains(&o.watching, stream)) continue;
            o.queue.pushUrgent(m);
        }
    }

    /// Cursor de quem transmite (fora do vídeo): vai pra quem assiste.
    fn forwardCursor(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < 5) return error.BadMessage;
        const kind = payload[0];
        if (kind > proto.kind_camera) return error.BadMessage;
        s.mutex.lock();
        defer s.mutex.unlock();
        if (!cn.streams[kind].on) return;
        const sec = sync.nowMs() / 1000;
        if (sec != cn.cursor_sec) {
            cn.cursor_sec = sec;
            cn.cursor_count = 0;
        }
        cn.cursor_count += 1;
        if (cn.cursor_count > cursor_rate) return;
        const stream = proto.streamId(cn.id, kind);
        const m = try proto.Msg.alloc(.cursor, 8);
        defer m.release();
        std.mem.writeInt(u32, m.payload()[0..4], stream, .little);
        @memcpy(m.payload()[4..8], payload[1..5]);
        for (s.conns.items) |o| {
            if (o != cn and contains(&o.watching, stream)) o.queue.pushUrgent(m);
        }
    }

    /// Desenho por cima de uma transmissão: vai pra quem transmite e pra quem
    /// assiste (como o ponteiro).
    fn forwardDraw(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < 7) return error.BadMessage;
        const stream = std.mem.readInt(u32, payload[0..4], .little);
        const n = std.mem.readInt(u16, payload[5..7], .little);
        if (n > proto.draw_max_points or payload.len != 7 + @as(usize, n) * 4) return error.BadMessage;
        s.mutex.lock();
        defer s.mutex.unlock();
        const sec = sync.nowMs() / 1000;
        if (sec != cn.draw_sec) {
            cn.draw_sec = sec;
            cn.draw_count = 0;
        }
        cn.draw_count += 1;
        if (cn.draw_count > draw_rate) return;
        if (cn.no_draw) return; // o admin tirou o pincel
        const owner = proto.memberOf(stream);
        if (owner != cn.id and !contains(&cn.watching, stream)) return;
        const m = try proto.Msg.alloc(.draw, 4 + payload.len);
        defer m.release();
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..], payload);
        for (s.conns.items) |o| {
            if (o == cn or o.chan != cn.chan) continue;
            if (o.id != owner and !contains(&o.watching, stream)) continue;
            o.queue.pushUrgent(m);
        }
    }

    fn forwardFrame(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < proto.frame_header_len) return error.BadMessage;
        const seq = std.mem.readInt(u32, payload[0..4], .little);
        const flags = payload[4];
        const is_key = flags & proto.frame_key != 0;
        const droppable = flags & proto.frame_droppable != 0 and !is_key;
        const kind: u8 = if (flags & proto.frame_camera != 0) proto.kind_camera else proto.kind_screen;
        const stream = proto.streamId(cn.id, kind);

        // confirma na hora: o transmissor mede o próprio upload com isso
        const ack = try proto.Msg.alloc(.ack, 5);
        ack.payload()[0] = kind;
        std.mem.writeInt(u32, ack.payload()[1..5], seq, .little);
        cn.queue.pushUrgentOwned(ack);

        // mensagem encaminhada montada uma vez só: [u32 stream][frame]
        const m = try proto.Msg.alloc(.frame, 4 + payload.len);
        defer m.release();
        m.from = stream;
        m.flags = flags;
        std.mem.writeInt(u32, m.payload()[0..4], stream, .little);
        @memcpy(m.payload()[4..], payload);

        s.mutex.lock();
        defer s.mutex.unlock();
        const ss = &cn.streams[kind];
        if (!ss.on) return; // parada (pelo admin) e ainda chegando quadro velho
        cn.rx_bytes += payload.len;
        s.received_bytes += payload.len;
        const now_ms = sync.nowMs();
        const now_us = sync.nowUs();
        ss.last_frame_ms = now_ms;
        if (droppable) ss.last_droppable_ms = now_ms;
        if (is_key) ss.last_key_ms = now_ms;
        // dá pra afinar quem não dá conta (a transmissão tem quadros puláveis)
        var thinnable = now_ms -| ss.last_droppable_ms < 2000;
        if (thinnable) {
            // afinar é pra proteger quem está dando conta. Se a maioria está
            // sofrendo (gargalo comum, ex.: o upload de quem hospeda, ou só tem
            // um espectador), quem resolve é a taxa (mantém os 30 q/s)
            var viewers: u32 = 0;
            var struggling: u32 = 0;
            for (s.conns.items) |o| {
                if (o == cn or !contains(&o.watching, stream)) continue;
                viewers += 1;
                const f = o.flow(stream) orelse continue;
                if (f.struggling(now_ms)) struggling += 1;
            }
            thinnable = (struggling + 1) * 2 <= viewers;
        }
        var need_key = false;
        var resynced = false; // algum espectador recomeçou agora
        var late = false; // algum espectador acumulando atraso há mais de 1 s
        for (s.conns.items) |o| {
            if (o == cn or !contains(&o.watching, stream)) continue;
            const f = o.flow(stream) orelse continue;
            if (f.thin and now_ms >= f.thin_until_ms and !f.late) {
                // tempo de afinar acabou e ele está em dia: volta a receber tudo
                // (é um teste: se começar a atrasar, afina de novo na hora)
                f.thin = false;
                f.thin_ended_ms = now_ms;
                f.probe_until_ms = now_ms + 3000;
            }
            if (f.thin and droppable) continue; // ninguém precisa desse pra decodificar o resto
            if (f.decoder_behind) {
                // CPU de quem assiste não deu conta: taxa menor também alivia o decoder
                f.decoder_behind = false;
                resynced = true;
            }
            if (contains(&o.waiting_key, stream)) {
                // depois de atrasar, o IDR só sai quando o que já foi enviado
                // chegar (senão ele fica na fila atrás do atraso)
                if (f.draining) {
                    if (!f.drained(now_us)) continue;
                    f.draining = false;
                }
                if (!is_key) {
                    // só pede IDR quando o tempo de espera desse espectador passou
                    if (now_ms >= f.resync_after_ms) need_key = true;
                    continue;
                }
                remove(&o.waiting_key, stream);
            }
            const allowance = f.win.keyAllowanceUs(now_us);
            const excess = f.win.excessUs(now_us, default_base_us);
            f.updateTrend(excess, now_us);
            const probe_failed = !f.thin and now_ms < f.probe_until_ms and excess > soft_viewer_excess_us;
            if ((f.late or probe_failed) and thinnable and f.thinOut(now_ms)) {
                // primeiro tira só dele metade dos quadros (os que já estão na
                // fila também); a taxa da sala toda só desce se nem assim ele der conta
                _ = o.queue.dropDroppable(stream);
                f.probe_until_ms = 0;
                s.n_thins +%= 1;
                s.log("{s} atrasando {d} ms com {s}: recebendo só metade dos quadros por {d} s", .{ o.nameSlice(), excess / 1000, cn.nameSlice(), f.thin_ms / 1000 });
            }
            // recém-afinado ainda escoando o atraso não conta
            if (f.late and !(f.thin and now_ms - f.thin_since_ms < thin_grace_ms)) late = true;
            if (excess > max_viewer_excess_us + allowance or o.queue.queuedBytes() > max_viewer_backlog) {
                // espectador acumulando atraso: descarta o que nem saiu da
                // fila, espera o resto chegar e recomeça de um IDR
                f.win.dropNewest(o.queue.dropFrames(stream));
                addUnique(&o.waiting_key, stream);
                f.draining = true;
                f.late = false;
                f.trend_at_us = 0;
                resynced = true;
                s.n_resyncs +%= 1;
                _ = f.backoff(now_ms);
                if (thinnable) _ = f.thinOut(now_ms); // depois do IDR, só metade
                s.log("{s} atrasou {d} ms assistindo {s}: recomeçando de um IDR (próximo em {d} ms)", .{ o.nameSlice(), excess / 1000, cn.nameSlice(), f.resync_after_ms - now_ms });
                continue;
            }
            o.queue.push(m);
            o.tx_bytes += m.data.len;
            f.win.sent(seq, now_us, is_key);
            _ = s.relayed_bytes.fetchAdd(m.data.len, .monotonic);
        }
        if (need_key) s.requestKey(stream, false);
        if ((resynced or late) and now_ms - ss.last_slow_ms > 2000) {
            // se a maioria está sofrendo, o gargalo é comum (o upload de quem
            // hospeda a sala, ou só tem um espectador): a taxa desce o quanto
            // precisar. Se é a minoria, desce no máximo até a metade: quem não
            // dá conta nem assim fica recomeçando de IDR de vez em quando, sem
            // estragar a qualidade pros outros.
            ss.last_slow_ms = now_ms;
            var viewers: u32 = 0;
            var struggling: u32 = 0;
            for (s.conns.items) |o| {
                if (o == cn or !contains(&o.watching, stream)) continue;
                viewers += 1;
                const f = o.flow(stream) orelse continue;
                if (f.struggling(now_ms)) struggling += 1;
            }
            // todo mundo que atrasou foi afinado e está escoando: a taxa fica
            if (struggling == 0) return;
            const majority = struggling * 2 > viewers;
            const hint = try proto.Msg.alloc(.viewer_slow, 2);
            hint.payload()[0] = kind;
            hint.payload()[1] = if (majority) 10 else 50;
            cn.queue.pushUrgentOwned(hint);
            s.n_slow +%= 1;
            s.log("pedindo taxa menor pra {s} ({d} de {d} espectadores com dificuldade{s})", .{ cn.nameSlice(), struggling, viewers, if (resynced) "" else ", atrasando sem escoar" });
        }
    }
};
