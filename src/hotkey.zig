//! Atalho global de salvar clipe (vale com o jogo em foco, como o apertar pra
//! falar; ver c/ptt.c): uma thread lê a tecla a cada 50 ms e avisa quando ela
//! foi apertada. Só existe com um atalho configurado.
const std = @import("std");
const sync = @import("sync.zig");
const c = @cImport(@cInclude("ptt.h"));

var gen: std.atomic.Value(u32) = .init(0);
var key: std.atomic.Value(i32) = .init(0);
var mouse: std.atomic.Value(i32) = .init(-1);
/// Apertou (a interface pega e limpa).
pub var pressed: std.atomic.Value(bool) = .init(false);
pub var on_press: ?*const fn () void = null;

/// `k`: scancode (Windows) / keycode do X11; `m`: botão do mouse (-1 = tecla).
/// Os dois vazios = sem atalho (a thread para).
pub fn configure(k: i32, m: i32) void {
    key.store(k, .release);
    mouse.store(m, .release);
    const g = gen.fetchAdd(1, .acq_rel) + 1;
    // botão que o sistema não deixa ler de fora (laterais no X11): sem thread à toa
    if (m >= 0 and c.ptt_global_button_supported(m) == 0) return;
    if (k > 0 or m >= 0) sync.spawn(loop, .{g}) catch {};
}

fn loop(my_gen: u32) void {
    var prev = true; // não dispara se já estava apertada na hora de configurar
    while (gen.load(.acquire) == my_gen) {
        const down = c.ptt_global_down(key.load(.monotonic), mouse.load(.monotonic)) != 0;
        if (down and !prev) {
            pressed.store(true, .release);
            if (on_press) |f| f();
        }
        prev = down;
        sync.sleepMs(50);
    }
}
