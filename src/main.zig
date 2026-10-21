//! telinha — compartilhamento de tela em grupo (Linux e Windows).
const std = @import("std");
const c = @import("c.zig").c;
const sync = @import("sync.zig");
const net = @import("net.zig");
const ui = @import("ui.zig");
const gl = @import("gl.zig");
const client_mod = @import("client.zig");
const qa = @import("qa.zig");
const crash = @import("crash.zig");
const config = @import("config.zig");

/// Panic do Zig: anota no relatório de travamento antes do padrão (que
/// imprime a pilha e aborta). No Linux o abort também cai no relatório (com a
/// pilha); no Windows a pilha vai junto da mensagem (crash.c).
pub const panic = std.debug.FullPanic(onPanic);
fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    crash.note(msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
/// TELINHA_SEM_SHADER=1 força a conversão de cor na CPU (diagnóstico).
fn noGpuYuv() bool {
    return getenv("TELINHA_SEM_SHADER") != null;
}

const fonts = @import("fonts.zig");
const icon64 = @embedFile("assets/icon64.rgba");


/// Quantos vsyncs por quadro pro limite de `cap` q/s (0 = sem limite) no
/// monitor onde a janela está.
fn swapIntervalFor(win: *c.GLFWwindow, cap: u64) c_int {
    if (cap == 0) return 1;
    var wx: c_int = 0;
    var wy: c_int = 0;
    var ww: c_int = 0;
    var wh: c_int = 0;
    c.glfwGetWindowPos(win, &wx, &wy);
    c.glfwGetWindowSize(win, &ww, &wh);
    const cx = wx + @divTrunc(ww, 2);
    const cy = wy + @divTrunc(wh, 2);
    var n: c_int = 0;
    const mons = c.glfwGetMonitors(&n);
    var refresh: c_int = 60;
    var i: usize = 0;
    while (mons != null and i < @as(usize, @intCast(n))) : (i += 1) {
        const mon = mons[i];
        var mx: c_int = 0;
        var my: c_int = 0;
        c.glfwGetMonitorPos(mon, &mx, &my);
        const mode = c.glfwGetVideoMode(mon) orelse continue;
        if (i == 0) refresh = mode.*.refreshRate;
        if (cx >= mx and cx < mx + mode.*.width and cy >= my and cy < my + mode.*.height) {
            refresh = mode.*.refreshRate;
            break;
        }
    }
    if (refresh <= 0) return 1;
    const ratio = @as(f64, @floatFromInt(refresh)) / @as(f64, @floatFromInt(cap));
    return @intCast(std.math.clamp(@as(i64, @intFromFloat(@round(ratio))), 1, 4));
}

fn onGlfwError(code: c_int, desc: [*c]const u8) callconv(.c) void {
    _ = code;
    _ = desc;
}

/// Teste: o app se comporta como minimizado (ver o laço principal).
var teste_minimizado = false;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    config.initDir();
    crash.install();
    teste_minimizado = std.c.getenv("TELINHA_TESTE_MINIMIZADO") != null;
    sync.tuneMalloc();
    net.init();
    sync.pool.start(@max(2, sync.cpuCount() - 1));

    _ = c.glfwSetErrorCallback(onGlfwError);
    if (c.glfwInit() == 0) return error.GlfwInit;
    defer c.glfwTerminate();
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);
    c.glfwWindowHint(c.GLFW_SCALE_TO_MONITOR, c.GLFW_TRUE);
    // o nome da janela casa com o telinha.desktop (ícone certo na barra/dock)
    c.glfwWindowHintString(c.GLFW_WAYLAND_APP_ID, "telinha");
    c.glfwWindowHintString(c.GLFW_X11_CLASS_NAME, "telinha");
    c.glfwWindowHintString(c.GLFW_X11_INSTANCE_NAME, "telinha");
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
    ui.dpi_scale = std.math.clamp(xs, 1.0, 3.0);
    ui.scale = ui.dpi_scale;

    _ = c.igCreateContext(null);
    const io = c.igGetIO_Nil();
    io.*.IniFilename = null;
    io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;
    // Enter num campo de texto não tira o foco (o chat continua pronto pra
    // próxima mensagem, sem perder letra digitada logo depois)
    io.*.ConfigInputTextEnterKeepActive = true;
    qa.init(); // TELINHA_QA: modo de testes (posição dos botões + estado em arquivos)
    const base = 15 * ui.scale;
    ui.fonts_sans = fonts.load(io.*.Fonts, base);
    ui.fonts_mono = fonts.loadMono(io.*.Fonts, base);
    ui.useFonts(ui.fonts_sans, 1.0);
    ui.applyStyle();

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

    // arquivo solto em cima da janela (imagem no chat)
    _ = c.glfwSetDropCallback(win, ui.onDrop);
    var app = ui.App.init(win);
    app.applyArgs(args);
    crash.testCrash();
    var idle_frames: u32 = 0;
    var swap_interval: c_int = 1;
    var pacing_check_at: f64 = 0;
    while (c.glfwWindowShouldClose(win) == 0) {
        // limite de quadros da interface (mexer o mouse num monitor de 144 Hz
        // não redesenha 144 vezes por segundo): o vsync faz o ritmo, pulando
        // vsyncs (144 Hz com limite 60 = um quadro a cada 2), sem dormir no
        // meio (o Sleep do Windows perderia o vsync e o vídeo tremeria)
        if (c.glfwGetTime() >= pacing_check_at) {
            pacing_check_at = c.glfwGetTime() + 2;
            const want = swapIntervalFor(win, ui.frame_cap_fps);
            if (want != swap_interval) {
                swap_interval = want;
                c.glfwSwapInterval(want);
            }
        }
        // dorme quando nada está acontecendo; rede e captura acordam o loop,
        // e o que anima pede o próximo redesenho (ui.redrawIn)
        // TELINHA_TESTE_MINIMIZADO: testes (no Xvfb sem gerenciador de janelas não dá pra minimizar)
        const iconified = c.glfwGetWindowAttrib(win, c.GLFW_ICONIFIED) != 0 or teste_minimizado;
        if (idle_frames > 3) {
            // sem foco (o jogo na frente): o redesenho "de segurança" fica raro;
            // rede, vídeo e eventos acordam o laço na hora do mesmo jeito
            const unfocused = c.glfwGetWindowAttrib(win, c.GLFW_FOCUSED) == 0;
            var timeout: f64 = if (qa.enabled()) 0.05 else if (iconified) 1.0 else if (unfocused) 2.0 else if (io.*.WantTextInput) 0.25 else 0.5;
            if (ui.redraw_at != std.math.inf(f64)) timeout = @min(timeout, @max(0.0, ui.redraw_at - c.igGetTime()));
            if (timeout > 0) c.glfwWaitEventsTimeout(timeout) else c.glfwPollEvents();
        } else c.glfwPollEvents();
        ui.redraw_at = std.math.inf(f64);
        const t_frame = sync.nowUs();

        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
        app.updateUnread();
        app.iconified = iconified;
        app.frame();
        qa.endFrame(&app, win);
        c.igRender();

        // minimizado: a lógica roda (avisos, sons, janela flutuante), o desenho não
        if (!iconified) {
            var fw: c_int = 0;
            var fh: c_int = 0;
            c.glfwGetFramebufferSize(win, &fw, &fh);
            glViewport(0, 0, fw, fh);
            const bg = c.igColorConvertU32ToFloat4(ui.col.bg_dark);
            glClearColor(bg.x, bg.y, bg.z, 1);
            glClear(0x4000);
            c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
            c.glfwSwapBuffers(win);
        }
        app.drawPips(); // janelas flutuantes (cada uma com o contexto dela)
        const work = sync.nowUs() - t_frame;
        ui.frame_work_us += work;
        ui.frame_work_max_us = @max(ui.frame_work_max_us, work);
        ui.frame_count += 1;

        // "ativo" = o mouse mexendo ou apertado (arrastando um slider). Um
        // campo de texto com foco (o chat) não conta: ele ficaria "ativo" pra
        // sempre e a interface redesenharia a 60 q/s parada — o cursor piscando
        // já pede o redesenho dele (WantTextInput, acima)
        const active = io.*.MouseDelta.x != 0 or io.*.MouseDelta.y != 0 or io.*.MouseWheel != 0 or
            c.igIsMouseDown_Nil(0) or c.igIsMouseDown_Nil(1);
        idle_frames = if (active) 0 else idle_frames + 1;
    }

    // fechou: a janela some na hora; a limpeza (avisar a sala, salvar a
    // configuração) vem depois, com prazo
    c.glfwHideWindow(win);
    c.glfwPollEvents();
    sync.spawn(exitDeadline, .{}) catch {};
    app.shutdown();
    c.ImGui_ImplOpenGL3_Shutdown();
    c.ImGui_ImplGlfw_Shutdown();
    c.igDestroyContext(null);
    sync.hardExit(0);
}

/// Se a limpeza travar (driver, áudio, rede), sai mesmo assim.
fn exitDeadline() void {
    sync.sleepMs(4000);
    sync.hardExit(0);
}

extern fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void;
extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.c) void;
extern fn glClear(mask: c_uint) callconv(.c) void;
