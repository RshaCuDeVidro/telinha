//! Uma janela só pros convites (c/single.c): o link telinha:// clicado com o
//! telinha aberto vai pra janela que já está aberta.
const std = @import("std");
const c = @cImport(@cInclude("single.h"));
const sync = @import("sync.zig");
const config = @import("config.zig");

/// Nome do canal: a pasta de configurações (cada telinha com a sua).
fn name(buf: []u8) ?[:0]const u8 {
    var db: [512]u8 = undefined;
    const dir = config.dirPath(&db) orelse return null;
    return std.fmt.bufPrintZ(buf, "telinha-{x}", .{std.hash.Wyhash.hash(0, dir)}) catch null;
}

/// Tem uma janela aberta? Entrega o convite pra ela (true: pode fechar).
pub fn handoff(invite: []const u8) bool {
    var nb: [64]u8 = undefined;
    const n = name(&nb) orelse return false;
    var ib: [1025]u8 = undefined;
    const inv = std.fmt.bufPrintZ(&ib, "{s}", .{invite[0..@min(invite.len, 1024)]}) catch return false;
    return c.single_handoff(n.ptr, inv.ptr) == 1;
}

extern var single_errno: c_int;
var mutex: sync.Mutex = .{};
var pending: [1025]u8 = undefined;
var pending_len: usize = 0;
var wake: ?*const fn () void = null;

fn onInvite(inv: [*c]const u8) callconv(.c) void {
    const s = std.mem.span(inv);
    if (!std.mem.startsWith(u8, s, "telinha://")) return;
    mutex.lock();
    pending_len = @min(s.len, pending.len);
    @memcpy(pending[0..pending_len], s[0..pending_len]);
    mutex.unlock();
    if (wake) |w| w();
}

/// Esta janela recebe os convites dos links clicados (a primeira que abriu).
pub fn listen(on_wake: *const fn () void) void {
    wake = on_wake;
    var nb: [64]u8 = undefined;
    const n = name(&nb) orelse return;
    const r = c.single_listen(n.ptr, onInvite);
    if (std.c.getenv("TELINHA_DEBUG") != null) std.debug.print("[telinha] convites de links: {s} ({s}, {d})\n", .{ if (r == 1) "esta janela recebe" else if (r == 0) "outra janela já recebe" else "não deu", n, single_errno });
}

/// Convite que chegou (e esquece).
pub fn take(buf: []u8) ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();
    if (pending_len == 0) return null;
    const n = @min(pending_len, buf.len);
    @memcpy(buf[0..n], pending[0..n]);
    pending_len = 0;
    return buf[0..n];
}
