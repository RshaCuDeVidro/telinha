//! Benchmark do pipeline de vídeo: `zig build bench [-- largura altura]`.
//! Mede conversão de cor, encode e decode H.264 com conteúdo parecido com
//! tela real (texto rolando) e com movimento (tudo mudando).
const std = @import("std");
const sync = @import("sync.zig");
const codec = @import("codec.zig");
const gpa = std.heap.c_allocator;

fn fillText(img: []u8, w: usize, h: usize, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    @memset(img, 0xF0);
    for (0..w * h / 300) |_| {
        const bx = r.uintLessThan(usize, w - 8);
        const by = r.uintLessThan(usize, h - 14);
        for (0..12) |yy| for (0..7) |xx| {
            if (r.uintLessThan(u8, 3) == 0) {
                const p = ((by + yy) * w + bx + xx) * 4;
                img[p] = 30;
                img[p + 1] = 30;
                img[p + 2] = 30;
            }
        };
    }
}

fn scroll(img: []u8, w: usize, h: usize) void {
    // rola uma "janela" de texto 4 linhas pra cima
    const x0 = w / 6;
    const x1 = w * 5 / 6;
    for (h / 6..h * 5 / 6) |y| {
        @memcpy(img[(y * w + x0) * 4 .. (y * w + x1) * 4], img[((y + 4) * w + x0) * 4 .. ((y + 4) * w + x1) * 4]);
    }
}

fn motion(img: []u8, w: usize, h: usize, f: usize) void {
    for (0..h) |y| for (0..w) |x| {
        const p = (y * w + x) * 4;
        const t: f32 = @floatFromInt(f);
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        img[p] = @intFromFloat(128 + 100 * @sin((fx + t * 7) * 0.02));
        img[p + 1] = @intFromFloat(128 + 100 * @cos((fy + t * 5) * 0.015));
        img[p + 2] = @intFromFloat(128 + 60 * @sin((fx + fy + t * 3) * 0.01));
    };
}

fn run(name: []const u8, w: u32, h: u32, mode: codec.Mode, scene: enum { text, motion }) !void {
    const img = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(img);
    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(rgba);
    fillText(img, w, h, 1);
    const fps = 30;
    var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = fps, .bitrate = 6_000_000, .mode = mode });
    defer enc.deinit();
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const frames = 90;
    var t_conv: u64 = 0;
    var t_enc: u64 = 0;
    var t_dec: u64 = 0;
    var t_rgb: u64 = 0;
    var bytes: u64 = 0;
    var worst_total: u64 = 0;
    const y = try gpa.alloc(u8, @as(usize, w) * h);
    defer gpa.free(y);
    const u = try gpa.alloc(u8, @as(usize, w) * h / 4);
    defer gpa.free(u);
    const v = try gpa.alloc(u8, @as(usize, w) * h / 4);
    defer gpa.free(v);
    for (0..frames) |f| {
        if (scene == .text) scroll(img, w, h) else motion(img, w, h, f);
        // conversão separada só pra medir (o encode converte de novo por dentro)
        const a = sync.nowUs();
        codec.toI420(img.ptr, @as(usize, w) * 4, w, h, .bgrx, y, u, v);
        const b = sync.nowUs();
        out.clearRetainingCapacity();
        _ = try enc.encode(img.ptr, @as(usize, w) * 4, .bgrx, &out);
        const c = sync.nowUs();
        var d = c;
        var e = c;
        if (try dec.decode(out.items)) |pic| {
            d = sync.nowUs();
            codec.toRgba(pic.y, pic.u, pic.v, pic.ys, pic.uvs, pic.w, pic.h, rgba);
            e = sync.nowUs();
        }
        if (f < 5) continue; // aquecimento
        t_conv += b - a;
        t_enc += (c - b) - (b - a);
        t_dec += d - c;
        t_rgb += e - d;
        bytes += out.items.len;
        worst_total = @max(worst_total, (c - b) + (e - c));
    }
    const n: f64 = frames - 5;
    std.debug.print("{s:<28} conv {d:>5.1} ms | encode {d:>5.1} ms | decode {d:>5.1} ms | rgba {d:>4.1} ms | pior {d:>5.1} ms | {d:>6.0} KB/s\n", .{
        name,
        @as(f64, @floatFromInt(t_conv)) / n / 1000,
        @as(f64, @floatFromInt(t_enc)) / n / 1000,
        @as(f64, @floatFromInt(t_dec)) / n / 1000,
        @as(f64, @floatFromInt(t_rgb)) / n / 1000,
        @as(f64, @floatFromInt(worst_total)) / 1000,
        @as(f64, @floatFromInt(bytes)) / n * fps / 1024,
    });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const w: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 1920;
    const h: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 1080;
    sync.pool.start(@max(2, sync.cpuCount() - 1));
    std.debug.print("telinha bench — {d}x{d} @ 30 fps, {d} threads, alvo 6 Mbit/s\n\n", .{ w, h, sync.cpuCount() });
    try run("texto rolando (modo tela)", w, h, .screen, .text);
    try run("movimento (modo tela)", w, h, .screen, .motion);
    try run("movimento (modo jogo)", w, h, .motion, .motion);
    try runHw("NVENC: texto rolando", w, h, .screen, .text);
    try runHw("NVENC: movimento", w, h, .motion, .motion);
}

fn runHw(name: []const u8, w: u32, h: u32, mode: codec.Mode, scene: enum { text, motion }) !void {
    var err: [256]u8 = undefined;
    var enc = codec.HwEncoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 6_000_000, .mode = mode }, &err) catch {
        std.debug.print("{s:<28} indisponível: {s}\n", .{ name, std.mem.sliceTo(&err, 0) });
        return;
    };
    defer enc.deinit();
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    var hwd: ?codec.HwDecoder = codec.HwDecoder.init(&err) catch null;
    defer if (hwd) |*d| d.deinit();
    const img = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(img);
    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(rgba);
    fillText(img, w, h, 1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const frames = 90;
    var t_enc: u64 = 0;
    var t_dec: u64 = 0;
    var t_hwdec: u64 = 0;
    var hw_frames: u32 = 0;
    var bytes: u64 = 0;
    var worst: u64 = 0;
    for (0..frames) |f| {
        if (scene == .text) scroll(img, w, h) else motion(img, w, h, f);
        out.clearRetainingCapacity();
        const a = sync.nowUs();
        _ = try enc.encode(img.ptr, @as(usize, w) * 4, .bgrx, f == 0, &out);
        const b = sync.nowUs();
        _ = try dec.decode(out.items);
        const c = sync.nowUs();
        var hd: u64 = 0;
        if (hwd) |*d| {
            if (try d.decode(out.items)) |fr| {
                codec.nv12ToRgba(fr.y, fr.uv, fr.w, fr.h, rgba);
                hd = sync.nowUs() - c;
                hw_frames += 1;
            } else return error.NvdecHeldFrame;
        }
        if (f < 5) continue;
        t_enc += b - a;
        t_dec += c - b;
        t_hwdec += hd;
        worst = @max(worst, b - a);
        bytes += out.items.len;
    }
    const n: f64 = frames - 5;
    std.debug.print("{s:<28} encode {d:>5.1} ms (pior {d:.1}) | decode openh264 {d:>5.1} ms | NVDEC+rgba {d:>5.1} ms | {d:>6.0} KB/s\n", .{
        name,
        @as(f64, @floatFromInt(t_enc)) / n / 1000,
        @as(f64, @floatFromInt(worst)) / 1000,
        @as(f64, @floatFromInt(t_dec)) / n / 1000,
        @as(f64, @floatFromInt(t_hwdec)) / n / 1000,
        @as(f64, @floatFromInt(bytes)) / n * 30 / 1024,
    });
}

