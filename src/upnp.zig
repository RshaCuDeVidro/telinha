//! Abre a porta da sala no roteador (UPnP IGD) pra galera de fora entrar
//! direto, sem túnel: menos atraso (o túnel público fica em outro continente)
//! e sem o limite de banda dele. Boa parte dos roteadores de casa deixa (vem
//! ligado). Se a operadora usa CGNAT (o roteador recebe um IP privado ou da
//! faixa 100.64/10), a porta abre no roteador mas de fora não chega: aí o
//! caminho é o link público.
//!
//! O protocolo: um M-SEARCH em multicast (SSDP) acha o roteador, a descrição
//! dele (XML por HTTP) diz onde fica o serviço WANIPConnection, e três ações
//! SOAP fazem o resto: GetExternalIPAddress, AddPortMapping e
//! DeletePortMapping. O mapeamento vale 1 h e é renovado enquanto a sala está
//! aberta: se o app fechar sem conseguir apagar, ele some sozinho.
const std = @import("std");
const net = @import("net.zig");
const sync = @import("sync.zig");
const gpa = std.heap.c_allocator;

pub const ssdp_multicast = [4]u8{ 239, 255, 255, 250 };
pub const ssdp_port: u16 = 1900;
const lease_s = 3600;
const renew_ms = 25 * 60 * 1000;

pub const Error = error{ NoRouter, BadRouter, Cgnat, Refused, Network };

/// Onde fica o serviço do roteador que mexe nas portas.
pub const Router = struct {
    host: [64]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 80,
    control: [256]u8 = undefined, // caminho do controlURL
    control_len: usize = 0,
    service: [64]u8 = undefined, // urn:schemas-upnp-org:service:WANIPConnection:1 etc.
    service_len: usize = 0,
    local_ip: [4]u8 = .{ 0, 0, 0, 0 }, // nosso endereço na rede dele

    fn hostSlice(r: *const Router) []const u8 {
        return r.host[0..r.host_len];
    }
    fn controlSlice(r: *const Router) []const u8 {
        return r.control[0..r.control_len];
    }
    fn serviceSlice(r: *const Router) []const u8 {
        return r.service[0..r.service_len];
    }
};

/// Porta aberta.
pub const Mapping = struct {
    router: Router,
    ext_ip: [4]u8,
    ext_port: u16,
    int_port: u16,
    lease: u32, // 0 = permanente (roteador que só aceita assim)
};

// ------------------------------------------------------------ descoberta (SSDP)

/// Procura o roteador. `to`/`port`: pra onde mandar o M-SEARCH (o multicast de
/// verdade, ou um roteador de mentira nos testes).
pub fn discover(to: [4]u8, port: u16, timeout_ms: u32) Error!Router {
    const s = net.udpOpen() catch return error.Network;
    defer net.close(s);
    net.setRecvTimeout(s, 250);
    const targets = [_][]const u8{
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
    };
    var msg: [256]u8 = undefined;
    for (targets) |st| {
        const m = std.fmt.bufPrint(&msg, "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {s}\r\n\r\n", .{st}) catch unreachable;
        _ = net.udpSendTo(s, to, port, m);
    }
    // cada resposta traz o LOCATION da descrição; vale o primeiro que tiver o serviço
    var tried: [8][256]u8 = undefined;
    var tried_len: [8]usize = undefined;
    var n_tried: usize = 0;
    const t0 = sync.nowMs();
    var buf: [1500]u8 = undefined;
    while (sync.nowMs() - t0 < timeout_ms) {
        const n = net.udpRecv(s, &buf) orelse continue;
        const loc = header(buf[0..n], "location") orelse continue;
        const seen = for (tried[0..n_tried], tried_len[0..n_tried]) |*t, l| {
            if (std.mem.eql(u8, t[0..l], loc)) break true;
        } else false;
        if (seen or loc.len > 256 or n_tried == tried.len) continue;
        @memcpy(tried[n_tried][0..loc.len], loc);
        tried_len[n_tried] = loc.len;
        n_tried += 1;
        if (describe(loc)) |r| return r else |_| {}
    }
    return if (n_tried > 0) error.BadRouter else error.NoRouter;
}

/// Valor de um cabeçalho HTTP (sem diferenciar maiúsculas).
fn header(resp: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, resp, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

const Url = struct { host: []const u8, port: u16, path: []const u8 };

fn parseUrl(url: []const u8) ?Url {
    if (!std.ascii.startsWithIgnoreCase(url, "http://")) return null;
    const rest = url["http://".len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const hostport = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    if (std.mem.findScalarLast(u8, hostport, ':')) |colon| {
        const p = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return null;
        return .{ .host = hostport[0..colon], .port = p, .path = path };
    }
    return .{ .host = hostport, .port = 80, .path = path };
}

/// Lê a descrição do roteador e acha o serviço que mexe nas portas.
fn describe(location: []const u8) Error!Router {
    const url = parseUrl(location) orelse return error.BadRouter;
    var r: Router = .{};
    if (url.host.len > r.host.len) return error.BadRouter;
    @memcpy(r.host[0..url.host.len], url.host);
    r.host_len = url.host.len;
    r.port = url.port;
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(gpa);
    const status = try httpRequest(&r, "GET", url.path, null, null, &resp);
    if (status != 200) return error.BadRouter;
    const xml = body(resp.items);
    // preferência: IP v2, IP v1, PPP v1
    const wanted = [_][]const u8{
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    };
    for (wanted) |w| {
        var it = std.mem.splitSequence(u8, xml, "<service>");
        _ = it.next();
        while (it.next()) |svc| {
            const end = std.mem.find(u8, svc, "</service>") orelse svc.len;
            const block = svc[0..end];
            const st = tag(block, "serviceType") orelse continue;
            if (!std.mem.eql(u8, st, w)) continue;
            const ctl = tag(block, "controlURL") orelse continue;
            // controlURL pode ser absoluto ("http://…") ou só o caminho
            const path = if (parseUrl(ctl)) |u| u.path else ctl;
            if (path.len == 0 or path.len > r.control.len or w.len > r.service.len) continue;
            if (path[0] == '/') {
                @memcpy(r.control[0..path.len], path);
                r.control_len = path.len;
            } else {
                if (path.len + 1 > r.control.len) continue;
                r.control[0] = '/';
                @memcpy(r.control[1..][0..path.len], path);
                r.control_len = path.len + 1;
            }
            @memcpy(r.service[0..w.len], w);
            r.service_len = w.len;
            return r;
        }
    }
    return error.BadRouter;
}

/// Conteúdo de <nome>…</nome> (primeira ocorrência, sem prefixo de namespace).
fn tag(xml: []const u8, name: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const o = std.fmt.bufPrint(&open_buf, "<{s}>", .{name}) catch return null;
    const cl = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
    const a = std.mem.find(u8, xml, o) orelse return null;
    const start = a + o.len;
    const b = std.mem.find(u8, xml[start..], cl) orelse return null;
    return std.mem.trim(u8, xml[start..][0..b], " \t\r\n");
}

// ------------------------------------------------------------------- HTTP

fn body(resp: []const u8) []const u8 {
    const i = std.mem.find(u8, resp, "\r\n\r\n") orelse return "";
    return resp[i + 4 ..];
}

/// Requisição HTTP/1.1 simples (Connection: close). Também anota nosso IP na
/// rede do roteador. Retorna o código de status; a resposta inteira vai em
/// `out` (corpo "chunked" já juntado).
fn httpRequest(r: *Router, method: []const u8, path: []const u8, soap_action: ?[]const u8, payload: ?[]const u8, out: *std.ArrayList(u8)) Error!u16 {
    const s = net.connect(r.hostSlice(), r.port) catch return error.Network;
    defer net.close(s);
    net.setRecvTimeout(s, 3000);
    if (net.localIp4(s)) |ip| r.local_ip = ip;
    var head: [1024]u8 = undefined;
    const h = if (soap_action) |act|
        std.fmt.bufPrint(&head, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: text/xml; charset=\"utf-8\"\r\nSOAPAction: \"{s}#{s}\"\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ method, path, r.hostSlice(), r.port, r.serviceSlice(), act, payload.?.len }) catch return error.Network
    else
        std.fmt.bufPrint(&head, "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ method, path, r.hostSlice(), r.port }) catch return error.Network;
    net.sendAll(s, h) catch return error.Network;
    if (payload) |p| net.sendAll(s, p) catch return error.Network;
    var buf: [4096]u8 = undefined;
    while (out.items.len < 256 * 1024) {
        const n = net.recvSome(s, &buf) catch break; // fechou (ou estourou o tempo)
        out.appendSlice(gpa, buf[0..n]) catch return error.Network;
        // roteador que ignora o "Connection: close": com Content-Length dá pra parar antes
        const he = std.mem.find(u8, out.items, "\r\n\r\n") orelse continue;
        const cl = header(out.items[0..he], "content-length") orelse continue;
        const want = std.fmt.parseInt(usize, cl, 10) catch continue;
        if (out.items.len >= he + 4 + want) break;
    }
    const resp = out.items;
    if (!std.mem.startsWith(u8, resp, "HTTP/1.")) return error.BadRouter;
    const sp = std.mem.findScalar(u8, resp, ' ') orelse return error.BadRouter;
    if (resp.len < sp + 4) return error.BadRouter;
    const status = std.fmt.parseInt(u16, resp[sp + 1 ..][0..3], 10) catch return error.BadRouter;
    if (header(resp[0 .. std.mem.find(u8, resp, "\r\n\r\n") orelse resp.len], "transfer-encoding")) |te| {
        if (std.ascii.eqlIgnoreCase(te, "chunked")) dechunk(out);
    }
    return status;
}

/// Junta um corpo "Transfer-Encoding: chunked" (alguns roteadores mandam assim).
fn dechunk(out: *std.ArrayList(u8)) void {
    const hdr_end = (std.mem.find(u8, out.items, "\r\n\r\n") orelse return) + 4;
    var src = hdr_end;
    var dst = hdr_end;
    const d = out.items;
    while (src < d.len) {
        const le = std.mem.find(u8, d[src..], "\r\n") orelse break;
        const size_s = std.mem.trim(u8, d[src..][0..le], " ");
        const semi = std.mem.findScalar(u8, size_s, ';') orelse size_s.len;
        const size = std.fmt.parseInt(usize, size_s[0..semi], 16) catch break;
        src += le + 2;
        if (size == 0 or src + size > d.len) break;
        std.mem.copyForwards(u8, d[dst..][0..size], d[src..][0..size]);
        dst += size;
        src += size + 2;
    }
    out.shrinkRetainingCapacity(dst);
}

// ------------------------------------------------------------------- SOAP

/// Ação SOAP no serviço do roteador. Retorna o corpo da resposta (em `out`) e
/// o código de erro UPnP (0 = deu certo).
fn soap(r: *Router, action: []const u8, args: []const u8, out: *std.ArrayList(u8)) Error!u32 {
    var env: [2048]u8 = undefined;
    const e = std.fmt.bufPrint(&env, "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:{s} xmlns:u=\"{s}\">{s}</u:{s}></s:Body></s:Envelope>\r\n", .{ action, r.serviceSlice(), args, action }) catch return error.Network;
    var path: [256]u8 = undefined;
    const p = path[0..r.control_len];
    @memcpy(p, r.controlSlice());
    const status = try httpRequest(r, "POST", p, action, e, out);
    if (status == 200) return 0;
    // erro UPnP: <errorCode>718</errorCode> etc.
    const code = tag(body(out.items), "errorCode") orelse return error.Refused;
    return std.fmt.parseInt(u32, code, 10) catch error.Refused;
}

pub fn externalIp(r: *Router) Error![4]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (try soap(r, "GetExternalIPAddress", "", &out) != 0) return error.Refused;
    const ip = tag(body(out.items), "NewExternalIPAddress") orelse return error.BadRouter;
    return parseIp4(ip) orelse error.BadRouter;
}

pub fn parseIp4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&out) |*b| {
        const part = it.next() orelse return null;
        b.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (it.next() != null) return null;
    return out;
}

/// IP que não é alcançável da internet: o roteador está atrás de outro NAT
/// (CGNAT da operadora) ou ainda nem pegou endereço.
pub fn unreachableIp(ip: [4]u8) bool {
    return ip[0] == 0 or ip[0] == 10 or ip[0] == 127 or
        (ip[0] == 100 and ip[1] & 0xc0 == 64) or // 100.64.0.0/10 (CGNAT)
        (ip[0] == 172 and ip[1] & 0xf0 == 16) or
        (ip[0] == 192 and ip[1] == 168) or
        (ip[0] == 169 and ip[1] == 254);
}

fn addMapping(r: *Router, ext_port: u16, int_port: u16, lease: u32) Error!u32 {
    var args: [600]u8 = undefined;
    const a = std.fmt.bufPrint(&args, "<NewRemoteHost></NewRemoteHost><NewExternalPort>{d}</NewExternalPort><NewProtocol>TCP</NewProtocol><NewInternalPort>{d}</NewInternalPort><NewInternalClient>{d}.{d}.{d}.{d}</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>telinha</NewPortMappingDescription><NewLeaseDuration>{d}</NewLeaseDuration>", .{ ext_port, int_port, r.local_ip[0], r.local_ip[1], r.local_ip[2], r.local_ip[3], lease }) catch return error.Network;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    return soap(r, "AddPortMapping", a, &out);
}

/// Abre a porta `port` (TCP) apontando pra esta máquina. Se a porta de fora
/// estiver ocupada (outro aparelho), tenta as próximas.
pub fn open(router: Router, port: u16) Error!Mapping {
    var r = router;
    const ext_ip = try externalIp(&r);
    if (unreachableIp(ext_ip)) return error.Cgnat;
    var ext_port = port;
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        var lease: u32 = lease_s;
        var code = try addMapping(&r, ext_port, port, lease);
        if (code == 725) { // OnlyPermanentLeasesSupported
            lease = 0;
            code = try addMapping(&r, ext_port, port, lease);
        }
        switch (code) {
            0 => return .{ .router = r, .ext_ip = ext_ip, .ext_port = ext_port, .int_port = port, .lease = lease },
            718 => ext_port +%= 1, // ConflictInMappingEntry: outra máquina usa essa porta
            else => return error.Refused,
        }
    }
    return error.Refused;
}

/// Renova (mesmo pedido de novo, antes do prazo acabar).
pub fn renew(m: *Mapping) bool {
    return (addMapping(&m.router, m.ext_port, m.int_port, m.lease) catch return false) == 0;
}

pub fn close(m: *Mapping) void {
    var args: [256]u8 = undefined;
    const a = std.fmt.bufPrint(&args, "<NewRemoteHost></NewRemoteHost><NewExternalPort>{d}</NewExternalPort><NewProtocol>TCP</NewProtocol>", .{m.ext_port}) catch return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = soap(&m.router, "DeletePortMapping", a, &out) catch {};
}

/// Pra onde mandar a descoberta: o multicast do SSDP, ou o que estiver em
/// TELINHA_UPNP_SSDP=ip:porta (testes com um roteador de mentira, sem mexer
/// no roteador de verdade).
pub fn discoveryTarget() struct { [4]u8, u16 } {
    var to = ssdp_multicast;
    var to_port = ssdp_port;
    if (std.c.getenv("TELINHA_UPNP_SSDP")) |v| {
        const sv = std.mem.span(v);
        if (std.mem.findScalarLast(u8, sv, ':')) |colon| {
            if (parseIp4(sv[0..colon])) |ip| to = ip;
            to_port = std.fmt.parseInt(u16, sv[colon + 1 ..], 10) catch to_port;
        }
    }
    return .{ to, to_port };
}

// ------------------------------------------------- abrindo em segundo plano

/// Abre a porta numa thread (a descoberta leva uns segundos) e mantém aberta
/// (renova) até `stop`, que fecha.
pub const Mapper = struct {
    mutex: sync.Mutex = .{},
    refs: std.atomic.Value(u32) = .init(2), // interface + thread
    stopping: std.atomic.Value(bool) = .init(false),
    state: State = .working,
    err: [200]u8 = undefined,
    err_len: usize = 0,
    mapping: ?Mapping = null,
    port: u16,
    to: [4]u8,
    to_port: u16,

    pub const State = enum { working, ready, failed };
    pub const Status = struct { state: State, err: []const u8 };

    /// `to`/`to_port`: pra onde mandar a descoberta (o multicast; testes usam outro).
    pub fn start(port: u16, to: [4]u8, to_port: u16) !*Mapper {
        const m = try gpa.create(Mapper);
        m.* = .{ .port = port, .to = to, .to_port = to_port };
        sync.spawn(run, .{m}) catch {
            gpa.destroy(m);
            return error.ThreadFailed;
        };
        return m;
    }

    /// A interface larga o objeto; a thread fecha a porta e termina.
    pub fn stop(m: *Mapper) void {
        m.stopping.store(true, .release);
        m.release();
    }

    fn release(m: *Mapper) void {
        if (m.refs.fetchSub(1, .acq_rel) == 1) gpa.destroy(m);
    }

    pub fn status(m: *Mapper) Status {
        m.mutex.lock();
        defer m.mutex.unlock();
        return .{ .state = m.state, .err = m.err[0..m.err_len] };
    }

    /// "ip:porta" de fora (vazio se ainda não abriu).
    pub fn address(m: *Mapper, buf: []u8) []const u8 {
        m.mutex.lock();
        defer m.mutex.unlock();
        const mp = m.mapping orelse return buf[0..0];
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ mp.ext_ip[0], mp.ext_ip[1], mp.ext_ip[2], mp.ext_ip[3], mp.ext_port }) catch buf[0..0];
    }

    fn fail(m: *Mapper, msg: []const u8) void {
        m.mutex.lock();
        defer m.mutex.unlock();
        m.state = .failed;
        m.err_len = @min(msg.len, m.err.len);
        @memcpy(m.err[0..m.err_len], msg[0..m.err_len]);
    }

    fn run(m: *Mapper) void {
        defer m.release();
        const router = discover(m.to, m.to_port, 3000) catch |e| {
            m.fail(switch (e) {
                error.NoRouter => "Nenhum roteador respondeu ao UPnP (ele pode estar desligado nas configurações do roteador).",
                else => "O roteador respondeu, mas não deixa abrir portas por UPnP.",
            });
            return;
        };
        var mp = open(router, m.port) catch |e| {
            m.fail(switch (e) {
                error.Cgnat => "Sua operadora usa CGNAT (o roteador não tem IP próprio na internet): porta aberta lá não chega aqui. Use o link público.",
                error.Refused => "O roteador recusou abrir a porta.",
                else => "O roteador não respondeu direito.",
            });
            return;
        };
        m.mutex.lock();
        m.mapping = mp;
        m.state = .ready;
        m.mutex.unlock();
        // mantém aberta (renova antes do prazo) até largarem
        var since = sync.nowMs();
        while (!m.stopping.load(.acquire)) {
            sync.sleepMs(200);
            if (mp.lease != 0 and sync.nowMs() - since >= renew_ms) {
                _ = renew(&mp);
                since = sync.nowMs();
            }
        }
        close(&mp);
    }
};

test "upnp: IP de fora que não é da internet (CGNAT, privado)" {
    try std.testing.expect(unreachableIp(.{ 100, 64, 1, 2 }));
    try std.testing.expect(unreachableIp(.{ 100, 127, 255, 255 }));
    try std.testing.expect(!unreachableIp(.{ 100, 128, 0, 1 }));
    try std.testing.expect(unreachableIp(.{ 192, 168, 0, 10 }));
    try std.testing.expect(unreachableIp(.{ 172, 20, 0, 1 }));
    try std.testing.expect(!unreachableIp(.{ 172, 32, 0, 1 }));
    try std.testing.expect(!unreachableIp(.{ 203, 0, 113, 7 }));
}
