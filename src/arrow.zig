//! A seta do mouse desenhada pela interface (a da vitrine da tela de entrada e
//! a de quem transmite, que quem assiste desenha por cima do vídeo).
//! Pintada uma vez numa imagem RGBA, no tamanho certo pra escala: a borda é
//! suavizada pela distância até o contorno (o mesmo que um PNG feito de SVG),
//! e a imagem vai na tela em pixel inteiro. Como polígono a cada quadro ela
//! tremia andando em posição quebrada, e o contorno do ImGui não fecha em
//! ângulo agudo (a ponta branca vazava).
const std = @import("std");

/// O formato, em pixels na escala 1x (ponta em 0,0).
const pts = [_][2]f32{ .{ 0, 0 }, .{ 0, 17 }, .{ 4, 13 }, .{ 7.5, 20.5 }, .{ 10, 19.5 }, .{ 6.6, 12 }, .{ 12, 12 } };

/// Maior lado da imagem (escala 5x ainda cabe).
pub const max_side = 128;

pub const Size = struct {
    w: u32,
    h: u32,
    /// onde fica a ponta, em pixels a partir do canto da imagem
    tip: u32,
};

/// Pinta a seta em `out` (RGBA, alfa não pré-multiplicado): branca com
/// contorno preto por fora, ou `dark` = preta com contorno branco. `s` = pixels
/// por unidade (1 na escala 1x).
pub fn paint(out: []u8, s: f32, dark: bool) Size {
    const k = std.math.clamp(s, 0.4, 5);
    const line = @max(1.0, @round(1.1 * k)); // largura do contorno
    const tip: u32 = @intFromFloat(line + 1);
    const pad: f32 = @floatFromInt(tip);
    const w: u32 = @min(max_side, @as(u32, @intFromFloat(@ceil(12 * k + 2 * pad))));
    const h: u32 = @min(max_side, @as(u32, @intFromFloat(@ceil(20.5 * k + 2 * pad))));
    std.debug.assert(out.len >= w * h * 4);
    for (0..h) |y| {
        for (0..w) |x| {
            const px = (@as(f32, @floatFromInt(x)) + 0.5 - pad) / k;
            const py = (@as(f32, @floatFromInt(y)) + 0.5 - pad) / k;
            const dist = signedDist(px, py) * k; // em pixels; negativa dentro
            const alpha = std.math.clamp(0.5 - (dist - line), 0, 1);
            const inner = std.math.clamp(0.5 - dist, 0, 1);
            const white = if (dark) 1 - inner else inner;
            const o = (y * w + x) * 4;
            const v: u8 = @intFromFloat(@round(white * 255));
            out[o] = v;
            out[o + 1] = v;
            out[o + 2] = v;
            out[o + 3] = @intFromFloat(@round(alpha * 255));
        }
    }
    return .{ .w = w, .h = h, .tip = tip };
}

/// Distância até a borda do polígono (negativa dentro).
fn signedDist(x: f32, y: f32) f32 {
    var best: f32 = std.math.inf(f32);
    var inside = false;
    var j: usize = pts.len - 1;
    for (pts, 0..) |a, i| {
        const b = pts[j];
        j = i;
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        const t = std.math.clamp(((x - a[0]) * ex + (y - a[1]) * ey) / (ex * ex + ey * ey), 0, 1);
        const dx = x - (a[0] + ex * t);
        const dy = y - (a[1] + ey * t);
        best = @min(best, @sqrt(dx * dx + dy * dy));
        if ((a[1] > y) != (b[1] > y) and x < a[0] + (y - a[1]) / (b[1] - a[1]) * ex) inside = !inside;
    }
    return if (inside) -best else best;
}

test "seta: miolo branco, contorno preto, ponta sem branco vazando, fora transparente" {
    var buf: [max_side * max_side * 4]u8 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |s| {
        const sz = paint(&buf, s, false);
        const at = struct {
            fn px(b: []const u8, z: Size, x: u32, y: u32) [4]u8 {
                const o = (y * z.w + x) * 4;
                return b[o..][0..4].*;
            }
        };
        // miolo da cabeça
        const mid = at.px(&buf, sz, sz.tip + @as(u32, @intFromFloat(3 * s)), sz.tip + @as(u32, @intFromFloat(8 * s)));
        try std.testing.expect(mid[0] == 255 and mid[3] == 255);
        // canto de fora: transparente
        try std.testing.expectEqual(@as(u8, 0), at.px(&buf, sz, sz.w - 1, 0)[3]);
        // ao redor da ponta: o que aparece é preto (nada branco vazando pra fora do contorno)
        for (0..sz.tip + 1) |y| {
            for (0..sz.tip + 1) |x| {
                const p = at.px(&buf, sz, @intCast(x), @intCast(y));
                if (x < sz.tip or y < sz.tip) try std.testing.expect(p[0] < 40 or p[3] < 40);
            }
        }
        // logo à esquerda da haste: contorno preto opaco
        const edge = at.px(&buf, sz, sz.tip - 1, sz.tip + @as(u32, @intFromFloat(8 * s)));
        try std.testing.expect(edge[3] > 200 and edge[0] < 60);
        // a escura: miolo preto, contorno branco
        const dz = paint(&buf, s, true);
        try std.testing.expectEqual(@as(u8, 0), at.px(&buf, dz, dz.tip + @as(u32, @intFromFloat(3 * s)), dz.tip + @as(u32, @intFromFloat(8 * s)))[0]);
        try std.testing.expect(at.px(&buf, dz, dz.tip - 1, dz.tip + @as(u32, @intFromFloat(8 * s)))[0] > 200);
    }
}
