//! Atalhos globais (valem com o jogo em foco, como o apertar pra falar; ver
//! c/ptt.c): uma thread lê as teclas a cada 50 ms e marca quais foram
//! apertadas; a interface pega (`take`) e executa a ação. Só existe com algum
//! atalho configurado. Um atalho = tecla (ou botão do mouse) + modificadores
//! (Ctrl/Shift/Alt), que têm que estar exatamente assim apertados.
const std = @import("std");
const sync = @import("sync.zig");
const config = @import("config.zig");
const c = @cImport(@cInclude("ptt.h"));

pub const max = config.n_hotkeys;

var gen: std.atomic.Value(u32) = .init(0);
/// Cada atalho num inteiro só (trocado atomicamente): tecla (bits 0-15, já
/// no formato que o sistema lê de fora), botão (bits 16-23, 0xff = tecla),
/// modificadores (bits 24-26) e, se a tecla é ela mesma um modificador, qual
/// (bits 27-29: esse não conta na comparação, senão Ctrl sozinho nunca dispara).
var packed_bind: [max]std.atomic.Value(u32) = [_]std.atomic.Value(u32){.init(unpack_none)} ** max;
const unpack_none: u32 = 0xff << 16;
/// Atalhos ligados (o de ligar/desligar vale sempre).
pub var enabled: std.atomic.Value(bool) = .init(true);
/// Apertou (a interface pega e limpa com `take`).
var pressed: [max]std.atomic.Value(bool) = [_]std.atomic.Value(bool){.init(false)} ** max;
pub var on_press: ?*const fn () void = null;

pub const Binding = struct { key: i32 = 0, mouse: i32 = -1, mods: u8 = 0, own: u8 = 0 };

fn pack(b: Binding) u32 {
    const key: u32 = @intCast(std.math.clamp(b.key, 0, 0xffff));
    const mouse: u32 = if (b.mouse < 0) 0xff else @intCast(@min(b.mouse, 0xfe));
    return key | (mouse << 16) | (@as(u32, b.mods & 7) << 24) | (@as(u32, b.own & 7) << 27);
}

fn unpack(v: u32) Binding {
    const mouse: u32 = (v >> 16) & 0xff;
    return .{ .key = @intCast(v & 0xffff), .mouse = if (mouse == 0xff) -1 else @intCast(mouse), .mods = @intCast((v >> 24) & 7), .own = @intCast((v >> 27) & 7) };
}

/// `key`: scancode (Windows) / keycode do X11 (0 = nenhuma); `mouse`: botão
/// (-1 = é tecla); `own`: o modificador que a própria tecla é (0 = nenhum).
/// Vale a partir da próxima leitura.
pub fn configure(idx: usize, key: i32, mouse: i32, mods: u8, own: u8) void {
    if (idx >= max) return;
    packed_bind[idx].store(pack(.{ .key = key, .mouse = mouse, .mods = mods, .own = own }), .release);
    restart();
}

pub fn setEnabled(on: bool) void {
    enabled.store(on, .release);
}

/// O atalho `idx` foi apertado desde a última vez? (limpa)
pub fn take(idx: usize) bool {
    if (idx >= max) return false;
    return pressed[idx].swap(false, .acq_rel);
}

fn active(b: Binding) bool {
    // botão que o sistema não deixa ler de fora (laterais no X11): sem thread à toa
    if (b.mouse >= 0) return c.ptt_global_button_supported(b.mouse) != 0;
    return b.key > 0;
}

fn restart() void {
    const g = gen.fetchAdd(1, .acq_rel) + 1;
    for (&packed_bind) |*pb| if (active(unpack(pb.load(.acquire)))) {
        sync.spawn(loop, .{g}) catch {};
        return;
    };
}

fn loop(my_gen: u32) void {
    sync.nameThread("atalho");
    var prev = [_]bool{true} ** max; // não dispara se já estava apertada na hora de configurar
    while (gen.load(.acquire) == my_gen) {
        const mods: u8 = @intCast(c.ptt_global_mods() & 7);
        const on = enabled.load(.acquire);
        for (0..max) |i| {
            const b = unpack(packed_bind[i].load(.monotonic));
            if (!active(b)) {
                prev[i] = false;
                continue;
            }
            const down = c.ptt_global_down(b.key, b.mouse) != 0 and (mods & ~b.own) == b.mods;
            const fire = down and !prev[i] and (on or i == @intFromEnum(config.HotkeyId.toggle));
            prev[i] = down;
            if (fire) {
                pressed[i].store(true, .release);
                if (on_press) |f| f();
            }
        }
        sync.sleepMs(50);
    }
}

test "atalhos: empacotar e desempacotar" {
    const b: Binding = .{ .key = 300, .mouse = -1, .mods = 5, .own = 2 };
    const u = unpack(pack(b));
    try std.testing.expectEqual(b.key, u.key);
    try std.testing.expectEqual(b.mouse, u.mouse);
    try std.testing.expectEqual(b.mods, u.mods);
    try std.testing.expectEqual(b.own, u.own);
    const m = unpack(pack(.{ .key = 0, .mouse = 3, .mods = 0 }));
    try std.testing.expectEqual(@as(i32, 3), m.mouse);
    try std.testing.expectEqual(@as(i32, 0), m.key);
}
