//! Gera uma cópia do cimgui.h que o translate-c do Zig consegue importar:
//! campos `ImGuiContext*` viram `void*` (o ImGuiContext completo não é
//! traduzível e vira opaco, e ponteiro C pra struct opaca não é permitido).
//! uso: patch_cimgui <entrada> <saída>
const std = @import("std");
const c = @cImport(@cInclude("stdio.h"));

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const in = c.fopen(args[1].ptr, "rb") orelse return error.OpenInput;
    defer _ = c.fclose(in);
    const out = c.fopen(args[2].ptr, "wb") orelse return error.OpenOutput;
    defer _ = c.fclose(out);
    var line: [8192]u8 = undefined;
    while (c.fgets(&line, line.len, in) != null) {
        const l = std.mem.sliceTo(&line, 0);
        const t = std.mem.trimStart(u8, l, " \t");
        const fields = [_][]const u8{ "ImGuiContext* Ctx;", "ImGuiContext* OwnerContext;", "ImGuiContext* Context;" };
        var replaced = false;
        for (fields) |f| {
            if (std.mem.startsWith(u8, t, f)) {
                const name = f["ImGuiContext* ".len..];
                _ = c.fprintf(out, "    void* %.*s // zig: era ImGuiContext*\n", @as(c_int, @intCast(name.len)), name.ptr);
                replaced = true;
                break;
            }
        }
        if (!replaced) _ = c.fputs(&line, out);
    }
}
