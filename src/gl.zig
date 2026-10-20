//! OpenGL: texturas das transmissões e conversão YUV → RGB na GPU.
const std = @import("std");

pub const TEXTURE_2D: c_uint = 0x0DE1;
pub const RGBA: c_uint = 0x1908;
pub const BGRA: c_uint = 0x80E1;
pub const UNSIGNED_BYTE: c_uint = 0x1401;
const RED: c_uint = 0x1903;
const RG: c_uint = 0x8227;
const R8: c_int = 0x8229;
const RG8: c_int = 0x822B;
const RGBA8: c_int = 0x8058;
const TEXTURE_MIN_FILTER: c_uint = 0x2801;
const TEXTURE_MAG_FILTER: c_uint = 0x2800;
const TEXTURE_WRAP_S: c_uint = 0x2802;
const TEXTURE_WRAP_T: c_uint = 0x2803;
const LINEAR: c_int = 0x2601;
const CLAMP_TO_EDGE: c_int = 0x812F;
const UNPACK_ROW_LENGTH: c_uint = 0x0CF2;
const UNPACK_ALIGNMENT: c_uint = 0x0CF5;
const FRAMEBUFFER: c_uint = 0x8D40;
const COLOR_ATTACHMENT0: c_uint = 0x8CE0;
const FRAMEBUFFER_COMPLETE: c_uint = 0x8CD5;
const TEXTURE0: c_uint = 0x84C0;
const TRIANGLES: c_uint = 0x0004;
const VERTEX_SHADER: c_uint = 0x8B31;
const FRAGMENT_SHADER: c_uint = 0x8B30;
const COMPILE_STATUS: c_uint = 0x8B81;
const LINK_STATUS: c_uint = 0x8B82;
const BLEND: c_uint = 0x0BE2;
const SCISSOR_TEST: c_uint = 0x0C11;
const VIEWPORT: c_uint = 0x0BA2;

extern fn glGenTextures(n: c_int, textures: [*]c_uint) callconv(.c) void;
extern fn glDeleteTextures(n: c_int, textures: [*]const c_uint) callconv(.c) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) callconv(.c) void;
extern fn glTexParameteri(target: c_uint, pname: c_uint, param: c_int) callconv(.c) void;
extern fn glPixelStorei(pname: c_uint, param: c_int) callconv(.c) void;
extern fn glTexImage2D(target: c_uint, level: c_int, internal: c_int, w: c_int, h: c_int, border: c_int, format: c_uint, typ: c_uint, data: ?*const anyopaque) callconv(.c) void;
extern fn glTexSubImage2D(target: c_uint, level: c_int, x: c_int, y: c_int, w: c_int, h: c_int, format: c_uint, typ: c_uint, data: ?*const anyopaque) callconv(.c) void;
extern fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void;
extern fn glDrawArrays(mode: c_uint, first: c_int, count: c_int) callconv(.c) void;
extern fn glDisable(cap: c_uint) callconv(.c) void;
extern fn glGetIntegerv(pname: c_uint, data: [*]c_int) callconv(.c) void;

fn newTexture(tex: *u32) void {
    var t: [1]c_uint = undefined;
    glGenTextures(1, &t);
    tex.* = t[0];
    glBindTexture(TEXTURE_2D, tex.*);
    glTexParameteri(TEXTURE_2D, TEXTURE_MIN_FILTER, LINEAR);
    glTexParameteri(TEXTURE_2D, TEXTURE_MAG_FILTER, LINEAR);
    glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_S, CLAMP_TO_EDGE);
    glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_T, CLAMP_TO_EDGE);
}

/// Cria (ou recria) a textura com a imagem inteira (RGBA/BGRA).
pub fn upload(tex: *u32, pixels: []const u8, w: u32, h: u32, format: c_uint) void {
    if (tex.* == 0) newTexture(tex);
    glBindTexture(TEXTURE_2D, tex.*);
    glPixelStorei(UNPACK_ALIGNMENT, 4);
    glPixelStorei(UNPACK_ROW_LENGTH, 0);
    glTexImage2D(TEXTURE_2D, 0, @intCast(RGBA), @intCast(w), @intCast(h), 0, format, UNSIGNED_BYTE, pixels.ptr);
}

/// Atualiza só um retângulo da textura.
pub fn uploadRect(tex: u32, pixels: []const u8, full_w: u32, x: u32, y: u32, w: u32, h: u32, format: c_uint) void {
    glBindTexture(TEXTURE_2D, tex);
    glPixelStorei(UNPACK_ALIGNMENT, 4);
    glPixelStorei(UNPACK_ROW_LENGTH, @intCast(full_w));
    const off = (@as(usize, y) * full_w + x) * 4;
    glTexSubImage2D(TEXTURE_2D, 0, @intCast(x), @intCast(y), @intCast(w), @intCast(h), format, UNSIGNED_BYTE, pixels.ptr + off);
    glPixelStorei(UNPACK_ROW_LENGTH, 0);
}

pub fn delete(tex: *u32) void {
    if (tex.* != 0) {
        const t = [1]c_uint{tex.*};
        glDeleteTextures(1, &t);
        tex.* = 0;
    }
}

// ---------------------------------------------------------------------------
// YUV → RGB na GPU: a CPU só sobe os planos (1,5 byte/pixel em vez de 4) e um
// shader converte pra uma textura RGBA, que a interface desenha como sempre.

/// Funções do OpenGL 3.0 (carregadas pelo GLFW).
const Fns = struct {
    createShader: *const fn (c_uint) callconv(.c) c_uint,
    shaderSource: *const fn (c_uint, c_int, [*]const [*:0]const u8, ?[*]const c_int) callconv(.c) void,
    compileShader: *const fn (c_uint) callconv(.c) void,
    getShaderiv: *const fn (c_uint, c_uint, *c_int) callconv(.c) void,
    deleteShader: *const fn (c_uint) callconv(.c) void,
    createProgram: *const fn () callconv(.c) c_uint,
    attachShader: *const fn (c_uint, c_uint) callconv(.c) void,
    linkProgram: *const fn (c_uint) callconv(.c) void,
    getProgramiv: *const fn (c_uint, c_uint, *c_int) callconv(.c) void,
    useProgram: *const fn (c_uint) callconv(.c) void,
    getUniformLocation: *const fn (c_uint, [*:0]const u8) callconv(.c) c_int,
    uniform1i: *const fn (c_int, c_int) callconv(.c) void,
    genFramebuffers: *const fn (c_int, [*]c_uint) callconv(.c) void,
    deleteFramebuffers: *const fn (c_int, [*]const c_uint) callconv(.c) void,
    bindFramebuffer: *const fn (c_uint, c_uint) callconv(.c) void,
    framebufferTexture2D: *const fn (c_uint, c_uint, c_uint, c_uint, c_int) callconv(.c) void,
    checkFramebufferStatus: *const fn (c_uint) callconv(.c) c_uint,
    genVertexArrays: *const fn (c_int, [*]c_uint) callconv(.c) void,
    bindVertexArray: *const fn (c_uint) callconv(.c) void,
    activeTexture: *const fn (c_uint) callconv(.c) void,
};

const vertex_src =
    \\#version 130
    \\out vec2 uv;
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    uv = p;
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

// BT.601, faixa limitada (o que o H.264 da gente usa)
const fragment_src =
    \\#version 130
    \\in vec2 uv;
    \\out vec4 color;
    \\uniform sampler2D ty;
    \\uniform sampler2D tu;
    \\uniform sampler2D tv;
    \\uniform int nv12;
    \\void main() {
    \\    float y = texture(ty, uv).r;
    \\    vec2 c = (nv12 == 1) ? texture(tu, uv).rg : vec2(texture(tu, uv).r, texture(tv, uv).r);
    \\    float Y = 1.164383 * (y - 0.0627451);
    \\    float U = c.x - 0.5;
    \\    float V = c.y - 0.5;
    \\    color = vec4(Y + 1.596027 * V, Y - 0.391762 * U - 0.812968 * V, Y + 2.017232 * U, 1.0);
    \\}
;

pub const YuvRenderer = struct {
    f: Fns,
    program: c_uint,
    vao: c_uint,
    loc_nv12: c_int,

    /// null se o OpenGL não der conta (aí a CPU converte, como antes).
    pub fn init(getProc: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque) ?YuvRenderer {
        var f: Fns = undefined;
        inline for (@typeInfo(Fns).@"struct".fields) |field| {
            // "createShader" -> "glCreateShader"
            const name = comptime blk: {
                var buf: [field.name.len + 2:0]u8 = undefined;
                buf[0] = 'g';
                buf[1] = 'l';
                buf[2] = std.ascii.toUpper(field.name[0]);
                @memcpy(buf[3..], field.name[1..]);
                break :blk buf;
            };
            const p = getProc(&name) orelse return null;
            @field(f, field.name) = @ptrCast(p);
        }
        const vs = compile(&f, VERTEX_SHADER, vertex_src) orelse return null;
        defer f.deleteShader(vs);
        const fs = compile(&f, FRAGMENT_SHADER, fragment_src) orelse return null;
        defer f.deleteShader(fs);
        const prog = f.createProgram();
        f.attachShader(prog, vs);
        f.attachShader(prog, fs);
        f.linkProgram(prog);
        var ok: c_int = 0;
        f.getProgramiv(prog, LINK_STATUS, &ok);
        if (ok == 0) return null;
        f.useProgram(prog);
        f.uniform1i(f.getUniformLocation(prog, "ty"), 0);
        f.uniform1i(f.getUniformLocation(prog, "tu"), 1);
        f.uniform1i(f.getUniformLocation(prog, "tv"), 2);
        f.useProgram(0);
        var vao: [1]c_uint = undefined;
        f.genVertexArrays(1, &vao);
        return .{ .f = f, .program = prog, .vao = vao[0], .loc_nv12 = f.getUniformLocation(prog, "nv12") };
    }

    fn compile(f: *const Fns, kind: c_uint, src: [:0]const u8) ?c_uint {
        const sh = f.createShader(kind);
        const srcs = [_][*:0]const u8{src.ptr};
        f.shaderSource(sh, 1, &srcs, null);
        f.compileShader(sh);
        var ok: c_int = 0;
        f.getShaderiv(sh, COMPILE_STATUS, &ok);
        if (ok == 0) {
            f.deleteShader(sh);
            return null;
        }
        return sh;
    }

    /// Texturas de uma transmissão: planos + resultado RGBA.
    pub const Target = struct {
        ty: u32 = 0,
        tu: u32 = 0,
        tv: u32 = 0,
        out: u32 = 0,
        fbo: u32 = 0,
        w: u32 = 0, // tamanho do vídeo (planos)
        h: u32 = 0,
        ow: u32 = 0, // tamanho da textura convertida (o que aparece; nunca maior que o vídeo)
        oh: u32 = 0,
        nv12: bool = false,

        pub fn deinit(t: *Target, r: *const YuvRenderer) void {
            delete(&t.ty);
            delete(&t.tu);
            delete(&t.tv);
            delete(&t.out);
            if (t.fbo != 0) {
                const f = [1]c_uint{t.fbo};
                r.f.deleteFramebuffers(1, &f);
                t.fbo = 0;
            }
        }
    };

    fn planeTexture(tex: *u32, internal: c_int, w: u32, h: u32, format: c_uint) void {
        if (tex.* == 0) newTexture(tex);
        glBindTexture(TEXTURE_2D, tex.*);
        glTexImage2D(TEXTURE_2D, 0, internal, @intCast(w), @intCast(h), 0, format, UNSIGNED_BYTE, null);
    }

    fn uploadPlane(tex: u32, data: [*]const u8, w: u32, h: u32, format: c_uint) void {
        glBindTexture(TEXTURE_2D, tex);
        glTexSubImage2D(TEXTURE_2D, 0, 0, 0, @intCast(w), @intCast(h), format, UNSIGNED_BYTE, data);
    }

    /// Sobe os planos do vídeo. `planes` = Y (w*h) seguido de UV intercalado
    /// (NV12) ou U e V separados (I420), sem padding.
    pub fn upload(r: *const YuvRenderer, t: *Target, planes: []const u8, w: u32, h: u32, nv12: bool) void {
        _ = r;
        if (t.w != w or t.h != h or t.nv12 != nv12 or t.ty == 0) {
            planeTexture(&t.ty, R8, w, h, RED);
            if (nv12) {
                planeTexture(&t.tu, RG8, w / 2, h / 2, RG);
            } else {
                planeTexture(&t.tu, R8, w / 2, h / 2, RED);
                planeTexture(&t.tv, R8, w / 2, h / 2, RED);
            }
            t.w = w;
            t.h = h;
            t.nv12 = nv12;
        }
        glPixelStorei(UNPACK_ALIGNMENT, 1);
        glPixelStorei(UNPACK_ROW_LENGTH, 0);
        const n = @as(usize, w) * h;
        uploadPlane(t.ty, planes.ptr, w, h, RED);
        if (nv12) {
            uploadPlane(t.tu, planes.ptr + n, w / 2, h / 2, RG);
        } else {
            uploadPlane(t.tu, planes.ptr + n, w / 2, h / 2, RED);
            uploadPlane(t.tv, planes.ptr + n + n / 4, w / 2, h / 2, RED);
        }
        glPixelStorei(UNPACK_ALIGNMENT, 4);
    }

    /// Converte os planos (já na placa) pra `t.out` em `ow` x `oh` — o tamanho
    /// em que o vídeo aparece: um 1080p num quadradinho converte só o que se
    /// vê. `vp` = a viewport do quadro (pra devolver).
    pub fn convert(r: *const YuvRenderer, t: *Target, ow_in: u32, oh_in: u32, vp: [4]c_int) bool {
        if (t.ty == 0) return false;
        const ow = std.math.clamp(ow_in, 16, t.w);
        const oh = std.math.clamp(oh_in, 16, t.h);
        if (t.ow != ow or t.oh != oh or t.out == 0) {
            planeTexture(&t.out, RGBA8, ow, oh, RGBA);
            if (t.fbo == 0) {
                var fb: [1]c_uint = undefined;
                r.f.genFramebuffers(1, &fb);
                t.fbo = fb[0];
            }
            r.f.bindFramebuffer(FRAMEBUFFER, t.fbo);
            r.f.framebufferTexture2D(FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, t.out, 0);
            const ok = r.f.checkFramebufferStatus(FRAMEBUFFER) == FRAMEBUFFER_COMPLETE;
            r.f.bindFramebuffer(FRAMEBUFFER, 0);
            if (!ok) return false;
            t.ow = ow;
            t.oh = oh;
        }
        const nv12 = t.nv12;
        const w = ow;
        const h = oh;
        // desenha um triângulo que cobre a textura de saída
        r.f.bindFramebuffer(FRAMEBUFFER, t.fbo);
        glViewport(0, 0, @intCast(w), @intCast(h));
        glDisable(BLEND);
        glDisable(SCISSOR_TEST);
        r.f.useProgram(r.program);
        r.f.uniform1i(r.loc_nv12, @intFromBool(nv12));
        r.f.activeTexture(TEXTURE0);
        glBindTexture(TEXTURE_2D, t.ty);
        r.f.activeTexture(TEXTURE0 + 1);
        glBindTexture(TEXTURE_2D, t.tu);
        r.f.activeTexture(TEXTURE0 + 2);
        glBindTexture(TEXTURE_2D, if (nv12) t.tu else t.tv);
        r.f.bindVertexArray(r.vao);
        glDrawArrays(TRIANGLES, 0, 3);
        r.f.bindVertexArray(0);
        r.f.useProgram(0);
        r.f.activeTexture(TEXTURE0);
        r.f.bindFramebuffer(FRAMEBUFFER, 0);
        glViewport(vp[0], vp[1], vp[2], vp[3]);
        return true;
    }
};
