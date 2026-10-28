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
const proto = @import("proto.zig");
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

/// O convite como link https da página de convite do site (".../j/#i=<convite
/// codificado>"): clicável no Discord e no navegador (telinha:// não é), e a
/// página abre o app ou ensina a instalar. O que vai depois do # nunca sai do
/// navegador de quem clica. `site` = "https://dono.github.io/telinha/" (com a barra).
pub fn toWebLink(site: []const u8, english: bool, invite: []const u8, buf: []u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}{s}j/#i=", .{ site, if (english) "en/" else "" }) catch return null;
    for (invite) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            w.writeByte(ch) catch return null;
        } else w.print("%{X:0>2}", .{ch}) catch return null;
    }
    return w.buffered();
}

/// O contrário: link da página de convite → "telinha://..." (null = não é um).
pub fn fromWebLink(text: []const u8, buf: []u8) ?[]const u8 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "https://")) return null;
    const at = std.mem.indexOf(u8, s, "/j/#i=") orelse return null;
    const enc = s[at + "/j/#i=".len ..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < enc.len) : (n += 1) {
        if (n >= buf.len) return null;
        if (enc[i] == '%' and i + 2 < enc.len) {
            buf[n] = std.fmt.parseInt(u8, enc[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buf[n] = enc[i];
            i += 1;
        }
    }
    const out = buf[0..n];
    return if (std.mem.startsWith(u8, out, "telinha://")) out else null;
}

test "convite como link https e de volta" {
    const inv = "telinha://1.2.3.4:7777,[2001:db8::1]:7777/canal!abcdefghijklmnopqrstuvwx#s3nh@ #x";
    var b1: [400]u8 = undefined;
    const link = toWebLink("https://dono.github.io/telinha/", false, inv, &b1).?;
    try std.testing.expect(std.mem.startsWith(u8, link, "https://dono.github.io/telinha/j/#i=telinha%3A%2F%2F1.2.3.4%3A7777"));
    try std.testing.expect(std.mem.indexOfScalar(u8, link["https://".len..], '#').? == "dono.github.io/telinha/j/".len);
    var b2: [400]u8 = undefined;
    try std.testing.expectEqualStrings(inv, fromWebLink(link, &b2).?);
    const en = toWebLink("https://dono.github.io/telinha/", true, inv, &b1).?;
    try std.testing.expect(std.mem.indexOf(u8, en, "/en/j/#i=") != null);
    try std.testing.expectEqualStrings(inv, fromWebLink(en, &b2).?);
    // outra coisa não vira convite
    try std.testing.expect(fromWebLink("https://exemplo.com/j/#i=oi", &b2) == null);
    try std.testing.expect(fromWebLink("telinha://x:1", &b2) == null);
    try std.testing.expect(fromWebLink("https://x/j/#i=%zz", &b2) == null);
}

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
    version: u16, // a versão do protocolo combinada (a nossa, ou a antiga com servidor antigo)
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

/// Uma tentativa num endereço: conecta, troca os hellos. `error.OldServer`
/// (em `err`): o servidor fala o protocolo antigo e a gente pediu o novo.
fn tryOnce(t: *const Target, version: u16, err: *anyerror, r: *Race) ?Winner {
    const s = net.connect(t.hostSlice(), t.port) catch |e| {
        err.* = e;
        return null;
    };
    net.setRecvTimeout(s, 8000);
    const hs = crypto.Handshake.init() catch {
        net.close(s);
        return null;
    };
    net.sendAll(s, &hs.helloBytes(version)) catch |e| {
        err.* = e;
        net.close(s);
        return null;
    };
    var hb: [crypto.hello_len]u8 = undefined;
    net.recvAll(s, &hb) catch |e| {
        err.* = e;
        net.close(s);
        return null;
    };
    const peer = crypto.parseHello(&hb) catch |e| {
        err.* = e;
        net.close(s);
        return null;
    };
    if (peer.version != version) {
        net.close(s);
        if (peer.version == proto.version_old and version == proto.version) {
            err.* = error.OldServer;
            return null;
        }
        err.* = error.VersionMismatch;
        r.mutex.lock();
        r.version_mismatch = peer.version;
        r.mutex.unlock();
        return null;
    }
    net.setRecvTimeout(s, 0);
    return .{ .sock = s, .hs = hs, .peer = peer, .index = 0, .version = version };
}

fn attempt(r: *Race, i: usize, delay_ms: u32, version: u16) void {
    defer r.release();
    // escalonamento: dá vantagem pros primeiros da lista (os diretos)
    var waited: u32 = 0;
    while (waited < delay_ms and !r.cancel.load(.acquire)) : (waited += 10) sync.sleepMs(10);
    var result: ?Winner = null;
    var err: anyerror = error.Cancelled;
    if (!r.cancel.load(.acquire)) {
        // servidor antigo (protocolo 6) recusa o nosso hello e fecha: conecta
        // de novo falando o 6 (uma vez só)
        result = tryOnce(&r.targets[i], version, &err, r);
        if (result == null and err == error.OldServer and !r.cancel.load(.acquire)) result = tryOnce(&r.targets[i], proto.version_old, &err, r);
        if (err == error.OldServer) err = error.VersionMismatch;
    }
    r.mutex.lock();
    defer r.mutex.unlock();
    r.finished += 1;
    if (result) |res| {
        var w = res;
        w.index = i;
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
