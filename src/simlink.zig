//! Link de mentira pra testar o controle de taxa (ratectl.zig) sem rede:
//! relógio virtual, um gargalo com capacidade em bits/s (que pode mudar no
//! meio) e uma fila na frente dele. Cada quadro entra na fila; o atraso da
//! fila é o "excesso" que o servidor mediria pelas confirmações.
const std = @import("std");
const RateControl = @import("ratectl.zig").RateControl;

pub const Phase = struct { until_s: f64, cap_bps: f64 };

pub const Result = struct {
    /// Média enviada (bits/s) em cada fase, contando só a segunda metade dela.
    avg_bps: [8]f64 = .{0} ** 8,
    /// Tempo (s) com a fila acima de 250 ms (o que quem assiste sente como atraso).
    late_s: f64 = 0,
    /// Quadros pulados.
    skipped: u32 = 0,
    /// Cortes de taxa.
    cuts: u32 = 0,
    /// Quanto tempo depois do começo de cada fase a taxa chegou a 90% do que
    /// o link aguenta (ou do alvo, o menor); -1 = não chegou.
    recover_s: [8]f64 = .{-1} ** 8,
    max_excess_ms: f64 = 0,
};

/// Roda `phases` (em sequência) com a transmissão pedindo `target` bits/s a `fps`.
pub fn run(phases: []const Phase, target: u32, fps: u32) Result {
    var rc: RateControl = .{};
    rc.reset(target);
    _ = rc.takeChange();
    var res: Result = .{};
    const dt_us: u64 = 1_000_000 / fps;
    var t_us: u64 = 1_000_000; // o relógio não começa em 0 (o controle usa 0 como "nunca")
    var queue_bits: f64 = 0;
    var pi: usize = 0;
    var phase_start_s: f64 = 0;
    var sent_bits: f64 = 0;
    var sent_since_s: f64 = 0;
    var last_bps = rc.bps;
    const end_s = phases[phases.len - 1].until_s;
    while (true) {
        const now_s = @as(f64, @floatFromInt(t_us - 1_000_000)) / 1e6;
        if (now_s >= end_s) break;
        if (now_s >= phases[pi].until_s) {
            const len = now_s - sent_since_s;
            if (len > 0) res.avg_bps[pi] = sent_bits / len;
            pi += 1;
            phase_start_s = now_s;
        }
        const ph = phases[pi];
        // metade de trás da fase: média do que saiu
        const half = phase_start_s + (ph.until_s - phase_start_s) / 2;
        if (now_s < half) {
            sent_bits = 0;
            sent_since_s = now_s;
        }
        // o gargalo escoa a fila
        queue_bits = @max(0, queue_bits - ph.cap_bps * @as(f64, @floatFromInt(dt_us)) / 1e6);
        const excess_us: u64 = @intFromFloat(queue_bits / ph.cap_bps * 1e6);
        res.max_excess_ms = @max(res.max_excess_ms, @as(f64, @floatFromInt(excess_us)) / 1000);
        if (excess_us > RateControl.max_excess_us) res.late_s += @as(f64, @floatFromInt(dt_us)) / 1e6;
        const skip = rc.congested(.{ .now_us = t_us, .excess_us = excess_us });
        if (skip) {
            res.skipped += 1;
        } else {
            const bits = @as(f64, @floatFromInt(rc.bps)) / @as(f64, @floatFromInt(fps));
            queue_bits += bits;
            sent_bits += bits;
        }
        rc.rampUp(t_us, excess_us);
        if (rc.bps < last_bps) res.cuts += 1;
        last_bps = rc.bps;
        const goal = @min(@as(f64, @floatFromInt(target)), ph.cap_bps) * 0.9;
        if (res.recover_s[pi] < 0 and @as(f64, @floatFromInt(rc.bps)) >= goal) res.recover_s[pi] = now_s - phase_start_s;
        t_us += dt_us;
    }
    const len = @as(f64, @floatFromInt(t_us - 1_000_000)) / 1e6 - sent_since_s;
    if (len > 0) res.avg_bps[pi] = sent_bits / len;
    return res;
}

fn show(name: []const u8, phases: []const Phase, r: Result) void {
    if (std.c.getenv("TELINHA_SIMLINK_LOG") == null) return;
    std.debug.print("\n[simlink] {s}: {d} cortes, {d} quadros pulados, {d:.1} s com fila > 250 ms (máx {d:.0} ms)\n", .{ name, r.cuts, r.skipped, r.late_s, r.max_excess_ms });
    for (phases, 0..) |ph, i| std.debug.print("  fase {d} (link {d:.1} Mbit/s até {d:.0} s): média {d:.2} Mbit/s, 90% em {d:.1} s\n", .{ i, ph.cap_bps / 1e6, ph.until_s, r.avg_bps[i] / 1e6, r.recover_s[i] });
}

test "simlink: link mais estreito que o alvo: acomoda perto da capacidade sem ficar atrasando" {
    const phases = [_]Phase{.{ .until_s = 90, .cap_bps = 4e6 }};
    const r = run(&phases, 6_000_000, 30);
    show("link de 4 Mbit/s, alvo 6", &phases, r);
    // usa a maior parte do link, e a fila não fica cheia o tempo todo
    try std.testing.expect(r.avg_bps[0] > 4e6 * 0.75);
    try std.testing.expect(r.late_s < 10);
}

test "simlink: link cai e volta: depois que volta, a taxa sobe de novo sem demorar" {
    const phases = [_]Phase{
        .{ .until_s = 20, .cap_bps = 10e6 },
        .{ .until_s = 40, .cap_bps = 3e6 },
        .{ .until_s = 100, .cap_bps = 10e6 },
    };
    const r = run(&phases, 6_000_000, 30);
    show("10 → 3 → 10 Mbit/s, alvo 6", &phases, r);
    try std.testing.expect(r.recover_s[0] >= 0 and r.recover_s[0] < 1);
    try std.testing.expect(r.avg_bps[1] > 3e6 * 0.7);
    try std.testing.expect(r.recover_s[2] >= 0);
}

test "simlink: link com folga: fica no alvo sem cortar nada" {
    const phases = [_]Phase{.{ .until_s = 60, .cap_bps = 7e6 }};
    const r = run(&phases, 6_000_000, 30);
    show("link de 7 Mbit/s, alvo 6", &phases, r);
    try std.testing.expectEqual(@as(u32, 0), r.cuts);
    try std.testing.expectEqual(@as(u32, 0), r.skipped);
}

test "simlink: link oscilando (quedas curtas): não fica atrasando a cada sondagem" {
    var phases: [8]Phase = undefined;
    var t: f64 = 0;
    for (0..4) |i| {
        t += 13;
        phases[i * 2] = .{ .until_s = t, .cap_bps = 5e6 };
        t += 3;
        phases[i * 2 + 1] = .{ .until_s = t, .cap_bps = 2e6 };
    }
    const r = run(&phases, 6_000_000, 30);
    show("5 Mbit/s com quedas de 3 s pra 2, alvo 6", &phases, r);
    try std.testing.expect(r.late_s < 6);
    try std.testing.expect(r.avg_bps[6] > 5e6 * 0.6);
}
