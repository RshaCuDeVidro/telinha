//! Link público embutido: túnel TCP pelo protocolo do bore
//! (https://github.com/ekzhang/bore), sem instalar nada.
//!
//! Abre uma porta pública no servidor do túnel (bore.pub por padrão) e cada
//! conexão que chega nela vira uma conexão nova da sala. O tráfego da sala já
//! é cifrado de ponta a ponta (X25519 + ChaCha20-Poly1305 com a senha na
//! derivação das chaves), então o servidor do túnel só vê bytes embaralhados.
//!
//! Protocolo (JSON terminado em \0, porta de controle 7835):
//!   nós → servidor: {"Hello":porta}        (0 = qualquer porta)
//!   servidor → nós: {"Hello":porta}        porta pública
//!                   "Heartbeat"            a cada 500 ms
//!                   {"Connection":"uuid"}  alguém conectou na porta pública
//!                   {"Error":"motivo"}
//!   nós → servidor (conexão nova): {"Accept":"uuid"} e a partir daí os bytes
//!   são os do visitante.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const gpa = std.heap.c_allocator;

pub const default_host = "bore.pub";
pub const control_port: u16 = 7835;
const max_frame = 256;

pub const State = enum(u8) { connecting, ready, failed };

pub const Status = struct {
    state: State,
    public_port: u16,
    err: []const u8, // válido até a próxima chamada
};

pub const Tunnel = struct {
    refs: std.atomic.Value(u32) = .init(2), // dono + thread de controle
    host: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = control_port,
    /// Recebe cada conexão de visitante (já depois do Accept); fica com o socket.
    on_conn: *const fn (ctx: *anyopaque, sock: net.Socket) void,
    ctx: *anyopaque,
    stopping: std.atomic.Value(bool) = .init(false),

    mutex: sync.Mutex = .{},
    state: State = .connecting,
    public_port: u16 = 0,
    err: [160]u8 = undefined,
    err_len: usize = 0,
    err_copy: [160]u8 = undefined,
    control: ?net.Socket = null,

    /// `spec` = "host" ou "host:porta" (porta de controle; padrão 7835).
    pub fn start(spec: []const u8, ctx: *anyopaque, on_conn: *const fn (*anyopaque, net.Socket) void) !*Tunnel {
        const t = try gpa.create(Tunnel);
        t.* = .{ .on_conn = on_conn, .ctx = ctx };
        var host = std.mem.trim(u8, spec, " \t");
        if (host.len == 0) host = default_host;
        if (std.mem.findScalarLast(u8, host, ':')) |i| {
            t.port = std.fmt.parseInt(u16, host[i + 1 ..], 10) catch control_port;
            host = host[0..i];
        }
        t.host_len = @min(host.len, t.host.len);
        @memcpy(t.host[0..t.host_len], host[0..t.host_len]);
        sync.spawn(controlLoop, .{t}) catch {
            gpa.destroy(t);
            return error.ThreadFailed;
        };
        return t;
    }

    /// Fecha o túnel. Conexões de visitantes já entregues continuam com o dono delas.
    pub fn stop(t: *Tunnel) void {
        t.stopping.store(true, .release);
        t.mutex.lock();
        if (t.control) |s| net.shutdown(s);
        t.mutex.unlock();
        t.release();
    }

    fn release(t: *Tunnel) void {
        if (t.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(t);
    }

    pub fn hostSlice(t: *const Tunnel) []const u8 {
        return t.host[0..t.host_len];
    }

    pub fn status(t: *Tunnel) Status {
        t.mutex.lock();
        defer t.mutex.unlock();
        @memcpy(t.err_copy[0..t.err_len], t.err[0..t.err_len]);
        return .{ .state = t.state, .public_port = t.public_port, .err = t.err_copy[0..t.err_len] };
    }

    /// "bore.pub:41234" (vazio se ainda não tem porta).
    pub fn address(t: *Tunnel, buf: []u8) []const u8 {
        const st = t.status();
        if (st.state != .ready) return buf[0..0];
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ t.hostSlice(), st.public_port }) catch buf[0..0];
    }

    fn setState(t: *Tunnel, state: State, public_port: u16, msg: []const u8) void {
        t.mutex.lock();
        defer t.mutex.unlock();
        t.state = state;
        t.public_port = public_port;
        t.err_len = @min(msg.len, t.err.len);
        @memcpy(t.err[0..t.err_len], msg[0..t.err_len]);
    }

    fn controlLoop(t: *Tunnel) void {
        defer t.release();
        var want_port: u16 = 0;
        var wait_ms: u32 = 1000;
        while (!t.stopping.load(.acquire)) {
            const was_ready = t.runControl(&want_port) catch |e| blk: {
                const msg: []const u8 = switch (e) {
                    error.UnknownHost => "não achei o servidor do túnel (sem internet?)",
                    error.ConnectionRefused, error.ConnectFailed => "o servidor do túnel não respondeu",
                    error.AuthRequired => "esse servidor de túnel exige senha",
                    error.Refused => "", // mensagem do servidor já foi guardada
                    else => "a conexão com o servidor do túnel caiu",
                };
                if (msg.len > 0) t.setState(.failed, 0, msg);
                break :blk false;
            };
            if (t.stopping.load(.acquire)) break;
            // caiu: tenta de novo pedindo a mesma porta (o convite continua valendo)
            if (was_ready) wait_ms = 1000;
            var waited: u32 = 0;
            while (waited < wait_ms and !t.stopping.load(.acquire)) : (waited += 100) sync.sleepMs(100);
            wait_ms = @min(wait_ms * 2, 30_000);
        }
    }

    /// Uma sessão de controle. Retorna true se chegou a ficar pronta.
    fn runControl(t: *Tunnel, want_port: *u16) !bool {
        const s = try net.connect(t.hostSlice(), t.port);
        t.mutex.lock();
        t.control = s;
        const stopping = t.stopping.load(.acquire);
        t.mutex.unlock();
        defer {
            t.mutex.lock();
            t.control = null;
            t.mutex.unlock();
            net.close(s);
        }
        if (stopping) return false;
        net.setRecvTimeout(s, 5000);

        var out: [64]u8 = undefined;
        try sendFrame(s, std.fmt.bufPrint(&out, "{{\"Hello\":{d}}}", .{want_port.*}) catch unreachable);
        var buf: [max_frame]u8 = undefined;
        const reply = try recvFrame(s, &buf);
        if (field(reply, "Hello")) |v| {
            const p = std.fmt.parseInt(u16, v, 10) catch return error.Protocol;
            want_port.* = p;
            t.setState(.ready, p, "");
        } else if (field(reply, "Error")) |msg| {
            // a porta antiga não está mais livre: na próxima pede qualquer uma
            if (want_port.* != 0) want_port.* = 0 else t.setState(.failed, 0, msg);
            return error.Refused;
        } else if (field(reply, "Challenge") != null) {
            return error.AuthRequired;
        } else return error.Protocol;

        // o servidor manda "Heartbeat" a cada 500 ms: 10 s de silêncio = caiu
        net.setRecvTimeout(s, 10_000);
        while (!t.stopping.load(.acquire)) {
            const m = recvFrame(s, &buf) catch |e| {
                if (t.stopping.load(.acquire)) return true;
                t.setState(.connecting, 0, "");
                return e;
            };
            if (field(m, "Connection")) |id| {
                const a = gpa.create(AcceptJob) catch continue;
                a.* = .{ .t = t };
                a.id_len = @min(id.len, a.id.len);
                @memcpy(a.id[0..a.id_len], id[0..a.id_len]);
                _ = t.refs.fetchAdd(1, .monotonic);
                sync.spawn(acceptConn, .{a}) catch {
                    t.release();
                    gpa.destroy(a);
                };
            }
            // "Heartbeat" e erros avulsos: nada a fazer
        }
        return true;
    }

    const AcceptJob = struct {
        t: *Tunnel,
        id: [64]u8 = undefined,
        id_len: usize = 0,
    };

    /// Abre a conexão de dados do visitante e entrega pra sala.
    fn acceptConn(a: *AcceptJob) void {
        const t = a.t;
        defer {
            gpa.destroy(a);
            t.release();
        }
        const s = net.connect(t.hostSlice(), t.port) catch return;
        var out: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&out, "{{\"Accept\":\"{s}\"}}", .{a.id[0..a.id_len]}) catch {
            net.close(s);
            return;
        };
        sendFrame(s, msg) catch {
            net.close(s);
            return;
        };
        if (t.stopping.load(.acquire)) {
            net.close(s);
            return;
        }
        t.on_conn(t.ctx, s);
    }
};

fn sendFrame(s: net.Socket, json: []const u8) !void {
    var buf: [max_frame + 1]u8 = undefined;
    if (json.len > max_frame) return error.Protocol;
    @memcpy(buf[0..json.len], json);
    buf[json.len] = 0;
    try net.sendAll(s, buf[0 .. json.len + 1]);
}

/// Lê até o \0 (byte a byte: as mensagens de controle são minúsculas e assim
/// nada além da mensagem é consumido do socket).
fn recvFrame(s: net.Socket, buf: []u8) ![]const u8 {
    var n: usize = 0;
    while (true) {
        var b: [1]u8 = undefined;
        try net.recvAll(s, &b);
        if (b[0] == 0) return buf[0..n];
        if (n == buf.len) return error.Protocol;
        buf[n] = b[0];
        n += 1;
    }
}

/// Valor de {"Nome":valor} (número ou string, sem aspas). null se não for essa mensagem.
pub fn field(json: []const u8, comptime name: []const u8) ?[]const u8 {
    const key = "\"" ++ name ++ "\"";
    const i = std.mem.find(u8, json, key) orelse return null;
    var rest = std.mem.trimStart(u8, json[i + key.len ..], " ");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trimStart(u8, rest[1..], " ");
    if (rest.len > 0 and rest[0] == '"') {
        const end = std.mem.findScalar(u8, rest[1..], '"') orelse return null;
        return rest[1 .. 1 + end];
    }
    const end = std.mem.findAny(u8, rest, ",} ") orelse rest.len;
    return rest[0..end];
}
