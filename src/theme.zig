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
    } },
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
    } },
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
