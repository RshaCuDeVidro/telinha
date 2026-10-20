//! Diagnóstico da captura do som do computador: `zig build audiotest -- [segundos]`.
//!
//! Captura do mesmo jeito que o app e, ao mesmo tempo, toca um tom de 1 kHz
//! pelo próprio processo. Mostra a força de 440 Hz (toque um tom desses em
//! outro programa) e de 1 kHz no que foi capturado: o 1 kHz (o próprio
//! telinha tocando) NÃO pode aparecer — senão quem assiste ouviria eco.
const std = @import("std");
const c = @cImport(@cInclude("audio.h"));

const rate: f32 = 48000;
const rate_n = 48000;

var lock: std.atomic.Value(bool) = .init(false);
var captured: [rate_n * 30]f32 = undefined; // mono, até 30 s
var n_captured: usize = 0;
var phase: f32 = 0;

fn onCapture(_: ?*anyopaque, samples: [*c]const f32, frames: c_int) callconv(.c) void {
    const n: usize = @intCast(frames);
    for (0..n) |i| {
        if (n_captured == captured.len) return;
        captured[n_captured] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5;
        n_captured += 1;
    }
}

fn onPlay(_: ?*anyopaque, samples: [*c]f32, frames: c_int) callconv(.c) void {
    for (0..@intCast(frames)) |i| {
        const v = 0.3 * @sin(phase);
        phase += 2 * std.math.pi * 1000.0 / rate;
        if (phase > 2 * std.math.pi) phase -= 2 * std.math.pi;
        samples[i * 2] = v;
        samples[i * 2 + 1] = v;
    }
}

/// Amplitude de uma frequência (Goertzel), normalizada (tom puro de amplitude A → ~A).
fn goertzel(x: []const f32, freq: f32) f32 {
    const k = 2 * @cos(2 * std.math.pi * freq / rate);
    var s1: f32 = 0;
    var s2: f32 = 0;
    for (x) |v| {
        const s0 = v + k * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    const p = s1 * s1 + s2 * s2 - k * s1 * s2;
    return 2 * @sqrt(@max(p, 0)) / @as(f32, @floatFromInt(x.len));
}

extern "c" fn usleep(us: c_uint) c_int;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seconds: u32 = if (args.len > 1) try std.fmt.parseInt(u32, args[1], 10) else 3;
    var err: [256]u8 = [_]u8{0} ** 256;
    // 2º argumento: só esse programa (nome, como na lista abaixo)
    var apps: [32]c.audio_app = undefined;
    const n_apps: usize = @intCast(@max(0, c.audio_list_apps(&apps, apps.len)));
    std.debug.print("programas tocando som: {d}\n", .{n_apps});
    for (apps[0..n_apps]) |*ap| std.debug.print("  {s} (pid {d})\n", .{ std.mem.sliceTo(&ap.name, 0), ap.pid });
    var only: [64:0]u8 = [_:0]u8{0} ** 64;
    if (args.len > 2) @memcpy(only[0..@min(args[2].len, 63)], args[2][0..@min(args[2].len, 63)]);
    const cap = c.audio_capture_open(onCapture, null, &only, 0, null, &err, err.len) orelse {
        std.debug.print("FALHOU ao abrir a captura: {s}\n", .{std.mem.sliceTo(&err, 0)});
        std.process.exit(1);
    };
    defer c.audio_close(cap);
    std.debug.print("captura aberta ({s})\n", .{if (c.audio_capture_hears_self(cap) != 0) "monitor da saída: pega tudo, inclusive o próprio app" else "aplicativos, sem o próprio app"});
    const out = c.audio_output_open(onPlay, null, &err, err.len);
    if (out == null) std.debug.print("aviso: sem saída de som ({s}); o teste de eco não vale\n", .{std.mem.sliceTo(&err, 0)});
    defer if (out) |o| c.audio_close(o);
    _ = usleep(seconds * 1_000_000);

    const x = captured[0..n_captured];
    std.debug.print("capturados {d:.1} s\n", .{@as(f32, @floatFromInt(x.len)) / rate});
    if (x.len < rate_n / 2) {
        std.debug.print("quase nada capturado (nenhum aplicativo tocando?)\n", .{});
        return;
    }
    const tail = x[x.len / 4 ..]; // pula o começo (ligações sendo feitas)
    const a440 = goertzel(tail, 440);
    const a1k = goertzel(tail, 1000);
    std.debug.print("440 Hz (outro aplicativo): {d:.3}\n1000 Hz (o próprio app):    {d:.3}\n", .{ a440, a1k });
    if (out != null and c.audio_capture_hears_self(cap) == 0 and a1k > 0.02) {
        std.debug.print("FALHOU: a captura pegou o som do próprio app (eco)\n", .{});
        std.process.exit(1);
    }
}
