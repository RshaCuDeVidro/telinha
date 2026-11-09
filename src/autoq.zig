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
/// demoram mais que um quadro), primeiro o fps automático cai de 60 pra 30 e
/// só depois desce um degrau de resolução; com folga por um tempo, sobe de
/// volta (até a escolhida). Descida que não baixou o tempo por quadro (o
/// gargalo é outro: placa integrada dividida com o jogo, driver esperando)
/// volta pro degrau de antes e não tenta de novo por um tempo: antes ia até
/// 360p e ficava lá, sem ganhar nada. Uma decisão por segundo.
pub const AutoQuality = struct {
    pub const tiers = [_]u32{ 2160, 1440, 1080, 900, 720, 540, 480, 360 };
    cap: u32 = 0, // altura máxima imposta (0 = nenhuma)
    /// fps automático em 30 (não deu conta de 60)
    fps30: bool = false,
    /// a última mudança foi desfazer uma descida que não adiantou
    reverted: bool = false,
    over: u8 = 0, // segundos seguidos sem dar conta
    under: u8 = 0, // segundos seguidos com folga
    up_wait: u8 = 15, // quanto folgar antes de subir (dobra se subir e cair logo)
    next_us: u64 = 0,
    last_up_us: u64 = 0,
    // a última descida, conferida na decisão seguinte (0 = nenhuma em teste)
    drop_from: u32 = 0, // altura que saía antes dela
    drop_cap: u32 = 0, // o teto de antes
    drop_load: u64 = 0, // o tempo por quadro de antes
    hold_until_us: u64 = 0, // descer não adiantou: nada de descer até aqui
    hold_us: u64 = 60_000_000, // dobra a cada vez (até 10 min)

    /// `load_us`: o mais lento entre encode e captura, por quadro. `fps`: o
    /// que vale agora; `fps_auto60`: o fps é o automático e seria 60 (pode
    /// cair pra 30). `out_h`: a altura que está saindo agora; `chosen`: a
    /// escolhida (0 = original); `src_h`: a da fonte. Retorna true se mudou o
    /// teto ou o fps.
    pub fn step(q: *AutoQuality, now: u64, load_us: u64, fps: u32, fps_auto60: bool, out_h: u32, chosen: u32, src_h: u32) bool {
        if (now < q.next_us) return false;
        q.next_us = now + 1_000_000;
        if (!fps_auto60) q.fps30 = false;
        if (q.drop_from != 0 and out_h < q.drop_from) {
            // a descida adiantou? Pelo menos metade do que a conta dos pixels
            // promete (900p → 720p: 36% menos pixels, tem que cair 18%)
            const kept = @as(u64, out_h) * out_h * 1000 / (@as(u64, q.drop_from) * q.drop_from); // ‰ dos pixels
            const want = q.drop_load * (1000 - (1000 - kept) / 2) / 1000;
            q.drop_from = 0;
            if (load_us > want) {
                q.cap = q.drop_cap;
                q.reverted = true;
                q.over = 0;
                q.under = 0;
                q.hold_until_us = now + q.hold_us;
                q.hold_us = @min(q.hold_us * 2, 600_000_000);
                q.next_us = now + 4_000_000;
                return true;
            }
        }
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
            q.over = 0;
            q.under = 0;
            // 60 → 30 primeiro (fica a resolução); acima de 1080p, a resolução
            // desce antes (4K a 60 → 1080p a 60 vale mais que 4K a 30)
            if (fps_auto60 and !q.fps30 and out_h <= 1080) {
                q.fps30 = true;
                q.reverted = false;
                q.next_us = now + 4_000_000;
                return true;
            }
            if (now < q.hold_until_us) return false;
            // desce: o primeiro degrau abaixo do que está saindo
            const next = for (tiers) |t| {
                if (t < out_h) break t;
            } else return false;
            q.drop_from = out_h;
            q.drop_cap = q.cap;
            q.drop_load = load_us;
            q.cap = next;
            q.reverted = false;
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
            q.reverted = false;
            q.last_up_us = now;
            q.next_us = now + 4_000_000;
            return true;
        }
        // resolução toda de volta: 60 q/s se couber num quadro de 60 com folga
        if (q.cap == 0 and q.fps30 and q.under >= q.up_wait and load_us * 100 < 1_000_000 / 60 * 55) {
            q.fps30 = false;
            q.under = 0;
            q.reverted = false;
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
    // 30 q/s = 33 ms por quadro; encode de 60 ms não dá conta
    var t: u64 = 10 * s;
    try std.testing.expect(!q.step(t, 60_000, 30, false, 1080, 0, 1080));
    t += s;
    try std.testing.expect(!q.step(t, 60_000, 30, false, 1080, 0, 1080));
    t += s;
    try std.testing.expect(q.step(t, 60_000, 30, false, 1080, 0, 1080));
    try std.testing.expectEqual(@as(u32, 900), q.cap);
    // espera o encoder novo assentar (4 s) antes de decidir de novo
    try std.testing.expect(!q.step(t + s, 60_000, 30, false, 900, 0, 1080));
    // em 900p caiu junto com os pixels (adiantou), mas ainda não dá conta: 720p
    t += 4 * s;
    for (0..2) |_| {
        try std.testing.expect(!q.step(t, 43_000, 30, false, 900, 0, 1080));
        t += s;
    }
    try std.testing.expect(q.step(t, 43_000, 30, false, 900, 0, 1080));
    try std.testing.expectEqual(@as(u32, 720), q.cap);
    // folga (10 ms por quadro) por 15 s: sobe pra 900
    t += 4 * s;
    var changed = false;
    for (0..15) |_| {
        changed = q.step(t, 10_000, 30, false, 720, 0, 1080);
        t += s;
    }
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u32, 900), q.cap);
    // caiu de novo logo depois de subir: a próxima subida espera o dobro
    t += 4 * s;
    for (0..3) |_| {
        _ = q.step(t, 50_000, 30, false, 900, 0, 1080);
        t += s;
    }
    try std.testing.expectEqual(@as(u32, 720), q.cap);
    try std.testing.expectEqual(@as(u8, 30), q.up_wait);
    // no meio-termo não mexe
    t += 4 * s;
    for (0..40) |_| {
        try std.testing.expect(!q.step(t, 25_000, 30, false, 720, 0, 1080));
        t += s;
    }
    // sobe até a escolhida (720p escolhido: tira o teto em vez de passar dela)
    var r: AutoQuality = .{ .cap = 540 };
    t = 100 * s;
    for (0..16) |_| {
        _ = r.step(t, 5_000, 30, false, 540, 720, 1080);
        t += s;
    }
    try std.testing.expectEqual(@as(u32, 0), r.cap);
    try std.testing.expectEqual(@as(u32, 720), effectiveHeight(720, 0));
    try std.testing.expectEqual(@as(u32, 540), effectiveHeight(0, 540));
    try std.testing.expectEqual(@as(u32, 480), effectiveHeight(720, 480));
}

test "qualidade automática: descer que não adianta volta pro degrau de antes e espera" {
    // placa integrada dividida com o jogo: o tempo por quadro não depende da
    // resolução (log da anajumita: 34,9 → 28,1 → 25,5 → 27,8 ms de 900p a 360p)
    var q: AutoQuality = .{};
    const s: u64 = 1_000_000;
    var t: u64 = 10 * s;
    for (0..3) |_| {
        _ = q.step(t, 50_000, 30, false, 1080, 0, 1080);
        t += s;
    }
    try std.testing.expectEqual(@as(u32, 900), q.cap);
    // 900p: o mesmo tempo. Volta pra resolução toda e avisa que foi desfeito
    t += 3 * s;
    try std.testing.expect(q.step(t, 49_000, 30, false, 900, 0, 1080));
    try std.testing.expectEqual(@as(u32, 0), q.cap);
    try std.testing.expect(q.reverted);
    // segue sem dar conta, mas não desce de novo por 1 min
    t += 4 * s;
    for (0..50) |_| {
        try std.testing.expect(!q.step(t, 50_000, 30, false, 1080, 0, 1080));
        t += s;
    }
    // passado o minuto, tenta de novo; não adiantou: espera o dobro
    for (0..8) |_| {
        _ = q.step(t, 50_000, 30, false, 1080, 0, 1080);
        t += s;
    }
    try std.testing.expectEqual(@as(u32, 900), q.cap);
    t += 3 * s;
    try std.testing.expect(q.step(t, 50_000, 30, false, 900, 0, 1080));
    try std.testing.expectEqual(@as(u32, 0), q.cap);
    try std.testing.expectEqual(@as(u64, 240_000_000), q.hold_us);
}

test "qualidade automática: fps automático cai pra 30 antes da resolução, e volta pra 60" {
    const s: u64 = 1_000_000;
    // 900p a 60 com 31 ms por quadro (não cabe em 16,7): 30 q/s, mesma resolução
    var q: AutoQuality = .{};
    var t: u64 = 10 * s;
    var changed = false;
    for (0..3) |_| {
        changed = q.step(t, 31_000, 60, true, 900, 0, 900);
        t += s;
    }
    try std.testing.expect(changed and q.fps30);
    try std.testing.expectEqual(@as(u32, 0), q.cap);
    // a 30 q/s (33 ms) os 31 ms cabem: fica em 900p30
    t += 4 * s;
    for (0..60) |_| {
        try std.testing.expect(!q.step(t, 31_000, 30, true, 900, 0, 900));
        t += s;
    }
    try std.testing.expect(q.fps30);
    // folgou (8 ms cabe num quadro de 60 com folga): volta pra 60
    for (0..15) |_| {
        changed = q.step(t, 8_000, 30, true, 900, 0, 900);
        t += s;
    }
    try std.testing.expect(changed and !q.fps30);
    // fps escolhido (não automático): direto na resolução
    var f: AutoQuality = .{};
    t = 10 * s;
    for (0..3) |_| {
        _ = f.step(t, 31_000, 60, false, 900, 0, 900);
        t += s;
    }
    try std.testing.expect(!f.fps30);
    try std.testing.expectEqual(@as(u32, 720), f.cap);
    // acima de 1080p a resolução desce antes (1440p60 → 1080p60)
    var h: AutoQuality = .{};
    t = 10 * s;
    for (0..3) |_| {
        _ = h.step(t, 25_000, 60, true, 1440, 0, 1440);
        t += s;
    }
    try std.testing.expect(!h.fps30);
    try std.testing.expectEqual(@as(u32, 1080), h.cap);
}
