// Emoji colorido no texto do ImGui: um carregador de fonte (ImFontLoader)
// próprio, com o FreeType, usado só na fonte de emoji do sistema (o resto do
// texto continua no stb_truetype). Diferente do imgui_freetype, aceita fonte
// de emoji em bitmap de tamanho fixo (a Noto Color Emoji do Linux só tem 109
// px): pega o tamanho mais próximo e reduz a imagem (média por área).
// Windows (Segoe UI Emoji) é vetorial: renderiza direto no tamanho.
#include "imgui.h"
#include "imgui_internal.h"
#include "emoji_loader.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_SIZES_H
#include <math.h>
#include <string.h>

namespace {

FT_Library g_lib = nullptr;

struct SrcData {
    FT_Face face = nullptr;
};

struct BakedData {
    FT_Size size = nullptr;
    float scale = 1.0f;   // tamanho pedido / tamanho do bitmap escolhido (fonte de tamanho fixo)
    float density = 1.0f;
};

bool loaderInit(ImFontAtlas*) {
    return g_lib != nullptr || FT_Init_FreeType(&g_lib) == 0;
}

void loaderShutdown(ImFontAtlas*) {} // a biblioteca fica (outras janelas usam)

bool srcInit(ImFontAtlas* atlas, ImFontConfig* src) {
    if (!loaderInit(atlas)) return false;
    SrcData* d = IM_NEW(SrcData)();
    if (FT_New_Memory_Face(g_lib, (const FT_Byte*)src->FontData, (FT_Long)src->FontDataSize, (FT_Long)src->FontNo, &d->face) != 0) {
        IM_DELETE(d);
        return false;
    }
    FT_Select_Charmap(d->face, FT_ENCODING_UNICODE);
    src->FontLoaderData = d;
    return true;
}

void srcDestroy(ImFontAtlas*, ImFontConfig* src) {
    SrcData* d = (SrcData*)src->FontLoaderData;
    if (!d) return;
    FT_Done_Face(d->face);
    IM_DELETE(d);
    src->FontLoaderData = nullptr;
}

// Os modificadores que só fazem sentido juntando emoji (o ImGui desenha um
// caractere por vez): seletor de variação (U+FE0F, o "?" depois do ❤), o
// emenda-emoji (U+200D) e o tom de pele (sairia um quadradinho colorido do
// lado). Viram um glifo vazio, sem largura: aparece o emoji básico.
const int invisible_glyph = 0x7FFFFFFF;

int glyphIndex(ImFontAtlas*, ImFontConfig* src, ImWchar codepoint) {
    if ((codepoint >= 0xFE00 && codepoint <= 0xFE0F) || codepoint == 0x200D || (codepoint >= 0x1F3FB && codepoint <= 0x1F3FF))
        return invisible_glyph;
    return (int)FT_Get_Char_Index(((SrcData*)src->FontLoaderData)->face, (FT_ULong)codepoint);
}

bool containsGlyph(ImFontAtlas*, ImFontConfig* src, int glyph_index) {
    FT_Face f = ((SrcData*)src->FontLoaderData)->face;
    return glyph_index == invisible_glyph || (glyph_index > 0 && glyph_index < f->num_glyphs);
}

bool bakedInit(ImFontAtlas*, ImFontConfig* src, ImFontBaked* baked, void* loader_data) {
    SrcData* d = (SrcData*)src->FontLoaderData;
    BakedData* b = (BakedData*)loader_data;
    IM_PLACEMENT_NEW(b) BakedData();
    float size = baked->Size;
    const float ref = baked->OwnerFont->Sources[0]->SizePixels;
    if (src->MergeMode && src->SizePixels != 0.0f && ref != 0.0f) size *= src->SizePixels / ref;
    size *= src->ExtraSizeScale;
    b->density = src->RasterizerDensity * baked->RasterizerDensity;
    const float px = size * b->density;
    FT_New_Size(d->face, &b->size);
    FT_Activate_Size(b->size);
    if (FT_IS_SCALABLE(d->face)) {
        FT_Set_Pixel_Sizes(d->face, 0, (FT_UInt)(px + 0.5f));
    } else if (d->face->num_fixed_sizes > 0) {
        // o menor bitmap que ainda é maior que o pedido (reduzir fica bonito; aumentar, não)
        int best = 0;
        for (int i = 0; i < d->face->num_fixed_sizes; i++) {
            const float ppem = d->face->available_sizes[i].y_ppem / 64.0f;
            const float cur = d->face->available_sizes[best].y_ppem / 64.0f;
            if ((ppem >= px && (cur < px || ppem < cur)) || (cur < px && ppem > cur)) best = i;
        }
        FT_Select_Size(d->face, best);
        const float ppem = d->face->available_sizes[best].y_ppem / 64.0f;
        if (ppem > 0) b->scale = px / ppem;
    }
    return true;
}

void bakedDestroy(ImFontAtlas*, ImFontConfig*, ImFontBaked*, void* loader_data) {
    BakedData* b = (BakedData*)loader_data;
    if (b->size) FT_Done_Size(b->size);
    b->~BakedData();
}

bool loadGlyph(ImFontAtlas* atlas, ImFontConfig* src, ImFontBaked* baked, void* loader_data, int glyph_index, ImFontGlyph* out_glyph, float* out_advance_x) {
    SrcData* d = (SrcData*)src->FontLoaderData;
    BakedData* b = (BakedData*)loader_data;
    if (glyph_index == invisible_glyph) {
        if (out_advance_x) *out_advance_x = 0.0f;
        else out_glyph->AdvanceX = 0.0f;
        return true;
    }
    FT_Activate_Size(b->size);
    if (FT_Load_Glyph(d->face, (FT_UInt)glyph_index, FT_LOAD_COLOR | FT_LOAD_NO_HINTING) != 0) return false;
    FT_GlyphSlot slot = d->face->glyph;
    const float advance = (slot->advance.x / 64.0f) * b->scale / b->density;
    if (out_advance_x) {
        *out_advance_x = advance;
        return true;
    }
    if (slot->format != FT_GLYPH_FORMAT_BITMAP && FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != 0) return false;
    const FT_Bitmap* bm = &slot->bitmap;
    out_glyph->AdvanceX = advance;
    const int sw = (int)bm->width, sh = (int)bm->rows;
    if (sw == 0 || sh == 0) return true;
    const bool color = bm->pixel_mode == FT_PIXEL_MODE_BGRA;
    if (!color && bm->pixel_mode != FT_PIXEL_MODE_GRAY) return false;
    const int w = ImMax(1, (int)(sw * b->scale + 0.5f));
    const int h = ImMax(1, (int)(sh * b->scale + 0.5f));
    // média por área, em alfa pré-multiplicado (o BGRA do FreeType já vem
    // assim); no fim volta pro RGBA normal que o ImGui espera
    ImVector<unsigned char>& out = atlas->Builder->TempBuffer;
    out.resize(w * h * 4);
    const float fx = (float)sw / w, fy = (float)sh / h;
    for (int y = 0; y < h; y++) {
        const int y0 = (int)(y * fy), y1 = ImMax(y0 + 1, ImMin(sh, (int)((y + 1) * fy + 0.999f)));
        for (int x = 0; x < w; x++) {
            const int x0 = (int)(x * fx), x1 = ImMax(x0 + 1, ImMin(sw, (int)((x + 1) * fx + 0.999f)));
            float r = 0, g = 0, bl = 0, a = 0;
            int n = 0;
            for (int yy = y0; yy < y1; yy++) {
                const unsigned char* row = bm->buffer + yy * bm->pitch;
                for (int xx = x0; xx < x1; xx++) {
                    if (color) {
                        const unsigned char* p = row + xx * 4; // B G R A
                        bl += p[0];
                        g += p[1];
                        r += p[2];
                        a += p[3];
                    } else {
                        const float v = row[xx];
                        r += v;
                        g += v;
                        bl += v;
                        a += v;
                    }
                    n++;
                }
            }
            unsigned char* o = &out[(y * w + x) * 4];
            const float av = a / n;
            if (av < 0.5f) {
                o[0] = o[1] = o[2] = o[3] = 0;
            } else {
                o[0] = (unsigned char)ImMin(255.0f, r / n * 255.0f / av);
                o[1] = (unsigned char)ImMin(255.0f, g / n * 255.0f / av);
                o[2] = (unsigned char)ImMin(255.0f, bl / n * 255.0f / av);
                o[3] = (unsigned char)(av + 0.5f);
            }
        }
    }
    ImFontAtlasRectId pack_id = ImFontAtlasPackAddRect(atlas, w, h);
    if (pack_id == ImFontAtlasRectId_Invalid) return false;
    ImTextureRect* rect = ImFontAtlasPackGetRect(atlas, pack_id);
    const float ref = baked->OwnerFont->Sources[0]->SizePixels;
    const float offsets_scale = (ref != 0.0f) ? (baked->Size / ref) : 1.0f;
    const float font_off_x = ImFloor(src->GlyphOffset.x * offsets_scale + 0.5f);
    const float font_off_y = ImFloor(src->GlyphOffset.y * offsets_scale + 0.5f) + baked->Ascent;
    const float left = slot->bitmap_left * b->scale / b->density;
    const float top = -slot->bitmap_top * b->scale / b->density;
    out_glyph->X0 = left + font_off_x;
    out_glyph->Y0 = top + font_off_y;
    out_glyph->X1 = left + w / b->density + font_off_x;
    out_glyph->Y1 = top + h / b->density + font_off_y;
    out_glyph->Visible = true;
    out_glyph->Colored = color;
    out_glyph->PackId = pack_id;
    ImFontAtlasBakedSetFontGlyphBitmap(atlas, baked, src, out_glyph, rect, out.Data, ImTextureFormat_RGBA32, w * 4);
    return true;
}

ImFontLoader g_loader;

} // namespace

extern "C" const ImFontLoader* telinha_emoji_loader(void) {
    if (g_loader.Name == nullptr) {
        g_loader.Name = "telinha-emoji";
        g_loader.LoaderInit = loaderInit;
        g_loader.LoaderShutdown = loaderShutdown;
        g_loader.FontSrcInit = srcInit;
        g_loader.FontSrcDestroy = srcDestroy;
        g_loader.FontSrcGetGlyphIndexFromCodepoint = glyphIndex;
        g_loader.FontSrcContainsGlyph = containsGlyph;
        g_loader.FontBakedInit = bakedInit;
        g_loader.FontBakedDestroy = bakedDestroy;
        g_loader.FontBakedLoadGlyph = loadGlyph;
        g_loader.FontBakedSrcLoaderDataSize = sizeof(BakedData);
    }
    return &g_loader;
}
