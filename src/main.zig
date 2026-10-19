//! telinha — compartilhamento de tela em grupo (Linux e Windows).
const std = @import("std");
const c = @import("c.zig").c;
const sync = @import("sync.zig");
const net = @import("net.zig");
const ui = @import("ui.zig");
const gl = @import("gl.zig");
const client_mod = @import("client.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
/// TELINHA_SEM_SHADER=1 força a conversão de cor na CPU (diagnóstico).
fn noGpuYuv() bool {
    return getenv("TELINHA_SEM_SHADER") != null;
}

const inter_regular = @embedFile("assets/Inter-400.ttf");
const inter_semibold = @embedFile("assets/Inter-600.ttf");
const inter_bold = @embedFile("assets/Inter-700.ttf");
const fa_solid = @embedFile("assets/fa-solid-900.ttf");
const icon64 = @embedFile("assets/icon64.rgba");

extern "winmm" fn timeBeginPeriod(ms: c_uint) callconv(.winapi) c_uint;

fn onGlfwError(code: c_int, desc: [*c]const u8) callconv(.c) void {
    _ = code;
    _ = desc;
}

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

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (sync.is_windows) _ = timeBeginPeriod(1); // Sleep() com precisão de 1ms (fps estável)
    net.init();
    sync.pool.start(@max(2, sync.cpuCount() - 1));

    _ = c.glfwSetErrorCallback(onGlfwError);
    if (c.glfwInit() == 0) return error.GlfwInit;
    defer c.glfwTerminate();
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);
    c.glfwWindowHint(c.GLFW_SCALE_TO_MONITOR, c.GLFW_TRUE);
    const win = c.glfwCreateWindow(1280, 760, "telinha", null, null) orelse return error.Window;
    defer c.glfwDestroyWindow(win);
    c.glfwSetWindowSizeLimits(win, 900, 560, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
    {
        var img: c.GLFWimage = .{ .width = 64, .height = 64, .pixels = @constCast(icon64.ptr) };
        c.glfwSetWindowIcon(win, 1, &img);
    }
    c.glfwMakeContextCurrent(win);
    c.glfwSwapInterval(1);

    var xs: f32 = 1;
    var ys: f32 = 1;
    c.glfwGetWindowContentScale(win, &xs, &ys);
    ui.scale = std.math.clamp(xs, 1.0, 3.0);

    _ = c.igCreateContext(null);
    const io = c.igGetIO_Nil();
    io.*.IniFilename = null;
    io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;
    const base = 15 * ui.scale;
    ui.font_regular = loadFont(io.*.Fonts, inter_regular, base);
    ui.font_semibold = loadFont(io.*.Fonts, inter_semibold, base);
    ui.font_bold = loadFont(io.*.Fonts, inter_bold, base);
    io.*.FontDefault = ui.font_regular;
    ui.applyStyle();
    c.igGetStyle().*.FontSizeBase = base;

    _ = c.ImGui_ImplGlfw_InitForOpenGL(win, true);
    _ = c.ImGui_ImplOpenGL3_Init("#version 130");

    // conversão de cor das transmissões na GPU (se o OpenGL der conta)
    ui.yuv_renderer = gl.YuvRenderer.init(@ptrCast(&c.glfwGetProcAddress));
    client_mod.gpu_yuv.store(ui.yuv_renderer != null and !noGpuYuv(), .release);

    // --janela x,y,w,h (posiciona a janela; útil pra testar várias instâncias)
    for (args, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, "--janela") or i + 1 >= args.len) continue;
        var it = std.mem.splitScalar(u8, args[i + 1], ',');
        var v: [4]c_int = .{ 0, 0, 1280, 760 };
        for (&v) |*x| x.* = std.fmt.parseInt(c_int, it.next() orelse break, 10) catch x.*;
        c.glfwSetWindowSizeLimits(win, 300, 200, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
        c.glfwSetWindowPos(win, v[0], v[1]);
        c.glfwSetWindowSize(win, v[2], v[3]);
    }

    var app = ui.App.init(win);
    app.applyArgs(args);
    var idle_frames: u32 = 0;
    while (c.glfwWindowShouldClose(win) == 0) {
        // dorme quando nada está acontecendo; rede e captura acordam o loop
        if (idle_frames > 3) c.glfwWaitEventsTimeout(if (io.*.WantTextInput) 0.25 else 0.5) else c.glfwPollEvents();

        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
        app.updateUnread();
        app.frame();
        c.igRender();

        var fw: c_int = 0;
        var fh: c_int = 0;
        c.glfwGetFramebufferSize(win, &fw, &fh);
        glViewport(0, 0, fw, fh);
        glClearColor(0.12, 0.12, 0.13, 1);
        glClear(0x4000);
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
        c.glfwSwapBuffers(win);

        const active = io.*.MouseDelta.x != 0 or io.*.MouseDelta.y != 0 or io.*.MouseWheel != 0 or
            c.igIsMouseDown_Nil(0) or c.igIsMouseDown_Nil(1) or c.igIsAnyItemActive();
        idle_frames = if (active) 0 else idle_frames + 1;
    }

    app.shutdown();
    c.ImGui_ImplOpenGL3_Shutdown();
    c.ImGui_ImplGlfw_Shutdown();
    c.igDestroyContext(null);
}

extern fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void;
extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.c) void;
extern fn glClear(mask: c_uint) callconv(.c) void;
