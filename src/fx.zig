//! Efeitos de desenho da interface: degradê com cantos arredondados, sombra e
//! brilho suaves, e animações que param sozinhas.
//!
//! As animações não ficam rodando: cada valor anda até o alvo (mouse entrou no
//! botão, painel abriu) e para. Enquanto algum ainda anda, `moving` fica true e
//! a interface pede o próximo quadro; parado, nada redesenha por causa disso
//! (o telinha tem que custar zero de placa com a tela quieta).
const std = @import("std");
const c = @import("c.zig").c;

/// "Reduzir movimento" (acessibilidade) ou modo econômico: tudo vai direto pro alvo.
pub var reduce_motion = false;
/// Tema chapado (`effects gradient=0`): degradê vira a cor de base e a linha
/// neon das bordas não aparece.
pub var flat = false;
/// Alguma animação ainda está andando neste quadro.
pub var moving = false;

var now: f64 = 0;
var dt: f32 = 1.0 / 60.0;
var frame_no: u32 = 0;

/// Começo do quadro completo (com a hora do ImGui).
pub fn beginFrame(t: f64) void {
    const d: f32 = @floatCast(t - now);
    // primeiro quadro, ou o primeiro depois de dormir (o laço parado e um
    // clique): um passo normal. Contar o tempo dormido fazia a animação dar um
    // salto de metade do caminho no começo (o "solavanco" do painel abrindo)
    dt = if (now == 0 or d <= 0 or d > 0.1) 1.0 / 60.0 else @min(d, 1.0 / 30.0);
    now = t;
    moving = false;
    frame_no +%= 1;
}

pub fn time() f64 {
    return now;
}

/// Vai e volta com começo e fim suaves (o painel do lado): de `from` até
/// `to` em `secs`, contando de `t0`. Pede quadro enquanto não chega.
pub fn tween(from: f32, to: f32, t0: f64, secs: f32) f32 {
    if (reduce_motion or secs <= 0) return to;
    const t: f32 = @floatCast(std.math.clamp((now - t0) / secs, 0, 1));
    if (t < 1) moving = true;
    // ease-in-out cúbica
    const e = if (t < 0.5) 4 * t * t * t else 1 - std.math.pow(f32, -2 * t + 2, 3) / 2;
    return from + (to - from) * e;
}

const Slot = struct { id: u32 = 0, v: f32 = 0, used: u32 = 0 };
var slots = [_]Slot{.{}} ** 512;

/// Id de animação a partir de um texto (o mesmo id de um botão serve).
pub fn idOf(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |ch| {
        h ^= ch;
        h *%= 16777619;
    }
    return if (h == 0) 1 else h;
}

/// Mistura dois ids (ex.: id do botão + id da janela).
pub fn idMix(a: u32, b: u32) u32 {
    const h = (a ^ (b *% 0x9E3779B1)) *% 0x85EBCA77;
    return if (h == 0) 1 else h;
}

fn slotFor(id: u32, start: f32) *Slot {
    var i: usize = id % slots.len;
    var oldest: usize = i;
    var probe: usize = 0;
    while (probe < 8) : (probe += 1) {
        const s = &slots[i];
        if (s.id == id) return s;
        if (s.id == 0) {
            s.* = .{ .id = id, .v = start, .used = frame_no };
            return s;
        }
        if (frame_no -% s.used > frame_no -% slots[oldest].used) oldest = i;
        i = (i + 1) % slots.len;
    }
    // tabela cheia por perto: reaproveita o que está há mais tempo sem uso
    slots[oldest] = .{ .id = id, .v = start, .used = frame_no };
    return &slots[oldest];
}

/// Valor que anda suavemente até `target` (sem passar). `speed`: quanto maior,
/// mais rápido (10 ≈ 90% em 0,23 s). Começa em `target` na primeira vez.
/// Perto o bastante pra parar: em fração (0 a 1: cor, opacidade) quase nada
/// se vê abaixo de 1%; em pixels (posição da linha das abas), um quarto de
/// pixel. Mais fino que isso, a animação pedia quadro por meio segundo a mais
/// depois de já parecer parada.
fn settleEps(target: f32, v: f32) f32 {
    return if (@abs(target) > 2 or @abs(v) > 2) 0.25 else 0.008;
}

pub fn smooth(id: u32, target: f32, speed: f32) f32 {
    const s = slotFor(id, target);
    s.used = frame_no;
    if (reduce_motion) {
        s.v = target;
        return target;
    }
    const k = 1 - @exp(-speed * dt);
    s.v += (target - s.v) * k;
    if (@abs(target - s.v) < settleEps(target, s.v)) s.v = target else moving = true;
    return s.v;
}

/// Como `smooth`, mas começando de `from` na primeira vez (entrada de um painel,
/// de um aviso): aparece animando em vez de já pronto.
pub fn enter(id: u32, from: f32, target: f32, speed: f32) f32 {
    const s = slotFor(id, from);
    s.used = frame_no;
    if (reduce_motion) {
        s.v = target;
        return target;
    }
    const k = 1 - @exp(-speed * dt);
    s.v += (target - s.v) * k;
    if (@abs(target - s.v) < settleEps(target, s.v)) s.v = target else moving = true;
    return s.v;
}

/// Esquece o valor (a próxima `enter` começa do começo: o aviso reaparecendo).
pub fn reset(id: u32) void {
    var i: usize = id % slots.len;
    var probe: usize = 0;
    while (probe < 8) : (probe += 1) {
        if (slots[i].id == id) {
            slots[i] = .{};
            return;
        }
        i = (i + 1) % slots.len;
    }
}

// ---------------------------------------------------------------------------
// Desenho

fn v2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

/// A mesma cor com o alfa multiplicado por k (0..1).
pub fn fade(color: u32, k: f32) u32 {
    const a8: f32 = @floatFromInt((color >> 24) & 0xFF);
    const na: u32 = @intFromFloat(std.math.clamp(a8 * k, 0, 255));
    return (color & 0x00FFFFFF) | (na << 24);
}

/// Mistura duas cores ABGR (t = 0: a, t = 1: b), canal a canal (alfa junto).
pub fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (0..4) |i| {
        const sh: u5 = @intCast(i * 8);
        const ca: f32 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f32 = @floatFromInt((b >> sh) & 0xFF);
        const v: u32 = @intFromFloat(std.math.clamp(@round(ca + (cb - ca) * t), 0, 255));
        out |= v << sh;
    }
    return out;
}

pub const Dir = enum { horizontal, vertical, diagonal };

/// Retângulo arredondado com degradê de `c0` pra `c1` (o alfa de cada cor vale).
pub fn gradRect(d: *c.ImDrawList, x0: f32, y0: f32, x1: f32, y1: f32, c0: u32, c1: u32, rounding: f32, dir: Dir) void {
    if (x1 <= x0 or y1 <= y0) return;
    if (flat) {
        // a base é a segunda cor (a primeira é o toque de luz); a linha que
        // some nas pontas (edgeLine) usa a mais forte das duas
        const base = if ((c1 >> 24) >= (c0 >> 24)) c1 else c0;
        c.ImDrawList_AddRectFilled(d, v2(x0, y0), v2(x1, y1), base, rounding, 0);
        return;
    }
    if (c0 == c1) {
        c.ImDrawList_AddRectFilled(d, v2(x0, y0), v2(x1, y1), c0, rounding, 0);
        return;
    }
    // desenha opaco em branco e pinta os vértices com o degradê; o alfa vem
    // de cada ponta (o ShadeVerts mantém o alfa do vértice: por isso branco
    // com o alfa médio e depois o alfa certo por vértice)
    const start = d.*.VtxBuffer.Size;
    c.ImDrawList_AddRectFilled(d, v2(x0, y0), v2(x1, y1), 0xFFFFFFFF, rounding, 0);
    const end = d.*.VtxBuffer.Size;
    const p0 = v2(x0, y0);
    const p1 = switch (dir) {
        .horizontal => v2(x1, y0),
        .vertical => v2(x0, y1),
        .diagonal => v2(x1, y1),
    };
    c.igShadeVertsLinearColorGradientKeepAlpha(d, start, end, p0, p1, c0 | 0xFF000000, c1 | 0xFF000000);
    // alfa por vértice (a mesma projeção do degradê)
    const a0: f32 = @floatFromInt((c0 >> 24) & 0xFF);
    const a1: f32 = @floatFromInt((c1 >> 24) & 0xFF);
    if (a0 == 255 and a1 == 255) return;
    const gx = p1.x - p0.x;
    const gy = p1.y - p0.y;
    const len2 = @max(gx * gx + gy * gy, 0.0001);
    const vtx: [*]c.ImDrawVert = @ptrCast(d.*.VtxBuffer.Data);
    var i: usize = @intCast(start);
    while (i < @as(usize, @intCast(end))) : (i += 1) {
        const v = &vtx[i];
        const t = std.math.clamp(((v.pos.x - p0.x) * gx + (v.pos.y - p0.y) * gy) / len2, 0, 1);
        // multiplica o alfa que já está lá: a borda suavizada (alfa 0) continua suave
        const old: f32 = @floatFromInt(v.col >> 24);
        const a: u32 = @intFromFloat(@round((a0 + (a1 - a0) * t) * old / 255));
        v.col = (v.col & 0x00FFFFFF) | (a << 24);
    }
}

/// Sombra suave em volta de um retângulo arredondado: camadas que somem pra
/// fora. `size` em pixels; `color` com o alfa do miolo.
pub fn shadow(d: *c.ImDrawList, x0: f32, y0: f32, x1: f32, y1: f32, rounding: f32, size: f32, color: u32) void {
    // cada camada é um contorno arredondado (centenas de vértices nos cantos
    // grandes): o tema chapado vai com duas, os outros com quatro
    const layers: f32 = if (flat) 2 else 4;
    const a: f32 = @floatFromInt((color >> 24) & 0xFF);
    var i: f32 = 0;
    while (i < layers) : (i += 1) {
        // a camada de dentro mais forte, as de fora sumindo
        const o = size * (i + 1) / layers;
        const f = 1 - i / layers;
        const ca: u32 = @intFromFloat(@round(a * f * f / 2.4));
        if (ca == 0) continue;
        c.ImDrawList_AddRect(d, v2(x0 - o, y0 - o), v2(x1 + o, y1 + o), (color & 0x00FFFFFF) | (ca << 24), rounding + o, size / layers + 0.5, 0);
    }
}

/// Brilho colorido em volta (neon): como a sombra, na cor do destaque.
pub fn glow(d: *c.ImDrawList, x0: f32, y0: f32, x1: f32, y1: f32, rounding: f32, size: f32, color: u32, strength: f32) void {
    if (strength <= 0.01 or size <= 0) return;
    shadow(d, x0, y0, x1, y1, rounding, size, fade(color, std.math.clamp(strength, 0, 1)));
}

/// Linha fina com degradê que some nas pontas (a borda neon das barras).
pub fn edgeLine(d: *c.ImDrawList, x0: f32, x1: f32, y: f32, thick: f32, c0: u32, c1: u32) void {
    if (x1 <= x0 or flat) return;
    const mid = (x0 + x1) / 2;
    gradRect(d, x0, y, mid, y + thick, fade(c0, 0), c0, 0, .horizontal);
    gradRect(d, mid, y, x1, y + thick, c1, fade(c1, 0), 0, .horizontal);
}

test "fx: depois de dormir não salta; o painel vai e volta sem passar do ponto; pixel para logo" {
    // parado 3 s e um clique: o primeiro passo é de um quadro, não de meio caminho
    beginFrame(10.0);
    const id = idOf("salto");
    _ = smooth(id, 0, 13);
    beginFrame(13.0);
    const first = smooth(id, 1, 13);
    try std.testing.expect(first > 0 and first < 0.25);
    // a curva do painel: começa devagar, nunca passa de 1 e chega em 0,26 s
    var t: f64 = 20.0;
    beginFrame(t);
    const t0 = t;
    var last: f32 = 0;
    var steps: usize = 0;
    while (t - t0 < 0.3) : (t += 1.0 / 60.0) {
        beginFrame(t);
        const k = tween(0, 1, t0, 0.26);
        try std.testing.expect(k >= last and k <= 1);
        if (steps == 1) try std.testing.expect(k < 0.05);
        last = k;
        steps += 1;
    }
    try std.testing.expectEqual(@as(f32, 1), last);
    // a linha das abas (pixels): para em menos de meio segundo
    const px = idOf("linha");
    beginFrame(t);
    _ = smooth(px, 100, 16);
    var frames: usize = 0;
    while (frames < 60) : (frames += 1) {
        t += 1.0 / 60.0;
        beginFrame(t);
        if (smooth(px, 400, 16) == 400) break;
    }
    try std.testing.expect(frames < 30);
}

test "fx: animação chega no alvo e para; reduzir movimento vai direto" {
    beginFrame(1.0);
    const id = idOf("teste");
    try std.testing.expectEqual(@as(f32, 0), smooth(id, 0, 10));
    var t: f64 = 1.0;
    var v: f32 = 0;
    for (0..120) |_| {
        t += 1.0 / 60.0;
        beginFrame(t);
        v = smooth(id, 1, 12);
    }
    try std.testing.expectEqual(@as(f32, 1), v);
    try std.testing.expect(!moving);
    t += 1.0 / 60.0;
    beginFrame(t);
    const half = smooth(id, 0, 12);
    try std.testing.expect(half > 0 and half < 1 and moving);
    reduce_motion = true;
    defer reduce_motion = false;
    try std.testing.expectEqual(@as(f32, 0), smooth(id, 0, 12));
    try std.testing.expectEqual(@as(u32, 127), fade(0xFFFFFFFF, 0.5) >> 24);
    try std.testing.expectEqual(@as(u32, 0xFF808080), mix(0xFF000000, 0xFFFFFFFF, 0.5) | 0xFF000000);
}
