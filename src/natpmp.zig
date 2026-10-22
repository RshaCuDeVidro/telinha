//! Abre a porta da sala pelo NAT-PMP (RFC 6886) ou pelo PCP (RFC 6887): os
//! outros dois jeitos de pedir porta ao roteador, além do UPnP. Muito roteador
//! sem UPnP (ou com ele desligado) responde a um deles: os da Apple, os com
//! OpenWrt/miniupnpd, vários de operadora. Nada de serviço de fora: um pacote
//! UDP pro próprio roteador (porta 5351).
//!
//! NAT-PMP primeiro (mais simples e mais comum); se o roteador disser que só
//! fala uma versão mais nova (o PCP), vai de PCP. O mapeamento vale 1 h e é
//! renovado; ao fechar, pede de volta com tempo zero.
const std = @import("std");
const net = @import("net.zig");
const sync = @import("sync.zig");
const upnp = @import("upnp.zig");

pub const port: u16 = 5351;
const lifetime_s: u32 = 3600;

pub const Error = error{ NoRouter, Cgnat, Refused, Network };

pub const Mapping = struct {
    gw: [4]u8,
    gw_port: u16,
    pcp: bool,
    nonce: [12]u8 = .{0} ** 12, // PCP: o mesmo nos pedidos de renovar e apagar
    local: [4]u8 = .{ 0, 0, 0, 0 },
    ext_ip: [4]u8,
    ext_port: u16,
    int_port: u16,
    lifetime: u32,
    udp: bool,
};

/// O roteador (gateway padrão). TELINHA_NATPMP=ip:porta troca (testes, com um
/// roteador de mentira, sem mexer no de verdade).
pub fn gateway() ?struct { [4]u8, u16 } {
    if (std.c.getenv("TELINHA_NATPMP")) |v| {
        const sv = std.mem.span(v);
        const colon = std.mem.findScalarLast(u8, sv, ':') orelse return null;
        const ip = upnp.parseIp4(sv[0..colon]) orelse return null;
        return .{ ip, std.fmt.parseInt(u16, sv[colon + 1 ..], 10) catch return null };
    }
    // testes (QA ou os de unidade) sem roteador de mentira: nunca fala com o de verdade
    if (@import("builtin").is_test or std.c.getenv("TELINHA_QA") != null) return null;
    const gw = defaultGateway() orelse return null;
    return .{ gw, port };
}

fn defaultGateway() ?[4]u8 {
    if (sync.is_windows) {
        var out: [4]u8 = undefined;
        return if (default_gateway4(&out) == 0) out else null;
    }
    // /proc/net/route: "eth0 00000000 0101A8C0 ..." (destino 0 = rota padrão; hex little-endian)
    const f = std.c.fopen("/proc/net/route", "r") orelse return null;
    defer _ = std.c.fclose(f);
    var line: [256]u8 = undefined;
    while (fgets(&line, line.len, f) != null) {
        if (parseRouteLine(std.mem.sliceTo(&line, 0))) |gw| return gw;
    }
    return null;
}

fn parseRouteLine(line: []const u8) ?[4]u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t\r\n");
    _ = it.next() orelse return null; // interface
    const dest = it.next() orelse return null;
    const gw = it.next() orelse return null;
    if (!std.mem.eql(u8, dest, "00000000")) return null;
    const v = std.fmt.parseInt(u32, gw, 16) catch return null;
    if (v == 0) return null;
    return std.mem.toBytes(std.mem.nativeToLittle(u32, v));
}

extern "c" fn fgets(buf: [*]u8, n: c_int, f: *std.c.FILE) ?[*]u8;
extern "c" fn default_gateway4(out: *[4]u8) c_int;

// ------------------------------------------------------------- pacotes

/// NAT-PMP: pedido de mapeamento (12 bytes). lifetime 0 = apagar.
pub fn pmpMapRequest(udp: bool, int_port: u16, ext_port: u16, lifetime: u32) [12]u8 {
    var b: [12]u8 = .{0} ** 12;
    b[1] = if (udp) 1 else 2;
    std.mem.writeInt(u16, b[4..6], int_port, .big);
    std.mem.writeInt(u16, b[6..8], ext_port, .big);
    std.mem.writeInt(u32, b[8..12], lifetime, .big);
    return b;
}

pub const PmpReply = struct { result: u16, ext_ip: [4]u8 = .{ 0, 0, 0, 0 }, ext_port: u16 = 0, lifetime: u32 = 0 };

/// Resposta do NAT-PMP pro pedido `op` (0 = IP de fora, 1/2 = mapear).
/// null = não é resposta a isso. result 1 = "não falo essa versão" (PCP).
pub fn pmpParse(op: u8, b: []const u8) ?PmpReply {
    if (b.len < 4 or b[1] != op + 128) {
        // roteador só de PCP responde ao NAT-PMP com a versão dele e erro de versão
        if (b.len >= 4 and b[0] == 2) return .{ .result = 1 };
        return null;
    }
    if (b[0] != 0) return .{ .result = 1 };
    const result = std.mem.readInt(u16, b[2..4], .big);
    if (result != 0) return .{ .result = result };
    if (op == 0) {
        if (b.len < 12) return null;
        return .{ .result = 0, .ext_ip = b[8..12].* };
    }
    if (b.len < 16) return null;
    return .{ .result = 0, .ext_port = std.mem.readInt(u16, b[10..12], .big), .lifetime = std.mem.readInt(u32, b[12..16], .big) };
}

/// PCP: pedido MAP (60 bytes). Endereços IPv4 vão como ::ffff:a.b.c.d.
pub fn pcpMapRequest(local: [4]u8, nonce: [12]u8, udp: bool, int_port: u16, ext_port: u16, lifetime: u32) [60]u8 {
    var b: [60]u8 = .{0} ** 60;
    b[0] = 2; // versão
    b[1] = 1; // MAP (pedido)
    std.mem.writeInt(u32, b[4..8], lifetime, .big);
    mapped(b[8..24], local);
    @memcpy(b[24..36], &nonce);
    b[36] = if (udp) 17 else 6;
    std.mem.writeInt(u16, b[40..42], int_port, .big);
    std.mem.writeInt(u16, b[42..44], ext_port, .big);
    mapped(b[44..60], .{ 0, 0, 0, 0 });
    return b;
}

fn mapped(out: *[16]u8, ip: [4]u8) void {
    @memset(out[0..10], 0);
    out[10] = 0xff;
    out[11] = 0xff;
    @memcpy(out[12..16], &ip);
}

/// Resposta do PCP ao MAP com esse nonce. null = não é dela.
pub fn pcpParse(nonce: [12]u8, b: []const u8) ?PmpReply {
    if (b.len < 60 or b[0] != 2 or b[1] != 0x81) return null;
    if (!std.mem.eql(u8, b[24..36], &nonce)) return null;
    const result: u16 = b[3];
    if (result != 0) return .{ .result = result };
    return .{ .result = 0, .lifetime = std.mem.readInt(u32, b[4..8], .big), .ext_port = std.mem.readInt(u16, b[42..44], .big), .ext_ip = b[56..60].* };
}

// ------------------------------------------------------------- conversa

/// Manda e espera a resposta (RFC 6886: 250 ms, dobrando). `parse` diz se é ela.
fn ask(gw: [4]u8, gw_port: u16, req: []const u8, ctx: anytype, comptime parse: fn (@TypeOf(ctx), []const u8) ?PmpReply) ?PmpReply {
    const s = net.udpOpen() catch return null;
    defer net.close(s);
    var wait: u32 = 250;
    var buf: [1100]u8 = undefined;
    for (0..4) |_| {
        if (!net.udpSendTo(s, gw, gw_port, req)) return null;
        net.setRecvTimeout(s, wait);
        const t0 = sync.nowMs();
        while (sync.nowMs() - t0 < wait) {
            const n = net.udpRecv(s, &buf) orelse break;
            if (parse(ctx, buf[0..n])) |r| return r;
        }
        wait *= 2;
    }
    return null;
}

fn parsePmp0(_: void, b: []const u8) ?PmpReply {
    return pmpParse(0, b);
}
fn parsePmpUdp(_: void, b: []const u8) ?PmpReply {
    return pmpParse(1, b);
}
fn parsePmpTcp(_: void, b: []const u8) ?PmpReply {
    return pmpParse(2, b);
}
fn parsePcp(nonce: [12]u8, b: []const u8) ?PmpReply {
    return pcpParse(nonce, b);
}

fn pmpMap(m: *const Mapping, udp: bool, ext_port: u16, lifetime: u32) ?PmpReply {
    const req = pmpMapRequest(udp, m.int_port, ext_port, lifetime);
    return if (udp) ask(m.gw, m.gw_port, &req, {}, parsePmpUdp) else ask(m.gw, m.gw_port, &req, {}, parsePmpTcp);
}

fn pcpMap(m: *const Mapping, udp: bool, ext_port: u16, lifetime: u32) ?PmpReply {
    // nonce diferente por protocolo (são dois mapeamentos)
    var nonce = m.nonce;
    if (udp) nonce[11] ^= 1;
    const req = pcpMapRequest(m.local, nonce, udp, m.int_port, ext_port, lifetime);
    return ask(m.gw, m.gw_port, &req, nonce, parsePcp);
}

fn mapOne(m: *const Mapping, udp: bool, ext_port: u16, lifetime: u32) ?PmpReply {
    return if (m.pcp) pcpMap(m, udp, ext_port, lifetime) else pmpMap(m, udp, ext_port, lifetime);
}

/// Abre `int_port` (TCP e, se der, UDP) no roteador `gw`.
pub fn open(gw: [4]u8, gw_port: u16, int_port: u16) Error!Mapping {
    var m: Mapping = .{ .gw = gw, .gw_port = gw_port, .pcp = false, .ext_ip = undefined, .ext_port = int_port, .int_port = int_port, .lifetime = lifetime_s, .udp = false };
    sync.osRandom(&m.nonce);
    m.local = net.localIp4To(gw) orelse return error.Network;
    // NAT-PMP: o IP de fora primeiro (e se o roteador fala NAT-PMP)
    const ext = ask(gw, gw_port, &[2]u8{ 0, 0 }, {}, parsePmp0);
    if (ext) |r| {
        if (r.result == 0) {
            if (upnp.unreachableIp(r.ext_ip)) return error.Cgnat;
            m.ext_ip = r.ext_ip;
        } else m.pcp = true; // "não falo essa versão": PCP
    } else m.pcp = true; // nada: talvez só PCP (o roteador ignora versão que não conhece)
    const tcp = mapOne(&m, false, int_port, lifetime_s) orelse return error.NoRouter;
    if (tcp.result != 0) return error.Refused;
    m.ext_port = tcp.ext_port;
    m.lifetime = if (tcp.lifetime != 0) tcp.lifetime else lifetime_s;
    if (m.pcp) {
        if (upnp.unreachableIp(tcp.ext_ip)) {
            _ = mapOne(&m, false, m.ext_port, 0);
            return error.Cgnat;
        }
        m.ext_ip = tcp.ext_ip;
    }
    // a mesma porta em UDP (vídeo/som); sem ela, fica no TCP
    if (mapOne(&m, true, m.ext_port, m.lifetime)) |u| m.udp = u.result == 0 and u.ext_port == m.ext_port;
    return m;
}

/// Renova (o mesmo pedido de novo, antes do prazo).
pub fn renew(m: *Mapping) bool {
    if (m.udp) _ = mapOne(m, true, m.ext_port, lifetime_s);
    const r = mapOne(m, false, m.ext_port, lifetime_s) orelse return false;
    if (r.result == 0 and r.lifetime != 0) m.lifetime = r.lifetime;
    return r.result == 0;
}

/// Devolve a porta (tempo zero).
pub fn close(m: *Mapping) void {
    if (m.udp) _ = mapOne(m, true, m.ext_port, 0);
    _ = mapOne(m, false, m.ext_port, 0);
}

const testing = std.testing;

test "natpmp: pedido e resposta (RFC 6886)" {
    const req = pmpMapRequest(false, 7777, 7777, 3600);
    try testing.expectEqualSlices(u8, &.{ 0, 2, 0, 0, 0x1e, 0x61, 0x1e, 0x61, 0, 0, 0x0e, 0x10 }, &req);
    // IP de fora
    const r0 = pmpParse(0, &.{ 0, 128, 0, 0, 0, 0, 0, 5, 203, 0, 113, 7 }).?;
    try testing.expectEqual(@as(u16, 0), r0.result);
    try testing.expectEqualSlices(u8, &.{ 203, 0, 113, 7 }, &r0.ext_ip);
    // mapeou TCP 7777 -> 7778, 1800 s
    const r2 = pmpParse(2, &.{ 0, 130, 0, 0, 0, 0, 0, 5, 0x1e, 0x61, 0x1e, 0x62, 0, 0, 0x07, 0x08 }).?;
    try testing.expectEqual(@as(u16, 7778), r2.ext_port);
    try testing.expectEqual(@as(u32, 1800), r2.lifetime);
    // recusou (2 = sem autorização)
    try testing.expectEqual(@as(u16, 2), pmpParse(2, &.{ 0, 130, 0, 2, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0 }).?.result);
    // roteador só de PCP: responde com a versão 2 (erro de versão)
    try testing.expectEqual(@as(u16, 1), pmpParse(0, &.{ 2, 0x80, 0, 1 }).?.result);
    // resposta a outro pedido: ignora
    try testing.expect(pmpParse(2, &.{ 0, 129, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }) == null);
}

test "pcp: pedido MAP e resposta (RFC 6887)" {
    const nonce = [12]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const req = pcpMapRequest(.{ 192, 168, 0, 10 }, nonce, true, 7777, 7777, 3600);
    try testing.expectEqual(@as(u8, 2), req[0]);
    try testing.expectEqual(@as(u8, 1), req[1]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 0, 10 }, req[8..24]);
    try testing.expectEqual(@as(u8, 17), req[36]);
    // resposta: a mesma estrutura, R=1, resultado 0, IP e porta de fora
    var resp = req;
    resp[1] = 0x81;
    resp[3] = 0;
    std.mem.writeInt(u32, resp[4..8], 1200, .big);
    std.mem.writeInt(u16, resp[42..44], 40000, .big);
    resp[56..60].* = .{ 203, 0, 113, 9 };
    const r = pcpParse(nonce, &resp).?;
    try testing.expectEqual(@as(u16, 0), r.result);
    try testing.expectEqual(@as(u16, 40000), r.ext_port);
    try testing.expectEqual(@as(u32, 1200), r.lifetime);
    try testing.expectEqualSlices(u8, &.{ 203, 0, 113, 9 }, &r.ext_ip);
    // nonce de outro pedido: não é a nossa
    var other = nonce;
    other[0] = 99;
    try testing.expect(pcpParse(other, &resp) == null);
}

test "natpmp: gateway padrão do /proc/net/route" {
    try testing.expectEqualSlices(u8, &.{ 192, 168, 0, 1 }, &parseRouteLine("eth0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n").?);
    try testing.expect(parseRouteLine("eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n") == null);
    try testing.expect(parseRouteLine("Iface\tDestination\tGateway") == null);
}
