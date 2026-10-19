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
const sharer_mod = @import("sharer.zig");
const proto = @import("proto.zig");
const audio = @import("audio.zig");
const voice = @import("voice.zig");
pub const version_string = "2.1.0";
const Sharer = sharer_mod.Sharer;

// ---------------------------------------------------------------------------
// Cores e fontes

fn rgba(comptime hex: u24, comptime a: u8) u32 {
    const r: u32 = (hex >> 16) & 0xff;
    const g: u32 = (hex >> 8) & 0xff;
    const b: u32 = hex & 0xff;
    return (@as(u32, a) << 24) | (b << 16) | (g << 8) | r;
}
fn rgb(comptime hex: u24) u32 {
    return rgba(hex, 255);
}

pub const col = struct {
    pub const bg_dark = rgb(0x1E1F22);
    pub const bg_side = rgb(0x2B2D31);
    pub const bg_main = rgb(0x313338);
    pub const bg_user = rgb(0x232428);
    pub const bg_float = rgb(0x111214);
    pub const input = rgb(0x1E1F22);
    pub const chat_input = rgb(0x383A40);
    pub const hover = rgb(0x35373C);
    pub const selected = rgb(0x404249);
    pub const text = rgb(0xDBDEE1);
    pub const muted = rgb(0x949BA4);
    pub const faint = rgb(0x6D6F78);
    pub const header = rgb(0xF2F3F5);
    pub const blurple = rgb(0x5865F2);
    pub const blurple_hover = rgb(0x4752C4);
    pub const blurple_active = rgb(0x3C45A5);
    pub const green = rgb(0x23A55A);
    pub const red = rgb(0xF23F43);
    pub const red_hover = rgb(0xDA373C);
    pub const yellow = rgb(0xF0B232);
    pub const black = rgb(0x000000);
    pub const white = rgb(0xFFFFFF);
    pub const shadow = rgba(0x000000, 140);
    pub const overlay = rgba(0x000000, 170);
};

const avatar_colors = [_]u32{ rgb(0x5865F2), rgb(0x3BA55C), rgb(0xFAA61A), rgb(0xED4245), rgb(0xEB459E), rgb(0x9B59B6), rgb(0x1ABC9C), rgb(0xE67E22) };

pub var font_regular: *c.ImFont = undefined;
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
    c.igPushFont(f, S(size));
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
    c.ImDrawList_AddText_FontPtr(d, f, S(size), pos, color, s.ptr, s.ptr + s.len, 0, null);
}
fn textSizeF(f: *c.ImFont, size: f32, s: []const u8) c.ImVec2_c {
    pushFont(f, size);
    defer popFont();
    return textSize(s);
}
fn rectFill(d: *c.ImDrawList, x0: f32, y0: f32, x1: f32, y1: f32, color: u32, rounding: f32) void {
    c.ImDrawList_AddRectFilled(d, v2(x0, y0), v2(x1, y1), color, rounding, 0);
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
fn fmtZ(comptime f: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintZ(&fmt_buf, f, args) catch "...";
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
    const t = "AO VIVO";
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
    c.igPushStyleColor_U32(c.ImGuiCol_Text, col.white);
    pushFont(font_semibold, 15);
    const r = c.igButton(label.ptr, size);
    popFont();
    c.igPopStyleColor(4);
    return r;
}

fn secondaryButton(label: [:0]const u8, size: c.ImVec2_c) bool {
    return primaryButton(label, size, rgb(0x4E5058), rgb(0x6D6F78), rgb(0x80848E));
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

fn fieldLabel(s: []const u8) void {
    pushFont(font_bold, 11.5);
    textColored(col.muted, s);
    popFont();
}

fn textField(id: [:0]const u8, hint: [:0]const u8, buf: []u8, width: f32, password: bool) bool {
    c.igSetNextItemWidth(width);
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(9)));
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, col.input);
    c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, col.input);
    var flags: c.ImGuiInputTextFlags = c.ImGuiInputTextFlags_EnterReturnsTrue;
    if (password) flags |= c.ImGuiInputTextFlags_Password;
    const r = c.igInputTextWithHint(id.ptr, hint.ptr, buf.ptr, buf.len, flags, null, null);
    c.igPopStyleColor(3);
    c.igPopStyleVar(1);
    return r;
}

/// Botões lado a lado, tipo "segmented control". Retorna o índice escolhido.
fn segmented(id: [:0]const u8, options: []const [:0]const u8, current: *i32, width: f32) bool {
    c.igPushID_Str(id.ptr);
    defer c.igPopID();
    var changed = false;
    const w = (width - S(4) * @as(f32, @floatFromInt(options.len - 1))) / @as(f32, @floatFromInt(options.len));
    for (options, 0..) |opt, i| {
        if (i > 0) c.igSameLine(0, S(4));
        const sel = current.* == @as(i32, @intCast(i));
        const bg = if (sel) col.blurple else col.input;
        const hv = if (sel) col.blurple_hover else col.hover;
        c.igPushID_Int(@intCast(i));
        if (primaryButton(opt, v2(w, S(34)), bg, hv, if (sel) col.blurple_active else col.selected)) {
            current.* = @intCast(i);
            changed = true;
        }
        c.igPopID();
    }
    return changed;
}

// ---------------------------------------------------------------------------
// Estado do app

const Toast = struct { text: [256]u8, len: usize, until: f64, err: bool };

/// Reconexão automática depois de uma queda (internet oscilou, túnel caiu...).
const Reconnect = struct {
    attempt: u32 = 0, // 0 = não está reconectando
    waiting: bool = false, // esperando a hora da próxima tentativa
    at: f64 = 0,
    // o que restaurar quando voltar (por nome: depois de o servidor reiniciar os ids mudam)
    share: bool = false,
    watch: [16][48]u8 = undefined,
    watch_len: [16]usize = undefined,
    n_watch: usize = 0,
};
const max_reconnect = 6;

pub const App = struct {
    window: *c.GLFWwindow,
    cfg: config.Config,

    screen: enum { home, room } = .home,
    home_tab: i32 = 0, // 0 entrar, 1 criar
    home_error: [256]u8 = undefined,
    home_error_len: usize = 0,
    port_buf: [8]u8 = undefined,
    home_card_h: f32 = 460,

    client: ?*Client = null,
    server: ?*Server = null,
    tunnel: ?*Tunnel = null, // link público da sala que eu hospedo
    own_tunnel_open: bool = false, // card: "prefere seu próprio túnel?" aberto
    sharer: ?*Sharer = null,
    connect_label: [300]u8 = undefined,
    connect_label_len: usize = 0,
    was_connected: bool = false,

    views: std.ArrayList(*View) = .empty,
    focused: ?u32 = null, // dono da transmissão em destaque (0 = eu)
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

    share_modal: bool = false,
    sources: [16]c.cap_source = undefined,
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

    // voz
    mic: ?*voice.Mic = null,
    mic_client: ?*Client = null, // quem recebe os pacotes do microfone (com referência)
    mic_wanted: bool = false, // quer o microfone ligado (lembra durante o "surdo")
    deaf: bool = false,
    echo_hint_shown: bool = false,
    mic_names: [16][128]u8 = undefined, // microfones (tela de configurações)
    n_mic_names: usize = 0,
    volumes: config.VoiceVolumes = .{}, // volume da voz por nome (lembrado)
    // membros do último quadro (sons de entrou/saiu/ao vivo, volumes salvos)
    known: [64]struct { id: u32, streaming: bool } = undefined,
    n_known: usize = 0,
    known_ready: bool = false, // a primeira lista depois de conectar não toca som

    // opções de linha de comando
    auto_share: bool = false,
    auto_watch: bool = false,
    auto_public: bool = false,

    pub fn init(window: *c.GLFWwindow) App {
        var a: App = .{ .window = window, .cfg = config.load(), .volumes = config.VoiceVolumes.load() };
        _ = std.fmt.bufPrintZ(&a.port_buf, "{d}", .{a.cfg.host_port}) catch {};
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
        if (a.screen == .room) a.leaveRoom();
        config.save(&a.cfg);
    }

    fn toast(a: *App, comptime f: []const u8, args: anytype, err: bool) void {
        if (a.n_toasts == a.toasts.len) {
            std.mem.copyForwards(Toast, a.toasts[0 .. a.toasts.len - 1], a.toasts[1..]);
            a.n_toasts -= 1;
        }
        var t: Toast = .{ .text = undefined, .len = 0, .until = c.igGetTime() + 5.0, .err = err };
        const s = std.fmt.bufPrint(&t.text, f, args) catch t.text[0..0];
        t.len = s.len;
        a.toasts[a.n_toasts] = t;
        a.n_toasts += 1;
    }

    // ------------------------------------------------------------------ ações

    fn setHomeError(a: *App, s: []const u8) void {
        a.home_error_len = @min(s.len, a.home_error.len);
        @memcpy(a.home_error[0..a.home_error_len], s[0..a.home_error_len]);
    }

    fn myName(a: *App) []const u8 {
        const n = std.mem.trim(u8, config.getStr(&a.cfg.name), " ");
        return if (n.len == 0) "anônimo" else n;
    }

    fn joinRoom(a: *App) void {
        var addr: []const u8 = std.mem.trim(u8, config.getStr(&a.cfg.join_addr), " \t");
        // convite: telinha://host:porta#senha
        if (std.mem.startsWith(u8, addr, "telinha://")) {
            addr = addr["telinha://".len..];
            if (std.mem.findScalar(u8, addr, '#')) |h| {
                var pw_buf: [129]u8 = undefined;
                config.setStr(&pw_buf, addr[h + 1 ..]);
                a.cfg.join_pass = pw_buf;
                addr = addr[0..h];
                // deixa o campo só com o endereço
                var tmp: [256]u8 = undefined;
                config.setStr(&tmp, addr);
                a.cfg.join_addr = tmp;
                addr = config.getStr(&a.cfg.join_addr);
            }
        }
        if (std.mem.find(u8, addr, "://")) |i| addr = addr[i + 3 ..];
        addr = std.mem.trimEnd(u8, addr, "/");
        const colon = std.mem.findScalarLast(u8, addr, ':') orelse return a.setHomeError("Põe o endereço com a porta. Ex.: 0.tcp.sa.ngrok.io:12345");
        var host = addr[0..colon];
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch 0;
        if (host.len == 0 or port == 0) return a.setHomeError("Endereço inválido. Ex.: 0.tcp.sa.ngrok.io:12345");
        a.connect(host, port, config.getStr(&a.cfg.join_pass), config.getStr(&a.cfg.admin_token));
    }

    fn createRoom(a: *App) void {
        const port = std.fmt.parseInt(u16, std.mem.sliceTo(&a.port_buf, 0), 10) catch 0;
        if (port == 0) return a.setHomeError("Porta inválida.");
        a.cfg.host_port = port;
        var rn = std.mem.trim(u8, config.getStr(&a.cfg.room_name), " ");
        var tmp: [64]u8 = undefined;
        if (rn.len == 0) rn = std.fmt.bufPrint(&tmp, "Sala do {s}", .{a.myName()}) catch "Sala";
        const pass = config.getStr(&a.cfg.host_pass);
        var rnd: [16]u8 = undefined;
        sync.osRandom(&rnd);
        const token = std.fmt.bufPrintZ(&a.room_admin_token, "{x}", .{&rnd}) catch "";
        a.server = Server.start(.{ .port = port, .password = pass, .room_name = rn, .admin_token = token }) catch {
            a.setHomeError("Não consegui abrir essa porta. Já tem outra coisa usando? Tenta outra.");
            return;
        };
        a.connect("127.0.0.1", port, pass, token);
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
        for (cur[0..n]) |*m| {
            const old = for (a.known[0..a.n_known]) |k| {
                if (k.id == m.id) break k;
            } else null;
            if (old == null) {
                if (m.id != me) joined = true;
                if (a.volumes.get(m.nameSlice())) |pct| cl.setVoiceVolume(m.id, @as(f32, @floatFromInt(pct)) / 100);
            } else if (!old.?.streaming and m.streaming and m.id != me) went_live = true;
        }
        for (a.known[0..a.n_known]) |k| {
            const still = for (cur[0..n]) |*m| {
                if (m.id == k.id) break true;
            } else false;
            if (!still) left = true;
        }
        if (a.known_ready) {
            if (went_live) a.chime(.live) else if (joined) a.chime(.join) else if (left) a.chime(.leave);
        }
        a.known_ready = true;
        a.n_known = n;
        for (cur[0..n], 0..) |*m, i| a.known[i] = .{ .id = m.id, .streaming = m.streaming };
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
            a.toast("Não consegui abrir o microfone: {s}", .{std.mem.sliceTo(&err, 0)}, true);
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
        if (a.mic_wanted and !a.deaf) a.startMic() else a.stopMic();
        if (a.client) |cl| {
            var flags: u8 = 0;
            if (a.mic != null) flags |= proto.voice_mic;
            if (a.deaf) flags |= proto.voice_deaf;
            cl.sendVoiceState(flags);
        }
    }

    fn toggleMic(a: *App) void {
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
        a.toast("Link público precisa de senha: a sala ganhou a senha {s} (já vai no convite).", .{pw}, false);
        return true;
    }

    /// Liga o link público (túnel pelo protocolo do bore).
    fn startTunnel(a: *App) void {
        const s = a.server orelse return;
        if (a.tunnel != null) return;
        if (!s.hasPassword()) {
            // a senha nova só vale pra quem conectar depois: a gente mesmo
            // precisa já estar dentro, senão nosso próprio handshake falha
            const connected = if (a.client) |cl| blk: {
                cl.mutex.lock();
                defer cl.mutex.unlock();
                break :blk cl.status == .connected;
            } else false;
            if (!connected) {
                a.toast("Espera entrar na sala pra criar o link público.", .{}, true);
                return;
            }
            if (a.ensureRoomPassword()) s.setPassword(config.getStr(&a.cfg.host_pass));
        }
        a.tunnel = Tunnel.start(config.getStr(&a.cfg.tunnel_host), s, Server.adoptCallback) catch {
            a.toast("Não consegui abrir o link público.", .{}, true);
            return;
        };
    }

    fn stopTunnel(a: *App) void {
        if (a.tunnel) |t| t.stop();
        a.tunnel = null;
    }

    fn connect(a: *App, host: []const u8, port: u16, pass: []const u8, admin_token: []const u8) void {
        a.home_error_len = 0;
        config.save(&a.cfg);
        a.client = Client.create(.{ .host = host, .port = port, .name = a.myName(), .password = pass, .admin_token = admin_token, .hw_decode = a.cfg.hardware, .wake = wakeUi }) catch {
            a.setHomeError("Falha ao iniciar a conexão.");
            return;
        };
        const s = std.fmt.bufPrint(&a.connect_label, "{s}:{d}", .{ host, port }) catch "";
        a.connect_label_len = s.len;
        a.was_connected = false;
        a.screen = .room;
        a.chat_seen = 0;
        a.chat_unread = 0;
        a.focused = null;
    }

    fn leaveRoom(a: *App) void {
        a.closeModals();
        a.stopMic();
        a.mic_wanted = false;
        a.setDeaf(false);
        a.n_known = 0;
        a.known_ready = false;
        a.stopSharing();
        for (a.views.items) |v| {
            freeViewGpu(v);
            if (a.client) |cl| cl.unwatch(v);
        }
        a.views.clearRetainingCapacity();
        if (a.client) |cl| cl.close();
        a.client = null;
        a.stopTunnel();
        if (a.server) |s| s.stop();
        a.server = null;
        a.screen = .home;
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
            r.n_watch = 0;
            if (a.client) |cl| {
                cl.mutex.lock();
                defer cl.mutex.unlock();
                for (a.views.items) |v| {
                    if (r.n_watch == r.watch.len) break;
                    for (cl.members.items) |*m| {
                        if (m.id != v.owner) continue;
                        const n = m.name_len;
                        @memcpy(r.watch[r.n_watch][0..n], m.name[0..n]);
                        r.watch_len[r.n_watch] = n;
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
            const found = for (cl.members.items) |*m| {
                if (m.streaming and m.id != cl.my_id and std.mem.eql(u8, m.nameSlice(), name)) break m.id;
            } else null;
            if (found) |id| {
                want[n_want] = id;
                n_want += 1;
                // tira da lista
                a.rewatch.n_watch -= 1;
                a.rewatch.watch[i] = a.rewatch.watch[a.rewatch.n_watch];
                a.rewatch.watch_len[i] = a.rewatch.watch_len[a.rewatch.n_watch];
            } else i += 1;
        }
        cl.mutex.unlock();
        for (want[0..n_want]) |id| a.watch(id);
    }

    fn shareSettings(a: *App) sharer_mod.Settings {
        const heights = [_]u32{ 0, 1080, 720, 480 };
        return .{
            .source = if (a.n_sources > 0) a.sources[@intCast(std.math.clamp(a.source_idx, 0, @as(i32, @intCast(a.n_sources)) - 1))].id else 0,
            .fps = @intCast(std.math.clamp(a.cfg.fps, 1, 60)),
            .quality = @intCast(std.math.clamp(a.cfg.quality, 20, 100)),
            .max_height = heights[@intCast(a.cfg.resolution)],
            .cursor = a.cfg.cursor,
            .mode = if (a.cfg.mode == 1) .motion else .screen,
            .hardware = a.cfg.hardware,
            .audio = a.cfg.audio,
        };
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
        a.sharer = Sharer.start(cl, a.shareSettings()) catch {
            a.toast("Não consegui iniciar a transmissão.", .{}, true);
            return;
        };
    }

    fn stopSharing(a: *App) void {
        audio.mixer.self_mute.store(false, .monotonic);
        a.audio_err_shown = false;
        if (a.sharer) |s| {
            gl.delete(&s.preview_tex);
            s.stop();
        }
        a.sharer = null;
        if (a.focused == 0) a.focused = null;
    }

    fn findView(a: *App, owner: u32) ?*View {
        for (a.views.items) |v| if (v.owner == owner) return v;
        return null;
    }

    fn watch(a: *App, owner: u32) void {
        const cl = a.client orelse return;
        if (a.findView(owner) != null) return;
        const v = cl.watch(owner) catch return;
        a.views.append(std.heap.c_allocator, v) catch {};
    }

    fn unwatch(a: *App, owner: u32) void {
        const cl = a.client orelse return;
        for (a.views.items, 0..) |v, i| {
            if (v.owner != owner) continue;
            freeViewGpu(v);
            cl.unwatch(v);
            _ = a.views.orderedRemove(i);
            break;
        }
        if (a.focused == owner) a.focused = null;
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
    fn uploadTextures(a: *App) void {
        for (a.views.items) |v| {
            v.mutex.lock();
            defer v.mutex.unlock();
            if (v.w == 0) continue;
            if (!v.dirty and !v.resized and v.tex != 0) continue;
            if (v.layout != .rgba) {
                // planos YUV: a GPU converte
                const r = &(yuv_renderer orelse continue);
                if (v.tex != 0 and v.tex != v.yuv.out) gl.delete(&v.tex);
                if (r.render(&v.yuv, v.pixels, v.w, v.h, v.layout == .nv12)) {
                    v.tex = v.yuv.out;
                    v.tex_w = v.w;
                    v.tex_h = v.h;
                }
                v.resized = false;
            } else if (v.resized or v.tex == 0 or v.tex == v.yuv.out) {
                if (v.tex == v.yuv.out) v.tex = 0;
                gl.upload(&v.tex, v.pixels, v.w, v.h, gl.RGBA);
                v.tex_w = v.w;
                v.tex_h = v.h;
                v.resized = false;
            } else {
                gl.uploadRect(v.tex, v.pixels, v.w, 0, 0, v.w, v.h, gl.RGBA);
            }
            v.dirty = false;
            // latência de ponta a ponta: captura no transmissor → tela aqui
            if (a.client) |cl| {
                const now = cl.serverNowUs();
                if (now > v.capture_ts and v.capture_ts > 0) {
                    const lat = @as(f32, @floatFromInt(now - v.capture_ts)) / 1000.0;
                    if (lat < 10_000) v.latency_ms = if (v.latency_ms == 0) lat else v.latency_ms * 0.9 + lat * 0.1;
                }
            }
        }
        if (a.sharer) |s| {
            s.mutex.lock();
            defer s.mutex.unlock();
            if (s.preview_new and s.preview.len > 0) {
                gl.upload(&s.preview_tex, s.preview, s.preview_w, s.preview_h, if (s.preview_bgr) gl.BGRA else gl.RGBA);
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
        }
        if (a.auto_watch and st == .connected) {
            var want: [32]u32 = undefined;
            var n_want: usize = 0;
            cl.mutex.lock();
            for (cl.members.items) |m| {
                if (m.streaming and m.id != cl.my_id and n_want < want.len) {
                    want[n_want] = m.id;
                    n_want += 1;
                }
            }
            cl.mutex.unlock();
            for (want[0..n_want]) |id| if (a.findView(id) == null) a.watch(id);
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
                a.setHomeError(if (a.reconnect.attempt > 0) "Não consegui reconectar na sala." else cl.errSlice());
                a.leaveRoom();
                return;
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
            if (!a.audio_err_shown and audio_err[0] != 0) {
                a.audio_err_shown = true;
                a.toast("Transmitindo sem áudio: {s}", .{std.mem.sliceTo(&audio_err, 0)}, true);
            }
            if (sst == .failed) {
                a.toast("A transmissão parou: {s}", .{s.errSlice()}, true);
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
            const owner = a.views.items[i].owner;
            const live = for (cl.members.items) |m| {
                if (m.id == owner) break m.streaming;
            } else false;
            if (!live and n_gone < gone.len) {
                gone[n_gone] = owner;
                n_gone += 1;
            }
        }
        cl.mutex.unlock();
        for (gone[0..n_gone]) |o| a.unwatch(o);
    }

    pub fn frame(a: *App) void {
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
        a.drawToasts(vp.*.Size);
        c.igEnd();
    }

    // ------------------------------------------------------------------ home

    fn drawHome(a: *App, size: c.ImVec2_c) void {
        const d = drawList();
        // fundo com um brilho sutil
        c.ImDrawList_AddRectFilledMultiColor(d, v2(0, 0), size, rgb(0x1E1F22), rgb(0x232436), rgb(0x1E1F22), rgb(0x1A1B1E));

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
            const isz = S(44);
            rectFill(d, p.x, p.y, p.x + isz, p.y + isz, col.blurple, S(12));
            const ts = textSizeF(font_regular, 22, ic.tv);
            drawTextF(d, font_regular, 22, v2(p.x + (isz - ts.x) / 2, p.y + (isz - ts.y) / 2), col.white, ic.tv);
            drawTextF(d, font_bold, 28, v2(p.x + isz + S(14), p.y - S(1)), col.header, "telinha");
            drawTextF(d, font_regular, 14, v2(p.x + isz + S(15), p.y + S(28)), col.muted, "compartilha a tela com a galera");
            c.igDummy(v2(inner, isz + S(26)));
        }

        _ = segmented("tabs", &.{ "Entrar numa sala", "Criar sala" }, &a.home_tab, inner);
        c.igDummy(v2(0, S(14)));

        fieldLabel("SEU NOME");
        _ = textField("##name", "como a galera vai te ver", a.cfg.name[0 .. a.cfg.name.len - 1], inner, false);
        c.igDummy(v2(0, S(8)));

        var go = false;
        if (a.home_tab == 0) {
            fieldLabel("ENDEREÇO DA SALA");
            if (textField("##addr", "ex.: 0.tcp.sa.ngrok.io:12345", &a.cfg.join_addr, inner, false)) go = true;
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
            if (primaryButton("Entrar", v2(inner, S(44)), col.blurple, col.blurple_hover, col.blurple_active)) go = true;
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
            if (primaryButton("Criar sala", v2(inner, S(44)), col.green, rgb(0x1A8B4C), rgb(0x15703D))) go = true;
            c.igDummy(v2(0, S(10)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + inner);
            pushFont(font_regular, 13);
            textColored(col.muted, "Pra galera de fora entrar, abre um túnel TCP pra essa porta (ngrok tcp, bore, playit...) e manda o endereço que ele mostrar.");
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
        }
    }

    fn closeModals(a: *App) void {
        if (a.settings_modal) config.save(&a.cfg); // o que o "Fechar" faria
        a.settings_modal = false;
        a.share_modal = false;
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
        const d = beginOverlay("##connecting", size, rgba(0x1E1F22, 240));
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
        if (secondaryButton("Cancelar", v2(S(120), S(36)))) a.leaveRoom();
        wakeUi(); // mantém a animação
    }

    fn drawDropped(a: *App, cl: *Client, size: c.ImVec2_c) void {
        const d = beginOverlay("##dropped", size, rgba(0x1E1F22, 225));
        defer c.igEnd();
        const t = cl.errSlice();
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
            if (primaryButton("Tentar agora", v2(S(125), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.reconnect.at = 0;
            c.igSameLine(0, S(10));
            if (secondaryButton("Sair", v2(S(125), S(38)))) a.leaveRoom();
            wakeUi(); // mantém a contagem andando
            return;
        }
        c.igSetCursorScreenPos(v2(size.x / 2 - S(130), size.y / 2 + S(30)));
        if (primaryButton("Reconectar", v2(S(125), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
            const was_host = a.server != null;
            a.leaveRoom();
            if (was_host) a.createRoom() else a.joinRoom();
            return;
        }
        c.igSameLine(0, S(10));
        if (secondaryButton("Sair", v2(S(125), S(38)))) a.leaveRoom();
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
        var members: [64]Member = undefined;
        const n_members = @min(cl.members.items.len, members.len);
        @memcpy(members[0..n_members], cl.members.items[0..n_members]);
        cl.mutex.unlock();

        const hh = S(56);
        rectFill(d, origin.x, origin.y + hh - 1, origin.x + size.x, origin.y + hh, rgba(0x000000, 60), 0);
        drawTextF(d, font_bold, 16, v2(origin.x + S(16), origin.y + S(10)), col.header, if (room_name.len > 0) room_name else "telinha");
        const sub = if (a.server) |s| fmtZ("{s} anfitrião · porta {d}", .{ ic.crown, s.port }) else fmtZ("{s}", .{a.connect_label[0..a.connect_label_len]});
        drawTextF(d, font_regular, 12.5, v2(origin.x + S(16), origin.y + S(32)), col.muted, sub);
        // convite
        {
            c.igSetCursorScreenPos(v2(origin.x + size.x - S(84), origin.y + S(8)));
            if (iconButton("##invite", ic.user_plus, S(28), col.muted, col.hover, "Copiar convite da sala")) a.copyInvite();
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
                tooltipText("Conexão criptografada (X25519 + ChaCha20-Poly1305)");
        }
        c.igDummy(v2(size.x, hh));

        // listas
        const list_h = size.y - hh - S(56) - S(50);
        _ = c.igBeginChild_Str("lists", v2(size.x, list_h), 0, 0);
        var n_live: usize = 0;
        for (members[0..n_members]) |m| {
            if (m.streaming) n_live += 1;
        }
        if (n_live > 0) {
            sectionHeader(fmtZ("AO VIVO — {d}", .{n_live}));
            for (members[0..n_members]) |*m| {
                if (!m.streaming) continue;
                a.liveRow(m, my_id, size.x, members[0..n_members]);
            }
        }
        sectionHeader(fmtZ("MEMBROS — {d}", .{n_members}));
        cl.mutex.lock();
        const i_am_admin = cl.is_admin;
        cl.mutex.unlock();
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
    /// compartilhar tela e sair.
    fn drawRoomStrip(a: *App, size: c.ImVec2_c) void {
        const d = drawList();
        const p = c.igGetCursorScreenPos();
        rectFill(d, p.x, p.y, p.x + size.x, p.y + size.y, col.bg_user, 0);
        rectFill(d, p.x + S(8), p.y + size.y - 1, p.x + size.x - S(8), p.y + size.y, rgba(0x000000, 60), 0);
        const live = a.sharer != null;
        const bh = S(34);
        const leave_w = S(40);
        const share_w = size.x - S(16) - leave_w - S(8);
        c.igSetCursorScreenPos(v2(p.x + S(8), p.y + (size.y - bh) / 2));
        const lbl = if (live) fmtZ("{s}  Ao vivo (configurar)##share", .{ic.desktop}) else fmtZ("{s}  Compartilhar tela##share", .{ic.desktop});
        if (if (live)
            primaryButton(lbl, v2(share_w, bh), col.red, rgb(0xC03537), rgb(0xA12828))
        else
            secondaryButton(lbl, v2(share_w, bh))) a.openShareModal();
        c.igSameLine(0, S(8));
        if (primaryButton(fmtZ("{s}##leave", .{ic.leave}), v2(leave_w, bh), rgb(0x3F2A2F), col.red, rgb(0xA12828))) a.leaveRoom();
        if (c.igIsItemHovered(0)) tooltipText(if (a.server != null) "Fechar a sala" else "Sair da sala");
        c.igSetCursorScreenPos(v2(p.x, p.y + size.y));
    }

    fn liveRow(a: *App, m: *const Member, my_id: u32, width: f32, all: []const Member) void {
        const d = drawList();
        const h = S(48);
        c.igPushID_Int(@intCast(m.id + 100000));
        defer c.igPopID();
        c.igSetCursorPosX(S(8));
        const p = c.igGetCursorScreenPos();
        const row_w = width - S(16);
        const clicked = c.igInvisibleButton("live", v2(row_w, h), 0);
        const hovered = c.igIsItemHovered(0);
        const is_me = m.id == my_id;
        const watching = a.findView(m.id) != null;
        if (hovered or watching) rectFill(d, p.x, p.y, p.x + row_w, p.y + h, if (watching) col.selected else col.hover, S(6));
        drawAvatar(d, v2(p.x + S(22), p.y + h / 2), S(15), m.id, m.nameSlice(), true);
        drawTextF(d, font_semibold, 14.5, v2(p.x + S(46), p.y + S(7)), col.text, m.nameSlice());
        var viewers: usize = 0;
        for (all) |*o| {
            if (o.isWatching(m.id)) viewers += 1;
        }
        const info = if (m.audio)
            fmtZ("{d}x{d} · {d} fps · {s} · {s} {d}", .{ m.w, m.h, m.fps, ic.volume, ic.eye, viewers })
        else
            fmtZ("{d}x{d} · {d} fps · {s} {d}", .{ m.w, m.h, m.fps, ic.eye, viewers });
        drawTextF(d, font_regular, 11.5, v2(p.x + S(46), p.y + S(27)), col.muted, info);
        // tooltip: ação + quem está assistindo
        var tip_buf: [320]u8 = undefined;
        var tip_len: usize = 0;
        const action: []const u8 = if (is_me) "É você!" else if (watching) "Parar de assistir" else "Assistir";
        @memcpy(tip_buf[0..action.len], action);
        tip_len = action.len;
        var first = true;
        for (all) |*o| {
            if (!o.isWatching(m.id)) continue;
            const sep: []const u8 = if (first) "\nAssistindo: " else ", ";
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
                if (watching) a.unwatch(m.id) else a.watch(m.id);
            }
        }
        c.igDummy(v2(0, S(2)));
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
        if (hovered) rectFill(d, p.x, p.y, p.x + row_w, p.y + h, col.hover, S(6));
        if (hovered and m.id != my_id) {
            tooltipText(if (i_am_admin) "Clique direito: volume da voz, expulsar" else "Clique direito: volume da voz");
            if (c.igIsItemClicked(1)) {
                a.menu_target = m.id;
                a.open_member_menu = true; // abre fora do PushID do membro
            }
        }
        const speaking = if (m.id == my_id)
            (if (a.mic) |mc| mc.speaking.load(.monotonic) else false)
        else if (a.client) |cl| cl.speaking(m.id) else false;
        drawAvatarSpeaking(d, v2(p.x + S(22), p.y + h / 2), S(15), m.id, m.nameSlice(), m.streaming, speaking);
        const name_col = if (m.id == my_id) col.header else col.text;
        drawTextF(d, font_semibold, 14.5, v2(p.x + S(46), p.y + (h - S(18)) / 2), name_col, m.nameSlice());
        const ns = textSizeF(font_semibold, 14.5, m.nameSlice());
        var tx = p.x + S(50) + ns.x;
        if (m.admin) {
            drawTextF(d, font_regular, 11, v2(tx, p.y + (h - S(13)) / 2), col.yellow, ic.crown);
            tx += S(18);
        }
        if (m.id == my_id) drawTextF(d, font_regular, 12, v2(tx, p.y + (h - S(15)) / 2), col.faint, "(você)");
        var rx = p.x + row_w - S(10);
        if (m.streaming) rx -= liveBadge(d, v2(p.x + row_w - S(58), p.y + (h - S(15)) / 2)) + S(14);
        // microfone desligado / surdo
        const iy = p.y + (h - S(14)) / 2;
        if (m.deaf()) {
            const gs = textSizeF(font_regular, 13, ic.headphones);
            rx -= gs.x;
            drawTextF(d, font_regular, 13, v2(rx, iy), col.red, ic.headphones);
            slash(d, v2(rx - S(2), iy - S(2)), gs.x + S(4));
            rx -= S(8);
        }
        if (!m.micOn()) {
            const gs = textSizeF(font_regular, 13, ic.mic_slash);
            rx -= gs.x;
            drawTextF(d, font_regular, 13, v2(rx, iy), col.faint, ic.mic_slash);
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
        const name = for (members) |*m| {
            if (m.id == a.menu_target) break m.nameSlice();
        } else {
            // a pessoa saiu com o menu aberto
            c.igCloseCurrentPopup();
            return;
        };
        pushFont(font_semibold, 13);
        textColored(col.muted, name);
        popFont();
        c.igDummy(v2(0, S(4)));
        // volume da voz dessa pessoa, só pra mim (0–200%)
        textColored(col.faint, "Volume da voz");
        var pct: i32 = @intFromFloat(@round(cl.voiceVolume(a.menu_target) * 100));
        const before = pct;
        sliderStyled("##vvol", &pct, 0, 200, "%d%%", S(200));
        // salva no arquivo quando solta o slider (não a cada quadro do arrasto)
        var save = c.igIsItemDeactivatedAfterEdit();
        var new_pct: ?i32 = if (pct != before) pct else null;
        const muted = pct == 0;
        c.igDummy(v2(0, S(4)));
        if (c.igSelectable_Bool(if (muted) "Voltar a ouvir" else "Silenciar pra mim", false, 0, v2(S(200), 0))) {
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
        cl.mutex.lock();
        const i_am_admin = cl.is_admin;
        cl.mutex.unlock();
        if (i_am_admin) {
            c.igDummy(v2(0, S(4)));
            c.igSeparator();
            c.igDummy(v2(0, S(4)));
            c.igPushStyleColor_U32(c.ImGuiCol_Text, col.red);
            if (c.igSelectable_Bool(fmtZ("{s}  Expulsar da sala", .{ic.ban}), false, 0, v2(S(200), 0))) cl.kick(a.menu_target);
            c.igPopStyleColor(1);
        }
    }

    fn copyInvite(a: *App) void {
        var buf: [512]u8 = undefined;
        var tun_buf: [300]u8 = undefined;
        const pass = if (a.server != null) config.getStr(&a.cfg.host_pass) else config.getStr(&a.cfg.join_pass);
        const tun_addr: []const u8 = if (a.tunnel) |t| t.address(&tun_buf) else "";
        const addr: []const u8 = if (tun_addr.len > 0)
            tun_addr
        else if (a.server != null)
            std.mem.trim(u8, config.getStr(&a.cfg.public_addr), " ")
        else
            a.connect_label[0..a.connect_label_len];
        if (addr.len == 0) {
            a.toast("Primeiro cria o link público (ou põe o endereço do seu túnel) no card \"Chamando a galera de fora\".", .{}, true);
            return;
        }
        const inv = (if (pass.len > 0)
            std.fmt.bufPrintZ(&buf, "telinha://{s}#{s}", .{ addr, pass })
        else
            std.fmt.bufPrintZ(&buf, "telinha://{s}", .{addr})) catch return;
        c.igSetClipboardText(inv.ptr);
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
        var status_text: []const u8 = "Online";
        var status_col = col.muted;
        if (a.sharer) |s| {
            s.mutex.lock();
            const st = s.state;
            s.mutex.unlock();
            status_text = if (st == .starting) "Iniciando..." else "Ao vivo";
            status_col = if (st == .starting) col.yellow else col.red;
        }
        drawTextF(d, font_regular, 12, v2(p.x + S(50), p.y + S(29)), status_col, status_text);

        const bs = S(34);
        const bx = p.x + size.x - bs * 3 - S(8);
        const by = p.y + (size.y - bs) / 2;
        c.igSetCursorScreenPos(v2(bx, by));
        const mic_on = a.mic != null;
        if (iconButton("##mic", if (mic_on) ic.mic else ic.mic_slash, bs, if (mic_on) col.text else col.red, col.hover, if (mic_on) "Desligar o microfone" else "Ligar o microfone")) a.toggleMic();
        c.igSameLine(0, 0);
        if (iconButton("##deaf", ic.headphones, bs, if (a.deaf) col.red else col.text, col.hover, if (a.deaf) "Voltar a ouvir a sala" else "Parar de ouvir a sala (surdo)")) a.toggleDeaf();
        if (a.deaf) slash(d, v2(bx + bs, by), bs);
        c.igSameLine(0, 0);
        if (iconButton("##gear", ic.gear, bs, col.text, col.hover, "Configurações")) a.openSettings();
    }

    fn openSettings(a: *App) void {
        a.n_mic_names = @intCast(audio.c.audio_list_mics(&a.mic_names, a.mic_names.len));
        a.settings_modal = true;
    }

    fn openShareModal(a: *App) void {
        a.n_sources = @intCast(c.cap_list_sources(&a.sources, a.sources.len));
        if (a.source_idx >= @as(i32, @intCast(a.n_sources))) a.source_idx = 0;
        a.share_modal = true;
    }

    // ------------------------------------------------------------ transmissões

    const Tile = struct {
        owner: u32, // 0 = minha prévia
        tex: u32,
        tw: u32,
        th: u32,
        name: []const u8,
        stats: [:0]const u8,
        loading: bool,
        ring: ?*audio.Ring = null, // áudio dessa transmissão (null = sem áudio / minha prévia)
    };

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
            if (n >= tiles.len - 1) break; // o último é da minha prévia
            // cópia: a thread de rede troca a lista de membros a qualquer hora
            const name = for (cl.members.items) |*m| {
                if (m.id == v.owner) {
                    const nm = m.nameSlice();
                    const k = @min(nm.len, name_bufs[n].len);
                    @memcpy(name_bufs[n][0..k], nm[0..k]);
                    break name_bufs[n][0..k];
                }
            } else "?";
            const st = std.fmt.bufPrintZ(&stat_bufs[n], "{d}x{d} · {d:.0} fps · {d:.0} KB/s · {s}", .{ v.tex_w, v.tex_h, v.fps, v.kbps, latencyText(&lat_bufs[n], v) }) catch "";
            tiles[n] = .{ .owner = v.owner, .tex = v.tex, .tw = v.tex_w, .th = v.tex_h, .name = name, .stats = st, .loading = v.tex == 0, .ring = if (v.audio_registered) &v.audio_ring else null };
            n += 1;
        }
        cl.mutex.unlock();
        if (a.sharer) |s| {
            s.mutex.lock();
            const st = std.fmt.bufPrintZ(&stat_bufs[n], "{d}x{d} · {d:.0} fps · {d} kbit/s{s} · {s} {d:.1} ms · {s}", .{ s.w, s.h, s.fps, s.bitrate_kbps, if (s.congested) " (rede lenta)" else if (s.slow_viewer) " (espectador lento)" else "", s.encoder_name, s.encode_ms, s.backendSlice() }) catch "";
            tiles[n] = .{ .owner = 0, .tex = s.preview_tex, .tw = s.preview_w, .th = s.preview_h, .name = "Você", .stats = st, .loading = s.preview_tex == 0 };
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
                if (iconButton("##side", ic.users, S(34), col.muted, col.hover, "Membros e controles")) {
                    a.cfg.show_chat = false;
                    config.save(&a.cfg);
                }
                tx += S(36);
            }
            drawTextF(d, font_regular, 16, v2(tx, o.y + S(14)), col.muted, ic.tv);
            drawTextF(d, font_bold, 15.5, v2(tx + S(28), o.y + S(14)), col.header, "Transmissões");
            if (n > 0) {
                const cnt = fmtZ("{d} na tela", .{n});
                drawTextF(d, font_regular, 13, v2(tx + S(144), o.y + S(16)), col.muted, cnt);
            }
            c.igSetCursorScreenPos(v2(o.x + size.x - S(44), o.y + S(7)));
            if (!a.chat_visible) {
                if (iconButton("##showchat", ic.comments, S(34), if (a.chat_unread > 0) col.header else col.muted, col.hover, "Mostrar chat")) {
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
                if (t.owner == fo) break i;
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
        if (v.fps < 0.5) return "tela parada";
        return std.fmt.bufPrint(buf, "atraso {d:.0} ms · {s} {d:.1} ms", .{ v.latency_ms, v.decoder_name, v.decode_ms }) catch "";
    }

    fn drawTile(a: *App, t: *const Tile, cell_x: f32, cell_y: f32, cell_w: f32, cell_h: f32, big: bool) void {
        const d = drawList();
        // o quadro tem o formato do vídeo (sem faixas pretas dentro da célula)
        const ar: f32 = if (t.tw > 0 and t.th > 0) @as(f32, @floatFromInt(t.tw)) / @as(f32, @floatFromInt(t.th)) else 16.0 / 9.0;
        var w = cell_w;
        var h = cell_h;
        if (!(a.theater and big)) {
            if (w / h > ar) w = h * ar else h = w / ar;
        }
        const x = cell_x + (cell_w - w) / 2;
        const y = cell_y + (cell_h - h) / 2;
        const round = if (a.theater and big) 0 else S(8);
        c.igPushID_Int(@intCast(t.owner));
        defer c.igPopID();
        c.igSetCursorScreenPos(v2(x, y));
        _ = c.igInvisibleButton("tile", v2(w, h), 0);
        const hovered = c.igIsItemHovered(0);
        const clicked = c.igIsItemClicked(0);
        const dbl = hovered and c.igIsMouseDoubleClicked_Nil(0);

        c.ImDrawList_PushClipRect(d, v2(x, y), v2(x + w, y + h), true);
        defer c.ImDrawList_PopClipRect(d);
        rectFill(d, x, y, x + w, y + h, col.black, round);
        if (t.tex != 0 and t.tw > 0 and t.th > 0) {
            var iw = w;
            var ih = w / ar;
            if (ih > h) {
                ih = h;
                iw = h * ar;
            }
            const ix = x + (w - iw) / 2;
            const iy = y + (h - ih) / 2;
            c.ImDrawList_AddImageRounded(d, texRef(t.tex), v2(ix, iy), v2(ix + iw, iy + ih), v2(0, 0), v2(1, 1), col.white, round, 0);
        } else {
            const msg = "Carregando...";
            const ts = textSizeF(font_semibold, 14, msg);
            drawTextF(d, font_semibold, 14, v2(x + (w - ts.x) / 2, y + (h - ts.y) / 2), col.muted, msg);
        }

        // etiqueta com o nome
        const small = h < S(160);
        const name_size: f32 = if (small) 12.5 else 14;
        const ns = textSizeF(font_semibold, name_size, t.name);
        const lx = x + S(10);
        const ly = y + h - ns.y - S(16);
        rectFill(d, lx, ly, lx + ns.x + S(70), ly + ns.y + S(8), col.overlay, S(6));
        const bw = liveBadge(d, v2(lx + S(6), ly + S(4) + (ns.y - S(14)) / 2));
        drawTextF(d, font_semibold, name_size, v2(lx + S(12) + bw, ly + S(4)), col.white, t.name);

        if ((hovered or a.cfg.stats_always) and !small) {
            const ss = textSizeF(font_regular, 12, t.stats);
            rectFill(d, x + S(10), y + S(10), x + S(22) + ss.x, y + S(16) + ss.y, col.overlay, S(6));
            drawTextF(d, font_regular, 12, v2(x + S(16), y + S(13)), col.text, t.stats);
        }
        if (hovered) {
            // botões no canto
            const bs = S(32);
            var bx = x + w - bs - S(8);
            const by = y + S(8);
            const save = c.igGetCursorScreenPos();
            if (t.owner != 0) {
                c.igSetCursorScreenPos(v2(bx, by));
                rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
                if (iconButton("##close", ic.xmark, bs, col.white, rgba(0xED4245, 200), "Parar de assistir")) {
                    a.unwatch(t.owner);
                    return;
                }
                bx -= bs + S(6);
            }
            c.igSetCursorScreenPos(v2(bx, by));
            rectFill(d, bx, by, bx + bs, by + bs, col.overlay, S(6));
            const focused = a.focused != null and a.focused.? == t.owner;
            if (iconButton("##focus", if (focused) ic.compress else ic.expand, bs, col.white, rgba(0x5865F2, 200), if (focused) "Voltar pra grade" else "Destacar (duplo clique: tela cheia)")) {
                a.focused = if (focused) null else t.owner;
            } else if (dbl) {
                a.focused = t.owner;
                a.theater = !a.theater;
                if (a.theater != a.fullscreen) a.toggleFullscreen();
            } else if (clicked and !big) {
                a.focused = t.owner;
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
                if (iconButton("##mute", if (rg_muted) ic.volume_off else ic.volume, vh, if (rg_muted) col.red else col.white, rgba(0xFFFFFF, 30), if (rg_muted) "Ativar som" else "Silenciar")) rg.setMuted(!rg_muted);
                c.igSameLine(0, S(4));
                c.igSetCursorScreenPos(v2(vx + vh + S(6), vy + S(7)));
                c.igSetNextItemWidth(vw - vh - S(14));
                c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, rgba(0xFFFFFF, 30));
                c.igPushStyleColor_U32(c.ImGuiCol_FrameBgHovered, rgba(0xFFFFFF, 45));
                c.igPushStyleColor_U32(c.ImGuiCol_FrameBgActive, rgba(0xFFFFFF, 45));
                c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(4), S(2)));
                var vol_pct: f32 = rg.getVolume() * 100;
                if (c.igSliderFloat("##vol", &vol_pct, 0, 200, "%.0f%%", c.ImGuiSliderFlags_AlwaysClamp)) rg.setVolume(vol_pct / 100);
                c.igPopStyleVar(1);
                c.igPopStyleColor(3);
            }
            c.igSetCursorScreenPos(save);
            c.igDummy(v2(0, 0));
            c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), rgba(0xFFFFFF, 40), round, S(1.5), 0);
        }
        // contorno verde: quem transmite está falando (voz), ou a transmissão
        // está tocando som (mais fraco)
        const talking = if (t.owner == 0)
            (if (a.mic) |m| m.speaking.load(.monotonic) else false)
        else if (a.client) |cl| cl.speaking(t.owner) else false;
        const ring_level = if (t.ring) |rg| rg.takeLevel() else 0; // decai um pouco a cada quadro
        if (talking) {
            c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), col.green, round, S(3), 0);
        } else if (t.ring) |rg| {
            if (!rg.isMuted() and ring_level > 0.02) c.ImDrawList_AddRect(d, v2(x, y), v2(x + w, y + h), rgba(0x23A55A, 160), round, S(2), 0);
        }
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

        const title = if (n_live > 0) "Tem gente ao vivo!" else "Ninguém está transmitindo";
        const ts = textSizeF(font_bold, 20, title);
        drawTextF(d, font_bold, 20, v2(cx - ts.x / 2, y), col.header, title);
        y += ts.y + S(8);
        const sub = if (n_live > 0) "Escolhe quem assistir. Dá pra assistir várias telas ao mesmo tempo." else "Clica em Compartilhar tela pra começar, ou espera alguém da sala.";
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
            const lbl = fmtZ("{s}   Compartilhar tela", .{ic.desktop});
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
        if (st == null) {
            drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, "Um endereço público pra essa sala, sem instalar nada.");
            drawTextF(d, font_regular, 13, v2(x + pad, yy + S(18)), col.muted, fmtZ("Passa pelo {s}; tudo continua cifrado de ponta a ponta.", .{config.getStr(&a.cfg.tunnel_host)}));
            c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
            if (primaryButton(fmtZ("{s}  Criar link público", .{ic.globe}), v2(S(200), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.startTunnel();
        } else switch (st.?.state) {
            .connecting => {
                drawTextF(d, font_semibold, 14, v2(x + pad, yy + S(4)), col.text, fmtZ("Abrindo o link público no {s}…", .{a.tunnel.?.hostSlice()}));
                drawTextF(d, font_regular, 13, v2(x + pad, yy + S(26)), col.muted, "Leva só alguns segundos.");
                c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
                if (secondaryButton("Cancelar##tunel", v2(S(110), S(38)))) a.stopTunnel();
            },
            .ready => {
                var abuf: [300]u8 = undefined;
                const addr = a.tunnel.?.address(&abuf);
                drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, "Link público no ar. Manda o convite pra galera:");
                rectFill(d, x + pad, yy + S(22), x + w - pad, yy + S(52), col.input, S(5));
                drawTextF(d, font_regular, 13, v2(x + pad + S(10), yy + S(29)), col.green, ic.circle);
                drawTextF(d, font_semibold, 14, v2(x + pad + S(30), yy + S(28)), col.header, fmtZ("{s}", .{addr}));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(62)));
                if (primaryButton(fmtZ("{s}  Copiar convite##tunel", .{ic.user_plus}), v2(S(170), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) a.copyInvite();
                c.igSameLine(0, S(10));
                if (secondaryButton(fmtZ("{s}  Desligar", .{ic.power}), v2(S(120), S(38)))) a.stopTunnel();
            },
            .failed => {
                drawTextF(d, font_semibold, 14, v2(x + pad, yy + S(4)), col.red, fmtZ("{s}  Não deu pra abrir o link público", .{ic.warn}));
                drawTextF(d, font_regular, 13, v2(x + pad, yy + S(26)), col.muted, fmtZ("{s}", .{st.?.err}));
                c.igSetCursorScreenPos(v2(x + pad, yy + S(48)));
                if (primaryButton(fmtZ("{s}  Tentar de novo", .{ic.rotate}), v2(S(170), S(38)), col.blurple, col.blurple_hover, col.blurple_active)) {
                    a.stopTunnel();
                    a.startTunnel();
                }
                c.igSameLine(0, S(10));
                if (secondaryButton("Fechar##tunel", v2(S(100), S(38)))) a.stopTunnel();
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
            if (iconButton("##cp", ic.copy, S(29), col.muted, col.hover, "Copiar")) c.igSetClipboardText(cmd.ptr);
            c.igPopID();
        }
        yy += S(100);
        drawTextF(d, font_regular, 13, v2(x + pad, yy), col.muted, "Cola aqui o endereço que o túnel mostrou e copia o convite:");
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

    fn drawChat(a: *App, cl: *Client, size: c.ImVec2_c) void {
        c.igPushStyleColor_U32(c.ImGuiCol_ChildBg, col.bg_side);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(0, 0));
        _ = c.igBeginChild_Str("chat", size, 0, c.ImGuiWindowFlags_NoScrollbar);
        const d = drawList();
        const o = c.igGetCursorScreenPos();
        const hh = S(48);
        rectFill(d, o.x, o.y + hh - 1, o.x + size.x, o.y + hh, rgba(0x000000, 60), 0);
        drawTextF(d, font_regular, 16, v2(o.x + S(16), o.y + S(14)), col.muted, ic.comments);
        drawTextF(d, font_bold, 15.5, v2(o.x + S(44), o.y + S(14)), col.header, "Chat");
        c.igSetCursorScreenPos(v2(o.x + size.x - S(44), o.y + S(7)));
        if (iconButton("##hidechat", ic.xmark, S(34), col.muted, col.hover, "Esconder chat")) {
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
        var last_from: u32 = 0xffffffff;
        for (cl.chat.items) |*line| {
            const text = line.text;
            if (line.from == 0) {
                c.igDummy(v2(0, S(6)));
                const p = c.igGetCursorScreenPos();
                const dl = drawList();
                drawTextF(dl, font_regular, 12, v2(p.x + S(4), p.y + S(2)), col.green, ic.arrow_right);
                c.igSetCursorScreenPos(v2(p.x + S(24), p.y));
                c.igPushTextWrapPos(0);
                pushFont(font_regular, 13.5);
                textColored(col.muted, text);
                popFont();
                c.igPopTextWrapPos();
                last_from = 0;
                continue;
            }
            if (line.from != last_from) {
                c.igDummy(v2(0, S(12)));
                const p = c.igGetCursorScreenPos();
                const dl = drawList();
                drawAvatar(dl, v2(p.x + S(18), p.y + S(18)), S(18), line.from, line.nameSlice(), false);
                drawTextF(dl, font_semibold, 14.5, v2(p.x + S(48), p.y), avatarColor(line.from), line.nameSlice());
                const ns = textSizeF(font_semibold, 14.5, line.nameSlice());
                drawTextF(dl, font_regular, 11.5, v2(p.x + S(54) + ns.x, p.y + S(3)), col.faint, fmtZ("{d:0>2}:{d:0>2}", .{ line.hour, line.minute }));
                c.igSetCursorScreenPos(v2(p.x + S(48), p.y + S(20)));
            } else {
                c.igSetCursorPosX(c.igGetCursorPosX() + S(48));
            }
            c.igPushTextWrapPos(0);
            pushFont(font_regular, 14.5);
            textColored(col.text, text);
            popFont();
            c.igPopTextWrapPos();
            last_from = line.from;
        }
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
        c.igSetNextItemWidth(bw - S(46));
        if (a.focus_chat) {
            c.igSetKeyboardFocusHere(0);
            a.focus_chat = false;
        }
        // a caixa continua ativa depois do Enter (io.ConfigInputTextEnterKeepActive):
        // sem buraco de foco, nenhuma letra digitada logo depois se perde. O
        // callback guarda a mensagem e esvazia a caixa no mesmo quadro do Enter.
        a.chat_sent_len = 0;
        const enter = c.igInputTextWithHint("##chatin", "Mandar mensagem na sala", &a.chat_input, a.chat_input.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackAlways, chatCallback, a);
        c.igPopStyleVar(1);
        c.igPopStyleColor(3);
        c.igSameLine(0, 0);
        c.igSetCursorScreenPos(v2(bx + bw - S(40), by + S(5)));
        const send_click = iconButton("##send", ic.send, S(34), col.muted, col.hover, "Enviar");
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
        _ = c.igOpenPopup_Str("Compartilhar tela", 0);
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(S(480), 0), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10));
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal("Compartilhar tela", null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const w = S(432);

        pushFont(font_bold, 20);
        textColored(col.header, "Compartilhar tela");
        popFont();
        pushFont(font_regular, 13.5);
        textColored(col.muted, "Todo mundo na sala vai poder assistir.");
        popFont();
        c.igDummy(v2(0, S(14)));

        fieldLabel("O QUE MOSTRAR");
        c.igSetNextItemWidth(w);
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(9)));
        const preview: [*:0]const u8 = if (a.n_sources > 0) @ptrCast(&a.sources[@intCast(a.source_idx)].name) else "Tela";
        if (c.igBeginCombo("##src", preview, 0)) {
            for (a.sources[0..a.n_sources], 0..) |*s, i| {
                if (c.igSelectable_Bool(@ptrCast(&s.name), a.source_idx == @as(i32, @intCast(i)), 0, v2(0, 0))) a.source_idx = @intCast(i);
            }
            c.igEndCombo();
        }
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
        c.igDummy(v2(0, S(12)));

        fieldLabel("TIPO DE CONTEÚDO");
        _ = segmented("mode", &.{ "Tela e texto", "Jogo e vídeo" }, &a.cfg.mode, w);
        c.igDummy(v2(0, S(12)));

        fieldLabel("RESOLUÇÃO");
        _ = segmented("res", &.{ "Original", "1080p", "720p", "480p" }, &a.cfg.resolution, w);
        c.igDummy(v2(0, S(12)));

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
        c.igDummy(v2(0, S(12)));

        fieldLabel("QUALIDADE");
        const qname = if (a.cfg.quality < 40) "economia" else if (a.cfg.quality < 65) "equilibrada" else if (a.cfg.quality < 85) "alta" else "máxima";
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
        textColored(col.faint, "A taxa cai sozinha se a internet de alguém não aguentar, e volta a subir quando melhora.");
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(10)));

        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        c.igPushStyleColor_U32(c.ImGuiCol_CheckMark, col.white);
        _ = c.igCheckbox("Mostrar o cursor do mouse", &a.cfg.cursor);
        _ = c.igCheckbox("Compartilhar o áudio do computador", &a.cfg.audio);
        _ = c.igCheckbox("Usar a placa de vídeo (NVIDIA NVENC/NVDEC), se tiver", &a.cfg.hardware);

        c.igPopStyleColor(2);

        if (!sync.is_windows and a.n_sources > 0 and std.mem.startsWith(u8, std.mem.sliceTo(&a.sources[0].name, 0), "Escolher")) {
            c.igDummy(v2(0, S(8)));
            c.igPushTextWrapPos(c.igGetCursorPosX() + w);
            pushFont(font_regular, 12.5);
            textColored(col.muted, "No Wayland o sistema abre um seletor pra escolher a tela ou janela. Na próxima vez ele lembra a escolha.");
            popFont();
            c.igPopTextWrapPos();
        }

        c.igDummy(v2(0, S(18)));
        const bw = (w - S(10)) / 2;
        if (secondaryButton("Cancelar", v2(bw, S(42))) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            a.share_modal = false;
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, S(10));
        if (a.sharer != null) {
            const hb = (bw - S(10)) / 2;
            if (primaryButton("Parar", v2(hb, S(42)), col.red, col.red_hover, col.red_hover)) {
                a.share_modal = false;
                c.igCloseCurrentPopup();
                a.stopSharing();
            }
            c.igSameLine(0, S(10));
            if (primaryButton("Aplicar", v2(hb, S(42)), col.blurple, col.blurple_hover, col.blurple_active)) {
                a.share_modal = false;
                c.igCloseCurrentPopup();
                a.startSharing();
            }
        } else {
            const go = fmtZ("{s}   Ao vivo", .{ic.circle});
            if (primaryButton(go, v2(bw, S(42)), col.blurple, col.blurple_hover, col.blurple_active)) {
                a.share_modal = false;
                c.igCloseCurrentPopup();
                a.startSharing();
            }
        }
    }

    // ------------------------------------------------------- configurações

    fn drawSettingsModal(a: *App) void {
        _ = c.igOpenPopup_Str("Configurações", 0);
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(v2(vp.*.Pos.x + vp.*.Size.x / 2, vp.*.Pos.y + vp.*.Size.y / 2), c.ImGuiCond_Always, v2(0.5, 0.5));
        c.igSetNextWindowSize(v2(S(460), 0), c.ImGuiCond_Always);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, v2(S(24), S(22)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, S(10));
        c.igPushStyleColor_U32(c.ImGuiCol_PopupBg, col.bg_main);
        c.igPushStyleColor_U32(c.ImGuiCol_ModalWindowDimBg, rgba(0x000000, 170));
        defer {
            c.igPopStyleColor(2);
            c.igPopStyleVar(2);
        }
        if (!c.igBeginPopupModal("Configurações", null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const w = S(412);
        pushFont(font_bold, 20);
        textColored(col.header, "Configurações");
        popFont();
        c.igDummy(v2(0, S(12)));

        fieldLabel("SEU NOME (vale na próxima vez que entrar numa sala)");
        _ = textField("##sname", "como a galera vai te ver", a.cfg.name[0 .. a.cfg.name.len - 1], w, false);
        c.igDummy(v2(0, S(10)));
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        _ = c.igCheckbox("Mostrar estatísticas sempre (não só com o mouse em cima)", &a.cfg.stats_always);
        c.igPopStyleColor(1);
        c.igDummy(v2(0, S(16)));

        // ---- voz
        pushFont(font_bold, 15);
        textColored(col.header, fmtZ("{s}  Voz", .{ic.mic}));
        popFont();
        c.igDummy(v2(0, S(6)));
        fieldLabel("MICROFONE");
        {
            const cur = config.getStr(&a.cfg.mic_device);
            const preview = if (cur.len == 0) "Padrão do sistema" else cur;
            c.igSetNextItemWidth(w);
            c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, v2(S(10), S(8)));
            var changed = false;
            if (c.igBeginCombo("##mic", fmtZ("{s}", .{preview}).ptr, 0)) {
                if (c.igSelectable_Bool("Padrão do sistema", cur.len == 0, 0, v2(0, 0))) {
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
            textColored(col.faint, "Liga o microfone pra ver o medidor.");
            popFont();
        }
        c.igPushStyleColor_U32(c.ImGuiCol_FrameBg, col.input);
        var reopen = c.igCheckbox("Supressão de ruído (tira ventilador, teclado, chiado)", &a.cfg.noise_suppression);
        reopen = c.igCheckbox("Cancelamento de eco (pra quem usa caixa de som em vez de fone)", &a.cfg.echo_cancellation) or reopen;
        _ = c.igCheckbox("Entrar na sala com o microfone ligado", &a.cfg.mic_on_join);
        _ = c.igCheckbox("Sons de aviso (alguém entrou/saiu, ao vivo, microfone)", &a.cfg.sounds);
        c.igPopStyleColor(1);
        if (reopen and a.mic != null) {
            a.stopMic();
            a.applyVoice();
        }
        c.igDummy(v2(0, S(16)));

        c.igPushTextWrapPos(c.igGetCursorPosX() + w);
        pushFont(font_regular, 12.5);
        textColored(col.faint, fmtZ("telinha {s} · protocolo v{d} · vídeo H.264 (NVENC/NVDEC ou openh264) · voz Opus + RNNoise + SpeexDSP · criptografia X25519 + ChaCha20-Poly1305", .{ version_string, proto.version }));
        textColored(col.faint, "Atalhos: Ctrl+M microfone · Ctrl+D surdo · F11 tela cheia · duplo clique = modo cinema · Esc sai");
        popFont();
        c.igPopTextWrapPos();
        c.igDummy(v2(0, S(14)));
        if (primaryButton("Fechar", v2(w, S(40)), col.blurple, col.blurple_hover, col.blurple_active) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            config.save(&a.cfg);
            a.settings_modal = false;
            c.igCloseCurrentPopup();
        }
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
        wakeUi();
    }
};

// ---------------------------------------------------------------------------

/// Acorda o loop principal (chamado de qualquer thread).
pub fn wakeUi() void {
    c.glfwPostEmptyEvent();
}

/// Tema base do ImGui.
pub fn applyStyle() void {
    const style = c.igGetStyle();
    c.igStyleColorsDark(style);
    style.*.WindowRounding = 0;
    style.*.ChildRounding = 0;
    style.*.FrameRounding = 5;
    style.*.PopupRounding = 8;
    style.*.GrabRounding = 4;
    style.*.ScrollbarRounding = 8;
    style.*.ScrollbarSize = 8;
    style.*.FrameBorderSize = 0;
    style.*.WindowBorderSize = 0;
    style.*.PopupBorderSize = 0;
    style.*.ItemSpacing = v2(8, 6);
    style.*.GrabMinSize = 14;
    ImGuiStyle_ScaleAllSizes(style, scale);
    const colors: *[c.ImGuiCol_COUNT]c.ImVec4_c = @ptrCast(&style.*.Colors);
    const f = struct {
        fn v(comptime hex: u24, a: f32) c.ImVec4_c {
            return .{ .x = @as(f32, @floatFromInt((hex >> 16) & 0xff)) / 255.0, .y = @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255.0, .z = @as(f32, @floatFromInt(hex & 0xff)) / 255.0, .w = a };
        }
    }.v;
    colors[c.ImGuiCol_Text] = f(0xDBDEE1, 1);
    colors[c.ImGuiCol_TextDisabled] = f(0x949BA4, 1);
    colors[c.ImGuiCol_WindowBg] = f(0x313338, 1);
    colors[c.ImGuiCol_ChildBg] = f(0x313338, 0);
    colors[c.ImGuiCol_PopupBg] = f(0x111214, 1);
    colors[c.ImGuiCol_FrameBg] = f(0x1E1F22, 1);
    colors[c.ImGuiCol_FrameBgHovered] = f(0x232428, 1);
    colors[c.ImGuiCol_FrameBgActive] = f(0x232428, 1);
    colors[c.ImGuiCol_Button] = f(0x4E5058, 1);
    colors[c.ImGuiCol_ButtonHovered] = f(0x6D6F78, 1);
    colors[c.ImGuiCol_ButtonActive] = f(0x80848E, 1);
    colors[c.ImGuiCol_Header] = f(0x404249, 1);
    colors[c.ImGuiCol_HeaderHovered] = f(0x35373C, 1);
    colors[c.ImGuiCol_HeaderActive] = f(0x404249, 1);
    colors[c.ImGuiCol_ScrollbarBg] = f(0x2B2D31, 0);
    colors[c.ImGuiCol_ScrollbarGrab] = f(0x1A1B1E, 1);
    colors[c.ImGuiCol_ScrollbarGrabHovered] = f(0x111214, 1);
    colors[c.ImGuiCol_ScrollbarGrabActive] = f(0x111214, 1);
    colors[c.ImGuiCol_CheckMark] = f(0xFFFFFF, 1);
    colors[c.ImGuiCol_SliderGrab] = f(0x5865F2, 1);
    colors[c.ImGuiCol_SliderGrabActive] = f(0x4752C4, 1);
    colors[c.ImGuiCol_TextSelectedBg] = f(0x5865F2, 0.45);
    colors[c.ImGuiCol_Border] = f(0x000000, 0);
    colors[c.ImGuiCol_NavCursor] = f(0x5865F2, 1);
}

const ImGuiStyle_ScaleAllSizes = c.ImGuiStyle_ScaleAllSizes;
