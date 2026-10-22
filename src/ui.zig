//! Interface (Dear ImGui), visual inspirado no Discord.
const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("gl.zig");
const sync = @import("sync.zig");
const config = @import("config.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const View = client_mod.View;
const Member = client_mod.Member;
const Server = @import("server.zig").Server;
const tunnel_mod = @import("tunnel.zig");
const Tunnel = tunnel_mod.Tunnel;
const upnp = @import("upnp.zig");
const sharer_mod = @import("sharer.zig");
const proto = @import("proto.zig");
const audio = @import("audio.zig");
const voice = @import("voice.zig");
const qa = @import("qa.zig");
const clip = @import("clip.zig");
const mp4 = @import("mp4.zig");
const pip = @import("pip.zig");
const connect_mod = @import("connect.zig");
const net = @import("net.zig");
const update = @import("update.zig");
const changelog = @import("changelog.zig");
const changelog_pt = @embedFile("changelog_pt");
const changelog_en = @embedFile("changelog_en");
const chatimg = @import("chatimg.zig");
const chatsend = @import("chatsend.zig");
const filexfer = @import("filexfer.zig");
const files_mod = @import("files.zig");
const markdown = @import("markdown.zig");
const known = @import("known.zig");
const crypto = @import("crypto.zig");
const debuglog = @import("debuglog.zig");
const theme = @import("theme.zig");
const fonts_mod = @import("fonts.zig");
const codec = @import("codec.zig");
const pctest = @import("pctest.zig");
const crash = @import("crash.zig");
const ptt = @import("ptt.zig");
const cssfile = @import("cssfile.zig");
const hotkey = @import("hotkey.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const build_options = @import("build_options");
pub const version_string = proto.app_version;
const Sharer = sharer_mod.Sharer;

// ---------------------------------------------------------------------------
// Cores e fontes

const rgba = theme.rgba;
const rgb = theme.rgb;
const withAlpha = theme.withAlpha;

/// Cores do tema em uso (troca na hora: ver `setTheme` e theme.zig).
pub var col: theme.Palette = theme.list[0].pal;

const avatar_colors = [_]u32{ rgb(0x5865F2), rgb(0x3BA55C), rgb(0xFAA61A), rgb(0xED4245), rgb(0xEB459E), rgb(0x9B59B6), rgb(0x1ABC9C), rgb(0xE67E22) };

pub var font_regular: *c.ImFont = undefined;
pub var fonts_sans: fonts_mod.Set = undefined;
pub var fonts_mono: fonts_mod.Set = undefined;
/// Apareceu um emoji (chat, nome, texto digitado): o main.zig carrega a fonte
/// de emoji do sistema antes do próximo quadro (ver fonts.addEmoji).
pub var emoji_wanted = false;

/// Tem emoji no texto? (os blocos onde quase todos moram: U+1Fxxx e os
/// símbolos de U+2600–27BF e U+2B00–2BFF)
fn hasEmoji(text: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        const b0 = text[i];
        const b1 = text[i + 1];
        if (b0 == 0xF0 and b1 == 0x9F) return true;
        // ☀..➿, ⭐; e os de mídia/setas que o emoji colorido também tem: ⏩⏸ (U+23xx), ▶◀ (U+25xx), ⬆⬛ (U+2Bxx)
        if (b0 == 0xE2 and ((b1 >= 0x98 and b1 <= 0x9E) or (b1 >= 0x8C and b1 <= 0x8F) or b1 == 0x96 or b1 == 0x97 or b1 == 0xAC or b1 == 0xAD)) return true;
    }
    return false;
}

fn noteEmoji(text: []const u8) void {
    if (!emoji_wanted and hasEmoji(text)) emoji_wanted = true;
}
/// A Fira Code é mais larga que a Inter: um pouco menor pra caber igual.
var font_k: f32 = 1.0;
/// Escala da tela (DPI) e o zoom escolhido nas configurações (scale = os dois).
pub var dpi_scale: f32 = 1.0;
var zoom: f32 = 1.0;
const logo_rgba = @embedFile("assets/icon128.rgba");
var logo_tex: u32 = 0;
/// Conversão YUV→RGB na GPU (null = CPU converte).
pub var yuv_renderer: ?gl.YuvRenderer = null;
pub var font_semibold: *c.ImFont = undefined;
pub var font_bold: *c.ImFont = undefined;
pub var scale: f32 = 1.0;

/// Ícone do Font Awesome como string UTF-8 (3 bytes, U+F000..U+FFFF).
fn iconArr(comptime cp: u21) [3:0]u8 {
    return .{
        0xE0 | @as(u8, @intCast(cp >> 12)),
        0x80 | @as(u8, @intCast((cp >> 6) & 0x3F)),
        0x80 | @as(u8, @intCast(cp & 0x3F)),
    };
}
/// Resultado do envio do log pela sala quando só o servidor guardou (debuglog.sendRoom).
const room_log_saved = "saved";
/// Motivo das mudanças do microfone no log (clique nos botões da barra).
const via_clique = "clique";

const ic = struct {
    const reply = &iconArr(0xF3E5);
    const paperclip = &iconArr(0xF0C6);
    const file = &iconArr(0xF15B);
    const download = &iconArr(0xF019);
    const desktop = &iconArr(0xF390);
    const eraser = &iconArr(0xF12D);
    const bug = &iconArr(0xF188);
    const gauge = &iconArr(0xF625);
    const palette = &iconArr(0xF53F);
    const info = &iconArr(0xF05A);
    const pen = &iconArr(0xF303);
    const crop = &iconArr(0xF565);
    const camera_photo = &iconArr(0xF030);
    const tv = &iconArr(0xF26C);
    const gear = &iconArr(0xF013);
    const leave = &iconArr(0xF2F5);
    const eye = &iconArr(0xF06E);
    const eye_slash = &iconArr(0xF070);
    const expand = &iconArr(0xF065);
    const spotlight = &iconArr(0xF424); // up-right-and-down-left-from-center
    const unspotlight = &iconArr(0xF422); // down-left-and-up-right-to-center
    const compress = &iconArr(0xF066);
    const xmark = &iconArr(0xF00D);
    const send = &iconArr(0xF1D8);
    const users = &iconArr(0xF0C0);
    const signal = &iconArr(0xF012);
    const comments = &iconArr(0xF086);
    const stop = &iconArr(0xF04D);
    const copy = &iconArr(0xF0C5);
    const crown = &iconArr(0xF521);
    const plus = &iconArr(0xF067);
    const link = &iconArr(0xF0C1);
    const arrow_right = &iconArr(0xF061);
    const circle = &iconArr(0xF111);
    const tower = &iconArr(0xF519);
    const lock = &iconArr(0xF023);
    const user_plus = &iconArr(0xF234);
    const ban = &iconArr(0xF05E);
    const chev_down = &iconArr(0xF078);
    const chev_up = &iconArr(0xF077);
    const volume = &iconArr(0xF028);
    const volume_off = &iconArr(0xF6A9);
    const warn = &iconArr(0xF071);
    const globe = &iconArr(0xF0AC);
    const mic = &iconArr(0xF130);
    const mic_slash = &iconArr(0xF131);
    const headphones = &iconArr(0xF025);
    const phone = &iconArr(0xF095);
    const phone_slash = &iconArr(0xF3DD);
    const power = &iconArr(0xF011);
    const rotate = &iconArr(0xF2F9);
    const shield = &iconArr(0xF3ED);
    const video = &iconArr(0xF03D);
    const video_slash = &iconArr(0xF4E2);
    const lock_open = &iconArr(0xF3C1);
    const laptop = &iconArr(0xF109);
    const house = &iconArr(0xF015);
    const gavel = &iconArr(0xF0E3);
    const zoom_in = &iconArr(0xF00E);
    const crosshairs = &iconArr(0xF05B);
    const scissors = &iconArr(0xF0C4);
    const keyboard = &iconArr(0xF11C);
    const record = &iconArr(0xF192);
    const window_restore = &iconArr(0xF2D2);
    const bell = &iconArr(0xF0F3);
    const hand_pointer = &iconArr(0xF25A);
    const image = &iconArr(0xF03E);
    const face_smile = &iconArr(0xF118);
    const folder = &iconArr(0xF07B);
};

fn S(x: f32) f32 {
    return x * scale;
}
fn v2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}
fn add(a: c.ImVec2_c, b: c.ImVec2_c) c.ImVec2_c {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn pushFont(f: *c.ImFont, size: f32) void {
    c.igPushFont(f, S(size) * font_k);
}

/// Troca as fontes da interface (as do tema).
pub fn useFonts(set: fonts_mod.Set, k: f32) void {
    font_regular = set.regular;
    font_semibold = set.semibold;
    font_bold = set.bold;
    font_k = k;
    c.igGetIO_Nil().*.FontDefault = set.regular;
    c.igGetStyle().*.FontSizeBase = 15 * scale * k;
}

/// Tamanho da interface (0.8 a 1.5), por cima da escala da tela.
pub fn setZoom(z: f32) void {
    zoom = std.math.clamp(z, 0.8, 1.5);
    scale = dpi_scale * zoom;
    applyStyle();
}
fn popFont() void {
    c.igPopFont();
}
fn textSize(s: []const u8) c.ImVec2_c {
    return c.igCalcTextSize(s.ptr, s.ptr + s.len, false, -1);
}
fn drawList() *c.ImDrawList {
    return c.igGetWindowDrawList();
}
fn drawText(d: *c.ImDrawList, pos: c.ImVec2_c, color: u32, s: []const u8) void {
    c.ImDrawList_AddText_Vec2(d, pos, color, s.ptr, s.ptr + s.len);
}
fn drawTextF(d: *c.ImDrawList, f: *c.ImFont, size: f32, pos: c.ImVec2_c, color: u32, s: []const u8) void {
    c.ImDrawList_AddText_FontPtr(d, f, drawSize(size), pos, color, s.ptr, s.ptr + s.len, 0, null);
}

/// Igual, quebrando linha em `wrap` pixels.
fn drawTextWrapF(d: *c.ImDrawList, f: *c.ImFont, size: f32, pos: c.ImVec2_c, color: u32, s: []const u8, wrap: f32) void {
    c.ImDrawList_AddText_FontPtr(d, f, drawSize(size), pos, color, s.ptr, s.ptr + s.len, wrap, null);
}

/// O tamanho em que o texto é desenhado: arredondado, como o PushFont do
/// ImGui faz (o textSizeF mede com ele). Sem arredondar, 13,5 media como 14 e
/// desenhava 13,5: cada palavra do texto com markdown sobrava um pedaço.
fn drawSize(size: f32) f32 {
    return @max(1, @round(S(size) * font_k));
}
fn textSizeF(f: *c.ImFont, size: f32, s: []const u8) c.ImVec2_c {
    pushFont(f, size);
    defer popFont();
    return textSize(s);
}
fn rectFill(d: *c.ImDrawList, x0: f32, y0: f32, x1: f32, y1: f32, color: u32, rounding: f32) void {
    c.ImDrawList_AddRectFilled(d, v2(x0, y0), v2(x1, y1), color, rounding * col.round, 0);
}
fn textColored(color: u32, s: []const u8) void {
    c.igPushStyleColor_U32(c.ImGuiCol_Text, color);
    c.igTextUnformatted(s.ptr, s.ptr + s.len);
    c.igPopStyleColor(1);
}
fn texRef(tex: u32) c.ImTextureRef_c {
    return .{ ._TexData = null, ._TexID = tex };
}

var fmt_buf: [1024]u8 = undefined;
/// Reações do chat (mesma ordem do protocolo): curti, amei, haha, fogo, uau, triste.
const reaction_icons = [proto.reactions][]const u8{ &iconArr(0xF164), &iconArr(0xF004), &iconArr(0xF59B), &iconArr(0xF06D), &iconArr(0xF5C2), &iconArr(0xF5B4) };
const reaction_colors = [proto.reactions]u32{ rgb(0x5865F2), rgb(0xF23F43), rgb(0xF0B232), rgb(0xF57731), rgb(0xF0B232), rgb(0x00A8FC) };
fn reactionName(e: usize) [:0]const u8 {
    return switch (e) {
        0 => tr("Curti"),
        1 => tr("Amei"),
        2 => tr("Haha"),
        3 => tr("Fogo"),
        4 => tr("Uau"),
        else => tr("Triste"),
    };
}

/// Arquivos soltos em cima da janela (callback do GLFW; tratados no quadro).
/// Envio do log pela sala: a conexão atual (com uma referência própria, pro
/// envio numa thread não pegar um cliente já liberado).
var room_log_mutex: sync.Mutex = .{};
var room_log_client: ?*Client = null;

fn setRoomLogClient(cl: ?*Client) void {
    room_log_mutex.lock();
    defer room_log_mutex.unlock();
    if (room_log_client == cl) return;
    if (room_log_client) |old| old.release();
    room_log_client = if (cl) |x| x.retain() else null;
}

fn roomLogSend(data: []const u8, what: debuglog.What) bool {
    room_log_mutex.lock();
    const cl = if (room_log_client) |x| x.retain() else null;
    room_log_mutex.unlock();
    const c2 = cl orelse return false;
    defer c2.release();
    return c2.sendLogFile(data, if (what == .crash) proto.log_what_crash else proto.log_what_log);
}

var drop_paths: [4][1024]u8 = undefined;
var drop_lens: [4]usize = undefined;
var n_drops: usize = 0;

pub fn onDrop(_: ?*c.GLFWwindow, count: c_int, paths: [*c][*c]const u8) callconv(.c) void {
    var i: usize = 0;
    while (i < @as(usize, @intCast(count)) and n_drops < drop_paths.len) : (i += 1) {
        const p = std.mem.span(paths[i]);
        if (p.len >= drop_paths[0].len) continue;
        @memcpy(drop_paths[n_drops][0..p.len], p);
        drop_lens[n_drops] = p.len;
        n_drops += 1;
    }
}

/// "@Nome" (nome inteiro, sem diferenciar maiúscula) no texto?
/// "12,3 MB", "850 KB", "3 bytes".
fn humanSize(n: u64, buf: []u8) []const u8 {
    if (n < 1024) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "";
    if (n < 1024 * 1024) return std.fmt.bufPrint(buf, "{d} KB", .{n / 1024}) catch "";
    const tenths = n * 10 / (1024 * 1024);
    return std.fmt.bufPrint(buf, "{d},{d} MB", .{ tenths / 10, tenths % 10 }) catch "";
}

/// O texto cabe em `avail`? Senão "começo…fim" (corta no meio, sem partir um caractere).
fn ellipsizeMiddle(font: *c.ImFont, size: f32, text: []const u8, avail: f32, buf: []u8) []const u8 {
    if (textSizeF(font, size, text).x <= avail or text.len + 3 > buf.len) return text;
    var keep = text.len;
    while (keep > 4) {
        keep -= 1;
        var head = keep / 2;
        var tail_start = text.len - (keep - head);
        while (head > 0 and text[head] & 0xC0 == 0x80) head -= 1;
        while (tail_start < text.len and text[tail_start] & 0xC0 == 0x80) tail_start += 1;
        const out = std.fmt.bufPrint(buf, "{s}…{s}", .{ text[0..head], text[tail_start..] }) catch return text;
        if (textSizeF(font, size, out).x <= avail) return out;
    }
    return text;
}

/// Pro fim de um link (depois do "#"): tudo que não é letra/número/-._~ vira %XX.
fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) try w.writeByte(ch) else try w.print("%{X:0>2}", .{ch});
    }
}

/// Programa/script (o cartão não oferece "Abrir": só a pasta).
fn looksRunnable(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for ([_][]const u8{ "exe", "bat", "cmd", "com", "scr", "msi", "ps1", "vbs", "vbe", "js", "jse", "wsf", "jar", "sh", "appimage", "lnk", "pif", "reg", "hta", "cpl", "desktop", "run" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn copyName(dst: []u8, len: *usize, src: []const u8) void {
    var n = @min(src.len, dst.len);
    while (n > 0 and n < src.len and src[n] & 0xC0 == 0x80) n -= 1; // sem cortar um caractere no meio
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn mentions(text: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '@')) |at| : (i = at + 1) {
        const rest = text[at + 1 ..];
        if (rest.len < name.len or !std.ascii.eqlIgnoreCase(rest[0..name.len], name)) continue;
        if (rest.len == name.len or !std.ascii.isAlphanumeric(rest[name.len])) return true;
    }
    return false;
}

/// Formata no buffer do quadro, com o formato traduzido (ver i18n.zig).
fn fmtZ(comptime f: []const u8, args: anytype) [:0]const u8 {
    return i18n.bufPrintZ(&fmt_buf, f, args) catch "...";
}

/// Nome da fonte de captura pra mostrar (o C escreve em português).
fn sourceName(src: *const c.cap_source, buf: []u8) [:0]const u8 {
    var tmp: [300]u8 = undefined;
    const name = i18n.dynamic(std.mem.sliceTo(&src.name, 0), &tmp);
    // Windows: "Monitor 1 — 1920x1080 (principal)"
    const main_sfx = " (principal)";
    if (i18n.english() and std.mem.endsWith(u8, name, main_sfx))
        return std.fmt.bufPrintZ(buf, "{s} (primary)", .{name[0 .. name.len - main_sfx.len]}) catch "?";
    const min_sfx = " — minimizada";
    if (i18n.english() and std.mem.endsWith(u8, name, min_sfx))
        return std.fmt.bufPrintZ(buf, "{s} — minimized", .{name[0 .. name.len - min_sfx.len]}) catch "?";
    return std.fmt.bufPrintZ(buf, "{s}", .{name}) catch "?";
}

fn avatarColor(id: u32) u32 {
    return avatar_colors[id % avatar_colors.len];
}

/// Primeira letra (UTF-8) do nome, em maiúscula se for ASCII.
fn initial(name: []const u8, out: *[5]u8) []const u8 {
    if (name.len == 0) return "?";
    const n = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
    const len = @min(n, name.len);
    @memcpy(out[0..len], name[0..len]);
    if (len == 1) out[0] = std.ascii.toUpper(out[0]);
    return out[0..len];
}

fn drawAvatar(d: *c.ImDrawList, center: c.ImVec2_c, radius: f32, id: u32, name: []const u8, live: bool) void {
    drawAvatarSpeaking(d, center, radius, id, name, live, false);
}

/// Avatar com o anel verde de "falando" (como no Discord).
fn drawAvatarSpeaking(d: *c.ImDrawList, center: c.ImVec2_c, radius: f32, id: u32, name: []const u8, live: bool, speaking: bool) void {
    if (speaking) c.ImDrawList_AddCircle(d, center, radius + S(2.5), col.green, 0, S(2.5), 0);
    c.ImDrawList_AddCircleFilled(d, center, radius, avatarColor(id), 0);
    var buf: [5]u8 = undefined;
    const ini = initial(name, &buf);
    const fs = radius * 0.95 / scale;
    const ts = textSizeF(font_semibold, fs, ini);
    drawTextF(d, font_semibold, fs, v2(center.x - ts.x / 2, center.y - ts.y / 2), col.white, ini);
    if (live) {
        // bolinha vermelha de "ao vivo"
        const p = v2(center.x + radius * 0.72, center.y + radius * 0.72);
        c.ImDrawList_AddCircleFilled(d, p, radius * 0.36, col.bg_side, 0);
        c.ImDrawList_AddCircleFilled(d, p, radius * 0.24, col.red, 0);
    }
}

/// Risco vermelho em diagonal sobre um ícone (fone "surdo").
fn slash(d: *c.ImDrawList, top_left: c.ImVec2_c, size: f32) void {
    const a = v2(top_left.x + size * 0.22, top_left.y + size * 0.22);
    const b = v2(top_left.x + size * 0.78, top_left.y + size * 0.78);
    c.ImDrawList_AddLine(d, a, b, col.bg_user, S(4), 0);
    c.ImDrawList_AddLine(d, a, b, col.red, S(2), 0);
}

// ---------------------------------------------------------------------------
// Tela inicial: ajudantes de desenho e animação

const demo_title = "hotkey.zig — telinha"; // o "editor" da vitrine

fn easeOut(x: f32) f32 {
    const k = 1 - x;
    return 1 - k * k * k;
}

/// A mesma cor com o alfa multiplicado por k (0..1).
fn fa(color: u32, k: f32) u32 {
    const a8: f32 = @floatFromInt((color >> 24) & 0xFF);
    const na: u32 = @intFromFloat(std.math.clamp(a8 * k, 0, 255));
    return (color & 0x00FFFFFF) | (na << 24);
}

/// Mistura duas cores (t = 0: a, t = 1: b).
fn mixCol(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    inline for (0..4) |i| {
        const sh: u5 = @intCast(i * 8);
        const ca: f32 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f32 = @floatFromInt((b >> sh) & 0xFF);
        const v: u32 = @intFromFloat(std.math.clamp(ca + (cb - ca) * t, 0, 255));
        out |= v << sh;
    }
    return out;
}

/// Número "aleatório" fixo de 0 a 1 pra cada n (o código de mentira da vitrine).
fn hash01(n: u32) f32 {
    var x = n *% 0x9E3779B1;
    x ^= x >> 15;
    x *%= 0x85EBCA77;
    x ^= x >> 13;
    return @as(f32, @floatFromInt(x & 0xFFFF)) / 65535.0;
}

/// Brilho redondo e suave: um leque de triângulos com a cor no meio sumindo
/// até a borda (degradê de verdade, sem os degraus de círculos empilhados).
fn glow(d: *c.ImDrawList, center: c.ImVec2_c, radius: f32, color: u32, strength: u8) void {
    const seg = 48;
    const uv = c.igGetFontTexUvWhitePixel();
    const inner = withAlpha(color, strength);
    const outer = withAlpha(color, 0);
    c.ImDrawList_PrimReserve(d, seg * 3, seg + 1);
    const base = d._VtxCurrentIdx;
    c.ImDrawList_PrimWriteVtx(d, center, uv, inner);
    for (0..seg) |i| {
        const ang = @as(f32, @floatFromInt(i)) / seg * std.math.tau;
        c.ImDrawList_PrimWriteVtx(d, v2(center.x + @cos(ang) * radius, center.y + @sin(ang) * radius), uv, outer);
    }
    for (0..seg) |i| {
        c.ImDrawList_PrimWriteIdx(d, @intCast(base));
        c.ImDrawList_PrimWriteIdx(d, @intCast(base + 1 + i));
        c.ImDrawList_PrimWriteIdx(d, @intCast(base + 1 + (i + 1) % seg));
    }
}

/// Campo de texto com ícone na esquerda e borda na cor do destaque quando em foco.
fn iconField(d: *c.ImDrawList, id: [:0]const u8, glyph: []const u8, comptime hint: [:0]const u8, buf: []u8, width: f32, password: bool, accent: u32, k: f32) bool {
    c.igSetNextItemWidth(width);
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(36), S(11)));
    c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameRounding, S(10) * col.round);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, col.input);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, col.input);
    var flags: c.ImGuiInputTextFlags = c.ImGuiInputTextFlags_EnterReturnsTrue;
    if (password) flags |= c.ImGuiInputTextFlags_Password;
    const r = c.igInputTextWithHint(id.ptr, tr(hint).ptr, buf.ptr, buf.len, flags, null, null);
    c.igPopStyleColor(3);
    c.igPopStyleVar(2);
    const mn = c.igGetItemRectMin();
    const mx = c.igGetItemRectMax();
    const active = c.igIsItemActive();
    const hovered = c.igIsItemHovered(0);
    if (active) {
        c.ImDrawList_AddRect(d, v2(mn.x - S(2), mn.y - S(2)), v2(mx.x + S(2), mx.y + S(2)), fa(withAlpha(accent, 60), k), S(12) * col.round, S(3), 0);
        c.ImDrawList_AddRect(d, mn, mx, fa(accent, k), S(10) * col.round, S(1.2), 0);
    } else if (hovered) {
        c.ImDrawList_AddRect(d, mn, mx, fa(withAlpha(col.text, 40), k), S(10) * col.round, S(1), 0);
    }
    const gs = textSizeF(font_regular, 13, glyph);
    drawTextF(d, font_regular, 13, v2(mn.x + S(13), mn.y + (mx.y - mn.y - gs.y) / 2), fa(if (active) accent else col.muted, k), glyph);
    return r;
}

/// Botão grande da tela inicial, com a setinha que anda quando o mouse passa.
fn goButton(d: *c.ImDrawList, label: [:0]const u8, width: f32, color: u32, hover: u32, active: u32, k: f32) bool {
    const h = S(46);
    c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameRounding, S(12) * col.round);
    const r = primaryButton(label, v2(width, h), color, hover, active);
    c.igPopStyleVar(1);
    const mn = c.igGetItemRectMin();
    const hovered = c.igIsItemHovered(0);
    const text = label[0 .. std.mem.indexOf(u8, label, "##") orelse label.len];
    const tw = textSizeF(font_semibold, 15, text).x;
    const shift: f32 = if (hovered) S(5) else 0;
    const as = textSizeF(font_regular, 13, ic.arrow_right);
    drawTextF(d, font_regular, 13, v2(mn.x + (width + tw) / 2 + S(10) + shift, mn.y + (h - as.y) / 2), fa(theme.textOn(color), k), ic.arrow_right);
    return r;
}

/// Cor 0xRRGGBB que só se sabe em tempo de execução (theme.rgb é de compilação).
fn rgbRuntime(hex: u24) u32 {
    const r: u32 = (hex >> 16) & 0xFF;
    const g: u32 = (hex >> 8) & 0xFF;
    const b: u32 = hex & 0xFF;
    return 0xFF000000 | (b << 16) | (g << 8) | r;
}

fn liveBadgeWidth() f32 {
    return textSizeF(font_bold, 10, tr("AO VIVO")).x + S(10);
}

fn liveBadge(d: *c.ImDrawList, pos: c.ImVec2_c) f32 {
    const t = tr("AO VIVO");
    const ts = textSizeF(font_bold, 10, t);
    const pad = S(5);
    rectFill(d, pos.x, pos.y, pos.x + ts.x + pad * 2, pos.y + ts.y + S(2), col.red, S(3));
    drawTextF(d, font_bold, 10, v2(pos.x + pad, pos.y + S(1)), col.white, t);
    return ts.x + pad * 2;
}

/// Etiqueta "BOT" do lado do nome (como no Discord). Devolve a largura.
fn botBadge(d: *c.ImDrawList, pos: c.ImVec2_c) f32 {
    const t = "BOT";
    const ts = textSizeF(font_bold, 9.5, t);
    const pad = S(4);
    rectFill(d, pos.x, pos.y, pos.x + ts.x + pad * 2, pos.y + ts.y + S(2), col.blurple, S(3));
    drawTextF(d, font_bold, 9.5, v2(pos.x + pad, pos.y + S(1)), theme.textOn(col.blurple), t);
    return ts.x + pad * 2;
}

// ---------------------------------------------------------------------------
// Widgets

fn primaryButton(label: [:0]const u8, size: c.ImVec2_c, color: u32, hover: u32, active: u32) bool {
    c.igPushStyleColor_U32(c.ImGuiCol_Button, color);
    c.igPushStyleColor_U32(c.ImGuiCol_ButtonHovered, hover);
    c.igPushStyleColor_U32(c.ImGuiCol_ButtonActive, active);
    c.igPushStyleColor_U32(c.ImGuiCol_Text, theme.textOn(color));
    pushFont(font_semibold, 15);
    const r = c.igButton(label.ptr, size);
    popFont();
    c.igPopStyleColor(4);
    return r;
}

fn secondaryButton(label: [:0]const u8, size: c.ImVec2_c) bool {
    return primaryButton(label, size, col.button, col.button_hover, col.button_active);
}

/// Botão de ícone redondinho (barra do usuário, topo das transmissões).
fn iconButton(id: [:0]const u8, glyph: []const u8, size: f32, color: u32, hover_bg: u32, tooltip: [:0]const u8) bool {
    const pos = c.igGetCursorScreenPos();
    const clicked = c.igInvisibleButton(id.ptr, v2(size, size), 0);
    const hovered = c.igIsItemHovered(0);
    const d = drawList();
    if (hovered) rectFill(d, pos.x, pos.y, pos.x + size, pos.y + size, hover_bg, S(4));
    const ts = textSizeF(font_regular, 17, glyph);
    drawTextF(d, font_regular, 17, v2(pos.x + (size - ts.x) / 2, pos.y + (size - ts.y) / 2), color, glyph);
    if (hovered and tooltip.len > 0) tooltipText(tooltip);
    return clicked;
}

fn tooltipText(s: [:0]const u8) void {
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(10), S(6)));
    c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_float);
    c.igPushStyleColor_U32(c.ImGuiCol_Text, col.text);
    if (c.igBeginTooltip()) {
        c.igTextUnformatted(s.ptr, null);
        c.igEndTooltip();
    }
    c.igPopStyleColor(2);
    c.igPopStyleVar(1);
}

fn fieldLabel(comptime s: [:0]const u8) void {
    pushFont(font_bold, 11.5);
    textColored(col.muted, tr(s));
    popFont();
}

fn textField(id: [:0]const u8, comptime hint: [:0]const u8, buf: []u8, width: f32, password: bool) bool {
    c.igSetNextItemWidth(width);
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(9)));
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, col.input);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, col.input);
    var flags: c.ImGuiInputTextFlags = c.ImGuiInputTextFlags_EnterReturnsTrue;
    if (password) flags |= c.ImGuiInputTextFlags_Password;
    const r = c.igInputTextWithHint(id.ptr, tr(hint).ptr, buf.ptr, buf.len, flags, null, null);
    c.igPopStyleColor(3);
    c.igPopStyleVar(1);
    return r;
}

/// Botões lado a lado, tipo "segmented control". Retorna o índice escolhido.
/// O ID de cada botão é a posição dele (não muda com o idioma).
fn segmented(id: [:0]const u8, comptime options: []const [:0]const u8, current: *i32, width: f32) bool {
    c.igPushID_Str(id.ptr);
    defer c.igPopID();
    var changed = false;
    const w = (width - S(4) * @as(f32, @floatFromInt(options.len - 1))) / @as(f32, @floatFromInt(options.len));
    inline for (options, 0..) |opt, i| {
        if (i > 0) c.igSameLine(0, S(4));
        const sel = current.* == @as(i32, @intCast(i));
        const bg = if (sel) col.blurple else col.input;
        const hv = if (sel) col.blurple_hover else col.hover;
        c.igPushID_Int(@intCast(i));
        var lb: [96]u8 = undefined;
        const label = std.fmt.bufPrintZ(&lb, "{s}###seg", .{tr(opt)}) catch "###seg";
        if (primaryButton(label, v2(w, S(34)), bg, hv, if (sel) col.blurple_active else col.selected)) {
            current.* = @intCast(i);
            changed = true;
        }
        c.igPopID();
    }
    return changed;
}

// ---------------------------------------------------------------------------
// Estado do app

const SettingsPage = enum { geral, aparencia, voz, atalhos, camera, desempenho, depuracao, sobre };

const Toast = struct { text: [256]u8, len: usize, until: f64, err: bool };

/// Reconexão automática depois de uma queda (internet oscilou, túnel caiu...).
const Reconnect = struct {
    attempt: u32 = 0, // 0 = não está reconectando
    waiting: bool = false, // esperando a hora da próxima tentativa
    at: f64 = 0,
    // o que restaurar quando voltar (por nome: depois de o servidor reiniciar os ids mudam)
    share: bool = false,
    camera: bool = false,
    watch: [16][48]u8 = undefined,
    watch_len: [16]usize = undefined,
    watch_kind: [16]u8 = undefined, // tela ou câmera
    n_watch: usize = 0,
};
const max_reconnect = 6;

const ChatH = struct { h: f32, header: bool, width: f32 };
const gpa_ui = std.heap.c_allocator;

const ImgTex = struct {
    id: u32 = 0, // mensagem (0 = livre)
    tex: u32 = 0, // 0 = ainda decodificando (job) ou falhou
    w: u16 = 0,
    h: u16 = 0,
    failed: bool = false,
    used: u64 = 0, // último quadro em que apareceu
    job: ?*ImgJob = null,
};

/// Decodifica a imagem do chat e faz a miniatura numa thread (o primeiro
/// aparecimento de uma imagem não engasga a interface).
const ImgJob = struct {
    refs: std.atomic.Value(u8) = .init(2), // a thread + o cache
    done: std.atomic.Value(bool) = .init(false),
    data: []u8, // o H.264 da imagem (cópia)
    w: u16,
    h: u16,
    px: []u8 = &.{}, // miniatura RGBA (vazio = falhou)
    tw: u32 = 0,
    th: u32 = 0,

    fn run(j: *ImgJob) void {
        defer {
            j.done.store(true, .release);
            wakeUi();
            j.release();
        }
        const full = chatimg.decode(j.data, j.w, j.h) catch return;
        // no chat vai uma miniatura (até 480 px de largura): a imagem inteira
        // só pra quem abrir em tela cheia (1600 px em RGBA = 10 MB de textura)
        const tw: usize = @min(j.w, 480);
        if (tw == j.w) {
            j.px = full;
            j.tw = j.w;
            j.th = j.h;
            return;
        }
        defer std.heap.c_allocator.free(full);
        const th: usize = @max(1, @as(usize, j.h) * tw / j.w);
        const small = std.heap.c_allocator.alloc(u8, tw * th * 4) catch return;
        chatimg.resample(full, j.w, j.h, small, tw, th);
        j.px = small;
        j.tw = @intCast(tw);
        j.th = @intCast(th);
    }

    fn release(j: *ImgJob) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        std.heap.c_allocator.free(j.data);
        if (j.px.len > 0) std.heap.c_allocator.free(j.px);
        std.heap.c_allocator.destroy(j);
    }
};

pub const App = struct {
    window: *c.GLFWwindow,
    cfg: config.Config,

    screen: enum { home, room } = .home,
    home_tab: i32 = 0, // 0 entrar, 1 criar
    home_error: [256]u8 = undefined,
    home_error_len: usize = 0,
    port_buf: [8]u8 = undefined,
    home_card_h: f32 = 460,
    conn_addrs: [256]u8 = undefined, // os endereços da última conexão (identidade já vista)
    conn_addrs_len: usize = 0,
    trust_fp: [crypto.fp_len]u8 = undefined, // identidade nova que o usuário pode aceitar (botão)
    trust_fp_len: usize = 0,
    home_tab_anim: f32 = 0, // o destaque da aba, deslizando até home_tab
    home_switch_at: f64 = -10, // quando trocou de aba (o conteúdo entra deslizando)
    home_enter_at: f64 = -10, // quando a tela inicial apareceu (entrada animada)
    home_last_frame: u64 = 0,
    home_anim_t: f32 = 0, // relógio da animação da tela inicial (para quando ela para)
    // convite colado sozinho (área de transferência)
    pasted: [512]u8 = undefined,
    pasted_len: usize = 0,
    paste_hint_until: f64 = 0,
    was_focused: bool = false,
    home_seen: bool = false, // já olhou a área de transferência ao abrir a tela inicial

    client: ?*Client = null,
    server: ?*Server = null,
    tunnel: ?*Tunnel = null, // link público da sala que eu hospedo
    upnp: ?*upnp.Mapper = null, // porta aberta no roteador (conexão direta)
    own_tunnel_open: bool = false, // card: "prefere seu próprio túnel?" aberto
    tips_card_h: f32 = 0, // cartões lado a lado do mesmo tamanho (o mais alto do quadro anterior)
    tips_body_h: [2]f32 = .{ 0, 0 },
    empty_h: f32 = 0, // altura do bloco da sala vazia (pra centralizar)
    own_scroll: bool = false,
    // canais
    new_chan_open: bool = false, // campo "criar/entrar num canal" aberto no painel
    focus_new_chan: bool = false,
    new_chan_buf: [32]u8 = [_]u8{0} ** 32,
    chan_gen_seen: u32 = 0, // última troca de call já tratada (client.channel_gen)
    // o último canal/call pedido (se voltar "tem senha", pergunta e pede de novo)
    chan_req: [proto.channel_name_max]u8 = undefined,
    chan_req_len: usize = 0,
    chan_req_call: bool = false,
    chan_pw_for: [proto.channel_name_max]u8 = undefined, // perguntando a senha desse canal (0 = não)
    chan_pw_len: usize = 0,
    chan_pw_call: bool = false,
    chan_pw_buf: [64]u8 = [_]u8{0} ** 64,
    focus_chan_pw: bool = false,
    // admin: menu do canal (clique direito) e o campo de senha/tópico
    chan_menu: [proto.channel_name_max]u8 = undefined,
    chan_menu_len: usize = 0,
    chan_menu_flags: u8 = 0,
    chan_edit: enum { none, password, topic } = .none,
    chan_edit_for: [proto.channel_name_max]u8 = undefined,
    chan_edit_len: usize = 0,
    chan_edit_buf: [proto.chan_topic_max + 1]u8 = [_]u8{0} ** (proto.chan_topic_max + 1),
    focus_chan_edit: bool = false,
    // estatísticas do servidor (dono)
    stats_open: bool = false,
    stats_hist: [60]u16 = [_]u16{0} ** 60, // CPU (milésimos de núcleo) dos últimos 2 min
    stats_out_hist: [60]u32 = [_]u32{0} ** 60,
    stats_hist_n: usize = 0,
    stats_seen: u32 = 0,
    sharer: ?*Sharer = null,
    camera: ?*Sharer = null, // câmera ao vivo (a transmissão de tipo câmera)
    leave_confirm: bool = false, // "fechar a sala?" aberto
    admin_muted: bool = false, // o admin silenciou nosso microfone
    connect_label: [300]u8 = undefined,
    connect_label_len: usize = 0,
    was_connected: bool = false,

    views: std.ArrayList(*View) = .empty,
    focused: ?u32 = null, // stream em destaque (minhas prévias: proto.streamId(0, tipo))
    theater: bool = false,
    fullscreen: bool = false,
    // tela cheia/cinema com o mouse parado: controles e seta somem
    mouse_moved_at: f64 = 0,
    controls_hidden: bool = false,
    saved_win: [4]c_int = .{ 0, 0, 1280, 760 },

    chat_input: [4000]u8 = [_]u8{0} ** 4000,
    chat_sent: [4000]u8 = undefined, // mensagem guardada no Enter (ver chatCallback)
    chat_sent_len: usize = 0,
    chat_seen: u64 = 0,
    chat_unread: u32 = 0,
    chat_visible: bool = true,
    side_visible: bool = true,
    focus_chat: bool = false,
    // imagens do chat: texturas já decodificadas (as mais usadas ficam)
    img_cache: [16]ImgTex = [_]ImgTex{.{}} ** 16, // miniaturas
    view_tex: u32 = 0, // imagem aberta em tela cheia (resolução inteira)
    view_tex_id: u32 = 0,
    img_view: ?u32 = null, // imagem aberta em tela cheia (id da mensagem)
    img_failed_seen: u32 = 0,
    img_sent_seen: u32 = 0,
    frame_no: u64 = 0,
    // @menção: sugestões pro que está sendo digitado
    mention_sugg: [6][48]u8 = undefined,
    mention_sugg_len: [6]usize = undefined,
    n_mention_sugg: usize = 0,
    mention_apply: [48]u8 = undefined, // nome escolhido (o callback da caixa aplica)
    mention_apply_len: usize = 0,
    react_hover: ?u32 = null, // mensagem com o mouse em cima (mostra as reações)
    trim_at: f64 = 0, // quando devolver a memória livre pro sistema (0 = nada pendente)
    debug_next: f64 = 0, // próxima amostra do log de depuração
    debug_frames_seen: u64 = 0,
    debug_status_seen: ?client_mod.Status = null,
    debug_size: usize = 0, // tamanho do arquivo (lido de vez em quando, nas configurações)
    debug_size_at: f64 = -10,
    debug_sent_via: debuglog.Method = .gofile, // por onde foi o último envio
    chat_h: std.AutoHashMapUnmanaged(u32, ChatH) = .empty, // altura medida de cada mensagem do chat

    share_modal: bool = false,
    sources: [48]c.cap_source = undefined, // monitores e, no Windows, janelas
    n_sources: usize = 0,
    source_idx: i32 = 0,

    toasts: [4]Toast = undefined,
    n_toasts: usize = 0,
    reconnect: Reconnect = .{},
    // quem voltar a assistir assim que aparecer ao vivo de novo
    rewatch: Reconnect = .{},
    rewatch_until: f64 = 0,

    settings_modal: bool = false,
    show_advanced: bool = false,
    room_admin_token: [33]u8 = [_]u8{0} ** 33, // gerado ao criar a sala
    menu_target: u32 = 0, // membro do menu de contexto (expulsar)
    open_member_menu: bool = false,

    audio_err_shown: bool = false,
    self_mute_shown: bool = false,
    // notificações do sistema
    notified_at: f64 = -100,
    notif_chat_seen: u64 = 0,
    notif_chat_ready: bool = false,
    notifications_sent: u32 = 0,
    /// Volume de uma transmissão sendo arrastado (os controles dela continuam
    /// na tela mesmo com o mouse fora do quadro).
    tile_controls: ?u32 = null,
    zooms: [24]Zoom = [_]Zoom{.{}} ** 24,
    clip_jobs: [6]?*ClipJob = [_]?*ClipJob{null} ** 6,
    print_job: ?*PrintJob = null,
    pips: [4]?*pip.Pip = [_]?*pip.Pip{null} ** 4, // janelas flutuantes
    iconified: bool = false, // janela principal minimizada (o main.zig avisa)
    preview_uploads: u64 = 0, // miniaturas da própria tela subidas pra placa (QA)
    settings_page: SettingsPage = .geral,
    fb_viewport: [4]c_int = .{ 0, 0, 0, 0 },
    theme_dirty: bool = false, // tema mudou: aplica no começo do próximo quadro
    zoom_dirty: bool = false,
    save_at: f64 = 0, // salvar a configuração quando der essa hora (0 = nada pendente)
    auto_cap_seen: u32 = 0, // último teto da qualidade automática avisado
    // transmissão que caiu sozinha (sem a UI pedir): retomadas no último minuto
    share_restarts: u8 = 0,
    share_restart_window: f64 = 0,
    pctest_logged: bool = true, // resultado do teste do PC já foi pro log
    crash_prompt: bool = false, // travou da última vez: pergunta se manda o relatório
    update_modal: bool = false, // versão nova: o que muda + atualizar
    update_seen: [32]u8 = undefined, // a versão nova que já apareceu nesta sessão
    update_seen_len: usize = 0,
    update_auto_started: bool = false, // instalou sozinho: avisa quando terminar
    whatsnew: bool = false, // acabou de atualizar: as novidades
    whatsnew_after: [24]u8 = undefined, // a versão de antes ("" = só a seção da atual)
    whatsnew_after_len: usize = 0,
    crash_sending: bool = false, // mandando o relatório pelo aviso (avisa quando acabar)
    ptt_capture: bool = false, // esperando a tecla nova do apertar pra falar
    key_capture: ?config.HotkeyId = null, // esperando a tecla nova desse atalho
    capture_mod_seen: c_int = 0, // modificador apertado sozinho na captura (vira o atalho se soltar sem outra tecla)
    clip_key_last: f64 = -10,
    hk_prev: [config.n_hotkeys]bool = [_]bool{false} ** config.n_hotkeys, // apertado no quadro passado (com o telinha em foco)
    hk_last: [5]f64 = [_]f64{-10} ** 5, // último disparo de cada ação (o mesmo aperto visto de dois jeitos)
    cuda_probed: bool = false, // já tentou ligar o NVDEC direto pra textura
    last_saved: [512]u8 = undefined, // último clipe/gravação salvo (modo de testes)
    last_saved_len: usize = 0,
    /// Transmissão com o ponteiro "olha aqui" ligado (o mouse vira o ponteiro).
    pointer_tile: ?u32 = null,
    // desenhar por cima de uma transmissão
    draw_tile: ?u32 = null,
    strokes_drawn: u32 = 0, // traços desenhados nesse quadro (testes)
    picking_file: bool = false, // a janela de escolher imagem está aberta
    // menu de uma mensagem do chat (clique direito)
    msg_menu_text: [4000]u8 = undefined,
    msg_menu_len: usize = 0,
    msg_menu_name: [48]u8 = undefined,
    msg_menu_name_len: usize = 0,
    msg_menu_id: u32 = 0, // a mensagem do menu (responder)
    msg_menu_from: u32 = 0,
    msg_menu_to: u32 = 0, // era privada (0 = do canal)
    msg_menu_to_name: [48]u8 = undefined,
    msg_menu_to_name_len: usize = 0,
    // pra onde a caixa de mensagem aponta: resposta (citação) e privada
    reply_id: u32 = 0,
    reply_name: [48]u8 = undefined,
    reply_name_len: usize = 0,
    reply_snip: [proto.chat_quote_max]u8 = undefined,
    reply_snip_len: usize = 0,
    dm_to: u32 = 0,
    dm_name: [48]u8 = undefined,
    dm_name_len: usize = 0,
    draw_pts: [proto.draw_max_points][2]u16 = undefined,
    draw_n: usize = 0,
    draw_new: bool = false, // o próximo envio começa um traço
    draw_active: bool = false, // mouse apertado desenhando
    draw_sent_us: u64 = 0,
    draw_prune_at: f64 = 0,
    // transmitir só um pedaço da tela (normalizado: x0, y0, x1, y1)
    crop: [4]f32 = .{ 0, 0, 1, 1 },
    crop_seen_frame: u64 = 0, // último quadro em que a escolha do recorte apareceu
    crop_tile: ?u32 = null, // escolhendo o pedaço nesse quadro
    crop_from: ?[2]f32 = null,
    pointer_sent_us: u64 = 0,
    pointer_shown: bool = false, // mandamos um ponteiro visível (precisa esconder ao sair)
    pointer_stream_sent: u32 = 0,
    my_ping_us: u64 = 0,
    /// Onde cada transmissão foi desenhada nesse quadro (modo de testes).
    tile_rects: [40]struct { stream: u32, x0: f32, y0: f32, x1: f32, y1: f32 } = undefined,
    n_tile_rects: usize = 0,
    /// Onde cada membro aparece na lista (modo de testes).
    member_rects: [64]struct { id: u32, x0: f32, y0: f32, x1: f32, y1: f32 } = undefined,
    n_member_rects: usize = 0,
    live_rects: [64]struct { stream: u32, x0: f32, y0: f32, x1: f32, y1: f32 } = undefined,
    n_live_rects: usize = 0,

    // voz
    mic: ?*voice.Mic = null,
    mic_client: ?*Client = null, // quem recebe os pacotes do microfone (com referência)
    mic_wanted: bool = false, // quer o microfone ligado (lembra durante o "surdo")
    deaf: bool = false,
    echo_hint_shown: bool = false,
    mic_names: [16][128]u8 = undefined, // microfones (tela de configurações)
    n_mic_names: usize = 0,
    cams: [8]c.cam_device = undefined, // câmeras (tela de configurações)
    audio_apps: [24]audio.c.audio_app = undefined, // programas tocando som (janela de compartilhar)
    n_audio_apps: usize = 0,
    newer_seen: [16]u8 = undefined, // versão mais nova vista na sala (já avisada)
    newer_seen_len: usize = 0,
    n_cams: usize = 0,
    volumes: config.VoiceVolumes = .{}, // volume da voz por nome (lembrado)
    // membros do último quadro (sons de entrou/saiu/ao vivo, volumes salvos)
    known: [64]struct { id: u32, streaming: bool } = undefined,
    n_known: usize = 0,
    known_ready: bool = false, // a primeira lista depois de conectar não toca som

    // opções de linha de comando
    auto_share: bool = false,
    auto_watch: bool = false,
    /// --assistir: transmissões que já assistimos sozinhos (fechar uma não faz ela voltar)
    auto_watched: [64]u32 = undefined,
    n_auto_watched: usize = 0,
    auto_public: bool = false,

    pub fn init(window: *c.GLFWwindow) App {
        var a: App = .{ .window = window, .cfg = config.load(), .volumes = config.VoiceVolumes.load() };
        i18n.init(config.getStr(&a.cfg.language));
        cssfile.on_change = wakeUi;
        if (config.getStr(&a.cfg.custom_css).len > 0) cssfile.watch(config.getStr(&a.cfg.custom_css));
        _ = a.takeCssFile();
        a.applyTheme();
        a.applyPtt();
        hotkey.on_press = wakeUi;
        a.applyHotkeys();
        clip.keep_secs.store(@intCast(std.math.clamp(a.cfg.clip_secs, 5, 600)), .release);
        frame_cap_fps = @intCast(@max(0, a.cfg.ui_fps_cap));
        codec.setHwEffort(@intCast(a.cfg.hw_effort));
        codec.av1_enabled.store(a.cfg.av1, .release);
        if (a.cfg.ui_zoom != 100) setZoom(@as(f32, @floatFromInt(a.cfg.ui_zoom)) / 100);
        a.crash_prompt = crash.pending();
        _ = std.fmt.bufPrintZ(&a.port_buf, "{d}", .{a.cfg.host_port}) catch {};
        if (a.cfg.check_updates) update.checkAsync(build_options.repo, version_string, i18n.english());
        a.noteVersion();
        voice.on_speaking_change = wakeUi;
        if (a.cfg.debug_log) {
            debuglog.start();
            a.logSystem();
        }
        return a;
    }

    /// Aplica as opções de linha de comando (atalhos e testes automáticos).
    pub fn applyArgs(a: *App, args: []const [:0]const u8) void {
        var action: enum { none, create, join } = .none;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg: []const u8 = args[i];
            const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
            if (std.mem.eql(u8, arg, "--nome") and next != null) {
                config.setStr(&a.cfg.name, next.?);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--senha") and next != null) {
                config.setStr(&a.cfg.join_pass, next.?);
                config.setStr(&a.cfg.host_pass, next.?);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--criar")) {
                action = .create;
                if (next) |n| if (std.fmt.parseInt(u16, n, 10)) |_| {
                    config.setStr(&a.port_buf, n);
                    i += 1;
                } else |_| {};
            } else if (std.mem.eql(u8, arg, "--entrar") and next != null) {
                action = .join;
                config.setStr(&a.cfg.join_addr, next.?);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--fps") and next != null) {
                a.cfg.fps = std.math.clamp(std.fmt.parseInt(i32, next.?, 10) catch 30, 1, 60);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--qualidade") and next != null) {
                a.cfg.quality = std.math.clamp(std.fmt.parseInt(i32, next.?, 10) catch 60, 20, 100);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--modo") and next != null) {
                a.cfg.mode = if (std.mem.eql(u8, next.?, "jogo") or std.mem.eql(u8, next.?, "video")) 1 else 0;
                i += 1;
            } else if (std.mem.eql(u8, arg, "--admin") and next != null) {
                config.setStr(&a.cfg.admin_token, next.?);
                i += 1;
            } else if (std.mem.eql(u8, arg, "--transmitir")) {
                a.auto_share = true;
            } else if (std.mem.eql(u8, arg, "--publico")) {
                a.auto_public = true;
            } else if (std.mem.eql(u8, arg, "--assistir")) {
                a.auto_watch = true;
            } else if (std.mem.eql(u8, arg, "--software")) {
                a.cfg.hardware = false;
            } else if (std.mem.eql(u8, arg, "--estatisticas")) {
                a.cfg.stats_always = true;
            } else if (std.mem.startsWith(u8, arg, "telinha://")) {
                // convite aberto pelo sistema (link clicado: x-scheme-handler/telinha)
                action = .join;
                config.setStr(&a.cfg.join_addr, arg);
            }
        }
        switch (action) {
            .create => {
                if (a.auto_public) _ = a.ensureRoomPassword();
                a.createRoom();
                if (a.auto_public) a.startTunnel();
            },
            .join => a.joinRoom(),
            .none => {},
        }
    }

    pub fn shutdown(a: *App) void {
        a.closePips();
        if (a.screen == .room) a.leaveRoom();
        config.save(&a.cfg);
    }

    fn toast(a: *App, comptime f: []const u8, args: anytype, err: bool) void {
        var t: Toast = .{ .text = undefined, .len = 0, .until = c.igGetTime() + 5.0, .err = err };
        const s = i18n.bufPrint(&t.text, f, args) catch t.text[0..0];
        t.len = s.len;
        debuglog.line("aviso{s}: {s}", .{ if (err) " (erro)" else "", s });
        // o mesmo aviso de novo (clicou várias vezes): renova o que já está na tela
        for (a.toasts[0..a.n_toasts]) |*o| if (std.mem.eql(u8, o.text[0..o.len], s)) {
            o.until = t.until;
            return;
        };
        if (a.n_toasts == a.toasts.len) {
            std.mem.copyForwards(Toast, a.toasts[0 .. a.toasts.len - 1], a.toasts[1..]);
            a.n_toasts -= 1;
        }
        a.toasts[a.n_toasts] = t;
        a.n_toasts += 1;
    }

    // ------------------------------------------------------- log de depuração

    /// Placa e tela (o que o OpenGL e o GLFW dizem), uma vez ao ligar o log.
    fn logSystem(a: *App) void {
        const gs = struct {
            extern fn glGetString(name: c_uint) callconv(.c) ?[*:0]const u8;
        };
        const v = gs.glGetString(0x1F00);
        const r = gs.glGetString(0x1F01);
        const gv = gs.glGetString(0x1F02);
        debuglog.line("OpenGL: {s} | {s} | {s}", .{ if (v) |x| std.mem.span(x) else "?", if (r) |x| std.mem.span(x) else "?", if (gv) |x| std.mem.span(x) else "?" });
        var count: c_int = 0;
        const mons = c.glfwGetMonitors(&count);
        for (0..@intCast(@max(0, count))) |i| {
            const m = mons[i];
            const mode = c.glfwGetVideoMode(m);
            var sx: f32 = 1;
            var sy: f32 = 1;
            c.glfwGetMonitorContentScale(m, &sx, &sy);
            if (mode != null) debuglog.line("monitor {d}: {d}x{d} a {d} Hz, escala {d:.2}", .{ i, mode.*.width, mode.*.height, mode.*.refreshRate, sx });
        }
        var fw: c_int = 0;
        var fh: c_int = 0;
        c.glfwGetFramebufferSize(a.window, &fw, &fh);
        debuglog.line("janela: {d}x{d} pixels, interface em {d:.2}x", .{ fw, fh, scale });
        var ab: [512]u8 = undefined;
        _ = audio.c.audio_describe(&ab, ab.len);
        debuglog.line("som: {s}", .{std.mem.sliceTo(&ab, 0)});
        const cf = &a.cfg;
        debuglog.line("config: fps={d} qualidade={d} modo={d} resolução={d} cursor={} som={} placa={} clipes={} notificações={} supressão_ruído={} eco={} idioma={s} câmera={s}/{d}", .{
            cf.fps, cf.quality, cf.mode, cf.resolution, cf.cursor, cf.audio, cf.hardware, cf.clips, cf.notifications, cf.noise_suppression, cf.echo_cancellation, config.getStr(&cf.language), config.getStr(&cf.camera_device), cf.camera_res,
        });
    }

    /// A cada 2 s com o log ligado: tudo o que dá pra medir do app agora.
    fn debugTick(a: *App) void {
        const now = c.igGetTime();
        // muda de estado da conexão: na hora (não espera a amostra)
        if (a.client) |cl| {
            cl.mutex.lock();
            const st = cl.status;
            const route = cl.route;
            const err = cl.err[0..cl.err_len];
            var eb: [256]u8 = undefined;
            const n = @min(err.len, eb.len);
            @memcpy(eb[0..n], err[0..n]);
            cl.mutex.unlock();
            if (a.debug_status_seen == null or a.debug_status_seen.? != st) {
                a.debug_status_seen = st;
                debuglog.line("conexão: {s} (rota {s}) {s}", .{ @tagName(st), Server.routeName(route), eb[0..n] });
            }
        } else a.debug_status_seen = null;
        if (now < a.debug_next) {
            redrawIn(a.debug_next - now);
            return;
        }
        const first = a.debug_next == 0;
        a.debug_next = now + 2;
        redrawIn(2);
        const frames = frame_count - a.debug_frames_seen;
        const work = frame_work_us;
        const work_max = frame_work_max_us;
        a.debug_frames_seen = frame_count;
        frame_work_us = 0;
        frame_work_max_us = 0;
        const u = debuglog.usage();
        if (first) return; // a primeira amostra só zera as contas
        var tb: [256]u8 = undefined;
        var tl: usize = 0;
        for (u.top[0..u.n_top]) |t| {
            const w = std.fmt.bufPrint(tb[tl..], " {s}={d:.0}%", .{ t.name[0..t.len], t.pct }) catch break;
            tl += w.len;
        }
        debuglog.line("cpu app={d:.0}% (100% = 1 núcleo) pc={d:.0}% | ram app={d} MB, livre={d} MB | interface {d:.1} q/s, {d:.1} ms/quadro (máx {d:.1}){s}{s}", .{
            u.proc_pct, u.sys_pct, u.rss_mb, u.ram_free_mb, @as(f32, @floatFromInt(frames)) / 2, if (frames > 0) @as(f32, @floatFromInt(work)) / @as(f32, @floatFromInt(frames)) / 1000 else 0, @as(f32, @floatFromInt(work_max)) / 1000, if (tl > 0) " | threads:" else "", tb[0..tl],
        });
        const cl = a.client orelse return;
        cl.mutex.lock();
        const ping = cl.ping_ms;
        const n_members = cl.members.items.len;
        cl.mutex.unlock();
        var ub: [160]u8 = undefined;
        const udp_txt: []const u8 = if (cl.udp.load(.acquire)) |l| (std.fmt.bufPrint(&ub, "udp={s} rtt={d}ms enviados={d} reenviados={d} nacks={d} perdidas={d}", .{ if (l.isActive()) "sim" else "não", l.ep.rttMs(), l.ep.stats.sent_pkts, l.ep.stats.resent_pkts, l.ep.stats.nacks_sent, l.ep.stats.lost_msgs }) catch "") else "udp=não oferecido";
        debuglog.line("sala: {d} pessoas, ping {d} ms, fila de envio {d} KB, {s}", .{ n_members, ping, cl.queue.queuedBytes() / 1024, udp_txt });
        for (a.views.items) |v| {
            debuglog.line("assistindo {x}: {d}x{d} {d:.1} q/s {d:.0} kbit/s | {s} via {s}, decodifica em {d:.1} ms | atraso {d:.0} ms | som={}", .{
                v.stream, v.w, v.h, v.shownFps(), v.shownKbps() * 8, v.codec.name(), v.decoder_name, v.decode_ms, v.latency_ms, v.audio_registered,
            });
        }
        for ([_]?*Sharer{ a.sharer, a.camera }) |maybe| {
            const sh = maybe orelse continue;
            sh.mutex.lock();
            defer sh.mutex.unlock();
            const idr_room = sh.idr_room.swap(0, .monotonic);
            const idr_clip = sh.idr_clip.swap(0, .monotonic);
            debuglog.line("transmitindo ({s}): {s} {d}x{d} {d:.1} q/s {d:.0} kbit/s (alvo {d}) | captura {s}, encoder {s} {d:.1} ms | IDR {d} (sala {d}, clipe {d}) | congestionado={} som={} ninguém_assistindo={}", .{
                if (sh.kind == proto.kind_camera) "câmera" else "tela",
                @tagName(sh.state),
                sh.w,
                sh.h,
                sh.shownFps(),
                sh.shownKbps() * 8,
                sh.bitrate_kbps,
                sh.backendSlice(),
                sh.encoder_name,
                sh.encode_ms,
                idr_room + idr_clip,
                idr_room,
                idr_clip,
                sh.congested,
                sh.audio_on,
                sh.idle.load(.monotonic),
            });
        }
    }

    // ------------------------------------------------------------------ ações

    fn setHomeError(a: *App, s: []const u8) void {
        a.home_error_len = @min(s.len, a.home_error.len);
        @memcpy(a.home_error[0..a.home_error_len], s[0..a.home_error_len]);
    }

    fn myName(a: *App) []const u8 {
        const n = std.mem.trim(u8, config.getStr(&a.cfg.name), " ");
        return if (n.len == 0 or std.ascii.startsWithIgnoreCase(n, "telinha://")) tr("anônimo") else n;
    }

    fn joinRoom(a: *App) void {
        // convite: telinha://endereço[,endereço...]#senha (ou só o endereço)
        const raw = std.mem.trim(u8, config.getStr(&a.cfg.join_addr), " \t");
        const inv = connect_mod.splitInvite(raw);
        if (inv.password) |pw| config.setStr(&a.cfg.join_pass, pw);
        if (inv.channel) |ch| config.setStr(&a.cfg.join_channel, ch);
        // a impressão do convite vale pros endereços dele (digitou outro: não vale mais)
        if (inv.fingerprint) |fp| {
            config.setStr(&a.cfg.join_fp, fp);
            config.setStr(&a.cfg.join_fp_for, inv.addrs);
        } else if (std.mem.startsWith(u8, raw, "telinha://")) config.setStr(&a.cfg.join_fp, "");
        // deixa o campo só com os endereços
        var tmp: [256]u8 = undefined;
        config.setStr(&tmp, inv.addrs);
        a.cfg.join_addr = tmp;
        const addrs = config.getStr(&a.cfg.join_addr);
        var targets: [connect_mod.max_targets]connect_mod.Target = undefined;
        if (addrs.len == 0 or std.mem.findScalar(u8, addrs, ':') == null) return a.setHomeError(tr("Põe o endereço com a porta. Ex.: 0.tcp.sa.ngrok.io:12345 (ou cola o convite)."));
        if (connect_mod.parseList(addrs, &targets) == 0) return a.setHomeError(tr("Endereço inválido. Ex.: 0.tcp.sa.ngrok.io:12345 (IPv6 entre colchetes: [2804::1]:7777)"));
        // a identidade que o servidor tem que provar: a do convite, ou a já vista
        // nesse endereço (como no SSH); sem nenhuma, aceita e guarda a primeira
        var kb: [crypto.fp_len]u8 = undefined;
        var expect: []const u8 = "";
        var tofu = false;
        const jfp = config.getStr(&a.cfg.join_fp);
        if (jfp.len > 0 and std.mem.eql(u8, config.getStr(&a.cfg.join_fp_for), addrs)) {
            expect = jfp;
        } else if (known.lookup(addrs)) |k| {
            kb = k;
            expect = &kb;
            tofu = true;
        }
        a.connect(addrs, config.getStr(&a.cfg.join_pass), config.getStr(&a.cfg.admin_token), std.mem.trim(u8, config.getStr(&a.cfg.join_channel), " #"), expect, tofu);
    }

    fn createRoom(a: *App) void {
        const port = std.fmt.parseInt(u16, std.mem.sliceTo(&a.port_buf, 0), 10) catch 0;
        if (port == 0) return a.setHomeError(tr("Porta inválida."));
        a.cfg.host_port = port;
        var rn = std.mem.trim(u8, config.getStr(&a.cfg.room_name), " ");
        var tmp: [64]u8 = undefined;
        if (rn.len == 0) rn = i18n.bufPrint(&tmp, "Sala do {s}", .{a.myName()}) catch "telinha";
        const pass = config.getStr(&a.cfg.host_pass);
        var rnd: [16]u8 = undefined;
        sync.osRandom(&rnd);
        const token = std.fmt.bufPrintZ(&a.room_admin_token, "{x}", .{&rnd}) catch "";
        a.server = Server.start(.{ .port = port, .password = pass, .room_name = rn, .admin_token = token, .hosted = true, .identity_seed = known.hostSeed() }) catch {
            a.setHomeError(tr("Não consegui abrir essa porta. Já tem outra coisa usando? Tenta outra."));
            return;
        };
        var self_addr: [32]u8 = undefined;
        const own_fp = a.server.?.fingerprint();
        a.connect(std.fmt.bufPrint(&self_addr, "127.0.0.1:{d}", .{port}) catch "127.0.0.1:7777", pass, token, "", if (own_fp) |*f| f else "", false);
    }

    // ------------------------------------------------------------------ voz

    fn chime(a: *App, kind: audio.Chime) void {
        if (a.cfg.sounds and !a.deaf) audio.playChime(kind);
    }

    /// Quem entrou, saiu ou ficou ao vivo desde o último quadro: toca o aviso
    /// e aplica o volume de voz salvo pra quem chegou.
    fn watchMembers(a: *App, cl: *Client) void {
        var cur: [64]Member = undefined;
        cl.mutex.lock();
        const n = @min(cl.members.items.len, cur.len);
        @memcpy(cur[0..n], cl.members.items[0..n]);
        const me = cl.my_id;
        cl.mutex.unlock();
        if (n == 0) return;
        var joined = false;
        var left = false;
        var went_live = false;
        var who: ?*const Member = null; // quem entrou / ficou ao vivo (notificação)
        for (cur[0..n]) |*m| {
            const old = for (a.known[0..a.n_known]) |k| {
                if (k.id == m.id) break k;
            } else null;
            if (old == null) {
                if (m.id != me) {
                    joined = true;
                    if (who == null) who = m;
                }
                if (a.volumes.get(m.nameSlice())) |pct| cl.setVoiceVolume(m.id, @as(f32, @floatFromInt(pct)) / 100);
            } else if (!old.?.streaming and m.streaming and m.id != me) {
                went_live = true;
                who = m;
            }
        }
        for (a.known[0..a.n_known]) |k| {
            const still = for (cur[0..n]) |*m| {
                if (m.id == k.id) break true;
            } else false;
            if (!still) left = true;
        }
        if (a.known_ready) {
            if (went_live) a.chime(.live) else if (joined) a.chime(.join) else if (left) a.chime(.leave);
            if (who) |m| {
                var b: [96]u8 = undefined;
                a.notifyAway("telinha", (if (went_live) i18n.bufPrint(&b, "{s} começou a transmitir", .{m.nameSlice()}) else i18n.bufPrint(&b, "{s} entrou na sala", .{m.nameSlice()})) catch "");
            }
        }
        // alguém na sala com o telinha mais novo: avisa uma vez por versão
        var newest: []const u8 = "";
        var newest_who: []const u8 = "";
        for (cur[0..n]) |*m| {
            if (m.id != me and update.isNewer(m.versionSlice(), if (newest.len > 0) newest else version_string)) {
                newest = m.versionSlice();
                newest_who = m.nameSlice();
            }
        }
        if (newest.len > 0 and !std.mem.eql(u8, newest, a.newer_seen[0..a.newer_seen_len])) {
            a.newer_seen_len = @min(newest.len, a.newer_seen.len);
            @memcpy(a.newer_seen[0..a.newer_seen_len], newest[0..a.newer_seen_len]);
            a.toast("{s} está no telinha {s} e você no {s}: tem versão nova.{s}", .{ newest_who, newest, version_string, if (build_options.repo.len > 0) tr(" Baixe em Configurações.") else "" }, false);
        }
        a.known_ready = true;
        a.n_known = n;
        for (cur[0..n], 0..) |*m, i| a.known[i] = .{ .id = m.id, .streaming = m.streaming };
    }

    /// O telinha está em segundo plano (outra janela em foco ou minimizado)?
    fn away(a: *App) bool {
        return c.glfwGetWindowAttrib(a.window, c.GLFW_FOCUSED) == 0 or c.glfwGetWindowAttrib(a.window, c.GLFW_ICONIFIED) != 0;
    }

    /// Notificação do sistema, só com o telinha em segundo plano (no máximo
    /// uma a cada 2 s; o que chegar no meio vira "N mensagens novas").
    fn notifyAway(a: *App, title: []const u8, body: []const u8) void {
        if (!a.cfg.notifications or !a.away()) return;
        const now = c.igGetTime();
        if (now - a.notified_at < 2.0) return;
        a.notified_at = now;
        var t: [96]u8 = undefined;
        var bd: [300]u8 = undefined;
        const tz = std.fmt.bufPrintZ(&t, "{s}", .{title[0..@min(title.len, 90)]}) catch return;
        const bz = std.fmt.bufPrintZ(&bd, "{s}", .{body[0..@min(body.len, 290)]}) catch return;
        a.notifications_sent += 1;
        c.notify_send(tz.ptr, bz.ptr, nativeWindow(a.window));
    }

    /// Mensagens novas de chat (de outras pessoas, não o histórico) enquanto fora.
    fn notifyChat(a: *App, cl: *Client) void {
        cl.mutex.lock();
        const count = cl.chat_new;
        var name: [48]u8 = undefined;
        var name_len: usize = 0;
        var text: [256]u8 = undefined;
        var text_len: usize = 0;
        var fresh: u64 = 0;
        var mentioned = false;
        var my_name: []const u8 = "";
        for (cl.members.items) |*m| {
            if (m.id == cl.my_id) my_name = m.nameSlice();
        }
        if (count > a.notif_chat_seen) {
            // as novas estão no fim da lista
            var i = cl.chat.items.len;
            var left = count - a.notif_chat_seen;
            while (i > 0 and left > 0) {
                i -= 1;
                const l = &cl.chat.items[i];
                if (l.history) continue;
                left -= 1;
                if (l.from == 0 or l.from == cl.my_id) continue;
                fresh += 1;
                const ment = mentions(l.text, my_name) or l.to == cl.my_id or l.reply_from == cl.my_id;
                if (name_len == 0 or (ment and !mentioned)) {
                    name_len = @min(l.name_len, name.len);
                    @memcpy(name[0..name_len], l.name[0..name_len]);
                    const body: []const u8 = if (l.text.len > 0) l.text else if (l.img != null) tr("mandou uma imagem") else "";
                    text_len = @min(body.len, text.len);
                    @memcpy(text[0..text_len], body[0..text_len]);
                }
                if (ment) mentioned = true;
            }
        }
        cl.mutex.unlock();
        // primeira vez nessa sala: o que já tinha não conta
        if (a.notif_chat_seen == 0 and !a.notif_chat_ready) {
            a.notif_chat_ready = true;
            a.notif_chat_seen = count;
            return;
        }
        if (fresh == 0) {
            a.notif_chat_seen = count;
            return;
        }
        if (!a.cfg.notifications or !a.away()) {
            a.notif_chat_seen = count;
            return;
        }
        if (c.igGetTime() - a.notified_at < 2.0) return; // espera: junta as próximas
        a.notif_chat_seen = count;
        if (mentioned) {
            var t: [96]u8 = undefined;
            a.notifyAway(i18n.bufPrint(&t, "{s} mencionou você", .{name[0..name_len]}) catch "telinha", text[0..text_len]);
        } else if (fresh == 1) {
            a.notifyAway(name[0..name_len], text[0..text_len]);
        } else {
            var b: [64]u8 = undefined;
            a.notifyAway("telinha", i18n.bufPrint(&b, "{d} mensagens novas no chat", .{fresh}) catch "");
        }
    }

    fn onMicPacket(ctx: *anyopaque, packet: []const u8) void {
        const cl: *Client = @ptrCast(@alignCast(ctx));
        cl.sendVoice(cl.voice_seq.fetchAdd(1, .monotonic), packet);
    }

    fn startMic(a: *App) void {
        if (a.mic != null) return;
        const cl = a.client orelse return;
        var err: [256]u8 = undefined;
        const opts: voice.Options = .{
            .device = config.getStr(&a.cfg.mic_device),
            .noise_suppression = a.cfg.noise_suppression,
            .echo_cancellation = a.cfg.echo_cancellation,
            .sensitivity = micSensitivity(&a.cfg),
            .auto_gain = a.cfg.mic_agc,
            .gain = @as(f32, @floatFromInt(a.cfg.mic_gain)) / 100,
        };
        a.mic = voice.Mic.open(opts, cl.retain(), onMicPacket, &err) catch {
            cl.release();
            a.mic_wanted = false;
            var eb: [300]u8 = undefined;
            a.toast("Não consegui abrir o microfone: {s}", .{i18n.dynamic(std.mem.sliceTo(&err, 0), &eb)}, true);
            return;
        };
        a.mic_client = cl;
    }

    /// Sensibilidade 0..100 da configuração → probabilidade de voz mínima 0,9..0,1.
    fn micSensitivity(cfg: *const config.Config) f32 {
        return 0.9 - @as(f32, @floatFromInt(cfg.voice_sensitivity)) / 100 * 0.8;
    }

    fn stopMic(a: *App) void {
        if (a.mic) |m| m.close();
        a.mic = null;
        if (a.mic_client) |cl| cl.release();
        a.mic_client = null;
    }

    fn setDeaf(a: *App, deaf: bool) void {
        a.deaf = deaf;
        audio.mixer.deaf.store(deaf, .monotonic);
    }

    /// Liga/desliga o microfone conforme o que a pessoa quer e avisa a sala.
    fn applyVoice(a: *App, why: []const u8) void {
        const before = a.mic != null;
        // silenciado pelo admin: o servidor descartaria a voz; nem abre o microfone
        if (a.mic_wanted and !a.deaf and !a.admin_muted) a.startMic() else a.stopMic();
        // toda mudança do microfone vai pro log, com o porquê ("desmutou sozinho")
        if (before != (a.mic != null)) debuglog.line("microfone {s} ({s})", .{ if (a.mic != null) "ligado" else "desligado", why });
        if (a.client) |cl| {
            var flags: u8 = 0;
            if (a.mic != null) flags |= proto.voice_mic;
            if (a.deaf) flags |= proto.voice_deaf;
            cl.sendVoiceState(flags);
        }
    }

    fn toggleMic(a: *App, why: []const u8) void {
        if (a.admin_muted) {
            a.toast("O admin da sala silenciou seu microfone.", .{}, true);
            return;
        }
        if (a.deaf) {
            // como no Discord: ligar o microfone tira o "surdo"
            a.setDeaf(false);
            a.mic_wanted = true;
        } else a.mic_wanted = !a.mic_wanted;
        a.applyVoice(why);
        a.chime(if (a.mic != null) .mic_on else .mic_off);
        if (a.mic != null and !a.echo_hint_shown) {
            a.echo_hint_shown = true;
            if (a.cfg.echo_cancellation)
                a.toast("Microfone ligado (Ctrl+M liga/desliga, Ctrl+D fica surdo).", .{}, false)
            else
                a.toast("Microfone ligado (Ctrl+M liga/desliga). Cancelamento de eco desligado: sem fone de ouvido, a sala pode ouvir eco da sua caixa de som.", .{}, false);
        }
    }

    fn toggleDeaf(a: *App, why: []const u8) void {
        if (a.deaf) {
            a.setDeaf(false);
            a.chime(.mic_on);
        } else {
            a.chime(.mic_off); // os avisos tocam mesmo surdo
            a.setDeaf(true); // surdo também desliga o microfone (mic_wanted fica guardado)
        }
        a.applyVoice(why);
    }

    /// Sala sem senha ganha uma (link público: qualquer um que achasse a
    /// porta entraria). Retorna true se criou.
    fn ensureRoomPassword(a: *App) bool {
        if (config.getStr(&a.cfg.host_pass).len > 0) return false;
        const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        var pw: [8]u8 = undefined;
        for (&pw, rnd) |*ch, r| ch.* = alphabet[r % alphabet.len];
        config.setStr(&a.cfg.host_pass, &pw);
        config.save(&a.cfg);
        a.toast("Sala aberta pra fora precisa de senha: ela ganhou a senha {s} (já vai no convite).", .{pw}, false);
        return true;
    }

    /// Sala com endereço público (túnel ou porta aberta) precisa de senha.
    /// Retorna false se ainda não dá (a gente mesmo ainda está entrando).
    fn requirePublicPassword(a: *App, s: *Server) bool {
        if (s.hasPassword()) return true;
        // a senha nova só vale pra quem conectar depois: a gente mesmo
        // precisa já estar dentro, senão nosso próprio handshake falha
        const connected = if (a.client) |cl| blk: {
            cl.mutex.lock();
            defer cl.mutex.unlock();
            break :blk cl.status == .connected;
        } else false;
        if (!connected) {
            a.toast("Espera entrar na sala pra abrir ela pra fora.", .{}, true);
            return false;
        }
        if (a.ensureRoomPassword()) s.setPassword(config.getStr(&a.cfg.host_pass));
        return true;
    }

    /// Liga o link público (túnel pelo protocolo do bore).
    fn startTunnel(a: *App) void {
        const s = a.server orelse return;
        if (a.tunnel != null) return;
        if (!a.requirePublicPassword(s)) return;
        a.tunnel = Tunnel.start(config.getStr(&a.cfg.tunnel_host), s, Server.adoptCallback) catch {
            a.toast("Não consegui abrir o link público.", .{}, true);
            return;
        };
        // o túnel entrega conexões até a thread dele acabar: segura o servidor até lá
        s.retain();
        a.tunnel.?.ctx_release = Server.releaseCallback;
    }

    /// Pede pro roteador abrir a porta da sala (UPnP): conexão direta, sem túnel.
    fn startUpnp(a: *App) void {
        const s = a.server orelse return;
        if (a.upnp != null) return;
        if (!a.requirePublicPassword(s)) return;
        const to, const to_port = upnp.discoveryTarget();
        a.upnp = upnp.Mapper.start(s.port, to, to_port) catch {
            a.toast("Não consegui pedir a porta pro roteador.", .{}, true);
            return;
        };
    }

    fn stopUpnp(a: *App) void {
        if (a.upnp) |m| m.stop(); // a thread fecha a porta no roteador
        a.upnp = null;
    }

    /// Desliga o link público. Quem entrou por ele sai da sala (o túnel é o
    /// caminho dessas pessoas até aqui; sem ele, ficariam "penduradas").
    fn stopTunnel(a: *App) void {
        const t = a.tunnel orelse return;
        if (a.server) |s| s.closeTunnelConns();
        t.stop();
        a.tunnel = null;
    }

    fn connect(a: *App, addrs: []const u8, pass: []const u8, admin_token: []const u8, channel: []const u8, expect_fp: []const u8, tofu: bool) void {
        a.home_error_len = 0;
        a.trust_fp_len = 0;
        a.conn_addrs_len = @min(addrs.len, a.conn_addrs.len);
        @memcpy(a.conn_addrs[0..a.conn_addrs_len], addrs[0..a.conn_addrs_len]);
        config.save(&a.cfg);
        a.chan_gen_seen = 0;
        a.stats_open = false;
        a.stats_hist_n = 0;
        a.stats_seen = 0;
        a.client = Client.create(.{ .addrs = addrs, .name = a.myName(), .password = pass, .admin_token = admin_token, .client_key = a.cfg.client_key, .hw_decode = a.cfg.hardware, .channel = channel, .expect_fp = expect_fp, .tofu = tofu, .wake = wakeUi }) catch {
            a.setHomeError(tr("Endereço inválido."));
            return;
        };
        // até conectar mostra a lista (ou "N caminhos"); depois, o que ganhou
        const n_paths = std.mem.count(u8, addrs, ",") + 1;
        const s = (if (n_paths > 1)
            i18n.bufPrint(&a.connect_label, "{d} caminhos", .{n_paths})
        else
            std.fmt.bufPrint(&a.connect_label, "{s}", .{addrs})) catch "";
        a.connect_label_len = s.len;
        a.was_connected = false;
        a.n_auto_watched = 0; // ids da conexão nova
        a.notif_chat_seen = 0;
        a.notif_chat_ready = false;
        a.screen = .room;
        a.chat_seen = 0;
        a.chat_unread = 0;
        a.focused = null;
    }

    fn leaveRoom(a: *App) void {
        a.trim_at = c.igGetTime() + 2;
        a.closeModals();
        a.clearChatImages();
        a.chat_h.clearRetainingCapacity();
        a.stopMic();
        a.mic_wanted = false;
        a.setDeaf(false);
        a.n_known = 0;
        a.known_ready = false;
        a.closePips();
        a.stopSharing();
        a.stopCamera();
        a.leave_confirm = false;
        a.admin_muted = false;
        // a sala fecha primeiro (todo mundo recebe "o dono fechou a sala",
        // inclusive quem está do outro lado do túnel), depois os caminhos
        if (a.server) |s| s.stop();
        for (a.views.items) |v| {
            freeViewGpu(v);
            if (a.client) |cl| cl.unwatch(v);
        }
        a.views.clearRetainingCapacity();
        if (a.client) |cl| cl.close();
        a.client = null;
        if (a.tunnel) |t| t.stop();
        a.tunnel = null;
        a.stopUpnp();
        a.server = null;
        a.screen = .home;
        a.home_seen = false;
        a.theater = false;
        a.focused = null;
        a.reconnect = .{};
        a.rewatch = .{};
        if (a.fullscreen) a.toggleFullscreen();
    }

    /// Agenda a próxima tentativa (espera 1, 2, 4, 8, 10, 10 s).
    fn scheduleReconnect(a: *App) void {
        const r = &a.reconnect;
        if (r.attempt == 0) {
            r.share = a.sharer != null;
            r.camera = a.camera != null;
            r.n_watch = 0;
            if (a.client) |cl| {
                cl.mutex.lock();
                defer cl.mutex.unlock();
                for (a.views.items) |v| {
                    if (r.n_watch == r.watch.len) break;
                    for (cl.members.items) |*m| {
                        if (m.id != v.member()) continue;
                        const n = m.name_len;
                        @memcpy(r.watch[r.n_watch][0..n], m.name[0..n]);
                        r.watch_len[r.n_watch] = n;
                        r.watch_kind[r.n_watch] = v.kind();
                        r.n_watch += 1;
                    }
                }
            }
        }
        r.attempt += 1;
        r.waiting = true;
        const exp: u5 = @intCast(@min(r.attempt - 1, 4));
        r.at = c.igGetTime() + @min(10.0, @as(f64, @floatFromInt(@as(u32, 1) << exp)));
    }

    fn doReconnect(a: *App) void {
        a.reconnect.waiting = false;
        a.closeModals();
        // derruba o que sobrou da conexão antiga, mas continua na tela da sala
        a.stopMic(); // volta sozinho em finishReconnect (mic_wanted continua)
        a.n_known = 0; // ids podem mudar (servidor reiniciou): sem sons de entrou/saiu
        a.known_ready = false;
        a.stopSharing();
        a.stopCamera();
        a.admin_muted = false; // conexão nova: o servidor não lembra
        for (a.views.items) |v| {
            freeViewGpu(v);
            if (a.client) |cl| cl.unwatch(v);
        }
        a.views.clearRetainingCapacity();
        if (a.client) |cl| {
            // volta pro canal em que estava
            cl.mutex.lock();
            if (cl.chans_supported) config.setStr(&a.cfg.join_channel, cl.chan_name[0..cl.chan_name_len]);
            cl.mutex.unlock();
            cl.close();
        }
        a.client = null;
        a.joinRoom();
        if (a.client == null) {
            a.reconnect = .{};
            a.screen = .home;
        }
    }

    fn finishReconnect(a: *App) void {
        const r = a.reconnect;
        a.reconnect = .{};
        if (r.share) a.startSharing();
        if (r.camera) a.toggleCamera();
        a.applyVoice("reconectou");
        a.rewatch = r;
        a.rewatch_until = c.igGetTime() + 20;
        a.toast("Reconectado!", .{}, false);
    }

    /// Depois de reconectar: volta a assistir quem estava assistindo, quando aparecer ao vivo.
    fn applyRewatch(a: *App, cl: *Client) void {
        if (a.rewatch.n_watch == 0) return;
        if (c.igGetTime() > a.rewatch_until) {
            a.rewatch = .{};
            return;
        }
        var want: [16]u32 = undefined;
        var n_want: usize = 0;
        cl.mutex.lock();
        var i: usize = 0;
        while (i < a.rewatch.n_watch) {
            const name = a.rewatch.watch[i][0..a.rewatch.watch_len[i]];
            const kind = a.rewatch.watch_kind[i];
            const found = for (cl.members.items) |*m| {
                if (m.live(kind) and m.id != cl.my_id and std.mem.eql(u8, m.nameSlice(), name)) break m.id;
            } else null;
            if (found) |id| {
                want[n_want] = proto.streamId(id, kind);
                n_want += 1;
                // tira da lista
                a.rewatch.n_watch -= 1;
                a.rewatch.watch[i] = a.rewatch.watch[a.rewatch.n_watch];
                a.rewatch.watch_len[i] = a.rewatch.watch_len[a.rewatch.n_watch];
                a.rewatch.watch_kind[i] = a.rewatch.watch_kind[a.rewatch.n_watch];
            } else i += 1;
        }
        cl.mutex.unlock();
        for (want[0..n_want]) |id| a.watch(id);
    }

    /// Fonte escolhida na janela de compartilhar.
    fn chosenSource(a: *App) ?*const c.cap_source {
        if (a.n_sources == 0) return null;
        return &a.sources[@intCast(std.math.clamp(a.source_idx, 0, @as(i32, @intCast(a.n_sources)) - 1))];
    }

    /// De quem é o som: nada, tudo, o programa da janela compartilhada ou um
    /// programa escolhido. cfg.audio_app: "" = tudo; "*janela" = o da janela.
    fn drawAudioChoice(a: *App, w: f32) void {
        const src = a.chosenSource();
        const win_app: []const u8 = if (src) |x| std.mem.sliceTo(&x.app, 0) else "";
        const has_win = src != null and src.?.pid != 0;
        const cur = config.getStr(&a.cfg.audio_app);
        const window_mode = std.mem.eql(u8, cur, "*janela");
        var preview_buf: [96]u8 = undefined;
        const preview: []const u8 = if (!a.cfg.audio)
            tr("Sem som")
        else if (window_mode and has_win)
            i18n.bufPrint(&preview_buf, "Só o som da janela ({s})", .{win_app}) catch win_app
        else if (cur.len == 0 or window_mode)
            tr("Todo o som do computador (menos o telinha)")
        else
            i18n.bufPrint(&preview_buf, "Só o som do {s}", .{cur}) catch cur;
        fieldLabel("SOM");
        // "todo o som": o botão de excluir programas fica do lado
        const all_mode = a.cfg.audio and cur.len == 0;
        const excl_w = S(56);
        c.igSetNextItemWidth(if (all_mode) w - excl_w - S(6) else w);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(9)));
        if (beginCombo("##audio", fmtZ("{s}", .{preview}).ptr, 0)) {
            if (c.igSelectable_Bool(tr("Todo o som do computador (menos o telinha)###audioall"), a.cfg.audio and cur.len == 0, 0, v2(0, 0))) {
                a.cfg.audio = true;
                config.setStr(&a.cfg.audio_app, "");
            }
            if (has_win and c.igSelectable_Bool(fmtZ("Só o som da janela ({s})###audiowin", .{win_app}).ptr, a.cfg.audio and window_mode, 0, v2(0, 0))) {
                a.cfg.audio = true;
                config.setStr(&a.cfg.audio_app, "*janela");
            }
            for (a.audio_apps[0..a.n_audio_apps], 0..) |*ap, i| {
                const name = std.mem.sliceTo(&ap.name, 0);
                c.igPushID_Int(@intCast(i));
                if (c.igSelectable_Bool(fmtZ("Só o som do {s}###audioapp", .{name}).ptr, a.cfg.audio and std.ascii.eqlIgnoreCase(name, cur), 0, v2(0, 0))) {
                    a.cfg.audio = true;
                    config.setStr(&a.cfg.audio_app, name);
                }
                c.igPopID();
            }
            if (c.igSelectable_Bool(tr("Sem som###audionone"), !a.cfg.audio, 0, v2(0, 0))) a.cfg.audio = false;
            c.igEndCombo();
        }
        const combo_h = c.igGetItemRectSize().y;
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
        if (all_mode) {
            c.igSameLine(0, S(6));
            a.drawAudioExclude(excl_w, combo_h, w);
        }
        if (a.n_audio_apps == 0 and !sync.is_windows) {
            pushFont(font_regular, 12);
            textColored(col.faint, tr("Programa tocando som aparece na lista (abra de novo esta janela se não aparecer)."));
            popFont();
        }
    }

    /// "Todo o som" menos alguns programas (o Discord, pra quem assiste não
    /// ouvir a própria voz de volta, por exemplo).
    fn drawAudioExclude(a: *App, bw: f32, bh: f32, w: f32) void {
        const list = config.getStr(&a.cfg.audio_exclude);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, list, '\n');
        while (it.next()) |x| {
            if (x.len > 0) n += 1;
        }
        const label = if (n == 0) fmtZ("{s}###audioexcl", .{ic.ban}) else fmtZ("{s} {d}###audioexcl", .{ ic.ban, n });
        const clicked = secondaryButton(label, v2(bw, bh));
        if (c.igIsItemHovered(0)) tooltipText(tr("Excluir programas do som (ex.: o Discord)"));
        if (clicked) {
            a.n_audio_apps = audio.listApps(&a.audio_apps); // quem está tocando agora
            _ = c.igOpenPopup_Str("##excluirsom", 0);
        }
        if (n > 0) {
            pushFont(font_regular, 12);
            var nb: [1024]u8 = undefined;
            const nn = std.mem.replace(u8, list, "\n", ", ", &nb);
            const names = nb[0 .. list.len + nn];
            c.igPushTextWrapPos(c.igGetCursorPosX() + w);
            textColored(col.faint, fmtZ("Fora do som: {s}", .{names}));
            c.igPopTextWrapPos();
            popFont();
        }
        if (a.sharer) |s| if (s.audio_exclude_ignored) {
            pushFont(font_regular, 12);
            textColored(col.yellow, tr("O Windows não deixou excluir programas do som: vai todo o som do computador (menos o telinha)."));
            popFont();
        };
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(14), S(12)));
        defer c.igPopStyleVar(1);
        if (!c.igBeginPopup("##excluirsom", 0)) return;
        defer c.igEndPopup();
        pushFont(font_bold, 13);
        textColored(col.header, tr("Quem fica de fora do som da transmissão"));
        popFont();
        pushFont(font_regular, 12);
        textColored(col.faint, tr("Ex.: o Discord, pra quem assiste não ouvir a própria voz de volta."));
        popFont();
        c.igDummy(v2(0, S(4)));
        var any = false;
        // quem está tocando agora
        for (a.audio_apps[0..a.n_audio_apps], 0..) |*ap, i| {
            const name = std.mem.sliceTo(&ap.name, 0);
            any = true;
            var on = audio.inList(config.getStr(&a.cfg.audio_exclude), name);
            c.igPushID_Int(@intCast(i));
            if (c.igCheckbox(fmtZ("{s}###excl", .{name}).ptr, &on)) a.setAudioExcluded(name, on);
            c.igPopID();
        }
        // excluídos que não estão tocando agora (pra poder tirar da lista)
        var it2 = std.mem.splitScalar(u8, config.getStr(&a.cfg.audio_exclude), '\n');
        var k: i32 = 1000;
        while (it2.next()) |name| {
            if (name.len == 0) continue;
            const playing = for (a.audio_apps[0..a.n_audio_apps]) |*ap| {
                if (std.ascii.eqlIgnoreCase(std.mem.sliceTo(&ap.name, 0), name)) break true;
            } else false;
            if (playing) continue;
            any = true;
            var on = true;
            var nb: [64]u8 = undefined;
            const copy = nb[0..@min(name.len, nb.len)];
            @memcpy(copy, name[0..copy.len]);
            c.igPushID_Int(k);
            k += 1;
            if (c.igCheckbox(fmtZ("{s} (não está tocando agora)###excl", .{copy}).ptr, &on) and !on) {
                a.setAudioExcluded(copy, false);
                c.igPopID();
                break; // a lista mudou
            }
            c.igPopID();
        }
        if (!any) textColored(col.muted, tr("Nenhum programa tocando som agora. Dá o play no que quer excluir e abre de novo."));
    }

    /// Põe ou tira um programa da lista de exclusão do som (e aplica se já está ao vivo).
    fn setAudioExcluded(a: *App, name: []const u8, on: bool) void {
        var out: [512]u8 = [_]u8{0} ** 512;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, config.getStr(&a.cfg.audio_exclude), '\n');
        while (it.next()) |x| {
            if (x.len == 0 or std.ascii.eqlIgnoreCase(x, name)) continue;
            if (len + x.len + 1 >= out.len) break;
            if (len > 0) {
                out[len] = '\n';
                len += 1;
            }
            @memcpy(out[len..][0..x.len], x);
            len += x.len;
        }
        if (on and len + name.len + 1 < out.len) {
            if (len > 0) {
                out[len] = '\n';
                len += 1;
            }
            @memcpy(out[len..][0..name.len], name);
            len += name.len;
        }
        config.setStr(&a.cfg.audio_exclude, out[0..len]);
        config.save(&a.cfg);
        if (a.sharer) |s| s.update(a.shareSettings());
    }

    fn shareSettings(a: *App) sharer_mod.Settings {
        const heights = [_]u32{ 0, 1080, 720, 480 };
        var st: sharer_mod.Settings = .{
            .source = if (a.n_sources > 0) a.sources[@intCast(std.math.clamp(a.source_idx, 0, @as(i32, @intCast(a.n_sources)) - 1))].id else 0,
            .fps = @intCast(std.math.clamp(a.cfg.fps, 1, 60)),
            .quality = @intCast(std.math.clamp(a.cfg.quality, 20, 100)),
            .max_height = heights[@intCast(a.cfg.resolution)],
            .cursor = a.cfg.cursor,
            .mode = if (a.cfg.mode == 1) .motion else .screen,
            .hardware = a.cfg.hardware,
            .audio = a.cfg.audio,
            .clips = a.cfg.clips,
            .auto_quality = a.cfg.auto_quality,
            .cursor_apart = a.cfg.cursor_apart,
            .view_size = a.cfg.view_size,
        };
        const cur = config.getStr(&a.cfg.audio_app);
        if (std.mem.eql(u8, cur, "*janela")) {
            // o programa dono da janela compartilhada (e os processos filhos dele)
            if (a.chosenSource()) |src| st.audio_pid = src.pid;
        } else config.setStr(&st.audio_app, cur);
        config.setStr(&st.audio_exclude, config.getStr(&a.cfg.audio_exclude));
        st.crop = a.crop;
        return st;
    }

    fn startSharing(a: *App) void {
        const cl = a.client orelse return;
        config.save(&a.cfg);
        if (a.sharer) |s| {
            // já está ao vivo: só aplica as configurações novas
            s.update(a.shareSettings());
            a.toast("Configurações aplicadas.", .{}, false);
            return;
        }
        const st = a.shareSettings();
        debuglog.line("começou a transmitir: fonte {d}, {d} q/s, qualidade {d}, altura máx {d}, modo {s}, placa={}, som={} ({s} pid {d}), cursor={}", .{ st.source, st.fps, st.quality, st.max_height, @tagName(st.mode), st.hardware, st.audio, std.mem.sliceTo(&st.audio_app, 0), st.audio_pid, st.cursor });
        a.sharer = Sharer.start(cl, st) catch {
            a.toast("Não consegui iniciar a transmissão.", .{}, true);
            return;
        };
    }

    /// Avisos do admin (silenciou, parou a transmissão, deu/tirou admin).
    fn handleNotices(a: *App, cl: *Client) void {
        while (cl.takeNotice()) |n| {
            switch (n.kind) {
                proto.notice_muted => {
                    a.admin_muted = true;
                    a.applyVoice("admin silenciou");
                },
                proto.notice_unmuted => {
                    a.admin_muted = false;
                    a.applyVoice("admin liberou");
                },
                proto.notice_stream_stopped => if (n.extra == proto.kind_camera) a.stopCamera() else a.stopSharing(),
                proto.notice_log_received => debuglog.line("{s}", .{n.textSlice()}),
                proto.notice_channel => if (n.extra == proto.notice_channel_needs_password and a.chan_req_len > 0) {
                    // o canal pede senha: o painel pergunta (e manda o mesmo pedido de novo)
                    @memcpy(a.chan_pw_for[0..a.chan_req_len], a.chan_req[0..a.chan_req_len]);
                    a.chan_pw_len = a.chan_req_len;
                    a.chan_pw_call = a.chan_req_call;
                    a.focus_chan_pw = true;
                    a.cfg.show_chat = true;
                },
                proto.notice_draw_off => {
                    a.draw_tile = null;
                    a.draw_active = false;
                },
                else => {},
            }
            const bad = n.kind == proto.notice_muted or n.kind == proto.notice_stream_stopped or n.kind == proto.notice_admin_off or n.kind == proto.notice_channel or n.kind == proto.notice_draw_off or n.kind == proto.notice_dm or n.kind == proto.notice_file_gone;
            var nb: [200]u8 = undefined;
            a.toast("{s}", .{i18n.server(n.textSlice(), &nb)}, bad);
        }
    }

    /// Liga/desliga a câmera (uma transmissão a mais, do tipo câmera).
    fn toggleCamera(a: *App) void {
        if (a.camera != null) {
            a.stopCamera();
            return;
        }
        const cl = a.client orelse return;
        a.ensureInCall();
        a.camera = Sharer.start(cl, a.cameraSettings()) catch {
            a.toast("Não consegui ligar a câmera.", .{}, true);
            return;
        };
    }

    fn cameraSettings(a: *App) sharer_mod.Settings {
        var st: sharer_mod.Settings = .{
            .kind = proto.kind_camera,
            .fps = 30,
            .quality = 55,
            .max_height = switch (a.cfg.camera_res) {
                0 => 480,
                1 => 720,
                else => 1080,
            },
            .cursor = false,
            .mode = .motion,
            .hardware = a.cfg.hardware,
            .audio = false,
            .clips = a.cfg.clips,
        };
        config.setStr(&st.camera_id, config.getStr(&a.cfg.camera_device));
        return st;
    }

    fn stopCamera(a: *App) void {
        if (a.camera) |cam| {
            gl.delete(&cam.preview_tex);
            cam.stop();
            a.trim_at = c.igGetTime() + 2; // o encoder termina numa thread: devolve a memória depois
        }
        a.camera = null;
        if (a.focused == proto.streamId(0, proto.kind_camera)) a.focused = null;
    }

    /// "Sair" de quem hospeda fecha a sala pra todo mundo: pergunta antes.
    fn askLeave(a: *App) void {
        if (a.server) |s| {
            if (s.memberCount() > 1) {
                a.leave_confirm = true;
                return;
            }
        }
        a.leaveRoom();
    }

    fn stopSharing(a: *App) void {
        if (a.sharer != null) debuglog.line("parou de transmitir", .{});
        audio.mixer.self_mute.store(false, .monotonic);
        a.audio_err_shown = false;
        a.self_mute_shown = false;
        if (a.sharer) |s| {
            gl.delete(&s.preview_tex);
            s.stop();
            a.trim_at = c.igGetTime() + 2;
        }
        a.sharer = null;
        a.auto_cap_seen = 0;
        a.crop = .{ 0, 0, 1, 1 };
        a.crop_tile = null;
        if (a.focused == 0) a.focused = null;
    }

    fn findView(a: *App, stream: u32) ?*View {
        for (a.views.items) |v| if (v.stream == stream) return v;
        return null;
    }

    fn watch(a: *App, stream: u32) void {
        debuglog.line("assistir {x}", .{stream});
        const cl = a.client orelse return;
        if (a.findView(stream) != null) return;
        const v = cl.watch(stream, if (a.cfg.clips) proto.watch_clips else 0) catch return;
        a.views.append(std.heap.c_allocator, v) catch {};
    }

    fn unwatch(a: *App, stream: u32) void {
        const cl = a.client orelse return;
        debuglog.line("parou de assistir {x}", .{stream});
        a.trim_at = c.igGetTime() + 2; // decoder e buffers da transmissão saem numa thread
        for (a.views.items, 0..) |v, i| {
            if (v.stream != stream) continue;
            if (v.clip) |cb| if (cb.recState().active) a.stopRecording(cb, "");
            freeViewGpu(v);
            cl.unwatch(v);
            _ = a.views.orderedRemove(i);
            break;
        }
        if (a.focused == stream) a.focused = null;
        if (a.tile_controls == stream) a.tile_controls = null;
        if (a.views.items.len == 0 and a.sharer == null) a.theater = false;
    }

    /// O monitor onde está o meio da janela (tela cheia vai pra ele, não pro principal).
    fn windowMonitor(a: *App) ?*c.GLFWmonitor {
        var wx: c_int = 0;
        var wy: c_int = 0;
        var ww: c_int = 0;
        var wh: c_int = 0;
        c.glfwGetWindowPos(a.window, &wx, &wy);
        c.glfwGetWindowSize(a.window, &ww, &wh);
        const cx = wx + @divTrunc(ww, 2);
        const cy = wy + @divTrunc(wh, 2);
        var n: c_int = 0;
        const mons = c.glfwGetMonitors(&n) orelse return c.glfwGetPrimaryMonitor();
        for (mons[0..@intCast(n)]) |m| {
            var mx: c_int = 0;
            var my: c_int = 0;
            c.glfwGetMonitorPos(m, &mx, &my);
            const mode = c.glfwGetVideoMode(m) orelse continue;
            if (cx >= mx and cy >= my and cx < mx + mode.*.width and cy < my + mode.*.height) return m;
        }
        return c.glfwGetPrimaryMonitor();
    }

    fn toggleFullscreen(a: *App) void {
        if (!a.fullscreen) {
            c.glfwGetWindowPos(a.window, &a.saved_win[0], &a.saved_win[1]);
            c.glfwGetWindowSize(a.window, &a.saved_win[2], &a.saved_win[3]);
            const mon = a.windowMonitor() orelse return;
            const mode = c.glfwGetVideoMode(mon) orelse return;
            c.glfwSetWindowMonitor(a.window, mon, 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
            a.fullscreen = true;
        } else {
            c.glfwSetWindowMonitor(a.window, null, a.saved_win[0], a.saved_win[1], a.saved_win[2], a.saved_win[3], 0);
            a.fullscreen = false;
        }
    }

    // ------------------------------------------------------------- por frame

    /// Tela cheia ou cinema: com o mouse parado 2,5 s, os controles dos quadros
    /// e a seta somem; qualquer movimento ou clique traz de volta.
    fn updateIdleControls(a: *App, io: *c.ImGuiIO) void {
        const now = c.igGetTime();
        if (io.MouseDelta.x != 0 or io.MouseDelta.y != 0 or c.igIsMouseDown_Nil(0) or c.igIsMouseDown_Nil(1) or io.MouseWheel != 0) a.mouse_moved_at = now;
        const immersive = (a.theater or a.fullscreen) and a.screen == .room;
        const busy = a.share_modal or a.settings_modal or a.crop_tile != null or a.draw_tile != null or a.pointer_tile != null;
        const hide = immersive and !busy and now - a.mouse_moved_at > 2.5;
        // acorda a interface na hora de esconder (ela dorme quando nada muda)
        if (immersive and !hide) redrawIn(2.55 - (now - a.mouse_moved_at));
        if (hide != a.controls_hidden) {
            a.controls_hidden = hide;
            c.glfwSetInputMode(a.window, c.GLFW_CURSOR, if (hide) c.GLFW_CURSOR_HIDDEN else c.GLFW_CURSOR_NORMAL);
        }
    }

    /// Libera as texturas de uma transmissão (thread da UI).
    fn freeViewGpu(v: *View) void {
        if (yuv_renderer) |*r| {
            if (v.yuv.out != 0 and v.tex == v.yuv.out) v.tex = 0;
            v.yuv.deinit(r);
        }
        gl.delete(&v.tex);
    }

    /// Sobe pra GPU o que mudou nas transmissões (antes de desenhar).
    /// Latência de ponta a ponta: captura no transmissor → tela aqui.
    fn noteLatency(a: *App, v: *View, f: *const client_mod.Pic) void {
        const cl = a.client orelse return;
        const now = cl.serverNowUs();
        if (now > f.ts and f.ts > 0) {
            const lat = @as(f32, @floatFromInt(now - f.ts)) / 1000.0;
            if (lat < 10_000) v.latency_ms = if (v.latency_ms == 0) lat else v.latency_ms * 0.9 + lat * 0.1;
        }
    }

    fn uploadTextures(a: *App) void {
        var fw: c_int = 0;
        var fh: c_int = 0;
        c.glfwGetFramebufferSize(a.window, &fw, &fh);
        a.fb_viewport = .{ 0, 0, fw, fh };
        // NVIDIA: o quadro do NVDEC vai direto pra textura (cudagl.c). Só liga
        // quando tem o que assistir: reter o contexto CUDA custa memória
        if (!a.cuda_probed and a.views.items.len > 0 and client_mod.gpu_yuv.load(.acquire)) {
            a.cuda_probed = true;
            gl.initCuda();
            client_mod.gpu_interop.store(gl.cudagl != null, .release);
            if (debuglog.on()) debuglog.line("NVDEC direto pra textura: {s}", .{if (gl.cudagl != null) "sim" else "não (sem NVIDIA/CUDA)"});
        }
        for (a.views.items) |v| {
            // minimizado: só o que aparece numa janela flutuante (o resto fica
            // marcado e sobe quando a janela voltar)
            if (a.iconified and a.findPip(v.stream) == null) continue;
            // pega o quadro novo (só a troca é travada; o upload não segura o decode)
            v.mutex.lock();
            const took = v.fresh;
            if (took) std.mem.swap(client_mod.Pic, &v.ready, &v.front);
            v.fresh = false;
            v.mutex.unlock();
            const f = &v.front;
            // em que tamanho (pixels) o vídeo apareceu no quadro passado: 0 = não apareceu
            const want_w = v.disp_px_w;
            const want_h = v.disp_px_h;
            v.disp_px_w = 0;
            v.disp_px_h = 0;
            a.reportViewSize(v, want_h);
            if (f.w == 0) continue;
            if (took) v.gl_stale = true;
            if (f.layout != .rgba) {
                // planos YUV: a GPU converte, no tamanho em que aparece (um 1080p
                // num quadradinho não converte 1080p); quem não aparece fica pra depois
                const r = &(yuv_renderer orelse continue);
                if (want_w == 0 and v.tex != 0) {
                    if (took) a.noteLatency(v, f);
                    continue;
                }
                const tw = @min(if (want_w == 0) f.w else want_w, f.w);
                const th = @min(if (want_h == 0) f.h else want_h, f.h);
                // cresceu (ou encolheu bastante) com a imagem parada: converte de novo sem subir nada
                const resize = v.yuv.ow == 0 or tw > v.yuv.ow + v.yuv.ow / 16 or tw < v.yuv.ow * 3 / 4;
                if (!v.gl_stale and !resize and v.tex != 0) continue;
                if (v.gl_stale) {
                    if (f.layout == .nv12_dev) {
                        const db = f.dev orelse continue;
                        if (!r.uploadDevice(&v.yuv, db.ptr, db.uv(), db.pitch, f.w, f.h)) {
                            // a cópia placa→textura falhou: daqui pra frente pela CPU
                            client_mod.gpu_interop.store(false, .release);
                            continue;
                        }
                    } else r.upload(&v.yuv, f.data, f.w, f.h, f.layout == .nv12);
                    v.gl_stale = false;
                }
                if (v.tex != 0 and v.tex != v.yuv.out) gl.delete(&v.tex);
                if (r.convert(&v.yuv, tw, th, a.fb_viewport)) {
                    v.tex = v.yuv.out;
                    v.tex_w = f.w;
                    v.tex_h = f.h;
                }
                if (took) a.noteLatency(v, f);
                continue;
            }
            if (!took and v.tex != 0) continue;
            v.gl_stale = false;
            if (f.w != v.tex_w or f.h != v.tex_h or v.tex == 0 or v.tex == v.yuv.out) {
                if (v.tex == v.yuv.out) v.tex = 0;
                gl.upload(&v.tex, f.data, f.w, f.h, gl.RGBA);
                v.tex_w = f.w;
                v.tex_h = f.h;
            } else {
                gl.uploadRect(v.tex, f.data, f.w, 0, 0, f.w, f.h, gl.RGBA);
            }
            a.noteLatency(v, f);
        }
        for ([_]?*Sharer{ a.sharer, a.camera }) |maybe| {
            const s = maybe orelse continue;
            // minimizado: a miniatura fica marcada e sobe quando a janela voltar
            // (subir sem trocar a tela acumula memória no driver: o log do Ryzen
            // foi de 200 MB pra 900 MB em 90 s minimizado)
            if (a.iconified) continue;
            s.mutex.lock();
            defer s.mutex.unlock();
            if (s.preview_new and s.preview.len > 0) {
                a.preview_uploads += 1;
                const fmt = if (s.preview_bgr) gl.BGRA else gl.RGBA;
                // mesmo tamanho: atualiza a textura no lugar (sem realocar na GPU)
                if (s.preview_tex != 0 and s.preview_tex_w == s.preview_w and s.preview_tex_h == s.preview_h) {
                    gl.uploadRect(s.preview_tex, s.preview, s.preview_w, 0, 0, s.preview_w, s.preview_h, fmt);
                } else {
                    gl.upload(&s.preview_tex, s.preview, s.preview_w, s.preview_h, fmt);
                    s.preview_tex_w = s.preview_w;
                    s.preview_tex_h = s.preview_h;
                }
                s.preview_new = false;
            }
        }
    }

    /// Diz pro servidor em que altura essa transmissão aparece (quem transmite
    /// manda no maior tamanho entre quem assiste). Degraus fixos, e só desce
    /// depois de 3 s menor (redimensionar a janela não fica trocando a
    /// resolução de quem transmite); sobe na hora.
    fn reportViewSize(a: *App, v: *View, shown_h: u32) void {
        const cl = a.client orelse return;
        const now = sync.nowMs();
        const tiers = [_]u16{ 360, 480, 540, 720, 900, 1080, 1440, 2160 };
        var q: u16 = proto.view_full;
        for (tiers) |t| if (shown_h <= t) {
            q = t;
            break;
        };
        // gravando: quer tudo (a gravação sai no tamanho que chega)
        if (v.clip) |cb| if (cb.recState().active) {
            q = proto.view_full;
        };
        if (q >= v.view_sent_h) {
            v.view_lower_since_ms = 0;
            v.view_peak_h = 0;
            if (q > v.view_sent_h) {
                v.view_sent_h = q;
                cl.sendViewSize(v.stream, q);
            }
            return;
        }
        // menor: espera ficar assim um tempo, e aí pede o maior visto nesse tempo
        if (v.view_lower_since_ms == 0) v.view_lower_since_ms = now;
        v.view_peak_h = @max(v.view_peak_h, q);
        if (now - v.view_lower_since_ms >= 3000) {
            v.view_sent_h = @intCast(v.view_peak_h);
            cl.sendViewSize(v.stream, v.view_sent_h);
            v.view_lower_since_ms = 0;
            v.view_peak_h = 0;
        } else redrawIn(0.5); // reavalia mesmo com a interface parada
    }

    fn checkState(a: *App) void {
        const cl = a.client orelse return;
        cl.mutex.lock();
        const st = cl.status;
        cl.mutex.unlock();
        if (st == .connected and !a.was_connected) {
            a.was_connected = true;
            // provou quem é: da próxima vez nesse endereço, tem que ser o mesmo
            if (cl.id_state == .verified and a.server == null) known.remember(a.conn_addrs[0..a.conn_addrs_len], &cl.server_fp);
            if (cl.viaTarget()) |t| {
                const lbl = std.fmt.bufPrint(&a.connect_label, "{s}{s}{s}:{d}", .{
                    if (std.mem.findScalar(u8, t.hostSlice(), ':') != null) "[" else "", t.hostSlice(),
                    if (std.mem.findScalar(u8, t.hostSlice(), ':') != null) "]" else "", t.port,
                }) catch "";
                a.connect_label_len = lbl.len;
            }
            if (a.reconnect.attempt == 0) {
                a.mic_wanted = a.cfg.mic_on_join;
                a.applyVoice("entrou na sala");
            }
            if (a.reconnect.attempt > 0) {
                a.finishReconnect();
            } else if (a.auto_share and a.sharer == null) {
                a.n_sources = @intCast(c.cap_list_sources(&a.sources, a.sources.len));
                a.startSharing();
            }
        }
        if (st == .connected) {
            const g = cl.channel_gen.load(.acquire);
            if (g != a.chan_gen_seen) {
                a.chan_gen_seen = g;
                a.onChannelChanged(cl);
            }
            a.applyRewatch(cl);
            a.watchMembers(cl);
            a.notifyChat(cl);
        }
        if (a.auto_watch and st == .connected) {
            var want: [32]u32 = undefined;
            var n_want: usize = 0;
            cl.mutex.lock();
            for (cl.members.items) |*m| {
                if (m.id == cl.my_id) continue;
                for ([_]u8{ proto.kind_screen, proto.kind_camera }) |k| {
                    if (m.live(k) and n_want < want.len) {
                        want[n_want] = proto.streamId(m.id, k);
                        n_want += 1;
                    }
                }
            }
            cl.mutex.unlock();
            for (want[0..n_want]) |id| {
                if (std.mem.findScalar(u32, a.auto_watched[0..a.n_auto_watched], id) != null) continue;
                if (a.n_auto_watched < a.auto_watched.len) {
                    a.auto_watched[a.n_auto_watched] = id;
                    a.n_auto_watched += 1;
                }
                if (a.findView(id) == null) a.watch(id);
            }
        }
        if (st == .failed) {
            cl.mutex.lock();
            const final = cl.final;
            cl.mutex.unlock();
            // queda de rede depois de ter entrado (ou durante uma reconexão): tenta de novo sozinho
            const retry = !final and a.server == null and (a.was_connected or a.reconnect.attempt > 0);
            if (retry and a.reconnect.attempt < max_reconnect) {
                if (!a.reconnect.waiting) a.scheduleReconnect();
                if (c.igGetTime() >= a.reconnect.at) a.doReconnect();
                return;
            }
            if (!a.was_connected) {
                // não conectou: volta pra tela inicial com o erro
                a.setHomeError(if (a.reconnect.attempt > 0) tr("Não consegui reconectar na sala.") else cl.errSlice());
                // identidade mudou desde a última vez: dá pra confiar na nova (botão)
                if (cl.id_state == .mismatch and cl.tofu) {
                    a.trust_fp = cl.server_fp;
                    a.trust_fp_len = crypto.fp_len;
                }
                a.leaveRoom();
                return;
            }
        }
        if (st == .connected) a.handleNotices(cl);
        if (a.camera) |cam| {
            cam.mutex.lock();
            const cst = cam.state;
            cam.mutex.unlock();
            if (cst == .failed) {
                var eb: [300]u8 = undefined;
                a.toast("A câmera parou: {s}", .{i18n.dynamic(cam.errSlice(), &eb)}, true);
                a.stopCamera();
            }
        }
        // transmissão falhou?
        if (a.sharer) |s| {
            s.mutex.lock();
            const sst = s.state;
            const hears_self = s.audio_on and s.audio_hears_self;
            var audio_err: [160]u8 = s.audio_err;
            s.mutex.unlock();
            // captura que escuta o próprio app (Linux sem PipeWire, Windows antigo):
            // silencia o que você assiste, senão quem assiste ouviria eco
            audio.mixer.self_mute.store(hears_self, .monotonic);
            if (hears_self and !a.self_mute_shown) {
                // antes o som da sala simplesmente parava ao começar a transmitir
                a.self_mute_shown = true;
                debuglog.line("a captura do som pega o próprio telinha: o som da sala fica mudo enquanto transmite", .{});
                a.toast("O Windows não deixou separar o som do telinha: enquanto você transmite com som, o que você ouve da sala fica mudo (senão quem assiste ouviria eco).", .{}, true);
            }
            // qualidade automática mudou a resolução: avisa quem transmite
            const cap = s.auto_cap.load(.acquire);
            if (cap != a.auto_cap_seen) {
                const from = s.auto_from.load(.acquire);
                if (cap != 0 and cap > from) {
                    // subindo de volta aos poucos (antes dizia "não estava dando conta")
                    a.toast("Folgou: a transmissão subiu pra {d}p.", .{cap}, false);
                } else if (cap != 0) {
                    a.toast("O PC não estava dando conta de {d}p no fps escolhido: transmitindo em {d}p (volta sozinho quando folgar).", .{ from, cap }, false);
                } else a.toast("Folgou: a transmissão voltou pra resolução escolhida.", .{}, false);
                debuglog.line("qualidade automática: {d}p -> {d}p (0 = a escolhida)", .{ from, cap });
                a.auto_cap_seen = cap;
            }
            if (!a.audio_err_shown and audio_err[0] != 0) {
                a.audio_err_shown = true;
                var eb: [300]u8 = undefined;
                a.toast("Transmitindo sem áudio: {s}", .{i18n.dynamic(std.mem.sliceTo(&audio_err, 0), &eb)}, true);
            }
            if (sst == .failed) {
                var eb: [300]u8 = undefined;
                a.toast("A transmissão parou: {s}", .{i18n.dynamic(s.errSlice(), &eb)}, true);
                a.stopSharing();
            } else if (sst == .stopped) {
                // parou sem a UI pedir (quando a UI para, a.sharer já vira null):
                // retoma sozinho, no máximo 3 vezes por minuto
                debuglog.line("a transmissão parou sozinha (motivo {s}); retomando", .{@tagName(s.stop_reason.load(.acquire))});
                a.stopSharing();
                const now = c.igGetTime();
                if (now - a.share_restart_window > 60) {
                    a.share_restarts = 0;
                    a.share_restart_window = now;
                }
                a.share_restarts += 1;
                if (a.share_restarts <= 3) {
                    a.toast("A transmissão caiu; retomando…", .{}, false);
                    a.startSharing();
                } else a.toast("A transmissão caiu várias vezes seguidas; parei de tentar.", .{}, true);
            }
        }
        // para de assistir quem parou de transmitir
        cl.mutex.lock();
        var i: usize = a.views.items.len;
        var gone: [32]u32 = undefined;
        var n_gone: usize = 0;
        while (i > 0) {
            i -= 1;
            const v = a.views.items[i];
            const live = for (cl.members.items) |*m| {
                if (m.id == v.member()) break m.live(v.kind());
            } else false;
            if (!live and n_gone < gone.len) {
                gone[n_gone] = v.stream;
                n_gone += 1;
            }
        }
        cl.mutex.unlock();
        for (gone[0..n_gone]) |o| a.unwatch(o);
    }

    pub fn frame(a: *App) void {
        a.frame_no += 1;
        // log pela sala: vale a conexão de agora (se conectado)
        debuglog.room_send = roomLogSend;
        setRoomLogClient(if (a.client) |cl| (if (cl.isConnected()) cl else null) else null);
        // escolhendo o recorte mas o quadro sumiu (outra transmissão em destaque, foi pra outra tela): cancela
        if (a.crop_tile != null and a.frame_no > a.crop_seen_frame + 2) a.cancelCrop();
        // algo grande parou (transmissão, câmera, sala, transmissão assistida):
        // a memória livre volta pro sistema
        if (a.trim_at > 0 and c.igGetTime() >= a.trim_at) {
            a.trim_at = 0;
            sync.trimMemory();
        } else if (a.trim_at > 0) redrawIn(a.trim_at - c.igGetTime());
        audio.mixer.housekeep(); // saída de som parada depois de 5 s de silêncio
        if (debuglog.on()) a.debugTick();
        a.pollPttKey();
        a.pollHotkeys();
        // tema/zoom mudados (configurações, arquivo CSS): aplica aqui, antes de
        // qualquer janela empilhar estilo (senão o Pop devolveria o antigo)
        if (a.takeCssFile()) a.theme_dirty = true;
        if (a.theme_dirty) {
            a.theme_dirty = false;
            a.applyTheme();
            a.chat_h.clearRetainingCapacity(); // fonte nova: as alturas das mensagens mudam
        }
        if (a.zoom_dirty) {
            a.zoom_dirty = false;
            setZoom(@as(f32, @floatFromInt(a.cfg.ui_zoom)) / 100);
            a.chat_h.clearRetainingCapacity();
        }
        if (a.save_at != 0 and c.igGetTime() >= a.save_at) {
            a.save_at = 0;
            config.save(&a.cfg);
        }
        if (a.client) |cl| if (c.igGetTime() > a.draw_prune_at) {
            a.draw_prune_at = c.igGetTime() + 2;
            cl.pruneStrokes(sync.nowUs(), stroke_life_us);
        };
        a.checkClipJobs();
        a.checkPrintJob();
        a.checkChatImages();
        a.n_tile_rects = 0;
        a.n_member_rects = 0;
        a.n_live_rects = 0;
        a.strokes_drawn = 0;
        a.checkState();
        a.uploadTextures();

        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F11, false)) a.toggleFullscreen();
        // atalhos de voz (fora de campo de texto): Ctrl+M microfone, Ctrl+D surdo
        const io = c.igGetIO_Nil();
        a.updateIdleControls(io);
        if (a.screen == .room and io.*.KeyCtrl and !io.*.WantTextInput) {
            // se alguém pôs exatamente Ctrl+M (Ctrl+D) como atalho dessa mesma
            // ação, quem cuida é o atalho: os dois juntos ligariam e desligariam
            // no mesmo aperto
            if (c.igIsKeyPressed_Bool(c.ImGuiKey_M, false) and !a.hotkeyIsCtrl(.mic, c.GLFW_KEY_M)) a.toggleMic("Ctrl+M");
            if (c.igIsKeyPressed_Bool(c.ImGuiKey_D, false) and !a.hotkeyIsCtrl(.deaf, c.GLFW_KEY_D)) a.toggleDeaf("Ctrl+D");
        }
        // Esc com uma janela aberta (configurações, recorte) é dela: não sai da tela cheia
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and !a.share_modal and !a.settings_modal and a.crop_tile == null) {
            if (a.fullscreen) a.toggleFullscreen();
            a.theater = false;
        }

        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(vp.*.Pos, 0, v2(0, 0));
        c.igSetNextWindowSize(vp.*.Size, 0);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowBorderSize, 0);
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, if (a.screen == .home) col.bg_dark else col.bg_main);
        const flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoBringToFrontOnFocus | c.ImGuiWindowFlags_NoScrollWithMouse;
        _ = c.igBegin("telinha", null, flags);
        c.igPopStyleColor(1);
        c.igPopStyleVar(2);
        switch (a.screen) {
            .home => a.drawHome(vp.*.Size),
            .room => a.drawRoom(vp.*.Size),
        }
        if (a.crash_prompt and !a.settings_modal and !a.share_modal and !a.leave_confirm) a.drawCrashPrompt();
        a.updateTick();
        const busy = a.settings_modal or a.share_modal or a.leave_confirm or a.crash_prompt;
        if (a.update_modal and !busy) a.drawUpdateModal() else if (a.whatsnew and !busy and !a.update_modal) a.drawWhatsNew();
        a.watchCrashSend();
        a.drawToasts(vp.*.Size);
        a.drawCrt(vp.*.Size);
        c.igEnd();
    }

    // ------------------------------------------------------------------ home

    /// Tem um convite telinha:// copiado? Preenche "Entrar numa sala" sozinho
    /// (sem entrar: a pessoa confere e clica). Olha ao abrir a tela inicial e
    /// quando a janela volta a ficar em foco (copiou o convite em outro app).
    fn pasteInvite(a: *App) void {
        const focused = c.glfwGetWindowAttrib(a.window, c.GLFW_FOCUSED) != 0;
        const gained = focused and !a.was_focused;
        a.was_focused = focused;
        if (a.home_seen and !gained) return;
        a.home_seen = true;
        const raw: [*c]const u8 = c.glfwGetClipboardString(a.window);
        if (raw == null) return;
        const txt = std.mem.trim(u8, std.mem.span(raw), " \t\r\n");
        if (!std.mem.startsWith(u8, txt, "telinha://") or txt.len > a.pasted.len) return;
        if (std.mem.eql(u8, txt, a.pasted[0..a.pasted_len])) return; // esse já foi colado
        @memcpy(a.pasted[0..txt.len], txt);
        a.pasted_len = txt.len;
        a.takeInvite(txt);
        a.home_error_len = 0;
        a.paste_hint_until = c.igGetTime() + 8;
    }

    /// Põe um convite nos campos de entrar (o endereço à vista; senha, canal e
    /// impressão do servidor guardados).
    fn takeInvite(a: *App, txt: []const u8) void {
        const inv = connect_mod.splitInvite(txt);
        config.setStr(&a.cfg.join_addr, inv.addrs);
        config.setStr(&a.cfg.join_pass, inv.password orelse "");
        config.setStr(&a.cfg.join_channel, inv.channel orelse "");
        config.setStr(&a.cfg.join_fp, inv.fingerprint orelse "");
        config.setStr(&a.cfg.join_fp_for, if (inv.fingerprint != null) inv.addrs else "");
        a.home_tab = 0;
    }

    /// Convite colado no campo do nome (a senha ia virar o nome, à vista de
    /// todo mundo): vai pro endereço e o nome fica vazio.
    fn nameIsInvite(a: *App) void {
        if (c.igIsItemActive()) return; // ainda digitando: confere quando sair do campo
        const name = std.mem.trim(u8, std.mem.sliceTo(&a.cfg.name, 0), " \t\r\n");
        if (!std.ascii.startsWithIgnoreCase(name, "telinha://")) return;
        // o campo do nome é curto: se o convite não coube inteiro, não dá pra usar
        // (o campo usa name.len - 1 bytes com o zero: cheio = pode ter cortado;
        // aí vale o da área de transferência, se for o mesmo convite inteiro)
        const len = std.mem.indexOfScalar(u8, &a.cfg.name, 0) orelse a.cfg.name.len;
        var full: []const u8 = if (len < a.cfg.name.len - 2) name else "";
        if (full.len == 0) if (@as(?[*:0]const u8, c.glfwGetClipboardString(a.window))) |cb| {
            const t = std.mem.trim(u8, std.mem.span(cb), " \t\r\n");
            if (std.mem.startsWith(u8, t, name)) full = t;
        };
        if (full.len > 0) a.takeInvite(full);
        config.setStr(&a.cfg.name, "");
        a.toast("Isso é o convite: ele vai no endereço da sala. Escolha um nome.", .{}, true);
    }

    /// Tela inicial: em janela larga, uma vitrine animada (uma "telinha" com
    /// gente assistindo) na esquerda e o cartão de entrar/criar na direita;
    /// em janela estreita, só o cartão. A animação só roda com o telinha em
    /// foco e as animações ligadas (Aparência); sem isso a tela fica parada.
    fn drawHome(a: *App, size: c.ImVec2_c) void {
        a.pasteInvite();
        const d = drawList();
        const now = c.igGetTime();
        // voltou pra tela inicial (abriu o app, saiu da sala): entrada animada
        if (a.home_last_frame + 1 != a.frame_no) a.home_enter_at = now;
        a.home_last_frame = a.frame_no;
        // anima só com alguém mexendo (12 s depois do último movimento ou com
        // um campo em uso), em foco; parada, a tela congela onde estava e o
        // telinha volta a dormir até o próximo evento
        const io = c.igGetIO_Nil();
        const active = now - a.mouse_moved_at < 12 or c.igIsAnyItemActive() or io.*.InputQueueCharacters.Size > 0;
        const animate = a.cfg.animations and !a.away() and active;
        if (animate) a.home_anim_t += @min(io.*.DeltaTime, 0.1);
        const t = a.home_anim_t;
        const enter = if (a.cfg.animations) easeOut(@floatCast(std.math.clamp((now - a.home_enter_at) / 0.55, 0, 1))) else 1;
        // indicador da aba deslizando
        const tab_goal: f32 = @floatFromInt(a.home_tab);
        if (!a.cfg.animations) a.home_tab_anim = tab_goal;
        a.home_tab_anim += (tab_goal - a.home_tab_anim) * @min(1, io.*.DeltaTime * 14);
        if (@abs(tab_goal - a.home_tab_anim) < 0.002) a.home_tab_anim = tab_goal;
        const switching = a.home_tab_anim != tab_goal or (a.cfg.animations and now - a.home_switch_at < 0.3);
        if (animate) redrawIn(1.0 / 30.0) else if (enter < 1 or switching) redrawIn(0.016);

        // fundo: o degradê do tema e três brilhos que passeiam devagar
        c.ImDrawList_AddRectFilledMultiColor(d, v2(0, 0), size, col.home_grad[0], col.home_grad[1], col.home_grad[2], col.home_grad[3]);
        glow(d, v2(size.x * (0.22 + 0.05 * @sin(t * 0.13)), size.y * (0.30 + 0.06 * @cos(t * 0.11))), S(360), col.blurple, 60);
        glow(d, v2(size.x * (0.78 + 0.04 * @cos(t * 0.09)), size.y * (0.78 + 0.05 * @sin(t * 0.12))), S(300), col.green, 30);
        glow(d, v2(size.x * (0.55 + 0.06 * @sin(t * 0.07 + 2)), size.y * (0.05 + 0.04 * @sin(t * 0.1))), S(240), col.red, 22);

        const wide = size.x >= S(1000) and size.y >= S(600);
        const card_w = if (wide) S(420) else @min(S(440), size.x - S(32));
        const card_area = if (wide) @max(S(500), size.x * 0.4) else size.x;
        if (wide) a.drawShowcase(d, v2(0, 0), v2(size.x - card_area, size.y), t, enter);
        const card_h = a.home_card_h + S(56);
        // o cartão rola se a janela for baixa demais pra ele
        c.igSetCursorPos(v2(0, 0));
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, 0);
        c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
        _ = c.igBeginChild_Str("homescroll", size, 0, 0);
        const sy = c.igGetScrollY();
        // em pixel inteiro: a altura medida depende de onde os itens caem
        // (o ImGui arredonda), e ela decide a posição do próximo quadro; com
        // fração, os dois ficavam se corrigindo e o cartão tremia
        const x0 = @round((size.x - card_area) + @max(S(16), (card_area - card_w) / 2) - (if (wide) S(24) else 0));
        const y0 = @round(@max(S(16), (size.y - card_h) / 2) + (1 - enter) * S(22) - sy);
        a.drawHomeCard(drawList(), x0, y0, card_w, card_h, !wide, enter);
        c.igSetCursorScreenPos(v2(x0, y0 + card_h));
        c.igDummy(v2(card_w, S(28)));
        c.igEndChild();
        c.igPopStyleColor(2);
        // configurações também antes de entrar numa sala (atualização, histórico, idioma...)
        const gs = S(34);
        c.igSetCursorScreenPos(v2(size.x - gs - S(14), S(12)));
        if (iconButton("##homegear", ic.gear, gs, col.muted, col.hover, tr("Configurações"))) a.openSettings();
        if (a.settings_modal) a.drawSettingsModal();
    }

    /// A vitrine da esquerda: marca, uma tela "ao vivo" com código rolando,
    /// seta passeando, gente assistindo, reações subindo e uma mensagem.
    fn drawShowcase(a: *App, d: *c.ImDrawList, o: c.ImVec2_c, size: c.ImVec2_c, t: f32, enter: f32) void {
        _ = a;
        c.ImDrawList_PushClipRect(d, o, v2(o.x + size.x, o.y + size.y), true);
        defer c.ImDrawList_PopClipRect(d);
        const ak = enter;
        const mw = @min(S(540), size.x - S(140));
        const mh = mw * 0.6;
        const brand_h = S(96);
        const chips_h = S(34);
        const total = brand_h + S(34) + mh + S(46) + chips_h;
        const cx = o.x + size.x / 2;
        var y = o.y + @max(S(24), (size.y - total) / 2);

        // marca
        {
            const lz = S(64);
            const bob = @sin(t * 1.6) * S(3);
            const tw = textSizeF(font_bold, 38, "telinha").x;
            const bx = cx - (lz + S(16) + tw) / 2;
            if (logo_tex == 0) gl.upload(&logo_tex, logo_rgba, 128, 128, gl.RGBA);
            c.ImDrawList_AddImageRounded(d, texRef(logo_tex), v2(bx, y + bob), v2(bx + lz, y + lz + bob), v2(0, 0), v2(1, 1), fa(col.white, ak), S(16), 0);
            drawTextF(d, font_bold, 38, v2(bx + lz + S(16), y + S(2)), fa(col.header, ak), "telinha");
            const tag = tr("compartilha a tela com a galera");
            drawTextF(d, font_regular, 15, v2(bx + lz + S(18), y + S(46)), fa(col.muted, ak), tag);
            y += brand_h + S(34);
        }

        // a telinha
        const mx = cx - mw / 2;
        const rise = (1 - enter) * S(30);
        const my = y + rise;
        rectFill(d, mx + S(4), my + S(10), mx + mw + S(4), my + mh + S(10), fa(rgba(0x000000, 90), ak), S(16));
        rectFill(d, mx, my, mx + mw, my + mh, fa(col.bg_main, ak), S(16));
        c.ImDrawList_AddRect(d, v2(mx, my), v2(mx + mw, my + mh), fa(withAlpha(col.text, 26), ak), S(16) * col.round, S(1), 0);
        // barra de título
        const bar = S(30);
        for ([_]u32{ rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840) }, 0..) |dc, i| {
            c.ImDrawList_AddCircleFilled(d, v2(mx + S(18) + @as(f32, @floatFromInt(i)) * S(16), my + bar / 2), S(4.5), fa(dc, ak), 0);
        }
        drawTextF(d, font_semibold, 12, v2(mx + S(76), my + S(8)), fa(col.muted, ak), demo_title);
        rectFill(d, mx, my + bar, mx + mw, my + bar + S(1), fa(withAlpha(col.text, 18), ak), 0);
        // conteúdo: barra de arquivos e código rolando
        const ix0 = mx + S(1);
        const iy0 = my + bar + S(1);
        const ix1 = mx + mw - S(1);
        const iy1 = my + mh - S(8);
        c.ImDrawList_PushClipRect(d, v2(ix0, iy0), v2(ix1, iy1), true);
        const side = mw * 0.2;
        rectFill(d, ix0, iy0, ix0 + side, iy1 + S(8), fa(withAlpha(col.text, 8), ak), 0);
        for (0..7) |i| {
            const fi: f32 = @floatFromInt(i);
            const w = side * (0.35 + 0.4 * hash01(@intCast(i * 7 + 3)));
            const ry = iy0 + S(16) + fi * S(20);
            if (i == 3) rectFill(d, ix0, ry - S(6), ix0 + side, ry + S(12), fa(withAlpha(col.blurple, 50), ak), 0);
            rectFill(d, ix0 + S(14) + (if (i % 3 == 0) 0 else S(10)), ry, ix0 + S(14) + w, ry + S(6), fa(withAlpha(col.text, 60), ak), S(3));
        }
        const lh = S(19);
        const scroll = @mod(t * S(9), lh * 32);
        const code_x = ix0 + side + S(18);
        const palette = [_]u32{ col.blurple, col.green, col.yellow, col.red, col.text };
        var li: usize = 0;
        while (li < 40) : (li += 1) {
            const ly = iy0 + S(14) + @as(f32, @floatFromInt(li)) * lh - scroll;
            if (ly > iy1) break;
            if (ly < iy0 - lh) continue;
            const k: u32 = @intCast(li % 32);
            if (hash01(k * 13 + 1) < 0.12) continue; // linha em branco
            const indent = @as(f32, @floatFromInt(@as(u32, @intFromFloat(hash01(k * 5 + 2) * 3)))) * S(22);
            var sx = code_x + indent;
            const parts: u32 = 1 + @as(u32, @intFromFloat(hash01(k * 3 + 7) * 3));
            for (0..parts) |pi| {
                const seg_w = S(24) + hash01(k * 17 + @as(u32, @intCast(pi)) * 31) * S(90);
                if (sx + seg_w > ix1 - S(16)) break;
                const pc = palette[@as(usize, @intFromFloat(hash01(k * 11 + @as(u32, @intCast(pi)) * 7) * 4.99))];
                rectFill(d, sx, ly, sx + seg_w, ly + S(7), fa(withAlpha(pc, 150), ak), S(3.5));
                sx += seg_w + S(8);
            }
        }
        // a seta de quem transmite passeando
        {
            const px = ix0 + side + (ix1 - ix0 - side) * (0.5 + 0.32 * @sin(t * 0.55));
            const py = iy0 + (iy1 - iy0) * (0.5 + 0.3 * @sin(t * 0.83 + 1));
            const pts = [_]c.ImVec2_c{ v2(px, py), v2(px, py + S(17)), v2(px + S(4.5), py + S(13)), v2(px + S(8), py + S(20)), v2(px + S(10.5), py + S(19)), v2(px + S(7), py + S(12)), v2(px + S(12), py + S(12)) };
            c.ImDrawList_AddConcavePolyFilled(d, &pts, pts.len, fa(col.white, ak));
            c.ImDrawList_AddPolyline(d, &pts, pts.len, fa(rgba(0x000000, 200), ak), S(1.2), c.ImDrawFlags_Closed);
        }
        c.ImDrawList_PopClipRect(d);
        // AO VIVO piscando
        const pulse = 0.5 + 0.5 * @sin(t * 3.2);
        const lb = v2(mx + S(14), my + mh - S(30));
        c.ImDrawList_AddCircleFilled(d, v2(lb.x + S(4), lb.y + S(8)), S(6) + S(4) * pulse, fa(withAlpha(col.red, @intFromFloat(70 * (1 - pulse))), ak), 0);
        _ = liveBadge(d, v2(lb.x + S(14), lb.y));

        // quem assiste, embaixo da tela (um falando)
        const names = [_][]const u8{ "Ana", "Bruno", "Carol", "Davi" };
        const r = S(17);
        const ay = my + mh + S(2);
        const ax0 = mx + mw - S(30) - @as(f32, @floatFromInt(names.len - 1)) * S(30);
        for (names, 0..) |nm, i| {
            const fi: f32 = @floatFromInt(i);
            const p = v2(ax0 + fi * S(30), ay + @sin(t * 2 + fi * 1.3) * S(2.5));
            c.ImDrawList_AddCircleFilled(d, p, r + S(3), fa(col.bg_dark, ak), 0);
            if (i == 1) {
                const ring = @mod(t * 0.9, 1);
                c.ImDrawList_AddCircle(d, p, r + S(3) + ring * S(9), fa(withAlpha(col.green, @intFromFloat(200 * (1 - ring))), ak), 0, S(2), 0);
            }
            drawAvatarSpeaking(d, p, r, @intCast(i + 1), nm, false, i == 1);
        }
        // reações subindo
        for (0..5) |k| {
            const fk: f32 = @floatFromInt(k);
            const ph = @mod(t * 0.32 + fk * 0.2, 1);
            const alpha = @sin(ph * std.math.pi);
            const rx = mx + mw - S(58) + @sin(ph * 7 + fk * 2) * S(12) + fk * S(6);
            const ry = my + mh - S(20) - ph * S(170);
            const e = (k * 2 + 1) % proto.reactions;
            drawTextF(d, font_regular, 18 + 4 * alpha, v2(rx, ry), fa(withAlpha(reaction_colors[e], @intFromFloat(230 * alpha)), ak), reaction_icons[e]);
        }
        // uma mensagem do chat que aparece e some (troca a cada 4 s)
        {
            const msgs = [_][]const u8{ tr("olha esse refactor"), tr("boa, manda ver!"), tr("da um zoom na linha 84?") };
            const cyc = @mod(t / 4.0, @as(f32, msgs.len));
            const idx: usize = @intFromFloat(@floor(cyc));
            const ph = cyc - @floor(cyc);
            const vis = if (t == 0) 1 else std.math.clamp(@min(ph / 0.12, (1 - ph) / 0.12), 0, 1);
            const msg = msgs[@min(idx, msgs.len - 1)];
            const who = names[(idx + 2) % names.len];
            const ts = textSizeF(font_regular, 13, msg);
            const bw = ts.x + S(52);
            const bh = S(40);
            const bx = @max(o.x + S(12), mx - S(34));
            const by = my + mh * 0.18 - (1 - vis) * S(8);
            const k = ak * vis;
            rectFill(d, bx + S(2), by + S(4), bx + bw + S(2), by + bh + S(4), fa(rgba(0x000000, 70), k), S(12));
            rectFill(d, bx, by, bx + bw, by + bh, fa(col.bg_side, k), S(12));
            c.ImDrawList_AddRect(d, v2(bx, by), v2(bx + bw, by + bh), fa(withAlpha(col.text, 24), k), S(12) * col.round, S(1), 0);
            c.ImDrawList_AddCircleFilled(d, v2(bx + S(20), by + bh / 2), S(11), fa(avatarColor(@intCast((idx + 2) % names.len + 1)), k), 0);
            var ib: [5]u8 = undefined;
            const ini = initial(who, &ib);
            const is = textSizeF(font_semibold, 11, ini);
            drawTextF(d, font_semibold, 11, v2(bx + S(20) - is.x / 2, by + bh / 2 - is.y / 2), fa(col.white, k), ini);
            drawTextF(d, font_regular, 13, v2(bx + S(38), by + (bh - ts.y) / 2), fa(col.text, k), msg);
        }

        // o que tem de bom
        {
            const chips = [_][2][]const u8{
                .{ ic.gauge, tr("Direto pela placa de vídeo") },
                .{ ic.lock, tr("Conexão criptografada") },
                .{ ic.user_plus, tr("Sem conta: é só o convite") },
            };
            var widths: [chips.len]f32 = undefined;
            var tw: f32 = 0;
            for (chips, 0..) |ch, i| {
                widths[i] = textSizeF(font_semibold, 12.5, ch[1]).x + S(44);
                tw += widths[i] + (if (i > 0) S(10) else 0);
            }
            var chx = cx - tw / 2;
            const chy = my + mh + S(46);
            if (tw < size.x - S(24)) for (chips, 0..) |ch, i| {
                const k = ak * easeOut(std.math.clamp(enter * 1.6 - 0.25 * @as(f32, @floatFromInt(i)), 0, 1));
                rectFill(d, chx, chy, chx + widths[i], chy + chips_h, fa(withAlpha(col.text, 10), k), chips_h / 2);
                c.ImDrawList_AddRect(d, v2(chx, chy), v2(chx + widths[i], chy + chips_h), fa(withAlpha(col.text, 22), k), chips_h / 2 * col.round, S(1), 0);
                drawTextF(d, font_regular, 13, v2(chx + S(14), chy + (chips_h - S(16)) / 2), fa(col.blurple, k), ch[0]);
                drawTextF(d, font_semibold, 12.5, v2(chx + S(34), chy + (chips_h - S(16)) / 2), fa(col.text, k), ch[1]);
                chx += widths[i] + S(10);
            };
        }
    }

    /// O cartão de entrar/criar. `brand`: com a marca em cima (janela estreita,
    /// sem a vitrine).
    fn drawHomeCard(a: *App, d: *c.ImDrawList, x0: f32, y0: f32, card_w: f32, card_h: f32, brand: bool, enter: f32) void {
        const ak = enter;
        rectFill(d, x0 + S(3), y0 + S(10), x0 + card_w + S(3), y0 + card_h + S(10), fa(rgba(0x000000, 80), ak), S(20));
        rectFill(d, x0, y0, x0 + card_w, y0 + card_h, fa(col.bg_main, ak), S(18));
        c.ImDrawList_AddRect(d, v2(x0, y0), v2(x0 + card_w, y0 + card_h), fa(withAlpha(col.text, 20), ak), S(18) * col.round, S(1), 0);
        // filete de cor no topo, na cor da aba (violeta entrar, verde criar)
        const accent = mixCol(col.blurple, col.green, a.home_tab_anim);
        rectFill(d, x0 + S(28), y0, x0 + card_w - S(28), y0 + S(2), fa(accent, ak), S(1));

        c.igPushStyleVar_Float(c.ImGuiStyleVar_Alpha, @max(0.01, ak));
        defer c.igPopStyleVar(1);
        const pad = S(30);
        const inner = card_w - pad * 2;
        c.igSetCursorScreenPos(v2(x0 + pad, y0 + S(28)));
        c.igBeginGroup();

        if (brand) {
            const p = c.igGetCursorScreenPos();
            const isz = S(44);
            if (logo_tex == 0) gl.upload(&logo_tex, logo_rgba, 128, 128, gl.RGBA);
            c.ImDrawList_AddImageRounded(d, texRef(logo_tex), p, v2(p.x + isz, p.y + isz), v2(0, 0), v2(1, 1), fa(col.white, ak), S(12), 0);
            drawTextF(d, font_bold, 26, v2(p.x + isz + S(14), p.y - S(1)), fa(col.header, ak), "telinha");
            drawTextF(d, font_regular, 13.5, v2(p.x + isz + S(15), p.y + S(27)), fa(col.muted, ak), tr("compartilha a tela com a galera"));
            c.igDummy(v2(inner, isz + S(22)));
        }
        a.drawUpdateBanner(inner);

        // saudação
        {
            const p = c.igGetCursorScreenPos();
            const nm = std.mem.sliceTo(&a.cfg.name, 0);
            const hello = if (nm.len > 0) fmtZ("Oi, {s}!", .{nm[0..@min(nm.len, 24)]}) else fmtZ("Bem-vindo ao telinha", .{});
            drawTextF(d, font_bold, 22, p, fa(col.header, ak), hello);
            const sub = if (a.home_tab == 0) tr("Cola o convite que te mandaram e entra.") else tr("Abre uma sala aqui e chama a galera.");
            drawTextF(d, font_regular, 13.5, v2(p.x, p.y + S(32)), fa(col.muted, ak), sub);
            c.igDummy(v2(inner, S(60)));
        }

        // escolha: entrar ou criar (o destaque desliza)
        {
            const p = c.igGetCursorScreenPos();
            const h = S(46);
            const half = (inner - S(8)) / 2;
            rectFill(d, p.x, p.y, p.x + inner, p.y + h, fa(col.input, ak), S(12));
            const hx = p.x + S(4) + a.home_tab_anim * (half + S(0));
            rectFill(d, hx, p.y + S(4), hx + half, p.y + h - S(4), fa(accent, ak), S(9));
            const opts = [_][2][]const u8{ .{ ic.arrow_right, tr("Entrar numa sala") }, .{ ic.plus, tr("Criar sala") } };
            for (opts, 0..) |op, i| {
                const fi: f32 = @floatFromInt(i);
                const bx = p.x + S(4) + fi * half;
                c.igSetCursorScreenPos(v2(bx, p.y + S(4)));
                var lb: [96]u8 = undefined;
                const id = std.fmt.bufPrintZ(&lb, "{s}###seg{d}", .{ op[1], i }) catch "###seg";
                if (c.igInvisibleButton(id.ptr, v2(half, h - S(8)), 0) and a.home_tab != @as(i32, @intCast(i))) {
                    a.home_tab = @intCast(i);
                    a.home_error_len = 0;
                    a.home_switch_at = c.igGetTime();
                }
                const sel_k = 1 - @abs(a.home_tab_anim - fi); // 1 = em cima do destaque
                const hovered = c.igIsItemHovered(0);
                const tc = mixCol(if (hovered) col.header else col.muted, theme.textOn(accent), sel_k);
                const iw = textSizeF(font_regular, 13, op[0]).x;
                const tw = textSizeF(font_semibold, 14, op[1]).x;
                const tx = bx + (half - iw - S(9) - tw) / 2;
                const ty = p.y + (h - S(18)) / 2;
                drawTextF(d, font_regular, 13, v2(tx, ty + S(1)), fa(tc, ak), op[0]);
                drawTextF(d, font_semibold, 14, v2(tx + iw + S(9), ty), fa(tc, ak), op[1]);
            }
            c.igSetCursorScreenPos(v2(p.x, p.y + h));
            c.igDummy(v2(inner, S(18)));
        }

        // o conteúdo da aba entra deslizando de lado
        const since: f32 = @floatCast(c.igGetTime() - a.home_switch_at);
        const sw = if (a.cfg.animations) easeOut(std.math.clamp(since / 0.3, 0, 1)) else 1;
        const dir: f32 = if (a.home_tab == 1) 1 else -1;
        c.igPushStyleVar_Float(c.ImGuiStyleVar_Alpha, @max(0.01, ak * sw));
        defer c.igPopStyleVar(1);
        const base_x = c.igGetCursorScreenPos().x;
        c.igSetCursorScreenPos(v2(base_x + (1 - sw) * S(18) * dir, c.igGetCursorScreenPos().y));
        c.igBeginGroup();
        const ck = ak * sw;

        fieldLabel("SEU NOME");
        _ = iconField(d, "##name", ic.users, "como a galera vai te ver", a.cfg.name[0 .. a.cfg.name.len - 1], inner, false, accent, ck);
        a.nameIsInvite();
        c.igDummy(v2(0, S(8)));

        var go = false;
        if (a.home_tab == 0) {
            fieldLabel("ENDEREÇO DA SALA");
            if (iconField(d, "##addr", ic.link, "ex.: 0.tcp.sa.ngrok.io:12345 ou o convite telinha://...", &a.cfg.join_addr, inner, false, accent, ck)) go = true;
            if (c.igGetTime() < a.paste_hint_until) {
                pushFont(font_regular, 12.5);
                textColored(col.green, tr("Convite colado da área de transferência. É só clicar em Entrar."));
                popFont();
            }
            c.igDummy(v2(0, S(8)));
            // senha e canal lado a lado (o canal é opcional: vazio = o padrão do servidor)
            const half = (inner - S(12)) / 2;
            const row = c.igGetCursorScreenPos();
            fieldLabel("SENHA");
            if (iconField(d, "##pass", ic.lock, "senha da sala", &a.cfg.join_pass, half, true, accent, ck)) go = true;
            const after = c.igGetCursorScreenPos();
            c.igSetCursorScreenPos(v2(row.x + half + S(12), row.y));
            fieldLabel("CANAL");
            c.igSetCursorScreenPos(v2(row.x + half + S(12), c.igGetCursorScreenPos().y));
            if (iconField(d, "##chan", ic.comments, "opcional", &a.cfg.join_channel, half, false, accent, ck)) go = true;
            if (c.igIsItemHovered(0)) tooltipText(tr("Num servidor com canais (como no IRC), entra direto nesse; vazio = o padrão. Dá pra trocar depois no painel ou com /join no chat."));
            c.igSetCursorScreenPos(after);
            c.igDummy(v2(0, S(6)));
            // opções avançadas (token de admin de servidor dedicado)
            {
                const tx = fmtZ("Opções avançadas  {s}", .{if (a.show_advanced) ic.chev_up else ic.chev_down});
                pushFont(font_semibold, 12.5);
                const ts = textSize(tx);
                const p = c.igGetCursorScreenPos();
                if (c.igInvisibleButton("##adv", v2(ts.x, ts.y + S(4)), 0)) a.show_advanced = !a.show_advanced;
                drawText(d, p, fa(if (c.igIsItemHovered(0)) col.header else col.muted, ck), tx);
                popFont();
            }
            if (a.show_advanced) {
                c.igDummy(v2(0, S(4)));
                fieldLabel("TOKEN DE ADMIN (só em servidor dedicado)");
                if (iconField(d, "##tok", ic.shield, "deixe vazio se não souber o que é", &a.cfg.admin_token, inner, true, accent, ck)) go = true;
            }
            c.igDummy(v2(0, S(16)));
            if (goButton(d, tr("Entrar##go"), inner, col.blurple, col.blurple_hover, col.blurple_active, ck)) go = true;
            if (go) a.joinRoom();
        } else {
            fieldLabel("NOME DA SALA");
            _ = iconField(d, "##room", ic.tv, "ex.: Sala do Gabriel", &a.cfg.room_name, inner, false, accent, ck);
            c.igDummy(v2(0, S(8)));
            const half = (inner - S(12)) / 2;
            const row = c.igGetCursorScreenPos();
            fieldLabel("PORTA");
            _ = iconField(d, "##port", ic.tower, "7777", &a.port_buf, half, false, accent, ck);
            const after = c.igGetCursorScreenPos();
            c.igSetCursorScreenPos(v2(row.x + half + S(12), row.y));
            fieldLabel("SENHA");
            c.igSetCursorScreenPos(v2(row.x + half + S(12), c.igGetCursorScreenPos().y));
            if (iconField(d, "##hpass", ic.lock, "vazio = sem senha", &a.cfg.host_pass, half, true, accent, ck)) go = true;
            c.igSetCursorScreenPos(after);
            c.igDummy(v2(0, S(18)));
            if (goButton(d, tr("Criar sala##go"), inner, col.green, col.green_hover, col.green_active, ck)) go = true;
            c.igDummy(v2(0, S(12)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + inner);
            pushFont(font_regular, 12.5);
            textColored(col.muted, tr("Pra galera de fora entrar: na sala tem o botão de criar um link público (funciona em qualquer rede) ou de abrir a porta no roteador."));
            popFont();
            c.igPopTextWrapPos();
            if (go) a.createRoom();
        }

        if (a.home_error_len > 0) {
            c.igDummy(v2(0, S(12)));
            const p = c.igGetCursorScreenPos();
            pushFont(font_regular, 13.5);
            const ts = c.igCalcTextSize(a.home_error[0..].ptr, a.home_error[0..].ptr + a.home_error_len, false, inner - S(40));
            popFont();
            const eh = ts.y + S(20);
            rectFill(d, p.x, p.y, p.x + inner, p.y + eh, fa(withAlpha(col.red, 30), ck), S(10));
            c.ImDrawList_AddRect(d, v2(p.x, p.y), v2(p.x + inner, p.y + eh), fa(withAlpha(col.red, 90), ck), S(10) * col.round, S(1), 0);
            drawTextF(d, font_regular, 14, v2(p.x + S(12), p.y + S(10)), fa(col.red, ck), ic.warn);
            c.igSetCursorScreenPos(v2(p.x + S(34), p.y + S(10)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + inner - S(44));
            pushFont(font_regular, 13.5);
            textColored(col.text, a.home_error[0..a.home_error_len]);
            popFont();
            c.igPopTextWrapPos();
            c.igSetCursorScreenPos(v2(p.x, p.y + eh));
            c.igDummy(v2(inner, 0));
            if (a.trust_fp_len > 0 and a.home_tab == 0) {
                c.igDummy(v2(0, S(6)));
                if (secondaryButton(fmtZ("{s}  Confiar na identidade nova ({s})###trustid", .{ ic.shield, a.trust_fp[0..a.trust_fp_len] }), v2(inner, S(38)))) {
                    known.remember(a.conn_addrs[0..a.conn_addrs_len], a.trust_fp[0..a.trust_fp_len]);
                    a.trust_fp_len = 0;
                    a.joinRoom();
                }
            }
        }
        c.igEndGroup();

        // rodapé
        c.igDummy(v2(0, S(16)));
        {
            const p = c.igGetCursorScreenPos();
            const ft = fmtZ("telinha {s}  ·  {s} X25519 + ChaCha20", .{ version_string, ic.lock });
            const fw = textSizeF(font_regular, 11.5, ft).x;
            drawTextF(d, font_regular, 11.5, v2(p.x + (inner - fw) / 2, p.y), fa(col.faint, ak), ft);
            c.igDummy(v2(inner, S(14)));
        }
        c.igEndGroup();
        a.home_card_h = c.igGetItemRectSize().y;
    }

    // ------------------------------------------------------------------ sala

    fn drawRoom(a: *App, size: c.ImVec2_c) void {
        const cl = a.client orelse return;
        // "Sair" no meio do quadro solta a referência da interface; o resto do
        // quadro ainda desenha com `cl`
        _ = cl.retain();
        defer cl.release();
        cl.mutex.lock();
        const status = cl.status;
        cl.mutex.unlock();

        // barra do topo (sala, quem está ao vivo, ações), o palco com as
        // transmissões e a cápsula de controles, e o painel da direita (quem
        // está na sala + chat). Cinema/tela cheia: só o palco.
        const header_h = if (a.theater) 0 else S(58);
        const want_panel = !a.theater and a.cfg.show_chat;
        // janela estreita: o painel some (o botão do topo traz de volta)
        const panel_w = if (want_panel and size.x - S(350) >= S(560)) S(350) else 0;
        a.chat_visible = panel_w > 0;
        a.side_visible = panel_w > 0;
        const main_w = size.x - panel_w;
        if (header_h > 0) {
            c.igSetCursorPos(v2(0, 0));
            a.drawHeader(cl, v2(size.x, header_h));
        }
        c.igSetCursorPos(v2(0, header_h));
        a.drawMain(cl, v2(main_w, size.y - header_h));
        if (panel_w > 0) {
            c.igSetCursorPos(v2(main_w, header_h));
            a.drawPanel(cl, v2(panel_w, size.y - header_h));
        }

        const overlay = status == .connecting or (status == .failed and (a.was_connected or a.reconnect.attempt > 0));
        if (status == .connecting) a.drawConnecting(size);
        if (status == .failed and (a.was_connected or a.reconnect.attempt > 0)) a.drawDropped(cl, size);
        if (overlay) {
            // a camada por cima pega o foco a cada quadro, o que fecharia a
            // janela (e ela reabriria invisível, travando os cliques)
            a.closeModals();
        } else {
            if (a.share_modal) a.drawShareModal();
            if (a.settings_modal) a.drawSettingsModal();
            if (a.leave_confirm) a.drawLeaveConfirm();
            if (a.stats_open) a.drawStatsModal(cl, size);
            if (a.img_view != null) a.drawImageViewer(size);
        }
    }

    // ------------------------------------------------- estatísticas do servidor

    fn setStatsOpen(a: *App, cl: *Client, on: bool) void {
        a.stats_open = on;
        cl.wantStats(on);
        if (on) {
            a.stats_hist_n = 0;
            a.stats_seen = 0;
        }
    }

    /// Guarda no histórico (gráfico) cada estatística nova que chega.
    fn takeStats(a: *App, cl: *Client) ?client_mod.ServerStats {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        if (cl.stats_gen == 0) return null;
        const st = cl.stats;
        if (cl.stats_gen != a.stats_seen) {
            a.stats_seen = cl.stats_gen;
            if (st.window_ms > 0) {
                if (a.stats_hist_n == a.stats_hist.len) {
                    std.mem.copyForwards(u16, a.stats_hist[0 .. a.stats_hist.len - 1], a.stats_hist[1..]);
                    std.mem.copyForwards(u32, a.stats_out_hist[0 .. a.stats_out_hist.len - 1], a.stats_out_hist[1..]);
                    a.stats_hist_n -= 1;
                }
                a.stats_hist[a.stats_hist_n] = @intCast(@min(65535, st.cpu_permille));
                a.stats_out_hist[a.stats_hist_n] = st.out_bps;
                a.stats_hist_n += 1;
            }
        }
        return st;
    }

    fn mbit(bps: u32) f32 {
        return @as(f32, @floatFromInt(bps)) * 8 / 1_000_000;
    }

    /// Um número grande com rótulo, explicação e (se tiver) o gráfico.
    fn statTile(d: *c.ImDrawList, x: f32, y: f32, w: f32, h: f32, label: []const u8, value: []const u8, sub: []const u8, tint: u32, hist: ?[]const f32) void {
        rectFill(d, x, y, x + w, y + h, col.bg_side, S(12));
        c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), withAlpha(col.text, 16), S(12) * col.round, S(1), 0);
        if (hist) |hs| if (hs.len > 1) {
            // gráfico ocupando o pé do cartão
            var mx: f32 = 0.0001;
            for (hs) |v| mx = @max(mx, v);
            const gx0 = x + S(10);
            const gx1 = x + w - S(10);
            // faixa embaixo do texto (o texto ocupa até ~y + 74)
            const gy1 = y + h - S(8);
            const gh = @max(S(8), h - S(84));
            var pts: [61]c.ImVec2_c = undefined;
            const n = @min(hs.len, 60);
            for (hs[hs.len - n ..], 0..) |v, i| {
                const fx = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(1, n - 1)));
                pts[i] = v2(gx0 + (gx1 - gx0) * fx, gy1 - gh * (v / mx));
            }
            // área embaixo da linha
            for (0..n - 1) |i| {
                c.ImDrawList_AddQuadFilled(d, pts[i], pts[i + 1], v2(pts[i + 1].x, gy1), v2(pts[i].x, gy1), withAlpha(tint, 28));
            }
            c.ImDrawList_AddPolyline(d, &pts, @intCast(n), withAlpha(tint, 220), S(1.6), 0);
        };
        drawTextF(d, font_bold, 10.5, v2(x + S(14), y + S(12)), col.muted, label);
        drawTextF(d, font_bold, 24, v2(x + S(14), y + S(28)), col.header, value);
        drawTextF(d, font_regular, 11.5, v2(x + S(14), y + S(60)), col.faint, sub);
    }

    fn drawStatsModal(a: *App, cl: *Client, size: c.ImVec2_c) void {
        _ = c.igOpenPopup_Str(tr("Servidor###srvstatsw"), 0);
        const vp = c.igGetMainViewport();
        const w = @min(S(900), size.x - S(32));
        const h = @min(S(680), size.y - S(32));
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(w, h), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(22), S(20)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(14) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 150));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("Servidor###srvstatsw"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove)) return;
        defer c.igEndPopup();
        const d = drawList();
        const inner = w - S(44);
        const o = c.igGetCursorScreenPos();
        // título
        drawTextF(d, font_regular, 18, v2(o.x, o.y + S(2)), col.blurple, ic.gauge);
        drawTextF(d, font_bold, 19, v2(o.x + S(30), o.y), col.header, tr("Servidor"));
        c.igSetCursorScreenPos(v2(o.x + inner - S(32), o.y - S(4)));
        if (iconButton("##statsclose", ic.xmark, S(32), col.muted, col.hover, tr("Fechar")) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            a.setStatsOpen(cl, false);
            c.igCloseCurrentPopup();
            return;
        }
        const st = a.takeStats(cl) orelse {
            c.igSetCursorScreenPos(v2(o.x, o.y + S(40)));
            textColored(col.muted, tr("Pedindo as estatísticas pro servidor…"));
            redrawIn(0.25);
            return;
        };
        const up = st.uptime_s;
        const upt = if (up >= 86400)
            fmtZ("no ar há {d} d {d} h", .{ up / 86400, up / 3600 % 24 })
        else if (up >= 3600)
            fmtZ("no ar há {d} h {d} min", .{ up / 3600, up / 60 % 60 })
        else
            fmtZ("no ar há {d} min", .{up / 60});
        var ub: [64]u8 = undefined;
        const upt_s = std.fmt.bufPrint(&ub, "{s}", .{upt}) catch "";
        drawTextF(d, font_regular, 12.5, v2(o.x + S(30), o.y + S(26)), col.muted, fmtZ("{s} · atualiza a cada 2 s", .{upt_s}));
        var y = o.y + S(56);

        // os quatro números
        const gap = S(12);
        const cols: usize = if (inner >= S(640)) 4 else 2;
        const tw = (inner - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        const th = S(118);
        const cores: f32 = @floatFromInt(@max(1, st.cores));
        const cpu_core = @as(f32, @floatFromInt(st.cpu_permille)) / 1000; // em núcleos
        const cpu_pct = cpu_core / cores * 100;
        var cpu_h: [60]f32 = undefined;
        var out_h: [60]f32 = undefined;
        for (0..a.stats_hist_n) |i| {
            cpu_h[i] = @floatFromInt(a.stats_hist[i]);
            out_h[i] = @floatFromInt(a.stats_out_hist[i]);
        }
        var vb: [4][32]u8 = undefined;
        var sb: [4][64]u8 = undefined;
        const tiles = [_]struct { []const u8, []const u8, []const u8, u32, ?[]const f32 }{
            .{ tr("CPU"), (if (cpu_pct < 10) std.fmt.bufPrint(&vb[0], "{d:.1}%", .{cpu_pct}) else std.fmt.bufPrint(&vb[0], "{d:.0}%", .{cpu_pct})) catch "", i18n.bufPrint(&sb[0], "{d:.2} de {d} núcleos", .{ cpu_core, st.cores }) catch "", if (cpu_pct >= 85) col.red else if (cpu_pct >= 60) col.yellow else col.green, cpu_h[0..a.stats_hist_n] },
            .{ tr("MEMÓRIA"), std.fmt.bufPrint(&vb[1], "{d} MB", .{st.rss_kb / 1024}) catch "", tr("usada pelo processo"), col.blurple, null },
            .{ tr("SAINDO"), std.fmt.bufPrint(&vb[2], "{d:.1} Mbit/s", .{mbit(st.out_bps)}) catch "", tr("pra quem assiste e ouve"), col.blurple, out_h[0..a.stats_hist_n] },
            .{ tr("CHEGANDO"), std.fmt.bufPrint(&vb[3], "{d:.1} Mbit/s", .{mbit(st.in_bps)}) catch "", tr("de quem transmite e fala"), col.green, null },
        };
        for (tiles, 0..) |t, i| {
            const cx = o.x + @as(f32, @floatFromInt(i % cols)) * (tw + gap);
            const cy = y + @as(f32, @floatFromInt(i / cols)) * (th + gap);
            statTile(d, cx, cy, tw, th, t[0], t[1], t[2], t[3], t[4]);
        }
        y += @as(f32, @floatFromInt((tiles.len + cols - 1) / cols)) * (th + gap) + S(4);

        // pílulas: gente, UDP, canais, sala
        {
            var px = o.x;
            var pb: [5][64]u8 = undefined;
            const pills = [_][]const u8{
                i18n.bufPrint(&pb[0], "{s}  {d} de {d} pessoas", .{ ic.users, st.conns, st.max_members }) catch "",
                i18n.bufPrint(&pb[1], "{s}  {d} por UDP", .{ ic.signal, st.udp_conns }) catch "",
                i18n.bufPrint(&pb[2], "#  {d} canais", .{st.channels}) catch "",
                if (st.flags & 2 != 0) (i18n.bufPrint(&pb[3], "{s}  trancada", .{ic.lock}) catch "") else "",
                if (st.hosted()) (i18n.bufPrint(&pb[4], "{s}  dentro do seu telinha", .{ic.laptop}) catch "") else "",
            };
            for (pills) |pt| {
                if (pt.len == 0) continue;
                const pw = textSizeF(font_semibold, 12, pt).x + S(22);
                if (px + pw > o.x + inner) break;
                rectFill(d, px, y, px + pw, y + S(26), withAlpha(col.text, 10), S(13));
                drawTextF(d, font_semibold, 12, v2(px + S(11), y + S(5)), col.text, pt);
                px += pw + S(8);
            }
            y += S(38);
        }

        // gargalos
        drawTextF(d, font_bold, 11, v2(o.x, y), col.muted, tr("GARGALOS"));
        y += S(20);
        {
            var lines: [10]struct { u32, [200]u8, usize } = undefined;
            var nl: usize = 0;
            const addLine = struct {
                fn f(ls: *[10]struct { u32, [200]u8, usize }, n: *usize, color: u32, comptime fmt: []const u8, args: anytype) void {
                    if (n.* == ls.len) return;
                    const t = i18n.bufPrint(&ls[n.*][1], fmt, args) catch return;
                    ls[n.*][0] = color;
                    ls[n.*][2] = t.len;
                    n.* += 1;
                }
            }.f;
            var late: usize = 0;
            var thin: usize = 0;
            var viewers: usize = 0;
            var late_names: [120]u8 = undefined;
            var ln_len: usize = 0;
            var big_q: ?*const client_mod.ServerStats.Person = null;
            var tcp_names: usize = 0;
            for (st.people[0..st.n_people]) |*p| {
                if (p.watching > 0) viewers += 1;
                if (p.flags & proto.stats_late != 0) {
                    late += 1;
                    const part = std.fmt.bufPrint(late_names[ln_len..], "{s}{s}", .{ if (ln_len > 0) ", " else "", p.nameSlice() }) catch "";
                    ln_len += part.len;
                }
                if (p.flags & proto.stats_thin != 0) thin += 1;
                if (p.queued > 1024 * 1024 and (big_q == null or p.queued > big_q.?.queued)) big_q = p;
                if (!p.udp and st.udp_conns > 0) tcp_names += 1;
            }
            if (cpu_pct >= 85) {
                addLine(&lines, &nl, col.red, "CPU do servidor no limite ({d:.0}% de {d} núcleos): ele não dá conta de repassar pra todo mundo.", .{ cpu_pct, st.cores });
            } else if (cpu_pct >= 60) addLine(&lines, &nl, col.yellow, "CPU do servidor alta ({d:.0}%). Se subir mais, começa a atrasar todo mundo.", .{cpu_pct});
            if (late > 0 and viewers > 0 and late * 2 > viewers) {
                addLine(&lines, &nl, col.red, "A maioria de quem assiste está atrasando: o gargalo deve ser o upload do servidor (saindo {d:.1} Mbit/s) ou de quem transmite.", .{mbit(st.out_bps)});
            } else if (late > 0) addLine(&lines, &nl, col.yellow, "Atrasando: {s}. Provavelmente a internet dessa pessoa (o resto está em dia).", .{late_names[0..ln_len]});
            if (thin > 0) addLine(&lines, &nl, col.yellow, "{d} recebendo só metade dos quadros (a rede ou o PC delas não deu conta).", .{thin});
            if (big_q) |p| addLine(&lines, &nl, col.yellow, "Fila grande pra {s} ({d} KB esperando pra sair): a conexão dela está lenta.", .{ p.nameSlice(), p.queued / 1024 });
            if (st.resyncs > 0) addLine(&lines, &nl, col.muted, "{d} recomeço(s) de quadro-chave nos últimos {d} s (alguém atrasou e voltou do zero).", .{ st.resyncs, @max(1, st.window_ms / 1000) });
            if (st.slow > 0) addLine(&lines, &nl, col.muted, "Pediu {d} vez(es) pra quem transmite baixar a taxa.", .{st.slow});
            if (st.rss_kb > 1536 * 1024) addLine(&lines, &nl, col.yellow, "Memória alta ({d} MB).", .{st.rss_kb / 1024});
            if (st.max_members > 0 and st.conns + 1 >= st.max_members) addLine(&lines, &nl, col.yellow, "Sala quase cheia ({d} de {d}).", .{ st.conns, st.max_members });
            if (tcp_names > 0) addLine(&lines, &nl, col.muted, "{d} pessoa(s) só pelo TCP (o UDP não passou na rede delas): perda de pacote vira atraso.", .{tcp_names});
            if (nl == 0) addLine(&lines, &nl, col.green, "Tudo tranquilo: nenhum gargalo agora.", .{});
            if (st.hosted()) addLine(&lines, &nl, col.muted, "A sala roda dentro do seu telinha: a CPU e a memória são do app inteiro (inclui transmitir e assistir).", .{});
            for (lines[0..nl]) |*ln| {
                const text = ln[1][0..ln[2]];
                c.ImDrawList_AddCircleFilled(d, v2(o.x + S(6), y + S(8)), S(4), ln[0], 0);
                pushFont(font_regular, 13);
                const ts = c.igCalcTextSize(text.ptr, text.ptr + text.len, false, inner - S(24));
                popFont();
                drawTextWrapF(d, font_regular, 13, v2(o.x + S(20), y), col.text, text, inner - S(24));
                y += ts.y + S(6);
            }
        }
        y += S(10);

        // quem está conectado
        drawTextF(d, font_bold, 11, v2(o.x, y), col.muted, fmtZ("QUEM ESTÁ CONECTADO · {d}", .{st.conns}));
        y += S(20);
        const col_x = [_]f32{ 0, 0.27, 0.44, 0.60, 0.72, 0.84, 0.92 };
        const heads = [_][]const u8{ tr("NOME"), tr("CANAL"), tr("CAMINHO"), tr("PRA ELA"), tr("DELA"), tr("FILA"), "" };
        for (heads, 0..) |hd, i| drawTextF(d, font_bold, 10.5, v2(o.x + inner * col_x[i], y), col.faint, hd);
        y += S(18);
        // a tabela rola junto com o resto se não couber
        c.igSetCursorScreenPos(v2(o.x, y));
        const table_h = @max(S(80), (o.y + h - S(40)) - y);
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, 0);
        _ = c.igBeginChild_Str("statsppl", v2(inner, table_h), 0, 0);
        const td = drawList();
        for (st.people[0..st.n_people], 0..) |*p, i| {
            const rp = c.igGetCursorScreenPos();
            const rh = S(30);
            if (i % 2 == 0) rectFill(td, rp.x, rp.y, rp.x + inner, rp.y + rh, withAlpha(col.text, 6), S(6));
            const ty = rp.y + (rh - S(16)) / 2;
            drawAvatar(td, v2(rp.x + S(12), rp.y + rh / 2), S(9), p.id, p.nameSlice(), p.flags & (proto.stats_streaming | proto.stats_camera) != 0);
            drawTextF(td, font_semibold, 13, v2(rp.x + S(28), ty), col.header, p.nameSlice());
            if (p.flags & proto.stats_owner != 0) drawTextF(td, font_regular, 11, v2(rp.x + S(32) + textSizeF(font_semibold, 13, p.nameSlice()).x, ty + S(1)), col.yellow, ic.crown);
            drawTextF(td, font_regular, 12.5, v2(rp.x + inner * col_x[1], ty), col.muted, fmtZ("#{s}", .{p.chanSlice()}));
            const route = if (p.udp and p.rtt_ms > 0) fmtZ("UDP · {d} ms", .{p.rtt_ms}) else if (p.udp) fmtZ("UDP · {s}", .{routeShort(p.route)}) else fmtZ("TCP · {s}", .{routeShort(p.route)});
            c.ImDrawList_PushClipRect(td, v2(rp.x + inner * col_x[2], rp.y), v2(rp.x + inner * col_x[3] - S(8), rp.y + rh), true);
            drawTextF(td, font_regular, 12.5, v2(rp.x + inner * col_x[2], ty), if (p.udp) col.text else col.muted, route);
            c.ImDrawList_PopClipRect(td);
            drawTextF(td, font_regular, 12.5, v2(rp.x + inner * col_x[3], ty), col.text, fmtZ("{d:.2} Mbit/s", .{mbit(p.tx_bps)}));
            drawTextF(td, font_regular, 12.5, v2(rp.x + inner * col_x[4], ty), col.text, fmtZ("{d:.2} Mbit/s", .{mbit(p.rx_bps)}));
            drawTextF(td, font_regular, 12.5, v2(rp.x + inner * col_x[5], ty), if (p.queued > 1024 * 1024) col.yellow else col.muted, fmtZ("{d} KB", .{p.queued / 1024}));
            const sit: []const u8 = if (p.flags & proto.stats_late != 0) tr("atrasando") else if (p.flags & proto.stats_thin != 0) tr("metade") else if (p.flags & proto.stats_streaming != 0) tr("ao vivo") else "";
            const sc = if (p.flags & proto.stats_late != 0) col.red else if (p.flags & proto.stats_thin != 0) col.yellow else col.red;
            if (sit.len > 0) drawTextF(td, font_semibold, 11.5, v2(rp.x + inner * col_x[6], ty + S(1)), sc, sit);
            c.igDummy(v2(inner, rh));
        }
        c.igEndChild();
        c.igPopStyleColor(1);
        redrawIn(0.5); // números novos chegam a cada 2 s (a rede acorda também)
    }

    fn closeModals(a: *App) void {
        if (a.settings_modal) config.save(&a.cfg); // o que o "Fechar" faria
        a.ptt_capture = false;
        a.key_capture = null;
        a.settings_modal = false;
        a.share_modal = false;
        a.leave_confirm = false;
        if (a.stats_open) {
            a.stats_open = false;
            if (a.client) |cl| cl.wantStats(false);
        }
    }

    /// O telinha travou da última vez: manda o relatório? (gofile, ou o
    /// webhook se ele estiver escolhido e configurado em Depuração)
    fn drawCrashPrompt(a: *App) void {
        _ = c.igOpenPopup_Str(tr("O telinha travou###travou"), 0);
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(S(440), 0), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("O telinha travou###travou"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const w = S(392);
        pushFont(font_bold, 19);
        textColored(col.header, tr("O telinha fechou do nada da última vez"));
        popFont();
        c.igDummy(v2(0, S(6)));
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 14);
        textColored(col.muted, tr("Dá pra mandar o relatório (o que deu errado e, se estava ligado, o fim do log de depuração) pra ajudar a consertar. Ele não tem senha nenhuma."));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(18)));
        const bw = (w - S(10)) / 2;
        if (secondaryButton(tr("Agora não###travounao"), v2(bw, S(40))) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            crash.dismiss();
            a.crash_prompt = false;
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, S(10));
        if (primaryButton(fmtZ("{s}  Mandar###travoumandar", .{ic.send}), v2(bw, S(40)), col.blurple, col.blurple_hover, col.blurple_active)) {
            a.sendCrashReport();
            a.crash_prompt = false;
            c.igCloseCurrentPopup();
        }
    }

    // ------------------------------------------------------ atualização

    /// O app abriu numa versão diferente da última vez: mostra as novidades.
    /// Primeira vez na máquina: nada (só anota a versão).
    fn noteVersion(a: *App) void {
        const last = config.getStr(&a.cfg.last_version);
        if (std.mem.eql(u8, last, version_string)) return;
        if (!config.fresh and (last.len == 0 or update.isNewer(version_string, last))) {
            a.whatsnew = true;
            a.whatsnew_after_len = @min(last.len, a.whatsnew_after.len);
            @memcpy(a.whatsnew_after[0..a.whatsnew_after_len], last[0..a.whatsnew_after_len]);
        }
        config.setStr(&a.cfg.last_version, version_string);
        config.save(&a.cfg);
    }

    /// A cada quadro: checa de novo de vez em quando, abre o aviso quando
    /// aparece versão nova (ou instala sozinho, se a pessoa quis).
    fn updateTick(a: *App) void {
        if (!a.cfg.check_updates) return;
        update.recheckIfStale(build_options.repo, version_string, i18n.english());
        const st = update.getState();
        if (st == .newer) {
            var vb: [32]u8 = undefined;
            const v = update.latest(&vb);
            if (!std.mem.eql(u8, v, a.update_seen[0..a.update_seen_len])) {
                @memcpy(a.update_seen[0..v.len], v);
                a.update_seen_len = v.len;
                if (a.cfg.update_auto and update.canInstall()) {
                    debuglog.line("versão nova {s}: instalando sozinho", .{v});
                    update.installAsync();
                    a.update_auto_started = true;
                } else if (!std.mem.eql(u8, v, config.getStr(&a.cfg.update_skip))) {
                    debuglog.line("versão nova {s}: avisando", .{v});
                    a.update_modal = true;
                }
            }
        }
        if (a.update_auto_started and (st == .installed or st == .install_failed)) {
            a.update_auto_started = false;
            a.update_modal = true;
        }
        if (st == .downloading or st == .checking) redrawIn(0.25);
    }

    fn ownChangelog() []const u8 {
        return if (i18n.english()) changelog_en else changelog_pt;
    }

    /// Seções do CHANGELOG (markdown) desenhadas: título da versão, subtítulos,
    /// itens. `collapse`: cada versão abre e fecha (o histórico inteiro).
    fn drawChangelog(text: []const u8, w: f32, comptime id: []const u8, collapse: bool) void {
        var it: changelog.Iter = .{ .text = text };
        var k: u32 = 0;
        var scratch: [4096]u8 = undefined;
        // sem "## versão" (as notas da release, quando o CHANGELOG não veio): as linhas direto
        noteEmoji(text); // os Destaques têm emoji: carrega a fonte deles
        if (!changelog.hasSections(text)) {
            drawChangelogLines(text, w, &scratch);
            return;
        }
        while (it.next()) |sec| : (k += 1) {
            if (collapse) {
                const flags: c.ImGuiTreeNodeFlags = if (k == 0) c.ImGuiTreeNodeFlags_DefaultOpen else 0;
                pushFont(font_semibold, 15);
                const open = c.igCollapsingHeader_TreeNodeFlags(fmtZ("{s}###" ++ id ++ "{d}", .{ i18n.dynamic(sec.title, &scratch), k }), flags);
                popFont();
                if (!open) continue;
            } else {
                pushFont(font_bold, 17);
                textColored(col.header, sec.title);
                popFont();
            }
            drawChangelogLines(sec.body, w, &scratch);
            c.igDummy(v2(0, S(10)));
        }
    }

    fn drawChangelogLines(body: []const u8, w: f32, scratch: []u8) void {
        var li: changelog.LineIter = .{ .body = body, .scratch = scratch };
        while (li.next()) |l| switch (l) {
            .gap => c.igDummy(v2(0, S(3))),
            .sub => |t| {
                pushFont(font_semibold, 14);
                textColored(col.muted, t);
                popFont();
            },
            .bullet => |t| richParagraph(t, w, true),
            .para => |t| richParagraph(t, w, false),
        };
    }

    fn richParagraph(t: []const u8, w: f32, bullet: bool) void {
        const d = drawList();
        const p0 = c.igGetCursorScreenPos();
        const fs: f32 = 13.5;
        const lh = textSizeF(font_regular, fs, "Ag").y;
        const indent: f32 = if (bullet) S(16) else 0;
        if (bullet) drawTextF(d, font_regular, fs, v2(p0.x + S(4), p0.y), col.muted, "•");
        const bottom = richInline(d, t, p0.x + indent, p0.x + w, p0.y, fs, lh);
        c.igSetCursorScreenPos(p0);
        c.igDummy(v2(w, @max(lh, bottom - p0.y) + S(2)));
    }

    /// Versão nova: o que muda (todas as versões entre a sua e a nova) e o botão
    /// de atualizar (ou de abrir a página, quando não dá pra instalar sozinho).
    fn drawUpdateModal(a: *App) void {
        const st = update.getState();
        if (st != .newer and st != .downloading and st != .installed and st != .install_failed) {
            a.update_modal = false;
            return;
        }
        _ = c.igOpenPopup_Str(tr("Versão nova###atualizar"), 0);
        const vp = c.igGetMainViewport();
        const mw = @min(S(600), vp.*.Size.x - S(40));
        const mh = @min(S(640), vp.*.Size.y - S(40));
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(mw, mh), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("Versão nova###atualizar"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollbar)) return;
        defer c.igEndPopup();
        const w = mw - S(48);
        var vb: [32]u8 = undefined;
        const v = update.latest(&vb);
        pushFont(font_bold, 20);
        if (st == .installed)
            textColored(col.header, fmtZ("telinha {s} instalado", .{v}))
        else
            textColored(col.header, fmtZ("telinha {s} saiu", .{v}));
        popFont();
        pushFont(font_regular, 13.5);
        textColored(col.muted, fmtZ("Você está na {s}. O que muda:", .{version_string}));
        popFont();
        c.igDummy(v2(0, S(6)));

        // o que muda (rola)
        const footer_h = S(118);
        const notes_h = @max(S(80), c.igGetContentRegionAvail().y - footer_h);
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, col.bg_side);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(14), S(12)));
        if (c.igBeginChild_Str("##updnotes", v2(w, notes_h), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0)) {
            const nt = update.notes();
            if (nt.len == 0) {
                pushFont(font_regular, 13.5);
                textColored(col.muted, tr("As novidades estão na página da versão."));
                popFont();
            } else drawChangelog(nt, w - S(40), "upd", false);
        }
        c.igEndChild();
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
        c.igDummy(v2(0, S(8)));

        // situação + botões
        pushFont(font_regular, 13);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        switch (st) {
            .downloading => {
                const p = update.progress();
                const pp = c.igGetCursorScreenPos();
                const d = c.igGetWindowDrawList();
                rectFill(d, pp.x, pp.y + S(4), pp.x + w, pp.y + S(10), withAlpha(col.text, 30), S(3));
                rectFill(d, pp.x, pp.y + S(4), pp.x + w * p, pp.y + S(10), col.green, S(3));
                c.igDummy(v2(w, S(14)));
                textColored(col.muted, fmtZ("Baixando... {d}%", .{@as(u32, @intFromFloat(p * 100))}));
            },
            .installed => textColored(col.green, tr("Pronto. A versão nova abre quando o telinha reiniciar.")),
            .install_failed => {
                var eb: [300]u8 = undefined;
                textColored(col.red, fmtZ("Não deu pra atualizar: {s}", .{i18n.dynamic(update.installError(), &eb)}));
            },
            else => if (!update.canInstall()) {
                var eb: [300]u8 = undefined;
                textColored(col.muted, fmtZ("Atualizar daqui não dá ({s}): é só baixar pela página.", .{i18n.dynamic(update.whyNot(), &eb)}));
            } else c.igDummy(v2(0, 0)),
        }
        c.igPopTextWrapPos();
        popFont();
        c.igSetCursorPosY(mh - S(22) - S(40) - S(30));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Instalar as próximas versões sozinho###updauto2"), &a.cfg.update_auto)) config.save(&a.cfg);
        c.igPopStyleColor(1);
        c.igSetCursorPosY(mh - S(22) - S(40));
        const bw = (w - S(20)) / 3;
        var close = c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);
        switch (st) {
            .installed => {
                if (secondaryButton(tr("Depois###updlater"), v2(bw, S(40)))) close = true;
                c.igSameLine(0, S(10));
                if (primaryButton(fmtZ("{s}  Reiniciar agora###updrestart", .{ic.arrow_right}), v2(bw * 2 + S(10), S(40)), col.green, col.green_hover, col.green_active)) {
                    debuglog.line("reiniciando na versão nova", .{});
                    if (update.restart()) {
                        c.glfwSetWindowShouldClose(a.window, 1);
                    } else a.toast("Não consegui abrir a versão nova: feche e abra o telinha.", .{}, true);
                    close = true;
                }
            },
            .downloading => {
                if (secondaryButton(tr("Continuar usando###updbg"), v2(w, S(40)))) close = true;
            },
            else => {
                if (secondaryButton(tr("Pular esta versão###updskip"), v2(bw, S(40)))) {
                    config.setStr(&a.cfg.update_skip, v);
                    config.save(&a.cfg);
                    close = true;
                }
                c.igSameLine(0, S(10));
                if (secondaryButton(tr("Depois###updlater"), v2(bw, S(40)))) close = true;
                c.igSameLine(0, S(10));
                if (update.canInstall()) {
                    const label = if (st == .install_failed) fmtZ("{s}  Tentar de novo###updgo", .{ic.arrow_right}) else fmtZ("{s}  Atualizar agora###updgo", .{ic.arrow_right});
                    if (primaryButton(label, v2(bw, S(40)), col.green, col.green_hover, col.green_active)) {
                        debuglog.line("atualizando pra {s}", .{v});
                        update.installAsync();
                    }
                } else if (primaryButton(tr("Abrir a página###updpage"), v2(bw, S(40)), col.blurple, col.blurple_hover, col.blurple_active)) {
                    openReleases();
                    close = true;
                }
            },
        }
        if (close) {
            a.update_modal = false;
            config.save(&a.cfg);
            c.igCloseCurrentPopup();
        }
    }

    /// Acabou de atualizar: o que mudou desde a versão de antes.
    fn drawWhatsNew(a: *App) void {
        const text = if (a.whatsnew_after_len > 0)
            changelog.between(ownChangelog(), a.whatsnew_after[0..a.whatsnew_after_len], version_string)
        else
            changelog.section(ownChangelog(), version_string);
        if (text.len == 0) {
            a.whatsnew = false;
            return;
        }
        _ = c.igOpenPopup_Str(tr("Novidades###novidades"), 0);
        const vp = c.igGetMainViewport();
        const mw = @min(S(600), vp.*.Size.x - S(40));
        const mh = @min(S(600), vp.*.Size.y - S(40));
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(mw, mh), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("Novidades###novidades"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollbar)) return;
        defer c.igEndPopup();
        const w = mw - S(48);
        pushFont(font_bold, 20);
        textColored(col.header, fmtZ("Novidades do telinha {s}", .{version_string}));
        popFont();
        c.igDummy(v2(0, S(6)));
        const notes_h = @max(S(80), c.igGetContentRegionAvail().y - S(56));
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, col.bg_side);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(14), S(12)));
        if (c.igBeginChild_Str("##newnotes", v2(w, notes_h), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0)) drawChangelog(text, w - S(40), "new", false);
        c.igEndChild();
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
        c.igSetCursorPosY(mh - S(22) - S(40));
        const bw = (w - S(10)) / 2;
        var close = c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);
        if (secondaryButton(tr("Histórico de versões###newhist"), v2(bw, S(40)))) {
            close = true;
            a.settings_page = .sobre;
            a.openSettings();
        }
        c.igSameLine(0, S(10));
        if (primaryButton(tr("Valeu###newok"), v2(bw, S(40)), col.blurple, col.blurple_hover, col.blurple_active)) close = true;
        if (close) {
            a.whatsnew = false;
            c.igCloseCurrentPopup();
        }
    }

    fn sendCrashReport(a: *App) void {
        const hook = config.getStr(&a.cfg.debug_webhook);
        const in_room = if (a.client) |cl| cl.isConnected() else false;
        // pela sala só dá conectado (o aviso costuma aparecer ao abrir o app): senão gofile
        const method: debuglog.Method = if (a.cfg.debug_send == 1 and debuglog.validUrl(hook)) .webhook else if (a.cfg.debug_send == 2 and in_room and a.server == null) .room else .gofile;
        a.debug_sent_via = method;
        debuglog.sendWhat(method, .crash, hook, config.getStr(&a.cfg.name)) catch {
            a.toast("Já tem um envio em andamento; tenta de novo daqui a pouco.", .{}, true);
            return;
        };
        a.crash_sending = true;
    }

    /// O relatório mandado pelo aviso terminou: diz como foi (e copia o link).
    fn watchCrashSend(a: *App) void {
        if (!a.crash_sending) return;
        switch (debuglog.sendState()) {
            .sending, .idle => redrawIn(0.25),
            .failed => {
                a.crash_sending = false;
                var rb: [512]u8 = undefined;
                var eb: [300]u8 = undefined;
                a.toast("Não consegui mandar o relatório: {s}", .{i18n.dynamic(debuglog.sendResult(&rb), &eb)}, true);
            },
            .done => {
                a.crash_sending = false;
                var rb: [520]u8 = undefined;
                const link = debuglog.sendResult(rb[0..512]);
                if (a.debug_sent_via == .room) {
                    a.toast("Relatório entregue pro dono da sala. Valeu!", .{}, false);
                } else if (link.len == 0) {
                    a.toast("Relatório mandado pro webhook. Valeu!", .{}, false);
                } else {
                    rb[link.len] = 0;
                    c.igSetClipboardText(@ptrCast(&rb));
                    a.toast("Relatório mandado: {s} (link copiado, manda pra quem vai consertar)", .{link}, false);
                }
            },
        }
    }

    fn drawLeaveConfirm(a: *App) void {
        _ = c.igOpenPopup_Str(tr("Fechar a sala###fecharsala"), 0);
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(S(400), 0), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("Fechar a sala###fecharsala"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const w = S(352);
        pushFont(font_bold, 19);
        textColored(col.header, tr("Fechar a sala?"));
        popFont();
        c.igDummy(v2(0, S(6)));
        const others = if (a.server) |sv| sv.memberCount() -| 1 else 0;
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 14);
        textColored(col.muted, if (others == 1)
            fmtZ("A sala é sua: fechando, a pessoa que está aqui sai da sala (e fica sabendo que você fechou).", .{})
        else
            fmtZ("A sala é sua: fechando, as {d} pessoas que estão aqui saem da sala (e fica sabendo que você fechou).", .{others}));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(18)));
        const bw = (w - S(10)) / 2;
        if (secondaryButton(tr("Cancelar###sair"), v2(bw, S(40))) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            a.leave_confirm = false;
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, S(10));
        if (primaryButton(tr("Fechar a sala###fecharsalabtn"), v2(bw, S(40)), col.red, col.red_hover, col.red_hover)) {
            c.igCloseCurrentPopup();
            a.leaveRoom();
        }
    }

    /// Janela por cima de tudo (recebe clique, diferente da foreground draw list).
    fn beginOverlay(id: [:0]const u8, size: c.ImVec2_c, bg: u32) *c.ImDrawList {
        c.igSetNextWindowPos(v2(0, 0), c.ImGuiCond_Always, v2(0, 0));
        c.igSetNextWindowSize(size, c.ImGuiCond_Always);
        c.igSetNextWindowFocus();
        c.igPushStyleColor_U32(c.ImGuiCol_WindowBg, bg);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        _ = c.igBegin(id.ptr, null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoResize);
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
        return drawList();
    }

    fn drawConnecting(a: *App, size: c.ImVec2_c) void {
        const d = beginOverlay("##connecting", size, withAlpha(col.bg_dark, 240));
        defer c.igEnd();
        const t = if (a.reconnect.attempt > 0)
            fmtZ("Reconectando em {s}... (tentativa {d} de {d})", .{ a.connect_label[0..a.connect_label_len], a.reconnect.attempt, max_reconnect })
        else
            fmtZ("Conectando em {s}...", .{a.connect_label[0..a.connect_label_len]});
        const ts = textSizeF(font_semibold, 18, t);
        // bolinhas animadas
        const tm: f32 = @floatCast(c.igGetTime());
        for (0..3) |i| {
            const fi: f32 = @floatFromInt(i);
            const s = 0.5 + 0.5 * @sin(tm * 5 - fi * 0.8);
            c.ImDrawList_AddCircleFilled(d, v2(size.x / 2 + (fi - 1) * S(22), size.y / 2 - S(30)), S(5) + S(3) * s, col.blurple, 0);
        }
        drawTextF(d, font_semibold, 18, v2((size.x - ts.x) / 2, size.y / 2), col.header, t);
        c.igSetCursorScreenPos(v2(size.x / 2 - S(60), size.y / 2 + S(40)));
        if (secondaryButton(tr("Cancelar###cancelconn"), v2(S(120), S(36)))) a.leaveRoom();
        redrawIn(0.05); // mantém a animação (20 q/s bastam)
    }

    fn drawDropped(a: *App, cl: *Client, size: c.ImVec2_c) void {
        const d = beginOverlay("##dropped", size, withAlpha(col.bg_dark, 225));
        defer c.igEnd();
        var eb: [400]u8 = undefined;
        const t = i18n.dynamic(cl.errSlice(), &eb);
        const ts = textSizeF(font_semibold, 18, t);
        const it = textSizeF(font_regular, 36, ic.warn);
        drawTextF(d, font_regular, 36, v2((size.x - it.x) / 2, size.y / 2 - S(70)), col.yellow, ic.warn);
        drawTextF(d, font_semibold, 18, v2((size.x - ts.x) / 2, size.y / 2 - S(10)), col.header, t);
        if (a.reconnect.waiting) {
            // contagem até a próxima tentativa automática
            const left = @max(0, a.reconnect.at - c.igGetTime());
            const sub = fmtZ("Tentando de novo em {d:.0} s... (tentativa {d} de {d})", .{ @ceil(left), a.reconnect.attempt, max_reconnect });
            const ss = textSizeF(font_regular, 14, sub);
            drawTextF(d, font_regular, 14, v2((size.x - ss.x) / 2, size.y / 2 + S(16)), col.muted, sub);
            c.igSetCursorScreenPos(v2(size.x / 2 - S(130), size.y / 2 + S(50)));
            if (primaryButton(tr("Tentar agora###tentar"), v2(S(125), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.reconnect.at = 0;
            c.igSameLine(0, S(10));
            if (secondaryButton(tr("Sair###sair"), v2(S(125), S(38)))) a.leaveRoom();
            redrawIn(0.25); // mantém a contagem andando
            return;
        }
        cl.mutex.lock();
        const final = cl.final;
        cl.mutex.unlock();
        if (final) {
            // expulso, sala fechada, link desligado: reconectar não adianta
            c.igSetCursorScreenPos(v2(size.x / 2 - S(80), size.y / 2 + S(30)));
            if (primaryButton(tr("Voltar ao início###inicio"), v2(S(160), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.leaveRoom();
            return;
        }
        c.igSetCursorScreenPos(v2(size.x / 2 - S(130), size.y / 2 + S(30)));
        if (primaryButton(tr("Reconectar###reconectar"), v2(S(125), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
            const was_host = a.server != null;
            a.leaveRoom();
            if (was_host) a.createRoom() else a.joinRoom();
            return;
        }
        c.igSameLine(0, S(10));
        if (secondaryButton(tr("Sair###sair"), v2(S(125), S(38)))) a.leaveRoom();
    }

    fn sectionHeader(text: []const u8) void {
        c.igDummy(v2(0, S(14)));
        c.igSetCursorPosX(S(16));
        pushFont(font_bold, 11.5);
        textColored(col.muted, text);
        popFont();
        c.igDummy(v2(0, S(2)));
    }

    /// Barra do topo: a sala (logo, nome, conexão), quem está ao vivo (pílulas:
    /// clique pra assistir) e, na direita, cadeado, convite, painel e
    /// configurações.
    fn drawHeader(a: *App, cl: *Client, size: c.ImVec2_c) void {
        const d = drawList();
        const o = c.igGetCursorScreenPos();
        rectFill(d, o.x, o.y, o.x + size.x, o.y + size.y, col.bg_dark, 0);
        rectFill(d, o.x, o.y + size.y - 1, o.x + size.x, o.y + size.y, withAlpha(col.text, 16), 0);

        cl.mutex.lock();
        var room_buf: [64]u8 = undefined;
        const room_name = blk: {
            const n = cl.room_name_len;
            @memcpy(room_buf[0..n], cl.room_name[0..n]);
            break :blk room_buf[0..n];
        };
        const ping = cl.ping_ms;
        const my_id = cl.my_id;
        const my_route = cl.route;
        const locked = cl.room_locked;
        const i_am_admin = cl.is_admin;
        var members: [64]Member = undefined;
        const n_members = @min(cl.members.items.len, members.len);
        @memcpy(members[0..n_members], cl.members.items[0..n_members]);
        var chan_buf: [proto.channel_name_max]u8 = undefined;
        const chan_len = if (cl.chans_supported) cl.chan_name_len else 0;
        @memcpy(chan_buf[0..chan_len], cl.chan_name[0..chan_len]);
        // estatísticas do servidor: só quem entrou com o token de admin, em servidor que tem
        const i_am_owner = cl.chans_supported and for (members[0..n_members]) |*m| {
            if (m.id == my_id) break m.owner;
        } else false;
        cl.mutex.unlock();

        // onde começam os botões da direita (o resto não passa disso)
        const bs = S(36);
        const n_btns: f32 = @floatFromInt(2 + @as(u8, @intFromBool(!a.chat_visible)) + @as(u8, @intFromBool(i_am_admin or locked)) + @as(u8, @intFromBool(i_am_owner)));
        const right_start = o.x + size.x - S(12) - n_btns * bs - (n_btns - 1) * S(4) - S(16);

        // logo + nome da sala + linha da conexão
        c.ImDrawList_PushClipRect(d, o, v2(@max(o.x, right_start - S(4)), o.y + size.y), true);
        const lz = S(34);
        const lx = o.x + S(14);
        const ly = o.y + (size.y - lz) / 2;
        if (logo_tex == 0) gl.upload(&logo_tex, logo_rgba, 128, 128, gl.RGBA);
        c.ImDrawList_AddImageRounded(d, texRef(logo_tex), v2(lx, ly), v2(lx + lz, ly + lz), v2(0, 0), v2(1, 1), col.white, S(9), 0);
        const tx = lx + lz + S(12);
        const title = if (room_name.len > 0) room_name else "telinha";
        drawTextF(d, font_bold, 15.5, v2(tx, o.y + S(10)), col.header, title);
        var title_end = tx + textSizeF(font_bold, 15.5, title).x;
        if (chan_len > 0) {
            // o canal em que a gente está, do lado do nome da sala
            const ct = fmtZ("#{s}", .{chan_buf[0..chan_len]});
            const cw = textSizeF(font_semibold, 12, ct).x + S(16);
            const cx0 = title_end + S(8);
            rectFill(d, cx0, o.y + S(9), cx0 + cw, o.y + S(29), withAlpha(col.blurple, 45), S(10));
            drawTextF(d, font_semibold, 12, v2(cx0 + S(8), o.y + S(11)), col.blurple, ct);
            title_end = cx0 + cw;
        }
        const pc = if (ping < 80) col.green else if (ping < 200) col.yellow else col.red;
        const where = if (a.server) |sv|
            fmtZ("{s} anfitrião · porta {d}", .{ ic.crown, sv.port })
        else if (my_route == proto.route_tunnel)
            fmtZ("{s} via link público", .{ic.globe})
        else
            fmtZ("{s}", .{a.connect_label[0..a.connect_label_len]});
        var wb: [96]u8 = undefined;
        const where_s = std.fmt.bufPrint(&wb, "{s}", .{where}) catch "";
        const sy = o.y + S(32);
        var sx = tx;
        drawTextF(d, font_regular, 11.5, v2(sx, sy), pc, ic.signal);
        sx += S(16);
        const pt = fmtZ("{d} ms", .{ping});
        drawTextF(d, font_regular, 11.5, v2(sx, sy), col.muted, pt);
        sx += textSizeF(font_regular, 11.5, pt).x + S(10);
        drawTextF(d, font_regular, 11, v2(sx, sy + S(1)), col.green, ic.lock);
        if (c.igIsMouseHoveringRect(v2(sx - S(4), sy - S(2)), v2(sx + S(14), sy + S(16)), true)) {
            const idt = switch (cl.id_state) {
                .verified => fmtZ("Conexão criptografada (X25519 + ChaCha20-Poly1305)\nIdentidade do servidor conferida: {s}", .{&cl.server_fp}),
                else => fmtZ("Conexão criptografada (X25519 + ChaCha20-Poly1305)\nO servidor não tem identidade fixa (versão antiga): não dá pra conferir quem é", .{}),
            };
            tooltipText(idt);
        }
        sx += S(18);
        drawTextF(d, font_regular, 11.5, v2(sx, sy), col.faint, where_s);
        sx += textSizeF(font_regular, 11.5, where_s).x;
        const left_end = @max(title_end, sx) + S(28);
        c.ImDrawList_PopClipRect(d);

        // direita: configurações, painel, convite, cadeado
        const by = o.y + (size.y - bs) / 2;
        var rx = o.x + size.x - S(12) - bs;
        c.igSetCursorScreenPos(v2(rx, by));
        if (iconButton("##gear", ic.gear, bs, col.muted, col.hover, tr("Configurações"))) a.openSettings();
        if (i_am_owner) {
            rx -= bs + S(4);
            c.igSetCursorScreenPos(v2(rx, by));
            if (iconButton("##srvstats", ic.gauge, bs, if (a.stats_open) col.header else col.muted, col.hover, tr("Estatísticas do servidor (você entrou com o token de admin)"))) a.setStatsOpen(cl, !a.stats_open);
        }
        if (!a.chat_visible) {
            rx -= bs + S(4);
            c.igSetCursorScreenPos(v2(rx, by));
            if (iconButton("##showchat", ic.comments, bs, if (a.chat_unread > 0) col.header else col.muted, col.hover, tr("Mostrar chat e quem está na sala"))) {
                a.cfg.show_chat = true;
                config.save(&a.cfg);
            }
            if (a.chat_unread > 0) {
                const bp = v2(rx + bs - S(6), by + S(6));
                c.ImDrawList_AddCircleFilled(d, bp, S(8), col.red, 0);
                const t = fmtZ("{d}", .{@min(a.chat_unread, 9)});
                const ts = textSizeF(font_bold, 10, t);
                drawTextF(d, font_bold, 10, v2(bp.x - ts.x / 2, bp.y - ts.y / 2), col.white, t);
            }
        }
        rx -= bs + S(4);
        c.igSetCursorScreenPos(v2(rx, by));
        if (iconButton("##invite", ic.user_plus, bs, col.muted, col.hover, tr("Copiar convite da sala"))) a.copyInvite();
        // o servidor tem página pra assistir no navegador: o link (pra quem não tem o app)
        if (cl.web_link_len > 0) {
            rx -= bs + S(4);
            c.igSetCursorScreenPos(v2(rx, by));
            if (iconButton("##weblink", ic.tv, bs, col.muted, col.hover, tr("Copiar o link pra assistir no navegador (sem instalar nada)"))) a.copyWebLink(cl);
        }
        if (i_am_admin) {
            rx -= bs + S(4);
            c.igSetCursorScreenPos(v2(rx, by));
            if (iconButton("##lockroom", if (locked) ic.lock else ic.lock_open, bs, if (locked) col.yellow else col.muted, col.hover, if (locked) tr("Sala trancada: ninguém novo entra. Clique pra destrancar.") else tr("Trancar a sala (ninguém novo entra)")))
                cl.admin(proto.admin_lock, 0, @intFromBool(!locked));
        } else if (locked) {
            rx -= bs + S(4);
            const ls = textSizeF(font_regular, 15, ic.lock);
            drawTextF(d, font_regular, 15, v2(rx + (bs - ls.x) / 2, by + (bs - ls.y) / 2), col.yellow, ic.lock);
            if (c.igIsMouseHoveringRect(v2(rx, by), v2(rx + bs, by + bs), true)) tooltipText(tr("Sala trancada: ninguém novo entra"));
        }

        // meio: quem está ao vivo (pílulas). Clique assiste / para de assistir.
        const ph = S(32);
        const py = o.y + (size.y - ph) / 2;
        var px = left_end;
        var hidden: usize = 0;
        for (members[0..n_members]) |*m| {
            for ([_]u8{ proto.kind_screen, proto.kind_camera }) |kind| {
                const on = if (kind == proto.kind_screen) m.streaming else m.camera();
                if (!on) continue;
                const stream = proto.streamId(m.id, kind);
                const camera = kind == proto.kind_camera;
                var nb: [64]u8 = undefined;
                const label = std.fmt.bufPrintZ(&nb, "{s}{s}", .{ m.nameSlice()[0..@min(m.name_len, 24)], if (camera) "  " ++ ic.video else "" }) catch "?";
                const lw = textSizeF(font_semibold, 13, label).x;
                const pw = ph + S(8) + lw + S(36); // avatar + nome + olho
                if (px + pw > right_start - S(44)) {
                    hidden += 1;
                    continue;
                }
                c.igPushID_Int(@intCast(m.id + 100000 + @as(u32, kind) * 100000));
                c.igSetCursorScreenPos(v2(px, py));
                const clicked = c.igInvisibleButton("live", v2(pw, ph), 0);
                const hovered = c.igIsItemHovered(0);
                c.igPopID();
                if (a.n_live_rects < a.live_rects.len) {
                    a.live_rects[a.n_live_rects] = .{ .stream = stream, .x0 = px, .y0 = py, .x1 = px + pw, .y1 = py + ph };
                    a.n_live_rects += 1;
                }
                const is_me = m.id == my_id;
                const watching = a.findView(stream) != null;
                const fill = if (watching) withAlpha(col.blurple, 70) else if (hovered) col.hover else withAlpha(col.text, 12);
                rectFill(d, px, py, px + pw, py + ph, fill, ph / 2);
                c.ImDrawList_AddRect(d, v2(px, py), v2(px + pw, py + ph), if (watching) col.blurple else withAlpha(col.red, 150), ph / 2, S(1.2), 0);
                drawAvatar(d, v2(px + ph / 2, py + ph / 2), S(11), m.id, m.nameSlice(), false);
                c.ImDrawList_AddCircleFilled(d, v2(px + ph / 2 + S(8), py + ph / 2 + S(8)), S(4), col.red, 0);
                drawTextF(d, font_semibold, 13, v2(px + ph + S(6), py + (ph - S(16)) / 2), col.header, label);
                if (!is_me) {
                    const glyph = if (watching) ic.eye_slash else ic.eye;
                    const gs = textSizeF(font_regular, 13, glyph);
                    drawTextF(d, font_regular, 13, v2(px + pw - gs.x - S(12), py + (ph - gs.y) / 2), if (hovered) col.header else col.muted, glyph);
                }
                if (hovered) {
                    var viewers: usize = 0;
                    for (members[0..n_members]) |*w| {
                        if (w.isWatching(stream)) viewers += 1;
                    }
                    const action: []const u8 = if (is_me) tr("É você!") else if (watching) tr("Parar de assistir") else tr("Assistir");
                    var tb: [200]u8 = undefined;
                    const tip = if (camera)
                        std.fmt.bufPrintZ(&tb, "{s}\n{d}x{d} · {s} {d}", .{ action, m.cam_w, m.cam_h, ic.eye, viewers }) catch ""
                    else
                        std.fmt.bufPrintZ(&tb, "{s}\n{d}x{d} · {d} fps · {s} {d}", .{ action, m.w, m.h, m.fps, ic.eye, viewers }) catch "";
                    tooltipText(tip);
                }
                if (clicked and !is_me) {
                    if (watching) a.unwatch(stream) else a.watch(stream);
                }
                px += pw + S(8);
            }
        }
        if (hidden > 0) {
            // sem espaço nem pra isso: o painel e os quadros mostram quem está ao vivo
            const t = fmtZ("+{d} ao vivo", .{hidden});
            if (px + S(2) + textSizeF(font_semibold, 12.5, t).x < right_start)
                drawTextF(d, font_semibold, 12.5, v2(px + S(2), py + (ph - S(16)) / 2), col.muted, t);
        }
        c.igSetCursorScreenPos(o);
        c.igDummy(size);
    }

    /// Painel da direita: um cartão com quem está na sala em cima e o chat
    /// embaixo.
    fn drawPanel(a: *App, cl: *Client, size: c.ImVec2_c) void {
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, 0);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, v2(0, 0));
        _ = c.igBeginChild_Str("panel", size, 0, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
        defer {
            c.igEndChild();
            c.igPopStyleVar(2);
            c.igPopStyleColor(1);
        }
        const d = drawList();
        const o = c.igGetCursorScreenPos();
        // o cartão
        const x0 = o.x + S(2);
        const y0 = o.y + S(12);
        const x1 = o.x + size.x - S(12);
        const y1 = o.y + size.y - S(12);
        rectFill(d, x0, y0 + S(2), x1, y1 + S(2), rgba(0x000000, 50), S(16));
        rectFill(d, x0, y0, x1, y1, col.bg_side, S(16));
        c.ImDrawList_AddRect(d, v2(x0, y0), v2(x1, y1), withAlpha(col.text, 16), S(16) * col.round, S(1), 0);
        const inner_x = x0 + S(4);
        const inner_w = x1 - x0 - S(8);

        cl.mutex.lock();
        const my_id = cl.my_id;
        const i_am_admin = cl.is_admin;
        // o chat (painel) e a call (palco, voz)
        var chat_ppl: [64]Member = undefined;
        const n_chat = @min(cl.chan_members.items.len, chat_ppl.len);
        @memcpy(chat_ppl[0..n_chat], cl.chan_members.items[0..n_chat]);
        var call_ppl: [64]Member = undefined;
        var n_call: usize = 0;
        for (cl.members.items) |m| {
            if (n_call == call_ppl.len) break;
            if (m.in_call) {
                call_ppl[n_call] = m;
                n_call += 1;
            }
        }
        const has_chans = cl.chans_supported;
        var chans: [proto.max_channels]client_mod.ChanInfo = undefined;
        const n_chans = cl.n_chans;
        @memcpy(chans[0..n_chans], cl.chans[0..n_chans]);
        var cur_buf: [proto.channel_name_max]u8 = undefined;
        const cur_len = cl.chan_name_len;
        @memcpy(cur_buf[0..cur_len], cl.chan_name[0..cur_len]);
        var call_buf: [proto.channel_name_max]u8 = undefined;
        const call_len = cl.call_name_len;
        @memcpy(call_buf[0..call_len], cl.call_name[0..call_len]);
        const calls_known = cl.calls_known;
        cl.mutex.unlock();
        const cur = cur_buf[0..cur_len];
        const my_call = call_buf[0..call_len];

        c.igSetCursorScreenPos(v2(x1 - S(38), y0 + S(8)));
        if (iconButton("##hidechat", ic.xmark, S(30), col.muted, col.hover, tr("Esconder o painel"))) {
            a.cfg.show_chat = false;
            config.save(&a.cfg);
        }
        var top = y0 + S(16);
        if (has_chans) {
            drawTextF(d, font_bold, 11, v2(inner_x + S(12), top), col.muted, fmtZ("CANAIS · {d}", .{n_chans}));
            c.igSetCursorScreenPos(v2(x1 - S(72), y0 + S(8)));
            if (iconButton("##newchan", ic.plus, S(30), if (a.new_chan_open) col.header else col.muted, col.hover, tr("Criar ou entrar num canal (no chat: /join nome)"))) {
                a.new_chan_open = !a.new_chan_open;
                a.focus_new_chan = a.new_chan_open;
            }
            top += S(24);
            const row_h = S(30);
            // campos que aparecem em cima da lista: canal novo, senha pedida, senha/tópico do admin
            const n_fields: f32 = @floatFromInt(@as(u8, @intFromBool(a.new_chan_open)) + @as(u8, @intFromBool(a.chan_pw_len > 0)) + @as(u8, @intFromBool(a.chan_edit != .none)));
            const want_h = row_h * @as(f32, @floatFromInt(n_chans)) + n_fields * S(48) + S(4);
            const ch_h = std.math.clamp(want_h, row_h, (y1 - y0) * 0.32);
            c.igSetCursorScreenPos(v2(inner_x, top));
            c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
            _ = c.igBeginChild_Str("chanlist", v2(inner_w, ch_h), 0, 0);
            const ld = drawList();
            const fw = inner_w - S(16);
            if (a.new_chan_open) {
                c.igSetCursorPosX(S(8));
                if (a.focus_new_chan) {
                    c.igSetKeyboardFocusHere(0);
                    a.focus_new_chan = false;
                }
                if (iconField(ld, "##chanin", ic.plus, "nome do canal (Enter entra)", &a.new_chan_buf, fw, false, col.blurple, 1)) {
                    const nm = std.mem.trim(u8, std.mem.sliceTo(&a.new_chan_buf, 0), " ");
                    if (nm.len > 0) a.askChannel(cl, nm, false);
                    @memset(&a.new_chan_buf, 0);
                    a.new_chan_open = false;
                }
                if (c.igIsItemActive() and c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) a.new_chan_open = false;
                c.igDummy(v2(0, S(4)));
            }
            // o canal pediu senha: pergunta aqui
            if (a.chan_pw_len > 0) {
                c.igSetCursorPosX(S(8));
                pushFont(font_semibold, 12);
                textColored(col.yellow, fmtZ("{s}  Senha do #{s}", .{ ic.lock, a.chan_pw_for[0..a.chan_pw_len] }));
                popFont();
                c.igSetCursorPosX(S(8));
                if (a.focus_chan_pw) {
                    c.igSetKeyboardFocusHere(0);
                    a.focus_chan_pw = false;
                }
                if (iconField(ld, "##chanpw", ic.lock, "senha (Enter entra, Esc desiste)", &a.chan_pw_buf, fw, true, col.yellow, 1)) {
                    const pw = std.mem.sliceTo(&a.chan_pw_buf, 0);
                    const nm = a.chan_pw_for[0..a.chan_pw_len];
                    if (a.chan_pw_call) cl.joinCall(nm, pw) else cl.joinChannel(nm, pw);
                    @memset(&a.chan_pw_buf, 0);
                    a.chan_pw_len = 0;
                }
                if (c.igIsItemActive() and c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) a.chan_pw_len = 0;
                c.igDummy(v2(0, S(4)));
            }
            // admin editando a senha ou o tópico de um canal
            if (a.chan_edit != .none) {
                const pw_edit = a.chan_edit == .password;
                c.igSetCursorPosX(S(8));
                pushFont(font_semibold, 12);
                textColored(col.muted, if (pw_edit) fmtZ("Senha nova do #{s} (vazio = sem senha)", .{a.chan_edit_for[0..a.chan_edit_len]}) else fmtZ("Tópico do #{s} (vazio = sem tópico)", .{a.chan_edit_for[0..a.chan_edit_len]}));
                popFont();
                c.igSetCursorPosX(S(8));
                if (a.focus_chan_edit) {
                    c.igSetKeyboardFocusHere(0);
                    a.focus_chan_edit = false;
                }
                if (iconField(ld, "##chanedit", if (pw_edit) ic.lock else ic.pen, "Enter salva, Esc desiste", &a.chan_edit_buf, fw, pw_edit, col.blurple, 1)) {
                    cl.chanAdmin(if (pw_edit) proto.chan_act_password else proto.chan_act_topic, a.chan_edit_for[0..a.chan_edit_len], std.mem.sliceTo(&a.chan_edit_buf, 0), 0);
                    @memset(&a.chan_edit_buf, 0);
                    a.chan_edit = .none;
                }
                if (c.igIsItemActive() and c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) a.chan_edit = .none;
                c.igDummy(v2(0, S(4)));
            }
            for (chans[0..n_chans], 0..) |*ch, i| {
                const name = ch.nameSlice();
                const here = std.mem.eql(u8, name, cur);
                const call_here = calls_known and std.mem.eql(u8, name, my_call);
                c.igSetCursorPosX(S(6));
                const p = c.igGetCursorScreenPos();
                const rw = inner_w - S(12);
                const cb = S(30); // botão da call, na direita
                var lb: [64]u8 = undefined;
                const id = std.fmt.bufPrintZ(&lb, "#{s}###ch{d}", .{ name, i }) catch "###ch";
                const clicked = c.igInvisibleButton(id.ptr, v2(rw - (if (calls_known) cb else 0), row_h - S(2)), 0);
                const hov = c.igIsItemHovered(0);
                if (i_am_admin and c.igIsItemClicked(1)) {
                    a.chan_menu_len = @min(name.len, a.chan_menu.len);
                    @memcpy(a.chan_menu[0..a.chan_menu_len], name[0..a.chan_menu_len]);
                    a.chan_menu_flags = ch.flags;
                    _ = c.igOpenPopup_Str("##chanmenu", 0);
                }
                if (here) {
                    rectFill(ld, p.x, p.y, p.x + rw, p.y + row_h - S(2), withAlpha(col.blurple, 55), S(8));
                    rectFill(ld, p.x, p.y + S(6), p.x + S(3), p.y + row_h - S(8), col.blurple, S(2));
                } else if (hov) rectFill(ld, p.x, p.y, p.x + rw, p.y + row_h - S(2), col.hover, S(8));
                const ty = p.y + (row_h - S(2) - S(17)) / 2;
                drawTextF(ld, font_bold, 14, v2(p.x + S(12), ty), if (here) col.blurple else col.faint, "#");
                var nx = p.x + S(26);
                drawTextF(ld, if (here) font_bold else font_semibold, 14, v2(nx, ty), if (here) col.header else if (hov) col.text else col.muted, name);
                nx += textSizeF(if (here) font_bold else font_semibold, 14, name).x + S(6);
                if (ch.flags & proto.chan_locked != 0) {
                    drawTextF(ld, font_regular, 10, v2(nx, ty + S(3)), col.yellow, ic.lock);
                    nx += S(14);
                } else if (ch.flags & proto.chan_password != 0) {
                    drawTextF(ld, font_regular, 10, v2(nx, ty + S(3)), col.faint, ic.lock);
                    nx += S(14);
                }
                // na direita: o botão da call (quantos nela), quem está no chat e se tem alguém ao vivo
                var rx = p.x + rw - S(6);
                if (calls_known) {
                    rx -= cb;
                    c.igSetCursorScreenPos(v2(rx, p.y - S(1)));
                    const call_tip = if (call_here) tr("Sair da call") else tr("Entrar na call desse canal (a voz e as transmissões)");
                    const tint = if (call_here) col.green else col.faint;
                    if (iconButton(fmtZ("##call{d}", .{i}), ic.headphones, cb, tint, col.hover, call_tip)) {
                        if (call_here) cl.joinCall("", "") else a.askChannel(cl, name, true);
                    }
                    if (ch.in_call > 0) {
                        const cnt = fmtZ("{d}", .{ch.in_call});
                        const cw = textSizeF(font_bold, 10, cnt).x;
                        c.ImDrawList_AddCircleFilled(ld, v2(rx + cb - S(7), p.y + S(6)), S(7), if (call_here) col.green else col.input, 0);
                        drawTextF(ld, font_bold, 10, v2(rx + cb - S(7) - cw / 2, p.y + S(6) - S(7)), if (call_here) col.white else col.text, cnt);
                    }
                    rx -= S(4);
                }
                if (ch.people > 0) {
                    const cnt = fmtZ("{d}", .{ch.people});
                    const cw = textSizeF(font_semibold, 12, cnt).x;
                    rx -= cw;
                    drawTextF(ld, font_semibold, 12, v2(rx, ty + S(1)), col.muted, cnt);
                    const us = textSizeF(font_regular, 11, ic.comments);
                    rx -= us.x + S(5);
                    drawTextF(ld, font_regular, 11, v2(rx, ty + S(2)), col.faint, ic.comments);
                }
                if (ch.flags & proto.chan_live != 0) {
                    rx -= S(14);
                    c.ImDrawList_AddCircleFilled(ld, v2(rx + S(4), p.y + (row_h - S(2)) / 2), S(4), col.red, 0);
                }
                if (hov and !here) tooltipText(if (ch.topic_len > 0) fmtZ("Ler o chat do #{s}\n{s}", .{ name, ch.topicSlice() }) else fmtZ("Ler o chat do #{s}", .{name}));
                if (clicked and !here) a.askChannel(cl, name, false);
                c.igSetCursorScreenPos(v2(p.x, p.y + row_h));
                c.igDummy(v2(rw, 0));
            }
            a.chanMenu(cl);
            c.igEndChild();
            c.igPopStyleColor(1);
            top += ch_h + S(6);
            rectFill(d, inner_x + S(10), top, inner_x + inner_w - S(10), top + S(1), withAlpha(col.text, 18), 0);
            top += S(12);
        }

        // quem está no canal de texto; embaixo, quem está na minha call e não
        // está aqui no chat (a call é de outro canal, ou a pessoa foi ler outro)
        var w_call: usize = 0;
        for (call_ppl[0..n_call]) |m| {
            const in_chat = for (chat_ppl[0..n_chat]) |x| {
                if (x.id == m.id) break true;
            } else false;
            if (!in_chat) {
                call_ppl[w_call] = m;
                w_call += 1;
            }
        }
        n_call = w_call;
        const same_call = std.mem.eql(u8, my_call, cur);
        const other_call = has_chans and calls_known and call_len > 0 and n_call > 0;
        const hdr = if (has_chans) fmtZ("EM #{s} · {d}", .{ cur, n_chat }) else fmtZ("NA SALA · {d}", .{n_chat});
        drawTextF(d, font_bold, 11, v2(inner_x + S(12), top), col.muted, hdr);
        const row_h = S(42);
        const rows: f32 = @floatFromInt(n_chat + (if (other_call) n_call + 1 else 0));
        const want_h = row_h * rows + S(8);
        const list_top = top + S(22);
        const list_h = std.math.clamp(want_h, S(60), @max(S(60), (y1 - list_top) * 0.45));
        c.igSetCursorScreenPos(v2(inner_x, list_top));
        c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
        _ = c.igBeginChild_Str("lists", v2(inner_w, list_h), 0, 0);
        for (chat_ppl[0..n_chat]) |*m| a.memberRow(m, my_id, inner_w, i_am_admin);
        if (other_call) {
            c.igDummy(v2(0, S(6)));
            c.igSetCursorPosX(S(12));
            pushFont(font_bold, 11);
            textColored(col.green, if (same_call) fmtZ("{s}  NA CALL, LENDO OUTRO CANAL · {d}", .{ ic.headphones, n_call }) else fmtZ("{s}  NA CALL #{s} · {d}", .{ ic.headphones, my_call, n_call }));
            popFont();
            c.igDummy(v2(0, S(2)));
            for (call_ppl[0..n_call]) |*m| a.memberRow(m, my_id, inner_w, i_am_admin);
        }
        // o menu de alguém (clique direito) vale pras duas listas
        var all: [128]Member = undefined;
        var n_all: usize = 0;
        for (chat_ppl[0..n_chat]) |m| {
            all[n_all] = m;
            n_all += 1;
        }
        for (call_ppl[0..n_call]) |m| {
            const dup = for (all[0..n_all]) |x| {
                if (x.id == m.id) break true;
            } else false;
            if (!dup) {
                all[n_all] = m;
                n_all += 1;
            }
        }
        a.memberMenu(cl, all[0..n_all]);
        c.igEndChild();
        c.igPopStyleColor(1);
        const div_y = list_top + list_h + S(6);
        rectFill(d, inner_x + S(10), div_y, inner_x + inner_w - S(10), div_y + S(1), withAlpha(col.text, 18), 0);

        // chat
        c.igSetCursorScreenPos(v2(inner_x, div_y + S(2)));
        a.drawChat(cl, v2(inner_w, y1 - div_y - S(6)));
    }

    /// Cápsula de controles embaixo do palco: você, microfone, surdo,
    /// compartilhar, câmera e sair. Fica num espaço só dela (não cobre vídeo).
    fn drawDock(a: *App, cl: *Client, o: c.ImVec2_c, size: c.ImVec2_c) void {
        const d = drawList();
        cl.mutex.lock();
        const my_id = cl.my_id;
        // call separada do canal: botão de entrar/sair da call do lado do surdo
        const calls = cl.chans_supported and cl.calls_known;
        const in_call = cl.call_name_len > 0;
        var call_buf: [proto.channel_name_max]u8 = undefined;
        const call_len = cl.call_name_len;
        @memcpy(call_buf[0..call_len], cl.call_name[0..call_len]);
        var text_buf: [proto.channel_name_max]u8 = undefined;
        const text_len = cl.chan_name_len;
        @memcpy(text_buf[0..text_len], cl.chan_name[0..text_len]);
        cl.mutex.unlock();
        const live = a.sharer != null;
        const h = S(58);
        const bs = S(42);
        const extra: f32 = if (calls) bs + S(6) else 0;
        // janela estreita: primeiro some o perfil, depois o texto do compartilhar
        const btns_w = bs * 2 + S(6) + S(16) + S(16) + bs * 2 + S(6) + S(20) + extra;
        const full_share = if (live) S(232) else S(200);
        const show_prof = size.x - S(16) >= btns_w + full_share + S(176) + S(12);
        const prof_w: f32 = if (show_prof) S(176) else 0;
        const share_w = if (size.x - S(16) >= btns_w + full_share + prof_w) full_share else S(56);
        const w = S(10) + (if (show_prof) prof_w + S(12) else 0) + bs * 2 + S(6) + S(16) + share_w + S(16) + bs * 2 + S(6) + S(10) + extra;
        const x0 = o.x + @max(S(8), (size.x - w) / 2);
        const y0 = o.y + size.y - h - S(14);
        rectFill(d, x0, y0 + S(4), x0 + w, y0 + h + S(4), rgba(0x000000, 70), h / 2);
        rectFill(d, x0, y0, x0 + w, y0 + h, col.bg_user, h / 2);
        c.ImDrawList_AddRect(d, v2(x0, y0), v2(x0 + w, y0 + h), withAlpha(col.text, 22), h / 2 * col.round, S(1), 0);

        // você
        var x = x0 + S(10);
        if (show_prof) {
            const me_speaking = if (a.mic) |m| m.speaking.load(.monotonic) else false;
            drawAvatarSpeaking(d, v2(x + S(20), y0 + h / 2), S(17), my_id, a.myName(), live, me_speaking);
            if (me_speaking) redrawIn(0.15);
            var name_buf: [32]u8 = undefined;
            const nm = a.myName();
            const shown = if (nm.len > 13) std.fmt.bufPrint(&name_buf, "{s}…", .{nm[0..11]}) catch nm else nm;
            drawTextF(d, font_semibold, 14, v2(x + S(46), y0 + S(11)), col.header, shown);
            var status_text: []const u8 = tr("Online");
            var status_col = col.muted;
            if (a.sharer) |s| {
                s.mutex.lock();
                const st = s.state;
                s.mutex.unlock();
                status_text = if (st == .starting) tr("Iniciando...") else tr("Ao vivo");
                status_col = if (st == .starting) col.yellow else col.red;
            }
            if (a.sharer == null and calls) {
                status_text = if (in_call) fmtZ("Na call #{s}", .{call_buf[0..call_len]}) else tr("Fora da call");
                status_col = if (in_call) col.green else col.muted;
            }
            if (a.admin_muted) {
                status_text = tr("Silenciado pelo admin");
                status_col = col.red;
            }
            drawTextF(d, font_regular, 12, v2(x + S(46), y0 + S(31)), status_col, status_text);
            x += prof_w;
            rectFill(d, x + S(4), y0 + S(14), x + S(5), y0 + h - S(14), withAlpha(col.text, 22), 0);
            x += S(12);
        }

        // microfone e surdo
        const by = y0 + (h - bs) / 2;
        c.igSetCursorScreenPos(v2(x, by));
        const mic_on = a.mic != null;
        const mic_tip: [:0]const u8 = if (a.admin_muted) tr("O admin silenciou seu microfone") else if (mic_on) tr("Desligar o microfone") else tr("Ligar o microfone");
        if (iconButton("##mic", if (mic_on) ic.mic else ic.mic_slash, bs, if (mic_on) col.text else col.red, col.hover, mic_tip)) a.toggleMic(via_clique);
        x += bs + S(6);
        c.igSetCursorScreenPos(v2(x, by));
        if (iconButton("##deaf", ic.headphones, bs, if (a.deaf) col.red else col.text, col.hover, if (a.deaf) tr("Voltar a ouvir a sala") else tr("Parar de ouvir a sala (surdo)"))) a.toggleDeaf(via_clique);
        if (a.deaf) slash(d, v2(x, by), bs);
        x += bs;
        if (calls) {
            x += S(6);
            c.igSetCursorScreenPos(v2(x, by));
            const tip = if (in_call) fmtZ("Sair da call do #{s}", .{call_buf[0..call_len]}) else fmtZ("Entrar na call do #{s}", .{text_buf[0..text_len]});
            if (iconButton("##callbtn", if (in_call) ic.phone_slash else ic.phone, bs, if (in_call) col.red else col.green, col.hover, tip)) {
                if (in_call) cl.joinCall("", "") else a.askChannel(cl, text_buf[0..text_len], true);
            }
            x += bs;
        }
        x += S(16);

        // compartilhar
        const sh = S(40);
        c.igSetCursorScreenPos(v2(x, y0 + (h - sh) / 2));
        const lbl = if (share_w < full_share) fmtZ("{s}##share", .{ic.desktop}) else if (live) fmtZ("{s}  Ao vivo (configurar)##share", .{ic.desktop}) else fmtZ("{s}  Compartilhar tela##share", .{ic.desktop});
        c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameRounding, sh / 2 * col.round);
        if (if (live)
            primaryButton(lbl, v2(share_w, sh), col.red, col.red_hover, col.red_active)
        else
            primaryButton(lbl, v2(share_w, sh), col.blurple, col.blurple_hover, col.blurple_active)) a.openShareModal();
        c.igPopStyleVar(1);
        if (share_w < full_share and c.igIsItemHovered(0)) tooltipText(if (live) tr("Ao vivo (configurar)") else tr("Compartilhar tela"));
        x += share_w + S(16);

        // câmera e sair
        c.igSetCursorScreenPos(v2(x, by));
        const cam_on = a.camera != null;
        if (iconButton("##camera", if (cam_on) ic.video else ic.video_slash, bs, if (cam_on) col.green else col.text, col.hover, if (cam_on) tr("Desligar a câmera") else tr("Ligar a câmera"))) a.toggleCamera();
        x += bs + S(6);
        c.igSetCursorScreenPos(v2(x, by));
        if (iconButton("##leave", ic.leave, bs, col.red, withAlpha(col.red, 40), if (a.server != null) tr("Fechar a sala") else tr("Sair da sala"))) a.askLeave();
    }

    /// Nome curto da rota (tabela das estatísticas).
    fn routeShort(route: u8) [:0]const u8 {
        return switch (route) {
            proto.route_local => tr("esta máquina"),
            proto.route_lan => tr("rede local"),
            proto.route_internet => tr("internet"),
            proto.route_internet6 => tr("IPv6"),
            proto.route_tunnel => tr("link público"),
            else => "?",
        };
    }

    fn routeText(route: u8) [:0]const u8 {
        return switch (route) {
            proto.route_local => tr("Nessa mesma máquina"),
            proto.route_lan => tr("Rede local (ou VPN tipo Tailscale)"),
            proto.route_internet => tr("Direto pela internet (IPv4)"),
            proto.route_internet6 => tr("Direto pela internet (IPv6)"),
            proto.route_tunnel => tr("Pelo link público (túnel)"),
            proto.route_web => tr("Assistindo pelo navegador"),
            else => "",
        };
    }

    fn routeIcon(route: u8) []const u8 {
        return switch (route) {
            proto.route_local => ic.laptop,
            proto.route_lan => ic.house,
            proto.route_tunnel => ic.globe,
            proto.route_web => ic.tv,
            proto.route_internet, proto.route_internet6 => ic.link,
            else => "",
        };
    }

    fn memberRow(a: *App, m: *const Member, my_id: u32, width: f32, i_am_admin: bool) void {
        const d = drawList();
        const h = S(42);
        c.igPushID_Int(@intCast(m.id));
        defer c.igPopID();
        c.igSetCursorPosX(S(8));
        const p = c.igGetCursorScreenPos();
        const row_w = width - S(16);
        _ = c.igInvisibleButton("m", v2(row_w, h), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);
        const hovered = c.igIsItemHovered(0);
        if (a.n_member_rects < a.member_rects.len) {
            a.member_rects[a.n_member_rects] = .{ .id = m.id, .x0 = p.x, .y0 = p.y, .x1 = p.x + row_w, .y1 = p.y + h };
            a.n_member_rects += 1;
        }
        if (hovered) rectFill(d, p.x, p.y, p.x + row_w, p.y + h, col.hover, S(6));
        if (hovered) {
            var tip: [200]u8 = undefined;
            const route = routeText(m.route);
            const action: []const u8 = if (m.id == my_id) "" else if (i_am_admin) tr("Clique direito: volume da voz e ações de admin") else tr("Clique direito: volume da voz");
            const t = std.fmt.bufPrintZ(&tip, "{s}{s}{s}{s}", .{
                if (route.len > 0) tr("Conectado: ") else "", route, if (route.len > 0 and action.len > 0) "\n" else "", action,
            }) catch "";
            if (t.len > 0) tooltipText(t);
            if (m.id != my_id and c.igIsItemClicked(1)) {
                a.menu_target = m.id;
                a.open_member_menu = true; // abre fora do PushID do membro
            }
        }
        const speaking = if (m.id == my_id)
            (if (a.mic) |mc| mc.speaking.load(.monotonic) else false)
        else if (a.client) |cl| cl.speaking(m.id) else false;
        drawAvatarSpeaking(d, v2(p.x + S(22), p.y + h / 2), S(15), m.id, m.nameSlice(), m.streaming, speaking);
        if (speaking) redrawIn(0.15); // a bolinha apaga sozinha quando a pessoa para
        const name_col = if (m.id == my_id) col.header else col.text;
        drawTextF(d, font_semibold, 14.5, v2(p.x + S(46), p.y + (h - S(18)) / 2), name_col, m.nameSlice());
        const ns = textSizeF(font_semibold, 14.5, m.nameSlice());
        var tx = p.x + S(50) + ns.x;
        if (m.bot) tx += botBadge(d, v2(tx, p.y + (h - S(14)) / 2)) + S(6);
        if (m.owner) {
            drawTextF(d, font_regular, 11, v2(tx, p.y + (h - S(13)) / 2), col.yellow, ic.crown);
            tx += S(18);
        } else if (m.admin) {
            drawTextF(d, font_regular, 11, v2(tx, p.y + (h - S(13)) / 2), col.blurple, ic.shield);
            tx += S(18);
        }
        if (m.id == my_id) drawTextF(d, font_regular, 12, v2(tx, p.y + (h - S(15)) / 2), col.faint, tr("(você)"));
        var rx = p.x + row_w - S(10);
        if (m.streaming) rx -= liveBadge(d, v2(rx - liveBadgeWidth(), p.y + (h - S(15)) / 2)) + S(14);
        // câmera, microfone desligado / silenciado pelo admin, surdo, rota
        const iy = p.y + (h - S(14)) / 2;
        if (m.camera()) {
            const gs = textSizeF(font_regular, 13, ic.video);
            rx -= gs.x;
            drawTextF(d, font_regular, 13, v2(rx, iy), col.green, ic.video);
            rx -= S(8);
        }
        if (m.deaf()) {
            const gs = textSizeF(font_regular, 13, ic.headphones);
            rx -= gs.x;
            drawTextF(d, font_regular, 13, v2(rx, iy), col.red, ic.headphones);
            slash(d, v2(rx - S(2), iy - S(2)), gs.x + S(4));
            rx -= S(8);
        }
        if (m.muted()) {
            const gs = textSizeF(font_regular, 13, ic.mic_slash);
            rx -= gs.x;
            drawTextF(d, font_regular, 13, v2(rx, iy), col.red, ic.mic_slash);
            rx -= S(8);
        } else if (!m.micOn()) {
            const gs = textSizeF(font_regular, 13, ic.mic_slash);
            rx -= gs.x;
            drawTextF(d, font_regular, 13, v2(rx, iy), col.faint, ic.mic_slash);
            rx -= S(8);
        }
        if (m.route == proto.route_tunnel or m.route == proto.route_local) {
            const glyph = routeIcon(m.route);
            const gs = textSizeF(font_regular, 11, glyph);
            rx -= gs.x;
            drawTextF(d, font_regular, 11, v2(rx, iy + S(1)), col.faint, glyph);
        }
    }

    fn memberMenu(a: *App, cl: *Client, members: []const Member) void {
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(8), S(8)));
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_float);
        defer {
            c.igPopStyleColor(1);
            c.igPopStyleVar(1);
        }
        if (a.open_member_menu) {
            _ = c.igOpenPopup_Str("membermenu", 0);
            a.open_member_menu = false;
        }
        if (!c.igBeginPopup("membermenu", 0)) return;
        defer c.igEndPopup();
        const target = for (members) |*m| {
            if (m.id == a.menu_target) break m;
        } else {
            // a pessoa saiu com o menu aberto
            c.igCloseCurrentPopup();
            return;
        };
        const name = target.nameSlice();
        pushFont(font_semibold, 13);
        textColored(col.muted, name);
        popFont();
        if (target.id != cl.my_id and cl.server_features & proto.srv_dm != 0 and
            c.igSelectable_Bool(fmtZ("{s}  Mensagem privada###mdmember", .{ic.lock}), false, 0, v2(S(220), 0)))
        {
            a.startDm(target.id, name);
            a.cfg.show_chat = true;
            a.focus_chat = true;
            c.igCloseCurrentPopup();
        }
        const route = routeText(target.route);
        if (route.len > 0) {
            pushFont(font_regular, 12);
            textColored(col.faint, route);
            popFont();
        }
        c.igDummy(v2(0, S(4)));
        // volume da voz dessa pessoa, só pra mim (0–200%)
        textColored(col.faint, tr("Volume da voz"));
        var pct: i32 = @intFromFloat(@round(cl.voiceVolume(a.menu_target) * 100));
        const before = pct;
        sliderStyled("##vvol", &pct, 0, 200, "%d%%", S(220));
        // salva no arquivo quando solta o slider (não a cada quadro do arrasto)
        var save = c.igIsItemDeactivatedAfterEdit();
        var new_pct: ?i32 = if (pct != before) pct else null;
        const muted = pct == 0;
        c.igDummy(v2(0, S(4)));
        if (c.igSelectable_Bool(if (muted) tr("Voltar a ouvir###vmute") else tr("Silenciar pra mim###vmute"), false, 0, v2(S(220), 0))) {
            new_pct = if (muted) 100 else 0;
            save = true;
        }
        if (new_pct) |np| cl.setVoiceVolume(a.menu_target, @as(f32, @floatFromInt(std.math.clamp(np, 0, 200))) / 100);
        if (save) {
            // lembra pelo nome (vale na próxima sala também)
            const v: u16 = @intCast(std.math.clamp(@as(i32, @intFromFloat(@round(cl.voiceVolume(a.menu_target) * 100))), 0, 200));
            a.volumes.set(name, v);
            a.volumes.save();
        }
        // ações de admin: dono pode tudo; admin promovido não mexe em admin
        cl.mutex.lock();
        const i_am_admin = cl.is_admin;
        const my_id = cl.my_id;
        cl.mutex.unlock();
        const me = for (members) |*m| {
            if (m.id == my_id) break m;
        } else null;
        const i_am_owner = me != null and me.?.owner;
        if (!i_am_admin or target.owner or (target.admin and !i_am_owner)) return;
        c.igDummy(v2(0, S(4)));
        c.igSeparator();
        c.igDummy(v2(0, S(2)));
        pushFont(font_bold, 11);
        textColored(col.muted, tr("ADMIN"));
        popFont();
        const w = S(220);
        if (c.igSelectable_Bool(if (target.muted()) fmtZ("{s}  Liberar o microfone###amute", .{ic.mic}) else fmtZ("{s}  Silenciar o microfone (pra todos)###amute", .{ic.mic_slash}), false, 0, v2(w, 0)))
            cl.admin(proto.admin_mute, target.id, @intFromBool(!target.muted()));
        if (target.streaming and c.igSelectable_Bool(fmtZ("{s}  Parar a transmissão###astop", .{ic.stop}), false, 0, v2(w, 0)))
            cl.admin(proto.admin_stop_stream, target.id, proto.kind_screen);
        if (target.camera() and c.igSelectable_Bool(fmtZ("{s}  Desligar a câmera###acam", .{ic.video_slash}), false, 0, v2(w, 0)))
            cl.admin(proto.admin_stop_stream, target.id, proto.kind_camera);
        if (i_am_owner and c.igSelectable_Bool(if (target.admin) fmtZ("{s}  Tirar o admin###aadmin", .{ic.shield}) else fmtZ("{s}  Dar admin###aadmin", .{ic.shield}), false, 0, v2(w, 0)))
            cl.admin(proto.admin_set_admin, target.id, @intFromBool(!target.admin));
        c.igPushStyleColor_U32(c.ImGuiCol_Text, col.red);
        if (c.igSelectable_Bool(if (target.noDraw()) fmtZ("{s}  Devolver o pincel###adraw", .{ic.pen}) else fmtZ("{s}  Tirar o pincel (apaga os desenhos)###adraw", .{ic.pen}), false, 0, v2(w, 0)))
            cl.admin(proto.admin_draw, target.id, @intFromBool(target.noDraw()));
        // levar pra outro canal (o chat e a call)
        if (cl.chans_supported and c.igBeginMenu(fmtZ("{s}  Levar pro canal###amove", .{ic.arrow_right}), true)) {
            cl.mutex.lock();
            var names: [proto.max_channels][proto.channel_name_max]u8 = undefined;
            var lens: [proto.max_channels]usize = undefined;
            const nch = cl.n_chans;
            for (cl.chans[0..nch], 0..) |*ch, i| {
                lens[i] = ch.name_len;
                @memcpy(names[i][0..ch.name_len], ch.nameSlice());
            }
            cl.mutex.unlock();
            for (0..nch) |i| {
                if (c.igMenuItem_Bool(fmtZ("#{s}###mv{d}", .{ names[i][0..lens[i]], i }), null, false, true)) cl.chanAdmin(proto.chan_act_move, names[i][0..lens[i]], "", target.id);
            }
            c.igEndMenu();
        }
        if (c.igSelectable_Bool(fmtZ("{s}  Expulsar da sala###akick", .{ic.ban}), false, 0, v2(w, 0))) cl.admin(proto.admin_kick, target.id, 0);
        if (c.igSelectable_Bool(fmtZ("{s}  Banir (não volta mais)###aban", .{ic.gavel}), false, 0, v2(w, 0))) cl.admin(proto.admin_ban, target.id, 0);
        c.igPopStyleColor(1);
    }

    fn drawUpnpState(a: *App, m: *upnp.Mapper, d: *c.ImDrawList, inner: f32) void {
        const st = m.status();
        const bh = S(38);
        switch (st.state) {
            .working => {
                spinnerTitle(d, tr("Pedindo pro roteador abrir a porta…"));
                wrapText(col.muted, 13, tr("Procurando o roteador na rede (UPnP). Leva uns segundos."), inner);
                c.igDummy(v2(0, S(2)));
                if (secondaryButton(tr("Cancelar##upnp"), v2(S(120), bh))) a.stopUpnp();
            },
            .ready => {
                var abuf: [64]u8 = undefined;
                cardTitle(d, ic.tower, col.green, tr("Porta aberta no roteador"));
                wrapText(col.muted, 13, tr("Conexão direta, sem túnel. Manda o convite pra galera:"), inner);
                addrBox(d, m.address(&abuf), inner);
                const half = (inner - S(10)) / 2;
                if (primaryButton(fmtZ("{s}  Copiar convite##upnp", .{ic.user_plus}), v2(half, bh), col.blurple, col.blurple_hover, col.blurple_active)) a.copyInvite();
                c.igSameLine(0, S(10));
                if (secondaryButton(fmtZ("{s}  Fechar porta###upnpclose", .{ic.power}), v2(half, bh))) a.stopUpnp();
            },
            .failed => {
                cardTitle(d, ic.warn, col.red, tr("Não deu pra abrir a porta"));
                var eb: [300]u8 = undefined;
                wrapText(col.muted, 12.5, i18n.dynamic(st.err, &eb), inner);
                c.igDummy(v2(0, S(2)));
                if (primaryButton(fmtZ("{s}  Criar link público##upnp", .{ic.globe}), v2(S(210), bh), col.blurple, col.blurple_hover, col.blurple_active)) {
                    a.stopUpnp();
                    a.startTunnel();
                }
                c.igSameLine(0, S(10));
                if (secondaryButton(tr("Fechar##upnp"), v2(S(110), bh))) a.stopUpnp();
            },
        }
    }

    /// Todos os caminhos pra essa sala, em ordem de preferência (cada pessoa
    /// entra pelo mais rápido que funcionar pra ela, ver connect.zig).
    fn inviteAddrs(a: *App, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var n: usize = 0;
        const sep = struct {
            fn put(wr: *std.Io.Writer, count: *usize) void {
                if (count.* > 0) wr.writeByte(',') catch {};
                count.* += 1;
            }
        }.put;
        const srv = a.server orelse {
            // quem entrou: passa adiante os caminhos que usou
            w.writeAll(config.getStr(&a.cfg.join_addr)) catch {};
            return w.buffered();
        };
        const port = srv.port;
        // 1. rede local (mesmo Wi-Fi: o mais rápido; de fora, falha rápido)
        if (net.primaryIp4()) |ip| {
            sep(&w, &n);
            w.print("{d}.{d}.{d}.{d}:{d}", .{ ip[0], ip[1], ip[2], ip[3], port }) catch {};
        }
        // 2. porta aberta no roteador
        if (a.upnp) |m| {
            var ub: [64]u8 = undefined;
            const ua = m.address(&ub);
            if (ua.len > 0) {
                sep(&w, &n);
                w.writeAll(ua) catch {};
            }
        }
        // 3. IPv6 direto (sem CGNAT; o roteador pode bloquear, aí esse falha e os outros seguem)
        var v6: [2][16]u8 = undefined;
        const n6 = net.globalIp6(&v6);
        for (v6[0..n6]) |ip| {
            var fb: [48]u8 = undefined;
            sep(&w, &n);
            w.print("{s}:{d}", .{ net.fmtIp6(ip, &fb), port }) catch {};
        }
        // 4. túnel digitado (ngrok etc.)
        const typed = std.mem.trim(u8, config.getStr(&a.cfg.public_addr), " ");
        if (typed.len > 0 and a.tunnel == null) {
            sep(&w, &n);
            w.writeAll(typed) catch {};
        }
        // 5. link público (funciona em qualquer rede: fica por último)
        if (a.tunnel) |t| {
            var tb: [300]u8 = undefined;
            const ta = t.address(&tb);
            if (ta.len > 0) {
                sep(&w, &n);
                w.writeAll(ta) catch {};
            }
        }
        return w.buffered();
    }

    /// O convite tem algum caminho que funciona de fora (não só rede local)?
    fn inviteReachesOutside(a: *App) bool {
        if (a.server == null) return true;
        if (a.tunnel) |t| if (t.status().state == .ready) return true;
        if (a.upnp) |m| if (m.status().state == .ready) return true;
        if (std.mem.trim(u8, config.getStr(&a.cfg.public_addr), " ").len > 0) return true;
        var v6: [1][16]u8 = undefined;
        return net.globalIp6(&v6) > 0;
    }

    /// O link da página do servidor pra assistir no navegador, com a senha e o
    /// canal no fim (depois do "#": não vai pro servidor nem pro túnel no pedido).
    fn copyWebLink(a: *App, cl: *Client) void {
        var lb: [300]u8 = undefined;
        var cb: [proto.channel_name_max]u8 = undefined;
        cl.mutex.lock();
        const link = lb[0..cl.web_link_len];
        @memcpy(link, cl.web_link[0..cl.web_link_len]);
        const chan = cb[0..cl.chan_name_len];
        @memcpy(chan, cl.chan_name[0..cl.chan_name_len]);
        cl.mutex.unlock();
        const pass = if (a.server != null) config.getStr(&a.cfg.host_pass) else config.getStr(&a.cfg.join_pass);
        var out: [1200]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        w.print("{s}/#", .{std.mem.trimEnd(u8, link, "/")}) catch return;
        if (pass.len > 0) {
            w.writeAll("s=") catch return;
            percentEncode(&w, pass) catch return;
            w.writeByte('&') catch return;
        }
        w.writeAll("c=") catch return;
        percentEncode(&w, chan) catch return;
        w.writeByte(0) catch return;
        const z = w.buffered();
        c.igSetClipboardText(@ptrCast(z.ptr));
        a.toast("Link copiado: quem abrir assiste pelo navegador, sem instalar nada.", .{}, false);
    }

    fn copyInvite(a: *App) void {
        var addr_buf: [600]u8 = undefined;
        const addrs = a.inviteAddrs(&addr_buf);
        if (addrs.len == 0) {
            a.toast("Não achei nenhum endereço dessa sala. Cria o link público no card \"Chamando a galera de fora\".", .{}, true);
            return;
        }
        const pass = if (a.server != null) config.getStr(&a.cfg.host_pass) else config.getStr(&a.cfg.join_pass);
        // fora do canal padrão (o primeiro da lista): o convite leva pro canal
        var chan_buf: [proto.channel_name_max + 1]u8 = undefined;
        var chan: []const u8 = "";
        if (a.client) |cl| {
            cl.mutex.lock();
            if (cl.chans_supported and cl.n_chans > 0 and !std.mem.eql(u8, cl.chans[0].nameSlice(), cl.chan_name[0..cl.chan_name_len]))
                chan = std.fmt.bufPrint(&chan_buf, "/{s}", .{cl.chan_name[0..cl.chan_name_len]}) catch "";
            cl.mutex.unlock();
        }
        // a identidade do servidor: quem receber confere que é ele mesmo
        var fp_buf: [crypto.fp_len + 1]u8 = undefined;
        var fp: []const u8 = "";
        if (a.server) |sv| {
            if (sv.fingerprint()) |f| fp = std.fmt.bufPrint(&fp_buf, "!{s}", .{&f}) catch "";
        } else if (a.client) |cl| {
            if (cl.id_state == .verified) fp = std.fmt.bufPrint(&fp_buf, "!{s}", .{&cl.server_fp}) catch "";
        }
        var buf: [800]u8 = undefined;
        const inv = (if (pass.len > 0)
            std.fmt.bufPrintZ(&buf, "telinha://{s}{s}{s}#{s}", .{ addrs, chan, fp, pass })
        else
            std.fmt.bufPrintZ(&buf, "telinha://{s}{s}{s}", .{ addrs, chan, fp })) catch return;
        c.igSetClipboardText(inv.ptr);
        const n_paths = std.mem.count(u8, addrs, ",") + 1;
        if (!a.inviteReachesOutside())
            a.toast("Convite copiado, mas só funciona na mesma rede. Pra galera de fora: link público ou porta no roteador.", .{}, true)
        else if (n_paths > 1)
            a.toast("Convite copiado ({d} caminhos: cada um entra pelo mais rápido que funcionar).", .{n_paths}, false)
        else
            a.toast("Convite copiado! Quem receber cola no campo de endereço.", .{}, false);
    }

    /// Liga/desliga os clipes das transmissões que já estão sendo assistidas.
    fn applyClips(a: *App) void {
        const cl = a.client orelse return;
        for (a.views.items) |v| {
            const on = a.cfg.clips;
            // (só liga em quem não tinha; desligar mantém o buffer até parar de assistir,
            // e pra de pedir IDR periódico)
            if (on and v.clip == null) v.clip = clip.Buffer.create() catch null;
            cl.sendWatch(v.stream, true, if (on) proto.watch_clips else 0);
        }
    }

    fn openSettings(a: *App) void {
        a.n_mic_names = @intCast(audio.c.audio_list_mics(&a.mic_names, a.mic_names.len));
        a.n_cams = @intCast(@max(0, c.cam_list(&a.cams, a.cams.len)));
        a.settings_modal = true;
    }

    fn openShareModal(a: *App) void {
        a.ensureInCall();
        a.n_sources = @intCast(c.cap_list_sources(&a.sources, a.sources.len));
        if (a.source_idx >= @as(i32, @intCast(a.n_sources))) a.source_idx = 0;
        a.n_audio_apps = audio.listApps(&a.audio_apps);
        a.share_modal = true;
    }

    // ------------------------------------------------------------ transmissões

    const Tile = struct {
        stream: u32, // minhas prévias: proto.streamId(0, tipo)
        tex: u32,
        tw: u32,
        th: u32,
        name: []const u8,
        stats: [:0]const u8,
        loading: bool,
        ring: ?*audio.Ring = null, // áudio dessa transmissão (null = sem áudio / minha prévia)
        view: ?*View = null, // null = minha prévia
        clipbuf: ?*clip.Buffer = null, // últimos 30 s + gravação dessa transmissão
        /// Stream de verdade (o ponteiro "olha aqui" vai com ele; nas minhas
        /// prévias é o meu id + tipo).
        ptr_stream: u32 = 0,
        cur_x: u16 = proto.coord_none, // ponta do cursor de quem transmite
        cur_y: u16 = proto.coord_none,
    };

    /// Zoom de uma transmissão (rodinha aproxima, arrastar move).
    const Zoom = struct {
        stream: u32 = 0,
        used: bool = false,
        z: f32 = 1, // 1 = inteira, até 8x
        cx: f32 = 0.5, // centro da vista, em coordenadas da imagem (0..1)
        cy: f32 = 0.5,
        follow: bool = false, // segue o cursor de quem transmite

        fn clamp(zm: *Zoom) void {
            zm.z = std.math.clamp(zm.z, 1, 8);
            const half = 0.5 / zm.z;
            zm.cx = std.math.clamp(zm.cx, half, 1 - half);
            zm.cy = std.math.clamp(zm.cy, half, 1 - half);
        }
    };

    fn zoomFor(a: *App, stream: u32) *Zoom {
        for (&a.zooms) |*zm| if (zm.used and zm.stream == stream) return zm;
        // vaga: uma sem uso, ou uma que está sem zoom
        for (&a.zooms) |*zm| if (!zm.used or (zm.z <= 1.001 and !zm.follow)) {
            zm.* = .{ .stream = stream, .used = true };
            return zm;
        };
        a.zooms[0] = .{ .stream = stream, .used = true };
        return &a.zooms[0];
    }

    fn drawMain(a: *App, cl: *Client, size: c.ImVec2_c) void {
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, if (a.theater) col.black else col.bg_main);
        _ = c.igBeginChild_Str("main", size, 0, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
        defer {
            c.igEndChild();
            c.igPopStyleColor(1);
        }
        const d = drawList();
        const o = c.igGetCursorScreenPos();
        if (!a.theater) {
            // palco: um degradê leve (o fundo não é chapado)
            c.ImDrawList_AddRectFilledMultiColor(d, o, v2(o.x + size.x, o.y + size.y), col.bg_main, col.bg_main, col.bg_dark, col.bg_dark);
        }
        // a cápsula de controles tem o espaço dela embaixo (nada fica por baixo)
        const dock_h: f32 = if (a.theater) 0 else S(86);
        defer if (!a.theater) a.drawDock(cl, o, size);

        // monta a lista de quadros
        var tiles: [33]Tile = undefined;
        var n: usize = 0;
        var stat_bufs: [33][128]u8 = undefined;
        var lat_bufs: [33][48]u8 = undefined;
        var name_bufs: [33][48]u8 = undefined;
        cl.mutex.lock();
        for (a.views.items) |v| {
            if (n >= tiles.len - 2) break; // os dois últimos são das minhas prévias (tela e câmera)
            // cópia: a thread de rede troca a lista de membros a qualquer hora
            const name = for (cl.members.items) |*m| {
                if (m.id == v.member()) {
                    break std.fmt.bufPrint(&name_bufs[n], "{s}{s}", .{ m.nameSlice()[0..@min(m.name_len, 32)], if (v.kind() == proto.kind_camera) tr(" (câmera)") else "" }) catch "?";
                }
            } else "?";
            const st = i18n.bufPrintZ(&stat_bufs[n], "{d}x{d} · {d:.0} fps · {d:.0} KB/s · {s}", .{ v.tex_w, v.tex_h, v.shownFps(), v.shownKbps(), latencyText(&lat_bufs[n], v) }) catch "";
            tiles[n] = .{
                .stream = v.stream,
                .tex = v.tex,
                .tw = v.tex_w,
                .th = v.tex_h,
                .name = name,
                .stats = st,
                .loading = v.tex == 0,
                .ring = if (v.audio_registered) &v.audio_ring else null,
                .view = v,
                .clipbuf = v.clip,
                .ptr_stream = v.stream,
                .cur_x = v.cursor_x.load(.monotonic),
                .cur_y = v.cursor_y.load(.monotonic),
            };
            n += 1;
        }
        const my_id = cl.my_id;
        cl.mutex.unlock();
        if (a.sharer) |s| {
            s.mutex.lock();
            const st = i18n.bufPrintZ(&stat_bufs[n], "{d}x{d} · {d:.0} fps · {d} kbit/s{s} · {s} {d:.1} ms · {s}", .{ s.w, s.h, s.shownFps(), s.bitrate_kbps, if (s.congested) tr(" (rede lenta)") else if (s.slow_viewer) tr(" (espectador lento)") else "", s.encoder_name, s.encode_ms, s.backendSlice() }) catch "";
            tiles[n] = .{ .stream = proto.streamId(0, proto.kind_screen), .tex = s.preview_tex, .tw = s.preview_w, .th = s.preview_h, .name = tr("Você"), .stats = st, .loading = s.preview_tex == 0, .ptr_stream = proto.streamId(my_id, proto.kind_screen), .clipbuf = s.clip };
            s.mutex.unlock();
            n += 1;
        }
        if (a.camera) |s| {
            s.mutex.lock();
            const st = i18n.bufPrintZ(&stat_bufs[n], "câmera · {d}x{d} · {d:.0} fps · {d} kbit/s · {s} · {s}", .{ s.w, s.h, s.shownFps(), s.bitrate_kbps, s.encoder_name, s.backendSlice() }) catch "";
            tiles[n] = .{ .stream = proto.streamId(0, proto.kind_camera), .tex = s.preview_tex, .tw = s.preview_w, .th = s.preview_h, .name = tr("Você (câmera)"), .stats = st, .loading = s.preview_tex == 0, .ptr_stream = proto.streamId(my_id, proto.kind_camera), .clipbuf = s.clip };
            s.mutex.unlock();
            n += 1;
        }

        const top_h: f32 = 0;
        const area_x = o.x + S(if (a.theater) 0 else 16);
        const area_y = o.y + top_h + S(if (a.theater) 0 else 16);
        const area_w = size.x - S(if (a.theater) 0 else 32);
        const area_h = size.y - top_h - S(if (a.theater) 0 else 32) - dock_h;

        if (n == 0) {
            a.drawEmpty(cl, v2(o.x, o.y + top_h), v2(size.x, size.y - top_h - dock_h));
            return;
        }

        // destaque: um grande + tira de miniaturas
        if (a.focused) |fo| {
            const fi = for (tiles[0..n], 0..) |t, i| {
                if (t.stream == fo) break i;
            } else null;
            if (fi) |idx| {
                const strip_h = if (n > 1 and !a.theater) S(130) else 0;
                const gap = if (strip_h > 0) S(12) else 0;
                a.drawTile(&tiles[idx], area_x, area_y, area_w, area_h - strip_h - gap, true);
                if (strip_h > 0) {
                    const tw = @min(S(230), (area_w - S(12) * @as(f32, @floatFromInt(n - 2))) / @as(f32, @floatFromInt(n - 1)));
                    var x = area_x + (area_w - (tw * @as(f32, @floatFromInt(n - 1)) + S(12) * @as(f32, @floatFromInt(n - 2)))) / 2;
                    for (tiles[0..n], 0..) |*t, i| {
                        if (i == idx) continue;
                        a.drawTile(t, x, area_y + area_h - strip_h, tw, strip_h, false);
                        x += tw + S(12);
                    }
                }
                return;
            }
            a.focused = null;
        }

        // grade automática: testa todas as quantidades de colunas e fica com a
        // que deixa os vídeos (16:9) maiores na tela
        const gap = S(12);
        var cols: usize = 1;
        var best_area: f32 = 0;
        for (1..n + 1) |cc| {
            const rr = (n + cc - 1) / cc;
            const cw = (area_w - gap * @as(f32, @floatFromInt(cc - 1))) / @as(f32, @floatFromInt(cc));
            const ch = (area_h - gap * @as(f32, @floatFromInt(rr - 1))) / @as(f32, @floatFromInt(rr));
            if (cw <= 0 or ch <= 0) continue;
            const vw = @min(cw, ch * 16.0 / 9.0);
            const area = vw * (vw * 9.0 / 16.0);
            if (area > best_area + 1) {
                best_area = area;
                cols = cc;
            }
        }
        const rows = (n + cols - 1) / cols;
        const tw = (area_w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        const th = (area_h - gap * @as(f32, @floatFromInt(rows - 1))) / @as(f32, @floatFromInt(rows));
        for (tiles[0..n], 0..) |*t, i| {
            const cx = i % cols;
            const cy = i / cols;
            // última linha centralizada
            const in_row = if (cy == rows - 1) n - cy * cols else cols;
            const row_off = (area_w - (tw * @as(f32, @floatFromInt(in_row)) + gap * @as(f32, @floatFromInt(in_row - 1)))) / 2;
            a.drawTile(t, area_x + row_off + @as(f32, @floatFromInt(cx)) * (tw + gap), area_y + @as(f32, @floatFromInt(cy)) * (th + gap), tw, th, false);
        }
    }

    fn latencyText(buf: *[48]u8, v: *const View) []const u8 {
        // sem quadro novo: diz há quanto tempo (tela parada de quem transmite,
        // ou a imagem parou de chegar); a contagem anda sozinha
        const idle = v.idleMs();
        if (idle > 3000) {
            return i18n.bufPrint(buf, "sem imagem nova há {d} s", .{idle / 1000}) catch "";
        }
        if (v.shownFps() < 0.5) return tr("tela parada");
        const dec = if (std.mem.eql(u8, v.decoder_name, "nenhum")) tr("nenhum") else v.decoder_name;
        return i18n.bufPrint(buf, "atraso {d:.0} ms · {s} ({s}) {d:.1} ms", .{ v.latency_ms, v.codec.name(), dec, v.decode_ms }) catch "";
    }

    fn drawTile(a: *App, t: *const Tile, cell_x: f32, cell_y: f32, cell_w: f32, cell_h: f32, big: bool) void {
        // minha prévia na tela: a captura continua gerando a miniatura
        // (minimizado não: ninguém vê, e a miniatura subindo pra placa sem a tela
        // ser trocada fazia o driver da AMD juntar centenas de MB)
        if (t.view == null and !a.iconified) {
            const sh = if (proto.kindOf(t.stream) == proto.kind_camera) a.camera else a.sharer;
            if (sh) |x| x.preview_wanted_ms.store(sync.nowMs(), .monotonic);
        }
        const d = drawList();
        const io = c.igGetIO_Nil();
        // o quadro tem o formato do vídeo (sem faixas pretas dentro da célula)
        const ar: f32 = if (t.tw > 0 and t.th > 0) @as(f32, @floatFromInt(t.tw)) / @as(f32, @floatFromInt(t.th)) else 16.0 / 9.0;
        var w = cell_w;
        var h = cell_h;
        if (!(a.theater and big)) {
            if (w / h > ar) w = h * ar else h = w / ar;
        }
        const x = cell_x + (cell_w - w) / 2;
        const y = cell_y + (cell_h - h) / 2;
        const round = if (a.theater and big) 0 else S(8) * col.round;
        c.igPushID_Int(@bitCast(t.stream));
        defer c.igPopID();
        if (a.n_tile_rects < a.tile_rects.len) {
            a.tile_rects[a.n_tile_rects] = .{ .stream = t.stream, .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h };
            a.n_tile_rects += 1;
        }
        c.igSetCursorScreenPos(v2(x, y));
        // os botões por cima (fechar, destacar, volume...) ganham o mouse do quadro
        c.igSetNextItemAllowOverlap();
        _ = c.igInvisibleButton("tile", v2(w, h), 0);
        const tile_active = c.igIsItemActive(); // apertou no quadro (arrastar = mover o zoom)
        // Mouse em cima do quadro, inclusive sobre um botão dele ou arrastando o
        // volume. Com o hover simples, o clique num botão por cima "tirava" o
        // mouse do quadro: os botões sumiam no meio do clique e nada funcionava.
        const over = c.igIsItemHovered(c.ImGuiHoveredFlags_AllowWhenOverlappedByItem | c.ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
        const on_tile = c.igIsItemHovered(0); // no quadro em si, não num botão dele
        const clicked = c.igIsItemClicked(0);
        const dbl = on_tile and c.igIsMouseDoubleClicked_Nil(0);
        // arrastando o volume pra fora do quadro: os controles continuam
        if (a.tile_controls) |o| {
            if (o == t.stream and !c.igIsMouseDown_Nil(0)) a.tile_controls = null;
        }
        const hovered = !a.controls_hidden and (over or (a.tile_controls != null and a.tile_controls.? == t.stream));

        c.ImDrawList_PushClipRect(d, v2(x, y), v2(x + w, y + h), true);
        defer c.ImDrawList_PopClipRect(d);
        rectFill(d, x, y, x + w, y + h, col.black, round);

        // imagem (com zoom)
        var iw = w;
        var ih = w / ar;
        if (ih > h) {
            ih = h;
            iw = h * ar;
        }
        const ix = x + (w - iw) / 2;
        const iy = y + (h - ih) / 2;
        const zm = a.zoomFor(t.stream);
        // o tamanho em que esse vídeo aparece (com o zoom): a conversão de cor sai nele
        if (t.view) |vw| {
            const fbs = io.*.DisplayFramebufferScale;
            vw.disp_px_w = @max(vw.disp_px_w, @as(u32, @intFromFloat(iw * zm.z * fbs.x)));
            vw.disp_px_h = @max(vw.disp_px_h, @as(u32, @intFromFloat(ih * zm.z * fbs.y)));
        }
        if (zm.follow and zm.z > 1.001 and t.cur_x != proto.coord_none) {
            // segue a ponta do cursor de quem transmite, suave
            const tx = @as(f32, @floatFromInt(t.cur_x)) / 65534.0;
            const ty = @as(f32, @floatFromInt(t.cur_y)) / 65534.0;
            const dx = tx - zm.cx;
            const dy = ty - zm.cy;
            const half_now = 0.5 / zm.z;
            // só anda quando o cursor sai do miolo da vista (não fica balançando)
            if (@abs(dx) > half_now * 0.35 or @abs(dy) > half_now * 0.35) {
                zm.cx += dx * 0.18;
                zm.cy += dy * 0.18;
                wakeUi();
            }
        }
        const mouse = io.*.MousePos;
        const in_img = mouse.x >= ix and mouse.x < ix + iw and mouse.y >= iy and mouse.y < iy + ih;
        // rodinha: aproxima no ponto do mouse (o ponto embaixo dele fica parado)
        if (over and in_img and io.*.MouseWheel != 0 and t.tex != 0) {
            const half0 = 0.5 / zm.z;
            const mu = (mouse.x - ix) / iw;
            const mv = (mouse.y - iy) / ih;
            const u = zm.cx - half0 + mu * 2 * half0;
            const vv = zm.cy - half0 + mv * 2 * half0;
            zm.z = std.math.clamp(zm.z * std.math.pow(f32, 1.25, io.*.MouseWheel), 1, 8);
            const half1 = 0.5 / zm.z;
            zm.cx = u - (mu - 0.5) * 2 * half1;
            zm.cy = vv - (mv - 0.5) * 2 * half1;
            if (zm.z <= 1.001) zm.follow = false;
        }
        // arrastar com zoom: move a imagem (e para de seguir o cursor)
        const tool_on = (a.draw_tile != null and a.draw_tile.? == t.stream) or (a.crop_tile != null and a.crop_tile.? == t.stream);
        if (tile_active and zm.z > 1.001 and !tool_on and c.igIsMouseDragging(0, -1)) {
            const half0 = 0.5 / zm.z;
            zm.cx -= io.*.MouseDelta.x / iw * 2 * half0;
            zm.cy -= io.*.MouseDelta.y / ih * 2 * half0;
            zm.follow = false;
        }
        zm.clamp();
        const half = 0.5 / zm.z;
        const uv0 = v2(zm.cx - half, zm.cy - half);
        const uv1 = v2(zm.cx + half, zm.cy + half);
        if (t.tex != 0 and t.tw > 0 and t.th > 0) {
            c.ImDrawList_AddImageRounded(d, texRef(t.tex), v2(ix, iy), v2(ix + iw, iy + ih), uv0, uv1, col.white, round, 0);
        } else {
            const msg = tr("Carregando...");
            const ts = textSizeF(font_semibold, 14, msg);
            drawTextF(d, font_semibold, 14, v2(x + (w - ts.x) / 2, y + (h - ts.y) / 2), col.muted, msg);
        }
        if (zm.z > 1.001) {
            // minimapa: onde a vista está na imagem inteira
            const mw = S(72);
            const mh = mw / ar;
            const mx0 = x + S(10);
            const my0 = y + h - mh - S(46);
            rectFill(d, mx0, my0, mx0 + mw, my0 + mh, rgba(0x000000, 150), S(3));
            c.ImDrawList_AddRect(d, v2(mx0 + uv0.x * mw, my0 + uv0.y * mh), v2(mx0 + uv1.x * mw, my0 + uv1.y * mh), col.white, 0, S(1.5), 0);
        }

        // cursor de quem transmite, quando ele vem fora do vídeo (feat_cursor)
        if (t.view) |tv| if (tv.cursor_apart.load(.acquire)) drawRemoteCursor(tv, ix, iy, iw, ih, uv0, uv1);
        // ponteiros "olha aqui" de quem está assistindo junto
        a.drawPointers(t, ix, iy, iw, ih, uv0, uv1);
        // o meu, quando o modo ponteiro está ligado nesse quadro
        const pointing = a.pointer_tile != null and a.pointer_tile.? == t.stream;
        if (pointing) a.updatePointer(t, over and in_img and on_tile, ix, iy, iw, ih, uv0, uv1, mouse);
        // traços desenhados por cima (de todo mundo) e o meu, se estiver desenhando aqui
        a.drawStrokes(t, ix, iy, iw, ih, uv0, uv1);
        const drawing = a.draw_tile != null and a.draw_tile.? == t.stream;
        if (drawing) {
            // a paleta fica por cima: clicar nela não risca
            const pr = paletteRect(w, x, y, h);
            const on_palette = mouse.x >= pr[0] and mouse.x < pr[2] and mouse.y >= pr[1] and mouse.y < pr[3];
            a.updateDraw(t, over and in_img and on_tile and !on_palette, ix, iy, iw, ih, uv0, uv1, mouse);
            if (a.client) |dcl| if (a.draw_tile != null) a.drawPalette(dcl, t, pr, w);
        }
        const cropping = a.crop_tile != null and a.crop_tile.? == t.stream;
        if (cropping) a.updateCrop(over and in_img and on_tile, ix, iy, iw, ih, uv0, uv1, mouse);
        const tool = pointing or drawing or cropping; // o clique é da ferramenta, não do quadro

        // etiqueta com o nome
        const small = h < S(160);
        const name_size: f32 = if (small) 12.5 else 14;
        const ns = textSizeF(font_semibold, name_size, t.name);
        const lx = x + S(10);
        const ly = y + h - ns.y - S(16);
        rectFill(d, lx, ly, lx + ns.x + S(70), ly + ns.y + S(8), col.overlay, S(6));
        const bw = liveBadge(d, v2(lx + S(6), ly + S(4) + (ns.y - S(14)) / 2));
        drawTextF(d, font_semibold, name_size, v2(lx + S(12) + bw, ly + S(4)), col.white, t.name);
        if (zm.z > 1.001) {
            const zt = fmtZ("{d:.1}x", .{zm.z});
            drawTextF(d, font_semibold, 12, v2(lx + ns.x + S(78), ly + S(5)), col.white, zt);
        }

        if (t.clipbuf) |cb| {
            const rs = cb.recState();
            if (rs.active) {
                const secs = rs.ms / 1000;
                const rt = if (rs.waiting) fmtZ("REC (esperando quadro completo)", .{}) else fmtZ("REC {d:0>2}:{d:0>2}", .{ secs / 60, secs % 60 });
                const rts = textSizeF(font_bold, 11, rt);
                const rx0 = x + w - rts.x - S(28);
                const ry0 = y + h - S(70);
                rectFill(d, rx0, ry0, rx0 + rts.x + S(20), ry0 + rts.y + S(8), col.overlay, S(5));
                const phase = @mod(c.igGetTime(), 1.0);
                const blink = phase < 0.6;
                if (blink) c.ImDrawList_AddCircleFilled(d, v2(rx0 + S(8), ry0 + (rts.y + S(8)) / 2), S(4), col.red, 0);
                drawTextF(d, font_bold, 11, v2(rx0 + S(15), ry0 + S(4)), col.white, rt);
                // próxima troca do pisca (e o tempo da gravação andando)
                redrawIn(if (blink) 0.6 - phase else 1.0 - phase);
            }
        }
        if ((hovered or a.cfg.stats_always) and !small) {
            const ss = textSizeF(font_regular, 12, t.stats);
            rectFill(d, x + S(10), y + S(10), x + S(22) + ss.x, y + S(16) + ss.y, col.overlay, S(6));
            drawTextF(d, font_regular, 12, v2(x + S(16), y + S(13)), col.text, t.stats);
            // estatística à mostra de uma transmissão parada: a contagem
            // "sem imagem nova há N s" anda (só enquanto ela aparece)
            if (t.view) |tv| if (tv.idleMs() > 3000) redrawIn(1.0);
        }
        if (hovered) {
            // botões no canto (da direita pra esquerda)
            const bs = S(32);
            var bx = x + w - bs - S(8);
            const by = y + S(8);
            const save = c.igGetCursorScreenPos();
            if (proto.memberOf(t.stream) != 0) {
                c.igSetCursorScreenPos(v2(bx, by));
                rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
                if (iconButton("##close", ic.xmark, bs, col.white, withAlpha(col.red, 200), tr("Parar de assistir"))) {
                    a.unwatch(t.stream);
                    return;
                }
                bx -= bs + S(6);
            }
            c.igSetCursorScreenPos(v2(bx, by));
            rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
            // tela cheia (o botão de cantos; F11 e duplo clique também)
            if (iconButton("##fullscreen", if (a.fullscreen) ic.compress else ic.expand, bs, col.white, withAlpha(col.blurple, 200), if (a.fullscreen) tr("Sair da tela cheia (Esc)") else tr("Tela cheia (F11 ou duplo clique)"))) {
                if (a.fullscreen) {
                    a.theater = false;
                    a.toggleFullscreen();
                } else {
                    a.focused = t.stream;
                    a.theater = true;
                    a.toggleFullscreen();
                }
            }
            bx -= bs + S(6);
            c.igSetCursorScreenPos(v2(bx, by));
            rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
            const focused = a.focused != null and a.focused.? == t.stream;
            if (iconButton("##focus", if (focused) ic.unspotlight else ic.spotlight, bs, col.white, withAlpha(col.blurple, 200), if (focused) tr("Voltar pra grade") else tr("Destacar na sala"))) {
                a.focused = if (focused) null else t.stream;
            } else if (dbl and !tool) {
                a.focused = t.stream;
                a.theater = !a.theater;
                if (a.theater != a.fullscreen) a.toggleFullscreen();
            } else if (clicked and !big and !tool) {
                // (com o ponteiro ligado, o clique é o "olha aqui", não destacar)
                a.focused = t.stream;
            }
            bx -= bs + S(6);
            if (!small) {
                // ponteiro "olha aqui"
                c.igSetCursorScreenPos(v2(bx, by));
                rectFill(d, bx, by, bx + bs, by + bs, if (pointing) col.blurple else col.overlay, S(6));
                if (iconButton("##pointer", ic.hand_pointer, bs, col.white, withAlpha(col.blurple, 200), if (pointing) tr("Desligar o ponteiro") else tr("Ponteiro: quem assiste vê onde você aponta (clique chama atenção)"))) {
                    if (pointing) a.stopPointer() else {
                        a.stopTools();
                        a.pointer_tile = t.stream;
                    }
                }
                bx -= bs + S(6);
                // desenhar por cima (todo mundo vê; some sozinho)
                c.igSetCursorScreenPos(v2(bx, by));
                rectFill(d, bx, by, bx + bs, by + bs, if (drawing) col.blurple else col.overlay, S(6));
                const no_draw = if (a.client) |dcl| a.myNoDraw(dcl) else false;
                if (iconButton("##draw", ic.pen, bs, if (no_draw) col.faint else col.white, withAlpha(col.blurple, 200), if (no_draw) tr("O admin tirou o seu pincel") else if (drawing) tr("Parar de desenhar (botão direito apaga os seus traços)") else tr("Desenhar por cima: quem assiste e quem transmite veem; some sozinho em alguns segundos"))) {
                    if (no_draw) {
                        a.toast("O admin tirou o seu pincel.", .{}, true);
                    } else if (drawing) a.draw_tile = null else {
                        a.stopTools();
                        a.draw_tile = t.stream;
                    }
                }
                bx -= bs + S(6);
                // a minha tela: transmitir só um pedaço
                if (t.view == null and proto.kindOf(t.stream) == proto.kind_screen and a.sharer != null) {
                    const cropped = a.crop[0] > 0 or a.crop[1] > 0 or a.crop[2] < 1 or a.crop[3] < 1;
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, if (cropping or cropped) col.blurple else col.overlay, S(6));
                    if (iconButton("##crop", ic.crop, bs, col.white, withAlpha(col.blurple, 200), if (cropping) tr("Cancelar o recorte") else tr("Transmitir só um pedaço da tela"))) {
                        if (cropping) a.cancelCrop() else {
                            a.stopTools();
                            // a prévia (só aqui) mostra a tela inteira pra escolher; quem
                            // assiste continua vendo o recorte de antes até confirmar
                            a.crop_tile = t.stream;
                            a.crop_seen_frame = a.frame_no;
                            if (a.sharer) |sh| sh.preview_full.store(true, .release);
                        }
                    }
                    bx -= bs + S(6);
                }
                // janela flutuante (só transmissões de outras pessoas)
                if (t.view != null) {
                    const open = a.findPip(t.stream) != null;
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, if (open) col.blurple else col.overlay, S(6));
                    if (iconButton("##pip", ic.window_restore, bs, col.white, withAlpha(col.blurple, 200), if (open) tr("Fechar a janela flutuante") else tr("Abrir numa janela flutuante (por cima das outras)"))) a.togglePip(t.stream, t.name);
                    bx -= bs + S(6);
                }
                // print (PNG em resolução cheia)
                if (t.view) |vw| {
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
                    if (iconButton("##print", ic.camera_photo, bs, col.white, withAlpha(col.blurple, 200), tr("Print (PNG, na resolução da transmissão)"))) a.savePrint(vw, t.name);
                    bx -= bs + S(6);
                }
                // clipe (últimos 30 s) e gravação
                if (t.clipbuf) |cb| {
                    const rs = cb.recState();
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, if (rs.active) col.red else col.overlay, S(6));
                    if (iconButton("##rec", ic.record, bs, col.white, withAlpha(col.red, 200), if (rs.active) tr("Parar de gravar (salva o arquivo)") else tr("Gravar (MP4, com o som da transmissão, a partir de agora)"))) {
                        if (rs.active) a.stopRecording(cb, t.name) else a.startRecording(cb, t.name);
                    }
                    bx -= bs + S(6);
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
                    if (iconButton("##clip", ic.scissors, bs, col.white, withAlpha(col.blurple, 200), fmtZ("Salvar clipe dos últimos {d} s", .{clip.keep_secs.load(.monotonic)}))) a.saveClip(cb, t.name);
                    bx -= bs + S(6);
                }
                // zoom: seguir o cursor de quem transmite / voltar pro tamanho normal
                if (t.view != null) {
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, if (zm.follow) col.blurple else col.overlay, S(6));
                    const can_follow = t.cur_x != proto.coord_none;
                    if (iconButton("##follow", ic.crosshairs, bs, if (can_follow) col.white else col.faint, withAlpha(col.blurple, 200), if (zm.follow) tr("Parar de seguir o cursor") else if (can_follow) tr("Zoom seguindo o cursor de quem transmite (rodinha: aproximar)") else tr("Seguir o cursor (quem transmite está sem cursor)"))) {
                        zm.follow = !zm.follow and can_follow;
                        if (zm.follow and zm.z < 2) zm.z = 2;
                    }
                    bx -= bs + S(6);
                }
                if (zm.z > 1.001) {
                    c.igSetCursorScreenPos(v2(bx, by));
                    rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
                    if (iconButton("##zoomreset", ic.compress, bs, col.white, withAlpha(col.blurple, 200), tr("Voltar pro tamanho normal (sem zoom)"))) {
                        zm.* = .{ .stream = t.stream, .used = true };
                    }
                    bx -= bs + S(6);
                }
            }
            // volume dessa transmissão (canto de baixo)
            if (t.ring) |rg| {
                const vh = S(30);
                const vw = S(150);
                const vx = x + w - vw - S(10);
                const vy = y + h - vh - S(10);
                rectFill(d, vx, vy, vx + vw, vy + vh, col.overlay, S(6));
                c.igSetCursorScreenPos(v2(vx + S(2), vy));
                const rg_muted = rg.isMuted();
                if (iconButton("##mute", if (rg_muted) ic.volume_off else ic.volume, vh, if (rg_muted) col.red else col.white, rgba(0xFFFFFF, 30), if (rg_muted) tr("Ativar som") else tr("Silenciar"))) rg.setMuted(!rg_muted);
                c.igSameLine(0, S(4));
                c.igSetCursorScreenPos(v2(vx + vh + S(6), vy + S(7)));
                c.igSetNextItemWidth(vw - vh - S(14));
                c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, rgba(0xFFFFFF, 30));
                c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, rgba(0xFFFFFF, 45));
                c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, rgba(0xFFFFFF, 45));
                c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(4), S(2)));
                var vol_pct: f32 = rg.getVolume() * 100;
                if (c.igSliderFloat("##vol", &vol_pct, 0, 200, "%.0f%%", c.ImGuiSliderFlags_AlwaysClamp)) rg.setVolume(vol_pct / 100);
                if (c.igIsItemActive()) a.tile_controls = t.stream;
                c.igPopStyleVar(1);
                c.igPopStyleColor(3);
            }
            c.igSetCursorScreenPos(save);
            c.igDummy(v2(0, 0));
            c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), rgba(0xFFFFFF, 40), round, S(1.5), 0);
        }
        // contorno verde: quem transmite está falando (voz), ou a transmissão
        // está tocando som (mais fraco)
        const talking = if (proto.memberOf(t.stream) == 0)
            (if (a.mic) |m| m.speaking.load(.monotonic) else false)
        else if (a.client) |cl| cl.speaking(proto.memberOf(t.stream)) else false;
        const ring_level = if (t.ring) |rg| rg.takeLevel() else 0; // decai um pouco a cada quadro
        if (talking) {
            c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), col.green, round, S(3), 0);
            redrawIn(0.2); // apaga quando parar
        } else if (t.ring) |rg| {
            if (!rg.isMuted() and ring_level > 0.02) {
                c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), withAlpha(col.green, 160), round, S(2), 0);
                redrawIn(0.35);
            }
        }
        if (pointing) c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), col.blurple, round, S(2), 0);
    }

    /// Ponto da imagem inteira (0..65534) → tela, considerando o zoom. null = fora da vista.
    fn mapPoint(px: u16, py: u16, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c) ?c.ImVec2_c {
        const u = @as(f32, @floatFromInt(px)) / 65534.0;
        const vv = @as(f32, @floatFromInt(py)) / 65534.0;
        if (u < uv0.x or u > uv1.x or vv < uv0.y or vv > uv1.y) return null;
        return v2(ix + (u - uv0.x) / (uv1.x - uv0.x) * iw, iy + (vv - uv0.y) / (uv1.y - uv0.y) * ih);
    }

    /// Seta de cursor clássica (preta com borda branca), ponta em `at`; `k` = escala (1 ≈ 22 px).
    fn drawArrow(d: *c.ImDrawList, at: c.ImVec2_c, k: f32) void {
        const pts = [_][2]f32{ .{ 0, 0 }, .{ 0, 17 }, .{ 4, 13 }, .{ 7.5, 20.5 }, .{ 10, 19.5 }, .{ 6.6, 12 }, .{ 12, 12 } };
        var poly: [pts.len]c.ImVec2_c = undefined;
        for (pts, 0..) |p, i| poly[i] = v2(at.x + p[0] * k * 1.05, at.y + p[1] * k * 1.05);
        c.ImDrawList_AddConcavePolyFilled(d, &poly, poly.len, rgba(0x000000, 235));
        c.ImDrawList_AddPolyline(d, &poly, poly.len, rgba(0xffffff, 255), @max(1.0, 1.4 * k), c.ImDrawFlags_Closed);
    }

    /// Seta com o nome de quem aponta (cor do avatar dela).
    fn drawPointerAt(d: *c.ImDrawList, p: c.ImVec2_c, color: u32, name: []const u8, ping_age_s: f32) void {
        if (ping_age_s >= 0 and ping_age_s < 0.9) {
            // clique: anel que cresce e some
            const k = ping_age_s / 0.9;
            redrawIn(0.016); // o anel do "olha aqui" anima por 0,9 s
            c.ImDrawList_AddCircle(d, p, S(8) + S(34) * k, (color & 0x00FFFFFF) | (@as(u32, @intFromFloat((1 - k) * 230)) << 24), 0, S(3), 0);
        }
        const tip = p;
        const pts = [_]c.ImVec2_c{ tip, v2(tip.x + S(4), tip.y + S(17)), v2(tip.x + S(8.5), tip.y + S(11.5)), v2(tip.x + S(15), tip.y + S(11)) };
        // seta côncava: dois triângulos
        c.ImDrawList_AddTriangleFilled(d, pts[0], pts[1], pts[2], color);
        c.ImDrawList_AddTriangleFilled(d, pts[0], pts[2], pts[3], color);
        c.ImDrawList_AddPolyline(d, &pts, pts.len, col.white, S(1.5), c.ImDrawFlags_Closed);
        const ts = textSizeF(font_semibold, 12, name);
        const lx = tip.x + S(14);
        const ly = tip.y + S(16);
        rectFill(d, lx, ly, lx + ts.x + S(12), ly + ts.y + S(6), color, S(5));
        drawTextF(d, font_semibold, 12, v2(lx + S(6), ly + S(3)), col.white, name);
    }

    /// A seta do cursor de quem transmite (o vídeo vem sem ela), no tamanho
    /// em que um cursor apareceria nessa imagem (~22 px numa tela de 1080).
    fn drawRemoteCursor(v: *View, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c) void {
        const x = v.cursor_x.load(.monotonic);
        const y = v.cursor_y.load(.monotonic);
        if (x == proto.coord_none or y == proto.coord_none) return;
        const at = mapPoint(x, y, ix, iy, iw, ih, uv0, uv1) orelse return;
        const full_h = ih / @max(0.01, uv1.y - uv0.y); // a imagem inteira, com zoom
        drawArrow(drawList(), at, std.math.clamp(full_h / 1080.0, 0.45, 2.5));
    }

    fn drawPointers(a: *App, t: *const Tile, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c) void {
        const cl = a.client orelse return;
        const now = sync.nowUs();
        var buf: [16]client_mod.Pointer = undefined;
        var names: [16][32]u8 = undefined;
        var name_lens: [16]usize = undefined;
        var n: usize = 0;
        cl.mutex.lock();
        for (cl.pointers.items) |p| {
            if (p.stream != t.ptr_stream or n == buf.len) continue;
            if (p.flags & proto.pointer_visible == 0 or now - p.at_us > 4_000_000) continue;
            buf[n] = p;
            name_lens[n] = 0;
            for (cl.members.items) |*m| if (m.id == p.from) {
                name_lens[n] = @min(m.name_len, 32);
                @memcpy(names[n][0..name_lens[n]], m.name[0..name_lens[n]]);
            };
            n += 1;
        }
        cl.mutex.unlock();
        const d = drawList();
        for (buf[0..n], 0..) |p, i| {
            const at = mapPoint(p.x, p.y, ix, iy, iw, ih, uv0, uv1) orelse continue;
            const ping_age: f32 = if (p.ping_us != 0) @as(f32, @floatFromInt(now - p.ping_us)) / 1e6 else -1;
            drawPointerAt(d, at, avatarColor(p.from), names[i][0..name_lens[i]], ping_age);
        }
        if (n > 0) redrawIn(0.25); // some sozinho depois de parado
    }

    /// Modo ponteiro ligado nesse quadro: manda a posição do mouse (até ~30x/s) e
    /// o clique; mostra o próprio ponteiro na hora (o servidor não devolve).
    fn updatePointer(a: *App, t: *const Tile, inside: bool, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c, mouse: c.ImVec2_c) void {
        const cl = a.client orelse return;
        const now = sync.nowUs();
        if (!inside) {
            if (a.pointer_shown) {
                cl.sendPointer(t.ptr_stream, proto.coord_none, proto.coord_none, 0);
                a.pointer_shown = false;
            }
            return;
        }
        const u = uv0.x + (mouse.x - ix) / iw * (uv1.x - uv0.x);
        const vv = uv0.y + (mouse.y - iy) / ih * (uv1.y - uv0.y);
        const px: u16 = @intFromFloat(std.math.clamp(u, 0, 1) * 65534);
        const py: u16 = @intFromFloat(std.math.clamp(vv, 0, 1) * 65534);
        const ping = c.igIsMouseClicked_Bool(0, false);
        const io = c.igGetIO_Nil();
        const moved = io.*.MouseDelta.x != 0 or io.*.MouseDelta.y != 0;
        if (ping or (moved and now - a.pointer_sent_us > 33_000) or now - a.pointer_sent_us > 1_000_000) {
            cl.sendPointer(t.ptr_stream, px, py, proto.pointer_visible | @as(u8, if (ping) proto.pointer_ping else 0));
            a.pointer_sent_us = now;
            a.pointer_stream_sent = t.ptr_stream;
            a.pointer_shown = true;
            if (ping) a.my_ping_us = now;
        }
        c.igSetMouseCursor(c.ImGuiMouseCursor_None);
        const ping_age: f32 = if (a.my_ping_us != 0) @as(f32, @floatFromInt(now - a.my_ping_us)) / 1e6 else -1;
        drawPointerAt(drawList(), mouse, col.blurple, tr("você"), ping_age);
    }

    // ------------------------------------------------------ clipes e gravação

    /// Escrita de um clipe numa thread (o arquivo pode ter dezenas de MB).
    /// Print de uma transmissão: converte o último quadro e grava o PNG numa thread.
    const PrintJob = struct {
        done: std.atomic.Value(bool) = .init(false),
        ok: bool = false,
        path: [512:0]u8 = undefined,
        pic: client_mod.Pic,

        fn run(j: *PrintJob) void {
            defer {
                std.heap.c_allocator.free(j.pic.data);
                j.done.store(true, .release);
                wakeUi();
            }
            const w: usize = j.pic.w;
            const h: usize = j.pic.h;
            const px = if (j.pic.layout == .rgba) j.pic.data else std.heap.c_allocator.alloc(u8, w * h * 4) catch return;
            defer if (j.pic.layout != .rgba) std.heap.c_allocator.free(px);
            const n = w * h;
            switch (j.pic.layout) {
                .rgba => {},
                .i420 => codec.toRgba(j.pic.data.ptr, j.pic.data.ptr + n, j.pic.data.ptr + n + n / 4, w, w / 2, w, h, px),
                .nv12, .nv12_dev => codec.nv12ToRgba(j.pic.data.ptr, j.pic.data.ptr + n, w, h, px),
            }
            // o PNG não usa o canal alfa: tudo opaco
            var i: usize = 3;
            while (i < px.len) : (i += 4) px[i] = 255;
            j.ok = c.img_write_png(&j.path, px.ptr, @intCast(w), @intCast(h)) == 0;
        }
    };

    fn savePrint(a: *App, v: *View, who: []const u8) void {
        if (a.print_job != null) return;
        const f = &v.front;
        if (f.w == 0) {
            a.toast("Ainda não chegou imagem dessa transmissão.", .{}, true);
            return;
        }
        const j = std.heap.c_allocator.create(PrintJob) catch return;
        const data = if (f.layout == .nv12_dev) blk: {
            // quadro na placa: traz os planos pra CPU (uma vez, só pro print)
            const db = f.dev orelse {
                std.heap.c_allocator.destroy(j);
                return;
            };
            const n = @as(usize, f.w) * f.h;
            const d = std.heap.c_allocator.alloc(u8, n + n / 2) catch {
                std.heap.c_allocator.destroy(j);
                return;
            };
            if (gl.cudagl_dev_to_host(gl.cudagl, db.ptr, @intCast(db.pitch), d.ptr, @intCast(f.w), @intCast(f.w), @intCast(f.h)) != 0 or
                gl.cudagl_dev_to_host(gl.cudagl, db.uv(), @intCast(db.pitch), d.ptr + n, @intCast(f.w), @intCast(f.w), @intCast(f.h / 2)) != 0)
            {
                std.heap.c_allocator.free(d);
                std.heap.c_allocator.destroy(j);
                a.toast("Não consegui ler o quadro da placa pro print.", .{}, true);
                return;
            }
            break :blk d;
        } else std.heap.c_allocator.dupe(u8, f.data) catch {
            std.heap.c_allocator.destroy(j);
            return;
        };
        j.* = .{ .pic = .{ .data = data, .layout = if (f.layout == .nv12_dev) .nv12 else f.layout, .w = f.w, .h = f.h } };
        _ = clip.newPathExt(&j.path, if (who.len > 0) who else tr("print"), tr("_print"), ".png") catch {
            std.heap.c_allocator.free(data);
            std.heap.c_allocator.destroy(j);
            a.toast("Não achei a pasta de vídeos pra salvar o print.", .{}, true);
            return;
        };
        sync.spawn(PrintJob.run, .{j}) catch {
            std.heap.c_allocator.free(data);
            std.heap.c_allocator.destroy(j);
            return;
        };
        a.print_job = j;
    }

    fn checkPrintJob(a: *App) void {
        const j = a.print_job orelse return;
        if (!j.done.load(.acquire)) return;
        const path = std.mem.sliceTo(&j.path, 0);
        if (j.ok) {
            a.rememberSaved(path);
            a.toast("Print salvo: {s}", .{baseName(path)}, false);
        } else a.toast("Não consegui salvar o print em {s}", .{path}, true);
        std.heap.c_allocator.destroy(j);
        a.print_job = null;
    }

    const ClipJob = struct {
        done: std.atomic.Value(bool) = .init(false),
        ok: bool = false,
        secs: f32 = 0,
        path: [512:0]u8 = undefined,
        snap: clip.Buffer.Snapshot,

        fn run(j: *ClipJob) void {
            const n = std.mem.len(@as([*:0]const u8, &j.path));
            if (mp4.writeClip(j.path[0..n :0], j.snap.w, j.snap.h, j.snap.video, j.snap.audio)) |_| {
                j.ok = true;
            } else |_| {}
            j.snap.deinit();
            j.done.store(true, .release);
            wakeUi();
        }
    };

    fn saveClip(a: *App, cb: *clip.Buffer, who: []const u8) void {
        const slot = for (&a.clip_jobs) |*sl| {
            if (sl.* == null) break sl;
        } else {
            a.toast("Calma: ainda salvando os clipes anteriores.", .{}, true);
            return;
        };
        const secs = cb.seconds();
        var snap = cb.snapshot() catch {
            a.toast("Ainda não tem nada pra clipar (espera uns segundos).", .{}, true);
            return;
        };
        const j = std.heap.c_allocator.create(ClipJob) catch {
            snap.deinit();
            return;
        };
        j.* = .{ .snap = snap, .secs = @min(secs, @as(f32, @floatFromInt(clip.keep_secs.load(.monotonic)))) };
        const path = clip.newPath(&j.path, if (who.len > 0) who else tr("clipe"), tr("_clipe")) catch {
            j.snap.deinit();
            std.heap.c_allocator.destroy(j);
            a.toast("Não achei a pasta de vídeos pra salvar o clipe.", .{}, true);
            return;
        };
        _ = path;
        sync.spawn(ClipJob.run, .{j}) catch {
            j.snap.deinit();
            std.heap.c_allocator.destroy(j);
            return;
        };
        slot.* = j;
        a.toast("Salvando o clipe...", .{}, false);
    }

    /// Clipes que terminaram de ser escritos (todo quadro).
    fn checkClipJobs(a: *App) void {
        for (&a.clip_jobs) |*sl| {
            const j = sl.* orelse continue;
            if (!j.done.load(.acquire)) continue;
            const path = std.mem.sliceTo(&j.path, 0);
            if (j.ok) {
                a.rememberSaved(path);
                a.toast("Clipe salvo ({d:.0} s): {s}", .{ j.secs, baseName(path) }, false);
            } else a.toast("Não consegui salvar o clipe em {s}", .{path}, true);
            std.heap.c_allocator.destroy(j);
            sl.* = null;
        }
    }

    fn startRecording(a: *App, cb: *clip.Buffer, who: []const u8) void {
        var buf: [512:0]u8 = undefined;
        const path = clip.newPath(&buf, if (who.len > 0) who else tr("gravacao"), tr("_gravacao")) catch {
            a.toast("Não achei a pasta de vídeos pra gravar.", .{}, true);
            return;
        };
        cb.startRecording(path);
        // a gravação começa no próximo quadro completo: pede um agora
        for (a.views.items) |v| if (v.clip == cb) if (a.client) |cl| cl.sendKeyreqReason(v.stream, proto.keyreq_record);
        for ([_]?*Sharer{ a.sharer, a.camera }) |maybe| if (maybe) |sh| if (sh.clip == cb) sh.client.keyreq[sh.kind].store(true, .release);
        const rs = cb.recState();
        if (rs.failed) a.toast("Não consegui criar o arquivo da gravação em {s}", .{path}, true) else a.toast("Gravando: {s}", .{baseName(path)}, false);
        a.rememberSaved(path);
    }

    fn stopRecording(a: *App, cb: *clip.Buffer, who: []const u8) void {
        _ = who;
        const ms = cb.stopRecording(if (a.client) |cl| cl.serverNowUs() else 0);
        if (ms == 0) {
            a.toast("Gravação cancelada (não chegou nenhum quadro completo).", .{}, true);
            return;
        }
        var pb: [528]u8 = undefined;
        a.rememberSaved(cb.recPath(&pb));
        const parts = cb.recParts();
        if (parts > 1)
            a.toast("Gravação salva ({d}:{d:0>2}) em {d} partes (a resolução mudou no meio): {s}", .{ ms / 60000, (ms / 1000) % 60, parts, baseName(a.last_saved[0..a.last_saved_len]) }, false)
        else
            a.toast("Gravação salva ({d}:{d:0>2}): {s}", .{ ms / 60000, (ms / 1000) % 60, baseName(a.last_saved[0..a.last_saved_len]) }, false);
    }

    fn rememberSaved(a: *App, path: []const u8) void {
        a.last_saved_len = @min(path.len, a.last_saved.len);
        @memcpy(a.last_saved[0..a.last_saved_len], path[0..a.last_saved_len]);
    }

    fn baseName(path: []const u8) []const u8 {
        const i = std.mem.findLastAny(u8, path, "/\\") orelse return path;
        return path[i + 1 ..];
    }

    // ------------------------------------------------------ janela flutuante

    fn findPip(a: *App, stream: u32) ?*pip.Pip {
        for (a.pips) |maybe| if (maybe) |p| if (p.stream == stream) return p;
        return null;
    }

    fn togglePip(a: *App, stream: u32, name: []const u8) void {
        for (&a.pips) |*sl| if (sl.*) |p| if (p.stream == stream) {
            p.close(a.window);
            sl.* = null;
            return;
        };
        const slot = for (&a.pips) |*sl| {
            if (sl.* == null) break sl;
        } else {
            a.toast("No máximo 4 janelas flutuantes.", .{}, true);
            return;
        };
        var title: [96]u8 = undefined;
        const t = std.fmt.bufPrintZ(&title, "telinha · {s}", .{name}) catch "telinha";
        slot.* = pip.Pip.open(a.window, stream, t, scale) catch {
            a.toast("Não consegui abrir a janela flutuante.", .{}, true);
            return;
        };
    }

    /// Desenha as janelas flutuantes (depois da principal, a cada volta do loop).
    pub fn drawPips(a: *App) void {
        for (&a.pips) |*sl| {
            const p = sl.* orelse continue;
            const v = a.findView(p.stream) orelse {
                // pararam de transmitir (ou paramos de assistir): fecha
                p.close(a.window);
                sl.* = null;
                continue;
            };
            var name_buf: [64]u8 = undefined;
            var name: []const u8 = "";
            if (a.client) |cl| {
                cl.mutex.lock();
                for (cl.members.items) |*m| if (m.id == v.member()) {
                    name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ m.nameSlice()[0..@min(m.name_len, 40)], if (v.kind() == proto.kind_camera) tr(" (câmera)") else "" }) catch "";
                };
                cl.mutex.unlock();
            }
            // a janela flutuante também conta no tamanho da conversão de cor
            var pw: c_int = 0;
            var ph: c_int = 0;
            c.glfwGetFramebufferSize(p.win, &pw, &ph);
            v.disp_px_w = @max(v.disp_px_w, @as(u32, @intCast(@max(0, pw))));
            v.disp_px_h = @max(v.disp_px_h, @as(u32, @intCast(@max(0, ph))));
            switch (p.frame(a.window, v.tex, v.tex_w, v.tex_h, name, if (v.audio_registered) &v.audio_ring else null)) {
                .none => {},
                .close => {
                    p.close(a.window);
                    sl.* = null;
                },
                .back => {
                    p.close(a.window);
                    sl.* = null;
                    c.glfwFocusWindow(a.window);
                },
            }
        }
    }

    pub fn closePips(a: *App) void {
        for (&a.pips) |*sl| if (sl.*) |p| {
            p.close(a.window);
            sl.* = null;
        };
    }

    /// Abre a pasta dos clipes no gerenciador de arquivos.
    /// "Versão nova disponível" (checagem no GitHub), com o botão de baixar.
    fn drawUpdateBanner(a: *App, w: f32) void {
        const ust = update.getState();
        if (ust != .newer and ust != .downloading and ust != .installed and ust != .install_failed) return;
        var vb: [32]u8 = undefined;
        const v = update.latest(&vb);
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        const h = S(40);
        rectFill(d, p.x, p.y, p.x + w, p.y + h, withAlpha(col.green, 40), S(8));
        drawTextF(d, font_semibold, 14, v2(p.x + S(12), p.y + S(11)), col.header, fmtZ("{s}  telinha {s} saiu (você tem o {s})", .{ ic.arrow_right, v, version_string }));
        const bw = S(78);
        c.igSetCursorScreenPos(v2(p.x + w - bw - S(6), p.y + S(6)));
        if (primaryButton(tr("Ver##update"), v2(bw, h - S(12)), col.green, col.green_hover, col.green_active)) a.update_modal = true;
        c.igSetCursorScreenPos(v2(p.x, p.y + h));
        c.igDummy(v2(w, S(12)));
    }

    fn openClipsFolder(a: *App) void {
        var buf: [512]u8 = undefined;
        const dir = clip.folder(&buf);
        if (dir.len == 0) return;
        if (!openPath(dir)) a.toast("Pasta dos clipes: {s}", .{dir}, false);
    }

    /// Desliga ponteiro, desenho e recorte (um de cada vez).
    fn stopTools(a: *App) void {
        a.stopPointer();
        a.draw_tile = null;
        a.draw_active = false;
        if (a.crop_tile != null) a.cancelCrop();
    }

    // -------------------------------------------- desenho por cima

    const stroke_life_us: u64 = 6_000_000; // o traço some 6 s depois do último ponto
    const stroke_widths = [4]f32{ 3, 1.8, 6, 16 }; // normal, fina, grossa, marca-texto

    /// Estilo do meu pincel nas flags do desenho (proto.draw_*_shift).
    fn drawStyle(a: *App) u8 {
        return (a.cfg.draw_color << proto.draw_color_shift) | (a.cfg.draw_size << proto.draw_size_shift);
    }

    /// Onde fica a paleta do pincel num quadro (embaixo, no meio).
    fn paletteRect(w: f32, x: f32, y: f32, h: f32) [4]f32 {
        const cols: f32 = if (w >= S(700)) 16 else 8;
        const rows: f32 = if (w >= S(700)) 1 else 2;
        const sw = S(26);
        const pw = cols * sw + S(12) + 4 * S(26) + S(12) + 2 * S(30) + S(16);
        const ph = rows * sw + S(12);
        const px = x + @max(S(8), (w - pw) / 2);
        const py = y + h - ph - S(52);
        return .{ px, py, px + @min(pw, w - S(16)), py + ph };
    }

    /// A paleta: cores (a primeira = a minha cor), espessuras, mostrar/esconder
    /// os desenhos dos outros e apagar os meus.
    fn drawPalette(a: *App, cl: *Client, t: *const Tile, r: [4]f32, w: f32) void {
        const d = drawList();
        rectFill(d, r[0], r[1], r[2], r[3], withAlpha(col.bg_dark, 225), S(12));
        c.ImDrawList_AddRect(d, v2(r[0], r[1]), v2(r[2], r[3]), withAlpha(col.text, 30), S(12) * col.round, S(1), 0);
        const cols: usize = if (w >= S(700)) 16 else 8;
        const sw = S(26);
        const back = c.igGetCursorScreenPos();
        defer c.igSetCursorScreenPos(back);
        var x = r[0] + S(6);
        const y = r[1] + S(6);
        for (0..16) |i| {
            const cx = x + @as(f32, @floatFromInt(i % cols)) * sw;
            const cy = y + @as(f32, @floatFromInt(i / cols)) * sw;
            c.igSetCursorScreenPos(v2(cx, cy));
            if (c.igInvisibleButton(fmtZ("##dcol{d}", .{i}).ptr, v2(sw, sw), 0)) {
                a.cfg.draw_color = @intCast(i);
                config.save(&a.cfg);
            }
            const hov = c.igIsItemHovered(0);
            const ctr = v2(cx + sw / 2, cy + sw / 2);
            const colr = if (i == 0) avatarColor(cl.my_id) else rgbRuntime(proto.draw_colors[i]);
            if (a.cfg.draw_color == i) c.ImDrawList_AddCircle(d, ctr, S(10.5), col.white, 0, S(2), 0);
            c.ImDrawList_AddCircleFilled(d, ctr, if (hov) S(8.5) else S(7.5), colr, 0);
            c.ImDrawList_AddCircle(d, ctr, S(7.5), withAlpha(col.black, 90), 0, S(1), 0);
            if (i == 0) {
                const ts = textSizeF(font_bold, 9, "A");
                drawTextF(d, font_bold, 9, v2(ctr.x - ts.x / 2, ctr.y - ts.y / 2), col.white, "A");
                if (hov) tooltipText(tr("A minha cor (a do meu avatar)"));
            }
        }
        x += @as(f32, @floatFromInt(cols)) * sw + S(6);
        rectFill(d, x, r[1] + S(8), x + S(1), r[3] - S(8), withAlpha(col.text, 30), 0);
        x += S(6);
        const my_col = if (a.cfg.draw_color == 0) avatarColor(cl.my_id) else rgbRuntime(proto.draw_colors[a.cfg.draw_color]);
        const size_tips = [4][:0]const u8{ tr("Traço normal"), tr("Traço fino"), tr("Traço grosso"), tr("Marca-texto") };
        const ym = (r[1] + r[3]) / 2;
        for (0..4) |i| {
            const sx = x + @as(f32, @floatFromInt(i)) * S(26);
            c.igSetCursorScreenPos(v2(sx, ym - S(13)));
            if (c.igInvisibleButton(fmtZ("##dsize{d}", .{i}).ptr, v2(S(26), S(26)), 0)) {
                a.cfg.draw_size = @intCast(i);
                config.save(&a.cfg);
            }
            if (c.igIsItemHovered(0)) tooltipText(size_tips[i]);
            if (a.cfg.draw_size == i) rectFill(d, sx + S(2), ym - S(11), sx + S(24), ym + S(11), withAlpha(col.text, 30), S(6));
            const rad = @min(S(9), S(stroke_widths[i]) / 2 + S(1));
            c.ImDrawList_AddCircleFilled(d, v2(sx + S(13), ym), rad, if (i == 3) withAlpha(my_col, 110) else my_col, 0);
        }
        x += 4 * S(26) + S(6);
        rectFill(d, x, r[1] + S(8), x + S(1), r[3] - S(8), withAlpha(col.text, 30), 0);
        x += S(6);
        c.igSetCursorScreenPos(v2(x, ym - S(15)));
        if (iconButton("##dothers", if (a.cfg.show_drawings) ic.eye else ic.eye_slash, S(30), if (a.cfg.show_drawings) col.white else col.yellow, col.hover, if (a.cfg.show_drawings) tr("Esconder os desenhos dos outros (só pra você)") else tr("Mostrar os desenhos dos outros"))) {
            a.cfg.show_drawings = !a.cfg.show_drawings;
            config.save(&a.cfg);
        }
        x += S(32);
        c.igSetCursorScreenPos(v2(x, ym - S(15)));
        if (iconButton("##dclear", ic.eraser, S(30), col.white, col.hover, tr("Apagar os meus traços (ou botão direito)"))) {
            cl.addDraw(cl.my_id, t.ptr_stream, proto.draw_clear, &.{});
            cl.sendDraw(t.ptr_stream, proto.draw_clear, &.{});
        }
    }

    fn strokePoint(p: [2]u16, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c) c.ImVec2_c {
        const u = @as(f32, @floatFromInt(p[0])) / 65535.0;
        const v = @as(f32, @floatFromInt(p[1])) / 65535.0;
        return v2(ix + (u - uv0.x) / (uv1.x - uv0.x) * iw, iy + (v - uv0.y) / (uv1.y - uv0.y) * ih);
    }

    fn drawStrokes(a: *App, t: *const Tile, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c) void {
        const cl = a.client orelse return;
        const d = drawList();
        const now = sync.nowUs();
        var next: f64 = std.math.inf(f64);
        var pts: [client_mod.Stroke.max_points]c.ImVec2_c = undefined;
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.strokes.items) |*st| {
            if (st.stream != t.ptr_stream or st.n == 0) continue;
            const age = now -| st.last_us;
            if (age >= stroke_life_us) continue;
            const fade_from = stroke_life_us - 1_000_000;
            const alpha: u8 = if (age < fade_from) 230 else @intCast(230 * (stroke_life_us - age) / 1_000_000);
            // redesenha quando começar a sumir (e durante o sumiço)
            next = @min(next, if (age < fade_from) @as(f64, @floatFromInt(fade_from - age)) / 1e6 else 0.04);
            // desenhos dos outros escondidos (só do meu lado)
            if (!a.cfg.show_drawings and st.from != cl.my_id) continue;
            for (st.pts[0..st.n], 0..) |p, i| pts[i] = strokePoint(p, ix, iy, iw, ih, uv0, uv1);
            const ci = st.style >> proto.draw_color_shift;
            const size = (st.style >> proto.draw_size_shift) & 3;
            const base = if (ci == 0) avatarColor(st.from) else rgbRuntime(proto.draw_colors[ci]);
            // marca-texto: grosso e meio transparente
            const color = withAlpha(base, if (size == 3) alpha / 3 else alpha);
            const thick = S(stroke_widths[size]);
            a.strokes_drawn += 1;
            if (st.n == 1) {
                c.ImDrawList_AddCircleFilled(d, pts[0], thick * 0.8, color, 0);
            } else c.ImDrawList_AddPolyline(d, &pts, st.n, color, thick, 0);
        }
        if (next != std.math.inf(f64)) redrawIn(next);
    }

    fn updateDraw(a: *App, t: *const Tile, inside: bool, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c, mouse: c.ImVec2_c) void {
        const cl = a.client orelse return;
        const now = sync.nowUs();
        // o admin tirou o pincel: nada de desenhar
        if (a.myNoDraw(cl)) {
            a.draw_tile = null;
            a.draw_active = false;
            return;
        }
        // botão direito: apaga os meus traços nessa transmissão
        if (inside and c.igIsMouseClicked_Bool(1, false)) {
            cl.addDraw(cl.my_id, t.ptr_stream, proto.draw_clear, &.{});
            cl.sendDraw(t.ptr_stream, proto.draw_clear, &.{});
        }
        const down = c.igIsMouseDown_Nil(0);
        if (down and (a.draw_active or (inside and c.igIsMouseClicked_Bool(0, false)))) {
            if (!a.draw_active) {
                a.draw_active = true;
                a.draw_n = 0;
                a.draw_new = true;
            }
            const u = uv0.x + std.math.clamp((mouse.x - ix) / iw, 0, 1) * (uv1.x - uv0.x);
            const v = uv0.y + std.math.clamp((mouse.y - iy) / ih, 0, 1) * (uv1.y - uv0.y);
            const p = [2]u16{ @intFromFloat(std.math.clamp(u, 0, 1) * 65535), @intFromFloat(std.math.clamp(v, 0, 1) * 65535) };
            const moved = a.draw_n == 0 or @abs(@as(i32, p[0]) - @as(i32, a.draw_pts[a.draw_n - 1][0])) + @abs(@as(i32, p[1]) - @as(i32, a.draw_pts[a.draw_n - 1][1])) > 80;
            if (moved and a.draw_n < a.draw_pts.len) {
                a.draw_pts[a.draw_n] = p;
                a.draw_n += 1;
            }
        }
        // manda em pedacinhos (quem assiste vê o traço nascendo)
        if (a.draw_n > 0 and (a.draw_n == a.draw_pts.len or now - a.draw_sent_us > 33_000 or !down)) {
            const flags: u8 = (if (a.draw_new) proto.draw_new else 0) | a.drawStyle();
            cl.addDraw(cl.my_id, t.ptr_stream, flags, a.draw_pts[0..a.draw_n]);
            cl.sendDraw(t.ptr_stream, flags, a.draw_pts[0..a.draw_n]);
            // o próximo pedaço continua do último ponto (sem buraco no traço)
            a.draw_pts[0] = a.draw_pts[a.draw_n - 1];
            a.draw_n = if (down) 1 else 0;
            a.draw_new = false;
            a.draw_sent_us = now;
        }
        if (!down) a.draw_active = false;
    }

    // -------------------------------------------- recorte (um pedaço da tela)

    fn applyCrop(a: *App) void {
        if (a.sharer) |s| s.update(a.shareSettings());
    }

    fn cancelCrop(a: *App) void {
        a.crop_tile = null;
        a.crop_from = null;
        if (a.sharer) |sh| sh.preview_full.store(false, .release);
    }

    /// Escolheu: a transmissão passa a sair com esse recorte.
    fn finishCrop(a: *App, r: [4]f32) void {
        a.crop = r;
        a.cancelCrop();
        a.applyCrop();
    }

    fn updateCrop(a: *App, inside: bool, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c, mouse: c.ImVec2_c) void {
        const d = drawList();
        const norm = struct {
            fn f(m: c.ImVec2_c, x0: f32, y0: f32, w: f32, h: f32, a0: c.ImVec2_c, a1: c.ImVec2_c) [2]f32 {
                return .{
                    std.math.clamp(a0.x + std.math.clamp((m.x - x0) / w, 0, 1) * (a1.x - a0.x), 0, 1),
                    std.math.clamp(a0.y + std.math.clamp((m.y - y0) / h, 0, 1) * (a1.y - a0.y), 0, 1),
                };
            }
        }.f;
        rectFill(d, ix, iy, ix + iw, iy + ih, rgba(0x000000, 120), 0);
        const msg = tr("Arraste pra escolher o pedaço · botão direito: tela inteira · Esc: cancelar");
        const ms = textSizeF(font_semibold, 13, msg);
        rectFill(d, ix + (iw - ms.x) / 2 - S(10), iy + S(10), ix + (iw + ms.x) / 2 + S(10), iy + S(18) + ms.y, col.overlay, S(6));
        drawTextF(d, font_semibold, 13, v2(ix + (iw - ms.x) / 2, iy + S(14)), col.white, msg);
        a.crop_seen_frame = a.frame_no;
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) return a.cancelCrop();
        if (inside and c.igIsMouseClicked_Bool(1, false)) return a.finishCrop(.{ 0, 0, 1, 1 });
        if (inside and c.igIsMouseClicked_Bool(0, false)) a.crop_from = norm(mouse, ix, iy, iw, ih, uv0, uv1);
        const from = a.crop_from orelse return;
        const to = norm(mouse, ix, iy, iw, ih, uv0, uv1);
        const r = [4]f32{ @min(from[0], to[0]), @min(from[1], to[1]), @max(from[0], to[0]), @max(from[1], to[1]) };
        const p0 = strokePointF(r[0], r[1], ix, iy, iw, ih, uv0, uv1);
        const p1 = strokePointF(r[2], r[3], ix, iy, iw, ih, uv0, uv1);
        rectFill(d, p0.x, p0.y, p1.x, p1.y, withAlpha(col.blurple, 50), 0);
        c.ImDrawList_AddRect(d, p0, p1, col.blurple, 0, S(2), 0);
        if (!c.igIsMouseDown_Nil(0)) {
            a.crop_from = null;
            if (r[2] - r[0] >= 0.04 and r[3] - r[1] >= 0.04) a.finishCrop(r);
        }
    }

    fn strokePointF(u: f32, v: f32, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c) c.ImVec2_c {
        return v2(ix + (u - uv0.x) / (uv1.x - uv0.x) * iw, iy + (v - uv0.y) / (uv1.y - uv0.y) * ih);
    }

    fn stopPointer(a: *App) void {
        if (a.pointer_tile) |_| {
            if (a.pointer_shown) if (a.client) |cl| {
                // esconde nos dois tipos de stream possíveis desse quadro: manda pro último usado
                cl.sendPointer(a.pointer_stream_sent, proto.coord_none, proto.coord_none, 0);
            };
        }
        a.pointer_tile = null;
        a.pointer_shown = false;
    }

    fn drawEmpty(a: *App, cl: *Client, o: c.ImVec2_c, size: c.ImVec2_c) void {
        cl.mutex.lock();
        var live: [16]Member = undefined;
        var n_live: usize = 0;
        const my_id = cl.my_id;
        for (cl.members.items) |m| {
            if (m.streaming and m.id != my_id and n_live < live.len) {
                live[n_live] = m;
                n_live += 1;
            }
        }
        cl.mutex.unlock();

        // tudo numa área que rola: janela baixa não esconde mais nada
        c.igSetCursorScreenPos(o);
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, 0);
        c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, v2(S(8), S(8)));
        _ = c.igBeginChild_Str("emptyscroll", size, 0, 0);
        defer {
            c.igEndChild();
            c.igPopStyleVar(1);
            c.igPopStyleColor(2);
        }
        const d = drawList();
        const wo = c.igGetCursorScreenPos(); // já descontada a rolagem
        // fora de call: o palco é só o convite pra entrar numa
        cl.mutex.lock();
        const out_of_call = cl.chans_supported and cl.calls_known and cl.call_name_len == 0;
        var tb: [proto.channel_name_max]u8 = undefined;
        const tl = cl.chan_name_len;
        @memcpy(tb[0..tl], cl.chan_name[0..tl]);
        cl.mutex.unlock();
        if (out_of_call) {
            const cx0 = wo.x + size.x / 2;
            var yy = wo.y + size.y * 0.3;
            const isz0 = S(76);
            c.ImDrawList_AddCircleFilled(d, v2(cx0, yy + isz0 / 2), isz0 / 2, col.bg_side, 0);
            const ps = textSizeF(font_regular, 30, ic.phone_slash);
            drawTextF(d, font_regular, 30, v2(cx0 - ps.x / 2, yy + (isz0 - ps.y) / 2), col.muted, ic.phone_slash);
            yy += isz0 + S(18);
            const t0 = tr("Você está fora da call");
            const t0s = textSizeF(font_bold, 20, t0);
            drawTextF(d, font_bold, 20, v2(cx0 - t0s.x / 2, yy), col.header, t0);
            yy += t0s.y + S(6);
            const sub0 = tr("Entre na call de um canal pra ouvir, falar e ver as transmissões. O chat continua aqui do lado.");
            const cw0 = @min(S(520), size.x - S(40));
            pushFont(font_regular, 14);
            const sub0s = c.igCalcTextSize(sub0.ptr, sub0.ptr + sub0.len, false, cw0);
            popFont();
            drawTextWrapF(d, font_regular, 14, v2(cx0 - @min(cw0, sub0s.x) / 2, yy), col.muted, sub0, cw0);
            yy += sub0s.y + S(22);
            const bw0 = S(260);
            c.igSetCursorScreenPos(v2(cx0 - bw0 / 2, yy));
            c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameRounding, S(12) * col.round);
            if (primaryButton(fmtZ("{s}   Entrar na call do #{s}###joincall", .{ ic.phone, tb[0..tl] }), v2(bw0, S(42)), col.green, col.green_hover, col.green_active)) a.askChannel(cl, tb[0..tl], true);
            c.igPopStyleVar(1);
            c.igDummy(v2(1, S(20)));
            return;
        }
        const cw = @min(S(720), size.x - S(40));
        const cx = wo.x + size.x / 2;
        const host = a.server != null and n_live == 0;
        const short = size.y < S(560);
        // no meio quando cabe (altura do quadro anterior); senão do topo, rolando
        const top_pad: f32 = if (short) S(20) else S(28);
        var y = @round(wo.y + if (host) @max(top_pad, (size.y - a.empty_h) / 2) else size.y * 0.22);
        const y_start = y;

        const isz = if (short) S(56) else S(76);
        c.ImDrawList_AddCircleFilled(d, v2(cx, y + isz / 2), isz / 2, col.bg_side, 0);
        c.ImDrawList_AddCircle(d, v2(cx, y + isz / 2), isz / 2, withAlpha(col.text, 18), 0, S(1), 0);
        const ifs: f32 = if (short) 24 else 30;
        const its = textSizeF(font_regular, ifs, ic.tv);
        drawTextF(d, font_regular, ifs, v2(cx - its.x / 2, y + (isz - its.y) / 2), col.muted, ic.tv);
        y += isz + S(18);

        const title = if (n_live > 0) tr("Tem gente ao vivo!") else tr("Ninguém está transmitindo");
        const ts = textSizeF(font_bold, 20, title);
        drawTextF(d, font_bold, 20, v2(cx - ts.x / 2, y), col.header, title);
        y += ts.y + S(6);
        const sub = if (n_live > 0) tr("Escolhe quem assistir. Dá pra assistir várias telas ao mesmo tempo.") else tr("Clica em Compartilhar tela pra começar, ou espera alguém da sala.");
        const ss = textSizeF(font_regular, 14, sub);
        if (ss.x <= cw) {
            drawTextF(d, font_regular, 14, v2(cx - ss.x / 2, y), col.muted, sub);
            y += ss.y + S(20);
        } else {
            pushFont(font_regular, 14);
            const wrapped = c.igCalcTextSize(sub.ptr, sub.ptr + sub.len, false, cw);
            popFont();
            drawTextWrapF(d, font_regular, 14, v2(cx - cw / 2, y), col.muted, sub, cw);
            y += wrapped.y + S(20);
        }

        if (n_live > 0) {
            const card_w = S(220);
            const card_h = S(150);
            const gap = S(14);
            const per_row = @max(1, @min(n_live, @as(usize, @intFromFloat((size.x - S(40) + gap) / (card_w + gap)))));
            var bottom = y;
            for (live[0..n_live], 0..) |*m, i| {
                const row = i / per_row;
                const colx = i % per_row;
                const in_row = @min(per_row, n_live - row * per_row);
                const row_w = @as(f32, @floatFromInt(in_row)) * card_w + @as(f32, @floatFromInt(in_row - 1)) * gap;
                const x = cx - row_w / 2 + @as(f32, @floatFromInt(colx)) * (card_w + gap);
                const yy = y + @as(f32, @floatFromInt(row)) * (card_h + gap);
                c.igPushID_Int(@intCast(m.id));
                c.igSetCursorScreenPos(v2(x, yy));
                const clicked = c.igInvisibleButton("card", v2(card_w, card_h), 0);
                const hov = c.igIsItemHovered(0);
                rectFill(d, x, yy, x + card_w, yy + card_h, if (hov) col.selected else col.bg_side, S(12));
                c.ImDrawList_AddRect(d, v2(x, yy), v2(x + card_w, yy + card_h), withAlpha(col.text, if (hov) 40 else 18), S(12) * col.round, S(1), 0);
                drawAvatar(d, v2(x + card_w / 2, yy + S(42)), S(26), m.id, m.nameSlice(), true);
                const nts = textSizeF(font_semibold, 15, m.nameSlice());
                drawTextF(d, font_semibold, 15, v2(x + (card_w - nts.x) / 2, yy + S(76)), col.header, m.nameSlice());
                const btn = fmtZ("{s}  Assistir", .{ic.eye});
                const bts = textSizeF(font_semibold, 13.5, btn);
                const bx0 = x + S(16);
                const by0 = yy + card_h - S(44);
                rectFill(d, bx0, by0, x + card_w - S(16), by0 + S(30), if (hov) col.blurple_hover else col.blurple, S(8));
                drawTextF(d, font_semibold, 13.5, v2(x + (card_w - bts.x) / 2, by0 + (S(30) - bts.y) / 2), col.white, btn);
                if (clicked) a.watch(m.id);
                c.igPopID();
                bottom = yy + card_h;
            }
            c.igSetCursorScreenPos(v2(wo.x, bottom));
            c.igDummy(v2(1, S(20)));
        } else {
            c.igSetCursorScreenPos(v2(cx - S(100), y));
            const lbl = fmtZ("{s}   Compartilhar tela###shareempty", .{ic.desktop});
            c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameRounding, S(12) * col.round);
            if (primaryButton(lbl, v2(S(200), S(42)), col.blurple, col.blurple_hover, col.blurple_active)) a.openShareModal();
            c.igPopStyleVar(1);
            y += S(42) + (if (short) S(24) else S(36));
            if (a.server) |s| {
                c.igSetCursorScreenPos(v2(cx - cw / 2, y));
                a.drawHostTips(s, cw);
            }
            a.empty_h = c.igGetCursorScreenPos().y - y_start;
            c.igDummy(v2(1, S(20)));
        }
    }

    /// Um cartão com fundo atrás do conteúdo (o fundo é desenhado depois de
    /// medir, num canal de baixo). `h_min`: altura mínima (cartões lado a lado
    /// ficam do mesmo tamanho).
    const Card = struct {
        p0: c.ImVec2_c,
        w: f32,
        fn begin(d: *c.ImDrawList, w: f32) Card {
            const p0 = c.igGetCursorScreenPos();
            c.ImDrawList_ChannelsSplit(d, 2);
            c.ImDrawList_ChannelsSetCurrent(d, 1);
            c.igSetCursorScreenPos(v2(p0.x + S(18), p0.y + S(16)));
            c.igBeginGroup();
            return .{ .p0 = p0, .w = w };
        }
        /// Fecha o cartão; devolve a altura que ele precisou.
        fn end(card: Card, d: *c.ImDrawList, h_min: f32, accent: ?u32) f32 {
            c.igEndGroup();
            const mx = c.igGetItemRectMax();
            const h = @max(h_min, mx.y - card.p0.y + S(16));
            c.ImDrawList_ChannelsSetCurrent(d, 0);
            const p = card.p0;
            rectFill(d, p.x, p.y, p.x + card.w, p.y + h, col.bg_side, S(14));
            c.ImDrawList_AddRect(d, p, v2(p.x + card.w, p.y + h), if (accent) |ac| withAlpha(ac, 120) else withAlpha(col.text, 18), S(14) * col.round, S(1), 0);
            c.ImDrawList_ChannelsMerge(d);
            c.igSetCursorScreenPos(v2(p.x, p.y + h));
            c.igDummy(v2(card.w, 0));
            return h;
        }
    };

    /// Ícone redondo + título de um cartão.
    fn cardTitle(d: *c.ImDrawList, glyph: []const u8, tint: u32, title: []const u8) void {
        const p = c.igGetCursorScreenPos();
        const r = S(15);
        c.ImDrawList_AddCircleFilled(d, v2(p.x + r, p.y + r), r, withAlpha(tint, 40), 0);
        const gs = textSizeF(font_regular, 13, glyph);
        drawTextF(d, font_regular, 13, v2(p.x + r - gs.x / 2, p.y + r - gs.y / 2), tint, glyph);
        drawTextF(d, font_bold, 14.5, v2(p.x + r * 2 + S(10), p.y + r - S(9)), col.header, title);
        c.igDummy(v2(r * 2, r * 2 + S(4)));
    }

    fn wrapText(color: u32, size: f32, text: []const u8, w: f32) void {
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, size);
        textColored(color, text);
        popFont();
        c.igPopTextWrapPos();
    }

    /// Caixa com o endereço que está no ar (bolinha verde).
    fn addrBox(d: *c.ImDrawList, addr: []const u8, w: f32) void {
        const p = c.igGetCursorScreenPos();
        const h = S(34);
        rectFill(d, p.x, p.y, p.x + w, p.y + h, col.input, S(8));
        drawTextF(d, font_regular, 11, v2(p.x + S(12), p.y + (h - S(13)) / 2), col.green, ic.circle);
        c.ImDrawList_PushClipRect(d, p, v2(p.x + w - S(8), p.y + h), true);
        drawTextF(d, font_semibold, 14, v2(p.x + S(32), p.y + (h - S(18)) / 2), col.header, addr);
        c.ImDrawList_PopClipRect(d);
        c.igDummy(v2(w, h));
    }

    /// "Chamando a galera de fora": link público e porta no roteador (cartões
    /// lado a lado, ou um embaixo do outro em janela estreita) e o túnel
    /// próprio. Tudo em fluxo: a altura sai do conteúdo.
    fn drawHostTips(a: *App, s: *Server, w: f32) void {
        const d = drawList();
        const x0 = c.igGetCursorScreenPos().x;
        c.igBeginGroup();
        defer c.igEndGroup();
        pushFont(font_bold, 15);
        textColored(col.header, fmtZ("{s}  Chamando a galera de fora", .{ic.link}));
        popFont();
        wrapText(col.muted, 13, tr("Na mesma rede (ou VPN) o convite já funciona. Pra quem está longe, escolhe um caminho; o convite leva todos que estiverem abertos, e tudo vai cifrado."), w);
        c.igDummy(v2(0, S(4)));

        const st: ?tunnel_mod.Status = if (a.tunnel) |t| t.status() else null;
        const bh = S(38);
        if (a.upnp == null and st == null) {
            const side = w >= S(560);
            const cwid = if (side) (w - S(12)) / 2 else w;
            const inner = cwid - S(36);
            const row_y = c.igGetCursorScreenPos().y;
            // link público
            var card = Card.begin(d, cwid);
            cardTitle(d, ic.globe, col.blurple, tr("Link público"));
            wrapText(col.muted, 13, fmtZ("Funciona em qualquer rede, pelo {s}. Um tiquinho mais de atraso.", .{config.getStr(&a.cfg.tunnel_host)}), inner);
            c.igDummy(v2(0, S(2)));
            const extra = @max(0, a.tips_card_h - a.tips_body_h[0]);
            if (side and extra > 0) c.igDummy(v2(0, extra));
            if (primaryButton(fmtZ("{s}  Criar link público###tunnelgo", .{ic.globe}), v2(inner, bh), col.blurple, col.blurple_hover, col.blurple_active)) a.startTunnel();
            const h1 = card.end(d, 0, null);
            a.tips_body_h[0] = h1 - extra;
            // porta no roteador
            if (side) c.igSetCursorScreenPos(v2(x0 + cwid + S(12), row_y)) else c.igDummy(v2(0, S(4)));
            card = Card.begin(d, cwid);
            cardTitle(d, ic.tower, col.green, tr("Porta no roteador"));
            wrapText(col.muted, 13, tr("Conexão direta (UPnP ou NAT-PMP): menos atraso. Nem todo roteador ou operadora deixa."), inner);
            c.igDummy(v2(0, S(2)));
            const extra2 = @max(0, a.tips_card_h - a.tips_body_h[1]);
            if (side and extra2 > 0) c.igDummy(v2(0, extra2));
            if (secondaryButton(fmtZ("{s}  Abrir porta no roteador###upnpgo", .{ic.link}), v2(inner, bh))) a.startUpnp();
            const h2 = card.end(d, 0, null);
            a.tips_body_h[1] = h2 - extra2;
            a.tips_card_h = @max(a.tips_body_h[0], a.tips_body_h[1]);
            if (side) {
                c.igSetCursorScreenPos(v2(x0, row_y + @max(h1, h2)));
                c.igDummy(v2(w, 0));
            }
        } else {
            const inner = w - S(36);
            if (a.upnp) |m| {
                const ust = m.status();
                const card = Card.begin(d, w);
                a.drawUpnpState(m, d, inner);
                _ = card.end(d, 0, if (ust.state == .ready) col.green else if (ust.state == .failed) col.red else null);
            } else {
                const tst = st.?;
                const card = Card.begin(d, w);
                switch (tst.state) {
                    .connecting => {
                        spinnerTitle(d, fmtZ("Abrindo o link público no {s}…", .{a.tunnel.?.hostSlice()}));
                        wrapText(col.muted, 13, tr("Leva só alguns segundos."), inner);
                        c.igDummy(v2(0, S(2)));
                        if (secondaryButton(tr("Cancelar##tunel"), v2(S(120), bh))) a.stopTunnel();
                    },
                    .ready => {
                        cardTitle(d, ic.globe, col.green, tr("Link público no ar"));
                        wrapText(col.muted, 13, tr("Manda o convite pra galera:"), inner);
                        var abuf: [300]u8 = undefined;
                        addrBox(d, a.tunnel.?.address(&abuf), inner);
                        const half = (inner - S(10)) / 2;
                        if (primaryButton(fmtZ("{s}  Copiar convite##tunel", .{ic.user_plus}), v2(half, bh), col.blurple, col.blurple_hover, col.blurple_active)) a.copyInvite();
                        c.igSameLine(0, S(10));
                        if (secondaryButton(fmtZ("{s}  Desligar###tunneloff", .{ic.power}), v2(half, bh))) a.stopTunnel();
                    },
                    .failed => {
                        cardTitle(d, ic.warn, col.red, tr("Não deu pra abrir o link público"));
                        var eb: [300]u8 = undefined;
                        wrapText(col.muted, 13, i18n.dynamic(tst.err, &eb), inner);
                        c.igDummy(v2(0, S(2)));
                        if (primaryButton(fmtZ("{s}  Tentar de novo###tunnelretry", .{ic.rotate}), v2(S(180), bh), col.blurple, col.blurple_hover, col.blurple_active)) {
                            a.stopTunnel();
                            a.startTunnel();
                        }
                        c.igSameLine(0, S(10));
                        if (secondaryButton(tr("Fechar##tunel"), v2(S(110), bh))) a.stopTunnel();
                    },
                }
                _ = card.end(d, 0, if (tst.state == .ready) col.green else if (tst.state == .failed) col.red else null);
            }
        }

        // alternativa: túnel próprio (ngrok, bore, ssh)
        c.igDummy(v2(0, S(6)));
        {
            const toggle = fmtZ("{s}  Prefere seu próprio túnel? (ngrok, bore, ssh)", .{if (a.own_tunnel_open) ic.chev_up else ic.chev_down});
            const ts = textSizeF(font_semibold, 13, toggle);
            const p = c.igGetCursorScreenPos();
            if (c.igInvisibleButton("##own", v2(ts.x, ts.y + S(8)), 0)) {
                a.own_tunnel_open = !a.own_tunnel_open;
                a.own_scroll = a.own_tunnel_open; // abriu: rola até o cartão aparecer inteiro
            }
            drawTextF(d, font_semibold, 13, v2(p.x, p.y + S(4)), if (c.igIsItemHovered(0)) col.text else col.muted, toggle);
        }
        if (!a.own_tunnel_open) return;
        const card = Card.begin(d, w);
        const inner = w - S(36);
        const cmds = [_][:0]const u8{
            fmtCmd(0, "ngrok tcp {d}", s.port),
            fmtCmd(1, "bore local {d} --to bore.pub", s.port),
            fmtCmd(2, "ssh -p 443 -R0:localhost:{d} tcp@a.pinggy.io", s.port),
            fmtCmd(3, "ssh -R 0:localhost:{d} serveo.net", s.port),
        };
        for (cmds, 0..) |cmd, i| {
            const p = c.igGetCursorScreenPos();
            const rh = S(30);
            rectFill(d, p.x, p.y, p.x + inner, p.y + rh, col.input, S(8));
            drawTextF(d, font_regular, 13, v2(p.x + S(12), p.y + (rh - S(16)) / 2), col.text, cmd);
            c.igSetCursorScreenPos(v2(p.x + inner - rh, p.y));
            c.igPushID_Int(@intCast(i));
            if (iconButton("##cp", ic.copy, rh, col.muted, col.hover, tr("Copiar"))) c.igSetClipboardText(cmd.ptr);
            c.igPopID();
            c.igSetCursorScreenPos(v2(p.x, p.y + rh + S(6)));
        }
        c.igDummy(v2(0, S(2)));
        wrapText(col.muted, 13, tr("Cola aqui o endereço que o túnel mostrou e copia o convite:"), inner);
        const bw = S(150);
        _ = textField("##pub", "ex.: 0.tcp.sa.ngrok.io:12345", &a.cfg.public_addr, inner - bw - S(10), false);
        c.igSameLine(0, S(10));
        if (primaryButton(fmtZ("{s}  Copiar convite##proprio", .{ic.user_plus}), v2(bw, S(37)), col.blurple, col.blurple_hover, col.blurple_active)) {
            config.save(&a.cfg);
            a.stopTunnel(); // vale o endereço digitado
            a.copyInvite();
        }
        // os outros jeitos (VPN de jogo, abrir porta na mão, CGNAT...): o guia
        c.igDummy(v2(0, S(4)));
        if (c.igSmallButton(fmtZ("{s}  Mais jeitos de conectar (sem conta, VPN, porta na mão)###guia", .{ic.link}))) openGuide();
        _ = card.end(d, 0, null);
        if (a.own_scroll) {
            a.own_scroll = false;
            c.igSetScrollHereY(1.0);
        }
    }

    /// Título com uma bolinha girando (esperando o túnel/roteador).
    fn spinnerTitle(d: *c.ImDrawList, title: []const u8) void {
        const p = c.igGetCursorScreenPos();
        const r = S(15);
        const ctr = v2(p.x + r, p.y + r);
        c.ImDrawList_AddCircleFilled(d, ctr, r, withAlpha(col.blurple, 40), 0);
        const t: f32 = @floatCast(c.igGetTime());
        c.ImDrawList_PathArcTo(d, ctr, r * 0.55, t * 6, t * 6 + 4.2, 16);
        c.ImDrawList_PathStroke(d, col.blurple, S(2.2), 0);
        drawTextF(d, font_bold, 14.5, v2(p.x + r * 2 + S(10), p.y + r - S(9)), col.header, title);
        c.igDummy(v2(r * 2, r * 2 + S(4)));
        redrawIn(0.05);
    }

    var cmd_bufs: [4][80]u8 = undefined;
    fn fmtCmd(i: usize, comptime f: []const u8, port: u16) [:0]const u8 {
        return std.fmt.bufPrintZ(&cmd_bufs[i], f, .{port}) catch "";
    }

    // ------------------------------------------------------------------ chat

    /// Arquivos soltos na janela e o resultado das imagens sendo preparadas.
    fn checkChatImages(a: *App) void {
        if (n_drops > 0) {
            for (0..n_drops) |i| {
                const p = drop_paths[i][0..drop_lens[i]];
                if (a.screen != .room or a.client == null) {
                    a.toast("Entre numa sala pra mandar imagem ou arquivo no chat.", .{}, true);
                    break;
                }
                a.sendPath(a.client.?, p);
            }
            n_drops = 0;
        }
        const f = chatsend.failed.load(.acquire);
        if (f != a.img_failed_seen) {
            a.img_failed_seen = f;
            a.toast("Não mandei a imagem: {s}.", .{chatsend.failureText(@enumFromInt(chatsend.last_error.load(.acquire)))}, true);
        }
        a.img_sent_seen = chatsend.sent.load(.acquire);
    }

    /// Textura da imagem da mensagem (decodifica na primeira vez). null = não deu.
    /// A imagem da mensagem: pronta (tex != 0), decodificando (tex == 0) ou null (com defeito).
    fn chatImageTex(a: *App, line: *const client_mod.ChatLine) ?*ImgTex {
        var free_i: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&a.img_cache, 0..) |*e, i| {
            if (e.id == line.id and e.id != 0) {
                e.used = a.frame_no;
                if (e.job) |jb| if (jb.done.load(.acquire)) {
                    if (jb.px.len > 0) gl.upload(&e.tex, jb.px, jb.tw, jb.th, gl.RGBA) else e.failed = true;
                    jb.release();
                    e.job = null;
                };
                return if (e.failed) null else e;
            }
            if (e.used < oldest) {
                oldest = e.used;
                free_i = i;
            }
        }
        const e = &a.img_cache[free_i];
        gl.delete(&e.tex);
        if (e.job) |jb| jb.release(); // a thread termina e solta sozinha
        e.* = .{ .id = line.id, .used = a.frame_no, .w = line.img_w, .h = line.img_h };
        const data = line.img orelse {
            e.failed = true;
            return null;
        };
        const jb = std.heap.c_allocator.create(ImgJob) catch {
            e.failed = true;
            return null;
        };
        jb.* = .{ .data = std.heap.c_allocator.dupe(u8, data) catch {
            std.heap.c_allocator.destroy(jb);
            e.failed = true;
            return null;
        }, .w = line.img_w, .h = line.img_h };
        sync.spawn(ImgJob.run, .{jb}) catch {
            jb.refs.store(1, .monotonic);
            jb.release();
            e.failed = true;
            return null;
        };
        e.job = jb;
        return e;
    }

    /// Textura da imagem aberta em tela cheia (resolução inteira; uma só).
    fn viewerTex(a: *App, id: u32) bool {
        if (a.view_tex != 0 and a.view_tex_id == id) return true;
        gl.delete(&a.view_tex);
        const cl = a.client orelse return false;
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.chat.items) |*line| {
            if (line.id != id) continue;
            const data = line.img orelse return false;
            const px = chatimg.decode(data, line.img_w, line.img_h) catch return false;
            defer std.heap.c_allocator.free(px);
            gl.upload(&a.view_tex, px, line.img_w, line.img_h, gl.RGBA);
            a.view_tex_id = id;
            return true;
        }
        return false;
    }

    fn clearChatImages(a: *App) void {
        for (&a.img_cache) |*e| {
            gl.delete(&e.tex);
            if (e.job) |jb| jb.release();
            e.* = .{};
        }
        a.img_view = null;
        gl.delete(&a.view_tex);
    }

    /// Reações embaixo da mensagem (as que alguém deu). Clique liga/desliga a sua.
    /// Reações embaixo da mensagem (pílulas): ícone + quantos. Clique liga/desliga a sua.
    fn drawReactionChips(a: *App, cl: *Client, line: *const client_mod.ChatLine, me: u32, left: f32, max_x: f32) void {
        _ = a;
        if (line.n_reacts == 0) return;
        const h = S(24);
        var x = left;
        var y = c.igGetCursorScreenPos().y + S(4);
        const d = drawList();
        for (0..proto.reactions) |e| {
            const rc = line.reactCount(@intCast(e), me);
            if (rc.n == 0) continue;
            // (o número num buffer só dele: o fmtZ é compartilhado e o id do
            // botão logo abaixo apagava o número, que saía como "#")
            var nb: [8]u8 = undefined;
            const label = std.fmt.bufPrintZ(&nb, "{d}", .{rc.n}) catch "?";
            const tw = textSizeF(font_semibold, 12.5, label).x;
            const w = S(36) + tw;
            if (x + w > max_x and x > left) {
                x = left;
                y += h + S(4);
            }
            var ib: [40]u8 = undefined;
            const id = std.fmt.bufPrintZ(&ib, "##chip{d}_{d}", .{ line.id, e }) catch "##chip";
            c.igSetCursorScreenPos(v2(x, y));
            const clicked = c.igInvisibleButton(id.ptr, v2(w, h), 0);
            const hov = c.igIsItemHovered(0);
            rectFill(d, x, y, x + w, y + h, if (rc.mine) withAlpha(col.blurple, 60) else if (hov) col.hover else withAlpha(col.text, 14), h / 2);
            c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), if (rc.mine) col.blurple else withAlpha(col.text, 26), h / 2 * col.round, S(1), 0);
            drawTextF(d, font_regular, 12.5, v2(x + S(10), y + S(5)), reaction_colors[e], reaction_icons[e]);
            drawTextF(d, font_semibold, 12.5, v2(x + S(28), y + S(4)), col.text, label);
            if (hov) tooltipText(reactionName(e));
            if (clicked) cl.sendReact(line.id, @intCast(e), !rc.mine);
            x += w + S(6);
        }
        c.igSetCursorScreenPos(v2(left, y + h + S(2)));
        c.igDummy(v2(0, 0));
    }

    /// Imagem aberta em tela cheia (clique ou Esc fecha).
    fn drawImageViewer(a: *App, size: c.ImVec2_c) void {
        const id = a.img_view orelse return;
        const e = for (&a.img_cache) |*x| {
            if (x.id == id and x.tex != 0) break x;
        } else {
            a.img_view = null;
            return;
        };
        const d = beginOverlay("##imgview", size, rgba(0x000000, 225));
        defer c.igEnd();
        const ar = @as(f32, @floatFromInt(e.w)) / @as(f32, @floatFromInt(e.h));
        var w = @min(size.x * 0.92, @as(f32, @floatFromInt(e.w)) * 2);
        var h = w / ar;
        if (h > size.y * 0.88) {
            h = size.y * 0.88;
            w = h * ar;
        }
        const x = (size.x - w) / 2;
        const y = (size.y - h) / 2;
        // resolução inteira (se não der, a miniatura esticada)
        const tex = if (a.viewerTex(id)) a.view_tex else e.tex;
        c.ImDrawList_AddImage(d, .{ ._TexData = null, ._TexID = tex }, v2(x, y), v2(x + w, y + h), v2(0, 0), v2(1, 1), 0xFFFFFFFF);
        drawTextF(d, font_regular, 13, v2(x, y + h + S(8)), col.muted, fmtZ("{d} x {d} · clique ou Esc pra fechar", .{ e.w, e.h }));
        c.igSetCursorScreenPos(v2(0, 0));
        if (c.igInvisibleButton("##imgclose", size, 0) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            a.img_view = null;
            gl.delete(&a.view_tex); // 10 MB de textura que ninguém está vendo
        }
    }

    /// Sugestões de @menção pro fim do que está digitado ("@an" → "Ana").
    fn updateMentionSuggestions(a: *App, cl: *Client) void {
        a.n_mention_sugg = 0;
        const text = std.mem.sliceTo(&a.chat_input, 0);
        const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return;
        if (at > 0 and text[at - 1] != ' ') return;
        const typed = text[at + 1 ..];
        if (std.mem.indexOfScalar(u8, typed, ' ') != null) return;
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.members.items) |*m| {
            if (m.id == cl.my_id or a.n_mention_sugg == a.mention_sugg.len) continue;
            const name = m.nameSlice();
            if (typed.len > name.len or !std.ascii.eqlIgnoreCase(name[0..typed.len], typed)) continue;
            const n = @min(name.len, 48);
            @memcpy(a.mention_sugg[a.n_mention_sugg][0..n], name[0..n]);
            a.mention_sugg_len[a.n_mention_sugg] = n;
            a.n_mention_sugg += 1;
        }
    }

    /// Imagem dentro da mensagem (clique abre em tela cheia).
    fn drawChatLineImage(a: *App, line: *const client_mod.ChatLine, max_w: f32) void {
        const e = a.chatImageTex(line) orelse {
            pushFont(font_regular, 13);
            textColored(col.faint, fmtZ("{s}  imagem com defeito", .{ic.image}));
            popFont();
            return;
        };
        const iw: f32 = @floatFromInt(e.w);
        const ih: f32 = @floatFromInt(e.h);
        const sc = @min(@min(1.0, max_w / iw), S(240) / ih);
        const w = @max(S(24), iw * sc);
        const h = @max(S(24), ih * sc);
        const p = c.igGetCursorScreenPos();
        c.igSetNextItemAllowOverlap(); // a barra de reações fica por cima
        if (c.igInvisibleButton(fmtZ("##img{d}", .{line.id}).ptr, v2(w, h), 0)) a.img_view = line.id;
        if (c.igIsItemHovered(0)) c.igSetMouseCursor(c.ImGuiMouseCursor_Hand);
        if (e.tex == 0) {
            // ainda decodificando: o espaço dela já fica reservado (nada pula quando chega)
            rectFill(drawList(), p.x, p.y, p.x + w, p.y + h, withAlpha(col.text, 18), S(6));
            return;
        }
        c.ImDrawList_AddImageRounded(drawList(), .{ ._TexData = null, ._TexID = e.tex }, p, v2(p.x + w, p.y + h), v2(0, 0), v2(1, 1), 0xFFFFFFFF, S(6) * col.round, 0);
    }

    fn pickMention(a: *App, i: usize) void {
        const n = a.mention_sugg_len[i];
        @memcpy(a.mention_apply[0..n], a.mention_sugg[i][0..n]);
        a.mention_apply_len = n;
    }

    /// Manda um arquivo escolhido/solto: imagem vai como imagem no chat; o
    /// resto vira anexo (pra onde a caixa aponta: canal ou privada, resposta).
    fn sendPath(a: *App, cl: *Client, path: []const u8) void {
        if (chatsend.looksLikeImage(path)) return chatsend.sendFile(cl, path);
        if (cl.server_features & proto.srv_files == 0) {
            a.toast("Esse servidor não recebe arquivos (é de uma versão mais velha do telinha); dá pra mandar imagem.", .{}, true);
            return;
        }
        filexfer.upload(cl, path, a.dm_to, a.reply_id) catch |e| {
            a.toast("{s}", .{switch (e) {
                error.TooBig => tr("Arquivo grande demais (até 256 MB)."),
                error.Empty => tr("O arquivo está vazio."),
                else => tr("Não consegui abrir o arquivo."),
            }}, true);
            return;
        };
        a.reply_id = 0;
    }

    /// Barra de um arquivo subindo: nome, quanto foi, velocidade e o X.
    fn uploadBar(a: *App, cl: *Client, d: *c.ImDrawList, p: c.ImVec2_c, w: f32, h: f32, t: *filexfer.Transfer, i: usize) void {
        const st = t.state.load(.acquire);
        switch (st) {
            .done => return cl.xfers.forget(t),
            .failed => {
                var eb: [300]u8 = undefined;
                a.toast("Não mandei {s}: {s}", .{ t.nameSlice(), i18n.dynamic(t.errSlice(), &eb) }, true);
                return cl.xfers.forget(t);
            },
            .canceled => return cl.xfers.forget(t),
            else => {},
        }
        const x0 = p.x + S(12);
        const x1 = p.x + w - S(12);
        const prog = t.progress();
        rectFill(d, x0, p.y + S(4), x1, p.y + h, withAlpha(col.green, 22), S(6));
        rectFill(d, x0, p.y + h - S(3), x0 + (x1 - x0) * prog, p.y + h, col.green, S(2));
        var sb: [24]u8 = undefined;
        var rb: [24]u8 = undefined;
        const title = if (st == .waiting) fmtZ("{s}  {s}", .{ ic.paperclip, t.nameSlice() }) else fmtZ("{s}  {s}   {d}% · {s}/s", .{ ic.paperclip, t.nameSlice(), @as(u32, @intFromFloat(prog * 100)), humanSize(t.rate(), &rb) });
        _ = &sb;
        c.ImDrawList_PushClipRect(d, v2(x0, p.y), v2(x1 - S(30), p.y + h), true);
        drawTextF(d, font_semibold, 12.5, v2(x0 + S(10), p.y + S(8)), col.text, title);
        c.ImDrawList_PopClipRect(d);
        const back = c.igGetCursorScreenPos();
        c.igSetCursorScreenPos(v2(x1 - S(26), p.y + S(5)));
        if (iconButton(fmtZ("##upcancel{d}", .{i}), ic.xmark, S(22), col.muted, col.hover, tr("Cancelar"))) t.cancel();
        c.igSetCursorScreenPos(back);
        redrawIn(0.25);
    }

    /// Cartão do arquivo anexado numa mensagem: nome, tamanho e baixar /
    /// baixando / abrir.
    fn drawFileCard(a: *App, cl: *Client, line: *const client_mod.ChatLine, max_w: f32) void {
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        const w = @min(max_w, S(380));
        const h = S(54);
        rectFill(d, p.x, p.y + S(2), p.x + w, p.y + h, col.input, S(8));
        drawTextF(d, font_regular, 20, v2(p.x + S(12), p.y + S(15)), col.blurple, ic.file);
        var sb: [24]u8 = undefined;
        const name = line.fileName();
        noteEmoji(name);
        // nome comprido: corta no meio (a extensão continua aparecendo); inteiro com o mouse em cima
        var nmb: [proto.file_name_max + 8]u8 = undefined;
        const name_end = p.x + w - S(140); // à direita: abrir + o botão
        const shown = ellipsizeMiddle(font_semibold, 13.5, name, name_end - p.x - S(42), &nmb);
        drawTextF(d, font_semibold, 13.5, v2(p.x + S(42), p.y + S(10)), col.text, shown);
        if (shown.len != name.len and c.igIsMouseHoveringRect(v2(p.x, p.y), v2(name_end, p.y + h), true)) tooltipText(fmtZ("{s}", .{name}));
        const dl = cl.xfers.download(line.file_id);
        defer if (dl) |t| t.release();
        const bx = p.x + w - S(88);
        const by = p.y + S(12);
        c.igSetCursorScreenPos(v2(bx, by));
        if (dl) |t| switch (t.state.load(.acquire)) {
            .running, .waiting => {
                const prog = t.progress();
                var rb: [24]u8 = undefined;
                drawTextF(d, font_regular, 12, v2(p.x + S(42), p.y + S(31)), col.muted, fmtZ("{d}% · {s}/s", .{ @as(u32, @intFromFloat(prog * 100)), humanSize(t.rate(), &rb) }));
                rectFill(d, p.x + S(42), p.y + h - S(6), p.x + w - S(100), p.y + h - S(3), withAlpha(col.text, 30), S(2));
                rectFill(d, p.x + S(42), p.y + h - S(6), p.x + S(42) + (w - S(142)) * prog, p.y + h - S(3), col.blurple, S(2));
                if (secondaryButton(fmtZ("{s}##dlx{d}", .{ tr("Cancelar"), line.file_id }), v2(S(80), S(30)))) t.cancel();
                redrawIn(0.25);
            },
            .done => {
                drawTextF(d, font_regular, 12, v2(p.x + S(42), p.y + S(31)), col.green, fmtZ("{s}  {s}", .{ ic.download, humanSize(line.file_size, &sb) }));
                const runnable = looksRunnable(name);
                if (!runnable) {
                    c.igSetCursorScreenPos(v2(bx - S(44), by));
                    if (iconButton(fmtZ("##dlopen{d}", .{line.file_id}), ic.file, S(30), col.muted, col.hover, tr("Abrir"))) _ = openPath(t.pathSlice());
                    c.igSetCursorScreenPos(v2(bx, by));
                }
                if (secondaryButton(fmtZ("{s}##dlf{d}", .{ tr("Pasta"), line.file_id }), v2(S(80), S(30)))) {
                    const pth = t.pathSlice();
                    const cut = std.mem.lastIndexOfAny(u8, pth, "/\\") orelse pth.len;
                    _ = openPath(pth[0..cut]);
                }
            },
            .failed, .canceled => {
                var eb: [300]u8 = undefined;
                const why = if (t.state.load(.acquire) == .failed) i18n.dynamic(t.errSlice(), &eb) else tr("cancelado");
                c.ImDrawList_PushClipRect(d, v2(p.x, p.y), v2(bx - S(6), p.y + h), true);
                drawTextF(d, font_regular, 12, v2(p.x + S(42), p.y + S(31)), col.red, why);
                c.ImDrawList_PopClipRect(d);
                if (primaryButton(fmtZ("{s}##dl{d}", .{ tr("De novo"), line.file_id }), v2(S(80), S(30)), col.blurple, col.blurple_hover, col.blurple_active)) {
                    cl.xfers.forget(t);
                    a.startDownload(cl, line);
                }
            },
        } else {
            drawTextF(d, font_regular, 12, v2(p.x + S(42), p.y + S(31)), col.muted, humanSize(line.file_size, &sb));
            if (primaryButton(fmtZ("{s}  {s}##dl{d}", .{ ic.download, tr("Baixar"), line.file_id }), v2(S(80), S(30)), col.blurple, col.blurple_hover, col.blurple_active)) a.startDownload(cl, line);
        }
        c.igSetCursorScreenPos(p);
        c.igDummy(v2(w, h + S(4)));
    }

    fn startDownload(a: *App, cl: *Client, line: *const client_mod.ChatLine) void {
        const t = filexfer.download(cl, line.file_id, line.fileName(), line.file_size) catch {
            a.toast("Não consegui criar o arquivo na pasta de downloads.", .{}, true);
            return;
        };
        t.release();
    }

    /// A caixa de mensagem passa a ir em privado pra essa pessoa.
    fn startDm(a: *App, id: u32, name: []const u8) void {
        a.dm_to = id;
        copyName(&a.dm_name, &a.dm_name_len, name);
    }

    /// Barra em cima da caixa de mensagem (respondendo / privado pra): ícone,
    /// título, um trecho (cortado) e o X. true = clicou no X.
    fn composeBar(a: *App, d: *c.ImDrawList, p: c.ImVec2_c, w: f32, h: f32, icon: []const u8, color: u32, title: []const u8, snip: []const u8, comptime close_id: [:0]const u8) bool {
        _ = a;
        const x0 = p.x + S(12);
        const x1 = p.x + w - S(12);
        rectFill(d, x0, p.y + S(4), x1, p.y + h, withAlpha(color, 30), S(6));
        drawTextF(d, font_regular, 12, v2(x0 + S(10), p.y + S(9)), color, icon);
        drawTextF(d, font_semibold, 12.5, v2(x0 + S(30), p.y + S(8)), col.text, title);
        if (snip.len > 0) {
            const sx = x0 + S(38) + textSizeF(font_semibold, 12.5, title).x;
            c.ImDrawList_PushClipRect(d, v2(sx, p.y), v2(x1 - S(30), p.y + h), true);
            drawTextF(d, font_regular, 12.5, v2(sx, p.y + S(8)), col.muted, snip);
            c.ImDrawList_PopClipRect(d);
        }
        const back = c.igGetCursorScreenPos();
        c.igSetCursorScreenPos(v2(x1 - S(26), p.y + S(5)));
        const close = iconButton(close_id, ic.xmark, S(22), col.muted, col.hover, tr("Cancelar"));
        c.igSetCursorScreenPos(back);
        return close;
    }

    fn drawChat(a: *App, cl: *Client, size: c.ImVec2_c) void {
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, 0);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        _ = c.igBeginChild_Str("chat", size, 0, c.ImGuiWindowFlags_NoScrollbar);
        const d = drawList();
        const o = c.igGetCursorScreenPos();
        const hh = S(34);
        drawTextF(d, font_bold, 11, v2(o.x + S(16), o.y + S(12)), col.muted, tr("CHAT"));
        // o tópico do canal, do lado (cortado; inteiro com o mouse em cima)
        {
            var tb: [proto.chan_topic_max]u8 = undefined;
            var tl: usize = 0;
            cl.mutex.lock();
            for (cl.chans[0..cl.n_chans]) |*ch| if (std.mem.eql(u8, ch.nameSlice(), cl.chan_name[0..cl.chan_name_len])) {
                tl = ch.topic_len;
                @memcpy(tb[0..tl], ch.topicSlice());
            };
            cl.mutex.unlock();
            if (tl > 0) {
                const tx = o.x + S(16) + textSizeF(font_bold, 11, tr("CHAT")).x + S(10);
                c.ImDrawList_PushClipRect(d, v2(tx, o.y), v2(o.x + size.x - S(12), o.y + S(32)), true);
                drawTextF(d, font_regular, 12, v2(tx, o.y + S(11)), col.faint, fmtZ("{s}  {s}", .{ ic.pen, tb[0..tl] }));
                c.ImDrawList_PopClipRect(d);
                if (c.igIsMouseHoveringRect(v2(tx, o.y), v2(o.x + size.x, o.y + S(32)), true)) tooltipText(fmtZ("{s}", .{tb[0..tl]}));
            }
        }
        c.igSetCursorScreenPos(v2(o.x, o.y + hh));

        // a caixa cresce com o texto (Shift+Enter quebra linha), até umas 7 linhas
        const box_w = size.x - S(24) - S(82) - S(16);
        const typed = std.mem.sliceTo(&a.chat_input, 0);
        noteEmoji(typed);
        pushFont(font_regular, 15);
        const typed_h = if (typed.len == 0) 0 else c.igCalcTextSize(typed.ptr, typed.ptr + typed.len, false, box_w).y;
        popFont();
        const box_h = std.math.clamp(typed_h + S(18), S(44), S(160));
        // a caixa aponta pra uma resposta e/ou uma privada: uma barra pra cada
        if (cl.server_features & proto.srv_dm == 0) {
            a.reply_id = 0;
            a.dm_to = 0;
        }
        cl.compose_to.store(a.dm_to, .release);
        cl.compose_reply.store(a.reply_id, .release);
        const bar_h = S(26);
        var ups: [8]*filexfer.Transfer = undefined;
        var n_ups: usize = 0;
        {
            var all: [16]*filexfer.Transfer = undefined;
            const n = cl.xfers.snapshot(&all);
            for (all[0..n]) |t| {
                if (t.kind == .up and n_ups < ups.len) {
                    ups[n_ups] = t;
                    n_ups += 1;
                } else t.release();
            }
        }
        defer for (ups[0..n_ups]) |t| t.release();
        const bars: f32 = @floatFromInt(@as(u32, @intFromBool(a.reply_id != 0)) + @intFromBool(a.dm_to != 0) + @as(u32, @intCast(n_ups)));
        // mensagens
        const input_h = box_h + S(24) + bars * bar_h;
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(14), S(10)));
        c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
        _ = c.igBeginChild_Str("msgs", v2(size.x, size.y - hh - input_h), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0);
        const at_bottom = c.igGetScrollY() >= c.igGetScrollMaxY() - S(4);

        cl.mutex.lock();
        const count = cl.chat_count;
        const me = cl.my_id;
        var my_name_buf: [48]u8 = undefined;
        var my_name: []const u8 = "";
        for (cl.members.items) |*m| {
            if (m.id == me) {
                const n = @min(m.name_len, my_name_buf.len);
                @memcpy(my_name_buf[0..n], m.name[0..n]);
                my_name = my_name_buf[0..n];
            }
        }
        // quem é bot (etiqueta do lado do nome nas mensagens)
        var bots: [32]u32 = undefined;
        var n_bots: usize = 0;
        for ([_][]const Member{ cl.members.items, cl.chan_members.items }) |list| for (list) |*m| {
            if (m.bot and n_bots < bots.len) {
                bots[n_bots] = m.id;
                n_bots += 1;
            }
        };
        var last_from: u32 = 0xffffffff;
        var in_history = false;
        const view_top = c.igGetScrollY();
        const view_h = c.igGetWindowHeight();
        if (a.chat_h.count() > 4000) a.chat_h.clearRetainingCapacity();
        const mdl = drawList();
        // fundo das menções atrás do texto: canal 0; o resto no 1
        c.ImDrawList_ChannelsSplit(mdl, 2);
        c.ImDrawList_ChannelsSetCurrent(mdl, 1);
        const mouse = c.igGetIO_Nil().*.MousePos;
        const msgs_hovered = c.igIsWindowHovered(c.ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
        var hover_line: ?u32 = null;
        for (cl.chat.items) |*line| {
            const text = line.text;
            noteEmoji(text);
            noteEmoji(line.nameSlice());
            // o histórico (de antes da gente entrar) fica separado do que é novo
            if (line.history and !in_history) {
                in_history = true;
                c.igDummy(v2(0, S(6)));
                pushFont(font_semibold, 11.5);
                textColored(col.faint, tr("MENSAGENS DE ANTES DE VOCÊ ENTRAR"));
                popFont();
            } else if (!line.history and in_history) {
                in_history = false;
                c.igDummy(v2(0, S(8)));
                const sp = c.igGetCursorScreenPos();
                c.ImDrawList_AddLine(drawList(), v2(sp.x, sp.y), v2(sp.x + size.x - S(28), sp.y), withAlpha(col.text, 30), S(1), 0);
                last_from = 0xffffffff;
            }
            // fora da área visível e já medida: só reserva o espaço (500 linhas
            // com quebra de texto custavam ~2 ms por quadro, com o cliente travado)
            const y0 = c.igGetCursorPosY();
            // privada e resposta sempre com o cabeçalho (o aviso e a citação ficam claros)
            const special = line.to != 0 or line.reply_id != 0;
            const with_header = line.from != 0 and (line.from != last_from or special);
            if (a.chat_h.get(line.id)) |ch| if (ch.header == with_header and ch.width == size.x and
                (y0 + ch.h < view_top - view_h or y0 > view_top + 2 * view_h))
            {
                c.igSetCursorPosY(y0 + ch.h);
                last_from = line.from;
                continue;
            };
            if (line.from == 0) {
                defer a.chat_h.put(gpa_ui, line.id, .{ .h = c.igGetCursorPosY() - y0, .header = false, .width = size.x }) catch {};
                c.igDummy(v2(0, S(6)));
                const p = c.igGetCursorScreenPos();
                const dl = drawList();
                drawTextF(dl, font_regular, 12, v2(p.x + S(4), p.y + S(2)), col.green, ic.arrow_right);
                c.igSetCursorScreenPos(v2(p.x + S(24), p.y));
                c.igPushTextWrapPos(size.x - S(18));
                pushFont(font_regular, 13.5);
                var sb: [256]u8 = undefined;
                textColored(col.muted, i18n.server(text, &sb));
                popFont();
                c.igPopTextWrapPos();
                last_from = 0;
                continue;
            }
            defer a.chat_h.put(gpa_ui, line.id, .{ .h = c.igGetCursorPosY() - y0, .header = with_header, .width = size.x }) catch {};
            var top: f32 = 0;
            if (line.from != last_from or special) {
                c.igDummy(v2(0, S(12)));
                const p = c.igGetCursorScreenPos();
                top = p.y;
                const dl = drawList();
                drawAvatar(dl, v2(p.x + S(18), p.y + S(18)), S(18), line.from, line.nameSlice(), false);
                drawTextF(dl, font_semibold, 14.5, v2(p.x + S(48), p.y), avatarColor(line.from), line.nameSlice());
                var ns = textSizeF(font_semibold, 14.5, line.nameSlice());
                if (line.from != 0 and std.mem.indexOfScalar(u32, bots[0..n_bots], line.from) != null)
                    ns.x += botBadge(dl, v2(p.x + S(54) + ns.x, p.y + S(3))) + S(6);
                const time_z = fmtZ("{d:0>2}:{d:0>2}", .{ line.hour, line.minute });
                drawTextF(dl, font_regular, 11.5, v2(p.x + S(54) + ns.x, p.y + S(3)), col.faint, time_z);
                if (line.to != 0) {
                    // privada: pra quem (ou "pra você")
                    const tx = p.x + S(62) + ns.x + textSizeF(font_regular, 11.5, time_z).x;
                    const who = if (line.from == me) fmtZ("{s}  privado pra {s}", .{ ic.lock, line.toName() }) else fmtZ("{s}  privado pra você", .{ic.lock});
                    drawTextF(dl, font_semibold, 11.5, v2(tx, p.y + S(3)), col.blurple, who);
                }
                c.igSetCursorScreenPos(v2(p.x + S(48), p.y + S(20)));
            } else {
                top = c.igGetCursorScreenPos().y;
                c.igSetCursorPosX(c.igGetCursorPosX() + S(48));
            }
            const left = c.igGetCursorScreenPos().x;
            if (line.reply_id != 0) {
                // a citação: barrinha, quem disse e o começo do que disse
                const qp = c.igGetCursorScreenPos();
                const dl = drawList();
                rectFill(dl, qp.x, qp.y + S(2), qp.x + S(3), qp.y + S(18), withAlpha(col.text, 60), 1);
                const qn = line.replyName();
                drawTextF(dl, font_semibold, 12.5, v2(qp.x + S(10), qp.y + S(2)), avatarColor(line.reply_from), qn);
                const qx = qp.x + S(16) + textSizeF(font_semibold, 12.5, qn).x;
                c.ImDrawList_PushClipRect(dl, v2(qx, qp.y), v2(c.igGetWindowPos().x + size.x - S(18), qp.y + S(20)), true);
                drawTextF(dl, font_regular, 12.5, v2(qx, qp.y + S(2)), col.muted, line.replySnip());
                c.ImDrawList_PopClipRect(dl);
                noteEmoji(line.replySnip());
                c.igDummy(v2(1, S(20)));
                c.igSetCursorScreenPos(v2(left, c.igGetCursorScreenPos().y));
            }
            if (line.file_id != 0) {
                a.drawFileCard(cl, line, size.x - S(48) - S(36));
            } else if (text.len > 0 and markdown.hasMarkup(text)) {
                a.drawRichText(text, c.igGetWindowPos().x + size.x - S(18), line.id);
            } else if (text.len > 0) {
                c.igPushTextWrapPos(size.x - S(18));
                pushFont(font_regular, 14.5);
                textColored(col.text, text);
                popFont();
                c.igPopTextWrapPos();
            }
            if (line.img != null) {
                if (text.len > 0) c.igSetCursorScreenPos(v2(left, c.igGetCursorScreenPos().y + S(2)));
                a.drawChatLineImage(line, size.x - S(48) - S(36));
            } else if (line.img_expired) {
                pushFont(font_regular, 13);
                textColored(col.faint, fmtZ("{s}  imagem antiga (não está mais guardada na sala)", .{ic.image}));
                popFont();
            }
            if (line.n_reacts > 0) a.drawReactionChips(cl, line, me, left, c.igGetWindowPos().x + size.x - S(18));
            const bottom = c.igGetCursorScreenPos().y;
            // privada: fundo azulado
            if (line.to != 0) {
                c.ImDrawList_ChannelsSetCurrent(mdl, 0);
                const wx = c.igGetWindowPos().x;
                rectFill(mdl, wx, top - S(2), wx + size.x, bottom + S(2), withAlpha(col.blurple, 22), 0);
                rectFill(mdl, wx, top - S(2), wx + S(3), bottom + S(2), col.blurple, 0);
                c.ImDrawList_ChannelsSetCurrent(mdl, 1);
            }
            // menção a você (ou resposta a uma mensagem sua): fundo amarelado com faixa do lado (como no Discord)
            if (line.from != me and line.to == 0 and (mentions(text, my_name) or line.reply_from == me)) {
                c.ImDrawList_ChannelsSetCurrent(mdl, 0);
                const wx = c.igGetWindowPos().x;
                rectFill(mdl, wx, top - S(2), wx + size.x, bottom + S(2), withAlpha(col.yellow, 26), 0);
                rectFill(mdl, wx, top - S(2), wx + S(3), bottom + S(2), col.yellow, 0);
                c.ImDrawList_ChannelsSetCurrent(mdl, 1);
            }
            // mouse em cima: barra de reações no canto da mensagem
            if (msgs_hovered and mouse.y >= top - S(10) and mouse.y < bottom + S(2)) {
                hover_line = line.id;
                // clique direito: copiar o texto / responder
                if (c.igIsMouseClicked_Bool(1, false) and (text.len > 0 or line.img != null)) {
                    a.msg_menu_id = line.id;
                    a.msg_menu_from = line.from;
                    a.msg_menu_to = line.to;
                    copyName(&a.msg_menu_to_name, &a.msg_menu_to_name_len, line.toName());
                    a.msg_menu_len = @min(text.len, a.msg_menu_text.len);
                    @memcpy(a.msg_menu_text[0..a.msg_menu_len], text[0..a.msg_menu_len]);
                    a.msg_menu_name_len = @min(line.name_len, a.msg_menu_name.len);
                    @memcpy(a.msg_menu_name[0..a.msg_menu_name_len], line.name[0..a.msg_menu_name_len]);
                    _ = c.igOpenPopup_Str("##msgmenu", 0);
                }
            }
            if (a.react_hover == line.id and line.to == 0) { // privada não tem reação
                const bs = S(26);
                const bx0 = c.igGetWindowPos().x + size.x - S(14) - bs * proto.reactions - S(8);
                const by0 = top - S(12);
                const back = c.igGetCursorScreenPos();
                rectFill(mdl, bx0 - S(4), by0 - S(3), bx0 + bs * proto.reactions + S(4), by0 + bs + S(3), col.bg_main, S(6));
                c.ImDrawList_AddRect(mdl, v2(bx0 - S(4), by0 - S(3)), v2(bx0 + bs * proto.reactions + S(4), by0 + bs + S(3)), rgba(0x000000, 90), S(6) * col.round, S(1), 0);
                for (0..proto.reactions) |e| {
                    c.igSetCursorScreenPos(v2(bx0 + bs * @as(f32, @floatFromInt(e)), by0));
                    const mine = line.reactCount(@intCast(e), me).mine;
                    if (iconButton(fmtZ("##r{d}_{d}", .{ line.id, e }), reaction_icons[e], bs, reaction_colors[e], col.hover, reactionName(e))) cl.sendReact(line.id, @intCast(e), !mine);
                }
                c.igSetCursorScreenPos(back);
            }
            // depois de uma privada ou resposta, a próxima mostra o cabeçalho de novo
            last_from = if (special) 0xfffffffe else line.from;
        }
        c.ImDrawList_ChannelsMerge(mdl);
        if (c.igBeginPopup("##msgmenu", 0)) {
            if (c.igSelectable_Bool(fmtZ("{s}  Copiar texto###mcopy", .{ic.copy}), false, 0, v2(S(200), 0))) {
                var z: [4001]u8 = undefined;
                @memcpy(z[0..a.msg_menu_len], a.msg_menu_text[0..a.msg_menu_len]);
                z[a.msg_menu_len] = 0;
                c.igSetClipboardText(@ptrCast(&z));
            }
            const dm_ok = cl.server_features & proto.srv_dm != 0;
            if (dm_ok and c.igSelectable_Bool(fmtZ("{s}  Responder###mreply", .{ic.reply}), false, 0, v2(S(220), 0))) {
                // citando: a barra em cima da caixa; resposta numa privada continua privada
                a.reply_id = a.msg_menu_id;
                copyName(&a.reply_name, &a.reply_name_len, a.msg_menu_name[0..a.msg_menu_name_len]);
                var snip = std.mem.trim(u8, a.msg_menu_text[0..a.msg_menu_len], " \t\r\n");
                if (snip.len > a.reply_snip.len) {
                    var n = a.reply_snip.len;
                    while (n > 0 and snip[n] & 0xC0 == 0x80) n -= 1;
                    snip = snip[0..n];
                }
                @memcpy(a.reply_snip[0..snip.len], snip);
                a.reply_snip_len = snip.len;
                for (a.reply_snip[0..snip.len]) |*ch| if (ch.* == '\n') {
                    ch.* = ' ';
                };
                if (a.msg_menu_to != 0) {
                    if (a.msg_menu_from == me)
                        a.startDm(a.msg_menu_to, a.msg_menu_to_name[0..a.msg_menu_to_name_len])
                    else
                        a.startDm(a.msg_menu_from, a.msg_menu_name[0..a.msg_menu_name_len]);
                }
                a.focus_chat = true;
            }
            if (dm_ok and a.msg_menu_from != me and a.msg_menu_from != 0 and a.msg_menu_to == 0 and
                c.igSelectable_Bool(fmtZ("{s}  Mensagem privada###mdm", .{ic.lock}), false, 0, v2(S(220), 0)))
            {
                a.startDm(a.msg_menu_from, a.msg_menu_name[0..a.msg_menu_name_len]);
                a.focus_chat = true;
            }
            if (!dm_ok and c.igSelectable_Bool(fmtZ("{s}  Responder###mreply", .{ic.reply}), false, 0, v2(S(220), 0))) {
                // servidor antigo: "@nome " no começo da caixa (a pessoa é avisada pela menção)
                const cur_len = std.mem.indexOfScalar(u8, &a.chat_input, 0) orelse a.chat_input.len;
                const name = a.msg_menu_name[0..a.msg_menu_name_len];
                if (name.len + 2 + cur_len < a.chat_input.len) {
                    std.mem.copyBackwards(u8, a.chat_input[name.len + 2 .. name.len + 2 + cur_len], a.chat_input[0..cur_len]);
                    a.chat_input[0] = '@';
                    @memcpy(a.chat_input[1 .. 1 + name.len], name);
                    a.chat_input[1 + name.len] = ' ';
                    a.chat_input[name.len + 2 + cur_len] = 0;
                }
                a.focus_chat = true;
            }
            c.igEndPopup();
        }
        a.react_hover = hover_line;
        cl.mutex.unlock();
        c.igDummy(v2(0, S(8)));
        if (count != a.chat_seen) {
            if (at_bottom or a.chat_seen == 0) c.igSetScrollHereY(1.0);
            a.chat_seen = count;
        }
        a.chat_unread = 0;
        c.igEndChild();
        c.igPopStyleColor(1);
        c.igPopStyleVar(1);

        // caixa de mensagem (com as barras de arquivo subindo, resposta e privada em cima)
        var ip = c.igGetCursorScreenPos();
        for (ups[0..n_ups], 0..) |t, ui| {
            a.uploadBar(cl, d, ip, size.x, bar_h, t, ui);
            ip.y += bar_h;
        }
        if (a.dm_to != 0) {
            if (a.composeBar(d, ip, size.x, bar_h, ic.lock, col.blurple, fmtZ("Privado pra {s}", .{a.dm_name[0..a.dm_name_len]}), "", "##dmclose")) a.dm_to = 0;
            ip.y += bar_h;
        }
        if (a.reply_id != 0) {
            if (a.composeBar(d, ip, size.x, bar_h, ic.arrow_right, col.muted, fmtZ("Respondendo {s}", .{a.reply_name[0..a.reply_name_len]}), a.reply_snip[0..a.reply_snip_len], "##replyclose")) a.reply_id = 0;
            ip.y += bar_h;
        }
        const bx = ip.x + S(12);
        const by = ip.y + S(10);
        const bw = size.x - S(24);
        const bh = box_h;
        rectFill(d, bx, by, bx + bw, by + bh, col.chat_input, S(8));
        c.igSetCursorScreenPos(v2(bx + S(4), by + S(4)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, 0);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, 0);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, 0);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(8), S(9)));
        if (a.focus_chat) {
            c.igSetKeyboardFocusHere(0);
            a.focus_chat = false;
        }
        // caixa multilinha: Enter manda (o callback tira a quebra que o Enter
        // pôs, guarda a mensagem e esvazia a caixa no mesmo quadro, sem a caixa
        // perder o foco: nenhuma letra digitada logo depois se perde) e
        // Shift+Enter quebra a linha.
        a.chat_sent_len = 0;
        a.updateMentionSuggestions(cl);
        c.igSetNextItemWidth(bw - S(82));
        var hint_buf: [96]u8 = undefined;
        const hint: [:0]const u8 = blk: {
            if (a.dm_to != 0) break :blk i18n.bufPrintZ(&hint_buf, "Mensagem privada pra {s}", .{a.dm_name[0..a.dm_name_len]}) catch tr("Mensagem ou @nome");
            cl.mutex.lock();
            defer cl.mutex.unlock();
            if (!cl.chans_supported) break :blk tr("Mensagem ou @nome");
            break :blk i18n.bufPrintZ(&hint_buf, "Mensagem em #{s}", .{cl.chan_name[0..cl.chan_name_len]}) catch tr("Mensagem ou @nome");
        };
        c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
        _ = c.igInputTextEx("##chatin", hint.ptr, &a.chat_input, @intCast(a.chat_input.len), v2(bw - S(82), bh - S(8)), c.ImGuiInputTextFlags_Multiline | c.ImGuiInputTextFlags_WordWrap | c.ImGuiInputTextFlags_CallbackAlways | c.ImGuiInputTextFlags_CallbackCompletion, chatCallback, a);
        c.igPopStyleColor(1);
        const enter = a.chat_sent_len > 0;
        const input_active = c.igIsItemActive();
        c.igPopStyleVar(1);
        c.igPopStyleColor(3);
        // Ctrl+V com imagem copiada: manda a imagem (texto colado segue normal)
        const io = c.igGetIO_Nil();
        if (input_active and io.*.KeyCtrl and c.igIsKeyPressed_Bool(c.ImGuiKey_V, false)) _ = chatsend.paste(cl);
        // sugestões de @menção (Tab completa a primeira; clique escolhe)
        if (a.n_mention_sugg > 0 and (input_active or a.mention_apply_len > 0)) {
            const row = S(30);
            const hgt = row * @as(f32, @floatFromInt(a.n_mention_sugg)) + S(8);
            const sy = by - hgt - S(6);
            rectFill(d, bx, sy, bx + bw, sy + hgt, col.bg_main, S(8));
            c.ImDrawList_AddRect(d, v2(bx, sy), v2(bx + bw, sy + hgt), rgba(0x000000, 90), S(8) * col.round, S(1), 0);
            const back = c.igGetCursorScreenPos();
            for (0..a.n_mention_sugg) |i| {
                const ry = sy + S(4) + row * @as(f32, @floatFromInt(i));
                c.igSetCursorScreenPos(v2(bx + S(4), ry));
                const name = a.mention_sugg[i][0..a.mention_sugg_len[i]];
                if (c.igInvisibleButton(fmtZ("@{s}##mention", .{name}).ptr, v2(bw - S(8), row), 0)) {
                    a.pickMention(i);
                    a.focus_chat = true;
                }
                if (c.igIsItemHovered(0) or i == 0) rectFill(d, bx + S(4), ry, bx + bw - S(4), ry + row, if (c.igIsItemHovered(0)) col.hover else withAlpha(col.text, 10), S(5));
                drawTextF(d, font_semibold, 14, v2(bx + S(14), ry + S(6)), col.text, fmtZ("@{s}", .{name}));
                if (i == 0) drawTextF(d, font_regular, 12, v2(bx + bw - S(60), ry + S(8)), col.faint, tr("Tab"));
            }
            c.igSetCursorScreenPos(back);
        }
        if (chatsend.running.load(.acquire) > 0) {
            drawTextF(d, font_regular, 12, v2(bx + S(6), by - S(18)), col.muted, fmtZ("{s}  mandando imagem...", .{ic.image}));
        }
        c.igSameLine(0, 0);
        c.igSetCursorScreenPos(v2(bx + bw - S(76), by + bh - S(39)));
        if (iconButton("##attach", ic.paperclip, S(34), col.muted, col.hover, tr("Mandar imagem ou arquivo (escolher; também dá pra arrastar pra janela ou colar imagem com Ctrl+V)"))) {
            // imagem copiada: manda; senão abre a janela do sistema pra escolher o arquivo
            if (!chatsend.paste(cl)) {
                // (nos testes nunca abre: a janela do portal poderia aparecer na tela de verdade)
                if (!qa.enabled() and c.filepick_start(tr("Escolha uma imagem ou arquivo pro chat")) == 0) {
                    a.picking_file = true;
                } else a.toast("Pra mandar: arraste o arquivo pra janela do telinha, ou copie a imagem e aperte Ctrl+V no chat.", .{}, false);
            }
        }
        if (a.picking_file) {
            var pb: [4096]u8 = undefined;
            switch (c.filepick_poll(&pb, pb.len)) {
                0 => redrawIn(0.2),
                1 => {
                    a.picking_file = false;
                    const path = std.mem.sliceTo(&pb, 0);
                    a.sendPath(cl, path);
                },
                else => a.picking_file = false,
            }
        }
        c.igSetCursorScreenPos(v2(bx + bw - S(40), by + bh - S(39)));
        const send_click = iconButton("##send", ic.send, S(34), col.muted, col.hover, tr("Enviar"));
        if (enter or send_click) {
            const raw = if (enter and a.chat_sent_len > 0) a.chat_sent[0..a.chat_sent_len] else std.mem.sliceTo(&a.chat_input, 0);
            const msg = std.mem.trim(u8, raw, " \t");
            if (msg.len > 0 and !a.chatCommand(cl, msg)) {
                cl.sendChat(msg, a.reply_id, a.dm_to);
                a.reply_id = 0; // a resposta é uma vez; a privada continua até fechar
            }
            @memset(&a.chat_input, 0);
            if (send_click) a.focus_chat = true; // o clique no botão tirou o foco
        }

        c.igEndChild();
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
    }

    // ------------------------------------------------------- texto formatado

    /// Mensagem com markdown (ver markdown.zig): blocos de código com botão de
    /// copiar, `código`, **negrito**, *itálico* e links clicáveis, quebrando
    /// linha em `max_x`. Avança o cursor pela altura usada.
    fn drawRichText(a: *App, text: []const u8, max_x: f32, id: u32) void {
        _ = a;
        const d = drawList();
        const p0 = c.igGetCursorScreenPos();
        const fs: f32 = 14.5;
        const lh = textSizeF(font_regular, fs, "Ag").y;
        var y = p0.y;
        var pos: usize = 0;
        var k: u32 = 0;
        var first = true;
        while (markdown.nextBlock(text, &pos)) |blk| : (k += 1) {
            switch (blk) {
                .text => |t| {
                    if (t.len == 0) continue;
                    if (!first) y += S(2);
                    y = richInline(d, t, p0.x, max_x, y, fs, lh);
                },
                .code => |cb| {
                    if (!first) y += S(4);
                    y = codeBlock(d, cb.lang, cb.body, p0.x, max_x, y, id, k);
                },
            }
            first = false;
        }
        c.igSetCursorScreenPos(p0);
        c.igDummy(v2(@max(1, max_x - p0.x), @max(lh, y - p0.y)));
    }

    /// Texto corrido com estilos; devolve o y da linha de baixo.
    fn richInline(d: *c.ImDrawList, text: []const u8, x0: f32, max_x: f32, y_start: f32, fs: f32, lh: f32) f32 {
        var buf: [128]markdown.Span = undefined;
        const n = markdown.spans(text, &buf);
        var x = x0;
        var y = y_start;
        const mono = fonts_mono.regular;
        const space_w = textSizeF(font_regular, fs, " ").x;
        for (buf[0..n]) |sp| {
            const st = sp.style;
            const font = if (st.code) mono else if (st.bold) font_bold else font_regular;
            const size = if (st.code) fs - 1.5 else fs;
            const color = if (st.link) col.blurple else if (st.bold) col.header else col.text;
            // link: o trecho inteiro é um alvo de clique (desenhado em pedaços)
            var i: usize = 0;
            while (i < sp.text.len) {
                const ch = sp.text[i];
                if (ch == '\n') {
                    x = x0;
                    y += lh;
                    i += 1;
                    continue;
                }
                if (ch == ' ' or ch == '\t') {
                    if (x > x0 or st.code) x += space_w * @as(f32, if (ch == '\t') 4 else 1);
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < sp.text.len and sp.text[j] != ' ' and sp.text[j] != '\n' and sp.text[j] != '\t') : (j += 1) {}
                var word = sp.text[i..j];
                const pad: f32 = if (st.code) S(4) else 0;
                while (word.len > 0) {
                    var w = textSizeF(font, size, word).x + pad * 2;
                    if (x + w > max_x and x > x0) {
                        x = x0;
                        y += lh;
                    }
                    // palavra maior que a linha inteira: corta onde couber
                    var piece = word;
                    if (w > max_x - x0) {
                        var cut: usize = 0;
                        var it = (std.unicode.Utf8View.init(word) catch break).iterator();
                        while (it.nextCodepointSlice()) |cp| {
                            const next = cut + cp.len;
                            if (textSizeF(font, size, word[0..next]).x + pad * 2 > max_x - x) break;
                            cut = next;
                        }
                        if (cut == 0) cut = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
                        piece = word[0..cut];
                        w = textSizeF(font, size, piece).x + pad * 2;
                    }
                    const ty = y + (lh - S(size) * font_k) / 2;
                    if (st.code) rectFill(d, x, y + S(1), x + w, y + lh - S(1), withAlpha(col.text, 24), S(4));
                    const vtx0 = d.*.VtxBuffer.Size;
                    drawTextF(d, font, size, v2(x + pad, ty), color, piece);
                    if (st.italic) {
                        // sem fonte itálica: inclina o que acabou de ser desenhado
                        const base = y + lh;
                        var vi: c_int = vtx0;
                        while (vi < d.*.VtxBuffer.Size) : (vi += 1) {
                            const v = &d.*.VtxBuffer.Data[@intCast(vi)];
                            v.pos.x += (base - v.pos.y) * 0.2;
                        }
                    }
                    if (st.link) {
                        c.ImDrawList_AddLine(d, v2(x, y + lh - S(2)), v2(x + w, y + lh - S(2)), withAlpha(col.blurple, 140), S(1), 0);
                        if (c.igIsMouseHoveringRect(v2(x, y), v2(x + w, y + lh), true) and c.igIsWindowHovered(0)) {
                            c.igSetMouseCursor(c.ImGuiMouseCursor_Hand);
                            tooltipText(fmtZ("{s}", .{sp.text}));
                            if (c.igIsMouseClicked_Bool(0, false)) _ = openPath(sp.text);
                        }
                    }
                    x += w;
                    word = word[piece.len..];
                    if (word.len > 0) {
                        x = x0;
                        y += lh;
                    }
                }
                i = j;
            }
        }
        return y + lh;
    }

    /// Bloco de código: fundo escuro, fonte monoespaçada, linguagem no canto e
    /// botão de copiar. Linha comprida quebra (no chat não dá pra rolar de lado).
    fn codeBlock(d: *c.ImDrawList, lang: []const u8, body_raw: []const u8, x0: f32, max_x: f32, y0: f32, id: u32, k: u32) f32 {
        // tab vira 4 espaços (a fonte não tem largura de tab)
        var tb: [4096]u8 = undefined;
        var n: usize = 0;
        for (body_raw) |ch| {
            if (n + 4 >= tb.len) break;
            if (ch == '\t') {
                @memcpy(tb[n .. n + 4], "    ");
                n += 4;
            } else if (ch != '\r') {
                tb[n] = ch;
                n += 1;
            }
        }
        const body = tb[0..n];
        const mono = fonts_mono.regular;
        const fs: f32 = 13;
        const pad = S(12);
        const top: f32 = if (lang.len > 0) S(22) else S(10);
        const inner_w = max_x - x0 - pad * 2;
        c.igPushFont(mono, S(fs) * font_k);
        const ts = c.igCalcTextSize(body.ptr, body.ptr + body.len, false, inner_w);
        c.igPopFont();
        const h = top + ts.y + S(10);
        rectFill(d, x0, y0, max_x, y0 + h, withAlpha(col.bg_dark, 230), S(8));
        c.ImDrawList_AddRect(d, v2(x0, y0), v2(max_x, y0 + h), withAlpha(col.text, 22), S(8) * col.round, S(1), 0);
        rectFill(d, x0, y0 + S(6), x0 + S(3), y0 + h - S(6), withAlpha(col.blurple, 160), S(2));
        if (lang.len > 0) drawTextF(d, font_semibold, 11, v2(x0 + pad, y0 + S(5)), col.faint, lang);
        c.ImDrawList_AddText_FontPtr(d, mono, S(fs) * font_k, v2(x0 + pad, y0 + top), col.text, body.ptr, body.ptr + body.len, inner_w, null);
        // copiar
        const bs = S(24);
        const back = c.igGetCursorScreenPos();
        c.igSetCursorScreenPos(v2(max_x - bs - S(4), y0 + S(3)));
        if (iconButton(fmtZ("##cpcode{d}_{d}", .{ id, k }), ic.copy, bs, col.muted, col.hover, tr("Copiar o código"))) {
            var cz: [4097]u8 = undefined;
            const m = @min(body.len, cz.len - 1);
            @memcpy(cz[0..m], body[0..m]);
            cz[m] = 0;
            c.igSetClipboardText(@ptrCast(&cz));
        }
        c.igSetCursorScreenPos(back);
        return y0 + h;
    }

    /// Pede um canal de texto (ou a call dele) e lembra o pedido: se voltar
    /// "esse canal tem senha", o painel pergunta e manda de novo.
    fn askChannel(a: *App, cl: *Client, name: []const u8, call: bool) void {
        a.chan_req_len = @min(name.len, a.chan_req.len);
        @memcpy(a.chan_req[0..a.chan_req_len], name[0..a.chan_req_len]);
        a.chan_req_call = call;
        if (call) cl.joinCall(name, "") else cl.joinChannel(name, "");
    }

    /// Fora de call e indo transmitir: entra na call do canal em que está
    /// (transmissão é sempre numa call).
    fn ensureInCall(a: *App) void {
        const cl = a.client orelse return;
        cl.mutex.lock();
        const need = cl.chans_supported and cl.calls_known and cl.call_name_len == 0;
        var nb: [proto.channel_name_max]u8 = undefined;
        const n = cl.chan_name_len;
        @memcpy(nb[0..n], cl.chan_name[0..n]);
        cl.mutex.unlock();
        if (need) cl.joinCall(nb[0..n], "");
    }

    /// Menu do admin num canal (clique direito na lista).
    fn chanMenu(a: *App, cl: *Client) void {
        if (!c.igBeginPopup("##chanmenu", 0)) return;
        defer c.igEndPopup();
        const name = a.chan_menu[0..a.chan_menu_len];
        const fl = a.chan_menu_flags;
        const w = S(250);
        pushFont(font_bold, 13);
        textColored(col.header, fmtZ("#{s}", .{name}));
        popFont();
        c.igSeparator();
        if (c.igSelectable_Bool(if (fl & proto.chan_fixed != 0) fmtZ("{s}  Soltar (some quando esvaziar)###cfix", .{ic.lock_open}) else fmtZ("{s}  Fixar (fica, mesmo vazio e reiniciando)###cfix", .{ic.lock}), false, 0, v2(w, 0)))
            cl.chanAdmin(proto.chan_act_fix, name, if (fl & proto.chan_fixed != 0) "0" else "1", 0);
        if (c.igSelectable_Bool(if (fl & proto.chan_locked != 0) fmtZ("{s}  Destrancar###clock", .{ic.lock_open}) else fmtZ("{s}  Trancar (só admin entra)###clock", .{ic.lock}), false, 0, v2(w, 0)))
            cl.chanAdmin(proto.chan_act_lock, name, if (fl & proto.chan_locked != 0) "0" else "1", 0);
        if (c.igSelectable_Bool(fmtZ("{s}  Senha do canal…###cpw", .{ic.shield}), false, 0, v2(w, 0))) a.startChanEdit(.password, name);
        if (c.igSelectable_Bool(fmtZ("{s}  Tópico…###ctopic", .{ic.pen}), false, 0, v2(w, 0))) a.startChanEdit(.topic, name);
    }

    fn startChanEdit(a: *App, what: @TypeOf(a.chan_edit), name: []const u8) void {
        a.chan_edit = what;
        a.chan_edit_len = @min(name.len, a.chan_edit_for.len);
        @memcpy(a.chan_edit_for[0..a.chan_edit_len], name[0..a.chan_edit_len]);
        @memset(&a.chan_edit_buf, 0);
        a.focus_chan_edit = true;
    }

    /// O admin tirou o meu pincel? (a bandeira vem na lista de membros)
    fn myNoDraw(a: *App, cl: *Client) bool {
        _ = a;
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.members.items) |*m| if (m.id == cl.my_id) return m.noDraw();
        return false;
    }

    /// Comandos do chat (como no IRC): /join canal (ou /j, /canal, /entrar)
    /// e /canais. true = era comando (não vai pro chat).
    fn chatCommand(a: *App, cl: *Client, msg: []const u8) bool {
        if (msg.len < 2 or msg[0] != '/') return false;
        var it = std.mem.tokenizeScalar(u8, msg[1..], ' ');
        const cmd = it.next() orelse return false;
        const arg = std.mem.trim(u8, it.rest(), " ");
        const is = struct {
            fn any(c0: []const u8, names: []const []const u8) bool {
                for (names) |n| if (std.ascii.eqlIgnoreCase(c0, n)) return true;
                return false;
            }
        }.any;
        cl.mutex.lock();
        const supported = cl.chans_supported;
        cl.mutex.unlock();
        if (is(cmd, &.{ "join", "j", "canal", "channel", "entrar" })) {
            if (!supported) {
                a.toast("Esse servidor não tem canais (é de uma versão mais velha do telinha).", .{}, true);
            } else if (arg.len == 0) {
                a.toast("Use /join nome-do-canal (cria o canal se ele não existir).", .{}, false);
            } else a.askChannel(cl, arg, false);
            return true;
        }
        if (is(cmd, &.{ "msg", "m", "w", "privado", "pm", "dm" })) {
            // /msg nome texto (o nome pode ter espaço: vale o maior nome de alguém da sala que bate)
            if (cl.server_features & proto.srv_dm == 0) {
                a.toast("Esse servidor não tem mensagem privada (é de uma versão mais velha do telinha).", .{}, true);
                return true;
            }
            var best_id: u32 = 0;
            var best_len: usize = 0;
            var best_name: [48]u8 = undefined;
            cl.mutex.lock();
            for (cl.members.items) |*m| {
                const n = m.nameSlice();
                if (m.id == cl.my_id or n.len <= best_len or arg.len < n.len or !std.ascii.eqlIgnoreCase(arg[0..n.len], n)) continue;
                if (arg.len > n.len and arg[n.len] != ' ') continue;
                best_id = m.id;
                best_len = n.len;
                @memcpy(best_name[0..n.len], n);
            }
            cl.mutex.unlock();
            if (best_id == 0) {
                a.toast("Use /msg nome mensagem (o nome de alguém da sala).", .{}, false);
                return true;
            }
            const body = std.mem.trim(u8, arg[best_len..], " ");
            if (body.len == 0) {
                // só o nome: a caixa passa a ir em privado pra essa pessoa
                a.startDm(best_id, best_name[0..best_len]);
            } else cl.sendChat(body, 0, best_id);
            return true;
        }
        if (is(cmd, &.{ "arquivo", "file", "enviar" })) {
            if (arg.len == 0) {
                a.toast("Use /arquivo caminho-do-arquivo (ou arraste o arquivo pra janela).", .{}, false);
            } else a.sendPath(cl, arg);
            return true;
        }
        if (is(cmd, &.{ "call", "voz", "voice" })) {
            if (!supported) {
                a.toast("Esse servidor não tem canais (é de uma versão mais velha do telinha).", .{}, true);
            } else if (arg.len == 0) {
                cl.joinCall("", ""); // sem nome: sai da call
            } else a.askChannel(cl, arg, true);
            return true;
        }
        if (is(cmd, &.{ "canais", "channels", "list" })) {
            if (!supported) {
                a.toast("Esse servidor não tem canais (é de uma versão mais velha do telinha).", .{}, true);
                return true;
            }
            var buf: [600]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            cl.mutex.lock();
            for (cl.chans[0..cl.n_chans], 0..) |*ch, i| w.print("{s}#{s} ({d})", .{ if (i > 0) ", " else "", ch.nameSlice(), ch.people }) catch break;
            cl.mutex.unlock();
            a.toast("Canais: {s}", .{w.buffered()}, false);
            return true;
        }
        return false; // outro "/..." vai pro chat normal
    }

    /// Mudou de canal: o que era assistido no canal velho sai da tela (o
    /// servidor já parou de mandar), o chat recomeçou.
    fn onChannelChanged(a: *App, cl: *Client) void {
        var streams: [32]u32 = undefined;
        var n: usize = 0;
        for (a.views.items) |v| {
            if (n == streams.len) break;
            streams[n] = v.stream;
            n += 1;
        }
        for (streams[0..n]) |st| a.unwatch(st);
        a.n_auto_watched = 0;
        a.chat_h.clearRetainingCapacity();
        a.n_known = 0; // gente nova na lista: sem som de "entrou" pra cada um
        a.known_ready = false;
        cl.mutex.lock();
        var nb: [proto.channel_name_max]u8 = undefined;
        const l = cl.chan_name_len;
        @memcpy(nb[0..l], cl.chan_name[0..l]);
        cl.mutex.unlock();
        debuglog.line("canal: #{s}", .{nb[0..l]});
        a.toast("Você está no #{s}", .{nb[0..l]}, false);
    }

    /// Na hora do Enter (ainda dentro do InputText): guarda a mensagem e
    /// esvazia a caixa sem tirar o foco dela.
    fn chatCallback(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(data.*.UserData));
        // Tab: completa a @menção com a primeira sugestão
        if (data.*.EventFlag == c.ImGuiInputTextFlags_CallbackCompletion) {
            if (a.n_mention_sugg > 0) a.pickMention(0);
        }
        // troca o "@an" do fim pelo nome escolhido
        if (a.mention_apply_len > 0) {
            const text = data.*.Buf[0..@intCast(data.*.BufTextLen)];
            if (std.mem.lastIndexOfScalar(u8, text, '@')) |at| {
                c.ImGuiInputTextCallbackData_DeleteChars(data, @intCast(at), @intCast(text.len - at));
                const ins = fmtZ("@{s} ", .{a.mention_apply[0..a.mention_apply_len]});
                c.ImGuiInputTextCallbackData_InsertChars(data, @intCast(at), ins.ptr, null);
                data.*.CursorPos = data.*.BufTextLen;
                data.*.SelectionStart = data.*.BufTextLen;
                data.*.SelectionEnd = data.*.BufTextLen;
            }
            a.mention_apply_len = 0;
        }
        const io = c.igGetIO_Nil();
        if ((c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false) or c.igIsKeyPressed_Bool(c.ImGuiKey_KeypadEnter, false)) and !io.*.KeyShift) {
            // a quebra de linha que o Enter acabou de pôr não faz parte da mensagem
            const cur: usize = @intCast(data.*.CursorPos);
            // (Ctrl+Enter não põe quebra; o ImGui solta a caixa: pega o foco de volta)
            if (io.*.KeyCtrl) {
                a.focus_chat = true;
            } else if (cur > 0 and data.*.Buf[cur - 1] == '\n') c.ImGuiInputTextCallbackData_DeleteChars(data, @intCast(cur - 1), 1);
            const n: usize = @intCast(@min(data.*.BufTextLen, a.chat_sent.len));
            @memcpy(a.chat_sent[0..n], data.*.Buf[0..n]);
            a.chat_sent_len = n;
            c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
        }
        return 0;
    }

    /// Conta mensagens não lidas quando o chat está escondido.
    pub fn updateUnread(a: *App) void {
        const cl = a.client orelse return;
        if (a.chat_visible and a.screen == .room) return;
        cl.mutex.lock();
        const count = cl.chat_count;
        cl.mutex.unlock();
        if (count > a.chat_seen) {
            a.chat_unread += @intCast(count - a.chat_seen);
            a.chat_seen = count;
        }
    }

    // ---------------------------------------------------------- modal de tela

    fn drawShareModal(a: *App) void {
        _ = c.igOpenPopup_Str(tr("Compartilhar tela###compartilhar"), 0);
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(S(480), 0), c.ImGuiCond_Always);
        // janela baixa: rola em vez de cortar o botão de ir ao vivo
        c.igSetNextWindowSizeConstraints(v2(S(480), 0), v2(S(480), @max(S(200), vp.*.Size.y - S(24))), null, null);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("Compartilhar tela###compartilhar"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const w = S(432);

        pushFont(font_bold, 20);
        textColored(col.header, tr("Compartilhar tela"));
        popFont();
        pushFont(font_regular, 13.5);
        textColored(col.muted, tr("Todo mundo na sala vai poder assistir."));
        popFont();
        c.igDummy(v2(0, S(14)));

        fieldLabel("O QUE MOSTRAR");
        c.igSetNextItemWidth(w);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(9)));
        var src_buf: [300]u8 = undefined;
        const preview: [:0]const u8 = if (a.n_sources > 0) sourceName(&a.sources[@intCast(a.source_idx)], &src_buf) else tr("Tela");
        if (beginCombo("##src", preview, 0)) {
            for (a.sources[0..a.n_sources], 0..) |*s, i| {
                c.igPushID_Int(@intCast(i));
                if (c.igSelectable_Bool(fmtZ("{s}###src", .{sourceName(s, &src_buf)}).ptr, a.source_idx == @as(i32, @intCast(i)), 0, v2(0, 0))) a.source_idx = @intCast(i);
                c.igPopID();
            }
            c.igEndCombo();
        }
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
        c.igDummy(v2(0, S(9)));

        a.drawAudioChoice(w);
        c.igDummy(v2(0, S(9)));

        fieldLabel("TIPO DE CONTEÚDO");
        _ = segmented("mode", &.{ "Tela e texto", "Jogo e vídeo" }, &a.cfg.mode, w);
        c.igDummy(v2(0, S(9)));

        fieldLabel("RESOLUÇÃO");
        _ = segmented("res", &.{ "Original", "1080p", "720p", "480p" }, &a.cfg.resolution, w);
        c.igDummy(v2(0, S(9)));

        fieldLabel("QUADROS POR SEGUNDO");
        var fps_preset: i32 = switch (a.cfg.fps) {
            15 => 0,
            30 => 1,
            60 => 2,
            else => -1,
        };
        if (segmented("fps", &.{ "15", "30", "60" }, &fps_preset, w)) a.cfg.fps = switch (fps_preset) {
            0 => 15,
            1 => 30,
            else => 60,
        };
        c.igDummy(v2(0, S(4)));
        sliderStyled("##fps", &a.cfg.fps, 1, 60, "%d fps", w);
        c.igDummy(v2(0, S(9)));

        fieldLabel("QUALIDADE");
        const qname = if (a.cfg.quality < 40) tr("economia") else if (a.cfg.quality < 65) tr("equilibrada") else if (a.cfg.quality < 85) tr("alta") else tr("máxima");
        // estimativa de banda pra resolução escolhida (tela 1080p se "Original")
        const est_h: u32 = switch (a.cfg.resolution) {
            1 => 1080,
            2 => 720,
            3 => 480,
            else => 1080,
        };
        const est = sharer_mod.targetBitrate(est_h * 16 / 9, est_h, @intCast(std.math.clamp(a.cfg.fps, 1, 60)), @intCast(std.math.clamp(a.cfg.quality, 20, 100)));
        const mbit10 = (est + 50_000) / 100_000; // décimos de Mbit/s
        sliderStyled("##q", &a.cfg.quality, 20, 100, fmtZ("%d — {s} · até {d},{d} Mbit/s", .{ qname, mbit10 / 10, mbit10 % 10 }), w);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 12);
        textColored(col.faint, tr("A taxa cai sozinha se a internet de alguém não aguentar, e volta a subir quando melhora."));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(10)));

        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleColor_U32(c.ImGuiCol_CheckMark, col.white);
        _ = c.igCheckbox(tr("Mostrar o cursor do mouse###cursor"), &a.cfg.cursor);
        _ = c.igCheckbox(tr("Usar a placa de vídeo, se tiver###hardware"), &a.cfg.hardware);
        if (c.igIsItemHovered(0)) tooltipText(tr("NVIDIA; no Windows também AMD e Intel. Sem placa que sirva, vai pela CPU."));

        c.igPopStyleColor(2);

        if (!sync.is_windows and a.n_sources > 0 and std.mem.startsWith(u8, std.mem.sliceTo(&a.sources[0].name, 0), "Escolher")) {
            c.igDummy(v2(0, S(8)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + w);
            pushFont(font_regular, 12.5);
            textColored(col.muted, tr("No Wayland o sistema abre um seletor pra escolher a tela ou janela. Na próxima vez ele lembra a escolha."));
            popFont();
            c.igPopTextWrapPos();
        }

        c.igDummy(v2(0, S(18)));
        const bw = (w - S(10)) / 2;
        if (secondaryButton(tr("Cancelar###cancelshare"), v2(bw, S(42))) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            a.share_modal = false;
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, S(10));
        if (a.sharer != null) {
            const hb = (bw - S(10)) / 2;
            if (primaryButton(tr("Parar###parar"), v2(hb, S(42)), col.red, col.red_hover, col.red_hover)) {
                a.share_modal = false;
                c.igCloseCurrentPopup();
                a.stopSharing();
            }
            c.igSameLine(0, S(10));
            if (primaryButton(tr("Aplicar###aplicar"), v2(hb, S(42)), col.blurple, col.blurple_hover, col.blurple_active)) {
                a.share_modal = false;
                c.igCloseCurrentPopup();
                a.startSharing();
            }
        } else {
            const go = fmtZ("{s}   Ao vivo###golive", .{ic.circle});
            if (primaryButton(go, v2(bw, S(42)), col.blurple, col.blurple_hover, col.blurple_active)) {
                a.share_modal = false;
                c.igCloseCurrentPopup();
                a.startSharing();
            }
        }
    }

    // ------------------------------------------------------- configurações

    fn drawSettingsModal(a: *App) void {
        _ = c.igOpenPopup_Str(tr("Configurações###configuracoes"), 0);
        const vp = c.igGetMainViewport();
        const mw = @min(S(800), vp.*.Size.x - S(24));
        const mh = @min(S(600), vp.*.Size.y - S(24));
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(mw, mh), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10) * col.round);
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal(tr("Configurações###configuracoes"), null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse)) return;
        defer c.igEndPopup();

        // barra lateral: as páginas
        const nav_w = S(200);
        const wp = c.igGetWindowPos();
        const d = c.igGetWindowDrawList();
        c.ImDrawList_AddRectFilled(d, wp, v2(wp.x + nav_w, wp.y + mh), col.bg_side, S(10) * col.round, c.ImDrawFlags_RoundTopLeft | c.ImDrawFlags_RoundBottomLeft);
        c.igSetCursorPos(v2(S(18), S(22)));
        pushFont(font_bold, 18);
        textColored(col.header, tr("Configurações"));
        popFont();
        var nav_y = S(62);
        const pages = [_]struct { page: SettingsPage, icon: []const u8, name: [:0]const u8 }{
            .{ .page = .geral, .icon = ic.gear, .name = tr("Geral") },
            .{ .page = .aparencia, .icon = ic.palette, .name = tr("Aparência") },
            .{ .page = .voz, .icon = ic.mic, .name = tr("Voz") },
            .{ .page = .atalhos, .icon = ic.keyboard, .name = tr("Atalhos") },
            .{ .page = .camera, .icon = ic.video, .name = tr("Câmera") },
            .{ .page = .desempenho, .icon = ic.gauge, .name = tr("Desempenho") },
            .{ .page = .depuracao, .icon = ic.bug, .name = tr("Depuração") },
            .{ .page = .sobre, .icon = ic.info, .name = tr("Sobre") },
        };
        for (pages) |pg| {
            c.igSetCursorPos(v2(S(10), nav_y));
            const p = c.igGetCursorScreenPos();
            const iw = nav_w - S(20);
            const ih = S(36);
            nav_y += ih + S(4);
            c.igPushID_Str(@tagName(pg.page).ptr);
            const clicked = c.igInvisibleButton(fmtZ("##cfg-{s}", .{@tagName(pg.page)}).ptr, v2(iw, ih), 0);
            c.igPopID();
            const sel = a.settings_page == pg.page;
            if (sel or c.igIsItemHovered(0)) rectFill(d, p.x, p.y, p.x + iw, p.y + ih, if (sel) col.selected else col.hover, S(6));
            const tcol = if (sel) col.header else col.muted;
            drawTextF(d, font_regular, 14, v2(p.x + S(12), p.y + S(10)), tcol, pg.icon);
            drawTextF(d, font_semibold, 14, v2(p.x + S(40), p.y + S(9)), tcol, pg.name);
            if (clicked and a.settings_page != pg.page) {
                a.settings_page = pg.page;
                // trocou de página: nenhuma captura de tecla fica pendurada
                a.ptt_capture = false;
                a.key_capture = null;
            }
        }
        // Fechar no pé da barra
        c.igSetCursorPos(v2(S(10), mh - S(56)));
        var close = primaryButton(tr("Fechar###fecharconfig"), v2(nav_w - S(20), S(40)), col.blurple, col.blurple_hover, col.blurple_active);
        // esperando uma tecla (apertar pra falar, atalho de clipe): o Esc só cancela isso
        const capturing = a.ptt_capture or a.key_capture != null;
        close = close or (!capturing and c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false));

        // a página escolhida (rola sozinha)
        c.igSetCursorPos(v2(nav_w, 0));
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(28), S(24)));
        if (c.igBeginChild_Str("##cfgpage", v2(mw - nav_w, mh), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0)) {
            const w = mw - nav_w - S(56);
            const title = for (pages) |pg| {
                if (pg.page == a.settings_page) break pg.name;
            } else "";
            pushFont(font_bold, 20);
            textColored(col.header, title);
            popFont();
            c.igDummy(v2(0, S(10)));
            switch (a.settings_page) {
                .geral => a.settingsGeneral(w),
                .aparencia => a.settingsAppearance(w),
                .voz => a.settingsVoice(w),
                .atalhos => a.settingsShortcuts(w),
                .camera => a.settingsCamera(w),
                .desempenho => a.settingsPerformance(w),
                .depuracao => a.drawDebug(w),
                .sobre => a.settingsAbout(w),
            }
            c.igDummy(v2(0, S(16)));
        }
        c.igEndChild();
        c.igPopStyleVar(1);

        if (close) {
            config.save(&a.cfg);
            a.settings_modal = false;
            a.ptt_capture = false;
            a.key_capture = null;
            c.igCloseCurrentPopup();
        }
    }

    fn settingsGeneral(a: *App, w: f32) void {
        fieldLabel("SEU NOME (vale na próxima vez que entrar numa sala)");
        _ = textField("##sname", "como a galera vai te ver", a.cfg.name[0 .. a.cfg.name.len - 1], w, false);
        c.igDummy(v2(0, S(10)));
        fieldLabel("IDIOMA");
        a.drawLanguage(@min(w, S(260)));
        c.igDummy(v2(0, S(12)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        _ = c.igCheckbox(tr("Mostrar estatísticas sempre (não só com o mouse em cima)###stats"), &a.cfg.stats_always);
        _ = c.igCheckbox(tr("Notificações com o telinha em segundo plano (chat, ao vivo, quem entrou)###notif"), &a.cfg.notifications);
        if (build_options.repo.len > 0 or update.getState() != .idle) {
            if (c.igCheckbox(tr("Avisar quando sair versão nova (pergunta ao GitHub ao abrir)###updates"), &a.cfg.check_updates) and a.cfg.check_updates)
                update.checkAsync(build_options.repo, version_string, i18n.english());
            if (update.getState() == .newer) {
                c.igSameLine(0, S(8));
                if (c.igSmallButton(tr("Ver a nova##upd"))) {
                    a.update_modal = true;
                    a.settings_modal = false;
                    c.igCloseCurrentPopup();
                }
            }
            if (a.cfg.check_updates) _ = c.igCheckbox(tr("Instalar as versões novas sozinho (confere a assinatura antes)###updauto"), &a.cfg.update_auto);
        }
        if (c.igCheckbox(tr("Clipes: guardar o finalzinho do que você assiste (pra salvar um clipe na hora)###clips"), &a.cfg.clips)) a.applyClips();
        // do lado se couber, senão embaixo
        const folder_w = textSizeF(font_regular, 15, tr("Abrir a pasta###clipsdir")).x + S(16);
        if (c.igGetContentRegionAvail().x - (c.igGetItemRectMax().x - c.igGetCursorScreenPos().x) > folder_w + S(8)) c.igSameLine(0, S(8));
        if (c.igSmallButton(tr("Abrir a pasta###clipsdir"))) a.openClipsFolder();
        c.igPopStyleColor(1);
        if (a.cfg.clips) {
            c.igDummy(v2(0, S(6)));
            fieldLabel("DURAÇÃO DO CLIPE");
            const secs = [_]i32{ 15, 30, 60, 120, 180 };
            var si: i32 = -1;
            for (secs, 0..) |x, i| {
                if (x == a.cfg.clip_secs) si = @intCast(i);
            }
            if (segmented("clipsecs", &.{ "15 s", "30 s", "1 min", "2 min", "3 min" }, &si, w)) {
                a.cfg.clip_secs = secs[@intCast(si)];
                clip.keep_secs.store(@intCast(a.cfg.clip_secs), .release);
                config.save(&a.cfg);
            }
            // ou qualquer duração (5 s a 10 min)
            c.igDummy(v2(0, S(4)));
            textColored(col.muted, tr("Outra duração (segundos):"));
            c.igSameLine(0, S(8));
            c.igSetNextItemWidth(S(110));
            var custom: c_int = a.cfg.clip_secs;
            if (c.igInputInt("##clipsecs_custom", &custom, 5, 30, 0)) {
                a.cfg.clip_secs = std.math.clamp(custom, 5, 600);
                clip.keep_secs.store(@intCast(a.cfg.clip_secs), .release);
                config.save(&a.cfg);
            }
            pushFont(font_regular, 12);
            textColored(col.faint, fmtZ("Usa até ~{d} MB de memória por transmissão assistida (depende da qualidade).", .{@divTrunc(a.cfg.clip_secs * 3, 4) + 4}));
            textColored(col.faint, tr("O atalho pra salvar clipe fica na página Atalhos."));
            popFont();
        }
    }

    fn settingsAppearance(a: *App, w: f32) void {
        fieldLabel("TEMA");
        c.igDummy(v2(0, S(2)));
        a.drawThemes(w);
        c.igDummy(v2(0, S(14)));
        fieldLabel("TAMANHO DA INTERFACE");
        const zooms = [_]i32{ 80, 90, 100, 115, 130, 150 };
        var zi: i32 = 2;
        for (zooms, 0..) |z, i| {
            if (z == a.cfg.ui_zoom) zi = @intCast(i);
        }
        if (segmented("zoom", &.{ "80%", "90%", "100%", "115%", "130%", "150%" }, &zi, w)) {
            a.cfg.ui_zoom = zooms[@intCast(zi)];
            a.zoom_dirty = true;
            config.save(&a.cfg);
        }
        c.igDummy(v2(0, S(14)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Efeito CRT (linhas de tela antiga; o vídeo fica de fora)###crt"), &a.cfg.crt)) config.save(&a.cfg);
        if (c.igCheckbox(tr("Animações na tela inicial (param sozinhas com o telinha fora de foco)###anim"), &a.cfg.animations)) config.save(&a.cfg);
        if (c.igCheckbox(tr("Mostrar os desenhos dos outros por cima das transmissões###showdraw"), &a.cfg.show_drawings)) config.save(&a.cfg);
        c.igPopStyleColor(1);
    }

    /// Linhas de tela antiga por cima da interface (menos nas transmissões).
    fn drawCrt(a: *App, size: c.ImVec2_c) void {
        if (!a.cfg.crt) return;
        const d = c.igGetForegroundDrawList_ViewportPtr(c.igGetMainViewport());
        const dark = theme.luminance(col.bg_main) < 0.2;
        const line = withAlpha(col.black, if (dark) 46 else 18);
        const step = @max(2.0, S(3));
        var y: f32 = 0;
        while (y < size.y) : (y += step) {
            // pula os pedaços em cima das transmissões
            var x: f32 = 0;
            while (x < size.x) {
                var end = size.x;
                var skip_to: ?f32 = null;
                for (a.tile_rects[0..a.n_tile_rects]) |r| {
                    if (y < r.y0 or y >= r.y1 or r.x1 <= x) continue;
                    if (r.x0 <= x) {
                        skip_to = @max(skip_to orelse 0, r.x1);
                    } else end = @min(end, r.x0);
                }
                if (skip_to) |s| {
                    x = s;
                    continue;
                }
                c.ImDrawList_AddLine(d, v2(x, y), v2(end, y), line, 1, 0);
                x = end;
            }
        }
    }

    /// Passa a tecla escolhida pro microfone (no formato que o sistema lê de fora).
    fn applyPtt(a: *App) void {
        ptt.enabled.store(a.cfg.voice_ptt, .release);
        if (a.cfg.ptt_mouse >= 0) {
            ptt.configure(0, a.cfg.ptt_mouse);
            return;
        }
        var sc = a.cfg.ptt_scancode;
        if (sc == 0 and a.cfg.ptt_key > 0) sc = c.glfwGetKeyScancode(a.cfg.ptt_key);
        // Linux: o GLFW no Wayland dá o código do evdev; o X11 soma 8
        const key = if (!sync.is_windows and c.glfwGetPlatform() == c.GLFW_PLATFORM_WAYLAND) sc + 8 else sc;
        ptt.configure(key, -1);
    }

    /// Modificadores apertados agora, vistos pela janela (Ctrl/Shift/Alt, qualquer lado).
    fn uiMods(a: *App) u8 {
        var m: u8 = 0;
        if (c.glfwGetKey(a.window, c.GLFW_KEY_LEFT_CONTROL) == c.GLFW_PRESS or c.glfwGetKey(a.window, c.GLFW_KEY_RIGHT_CONTROL) == c.GLFW_PRESS) m |= config.mod_ctrl;
        if (c.glfwGetKey(a.window, c.GLFW_KEY_LEFT_SHIFT) == c.GLFW_PRESS or c.glfwGetKey(a.window, c.GLFW_KEY_RIGHT_SHIFT) == c.GLFW_PRESS) m |= config.mod_shift;
        if (c.glfwGetKey(a.window, c.GLFW_KEY_LEFT_ALT) == c.GLFW_PRESS or c.glfwGetKey(a.window, c.GLFW_KEY_RIGHT_ALT) == c.GLFW_PRESS) m |= config.mod_alt;
        return m;
    }

    fn isModKey(k: c_int) bool {
        return ownMod(k) != 0;
    }

    /// O modificador que a tecla é (Ctrl esq. = Ctrl...; 0 = tecla comum).
    fn ownMod(k: c_int) u8 {
        if (k == c.GLFW_KEY_LEFT_CONTROL or k == c.GLFW_KEY_RIGHT_CONTROL) return config.mod_ctrl;
        if (k == c.GLFW_KEY_LEFT_SHIFT or k == c.GLFW_KEY_RIGHT_SHIFT) return config.mod_shift;
        if (k == c.GLFW_KEY_LEFT_ALT or k == c.GLFW_KEY_RIGHT_ALT) return config.mod_alt;
        return 0;
    }

    /// Atalhos globais: a thread (de fora) ou a própria janela (com foco; o
    /// Wayland só deixa assim). Desligados, só o de ligar/desligar vale.
    fn pollHotkeys(a: *App) void {
        const focused = c.glfwGetWindowAttrib(a.window, c.GLFW_FOCUSED) != 0;
        const typing = c.igGetIO_Nil().*.WantTextInput;
        const mods = a.uiMods();
        inline for (@typeInfo(config.HotkeyId).@"enum".fields) |f| {
            const id: config.HotkeyId = @enumFromInt(f.value);
            const hk = a.cfg.hk[f.value];
            const allowed = a.cfg.hotkeys_on or id == .toggle;
            // digitando no chat, uma letra sozinha é texto, não atalho (a thread
            // de fora não sabe disso: o que ela viu é descartado aqui)
            const plain_typing = focused and typing and hk.mods == 0 and hk.mouse < 0;
            if (hotkey.take(f.value) and allowed and !plain_typing) a.runHotkey(id);
            // com foco: a janela vê a tecla (de fora e de dentro ao mesmo tempo é
            // o mesmo aperto; cada ação ignora repetição por 1 s onde importa)
            const bound = hk.key > 0 or hk.mouse >= 0;
            const own: u8 = if (hk.mouse < 0) ownMod(hk.key) else 0;
            const down = bound and focused and a.key_capture == null and !plain_typing and (mods & ~own) == hk.mods and
                (if (hk.mouse >= 0) c.glfwGetMouseButton(a.window, hk.mouse) == c.GLFW_PRESS else c.glfwGetKey(a.window, hk.key) == c.GLFW_PRESS);
            if (down and !a.hk_prev[f.value] and allowed) a.runHotkey(id);
            a.hk_prev[f.value] = down;
        }
    }

    /// O que cada atalho faz.
    /// O atalho `id` está ligado e é exatamente Ctrl + `key`?
    fn hotkeyIsCtrl(a: *const App, id: config.HotkeyId, key: c_int) bool {
        const hk = a.cfg.hk[@intFromEnum(id)];
        return a.cfg.hotkeys_on and hk.mouse < 0 and hk.key == key and hk.mods == config.mod_ctrl;
    }

    fn runHotkey(a: *App, id: config.HotkeyId) void {
        const now = c.igGetTime();
        switch (id) {
            .clip => a.clipHotkey(),
            .mic => {
                if (now - a.hk_last[0] < 0.15) return;
                a.hk_last[0] = now;
                if (a.screen == .room) a.toggleMic("atalho");
            },
            .deaf => {
                if (now - a.hk_last[1] < 0.15) return;
                a.hk_last[1] = now;
                if (a.screen == .room) a.toggleDeaf("atalho");
            },
            .share => {
                if (now - a.hk_last[2] < 1.0) return;
                a.hk_last[2] = now;
                if (a.screen != .room) return;
                if (a.sharer != null) a.stopSharing() else a.startSharing();
            },
            .print => {
                if (now - a.hk_last[3] < 1.0) return;
                a.hk_last[3] = now;
                a.printHotkey();
            },
            .toggle => {
                if (now - a.hk_last[4] < 0.15) return;
                a.hk_last[4] = now;
                a.cfg.hotkeys_on = !a.cfg.hotkeys_on;
                hotkey.setEnabled(a.cfg.hotkeys_on);
                config.save(&a.cfg);
                if (a.cfg.hotkeys_on) a.toast("Atalhos ligados.", .{}, false) else a.toast("Atalhos desligados (só o de ligar de novo continua valendo).", .{}, false);
            },
        }
    }

    /// Print pelo atalho: a transmissão em destaque (ou a primeira assistida).
    fn printHotkey(a: *App) void {
        var target: ?*View = null;
        for (a.views.items) |v| {
            if (a.focused != null and a.focused.? == v.stream) {
                target = v;
                break;
            }
            if (target == null) target = v;
        }
        const v = target orelse {
            a.toast("Nada pra printar: assista alguém.", .{}, true);
            return;
        };
        var nb: [64]u8 = undefined;
        a.savePrint(v, a.viewerName(v, &nb));
    }

    /// Nome de quem transmite essa view (vazio se já saiu).
    fn viewerName(a: *App, v: *View, nb: *[64]u8) []const u8 {
        var name: []const u8 = "";
        if (a.client) |cl| {
            cl.mutex.lock();
            for (cl.members.items) |*m| if (m.id == v.member()) {
                const n = @min(m.name_len, nb.len);
                @memcpy(nb[0..n], m.nameSlice()[0..n]);
                name = nb[0..n];
            };
            cl.mutex.unlock();
        }
        return name;
    }

    /// Com o telinha em foco, a interface também vê a tecla (o Wayland só deixa assim).
    fn pollPttKey(a: *App) void {
        if (!a.cfg.voice_ptt or a.ptt_capture) {
            ptt.ui_down.store(false, .release);
            return;
        }
        const focused = c.glfwGetWindowAttrib(a.window, c.GLFW_FOCUSED) != 0;
        const down = focused and if (a.cfg.ptt_mouse >= 0)
            c.glfwGetMouseButton(a.window, a.cfg.ptt_mouse) == c.GLFW_PRESS
        else
            a.cfg.ptt_key > 0 and c.glfwGetKey(a.window, a.cfg.ptt_key) == c.GLFW_PRESS;
        ptt.ui_down.store(down, .release);
    }

    /// Nome da tecla pra mostrar ("V", "F5", "Mouse 4").
    fn pttKeyName(a: *App, buf: []u8) []const u8 {
        return keyName(a.cfg.ptt_key, a.cfg.ptt_scancode, a.cfg.ptt_mouse, buf);
    }

    /// Com os modificadores na frente ("Ctrl+Shift+K").
    fn hotkeyName(hk: config.Hotkey, buf: []u8) []const u8 {
        if (hk.key <= 0 and hk.mouse < 0) return tr("nenhum");
        var kb: [32]u8 = undefined;
        const base = keyName(hk.key, hk.scancode, hk.mouse, &kb);
        return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{
            if (hk.mods & config.mod_ctrl != 0) "Ctrl+" else "",
            if (hk.mods & config.mod_shift != 0) "Shift+" else "",
            if (hk.mods & config.mod_alt != 0) "Alt+" else "",
            base,
        }) catch "?";
    }

    fn keyName(k: i32, scancode: i32, mouse: i32, buf: []u8) []const u8 {
        if (mouse >= 0) return std.fmt.bufPrint(buf, "Mouse {d}", .{mouse + 1}) catch "?";
        if (k <= 0) return tr("nenhum");
        if (c.glfwGetKeyName(k, scancode)) |n| {
            const name = std.mem.span(n);
            if (name.len == 1) return std.fmt.bufPrint(buf, "{c}", .{std.ascii.toUpper(name[0])}) catch "?";
            return std.fmt.bufPrint(buf, "{s}", .{name}) catch "?";
        }
        if (k >= c.GLFW_KEY_F1 and k <= c.GLFW_KEY_F25) return std.fmt.bufPrint(buf, "F{d}", .{k - c.GLFW_KEY_F1 + 1}) catch "?";
        const special = [_]struct { k: c_int, n: []const u8 }{
            .{ .k = c.GLFW_KEY_SPACE, .n = tr("Espaço") },
            .{ .k = c.GLFW_KEY_LEFT_CONTROL, .n = tr("Ctrl esq.") },
            .{ .k = c.GLFW_KEY_RIGHT_CONTROL, .n = tr("Ctrl dir.") },
            .{ .k = c.GLFW_KEY_LEFT_ALT, .n = "Alt" },
            .{ .k = c.GLFW_KEY_RIGHT_ALT, .n = "AltGr" },
            .{ .k = c.GLFW_KEY_LEFT_SHIFT, .n = tr("Shift esq.") },
            .{ .k = c.GLFW_KEY_RIGHT_SHIFT, .n = tr("Shift dir.") },
            .{ .k = c.GLFW_KEY_CAPS_LOCK, .n = "Caps Lock" },
            .{ .k = c.GLFW_KEY_TAB, .n = "Tab" },
            .{ .k = c.GLFW_KEY_INSERT, .n = "Insert" },
            .{ .k = c.GLFW_KEY_HOME, .n = "Home" },
            .{ .k = c.GLFW_KEY_END, .n = "End" },
            .{ .k = c.GLFW_KEY_PAGE_UP, .n = "Page Up" },
            .{ .k = c.GLFW_KEY_PAGE_DOWN, .n = "Page Down" },
            .{ .k = c.GLFW_KEY_PAUSE, .n = "Pause" },
            .{ .k = c.GLFW_KEY_SCROLL_LOCK, .n = "Scroll Lock" },
        };
        for (special) |sp| if (sp.k == k) return sp.n;
        return i18n.bufPrint(buf, "tecla {d}", .{k}) catch "?";
    }

    /// Esperando a tecla nova: a primeira apertada (ou botão do meio/lateral do mouse).
    /// Uma tecla configurável (apertar pra falar, atalho de clipe).
    /// `mods` = null: sem modificadores (apertar pra falar: a tecla sozinha).
    const KeyRef = struct { key: *i32, scancode: *i32, mouse: *i32, mods: ?*u8 = null };

    /// Esperando a tecla nova: a primeira apertada (ou botão do meio/lateral do
    /// mouse), com os modificadores que estiverem segurados (Ctrl+Shift+K);
    /// um modificador apertado e solto sozinho vira o atalho ele mesmo.
    /// true = pegou; false = Esc (cancelou); null = ainda esperando.
    fn captureKey(a: *App, r: KeyRef) ?bool {
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            a.capture_mod_seen = 0;
            return false;
        }
        var k: c_int = c.GLFW_KEY_SPACE;
        var mod_down: c_int = 0;
        while (k <= c.GLFW_KEY_LAST) : (k += 1) {
            if (k == c.GLFW_KEY_ESCAPE) continue;
            if (c.glfwGetKey(a.window, k) != c.GLFW_PRESS) continue;
            if (r.mods != null and isModKey(k)) {
                mod_down = k;
                continue;
            }
            r.key.* = k;
            r.scancode.* = c.glfwGetKeyScancode(k);
            r.mouse.* = -1;
            if (r.mods) |m| m.* = a.uiMods();
            a.capture_mod_seen = 0;
            return true;
        }
        for ([_]c_int{ 2, 3, 4 }) |btn| {
            if (c.glfwGetMouseButton(a.window, btn) == c.GLFW_PRESS) {
                r.key.* = 0;
                r.mouse.* = btn;
                if (r.mods) |m| m.* = a.uiMods();
                a.capture_mod_seen = 0;
                return true;
            }
        }
        if (mod_down != 0) {
            a.capture_mod_seen = mod_down;
        } else if (a.capture_mod_seen != 0) {
            // soltou o modificador sem outra tecla: ele é o atalho
            r.key.* = a.capture_mod_seen;
            r.scancode.* = c.glfwGetKeyScancode(a.capture_mod_seen);
            r.mouse.* = -1;
            if (r.mods) |m| m.* = 0;
            a.capture_mod_seen = 0;
            return true;
        }
        redrawIn(0.05);
        return null;
    }

    fn capturePttKey(a: *App) void {
        const got = a.captureKey(.{ .key = &a.cfg.ptt_key, .scancode = &a.cfg.ptt_scancode, .mouse = &a.cfg.ptt_mouse }) orelse return;
        a.ptt_capture = false;
        if (got) {
            a.applyPtt();
            config.save(&a.cfg);
        }
    }

    fn captureHotkey(a: *App, id: config.HotkeyId) void {
        const hk = &a.cfg.hk[@intFromEnum(id)];
        const got = a.captureKey(.{ .key = &hk.key, .scancode = &hk.scancode, .mouse = &hk.mouse, .mods = &hk.mods }) orelse return;
        a.key_capture = null;
        if (got) {
            a.applyHotkeys();
            config.save(&a.cfg);
        }
    }

    /// Tecla no formato que o sistema lê de fora (scancode no Windows, keycode do X11).
    fn globalKey(key: i32, scancode: i32) i32 {
        var sc = scancode;
        if (sc == 0 and key > 0) sc = c.glfwGetKeyScancode(key);
        // Linux: o GLFW no Wayland dá o código do evdev; o X11 soma 8
        return if (!sync.is_windows and c.glfwGetPlatform() == c.GLFW_PLATFORM_WAYLAND) sc + 8 else sc;
    }

    /// Passa todos os atalhos pra thread que lê de fora.
    fn applyHotkeys(a: *App) void {
        hotkey.setEnabled(a.cfg.hotkeys_on);
        for (a.cfg.hk, 0..) |hk, i| {
            if (hk.mouse >= 0) {
                hotkey.configure(i, 0, hk.mouse, hk.mods, 0);
            } else if (hk.key > 0) {
                hotkey.configure(i, globalKey(hk.key, hk.scancode), -1, hk.mods, ownMod(hk.key));
            } else hotkey.configure(i, 0, -1, 0, 0);
        }
    }

    /// Página de atalhos: liga/desliga geral e uma tecla (ou combinação) por ação.
    fn settingsShortcuts(a: *App, w: f32) void {
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Atalhos ligados###hkon"), &a.cfg.hotkeys_on)) {
            hotkey.setEnabled(a.cfg.hotkeys_on);
            config.save(&a.cfg);
        }
        c.igPopStyleColor(1);
        pushFont(font_regular, 12.5);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        if (!sync.is_windows and c.glfwGetPlatform() == c.GLFW_PLATFORM_WAYLAND)
            textColored(col.yellow, tr("No Wayland os atalhos só valem com o telinha em foco (o sistema não deixa ler o teclado de outro programa)."))
        else
            textColored(col.faint, tr("Valem com o jogo em foco. Clique na tecla e aperte a nova (pode ser combinação, tipo Ctrl+Shift+K, ou o botão do meio/laterais do mouse); Esc cancela."));
        c.igPopTextWrapPos();
        popFont();
        c.igDummy(v2(0, S(8)));
        const rows = [_]struct { id: config.HotkeyId, name: [:0]const u8, tag: [:0]const u8 }{
            .{ .id = .clip, .name = tr("Salvar clipe"), .tag = "clipkey" },
            .{ .id = .mic, .name = tr("Microfone liga/desliga"), .tag = "mickey" },
            .{ .id = .deaf, .name = tr("Surdo liga/desliga (não ouve ninguém)"), .tag = "deafkey" },
            .{ .id = .share, .name = tr("Transmitir a tela / parar"), .tag = "sharekey" },
            .{ .id = .print, .name = tr("Print da transmissão"), .tag = "printkey" },
            .{ .id = .toggle, .name = tr("Ligar/desligar todos os atalhos (vale sempre)"), .tag = "togglekey" },
        };
        const bw = @min(S(260), (w - S(8)) * 0.45);
        for (rows) |row| {
            const idx = @intFromEnum(row.id);
            if (a.key_capture == row.id) a.captureHotkey(row.id);
            pushFont(font_bold, 11.5);
            textColored(col.muted, row.name);
            popFont();
            var kb: [48]u8 = undefined;
            const capturing = a.key_capture == row.id;
            const label = if (capturing) fmtZ("{s}###{s}", .{ tr("Aperte a tecla ou combinação..."), row.tag }) else fmtZ("{s}  {s}###{s}", .{ tr("Tecla:"), hotkeyName(a.cfg.hk[idx], &kb), row.tag });
            if (secondaryButton(label, v2(bw, S(34)))) {
                a.key_capture = row.id;
                a.capture_mod_seen = 0;
            }
            c.igSameLine(0, S(8));
            if (secondaryButton(fmtZ("{s}###{s}off", .{ tr("Sem atalho"), row.tag }), v2(S(110), S(34)))) {
                a.cfg.hk[idx] = .{};
                if (a.key_capture == row.id) a.key_capture = null;
                a.applyHotkeys();
                config.save(&a.cfg);
            }
            c.igDummy(v2(0, S(4)));
        }
    }

    /// Atalho de clipe: a transmissão em destaque (ou a primeira assistida, ou a minha).
    fn clipHotkey(a: *App) void {
        const now = c.igGetTime();
        if (now - a.clip_key_last < 1.0) return; // o mesmo aperto visto de dois jeitos
        a.clip_key_last = now;
        var target: ?*View = null;
        for (a.views.items) |v| {
            if (v.clip == null) continue;
            if (a.focused != null and a.focused.? == v.stream) {
                target = v;
                break;
            }
            if (target == null) target = v;
        }
        if (target) |v| {
            var nb: [64]u8 = undefined;
            var name: []const u8 = "";
            if (a.client) |cl| {
                cl.mutex.lock();
                for (cl.members.items) |*m| if (m.id == v.member()) {
                    const n = @min(m.name_len, nb.len);
                    @memcpy(nb[0..n], m.nameSlice()[0..n]);
                    name = nb[0..n];
                };
                cl.mutex.unlock();
            }
            a.saveClip(v.clip.?, name);
        } else if (a.sharer) |sh| {
            if (sh.clip) |cb| a.saveClip(cb, tr("minha_tela"));
        } else a.toast("Nada pra clipar: assista alguém (ou transmita) com os clipes ligados.", .{}, true);
    }

    fn settingsVoice(a: *App, w: f32) void {
        fieldLabel("MODO");
        var mode: i32 = if (a.cfg.voice_ptt) 1 else 0;
        if (segmented("voicemode", &.{ "Detecção de voz", "Apertar pra falar" }, &mode, w)) {
            a.cfg.voice_ptt = mode == 1;
            a.applyPtt();
            config.save(&a.cfg);
        }
        if (a.cfg.voice_ptt) {
            c.igDummy(v2(0, S(6)));
            if (a.ptt_capture) a.capturePttKey();
            var kb: [32]u8 = undefined;
            const label = if (a.ptt_capture) fmtZ("{s}###pttkey", .{tr("Aperte a tecla (ou um botão lateral do mouse)...")}) else fmtZ("{s}  {s}###pttkey", .{ tr("Tecla:"), a.pttKeyName(&kb) });
            if (secondaryButton(label, v2(w, S(36)))) a.ptt_capture = true;
            pushFont(font_regular, 12.5);
            c.igPushTextWrapPos(c.igGetCursorPosX() + w);
            if (!sync.is_windows and c.glfwGetPlatform() == c.GLFW_PLATFORM_WAYLAND)
                textColored(col.yellow, tr("No Wayland a tecla só vale com o telinha em foco (o sistema não deixa ler o teclado de outro programa)."))
            else if (!sync.is_windows and a.cfg.ptt_mouse >= 3)
                textColored(col.yellow, tr("Botão lateral do mouse no Linux só vale com o telinha em foco (o X não informa ele pra outros programas)."))
            else
                textColored(col.faint, tr("Vale com qualquer programa em foco (no jogo também). Clique no botão pra trocar a tecla."));
            c.igPopTextWrapPos();
            popFont();
        }
        c.igDummy(v2(0, S(12)));
        fieldLabel("MICROFONE");
        {
            const cur = config.getStr(&a.cfg.mic_device);
            const preview = if (cur.len == 0) tr("Padrão do sistema") else cur;
            c.igSetNextItemWidth(w);
            c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(8)));
            var changed = false;
            if (beginCombo("##mic", fmtZ("{s}", .{preview}).ptr, 0)) {
                if (c.igSelectable_Bool(tr("Padrão do sistema###micdefault"), cur.len == 0, 0, v2(0, 0))) {
                    config.setStr(&a.cfg.mic_device, "");
                    changed = true;
                }
                for (a.mic_names[0..a.n_mic_names], 0..) |*nm, i| {
                    const name = std.mem.sliceTo(nm, 0);
                    c.igPushID_Int(@intCast(i));
                    if (c.igSelectable_Bool(fmtZ("{s}", .{name}).ptr, std.mem.eql(u8, name, cur), 0, v2(0, 0))) {
                        config.setStr(&a.cfg.mic_device, name);
                        changed = true;
                    }
                    c.igPopID();
                }
                c.igEndCombo();
            }
            c.igPopStyleVar(1);
            c.igPopStyleColor(1);
            if (changed and a.mic != null) {
                a.stopMic();
                a.applyVoice("trocou o microfone");
            }
        }
        c.igDummy(v2(0, S(8)));
        fieldLabel("SENSIBILIDADE (quanto maior, mais fácil o microfone abrir)");
        const sens_before = a.cfg.voice_sensitivity;
        sliderStyled("##sens", &a.cfg.voice_sensitivity, 0, 100, "%d", w);
        if (sens_before != a.cfg.voice_sensitivity) if (a.mic) |m| m.setSensitivity(micSensitivity(&a.cfg));
        // volume do microfone: automático (voz baixa sobe) e manual
        c.igDummy(v2(0, S(8)));
        fieldLabel("VOLUME DO MICROFONE");
        const agc_before = a.cfg.mic_agc;
        const gain_before = a.cfg.mic_gain;
        _ = c.igCheckbox(tr("Ganho automático: sua voz baixa sobe pra todo mundo ouvir###micagc"), &a.cfg.mic_agc);
        sliderStyled("##micgain", &a.cfg.mic_gain, 25, 300, "%d%%", w);
        if (agc_before != a.cfg.mic_agc or gain_before != a.cfg.mic_gain) if (a.mic) |m| m.setGain(a.cfg.mic_agc, @as(f32, @floatFromInt(a.cfg.mic_gain)) / 100);
        if (a.mic) |m| {
            // medidor: a barra fica verde quando o portão abre (sua voz está indo)
            const d = c.igGetWindowDrawList();
            const mp = c.igGetCursorScreenPos();
            const lvl = std.math.clamp(m.level() * 1.6, 0, 1);
            rectFill(d, mp.x, mp.y + S(4), mp.x + w, mp.y + S(10), col.input, S(3));
            rectFill(d, mp.x, mp.y + S(4), mp.x + w * lvl, mp.y + S(10), if (m.speaking.load(.monotonic)) col.green else col.faint, S(3));
            c.igDummy(v2(w, S(14)));
        } else {
            pushFont(font_regular, 12);
            textColored(col.faint, tr("Liga o microfone pra ver o medidor."));
            popFont();
        }
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        var reopen = c.igCheckbox(tr("Supressão de ruído (tira ventilador, teclado, chiado)###noise"), &a.cfg.noise_suppression);
        reopen = c.igCheckbox(tr("Cancelamento de eco (pra quem usa caixa de som em vez de fone)###echo"), &a.cfg.echo_cancellation) or reopen;
        _ = c.igCheckbox(tr("Entrar na sala com o microfone ligado###micjoin"), &a.cfg.mic_on_join);
        _ = c.igCheckbox(tr("Sons de aviso (alguém entrou/saiu, ao vivo, microfone)###sounds"), &a.cfg.sounds);
        c.igPopStyleColor(1);
        if (reopen and a.mic != null) {
            a.stopMic();
            a.applyVoice("configurações da voz");
        }
    }

    fn settingsCamera(a: *App, w: f32) void {
        {
            var changed = false;
            const cur = config.getStr(&a.cfg.camera_device);
            var preview: []const u8 = if (a.n_cams == 0) tr("Nenhuma câmera encontrada") else tr("A primeira que achar");
            for (a.cams[0..a.n_cams]) |*cd| {
                if (cur.len > 0 and std.mem.eql(u8, std.mem.sliceTo(&cd.id, 0), cur)) preview = std.mem.sliceTo(&cd.name, 0);
            }
            c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(8)));
            c.igSetNextItemWidth(w * 0.68);
            if (beginCombo("##camdev", fmtZ("{s}", .{preview}).ptr, 0)) {
                if (c.igSelectable_Bool(tr("A primeira que achar###camfirst"), cur.len == 0, 0, v2(0, 0))) {
                    config.setStr(&a.cfg.camera_device, "");
                    changed = true;
                }
                for (a.cams[0..a.n_cams], 0..) |*cd, i| {
                    const id = std.mem.sliceTo(&cd.id, 0);
                    c.igPushID_Int(@intCast(i));
                    if (c.igSelectable_Bool(fmtZ("{s}", .{std.mem.sliceTo(&cd.name, 0)}).ptr, std.mem.eql(u8, id, cur), 0, v2(0, 0))) {
                        config.setStr(&a.cfg.camera_device, id);
                        changed = true;
                    }
                    c.igPopID();
                }
                c.igEndCombo();
            }
            c.igSameLine(0, S(8));
            const res_names = [_][:0]const u8{ "480p", "720p", "1080p" };
            c.igSetNextItemWidth(w * 0.32 - S(8));
            if (beginCombo("##camres", res_names[@intCast(std.math.clamp(a.cfg.camera_res, 0, 2))].ptr, 0)) {
                for (res_names, 0..) |rn, i| {
                    if (c.igSelectable_Bool(rn.ptr, a.cfg.camera_res == i, 0, v2(0, 0))) {
                        a.cfg.camera_res = @intCast(i);
                        changed = true;
                    }
                }
                c.igEndCombo();
            }
            c.igPopStyleVar(1);
            c.igPopStyleColor(1);
            // câmera ligada: troca na hora, sem derrubar quem assiste
            if (changed) if (a.camera) |cam| cam.update(a.cameraSettings());
        }
    }

    fn settingsPerformance(a: *App, w: f32) void {
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Qualidade automática: baixa a resolução sozinho se o PC não der conta do fps###autoq"), &a.cfg.auto_quality)) {
            config.save(&a.cfg);
            if (a.sharer) |s| s.update(a.shareSettings());
        }
        c.igPopStyleColor(1);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Quando a transmissão não consegue manter o fps escolhido, desce um degrau (1080p → 900p → 720p...) e volta sozinha quando sobrar folga."));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(8)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Cursor fora do vídeo: mexer o mouse com a tela parada não gera quadro nenhum###curapart"), &a.cfg.cursor_apart)) {
            config.save(&a.cfg);
            if (a.sharer) |s| s.update(a.shareSettings());
        }
        c.igPopStyleColor(1);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Quem assiste desenha a seta. Só vale se todo mundo que assiste estiver nesta versão; o cursor não aparece nos clipes e gravações de quem assiste (gravando a própria tela, ele volta pro vídeo)."));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(8)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Mandar no tamanho em que aparece pra quem assiste###viewsize"), &a.cfg.view_size)) {
            config.save(&a.cfg);
            if (a.sharer) |s| s.update(a.shareSettings());
        }
        c.igPopStyleColor(1);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Se todo mundo está te vendo num quadradinho da grade, não precisa mandar 1080p: menos placa, menos rede pra todos. Volta na hora quando alguém amplia. Os seus clipes da própria tela saem no tamanho mandado."));
        popFont();
        c.igDummy(v2(0, S(18)));

        fieldLabel("LIMITE DE QUADROS DA INTERFACE");
        const caps = [_]i32{ 30, 60, 0 };
        var ci: i32 = 1;
        for (caps, 0..) |x, i| {
            if (x == a.cfg.ui_fps_cap) ci = @intCast(i);
        }
        if (segmented("fpscap", &.{ "30 q/s", "60 q/s", "O do monitor" }, &ci, w)) {
            a.cfg.ui_fps_cap = caps[@intCast(ci)];
            frame_cap_fps = @intCast(a.cfg.ui_fps_cap);
            config.save(&a.cfg);
        }
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("A interface só redesenha quando algo muda; isso limita quando muda muito (mouse mexendo, vídeo). Menos quadros = menos placa de vídeo."));
        popFont();
        c.igDummy(v2(0, S(18)));

        fieldLabel("ENCODER DA PLACA DE VÍDEO (vale na próxima transmissão)");
        var he: i32 = a.cfg.hw_effort;
        if (segmented("hweffort", &.{ "Leve", "Equilibrado", "Qualidade" }, &he, w)) {
            a.cfg.hw_effort = he;
            codec.setHwEffort(@intCast(he));
            config.save(&a.cfg);
        }
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Leve: menos trabalho na placa (bom pra jogar e transmitir junto), um pouco menos nítido. Qualidade: mais nítido, mais placa."));
        popFont();
        c.igDummy(v2(0, S(10)));
        if (c.igCheckbox(tr("AV1 (experimental, NVIDIA RTX 40 em diante)###av1"), &a.cfg.av1)) {
            codec.av1_enabled.store(a.cfg.av1, .release);
            config.save(&a.cfg);
        }
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Mais nítido com a mesma banda. Só entra quando todo mundo que assiste decodifica AV1 (senão fica no HEVC/H.264); vale na próxima transmissão."));
        popFont();
        c.igDummy(v2(0, S(18)));

        fieldLabel("TESTAR MEU PC");
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Uns segundos medindo quanto esse computador aguenta pra transmitir e pra assistir, e a configuração sugerida."));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(4)));
        const st = pctest.getState();
        const busy = st == .running or a.sharer != null;
        if (busy) c.igBeginDisabled(true);
        if (primaryButton(fmtZ("{s}  Testar meu PC###pctest", .{ic.gauge}), v2(S(200), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
            if (pctest.start()) {
                a.pctest_logged = false;
                debuglog.line("teste do PC começou", .{});
            }
        }
        if (busy) c.igEndDisabled();
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        defer c.igPopTextWrapPos();
        if (a.sharer != null and st != .running) {
            pushFont(font_regular, 12.5);
            textColored(col.muted, tr("Pare de transmitir pra testar (o teste usa o processador todo por uns segundos)."));
            popFont();
        }
        c.igDummy(v2(0, S(6)));
        switch (st) {
            .idle => {},
            .running => {
                textColored(col.muted, fmtZ("Testando... {d}%", .{pctest.getProgress()}));
                redrawIn(0.2);
            },
            .failed => textColored(col.red, tr("O teste não conseguiu rodar.")),
            .done => {
                const r = pctest.getResult();
                const sug = pctest.suggest(&r);
                if (!a.pctest_logged) {
                    a.pctest_logged = true;
                    debuglog.line("teste do PC: CPU 1080p {d:.1} ms, 720p {d:.1} ms, conversão {d:.1} ms | placa {s} {d:.1} ms | decode CPU {d:.1} ms, {s} {d:.1} ms | sugestão {d}p {d} q/s placa={} (assistir até {d} q/s)", .{ r.sw1080_ms, r.sw720_ms, r.conv_ms, r.hwName(), r.hw1080_ms, r.dec_sw_ms, r.decHwName(), r.dec_hw_ms, sug.height, sug.fps, sug.hardware, sug.watch_fps });
                }
                pushFont(font_regular, 13);
                textColored(col.text, fmtZ("Transmitir na CPU (openh264): 1080p {d:.1} ms por quadro · 720p {d:.1} ms", .{ r.sw1080_ms, r.sw720_ms }));
                if (r.hw1080_ms > 0)
                    textColored(col.text, fmtZ("Transmitir na placa ({s}): 1080p {d:.1} ms por quadro", .{ r.hwName(), r.hw1080_ms }))
                else
                    textColored(col.text, tr("Transmitir na placa: esse PC não tem encoder de vídeo que o telinha use."));
                if (r.dec_hw_ms > 0)
                    textColored(col.text, fmtZ("Assistir 1080p: CPU {d:.1} ms por quadro · placa ({s}) {d:.1} ms", .{ r.dec_sw_ms, r.decHwName(), r.dec_hw_ms }))
                else
                    textColored(col.text, fmtZ("Assistir 1080p: CPU {d:.1} ms por quadro", .{r.dec_sw_ms}));
                popFont();
                c.igDummy(v2(0, S(6)));
                pushFont(font_semibold, 14);
                textColored(col.green, fmtZ("Sugestão: transmitir em {d}p a {d} q/s ({s})", .{ sug.height, sug.fps, if (sug.hardware) tr("na placa de vídeo") else tr("na CPU") }));
                popFont();
                pushFont(font_regular, 13);
                textColored(col.muted, fmtZ("Pra assistir, esse PC decodifica uns {d} q/s em 1080p.", .{sug.watch_fps}));
                popFont();
                c.igDummy(v2(0, S(4)));
                if (secondaryButton(tr("Usar a sugestão###pcuse"), v2(S(200), S(34)))) {
                    a.cfg.resolution = switch (sug.height) {
                        1080 => 1,
                        720 => 2,
                        else => 3,
                    };
                    a.cfg.fps = @intCast(sug.fps);
                    a.cfg.hardware = sug.hardware;
                    config.save(&a.cfg);
                    a.toast("Pronto: a próxima transmissão sai em {d}p a {d} q/s.", .{ sug.height, sug.fps }, false);
                }
            },
        }
    }

    fn settingsAbout(a: *App, w: f32) void {
        _ = a;
        const p = c.igGetCursorScreenPos();
        if (logo_tex == 0) gl.upload(&logo_tex, logo_rgba, 128, 128, gl.RGBA);
        c.ImDrawList_AddImage(c.igGetWindowDrawList(), texRef(logo_tex), p, v2(p.x + S(72), p.y + S(72)), v2(0, 0), v2(1, 1), col.white);
        drawTextF(c.igGetWindowDrawList(), font_bold, 22, v2(p.x + S(88), p.y + S(12)), col.header, fmtZ("telinha {s}", .{version_string}));
        drawTextF(c.igGetWindowDrawList(), font_regular, 13, v2(p.x + S(89), p.y + S(42)), col.muted, tr("compartilha a tela com a galera"));
        c.igDummy(v2(w, S(86)));
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 13);
        textColored(col.faint, fmtZ("protocolo v{d} · vídeo H.264 (NVENC/NVDEC, Media Foundation ou openh264) · voz Opus + RNNoise + SpeexDSP · criptografia X25519 + ChaCha20-Poly1305", .{proto.version}));
        c.igDummy(v2(0, S(8)));
        textColored(col.faint, tr("Atalhos: Ctrl+M microfone · Ctrl+D surdo · F11 tela cheia · duplo clique = modo cinema · Esc sai"));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(14)));
        fieldLabel("HISTÓRICO DE VERSÕES");
        drawChangelog(ownChangelog(), w, "hist", true);
    }

    /// Log de depuração: grava tudo num arquivo e manda (gofile.io ou webhook).
    fn drawDebug(a: *App, w: f32) void {
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        var on = debuglog.on();
        if (c.igCheckbox(tr("Gravar log de depuração (desempenho, rede, vídeo, erros: tudo)###debuglog"), &on)) {
            if (on) {
                debuglog.start();
                if (debuglog.on()) a.logSystem() else a.toast("Não consegui criar o arquivo do log.", .{}, true);
            } else debuglog.stop();
            a.cfg.debug_log = debuglog.on();
            config.save(&a.cfg);
            a.debug_size_at = -10;
        }
        c.igPopStyleColor(1);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 12.5);
        textColored(col.faint, tr("Liga, usa normalmente até o problema acontecer (fps caindo, travadas...) e manda o log. Ele tem nomes, endereços e as configurações, mas nenhuma senha."));
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(4)));

        const now = c.igGetTime();
        if (now - a.debug_size_at > 1.0) {
            a.debug_size = debuglog.fileSize();
            a.debug_size_at = now;
        }
        if (debuglog.on()) redrawIn(1.0); // tamanho subindo
        var pb: [600]u8 = undefined;
        const p = debuglog.path(&pb) orelse "?";
        pushFont(font_regular, 12.5);
        // só o nome (o caminho inteiro não cabe; fica na dica)
        if (a.debug_size == 0)
            textColored(col.muted, fmtZ("{s} (vazio)", .{debuglog.file_name}))
        else
            textColored(col.muted, fmtZ("{s} ({d:.1} MB)", .{ debuglog.file_name, @as(f64, @floatFromInt(a.debug_size)) / (1024 * 1024) }));
        popFont();
        if (c.igIsItemHovered(0)) tooltipText(p);
        c.igDummy(v2(0, S(2)));
        const bw = (w - S(8)) / 2;
        if (secondaryButton(fmtZ("{s}  Abrir pasta###dbgdir", .{ic.folder}), v2(bw, S(34)))) {
            var db: [512]u8 = undefined;
            if (config.dirPath(&db)) |dir| _ = openPath(dir);
        }
        c.igSameLine(0, S(8));
        if (secondaryButton(tr("Apagar log###dbgclear"), v2(bw, S(34)))) {
            debuglog.clear();
            if (debuglog.on()) a.logSystem();
            a.debug_size_at = -10;
        }
        c.igDummy(v2(0, S(8)));

        fieldLabel("MANDAR O LOG");
        c.igDummy(v2(0, S(2)));
        var via = a.cfg.debug_send;
        if (segmented("dbgvia", &.{ "gofile.io (gera um link)", "Webhook (Discord etc.)", "Pro dono da sala" }, &via, w)) {
            a.cfg.debug_send = via;
            config.save(&a.cfg);
        }
        const method: debuglog.Method = switch (a.cfg.debug_send) {
            1 => .webhook,
            2 => .room,
            else => .gofile,
        };
        const in_room = if (a.client) |cl| cl.isConnected() else false;
        if (method == .room) {
            c.igDummy(v2(0, S(4)));
            pushFont(font_regular, 12.5);
            c.igPushTextWrapPos(c.igGetCursorPosX() + w);
            if (!in_room)
                textColored(col.yellow, tr("Entre numa sala pra mandar o log pro dono dela (quem tem a coroa)."))
            else if (a.server != null)
                textColored(col.muted, tr("Você é o dono desta sala: quem mandar o log por aqui, ele chega no seu PC (pasta logs-recebidos)."))
            else
                textColored(col.muted, tr("O log vai pela própria sala, direto pra quem tem a coroa. Servidor dedicado com --logs também guarda uma cópia."));
            c.igPopTextWrapPos();
            popFont();
        }
        c.igDummy(v2(0, S(4)));
        if (method == .webhook) {
            // escondido: a URL é a chave do canal (e a tela pode estar sendo transmitida)
            if (textField("##dbghook", "https://discord.com/api/webhooks/...", a.cfg.debug_webhook[0 .. a.cfg.debug_webhook.len - 1], w, true)) config.save(&a.cfg);
            if (c.igIsItemDeactivatedAfterEdit()) config.save(&a.cfg);
            c.igDummy(v2(0, S(4)));
        }
        const st = debuglog.sendState();
        const hook = config.getStr(&a.cfg.debug_webhook);
        const can = a.debug_size > 0 and st != .sending and switch (method) {
            .gofile => true,
            .webhook => debuglog.validUrl(hook),
            .room => in_room and a.server == null,
        };
        if (!can) c.igBeginDisabled(true);
        if (primaryButton(fmtZ("{s}  Enviar log###dbgsend", .{ic.send}), v2(w, S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
            a.debug_sent_via = method;
            debuglog.send(method, hook, config.getStr(&a.cfg.name)) catch |e| switch (e) {
                error.BadUrl => a.toast("Link do webhook inválido (tem que começar com https://).", .{}, true),
                error.Busy => {},
                error.OutOfMemory => a.toast("Sem memória.", .{}, true),
            };
        }
        if (!can) c.igEndDisabled();
        if (method == .webhook and hook.len > 0 and !debuglog.validUrl(hook)) {
            pushFont(font_regular, 12.5);
            textColored(col.red, tr("Link do webhook inválido (tem que começar com https://)."));
            popFont();
        }

        var rb: [512]u8 = undefined;
        const res = debuglog.sendResult(&rb);
        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 13);
        switch (st) {
            .idle => {},
            .sending => {
                textColored(col.muted, tr("Enviando o log..."));
                redrawIn(0.25);
            },
            .failed => {
                var eb: [300]u8 = undefined;
                textColored(col.red, fmtZ("Não consegui enviar: {s}", .{i18n.dynamic(res, &eb)}));
            },
            .done => if (a.debug_sent_via == .webhook) {
                textColored(col.green, tr("Log enviado pro webhook."));
            } else if (a.debug_sent_via == .room) {
                const saved_only = std.mem.eql(u8, res, room_log_saved);
                textColored(col.green, if (saved_only) tr("O servidor da sala guardou o log (ninguém com a coroa estava na sala agora).") else tr("Log entregue pro dono da sala."));
            } else {
                textColored(col.green, tr("Pronto! Manda esse link pra quem vai olhar o log:"));
                var lz: [520]u8 = undefined;
                const link = std.fmt.bufPrintZ(&lz, "{s}", .{res}) catch "";
                pushFont(font_semibold, 13.5);
                textColored(col.header, link);
                popFont();
                if (secondaryButton(fmtZ("{s}  Copiar link###dbgcopy", .{ic.copy}), v2(bw, S(32)))) {
                    c.igSetClipboardText(link.ptr);
                    a.toast("Link copiado.", .{}, false);
                }
                c.igSameLine(0, S(8));
                if (secondaryButton(fmtZ("{s}  Abrir###dbgopen", .{ic.link}), v2(bw, S(32)))) _ = openPath(link);
            },
        }
        popFont();
        c.igPopTextWrapPos();

        // relatório de travamento (o app oferece mandar ao abrir; aqui dá pra mandar depois)
        c.igDummy(v2(0, S(16)));
        fieldLabel("RELATÓRIO DE TRAVAMENTO");
        pushFont(font_regular, 13);
        if (crash.pending()) {
            textColored(col.text, tr("Tem um relatório do último travamento, ainda não mandado."));
            popFont();
            c.igDummy(v2(0, S(2)));
            if (secondaryButton(fmtZ("{s}  Mandar o relatório###crashsend", .{ic.send}), v2(S(220), S(34)))) a.sendCrashReport();
        } else {
            textColored(col.muted, tr("Nenhum travamento registrado."));
            popFont();
        }
    }
    /// Tema: um cartãozinho com as cores de cada um (troca na hora).
    fn drawThemes(a: *App, w: f32) void {
        const id = config.getStr(&a.cfg.theme);
        const custom_on = std.mem.eql(u8, id, theme.custom_id);
        const cur: usize = if (custom_on) theme.list.len else theme.find(id);
        const per_row = 3;
        const gap = S(8);
        const cw = (w - gap * (per_row - 1)) / per_row;
        const ch = S(54);
        const custom_base = theme.decodeBase(config.getStr(&a.cfg.custom_theme));
        inline for (0..theme.list.len + 1) |i| {
            if (i % per_row != 0) c.igSameLine(0, gap);
            const is_custom = i == theme.list.len;
            const label = if (is_custom) "##tema-" ++ theme.custom_id else "##tema-" ++ theme.list[i].id;
            const pal = if (is_custom) theme.derive(custom_base) else theme.list[i].pal;
            const name = if (is_custom) tr("Personalizado") else tr(theme.list[i].name);
            if (themeCard(label, pal, name, cw, ch, i == cur) and i != cur) {
                const new_id = if (is_custom) theme.custom_id else theme.list[i].id;
                config.setStr(&a.cfg.theme, new_id);
                a.theme_dirty = true; // aplica no começo do próximo quadro (fora das janelas abertas)
                config.save(&a.cfg);
            }
        }
        if (custom_on) a.drawCustomTheme(w);
    }

    /// Um cartãozinho nas cores (e cantos) do próprio tema. true = clicou.
    fn themeCard(label: [:0]const u8, pal: theme.Palette, name: []const u8, cw: f32, ch: f32, selected: bool) bool {
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        const clicked = c.igInvisibleButton(label.ptr, v2(cw, ch), 0);
        const hov = c.igIsItemHovered(0);
        const r = S(6) * pal.round;
        c.ImDrawList_AddRectFilled(d, p, v2(p.x + cw, p.y + ch), pal.bg_side, r, 0);
        c.ImDrawList_AddRectFilled(d, v2(p.x + S(16), p.y), v2(p.x + cw, p.y + ch), pal.bg_main, r, 0);
        drawTextF(d, font_semibold, 13, v2(p.x + S(26), p.y + S(9)), pal.header, name);
        const by = p.y + ch - S(17);
        c.ImDrawList_AddRectFilled(d, v2(p.x + S(26), by), v2(p.x + S(58), by + S(9)), pal.blurple, S(3) * pal.round, 0);
        c.ImDrawList_AddRectFilled(d, v2(p.x + S(63), by), v2(p.x + S(77), by + S(9)), pal.green, S(3) * pal.round, 0);
        c.ImDrawList_AddRectFilled(d, v2(p.x + S(82), by), v2(p.x + S(96), by + S(9)), pal.red, S(3) * pal.round, 0);
        const border = if (selected) col.blurple else if (hov) col.muted else withAlpha(col.text, 40);
        c.ImDrawList_AddRect(d, p, v2(p.x + cw, p.y + ch), border, r, if (selected) S(2) else S(1), 0);
        return clicked;
    }

    /// Salva daqui a pouco (mudança contínua, tipo arrastar uma cor: uma escrita só no fim).
    fn saveSoon(a: *App) void {
        a.save_at = c.igGetTime() + 0.8;
        redrawIn(0.85);
    }

    /// O arquivo CSS do tema mudou: as cores novas vão pro tema personalizado.
    fn takeCssFile(a: *App) bool {
        const b = cssfile.take() orelse return false;
        var eb: [96]u8 = undefined;
        config.setStr(&a.cfg.custom_theme, theme.encodeBase(b, &eb));
        config.save(&a.cfg);
        return std.mem.eql(u8, config.getStr(&a.cfg.theme), theme.custom_id);
    }

    fn applyTheme(a: *App) void {
        setTheme(config.getStr(&a.cfg.theme), config.getStr(&a.cfg.custom_theme));
    }

    /// Tema personalizado: as cores base (o resto sai delas), colar um CSS
    /// (as variáveis do :root) ou copiar o tema como CSS.
    fn drawCustomTheme(a: *App, w: f32) void {
        var b = theme.decodeBase(config.getStr(&a.cfg.custom_theme));
        var changed = false;
        c.igDummy(v2(0, S(8)));
        const fields = [_]struct { v: *u24, name: [:0]const u8, id: [:0]const u8 }{
            .{ .v = &b.bg, .name = tr("Fundo"), .id = "##cbg" },
            .{ .v = &b.side, .name = tr("Painéis"), .id = "##cside" },
            .{ .v = &b.accent, .name = tr("Destaque"), .id = "##caccent" },
            .{ .v = &b.accent2, .name = tr("Destaque (mouse em cima)"), .id = "##caccent2" },
            .{ .v = &b.text, .name = tr("Texto"), .id = "##ctext" },
            .{ .v = &b.ok, .name = tr("Verde"), .id = "##cok" },
            .{ .v = &b.danger, .name = tr("Vermelho"), .id = "##cdanger" },
        };
        const colw = (w - S(12)) / 2;
        for (fields, 0..) |fld, i| {
            if (i % 2 == 1) c.igSameLine(0, S(12));
            var rgbf = [3]f32{
                @as(f32, @floatFromInt((fld.v.* >> 16) & 0xff)) / 255,
                @as(f32, @floatFromInt((fld.v.* >> 8) & 0xff)) / 255,
                @as(f32, @floatFromInt(fld.v.* & 0xff)) / 255,
            };
            c.igBeginGroup();
            if (c.igColorEdit3(fld.id.ptr, &rgbf, c.ImGuiColorEditFlags_NoInputs | c.ImGuiColorEditFlags_NoLabel)) {
                var out: u24 = 0;
                for (rgbf) |x| out = (out << 8) | @as(u24, @intFromFloat(std.math.clamp(@round(x * 255), 0, 255)));
                fld.v.* = out;
                changed = true;
            }
            c.igSameLine(0, S(8));
            textColored(col.text, fld.name);
            c.igEndGroup();
            if (i % 2 == 0) {
                // a outra coluna começa na metade
                c.igSameLine(colw, 0);
                c.igDummy(v2(0, 0));
            }
        }
        c.igNewLine();
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        changed = c.igCheckbox(tr("Cantos retos###csquare"), &b.square) or changed;
        c.igSameLine(0, S(16));
        changed = c.igCheckbox(tr("Fonte monoespaçada (Fira Code)###cmono"), &b.mono) or changed;
        c.igPopStyleColor(1);
        c.igDummy(v2(0, S(6)));
        const bw = (w - S(8)) / 2;
        if (secondaryButton(fmtZ("{s}  Colar CSS###csspaste", .{ic.copy}), v2(bw, S(34)))) {
            const cb_text: [*c]const u8 = c.igGetClipboardText();
            const text = if (cb_text != null) std.mem.span(cb_text) else "";
            if (theme.parseCss(text)) |nb| {
                b = nb;
                changed = true;
                a.toast("Tema montado a partir do CSS.", .{}, false);
            } else a.toast("Não achei as cores no CSS copiado (precisa das variáveis do :root, tipo --bg: #050505).", .{}, true);
        }
        c.igSameLine(0, S(8));
        if (secondaryButton(fmtZ("{s}  Copiar como CSS###csscopy", .{ic.copy}), v2(bw, S(34)))) {
            var cb: [512:0]u8 = undefined;
            const css = theme.toCss(b, cb[0..511]);
            cb[css.len] = 0;
            c.igSetClipboardText(&cb);
            a.toast("Tema copiado como CSS.", .{}, false);
        }
        if (changed) {
            var eb: [96]u8 = undefined;
            config.setStr(&a.cfg.custom_theme, theme.encodeBase(b, &eb));
            a.theme_dirty = true;
            a.saveSoon(); // arrastando a cor muda a cada quadro: salva quando parar
        }

        // arquivo CSS: as cores vêm dele e acompanham quando ele é salvo
        c.igDummy(v2(0, S(10)));
        fieldLabel("ARQUIVO CSS (atualiza sozinho quando você salva o arquivo)");
        const pw = w - S(110) - S(8);
        const enter = textField("##csspath", "/caminho/do/tema.css", a.cfg.custom_css[0 .. a.cfg.custom_css.len - 1], pw, false);
        c.igSameLine(0, S(8));
        const watching = cssfile.getStatus() != .off;
        const use = secondaryButton(if (watching) tr("Parar###cssfile") else tr("Usar###cssfile"), v2(S(110), S(36)));
        if (use and watching) {
            cssfile.watch("");
            config.setStr(&a.cfg.custom_css, "");
            config.save(&a.cfg);
        } else if (enter or use) {
            const p = std.mem.trim(u8, config.getStr(&a.cfg.custom_css), " \"'");
            var pb2: [512]u8 = undefined;
            @memcpy(pb2[0..p.len], p);
            config.setStr(&a.cfg.custom_css, pb2[0..p.len]);
            config.save(&a.cfg);
            cssfile.watch(pb2[0..p.len]);
            if (a.takeCssFile()) a.theme_dirty = true;
        }
        pushFont(font_regular, 12.5);
        switch (cssfile.getStatus()) {
            .off => textColored(col.faint, tr("Cole o caminho de um .css com variáveis no :root (--bg, --accent...).")),
            .ok => textColored(col.green, tr("Usando o arquivo: salvou, mudou aqui.")),
            .missing => textColored(col.red, tr("Não achei o arquivo.")),
            .no_colors => textColored(col.red, tr("O arquivo não tem as cores (variáveis do :root, tipo --bg: #050505).")),
        }
        popFont();
    }

    /// Idioma da interface (troca na hora).
    fn drawLanguage(a: *App, w: f32) void {
        const cur = config.getStr(&a.cfg.language);
        const sel: usize = if (std.mem.eql(u8, cur, "pt")) 1 else if (std.mem.eql(u8, cur, "en")) 2 else 0;
        // Português e English sempre na própria língua
        const labels = [_][:0]const u8{ tr("Automático###lang0"), "Português###lang1", "English###lang2" };
        const values = [_][]const u8{ "auto", "pt", "en" };
        c.igSetNextItemWidth(w);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(4)));
        defer {
            c.igPopStyleVar(1);
            c.igPopStyleColor(1);
        }
        const open = beginCombo("##lang", fmtZ("{s}  {s}", .{ ic.globe, labels[sel] }).ptr, 0);
        if (c.igIsItemHovered(0)) tooltipText(tr("Idioma / Language"));
        if (!open) return;
        defer c.igEndCombo();
        for (labels, values, 0..) |lb, v, i| {
            if (!c.igSelectable_Bool(lb.ptr, sel == i, 0, v2(0, 0))) continue;
            config.setStr(&a.cfg.language, v);
            i18n.set(i18n.resolve(v));
            config.save(&a.cfg);
        }
    }

    /// igBeginCombo com rótulo pro modo de testes (o ImGui não registra o do combo).
    fn beginCombo(id: [:0]const u8, preview: [*c]const u8, flags: c_int) bool {
        const iid = c.igGetID_Str(id.ptr);
        const open = c.igBeginCombo(id.ptr, preview, flags);
        if (qa.enabled()) c.qa_label(iid, id.ptr);
        return open;
    }

    fn sliderStyled(id: [:0]const u8, v: *i32, min: i32, max: i32, f: [:0]const u8, w: f32) void {
        c.igSetNextItemWidth(w);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, col.hover);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, col.hover);
        c.igPushStyleColor_U32(c.ImGuiCol_SliderGrab, col.blurple);
        c.igPushStyleColor_U32(c.ImGuiCol_SliderGrabActive, col.blurple_hover);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(7)));
        // AlwaysClamp: Ctrl+clique deixa digitar qualquer número
        _ = c.igSliderInt(id.ptr, v, min, max, f.ptr, c.ImGuiSliderFlags_AlwaysClamp);
        c.igPopStyleVar(1);
        c.igPopStyleColor(5);
    }

    // ------------------------------------------------------- modo de testes

    /// Estado pro modo de testes (TELINHA_QA, ver qa.zig): o que um teste
    /// precisa conferir depois de clicar num botão.
    pub fn qaState(a: *App, w: *std.Io.Writer) !void {
        const s = qa.str;
        try w.print("{{\"screen\":{f},\"home_error\":{f}", .{ s(@tagName(a.screen)), s(a.home_error[0..a.home_error_len]) });
        try w.print(",\"mic\":{},\"deaf\":{},\"share_modal\":{},\"settings_modal\":{},\"theater\":{},\"fullscreen\":{},\"controls_hidden\":{}", .{ a.mic != null, a.deaf, a.share_modal, a.settings_modal, a.theater, a.fullscreen, a.controls_hidden });
        if (a.focused) |f| try w.print(",\"focused\":{d}", .{f}) else try w.writeAll(",\"focused\":null");
        try w.print(",\"reconnect\":{{\"attempt\":{d},\"waiting\":{}}}", .{ a.reconnect.attempt, a.reconnect.waiting });
        try w.print(",\"home_tab\":{d},\"show_advanced\":{},\"own_tunnel_open\":{},\"chat_visible\":{},\"side_visible\":{},\"chat_unread\":{d}", .{
            a.home_tab, a.show_advanced, a.own_tunnel_open, a.chat_visible, a.side_visible, a.chat_unread,
        });
        const cf = &a.cfg;
        try w.print(",\"cfg\":{{\"name\":{f},\"join_addr\":{f},\"join_pass\":{f},\"room_name\":{f},\"host_pass\":{f},\"port\":{f},\"public_addr\":{f},\"join_fp\":{f}", .{
            s(config.getStr(&cf.name)),      s(config.getStr(&cf.join_addr)),    s(config.getStr(&cf.join_pass)),   s(config.getStr(&cf.room_name)),
            s(config.getStr(&cf.host_pass)), s(std.mem.sliceTo(&a.port_buf, 0)), s(config.getStr(&cf.public_addr)), s(config.getStr(&cf.join_fp)),
        });
        try w.print(",\"fps\":{d},\"quality\":{d},\"mode\":{d},\"resolution\":{d},\"cursor\":{},\"audio\":{},\"hardware\":{},\"stats_always\":{},\"show_chat\":{}", .{
            cf.fps, cf.quality, cf.mode, cf.resolution, cf.cursor, cf.audio, cf.hardware, cf.stats_always, cf.show_chat,
        });
        try w.print(",\"noise_suppression\":{},\"echo_cancellation\":{},\"voice_sensitivity\":{d},\"mic_on_join\":{},\"sounds\":{},\"mic_device\":{f},\"notifications\":{},\"clips\":{},\"camera_res\":{d},\"camera_device\":{f},\"cameras\":{d},\"audio_app\":{f},\"audio_exclude\":{f},\"audio_apps\":{d},\"language\":{f},\"debug_log\":{},\"debug_send\":{d},\"debug_webhook\":{f},\"theme\":{f},\"custom_theme\":{f},\"custom_css\":{f},\"css_status\":{f},\"auto_quality\":{},\"resolution_idx\":{d},\"ui_zoom\":{d},\"crt\":{},\"voice_ptt\":{},\"ptt_key\":{d},\"ptt_mouse\":{d},\"clip_key\":{d}", .{
            cf.noise_suppression, cf.echo_cancellation, cf.voice_sensitivity, cf.mic_on_join, cf.sounds, s(config.getStr(&cf.mic_device)), cf.notifications, cf.clips, cf.camera_res, s(config.getStr(&cf.camera_device)), a.n_cams, s(config.getStr(&cf.audio_app)), s(config.getStr(&cf.audio_exclude)), a.n_audio_apps, s(config.getStr(&cf.language)), cf.debug_log, cf.debug_send, s(config.getStr(&cf.debug_webhook)), s(config.getStr(&cf.theme)), s(config.getStr(&cf.custom_theme)), s(config.getStr(&cf.custom_css)), s(@tagName(cssfile.getStatus())), cf.auto_quality, cf.resolution, cf.ui_zoom, cf.crt, cf.voice_ptt, cf.ptt_key, cf.ptt_mouse, cf.hk[@intFromEnum(config.HotkeyId.clip)].key,
        });
        try w.print(",\"hotkeys_on\":{},\"hk_mic\":{d},\"hk_mic_mods\":{d},\"hk_deaf\":{d},\"hk_toggle\":{d},\"clip_secs\":{d}}}", .{
            cf.hotkeys_on, cf.hk[@intFromEnum(config.HotkeyId.mic)].key, cf.hk[@intFromEnum(config.HotkeyId.mic)].mods, cf.hk[@intFromEnum(config.HotkeyId.deaf)].key, cf.hk[@intFromEnum(config.HotkeyId.toggle)].key, cf.clip_secs,
        });
        try w.print(",\"lang\":{f}", .{s(@tagName(i18n.get()))});
        const cb_text: [*c]const u8 = c.glfwGetClipboardString(a.window);
        try w.print(",\"clipboard\":{f},\"chat_input\":{f}", .{ s(if (cb_text != null) std.mem.span(cb_text) else ""), s(std.mem.sliceTo(&a.chat_input, 0)) });
        try w.print(",\"reply_to\":{d},\"dm_to\":{d}", .{ a.reply_id, a.dm_to });
        if (a.client) |xcl| {
            try w.writeAll(",\"transfers\":[");
            var all: [16]*filexfer.Transfer = undefined;
            const n = xcl.xfers.snapshot(&all);
            for (all[0..n], 0..) |t, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"kind\":{f},\"name\":{f},\"state\":{f},\"file_id\":{d},\"done\":{d},\"size\":{d},\"path\":{f},\"err\":{f}}}", .{ s(@tagName(t.kind)), s(t.nameSlice()), s(@tagName(t.state.load(.acquire))), t.file_id.load(.acquire), t.done_bytes.load(.acquire), t.size, s(t.pathSlice()), s(t.errSlice()) });
                t.release();
            }
            try w.writeAll("]");
        }
        try w.print(",\"notifications_sent\":{d},\"away\":{},\"iconified\":{},\"preview_uploads\":{d}", .{ a.notifications_sent, a.away(), a.iconified, a.preview_uploads });
        try w.writeAll(",\"sources\":[");
        for (a.sources[0..a.n_sources], 0..) |*src, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"id\":{d},\"name\":{f}}}", .{ src.id, s(std.mem.sliceTo(&src.name, 0)) });
        }
        try w.print("],\"source_idx\":{d}", .{a.source_idx});
        try w.writeAll(",\"pips\":[");
        var first_pip = true;
        for (a.pips) |maybe| if (maybe) |pp| {
            var px: c_int = 0;
            var py: c_int = 0;
            var pw: c_int = 0;
            var ph: c_int = 0;
            c.glfwGetWindowPos(pp.win, &px, &py);
            c.glfwGetWindowSize(pp.win, &pw, &ph);
            if (!first_pip) try w.writeByte(',');
            first_pip = false;
            try w.print("{{\"stream\":{d},\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ pp.stream, px, py, pw, ph });
        };
        try w.writeAll("]");
        var ub: [32]u8 = undefined;
        try w.print(",\"opened\":{f},\"update\":{f},\"update_latest\":{f}", .{ s(qa_opened[0..qa_opened_len]), s(@tagName(update.getState())), s(update.latest(&ub)) });
        const un = update.notes();
        try w.print(",\"pid\":{d},\"update_modal\":{},\"update_can\":{},\"update_why\":{f},\"update_err\":{f},\"update_notes\":{f},\"whatsnew\":{}", .{
            qaPid(), a.update_modal, update.canInstall(), s(update.whyNot()), s(update.installError()), s(un[0..@min(un.len, 600)]), a.whatsnew,
        });
        try w.print(",\"speaking\":{}", .{if (a.mic) |m| m.speaking.load(.monotonic) else false});
        try w.print(",\"crop\":[{d:.3},{d:.3},{d:.3},{d:.3}],\"strokes\":[", .{ a.crop[0], a.crop[1], a.crop[2], a.crop[3] });
        if (a.client) |cl| {
            cl.mutex.lock();
            for (cl.strokes.items, 0..) |st, i| try w.print("{s}{{\"from\":{d},\"stream\":{d},\"n\":{d},\"color\":{d},\"size\":{d}}}", .{ if (i > 0) "," else "", st.from, st.stream, st.n, st.style >> proto.draw_color_shift, (st.style >> proto.draw_size_shift) & 3 });
            cl.mutex.unlock();
        }
        try w.print("],\"strokes_drawn\":{d},\"show_drawings\":{},\"draw_color\":{d},\"draw_size\":{d},\"drawing\":{}", .{ a.strokes_drawn, a.cfg.show_drawings, a.cfg.draw_color, a.cfg.draw_size, a.draw_tile != null });
        try w.print(",\"pctest\":{f},\"crash_pending\":{},\"crash_prompt\":{}", .{ s(@tagName(pctest.getState())), crash.pending(), a.crash_prompt });
        var dlb: [512]u8 = undefined;
        try w.print(",\"debug_on\":{},\"debug_size\":{d},\"debug_send\":{f},\"debug_result\":{f}", .{ debuglog.on(), debuglog.fileSize(), s(@tagName(debuglog.sendState())), s(debuglog.sendResult(&dlb)) });
        try w.print(",\"last_saved\":{f},\"clip_jobs\":{d}", .{ s(a.last_saved[0..a.last_saved_len]), blk: {
            var n: usize = 0;
            for (a.clip_jobs) |j| n += @intFromBool(j != null);
            break :blk n;
        } });
        try w.print(",\"hosting\":{},\"leave_confirm\":{},\"admin_muted\":{},\"pointer_tile\":{d}", .{ a.server != null, a.leave_confirm, a.admin_muted, if (a.pointer_tile) |pt| @as(i64, pt) else -1 });
        if (a.camera) |cam| {
            cam.mutex.lock();
            defer cam.mutex.unlock();
            try w.print(",\"camera\":{{\"state\":{f},\"w\":{d},\"h\":{d},\"fps\":{d:.1},\"err\":{f}}}", .{ s(@tagName(cam.state)), cam.w, cam.h, cam.fps, s(cam.errSlice()) });
        } else try w.writeAll(",\"camera\":null");
        if (a.server) |srv| try w.print(",\"server_members\":{d}", .{srv.memberCount()});
        // link público e porta no roteador
        if (a.tunnel) |t| {
            var buf: [300]u8 = undefined;
            const st = t.status();
            try w.print(",\"tunnel\":{{\"state\":{f},\"addr\":{f},\"err\":{f}}}", .{ s(@tagName(st.state)), s(t.address(&buf)), s(st.err) });
        } else try w.writeAll(",\"tunnel\":null");
        if (a.upnp) |m| {
            var buf: [64]u8 = undefined;
            const st = m.status();
            try w.print(",\"upnp\":{{\"state\":{f},\"addr\":{f},\"err\":{f}}}", .{ s(@tagName(st.state)), s(m.address(&buf)), s(st.err) });
        } else try w.writeAll(",\"upnp\":null");
        // transmissão própria
        if (a.sharer) |sh| {
            sh.mutex.lock();
            defer sh.mutex.unlock();
            const audio_on = sh.audio_on;
            const aerr: [160]u8 = sh.audio_err;
            try w.print(",\"sharer\":{{\"state\":{f},\"w\":{d},\"h\":{d},\"fps\":{d:.1},\"backend\":{f},\"encoder\":{f},\"audio\":{},\"audio_err\":{f},\"auto_cap\":{d},\"frames\":{d},\"cursor_msgs\":{d}}}", .{ s(@tagName(sh.state)), sh.w, sh.h, sh.fps, s(sh.backendSlice()), s(sh.encoder_name), audio_on, s(std.mem.sliceTo(&aerr, 0)), sh.auto_cap.load(.acquire), sh.frames_sent.load(.monotonic), sh.cursor_msgs.load(.monotonic) });
        } else try w.writeAll(",\"sharer\":null");
        // avisos na tela
        try w.writeAll(",\"toasts\":[");
        for (a.toasts[0..a.n_toasts], 0..) |*t, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}", .{s(t.text[0..t.len])});
        }
        try w.writeAll("]");
        // onde estão os quadros das transmissões
        try w.writeAll(",\"tiles\":[");
        for (a.tile_rects[0..a.n_tile_rects], 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            const zm = a.zoomFor(r.stream);
            try w.print("{{\"stream\":{d},\"x0\":{d:.0},\"y0\":{d:.0},\"x1\":{d:.0},\"y1\":{d:.0},\"zoom\":{d:.2},\"follow\":{}}}", .{ r.stream, r.x0, r.y0, r.x1, r.y1, zm.z, zm.follow });
        }
        try w.writeAll("]");
        try w.writeAll(",\"live_rows\":[");
        for (a.live_rects[0..a.n_live_rects], 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"stream\":{d},\"x0\":{d:.0},\"y0\":{d:.0},\"x1\":{d:.0},\"y1\":{d:.0}}}", .{ r.stream, r.x0, r.y0, r.x1, r.y1 });
        }
        try w.writeAll("]");
        try w.writeAll(",\"member_rows\":[");
        for (a.member_rects[0..a.n_member_rects], 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"id\":{d},\"x0\":{d:.0},\"y0\":{d:.0},\"x1\":{d:.0},\"y1\":{d:.0}}}", .{ r.id, r.x0, r.y0, r.x1, r.y1 });
        }
        try w.writeAll("]");
        // transmissões assistidas
        try w.writeAll(",\"views\":[");
        for (a.views.items, 0..) |v, i| {
            if (i > 0) try w.writeByte(',');
            const has_audio = v.audio_registered;
            const rs: clip.Buffer.RecState = if (v.clip) |cb| cb.recState() else .{ .active = false, .waiting = false, .ms = 0, .failed = false };
            try w.print("{{\"stream\":{d},\"fps\":{d:.1},\"w\":{d},\"h\":{d},\"shown\":{},\"audio\":{},\"volume\":{d:.2},\"muted\":{},\"clip_secs\":{d:.1},\"recording\":{},\"rec_ms\":{d},\"decoder\":{f},\"codec\":{f},\"latency\":{d:.0},\"cursor_apart\":{},\"cursor_x\":{d},\"cursor_y\":{d},\"view_sent_h\":{d}}}", .{
                v.stream,                      v.fps,                       v.tex_w,                     v.tex_h,       v.tex != 0, has_audio, v.audio_ring.getVolume(), v.audio_ring.isMuted(), if (v.clip) |cb| cb.seconds() else -1, rs.active, rs.ms, s(v.decoder_name), s(v.codec.name()), v.latency_ms,
                v.cursor_apart.load(.acquire), v.cursor_x.load(.monotonic), v.cursor_y.load(.monotonic), v.view_sent_h,
            });
        }
        try w.writeAll("]");
        // conexão com a sala
        if (a.client) |cl| {
            cl.mutex.lock();
            defer cl.mutex.unlock();
            try w.print(",\"status\":{f},\"error\":{f},\"final\":{},\"deny\":{d},\"my_id\":{d},\"admin\":{},\"route\":{d},\"locked\":{},\"room\":{f},\"ping\":{d}", .{
                s(@tagName(cl.status)), s(cl.err[0..cl.err_len]), cl.final, cl.deny_code, cl.my_id, cl.is_admin, cl.route, cl.room_locked, s(cl.room_name[0..cl.room_name_len]), cl.ping_ms,
            });
            if (cl.udp.load(.acquire)) |l| {
                const st = l.ep.stats;
                try w.print(",\"udp\":{{\"active\":{},\"rtt\":{d},\"sent\":{d},\"resent\":{d},\"nacks\":{d},\"lost\":{d}}}", .{ l.isActive(), l.ep.rttMs(), st.sent_pkts, st.resent_pkts, st.nacks_sent, st.lost_msgs });
            } else try w.writeAll(",\"udp\":null");
            try w.writeAll(",\"members\":[");
            for (cl.members.items, 0..) |*m, i| {
                if (i > 0) try w.writeByte(',');
                const vv = cl.voice_volumes.get(m.id) orelse 1.0;
                // tocando voz agora (o mutex já está travado: sem o cl.speaking)
                var spk = false;
                for (cl.voice_peers.items) |p| if (p.id == m.id) {
                    spk = p.speaking(sync.nowUs());
                };
                try w.print("{{\"id\":{d},\"name\":{f},\"speaking\":{},\"flags\":{d},\"streaming\":{},\"camera\":{},\"admin\":{},\"owner\":{},\"bot\":{},\"muted\":{},\"route\":{d},\"audio\":{},\"w\":{d},\"h\":{d},\"voice_volume\":{d:.2},\"watching\":[", .{
                    m.id, s(m.nameSlice()), spk, m.flags, m.streaming, m.camera(), m.admin, m.owner, m.bot, m.muted(), m.route, m.audio, m.w, m.h, vv,
                });
                for (m.watching[0..m.n_watching], 0..) |id, k| {
                    if (k > 0) try w.writeByte(',');
                    try w.print("{d}", .{id});
                }
                try w.writeAll("]}");
            }
            try w.writeAll("],\"pointers\":[");
            for (cl.pointers.items, 0..) |pt, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"from\":{d},\"stream\":{d},\"x\":{d},\"y\":{d},\"flags\":{d},\"ping\":{}}}", .{ pt.from, pt.stream, pt.x, pt.y, pt.flags, pt.ping_us != 0 });
            }
            try w.writeAll("]");
            try w.print(",\"img_view\":{?d},\"img_sending\":{d},\"img_sent\":{d},\"react_hover\":{?d},\"mention_sugg\":[", .{ a.img_view, chatsend.running.load(.acquire), chatsend.sent.load(.acquire), a.react_hover });
            for (0..a.n_mention_sugg) |i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}", .{s(a.mention_sugg[i][0..a.mention_sugg_len[i]])});
            }
            try w.writeAll("],\"chat\":[");
            const first = cl.chat.items.len -| 30;
            for (cl.chat.items[first..], 0..) |*l, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"id\":{d},\"from\":{d},\"name\":{f},\"text\":{f},\"history\":{}", .{ l.id, l.from, s(l.nameSlice()), s(l.text), l.history });
                try w.print(",\"reply_id\":{d},\"reply_from\":{d},\"reply_name\":{f},\"reply_snip\":{f},\"to\":{d},\"to_name\":{f},\"file_id\":{d},\"file_name\":{f},\"file_size\":{d}", .{ l.reply_id, l.reply_from, s(l.replyName()), s(l.replySnip()), l.to, s(l.toName()), l.file_id, s(l.fileName()), l.file_size });
                const ready = for (a.img_cache) |e| {
                    if (e.id == l.id and e.tex != 0) break true;
                } else false;
                try w.print(",\"img\":{},\"img_w\":{d},\"img_h\":{d},\"img_bytes\":{d},\"img_ready\":{},\"img_expired\":{},\"reacts\":[", .{ l.img != null, l.img_w, l.img_h, if (l.img) |im| im.len else 0, ready, l.img_expired });
                for (0..proto.reactions) |e| {
                    if (e > 0) try w.writeByte(',');
                    try w.print("{d}", .{l.reactCount(@intCast(e), cl.my_id).n});
                }
                try w.writeAll("]}");
            }
            try w.writeAll("]");
            // canais e estatísticas do servidor
            try w.print(",\"id_state\":{f},\"server_fp\":{f}", .{ s(@tagName(cl.id_state)), s(if (cl.id_state == .verified or cl.id_state == .mismatch) &cl.server_fp else "") });
            try w.print(",\"channels_supported\":{},\"channel\":{f},\"call\":{f},\"calls_known\":{},\"chan_pw_for\":{f},\"chan_members\":[", .{ cl.chans_supported, s(cl.chan_name[0..cl.chan_name_len]), s(cl.call_name[0..cl.call_name_len]), cl.calls_known, s(a.chan_pw_for[0..a.chan_pw_len]) });
            for (cl.chan_members.items, 0..) |*m, i| try w.print("{s}{d}", .{ if (i > 0) "," else "", m.id });
            try w.writeAll("],\"channels\":[");
            for (cl.chans[0..cl.n_chans], 0..) |*ch, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"name\":{f},\"people\":{d},\"in_call\":{d},\"live\":{},\"fixed\":{},\"locked\":{},\"password\":{},\"topic\":{f}}}", .{ s(ch.nameSlice()), ch.people, ch.in_call, ch.flags & proto.chan_live != 0, ch.flags & proto.chan_fixed != 0, ch.flags & proto.chan_locked != 0, ch.flags & proto.chan_password != 0, s(ch.topicSlice()) });
            }
            const sst = &cl.stats;
            try w.print("],\"channel_gen\":{d},\"stats_open\":{},\"stats_gen\":{d},\"stats\":{{\"conns\":{d},\"channels\":{d},\"cpu\":{d},\"rss_kb\":{d},\"out_bps\":{d},\"in_bps\":{d},\"people\":{d},\"hosted\":{}}}", .{
                cl.channel_gen.load(.acquire), a.stats_open, cl.stats_gen, sst.conns, sst.channels, sst.cpu_permille, sst.rss_kb, sst.out_bps, sst.in_bps, sst.n_people, sst.hosted(),
            });
        } else try w.writeAll(",\"status\":null");
        try w.writeAll("}\n");
    }

    // ---------------------------------------------------------------- toasts

    fn drawToasts(a: *App, size: c.ImVec2_c) void {
        const now = c.igGetTime();
        var i: usize = 0;
        while (i < a.n_toasts) {
            if (a.toasts[i].until < now) {
                std.mem.copyForwards(Toast, a.toasts[i .. a.n_toasts - 1], a.toasts[i + 1 .. a.n_toasts]);
                a.n_toasts -= 1;
            } else i += 1;
        }
        if (a.n_toasts == 0) return;
        const d = c.igGetForegroundDrawList_ViewportPtr(c.igGetMainViewport());
        // na sala, acima da cápsula de controles (não por cima dela)
        var y = size.y - S(24) - (if (a.screen == .room and !a.theater) S(84) else 0);
        var k = a.n_toasts;
        while (k > 0) {
            k -= 1;
            const t = &a.toasts[k];
            const s = t.text[0..t.len];
            const ts = textSizeF(font_semibold, 14, s);
            const w = @min(ts.x + S(48), size.x - S(40));
            const h = ts.y + S(22);
            y -= h;
            const x = (size.x - w) / 2;
            rectFill(d, x, y + S(3), x + w, y + h + S(3), rgba(0x000000, 100), S(8));
            rectFill(d, x, y, x + w, y + h, col.bg_float, S(8));
            rectFill(d, x, y, x + S(4), y + h, if (t.err) col.red else col.green, S(8));
            drawTextF(d, font_semibold, 14, v2(x + S(22), y + S(11)), col.text, s);
            y -= S(10);
        }
        // redesenha quando o primeiro aviso vencer (não há animação)
        var first = a.toasts[0].until;
        for (a.toasts[0..a.n_toasts]) |t| first = @min(first, t.until);
        redrawIn(@max(0.01, first - now) + 0.01);
    }
};

// ---------------------------------------------------------------------------

extern fn glfwGetWin32Window(window: *c.GLFWwindow) ?*anyopaque;
extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, op: [*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(.winapi) ?*anyopaque;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, fa: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

/// Abre uma pasta/arquivo no programa padrão (xdg-open / Explorer).
/// Página da release nova (a que veio do GitHub; senão a última do repositório).
/// O guia de conexão (docs/CONNECTING) no GitHub, no idioma da interface.
fn openGuide() void {
    const repo = if (build_options.repo.len > 0) build_options.repo else "RshaCuDeVidro/telinha";
    var b: [200]u8 = undefined;
    const url = std.fmt.bufPrint(&b, "https://github.com/{s}/blob/main/docs/{s}", .{ repo, if (i18n.english()) "CONNECTING.md" else "CONNECTING.pt.md" }) catch return;
    _ = openPath(url);
}

fn qaPid() u32 {
    if (sync.is_windows) return GetCurrentProcessId();
    return @intCast(std.c.getpid());
}
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn openReleases() void {
    var b: [256]u8 = undefined;
    const page = update.page(&b);
    const url = if (page.len > 0) page else if (build_options.repo.len > 0)
        std.fmt.bufPrint(&b, "https://github.com/{s}/releases/latest", .{build_options.repo}) catch return
    else
        return;
    _ = openPath(url);
}

/// O que o modo de testes "abriu" (nada é aberto de verdade nos testes).
var qa_opened: [256]u8 = undefined;
var qa_opened_len: usize = 0;

fn openPath(path: []const u8) bool {
    if (qa.enabled()) {
        qa_opened_len = @min(path.len, qa_opened.len);
        @memcpy(qa_opened[0..qa_opened_len], path[0..qa_opened_len]);
        return true;
    }
    if (sync.is_windows) {
        var w: [1024:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&w, path) catch return false;
        if (n >= w.len) return false;
        w[n] = 0;
        const r = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), &w, null, null, 1);
        return @intFromPtr(r) > 32;
    }
    var z: [1024:0]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{path}) catch return false;
    var pid: c_int = 0;
    const argv = [_:null]?[*:0]const u8{ "xdg-open", pz.ptr };
    return posix_spawnp(&pid, "xdg-open", null, null, &argv, environ) == 0;
}

/// HWND da janela no Windows (pra piscar na barra de tarefas); null no Linux.
fn nativeWindow(w: *c.GLFWwindow) ?*anyopaque {
    return if (sync.is_windows) glfwGetWin32Window(w) else null;
}

/// Tempo de trabalho de cada quadro da interface (o laço principal soma; o
/// log de depuração tira a média a cada amostra).
pub var frame_work_us: u64 = 0;
pub var frame_count: u64 = 0;
pub var frame_work_max_us: u64 = 0;

/// Limite de quadros por segundo da interface (0 = o do monitor).
pub var frame_cap_fps: u64 = 60;

/// Quando a interface precisa se redesenhar sozinha (animação, contagem,
/// aviso sumindo), em segundos de igGetTime. O loop principal dorme até lá
/// (ou até um evento) em vez de redesenhar todo quadro. Só a thread da UI mexe.
pub var redraw_at: f64 = std.math.inf(f64);

/// Pede um redesenho daqui a `secs` (o mais cedo dos pedidos vale).
pub fn redrawIn(secs: f64) void {
    redraw_at = @min(redraw_at, c.igGetTime() + secs);
}

/// Acorda o loop principal (chamado de qualquer thread).
pub fn wakeUi() void {
    c.glfwPostEmptyEvent();
}

/// Tema base do ImGui (tamanhos; uma vez, na escala da tela) e as cores do tema.
pub fn applyStyle() void {
    const style = c.igGetStyle();
    // do zero: o ScaleAllSizes multiplica o que já está lá (zoom mudando)
    const def = c.ImGuiStyle_ImGuiStyle();
    style.* = def.*;
    c.ImGuiStyle_destroy(def);
    c.igStyleColorsDark(style);
    style.*.WindowRounding = 0;
    style.*.ChildRounding = 0;
    style.*.ScrollbarSize = 8;
    style.*.FrameBorderSize = 0;
    style.*.WindowBorderSize = 0;
    style.*.PopupBorderSize = 0;
    style.*.ItemSpacing = v2(8, 6);
    style.*.GrabMinSize = 14;
    ImGuiStyle_ScaleAllSizes(style, scale);
    style.*.FontSizeBase = 15 * scale * font_k;
    applyThemeStyle();
}

/// Troca o tema (pelo id do config.ini; desconhecido = o primeiro).
pub fn setTheme(id: []const u8, custom: []const u8) void {
    var mono = false;
    if (std.mem.eql(u8, id, theme.custom_id)) {
        const b = theme.decodeBase(custom);
        col = theme.derive(b);
        mono = b.mono;
    } else {
        const t = theme.list[theme.find(id)];
        col = t.pal;
        mono = t.mono;
    }
    if (mono) useFonts(fonts_mono, 0.9) else useFonts(fonts_sans, 1.0);
    applyThemeStyle();
}

/// Cores e cantos do ImGui a partir de `col`.
fn applyThemeStyle() void {
    const style = c.igGetStyle();
    style.*.FrameRounding = S(5) * col.round;
    style.*.PopupRounding = S(8) * col.round;
    style.*.GrabRounding = S(4) * col.round;
    style.*.ScrollbarRounding = S(8) * col.round;
    const colors: *[c.ImGuiCol_COUNT]c.ImVec4_c = @ptrCast(&style.*.Colors);
    const f = struct {
        fn v(color: u32, a: f32) c.ImVec4_c {
            var r = c.igColorConvertU32ToFloat4(color);
            r.w = a;
            return r;
        }
    }.v;
    colors[c.ImGuiCol_Text] = f(col.text, 1);
    colors[c.ImGuiCol_TextDisabled] = f(col.muted, 1);
    colors[c.ImGuiCol_WindowBg] = f(col.bg_main, 1);
    colors[c.ImGuiCol_ChildBg] = f(col.bg_main, 0);
    colors[c.ImGuiCol_PopupBg] = f(col.bg_float, 1);
    colors[c.ImGuiCol_FrameBg] = f(col.input, 1);
    colors[c.ImGuiCol_FrameBgHovered] = f(col.bg_user, 1);
    colors[c.ImGuiCol_FrameBgActive] = f(col.bg_user, 1);
    colors[c.ImGuiCol_Button] = f(col.button, 1);
    colors[c.ImGuiCol_ButtonHovered] = f(col.button_hover, 1);
    colors[c.ImGuiCol_ButtonActive] = f(col.button_active, 1);
    colors[c.ImGuiCol_Header] = f(col.selected, 1);
    colors[c.ImGuiCol_HeaderHovered] = f(col.hover, 1);
    colors[c.ImGuiCol_HeaderActive] = f(col.selected, 1);
    colors[c.ImGuiCol_ScrollbarBg] = f(col.bg_side, 0);
    colors[c.ImGuiCol_ScrollbarGrab] = f(col.scroll, 1);
    colors[c.ImGuiCol_ScrollbarGrabHovered] = f(col.scroll_hover, 1);
    colors[c.ImGuiCol_ScrollbarGrabActive] = f(col.scroll_hover, 1);
    colors[c.ImGuiCol_CheckMark] = f(col.check, 1);
    colors[c.ImGuiCol_CheckboxSelectedBg] = f(col.input, 1);
    colors[c.ImGuiCol_SliderGrab] = f(col.blurple, 1);
    colors[c.ImGuiCol_SliderGrabActive] = f(col.blurple_hover, 1);
    colors[c.ImGuiCol_TextSelectedBg] = f(col.blurple, 0.45);
    colors[c.ImGuiCol_Border] = f(col.black, 0);
    colors[c.ImGuiCol_NavCursor] = f(col.blurple, 1);
}

const ImGuiStyle_ScaleAllSizes = c.ImGuiStyle_ScaleAllSizes;
