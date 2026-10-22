//! Assistir pelo navegador: a porta web do servidor dedicado. Serve a página
//! (src/web/, embutida) e o WebSocket por onde ela fala o mesmo protocolo da
//! sala (sem cifrar aqui: quem cifra é o HTTPS na frente, o túnel da
//! Cloudflare ou outro proxy). Quem assiste pelo navegador vira um membro
//! normal da sala: recebe os mesmos quadros já codificados (nada é
//! recodificado; quem transmite não gasta nada a mais) e manda as mesmas
//! confirmações, então o controle de atraso vale pra ele também.
//!
//! Escuta só em 127.0.0.1: sem HTTPS o navegador nem decodifica vídeo
//! (WebCodecs exige página segura), então a porta não serve pra nada exposta.
const std = @import("std");
const net = @import("net.zig");
const sync = @import("sync.zig");
const proto = @import("proto.zig");
const gpa = std.heap.c_allocator;

const page_html = @embedFile("web/index.html");
const page_js = @embedFile("web/app.js");
const page_css = @embedFile("web/app.css");
const page_worklet = @embedFile("web/audio-worklet.js");

/// Quem recebe a conexão WebSocket pronta (o servidor da sala).
pub const Adopt = *const fn (ctx: *anyopaque, sock: net.Socket, ip: []const u8) void;

pub const Listener = struct {
    sock: net.Socket,
    ctx: *anyopaque,
    adopt: Adopt,
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn start(port: u16, ctx: *anyopaque, adopt: Adopt) !*Listener {
        const s = try net.listenLocal(port);
        const l = try gpa.create(Listener);
        l.* = .{ .sock = s, .ctx = ctx, .adopt = adopt };
        sync.spawn(acceptLoop, .{l}) catch |e| {
            net.close(s);
            gpa.destroy(l);
            return e;
        };
        return l;
    }

    /// Para de aceitar (a thread larga o objeto sozinha).
    pub fn stop(l: *Listener) void {
        l.stopped.store(true, .release);
        net.shutdown(l.sock);
        net.close(l.sock);
    }
};

fn acceptLoop(l: *Listener) void {
    sync.nameThread("web-aceita");
    defer gpa.destroy(l);
    while (!l.stopped.load(.acquire)) {
        const c = net.accept(l.sock) catch {
            if (l.stopped.load(.acquire)) return;
            sync.sleepMs(20);
            continue;
        };
        sync.spawn(serveOne, .{ l.ctx, l.adopt, c }) catch net.close(c);
    }
}

/// Uma conexão HTTP: a página, ou o WebSocket (que vira membro da sala).
fn serveOne(ctx: *anyopaque, adopt: Adopt, c: net.Socket) void {
    sync.nameThread("web");
    net.setRecvTimeout(c, 10_000);
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    // cabeçalhos até a linha vazia (no máximo 8 KB)
    const end = while (n < buf.len) {
        const got = net.recvSome(c, buf[n..]) catch break null;
        if (got == 0) break null;
        n += got;
        if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n")) |e| break e;
    } else null;
    const head_end = end orelse return net.close(c);
    const req = parseRequest(buf[0..head_end]) orelse return reply(c, "400 Bad Request", "text/plain", "pedido estranho");
    if (req.upgrade) {
        const key = req.ws_key orelse return reply(c, "400 Bad Request", "text/plain", "sem Sec-WebSocket-Key");
        var accept: [28]u8 = undefined;
        acceptKey(key, &accept);
        var rb: [200]u8 = undefined;
        const resp = std.fmt.bufPrint(&rb, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return net.close(c);
        net.sendAll(c, resp) catch return net.close(c);
        net.setRecvTimeout(c, 0);
        // o IP de verdade de quem está do outro lado (o proxy põe no cabeçalho)
        var ipb: [16]u8 = undefined;
        const ip = if (req.client_ip) |s| net.parseIp(s, &ipb) else net.peerAddress(c, &ipb);
        adopt(ctx, c, ip);
        return;
    }
    if (std.mem.eql(u8, req.path, "/") or std.mem.eql(u8, req.path, "/index.html")) return reply(c, "200 OK", "text/html; charset=utf-8", page_html);
    if (std.mem.eql(u8, req.path, "/app.js")) return reply(c, "200 OK", "text/javascript; charset=utf-8", page_js);
    if (std.mem.eql(u8, req.path, "/app.css")) return reply(c, "200 OK", "text/css; charset=utf-8", page_css);
    if (std.mem.eql(u8, req.path, "/audio-worklet.js")) return reply(c, "200 OK", "text/javascript; charset=utf-8", page_worklet);
    return reply(c, "404 Not Found", "text/plain", "não tem isso aqui");
}

fn reply(c: net.Socket, status: []const u8, ctype: []const u8, body: []const u8) void {
    defer net.close(c);
    var hb: [600]u8 = undefined;
    // a página só fala com o próprio servidor (nada de terceiros)
    const head = std.fmt.bufPrint(&hb, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n", .{ status, ctype, body.len }) catch return;
    net.sendAll(c, head) catch return;
    net.sendAll(c, body) catch return;
}

pub const Request = struct {
    path: []const u8,
    upgrade: bool = false,
    ws_key: ?[]const u8 = null,
    client_ip: ?[]const u8 = null,
};

pub fn parseRequest(head: []const u8) ?Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const first = lines.next() orelse return null;
    var parts = std.mem.tokenizeScalar(u8, first, ' ');
    const method = parts.next() orelse return null;
    if (!std.mem.eql(u8, method, "GET")) return null;
    var path = parts.next() orelse return null;
    if (std.mem.indexOfAny(u8, path, "?#")) |q| path = path[0..q];
    var r: Request = .{ .path = path };
    var upgrade_ws = false;
    var conn_upgrade = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const k = std.mem.trim(u8, line[0..colon], " ");
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(k, "upgrade")) upgrade_ws = std.ascii.eqlIgnoreCase(v, "websocket");
        if (std.ascii.eqlIgnoreCase(k, "connection")) conn_upgrade = std.ascii.indexOfIgnoreCase(v, "upgrade") != null;
        if (std.ascii.eqlIgnoreCase(k, "sec-websocket-key")) r.ws_key = v;
        // o IP de quem está do outro lado do proxy (Cloudflare; ou o padrão)
        if (std.ascii.eqlIgnoreCase(k, "cf-connecting-ip")) r.client_ip = v;
        if (r.client_ip == null and std.ascii.eqlIgnoreCase(k, "x-forwarded-for")) r.client_ip = std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ',') orelse v.len], " ");
    }
    r.upgrade = upgrade_ws and conn_upgrade and std.mem.eql(u8, path, "/ws");
    return r;
}

/// Sec-WebSocket-Accept = base64(SHA-1(chave + o GUID do RFC 6455)).
pub fn acceptKey(key: []const u8, out: *[28]u8) void {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var d: [20]u8 = undefined;
    h.final(&d);
    _ = std.base64.standard.Encoder.encode(out, &d);
}

/// O endereço https://...trycloudflare.com numa linha do cloudflared (o túnel rápido).
pub fn findTryCloudflare(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, "https://") orelse return null;
    var end = at + 8;
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '-' or line[end] == '.')) end += 1;
    const url = line[at..end];
    if (!std.mem.endsWith(u8, url, ".trycloudflare.com") or std.mem.startsWith(u8, url, "https://api.")) return null;
    return url;
}

// ------------------------------------------------- quadros do navegador

pub const max_message = 1024 * 1024;

/// Lê a próxima mensagem (binária ou texto) do navegador, juntando pedaços.
/// null = quadro de controle (ping/pong), ignorado. Erro = fechou.
pub fn readMessage(c: net.Socket, out: *std.ArrayList(u8)) !?[]const u8 {
    out.clearRetainingCapacity();
    while (true) {
        var h: [2]u8 = undefined;
        try net.recvAll(c, &h);
        const fin = h[0] & 0x80 != 0;
        const op = h[0] & 0x0F;
        const masked = h[1] & 0x80 != 0;
        var len: u64 = h[1] & 0x7F;
        if (len == 126) {
            var b: [2]u8 = undefined;
            try net.recvAll(c, &b);
            len = std.mem.readInt(u16, &b, .big);
        } else if (len == 127) {
            var b: [8]u8 = undefined;
            try net.recvAll(c, &b);
            len = std.mem.readInt(u64, &b, .big);
        }
        if (!masked) return error.Protocol; // do navegador sempre vem com máscara
        if (len > max_message or out.items.len + len > max_message) return error.TooBig;
        var mask: [4]u8 = undefined;
        try net.recvAll(c, &mask);
        const start = out.items.len;
        try out.resize(gpa, start + @as(usize, @intCast(len)));
        const body = out.items[start..];
        try net.recvAll(c, body);
        for (body, 0..) |*b, i| b.* ^= mask[i % 4];
        switch (op) {
            0x8 => return error.Closed,
            0x9, 0xA => {
                // ping/pong (o navegador quase não manda): ignora
                out.shrinkRetainingCapacity(start);
                if (start == 0) return null;
                continue;
            },
            else => {},
        }
        if (fin) return out.items;
    }
}

const testing = std.testing;

test "web: pedido HTTP (página, WebSocket, IP do proxy)" {
    const r = parseRequest("GET /ws HTTP/1.1\r\nHost: x.trycloudflare.com\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nCF-Connecting-IP: 203.0.113.9\r\n").?;
    try testing.expect(r.upgrade);
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", r.ws_key.?);
    try testing.expectEqualStrings("203.0.113.9", r.client_ip.?);
    const p = parseRequest("GET /app.js?v=2 HTTP/1.1\r\nHost: x\r\n").?;
    try testing.expectEqualStrings("/app.js", p.path);
    try testing.expect(!p.upgrade);
    try testing.expect(parseRequest("POST / HTTP/1.1\r\n") == null);
    // WebSocket fora do /ws não vale
    try testing.expect(!parseRequest("GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: a\r\n").?.upgrade);
}

test "web: Sec-WebSocket-Accept (o exemplo do RFC 6455)" {
    var out: [28]u8 = undefined;
    acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "web: o endereço do túnel rápido no que o cloudflared imprime" {
    try testing.expectEqualStrings("https://pale-tree-river-moon.trycloudflare.com", findTryCloudflare("2026-10-22T03:00:00Z INF |  https://pale-tree-river-moon.trycloudflare.com                                     |").?);
    try testing.expect(findTryCloudflare("2026-10-22T03:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...") == null);
    try testing.expect(findTryCloudflare("ERR failed to request quick Tunnel: Post https://api.trycloudflare.com/tunnel") == null);
    try testing.expect(findTryCloudflare("https://evil.example.com/x.trycloudflare.com") == null);
}
