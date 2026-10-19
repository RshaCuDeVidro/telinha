//! Servidor da sala (relay). Roda embutido no app de quem cria a sala ou como
//! servidor dedicado (server_main.zig). Todo mundo conecta nele como cliente.
//!
//! Cada conexão tem uma thread leitora e uma escritora com fila própria.
//! Frames são encaminhados só pra quem está assistindo, sem copiar o buffer.
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
const keyreq_interval_ms = 500;
const handshake_timeout_ms = 10_000;

const Conn = struct {
    server: *Server,
    sock: net.Socket,
    channel: crypto.Channel = undefined,
    id: u32 = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    authed: bool = false,
    admin: bool = false,
    streaming: bool = false,
    audio: bool = false,
    mic: bool = false, // microfone ligado
    deaf: bool = false, // não quer ouvir a sala (não recebe voz)
    w: u16 = 0,
    h: u16 = 0,
    fps: u8 = 0,
    queue: proto.SendQueue = .{},
    watching: std.ArrayList(u32) = .empty, // ids que essa pessoa assiste
    waiting_key: std.ArrayList(u32) = .empty, // ids cujo próximo frame tem que ser IDR
    flows: std.ArrayList(Flow) = .empty, // frames a caminho, por transmissor assistido
    last_keyreq_ms: u64 = 0,
    last_slow_ms: u64 = 0,
    refs: std.atomic.Value(u32) = .init(1), // leitora (+ escritora quando existir)

    fn nameSlice(self: *const Conn) []const u8 {
        return self.name[0..self.name_len];
    }
    /// Estado do que esse espectador recebe de `from` (cria se precisar).
    fn flow(self: *Conn, from: u32) ?*Flow {
        for (self.flows.items) |*f| if (f.from == from) return f;
        self.flows.append(gpa, .{ .from = from }) catch return null;
        return &self.flows.items[self.flows.items.len - 1];
    }
    fn dropFlow(self: *Conn, from: u32) void {
        for (self.flows.items, 0..) |f, i| if (f.from == from) {
            _ = self.flows.swapRemove(i);
            return;
        };
    }
    fn release(self: *Conn) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.queue.deinit();
            self.watching.deinit(gpa);
            self.waiting_key.deinit(gpa);
            self.flows.deinit(gpa);
            net.close(self.sock);
            gpa.destroy(self);
        }
    }
};

/// O que um espectador está recebendo de um transmissor.
const Flow = struct {
    from: u32,
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

    /// Atrasado sem escoar, ou recomeçou há menos de 10 s.
    fn struggling(f: *const Flow, now_ms: u64) bool {
        return f.late or (f.last_resync_ms != 0 and now_ms - f.last_resync_ms < 10_000);
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

pub const Options = struct {
    port: u16,
    password: []const u8 = "",
    room_name: []const u8 = "telinha",
    /// Quem mandar esse token no hello vira admin (pode expulsar). Vazio = ninguém.
    admin_token: []const u8 = "",
    max_members: u32 = 32,
    /// Recebe mensagens de log (servidor dedicado imprime no terminal).
    log: ?*const fn ([]const u8) void = null,
};

pub const Server = struct {
    listen_sock: net.Socket,
    port: u16,
    password: [128]u8 = undefined,
    password_len: usize = 0,
    room_name: [64]u8 = undefined,
    room_name_len: usize = 0,
    admin_token: [64]u8 = undefined,
    admin_token_len: usize = 0,
    max_members: u32,
    log_fn: ?*const fn ([]const u8) void,
    start_us: u64,
    mutex: sync.Mutex = .{},
    conns: std.ArrayList(*Conn) = .empty,
    next_id: u32 = 1,
    stopped: std.atomic.Value(bool) = .init(false),
    // estatística
    relayed_bytes: std.atomic.Value(u64) = .init(0),

    pub fn start(opts: Options) !*Server {
        const ls = try net.listen(opts.port);
        const s = try gpa.create(Server);
        s.* = .{ .listen_sock = ls, .port = opts.port, .max_members = opts.max_members, .log_fn = opts.log, .start_us = sync.nowUs() };
        copyInto(&s.password, &s.password_len, opts.password);
        copyInto(&s.room_name, &s.room_name_len, opts.room_name);
        copyInto(&s.admin_token, &s.admin_token_len, opts.admin_token);
        try sync.spawn(acceptLoop, .{s});
        return s;
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

    /// Fecha a sala e derruba todo mundo.
    pub fn stop(s: *Server) void {
        s.stopped.store(true, .release);
        net.shutdown(s.listen_sock);
        net.close(s.listen_sock);
        s.mutex.lock();
        for (s.conns.items) |cn| {
            net.shutdown(cn.sock);
            cn.queue.close();
        }
        s.mutex.unlock();
        // o Server continua alocado: threads de conexão podem estar terminando
    }

    fn acceptLoop(s: *Server) void {
        while (!s.stopped.load(.acquire)) {
            const sock = net.accept(s.listen_sock) catch {
                if (s.stopped.load(.acquire)) return;
                sync.sleepMs(20);
                continue;
            };
            s.adopt(sock);
        }
    }

    /// Recebe uma conexão já aberta (ex.: um visitante vindo do túnel público).
    pub fn adopt(s: *Server, sock: net.Socket) void {
        if (s.stopped.load(.acquire)) {
            net.close(sock);
            return;
        }
        const cn = gpa.create(Conn) catch {
            net.close(sock);
            return;
        };
        cn.* = .{ .server = s, .sock = sock };
        sync.spawn(readerLoop, .{cn}) catch {
            net.close(sock);
            gpa.destroy(cn);
        };
    }

    /// Pro túnel: `ctx` é o *Server.
    pub fn adoptCallback(ctx: *anyopaque, sock: net.Socket) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        s.adopt(sock);
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

    fn writerLoop(cn: *Conn) void {
        cn.queue.writerLoop(cn.sock, &cn.channel);
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
        net.shutdown(cn.sock);
        cn.queue.close();
        cn.release();
    }

    fn handle(s: *Server, cn: *Conn, typ: proto.Type, payload: []const u8) !void {
        var r: proto.Reader = .{ .data = payload };
        switch (typ) {
            .chat => {
                const text = std.mem.trim(u8, try r.str(), " \t\r\n");
                if (text.len == 0) return;
                s.mutex.lock();
                defer s.mutex.unlock();
                try s.broadcastChat(cn.id, cn.nameSlice(), text);
            },
            .stream_start => {
                const w = try r.u16_();
                const h = try r.u16_();
                const fps = try r.u8_();
                const flags: u8 = r.u8_() catch 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                const was = cn.streaming;
                cn.streaming = true;
                cn.audio = flags & proto.stream_audio != 0;
                cn.w = w;
                cn.h = h;
                cn.fps = fps;
                if (!was) {
                    var tmp: [96]u8 = undefined;
                    try s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} começou a transmitir", .{cn.nameSlice()}) catch "");
                    s.log("{s} começou a transmitir ({d}x{d} @ {d} fps)", .{ cn.nameSlice(), w, h, fps });
                }
                // todo mundo que já assistia precisa de um IDR na resolução nova
                for (s.conns.items) |o| {
                    if (!contains(&o.watching, cn.id)) continue;
                    addUnique(&o.waiting_key, cn.id);
                    if (o.flow(cn.id)) |f| f.win.reset();
                }
                try s.broadcastMembers();
            },
            .stream_stop => {
                s.mutex.lock();
                defer s.mutex.unlock();
                if (cn.streaming) {
                    cn.streaming = false;
                    cn.audio = false;
                    for (s.conns.items) |o| {
                        _ = o.queue.dropFrames(cn.id);
                        o.dropFlow(cn.id);
                    }
                    s.log("{s} parou de transmitir", .{cn.nameSlice()});
                    try s.broadcastMembers();
                }
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
                const target = try r.u32_();
                const on = (try r.u8_()) != 0;
                s.mutex.lock();
                defer s.mutex.unlock();
                if (on) {
                    const changed = !contains(&cn.watching, target);
                    addUnique(&cn.watching, target);
                    addUnique(&cn.waiting_key, target);
                    _ = cn.queue.dropFrames(target);
                    cn.dropFlow(target);
                    _ = cn.flow(target);
                    s.requestKey(target, changed);
                    if (changed) try s.broadcastMembers();
                } else {
                    remove(&cn.watching, target);
                    remove(&cn.waiting_key, target);
                    _ = cn.queue.dropFrames(target);
                    cn.dropFlow(target);
                    try s.broadcastMembers();
                }
            },
            .ack => {
                const from = try r.u32_();
                const seq = try r.u32_();
                s.mutex.lock();
                defer s.mutex.unlock();
                for (cn.flows.items) |*f| if (f.from == from) f.win.acked(seq, sync.nowUs());
            },
            .keyreq => {
                // o espectador perdeu a referência (decoder atrasou ou deu erro)
                const target = try r.u32_();
                s.mutex.lock();
                defer s.mutex.unlock();
                if (!contains(&cn.watching, target)) return;
                const f = cn.flow(target) orelse return;
                f.win.dropNewest(cn.queue.dropFrames(target));
                addUnique(&cn.waiting_key, target);
                const now = sync.nowMs();
                if (now >= f.resync_after_ms) s.requestKey(target, false);
                _ = f.backoff(now);
                f.decoder_behind = true;
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
                if (!cn.admin or target == cn.id) return;
                for (s.conns.items) |o| {
                    if (o.id != target) continue;
                    s.log("{s} expulsou {s}", .{ cn.nameSlice(), o.nameSlice() });
                    var b: proto.Builder = .{};
                    defer b.deinit();
                    try b.begin(.denied);
                    try b.str("Você foi removido da sala.");
                    o.queue.pushOwned(try b.finish());
                    // dá tempo da escritora mandar o aviso antes de derrubar
                    sync.spawn(delayedShutdown, .{o.sock}) catch net.shutdown(o.sock);
                    break;
                }
            },
            else => {},
        }
    }

    fn delayedShutdown(sock: net.Socket) void {
        sync.sleepMs(300);
        net.shutdown(sock);
    }

    fn sendDenied(cn: *Conn, reason: []const u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.denied);
        try b.str(reason);
        cn.queue.pushOwned(try b.finish());
        sync.sleepMs(300); // deixa a escritora mandar antes de fechar
    }

    fn join(s: *Server, cn: *Conn, raw_name: []const u8, token: []const u8) !void {
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.conns.items.len >= s.max_members) {
            s.mutex.unlock();
            defer s.mutex.lock();
            try sendDenied(cn, "A sala está cheia.");
            return error.RoomFull;
        }
        const trimmed = std.mem.trim(u8, raw_name, " \t\r\n");
        const base = if (trimmed.len == 0) "anônimo" else trimmed[0..@min(trimmed.len, 32)];
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
        cn.admin = s.admin_token_len > 0 and std.mem.eql(u8, token, s.admin_token[0..s.admin_token_len]);
        try s.conns.append(gpa, cn);

        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.welcome);
        try b.u32_(cn.id);
        try b.str(s.room_name[0..s.room_name_len]);
        try b.u8_(@intFromBool(cn.admin));
        try b.u64_(s.nowUs());
        cn.queue.pushOwned(try b.finish());

        var tmp: [96]u8 = undefined;
        try s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} entrou na sala", .{name}) catch "");
        try s.broadcastMembers();
        s.log("{s} entrou ({d} na sala)", .{ name, s.conns.items.len });
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
            remove(&o.watching, cn.id);
            remove(&o.waiting_key, cn.id);
            _ = o.queue.dropFrames(cn.id);
            o.dropFlow(cn.id);
        }
        s.log("{s} saiu ({d} na sala)", .{ cn.nameSlice(), s.conns.items.len });
        if (s.stopped.load(.acquire)) return;
        var tmp: [96]u8 = undefined;
        s.broadcastChat(0, "", std.fmt.bufPrint(&tmp, "{s} saiu da sala", .{cn.nameSlice()}) catch "") catch {};
        s.broadcastMembers() catch {};
    }

    /// Chamado com o mutex travado.
    fn broadcastChat(s: *Server, from: u32, name: []const u8, text: []const u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.chat);
        try b.u32_(from);
        try b.str(name);
        try b.str(text);
        const m = try b.finish();
        defer m.release();
        for (s.conns.items) |o| o.queue.push(m);
    }

    /// Chamado com o mutex travado.
    fn broadcastMembers(s: *Server) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.members);
        try b.u16_(@intCast(s.conns.items.len));
        for (s.conns.items) |o| {
            try b.u32_(o.id);
            try b.str(o.nameSlice());
            var flags: u8 = 0;
            if (o.streaming) flags |= proto.member_streaming;
            if (o.admin) flags |= proto.member_admin;
            if (o.streaming and o.audio) flags |= proto.member_audio;
            if (o.mic) flags |= proto.member_mic;
            if (o.deaf) flags |= proto.member_deaf;
            try b.u8_(flags);
            try b.u16_(o.w);
            try b.u16_(o.h);
            try b.u8_(o.fps);
            const k: u16 = @intCast(@min(o.watching.items.len, 64));
            try b.u16_(k);
            for (o.watching.items[0..k]) |id| try b.u32_(id);
        }
        const m = try b.finish();
        defer m.release();
        for (s.conns.items) |o| o.queue.push(m);
    }

    /// Pede um IDR pro transmissor. Chamado com o mutex travado.
    fn requestKey(s: *Server, target: u32, force: bool) void {
        for (s.conns.items) |o| {
            if (o.id != target) continue;
            const now = sync.nowMs();
            if (!force and now - o.last_keyreq_ms < keyreq_interval_ms) return;
            o.last_keyreq_ms = now;
            o.queue.pushOwned(proto.simple(.keyreq) catch return);
            return;
        }
    }

    /// Áudio vai pra quem assiste; não espera IDR e só é descartado se a fila
    /// do espectador estiver muito atrasada (som picotado é melhor que atraso).
    fn forwardAudio(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < proto.audio_header_len) return error.BadMessage;
        const m = try proto.Msg.alloc(.audio, 4 + payload.len);
        defer m.release();
        m.from = cn.id;
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..], payload);
        s.mutex.lock();
        defer s.mutex.unlock();
        for (s.conns.items) |o| {
            if (o == cn or !contains(&o.watching, cn.id)) continue;
            if (o.queue.queuedBytes() > max_viewer_backlog * 2) continue;
            o.queue.push(m);
            _ = s.relayed_bytes.fetchAdd(m.data.len, .monotonic);
        }
    }

    /// Voz vai pra todo mundo da sala (menos quem fala e quem está surdo),
    /// furando a fila: conversa não pode esperar atrás de quadros de vídeo.
    fn forwardVoice(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < 4) return error.BadMessage;
        const m = try proto.Msg.alloc(.voice, 4 + payload.len);
        defer m.release();
        m.from = cn.id;
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..], payload);
        s.mutex.lock();
        defer s.mutex.unlock();
        for (s.conns.items) |o| {
            if (o == cn or o.deaf or !o.authed) continue;
            if (o.queue.queuedBytes() > max_viewer_backlog * 2) continue;
            o.queue.pushUrgent(m);
            _ = s.relayed_bytes.fetchAdd(m.data.len, .monotonic);
        }
    }

    fn forwardFrame(s: *Server, cn: *Conn, payload: []const u8) !void {
        if (payload.len < proto.frame_header_len) return error.BadMessage;
        const seq = std.mem.readInt(u32, payload[0..4], .little);
        const is_key = payload[4] & proto.frame_key != 0;

        // confirma na hora: o transmissor mede o próprio upload com isso
        const ack = try proto.Msg.alloc(.ack, 4);
        std.mem.writeInt(u32, ack.payload()[0..4], seq, .little);
        cn.queue.pushUrgentOwned(ack);

        // mensagem encaminhada montada uma vez só: [u32 de][frame]
        const m = try proto.Msg.alloc(.frame, 4 + payload.len);
        defer m.release();
        m.from = cn.id;
        std.mem.writeInt(u32, m.payload()[0..4], cn.id, .little);
        @memcpy(m.payload()[4..], payload);

        s.mutex.lock();
        defer s.mutex.unlock();
        const now_ms = sync.nowMs();
        const now_us = sync.nowUs();
        var need_key = false;
        var resynced = false; // algum espectador recomeçou agora
        var late = false; // algum espectador acumulando atraso há mais de 1 s
        for (s.conns.items) |o| {
            if (o == cn or !contains(&o.watching, cn.id)) continue;
            const f = o.flow(cn.id) orelse continue;
            if (f.decoder_behind) {
                // CPU de quem assiste não deu conta: taxa menor também alivia o decoder
                f.decoder_behind = false;
                resynced = true;
            }
            if (contains(&o.waiting_key, cn.id)) {
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
                remove(&o.waiting_key, cn.id);
            }
            const allowance = f.win.keyAllowanceUs(now_us);
            const excess = f.win.excessUs(now_us, default_base_us);
            f.updateTrend(excess, now_us);
            if (f.late) late = true;
            if (excess > max_viewer_excess_us + allowance or o.queue.queuedBytes() > max_viewer_backlog) {
                // espectador acumulando atraso: descarta o que nem saiu da
                // fila, espera o resto chegar e recomeça de um IDR
                f.win.dropNewest(o.queue.dropFrames(cn.id));
                addUnique(&o.waiting_key, cn.id);
                f.draining = true;
                f.late = false;
                f.trend_at_us = 0;
                resynced = true;
                _ = f.backoff(now_ms);
                s.log("{s} atrasou {d} ms assistindo {s}: recomeçando de um IDR (próximo em {d} ms)", .{ o.nameSlice(), excess / 1000, cn.nameSlice(), f.resync_after_ms - now_ms });
                continue;
            }
            o.queue.push(m);
            f.win.sent(seq, now_us, is_key);
            _ = s.relayed_bytes.fetchAdd(m.data.len, .monotonic);
        }
        if (need_key) s.requestKey(cn.id, false);
        if ((resynced or late) and now_ms - cn.last_slow_ms > 2000) {
            // se a maioria está sofrendo, o gargalo é comum (o upload de quem
            // hospeda a sala, ou só tem um espectador): a taxa desce o quanto
            // precisar. Se é a minoria, desce no máximo até a metade: quem não
            // dá conta nem assim fica recomeçando de IDR de vez em quando, sem
            // estragar a qualidade pros outros.
            cn.last_slow_ms = now_ms;
            var viewers: u32 = 0;
            var struggling: u32 = 0;
            for (s.conns.items) |o| {
                if (o == cn or !contains(&o.watching, cn.id)) continue;
                viewers += 1;
                const f = o.flow(cn.id) orelse continue;
                if (f.struggling(now_ms)) struggling += 1;
            }
            const majority = struggling * 2 > viewers;
            const hint = try proto.Msg.alloc(.viewer_slow, 1);
            hint.payload()[0] = if (majority) 10 else 50;
            cn.queue.pushUrgentOwned(hint);
            s.log("pedindo taxa menor pra {s} ({d} de {d} espectadores com dificuldade{s})", .{ cn.nameSlice(), struggling, viewers, if (resynced) "" else ", atrasando sem escoar" });
        }
    }
};
