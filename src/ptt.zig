//! Apertar pra falar: o portão da voz abre só com a tecla apertada. A tecla
//! vale com qualquer programa em foco onde o sistema deixa (Windows, X11; ver
//! c/ptt.c); no Wayland nativo, só com o telinha em foco (a interface avisa
//! pela `ui_down`).
const std = @import("std");
const c = @cImport(@cInclude("ptt.h"));

/// Modo ligado (a interface muda; o microfone lê).
pub var enabled: std.atomic.Value(bool) = .init(false);
/// Tecla pra leitura global: scancode (Windows) ou keycode do X11; 0 = nenhuma.
var global_key: std.atomic.Value(i32) = .init(0);
/// Botão do mouse (2 = meio, 3/4 = laterais); -1 = é tecla.
var mouse_button: std.atomic.Value(i32) = .init(-1);
/// A interface viu a tecla apertada com o telinha em foco.
pub var ui_down: std.atomic.Value(bool) = .init(false);

/// Depois de soltar, o portão fica aberto mais um pouco (não corta o fim da palavra).
const release_hold_us = 150_000;
var hold_until_us: u64 = 0; // só a thread do microfone

pub fn configure(key: i32, mouse: i32) void {
    global_key.store(key, .release);
    mouse_button.store(mouse, .release);
}

/// Thread do microfone, a cada bloco de 10 ms: a tecla está apertada (ou foi agora há pouco)?
pub fn pressed(now_us: u64) bool {
    const down = ui_down.load(.monotonic) or c.ptt_global_down(global_key.load(.monotonic), mouse_button.load(.monotonic)) != 0;
    if (down) hold_until_us = now_us + release_hold_us;
    return down or now_us < hold_until_us;
}

/// Dá pra ler a tecla com outro programa em foco?
pub fn globalSupported() bool {
    return c.ptt_global_supported() != 0;
}
