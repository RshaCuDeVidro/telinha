//! Salas recentes (salas.txt na pasta de configuração): a tela inicial lista
//! as últimas em que a pessoa entrou e um clique entra de novo, sem colar o
//! convite. Uma por linha: "endereços\tsenha\tcanal\tnome da sala" (a senha
//! fica do jeito que já fica no config.ini).
const std = @import("std");
const config = @import("config.zig");
const c = config.c;

pub const max = 6;

pub const Room = struct {
    addr: [256]u8 = undefined,
    addr_len: usize = 0,
    pass: [129]u8 = undefined,
    pass_len: usize = 0,
    chan: [32]u8 = undefined,
    chan_len: usize = 0,
    name: [65]u8 = undefined,
    name_len: usize = 0,

    pub fn addrSlice(r: *const Room) []const u8 {
        return r.addr[0..r.addr_len];
    }
    pub fn passSlice(r: *const Room) []const u8 {
        return r.pass[0..r.pass_len];
    }
    pub fn chanSlice(r: *const Room) []const u8 {
        return r.chan[0..r.chan_len];
    }
    pub fn nameSlice(r: *const Room) []const u8 {
        return r.name[0..r.name_len];
    }
};

/// Copia sem tab nem quebra de linha (separam os campos e as salas).
fn put(dst: []u8, len: *usize, v: []const u8) void {
    var n: usize = 0;
    for (v) |ch| {
        if (n == dst.len) break;
        if (ch == '\t' or ch == '\n' or ch == '\r') continue;
        dst[n] = ch;
        n += 1;
    }
    // não corta um caractere no meio
    while (n > 0 and n < v.len and dst[n - 1] & 0xC0 == 0x80) n -= 1;
    if (n > 0 and dst[n - 1] & 0xC0 == 0xC0 and n < v.len) n -= 1;
    len.* = n;
}

pub fn make(addr: []const u8, pass: []const u8, chan: []const u8, name: []const u8) Room {
    var r: Room = .{};
    put(&r.addr, &r.addr_len, addr);
    put(&r.pass, &r.pass_len, pass);
    put(&r.chan, &r.chan_len, chan);
    put(&r.name, &r.name_len, name);
    return r;
}

/// Lê as salas do texto do arquivo (linhas sem endereço não valem).
pub fn parse(text: []const u8, out: []Room) usize {
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (n == out.len) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        var f = std.mem.splitScalar(u8, line, '\t');
        const addr = f.next() orelse continue;
        if (addr.len == 0) continue;
        out[n] = make(addr, f.next() orelse "", f.next() orelse "", f.next() orelse "");
        n += 1;
    }
    return n;
}

/// Escreve as salas no formato do arquivo; devolve o que foi escrito.
pub fn format(rooms: []const Room, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (rooms) |*r| w.print("{s}\t{s}\t{s}\t{s}\n", .{ r.addrSlice(), r.passSlice(), r.chanSlice(), r.nameSlice() }) catch break;
    return w.buffered();
}

/// Põe `r` na frente (a mesma sala, pelo endereço, sai de onde estava) e
/// guarda no máximo `max`.
pub fn pushFront(rooms: []Room, n: usize, r: Room) usize {
    var k: usize = 0;
    var tmp: [max]Room = undefined;
    tmp[0] = r;
    k = 1;
    for (rooms[0..n]) |*x| {
        if (k == max) break;
        if (std.mem.eql(u8, x.addrSlice(), r.addrSlice())) continue;
        tmp[k] = x.*;
        k += 1;
    }
    @memcpy(rooms[0..k], tmp[0..k]);
    return k;
}

pub fn load(out: []Room) usize {
    const f = config.openNamed("salas.txt", false) orelse return 0;
    defer _ = c.fclose(f);
    var buf: [8 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    return parse(buf[0..n], out);
}

fn save(rooms: []const Room) void {
    var buf: [8 * 1024]u8 = undefined;
    const text = format(rooms, &buf);
    const f = config.openNamed("salas.txt", true) orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(text.ptr, 1, text.len, f);
}

/// Entrou nessa sala: ela vai pro começo da lista.
pub fn remember(addr: []const u8, pass: []const u8, chan: []const u8, name: []const u8) void {
    if (addr.len == 0) return;
    var rooms: [max]Room = undefined;
    const n = load(&rooms);
    const k = pushFront(&rooms, n, make(addr, pass, chan, name));
    save(rooms[0..k]);
}

/// Tira uma sala da lista (o x dela na tela inicial).
pub fn forget(addr: []const u8) void {
    var rooms: [max]Room = undefined;
    const n = load(&rooms);
    var k: usize = 0;
    for (rooms[0..n]) |r| {
        if (std.mem.eql(u8, r.addrSlice(), addr)) continue;
        rooms[k] = r;
        k += 1;
    }
    save(rooms[0..k]);
}

test "salas recentes: lê, escreve, a de agora vai pra frente sem repetir, no máximo seis" {
    var rooms: [max]Room = undefined;
    var n = parse("a:1\tsenha\tgeral\tSala A\n\nb:2\t\t\t\nlixo sem nada\r\n", &rooms);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("senha", rooms[0].passSlice());
    try std.testing.expectEqualStrings("Sala A", rooms[0].nameSlice());
    try std.testing.expectEqualStrings("b:2", rooms[1].addrSlice());
    try std.testing.expectEqualStrings("lixo sem nada", rooms[2].addrSlice());
    // a mesma sala de novo: vai pra frente e não repete
    n = pushFront(&rooms, n, make("b:2", "pw", "jogos", "Sala B"));
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("b:2", rooms[0].addrSlice());
    try std.testing.expectEqualStrings("jogos", rooms[0].chanSlice());
    try std.testing.expectEqualStrings("a:1", rooms[1].addrSlice());
    // tab e quebra de linha não entram (separam os campos)
    n = pushFront(&rooms, n, make("c:3", "p\tw", "x\ny", "S\tala"));
    try std.testing.expectEqualStrings("pw", rooms[0].passSlice());
    try std.testing.expectEqualStrings("Sala", rooms[0].nameSlice());
    // escreve e lê de volta igual
    var buf: [2048]u8 = undefined;
    var back: [max]Room = undefined;
    const m = parse(format(rooms[0..n], &buf), &back);
    try std.testing.expectEqual(n, m);
    for (rooms[0..n], back[0..m]) |*x, *y| {
        try std.testing.expectEqualStrings(x.addrSlice(), y.addrSlice());
        try std.testing.expectEqualStrings(x.nameSlice(), y.nameSlice());
    }
    // no máximo seis
    for (0..10) |i| {
        var ab: [16]u8 = undefined;
        n = pushFront(&rooms, n, make(std.fmt.bufPrint(&ab, "h{d}:1", .{i}) catch unreachable, "", "", ""));
    }
    try std.testing.expectEqual(@as(usize, max), n);
    try std.testing.expectEqualStrings("h9:1", rooms[0].addrSlice());
}
