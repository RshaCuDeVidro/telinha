//! Apertar pra falar: o portão da voz abre só com a tecla apertada. A tecla
//! vale com qualquer programa em foco onde o sistema deixa (Windows, X11; ver
//! c/ptt.c); no Wayland nativo, só com o telinha em foco (a interface avisa
//! pela `ui_down`).
const std = @import("std");
const c = @cImport(@cInclude("ptt.h"));
const sync = @import("sync.zig");

/// Modo ligado (a interface muda; o microfone lê).
pub var enabled: std.atomic.Value(bool) = .init(false);
/// Tecla pra leitura global: scancode (Windows) ou keycode do X11; 0 = nenhuma.
var global_key: std.atomic.Value(i32) = .init(0);
/// Botão do mouse (2 = meio, 3/4 = laterais); -1 = é tecla.
var mouse_button: std.atomic.Value(i32) = .init(-1);
/// A interface viu a tecla apertada com o telinha em foco.
pub var ui_down: std.atomic.Value(bool) = .init(false);
/// A thread que lê a tecla de fora (a cada 10 ms) deixa o resultado aqui: o
/// microfone só lê isso (nada de ida ao servidor X dentro do callback de áudio).
var global_down: std.atomic.Value(bool) = .init(false);
var gen: std.atomic.Value(u32) = .init(0);

/// Depois de soltar, o portão fica aberto mais um pouco (não corta o fim da palavra).
const release_hold_us = 150_000;
var hold_until_us: u64 = 0; // só a thread do microfone

pub fn configure(key: i32, mouse: i32) void {
    global_key.store(key, .release);
    mouse_button.store(mouse, .release);
    restart();
}

fn restart() void {
    const g = gen.fetchAdd(1, .acq_rel) + 1;
    global_down.store(false, .release);
    if (!enabled.load(.acquire)) return;
    const m = mouse_button.load(.acquire);
    if (m >= 0 and c.ptt_global_button_supported(m) == 0) return; // esse botão só com o telinha em foco
    if (m < 0 and global_key.load(.acquire) <= 0) return;
    sync.spawn(poll, .{g}) catch {};
}

fn poll(my_gen: u32) void {
    while (gen.load(.acquire) == my_gen) {
        global_down.store(c.ptt_global_down(global_key.load(.monotonic), mouse_button.load(.monotonic)) != 0, .release);
        sync.sleepMs(10);
    }
}

/// Thread do microfone, a cada bloco de 10 ms: a tecla está apertada (ou foi agora há pouco)?
pub fn pressed(now_us: u64) bool {
    const down = ui_down.load(.monotonic) or global_down.load(.monotonic);
    if (down) hold_until_us = now_us + release_hold_us;
    return down or now_us < hold_until_us;
}

/// Dá pra ler a tecla com outro programa em foco?
pub fn globalSupported() bool {
    return c.ptt_global_supported() != 0;
}
