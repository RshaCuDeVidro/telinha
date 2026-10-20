//! Qualidade automática da transmissão: se o PC não dá conta do fps, desce a
//! resolução um degrau; com folga, sobe de volta (ver sharer.zig).

const std = @import("std");

/// Altura máxima de verdade: a escolhida (0 = original) com o teto da
/// qualidade automática (0 = nenhum).
pub fn effectiveHeight(chosen: u32, auto_cap: u32) u32 {
    if (auto_cap == 0) return chosen;
    if (chosen == 0) return auto_cap;
    return @min(chosen, auto_cap);
}

/// Qualidade automática: se o PC não dá conta do fps (o encoder ou a captura
/// demoram mais que um quadro), desce um degrau de resolução; com folga por
/// um tempo, sobe de volta (até a escolhida). Uma decisão por segundo.
pub const AutoQuality = struct {
    pub const tiers = [_]u32{ 2160, 1440, 1080, 900, 720, 540, 480, 360 };
    cap: u32 = 0, // altura máxima imposta (0 = nenhuma)
    over: u8 = 0, // segundos seguidos sem dar conta
    under: u8 = 0, // segundos seguidos com folga
    up_wait: u8 = 15, // quanto folgar antes de subir (dobra se subir e cair logo)
    next_us: u64 = 0,
    last_up_us: u64 = 0,

    /// `load_us`: o mais lento entre encode e captura, por quadro. `out_h`:
    /// a altura que está saindo agora; `chosen`: a escolhida (0 = original);
    /// `src_h`: a da fonte. Retorna true se mudou o teto.
    pub fn step(q: *AutoQuality, now: u64, load_us: u64, fps: u32, out_h: u32, chosen: u32, src_h: u32) bool {
        if (now < q.next_us) return false;
        q.next_us = now + 1_000_000;
        const budget: u64 = 1_000_000 / @max(fps, 1);
        if (load_us * 100 > budget * 115) {
            q.over +|= 1;
            q.under = 0;
        } else if (load_us * 100 < budget * 55) {
            q.under +|= 1;
            q.over = 0;
        } else {
            q.over = 0;
            q.under = 0;
        }
        if (q.over >= 3) {
            // desce: o primeiro degrau abaixo do que está saindo
            const next = for (tiers) |t| {
                if (t < out_h) break t;
            } else return false;
            q.cap = next;
            q.over = 0;
            q.under = 0;
            if (q.last_up_us != 0 and now - q.last_up_us < 20_000_000) q.up_wait = @min(120, q.up_wait *| 2);
            q.next_us = now + 4_000_000; // o encoder novo precisa de uns segundos pra medir
            return true;
        }
        if (q.cap != 0 and q.under >= q.up_wait) {
            // sobe um degrau (ou tira o teto, se já chegou no escolhido)
            var up: u32 = 0;
            for (tiers) |t| {
                if (t > q.cap) up = t;
            }
            const limit = if (chosen == 0) src_h else @min(chosen, src_h);
            q.cap = if (up == 0 or up >= limit) 0 else up;
            q.under = 0;
            q.last_up_us = now;
            q.next_us = now + 4_000_000;
            return true;
        }
        return false;
    }
};

test "qualidade automática: desce depois de 3 s sem dar conta, sobe com folga até a escolhida" {
    var q: AutoQuality = .{};
    const s: u64 = 1_000_000;
    // 30 q/s = 33 ms por quadro; encode de 50 ms não dá conta
    var t: u64 = 10 * s;
    try std.testing.expect(!q.step(t, 50_000, 30, 1080, 0, 1080));
    t += s;
    try std.testing.expect(!q.step(t, 50_000, 30, 1080, 0, 1080));
    t += s;
    try std.testing.expect(q.step(t, 50_000, 30, 1080, 0, 1080));
    try std.testing.expectEqual(@as(u32, 900), q.cap);
    // espera o encoder novo assentar (4 s) antes de decidir de novo
    try std.testing.expect(!q.step(t + s, 50_000, 30, 900, 0, 1080));
    // ainda não dá conta em 900p: 720p
    t += 4 * s;
    for (0..2) |_| {
        try std.testing.expect(!q.step(t, 45_000, 30, 900, 0, 1080));
        t += s;
    }
    try std.testing.expect(q.step(t, 45_000, 30, 900, 0, 1080));
    try std.testing.expectEqual(@as(u32, 720), q.cap);
    // folga (10 ms por quadro) por 15 s: sobe pra 900
    t += 4 * s;
    var changed = false;
    for (0..15) |_| {
        changed = q.step(t, 10_000, 30, 720, 0, 1080);
        t += s;
    }
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u32, 900), q.cap);
    // caiu de novo logo depois de subir: a próxima subida espera o dobro
    t += 4 * s;
    for (0..3) |_| {
        _ = q.step(t, 50_000, 30, 900, 0, 1080);
        t += s;
    }
    try std.testing.expectEqual(@as(u32, 720), q.cap);
    try std.testing.expectEqual(@as(u8, 30), q.up_wait);
    // no meio-termo não mexe
    t += 4 * s;
    for (0..40) |_| {
        try std.testing.expect(!q.step(t, 25_000, 30, 720, 0, 1080));
        t += s;
    }
    // sobe até a escolhida (720p escolhido: tira o teto em vez de passar dela)
    var r: AutoQuality = .{ .cap = 540 };
    t = 100 * s;
    for (0..16) |_| {
        _ = r.step(t, 5_000, 30, 540, 720, 1080);
        t += s;
    }
    try std.testing.expectEqual(@as(u32, 0), r.cap);
    try std.testing.expectEqual(@as(u32, 720), effectiveHeight(720, 0));
    try std.testing.expectEqual(@as(u32, 540), effectiveHeight(0, 540));
    try std.testing.expectEqual(@as(u32, 480), effectiveHeight(720, 480));
}
