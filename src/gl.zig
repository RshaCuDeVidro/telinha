//! O pouco de OpenGL 1.1 que a gente usa direto (texturas das transmissões).
const std = @import("std");

pub const TEXTURE_2D: c_uint = 0x0DE1;
pub const RGBA: c_uint = 0x1908;
pub const BGRA: c_uint = 0x80E1;
pub const UNSIGNED_BYTE: c_uint = 0x1401;
const TEXTURE_MIN_FILTER: c_uint = 0x2801;
const TEXTURE_MAG_FILTER: c_uint = 0x2800;
const TEXTURE_WRAP_S: c_uint = 0x2802;
const TEXTURE_WRAP_T: c_uint = 0x2803;
const LINEAR: c_int = 0x2601;
const CLAMP_TO_EDGE: c_int = 0x812F;
const UNPACK_ROW_LENGTH: c_uint = 0x0CF2;
const UNPACK_ALIGNMENT: c_uint = 0x0CF5;

extern fn glGenTextures(n: c_int, textures: [*]c_uint) callconv(.c) void;
extern fn glDeleteTextures(n: c_int, textures: [*]const c_uint) callconv(.c) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) callconv(.c) void;
extern fn glTexParameteri(target: c_uint, pname: c_uint, param: c_int) callconv(.c) void;
extern fn glPixelStorei(pname: c_uint, param: c_int) callconv(.c) void;
extern fn glTexImage2D(target: c_uint, level: c_int, internal: c_int, w: c_int, h: c_int, border: c_int, format: c_uint, typ: c_uint, data: ?*const anyopaque) callconv(.c) void;
extern fn glTexSubImage2D(target: c_uint, level: c_int, x: c_int, y: c_int, w: c_int, h: c_int, format: c_uint, typ: c_uint, data: ?*const anyopaque) callconv(.c) void;

/// Cria (ou recria) a textura com a imagem inteira.
pub fn upload(tex: *u32, pixels: []const u8, w: u32, h: u32, format: c_uint) void {
    if (tex.* == 0) {
        var t: [1]c_uint = undefined;
        glGenTextures(1, &t);
        tex.* = t[0];
        glBindTexture(TEXTURE_2D, tex.*);
        glTexParameteri(TEXTURE_2D, TEXTURE_MIN_FILTER, LINEAR);
        glTexParameteri(TEXTURE_2D, TEXTURE_MAG_FILTER, LINEAR);
        glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_S, CLAMP_TO_EDGE);
        glTexParameteri(TEXTURE_2D, TEXTURE_WRAP_T, CLAMP_TO_EDGE);
    }
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
