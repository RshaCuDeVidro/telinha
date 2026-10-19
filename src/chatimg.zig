//! Imagens no chat. Quem manda já tem a imagem decodificada (RGBA, do arquivo
//! ou da área de transferência); aqui ela é reduzida pra caber em 1600 px e
//! vira **um quadro H.264** (IDR) do openh264. Quem recebe decodifica com o
//! mesmo decoder do vídeo — nenhum leitor de PNG/JPEG fica exposto ao que
//! chega pela rede, e uma captura de tela típica sai com 100–400 KB.
const std = @import("std");
const codec = @import("codec.zig");
const proto = @import("proto.zig");
const gpa = std.heap.c_allocator;

pub const max_side = 1600;

pub const Encoded = struct {
    data: []u8,
    w: u16,
    h: u16,

    pub fn deinit(e: *Encoded) void {
        gpa.free(e.data);
    }
};

/// Fundo pra transparência (a cor do chat).
const bg = [3]u8{ 0x31, 0x33, 0x38 };

/// RGBA (w x h) → quadro H.264 pronto pra mandar.
pub fn encode(rgba: []const u8, w: usize, h: usize) !Encoded {
    if (w == 0 or h == 0 or rgba.len < w * h * 4) return error.BadImage;
    // tamanho final: cabe em max_side; imagem minúscula aumenta (o codec quer 16+)
    var scale: f64 = @min(1.0, @as(f64, max_side) / @as(f64, @floatFromInt(@max(w, h))));
    const min_side: f64 = @floatFromInt(@min(w, h));
    if (min_side * scale < 16) scale = 16.0 / min_side;
    const nw: usize = @max(16, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale))) & ~@as(usize, 1));
    const nh: usize = @max(16, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale))) & ~@as(usize, 1));
    if (nw > proto.chat_image_side or nh > proto.chat_image_side) return error.BadImage;
    const px = try gpa.alloc(u8, nw * nh * 4);
    defer gpa.free(px);
    resample(rgba, w, h, px, nw, nh);

    // um quadro só: o "fps 1" faz a taxa virar o tamanho do quadro. Se passar
    // do limite, tenta de novo com menos bits.
    var budget: u32 = @intCast(std.math.clamp(nw * nh * 3, 400_000, 9_000_000));
    var tries: usize = 0;
    while (tries < 4) : (tries += 1) {
        var enc = try codec.Encoder.init(.{ .width = @intCast(nw), .height = @intCast(nh), .fps = 1, .bitrate = budget, .mode = .screen, .temporal_layers = 1 });
        defer enc.deinit();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        _ = try enc.encode(px.ptr, nw * 4, .rgbx, &out);
        if (out.items.len == 0 or !codec.hasIdrNal(out.items)) return error.Encode;
        if (out.items.len <= proto.chat_image_max) return .{ .data = try out.toOwnedSlice(gpa), .w = @intCast(nw), .h = @intCast(nh) };
        out.deinit(gpa);
        budget /= 2;
    }
    return error.TooBig;
}

/// Reduz (média da área) ou aumenta (vizinho mais próximo), e tira a
/// transparência pintando por cima do fundo do chat. Saída RGBX.
fn resample(src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    for (0..dh) |y| {
        const y0 = y * sh / dh;
        const y1 = @max(y0 + 1, (y + 1) * sh / dh);
        for (0..dw) |x| {
            const x0 = x * sw / dw;
            const x1 = @max(x0 + 1, (x + 1) * sw / dw);
            var acc = [4]u32{ 0, 0, 0, 0 };
            for (y0..y1) |yy| {
                for (x0..x1) |xx| {
                    const p = src[(yy * sw + xx) * 4 ..][0..4];
                    const a: u32 = p[3];
                    for (0..3) |k| acc[k] += (@as(u32, p[k]) * a + @as(u32, bg[k]) * (255 - a)) / 255;
                    acc[3] += 1;
                }
            }
            const o = dst[(y * dw + x) * 4 ..][0..4];
            for (0..3) |k| o[k] = @intCast(acc[k] / acc[3]);
            o[3] = 255;
        }
    }
}

/// Quadro H.264 recebido → RGBA (gpa). Confere o tamanho que a mensagem disse.
pub fn decode(h264: []const u8, w: u16, h: u16) ![]u8 {
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    const pic = (try dec.decode(h264)) orelse return error.Decode;
    if (pic.w != w or pic.h != h) return error.Decode;
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    codec.toRgba(pic.y, pic.u, pic.v, pic.ys, pic.uvs, w, h, out);
    return out;
}

fn luma(p: *const [3]u8) f64 {
    return 0.299 * @as(f64, @floatFromInt(p[0])) + 0.587 * @as(f64, @floatFromInt(p[1])) + 0.114 * @as(f64, @floatFromInt(p[2]));
}

test "imagem do chat: codifica e volta parecida, dentro do limite" {
    const w = 900;
    const h = 500;
    const src = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(src);
    // degradê + "texto" (listras finas) + canto transparente
    for (0..h) |y| for (0..w) |x| {
        const p = src[(y * w + x) * 4 ..][0..4];
        p[0] = @intCast(x * 255 / w);
        p[1] = @intCast(y * 255 / h);
        p[2] = if ((x / 3 + y / 7) % 2 == 0) 230 else 30;
        p[3] = if (x < 50 and y < 50) 0 else 255;
    };
    var e = try encode(src, w, h);
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 900), e.w);
    try std.testing.expectEqual(@as(u16, 500), e.h);
    try std.testing.expect(e.data.len <= proto.chat_image_max);
    const back = try decode(e.data, e.w, e.h);
    defer gpa.free(back);
    // PSNR do brilho (o que deixa texto legível) e o canto transparente virou o fundo
    var se: f64 = 0;
    for (0..h) |y| for (0..w) |x| {
        const d = luma(back[(y * w + x) * 4 ..][0..3]) - luma(src[(y * w + x) * 4 ..][0..3]);
        if (x >= 60 or y >= 60) se += d * d;
    };
    const psnr = 10 * std.math.log10(255.0 * 255.0 / (se / @as(f64, @floatFromInt(w * h))));
    try std.testing.expect(psnr > 30);
    const corner = back[(10 * w + 10) * 4 ..][0..3];
    try std.testing.expect(@abs(@as(i32, corner[0]) - bg[0]) < 12 and @abs(@as(i32, corner[2]) - bg[2]) < 12);
    // mensagem dizendo outro tamanho: recusa
    try std.testing.expectError(error.Decode, decode(e.data, 800, 500));
}

test "imagem do chat: grande reduz pra 1600, minúscula aumenta pra 16" {
    const big = try gpa.alloc(u8, 3200 * 1000 * 4);
    defer gpa.free(big);
    @memset(big, 200);
    var e = try encode(big, 3200, 1000);
    defer e.deinit();
    try std.testing.expectEqual(@as(u16, 1600), e.w);
    try std.testing.expectEqual(@as(u16, 500), e.h);
    var tiny = [_]u8{255} ** (4 * 4 * 4);
    var t = try encode(&tiny, 4, 4);
    defer t.deinit();
    try std.testing.expectEqual(@as(u16, 16), t.w);
    try std.testing.expectEqual(@as(u16, 16), t.h);
    try std.testing.expectError(error.BadImage, encode(&tiny, 4, 40));
}
