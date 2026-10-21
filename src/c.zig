//! Headers C compartilhados (ImGui via cimgui + GLFW).
pub const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cDefine("CIMGUI_USE_GLFW", "1");
    @cDefine("CIMGUI_USE_OPENGL3", "1");
    @cDefine("IMGUI_USE_WCHAR32", "1"); // igual ao build do ImGui (emoji acima de U+FFFF)
    @cInclude("GLFW/glfw3.h");
    @cInclude("cimgui_zig.h"); // cimgui.h com campos ImGuiContext* trocados por void* (limite do translate-c)
    @cInclude("cimgui_impl.h");
    @cInclude("capture.h");
    @cInclude("cudagl.h");
    @cInclude("camera.h");
    @cInclude("qa_hooks.h");
    @cInclude("notify.h");
    @cInclude("image.h");
    @cInclude("emoji_loader.h");
    @cInclude("filepick.h");
});
