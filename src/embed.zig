//! Cartão (embed) de uma mensagem do chat: o que um bot manda pra aparecer
//! como um cartão com barra de cor, capa, título, campos, progresso e
//! botões. Chega como um bloco no fim do chat (ver docs/PROTOCOL.md
//! "Cartões"); o servidor não interpreta, só repassa. Aqui ele vira um Embed
//! com os textos apontando pra uma cópia própria dos bytes.
const std = @import("std");
const proto = @import("proto.zig");

const gpa = std.heap.c_allocator;

pub const flag_thumb: u8 = 1; // a imagem da mensagem vai como capa do cartão
pub const flag_progress: u8 = 2; // tem barra de progresso
pub const flag_big_image: u8 = 4; // a imagem da mensagem vai grande, embaixo

pub const Style = enum(u8) { neutral = 0, primary = 1, danger = 2, success = 3, _ };

/// Ícones dos botões (o mesmo número no app, na página e no SDK).
pub const Icon = enum(u8) {
    none = 0,
    play = 1,
    pause = 2,
    next = 3,
    previous = 4,
    stop = 5,
    shuffle = 6,
    repeat = 7,
    volume_up = 8,
    volume_down = 9,
    list = 10,
    heart = 11,
    music = 12,
    radio = 13,
    search = 14,
    plus = 15,
    check = 16,
    close = 17,
    link = 18,
    join = 19,
    trash = 20,
    star = 21,
    dice = 22,
    _,
};

pub const Field = struct { name: []const u8, value: []const u8, inline_: bool };
pub const Button = struct { style: Style, icon: Icon, label: []const u8, disabled: bool };

pub const Embed = struct {
    raw: []u8, // a cópia dos bytes (os textos apontam pra cá)
    color: u32, // 0xRRGGBB; 0 = a cor de destaque do tema
    flags: u8,
    kicker: []const u8, // linha pequena em cima do título ("TOCANDO AGORA")
    title: []const u8,
    url: []const u8,
    description: []const u8, // markdown
    footer: []const u8,
    elapsed_ms: u32 = 0,
    total_ms: u32 = 0, // 0 = ao vivo / sem duração
    paused: bool = false,
    fields: [proto.embed_max_fields]Field = undefined,
    n_fields: u8 = 0,
    buttons: [proto.embed_max_buttons]Button = undefined,
    n_buttons: u8 = 0,
    received_ms: u64 = 0, // quando chegou (a barra de progresso anda a partir daqui)

    pub fn deinit(e: *Embed) void {
        gpa.free(e.raw);
        gpa.destroy(e);
    }

    pub fn hasThumb(e: *const Embed) bool {
        return e.flags & flag_thumb != 0;
    }
    pub fn hasProgress(e: *const Embed) bool {
        return e.flags & flag_progress != 0;
    }
    pub fn fieldSlice(e: *const Embed) []const Field {
        return e.fields[0..e.n_fields];
    }
    pub fn buttonSlice(e: *const Embed) []const Button {
        return e.buttons[0..e.n_buttons];
    }

    /// Onde a música (ou o que for) está agora, em ms: anda sozinha enquanto
    /// não está pausada (o bot só edita a mensagem quando o estado muda).
    pub fn positionMs(e: *const Embed, now_ms: u64) u32 {
        if (e.paused) return e.elapsed_ms;
        const p = @as(u64, e.elapsed_ms) + (now_ms -| e.received_ms);
        if (e.total_ms != 0) return @intCast(@min(p, e.total_ms));
        return @intCast(@min(p, std.math.maxInt(u32)));
    }
};

/// Lê o cartão (a versão tem que ser a nossa). A cópia é do Embed.
pub fn parse(bytes: []const u8, now_ms: u64) !*Embed {
    if (bytes.len == 0 or bytes.len > proto.embed_max or bytes[0] != proto.embed_version) return error.BadEmbed;
    const e = try gpa.create(Embed);
    errdefer gpa.destroy(e);
    const raw = try gpa.dupe(u8, bytes);
    errdefer gpa.free(raw);
    var r: proto.Reader = .{ .data = raw[1..] };
    e.* = .{
        .raw = raw,
        .color = try r.u32_(),
        .flags = try r.u8_(),
        .kicker = try r.str(),
        .title = try r.str(),
        .url = try r.str(),
        .description = try r.str(),
        .footer = try r.str(),
        .received_ms = now_ms,
    };
    if (e.flags & flag_progress != 0) {
        e.elapsed_ms = try r.u32_();
        e.total_ms = try r.u32_();
        e.paused = (try r.u8_()) != 0;
    }
    const nf = try r.u8_();
    for (0..nf) |_| {
        const f: Field = .{ .name = try r.str(), .value = try r.str(), .inline_ = (try r.u8_()) != 0 };
        if (e.n_fields < e.fields.len) {
            e.fields[e.n_fields] = f;
            e.n_fields += 1;
        }
    }
    const nb = try r.u8_();
    for (0..nb) |_| {
        const style: Style = @enumFromInt(try r.u8_());
        const icon: Icon = @enumFromInt(try r.u8_());
        const label = try r.str();
        const disabled = (r.u8_() catch 0) & 1 != 0;
        if (e.n_buttons < e.buttons.len) {
            e.buttons[e.n_buttons] = .{ .style = style, .icon = icon, .label = label, .disabled = disabled };
            e.n_buttons += 1;
        }
    }
    // só link http(s) no título (nada de file:// ou javascript:)
    if (!std.mem.startsWith(u8, e.url, "https://") and !std.mem.startsWith(u8, e.url, "http://")) e.url = "";
    return e;
}

/// Monta um cartão (testes e quem quiser mandar um do Zig).
pub const Builder = struct {
    b: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *Builder) void {
        w.b.deinit(gpa);
    }
    fn int(w: *Builder, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try w.b.appendSlice(gpa, &tmp);
    }
    pub fn u8_(w: *Builder, v: u8) !void {
        try w.b.append(gpa, v);
    }
    pub fn u32_(w: *Builder, v: u32) !void {
        try w.int(u32, v);
    }
    pub fn str(w: *Builder, s: []const u8) !void {
        try w.int(u16, @intCast(s.len));
        try w.b.appendSlice(gpa, s);
    }
};

test "embed: lê o cartão inteiro, ignora o que passa do limite, só link http(s)" {
    var w: Builder = .{};
    defer w.deinit();
    try w.u8_(proto.embed_version);
    try w.u32_(0xd946ef);
    try w.u8_(flag_thumb | flag_progress);
    try w.str("TOCANDO AGORA");
    try w.str("Popular Monster");
    try w.str("javascript:alert(1)");
    try w.str("**Falling In Reverse**");
    try w.str("pedido por Ana");
    try w.u32_(30_000);
    try w.u32_(232_000);
    try w.u8_(0);
    try w.u8_(2);
    try w.str("Fila");
    try w.str("3");
    try w.u8_(1);
    try w.str("Volume");
    try w.str("60%");
    try w.u8_(1);
    try w.u8_(7); // botões: 7, só os 5 primeiros ficam
    for (0..7) |i| {
        try w.u8_(1);
        try w.u8_(@intCast(i + 1));
        try w.str("b");
        try w.u8_(0);
    }
    const e = try parse(w.b.items, 1000);
    defer e.deinit();
    try std.testing.expectEqualStrings("Popular Monster", e.title);
    try std.testing.expectEqualStrings("", e.url); // javascript: fora
    try std.testing.expect(e.hasThumb() and e.hasProgress());
    try std.testing.expectEqual(@as(u8, 2), e.n_fields);
    try std.testing.expectEqual(@as(u8, proto.embed_max_buttons), e.n_buttons);
    try std.testing.expectEqual(Icon.play, e.buttons[0].icon);
    // a barra anda sozinha; pausada, fica
    try std.testing.expectEqual(@as(u32, 32_000), e.positionMs(3000));
    e.paused = true;
    try std.testing.expectEqual(@as(u32, 30_000), e.positionMs(9000));
    // versão desconhecida ou cortado no meio: nada
    var bad = try gpa.dupe(u8, w.b.items);
    defer gpa.free(bad);
    bad[0] = 99;
    try std.testing.expectError(error.BadEmbed, parse(bad, 0));
    try std.testing.expectError(error.BadMessage, parse(w.b.items[0..20], 0));
}
