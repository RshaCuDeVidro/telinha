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
const files_mod = @import("files.zig");
const web = @import("web.zig");
const builtin = @import("builtin");
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
    web: bool = false, // assistindo pelo navegador (WebSocket; web.zig)
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
    bot: bool = false, // conectou como bot (feat_bot): marcado na lista, nunca admin
    last_edit_ms: u64 = 0, // chat_edit (limite de ritmo)
    last_action_ms: u64 = 0, // embed_action (limite de ritmo)
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
    chan: *Chan = undefined, // o canal de texto em que a pessoa está (depois do join)
    call: ?*Chan = null, // a call (voz e transmissões); null = fora de call
    calls_aware: bool = false, // o app separa call de canal (feat_calls); senão os dois andam juntos
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
    // resposta: a mensagem citada (o trecho vem daqui, não de quem respondeu)
    reply_id: u32 = 0,
    reply_from: u32 = 0,
    reply_name: [48]u8 = undefined,
    reply_name_len: usize = 0,
    reply_snip: [proto.chat_quote_max]u8 = undefined,
    reply_snip_len: usize = 0,
    // privada: só quem mandou e `to` recebem (não entra no histórico do canal)
    to: u32 = 0,
    to_name: [48]u8 = undefined,
    to_name_len: usize = 0,
    // arquivo anexado (files.zig): quem vê baixa pelo id
    file_id: u32 = 0,
    file_name: [proto.file_name_max]u8 = undefined,
    file_name_len: usize = 0,
    file_size: u64 = 0,
    // cartão (proto.embed_*): bytes como vieram; o servidor não interpreta
    embed: ?[]u8 = null,

    const React = struct { emoji: u8, from: u32 };

    /// Copia o começo da mensagem `q` pro trecho citado (sem cortar um
    /// caractere UTF-8 no meio; imagem sem texto vira "[imagem]").
    fn quote(e: *ChatEntry, q: *const ChatEntry) void {
        e.reply_id = q.id;
        e.reply_from = q.from;
        Server.copyInto(&e.reply_name, &e.reply_name_len, q.name[0..q.name_len]);
        var t: []const u8 = std.mem.trim(u8, q.text, " \t\r\n");
        if (t.len == 0 and (q.img != null or q.img_expired)) t = "[imagem]";
        var n = @min(t.len, e.reply_snip.len);
        while (n > 0 and n < t.len and t[n] & 0xC0 == 0x80) n -= 1;
        @memcpy(e.reply_snip[0..n], t[0..n]);
        e.reply_snip_len = n;
        for (e.reply_snip[0..n]) |*ch| if (ch.* == '\n' or ch.* == '\r') {
            ch.* = ' ';
        };
    }

    fn free(e: *ChatEntry) void {
        gpa.free(e.text);
        if (e.img) |im| gpa.free(im);
        if (e.embed) |em| gpa.free(em);
        e.reacts.deinit(gpa);
    }
};

/// Imagens guardadas no histórico do chat, no total (as mais velhas expiram).
const chat_img_budget = 24 * 1024 * 1024;
/// Imagem no chat: no máximo uma a cada tanto, por pessoa.
const chat_img_interval_ms = 1500;
/// Editar mensagem (chat_edit) e clicar em botão de cartão: no máximo tantas por segundo.
const chat_edit_interval_ms = 200;
const embed_action_interval_ms = 120;

/// O cartão (embed) no fim de chat/chat_edit: u32 tamanho + bytes. null = sem
/// (tamanho 0, campo ausente de app antigo, ou versão que não é a nossa).
fn readEmbed(r: *proto.Reader) !?[]const u8 {
    const n = r.u32_() catch return null;
    if (n == 0) return null;
    if (n > proto.embed_max) return error.BadMessage;
    const b = try r.take(n);
    if (b[0] != proto.embed_version) return null;
    return b;
}

/// Um canal (como no IRC): o chat dele, quem está nele e as transmissões de
/// quem está nele. Voz, "assistir", ponteiro e desenho só dentro do canal.
/// Banimento, silenciar, trancar e lotação valem pro servidor inteiro.
const Chan = struct {
    name: [proto.channel_name_max]u8 = undefined,
    name_len: usize = 0,
    fixed: bool = false, // não some quando esvazia
    locked: bool = false, // só admin entra
    has_password: bool = false,
    password_hash: [32]u8 = undefined, // SHA-256("telinha-canal-v1" + senha)
    topic: [proto.chan_topic_max]u8 = undefined,
    topic_len: usize = 0,
    chat_log: [chat_history_len]ChatEntry = undefined,
    chat_len: usize = 0,
    chat_head: usize = 0,
    creator_key: u64 = 0, // a chave do app de quem criou (0 = o servidor/admin): manda no canal
    hidden: bool = false, // invisível: fora da lista de quem não está nele
    empty_since_ms: u64 = 0, // vazio desde (0 = tem gente): some depois de proto.chan_keep_empty_ms
    banned: [16]u64 = .{0} ** 16, // chaves que quem manda tirou do canal

    fn nameSlice(ch: *const Chan) []const u8 {
        return ch.name[0..ch.name_len];
    }

    /// Admin da sala, ou quem criou o canal.
    fn isBoss(ch: *const Chan, cn: *const Conn) bool {
        return cn.admin or (ch.creator_key != 0 and ch.creator_key == cn.client_key);
    }

    fn isBanned(ch: *const Chan, key: u64) bool {
        if (key == 0) return false;
        for (ch.banned) |b| if (b == key) return true;
        return false;
    }

    fn ban(ch: *Chan, key: u64) void {
        if (key == 0 or ch.isBanned(key)) return;
        for (&ch.banned) |*b| if (b.* == 0) {
            b.* = key;
            return;
        };
        // cheia: o mais velho sai
        std.mem.copyForwards(u64, ch.banned[0 .. ch.banned.len - 1], ch.banned[1..]);
        ch.banned[ch.banned.len - 1] = key;
    }

    fn topicSlice(ch: *const Chan) []const u8 {
        return ch.topic[0..ch.topic_len];
    }

    fn hashPassword(pw: []const u8) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("telinha-canal-v1");
        h.update(pw);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    fn passwordOk(ch: *const Chan, pw: []const u8) bool {
        if (!ch.has_password) return true;
        const h = hashPassword(pw);
        return std.crypto.timing_safe.eql([32]u8, h, ch.password_hash);
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
    /// Arquivo onde guardar o que sobrevive ao servidor reiniciar (canais
    /// fixos com senha/trava/tópico, banidos, silenciados, sem pincel).
    /// Vazio = nada fica (a sala do app).
    state_path: []const u8 = "",
    /// Onde guardar os arquivos mandados na sala (cifrados; ver files.zig).
    /// Vazio = uma pasta temporária do sistema.
    files_dir: []const u8 = "",
    /// Bots (feat_bot): recusar todos, ou só aceitar quem mandar esse token.
    no_bots: bool = false,
    bot_token: []const u8 = "",
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
    no_bots: bool = false,
    bot_token: [64]u8 = undefined,
    bot_token_len: usize = 0,
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
    state_path: [400]u8 = undefined,
    state_path_len: usize = 0,
    chans_sent: [1024]u8 = undefined, // última lista de canais mandada (só manda se mudar)
    chans_sent_len: usize = 0,
    next_chat_id: u32 = 1,
    /// As últimas mensagens privadas (pra conferir o trecho citado numa
    /// resposta a uma delas; não são mandadas pra mais ninguém).
    dms: [64]ChatEntry = undefined,
    files: files_mod.Store = .{},
    web_listener: ?*web.Listener = null,
    web_link: [300]u8 = undefined, // link pra assistir no navegador (vazio = não tem)
    web_link_len: usize = 0,
    dms_len: usize = 0,
    dms_head: usize = 0,
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
        copyInto(&s.state_path, &s.state_path_len, opts.state_path);
        s.loadState();
        {
            var fb: [480]u8 = undefined;
            s.files.init(if (opts.files_dir.len > 0) opts.files_dir else tempFilesDir(&fb));
        }
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        s.instance = std.mem.readInt(u64, &rnd, .little);
        copyInto(&s.password, &s.password_len, opts.password);
        copyInto(&s.room_name, &s.room_name_len, opts.room_name);
        copyInto(&s.logs_dir, &s.logs_dir_len, opts.logs_dir);
        copyInto(&s.admin_token, &s.admin_token_len, opts.admin_token);
        copyInto(&s.bot_token, &s.bot_token_len, opts.bot_token);
        s.no_bots = opts.no_bots;
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
        for (0..s.dms_len) |i| s.dms[(s.dms_head + i) % s.dms.len].free();
        s.files.deinit();
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
            // arquivos vencidos e subidas paradas, a cada 10 s
            if (ticks % 40 == 0) _ = s.files.expire(now_ms);
            // canais vazios há dias, a cada minuto
            if (ticks % 240 == 0) s.expireChans(now_ms);
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
        if (s.web_listener) |l| l.stop();
        s.web_listener = null;
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
        if (cn.web) cn.queue.writerLoop(cn.sock, null, null) else cn.queue.writerLoop(cn.sock, &cn.channel, &cn.udp);
        cn.release();
    }

    // ------------------------------------------------- navegador (web.zig)

    /// Liga a porta web (só 127.0.0.1: fica atrás do HTTPS de um túnel/proxy).
    pub fn startWeb(s: *Server, port: u16) !void {
        s.web_listener = try web.Listener.start(port, s, adoptWebCallback);
    }

    /// O link que a sala divulga pra assistir no navegador (o túnel mudou de
    /// endereço, ou caiu: vazio). Manda pra todo mundo.
    pub fn setWebLink(s: *Server, link: []const u8) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        copyInto(&s.web_link, &s.web_link_len, link);
        for (s.conns.items) |o| if (o.authed and !o.web) pushWebLink(s, o) catch {};
    }

    fn pushWebLink(s: *Server, cn: *Conn) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.web_link);
        try b.str(s.web_link[0..s.web_link_len]);
        cn.queue.pushOwned(try b.finish());
    }

    fn adoptWebCallback(ctx: *anyopaque, sock: net.Socket, ip: []const u8) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        if (s.stopped.load(.acquire)) return net.close(sock);
        const cn = gpa.create(Conn) catch return net.close(sock);
        cn.* = .{ .server = s, .sock = sock, .web = true, .route = proto.route_web };
        const n = @min(ip.len, cn.ip.len);
        @memcpy(cn.ip[0..n], ip[0..n]);
        cn.ip_len = n;
        s.retain(); // solta no release da conexão
        readerLoop(cn); // já está numa thread só dessa conexão (web.serveOne)
    }

    /// O primeiro do navegador: `web_hello` (a senha e os campos do hello).
    fn webHandshake(s: *Server, cn: *Conn, buf: *std.ArrayList(u8)) !void {
        net.setRecvTimeout(cn.sock, handshake_timeout_ms);
        const msg = (try web.readMessage(cn.sock, buf)) orelse return error.Protocol;
        if (msg.len < 1 or msg[0] != @intFromEnum(proto.Type.web_hello)) return error.Protocol;
        var r: proto.Reader = .{ .data = msg[1..] };
        const given = try r.str();
        s.mutex.lock();
        const ok = constEql(given, s.password[0..s.password_len]);
        s.mutex.unlock();
        if (!ok) {
            // senha errada: diz e fecha (sem escritora ainda: manda direto)
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var b: proto.Builder = .{};
            defer b.deinit();
            try b.begin(.denied);
            try b.str("Senha errada.");
            try b.u8_(proto.deny_generic);
            const m = try b.finish();
            defer m.release();
            try proto.wsFrameInto(&out, m);
            net.sendAll(cn.sock, out.items) catch {};
            s.log("navegador recusado: senha errada", .{});
            return error.AuthFailed;
        }
        net.setRecvTimeout(cn.sock, 0);
        _ = cn.refs.fetchAdd(1, .monotonic);
        sync.spawn(writerLoop, .{cn}) catch {
            _ = cn.refs.fetchSub(1, .monotonic);
            return error.ThreadFailed;
        };
        try s.helloFields(cn, &r);
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
        try s.helloFields(cn, &r);
    }

    /// Os campos do hello (do app, ou do navegador depois da senha): nome,
    /// token, versão, o que decodifica e entende, o canal. Entra na sala.
    fn helloFields(s: *Server, cn: *Conn, r: *proto.Reader) !void {
        const name = try r.str();
        const token = if (cn.web) blk: {
            _ = try r.str(); // pelo navegador não vira admin
            break :blk "";
        } else try r.str();
        cn.client_key = r.u64_() catch 0;
        if (r.str()) |v| {
            const n = @min(v.len, cn.app_version.len - 1);
            @memcpy(cn.app_version[0..n], v[0..n]);
        } else |_| {}
        cn.decode_codecs = (r.u8_() catch 0) | proto.codecs_h264;
        cn.features = r.u8_() catch 0;
        cn.calls_aware = cn.features & proto.feat_calls != 0;
        cn.bot = cn.features & proto.feat_bot != 0;
        const want_chan = r.str() catch ""; // app antigo não manda: o canal padrão
        const bot_token = r.str() catch ""; // só bot manda
        if (cn.bot) try s.admitBot(cn, name, bot_token);
        // bot nunca vira dono/admin, nem mandando o token
        try s.join(cn, name, if (cn.bot) "" else token, want_chan);
    }

    /// A sala aceita esse bot? (--sem-bots recusa todos; --token-bots pede o token)
    fn admitBot(s: *Server, cn: *Conn, name: []const u8, token: []const u8) !void {
        if (s.no_bots) {
            s.log("bot {s} recusado (a sala não aceita bots)", .{safeName(name)});
            refuse(cn, proto.deny_bots, "Essa sala não aceita bots.");
            return error.BotsRefused;
        }
        if (s.bot_token_len > 0 and !constEql(token, s.bot_token[0..s.bot_token_len])) {
            s.log("bot {s} recusado (token de bot errado)", .{safeName(name)});
            refuse(cn, proto.deny_bots, "Token de bot errado: essa sala só aceita bots com o token dela.");
            return error.BotsRefused;
        }
    }

    fn readerLoop(cn: *Conn) void {
        sync.nameThread("sala-leitura");
        const s = cn.server;
        var rb: proto.RecvBuf = .{};
        defer rb.deinit();
        if (cn.web) {
            var wb: std.ArrayList(u8) = .empty;
            defer wb.deinit(gpa);
            if (s.webHandshake(cn, &wb)) {
                while (true) {
                    const msg = (web.readMessage(cn.sock, &wb) catch break) orelse continue;
                    if (msg.len == 0) continue;
                    const typ: proto.Type = @enumFromInt(msg[0]);
                    // o navegador só assiste, conversa e troca de canal
                    switch (typ) {
                        .watch, .keyreq, .ack, .ping, .view_size, .chat, .react, .channel, .call, .embed_action => {},
                        else => continue,
                    }
                    s.handle(cn, typ, msg[1..]) catch break;
                }
            } else |_| {}
        } else if (s.handshake(cn, &rb)) {
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
                // (campos do fim: app antigo não manda)
                const reply_to = r.u32_() catch 0;
                const to = r.u32_() catch 0;
                const embed = try readEmbed(&r);
                if (text.len == 0 and img == null and embed == null) return;
                s.mutex.lock();
                defer s.mutex.unlock();
                if (img != null) {
                    const now = sync.nowMs();
                    if (now -% cn.last_img_ms < chat_img_interval_ms) return; // rajada de imagem: ignora
                    cn.last_img_ms = now;
                }
                if (to != 0) return s.sendDm(cn, to, reply_to, text, img, embed);
                var e = try s.newEntry(cn.id, cn.nameSlice(), text, img, s.findQuote(cn, reply_to, false));
                if (embed) |em| e.embed = gpa.dupe(u8, em) catch {
                    e.free();
                    return error.OutOfMemory;
                };
                try s.postEntryFrom(cn.chan, e, cn);
            },
            .chat_edit => {
                const id = try r.u32_();
                const text = std.mem.trim(u8, try r.str(), " \t\r\n");
                const embed = try readEmbed(&r);
                s.mutex.lock();
                defer s.mutex.unlock();
                const now = sync.nowMs();
                if (now -% cn.last_edit_ms < chat_edit_interval_ms) return; // rajada: ignora
                cn.last_edit_ms = now;
                try s.editChat(cn, id, text, embed);
            },
            .embed_action => {
                const id = try r.u32_();
                const button = try r.u8_();
                s.mutex.lock();
                defer s.mutex.unlock();
                const now = sync.nowMs();
                if (now -% cn.last_action_ms < embed_action_interval_ms) return; // clique repetido: ignora
                cn.last_action_ms = now;
                try s.embedAction(cn, id, button);
            },
            .file_put => try s.onFilePut(cn, &r),
            .file_data => try s.onFileData(cn, &r),
            .file_get => try s.onFileGet(cn, &r),
            .file_cancel => {
                const id = try r.u32_();
                s.mutex.lock();
                defer s.mutex.unlock();
                const e = s.files.find(id) orelse return;
                if (e.from == cn.id and !e.complete) s.files.remove(id);
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
                    try s.broadcastChat(cn.call orelse cn.chan, std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), what }) catch "");
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
                    if (target == cn.id or cn.call == null or tc.call != cn.call) return; // só quem está na mesma call
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
                const pw = r.str() catch "";
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.switchChannel(cn, name, pw);
            },
            .call => {
                const name = try r.str();
                const pw = r.str() catch "";
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.joinCall(cn, name, pw);
            },
            .chan_admin => {
                const action = try r.u8_();
                const name = try r.str();
                const value = r.str() catch "";
                const target = r.u32_() catch 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.chanAdmin(cn, action, name, value, target);
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
        if (action == proto.admin_clear_chat) {
            // "zerar" a sala sem reiniciar o servidor: o histórico de todos os
            // canais (privadas inclusive) e os arquivos que ficaram
            for (s.chans.items) |ch| {
                for (0..ch.chat_len) |i| ch.chat_log[(ch.chat_head + i) % chat_history_len].free();
                ch.chat_len = 0;
                ch.chat_head = 0;
            }
            const gone = s.files.removeComplete();
            var tmp: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&tmp, "{s} limpou o chat da sala", .{cn.nameSlice()}) catch "";
            for (s.conns.items) |o| if (o.authed) pushNotice(o, proto.notice_chat_cleared, text, 0) catch {};
            s.log("{s} limpou o chat da sala ({d} arquivos)", .{ cn.nameSlice(), gone });
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
                    s.saveState();
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
                    s.saveState();
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
                    s.saveState();
                }
                s.log("{s} {s} {s}", .{ cn.nameSlice(), if (allow) "devolveu o pincel de" else "tirou o pincel de", t.nameSlice() });
                const text = std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), if (allow) "devolveu seu pincel." else "tirou seu pincel." }) catch "";
                try pushNotice(t, if (allow) proto.notice_draw_on else proto.notice_draw_off, text, 0);
                try s.broadcastMembers(); // quem vê a bandeira apaga os traços dela
            },
            proto.admin_set_admin => {
                if (!cn.owner) return; // só o dono promove/rebaixa
                const on = value != 0;
                if (on and t.bot) return; // bot não vira admin
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

    /// O nome que vai pra sala: sem espaço nas pontas, até 32 bytes. Vazio, ou
    /// um convite colado no campo do nome (a senha ia aparecer pra todo mundo),
    /// vira "anônimo".
    pub fn safeName(raw_name: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
        if (trimmed.len == 0 or std.ascii.startsWithIgnoreCase(trimmed, "telinha://")) return "anônimo";
        return trimmed[0..@min(trimmed.len, 32)];
    }

    fn join(s: *Server, cn: *Conn, raw_name: []const u8, token: []const u8, want_chan: []const u8) !void {
        s.mutex.lock();
        defer s.mutex.unlock();
        // a sala fechou enquanto essa conexão fazia o handshake
        if (s.stopped.load(.acquire)) return error.Stopped;
        const is_owner = s.admin_token_len > 0 and std.mem.eql(u8, token, s.admin_token[0..s.admin_token_len]);
        const base = safeName(raw_name);
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
        var needs_pw = false;
        if (normalizeChannel(want_chan, &nb)) |nm| {
            if (s.findChan(nm)) |ch| {
                // trancado ou com senha: começa no padrão (o app pergunta a senha)
                const boss = is_owner or (ch.creator_key != 0 and ch.creator_key == cn.client_key);
                if (ch.isBanned(cn.client_key) and !is_owner) {
                    // tirado do canal: começa no padrão
                } else if ((ch.locked or ch.has_password) and !boss) {
                    needs_pw = ch.has_password and !ch.locked;
                } else cn.chan = ch;
            } else if (s.canCreateChan()) {
                if (s.addChan(nm, false)) |ch| {
                    ch.creator_key = cn.client_key;
                    cn.chan = ch;
                    s.saveState();
                } else |_| {}
            }
        }
        cn.call = cn.chan; // entrar na sala = estar na call do canal em que entrou
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
        try b.u8_(s.serverFeatures()); // o que este servidor sabe fazer (srv_*)
        cn.queue.pushOwned(try b.finish());

        // em que canal ela está e quais existem; depois o que já foi dito nele
        s.pushChannels(cn);
        try s.pushHistory(cn);
        if (needs_pw) pushNotice(cn, proto.notice_channel, "Esse canal tem senha.", proto.notice_channel_needs_password) catch {};
        // dá pra chamar gente pelo navegador: o link (o app mostra "copiar")
        if (s.web_link_len > 0 and !cn.web) s.pushWebLink(cn) catch {};

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
        // arquivos que ela estava subindo (pela metade) somem
        var fi: usize = 0;
        while (fi < s.files.items.items.len) {
            const fe = s.files.items.items[fi];
            if (fe.from == cn.id and !fe.complete) s.files.remove(fe.id) else fi += 1;
        }
        for (s.conns.items) |o| {
            o.forget(proto.streamId(cn.id, proto.kind_screen));
            o.forget(proto.streamId(cn.id, proto.kind_camera));
        }
        s.log("{s} saiu ({d} na sala)", .{ cn.nameSlice(), s.conns.items.len });
        if (s.stopped.load(.acquire)) return;
        var tmp: [96]u8 = undefined;
        s.broadcastChat(cn.chan, std.fmt.bufPrint(&tmp, "{s} saiu da sala", .{cn.nameSlice()}) catch "") catch {};
        if (cn.call) |cc| if (cc != cn.chan) s.dropIfEmpty(cc);
        s.dropIfEmpty(cn.chan);
        s.broadcastMembers() catch {};
    }

    fn chatMsg(e: *const ChatEntry, flags: u8) !*proto.Msg {
        return chatMsgFor(e, flags, null);
    }

    /// Pra um bot: no fim vai onde está quem mandou (o canal de texto e a
    /// call), pra ele poder ir atrás (o "!join" de qualquer canal).
    fn chatMsgFor(e: *const ChatEntry, flags: u8, sender: ?*const Conn) !*proto.Msg {
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
        // resposta (0 = não é) e privada (0 = pra todo mundo)
        try b.u32_(e.reply_id);
        if (e.reply_id != 0) {
            try b.u32_(e.reply_from);
            try b.str(e.reply_name[0..e.reply_name_len]);
            try b.str(e.reply_snip[0..e.reply_snip_len]);
        }
        try b.u32_(e.to);
        if (e.to != 0) try b.str(e.to_name[0..e.to_name_len]);
        // arquivo (0 = nenhum); o texto já diz "📎 nome (tamanho)" pra app antigo
        try b.u32_(e.file_id);
        if (e.file_id != 0) {
            try b.str(e.file_name[0..e.file_name_len]);
            try b.u64_(e.file_size);
        }
        // cartão (0 = nenhum)
        const em = e.embed orelse &.{};
        try b.u32_(@intCast(em.len));
        try b.bytes(em);
        if (sender) |sc| try writeWhere(&b, sc);
        return b.finish();
    }

    /// A mensagem `id` que `cn` pode ver: do histórico do canal dela ou das
    /// privadas em que ela está. Mutex travado.
    fn visibleEntry(s: *Server, cn: *const Conn, id: u32) ?*ChatEntry {
        if (id == 0) return null;
        const ch = cn.chan;
        for (0..ch.chat_len) |i| {
            const e = &ch.chat_log[(ch.chat_head + i) % chat_history_len];
            if (e.id == id) return e;
        }
        for (0..s.dms_len) |i| {
            const e = &s.dms[(s.dms_head + i) % s.dms.len];
            if (e.id == id and (e.from == cn.id or e.to == cn.id)) return e;
        }
        return null;
    }

    /// O autor muda a própria mensagem (o texto e o cartão; a imagem fica):
    /// um bot atualizando o "tocando agora", por exemplo. Mutex travado.
    fn editChat(s: *Server, cn: *Conn, id: u32, text: []const u8, embed: ?[]const u8) !void {
        const e = s.visibleEntry(cn, id) orelse return;
        if (e.from != cn.id) return; // só o autor
        if (text.len == 0 and embed == null and e.img == null and !e.img_expired) return;
        const owned = try gpa.dupe(u8, text[0..@min(text.len, 4000)]);
        const new_embed: ?[]u8 = if (embed) |em| gpa.dupe(u8, em) catch {
            gpa.free(owned);
            return error.OutOfMemory;
        } else null;
        gpa.free(e.text);
        e.text = owned;
        if (e.embed) |old| gpa.free(old);
        e.embed = new_embed;
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.chat_edit);
        try b.u32_(e.id);
        try b.str(e.text);
        const em = e.embed orelse &.{};
        try b.u32_(@intCast(em.len));
        try b.bytes(em);
        const m = try b.finish();
        defer m.release();
        if (e.to != 0) {
            for (s.conns.items) |o| if (o.id == e.from or o.id == e.to) o.queue.push(m);
        } else for (s.conns.items) |o| if (o.chan == cn.chan) o.queue.push(m);
    }

    /// Clique num botão de cartão: vai só pro autor da mensagem (um bot, quase
    /// sempre), com quem clicou e, se ele for bot, onde quem clicou está.
    fn embedAction(s: *Server, cn: *Conn, id: u32, button: u8) !void {
        if (button >= proto.embed_max_buttons) return;
        const e = s.visibleEntry(cn, id) orelse return;
        if (e.embed == null or e.from == cn.id) return;
        const author = for (s.conns.items) |o| {
            if (o.id == e.from and o.authed) break o;
        } else return; // quem mandou já saiu
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.embed_action);
        try b.u32_(id);
        try b.u8_(button);
        try b.u32_(cn.id);
        try b.str(cn.nameSlice());
        if (author.bot) try writeWhere(&b, cn);
        author.queue.pushOwned(try b.finish());
    }

    /// Onde a pessoa está: str canal de texto, str call ("" = fora de call).
    fn writeWhere(b: *proto.Builder, cn: *const Conn) !void {
        try b.str(if (cn.authed) cn.chan.nameSlice() else "");
        try b.str(if (cn.call) |cc| cc.nameSlice() else "");
    }

    const Image = struct { w: u16, h: u16, data: []const u8 };

    /// Aviso do sistema no chat de um canal (guarda no histórico dele e manda
    /// pra quem está nele). Chamado com o mutex travado.
    fn broadcastChat(s: *Server, ch: *Chan, text: []const u8) !void {
        return s.postChat(ch, 0, "", text, null, null);
    }

    /// Uma mensagem nova (o id é o próximo). Mutex travado.
    fn newEntry(s: *Server, from: u32, name: []const u8, text: []const u8, img: ?Image, quote: ?*const ChatEntry) !ChatEntry {
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
        if (quote) |q| e.quote(q);
        return e;
    }

    /// A mensagem citada numa resposta: do histórico do canal de quem
    /// responde, ou (`dm`) das privadas em que ele está. null = velha demais.
    fn findQuote(s: *Server, cn: *Conn, id: u32, dm: bool) ?*const ChatEntry {
        if (id == 0) return null;
        const ch = cn.chan;
        for (0..ch.chat_len) |i| {
            const e = &ch.chat_log[(ch.chat_head + i) % chat_history_len];
            if (e.id == id and e.from != 0) return e;
        }
        // numa privada dá pra citar a conversa privada (e o canal); em público, só o canal
        if (!dm) return null;
        for (0..s.dms_len) |i| {
            const e = &s.dms[(s.dms_head + i) % s.dms.len];
            if (e.id == id and (e.from == cn.id or e.to == cn.id)) return e;
        }
        return null;
    }

    fn serverFeatures(s: *Server) u8 {
        return proto.srv_dm | (if (s.files.ok) proto.srv_files else 0);
    }

    // ------------------------------------------------------------ arquivos

    fn pushFileReady(cn: *Conn, local: u32, id: u32, why: []const u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.file_ready);
        try b.u32_(local);
        try b.u32_(id);
        try b.str(why);
        cn.queue.pushOwned(try b.finish());
    }

    /// Alguém quer mandar um arquivo: reserva o lugar (ou diz por que não).
    fn onFilePut(s: *Server, cn: *Conn, r: *proto.Reader) !void {
        const local = try r.u32_();
        const raw_name = try r.str();
        const size = try r.u64_();
        const to = r.u32_() catch 0;
        const reply_to = r.u32_() catch 0;
        var nb: [proto.file_name_max]u8 = undefined;
        const name = files_mod.cleanName(raw_name, &nb);
        s.mutex.lock();
        defer s.mutex.unlock();
        var mine: usize = 0;
        for (s.files.items.items) |e| {
            if (e.from == cn.id and !e.complete) mine += 1;
        }
        if (mine >= 3) return pushFileReady(cn, local, 0, "Já tem 3 arquivos seus subindo: espera um terminar.");
        if (to != 0) {
            const target = for (s.conns.items) |o| {
                if (o.id == to and o.authed) break o;
            } else return pushFileReady(cn, local, 0, "Essa pessoa não está mais na sala.");
            if (target.features & proto.feat_dm == 0) return pushFileReady(cn, local, 0, "Essa pessoa usa uma versão do telinha que não recebe mensagem privada.");
        }
        const e = s.files.create(name, size, cn.id, cn.nameSlice(), to, cn.chan.nameSlice(), reply_to) catch |err| return pushFileReady(cn, local, 0, switch (err) {
            error.TooBig => "Arquivo grande demais (até 256 MB).",
            error.Full => "O servidor está cheio de arquivos agora; tenta daqui a pouco.",
            error.NoStorage => "Esse servidor não guarda arquivos.",
            else => "Não deu pra receber o arquivo.",
        });
        s.log("{s} mandando o arquivo {s} ({d} KB)", .{ cn.nameSlice(), e.nameSlice(), size / 1024 });
        try pushFileReady(cn, local, e.id, "");
    }

    /// Um pedaço do arquivo subindo: guarda (cifrado), confirma (o ritmo de
    /// quem manda vem dessas confirmações) e, completo, aparece no chat.
    fn onFileData(s: *Server, cn: *Conn, r: *proto.Reader) !void {
        const id = try r.u32_();
        const off = try r.u64_();
        const bytes = r.rest();
        if (bytes.len == 0 or bytes.len > 64 * 1024) return error.BadMessage;
        s.mutex.lock();
        defer s.mutex.unlock();
        const e = s.files.find(id) orelse return; // cancelado ou expirou
        if (e.from != cn.id) return error.BadMessage;
        const got = s.files.write(e, off, bytes) catch {
            s.files.remove(id);
            return pushNotice(cn, proto.notice_dm, "O servidor não conseguiu guardar o arquivo.", 0);
        };
        const m = try proto.Msg.alloc(.file_ack, 12);
        std.mem.writeInt(u32, m.payload()[0..4], id, .little);
        std.mem.writeInt(u64, m.payload()[4..12], got, .little);
        cn.queue.pushOwned(m);
        if (e.complete) try s.announceFile(cn, e);
    }

    /// O arquivo chegou inteiro: vira uma mensagem no chat (do canal, ou privada).
    fn announceFile(s: *Server, cn: *Conn, f: *files_mod.Entry) !void {
        var tb: [proto.file_name_max + 40]u8 = undefined;
        var sb: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&tb, "\u{1F4CE} {s} ({s})", .{ f.nameSlice(), humanSize(f.size, &sb) }) catch f.nameSlice();
        const quote = s.findQuote(cn, f.reply_to, f.to != 0);
        var e = try s.newEntry(cn.id, cn.nameSlice(), text, null, quote);
        e.file_id = f.id;
        copyInto(&e.file_name, &e.file_name_len, f.nameSlice());
        e.file_size = f.size;
        if (f.to != 0) {
            const target = for (s.conns.items) |o| {
                if (o.id == f.to) break o;
            } else {
                e.free();
                s.files.remove(f.id);
                return pushNotice(cn, proto.notice_dm, "Essa pessoa não está mais na sala.", 0);
            };
            return s.deliverDm(cn, target, e);
        }
        // no canal onde começou a subir (se ainda existir), senão no de agora
        const ch = s.findChan(f.chanSlice()) orelse cn.chan;
        copyInto(&f.chan, &f.chan_len, ch.nameSlice());
        try s.postEntry(ch, e);
    }

    /// Alguém baixando: manda o pedaço pedido (quem baixa controla o ritmo).
    fn onFileGet(s: *Server, cn: *Conn, r: *proto.Reader) !void {
        const id = try r.u32_();
        const off = try r.u64_();
        const len = try r.u32_();
        if (len == 0 or len > 64 * 1024 or off % 64 != 0) return error.BadMessage;
        s.mutex.lock();
        defer s.mutex.unlock();
        const e = s.files.find(id) orelse return pushNotice(cn, proto.notice_file_gone, "Esse arquivo não está mais na sala (expira em 2 h).", 0);
        // privada: só os dois; do canal: só quem está nele
        const allowed = if (e.to != 0) cn.id == e.from or cn.id == e.to else std.mem.eql(u8, cn.chan.nameSlice(), e.chanSlice());
        if (!allowed or !e.complete or off >= e.size) return;
        const n: usize = @intCast(@min(len, e.size - off));
        const m = try proto.Msg.alloc(.file_data, 12 + n);
        errdefer m.release();
        std.mem.writeInt(u32, m.payload()[0..4], id, .little);
        std.mem.writeInt(u64, m.payload()[4..12], off, .little);
        _ = s.files.read(e, off, m.payload()[12..][0..n]) catch {
            m.release();
            return;
        };
        cn.queue.pushOwned(m);
    }

    /// Mensagem privada de `cn` pra `to`: só os dois recebem. Mutex travado.
    fn sendDm(s: *Server, cn: *Conn, to: u32, reply_to: u32, text: []const u8, img: ?Image, embed: ?[]const u8) !void {
        const target = for (s.conns.items) |o| {
            if (o.id == to and o.authed) break o;
        } else return pushNotice(cn, proto.notice_dm, "Essa pessoa não está mais na sala.", 0);
        if (target == cn) return;
        if (target.features & proto.feat_dm == 0)
            return pushNotice(cn, proto.notice_dm, "Essa pessoa usa uma versão do telinha que não recebe mensagem privada.", 0);
        var e = try s.newEntry(cn.id, cn.nameSlice(), text, img, s.findQuote(cn, reply_to, true));
        if (embed) |em| e.embed = gpa.dupe(u8, em) catch {
            e.free();
            return error.OutOfMemory;
        };
        return s.deliverDm(cn, target, e);
    }

    /// Manda a privada pronta (`e`) pros dois e guarda no anel. Mutex travado.
    fn deliverDm(s: *Server, cn: *Conn, target: *Conn, entry: ChatEntry) !void {
        var e = entry;
        e.to = target.id;
        copyInto(&e.to_name, &e.to_name_len, target.nameSlice());
        const m = chatMsg(&e, 0) catch |err| {
            e.free();
            return err;
        };
        defer m.release();
        // bot recebe também onde está quem mandou (pra ir atrás)
        const mb: ?*proto.Msg = if (target.bot) chatMsgFor(&e, 0, cn) catch null else null;
        defer if (mb) |x| x.release();
        // guarda (pra conferir citações), sem a imagem: ela já foi
        if (e.img) |im| {
            gpa.free(im);
            e.img = null;
            e.img_expired = true;
        }
        if (s.dms_len == s.dms.len) {
            s.dms[s.dms_head].free();
            s.dms[s.dms_head] = e;
            s.dms_head = (s.dms_head + 1) % s.dms.len;
        } else {
            s.dms[(s.dms_head + s.dms_len) % s.dms.len] = e;
            s.dms_len += 1;
        }
        cn.queue.push(m);
        target.queue.push(mb orelse m);
    }

    /// Mensagem no chat de um canal (histórico + quem está nele). Mutex travado.
    fn postChat(s: *Server, ch: *Chan, from: u32, name: []const u8, text: []const u8, img: ?Image, quote: ?*const ChatEntry) !void {
        return s.postEntry(ch, try s.newEntry(from, name, text, img, quote));
    }

    /// Põe a mensagem pronta (`e`) no histórico do canal e manda pra quem está nele.
    fn postEntry(s: *Server, ch: *Chan, entry: ChatEntry) !void {
        return s.postEntryFrom(ch, entry, null);
    }

    /// O mesmo, dizendo quem mandou: os bots do canal recebem onde ele está.
    fn postEntryFrom(s: *Server, ch: *Chan, entry: ChatEntry, sender: ?*const Conn) !void {
        var e = entry;
        const m = chatMsg(&e, 0) catch |err| {
            e.free();
            return err;
        };
        defer m.release();
        var mb: ?*proto.Msg = null; // a versão dos bots (só se tiver bot no canal)
        defer if (mb) |x| x.release();
        if (sender) |sc| for (s.conns.items) |o| if (o.chan == ch and o.bot) {
            mb = chatMsgFor(&e, 0, sc) catch null;
            break;
        };
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
        for (s.conns.items) |o| if (o.chan == ch) o.queue.push(if (o.bot) (mb orelse m) else m);
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

    /// Manda a lista de membros pra cada um: quem está no canal de texto dele
    /// e quem está na call dele (bandeiras no byte da rota), ela inclusive.
    /// Uma mensagem por par (canal, call). Chamado com o mutex travado.
    fn broadcastMembers(s: *Server) !void {
        s.updateCodecs();
        var done: [64]struct { ?*Chan, ?*Chan } = undefined;
        var n_done: usize = 0;
        for (s.conns.items) |cn| {
            const key = .{ @as(?*Chan, cn.chan), cn.call };
            const seen = for (done[0..n_done]) |d| {
                if (d[0] == key[0] and d[1] == key[1]) break true;
            } else false;
            if (seen) continue;
            if (n_done < done.len) {
                done[n_done] = key;
                n_done += 1;
            }
            try s.broadcastMembersFor(cn.chan, cn.call);
        }
        s.broadcastChannels();
    }

    fn broadcastMembersFor(s: *Server, ch: *Chan, call: ?*Chan) !void {
        const shown = struct {
            fn f(o: *const Conn, c0: *Chan, c1: ?*Chan) bool {
                return o.chan == c0 or (c1 != null and o.call == c1);
            }
        }.f;
        var n: u16 = 0;
        for (s.conns.items) |o| {
            if (shown(o, ch, call)) n += 1;
        }
        if (n == 0) return;
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.members);
        try b.u8_(if (s.locked) proto.room_locked else 0);
        try b.u16_(n);
        for (s.conns.items) |o| {
            if (!shown(o, ch, call)) continue;
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
            var rt: u8 = o.route;
            if (o.owner) rt |= 0x80;
            if (o.chan == ch) rt |= proto.member_in_chan;
            if (call != null and o.call == call) rt |= proto.member_in_call;
            try b.u8_(rt);
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
        for (s.conns.items) |o| if (shown(o, ch, call)) try b.str(std.mem.sliceTo(&o.app_version, 0));
        // e o que cada um é (bot ou gente)
        for (s.conns.items) |o| if (shown(o, ch, call)) try b.u8_(if (o.bot) proto.member_kind_bot else 0);
        const m = try b.finish();
        defer m.release();
        for (s.conns.items) |o| if (o.chan == ch and o.call == call) o.queue.push(m);
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
        if (!s.new_channels) return false;
        if (s.chans.items.len >= proto.max_channels) s.evictEmptyChan();
        return s.chans.items.len < proto.max_channels;
    }

    /// Sem vaga pra canal novo: o que está vazio há mais tempo (não fixo) sai.
    fn evictEmptyChan(s: *Server) void {
        var oldest: ?usize = null;
        for (s.chans.items, 0..) |ch, i| {
            if (ch.fixed or ch.empty_since_ms == 0) continue;
            if (oldest == null or ch.empty_since_ms < s.chans.items[oldest.?].empty_since_ms) oldest = i;
        }
        const i = oldest orelse return;
        const ch = s.chans.orderedRemove(i);
        s.log("canal #{s} vazio saiu pra dar lugar a um novo", .{ch.nameSlice()});
        ch.destroy();
        s.saveState();
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

    /// Canal criado por alguém que ficou vazio (ninguém no chat nem na call)
    /// continua na lista (e no arquivo de estado) por proto.chan_keep_empty_ms;
    /// depois some, com o chat dele (expireChans).
    fn dropIfEmpty(s: *Server, ch: *Chan) void {
        if (ch.fixed or ch.empty_since_ms != 0) return;
        for (s.conns.items) |o| if (o.chan == ch or o.call == ch) return;
        ch.empty_since_ms = sync.nowMs();
        s.log("canal #{s} vazio: fica mais {d} dias", .{ ch.nameSlice(), proto.chan_keep_empty_ms / (24 * 3600 * 1000) });
    }

    /// Canais vazios há tempo demais somem; os que voltaram a ter gente zeram a conta.
    fn expireChans(s: *Server, now_ms: u64) void {
        var changed = false;
        var i: usize = 0;
        while (i < s.chans.items.len) {
            const ch = s.chans.items[i];
            const used = for (s.conns.items) |o| {
                if (o.chan == ch or o.call == ch) break true;
            } else false;
            if (used or ch.fixed) {
                ch.empty_since_ms = 0;
            } else if (ch.empty_since_ms == 0) {
                ch.empty_since_ms = now_ms;
            } else if (now_ms -| ch.empty_since_ms > proto.chan_keep_empty_ms) {
                _ = s.chans.orderedRemove(i);
                s.log("canal #{s} vazio há {d} dias: fechado", .{ ch.nameSlice(), proto.chan_keep_empty_ms / (24 * 3600 * 1000) });
                ch.destroy();
                changed = true;
                continue;
            }
            i += 1;
        }
        if (changed) {
            s.saveState();
            s.broadcastChannels();
        }
    }

    /// Mensagem `channel` pra `cn`: em que canal ela está + a lista.
    fn pushChannels(s: *Server, cn: *Conn) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        s.buildChannels(&b, cn.chan, cn.call, cn) catch return;
        cn.queue.pushOwned(b.finish() catch return);
    }

    /// O canal aparece na lista de `viewer`? (invisível: só pra quem está
    /// nele e pra quem manda nele)
    fn listed(ch: *const Chan, viewer: ?*const Conn) bool {
        if (!ch.hidden) return true;
        const v = viewer orelse return true;
        return v.chan == ch or v.call == ch or ch.isBoss(v);
    }

    /// str canal atual, u8 n, n × (str nome, u16 no chat, u8 flags), e no fim
    /// (app que só lê o começo ignora): n × u16 na call, n × str tópico, str call atual.
    fn buildChannels(s: *Server, b: *proto.Builder, current: *Chan, call: ?*Chan, viewer: ?*const Conn) !void {
        try b.begin(.channel);
        try b.str(current.nameSlice());
        var n: u8 = 0;
        for (s.chans.items) |ch| n += @intFromBool(listed(ch, viewer));
        try b.u8_(n);
        for (s.chans.items) |ch| {
            if (!listed(ch, viewer)) continue;
            var people: u16 = 0;
            var live = false;
            for (s.conns.items) |o| {
                if (o.chan == ch) people += 1;
                if (o.call == ch and (o.streams[0].on or o.streams[1].on)) live = true;
            }
            var flags: u8 = 0;
            if (live) flags |= proto.chan_live;
            if (ch.fixed) flags |= proto.chan_fixed;
            if (ch.has_password) flags |= proto.chan_password;
            if (ch.locked) flags |= proto.chan_locked;
            if (ch.hidden) flags |= proto.chan_hidden;
            if (viewer) |v| if (ch.creator_key != 0 and ch.creator_key == v.client_key) {
                flags |= proto.chan_mine;
            };
            try b.str(ch.nameSlice());
            try b.u16_(people);
            try b.u8_(flags);
        }
        for (s.chans.items) |ch| {
            if (!listed(ch, viewer)) continue;
            var in_call: u16 = 0;
            for (s.conns.items) |o| {
                if (o.call == ch) in_call += 1;
            }
            try b.u16_(in_call);
        }
        for (s.chans.items) |ch| if (listed(ch, viewer)) try b.str(ch.topicSlice());
        try b.str(if (call) |cc| cc.nameSlice() else "");
    }

    /// A lista de canais (gente, call, ao vivo, tópico...) mudou: manda pra
    /// todo mundo. Compara com a última mandada (montada sempre com o mesmo
    /// "atual", o padrão e sem call: igual = nada mudou).
    fn broadcastChannels(s: *Server) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        s.buildChannels(&b, s.chans.items[0], null, null) catch return;
        const m = b.finish() catch return;
        defer m.release();
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

    /// O canal `raw` (normalizado; cria se não existir e der), conferindo
    /// trava e senha. null = não pode (o aviso já foi). Mutex travado.
    fn reachChan(s: *Server, cn: *Conn, raw: []const u8, pw: []const u8) !?*Chan {
        var nb: [proto.channel_name_max]u8 = undefined;
        const name = normalizeChannel(raw, &nb) orelse {
            try pushNotice(cn, proto.notice_channel, "Nome de canal inválido: use letras, números, - ou _ (até 24).", 0);
            return null;
        };
        const ch = s.findChan(name) orelse {
            if (!s.new_channels) {
                try pushNotice(cn, proto.notice_channel, "Esse servidor não deixa criar canal novo.", 0);
                return null;
            }
            if (!s.canCreateChan()) {
                try pushNotice(cn, proto.notice_channel, "O servidor já tem canais demais.", 0);
                return null;
            }
            const nc = try s.addChan(name, false);
            nc.creator_key = cn.client_key;
            s.saveState();
            return nc;
        };
        if (ch.isBanned(cn.client_key) and !cn.admin) {
            try pushNotice(cn, proto.notice_channel, "Você foi tirado desse canal.", 0);
            return null;
        }
        if (!ch.isBoss(cn)) {
            if (ch.locked) {
                try pushNotice(cn, proto.notice_channel, "Esse canal está trancado: só admin entra.", 0);
                return null;
            }
            if (!ch.passwordOk(pw)) {
                try pushNotice(cn, proto.notice_channel, if (pw.len == 0) "Esse canal tem senha." else "Senha do canal errada.", proto.notice_channel_needs_password);
                return null;
            }
        }
        return ch;
    }

    /// No máximo uma troca (que deu certo) a cada 800 ms.
    fn switchTooFast(cn: *Conn) !bool {
        if (sync.nowMs() -| cn.chan_switch_ms < 800) {
            try pushNotice(cn, proto.notice_channel, "Calma: trocando de canal rápido demais.", 0);
            return true;
        }
        return false;
    }

    /// Troca o canal de texto de `cn`. App que não separa call de canal leva
    /// a call junto (como antes). Chamado com o mutex travado.
    fn switchChannel(s: *Server, cn: *Conn, raw: []const u8, pw: []const u8) !void {
        var nb: [proto.channel_name_max]u8 = undefined;
        if (normalizeChannel(raw, &nb)) |nm| if (std.mem.eql(u8, nm, cn.chan.nameSlice())) return s.pushChannels(cn);
        if (try switchTooFast(cn)) return s.pushChannels(cn);
        const target = (try s.reachChan(cn, raw, pw)) orelse return s.pushChannels(cn);
        cn.chan_switch_ms = sync.nowMs();
        // app antigo: a call vai junto (primeiro ela, pra lista já sair sem o canal que esvaziou)
        if (!cn.calls_aware) s.moveCall(cn, target);
        try s.moveText(cn, target);
        try s.broadcastMembers();
    }

    /// Entra (ou sai: nome vazio) na call de um canal. Mutex travado.
    fn joinCall(s: *Server, cn: *Conn, raw: []const u8, pw: []const u8) !void {
        if (std.mem.trim(u8, raw, " #").len == 0) {
            if (cn.call == null) return s.pushChannels(cn);
            s.moveCall(cn, null);
            try s.broadcastMembers();
            return;
        }
        var nb: [proto.channel_name_max]u8 = undefined;
        if (normalizeChannel(raw, &nb)) |nm| if (cn.call) |cc| if (std.mem.eql(u8, nm, cc.nameSlice())) return s.pushChannels(cn);
        if (try switchTooFast(cn)) return s.pushChannels(cn);
        const target = (try s.reachChan(cn, raw, pw)) orelse return s.pushChannels(cn);
        cn.chan_switch_ms = sync.nowMs();
        s.moveCall(cn, target);
        try s.broadcastMembers();
    }

    /// O chat de `cn` passa a ser o de `target` (o app limpa e recebe o histórico).
    fn moveText(s: *Server, cn: *Conn, target: *Chan) !void {
        const old = cn.chan;
        if (old == target) return;
        var tmp: [120]u8 = undefined;
        try s.broadcastChat(old, std.fmt.bufPrint(&tmp, "{s} foi pro #{s}", .{ cn.nameSlice(), target.nameSlice() }) catch "");
        cn.chan = target;
        s.log("{s}: #{s} → #{s}", .{ cn.nameSlice(), old.nameSlice(), target.nameSlice() });
        s.dropIfEmpty(old); // (antes da lista: ela já sai sem o canal que esvaziou)
        // primeiro "você está no canal X" (o app limpa o chat), depois o histórico dele
        s.pushChannels(cn);
        try s.pushHistory(cn);
        try s.broadcastChat(target, std.fmt.bufPrint(&tmp, "{s} entrou no #{s}", .{ cn.nameSlice(), target.nameSlice() }) catch "");
    }

    /// Troca a call de `cn` (null = sai). As transmissões dela vão junto (o
    /// app anuncia de novo); quem assistia na call velha para de receber, e
    /// ela para de assistir quem ficou lá. Mutex travado.
    fn moveCall(s: *Server, cn: *Conn, target: ?*Chan) void {
        const old = cn.call;
        if (old == target) return;
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
        cn.call = target;
        s.log("{s}: call {s} → {s}", .{ cn.nameSlice(), if (old) |o| o.nameSlice() else "-", if (target) |t| t.nameSlice() else "-" });
        if (old) |o| s.dropIfEmpty(o);
        s.pushChannels(cn);
    }

    /// Admin mexe num canal: fixar, trancar, senha, tópico, levar alguém.
    /// Chamado com o mutex travado.
    fn chanAdmin(s: *Server, cn: *Conn, action: u8, raw: []const u8, value: []const u8, target_id: u32) !void {
        var nb: [proto.channel_name_max]u8 = undefined;
        const name = normalizeChannel(raw, &nb) orelse return;
        var tmp: [200]u8 = undefined;
        // fixar e levar alguém: só admin da sala; o resto, quem criou o canal também
        if (!cn.admin) {
            const ch = s.findChan(name) orelse return;
            if (action == proto.chan_act_fix or action == proto.chan_act_move or !ch.isBoss(cn)) return;
        }
        if (action == proto.chan_act_ban) {
            const ch = s.findChan(name) orelse return;
            const t = s.findConn(target_id) orelse return;
            if (t == cn or t.owner or (t.admin and !cn.owner)) return;
            ch.ban(t.client_key);
            if (t.chan == ch) try s.moveText(t, s.chans.items[0]);
            if (t.call == ch) s.moveCall(t, null);
            try pushNotice(t, proto.notice_moved, std.fmt.bufPrint(&tmp, "{s} te tirou do #{s}.", .{ cn.nameSlice(), ch.nameSlice() }) catch "", 0);
            try s.broadcastChat(ch, std.fmt.bufPrint(&tmp, "{s} tirou do canal: {s}", .{ cn.nameSlice(), t.nameSlice() }) catch "");
            s.log("{s} tirou {s} do #{s}", .{ cn.nameSlice(), t.nameSlice(), ch.nameSlice() });
            try s.broadcastMembers();
            s.broadcastChannels();
            return;
        }
        if (action == proto.chan_act_move) {
            const t = s.findConn(target_id) orelse return;
            if (t.owner and !cn.owner) return;
            const ch = s.findChan(name) orelse blk: {
                if (s.chans.items.len >= proto.max_channels) return;
                break :blk try s.addChan(name, false);
            };
            try s.moveText(t, ch);
            s.moveCall(t, ch);
            try pushNotice(t, proto.notice_moved, std.fmt.bufPrint(&tmp, "{s} te levou pro #{s}.", .{ cn.nameSlice(), ch.nameSlice() }) catch "", 0);
            s.log("{s} levou {s} pro #{s}", .{ cn.nameSlice(), t.nameSlice(), ch.nameSlice() });
            try s.broadcastMembers();
            return;
        }
        const ch = s.findChan(name) orelse return;
        const on = std.mem.eql(u8, value, "1");
        const said: []const u8 = switch (action) {
            proto.chan_act_fix => blk: {
                if (!on and ch == s.chans.items[0]) return; // o padrão fica sempre
                ch.fixed = on;
                break :blk std.fmt.bufPrint(&tmp, "{s} {s} o canal", .{ cn.nameSlice(), if (on) "fixou" else "soltou" }) catch "";
            },
            proto.chan_act_hide => blk: {
                if (ch == s.chans.items[0]) return; // o padrão sempre aparece
                ch.hidden = on;
                break :blk std.fmt.bufPrint(&tmp, "{s} {s} o canal", .{ cn.nameSlice(), if (on) "deixou invisível" else "voltou a mostrar" }) catch "";
            },
            proto.chan_act_lock => blk: {
                ch.locked = on;
                break :blk std.fmt.bufPrint(&tmp, "{s} {s} o canal", .{ cn.nameSlice(), if (on) "trancou" else "destrancou" }) catch "";
            },
            proto.chan_act_password => blk: {
                ch.has_password = value.len > 0;
                if (ch.has_password) ch.password_hash = Chan.hashPassword(value);
                break :blk std.fmt.bufPrint(&tmp, "{s} {s} a senha do canal", .{ cn.nameSlice(), if (ch.has_password) "trocou" else "tirou" }) catch "";
            },
            proto.chan_act_topic => blk: {
                var tv = std.mem.trim(u8, value, " \t\r\n");
                // não corta letra no meio
                if (tv.len > proto.chan_topic_max) {
                    var cut: usize = proto.chan_topic_max;
                    while (cut > 0 and tv[cut] & 0xC0 == 0x80) cut -= 1;
                    tv = tv[0..cut];
                }
                for (tv, 0..) |chr, i| ch.topic[i] = if (chr == '\n' or chr == '\r') ' ' else chr;
                ch.topic_len = tv.len;
                break :blk std.fmt.bufPrint(&tmp, "{s} {s} o tópico", .{ cn.nameSlice(), if (tv.len > 0) "mudou" else "tirou" }) catch "";
            },
            else => return,
        };
        try s.broadcastChat(ch, said);
        s.log("#{s}: {s}", .{ ch.nameSlice(), said });
        s.saveState();
        s.dropIfEmpty(ch); // soltou um canal vazio: começa a contar os dias
        s.broadcastChannels();
    }

    // ------------------------------------------- o que sobrevive a reiniciar

    /// Grava o estado (canais fixos, banidos, silenciados, sem pincel) num
    /// arquivo de texto, trocando o velho de uma vez (rename). Mutex travado.
    fn saveState(s: *Server) void {
        if (s.state_path_len == 0) return;
        var pb: [420]u8 = undefined;
        const tmp_path = std.fmt.bufPrintZ(&pb, "{s}.novo", .{s.state_path[0..s.state_path_len]}) catch return;
        const f = cio.fopen(tmp_path.ptr, "wb") orelse {
            s.log("não consegui gravar {s}", .{tmp_path});
            return;
        };
        var lb: [600]u8 = undefined;
        const put = struct {
            fn w(file: *cio.FILE, line: []const u8) void {
                _ = cio.fwrite(line.ptr, 1, line.len, file);
            }
        }.w;
        put(f, "# telinha-server: estado (canais fixos, banidos, silenciados). Gerado sozinho.\n");
        for (s.chans.items) |ch| {
            var hex: [64]u8 = undefined;
            const pw = if (ch.has_password) std.fmt.bufPrint(&hex, "{x}", .{&ch.password_hash}) catch "-" else "-";
            // fixo: "canal" (o formato de sempre); criado por alguém: "criado" (some vazio depois de dias)
            put(f, std.fmt.bufPrint(&lb, "{s}\t{s}\t{d}\t{s}\t{s}\n", .{ if (ch.fixed) "canal" else "criado", ch.nameSlice(), @intFromBool(ch.locked), pw, ch.topicSlice() }) catch continue);
            if (ch.creator_key != 0 or ch.hidden)
                put(f, std.fmt.bufPrint(&lb, "dono\t{s}\t{x}\t{d}\n", .{ ch.nameSlice(), ch.creator_key, @intFromBool(ch.hidden) }) catch continue);
        }
        for (s.bans.items) |*b| put(f, std.fmt.bufPrint(&lb, "ban\t{x}\t{s}\t{s}\n", .{ b.key, b.ip[0..b.ip_len], b.name[0..b.name_len] }) catch continue);
        for (s.muted_keys.items) |k| put(f, std.fmt.bufPrint(&lb, "mudo\t{x}\n", .{k}) catch continue);
        for (s.no_draw_keys.items) |k| put(f, std.fmt.bufPrint(&lb, "sempincel\t{x}\n", .{k}) catch continue);
        _ = cio.fclose(f);
        var pb2: [420]u8 = undefined;
        const final = std.fmt.bufPrintZ(&pb2, "{s}", .{s.state_path[0..s.state_path_len]}) catch return;
        _ = cio.rename(tmp_path.ptr, final.ptr);
    }

    /// Lê o estado gravado (no começo, antes de aceitar conexões).
    fn loadState(s: *Server) void {
        if (s.state_path_len == 0) return;
        var pb: [420]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pb, "{s}", .{s.state_path[0..s.state_path_len]}) catch return;
        const f = cio.fopen(path.ptr, "rb") orelse return;
        defer _ = cio.fclose(f);
        var buf: [128 * 1024]u8 = undefined;
        const n = cio.fread(&buf, 1, buf.len, f);
        var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var it = std.mem.splitScalar(u8, line, '\t');
            const kind = it.next() orelse continue;
            if (std.mem.eql(u8, kind, "canal") or std.mem.eql(u8, kind, "criado")) {
                const fixed = kind[1] == 'a';
                var nb: [proto.channel_name_max]u8 = undefined;
                const name = normalizeChannel(it.next() orelse continue, &nb) orelse continue;
                const ch = s.findChan(name) orelse (if (s.chans.items.len < proto.max_channels) (s.addChan(name, fixed) catch continue) else continue);
                ch.fixed = ch.fixed or fixed;
                if (!ch.fixed) ch.empty_since_ms = sync.nowMs(); // começa vazio: conta os dias de novo
                ch.locked = std.mem.eql(u8, it.next() orelse "0", "1");
                const pw = it.next() orelse "-";
                if (pw.len == 64) {
                    if (std.fmt.hexToBytes(&ch.password_hash, pw)) |_| {
                        ch.has_password = true;
                    } else |_| {}
                }
                const topic = it.rest();
                ch.topic_len = @min(topic.len, ch.topic.len);
                @memcpy(ch.topic[0..ch.topic_len], topic[0..ch.topic_len]);
            } else if (std.mem.eql(u8, kind, "dono")) {
                var nb: [proto.channel_name_max]u8 = undefined;
                const name = normalizeChannel(it.next() orelse continue, &nb) orelse continue;
                const ch = s.findChan(name) orelse continue;
                ch.creator_key = std.fmt.parseInt(u64, it.next() orelse "0", 16) catch 0;
                ch.hidden = std.mem.eql(u8, it.next() orelse "0", "1");
            } else if (std.mem.eql(u8, kind, "ban")) {
                var b: Ban = .{ .key = std.fmt.parseInt(u64, it.next() orelse continue, 16) catch 0 };
                copyInto(&b.ip, &b.ip_len, it.next() orelse "");
                copyInto(&b.name, &b.name_len, it.next() orelse "");
                s.bans.append(gpa, b) catch {};
            } else if (std.mem.eql(u8, kind, "mudo")) {
                s.muted_keys.append(gpa, std.fmt.parseInt(u64, it.next() orelse continue, 16) catch continue) catch {};
            } else if (std.mem.eql(u8, kind, "sempincel")) {
                s.no_draw_keys.append(gpa, std.fmt.parseInt(u64, it.next() orelse continue, 16) catch continue) catch {};
            } else continue;
            count += 1;
        }
        s.log("estado: {d} itens lidos de {s}", .{ count, path });
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
            if (o == cn or o.deaf or !o.authed or cn.call == null or o.call != cn.call) continue;
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
            if (o == cn or cn.call == null or o.call != cn.call) continue;
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
            if (o == cn or cn.call == null or o.call != cn.call) continue;
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

/// Pasta temporária pros arquivos da sala do app: TMPDIR/TEMP + telinha-arquivos-<pid>.
fn tempFilesDir(buf: []u8) []const u8 {
    const base = if (std.c.getenv("TEMP")) |t| std.mem.span(t) else if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    const pid: u32 = if (builtin.os.tag == .windows) GetCurrentProcessId() else @intCast(std.c.getpid());
    return std.fmt.bufPrint(buf, "{s}{s}telinha-arquivos-{d}", .{ base, if (builtin.os.tag == .windows) "\\" else "/", pid }) catch "";
}
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

/// "12,3 MB", "850 KB", "3 bytes".
pub fn humanSize(n: u64, buf: []u8) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} bytes", .{n}) catch "";
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d} KB", .{n / 1024}) catch "";
    const tenths = n * 10 / (1024 * 1024);
    return std.fmt.bufPrint(buf, "{d},{d} MB", .{ tenths / 10, tenths % 10 }) catch "";
}

/// Comparação que não diz pelo tempo onde a senha diferiu.
fn constEql(a: []const u8, b: []const u8) bool {
    var diff: u8 = @intFromBool(a.len != b.len);
    for (0..@max(a.len, b.len)) |i| {
        const x = if (i < a.len) a[i] else 0;
        const y = if (i < b.len) b[i] else 0;
        diff |= x ^ y;
    }
    return diff == 0;
}
