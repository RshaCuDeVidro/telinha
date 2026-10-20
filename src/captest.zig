//! Diagnóstico da captura de tela: `zig build captest -- [segundos] [fps] [quadro.ppm]`.
//!
//! Abre a captura do mesmo jeito que o app (portal + PipeWire no Wayland, X11
//! no X) e mostra o que chegou: método, formato, tamanho, quadros por segundo
//! de verdade e quanto tempo cada quadro levou pra ficar pronto. Útil quando
//! "a tela não aparece" ou "está lenta" numa máquina específica.
const std = @import("std");
const c = @cImport({
    @cInclude("capture.h");
    @cInclude("cudagl.h");
});
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Caminho pela placa (TELINHA_CAPTEST_PLACA=1): fonte inteira, sem escala.
fn fullRect(fw: c_int, fh: c_int, crop: [*c]const f32, max_h: c_int, x: [*c]c_int, y: [*c]c_int, w: [*c]c_int, h: [*c]c_int, ow: [*c]c_int, oh: [*c]c_int) callconv(.c) void {
    _ = crop;
    _ = max_h;
    x.* = 0;
    y.* = 0;
    w.* = fw & ~@as(c_int, 1);
    h.* = fh & ~@as(c_int, 1);
    ow.* = w.*;
    oh.* = h.*;
}
extern "c" fn sleep(seconds: c_uint) c_uint;

fn nowUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seconds: u64 = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 5;
    const fps: c_int = if (args.len > 2) try std.fmt.parseInt(c_int, args[2], 10) else 30;
    const ppm: ?[]const u8 = if (args.len > 3 and !std.mem.eql(u8, args[3], "-")) args[3] else null;
    // "segura": em caso de falha, mantém a sessão aberta 20 s (pra inspecionar com pw-cli)
    const hold = args.len > 4 and std.mem.eql(u8, args[4], "segura");

    var err: [256]u8 = [_]u8{0} ** 256;
    const t_open = nowUs();
    // o CUDA tem que viver mais que a captura (os buffers da placa são dele): o
    // defer que fecha ele vem antes, então roda depois do cap_close
    var cg: ?*c.cudagl = null;
    defer if (cg) |g| c.cudagl_close(g);
    const cap = c.cap_open(0, 1, fps, &err, err.len) orelse {
        std.debug.print("FALHOU ao abrir a captura: {s}\n", .{std.mem.sliceTo(&err, 0)});
        std.process.exit(1);
    };
    defer c.cap_close(cap);
    std.debug.print("captura aberta em {d} ms: {s}\n", .{ (nowUs() - t_open) / 1000, std.mem.span(c.cap_backend(cap)) });
    // TELINHA_CAPTEST_PLACA=1: liga o caminho pela placa (como o app com NVENC)
    if (getenv("TELINHA_CAPTEST_PLACA") != null) {
        cg = c.cudagl_open();
        const on = cg != null and c.cap_gpu_enable(cap, cg, fullRect, null) != 0;
        std.debug.print("caminho pela placa: {s}\n", .{if (on) "ligado" else "não deu"});
    }
    var gpu_frames: u32 = 0;
    var cpu_frames: u32 = 0;

    var frames: u32 = 0;
    var cursor_only: u32 = 0;
    var last_sum: u64 = 0;
    var waits: u64 = 0;
    var max_gap: u64 = 0;
    var last_frame_us: u64 = 0;
    var saved = false;
    var seen_first = false;
    const t0 = nowUs();
    var report_at = t0 + 1_000_000;
    while (nowUs() - t0 < seconds * 1_000_000) {
        var f: c.cap_frame = std.mem.zeroes(c.cap_frame);
        const t = nowUs();
        const r = c.cap_next(cap, &f, 100, &err, err.len);
        if (r < 0) {
            std.debug.print("FALHOU durante a captura: {s}\n", .{std.mem.sliceTo(&err, 0)});
            if (hold) _ = sleep(20);
            std.process.exit(1);
        }
        const now = nowUs();
        if (r == 1 and f.gpu != null) {
            // quadro na placa: não tem pixel pra olhar aqui; devolve
            c.cap_gpu_release(cap, f.gpu);
            gpu_frames += 1;
            frames += 1;
            seen_first = true;
        } else if (r == 1 and f.data == null) {
            // era aqui que o app caía (memcpy do endereço 0 na escala do quadro)
            std.debug.print("ERRO: quadro sem pixels (nem na placa, nem na memória)\n", .{});
            std.process.exit(2);
        } else if (r == 1) {
            cpu_frames += 1;
            if (!seen_first) std.debug.print("primeiro quadro em {d} ms: {d}x{d}, stride {d}, {s}{s}\n", .{
                (now - t0) / 1000,                              f.width,
                f.height,                                       f.stride,
                if (f.format == c.CAP_RGBX) "RGBX" else "BGRX", if (f.cursor_draw != 0) ", cursor desenhado pelo telinha" else "",
            });
            seen_first = true;
            frames += 1;
            waits += now - t;
            if (last_frame_us != 0) max_gap = @max(max_gap, now - last_frame_us);
            last_frame_us = now;
            // o mesmo quadro de antes (só o cursor mexeu)?
            const sum = std.hash.Wyhash.hash(0, f.data[0..@intCast(f.stride * @min(f.height, 64))]);
            if (sum == last_sum) cursor_only += 1;
            last_sum = sum;
            if (ppm != null and !saved) {
                saved = true;
                try savePpm(ppm.?, &f);
            }
        }
        if (now >= report_at) {
            report_at += 1_000_000;
            std.debug.print("  {d} q/s (espera média {d:.1} ms, maior intervalo {d:.0} ms{s})\n", .{
                frames,
                if (frames > 0) @as(f64, @floatFromInt(waits)) / @as(f64, @floatFromInt(frames)) / 1000 else 0,
                @as(f64, @floatFromInt(max_gap)) / 1000,
                if (cursor_only > 0) ", alguns só com o cursor mexendo" else "",
            });
            if (gpu_frames + cpu_frames > 0 and cg != null) std.debug.print("    pela placa {d}, pela CPU {d}\n", .{ gpu_frames, cpu_frames });
            gpu_frames = 0;
            cpu_frames = 0;
            frames = 0;
            waits = 0;
            max_gap = 0;
            cursor_only = 0;
        }
    }
}

fn savePpm(path: []const u8, f: *const c.cap_frame) !void {
    const w: usize = @intCast(f.width);
    const h: usize = @intCast(f.height);
    const out = try std.heap.c_allocator.alloc(u8, 32 + w * h * 3);
    defer std.heap.c_allocator.free(out);
    const hdr = try std.fmt.bufPrint(out, "P6\n{d} {d}\n255\n", .{ w, h });
    var o = hdr.len;
    for (0..h) |y| {
        const row = f.data[y * @as(usize, @intCast(f.stride)) ..];
        for (0..w) |x| {
            const p = row[x * 4 ..][0..4];
            const rgb: [3]u8 = if (f.format == c.CAP_RGBX) .{ p[0], p[1], p[2] } else .{ p[2], p[1], p[0] };
            @memcpy(out[o..][0..3], &rgb);
            o += 3;
        }
    }
    const file = std.c.fopen(@ptrCast(try std.heap.c_allocator.dupeZ(u8, path)), "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(out.ptr, 1, o, file);
    std.debug.print("quadro salvo em {s}\n", .{path});
}
