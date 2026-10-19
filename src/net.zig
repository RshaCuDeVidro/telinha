//! Sockets TCP (POSIX no Linux, Winsock no Windows).
const std = @import("std");
const sync = @import("sync.zig");
const is_windows = sync.is_windows;

const c = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("winsock2.h");
    @cInclude("ws2tcpip.h");
}) else @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/types.h");
    @cInclude("sys/time.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

/// sockaddr_in6 com layout fixo (no Windows o header tem bitfields que o Zig não traduz).
const SockAddrIn6 = extern struct {
    family: u16,
    port: u16,
    flowinfo: u32 = 0,
    addr: [16]u8 = [_]u8{0} ** 16,
    scope_id: u32 = 0,
};

pub const Socket = if (is_windows) c.SOCKET else c_int;
const invalid: Socket = if (is_windows) c.INVALID_SOCKET else -1;

pub const Error = error{ ConnectionLost, ConnectFailed, ConnectionRefused, UnknownHost, ListenFailed, AcceptFailed };

pub fn init() void {
    if (is_windows) {
        var wsa: c.WSADATA = undefined;
        _ = c.WSAStartup(0x0202, &wsa);
    }
}

fn setOpt(s: Socket, level: c_int, name: c_int, value: c_int) void {
    var v = value;
    _ = c.setsockopt(s, level, name, @ptrCast(&v), @sizeOf(c_int));
}

fn tune(s: Socket) void {
    setOpt(s, c.IPPROTO_TCP, c.TCP_NODELAY, 1);
    setOpt(s, c.SOL_SOCKET, c.SO_KEEPALIVE, 1);
    // Linux: o kernel segura no máximo 32 KB ainda não enviados; o resto
    // espera na nossa fila, onde dá pra descartar quadro velho em vez de ficar
    // escondido no kernel. O que já está na rede (janela do TCP) continua com
    // ajuste automático, então a vazão em link longo não cai. No Windows o
    // buffer de envio dinâmico (sem SO_SNDBUF fixo) já segue o RTT da conexão.
    if (!is_windows) setOpt(s, c.IPPROTO_TCP, c.TCP_NOTSENT_LOWAT, 32 * 1024);
}

/// Escuta em todas as interfaces (IPv6 + IPv4 quando der).
pub fn listen(port: u16) Error!Socket {
    // tenta dual-stack
    const s6 = c.socket(c.AF_INET6, c.SOCK_STREAM, c.IPPROTO_TCP);
    if (s6 != invalid) {
        setOpt(s6, c.SOL_SOCKET, c.SO_REUSEADDR, 1);
        setOpt(s6, c.IPPROTO_IPV6, c.IPV6_V6ONLY, 0);
        var a6: SockAddrIn6 = .{ .family = c.AF_INET6, .port = std.mem.nativeToBig(u16, port) };
        if (c.bind(s6, @ptrCast(&a6), @sizeOf(SockAddrIn6)) == 0 and c.listen(s6, 64) == 0) return s6;
        close(s6);
    }
    const s4 = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
    if (s4 == invalid) return error.ListenFailed;
    setOpt(s4, c.SOL_SOCKET, c.SO_REUSEADDR, 1);
    var a4 = std.mem.zeroes(c.struct_sockaddr_in);
    a4.sin_family = c.AF_INET;
    a4.sin_port = std.mem.nativeToBig(u16, port);
    if (c.bind(s4, @ptrCast(&a4), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(s4, 64) != 0) {
        close(s4);
        return error.ListenFailed;
    }
    return s4;
}

pub fn accept(ls: Socket) Error!Socket {
    const s = c.accept(ls, null, null);
    if (s == invalid) return error.AcceptFailed;
    tune(s);
    return s;
}

pub fn connect(host: []const u8, port: u16) Error!Socket {
    var host_z: [256]u8 = undefined;
    if (host.len >= host_z.len) return error.UnknownHost;
    @memcpy(host_z[0..host.len], host);
    host_z[host.len] = 0;
    var port_z: [8]u8 = undefined;
    const port_s = std.fmt.bufPrintZ(&port_z, "{d}", .{port}) catch unreachable;

    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;
    var res: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(&host_z, port_s.ptr, &hints, &res) != 0) return error.UnknownHost;
    defer c.freeaddrinfo(res);

    var refused = false;
    var it = res;
    while (it) |ai| : (it = ai.ai_next) {
        const s = c.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
        if (s == invalid) continue;
        if (c.connect(s, ai.ai_addr, @intCast(ai.ai_addrlen)) == 0) {
            tune(s);
            return s;
        }
        if (is_windows) {
            if (c.WSAGetLastError() == c.WSAECONNREFUSED) refused = true;
        } else {
            if (std.c._errno().* == @intFromEnum(std.c.E.CONNREFUSED)) refused = true;
        }
        close(s);
    }
    return if (refused) error.ConnectionRefused else error.ConnectFailed;
}

pub fn sendAll(s: Socket, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const chunk: c_int = @intCast(@min(data.len - off, 1 << 20));
        const n = if (is_windows)
            c.send(s, data[off..].ptr, chunk, 0)
        else
            c.send(s, data[off..].ptr, @intCast(chunk), c.MSG_NOSIGNAL);
        if (n <= 0) return error.ConnectionLost;
        off += @intCast(n);
    }
}

pub fn recvAll(s: Socket, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const chunk: c_int = @intCast(@min(buf.len - off, 1 << 20));
        const n = if (is_windows) c.recv(s, buf[off..].ptr, chunk, 0) else c.recv(s, buf[off..].ptr, @intCast(chunk), 0);
        if (n <= 0) return error.ConnectionLost;
        off += @intCast(n);
    }
}

/// Lê o que já tiver chegado (pelo menos 1 byte).
pub fn recvSome(s: Socket, buf: []u8) Error!usize {
    const chunk: c_int = @intCast(@min(buf.len, 1 << 20));
    const n = if (is_windows) c.recv(s, buf.ptr, chunk, 0) else c.recv(s, buf.ptr, @intCast(chunk), 0);
    if (n <= 0) return error.ConnectionLost;
    return @intCast(n);
}

/// Limita o buffer de recebimento (usado pra simular link lento nos testes).
pub fn setRecvBuffer(s: Socket, bytes: u32) void {
    setOpt(s, c.SOL_SOCKET, c.SO_RCVBUF, @intCast(bytes));
}

/// Tempo máximo esperando dados (0 = sem limite).
pub fn setRecvTimeout(s: Socket, ms: u32) void {
    if (is_windows) {
        var v: u32 = ms;
        _ = c.setsockopt(s, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&v), @sizeOf(u32));
    } else {
        var tv: c.struct_timeval = .{ .tv_sec = @intCast(ms / 1000), .tv_usec = @intCast(@as(u64, ms % 1000) * 1000) };
        _ = c.setsockopt(s, c.SOL_SOCKET, c.SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(c.struct_timeval));
    }
}

/// Derruba a conexão (destrava threads bloqueadas em recv/send).
pub fn shutdown(s: Socket) void {
    _ = c.shutdown(s, if (is_windows) c.SD_BOTH else c.SHUT_RDWR);
}

/// Fecha só o envio: o que já está na fila sai e depois vai o FIN. O outro
/// lado lê tudo e fecha. (Um close com dados chegando manda RST, e o RST
/// joga fora o que ainda não tinha saído, tipo o aviso de "sala fechada".)
pub fn shutdownWrite(s: Socket) void {
    _ = c.shutdown(s, if (is_windows) c.SD_SEND else c.SHUT_WR);
}

pub fn close(s: Socket) void {
    if (is_windows) _ = c.closesocket(s) else _ = c.close(s);
}

// ------------------------------------------------------------ UDP (rede local)

/// Socket UDP IPv4 (descoberta do roteador por SSDP). Multicast com TTL 2:
/// não passa do roteador.
pub fn udpOpen() Error!Socket {
    const s = c.socket(c.AF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
    if (s == invalid) return error.ConnectFailed;
    setOpt(s, c.IPPROTO_IP, c.IP_MULTICAST_TTL, 2);
    return s;
}

fn sockaddr4(ip: [4]u8, port: u16) c.struct_sockaddr_in {
    var a = std.mem.zeroes(c.struct_sockaddr_in);
    a.sin_family = c.AF_INET;
    a.sin_port = std.mem.nativeToBig(u16, port);
    @memcpy(std.mem.asBytes(&a.sin_addr)[0..4], &ip);
    return a;
}

pub fn udpSendTo(s: Socket, ip: [4]u8, port: u16, data: []const u8) bool {
    const a = sockaddr4(ip, port);
    const n = if (is_windows)
        c.sendto(s, data.ptr, @intCast(data.len), 0, @ptrCast(&a), @sizeOf(c.struct_sockaddr_in))
    else
        c.sendto(s, data.ptr, data.len, 0, @ptrCast(&a), @sizeOf(c.struct_sockaddr_in));
    return n == @as(@TypeOf(n), @intCast(data.len));
}

/// Um datagrama (espera até o tempo de `setRecvTimeout`); null se nada chegou.
pub fn udpRecv(s: Socket, buf: []u8) ?usize {
    const n = if (is_windows)
        c.recvfrom(s, buf.ptr, @intCast(buf.len), 0, null, null)
    else
        c.recvfrom(s, buf.ptr, buf.len, 0, null, null);
    if (n <= 0) return null;
    return @intCast(n);
}

/// Pra testes: socket UDP escutando em 127.0.0.1:porta.
pub fn udpBindLocal(port: u16) Error!Socket {
    const s = c.socket(c.AF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
    if (s == invalid) return error.ListenFailed;
    const a = sockaddr4(.{ 127, 0, 0, 1 }, port);
    if (c.bind(s, @ptrCast(&a), @sizeOf(c.struct_sockaddr_in)) != 0) {
        close(s);
        return error.ListenFailed;
    }
    return s;
}

/// Responde pra quem mandou o último datagrama (testes: o roteador de mentira).
pub fn udpRecvReply(s: Socket, buf: []u8, reply: []const u8) ?usize {
    var from: c.struct_sockaddr_in = undefined;
    var len: if (is_windows) c_int else c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    const n = if (is_windows)
        c.recvfrom(s, buf.ptr, @intCast(buf.len), 0, @ptrCast(&from), &len)
    else
        c.recvfrom(s, buf.ptr, buf.len, 0, @ptrCast(&from), &len);
    if (n <= 0) return null;
    if (reply.len > 0) {
        _ = if (is_windows)
            c.sendto(s, reply.ptr, @intCast(reply.len), 0, @ptrCast(&from), len)
        else
            c.sendto(s, reply.ptr, reply.len, 0, @ptrCast(&from), len);
    }
    return @intCast(n);
}

/// IPv4 local de um socket conectado (o endereço da máquina na rede do roteador).
pub fn localIp4(s: Socket) ?[4]u8 {
    var st: [128]u8 align(8) = undefined;
    var len: if (is_windows) c_int else c.socklen_t = st.len;
    if (c.getsockname(s, @ptrCast(&st), &len) != 0) return null;
    const family = std.mem.readInt(u16, st[0..2], .little);
    if (family == c.AF_INET) {
        const a: *const c.struct_sockaddr_in = @ptrCast(&st);
        return std.mem.asBytes(&a.sin_addr)[0..4].*;
    }
    if (family == c.AF_INET6) {
        // IPv4 mapeado em IPv6 (::ffff:a.b.c.d)
        const a6: *const SockAddrIn6 = @ptrCast(&st);
        if (std.mem.eql(u8, a6.addr[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) return a6.addr[12..16].*;
    }
    return null;
}

// ------------------------------------------------------------ rota

pub const Route = enum { unknown, local, lan, internet4, internet6 };

/// Endereço (IPv4 como 4 bytes, IPv6 como 16; IPv4 mapeado em IPv6 vira IPv4).
const Addr = struct {
    bytes: [16]u8 = undefined,
    len: usize = 0,

    fn slice(a: *const Addr) []const u8 {
        return a.bytes[0..a.len];
    }
};

fn sockAddr(st: *align(8) const [128]u8) Addr {
    var out: Addr = .{};
    const family = std.mem.readInt(u16, st[0..2], .little);
    if (family == c.AF_INET) {
        const a: *const c.struct_sockaddr_in = @ptrCast(st);
        @memcpy(out.bytes[0..4], std.mem.asBytes(&a.sin_addr)[0..4]);
        out.len = 4;
    } else if (family == c.AF_INET6) {
        const a6: *const SockAddrIn6 = @ptrCast(st);
        if (std.mem.eql(u8, a6.addr[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
            @memcpy(out.bytes[0..4], a6.addr[12..16]);
            out.len = 4;
        } else {
            out.bytes = a6.addr;
            out.len = 16;
        }
    }
    return out;
}

fn peerAndLocal(s: Socket) ?struct { Addr, Addr } {
    var st: [128]u8 align(8) = undefined;
    var len: if (is_windows) c_int else c.socklen_t = st.len;
    if (c.getpeername(s, @ptrCast(&st), &len) != 0) return null;
    const peer = sockAddr(&st);
    len = st.len;
    if (c.getsockname(s, @ptrCast(&st), &len) != 0) return null;
    return .{ peer, sockAddr(&st) };
}

/// Endereço de quem está do outro lado (4 bytes IPv4, 16 IPv6; vazio se não der).
pub fn peerAddress(s: Socket, out: *[16]u8) []u8 {
    const peer, _ = peerAndLocal(s) orelse return out[0..0];
    @memcpy(out[0..peer.len], peer.slice());
    return out[0..peer.len];
}

/// Por onde veio uma conexão aceita: dessa máquina, da rede local, ou da internet.
pub fn peerRoute(s: Socket) Route {
    const peer, const local = peerAndLocal(s) orelse return .unknown;
    return classify(peer.slice(), local.slice());
}

pub fn classify(peer: []const u8, local: []const u8) Route {
    if (peer.len == 0) return .unknown;
    if (std.mem.eql(u8, peer, local)) return .local; // conectou no próprio IP
    if (peer.len == 4) {
        const a = peer;
        if (a[0] == 127) return .local;
        if (a[0] == 10 or (a[0] == 172 and a[1] & 0xF0 == 16) or (a[0] == 192 and a[1] == 168) or
            (a[0] == 169 and a[1] == 254) or (a[0] == 100 and a[1] & 0xC0 == 64)) return .lan; // 100.64/10: CGNAT e Tailscale
        return .internet4;
    }
    const loopback = [_]u8{0} ** 15 ++ [_]u8{1};
    if (std.mem.eql(u8, peer, &loopback)) return .local;
    if (peer[0] == 0xfe and peer[1] & 0xC0 == 0x80) return .lan; // fe80::/10
    if (peer[0] & 0xFE == 0xfc) return .lan; // fc00::/7 (ULA, Tailscale)
    return .internet6;
}
