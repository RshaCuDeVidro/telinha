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
const single = @import("single.zig");
const config = @import("config.zig");
const update = @import("update.zig");
const debuglog = @import("debuglog.zig");

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
    // reiniciou depois de atualizar: espera a versão anterior fechar e apaga as sobras
    update.startup();
    // link telinha:// clicado com o telinha já aberto: o convite vai pra janela
    // aberta e este processo fecha (antes abria uma segunda janela)
    for (args) |arg| if (std.mem.startsWith(u8, arg, "telinha://")) {
        if (single.handoff(arg)) return;
    };
    teste_minimizado = std.c.getenv("TELINHA_TESTE_MINIMIZADO") != null;
    // Windows: a thread da interface com nome no log (no Linux isso renomearia o processo)
    if (sync.is_windows) sync.nameThread("interface");
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
    var emoji_loaded = false;
    ui.fonts_sans = fonts.load(io.*.Fonts, base);
    ui.fonts_mono = fonts.loadMono(io.*.Fonts, base);
    ui.useFonts(ui.fonts_sans, 1.0);
    ui.applyStyle();

    // eventos da janela contam pra "refazer a interface" (o ImGui encadeia os
    // dele depois destes); tamanho e exposição não passam pelo ImGui
    _ = c.glfwSetCursorPosCallback(win, inputCb.pos);
    _ = c.glfwSetMouseButtonCallback(win, inputCb.button);
    _ = c.glfwSetScrollCallback(win, inputCb.pos);
    _ = c.glfwSetKeyCallback(win, inputCb.key);
    _ = c.glfwSetCharCallback(win, inputCb.char);
    _ = c.glfwSetWindowFocusCallback(win, inputCb.int1);
    _ = c.glfwSetCursorEnterCallback(win, inputCb.int1);
    _ = c.glfwSetWindowSizeCallback(win, inputCb.int2);
    _ = c.glfwSetFramebufferSizeCallback(win, inputCb.int2);
    _ = c.glfwSetWindowRefreshCallback(win, inputCb.none);
    _ = c.glfwSetWindowContentScaleCallback(win, inputCb.float2);
    _ = c.ImGui_ImplGlfw_InitForOpenGL(win, true);
    _ = c.ImGui_ImplOpenGL3_Init("#version 130");
    {
        // placa e driver no relatório de travamento (o OpenGL só responde agora)
        const gs = struct {
            extern fn glGetString(name: c_uint) callconv(.c) ?[*:0]const u8;
        };
        const span = struct {
            fn f(p: ?[*:0]const u8) []const u8 {
                return if (p) |x| std.mem.span(x) else "?";
            }
        }.f;
        crash.noteSystem(span(gs.glGetString(0x1F00)), span(gs.glGetString(0x1F01)), span(gs.glGetString(0x1F02)));
    }

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
    var last_full: f64 = 0; // último quadro em que a interface foi refeita
    // TELINHA_SEM_QUADRO_RAPIDO=1: sempre refaz a interface (comparar / contornar)
    const fast_ok = std.c.getenv("TELINHA_SEM_QUADRO_RAPIDO") == null;
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
            var timeout: f64 = if (qa.enabled() and !qa.idle_mode) 0.05 else if (iconified) 1.0 else if (unfocused) 2.0 else if (io.*.WantTextInput) 0.25 else 0.5;
            // (a hora do ImGui só anda nos quadros completos: soma o que passou desde o último)
            const imgui_now = c.igGetTime() + @max(0.0, c.glfwGetTime() - last_full);
            if (ui.redraw_at != std.math.inf(f64)) timeout = @min(timeout, @max(0.0, ui.redraw_at - imgui_now));
            if (timeout > 0) c.glfwWaitEventsTimeout(timeout) else c.glfwPollEvents();
        } else c.glfwPollEvents();
        var t_frame = sync.nowUs();

        // só chegou quadro de vídeo (nenhum evento, aviso da rede ou animação
        // pendente): sobe a textura e reapresenta o desenho anterior, sem
        // refazer a interface inteira (a 60 q/s era ~7% de um núcleo só nisso).
        // Textura nova ou de outro tamanho, ou 1 s sem refazer: o caminho normal
        {
            const ui_wake = ui.ui_wake_pending.swap(false, .acq_rel);
            const video_wake = ui.video_wake_pending.swap(false, .acq_rel);
            const inputs = ui.input_events.swap(0, .acq_rel);
            const now = c.glfwGetTime();
            const timer_due = c.igGetTime() + @max(0.0, now - last_full) >= ui.redraw_at;
            if (fast_ok and video_wake and !ui_wake and inputs == 0 and !timer_due and idle_frames > 3 and !iconified and now - last_full < 1.0 and app.videoOnlyFrame()) {
                var fw: c_int = 0;
                var fh: c_int = 0;
                c.glfwGetFramebufferSize(win, &fw, &fh);
                glViewport(0, 0, fw, fh);
                const bg = c.igColorConvertU32ToFloat4(ui.col.bg_dark);
                glClearColor(bg.x, bg.y, bg.z, 1);
                glClear(0x4000);
                c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
                const t_swap = sync.nowUs();
                c.glfwSwapBuffers(win);
                const swap = sync.nowUs() - t_swap;
                ui.frame_swap_us += swap;
                ui.frame_swap_max_us = @max(ui.frame_swap_max_us, swap);
                t_frame += swap;
                app.drawPips();
                const work = sync.nowUs() - t_frame;
                ui.frame_work_us += work;
                ui.frame_work_max_us = @max(ui.frame_work_max_us, work);
                ui.frame_count += 1;
                ui.frame_fast_count += 1;
                continue;
            }
            last_full = now;
        }
        ui.redraw_at = std.math.inf(f64);

        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        // primeiro emoji na tela: carrega a fonte de emoji (uma vez)
        if (ui.emoji_wanted and !emoji_loaded) {
            emoji_loaded = true;
            const ok = fonts.addEmoji(io.*.Fonts, ui.fonts_sans, base) and fonts.addEmoji(io.*.Fonts, ui.fonts_mono, base);
            debuglog.line("emoji: {s}", .{if (ok) "fonte do sistema carregada" else "nenhuma fonte de emoji no sistema"});
        }
        const t_build = sync.nowUs();
        c.igNewFrame();
        app.updateUnread();
        app.iconified = iconified;
        app.frame();
        qa.endFrame(&app, win);
        c.igRender();
        ui.frame_build_us += sync.nowUs() - t_build;

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
            // o swap espera o vsync (ou o frame callback no Wayland): fora do
            // "trabalho", senão o log media o monitor (~16 ms) e não a interface
            const t_swap = sync.nowUs();
            c.glfwSwapBuffers(win);
            const swap = sync.nowUs() - t_swap;
            ui.frame_swap_us += swap;
            ui.frame_swap_max_us = @max(ui.frame_swap_max_us, swap);
            t_frame += swap;
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
    update.confirmHealthy(); // versão nova recém-instalada que fechou direito: passou
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

/// Callbacks da janela que só contam eventos (ver ui.input_events).
const inputCb = struct {
    fn pos(_: ?*c.GLFWwindow, _: f64, _: f64) callconv(.c) void {
        ui.noteInput();
    }
    fn button(_: ?*c.GLFWwindow, _: c_int, _: c_int, _: c_int) callconv(.c) void {
        ui.noteInput();
    }
    fn key(_: ?*c.GLFWwindow, _: c_int, _: c_int, _: c_int, _: c_int) callconv(.c) void {
        ui.noteInput();
    }
    fn char(_: ?*c.GLFWwindow, _: c_uint) callconv(.c) void {
        ui.noteInput();
    }
    fn int1(_: ?*c.GLFWwindow, _: c_int) callconv(.c) void {
        ui.noteInput();
    }
    fn int2(_: ?*c.GLFWwindow, _: c_int, _: c_int) callconv(.c) void {
        ui.noteInput();
    }
    fn float2(_: ?*c.GLFWwindow, _: f32, _: f32) callconv(.c) void {
        ui.noteInput();
    }
    fn none(_: ?*c.GLFWwindow) callconv(.c) void {
        ui.noteInput();
    }
};
