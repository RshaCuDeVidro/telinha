//! Fontes da interface (Inter + ícones do Font Awesome), embutidas no binário.
//! Cada contexto do ImGui (janela principal, janelas flutuantes) carrega as suas.
const c = @import("c.zig").c;

const inter_regular = @embedFile("assets/Inter-400.ttf");
const inter_semibold = @embedFile("assets/Inter-600.ttf");
const inter_bold = @embedFile("assets/Inter-700.ttf");
const fa_solid = @embedFile("assets/fa-solid-900.ttf");

pub const Set = struct { regular: *c.ImFont, semibold: *c.ImFont, bold: *c.ImFont };

fn loadFont(atlas: *c.ImFontAtlas, data: []const u8, size: f32) *c.ImFont {
    const cfg = c.ImFontConfig_ImFontConfig();
    defer c.ImFontConfig_destroy(cfg);
    cfg.*.FontDataOwnedByAtlas = false;
    const font = c.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(data.ptr), @intCast(data.len), size, cfg, null);
    // ícones (Font Awesome) misturados na mesma fonte
    cfg.*.MergeMode = true;
    cfg.*.GlyphMinAdvanceX = size;
    cfg.*.GlyphOffset = .{ .x = 0, .y = size * 0.05 };
    _ = c.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(fa_solid.ptr), @intCast(fa_solid.len), size * 0.9, cfg, null);
    return font;
}

/// Carrega as três fontes no atlas do contexto atual.
pub fn load(atlas: *c.ImFontAtlas, size: f32) Set {
    return .{
        .regular = loadFont(atlas, inter_regular, size),
        .semibold = loadFont(atlas, inter_semibold, size),
        .bold = loadFont(atlas, inter_bold, size),
    };
}
