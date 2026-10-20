//! Relatório de travamento: liga os tratadores (c/crash.c) logo ao abrir e,
//! na próxima abertura, diz se tem relatório pra mandar (ver debuglog.send).
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("crash.h");
    @cInclude("debugsys.h");
});
const sync = @import("sync.zig");
const config = @import("config.zig");
const proto = @import("proto.zig");
const mp4 = @import("mp4.zig");
const cio = mp4.cio;

pub const file_name = "telinha-travou.txt";
const old_name = "telinha-travou-antigo.txt";

/// Caminho do relatório (UTF-8).
pub fn path(buf: []u8) ?[:0]const u8 {
    return inConfigDir(buf, file_name);
}

fn inConfigDir(buf: []u8, name: []const u8) ?[:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = config.dirPath(&dir_buf) orelse return null;
    const sep = if (sync.is_windows) "\\" else "/";
    return std.fmt.bufPrintZ(buf, "{s}" ++ sep ++ "{s}", .{ dir, name }) catch null;
}

/// Liga os tratadores (antes de qualquer outra coisa abrir).
pub fn install() void {
    var pb: [600]u8 = undefined;
    const p = path(&pb) orelse return;
    var info: [1536]u8 = undefined;
    var sys: [1024]u8 = [_]u8{0} ** 1024;
    if (sync.is_windows) {
        _ = c.dbg_sysinfo(&sys, sys.len);
    } else {
        // Linux: a distro e o kernel
        var ub: std.posix.utsname = undefined;
        ub = std.posix.uname();
        _ = std.fmt.bufPrint(&sys, "kernel {s} {s}", .{ std.mem.sliceTo(&ub.sysname, 0), std.mem.sliceTo(&ub.release, 0) }) catch {};
    }
    const s = std.fmt.bufPrintZ(&info, "telinha {s} · {s} {s}\n{s}", .{ proto.app_version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), std.mem.sliceTo(&sys, 0) }) catch return;
    c.crash_install(p.ptr, s.ptr);
}

/// Panic do Zig: anota a mensagem (o abort que vem depois anota a pilha).
pub fn note(msg: []const u8) void {
    var b: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&b, "{s}", .{msg[0..@min(msg.len, 500)]}) catch return;
    c.crash_note(z.ptr);
}

var pending_cache: std.atomic.Value(u8) = .init(2); // 0 não, 1 sim, 2 não sabe ainda

/// Tem relatório de um travamento que ainda não foi mandado nem dispensado?
/// (lido do arquivo uma vez; mandar ou dispensar atualiza)
pub fn pending() bool {
    const v = pending_cache.load(.acquire);
    if (v != 2) return v == 1;
    const p = pendingFile();
    pending_cache.store(@intFromBool(p), .release);
    return p;
}

fn pendingFile() bool {
    var pb: [600]u8 = undefined;
    const p = path(&pb) orelse return false;
    var st: [1]u8 = undefined;
    const f = mp4.openFile(p, "rb") orelse return false;
    defer _ = cio.fclose(f);
    return cio.fread(&st, 1, 1, f) == 1;
}

/// Mandou ou dispensou: copia pro "antigo" e esvazia (não pergunta de novo).
pub fn dismiss() void {
    var pb: [600]u8 = undefined;
    var ob: [600]u8 = undefined;
    const p = path(&pb) orelse return;
    const o = inConfigDir(&ob, old_name) orelse return;
    if (mp4.openFile(p, "rb")) |src| {
        defer _ = cio.fclose(src);
        if (mp4.openFile(o, "wb")) |dst| {
            defer _ = cio.fclose(dst);
            var buf: [16 * 1024]u8 = undefined;
            while (true) {
                const n = cio.fread(&buf, 1, buf.len, src);
                if (n == 0) break;
                _ = cio.fwrite(&buf, 1, n, dst);
            }
        }
    }
    if (mp4.openFile(p, "wb")) |f| _ = cio.fclose(f);
    pending_cache.store(0, .release);
}

/// Teste (TELINHA_TESTE_TRAVAR): "1" = falha de memória, "panic" = panic do Zig.
pub fn testCrash() void {
    const v = std.c.getenv("TELINHA_TESTE_TRAVAR") orelse return;
    if (std.mem.eql(u8, std.mem.span(v), "panic")) @panic("teste de travamento");
    c.crash_now(1);
}
