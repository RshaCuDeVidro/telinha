//! Robô de voz pra testar a voz da sala sem microfone de verdade:
//! `zig build voicebot -- host:porta [nome] [segundos]`.
//!
//! Entra na sala como um cliente comum, liga o "microfone" e fala sílabas
//! sintéticas (vogais com formantes) pelo mesmo motor de voz do app
//! (RNNoise → portão → Opus). Serve pra ver o anel de "falando" e ouvir/medir
//! a voz do outro lado.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const voice = @import("voice.zig");
const Client = @import("client.zig").Client;

fn noWake() void {}

fn onPacket(ctx: *anyopaque, packet: []const u8) void {
    const cl: *Client = @ptrCast(@alignCast(ctx));
    cl.sendVoice(cl.voice_seq.fetchAdd(1, .monotonic), packet);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("uso: voicebot host:porta [nome] [segundos]\n", .{});
        std.process.exit(1);
    }
    const addr: []const u8 = args[1];
    const name: []const u8 = if (args.len > 2) args[2] else "robô";
    const seconds: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 20;
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
