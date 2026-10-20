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
};

pub const Theme = struct {
    id: []const u8, // o que vai pro config.ini (não muda com o idioma)
    name: [:0]const u8, // em português (a interface traduz)
    pal: Palette,
    mono: bool = false, // fonte monoespaçada (Fira Code)
};

pub const list = [_]Theme{
    .{ .id = "escuro", .name = "Escuro", .pal = .{
        .bg_dark = rgb(0x1E1F22),
        .bg_side = rgb(0x2B2D31),
        .bg_main = rgb(0x313338),
        .bg_user = rgb(0x232428),
        .bg_float = rgb(0x111214),
        .input = rgb(0x1E1F22),
        .chat_input = rgb(0x383A40),
        .hover = rgb(0x35373C),
        .selected = rgb(0x404249),
        .text = rgb(0xDBDEE1),
        .muted = rgb(0x949BA4),
        .faint = rgb(0x6D6F78),
        .header = rgb(0xF2F3F5),
        .blurple = rgb(0x5865F2),
        .blurple_hover = rgb(0x4752C4),
        .blurple_active = rgb(0x3C45A5),
        .green = rgb(0x23A55A),
        .green_hover = rgb(0x1A8B4C),
        .green_active = rgb(0x15703D),
        .red = rgb(0xF23F43),
        .red_hover = rgb(0xC03537),
        .red_active = rgb(0xA12828),
        .leave = rgb(0x3F2A2F),
        .yellow = rgb(0xF0B232),
        .button = rgb(0x4E5058),
        .button_hover = rgb(0x6D6F78),
        .button_active = rgb(0x80848E),
        .check = rgb(0xFFFFFF),
        .scroll = rgb(0x1A1B1E),
        .scroll_hover = rgb(0x111214),
        .home_grad = .{ rgb(0x1E1F22), rgb(0x232436), rgb(0x1E1F22), rgb(0x1A1B1E) },
    } },
    .{ .id = "claro", .name = "Claro", .pal = .{
        .bg_dark = rgb(0xE3E5E8),
        .bg_side = rgb(0xF2F3F5),
        .bg_main = rgb(0xFFFFFF),
        .bg_user = rgb(0xEBEDEF),
        .bg_float = rgb(0xF2F3F5),
        .input = rgb(0xE3E5E8),
        .chat_input = rgb(0xEBEDEF),
        .hover = rgb(0xE6E8EB),
        .selected = rgb(0xD4D7DC),
        .text = rgb(0x313338),
        .muted = rgb(0x5C5E66),
        .faint = rgb(0x80848E),
        .header = rgb(0x060607),
        .blurple = rgb(0x5865F2),
        .blurple_hover = rgb(0x4752C4),
        .blurple_active = rgb(0x3C45A5),
        .green = rgb(0x248046),
        .green_hover = rgb(0x1A6334),
        .green_active = rgb(0x15562C),
        .red = rgb(0xDA373C),
        .red_hover = rgb(0xA12D2F),
        .red_active = rgb(0x8F2022),
        .leave = rgb(0xF6D4D5),
        .yellow = rgb(0xB57A0E),
        .button = rgb(0x6D6F78),
        .button_hover = rgb(0x4E5058),
        .button_active = rgb(0x41434A),
        .check = rgb(0x5865F2),
        .scroll = rgb(0xC4C9CE),
        .scroll_hover = rgb(0xA3A6AA),
        .home_grad = .{ rgb(0xE3E5E8), rgb(0xDCDFF7), rgb(0xE3E5E8), rgb(0xD8DADE) },
    } },
    // cores do pwnd.blog: preto, fúcsia e roxo neon, verde de terminal, cantos quase retos
    .{ .id = "pwnd", .name = "pwnd", .pal = .{
        .bg_dark = rgb(0x050505),
        .bg_side = rgb(0x0A050F),
        .bg_main = rgb(0x0D0716),
        .bg_user = rgb(0x07030C),
        .bg_float = rgb(0x030208),
        .input = rgb(0x050505),
        .chat_input = rgb(0x140A20),
        .hover = rgb(0x1A0F29),
        .selected = rgb(0x2A1442),
        .text = rgb(0xE5E7EB),
        .muted = rgb(0x9D8CB3),
        .faint = rgb(0x6B7280),
        .header = rgb(0xF5F3FF),
        .blurple = rgb(0x9333EA),
        .blurple_hover = rgb(0xC026D3),
        .blurple_active = rgb(0x7E22CE),
        .green = rgb(0x22C55E),
        .green_hover = rgb(0x16A34A),
        .green_active = rgb(0x15803D),
        .red = rgb(0xF43F5E),
        .red_hover = rgb(0xE11D48),
        .red_active = rgb(0xBE123C),
        .leave = rgb(0x2A0A16),
        .yellow = rgb(0xFACC15),
        .button = rgb(0x1F1030),
        .button_hover = rgb(0x2E1747),
        .button_active = rgb(0x3B1D5C),
        .check = rgb(0xD946EF),
        .scroll = rgb(0x9333EA),
        .scroll_hover = rgb(0xD946EF),
        .home_grad = .{ rgb(0x050505), rgb(0x14061F), rgb(0x050505), rgb(0x030208) },
        .round = 0.25,
    }, .mono = true },
    // a variante clara do mesmo CSS (body.light-theme)
    .{ .id = "pwnd-claro", .name = "pwnd claro", .pal = .{
        .bg_dark = rgb(0xF1F5F9),
        .bg_side = rgb(0xF8FAFC),
        .bg_main = rgb(0xFFFFFF),
        .bg_user = rgb(0xEEF2F6),
        .bg_float = rgb(0xF8FAFC),
        .input = rgb(0xE5E7EB),
        .chat_input = rgb(0xF1F5F9),
        .hover = rgb(0xEDE9FE),
        .selected = rgb(0xDDD6FE),
        .text = rgb(0x111827),
        .muted = rgb(0x4B5563),
        .faint = rgb(0x6B7280),
        .header = rgb(0x1E1036),
        .blurple = rgb(0x7C3AED),
        .blurple_hover = rgb(0x6D28D9),
        .blurple_active = rgb(0x5B21B6),
        .green = rgb(0x15803D),
        .green_hover = rgb(0x166534),
        .green_active = rgb(0x14532D),
        .red = rgb(0xDC2626),
        .red_hover = rgb(0xB91C1C),
        .red_active = rgb(0x991B1B),
        .leave = rgb(0xFDE2E4),
        .yellow = rgb(0x92400E),
        .button = rgb(0x64748B),
        .button_hover = rgb(0x475569),
        .button_active = rgb(0x334155),
        .check = rgb(0x7C3AED),
        .scroll = rgb(0xD1D5DB),
        .scroll_hover = rgb(0x7C3AED),
        .home_grad = .{ rgb(0xF8FAFC), rgb(0xEDE9FE), rgb(0xF8FAFC), rgb(0xF1F5F9) },
        .round = 0.25,
    }, .mono = true },
    .{ .id = "nord", .name = "Nord", .pal = .{
        .bg_dark = rgb(0x242933),
        .bg_side = rgb(0x2E3440),
        .bg_main = rgb(0x3B4252),
        .bg_user = rgb(0x292E39),
        .bg_float = rgb(0x1F232B),
        .input = rgb(0x2E3440),
        .chat_input = rgb(0x434C5E),
        .hover = rgb(0x434C5E),
        .selected = rgb(0x4C566A),
        .text = rgb(0xE5E9F0),
        .muted = rgb(0xA3ADBF),
        .faint = rgb(0x7B88A1),
        .header = rgb(0xECEFF4),
        .blurple = rgb(0x5E81AC),
        .blurple_hover = rgb(0x6C8EBA),
        .blurple_active = rgb(0x4C6F99),
        .green = rgb(0xA3BE8C),
        .green_hover = rgb(0x93AE7C),
        .green_active = rgb(0x84A06D),
        .red = rgb(0xBF616A),
        .red_hover = rgb(0xA9545C),
        .red_active = rgb(0x94484F),
        .leave = rgb(0x4A3A44),
        .yellow = rgb(0xEBCB8B),
        .button = rgb(0x4C566A),
        .button_hover = rgb(0x5B657B),
        .button_active = rgb(0x697388),
        .check = rgb(0x88C0D0),
        .scroll = rgb(0x4C566A),
        .scroll_hover = rgb(0x5E81AC),
        .home_grad = .{ rgb(0x242933), rgb(0x2B3445), rgb(0x242933), rgb(0x20242D) },
    } },
    .{ .id = "dracula", .name = "Drácula", .pal = .{
        .bg_dark = rgb(0x1E1F29),
        .bg_side = rgb(0x21222C),
        .bg_main = rgb(0x282A36),
        .bg_user = rgb(0x1E1F29),
        .bg_float = rgb(0x191A21),
        .input = rgb(0x21222C),
        .chat_input = rgb(0x343746),
        .hover = rgb(0x343746),
        .selected = rgb(0x44475A),
        .text = rgb(0xF8F8F2),
        .muted = rgb(0xB0B4CE),
        .faint = rgb(0x7D88B8),
        .header = rgb(0xFFFFFF),
        .blurple = rgb(0xBD93F9),
        .blurple_hover = rgb(0xCAA9FA),
        .blurple_active = rgb(0xA87FE6),
        .green = rgb(0x50FA7B),
        .green_hover = rgb(0x6BFB90),
        .green_active = rgb(0x3EDB66),
        .red = rgb(0xFF5555),
        .red_hover = rgb(0xFF6E6E),
        .red_active = rgb(0xE04545),
        .leave = rgb(0x3D2533),
        .yellow = rgb(0xF1FA8C),
        .button = rgb(0x44475A),
        .button_hover = rgb(0x565970),
        .button_active = rgb(0x6272A4),
        .check = rgb(0xBD93F9),
        .scroll = rgb(0x44475A),
        .scroll_hover = rgb(0x6272A4),
        .home_grad = .{ rgb(0x21222C), rgb(0x2B2440), rgb(0x21222C), rgb(0x1C1D26) },
    } },
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

test "temas: texto legível em cima dos botões" {
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
