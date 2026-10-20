//! Benchmark do pipeline de vídeo: `zig build bench [-- largura altura]`.
//! Mede conversão de cor, encode e decode H.264 com conteúdo parecido com
//! tela real (texto rolando) e com movimento (tudo mudando).
//!
//! Qualidade (PSNR) x tempo por encoder/preset: TELINHA_BENCH_QUALIDADE=1.
//! Opções: TELINHA_BENCH_IMAGEM=tela.bgra (uma captura de verdade, w*h*4),
//! TELINHA_BENCH_CURVA=1 (qualidade quadro a quadro depois de cada IDR),
//! TELINHA_BENCH_PRESET=N (só o preset N do NVENC; 0 = openh264),
//! TELINHA_BENCH_SO_NVENC=1.
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
    try convNV12(w, h);
    try runHw("NVENC: texto rolando", w, h, .screen, .text);
    try runHw("NVENC: movimento", w, h, .motion, .motion);
    if (std.c.getenv("TELINHA_BENCH_QUALIDADE") != null) try quality(w, h, 6_000_000);
}

/// A conversão que os encoders VA-API e Media Foundation usam.
fn convNV12(w: u32, h: u32) !void {
    const img = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(img);
    const nv = try gpa.alloc(u8, @as(usize, w) * h * 3 / 2);
    defer gpa.free(nv);
    fillText(img, w, h, 1);
    var t: u64 = 0;
    const frames = 60;
    for (0..frames + 5) |f| {
        const a = sync.nowUs();
        codec.toNV12(img.ptr, @as(usize, w) * 4, w, h, .bgrx, nv[0 .. @as(usize, w) * h], w, nv[@as(usize, w) * h ..], w);
        if (f >= 5) t += sync.nowUs() - a;
    }
    std.debug.print("{s:<28} conv {d:>5.1} ms (BGRX → NV12, pros encoders VA-API e Media Foundation)\n", .{ "NV12", @as(f64, @floatFromInt(t)) / frames / 1000 });
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
    var hwd: ?codec.HwDecoder = codec.HwDecoder.init(.h264, &err) catch null;
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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// PSNR do brilho (Y) entre a imagem original e a decodificada, em dB.
fn psnrY(src_y: []const u8, p: codec.Decoder.Picture, w: u32, h: u32) f64 {
    var sse: u64 = 0;
    for (0..h) |y| {
        const a = src_y[y * w ..][0..w];
        const b = p.y[y * p.ys ..][0..w];
        for (a, b) |x, z| {
            const d: i32 = @as(i32, x) - @as(i32, z);
            sse += @intCast(d * d);
        }
    }
    const mse = @as(f64, @floatFromInt(sse)) / @as(f64, @floatFromInt(@as(u64, w) * h));
    if (mse == 0) return 99;
    return 10 * std.math.log10(255.0 * 255.0 / mse);
}

/// Qualidade x tempo de cada preset do NVENC (e do openh264), mesma taxa de bits.
pub fn quality(w: u32, h: u32, bitrate: u32) !void {
    const img = try gpa.alloc(u8, @as(usize, w) * h * 4);
    defer gpa.free(img);
    const n = @as(usize, w) * h;
    const sy = try gpa.alloc(u8, n);
    defer gpa.free(sy);
    const su = try gpa.alloc(u8, n / 4);
    defer gpa.free(su);
    const sv = try gpa.alloc(u8, n / 4);
    defer gpa.free(sv);
    const prev_y = try gpa.alloc(u8, n); // Y do quadro anterior (pra detectar atraso de 1 quadro)
    defer gpa.free(prev_y);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    std.debug.print("\nqualidade x tempo ({d}x{d}, {d} kbit/s, 30 fps): PSNR do brilho, maior = melhor\n", .{ w, h, bitrate / 1000 });
    for ([_]enum { text, motion }{ .text, .motion }) |scene| {
        for ([_]u8{ 0, 1, 2, 3, 4, 5, 7 }) |preset| {
            if (std.c.getenv("TELINHA_BENCH_SO_NVENC") != null and preset == 0) continue;
            if (std.c.getenv("TELINHA_BENCH_PRESET")) |only| if (preset != only[0] - '0') continue;
            var err: [256]u8 = undefined;
            // camadas temporais como no app (NVENC com texto: uma só); com
            // TELINHA_BENCH_CAMADAS=1/2 força pra comparar
            const layers: u8 = if (std.c.getenv("TELINHA_BENCH_CAMADAS")) |v| v[0] - '0' else if (preset > 0 and scene == .text) 1 else 2;
            const opts: codec.EncoderOptions = .{ .width = w, .height = h, .fps = 30, .bitrate = bitrate, .mode = if (scene == .text) .screen else .motion, .temporal_layers = layers };
            var name_buf: [32]u8 = undefined;
            const name = if (preset == 0) "openh264" else std.fmt.bufPrint(&name_buf, "NVENC P{d}", .{preset}) catch "";
            if (preset > 0) {
                var pb: [2:0]u8 = .{ '0' + preset, 0 };
                _ = setenv("TELINHA_NVENC_PRESET", &pb, 1);
            }
            var sw: ?codec.Encoder = if (preset == 0) try codec.Encoder.init(opts) else null;
            defer if (sw) |*e| e.deinit();
            var hwe: ?codec.HwEncoder = if (preset > 0) (codec.HwEncoder.init(opts, &err) catch {
                std.debug.print("  {s}: indisponível\n", .{name});
                return;
            }) else null;
            defer if (hwe) |*e| e.deinit();
            var dec = try codec.Decoder.init();
            defer dec.deinit();
            fillText(img, w, h, 1);
            // TELINHA_BENCH_IMAGEM=arquivo.bgra (w*h*4): uma tela de verdade no lugar do texto sintético
            if (std.c.getenv("TELINHA_BENCH_IMAGEM")) |path| if (scene == .text) {
                if (std.c.fopen(path, "rb")) |fh| {
                    _ = std.c.fread(img.ptr, 1, img.len, fh);
                    _ = std.c.fclose(fh);
                }
            };
            const frames = 90;
            var t_enc: u64 = 0;
            var bytes: u64 = 0;
            var psnr_sum: f64 = 0;
            var psnr_min: f64 = 99;
            var psnr_prev: f64 = 0;
            for (0..frames) |f| {
                if (scene == .text) scroll(img, w, h) else motion(img, w, h, f);
                out.clearRetainingCapacity();
                const a = sync.nowUs();
                if (sw) |*e| {
                    _ = try e.encode(img.ptr, @as(usize, w) * 4, .bgrx, &out);
                } else {
                    // IDR no meio (alguém entrou na sala) no quadro 40
                    _ = try hwe.?.encode(img.ptr, @as(usize, w) * 4, .bgrx, f == 0 or (std.c.getenv("TELINHA_BENCH_CURVA") != null and f == 40), &out);
                }
                const b = sync.nowUs();
                const pic = (try dec.decode(out.items)) orelse continue;
                @memcpy(prev_y, sy);
                codec.toI420(img.ptr, @as(usize, w) * 4, w, h, .bgrx, sy, su, sv);
                if (std.c.getenv("TELINHA_BENCH_CURVA") != null and scene == .text and (f < 24 or (f >= 38 and f < 52)))
                    std.debug.print("    quadro {d:>2}: {d:.1} dB, {d} KB\n", .{ f, psnrY(sy, pic, w, h), out.items.len / 1024 });
                if (f < 10) continue; // deixa o controle de taxa assentar
                const ps = psnrY(sy, pic, w, h);
                psnr_prev += psnrY(prev_y, pic, w, h);
                psnr_sum += ps;
                psnr_min = @min(psnr_min, ps);
                t_enc += b - a;
                bytes += out.items.len;
            }
            const cnt: f64 = frames - 10;
            std.debug.print("  {s:<6} {s:<10} encode {d:>5.1} ms | PSNR {d:>5.2} dB (pior {d:.2}, vs anterior {d:.2}) | {d:>5.0} kbit/s\n", .{
                if (scene == .text) "texto" else "jogo",              name,
                @as(f64, @floatFromInt(t_enc)) / cnt / 1000,          psnr_sum / cnt,
                psnr_min,                                             psnr_prev / cnt,
                @as(f64, @floatFromInt(bytes)) * 8 / cnt * 30 / 1000,
            });
        }
    }
}
