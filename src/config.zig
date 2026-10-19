//! Preferências salvas entre execuções.
//! Linux: ~/.config/telinha/config.ini   Windows: %APPDATA%\telinha\config.ini
const std = @import("std");
const sync = @import("sync.zig");
const is_windows = sync.is_windows;

const c = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("stdio.h");
}) else @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
});

pub const Config = struct {
    name: [33]u8 = zstr("", 33),
    join_addr: [256]u8 = zstr("", 256),
    join_pass: [129]u8 = zstr("", 129),
    room_name: [65]u8 = zstr("", 65),
    host_port: i32 = 7777,
    host_pass: [129]u8 = zstr("", 129),
    fps: i32 = 30,
    quality: i32 = 60,
    mode: i32 = 0, // 0 tela/texto, 1 jogo/vídeo
    resolution: i32 = 0, // 0 original, 1 1080p, 2 720p, 3 480p
    cursor: bool = true,
    show_chat: bool = true,
    stats_always: bool = false,
    hardware: bool = true, // encoder na placa de vídeo (NVENC) quando der
    audio: bool = true, // compartilhar o som do computador junto
    admin_token: [65]u8 = zstr("", 65), // pra entrar como admin num servidor dedicado
    public_addr: [256]u8 = zstr("", 256), // endereço do túnel (pra montar o convite)
    tunnel_host: [128]u8 = zstr("bore.pub", 128), // servidor do link público (protocolo do bore)
};

fn zstr(comptime s: []const u8, comptime n: usize) [n]u8 {
    var out = [_]u8{0} ** n;
    @memcpy(out[0..s.len], s);
    return out;
}

pub fn setStr(buf: []u8, s: []const u8) void {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

pub fn getStr(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

fn openFile(write: bool) ?*c.FILE {
    if (is_windows) {
        var dir: [600]u16 = undefined;
        const n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"), &dir, 500);
        if (n == 0 or n >= 500) return null;
        const sub = std.unicode.utf8ToUtf16LeStringLiteral("\\telinha");
        @memcpy(dir[n..][0..sub.len], sub);
        dir[n + sub.len] = 0;
        _ = c.CreateDirectoryW(&dir, null);
        const file = std.unicode.utf8ToUtf16LeStringLiteral("\\config.ini");
        @memcpy(dir[n + sub.len ..][0..file.len], file);
        dir[n + sub.len + file.len] = 0;
        const mode = if (write) std.unicode.utf8ToUtf16LeStringLiteral("wb") else std.unicode.utf8ToUtf16LeStringLiteral("rb");
        return c._wfopen(&dir, mode);
    } else {
        var path: [512]u8 = undefined;
        const xdg = c.getenv("XDG_CONFIG_HOME");
        const base = if (xdg != null and xdg[0] != 0)
            std.fmt.bufPrintZ(&path, "{s}/telinha", .{std.mem.span(xdg)}) catch return null
        else
            std.fmt.bufPrintZ(&path, "{s}/.config/telinha", .{std.mem.span(c.getenv("HOME") orelse return null)}) catch return null;
        _ = c.mkdir(base.ptr, 0o700);
        var full: [600]u8 = undefined;
        const p = std.fmt.bufPrintZ(&full, "{s}/config.ini", .{base}) catch return null;
        return c.fopen(p.ptr, if (write) "wb" else "rb");
    }
}

pub fn load() Config {
    var cfg: Config = .{};
    const f = openFile(false) orelse return cfg;
    defer _ = c.fclose(f);
    var line: [512]u8 = undefined;
    while (c.fgets(&line, line.len, f) != null) {
        const l = std.mem.trimEnd(u8, std.mem.sliceTo(&line, 0), "\r\n");
        const eq = std.mem.findScalar(u8, l, '=') orelse continue;
        const k = l[0..eq];
        const v = l[eq + 1 ..];
        const int = std.fmt.parseInt(i32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "name")) setStr(&cfg.name, v) else if (std.mem.eql(u8, k, "join_addr")) setStr(&cfg.join_addr, v) else if (std.mem.eql(u8, k, "join_pass")) setStr(&cfg.join_pass, v) else if (std.mem.eql(u8, k, "room_name")) setStr(&cfg.room_name, v) else if (std.mem.eql(u8, k, "host_pass")) setStr(&cfg.host_pass, v) else if (std.mem.eql(u8, k, "host_port")) cfg.host_port = std.math.clamp(int, 1, 65535) else if (std.mem.eql(u8, k, "fps")) cfg.fps = std.math.clamp(int, 1, 60) else if (std.mem.eql(u8, k, "quality")) cfg.quality = std.math.clamp(int, 20, 100) else if (std.mem.eql(u8, k, "mode")) cfg.mode = std.math.clamp(int, 0, 1) else if (std.mem.eql(u8, k, "stats_always")) cfg.stats_always = int != 0 else if (std.mem.eql(u8, k, "hardware")) cfg.hardware = int != 0 else if (std.mem.eql(u8, k, "admin_token")) setStr(&cfg.admin_token, v) else if (std.mem.eql(u8, k, "public_addr")) setStr(&cfg.public_addr, v) else if (std.mem.eql(u8, k, "resolution")) cfg.resolution = std.math.clamp(int, 0, 3) else if (std.mem.eql(u8, k, "cursor")) cfg.cursor = int != 0 else if (std.mem.eql(u8, k, "show_chat")) cfg.show_chat = int != 0 else if (std.mem.eql(u8, k, "audio")) cfg.audio = int != 0 else if (std.mem.eql(u8, k, "tunnel_host")) setStr(&cfg.tunnel_host, v);
    }
    return cfg;
}

pub fn save(cfg: *const Config) void {
    const f = openFile(true) orelse return;
    defer _ = c.fclose(f);
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf,
        \\name={s}
        \\join_addr={s}
        \\join_pass={s}
        \\room_name={s}
        \\host_pass={s}
        \\host_port={d}
        \\fps={d}
        \\quality={d}
        \\resolution={d}
        \\cursor={d}
        \\show_chat={d}
        \\mode={d}
        \\stats_always={d}
        \\hardware={d}
        \\audio={d}
        \\admin_token={s}
        \\public_addr={s}
        \\tunnel_host={s}
        \\
    , .{
        getStr(&cfg.name),              getStr(&cfg.join_addr),     getStr(&cfg.join_pass),      getStr(&cfg.room_name),
        getStr(&cfg.host_pass),         cfg.host_port,              cfg.fps,                     cfg.quality,
        cfg.resolution,                 @intFromBool(cfg.cursor),   @intFromBool(cfg.show_chat), cfg.mode,
        @intFromBool(cfg.stats_always), @intFromBool(cfg.hardware), @intFromBool(cfg.audio),     getStr(&cfg.admin_token),
        getStr(&cfg.public_addr),       getStr(&cfg.tunnel_host),
    }) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}
