//! Janela flutuante (picture-in-picture): uma transmissão numa janelinha
//! separada, por cima das outras (onde o sistema deixa: no Wayland quem decide
//! é o compositor; no Hyprland, uma regra de janela pelo título "telinha · ...").
//!
//! É uma segunda janela do GLFW com contexto OpenGL compartilhado (usa a mesma
//! textura do vídeo, sem copiar nada) e um contexto próprio do ImGui (o backend
//! do GLFW manda os eventos de cada janela pro contexto dela).
const std = @import("std");
const c = @import("c.zig").c;
const fonts = @import("fonts.zig");
const audio = @import("audio.zig");
const gpa = std.heap.c_allocator;

extern fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void;
extern fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.c) void;
extern fn glClear(mask: c_uint) callconv(.c) void;

pub const Action = enum { none, close, back };

pub const Pip = struct {
    win: *c.GLFWwindow,
    ctx: *c.ImGuiContext,
    stream: u32,
    font: fonts.Set,
    scale: f32,

    /// Abre a janelinha. Quem chama continua com o contexto (GL e ImGui) dele.
    pub fn open(main_win: *c.GLFWwindow, stream: u32, title: [:0]const u8, scale: f32) !*Pip {
        const prev = c.igGetCurrentContext();
        c.glfwWindowHint(c.GLFW_FLOATING, c.GLFW_TRUE); // por cima das outras (X11/Windows)
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 0);
        const w: c_int = @intFromFloat(480 * scale);
        const h: c_int = @intFromFloat(270 * scale);
        const win = c.glfwCreateWindow(w, h, title.ptr, null, main_win);
        c.glfwWindowHint(c.GLFW_FLOATING, c.GLFW_FALSE);
        const pw = win orelse return error.Window;
        c.glfwSetWindowSizeLimits(pw, 160, 90, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
        const p = gpa.create(Pip) catch {
            c.glfwDestroyWindow(pw);
            return error.OutOfMemory;
        };
        c.glfwMakeContextCurrent(pw);
        c.glfwSwapInterval(0); // a janela principal já espera o vsync
        const ctx = c.igCreateContext(null) orelse {
            c.glfwMakeContextCurrent(main_win);
            c.glfwDestroyWindow(pw);
            gpa.destroy(p);
            return error.Context;
        };
        c.igSetCurrentContext(ctx);
        const io = c.igGetIO_Nil();
        io.*.IniFilename = null;
        const fs = fonts.load(io.*.Fonts, 15 * scale);
        io.*.FontDefault = fs.regular;
        c.igStyleColorsDark(c.igGetStyle());
        c.igGetStyle().*.FontSizeBase = 15 * scale;
        _ = c.ImGui_ImplGlfw_InitForOpenGL(pw, true);
        _ = c.ImGui_ImplOpenGL3_Init("#version 130");
        p.* = .{ .win = pw, .ctx = ctx, .stream = stream, .font = fs, .scale = scale };
        c.glfwMakeContextCurrent(main_win);
        c.igSetCurrentContext(prev);
        return p;
    }

    fn S(p: *const Pip, x: f32) f32 {
        return x * p.scale;
    }

    /// Desenha um quadro. `tex` = textura do vídeo (0 = ainda carregando).
    pub fn frame(p: *Pip, main_win: *c.GLFWwindow, tex: u32, tw: u32, th: u32, name: []const u8, ring: ?*audio.Ring) Action {
        if (c.glfwWindowShouldClose(p.win) != 0) return .close;
        const prev = c.igGetCurrentContext();
        c.glfwMakeContextCurrent(p.win);
        c.igSetCurrentContext(p.ctx);
        defer {
            c.glfwMakeContextCurrent(main_win);
            c.igSetCurrentContext(prev);
        }
        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
        var action: Action = .none;
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(vp.*.Pos, 0, .{ .x = 0, .y = 0 });
        c.igSetNextWindowSize(vp.*.Size, 0);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowBorderSize, 0);
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, 0xFF000000);
        _ = c.igBegin("pip", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoScrollWithMouse);
        c.igPopStyleColor(1);
        c.igPopStyleVar(2);
        const d = c.igGetWindowDrawList();
        const size = vp.*.Size;
        if (tex != 0 and tw > 0 and th > 0) {
            // vídeo inteiro, sem cortar (faixa preta se a janela tiver outro formato)
            const ar = @as(f32, @floatFromInt(tw)) / @as(f32, @floatFromInt(th));
            var iw = size.x;
            var ih = size.x / ar;
            if (ih > size.y) {
                ih = size.y;
                iw = size.y * ar;
            }
            const ix = (size.x - iw) / 2;
            const iy = (size.y - ih) / 2;
            c.ImDrawList_AddImage(d, .{ ._TexData = null, ._TexID = tex }, .{ .x = ix, .y = iy }, .{ .x = ix + iw, .y = iy + ih }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, 0xFFFFFFFF);
        } else {
            const t: []const u8 = "Carregando...";
            c.ImDrawList_AddText_Vec2(d, .{ .x = p.S(12), .y = p.S(12) }, 0xFFA49B94, t.ptr, t.ptr + t.len);
        }
        // controles com o mouse em cima
        c.igSetCursorScreenPos(.{ .x = 0, .y = 0 });
        c.igSetNextItemAllowOverlap(); // os botões por cima ganham o mouse
        _ = c.igInvisibleButton("##fundo", size, 0);
        const over = c.igIsWindowHovered(c.ImGuiHoveredFlags_ChildWindows) or c.igIsAnyItemActive();
        if (c.igIsItemHovered(0) and c.igIsMouseDoubleClicked_Nil(0)) action = .back;
        if (over) {
            const bs = p.S(28);
            c.igSetCursorScreenPos(.{ .x = size.x - bs - p.S(6), .y = p.S(6) });
            if (p.button("##pipclose", "\u{F00D}", bs, "Fechar a janela flutuante")) action = .close;
            c.igSetCursorScreenPos(.{ .x = size.x - 2 * bs - p.S(10), .y = p.S(6) });
            if (p.button("##pipback", "\u{F066}", bs, "Voltar pra janela do telinha (duplo clique também)")) action = .back;
            // nome
            const ts = c.igCalcTextSize(name.ptr, name.ptr + name.len, false, -1);
            c.ImDrawList_AddRectFilled(d, .{ .x = p.S(6), .y = size.y - ts.y - p.S(16) }, .{ .x = p.S(18) + ts.x, .y = size.y - p.S(6) }, 0xAA000000, p.S(5), 0);
            c.ImDrawList_AddText_Vec2(d, .{ .x = p.S(12), .y = size.y - ts.y - p.S(11) }, 0xFFFFFFFF, name.ptr, name.ptr + name.len);
            // volume da transmissão
            if (ring) |rg| {
                const vw = p.S(110);
                c.igSetCursorScreenPos(.{ .x = size.x - vw - p.S(8), .y = size.y - p.S(30) });
                c.igSetNextItemWidth(vw);
                var vol: f32 = rg.getVolume() * 100;
                if (c.igSliderFloat("##pipvol", &vol, 0, 200, "%.0f%%", c.ImGuiSliderFlags_AlwaysClamp)) rg.setVolume(vol / 100);
            }
        }
        c.igEnd();
        c.igRender();
        var fw: c_int = 0;
        var fh: c_int = 0;
        c.glfwGetFramebufferSize(p.win, &fw, &fh);
        glViewport(0, 0, fw, fh);
        glClearColor(0, 0, 0, 1);
        glClear(0x4000);
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
        c.glfwSwapBuffers(p.win);
        return action;
    }

    fn button(p: *Pip, id: [:0]const u8, glyph: []const u8, size: f32, tip: [:0]const u8) bool {
        const pos = c.igGetCursorScreenPos();
        const clicked = c.igInvisibleButton(id.ptr, .{ .x = size, .y = size }, 0);
        const hovered = c.igIsItemHovered(0);
        const d = c.igGetWindowDrawList();
        c.ImDrawList_AddRectFilled(d, pos, .{ .x = pos.x + size, .y = pos.y + size }, if (hovered) 0xDD5865F2 else 0xAA000000, p.S(5), 0);
        const ts = c.igCalcTextSize(glyph.ptr, glyph.ptr + glyph.len, false, -1);
        c.ImDrawList_AddText_Vec2(d, .{ .x = pos.x + (size - ts.x) / 2, .y = pos.y + (size - ts.y) / 2 }, 0xFFFFFFFF, glyph.ptr, glyph.ptr + glyph.len);
        if (hovered) c.igSetTooltip("%s", tip.ptr);
        return clicked;
    }

    /// Fecha a janelinha (quem chama continua com o contexto dele).
    pub fn close(p: *Pip, main_win: *c.GLFWwindow) void {
        const prev = c.igGetCurrentContext();
        c.glfwMakeContextCurrent(p.win);
        c.igSetCurrentContext(p.ctx);
        c.ImGui_ImplOpenGL3_Shutdown();
        c.ImGui_ImplGlfw_Shutdown();
        c.igDestroyContext(p.ctx);
        c.glfwMakeContextCurrent(main_win);
        c.igSetCurrentContext(prev);
        c.glfwDestroyWindow(p.win);
        gpa.destroy(p);
    }
};
