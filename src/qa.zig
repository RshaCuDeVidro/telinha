//! Modo de testes (TELINHA_QA=pasta). A cada ~80 ms o app escreve nessa pasta
//! onde está cada item da interface (items.tsv: rótulo, janela, retângulo,
//! estado) e o estado do app (state.json). tools/qa/ usa isso pra clicar nos
//! botões de verdade (XTest, numa tela escondida) e conferir o resultado.
//! Fora desse modo nada aqui roda e os ganchos do ImGui ficam desligados.
const std = @import("std");
const c = @import("c.zig").c;
const sync = @import("sync.zig");
const gpa = std.heap.c_allocator;

const cio = @cImport({
    @cInclude("stdio.h");
});

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

var dir_buf: [512]u8 = undefined;
var dir_len: usize = 0;
var last_ms: u64 = 0;
var state_err_shown = false;

pub fn enabled() bool {
    return dir_len > 0;
}

/// Liga o modo de testes se TELINHA_QA apontar pra uma pasta (depois de criar o contexto do ImGui).
pub fn init() void {
    const d = std.mem.span(getenv("TELINHA_QA") orelse return);
    if (d.len == 0 or d.len >= dir_buf.len - 32) return;
    @memcpy(dir_buf[0..d.len], d);
    dir_len = d.len;
    c.qa_enable(1);
}

/// Fim de um quadro: guarda os itens dele e, de tempos em tempos, escreve os arquivos.
pub fn endFrame(app: anytype, win: *c.GLFWwindow) void {
    if (!enabled()) return;
    c.qa_end_frame();
    const now = sync.nowMs();
    if (now - last_ms < 80) return;
    last_ms = now;
    writeItems(win) catch {};
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    app.qaState(&aw.writer) catch |e| {
        // estado pela metade não vale: avisa (uma vez) e mantém o anterior
        if (!state_err_shown) std.debug.print("[telinha] modo de testes: estado falhou: {s}\n", .{@errorName(e)});
        state_err_shown = true;
        return;
    };
    writeFile("state.json", aw.written()) catch {};
}

fn writeItems(win: *c.GLFWwindow) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    var x: c_int = 0;
    var y: c_int = 0;
    var ww: c_int = 0;
    var wh: c_int = 0;
    c.glfwGetWindowPos(win, &x, &y);
    c.glfwGetWindowSize(win, &ww, &wh);
    try w.print("#janela\t{d}\t{d}\t{d}\t{d}\n", .{ x, y, ww, wh });
    const n: usize = @intCast(c.qa_count());
    const raw = c.qa_items();
    if (raw == null) return writeFile("items.tsv", aw.written());
    const items: [*]const c.qa_item = @ptrCast(raw);
    for (0..n) |i| {
        const it = &items[i];
        const label = std.mem.sliceTo(&it.label, 0);
        const window = std.mem.sliceTo(&it.window, 0);
        if (it.hidden != 0) continue;
        try w.print("{f}\t{f}\t{d}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d}\n", .{
            clean(label), clean(window), it.id, it.x0, it.y0, it.x1, it.y1, it.cx0, it.cy0, it.cx1, it.cy1, it.status,
        });
    }
    try writeFile("items.tsv", aw.written());
}

/// Tab e quebra de linha viram espaço (o arquivo é separado por tab).
fn clean(s: []const u8) Clean {
    return .{ .s = s };
}
const Clean = struct {
    s: []const u8,
    pub fn format(self: Clean, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.s) |ch| try w.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
    }
};

fn writeFile(name: []const u8, data: []const u8) !void {
    var tmp_buf: [600]u8 = undefined;
    var dst_buf: [600]u8 = undefined;
    const dir = dir_buf[0..dir_len];
    const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}/.{s}.tmp", .{ dir, name });
    const dst = try std.fmt.bufPrintZ(&dst_buf, "{s}/{s}", .{ dir, name });
    const f = cio.fopen(tmp.ptr, "wb") orelse return error.Open;
    _ = cio.fwrite(data.ptr, 1, data.len, f);
    _ = cio.fclose(f);
    // troca atômica: quem lê nunca vê o arquivo pela metade (no Windows o
    // rename não substitui: apaga antes, e quem lê tenta de novo se faltar)
    if (sync.is_windows) _ = cio.remove(dst.ptr);
    _ = cio.rename(tmp.ptr, dst.ptr);
}

/// String JSON com escape.
pub fn str(s: []const u8) JsonStr {
    return .{ .s = s };
}
pub const JsonStr = struct {
    s: []const u8,
    pub fn format(self: JsonStr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.s) |ch| switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        };
        try w.writeByte('"');
    }
};
