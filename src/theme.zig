//! Temas da interface: a paleta que ui.zig usa (`ui.col`) e a lista de temas
//! que dá pra escolher nas configurações (troca na hora).

const std = @import("std");

/// Cor no formato do ImGui (ABGR).
pub fn rgba(comptime hex: u24, comptime a: u8) u32 {
    const r: u32 = (hex >> 16) & 0xff;
    const g: u32 = (hex >> 8) & 0xff;
    const b: u32 = hex & 0xff;
    return (@as(u32, a) << 24) | (b << 16) | (g << 8) | r;
}
pub fn rgb(comptime hex: u24) u32 {
    return rgba(hex, 255);
}

/// A mesma cor com outra transparência.
pub fn withAlpha(color: u32, a: u8) u32 {
    return (color & 0x00FF_FFFF) | (@as(u32, a) << 24);
}

/// Luminância relativa (sRGB, 0..1) de uma cor ABGR.
pub fn luminance(color: u32) f32 {
    const ch = struct {
        fn lin(v: u32) f32 {
            const s = @as(f32, @floatFromInt(v & 0xff)) / 255.0;
            return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
        }
    }.lin;
    return 0.2126 * ch(color) + 0.7152 * ch(color >> 8) + 0.0722 * ch(color >> 16);
}

/// Texto que aparece melhor em cima dessa cor: branco ou quase preto.
pub fn textOn(fill: u32) u32 {
    const l = luminance(fill);
    const vs_white = 1.05 / (l + 0.05);
    const vs_dark = (l + 0.05) / (luminance(dark_text) + 0.05);
    return if (vs_dark > vs_white) dark_text else rgb(0xFFFFFF);
}
const dark_text = rgb(0x111214);

pub const Palette = struct {
    bg_dark: u32, // tela inicial, fundo mais escuro
    bg_side: u32, // barra lateral
    bg_main: u32, // área principal
    bg_user: u32, // barra do usuário (embaixo da lateral)
    bg_float: u32, // dicas, menus, popups
    input: u32,
    chat_input: u32,
    hover: u32,
    selected: u32,
    text: u32,
    muted: u32,
    faint: u32,
    header: u32, // títulos e nomes
    blurple: u32, // cor de destaque (botão principal)
    blurple_hover: u32,
    blurple_active: u32,
    green: u32,
    green_hover: u32,
    green_active: u32,
    red: u32,
    red_hover: u32,
    red_active: u32,
    leave: u32, // fundo do botão de sair da sala
    yellow: u32,
    button: u32, // botão secundário
    button_hover: u32,
    button_active: u32,
    check: u32, // marca da caixinha de seleção
    scroll: u32,
    scroll_hover: u32,
    home_grad: [4]u32, // degradê da tela inicial (cantos: ↖ ↗ ↘ ↙)
    round: f32 = 1, // fator dos cantos arredondados
    black: u32 = rgb(0x000000),
    white: u32 = rgb(0xFFFFFF),
    shadow: u32 = rgba(0x000000, 140),
    overlay: u32 = rgba(0x000000, 170),
    // dos temas em KDL (com padrão pros temas antigos e o personalizado)
    accent2: u32 = rgb(0x2DD4FF), // segunda cor de destaque (degradês, brilho)
    border: u32 = rgba(0xFFFFFF, 18), // contorno de painéis e cartões
    live: u32 = rgb(0xF2445F), // ao vivo
    glow: f32 = 0.5, // força do brilho neon (0 = nenhum)
    border_w: f32 = 1, // espessura dos contornos (alto contraste: 2)
    pattern: Pattern = .none, // desenho parado no fundo do palco
    pattern_color: u32 = 0,
    pattern_size: f32 = 28,
    light: bool = false,
};

pub const Pattern = enum(u8) { none, grid, dots, scanlines };

/// Famílias de fonte embutidas (ver fonts.zig).
pub const Font = enum(u8) {
    inter,
    atkinson,
    fira,

    pub fn fromName(name: []const u8) ?Font {
        const t = std.mem.trim(u8, name, " ");
        if (std.ascii.eqlIgnoreCase(t, "inter")) return .inter;
        if (std.ascii.startsWithIgnoreCase(t, "atkinson")) return .atkinson;
        if (std.ascii.startsWithIgnoreCase(t, "fira") or std.ascii.eqlIgnoreCase(t, "mono") or std.ascii.eqlIgnoreCase(t, "monospace")) return .fira;
        return null;
    }
    pub fn label(f: Font) [:0]const u8 {
        return switch (f) {
            .inter => "Inter",
            .atkinson => "Atkinson Hyperlegible",
            .fira => "Fira Code",
        };
    }
    /// id do config.ini
    pub fn id(f: Font) []const u8 {
        return switch (f) {
            .inter => "inter",
            .atkinson => "atkinson",
            .fira => "fira",
        };
    }
};

pub const Theme = struct {
    id: []const u8, // o que vai pro config.ini (o nome do arquivo, sem .kdl)
    name: []const u8,
    name_en: []const u8 = "",
    description: []const u8 = "",
    description_en: []const u8 = "",
    author: []const u8 = "",
    pal: Palette,
    font_ui: Font = .inter,
    font_heading: Font = .inter,
    font_mono: Font = .fira,
    font_size: f32 = 15,
    path: []const u8 = "", // tema da pasta temas/ (vazio = embutido)

    pub fn displayName(t: *const Theme, english: bool) []const u8 {
        return if (english and t.name_en.len > 0) t.name_en else t.name;
    }
    pub fn displayDescription(t: *const Theme, english: bool) []const u8 {
        return if (english and t.description_en.len > 0) t.description_en else t.description;
    }
};

/// O tema de antes de carregar os arquivos (e se um arquivo embutido quebrar).
pub const fallback: Palette = .{
        .bg_dark = rgb(0x0D0F15),
        .bg_side = rgb(0x151823),
        .bg_main = rgb(0x11141C),
        .bg_user = rgb(0x1B1F2D),
        .bg_float = rgb(0x1D2232),
        .input = rgb(0x0B0D13),
        .chat_input = rgb(0x1E2333),
        .hover = rgb(0x232838),
        .selected = rgb(0x2C3248),
        .text = rgb(0xE3E6EE),
        .muted = rgb(0x979FB3),
        .faint = rgb(0x646C82),
        .header = rgb(0xF7F8FC),
        .blurple = rgb(0x7B5CFF),
        .blurple_hover = rgb(0x6A4AF0),
        .blurple_active = rgb(0x5A3CD6),
        .green = rgb(0x22A867),
        .green_hover = rgb(0x1B8D56),
        .green_active = rgb(0x167447),
        .red = rgb(0xF2445F),
        .red_hover = rgb(0xD03650),
        .red_active = rgb(0xB12A42),
        .leave = rgb(0x3A1E2A),
        .yellow = rgb(0xFFC24B),
        .button = rgb(0x2A3044),
        .button_hover = rgb(0x353C56),
        .button_active = rgb(0x424A69),
        .check = rgb(0xFFFFFF),
        .scroll = rgb(0x0B0D13),
        .scroll_hover = rgb(0x05060A),
        .home_grad = .{ rgb(0x0D0F15), rgb(0x1C1638), rgb(0x0D0F15), rgb(0x0B1B24) },
    };

/// Os temas que dá pra escolher: os embutidos (assets/temas/*.kdl, nessa ordem)
/// e os da pasta temas/ da configuração (um com o id de um embutido troca ele).
/// Vazio até o loadAll (antes disso, find devolve o fallback).
pub var list: []Theme = &.{};

const builtin_files = [_]struct { id: []const u8, src: []const u8 }{
    .{ .id = "escuro", .src = @embedFile("assets/temas/escuro.kdl") },
    .{ .id = "neon", .src = @embedFile("assets/temas/neon.kdl") },
    .{ .id = "pwnd", .src = @embedFile("assets/temas/pwnd.kdl") },
    .{ .id = "aurora", .src = @embedFile("assets/temas/aurora.kdl") },
    .{ .id = "alto-contraste", .src = @embedFile("assets/temas/alto-contraste.kdl") },
    .{ .id = "claro", .src = @embedFile("assets/temas/claro.kdl") },
    .{ .id = "pwnd-claro", .src = @embedFile("assets/temas/pwnd-claro.kdl") },
    .{ .id = "nord", .src = @embedFile("assets/temas/nord.kdl") },
    .{ .id = "dracula", .src = @embedFile("assets/temas/dracula.kdl") },
};

// ---------------------------------------------------------------------------
// Tema personalizado: poucas cores escolhidas (ou lidas de um CSS) e o resto
// da paleta derivado delas.

pub const custom_id = "personalizado";

pub const Base = struct {
    bg: u24 = 0x1E1F22, // fundo (o mais escuro, ou o mais claro num tema claro)
    side: u24 = 0x2B2D31, // painéis
    accent: u24 = 0x5865F2, // destaque (botão principal)
    accent2: u24 = 0x4752C4, // destaque com o mouse em cima
    text: u24 = 0xDBDEE1,
    ok: u24 = 0x23A55A,
    danger: u24 = 0xF23F43,
    square: bool = false, // cantos retos
    mono: bool = false, // fonte monoespaçada
};

fn rgbOf(hex: u24) [3]i32 {
    return .{ @intCast(hex >> 16), @intCast((hex >> 8) & 0xff), @intCast(hex & 0xff) };
}

/// Mistura `a` com `b` (t = 0 dá `a`, 1 dá `b`), em ABGR opaco.
fn mix(a: u24, b: u24, t: f32) u32 {
    const x = rgbOf(a);
    const y = rgbOf(b);
    var out: [3]u32 = undefined;
    for (0..3) |i| {
        const v = @as(f32, @floatFromInt(x[i])) + (@as(f32, @floatFromInt(y[i] - x[i]))) * t;
        out[i] = @intFromFloat(std.math.clamp(@round(v), 0, 255));
    }
    return 0xFF00_0000 | (out[2] << 16) | (out[1] << 8) | out[0];
}

fn abgr(hex: u24) u32 {
    const x = rgbOf(hex);
    return 0xFF00_0000 | (@as(u32, @intCast(x[2])) << 16) | (@as(u32, @intCast(x[1])) << 8) | @as(u32, @intCast(x[0]));
}

pub fn derive(b: Base) Palette {
    const dark = luminance(abgr(b.bg)) < 0.35;
    const ink: u24 = if (dark) 0xFFFFFF else 0x000000; // pra onde clarear/escurecer
    const shade: u24 = if (dark) 0x000000 else 0xFFFFFF;
    const main_ = mix(b.side, b.text, 0.03);
    const main24: u24 = @truncate(((main_ & 0xff) << 16) | (main_ & 0xff00) | ((main_ >> 16) & 0xff));
    return .{
        .bg_dark = abgr(b.bg),
        .bg_side = abgr(b.side),
        .bg_main = main_,
        .bg_user = mix(b.bg, b.side, 0.5),
        .bg_float = mix(b.bg, shade, 0.4),
        .input = abgr(b.bg),
        .chat_input = mix(b.side, b.text, 0.07),
        .hover = mix(main24, b.accent, 0.12),
        .selected = mix(main24, b.accent, 0.25),
        .text = abgr(b.text),
        .muted = mix(b.text, b.bg, 0.35),
        .faint = mix(b.text, b.bg, 0.55),
        .header = mix(b.text, ink, 0.5),
        .blurple = abgr(b.accent),
        .blurple_hover = abgr(b.accent2),
        .blurple_active = mix(b.accent, shade, 0.2),
        .green = abgr(b.ok),
        .green_hover = mix(b.ok, shade, 0.15),
        .green_active = mix(b.ok, shade, 0.3),
        .red = abgr(b.danger),
        .red_hover = mix(b.danger, shade, 0.15),
        .red_active = mix(b.danger, shade, 0.3),
        .leave = mix(b.bg, b.danger, 0.18),
        .yellow = if (dark) rgb(0xF0B232) else rgb(0xB57A0E),
        .button = mix(b.side, b.text, 0.14),
        .button_hover = mix(b.side, b.text, 0.22),
        .button_active = mix(b.side, b.text, 0.3),
        .check = abgr(b.accent2),
        .scroll = mix(b.side, b.text, 0.2),
        .scroll_hover = abgr(b.accent),
        .home_grad = .{ abgr(b.bg), mix(b.bg, b.accent, 0.1), abgr(b.bg), mix(b.bg, shade, 0.3) },
        .round = if (b.square) 0.25 else 1,
    };
}

/// "#rgb", "#rrggbb" ou "rgb(r, g, b)" → cor.
pub fn parseColor(v: []const u8) ?u24 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (t.len >= 4 and t[0] == '#') {
        const h = t[1..];
        const n: usize = if (h.len >= 6 and isHex(h[0..6])) 6 else if (isHex(h[0..3])) 3 else return null;
        const x = std.fmt.parseInt(u24, h[0..n], 16) catch return null;
        if (n == 6) return x;
        const r: u24 = (x >> 8) & 0xf;
        const g: u24 = (x >> 4) & 0xf;
        const bb: u24 = x & 0xf;
        return (r * 17) << 16 | (g * 17) << 8 | bb * 17;
    }
    if (std.mem.startsWith(u8, t, "rgb")) {
        const a = std.mem.indexOfScalar(u8, t, '(') orelse return null;
        const z = std.mem.indexOfScalarPos(u8, t, a, ')') orelse return null; // ")" antes do "(" = lixo
        var it = std.mem.tokenizeAny(u8, t[a + 1 .. z], ", /");
        var out: u24 = 0;
        for (0..3) |_| {
            const part = it.next() orelse return null;
            const n = std.fmt.parseInt(u8, part, 10) catch return null;
            out = (out << 8) | n;
        }
        return out;
    }
    return null;
}

fn isHex(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// Lê as variáveis de cor de um CSS (a primeira definição de cada uma, ou
/// seja, a do :root) e monta o tema pelos nomes: fundo, painel, destaque,
/// texto, verde, vermelho. null = não achou nem o fundo nem o destaque.
pub fn parseCss(css: []const u8) ?Base {
    const Var = struct { name: []const u8, color: u24 };
    var vars: [64]Var = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, css, i, "--")) |at| {
        i = at + 2;
        const colon = std.mem.indexOfScalarPos(u8, css, at, ':') orelse break;
        const name = std.mem.trim(u8, css[at + 2 .. colon], " \t");
        if (name.len == 0 or name.len > 40 or std.mem.indexOfAny(u8, name, " ;{}()\n") != null) continue;
        const end = std.mem.indexOfAnyPos(u8, css, colon, ";}\n") orelse css.len;
        const color = parseColor(css[colon + 1 .. end]) orelse continue;
        // a primeira definição vale (o :root vem antes das variantes)
        const seen = for (vars[0..n]) |v| {
            if (std.ascii.eqlIgnoreCase(v.name, name)) break true;
        } else false;
        if (seen or n == vars.len) continue;
        vars[n] = .{ .name = name, .color = color };
        n += 1;
    }
    const pick = struct {
        fn f(vs: []const Var, keys: []const []const u8, avoid: []const []const u8) ?u24 {
            for (keys) |k| {
                for (vs) |v| {
                    if (std.ascii.indexOfIgnoreCase(v.name, k) == null) continue;
                    const bad = for (avoid) |x| {
                        if (std.ascii.indexOfIgnoreCase(v.name, x) != null) break true;
                    } else false;
                    if (!bad) return v.color;
                }
            }
            return null;
        }
    }.f;
    const found = vars[0..n];
    const bg = pick(found, &.{ "bg-dark", "background", "bg-main", "bg", "base" }, &.{ "card", "text", "hover", "surface" }) orelse return null;
    const accent = pick(found, &.{ "primary", "accent", "purple", "brand", "violet", "blue", "neon", "cyan" }, &.{ "text", "bg", "hover", "fuchsia", "pink" }) orelse return null;
    var b: Base = .{ .bg = bg, .accent = accent };
    b.side = pick(found, &.{ "bg-card", "card", "surface", "panel", "side", "bg-2", "secondary-bg" }, &.{"text"}) orelse @truncate(blend(bg, 0xFFFFFF, 0.04));
    b.accent2 = pick(found, &.{ "fuchsia", "pink", "hover", "secondary", "accent-2", "magenta" }, &.{ "text", "bg" }) orelse accent;
    const dark = luminance(abgr(bg)) < 0.35;
    b.text = pick(found, &.{ "text-main", "text", "foreground", "fg" }, &.{ "dim", "muted", "faint" }) orelse (if (dark) 0xE5E7EB else 0x111827);
    b.ok = pick(found, &.{ "green", "success", "ok" }, &.{}) orelse 0x23A55A;
    b.danger = pick(found, &.{ "red", "danger", "error", "rose" }, &.{}) orelse 0xF23F43;
    return b;
}

fn blend(a: u24, b: u24, t: f32) u32 {
    const x = rgbOf(a);
    const y = rgbOf(b);
    var out: u32 = 0;
    for (0..3) |k| {
        const v = @as(f32, @floatFromInt(x[k])) + @as(f32, @floatFromInt(y[k] - x[k])) * t;
        out = (out << 8) | @as(u32, @intFromFloat(std.math.clamp(@round(v), 0, 255)));
    }
    return out;
}

/// O tema como CSS (pra mandar pra alguém ou guardar).
pub fn toCss(b: Base, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\:root {{
        \\  --bg: #{x:0>6};
        \\  --bg-card: #{x:0>6};
        \\  --accent: #{x:0>6};
        \\  --accent-hover: #{x:0>6};
        \\  --text: #{x:0>6};
        \\  --green: #{x:0>6};
        \\  --red: #{x:0>6};
        \\}}
        \\
    , .{ b.bg, b.side, b.accent, b.accent2, b.text, b.ok, b.danger }) catch "";
}

/// Pro config.ini: "bg,side,accent,accent2,text,ok,danger,square,mono" em hex.
pub fn encodeBase(b: Base, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>6},{x:0>6},{x:0>6},{x:0>6},{x:0>6},{x:0>6},{x:0>6},{d},{d}", .{ b.bg, b.side, b.accent, b.accent2, b.text, b.ok, b.danger, @intFromBool(b.square), @intFromBool(b.mono) }) catch "";
}

pub fn decodeBase(s: []const u8) Base {
    var b: Base = .{};
    var it = std.mem.splitScalar(u8, s, ',');
    const fields = [_]*u24{ &b.bg, &b.side, &b.accent, &b.accent2, &b.text, &b.ok, &b.danger };
    for (fields) |f| {
        const part = it.next() orelse return b;
        f.* = std.fmt.parseInt(u24, part, 16) catch f.*;
    }
    b.square = std.mem.eql(u8, it.next() orelse "0", "1");
    b.mono = std.mem.eql(u8, it.next() orelse "0", "1");
    return b;
}

/// Índice do tema pelo id (o primeiro se não achar).
pub fn find(id: []const u8) usize {
    for (list, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) return i;
    return 0;
}

// ---------------------------------------------------------------------------
// Temas em KDL (assets/temas/*.kdl e a pasta temas/ da configuração)

const kdl = @import("kdl.zig");
const builtin = @import("builtin");

/// O bloco `colors` de um tema enquanto as cores são lidas: cada nome com a
/// expressão; @nome resolve outra cor do mesmo bloco (sem ciclo).
const ColorCtx = struct {
    names: []const []const u8,
    exprs: []const []const u8,
    memo: []?u32,
    busy: []bool,

    fn index(ctx: *const ColorCtx, name: []const u8) ?usize {
        for (ctx.names, 0..) |n, i| if (sameKey(n, name)) return i;
        return null;
    }
    fn get(ctx: *ColorCtx, name: []const u8) ?u32 {
        const i = ctx.index(name) orelse return null;
        if (ctx.memo[i]) |v| return v;
        if (ctx.busy[i]) return null; // a = @b, b = @a
        ctx.busy[i] = true;
        defer ctx.busy[i] = false;
        const v = evalColor(ctx.exprs[i], ctx) orelse return null;
        ctx.memo[i] = v;
        return v;
    }
};

/// "accent-2", "accent_2" e "Accent2" são a mesma chave.
fn sameKey(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == '-' or a[i] == '_')) i += 1;
        while (j < b.len and (b[j] == '-' or b[j] == '_')) j += 1;
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
        i += 1;
        j += 1;
    }
}

/// Cor ABGR (com alfa) de uma expressão: "#rgb", "#rgba", "#rrggbb",
/// "#rrggbbaa", "rgb(r, g, b)", "rgba(r, g, b, a)", "white", "black",
/// "transparent", "@nome" e alpha(cor, a), mix(cor, cor, t), lighten(cor, t),
/// darken(cor, t). null = não entendeu.
pub fn evalColor(expr: []const u8, ctx: ?*ColorCtx) ?u32 {
    var e: Expr = .{ .s = expr, .ctx = ctx };
    const v = e.color() orelse return null;
    e.ws();
    if (e.i != e.s.len) return null;
    return v;
}

const Expr = struct {
    s: []const u8,
    i: usize = 0,
    ctx: ?*ColorCtx,
    depth: u8 = 0,

    fn ws(e: *Expr) void {
        while (e.i < e.s.len and (e.s[e.i] == ' ' or e.s[e.i] == '\t')) e.i += 1;
    }
    fn eat(e: *Expr, ch: u8) bool {
        e.ws();
        if (e.i < e.s.len and e.s[e.i] == ch) {
            e.i += 1;
            return true;
        }
        return false;
    }
    fn word(e: *Expr) []const u8 {
        e.ws();
        const start = e.i;
        while (e.i < e.s.len and (std.ascii.isAlphanumeric(e.s[e.i]) or e.s[e.i] == '-' or e.s[e.i] == '_')) e.i += 1;
        return e.s[start..e.i];
    }
    fn number(e: *Expr) ?f32 {
        e.ws();
        const start = e.i;
        while (e.i < e.s.len and (std.ascii.isDigit(e.s[e.i]) or e.s[e.i] == '.' or e.s[e.i] == '-' or e.s[e.i] == '+')) e.i += 1;
        var v = std.fmt.parseFloat(f32, e.s[start..e.i]) catch return null;
        if (e.i < e.s.len and e.s[e.i] == '%') {
            e.i += 1;
            v /= 100;
        }
        return v;
    }
    fn color(e: *Expr) ?u32 {
        if (e.depth > 16) return null;
        e.depth += 1;
        defer e.depth -= 1;
        e.ws();
        if (e.i >= e.s.len) return null;
        if (e.s[e.i] == '#') {
            e.i += 1;
            const start = e.i;
            while (e.i < e.s.len and std.ascii.isHex(e.s[e.i])) e.i += 1;
            return hexColor(e.s[start..e.i]);
        }
        if (e.s[e.i] == '@') {
            e.i += 1;
            const name = e.word();
            const ctx = e.ctx orelse return null;
            return ctx.get(name);
        }
        const w = e.word();
        if (std.ascii.eqlIgnoreCase(w, "white")) return 0xFFFFFFFF;
        if (std.ascii.eqlIgnoreCase(w, "black")) return 0xFF000000;
        if (std.ascii.eqlIgnoreCase(w, "transparent")) return 0;
        if (!e.eat('(')) return null;
        if (std.ascii.eqlIgnoreCase(w, "rgb") or std.ascii.eqlIgnoreCase(w, "rgba")) {
            var ch: [4]f32 = .{ 0, 0, 0, 1 };
            var n: usize = 0;
            while (n < 4) : (n += 1) {
                ch[n] = e.number() orelse return null;
                if (!e.eat(',')) break;
            }
            if (n < 2 or !e.eat(')')) return null;
            const a = if (n == 3) ch[3] else 1;
            return packColor(ch[0], ch[1], ch[2], a * 255);
        }
        const c1 = e.color() orelse return null;
        if (!e.eat(',')) return null;
        if (std.ascii.eqlIgnoreCase(w, "mix")) {
            const c2 = e.color() orelse return null;
            if (!e.eat(',')) return null;
            const t = e.number() orelse return null;
            if (!e.eat(')')) return null;
            return mixAbgr(c1, c2, std.math.clamp(t, 0, 1));
        }
        const t = e.number() orelse return null;
        if (!e.eat(')')) return null;
        const k = std.math.clamp(t, 0, 1);
        if (std.ascii.eqlIgnoreCase(w, "alpha")) return withAlpha(c1, @intFromFloat(@round(k * 255)));
        if (std.ascii.eqlIgnoreCase(w, "lighten")) return mixAbgr(c1, 0xFFFFFFFF, k) & 0x00FFFFFF | (c1 & 0xFF000000);
        if (std.ascii.eqlIgnoreCase(w, "darken")) return mixAbgr(c1, 0xFF000000, k) & 0x00FFFFFF | (c1 & 0xFF000000);
        return null;
    }
};

fn packColor(r: f32, g: f32, b: f32, a: f32) u32 {
    const f = struct {
        fn ch(v: f32) u32 {
            return @intFromFloat(std.math.clamp(@round(v), 0, 255));
        }
    }.ch;
    return (f(a) << 24) | (f(b) << 16) | (f(g) << 8) | f(r);
}

fn hexColor(h: []const u8) ?u32 {
    const x = std.fmt.parseInt(u32, h, 16) catch return null;
    return switch (h.len) {
        3 => packColor(@floatFromInt(((x >> 8) & 0xF) * 17), @floatFromInt(((x >> 4) & 0xF) * 17), @floatFromInt((x & 0xF) * 17), 255),
        4 => packColor(@floatFromInt(((x >> 12) & 0xF) * 17), @floatFromInt(((x >> 8) & 0xF) * 17), @floatFromInt(((x >> 4) & 0xF) * 17), @floatFromInt((x & 0xF) * 17)),
        6 => packColor(@floatFromInt((x >> 16) & 0xFF), @floatFromInt((x >> 8) & 0xFF), @floatFromInt(x & 0xFF), 255),
        8 => packColor(@floatFromInt((x >> 24) & 0xFF), @floatFromInt((x >> 16) & 0xFF), @floatFromInt((x >> 8) & 0xFF), @floatFromInt(x & 0xFF)),
        else => null,
    };
}

/// Mistura duas cores ABGR (alfa junto).
fn mixAbgr(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (0..4) |k| {
        const sh: u5 = @intCast(k * 8);
        const ca: f32 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f32 = @floatFromInt((b >> sh) & 0xFF);
        out |= @as(u32, @intFromFloat(std.math.clamp(@round(ca + (cb - ca) * t), 0, 255))) << sh;
    }
    return out;
}

/// ABGR → 0xRRGGBB (sem alfa), pra Base.
fn hex24(c: u32) u24 {
    return @intCast(((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF));
}

/// Cada chave do bloco `colors` e o campo da paleta que ela troca.
const color_keys = [_]struct { key: []const u8, field: []const u8 }{
    .{ .key = "bg", .field = "bg_dark" },
    .{ .key = "panel", .field = "bg_side" },
    .{ .key = "surface", .field = "bg_main" },
    .{ .key = "elevated", .field = "bg_user" },
    .{ .key = "float", .field = "bg_float" },
    .{ .key = "input", .field = "input" },
    .{ .key = "chat-input", .field = "chat_input" },
    .{ .key = "hover", .field = "hover" },
    .{ .key = "selected", .field = "selected" },
    .{ .key = "text", .field = "text" },
    .{ .key = "muted", .field = "muted" },
    .{ .key = "faint", .field = "faint" },
    .{ .key = "heading", .field = "header" },
    .{ .key = "accent", .field = "blurple" },
    .{ .key = "accent-hover", .field = "blurple_hover" },
    .{ .key = "accent-active", .field = "blurple_active" },
    .{ .key = "success", .field = "green" },
    .{ .key = "success-hover", .field = "green_hover" },
    .{ .key = "success-active", .field = "green_active" },
    .{ .key = "danger", .field = "red" },
    .{ .key = "danger-hover", .field = "red_hover" },
    .{ .key = "danger-active", .field = "red_active" },
    .{ .key = "leave", .field = "leave" },
    .{ .key = "warning", .field = "yellow" },
    .{ .key = "button", .field = "button" },
    .{ .key = "button-hover", .field = "button_hover" },
    .{ .key = "button-active", .field = "button_active" },
    .{ .key = "check", .field = "check" },
    .{ .key = "scroll", .field = "scroll" },
    .{ .key = "scroll-hover", .field = "scroll_hover" },
    .{ .key = "accent-2", .field = "accent2" },
    .{ .key = "border", .field = "border" },
    .{ .key = "live", .field = "live" },
    .{ .key = "shadow", .field = "shadow" },
    .{ .key = "overlay", .field = "overlay" },
};

pub const LoadError = struct { file: []const u8, line: u32, msg: []const u8 };

/// Lê um tema. `id`: o nome do arquivo (o `theme "id"` do arquivo, se tiver,
/// ganha). As sete de base (bg, panel, accent, accent-hover, text, success,
/// danger) montam a paleta inteira; qualquer outra chave troca a sua parte.
pub fn fromKdl(a: std.mem.Allocator, src: []const u8, id: []const u8, err: *LoadError) !Theme {
    var diag: kdl.Diag = .{};
    var doc = kdl.parse(a, src, &diag) catch |e| {
        err.* = .{ .file = id, .line = diag.line, .msg = if (e == error.TooDeep) "blocos dentro de blocos demais" else diag.msg };
        return error.Syntax;
    };
    // a arena do documento vira parte da arena de quem chamou (os textos ficam)
    const head = doc.find("theme");
    var t: Theme = .{ .id = id, .name = id, .pal = fallback };
    if (head) |h| {
        if (h.argStr(0)) |tid| if (tid.len > 0 and tid.len <= 48) {
            t.id = tid;
        };
        t.name = h.propStr("name") orelse t.id;
        t.name_en = h.propStr("name-en") orelse "";
        t.description = h.propStr("description") orelse "";
        t.description_en = h.propStr("description-en") orelse "";
        t.author = h.propStr("author") orelse "";
    }
    // cores
    if (doc.find("colors")) |cb| {
        const n = cb.children.len;
        const names = try a.alloc([]const u8, n);
        const exprs = try a.alloc([]const u8, n);
        const memo = try a.alloc(?u32, n);
        const busy = try a.alloc(bool, n);
        for (cb.children, 0..) |*ch, i| {
            names[i] = ch.name;
            exprs[i] = ch.argStr(0) orelse "";
            memo[i] = null;
            busy[i] = false;
        }
        var ctx: ColorCtx = .{ .names = names, .exprs = exprs, .memo = memo, .busy = busy };
        // toda cor tem que fazer sentido: o erro diz qual
        for (names, 0..) |nm, i| if (ctx.get(nm) == null) {
            err.* = .{ .file = id, .line = 0, .msg = try std.fmt.allocPrint(a, "a cor \"{s}\" ({s}) não deu pra entender", .{ nm, exprs[i] }) };
            return error.BadColor;
        };
        const bg = ctx.get("bg") orelse abgr(0x0D0F15);
        const text = ctx.get("text") orelse (if (luminance(bg) < 0.35) abgr(0xE3E6EE) else abgr(0x111214));
        const dark = luminance(bg) < 0.35;
        const accent = ctx.get("accent") orelse abgr(0x7B5CFF);
        const ink: u32 = if (dark) 0xFFFFFFFF else 0xFF000000;
        const base: Base = .{
            .bg = hex24(bg),
            .side = hex24(ctx.get("panel") orelse mixAbgr(bg, text, 0.04)),
            .accent = hex24(accent),
            .accent2 = hex24(ctx.get("accent-hover") orelse mixAbgr(accent, ink, 0.14)),
            .text = hex24(text),
            .ok = hex24(ctx.get("success") orelse abgr(0x23A55A)),
            .danger = hex24(ctx.get("danger") orelse abgr(0xF23F43)),
        };
        t.pal = derive(base);
        t.pal.light = !dark;
        t.pal.accent2 = ctx.get("accent-2") orelse mixAbgr(accent, abgr(0x2DD4FF), 0.6);
        t.pal.border = ctx.get("border") orelse withAlpha(text, 18);
        t.pal.live = ctx.get("live") orelse t.pal.red;
        inline for (color_keys) |ck| {
            if (ctx.get(ck.key)) |v| @field(t.pal, ck.field) = v;
        }
        // "elevated" sozinho vale pro campo do chat também
        if (ctx.index("elevated") != null and ctx.index("chat-input") == null) t.pal.chat_input = t.pal.bg_user;
    }
    if (doc.find("background")) |bgn| {
        if (bgn.propStr("gradient")) |g| {
            var cols: [4]u32 = undefined;
            var n: usize = 0;
            var it = std.mem.tokenizeScalar(u8, g, ' ');
            while (it.next()) |part| {
                if (n == 4) break;
                cols[n] = evalColor(part, null) orelse {
                    err.* = .{ .file = id, .line = 0, .msg = "o degradê do fundo tem uma cor que não deu pra entender (use #rrggbb separadas por espaço)" };
                    return error.BadColor;
                };
                n += 1;
            }
            if (n == 1) cols = .{ cols[0], cols[0], cols[0], cols[0] };
            if (n == 2) cols = .{ cols[0], cols[1], cols[0], cols[1] };
            if (n == 3) cols[3] = cols[0];
            if (n > 0) t.pal.home_grad = cols;
        }
        if (bgn.propStr("pattern")) |pn| t.pal.pattern = std.meta.stringToEnum(Pattern, pn) orelse .none;
        if (bgn.propStr("pattern-color")) |pc| t.pal.pattern_color = evalColor(pc, null) orelse withAlpha(t.pal.blurple, 14);
        if (bgn.propNum("pattern-size")) |ps| t.pal.pattern_size = @floatCast(std.math.clamp(ps, 8, 128));
        if (t.pal.pattern != .none and t.pal.pattern_color == 0) t.pal.pattern_color = withAlpha(t.pal.blurple, 14);
    }
    if (doc.find("fonts")) |f| {
        if (f.propStr("ui")) |v| t.font_ui = Font.fromName(v) orelse t.font_ui;
        t.font_heading = t.font_ui;
        if (f.propStr("heading")) |v| t.font_heading = Font.fromName(v) orelse t.font_heading;
        if (f.propStr("mono")) |v| t.font_mono = Font.fromName(v) orelse t.font_mono;
        if (f.propNum("size")) |v| t.font_size = @floatCast(std.math.clamp(v, 11, 24));
    }
    if (doc.find("metrics")) |m| {
        if (m.propNum("radius")) |r| t.pal.round = @floatCast(std.math.clamp(r / 5.0, 0, 4));
        if (m.propNum("border")) |b| t.pal.border_w = @floatCast(std.math.clamp(b, 0.5, 4));
    }
    if (doc.find("effects")) |fx| {
        if (fx.propNum("glow")) |g| t.pal.glow = @floatCast(std.math.clamp(g, 0, 1.5));
    }
    return t;
}

var registry_arena: ?std.heap.ArenaAllocator = null;
/// Erros do último loadAll (arquivo, linha, o quê), pra tela de temas mostrar.
pub var load_errors: [8]LoadError = undefined;
pub var n_load_errors: usize = 0;

/// (Re)carrega os temas: os embutidos e os .kdl de `user_dir` (vazio = só os
/// embutidos). Só a thread da interface chama; a paleta em uso é uma cópia.
pub fn loadAll(gpa: std.mem.Allocator, user_dir: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    var out: std.ArrayList(Theme) = .empty;
    n_load_errors = 0;
    for (builtin_files) |bf| {
        var e: LoadError = .{ .file = bf.id, .line = 0, .msg = "" };
        const t = fromKdl(a, bf.src, bf.id, &e) catch {
            noteError(e);
            continue;
        };
        out.append(a, t) catch break;
    }
    if (user_dir.len > 0) {
        var ctx: UserLoad = .{ .a = a, .out = &out };
        forEachKdl(a, user_dir, &ctx, UserLoad.add);
    }
    if (out.items.len == 0) out.append(a, .{ .id = "escuro", .name = "Escuro", .name_en = "Dark", .pal = fallback }) catch {};
    list = out.items;
    if (registry_arena) |*old| old.deinit();
    registry_arena = arena;
}

fn noteError(e: LoadError) void {
    if (n_load_errors < load_errors.len) {
        load_errors[n_load_errors] = e;
        n_load_errors += 1;
    }
}

const UserLoad = struct {
    a: std.mem.Allocator,
    out: *std.ArrayList(Theme),

    fn add(ctx: *UserLoad, path: [:0]const u8, stem: []const u8) void {
        const src = readSmallFile(ctx.a, path, 256 * 1024) orelse {
            noteError(.{ .file = ctx.a.dupe(u8, stem) catch stem, .line = 0, .msg = "não consegui ler o arquivo" });
            return;
        };
        const id = ctx.a.dupe(u8, stem) catch return;
        var e: LoadError = .{ .file = id, .line = 0, .msg = "" };
        var t = fromKdl(ctx.a, src, id, &e) catch {
            noteError(e);
            return;
        };
        t.path = ctx.a.dupe(u8, path) catch "";
        // o mesmo id de um embutido: o do usuário troca ele (dá pra mexer num embutido copiando o arquivo)
        for (ctx.out.items) |*old| if (std.mem.eql(u8, old.id, t.id)) {
            old.* = t;
            return;
        };
        ctx.out.append(ctx.a, t) catch {};
    }
};

// ---------------------------------------------------------------- arquivos

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn _wfopen(path: [*:0]const u16, mode: [*:0]const u16) ?*anyopaque;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, attr: ?*anyopaque) callconv(.winapi) c_int;

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
extern "kernel32" fn FindFirstFileW(name: [*:0]const u16, data: *WIN32_FIND_DATAW) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FindNextFileW(h: *anyopaque, data: *WIN32_FIND_DATAW) callconv(.winapi) c_int;
extern "kernel32" fn FindClose(h: *anyopaque) callconv(.winapi) c_int;

fn openFile(path: [:0]const u8, mode: [:0]const u8) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        var w: [1024:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&w, path) catch return null;
        if (n >= w.len) return null;
        w[n] = 0;
        var wm: [8:0]u16 = undefined;
        for (mode, 0..) |ch, i| wm[i] = ch;
        wm[mode.len] = 0;
        return _wfopen(&w, &wm);
    }
    return fopen(path.ptr, mode.ptr);
}

/// O arquivo inteiro (até `max` bytes; maior = null).
pub fn readSmallFile(a: std.mem.Allocator, path: [:0]const u8, max: usize) ?[]u8 {
    const f = openFile(path, "rb") orelse return null;
    defer _ = fclose(f);
    var buf = a.alloc(u8, max + 1) catch return null;
    var n: usize = 0;
    while (n < buf.len) {
        const got = fread(buf[n..].ptr, 1, buf.len - n, f);
        if (got == 0) break;
        n += got;
    }
    if (n > max) return null;
    return buf[0..n];
}

pub fn writeFile(path: [:0]const u8, data: []const u8) bool {
    const f = openFile(path, "wb") orelse return false;
    defer _ = fclose(f);
    return fwrite(data.ptr, 1, data.len, f) == data.len;
}

pub fn makeDir(path: [:0]const u8) void {
    if (builtin.os.tag == .windows) {
        var w: [1024:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&w, path) catch return;
        if (n >= w.len) return;
        w[n] = 0;
        _ = CreateDirectoryW(&w, null);
    } else _ = mkdir(path.ptr, 0o755);
}

/// Cada *.kdl de `dir` (em ordem de nome): f(ctx, caminho, nome sem .kdl).
fn forEachKdl(a: std.mem.Allocator, dir: []const u8, ctx: anytype, comptime f: anytype) void {
    var names: std.ArrayList([]const u8) = .empty;
    if (builtin.os.tag == .windows) {
        var pat_buf: [1100]u8 = undefined;
        const pat = std.fmt.bufPrint(&pat_buf, "{s}\\*.kdl", .{dir}) catch return;
        var w: [1100:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&w, pat) catch return;
        if (n >= w.len) return;
        w[n] = 0;
        var fd: WIN32_FIND_DATAW = undefined;
        const h = FindFirstFileW(&w, &fd) orelse return;
        if (@intFromPtr(h) == std.math.maxInt(usize)) return; // INVALID_HANDLE_VALUE
        defer _ = FindClose(h);
        while (true) {
            const wn = std.mem.sliceTo(&fd.cFileName, 0);
            if (fd.dwFileAttributes & 0x10 == 0) { // não é pasta
                if (std.unicode.utf16LeToUtf8Alloc(a, wn)) |u8name| names.append(a, u8name) catch {} else |_| {}
            }
            if (FindNextFileW(h, &fd) == 0) break;
        }
    } else {
        var zb: [1024]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&zb, "{s}", .{dir}) catch return;
        const d = std.c.opendir(dz.ptr) orelse return;
        defer _ = std.c.closedir(d);
        while (std.c.readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (name.len > 4 and std.ascii.endsWithIgnoreCase(name, ".kdl") and name[0] != '.') names.append(a, a.dupe(u8, name) catch continue) catch {};
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (names.items) |name| {
        if (name.len <= 4) continue;
        const stem = name[0 .. name.len - 4];
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        const path = std.fmt.allocPrintSentinel(a, "{s}{s}{s}", .{ dir, sep, name }, 0) catch continue;
        f(ctx, path, stem);
    }
}

/// O tema como arquivo KDL (todas as cores, pra copiar e mexer).
pub fn toKdl(a: std.mem.Allocator, t: *const Theme, new_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn hex(c: u32, buf: *[10]u8) []const u8 {
            const al = (c >> 24) & 0xFF;
            if (al == 255) return std.fmt.bufPrint(buf, "#{X:0>6}", .{hex24(c)}) catch "";
            return std.fmt.bufPrint(buf, "#{X:0>6}{X:0>2}", .{ hex24(c), al }) catch "";
        }
    };
    try out.print(a,
        \\// {s}: feito a partir do tema "{s}" do telinha. Mude o que quiser e salve:
        \\// o telinha atualiza sozinho. Cores: "#rrggbb", "#rrggbbaa", "alpha(@accent, 0.2)",
        \\// "mix(@bg, @text, 0.1)", "lighten(@accent, 0.1)", "darken(...)". Fontes: "Inter",
        \\// "Atkinson Hyperlegible" (a mais fácil de ler) ou "Fira Code". Guia em docs/THEMES.pt.md
        \\theme "{s}" name="{s}" author="você"
        \\
        \\colors {{
        \\
    , .{ new_id, t.id, new_id, new_id });
    var hb: [10]u8 = undefined;
    inline for (color_keys) |ck| {
        try out.print(a, "    {s} \"{s}\"\n", .{ ck.key, w.hex(@field(t.pal, ck.field), &hb) });
    }
    try out.appendSlice(a, "}\n");
    try out.print(a, "background gradient=\"", .{});
    for (t.pal.home_grad, 0..) |g, i| try out.print(a, "{s}{s}", .{ if (i > 0) " " else "", w.hex(g, &hb) });
    try out.print(a, "\" pattern={s}", .{@tagName(t.pal.pattern)});
    if (t.pal.pattern != .none) try out.print(a, " pattern-color=\"{s}\" pattern-size={d}", .{ w.hex(t.pal.pattern_color, &hb), t.pal.pattern_size });
    try out.print(a, "\nfonts ui=\"{s}\" heading=\"{s}\" mono=\"{s}\" size={d}\n", .{ t.font_ui.label(), t.font_heading.label(), t.font_mono.label(), t.font_size });
    try out.print(a, "metrics radius={d} border={d}\neffects glow={d}\n", .{ t.pal.round * 5, t.pal.border_w, t.pal.glow });
    return out.toOwnedSlice(a);
}

test "temas: os embutidos carregam e o texto fica legível em cima dos botões" {
    loadAll(std.testing.allocator, "");
    defer if (registry_arena) |*ar| {
        ar.deinit();
        registry_arena = null;
        list = &.{};
    };
    if (n_load_errors > 0) {
        std.debug.print("tema {s} linha {d}: {s}\n", .{ load_errors[0].file, load_errors[0].line, load_errors[0].msg });
        return error.TemaQuebrado;
    }
    try std.testing.expectEqual(builtin_files.len, list.len);
    for (list) |t| {
        for ([_]u32{ t.pal.blurple, t.pal.green, t.pal.red, t.pal.button, t.pal.blurple_hover, t.pal.red_hover }) |fill| {
            const fg = textOn(fill);
            const lf = luminance(fill);
            const lt = luminance(fg);
            const ratio = (@max(lf, lt) + 0.05) / (@min(lf, lt) + 0.05);
            if (ratio < 2.9) {
                std.debug.print("tema {s}: contraste {d:.2} no botão {x}\n", .{ t.id, ratio, fill });
                return error.PoucoContraste;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), find("pwnd"));
    try std.testing.expectEqual(@as(usize, 0), find("nao-existe"));
    // o pwnd lê bem (Atkinson no texto) e guarda o terminal nos títulos
    const pw = list[find("pwnd")];
    try std.testing.expectEqual(Font.atkinson, pw.font_ui);
    try std.testing.expectEqual(Font.fira, pw.font_heading);
    // as cores convertidas da 3.10 ficaram iguais
    try std.testing.expectEqual(rgb(0x9333EA), pw.pal.blurple);
    try std.testing.expectEqual(rgb(0x0A050F), pw.pal.bg_side);
    const ac = list[find("alto-contraste")];
    try std.testing.expect(ac.font_size >= 16 and ac.pal.border_w >= 2);
}

test "tema do CSS: as variáveis do pwnd.blog viram um tema legível" {
    const css =
        \\:root {
        \\  --neon-fuchsia: #d946ef;
        \\  --neon-purple: #9333ea;
        \\  --neon-blue: #06b6d4;
        \\  --terminal-green: #22c55e;
        \\  --bg-dark: #050505;
        \\  --bg-card: #0a050f;
        \\  --text-main: #e5e7eb;
        \\  --text-dim: #6b7280;
        \\}
        \\body.light-theme {
        \\  --neon-fuchsia: #7c3aed;
        \\  --bg-dark: #ffffff;
        \\}
    ;
    const b = parseCss(css).?;
    try std.testing.expectEqual(@as(u24, 0x050505), b.bg);
    try std.testing.expectEqual(@as(u24, 0x0a050f), b.side);
    try std.testing.expectEqual(@as(u24, 0x9333ea), b.accent);
    try std.testing.expectEqual(@as(u24, 0xd946ef), b.accent2);
    try std.testing.expectEqual(@as(u24, 0xe5e7eb), b.text);
    try std.testing.expectEqual(@as(u24, 0x22c55e), b.ok);
    const pal = derive(b);
    for ([_]u32{ pal.blurple, pal.green, pal.red, pal.button }) |fill| {
        const fg = textOn(fill);
        const lf = luminance(fill);
        const lt = luminance(fg);
        try std.testing.expect((@max(lf, lt) + 0.05) / (@min(lf, lt) + 0.05) >= 2.9);
    }
    // ida e volta pelo config.ini e pelo CSS exportado
    var buf: [256]u8 = undefined;
    const enc = encodeBase(b, &buf);
    const back = decodeBase(enc);
    try std.testing.expectEqual(b, back);
    var cb: [512]u8 = undefined;
    const again = parseCss(toCss(b, &cb)).?;
    try std.testing.expectEqual(b.bg, again.bg);
    try std.testing.expectEqual(b.accent, again.accent);
    try std.testing.expectEqual(b.accent2, again.accent2);
    try std.testing.expectEqual(b.text, again.text);
    try std.testing.expectEqual(@as(?u24, 0xaabbcc), parseColor(" #abc"));
    try std.testing.expectEqual(@as(?u24, 0x0a0b0c), parseColor("rgb(10, 11, 12)"));
    try std.testing.expect(parseCss("body { color: red; }") == null);
    try std.testing.expect(parseColor("rgb)(") == null); // malformado não quebra
    try std.testing.expect(parseCss(":root { --bg: rgb)(; --accent: #fff; }") == null);
}

test "temas: expressões de cor, referências e erros" {
    try std.testing.expectEqual(@as(?u32, rgb(0xAABBCC)), evalColor("#abc", null));
    try std.testing.expectEqual(@as(?u32, rgb(0x123456)), evalColor(" #123456 ", null));
    try std.testing.expectEqual(@as(?u32, rgba(0x123456, 0x80)), evalColor("#12345680", null));
    try std.testing.expectEqual(@as(?u32, rgba(0xFFFFFF, 128)), evalColor("alpha(white, 0.5)", null));
    try std.testing.expectEqual(@as(?u32, rgb(0x808080)), evalColor("mix(black, white, 0.5)", null));
    try std.testing.expectEqual(@as(?u32, rgba(0x0A0B0C, 255)), evalColor("rgb(10, 11, 12)", null));
    try std.testing.expectEqual(@as(?u32, rgba(0x0A0B0C, 128)), evalColor("rgba(10, 11, 12, 0.5)", null));
    try std.testing.expectEqual(@as(?u32, rgb(0x808080)), evalColor("lighten(black, 50%)", null));
    try std.testing.expect(evalColor("alpha(#fff)", null) == null);
    try std.testing.expect(evalColor("#12", null) == null);
    try std.testing.expect(evalColor("mix(#000, #fff, 0.5) lixo", null) == null);
    try std.testing.expect(evalColor("@accent", null) == null);
    const src =
        \\theme "meu" name="Meu tema"
        \\colors {
        \\    bg "#101010"
        \\    accent "#FF0000"
        \\    hover "alpha(@accent, 0.25)"
        \\    selected "mix(@bg, @accent, 0.5)"
        \\}
        \\fonts ui="Atkinson Hyperlegible" size=17
        \\metrics radius=10
        \\effects glow=0.8
        \\background gradient="#000 #111" pattern=grid
    ;
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    var e: LoadError = .{ .file = "", .line = 0, .msg = "" };
    const t = try fromKdl(ar.allocator(), src, "arquivo", &e);
    try std.testing.expectEqualStrings("meu", t.id);
    try std.testing.expectEqualStrings("Meu tema", t.name);
    try std.testing.expectEqual(rgb(0xFF0000), t.pal.blurple);
    try std.testing.expectEqual(rgba(0xFF0000, 64), t.pal.hover);
    try std.testing.expectEqual(rgb(0x880808), t.pal.selected);
    try std.testing.expectEqual(Font.atkinson, t.font_ui);
    try std.testing.expectEqual(Font.atkinson, t.font_heading); // sem heading: o mesmo do texto
    try std.testing.expectEqual(@as(f32, 17), t.font_size);
    try std.testing.expectEqual(@as(f32, 2), t.pal.round);
    try std.testing.expectEqual(Pattern.grid, t.pal.pattern);
    try std.testing.expect(t.pal.pattern_color != 0);
    // ciclo e cor ruim: erro dizendo qual
    try std.testing.expectError(error.BadColor, fromKdl(ar.allocator(), "colors {\n a \"@b\"\n b \"@a\"\n}", "x", &e));
    try std.testing.expect(std.mem.indexOf(u8, e.msg, "\"a\"") != null);
    try std.testing.expectError(error.Syntax, fromKdl(ar.allocator(), "colors {\n bg \"#000\"\n", "x", &e));
    try std.testing.expect(e.line >= 2);
    // ida e volta: o tema exportado lê igual
    const out = try toKdl(ar.allocator(), &t, "copia");
    const back = try fromKdl(ar.allocator(), out, "copia", &e);
    try std.testing.expectEqual(t.pal.blurple, back.pal.blurple);
    try std.testing.expectEqual(t.pal.hover, back.pal.hover);
    try std.testing.expectEqual(t.font_ui, back.font_ui);
    try std.testing.expectEqual(t.pal.round, back.pal.round);
}
