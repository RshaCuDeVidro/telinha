//! Vários caminhos pra mesma sala. O convite pode trazer vários endereços
//! (porta aberta no roteador, IPv6 direto, rede local, link público...):
//!
//!     telinha://203.0.113.7:7777,[2804:14c::1]:7777,bore.pub:41234#senha
//!
//! Quem entra tenta todos quase juntos (o primeiro da lista sai na frente, os
//! outros 250 ms depois um do outro) e fica com o primeiro que responder como
//! uma sala do telinha. Quem tem IPv6 entra direto; quem não tem cai no link
//! público sozinho — cada pessoa pelo melhor caminho que tiver.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const crypto = @import("crypto.zig");
const gpa = std.heap.c_allocator;

pub const max_targets = 8;

pub const Target = struct {
    host: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,

    pub fn hostSlice(t: *const Target) []const u8 {
        return t.host[0..t.host_len];
    }
};

/// "host:porta" ou "[ipv6]:porta" (aceita "telinha://", "tcp://" e barra no fim).
pub fn parseOne(raw: []const u8) ?Target {
    var a = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.find(u8, a, "://")) |i| a = a[i + 3 ..];
    a = std.mem.trimEnd(u8, a, "/");
    const colon = std.mem.findScalarLast(u8, a, ':') orelse return null;
    var host = a[0..colon];
    // IPv6 sem colchete ("2804::1:7777") é ambíguo: exige [ ]
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    } else if (std.mem.findScalar(u8, host, ':') != null) return null;
    const port = std.fmt.parseInt(u16, a[colon + 1 ..], 10) catch return null;
    if (host.len == 0 or host.len > 255 or port == 0) return null;
    var t: Target = .{ .port = port };
    @memcpy(t.host[0..host.len], host);
    t.host_len = host.len;
    return t;
}

/// Lista separada por vírgula (ordem = preferência). Retorna quantos achou.
pub fn parseList(s: []const u8, out: []Target) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (n == out.len) break;
        if (std.mem.trim(u8, part, " ").len == 0) continue;
        out[n] = parseOne(part) orelse continue;
        n += 1;
    }
    return n;
}

/// Convite → endereços + canal + identidade + senha:
/// telinha://end1,end2/canal!impressão#senha (canal, impressão e senha são
/// opcionais; a impressão é a identidade que o servidor tem que provar).
pub const Invite = struct {
    addrs: []const u8, // lista separada por vírgula
    password: ?[]const u8,
    channel: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
};

pub fn splitInvite(raw: []const u8) Invite {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, s, "telinha://")) s = s["telinha://".len..];
    var inv: Invite = .{ .addrs = s, .password = null };
    if (std.mem.findScalar(u8, s, '#')) |h| {
        inv.addrs = s[0..h];
        inv.password = s[h + 1 ..];
    }
    // a impressão vem depois do "!" (endereço e canal nunca têm "!")
    if (std.mem.findScalar(u8, inv.addrs, '!')) |ex| {
        const fp = std.mem.trim(u8, inv.addrs[ex + 1 ..], " ");
        if (fp.len > 0) inv.fingerprint = fp;
        inv.addrs = inv.addrs[0..ex];
    }
    // endereço nunca tem "/" (IPv6 vai entre colchetes, sem barra)
    if (std.mem.findScalar(u8, inv.addrs, '/')) |sl| {
        const ch = std.mem.trim(u8, inv.addrs[sl + 1 ..], "/ ");
        if (ch.len > 0) inv.channel = ch;
        inv.addrs = inv.addrs[0..sl];
    }
    return inv;
}

// ---------------------------------------------------------------------------
// Corrida

pub const Winner = struct {
    sock: net.Socket,
    hs: crypto.Handshake,
    peer: crypto.Hello,
    index: usize, // qual endereço da lista ganhou
};

const Race = struct {
    refs: std.atomic.Value(u32),
    mutex: sync.Mutex = .{},
    cond: sync.Cond = .{},
    winner: ?Winner = null,
    finished: usize = 0, // tentativas que já acabaram (ganhando ou perdendo)
    total: usize,
    cancel: std.atomic.Value(bool) = .init(false),
    refused: bool = false, // alguma deu "conexão recusada" (porta fechada)
    unknown: bool = false, // algum nome não resolveu
    not_telinha: bool = false, // respondeu, mas não é sala do telinha
    version_mismatch: ?u16 = null, // é sala do telinha, mas outra versão
    targets: [max_targets]Target,

    fn release(r: *Race) void {
        if (r.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(r);
    }
};

fn attempt(r: *Race, i: usize, delay_ms: u32, version: u16) void {
    defer r.release();
    // escalonamento: dá vantagem pros primeiros da lista (os diretos)
    var waited: u32 = 0;
    while (waited < delay_ms and !r.cancel.load(.acquire)) : (waited += 10) sync.sleepMs(10);
    var result: ?Winner = null;
    var err: anyerror = error.Cancelled;
    if (!r.cancel.load(.acquire)) blk: {
        const t = &r.targets[i];
        const s = net.connect(t.hostSlice(), t.port) catch |e| {
            err = e;
            break :blk;
        };
        net.setRecvTimeout(s, 8000);
        const hs = crypto.Handshake.init() catch {
            net.close(s);
            break :blk;
        };
        net.sendAll(s, &hs.helloBytes(version)) catch |e| {
            err = e;
            net.close(s);
            break :blk;
        };
        var hb: [crypto.hello_len]u8 = undefined;
        net.recvAll(s, &hb) catch |e| {
            err = e;
            net.close(s);
            break :blk;
        };
        const peer = crypto.parseHello(&hb) catch |e| {
            err = e;
            net.close(s);
            break :blk;
        };
        if (peer.version != version) {
            err = error.VersionMismatch;
            r.mutex.lock();
            r.version_mismatch = peer.version;
            r.mutex.unlock();
            net.close(s);
            break :blk;
        }
        net.setRecvTimeout(s, 0);
        result = .{ .sock = s, .hs = hs, .peer = peer, .index = i };
    }
    r.mutex.lock();
    defer r.mutex.unlock();
    r.finished += 1;
    if (result) |w| {
        if (r.winner == null and !r.cancel.load(.acquire)) {
            r.winner = w;
            r.cancel.store(true, .release); // as outras desistem
        } else net.close(w.sock); // chegou depois
    } else switch (err) {
        error.ConnectionRefused => r.refused = true,
        error.UnknownHost => r.unknown = true,
        error.NotTelinha => r.not_telinha = true,
        else => {},
    }
    r.cond.broadcast();
}

pub const Error = error{ UnknownHost, ConnectionRefused, ConnectFailed, NotTelinha, VersionMismatch, ThreadFailed, Cancelled };

pub const Failure = struct {
    err: Error,
    server_version: u16 = 0,
};

/// Conecta no primeiro endereço que responder como sala do telinha (versão
/// `version`). `cancel`: quem chama pode desistir (sair da tela).
pub fn race(targets: []const Target, version: u16, timeout_ms: u32, cancel: *const std.atomic.Value(bool), fail: *Failure) Error!Winner {
    if (targets.len == 0) return error.UnknownHost;
    const n = @min(targets.len, max_targets);
    const r = gpa.create(Race) catch return error.ThreadFailed;
    r.* = .{ .refs = .init(1), .total = n, .targets = undefined };
    @memcpy(r.targets[0..n], targets[0..n]);
    for (0..n) |i| {
        _ = r.refs.fetchAdd(1, .monotonic);
        sync.spawn(attempt, .{ r, i, @as(u32, @intCast(i)) * 250, version }) catch {
            _ = r.refs.fetchSub(1, .monotonic);
            r.mutex.lock();
            r.finished += 1;
            r.mutex.unlock();
        };
    }
    defer r.release();
    const t0 = sync.nowMs();
    r.mutex.lock();
    defer r.mutex.unlock();
    while (r.winner == null and r.finished < r.total) {
        if (cancel.load(.acquire) or sync.nowMs() - t0 > timeout_ms) {
            r.cancel.store(true, .release);
            fail.err = if (cancel.load(.acquire)) error.Cancelled else error.ConnectFailed;
            return fail.err;
        }
        r.cond.timedWait(&r.mutex, 50);
    }
    if (r.winner) |w| return w;
    fail.err = if (r.version_mismatch) |v| blk: {
        fail.server_version = v;
        break :blk error.VersionMismatch;
    } else if (r.not_telinha) error.NotTelinha else if (r.refused) error.ConnectionRefused else if (r.unknown and r.total == 1) error.UnknownHost else error.ConnectFailed;
    return fail.err;
}
