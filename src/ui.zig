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
const chatimg = @import("chatimg.zig");
const chatsend = @import("chatsend.zig");
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
const ic = struct {
    const desktop = &iconArr(0xF390);
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
    c.ImDrawList_AddText_FontPtr(d, f, S(size) * font_k, pos, color, s.ptr, s.ptr + s.len, 0, null);
}

/// Igual, quebrando linha em `wrap` pixels.
fn drawTextWrapF(d: *c.ImDrawList, f: *c.ImFont, size: f32, pos: c.ImVec2_c, color: u32, s: []const u8, wrap: f32) void {
    c.ImDrawList_AddText_FontPtr(d, f, S(size) * font_k, pos, color, s.ptr, s.ptr + s.len, wrap, null);
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

fn liveBadge(d: *c.ImDrawList, pos: c.ImVec2_c) f32 {
    const t = tr("AO VIVO");
    const ts = textSizeF(font_bold, 10, t);
    const pad = S(5);
    rectFill(d, pos.x, pos.y, pos.x + ts.x + pad * 2, pos.y + ts.y + S(2), col.red, S(3));
    drawTextF(d, font_bold, 10, v2(pos.x + pad, pos.y + S(1)), col.white, t);
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

const SettingsPage = enum { geral, aparencia, voz, camera, desempenho, depuracao, sobre };

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
    tex: u32 = 0,
    w: u16 = 0,
    h: u16 = 0,
    failed: bool = false,
    used: u64 = 0, // último quadro em que apareceu
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
    saved_win: [4]c_int = .{ 0, 0, 1280, 760 },

    chat_input: [1024]u8 = [_]u8{0} ** 1024,
    chat_sent: [1024]u8 = undefined, // mensagem guardada no Enter (ver chatCallback)
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
    settings_page: SettingsPage = .geral,
    fb_viewport: [4]c_int = .{ 0, 0, 0, 0 },
    auto_cap_seen: u32 = 0, // último teto da qualidade automática avisado
    pctest_logged: bool = true, // resultado do teste do PC já foi pro log
    crash_prompt: bool = false, // travou da última vez: pergunta se manda o relatório
    crash_sending: bool = false, // mandando o relatório pelo aviso (avisa quando acabar)
    ptt_capture: bool = false, // esperando a tecla nova do apertar pra falar
    clip_key_capture: bool = false, // esperando a tecla do atalho de clipe
    clip_key_last: f64 = -10,
    clip_key_prev: bool = false, // a tecla estava apertada no quadro passado (com o telinha em foco)
    last_saved: [512]u8 = undefined, // último clipe/gravação salvo (modo de testes)
    last_saved_len: usize = 0,
    /// Transmissão com o ponteiro "olha aqui" ligado (o mouse vira o ponteiro).
    pointer_tile: ?u32 = null,
    // desenhar por cima de uma transmissão
    draw_tile: ?u32 = null,
    draw_pts: [proto.draw_max_points][2]u16 = undefined,
    draw_n: usize = 0,
    draw_new: bool = false, // o próximo envio começa um traço
    draw_active: bool = false, // mouse apertado desenhando
    draw_sent_us: u64 = 0,
    draw_prune_at: f64 = 0,
    // transmitir só um pedaço da tela (normalizado: x0, y0, x1, y1)
    crop: [4]f32 = .{ 0, 0, 1, 1 },
    crop_saved: [4]f32 = .{ 0, 0, 1, 1 },
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
        a.applyClipKey();
        clip.keep_secs.store(@intCast(std.math.clamp(a.cfg.clip_secs, 10, 300)), .release);
        frame_cap_fps = @intCast(@max(0, a.cfg.ui_fps_cap));
        codec.setHwEffort(@intCast(a.cfg.hw_effort));
        if (a.cfg.ui_zoom != 100) setZoom(@as(f32, @floatFromInt(a.cfg.ui_zoom)) / 100);
        a.crash_prompt = crash.pending();
        _ = std.fmt.bufPrintZ(&a.port_buf, "{d}", .{a.cfg.host_port}) catch {};
        if (a.cfg.check_updates) update.checkAsync(build_options.repo, version_string);
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
        if (a.n_toasts == a.toasts.len) {
            std.mem.copyForwards(Toast, a.toasts[0 .. a.toasts.len - 1], a.toasts[1..]);
            a.n_toasts -= 1;
        }
        var t: Toast = .{ .text = undefined, .len = 0, .until = c.igGetTime() + 5.0, .err = err };
        const s = i18n.bufPrint(&t.text, f, args) catch t.text[0..0];
        t.len = s.len;
        a.toasts[a.n_toasts] = t;
        a.n_toasts += 1;
        debuglog.line("aviso{s}: {s}", .{ if (err) " (erro)" else "", s });
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
                v.stream, v.w, v.h, v.fps, v.kbps * 8, v.codec.name(), v.decoder_name, v.decode_ms, v.latency_ms, v.audio_registered,
            });
        }
        for ([_]?*Sharer{ a.sharer, a.camera }) |maybe| {
            const sh = maybe orelse continue;
            sh.mutex.lock();
            defer sh.mutex.unlock();
            debuglog.line("transmitindo ({s}): {s} {d}x{d} {d:.1} q/s {d:.0} kbit/s (alvo {d}) | captura {s}, encoder {s} {d:.1} ms | congestionado={} som={} ninguém_assistindo={}", .{
                if (sh.kind == proto.kind_camera) "câmera" else "tela", @tagName(sh.state), sh.w, sh.h, sh.fps, sh.kbps * 8, sh.bitrate_kbps, sh.backendSlice(), sh.encoder_name, sh.encode_ms, sh.congested, sh.audio_on, sh.idle.load(.monotonic),
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
        return if (n.len == 0) tr("anônimo") else n;
    }

    fn joinRoom(a: *App) void {
        // convite: telinha://endereço[,endereço...]#senha (ou só o endereço)
        const raw = std.mem.trim(u8, config.getStr(&a.cfg.join_addr), " \t");
        const inv = connect_mod.splitInvite(raw);
        if (inv.password) |pw| config.setStr(&a.cfg.join_pass, pw);
        // deixa o campo só com os endereços
        var tmp: [256]u8 = undefined;
        config.setStr(&tmp, inv.addrs);
        a.cfg.join_addr = tmp;
        const addrs = config.getStr(&a.cfg.join_addr);
        var targets: [connect_mod.max_targets]connect_mod.Target = undefined;
        if (addrs.len == 0 or std.mem.findScalar(u8, addrs, ':') == null) return a.setHomeError(tr("Põe o endereço com a porta. Ex.: 0.tcp.sa.ngrok.io:12345 (ou cola o convite)."));
        if (connect_mod.parseList(addrs, &targets) == 0) return a.setHomeError(tr("Endereço inválido. Ex.: 0.tcp.sa.ngrok.io:12345 (IPv6 entre colchetes: [2804::1]:7777)"));
        a.connect(addrs, config.getStr(&a.cfg.join_pass), config.getStr(&a.cfg.admin_token));
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
        a.server = Server.start(.{ .port = port, .password = pass, .room_name = rn, .admin_token = token }) catch {
            a.setHomeError(tr("Não consegui abrir essa porta. Já tem outra coisa usando? Tenta outra."));
            return;
        };
        var self_addr: [32]u8 = undefined;
        a.connect(std.fmt.bufPrint(&self_addr, "127.0.0.1:{d}", .{port}) catch "127.0.0.1:7777", pass, token);
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
                const ment = mentions(l.text, my_name);
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
    fn applyVoice(a: *App) void {
        // silenciado pelo admin: o servidor descartaria a voz; nem abre o microfone
        if (a.mic_wanted and !a.deaf and !a.admin_muted) a.startMic() else a.stopMic();
        if (a.client) |cl| {
            var flags: u8 = 0;
            if (a.mic != null) flags |= proto.voice_mic;
            if (a.deaf) flags |= proto.voice_deaf;
            cl.sendVoiceState(flags);
        }
    }

    fn toggleMic(a: *App) void {
        if (a.admin_muted) {
            a.toast("O admin da sala silenciou seu microfone.", .{}, true);
            return;
        }
        if (a.deaf) {
            // como no Discord: ligar o microfone tira o "surdo"
            a.setDeaf(false);
            a.mic_wanted = true;
        } else a.mic_wanted = !a.mic_wanted;
        a.applyVoice();
        a.chime(if (a.mic != null) .mic_on else .mic_off);
        if (a.mic != null and !a.echo_hint_shown) {
            a.echo_hint_shown = true;
            if (a.cfg.echo_cancellation)
                a.toast("Microfone ligado (Ctrl+M liga/desliga, Ctrl+D fica surdo).", .{}, false)
            else
                a.toast("Microfone ligado (Ctrl+M liga/desliga). Cancelamento de eco desligado: sem fone de ouvido, a sala pode ouvir eco da sua caixa de som.", .{}, false);
        }
    }

    fn toggleDeaf(a: *App) void {
        if (a.deaf) {
            a.setDeaf(false);
            a.chime(.mic_on);
        } else {
            a.chime(.mic_off); // os avisos tocam mesmo surdo
            a.setDeaf(true); // surdo também desliga o microfone (mic_wanted fica guardado)
        }
        a.applyVoice();
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

    fn connect(a: *App, addrs: []const u8, pass: []const u8, admin_token: []const u8) void {
        a.home_error_len = 0;
        config.save(&a.cfg);
        a.client = Client.create(.{ .addrs = addrs, .name = a.myName(), .password = pass, .admin_token = admin_token, .client_key = a.cfg.client_key, .hw_decode = a.cfg.hardware, .wake = wakeUi }) catch {
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
        if (a.client) |cl| cl.close();
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
        a.applyVoice();
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
            const names = std.mem.replaceOwned(u8, std.heap.c_allocator, list, "\n", ", ") catch null;
            defer if (names) |x| std.heap.c_allocator.free(x);
            c.igPushTextWrapPos(c.igGetCursorPosX() + w);
            textColored(col.faint, fmtZ("Fora do som: {s}", .{names orelse list}));
            c.igPopTextWrapPos();
            popFont();
        }
        if (a.sharer) |s| if (s.audio_exclude_ignored) {
            pushFont(font_regular, 12);
            textColored(col.yellow, tr("Esse Windows não deixa excluir programas do som (precisa do Windows 10 versão 2004 ou mais novo)."));
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
                    a.applyVoice();
                },
                proto.notice_unmuted => {
                    a.admin_muted = false;
                    a.applyVoice();
                },
                proto.notice_stream_stopped => if (n.extra == proto.kind_camera) a.stopCamera() else a.stopSharing(),
                else => {},
            }
            const bad = n.kind == proto.notice_muted or n.kind == proto.notice_stream_stopped or n.kind == proto.notice_admin_off;
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

    fn toggleFullscreen(a: *App) void {
        if (!a.fullscreen) {
            c.glfwGetWindowPos(a.window, &a.saved_win[0], &a.saved_win[1]);
            c.glfwGetWindowSize(a.window, &a.saved_win[2], &a.saved_win[3]);
            const mon = c.glfwGetPrimaryMonitor() orelse return;
            const mode = c.glfwGetVideoMode(mon) orelse return;
            c.glfwSetWindowMonitor(a.window, mon, 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
            a.fullscreen = true;
        } else {
            c.glfwSetWindowMonitor(a.window, null, a.saved_win[0], a.saved_win[1], a.saved_win[2], a.saved_win[3], 0);
            a.fullscreen = false;
        }
    }

    // ------------------------------------------------------------- por frame

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
                    r.upload(&v.yuv, f.data, f.w, f.h, f.layout == .nv12);
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
            s.mutex.lock();
            defer s.mutex.unlock();
            if (s.preview_new and s.preview.len > 0) {
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

    fn checkState(a: *App) void {
        const cl = a.client orelse return;
        cl.mutex.lock();
        const st = cl.status;
        cl.mutex.unlock();
        if (st == .connected and !a.was_connected) {
            a.was_connected = true;
            if (cl.viaTarget()) |t| {
                const lbl = std.fmt.bufPrint(&a.connect_label, "{s}{s}{s}:{d}", .{
                    if (std.mem.findScalar(u8, t.hostSlice(), ':') != null) "[" else "", t.hostSlice(),
                    if (std.mem.findScalar(u8, t.hostSlice(), ':') != null) "]" else "", t.port,
                }) catch "";
                a.connect_label_len = lbl.len;
            }
            if (a.reconnect.attempt == 0) {
                a.mic_wanted = a.cfg.mic_on_join;
                a.applyVoice();
            }
            if (a.reconnect.attempt > 0) {
                a.finishReconnect();
            } else if (a.auto_share and a.sharer == null) {
                a.n_sources = @intCast(c.cap_list_sources(&a.sources, a.sources.len));
                a.startSharing();
            }
        }
        if (st == .connected) {
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
            // qualidade automática mudou a resolução: avisa quem transmite
            const cap = s.auto_cap.load(.acquire);
            if (cap != a.auto_cap_seen) {
                const from = s.auto_from.load(.acquire);
                if (cap != 0) {
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
        // algo grande parou (transmissão, câmera, sala, transmissão assistida):
        // a memória livre volta pro sistema
        if (a.trim_at > 0 and c.igGetTime() >= a.trim_at) {
            a.trim_at = 0;
            sync.trimMemory();
        } else if (a.trim_at > 0) redrawIn(a.trim_at - c.igGetTime());
        audio.mixer.housekeep(); // saída de som parada depois de 5 s de silêncio
        if (debuglog.on()) a.debugTick();
        a.pollPttKey();
        a.pollClipKey();
        if (a.takeCssFile()) a.applyTheme();
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
        a.checkState();
        a.uploadTextures();

        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F11, false)) a.toggleFullscreen();
        // atalhos de voz (fora de campo de texto): Ctrl+M microfone, Ctrl+D surdo
        const io = c.igGetIO_Nil();
        if (a.screen == .room and io.*.KeyCtrl and !io.*.WantTextInput) {
            if (c.igIsKeyPressed_Bool(c.ImGuiKey_M, false)) a.toggleMic();
            if (c.igIsKeyPressed_Bool(c.ImGuiKey_D, false)) a.toggleDeaf();
        }
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and !a.share_modal) {
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
        const body = txt["telinha://".len..];
        const h = std.mem.findScalar(u8, body, '#');
        config.setStr(&a.cfg.join_addr, if (h) |i| body[0..i] else body);
        config.setStr(&a.cfg.join_pass, if (h) |i| body[i + 1 ..] else "");
        a.home_tab = 0;
        a.home_error_len = 0;
        a.paste_hint_until = c.igGetTime() + 8;
    }

    fn drawHome(a: *App, size: c.ImVec2_c) void {
        a.pasteInvite();
        const d = drawList();
        // fundo com um brilho sutil
        c.ImDrawList_AddRectFilledMultiColor(d, v2(0, 0), size, col.home_grad[0], col.home_grad[1], col.home_grad[2], col.home_grad[3]);

        const card_w = S(460);
        const card_h = a.home_card_h + S(60);
        const x0 = @max(S(16), (size.x - card_w) / 2);
        const y0 = @max(S(16), (size.y - card_h) / 2);
        rectFill(d, x0 + S(2), y0 + S(6), x0 + card_w + S(2), y0 + card_h + S(6), rgba(0x000000, 90), S(12));
        rectFill(d, x0, y0, x0 + card_w, y0 + card_h, col.bg_main, S(10));

        const pad = S(32);
        const inner = card_w - pad * 2;
        c.igSetCursorScreenPos(v2(x0 + pad, y0 + S(30)));
        c.igBeginGroup();

        // logo
        {
            const p = c.igGetCursorScreenPos();
            const isz = S(48);
            // o husky (assets/telinha.svg em 128 px)
            if (logo_tex == 0) gl.upload(&logo_tex, logo_rgba, 128, 128, gl.RGBA);
            c.ImDrawList_AddImage(d, texRef(logo_tex), p, v2(p.x + isz, p.y + isz), v2(0, 0), v2(1, 1), col.white);
            drawTextF(d, font_bold, 28, v2(p.x + isz + S(14), p.y - S(1)), col.header, "telinha");
            drawTextF(d, font_regular, 14, v2(p.x + isz + S(15), p.y + S(28)), col.muted, tr("compartilha a tela com a galera"));
            c.igDummy(v2(inner, isz + S(26)));
        }
        a.drawUpdateBanner(inner);

        _ = segmented("tabs", &.{ "Entrar numa sala", "Criar sala" }, &a.home_tab, inner);
        c.igDummy(v2(0, S(14)));

        fieldLabel("SEU NOME");
        _ = textField("##name", "como a galera vai te ver", a.cfg.name[0 .. a.cfg.name.len - 1], inner, false);
        c.igDummy(v2(0, S(8)));

        var go = false;
        if (a.home_tab == 0) {
            fieldLabel("ENDEREÇO DA SALA");
            if (textField("##addr", "ex.: 0.tcp.sa.ngrok.io:12345 ou o convite telinha://...", &a.cfg.join_addr, inner, false)) go = true;
            if (c.igGetTime() < a.paste_hint_until) {
                pushFont(font_regular, 12.5);
                textColored(col.green, tr("Convite colado da área de transferência. É só clicar em Entrar."));
                popFont();
            }
            c.igDummy(v2(0, S(8)));
            fieldLabel("SENHA");
            if (textField("##pass", "senha da sala", &a.cfg.join_pass, inner, true)) go = true;
            c.igDummy(v2(0, S(6)));
            // opções avançadas (token de admin de servidor dedicado)
            {
                const t = fmtZ("Opções avançadas  {s}", .{if (a.show_advanced) ic.chev_up else ic.chev_down});
                pushFont(font_semibold, 12.5);
                const ts = textSize(t);
                const p = c.igGetCursorScreenPos();
                if (c.igInvisibleButton("##adv", v2(ts.x, ts.y + S(4)), 0)) a.show_advanced = !a.show_advanced;
                drawText(drawList(), p, if (c.igIsItemHovered(0)) col.header else col.muted, t);
                popFont();
            }
            if (a.show_advanced) {
                c.igDummy(v2(0, S(4)));
                fieldLabel("TOKEN DE ADMIN (só em servidor dedicado)");
                if (textField("##tok", "deixe vazio se não souber o que é", &a.cfg.admin_token, inner, true)) go = true;
            }
            c.igDummy(v2(0, S(14)));
            if (primaryButton(tr("Entrar##go"), v2(inner, S(44)), col.blurple, col.blurple_hover, col.blurple_active)) go = true;
            if (go) a.joinRoom();
        } else {
            fieldLabel("NOME DA SALA");
            _ = textField("##room", "ex.: Sala do Gabriel", &a.cfg.room_name, inner, false);
            c.igDummy(v2(0, S(8)));
            const half = (inner - S(12)) / 2;
            const row = c.igGetCursorScreenPos();
            fieldLabel("PORTA");
            _ = textField("##port", "7777", &a.port_buf, half, false);
            const after = c.igGetCursorScreenPos();
            c.igSetCursorScreenPos(v2(row.x + half + S(12), row.y));
            fieldLabel("SENHA");
            c.igSetCursorScreenPos(v2(row.x + half + S(12), c.igGetCursorScreenPos().y));
            if (textField("##hpass", "vazio = sem senha", &a.cfg.host_pass, half, true)) go = true;
            c.igSetCursorScreenPos(after);
            c.igDummy(v2(0, S(18)));
            if (primaryButton(tr("Criar sala##go"), v2(inner, S(44)), col.green, col.green_hover, col.green_active)) go = true;
            c.igDummy(v2(0, S(10)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + inner);
            pushFont(font_regular, 13);
            textColored(col.muted, tr("Pra galera de fora entrar, abre um túnel TCP pra essa porta (ngrok tcp, bore, playit...) e manda o endereço que ele mostrar."));
            popFont();
            c.igPopTextWrapPos();
            if (go) a.createRoom();
        }

        if (a.home_error_len > 0) {
            c.igDummy(v2(0, S(10)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + inner);
            textColored(col.red, a.home_error[0..a.home_error_len]);
            c.igPopTextWrapPos();
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

        // janela estreita: se o chat estiver aberto, a barra lateral recolhe; se nem
        // assim couber, o chat fica escondido (o botão no topo continua mostrando os não lidos)
        const want_chat = !a.theater and a.cfg.show_chat;
        var side_w = if (a.theater) 0 else S(260);
        if (want_chat and size.x - side_w - S(320) < S(480)) side_w = 0;
        const chat_w = if (want_chat and size.x - side_w - S(320) >= S(400)) S(320) else 0;
        a.chat_visible = chat_w > 0;
        a.side_visible = side_w > 0;
        const main_w = size.x - side_w - chat_w;

        if (side_w > 0) {
            c.igSetCursorPos(v2(0, 0));
            a.drawSidebar(cl, v2(side_w, size.y));
        }
        c.igSetCursorPos(v2(side_w, 0));
        a.drawMain(cl, v2(main_w, size.y));
        if (chat_w > 0) {
            c.igSetCursorPos(v2(side_w + main_w, 0));
            a.drawChat(cl, v2(chat_w, size.y));
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
            if (a.img_view != null) a.drawImageViewer(size);
        }
    }

    fn closeModals(a: *App) void {
        if (a.settings_modal) config.save(&a.cfg); // o que o "Fechar" faria
        a.settings_modal = false;
        a.share_modal = false;
        a.leave_confirm = false;
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

    fn sendCrashReport(a: *App) void {
        const hook = config.getStr(&a.cfg.debug_webhook);
        const method: debuglog.Method = if (a.cfg.debug_send == 1 and debuglog.validUrl(hook)) .webhook else .gofile;
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
                if (link.len == 0) {
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

    fn drawSidebar(a: *App, cl: *Client, size: c.ImVec2_c) void {
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, col.bg_side);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, v2(0, 0));
        _ = c.igBeginChild_Str("sidebar", size, 0, c.ImGuiWindowFlags_NoScrollbar);
        const d = drawList();
        const origin = c.igGetCursorScreenPos();

        // cabeçalho da sala
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
        cl.mutex.unlock();

        const hh = S(56);
        rectFill(d, origin.x, origin.y + hh - 1, origin.x + size.x, origin.y + hh, rgba(0x000000, 60), 0);
        drawTextF(d, font_bold, 16, v2(origin.x + S(16), origin.y + S(10)), col.header, if (room_name.len > 0) room_name else "telinha");
        // quem hospeda vê a porta; quem entrou vê por onde chegou (o link público passa mesmo pelo túnel)
        const sub = if (a.server) |s|
            fmtZ("{s} anfitrião · porta {d}", .{ ic.crown, s.port })
        else if (my_route == proto.route_tunnel)
            fmtZ("{s} via link público · {s}", .{ ic.globe, a.connect_label[0..a.connect_label_len] })
        else
            fmtZ("{s}", .{a.connect_label[0..a.connect_label_len]});
        drawTextF(d, font_regular, 12.5, v2(origin.x + S(16), origin.y + S(32)), col.muted, sub);
        // convite e cadeado da sala (admin tranca: ninguém novo entra)
        {
            c.igSetCursorScreenPos(v2(origin.x + size.x - S(116), origin.y + S(8)));
            if (i_am_admin) {
                if (iconButton("##lockroom", if (locked) ic.lock else ic.lock_open, S(28), if (locked) col.yellow else col.muted, col.hover, if (locked) tr("Sala trancada: ninguém novo entra. Clique pra destrancar.") else tr("Trancar a sala (ninguém novo entra)")))
                    cl.admin(proto.admin_lock, 0, @intFromBool(!locked));
            } else if (locked) {
                const ls = textSizeF(font_regular, 15, ic.lock);
                drawTextF(d, font_regular, 15, v2(origin.x + size.x - S(102) - ls.x / 2, origin.y + S(14)), col.yellow, ic.lock);
                if (c.igIsMouseHoveringRect(v2(origin.x + size.x - S(116), origin.y + S(8)), v2(origin.x + size.x - S(88), origin.y + S(36)), true))
                    tooltipText(tr("Sala trancada: ninguém novo entra"));
            }
            c.igSetCursorScreenPos(v2(origin.x + size.x - S(84), origin.y + S(8)));
            if (iconButton("##invite", ic.user_plus, S(28), col.muted, col.hover, tr("Copiar convite da sala"))) a.copyInvite();
            c.igSetCursorScreenPos(origin);
        }
        // ping + cadeado
        {
            const pc = if (ping < 80) col.green else if (ping < 200) col.yellow else col.red;
            const ts = textSizeF(font_regular, 14, ic.signal);
            const px = origin.x + size.x - S(16) - ts.x;
            drawTextF(d, font_regular, 14, v2(px, origin.y + S(12)), pc, ic.signal);
            const pt = fmtZ("{d} ms", .{ping});
            const pts = textSizeF(font_regular, 11, pt);
            drawTextF(d, font_regular, 11, v2(origin.x + size.x - S(16) - pts.x, origin.y + S(32)), col.muted, pt);
            const ls = textSizeF(font_regular, 11, ic.lock);
            const lx = origin.x + size.x - S(20) - pts.x - ls.x;
            drawTextF(d, font_regular, 11, v2(lx, origin.y + S(32)), col.green, ic.lock);
            if (c.igIsMouseHoveringRect(v2(lx - S(4), origin.y + S(6)), v2(origin.x + size.x, origin.y + S(48)), true))
                tooltipText(tr("Conexão criptografada (X25519 + ChaCha20-Poly1305)"));
        }
        c.igDummy(v2(size.x, hh));

        // listas
        const list_h = size.y - hh - S(56) - S(50);
        _ = c.igBeginChild_Str("lists", v2(size.x, list_h), 0, 0);
        var n_live: usize = 0;
        for (members[0..n_members]) |*m| {
            if (m.streaming) n_live += 1;
            if (m.camera()) n_live += 1;
        }
        if (n_live > 0) {
            sectionHeader(fmtZ("AO VIVO — {d}", .{n_live}));
            for (members[0..n_members]) |*m| {
                if (m.streaming) a.liveRow(m, proto.kind_screen, my_id, size.x, members[0..n_members]);
                if (m.camera()) a.liveRow(m, proto.kind_camera, my_id, size.x, members[0..n_members]);
            }
        }
        sectionHeader(fmtZ("MEMBROS — {d}", .{n_members}));
        for (members[0..n_members]) |*m| a.memberRow(m, my_id, size.x, i_am_admin);
        a.memberMenu(cl, members[0..n_members]);
        c.igEndChild();

        a.drawRoomStrip(v2(size.x, S(50)));
        a.drawUserPanel(cl, v2(size.x, S(56)));
        c.igEndChild();
        c.igPopStyleVar(2);
        c.igPopStyleColor(1);
    }

    /// Faixa acima do painel do usuário (como a de voz do Discord):
    /// compartilhar tela, câmera e sair.
    fn drawRoomStrip(a: *App, size: c.ImVec2_c) void {
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        rectFill(d, p.x, p.y, p.x + size.x, p.y + size.y, col.bg_user, 0);
        rectFill(d, p.x + S(8), p.y + size.y - 1, p.x + size.x - S(8), p.y + size.y, rgba(0x000000, 60), 0);
        const live = a.sharer != null;
        const bh = S(34);
        const leave_w = S(40);
        const cam_w = S(40);
        const share_w = size.x - S(16) - leave_w - cam_w - S(16);
        c.igSetCursorScreenPos(v2(p.x + S(8), p.y + (size.y - bh) / 2));
        const lbl = if (live) fmtZ("{s}  Ao vivo (configurar)##share", .{ic.desktop}) else fmtZ("{s}  Compartilhar tela##share", .{ic.desktop});
        if (if (live)
            primaryButton(lbl, v2(share_w, bh), col.red, col.red_hover, col.red_active)
        else
            secondaryButton(lbl, v2(share_w, bh))) a.openShareModal();
        c.igSameLine(0, S(8));
        const cam_on = a.camera != null;
        if (if (cam_on)
            primaryButton(fmtZ("{s}##camera", .{ic.video}), v2(cam_w, bh), col.red, col.red_hover, col.red_active)
        else
            secondaryButton(fmtZ("{s}##camera", .{ic.video}), v2(cam_w, bh))) a.toggleCamera();
        if (c.igIsItemHovered(0)) tooltipText(if (cam_on) tr("Desligar a câmera") else tr("Ligar a câmera"));
        c.igSameLine(0, S(8));
        if (primaryButton(fmtZ("{s}##leave", .{ic.leave}), v2(leave_w, bh), col.leave, col.red, col.red_active)) a.askLeave();
        if (c.igIsItemHovered(0)) tooltipText(if (a.server != null) tr("Fechar a sala") else tr("Sair da sala"));
        c.igSetCursorScreenPos(v2(p.x, p.y + size.y));
    }

    fn liveRow(a: *App, m: *const Member, kind: u8, my_id: u32, width: f32, all: []const Member) void {
        const d = drawList();
        const h = S(48);
        const stream = proto.streamId(m.id, kind);
        c.igPushID_Int(@intCast(m.id + 100000 + @as(u32, kind) * 100000));
        defer c.igPopID();
        c.igSetCursorPosX(S(8));
        const p = c.igGetCursorScreenPos();
        const row_w = width - S(16);
        const clicked = c.igInvisibleButton("live", v2(row_w, h), 0);
        const hovered = c.igIsItemHovered(0);
        if (a.n_live_rects < a.live_rects.len) {
            a.live_rects[a.n_live_rects] = .{ .stream = stream, .x0 = p.x, .y0 = p.y, .x1 = p.x + row_w, .y1 = p.y + h };
            a.n_live_rects += 1;
        }
        const is_me = m.id == my_id;
        const watching = a.findView(stream) != null;
        if (hovered or watching) rectFill(d, p.x, p.y, p.x + row_w, p.y + h, if (watching) col.selected else col.hover, S(6));
        drawAvatar(d, v2(p.x + S(22), p.y + h / 2), S(15), m.id, m.nameSlice(), true);
        const camera = kind == proto.kind_camera;
        drawTextF(d, font_semibold, 14.5, v2(p.x + S(46), p.y + S(7)), col.text, if (camera) fmtZ("{s}  {s}", .{ m.nameSlice(), ic.video }) else fmtZ("{s}", .{m.nameSlice()}));
        var viewers: usize = 0;
        for (all) |*o| {
            if (o.isWatching(stream)) viewers += 1;
        }
        const info = if (camera)
            fmtZ("câmera · {d}x{d} · {s} {d}", .{ m.cam_w, m.cam_h, ic.eye, viewers })
        else if (m.audio)
            fmtZ("{d}x{d} · {d} fps · {s} · {s} {d}", .{ m.w, m.h, m.fps, ic.volume, ic.eye, viewers })
        else
            fmtZ("{d}x{d} · {d} fps · {s} {d}", .{ m.w, m.h, m.fps, ic.eye, viewers });
        drawTextF(d, font_regular, 11.5, v2(p.x + S(46), p.y + S(27)), col.muted, info);
        // tooltip: ação + quem está assistindo
        var tip_buf: [320]u8 = undefined;
        var tip_len: usize = 0;
        const action: []const u8 = if (is_me) tr("É você!") else if (watching) tr("Parar de assistir") else tr("Assistir");
        @memcpy(tip_buf[0..action.len], action);
        tip_len = action.len;
        var first = true;
        for (all) |*o| {
            if (!o.isWatching(stream)) continue;
            const sep: []const u8 = if (first) tr("\nAssistindo: ") else ", ";
            first = false;
            const part = std.fmt.bufPrint(tip_buf[tip_len .. tip_buf.len - 1], "{s}{s}", .{ sep, o.nameSlice() }) catch break;
            tip_len += part.len;
        }
        tip_buf[tip_len] = 0;
        if (hovered) tooltipText(tip_buf[0..tip_len :0]);
        if (!is_me) {
            const glyph = if (watching) ic.eye_slash else ic.eye;
            const gs = textSizeF(font_regular, 15, glyph);
            drawTextF(d, font_regular, 15, v2(p.x + row_w - gs.x - S(10), p.y + (h - gs.y) / 2), if (hovered) col.header else col.muted, glyph);
            if (clicked) {
                if (watching) a.unwatch(stream) else a.watch(stream);
            }
        }
        c.igDummy(v2(0, S(2)));
    }

    fn routeText(route: u8) [:0]const u8 {
        return switch (route) {
            proto.route_local => tr("Nessa mesma máquina"),
            proto.route_lan => tr("Rede local (ou VPN tipo Tailscale)"),
            proto.route_internet => tr("Direto pela internet (IPv4)"),
            proto.route_internet6 => tr("Direto pela internet (IPv6)"),
            proto.route_tunnel => tr("Pelo link público (túnel)"),
            else => "",
        };
    }

    fn routeIcon(route: u8) []const u8 {
        return switch (route) {
            proto.route_local => ic.laptop,
            proto.route_lan => ic.house,
            proto.route_tunnel => ic.globe,
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
        if (m.owner) {
            drawTextF(d, font_regular, 11, v2(tx, p.y + (h - S(13)) / 2), col.yellow, ic.crown);
            tx += S(18);
        } else if (m.admin) {
            drawTextF(d, font_regular, 11, v2(tx, p.y + (h - S(13)) / 2), col.blurple, ic.shield);
            tx += S(18);
        }
        if (m.id == my_id) drawTextF(d, font_regular, 12, v2(tx, p.y + (h - S(15)) / 2), col.faint, tr("(você)"));
        var rx = p.x + row_w - S(10);
        if (m.streaming) rx -= liveBadge(d, v2(p.x + row_w - S(58), p.y + (h - S(15)) / 2)) + S(14);
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
        if (c.igSelectable_Bool(fmtZ("{s}  Expulsar da sala###akick", .{ic.ban}), false, 0, v2(w, 0))) cl.admin(proto.admin_kick, target.id, 0);
        if (c.igSelectable_Bool(fmtZ("{s}  Banir (não volta mais)###aban", .{ic.gavel}), false, 0, v2(w, 0))) cl.admin(proto.admin_ban, target.id, 0);
        c.igPopStyleColor(1);
    }

    fn drawUpnpState(a: *App, m: *upnp.Mapper, d: *c.ImDrawList, x: f32, yy: f32, w: f32, pad: f32) void {
        const st = m.status();
        switch (st.state) {
            .working => {
                drawTextF(d, font_semibold, 14, v2(x + pad, yy + S(4)), col.text, tr("Pedindo pro roteador abrir a porta…"));
                drawTextF(d, font_regular, 13, v2(x + pad, yy + S(26)), col.muted, tr("Procurando o roteador na rede (UPnP). Leva uns segundos."));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
                if (secondaryButton(tr("Cancelar##upnp"), v2(S(110), S(38)))) a.stopUpnp();
            },
            .ready => {
                var abuf: [64]u8 = undefined;
                const addr = m.address(&abuf);
                drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, tr("Porta aberta no roteador: conexão direta, sem túnel."));
                rectFill(d, x + pad, yy + S(22), x + w - pad, yy + S(52), col.input, S(5));
                drawTextF(d, font_regular, 13, v2(x + pad + S(10), yy + S(29)), col.green, ic.circle);
                drawTextF(d, font_semibold, 14, v2(x + pad + S(30), yy + S(28)), col.header, fmtZ("{s}", .{addr}));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(62)));
                if (primaryButton(fmtZ("{s}  Copiar convite##upnp", .{ic.user_plus}), v2(S(170), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.copyInvite();
                c.igSameLine(0, S(10));
                if (secondaryButton(fmtZ("{s}  Fechar porta###upnpclose", .{ic.power}), v2(S(140), S(38)))) a.stopUpnp();
            },
            .failed => {
                drawTextF(d, font_semibold, 14, v2(x + pad, yy - S(2)), col.red, fmtZ("{s}  Não deu pra abrir a porta", .{ic.warn}));
                var eb: [300]u8 = undefined;
                drawTextWrapF(d, font_regular, 12.5, v2(x + pad, yy + S(18)), col.muted, i18n.dynamic(st.err, &eb), w - 2 * pad);
                c.igSetCursorScreenPos(v2(x + pad, yy + S(56)));
                if (primaryButton(fmtZ("{s}  Criar link público##upnp", .{ic.globe}), v2(S(200), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
                    a.stopUpnp();
                    a.startTunnel();
                }
                c.igSameLine(0, S(10));
                if (secondaryButton(tr("Fechar##upnp"), v2(S(100), S(38)))) a.stopUpnp();
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

    fn copyInvite(a: *App) void {
        var addr_buf: [600]u8 = undefined;
        const addrs = a.inviteAddrs(&addr_buf);
        if (addrs.len == 0) {
            a.toast("Não achei nenhum endereço dessa sala. Cria o link público no card \"Chamando a galera de fora\".", .{}, true);
            return;
        }
        const pass = if (a.server != null) config.getStr(&a.cfg.host_pass) else config.getStr(&a.cfg.join_pass);
        var buf: [800]u8 = undefined;
        const inv = (if (pass.len > 0)
            std.fmt.bufPrintZ(&buf, "telinha://{s}#{s}", .{ addrs, pass })
        else
            std.fmt.bufPrintZ(&buf, "telinha://{s}", .{addrs})) catch return;
        c.igSetClipboardText(inv.ptr);
        const n_paths = std.mem.count(u8, addrs, ",") + 1;
        if (!a.inviteReachesOutside())
            a.toast("Convite copiado, mas só funciona na mesma rede. Pra galera de fora: link público ou porta no roteador.", .{}, true)
        else if (n_paths > 1)
            a.toast("Convite copiado ({d} caminhos: cada um entra pelo mais rápido que funcionar).", .{n_paths}, false)
        else
            a.toast("Convite copiado! Quem receber cola no campo de endereço.", .{}, false);
    }

    fn drawUserPanel(a: *App, cl: *Client, size: c.ImVec2_c) void {
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        rectFill(d, p.x, p.y, p.x + size.x, p.y + size.y, col.bg_user, 0);
        cl.mutex.lock();
        const my_id = cl.my_id;
        cl.mutex.unlock();
        const live = a.sharer != null;
        const me_speaking = if (a.mic) |m| m.speaking.load(.monotonic) else false;
        drawAvatarSpeaking(d, v2(p.x + S(26), p.y + size.y / 2), S(16), my_id, a.myName(), live, me_speaking);

        var name_buf: [32]u8 = undefined;
        const nm = a.myName();
        const shown = if (nm.len > 14) std.fmt.bufPrint(&name_buf, "{s}…", .{nm[0..12]}) catch nm else nm;
        drawTextF(d, font_semibold, 14, v2(p.x + S(50), p.y + S(10)), col.header, shown);
        var status_text: []const u8 = tr("Online");
        var status_col = col.muted;
        if (a.sharer) |s| {
            s.mutex.lock();
            const st = s.state;
            s.mutex.unlock();
            status_text = if (st == .starting) tr("Iniciando...") else tr("Ao vivo");
            status_col = if (st == .starting) col.yellow else col.red;
        }
        drawTextF(d, font_regular, 12, v2(p.x + S(50), p.y + S(29)), status_col, status_text);

        const bs = S(34);
        const bx = p.x + size.x - bs * 3 - S(8);
        const by = p.y + (size.y - bs) / 2;
        c.igSetCursorScreenPos(v2(bx, by));
        const mic_on = a.mic != null;
        const mic_tip: [:0]const u8 = if (a.admin_muted) tr("O admin silenciou seu microfone") else if (mic_on) tr("Desligar o microfone") else tr("Ligar o microfone");
        if (iconButton("##mic", if (mic_on) ic.mic else ic.mic_slash, bs, if (mic_on) col.text else col.red, col.hover, mic_tip)) a.toggleMic();
        c.igSameLine(0, 0);
        if (iconButton("##deaf", ic.headphones, bs, if (a.deaf) col.red else col.text, col.hover, if (a.deaf) tr("Voltar a ouvir a sala") else tr("Parar de ouvir a sala (surdo)"))) a.toggleDeaf();
        if (a.deaf) slash(d, v2(bx + bs, by), bs);
        c.igSameLine(0, 0);
        if (iconButton("##gear", ic.gear, bs, col.text, col.hover, tr("Configurações"))) a.openSettings();
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
            const st = i18n.bufPrintZ(&stat_bufs[n], "{d}x{d} · {d:.0} fps · {d:.0} KB/s · {s}", .{ v.tex_w, v.tex_h, v.fps, v.kbps, latencyText(&lat_bufs[n], v) }) catch "";
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
            const st = i18n.bufPrintZ(&stat_bufs[n], "{d}x{d} · {d:.0} fps · {d} kbit/s{s} · {s} {d:.1} ms · {s}", .{ s.w, s.h, s.fps, s.bitrate_kbps, if (s.congested) tr(" (rede lenta)") else if (s.slow_viewer) tr(" (espectador lento)") else "", s.encoder_name, s.encode_ms, s.backendSlice() }) catch "";
            tiles[n] = .{ .stream = proto.streamId(0, proto.kind_screen), .tex = s.preview_tex, .tw = s.preview_w, .th = s.preview_h, .name = tr("Você"), .stats = st, .loading = s.preview_tex == 0, .ptr_stream = proto.streamId(my_id, proto.kind_screen), .clipbuf = s.clip };
            s.mutex.unlock();
            n += 1;
        }
        if (a.camera) |s| {
            s.mutex.lock();
            const st = i18n.bufPrintZ(&stat_bufs[n], "câmera · {d}x{d} · {d:.0} fps · {d} kbit/s · {s} · {s}", .{ s.w, s.h, s.fps, s.bitrate_kbps, s.encoder_name, s.backendSlice() }) catch "";
            tiles[n] = .{ .stream = proto.streamId(0, proto.kind_camera), .tex = s.preview_tex, .tw = s.preview_w, .th = s.preview_h, .name = tr("Você (câmera)"), .stats = st, .loading = s.preview_tex == 0, .ptr_stream = proto.streamId(my_id, proto.kind_camera), .clipbuf = s.clip };
            s.mutex.unlock();
            n += 1;
        }

        // barra do topo
        const top_h = if (a.theater) 0 else S(48);
        if (top_h > 0) {
            rectFill(d, o.x, o.y + top_h - 1, o.x + size.x, o.y + top_h, rgba(0x000000, 60), 0);
            var tx = o.x + S(18);
            if (!a.side_visible) {
                // barra lateral recolhida (janela estreita): botão pra trazer de volta
                c.igSetCursorScreenPos(v2(o.x + S(8), o.y + S(7)));
                if (iconButton("##side", ic.users, S(34), col.muted, col.hover, tr("Membros e controles"))) {
                    a.cfg.show_chat = false;
                    config.save(&a.cfg);
                }
                tx += S(36);
            }
            drawTextF(d, font_regular, 16, v2(tx, o.y + S(14)), col.muted, ic.tv);
            drawTextF(d, font_bold, 15.5, v2(tx + S(28), o.y + S(14)), col.header, tr("Transmissões"));
            if (n > 0) {
                const cnt = fmtZ("{d} na tela", .{n});
                drawTextF(d, font_regular, 13, v2(tx + S(144), o.y + S(16)), col.muted, cnt);
            }
            c.igSetCursorScreenPos(v2(o.x + size.x - S(44), o.y + S(7)));
            if (!a.chat_visible) {
                if (iconButton("##showchat", ic.comments, S(34), if (a.chat_unread > 0) col.header else col.muted, col.hover, tr("Mostrar chat"))) {
                    a.cfg.show_chat = true;
                    config.save(&a.cfg);
                }
                if (a.chat_unread > 0) {
                    const bp = v2(o.x + size.x - S(16), o.y + S(12));
                    c.ImDrawList_AddCircleFilled(d, bp, S(7), col.red, 0);
                    const t = fmtZ("{d}", .{@min(a.chat_unread, 9)});
                    const ts = textSizeF(font_bold, 10, t);
                    drawTextF(d, font_bold, 10, v2(bp.x - ts.x / 2, bp.y - ts.y / 2), col.white, t);
                }
            }
        }

        const area_x = o.x + S(if (a.theater) 0 else 16);
        const area_y = o.y + top_h + S(if (a.theater) 0 else 16);
        const area_w = size.x - S(if (a.theater) 0 else 32);
        const area_h = size.y - top_h - S(if (a.theater) 0 else 32);

        if (n == 0) {
            a.drawEmpty(cl, v2(o.x, o.y + top_h), v2(size.x, size.y - top_h));
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
        if (v.fps < 0.5) return tr("tela parada");
        const dec = if (std.mem.eql(u8, v.decoder_name, "nenhum")) tr("nenhum") else v.decoder_name;
        return i18n.bufPrint(buf, "atraso {d:.0} ms · {s} ({s}) {d:.1} ms", .{ v.latency_ms, v.codec.name(), dec, v.decode_ms }) catch "";
    }

    fn drawTile(a: *App, t: *const Tile, cell_x: f32, cell_y: f32, cell_w: f32, cell_h: f32, big: bool) void {
        // minha prévia na tela: a captura continua gerando a miniatura
        if (t.view == null) {
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
        const hovered = over or (a.tile_controls != null and a.tile_controls.? == t.stream);

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

        // ponteiros "olha aqui" de quem está assistindo junto
        a.drawPointers(t, ix, iy, iw, ih, uv0, uv1);
        // o meu, quando o modo ponteiro está ligado nesse quadro
        const pointing = a.pointer_tile != null and a.pointer_tile.? == t.stream;
        if (pointing) a.updatePointer(t, over and in_img and on_tile, ix, iy, iw, ih, uv0, uv1, mouse);
        // traços desenhados por cima (de todo mundo) e o meu, se estiver desenhando aqui
        a.drawStrokes(t, ix, iy, iw, ih, uv0, uv1);
        const drawing = a.draw_tile != null and a.draw_tile.? == t.stream;
        if (drawing) a.updateDraw(t, over and in_img and on_tile, ix, iy, iw, ih, uv0, uv1, mouse);
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
            const focused = a.focused != null and a.focused.? == t.stream;
            if (iconButton("##focus", if (focused) ic.compress else ic.expand, bs, col.white, withAlpha(col.blurple, 200), if (focused) tr("Voltar pra grade") else tr("Destacar (duplo clique: tela cheia)"))) {
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
                if (iconButton("##draw", ic.pen, bs, col.white, withAlpha(col.blurple, 200), if (drawing) tr("Parar de desenhar (botão direito apaga os seus traços)") else tr("Desenhar por cima: quem assiste e quem transmite veem; some sozinho em alguns segundos"))) {
                    if (drawing) a.draw_tile = null else {
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
                            a.crop_saved = a.crop;
                            a.crop = .{ 0, 0, 1, 1 }; // a prévia mostra a tela inteira pra escolher
                            a.crop_tile = t.stream;
                            a.applyCrop();
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
                .nv12 => codec.nv12ToRgba(j.pic.data.ptr, j.pic.data.ptr + n, w, h, px),
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
        const data = std.heap.c_allocator.dupe(u8, f.data) catch {
            std.heap.c_allocator.destroy(j);
            return;
        };
        j.* = .{ .pic = .{ .data = data, .layout = f.layout, .w = f.w, .h = f.h } };
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
        const ms = cb.stopRecording();
        if (ms == 0) {
            a.toast("Gravação cancelada (não chegou nenhum quadro completo).", .{}, true);
            return;
        }
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
        _ = a;
        if (update.getState() != .newer) return;
        var vb: [32]u8 = undefined;
        const v = update.latest(&vb);
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        const h = S(40);
        rectFill(d, p.x, p.y, p.x + w, p.y + h, withAlpha(col.green, 40), S(8));
        drawTextF(d, font_semibold, 14, v2(p.x + S(12), p.y + S(11)), col.header, fmtZ("{s}  telinha {s} saiu (você tem o {s})", .{ ic.arrow_right, v, version_string }));
        const bw = S(78);
        c.igSetCursorScreenPos(v2(p.x + w - bw - S(6), p.y + S(6)));
        if (primaryButton(tr("Baixar##update"), v2(bw, h - S(12)), col.green, col.green_hover, col.green_active)) openReleases();
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
            for (st.pts[0..st.n], 0..) |p, i| pts[i] = strokePoint(p, ix, iy, iw, ih, uv0, uv1);
            const color = withAlpha(avatarColor(st.from), alpha);
            if (st.n == 1) {
                c.ImDrawList_AddCircleFilled(d, pts[0], S(2.5), color, 0);
            } else c.ImDrawList_AddPolyline(d, &pts, st.n, color, S(3), 0);
        }
        if (next != std.math.inf(f64)) redrawIn(next);
    }

    fn updateDraw(a: *App, t: *const Tile, inside: bool, ix: f32, iy: f32, iw: f32, ih: f32, uv0: c.ImVec2_c, uv1: c.ImVec2_c, mouse: c.ImVec2_c) void {
        const cl = a.client orelse return;
        const now = sync.nowUs();
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
            const flags: u8 = if (a.draw_new) proto.draw_new else 0;
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
        a.crop = a.crop_saved;
        a.crop_tile = null;
        a.crop_from = null;
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
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) return a.cancelCrop();
        if (inside and c.igIsMouseClicked_Bool(1, false)) {
            a.crop = .{ 0, 0, 1, 1 };
            a.crop_tile = null;
            a.crop_from = null;
            return a.applyCrop();
        }
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
            if (r[2] - r[0] >= 0.04 and r[3] - r[1] >= 0.04) {
                a.crop = r;
                a.crop_tile = null;
                a.applyCrop();
            }
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
        const d = drawList();
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

        const cx = o.x + size.x / 2;
        var y = o.y + size.y * 0.22;
        const isz = S(84);
        c.ImDrawList_AddCircleFilled(d, v2(cx, y + isz / 2), isz / 2, col.bg_side, 0);
        const its = textSizeF(font_regular, 34, ic.tv);
        drawTextF(d, font_regular, 34, v2(cx - its.x / 2, y + (isz - its.y) / 2), col.muted, ic.tv);
        y += isz + S(22);

        const title = if (n_live > 0) tr("Tem gente ao vivo!") else tr("Ninguém está transmitindo");
        const ts = textSizeF(font_bold, 20, title);
        drawTextF(d, font_bold, 20, v2(cx - ts.x / 2, y), col.header, title);
        y += ts.y + S(8);
        const sub = if (n_live > 0) tr("Escolhe quem assistir. Dá pra assistir várias telas ao mesmo tempo.") else tr("Clica em Compartilhar tela pra começar, ou espera alguém da sala.");
        const ss = textSizeF(font_regular, 14, sub);
        drawTextF(d, font_regular, 14, v2(cx - ss.x / 2, y), col.muted, sub);
        y += ss.y + S(24);

        if (n_live > 0) {
            const card_w = S(220);
            const card_h = S(150);
            const gap = S(14);
            const per_row = @max(1, @min(n_live, @as(usize, @intFromFloat((size.x - S(40) + gap) / (card_w + gap)))));
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
                rectFill(d, x, yy, x + card_w, yy + card_h, if (hov) col.selected else col.bg_side, S(10));
                drawAvatar(d, v2(x + card_w / 2, yy + S(42)), S(26), m.id, m.nameSlice(), true);
                const nts = textSizeF(font_semibold, 15, m.nameSlice());
                drawTextF(d, font_semibold, 15, v2(x + (card_w - nts.x) / 2, yy + S(76)), col.header, m.nameSlice());
                const btn = fmtZ("{s}  Assistir", .{ic.eye});
                const bts = textSizeF(font_semibold, 13.5, btn);
                const bx0 = x + S(16);
                const by0 = yy + card_h - S(44);
                rectFill(d, bx0, by0, x + card_w - S(16), by0 + S(30), if (hov) col.blurple_hover else col.blurple, S(5));
                drawTextF(d, font_semibold, 13.5, v2(x + (card_w - bts.x) / 2, by0 + (S(30) - bts.y) / 2), col.white, btn);
                if (clicked) a.watch(m.id);
                c.igPopID();
            }
        } else {
            c.igSetCursorScreenPos(v2(cx - S(100), y));
            const lbl = fmtZ("{s}   Compartilhar tela###shareempty", .{ic.desktop});
            if (primaryButton(lbl, v2(S(200), S(42)), col.blurple, col.blurple_hover, col.blurple_active)) a.openShareModal();
            y += S(70);
            if (a.server) |s| a.drawHostTips(s, v2(cx, y));
        }
    }

    fn drawHostTips(a: *App, s: *Server, top: c.ImVec2_c) void {
        const d = drawList();
        const w = S(500);
        const x = top.x - w / 2;
        const y = top.y;
        const pad = S(18);
        const own_h: f32 = if (a.own_tunnel_open) S(196) else 0;
        const h = S(178) + own_h;
        rectFill(d, x, y, x + w, y + h, col.bg_side, S(10));
        drawTextF(d, font_bold, 14, v2(x + pad, y + S(16)), col.header, fmtZ("{s}  Chamando a galera de fora", .{ic.link}));

        // link público embutido
        var yy = y + S(44);
        const st: ?tunnel_mod.Status = if (a.tunnel) |t| t.status() else null;
        if (a.upnp) |m| {
            a.drawUpnpState(m, d, x, yy, w, pad);
        } else if (st == null) {
            drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, fmtZ("Link público: pelo {s}, funciona em qualquer rede.", .{config.getStr(&a.cfg.tunnel_host)}));
            drawTextF(d, font_regular, 13, v2(x + pad, yy + S(18)), col.muted, tr("Porta no roteador (UPnP): direto, menos atraso. Tudo cifrado."));
            c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
            if (primaryButton(fmtZ("{s}  Criar link público###tunnelgo", .{ic.globe}), v2(S(200), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.startTunnel();
            c.igSameLine(0, S(10));
            if (secondaryButton(fmtZ("{s}  Abrir porta no roteador###upnpgo", .{ic.link}), v2(S(230), S(38)))) a.startUpnp();
        } else switch (st.?.state) {
            .connecting => {
                drawTextF(d, font_semibold, 14, v2(x + pad, yy + S(4)), col.text, fmtZ("Abrindo o link público no {s}…", .{a.tunnel.?.hostSlice()}));
                drawTextF(d, font_regular, 13, v2(x + pad, yy + S(26)), col.muted, tr("Leva só alguns segundos."));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
                if (secondaryButton(tr("Cancelar##tunel"), v2(S(110), S(38)))) a.stopTunnel();
            },
            .ready => {
                var abuf: [300]u8 = undefined;
                const addr = a.tunnel.?.address(&abuf);
                drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, tr("Link público no ar. Manda o convite pra galera:"));
                rectFill(d, x + pad, yy + S(22), x + w - pad, yy + S(52), col.input, S(5));
                drawTextF(d, font_regular, 13, v2(x + pad + S(10), yy + S(29)), col.green, ic.circle);
                drawTextF(d, font_semibold, 14, v2(x + pad + S(30), yy + S(28)), col.header, fmtZ("{s}", .{addr}));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(62)));
                if (primaryButton(fmtZ("{s}  Copiar convite##tunel", .{ic.user_plus}), v2(S(170), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.copyInvite();
                c.igSameLine(0, S(10));
                if (secondaryButton(fmtZ("{s}  Desligar###tunneloff", .{ic.power}), v2(S(120), S(38)))) a.stopTunnel();
            },
            .failed => {
                drawTextF(d, font_semibold, 14, v2(x + pad, yy + S(4)), col.red, fmtZ("{s}  Não deu pra abrir o link público", .{ic.warn}));
                var eb: [300]u8 = undefined;
                drawTextF(d, font_regular, 13, v2(x + pad, yy + S(26)), col.muted, fmtZ("{s}", .{i18n.dynamic(st.?.err, &eb)}));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
                if (primaryButton(fmtZ("{s}  Tentar de novo###tunnelretry", .{ic.rotate}), v2(S(170), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
                    a.stopTunnel();
                    a.startTunnel();
                }
                c.igSameLine(0, S(10));
                if (secondaryButton(tr("Fechar##tunel"), v2(S(100), S(38)))) a.stopTunnel();
            },
        }

        // alternativa: túnel próprio (ngrok, bore, ssh)
        yy = y + S(150);
        c.igSetCursorScreenPos(v2(x + pad, yy - S(4)));
        const toggle = fmtZ("{s}  Prefere seu próprio túnel? (ngrok, bore, ssh)", .{if (a.own_tunnel_open) ic.chev_up else ic.chev_down});
        const ts = textSizeF(font_regular, 13, toggle);
        if (c.igInvisibleButton("##own", v2(ts.x, ts.y + S(8)), 0)) a.own_tunnel_open = !a.own_tunnel_open;
        drawTextF(d, font_regular, 13, v2(x + pad, yy), if (c.igIsItemHovered(0)) col.text else col.muted, toggle);
        if (!a.own_tunnel_open) return;

        yy += S(28);
        const cmds = [_][:0]const u8{
            fmtCmd(0, "ngrok tcp {d}", s.port),
            fmtCmd(1, "bore local {d} --to bore.pub", s.port),
            fmtCmd(2, "ssh -R 0:localhost:{d} serveo.net", s.port),
        };
        for (cmds, 0..) |cmd, i| {
            const cy = yy + @as(f32, @floatFromInt(i)) * S(32);
            rectFill(d, x + pad, cy, x + w - pad, cy + S(27), col.input, S(5));
            drawTextF(d, font_regular, 13, v2(x + S(28), cy + S(5)), col.text, cmd);
            c.igSetCursorScreenPos(v2(x + w - S(50), cy - S(1)));
            c.igPushID_Int(@intCast(i));
            if (iconButton("##cp", ic.copy, S(29), col.muted, col.hover, tr("Copiar"))) c.igSetClipboardText(cmd.ptr);
            c.igPopID();
        }
        yy += S(100);
        drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, tr("Cola aqui o endereço que o túnel mostrou e copia o convite:"));
        c.igSetCursorScreenPos(v2(x + pad, yy + S(22)));
        const fw = w - S(36) - S(150);
        _ = textField("##pub", "ex.: 0.tcp.sa.ngrok.io:12345", &a.cfg.public_addr, fw, false);
        c.igSameLine(0, S(10));
        if (primaryButton(fmtZ("{s}  Copiar convite##proprio", .{ic.user_plus}), v2(S(140), S(37)), col.blurple, col.blurple_hover, col.blurple_active)) {
            config.save(&a.cfg);
            a.stopTunnel(); // vale o endereço digitado
            a.copyInvite();
        }
    }

    var cmd_bufs: [3][80]u8 = undefined;
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
                    a.toast("Entre numa sala pra mandar imagem no chat.", .{}, true);
                    break;
                }
                if (!chatsend.looksLikeImage(p)) {
                    a.toast("Só dá pra mandar imagem (PNG, JPEG, GIF ou BMP).", .{}, true);
                    continue;
                }
                chatsend.sendFile(a.client.?, p);
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
    fn chatImageTex(a: *App, line: *const client_mod.ChatLine) ?*ImgTex {
        var free_i: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&a.img_cache, 0..) |*e, i| {
            if (e.id == line.id and e.id != 0) {
                e.used = a.frame_no;
                return if (e.failed) null else e;
            }
            if (e.used < oldest) {
                oldest = e.used;
                free_i = i;
            }
        }
        const e = &a.img_cache[free_i];
        gl.delete(&e.tex);
        e.* = .{ .id = line.id, .used = a.frame_no, .w = line.img_w, .h = line.img_h };
        const data = line.img orelse {
            e.failed = true;
            return null;
        };
        const px = chatimg.decode(data, line.img_w, line.img_h) catch {
            e.failed = true;
            return null;
        };
        defer std.heap.c_allocator.free(px);
        // no chat vai uma miniatura (até 480 px de largura): a imagem inteira
        // só pra quem abrir em tela cheia (1600 px em RGBA = 10 MB de textura)
        const tw: usize = @min(line.img_w, 480);
        if (tw == line.img_w) {
            gl.upload(&e.tex, px, line.img_w, line.img_h, gl.RGBA);
        } else {
            const th: usize = @max(1, @as(usize, line.img_h) * tw / line.img_w);
            const small = std.heap.c_allocator.alloc(u8, tw * th * 4) catch {
                e.failed = true;
                return null;
            };
            defer std.heap.c_allocator.free(small);
            chatimg.resample(px, line.img_w, line.img_h, small, tw, th);
            gl.upload(&e.tex, small, @intCast(tw), @intCast(th), gl.RGBA);
        }
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
            e.* = .{};
        }
        a.img_view = null;
        gl.delete(&a.view_tex);
    }

    /// Reações embaixo da mensagem (as que alguém deu). Clique liga/desliga a sua.
    fn drawReactionChips(a: *App, cl: *Client, line: *const client_mod.ChatLine, me: u32) void {
        _ = a;
        if (line.n_reacts == 0) return;
        c.igDummy(v2(0, S(2)));
        var first = true;
        for (0..proto.reactions) |e| {
            const rc = line.reactCount(@intCast(e), me);
            if (rc.n == 0) continue;
            if (!first) c.igSameLine(0, S(4));
            first = false;
            const label = fmtZ("{d}", .{rc.n});
            const tw = textSizeF(font_semibold, 12.5, label).x;
            const w = S(32) + tw;
            const h = S(22);
            const p = c.igGetCursorScreenPos();
            const clicked = c.igInvisibleButton(fmtZ("##chip{d}_{d}", .{ line.id, e }).ptr, v2(w, h), 0);
            const hov = c.igIsItemHovered(0);
            const d = drawList();
            rectFill(d, p.x, p.y, p.x + w, p.y + h, if (rc.mine) withAlpha(col.blurple, 70) else if (hov) col.hover else rgba(0x000000, 60), S(8));
            if (rc.mine) c.ImDrawList_AddRect(d, p, v2(p.x + w, p.y + h), col.blurple, S(8) * col.round, S(1), 0);
            drawTextF(d, font_regular, 12.5, v2(p.x + S(8), p.y + S(4)), reaction_colors[e], reaction_icons[e]);
            drawTextF(d, font_semibold, 12.5, v2(p.x + S(26), p.y + S(3)), col.text, label);
            if (hov) tooltipText(reactionName(e));
            if (clicked) cl.sendReact(line.id, @intCast(e), !rc.mine);
        }
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
        c.ImDrawList_AddImageRounded(drawList(), .{ ._TexData = null, ._TexID = e.tex }, p, v2(p.x + w, p.y + h), v2(0, 0), v2(1, 1), 0xFFFFFFFF, S(6) * col.round, 0);
    }

    fn pickMention(a: *App, i: usize) void {
        const n = a.mention_sugg_len[i];
        @memcpy(a.mention_apply[0..n], a.mention_sugg[i][0..n]);
        a.mention_apply_len = n;
    }

    fn drawChat(a: *App, cl: *Client, size: c.ImVec2_c) void {
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, col.bg_side);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        _ = c.igBeginChild_Str("chat", size, 0, c.ImGuiWindowFlags_NoScrollbar);
        const d = drawList();
        const o = c.igGetCursorScreenPos();
        const hh = S(48);
        rectFill(d, o.x, o.y + hh - 1, o.x + size.x, o.y + hh, rgba(0x000000, 60), 0);
        drawTextF(d, font_regular, 16, v2(o.x + S(16), o.y + S(14)), col.muted, ic.comments);
        drawTextF(d, font_bold, 15.5, v2(o.x + S(44), o.y + S(14)), col.header, tr("Chat"));
        c.igSetCursorScreenPos(v2(o.x + size.x - S(44), o.y + S(7)));
        if (iconButton("##hidechat", ic.xmark, S(34), col.muted, col.hover, tr("Esconder chat"))) {
            a.cfg.show_chat = false;
            config.save(&a.cfg);
        }
        c.igSetCursorScreenPos(v2(o.x, o.y + hh));

        // mensagens
        const input_h = S(68);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(14), S(10)));
        c.igPushStyleColor_U32(c.ImGuiCol_ScrollbarBg, 0);
        _ = c.igBeginChild_Str("msgs", v2(size.x, size.y - hh - input_h), 0, 0);
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
            const with_header = line.from != 0 and line.from != last_from;
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
                c.igPushTextWrapPos(0);
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
            if (line.from != last_from) {
                c.igDummy(v2(0, S(12)));
                const p = c.igGetCursorScreenPos();
                top = p.y;
                const dl = drawList();
                drawAvatar(dl, v2(p.x + S(18), p.y + S(18)), S(18), line.from, line.nameSlice(), false);
                drawTextF(dl, font_semibold, 14.5, v2(p.x + S(48), p.y), avatarColor(line.from), line.nameSlice());
                const ns = textSizeF(font_semibold, 14.5, line.nameSlice());
                drawTextF(dl, font_regular, 11.5, v2(p.x + S(54) + ns.x, p.y + S(3)), col.faint, fmtZ("{d:0>2}:{d:0>2}", .{ line.hour, line.minute }));
                c.igSetCursorScreenPos(v2(p.x + S(48), p.y + S(20)));
            } else {
                top = c.igGetCursorScreenPos().y;
                c.igSetCursorPosX(c.igGetCursorPosX() + S(48));
            }
            const left = c.igGetCursorScreenPos().x;
            if (text.len > 0) {
                c.igPushTextWrapPos(0);
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
            if (line.n_reacts > 0) {
                c.igSetCursorScreenPos(v2(left, c.igGetCursorScreenPos().y));
                a.drawReactionChips(cl, line, me);
            }
            const bottom = c.igGetCursorScreenPos().y;
            // menção a você: fundo amarelado com faixa do lado (como no Discord)
            if (line.from != me and mentions(text, my_name)) {
                c.ImDrawList_ChannelsSetCurrent(mdl, 0);
                const wx = c.igGetWindowPos().x;
                rectFill(mdl, wx, top - S(2), wx + size.x, bottom + S(2), withAlpha(col.yellow, 26), 0);
                rectFill(mdl, wx, top - S(2), wx + S(3), bottom + S(2), col.yellow, 0);
                c.ImDrawList_ChannelsSetCurrent(mdl, 1);
            }
            // mouse em cima: barra de reações no canto da mensagem
            if (msgs_hovered and mouse.y >= top - S(10) and mouse.y < bottom + S(2)) hover_line = line.id;
            if (a.react_hover == line.id) {
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
            last_from = line.from;
        }
        c.ImDrawList_ChannelsMerge(mdl);
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

        // caixa de mensagem
        const ip = c.igGetCursorScreenPos();
        const bx = ip.x + S(12);
        const by = ip.y + S(10);
        const bw = size.x - S(24);
        const bh = S(44);
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
        // a caixa continua ativa depois do Enter (io.ConfigInputTextEnterKeepActive):
        // sem buraco de foco, nenhuma letra digitada logo depois se perde. O
        // callback guarda a mensagem e esvazia a caixa no mesmo quadro do Enter.
        a.chat_sent_len = 0;
        a.updateMentionSuggestions(cl);
        c.igSetNextItemWidth(bw - S(82));
        const enter = c.igInputTextWithHint("##chatin", tr("Mensagem, @nome, ou cole/arraste uma imagem"), &a.chat_input, a.chat_input.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackAlways | c.ImGuiInputTextFlags_CallbackCompletion, chatCallback, a);
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
        c.igSetCursorScreenPos(v2(bx + bw - S(76), by + S(5)));
        if (iconButton("##attach", ic.image, S(34), col.muted, col.hover, tr("Imagem: arraste o arquivo pra janela ou copie e aperte Ctrl+V aqui"))) {
            if (!chatsend.paste(cl)) a.toast("Pra mandar imagem: arraste o arquivo pra janela do telinha, ou copie a imagem e aperte Ctrl+V no chat.", .{}, false);
        }
        c.igSetCursorScreenPos(v2(bx + bw - S(40), by + S(5)));
        const send_click = iconButton("##send", ic.send, S(34), col.muted, col.hover, tr("Enviar"));
        if (enter or send_click) {
            const raw = if (enter and a.chat_sent_len > 0) a.chat_sent[0..a.chat_sent_len] else std.mem.sliceTo(&a.chat_input, 0);
            const msg = std.mem.trim(u8, raw, " \t");
            if (msg.len > 0) cl.sendChat(msg);
            @memset(&a.chat_input, 0);
            if (send_click) a.focus_chat = true; // o clique no botão tirou o foco
        }

        c.igEndChild();
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
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
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false) or c.igIsKeyPressed_Bool(c.ImGuiKey_KeypadEnter, false)) {
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
        _ = c.igCheckbox(tr("Usar a placa de vídeo (NVIDIA; no Windows também AMD e Intel), se tiver###hardware"), &a.cfg.hardware);

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
            if (clicked) a.settings_page = pg.page;
        }
        // Fechar no pé da barra
        c.igSetCursorPos(v2(S(10), mh - S(56)));
        var close = primaryButton(tr("Fechar###fecharconfig"), v2(nav_w - S(20), S(40)), col.blurple, col.blurple_hover, col.blurple_active);
        close = close or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);

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
                update.checkAsync(build_options.repo, version_string);
            if (update.getState() == .newer) {
                c.igSameLine(0, S(8));
                if (c.igSmallButton(tr("Baixar a nova##upd"))) openReleases();
            }
        }
        if (c.igCheckbox(tr("Clipes: guardar o finalzinho do que você assiste (pra salvar um clipe na hora)###clips"), &a.cfg.clips)) a.applyClips();
        c.igSameLine(0, S(8));
        if (c.igSmallButton(tr("Abrir a pasta###clipsdir"))) a.openClipsFolder();
        c.igPopStyleColor(1);
        if (a.cfg.clips) {
            c.igDummy(v2(0, S(6)));
            fieldLabel("DURAÇÃO DO CLIPE");
            const secs = [_]i32{ 15, 30, 60, 120, 180 };
            var si: i32 = 1;
            for (secs, 0..) |x, i| {
                if (x == a.cfg.clip_secs) si = @intCast(i);
            }
            if (segmented("clipsecs", &.{ "15 s", "30 s", "1 min", "2 min", "3 min" }, &si, w)) {
                a.cfg.clip_secs = secs[@intCast(si)];
                clip.keep_secs.store(@intCast(a.cfg.clip_secs), .release);
                config.save(&a.cfg);
            }
            pushFont(font_regular, 12);
            textColored(col.faint, fmtZ("Usa até ~{d} MB de memória por transmissão assistida (depende da qualidade).", .{@divTrunc(a.cfg.clip_secs * 3, 4) + 4}));
            popFont();
            c.igDummy(v2(0, S(6)));
            fieldLabel("ATALHO PRA SALVAR CLIPE (vale com o jogo em foco)");
            if (a.clip_key_capture) a.captureClipKey();
            var kb: [32]u8 = undefined;
            const bw = (w - S(8)) * 0.7;
            const label = if (a.clip_key_capture) fmtZ("{s}###clipkey", .{tr("Aperte a tecla (ou um botão lateral do mouse)...")}) else fmtZ("{s}  {s}###clipkey", .{ tr("Tecla:"), keyName(a.cfg.clip_key, a.cfg.clip_scancode, a.cfg.clip_mouse, &kb) });
            if (secondaryButton(label, v2(bw, S(34)))) a.clip_key_capture = true;
            c.igSameLine(0, S(8));
            if (secondaryButton(tr("Sem atalho###clipkeyoff"), v2(w - bw - S(8), S(34)))) {
                a.cfg.clip_key = 0;
                a.cfg.clip_mouse = -1;
                a.clip_key_capture = false;
                a.applyClipKey();
                config.save(&a.cfg);
            }
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
            setZoom(@as(f32, @floatFromInt(a.cfg.ui_zoom)) / 100);
            config.save(&a.cfg);
        }
        c.igDummy(v2(0, S(14)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        if (c.igCheckbox(tr("Efeito CRT (linhas de tela antiga; o vídeo fica de fora)###crt"), &a.cfg.crt)) config.save(&a.cfg);
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

    /// Atalho de clipe: a thread (de fora) ou a própria janela (com foco; o Wayland só deixa assim).
    fn pollClipKey(a: *App) void {
        if (hotkey.pressed.swap(false, .acq_rel)) a.clipHotkey();
        if (a.clip_key_capture or (a.cfg.clip_key <= 0 and a.cfg.clip_mouse < 0)) return;
        const focused = c.glfwGetWindowAttrib(a.window, c.GLFW_FOCUSED) != 0;
        const down = focused and !c.igGetIO_Nil().*.WantTextInput and if (a.cfg.clip_mouse >= 0)
            c.glfwGetMouseButton(a.window, a.cfg.clip_mouse) == c.GLFW_PRESS
        else
            c.glfwGetKey(a.window, a.cfg.clip_key) == c.GLFW_PRESS;
        if (down and !a.clip_key_prev) a.clipHotkey();
        a.clip_key_prev = down;
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
            .{ .k = c.GLFW_KEY_SPACE, .n = tr("Espaço") },             .{ .k = c.GLFW_KEY_LEFT_CONTROL, .n = tr("Ctrl esq.") },
            .{ .k = c.GLFW_KEY_RIGHT_CONTROL, .n = tr("Ctrl dir.") }, .{ .k = c.GLFW_KEY_LEFT_ALT, .n = "Alt" },
            .{ .k = c.GLFW_KEY_RIGHT_ALT, .n = "AltGr" },         .{ .k = c.GLFW_KEY_LEFT_SHIFT, .n = tr("Shift esq.") },
            .{ .k = c.GLFW_KEY_RIGHT_SHIFT, .n = tr("Shift dir.") },  .{ .k = c.GLFW_KEY_CAPS_LOCK, .n = "Caps Lock" },
            .{ .k = c.GLFW_KEY_TAB, .n = "Tab" },                  .{ .k = c.GLFW_KEY_INSERT, .n = "Insert" },
            .{ .k = c.GLFW_KEY_HOME, .n = "Home" },                .{ .k = c.GLFW_KEY_END, .n = "End" },
            .{ .k = c.GLFW_KEY_PAGE_UP, .n = "Page Up" },          .{ .k = c.GLFW_KEY_PAGE_DOWN, .n = "Page Down" },
            .{ .k = c.GLFW_KEY_PAUSE, .n = "Pause" },              .{ .k = c.GLFW_KEY_SCROLL_LOCK, .n = "Scroll Lock" },
        };
        for (special) |sp| if (sp.k == k) return sp.n;
        return i18n.bufPrint(buf, "tecla {d}", .{k}) catch "?";
    }

    /// Esperando a tecla nova: a primeira apertada (ou botão do meio/lateral do mouse).
    /// Uma tecla configurável (apertar pra falar, atalho de clipe).
    const KeyRef = struct { key: *i32, scancode: *i32, mouse: *i32 };

    /// Esperando a tecla nova: a primeira apertada (ou botão do meio/lateral do
    /// mouse). true = pegou; false = Esc (cancelou); null = ainda esperando.
    fn captureKey(a: *App, r: KeyRef) ?bool {
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) return false;
        var k: c_int = c.GLFW_KEY_SPACE;
        while (k <= c.GLFW_KEY_LAST) : (k += 1) {
            if (k == c.GLFW_KEY_ESCAPE) continue;
            if (c.glfwGetKey(a.window, k) != c.GLFW_PRESS) continue;
            r.key.* = k;
            r.scancode.* = c.glfwGetKeyScancode(k);
            r.mouse.* = -1;
            return true;
        }
        for ([_]c_int{ 2, 3, 4 }) |btn| {
            if (c.glfwGetMouseButton(a.window, btn) == c.GLFW_PRESS) {
                r.key.* = 0;
                r.mouse.* = btn;
                return true;
            }
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

    fn captureClipKey(a: *App) void {
        const got = a.captureKey(.{ .key = &a.cfg.clip_key, .scancode = &a.cfg.clip_scancode, .mouse = &a.cfg.clip_mouse }) orelse return;
        a.clip_key_capture = false;
        if (got) {
            a.applyClipKey();
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

    fn applyClipKey(a: *App) void {
        if (a.cfg.clip_mouse >= 0) {
            hotkey.configure(0, a.cfg.clip_mouse);
        } else if (a.cfg.clip_key > 0) {
            hotkey.configure(globalKey(a.cfg.clip_key, a.cfg.clip_scancode), -1);
        } else hotkey.configure(0, -1);
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
                a.applyVoice();
            }
        }
        c.igDummy(v2(0, S(8)));
        fieldLabel("SENSIBILIDADE (quanto maior, mais fácil o microfone abrir)");
        const sens_before = a.cfg.voice_sensitivity;
        sliderStyled("##sens", &a.cfg.voice_sensitivity, 0, 100, "%d", w);
        if (sens_before != a.cfg.voice_sensitivity) if (a.mic) |m| m.setSensitivity(micSensitivity(&a.cfg));
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
            a.applyVoice();
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
        if (segmented("dbgvia", &.{ "gofile.io (gera um link)", "Webhook (Discord etc.)" }, &via, w)) {
            a.cfg.debug_send = via;
            config.save(&a.cfg);
        }
        const method: debuglog.Method = if (a.cfg.debug_send == 1) .webhook else .gofile;
        c.igDummy(v2(0, S(4)));
        if (method == .webhook) {
            // escondido: a URL é a chave do canal (e a tela pode estar sendo transmitida)
            if (textField("##dbghook", "https://discord.com/api/webhooks/...", a.cfg.debug_webhook[0 .. a.cfg.debug_webhook.len - 1], w, true)) config.save(&a.cfg);
            if (c.igIsItemDeactivatedAfterEdit()) config.save(&a.cfg);
            c.igDummy(v2(0, S(4)));
        }
        const st = debuglog.sendState();
        const hook = config.getStr(&a.cfg.debug_webhook);
        const can = a.debug_size > 0 and st != .sending and (method == .gofile or debuglog.validUrl(hook));
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
                a.applyTheme();
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
            a.applyTheme();
            config.save(&a.cfg);
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
            if (a.takeCssFile()) a.applyTheme();
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
        try w.print(",\"mic\":{},\"deaf\":{},\"share_modal\":{},\"settings_modal\":{},\"theater\":{},\"fullscreen\":{}", .{ a.mic != null, a.deaf, a.share_modal, a.settings_modal, a.theater, a.fullscreen });
        if (a.focused) |f| try w.print(",\"focused\":{d}", .{f}) else try w.writeAll(",\"focused\":null");
        try w.print(",\"reconnect\":{{\"attempt\":{d},\"waiting\":{}}}", .{ a.reconnect.attempt, a.reconnect.waiting });
        try w.print(",\"home_tab\":{d},\"show_advanced\":{},\"own_tunnel_open\":{},\"chat_visible\":{},\"side_visible\":{},\"chat_unread\":{d}", .{
            a.home_tab, a.show_advanced, a.own_tunnel_open, a.chat_visible, a.side_visible, a.chat_unread,
        });
        const cf = &a.cfg;
        try w.print(",\"cfg\":{{\"name\":{f},\"join_addr\":{f},\"join_pass\":{f},\"room_name\":{f},\"host_pass\":{f},\"port\":{f},\"public_addr\":{f}", .{
            s(config.getStr(&cf.name)), s(config.getStr(&cf.join_addr)), s(config.getStr(&cf.join_pass)), s(config.getStr(&cf.room_name)),
            s(config.getStr(&cf.host_pass)), s(std.mem.sliceTo(&a.port_buf, 0)), s(config.getStr(&cf.public_addr)),
        });
        try w.print(",\"fps\":{d},\"quality\":{d},\"mode\":{d},\"resolution\":{d},\"cursor\":{},\"audio\":{},\"hardware\":{},\"stats_always\":{},\"show_chat\":{}", .{
            cf.fps, cf.quality, cf.mode, cf.resolution, cf.cursor, cf.audio, cf.hardware, cf.stats_always, cf.show_chat,
        });
        try w.print(",\"noise_suppression\":{},\"echo_cancellation\":{},\"voice_sensitivity\":{d},\"mic_on_join\":{},\"sounds\":{},\"mic_device\":{f},\"notifications\":{},\"clips\":{},\"camera_res\":{d},\"camera_device\":{f},\"cameras\":{d},\"audio_app\":{f},\"audio_exclude\":{f},\"audio_apps\":{d},\"language\":{f},\"debug_log\":{},\"debug_send\":{d},\"debug_webhook\":{f},\"theme\":{f},\"custom_theme\":{f},\"custom_css\":{f},\"css_status\":{f},\"auto_quality\":{},\"resolution_idx\":{d},\"ui_zoom\":{d},\"crt\":{},\"voice_ptt\":{},\"ptt_key\":{d},\"ptt_mouse\":{d},\"clip_key\":{d}}}", .{
            cf.noise_suppression, cf.echo_cancellation, cf.voice_sensitivity, cf.mic_on_join, cf.sounds, s(config.getStr(&cf.mic_device)), cf.notifications, cf.clips, cf.camera_res, s(config.getStr(&cf.camera_device)), a.n_cams, s(config.getStr(&cf.audio_app)), s(config.getStr(&cf.audio_exclude)), a.n_audio_apps, s(config.getStr(&cf.language)), cf.debug_log, cf.debug_send, s(config.getStr(&cf.debug_webhook)), s(config.getStr(&cf.theme)), s(config.getStr(&cf.custom_theme)), s(config.getStr(&cf.custom_css)), s(@tagName(cssfile.getStatus())), cf.auto_quality, cf.resolution, cf.ui_zoom, cf.crt, cf.voice_ptt, cf.ptt_key, cf.ptt_mouse, cf.clip_key,
        });
        try w.print(",\"lang\":{f}", .{s(@tagName(i18n.get()))});
        const cb_text: [*c]const u8 = c.glfwGetClipboardString(a.window);
        try w.print(",\"clipboard\":{f},\"chat_input\":{f}", .{ s(if (cb_text != null) std.mem.span(cb_text) else ""), s(std.mem.sliceTo(&a.chat_input, 0)) });
        try w.print(",\"notifications_sent\":{d},\"away\":{}", .{ a.notifications_sent, a.away() });
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
        try w.print(",\"speaking\":{}", .{if (a.mic) |m| m.speaking.load(.monotonic) else false});
        try w.print(",\"crop\":[{d:.3},{d:.3},{d:.3},{d:.3}],\"strokes\":[", .{ a.crop[0], a.crop[1], a.crop[2], a.crop[3] });
        if (a.client) |cl| {
            cl.mutex.lock();
            for (cl.strokes.items, 0..) |st, i| try w.print("{s}{{\"from\":{d},\"stream\":{d},\"n\":{d}}}", .{ if (i > 0) "," else "", st.from, st.stream, st.n });
            cl.mutex.unlock();
        }
        try w.writeAll("]");
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
            try w.print(",\"sharer\":{{\"state\":{f},\"w\":{d},\"h\":{d},\"fps\":{d:.1},\"backend\":{f},\"encoder\":{f},\"audio\":{},\"audio_err\":{f},\"auto_cap\":{d}}}", .{ s(@tagName(sh.state)), sh.w, sh.h, sh.fps, s(sh.backendSlice()), s(sh.encoder_name), audio_on, s(std.mem.sliceTo(&aerr, 0)), sh.auto_cap.load(.acquire) });
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
            try w.print("{{\"stream\":{d},\"fps\":{d:.1},\"w\":{d},\"h\":{d},\"shown\":{},\"audio\":{},\"volume\":{d:.2},\"muted\":{},\"clip_secs\":{d:.1},\"recording\":{},\"rec_ms\":{d},\"decoder\":{f},\"codec\":{f},\"latency\":{d:.0}}}", .{
                v.stream, v.fps, v.tex_w, v.tex_h, v.tex != 0, has_audio, v.audio_ring.getVolume(), v.audio_ring.isMuted(), if (v.clip) |cb| cb.seconds() else -1, rs.active, rs.ms, s(v.decoder_name), s(v.codec.name()), v.latency_ms,
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
                try w.print("{{\"id\":{d},\"name\":{f},\"flags\":{d},\"streaming\":{},\"camera\":{},\"admin\":{},\"owner\":{},\"muted\":{},\"route\":{d},\"audio\":{},\"w\":{d},\"h\":{d},\"voice_volume\":{d:.2},\"watching\":[", .{
                    m.id, s(m.nameSlice()), m.flags, m.streaming, m.camera(), m.admin, m.owner, m.muted(), m.route, m.audio, m.w, m.h, vv,
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
        var y = size.y - S(24);
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
