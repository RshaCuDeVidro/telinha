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

pub fn close(s: Socket) void {
    if (is_windows) _ = c.closesocket(s) else _ = c.close(s);
}
