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
const gpa = proto.gpa;

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
const keyreq_interval_ms = 500;
const handshake_timeout_ms = 10_000;
/// Alguém guardando os últimos segundos pra clipe: um IDR a cada tanto (um
/// clipe só começa num IDR, e sem isso eles só saem quando alguém entra).
pub const clip_key_interval_ms = 20_000;
/// Mensagens que quem entra na sala recebe de histórico.
pub const chat_history_len = 50;
/// Ponteiro: no máximo isso por segundo por pessoa.
const pointer_rate = 40;
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
};

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
    udp: std.atomic.Value(?*udp.Link) = .init(null), // vídeo/som por UDP (quando o cliente abre o caminho)
    route: u8 = proto.route_unknown,
    via_tunnel: bool = false,
    ip: [16]u8 = undefined,
    ip_len: usize = 0,
    muted: bool = false, // microfone silenciado pelo admin
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
            self.waiting_key.deinit(gpa);
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
};

pub const Server = struct {
    listen_sock: net.Socket,
    udp_sock: ?net.Socket = null, // vídeo/som por UDP, na mesma porta (null = só TCP)
    port: u16,
    password: [128]u8 = undefined,
    password_len: usize = 0,
    room_name: [64]u8 = undefined,
    room_name_len: usize = 0,
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
    chat_log: [chat_history_len]ChatEntry = undefined,
    chat_len: usize = 0,
    chat_head: usize = 0,
    next_chat_id: u32 = 1,
    stopped: std.atomic.Value(bool) = .init(false),
    /// Dono (quem chamou start) + uma por thread do servidor + uma por conexão
    /// + o túnel: o último a soltar libera tudo (histórico do chat, imagens...).
    refs: std.atomic.Value(u32) = .init(1),
    // estatística
    relayed_bytes: std.atomic.Value(u64) = .init(0),

    pub fn start(opts: Options) !*Server {
        const ls = try net.listen(opts.port);
        const s = try gpa.create(Server);
        s.* = .{ .listen_sock = ls, .port = opts.port, .max_members = opts.max_members, .clip_key_ms = opts.clip_key_interval_ms, .log_fn = opts.log, .start_us = sync.nowUs() };
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        s.instance = std.mem.readInt(u64, &rnd, .little);
        copyInto(&s.password, &s.password_len, opts.password);
        copyInto(&s.room_name, &s.room_name_len, opts.room_name);
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
        for (0..s.chat_len) |i| s.chat_log[(s.chat_head + i) % chat_history_len].free();
        s.conns.deinit(gpa);
        s.bans.deinit(gpa);
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
        defer s.release();
        while (!s.stopped.load(.acquire)) {
            sync.sleepMs(250);
            s.mutex.lock();
            defer s.mutex.unlock();
            const now_ms = sync.nowMs();
            const now_us = sync.nowUs();
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

    pub fn isLocked(s: *Server) bool {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.locked;
    }

    fn writerLoop(cn: *Conn) void {
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
        try s.join(cn, name, token);
    }

    fn readerLoop(cn: *Conn) void {
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
                try s.broadcastChatImg(cn.id, cn.nameSlice(), text, img);
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
                    try s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} {s}", .{ cn.nameSlice(), what }) catch "");
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
                    if (target == cn.id or s.findConn(target) == null) return;
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
                    s.requestKey(stream, true);
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
            try s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} {s} a sala", .{ cn.nameSlice(), if (lock) "trancou" else "destrancou" }) catch "");
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
                try s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} {s} {s}", .{ cn.nameSlice(), if (ban) "baniu" else "expulsou", t.nameSlice() }) catch "");
                const reason = std.fmt.bufPrint(&tmp, "{s} {s} você da sala.", .{ cn.nameSlice(), if (ban) "baniu" else "expulsou" }) catch "Você foi removido da sala.";
                s.dismiss(t, if (ban) proto.deny_banned else proto.deny_kicked, reason);
            },
            proto.admin_mute => {
                const mute = value != 0;
                if (t.muted == mute) return;
                t.muted = mute;
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

    fn banned(s: *Server, cn: *const Conn, name: []const u8) bool {
        for (s.bans.items) |*b| {
            if (b.key != 0 and b.key == cn.client_key) return true;
            if (std.ascii.eqlIgnoreCase(b.name[0..b.name_len], name)) return true;
            if (b.ip_len > 0 and !cn.via_tunnel and std.mem.eql(u8, b.ip[0..b.ip_len], cn.ip[0..cn.ip_len])) return true;
        }
        return false;
    }

    fn join(s: *Server, cn: *Conn, raw_name: []const u8, token: []const u8) !void {
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

        // o que já foi dito na sala
        for (0..s.chat_len) |i| {
            const e = &s.chat_log[(s.chat_head + i) % chat_history_len];
            const m = try chatMsg(e, proto.chat_history);
            cn.queue.pushOwned(m);
        }

        var tmp: [96]u8 = undefined;
        try s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} entrou na sala", .{name}) catch "");
        try s.broadcastMembers();
        s.log("{s} entrou ({d} na sala, {s})", .{ name, s.conns.items.len, routeName(cn.route) });
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
        s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} saiu da sala", .{cn.nameSlice()}) catch "") catch {};
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

    /// Guarda no histórico e manda pra todo mundo. Chamado com o mutex travado.
    fn broadcastChat(s: *Server, from: u32, name: []const u8, text: []const u8) !void {
        return s.broadcastChatImg(from, name, text, null);
    }

    fn broadcastChatImg(s: *Server, from: u32, name: []const u8, text: []const u8, img: ?Image) !void {
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
        if (s.chat_len == chat_history_len) {
            s.chat_log[s.chat_head].free();
            s.chat_log[s.chat_head] = e;
            s.chat_head = (s.chat_head + 1) % chat_history_len;
        } else {
            s.chat_log[(s.chat_head + s.chat_len) % chat_history_len] = e;
            s.chat_len += 1;
        }
        // memória: as imagens mais velhas do histórico expiram
        var total: usize = 0;
        var i: usize = s.chat_len;
        while (i > 0) {
            i -= 1;
            const ent = &s.chat_log[(s.chat_head + i) % chat_history_len];
            const im = ent.img orelse continue;
            total += im.len;
            if (total > chat_img_budget) {
                gpa.free(im);
                ent.img = null;
                ent.img_expired = true;
            }
        }
        for (s.conns.items) |o| o.queue.push(m);
    }

    /// Liga/desliga uma reação numa mensagem do histórico. Mutex travado.
    fn react(s: *Server, cn: *Conn, id: u32, emoji: u8, on: bool) !void {
        const e = for (0..s.chat_len) |i| {
            const ent = &s.chat_log[(s.chat_head + i) % chat_history_len];
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
        for (s.conns.items) |o| o.queue.push(m);
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
                    continue;
                }
                const stream = proto.streamId(owner.id, @intCast(kind));
                var mask: u8 = 0xFF;
                for (s.conns.items) |o| {
                    if (contains(&o.watching, stream)) mask &= o.decode_codecs;
                }
                mask |= proto.codecs_h264;
                if (mask == ss.codecs_sent) continue;
                ss.codecs_sent = mask;
                const m = proto.Msg.alloc(.codec, 2) catch continue;
                m.payload()[0] = @intCast(kind);
                m.payload()[1] = mask;
                owner.queue.pushOwned(m);
            }
        }
    }

    fn broadcastMembers(s: *Server) !void {
        s.updateCodecs();
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.members);
        try b.u8_(if (s.locked) proto.room_locked else 0);
        try b.u16_(@intCast(s.conns.items.len));
        for (s.conns.items) |o| {
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
        for (s.conns.items) |o| try b.str(std.mem.sliceTo(&o.app_version, 0));
        const m = try b.finish();
        defer m.release();
        for (s.conns.items) |o| o.queue.push(m);
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
        for (s.conns.items) |o| {
            if (o == cn or !contains(&o.watching, stream)) continue;
            if (o.queue.queuedBytes() > max_viewer_backlog * 2) continue;
            o.queue.pushUrgent(m); // som não espera atrás de quadro
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
        if (cn.muted) return; // silenciado pelo admin
        for (s.conns.items) |o| {
            if (o == cn or o.deaf or !o.authed) continue;
            if (o.queue.queuedBytes() > max_viewer_backlog * 2) continue;
            o.queue.pushUrgent(m);
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
            if (o == cn) continue;
            if (o.id != owner and !contains(&o.watching, stream)) continue;
            o.queue.pushUrgent(m);
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
        const owner = proto.memberOf(stream);
        if (owner != cn.id and !contains(&cn.watching, stream)) return;
        const m = try proto.Msg.alloc(.draw, 4 + payload.len);
        defer m.release();
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..], payload);
        for (s.conns.items) |o| {
            if (o == cn) continue;
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
                _ = f.backoff(now_ms);
                if (thinnable) _ = f.thinOut(now_ms); // depois do IDR, só metade
                s.log("{s} atrasou {d} ms assistindo {s}: recomeçando de um IDR (próximo em {d} ms)", .{ o.nameSlice(), excess / 1000, cn.nameSlice(), f.resync_after_ms - now_ms });
                continue;
            }
            o.queue.push(m);
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
            s.log("pedindo taxa menor pra {s} ({d} de {d} espectadores com dificuldade{s})", .{ cn.nameSlice(), struggling, viewers, if (resynced) "" else ", atrasando sem escoar" });
        }
    }
};
