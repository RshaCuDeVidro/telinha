//! Robô de voz pra testar a voz da sala sem microfone de verdade:
//! `zig build voicebot -- host:porta [nome] [segundos] [opções]`.
//!
//! Entra na sala como um cliente comum, liga o "microfone" e fala sílabas
//! sintéticas (vogais com formantes) pelo mesmo motor de voz do app
//! (RNNoise → portão → Opus). Serve pra ver o anel de "falando" e ouvir/medir
//! a voz do outro lado.
//!
//! Opções:
//!   --listar           lista os microfones e sai
//!   --ouvinte MIC      em vez de falar: abre o microfone MIC de verdade, toca
//!                      a voz da sala e conta os pacotes que mandou. Com o
//!                      monitor da saída como "microfone", o que ele manda é
//!                      eco: mede o cancelamento de eco de ponta a ponta
//!   --sem-eco          (com --ouvinte) desliga o cancelamento de eco
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const voice = @import("voice.zig");
const audio = @import("audio.zig");
const aec = @import("aec.zig");
const Client = @import("client.zig").Client;

fn noWake() void {}

var sent = std.atomic.Value(u32).init(0);

fn onPacket(ctx: *anyopaque, packet: []const u8) void {
    const cl: *Client = @ptrCast(@alignCast(ctx));
    _ = sent.fetchAdd(1, .monotonic);
    cl.sendVoice(cl.voice_seq.fetchAdd(1, .monotonic), packet);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var pos: [3][]const u8 = undefined;
    var n_pos: usize = 0;
    var listener: ?[]const u8 = null;
    var echo_cancellation = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--listar")) {
            var names: [32][128]u8 = undefined;
            const n: usize = @intCast(audio.c.audio_list_mics(&names, names.len));
            for (names[0..n]) |*nm| std.debug.print("{s}\n", .{std.mem.sliceTo(nm, 0)});
            return;
        } else if (std.mem.eql(u8, a, "--ouvinte") and i + 1 < args.len) {
            i += 1;
            listener = args[i];
        } else if (std.mem.eql(u8, a, "--sem-eco")) {
            echo_cancellation = false;
        } else if (n_pos < pos.len) {
            pos[n_pos] = a;
            n_pos += 1;
        }
    }
    if (n_pos < 1) {
        std.debug.print("uso: voicebot host:porta [nome] [segundos] [--listar] [--ouvinte MICROFONE [--sem-eco]]\n", .{});
        std.process.exit(1);
    }
    const addr = pos[0];
    const name: []const u8 = if (n_pos > 1) pos[1] else "robô";
    const seconds: u32 = if (n_pos > 2) try std.fmt.parseInt(u32, pos[2], 10) else 20;
    const colon = std.mem.findScalarLast(u8, addr, ':') orelse return error.Address;
    const port = try std.fmt.parseInt(u16, addr[colon + 1 ..], 10);
    net.init();

    const cl = try Client.create(.{ .host = addr[0..colon], .port = port, .name = name, .password = "", .wake = noWake });
    defer cl.close();
    for (0..100) |_| {
        cl.mutex.lock();
        const st = cl.status;
        cl.mutex.unlock();
        if (st == .connected) break;
        sync.sleepMs(50);
    }
    cl.sendVoiceState(proto.voice_mic);

    if (listener) |mic_name| {
        var err: [256]u8 = undefined;
        const mic = voice.Mic.open(.{ .device = mic_name, .echo_cancellation = echo_cancellation }, cl, onPacket, &err) catch {
            std.debug.print("não abriu o microfone: {s}\n", .{std.mem.sliceTo(&err, 0)});
            std.process.exit(1);
        };
        defer mic.close();
        std.debug.print("{s} ouvindo por {d} s (cancelamento de eco {s})\n", .{ name, seconds, if (echo_cancellation) "ligado" else "desligado" });
        var last: u32 = 0;
        for (0..seconds) |s| {
            sync.sleepMs(1000);
            const now = sent.load(.monotonic);
            const st = mic.echoStats();
            const rs = aec.reference.takeStats();
            std.debug.print("{d:>3} s: {d:>3} pacotes | microfone {d:>6.1} dBFS, depois do cancelador {d:>6.1}, referência {d:>6.1} | deriva {d:.1} ppm | anel: {d} escritas (máx {d}), {d} leituras, {d} secas, +{d} -{d}, nível máx {d}\n", .{ s + 1, now - last, st[0], st[1], st[2], aec.reference.driftPpm(), rs.pushes, rs.max_push, rs.pops, rs.dry, rs.inserted, rs.dropped, rs.max_level });
            last = now;
        }
        std.debug.print("total: {d} pacotes em {d} s\n", .{ sent.load(.monotonic), seconds });
        return;
    }

    const mic = try voice.Mic.openDetached(.{}, cl, onPacket);
    defer mic.close();
    std.debug.print("{s} entrou e está falando por {d} s\n", .{ name, seconds });

    // fala 1,5 s, pausa 1 s, em tempo real (blocos de 10 ms)
    var buf: [480]f32 = undefined;
    var k: usize = 0;
    const t0 = sync.nowUs();
    while (sync.nowUs() - t0 < @as(u64, seconds) * 1_000_000) : (k += 1) {
        const in_phrase = (k % 250) < 150;
        vowel(&buf, k * 480, 125 + @as(f32, @floatFromInt(k % 7)) * 6, if (in_phrase) 0.08 else 0);
        mic.feed(&buf);
        const due = t0 + (k + 1) * 10_000;
        const now = sync.nowUs();
        if (due > now) sync.sleepMs(@intCast((due - now) / 1000));
    }
}

/// Vogal sintética: pulsos glotais (f0) com envelope de formantes e sílabas.
fn vowel(buf: []f32, start: usize, f0: f32, amp: f32) void {
    const formants = [_][2]f32{ .{ 700, 1.0 }, .{ 1200, 0.6 }, .{ 2600, 0.25 } };
    for (buf, 0..) |*v, i| {
        const t: f32 = @as(f32, @floatFromInt(start + i)) / 48000;
        var x: f32 = 0;
        var h: f32 = 1;
        while (h * f0 < 4000) : (h += 1) {
            const f = h * f0;
            var gain: f32 = 0;
            for (formants) |fm| gain += fm[1] / (1 + ((f - fm[0]) / 150) * ((f - fm[0]) / 150));
            x += gain * @sin(2 * std.math.pi * f * t) / h;
        }
        const syl = 0.5 + 0.5 * @sin(2 * std.math.pi * 4 * t);
        v.* = amp * x * syl;
    }
}
