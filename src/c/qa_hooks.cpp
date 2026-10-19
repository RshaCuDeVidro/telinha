// Ganchos de teste do Dear ImGui (IMGUI_ENABLE_TEST_ENGINE): a cada quadro guarda
// o retângulo, o rótulo e o estado de cada item. Só trabalham quando o modo de
// testes está ligado (TELINHA_QA); fora dele o ImGui nem chama.
#include "imgui.h"
#include "imgui_internal.h"
#include <string.h>

#include "qa_hooks.h"

static ImVector<qa_item> g_items; // quadro sendo montado
static ImVector<qa_item> g_done;  // último quadro completo

static void copy_str(char* dst, size_t cap, const char* src) {
    size_t n = src ? strlen(src) : 0;
    if (n >= cap) n = cap - 1;
    if (n) memcpy(dst, src, n);
    dst[n] = 0;
}

void ImGuiTestEngineHook_ItemAdd(ImGuiContext* ctx, ImGuiID id, const ImRect& bb, const ImGuiLastItemData* item_data) {
    (void)item_data;
    qa_item it;
    memset(&it, 0, sizeof it);
    it.id = id;
    it.x0 = bb.Min.x;
    it.y0 = bb.Min.y;
    it.x1 = bb.Max.x;
    it.y1 = bb.Max.y;
    if (ImGuiWindow* w = ctx->CurrentWindow) {
        it.cx0 = w->ClipRect.Min.x;
        it.cy0 = w->ClipRect.Min.y;
        it.cx1 = w->ClipRect.Max.x;
        it.cy1 = w->ClipRect.Max.y;
        copy_str(it.window, sizeof it.window, w->Name);
    }
    g_items.push_back(it);
}

void ImGuiTestEngineHook_ItemInfo(ImGuiContext* ctx, ImGuiID id, const char* label, ImGuiItemStatusFlags flags) {
    (void)ctx;
    // o ItemInfo vem logo depois do ItemAdd do mesmo item
    for (int i = g_items.Size - 1; i >= 0 && i >= g_items.Size - 16; i--) {
        if (g_items[i].id != id) continue;
        copy_str(g_items[i].label, sizeof g_items[i].label, label);
        g_items[i].status = (unsigned)flags;
        return;
    }
}

void ImGuiTestEngineHook_Log(ImGuiContext* ctx, const char* fmt, ...) {
    (void)ctx;
    (void)fmt;
}

const char* ImGuiTestEngine_FindItemDebugLabel(ImGuiContext* ctx, ImGuiID id) {
    (void)ctx;
    for (int i = g_done.Size - 1; i >= 0; i--)
        if (g_done[i].id == id) return g_done[i].label;
    return NULL;
}

extern "C" void qa_enable(int on) {
    if (ImGuiContext* g = ImGui::GetCurrentContext()) g->TestEngineHookItems = on != 0;
}

extern "C" void qa_end_frame(void) {
    g_done.swap(g_items);
    g_items.resize(0);
}

extern "C" int qa_count(void) {
    return g_done.Size;
}

extern "C" const qa_item* qa_items(void) {
    return g_done.Data;
}
