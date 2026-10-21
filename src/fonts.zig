//! Fontes da interface (Inter + ícones do Font Awesome), embutidas no binário.
//! Cada contexto do ImGui (janela principal, janelas flutuantes) carrega as suas.
const c = @import("c.zig").c;

const inter_regular = @embedFile("assets/Inter-400.ttf");
const inter_semibold = @embedFile("assets/Inter-600.ttf");
const inter_bold = @embedFile("assets/Inter-700.ttf");
const fa_solid = @embedFile("assets/fa-solid-900.ttf");
// Fira Code (tema pwnd): instâncias fixas da variável, só o alfabeto latino
const fira_regular = @embedFile("assets/FiraCode-400.ttf");
const fira_semibold = @embedFile("assets/FiraCode-600.ttf");
const fira_bold = @embedFile("assets/FiraCode-700.ttf");

pub const Set = struct { regular: *c.ImFont, semibold: *c.ImFont, bold: *c.ImFont };

const fa_exclude = [_]c.ImWchar{ 0x0001, 0xDFFF, 0xF900, 0x10FFFF, 0 };

fn loadFont(atlas: *c.ImFontAtlas, data: []const u8, size: f32) *c.ImFont {
    const cfg = c.ImFontConfig_ImFontConfig();
    defer c.ImFontConfig_destroy(cfg);
    cfg.*.FontDataOwnedByAtlas = false;
    const font = c.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(data.ptr), @intCast(data.len), size, cfg, null);
    // ícones (Font Awesome) misturados na mesma fonte
    cfg.*.MergeMode = true;
    cfg.*.GlyphMinAdvanceX = size;
    cfg.*.GlyphOffset = .{ .x = 0, .y = size * 0.05 };
    // só os ícones (área privada do Unicode): o Font Awesome também tem alguns
    // emoji (🔥, ❤...) e, vindo antes, ganharia da fonte de emoji colorida
    cfg.*.GlyphExcludeRanges = &fa_exclude;
    _ = c.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(fa_solid.ptr), @intCast(fa_solid.len), size * 0.9, cfg, null);
    return font;
}

/// A versão monoespaçada (temas que pedem, como o pwnd).
pub fn loadMono(atlas: *c.ImFontAtlas, size: f32) Set {
    return .{
        .regular = loadFont(atlas, fira_regular, size),
        .semibold = loadFont(atlas, fira_semibold, size),
        .bold = loadFont(atlas, fira_bold, size),
    };
}

/// Carrega as três fontes no atlas do contexto atual.
pub fn load(atlas: *c.ImFontAtlas, size: f32) Set {
    return .{
        .regular = loadFont(atlas, inter_regular, size),
        .semibold = loadFont(atlas, inter_semibold, size),
        .bold = loadFont(atlas, inter_bold, size),
    };
}

// ---------------------------------------------------------------------------
// Emoji: a fonte colorida do sistema, mesclada em cada fonte do texto (desenhada
// pelo carregador do src/c/emoji_loader.cpp). Carregada só quando aparece o
// primeiro emoji: quem nunca recebe emoji não gasta a memória da fonte (~10 MB).

const std = @import("std");
const builtin = @import("builtin");

const emoji_paths = if (builtin.os.tag == .windows) [_][*:0]const u8{
    "C:\\Windows\\Fonts\\seguiemj.ttf",
} else [_][*:0]const u8{
    "/usr/share/fonts/noto/NotoColorEmoji.ttf", // Arch
    "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf", // Debian, Ubuntu
    "/usr/share/fonts/google-noto-color-emoji-fonts/NotoColorEmoji.ttf", // Fedora
    "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
    "/usr/share/fonts/noto-emoji/NotoColorEmoji.ttf",
    "/usr/share/fonts/TTF/NotoColorEmoji.ttf",
    "/usr/share/fonts/twemoji/twemoji.ttf",
    "/usr/share/fonts/truetype/twemoji/TwitterColorEmoji-SVGinOT.ttf",
};

var emoji_data: ?[]u8 = null;
var emoji_tried = false;

fn readEmojiFont() ?[]u8 {
    if (emoji_tried) return emoji_data;
    emoji_tried = true;
    for (emoji_paths) |p| {
        const f = std.c.fopen(p, "rb") orelse continue;
        defer _ = std.c.fclose(f);
        var list: std.ArrayList(u8) = .empty;
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.c.fread(&chunk, 1, chunk.len, f);
            if (n == 0) break;
            list.appendSlice(std.heap.c_allocator, chunk[0..n]) catch {
                list.deinit(std.heap.c_allocator);
                return null;
            };
            if (list.items.len > 64 * 1024 * 1024) break;
        }
        if (list.items.len < 1024) {
            list.deinit(std.heap.c_allocator);
            continue;
        }
        emoji_data = list.toOwnedSlice(std.heap.c_allocator) catch return null;
        return emoji_data;
    }
    return null;
}

/// Mescla a fonte de emoji do sistema nas três fontes do conjunto. false =
/// não achou fonte de emoji (o emoji continua aparecendo como quadradinho).
pub fn addEmoji(atlas: *c.ImFontAtlas, set: Set, size: f32) bool {
    const data = readEmojiFont() orelse return false;
    for ([_]*c.ImFont{ set.regular, set.semibold, set.bold }) |dst| {
        const cfg = c.ImFontConfig_ImFontConfig();
        defer c.ImFontConfig_destroy(cfg);
        cfg.*.FontDataOwnedByAtlas = false;
        cfg.*.MergeMode = true;
        cfg.*.DstFont = dst;
        cfg.*.FontLoader = c.telinha_emoji_loader();
        cfg.*.GlyphOffset = .{ .x = 0, .y = size * 0.06 };
        _ = c.ImFontAtlas_AddFontFromMemoryTTF(atlas, data.ptr, @intCast(data.len), size, cfg, null);
    }
    return true;
}
