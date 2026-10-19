//! Testes: `zig build test`.
const std = @import("std");
const testing = std.testing;
const sync = @import("sync.zig");
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");
const proto = @import("proto.zig");
const audio = @import("audio.zig");

test {
    _ = @import("integration_test.zig");
}

fn initPool() void {
    const S = struct {
        var started = false;
    };
    if (!S.started) {
        sync.pool.start(3);
        S.started = true;
    }
}

// ---------------------------------------------------------------- conversão

test "BGRX -> I420 -> RGBA preserva as cores (erro pequeno)" {
    initPool();
    const w = 64;
    const h = 34;
    var src: [w * h * 4]u8 = undefined;
    // blocos 2x2 de cor sólida (o I420 subamostra a cor em 2x2)
    for (0..h) |y| for (0..w) |x| {
        const bx = x / 2;
        const by = y / 2;
        const p = (y * w + x) * 4;
        src[p + 0] = @intCast((bx * 37 + by * 11) % 256); // B
        src[p + 1] = @intCast((bx * 13 + by * 29) % 256); // G
        src[p + 2] = @intCast((bx * 7 + by * 53) % 256); // R
        src[p + 3] = 255;
    };
    var y: [w * h]u8 = undefined;
    var u: [w * h / 4]u8 = undefined;
    var v: [w * h / 4]u8 = undefined;
    codec.toI420(&src, w * 4, w, h, .bgrx, &y, &u, &v);
    var rgba: [w * h * 4]u8 = undefined;
    codec.toRgba(&y, &u, &v, w, w / 2, w, h, &rgba);
    var max_err: i32 = 0;
    for (0..w * h) |i| {
        const r: i32 = rgba[i * 4];
        const g: i32 = rgba[i * 4 + 1];
        const b: i32 = rgba[i * 4 + 2];
        max_err = @max(max_err, @as(i32, @intCast(@abs(r - @as(i32, src[i * 4 + 2])))));
        max_err = @max(max_err, @as(i32, @intCast(@abs(g - @as(i32, src[i * 4 + 1])))));
        max_err = @max(max_err, @as(i32, @intCast(@abs(b - @as(i32, src[i * 4 + 0])))));
        try testing.expectEqual(@as(u8, 255), rgba[i * 4 + 3]);
    }
    // faixa limitada (16..235) + arredondamento: cores extremas perdem um pouco
    try testing.expect(max_err <= 6);
}

test "RGBX e BGRX dão o mesmo Y" {
    initPool();
    const w = 32;
    const h = 2;
    var bgrx: [w * h * 4]u8 = undefined;
    var rgbx: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| {
        const r: u8 = @intCast(i * 3 % 256);
        const g: u8 = @intCast(i * 5 % 256);
        const b: u8 = @intCast(i * 7 % 256);
        bgrx[i * 4 ..][0..4].* = .{ b, g, r, 0 };
        rgbx[i * 4 ..][0..4].* = .{ r, g, b, 0 };
    }
    var y1: [w * h]u8 = undefined;
    var y2: [w * h]u8 = undefined;
    var uv: [w * h / 2]u8 = undefined;
    codec.toI420(&bgrx, w * 4, w, h, .bgrx, &y1, uv[0 .. w * h / 4], uv[w * h / 4 ..]);
    codec.toI420(&rgbx, w * 4, w, h, .rgbx, &y2, uv[0 .. w * h / 4], uv[w * h / 4 ..]);
    try testing.expectEqualSlices(u8, &y1, &y2);
}

// --------------------------------------------------------------------- H.264

test "H.264: codifica e decodifica um quadro" {
    initPool();
    const w = 320;
    const h = 240;
    const img = try std.heap.c_allocator.alloc(u8, w * h * 4);
    defer std.heap.c_allocator.free(img);
    for (0..h) |y| for (0..w) |x| {
        const p = (y * w + x) * 4;
        img[p + 0] = @intCast(x % 256);
        img[p + 1] = @intCast(y % 256);
        img[p + 2] = @intCast((x + y) % 256);
        img[p + 3] = 255;
    };
    var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 2_000_000, .threads = 1 });
    defer enc.deinit();
    var dec = try codec.Decoder.init();
    defer dec.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    var got_pic = false;
    var first_key = false;
    for (0..3) |i| {
        out.clearRetainingCapacity();
        const key = try enc.encode(img.ptr, w * 4, .bgrx, &out) orelse continue;
        if (i == 0) first_key = key;
        if (try dec.decode(out.items)) |pic| {
            try testing.expectEqual(@as(u32, w), pic.w);
            try testing.expectEqual(@as(u32, h), pic.h);
            got_pic = true;
        }
    }
    try testing.expect(first_key);
    try testing.expect(got_pic);
}

test "NVENC: um IDR sozinho já vira imagem (sem atraso de reordenação)" {
    initPool();
    const w = 640;
    const h = 360;
    var err: [256]u8 = undefined;
    var enc = codec.HwEncoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 2_000_000 }, &err) catch return error.SkipZigTest;
    defer enc.deinit();
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    const img = try std.heap.c_allocator.alloc(u8, w * h * 4);
    defer std.heap.c_allocator.free(img);
    @memset(img, 0x80);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    for (0..3) |i| {
        out.clearRetainingCapacity();
        const key = try enc.encode(img.ptr, w * 4, .bgrx, i == 0, &out);
        if (i == 0) try testing.expect(key);
        // cada quadro tem que sair na mesma chamada
        const pic = (try dec.decode(out.items)) orelse return error.DecoderHeldFrame;
        try testing.expectEqual(@as(u32, w), pic.w);
    }
}

test "Opus: codifica e decodifica 10 ms de áudio" {
    var err: c_int = 0;
    const enc = audio.c.opus_encoder_create(audio.rate, audio.channels, audio.c.OPUS_APPLICATION_RESTRICTED_LOWDELAY, &err) orelse return error.OpusInit;
    defer audio.c.opus_encoder_destroy(enc);
    var dec = try audio.Decoder.init();
    defer dec.deinit();
    var pcm: [audio.frame_len * audio.channels]f32 = undefined;
    var got: usize = 0;
    var packet: [1500]u8 = undefined;
    for (0..10) |f| {
        for (0..audio.frame_len) |i| {
            const t: f32 = @floatFromInt(f * audio.frame_len + i);
            const v = 0.5 * @sin(t * 2.0 * std.math.pi * 440.0 / 48000.0);
            pcm[i * 2] = v;
            pcm[i * 2 + 1] = v;
        }
        const n = audio.c.opus_encode_float(enc, &pcm, audio.frame_len, &packet, packet.len);
        try testing.expect(n > 0);
        const out = try dec.decode(packet[0..@intCast(n)]);
        try testing.expectEqual(@as(usize, audio.frame_len * audio.channels), out.len);
        got += out.len;
    }
    try testing.expectEqual(@as(usize, 10 * audio.frame_len * audio.channels), got);
}

test "anel de áudio: espera encher, toca e não acumula atraso" {
    var rg: audio.Ring = .{};
    defer rg.deinit();
    var chunk = [_]f32{0.25} ** (audio.frame_len * audio.channels); // 10 ms
    var out = [_]f32{0} ** (audio.frame_len * audio.channels);

    rg.write(&chunk); // 10 ms guardados: ainda não toca (buffer anti-oscilação)
    rg.mixInto(&out, 1.0);
    try testing.expectEqual(@as(f32, 0), out[0]);

    for (0..5) |_| rg.write(&chunk); // 60 ms: começa a tocar
    rg.mixInto(&out, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-6);

    // consome tudo: no fim faltou áudio, então volta a esperar encher
    for (0..10) |_| {
        @memset(&out, 0);
        rg.mixInto(&out, 1.0);
    }
    try testing.expect(!rg.primed);

    // a rede despejou 400 ms de uma vez: pula pra frente e fica perto do alvo
    for (0..40) |_| rg.write(&chunk);
    @memset(&out, 0);
    rg.mixInto(&out, 1.0);
    try testing.expect(rg.len <= audio.target_samples);
}

test "detecta IDR no bitstream" {
    try testing.expect(codec.hasIdrNal(&.{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x65, 9 }));
    try testing.expect(!codec.hasIdrNal(&.{ 0, 0, 0, 1, 0x41, 1, 2, 3 }));
    try testing.expect(!codec.hasIdrNal(&.{}));
}

// ----------------------------------------------------------------- crypto

test "canal: mesma senha conversa, senha errada falha" {
    const a = try crypto.Handshake.init();
    const b = try crypto.Handshake.init();
    const ha = try crypto.parseHello(&a.helloBytes(proto.version));
    const hb = try crypto.parseHello(&b.helloBytes(proto.version));

    var cli = try crypto.Channel.derive(&a, hb, true, "segredo");
    var srv = try crypto.Channel.derive(&b, ha, false, "segredo");
    const msg = "oi, tudo bem?";
    var sealed: [msg.len + crypto.tag_len]u8 = undefined;
    var opened: [msg.len]u8 = undefined;
    for (0..3) |_| { // contadores andam juntos
        cli.seal(msg, &sealed);
        try srv.open(&sealed, &opened);
        try testing.expectEqualStrings(msg, &opened);
    }
    srv.seal(msg, &sealed);
    try cli.open(&sealed, &opened);

    var bad = try crypto.Channel.derive(&b, ha, false, "outra");
    cli.seal(msg, &sealed);
    try testing.expectError(error.AuthFailed, bad.open(&sealed, &opened));
}

test "canal: mensagem adulterada é rejeitada" {
    const a = try crypto.Handshake.init();
    const b = try crypto.Handshake.init();
    var cli = try crypto.Channel.derive(&a, try crypto.parseHello(&b.helloBytes(1)), true, "");
    var srv = try crypto.Channel.derive(&b, try crypto.parseHello(&a.helloBytes(1)), false, "");
    var sealed: [5 + crypto.tag_len]u8 = undefined;
    var opened: [5]u8 = undefined;
    cli.seal("abcde", &sealed);
    sealed[2] ^= 1;
    try testing.expectError(error.AuthFailed, srv.open(&sealed, &opened));
}

test "hello inválido" {
    var junk = [_]u8{0} ** crypto.hello_len;
    try testing.expectError(error.NotTelinha, crypto.parseHello(&junk));
}

// ------------------------------------------------------------------ proto

test "Builder/Reader ida e volta" {
    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.chat);
    try b.u32_(42);
    try b.str("fulano");
    try b.u64_(0x1122334455667788);
    try b.u16_(7);
    const m = try b.finish();
    defer m.release();
    try testing.expectEqual(proto.Type.chat, m.typ);
    var r: proto.Reader = .{ .data = m.payload() };
    try testing.expectEqual(@as(u32, 42), try r.u32_());
    try testing.expectEqualStrings("fulano", try r.str());
    try testing.expectEqual(@as(u64, 0x1122334455667788), try r.u64_());
    try testing.expectEqual(@as(u16, 7), try r.u16_());
    try testing.expectError(error.BadMessage, r.u8_());
}

test "SendQueue: dropFrames só remove frames do remetente" {
    var q: proto.SendQueue = .{};
    defer q.deinit();
    const f1 = try proto.Msg.alloc(.frame, 10);
    f1.from = 1;
    const f2 = try proto.Msg.alloc(.frame, 10);
    f2.from = 2;
    const chat = try proto.Msg.alloc(.chat, 3);
    q.pushOwned(f1);
    q.pushOwned(chat);
    q.pushOwned(f2);
    const before = q.queuedBytes();
    try testing.expectEqual(@as(usize, 1), q.dropFrames(1));
    try testing.expectEqual(before - 15, q.queuedBytes());
    try testing.expectEqual(@as(usize, 1), q.dropFrames(null));
    try testing.expectEqual(@as(usize, 8), q.queuedBytes());
}

test "SendQueue: pushUrgent fura a fila" {
    var q: proto.SendQueue = .{};
    defer q.deinit();
    q.pushOwned(try proto.Msg.alloc(.frame, 10));
    q.pushOwned(try proto.Msg.alloc(.frame, 10));
    const a1 = try proto.Msg.alloc(.ack, 4);
    a1.payload()[0] = 1;
    q.pushUrgentOwned(a1);
    try testing.expectEqual(proto.Type.ack, q.items.items[q.head].typ);
    try testing.expectEqual(@as(usize, 3 * 5 + 24), q.queuedBytes());
    // a segunda urgente fura os quadros, mas fica atrás da primeira
    const a2 = try proto.Msg.alloc(.ack, 4);
    a2.payload()[0] = 2;
    q.pushUrgentOwned(a2);
    try testing.expectEqual(@as(u8, 1), q.items.items[q.head].payload()[0]);
    try testing.expectEqual(@as(u8, 2), q.items.items[q.head + 1].payload()[0]);
    try testing.expectEqual(proto.Type.frame, q.items.items[q.head + 2].typ);
}

test "AckWindow: atraso acumulado e confirmação cumulativa" {
    var w: proto.AckWindow = .{};
    // sem medida ainda: usa a referência padrão
    w.sent(10, 1_000_000, false);
    try testing.expectEqual(@as(u64, 0), w.excessUs(1_100_000, 300_000));
    try testing.expectEqual(@as(u64, 200_000), w.excessUs(1_500_000, 300_000));
    // confirmado em 50 ms: vira a referência
    w.acked(10, 1_050_000);
    try testing.expectEqual(@as(u64, 50_000), w.baseUs(300_000));
    try testing.expectEqual(@as(usize, 0), w.len);
    // vários a caminho; a confirmação do 13 libera 11, 12 e 13
    for (11..15) |i| w.sent(@intCast(i), 2_000_000 + (i - 11) * 33_000, false);
    w.acked(13, 2_150_000);
    try testing.expectEqual(@as(usize, 1), w.len);
    // a referência continua 50 ms (menor da janela); o 14 saiu em 2,099 s:
    // em 2,5 s está há 401 ms no caminho = 351 ms acima do normal
    try testing.expectEqual(@as(u64, 50_000), w.baseUs(300_000));
    try testing.expectEqual(@as(u64, 351_000), w.excessUs(2_500_000, 300_000));
    // descartado antes de sair da fila: não espera confirmação
    w.dropNewest(1);
    try testing.expectEqual(@as(u64, 0), w.excessUs(2_500_000, 300_000));
    // seq dando a volta no u32
    w.sent(0xFFFF_FFFF, 3_000_000, false);
    w.sent(0, 3_010_000, false);
    w.acked(0xFFFF_FFFF, 3_020_000);
    try testing.expectEqual(@as(usize, 1), w.len);
    w.acked(0, 3_030_000);
    try testing.expectEqual(@as(usize, 0), w.len);

    // IDR a caminho: folga grande; confirmado depois de 800 ms: folga de 800 ms
    // que some em 4 s
    w.sent(1, 4_000_000, true);
    try testing.expectEqual(@as(u64, 4_000_000), w.keyAllowanceUs(4_100_000));
    w.acked(1, 4_800_000);
    try testing.expectEqual(@as(u64, 800_000), w.keyAllowanceUs(4_800_000));
    try testing.expectEqual(@as(u64, 400_000), w.keyAllowanceUs(6_800_000));
    try testing.expectEqual(@as(u64, 0), w.keyAllowanceUs(8_800_000));
    // IDR descartado antes de sair: não conta
    w.sent(2, 9_000_000, true);
    w.dropNewest(1);
    try testing.expect(!w.key_pending);

    // o atraso do IDR (800 ms) não virou referência (a menor é a de 20 ms
    // do teste da volta do u32)
    try testing.expectEqual(@as(u64, 20_000), w.baseUs(300_000));
    // janelas de 10 s: a referência antiga sai depois de duas janelas sem
    // nada tão rápido (rota piorou: 20 → 120 ms)
    w.sent(3, 12_000_000, false);
    w.acked(3, 12_120_000);
    try testing.expectEqual(@as(u64, 20_000), w.baseUs(300_000));
    w.sent(4, 23_000_000, false);
    w.acked(4, 23_120_000);
    try testing.expectEqual(@as(u64, 120_000), w.baseUs(300_000));
    // conexão congestionada desde o começo: medidas infladas não passam de 400 ms
    var c: proto.AckWindow = .{};
    c.sent(0, 0, false);
    c.acked(0, 1_700_000);
    try testing.expectEqual(@as(u64, 400_000), c.baseUs(300_000));
}

const RateControl = @import("ratectl.zig").RateControl;

test "RateControl: congestionamento persistente baixa a taxa; IDR não" {
    var rc: RateControl = .{};
    rc.reset(4_000_000);
    _ = rc.takeChange();
    // atrasado só por causa de um IDR: pula o quadro, mas não baixa a taxa
    try testing.expect(rc.congested(.{ .now_us = 1_000_000, .excess_us = 700_000, .key_allowance_us = 800_000 }));
    try testing.expectEqual(@as(?u32, null), rc.takeChange());
    // atrasado de verdade: pula; continua atrasado 300 ms depois: -25%
    try testing.expect(rc.congested(.{ .now_us = 2_000_000, .excess_us = 400_000 }));
    try testing.expect(rc.congested(.{ .now_us = 2_350_000, .excess_us = 400_000 }));
    try testing.expectEqual(@as(?u32, 3_000_000), rc.takeChange());
    try testing.expectEqual(@as(u32, 4_000_000), rc.ceiling);
    // atraso começando a crescer: -7% sem pular quadro
    try testing.expect(!rc.congested(.{ .now_us = 3_000_000, .excess_us = 150_000 }));
    try testing.expectEqual(@as(?u32, 2_790_000), rc.takeChange());
}

test "RateControl: sobe rápido até 90% do teto, segura, e depois só sonda" {
    var rc: RateControl = .{};
    rc.reset(4_000_000);
    rc.bps = 1_000_000;
    rc.ceiling = 2_000_000;
    rc.last_congestion_us = 1;
    rc.last_adjust_us = 1;
    // atraso não zerado: segura
    rc.rampUp(10_000_000, 80_000);
    try testing.expectEqual(@as(u32, 1_000_000), rc.bps);
    // longe do teto: +12% +50 kbit/s
    rc.rampUp(10_000_000, 0);
    try testing.expectEqual(@as(u32, 1_170_000), rc.bps);
    // não passa de 90% do teto rápido
    rc.bps = 1_700_000;
    rc.rampUp(11_100_000, 0);
    try testing.expectEqual(@as(u32, 1_800_000), rc.bps);
    // em 90%: segura até 15 s sem problema...
    rc.rampUp(12_200_000, 0);
    try testing.expectEqual(@as(u32, 1_800_000), rc.bps);
    // ...depois sonda devagar (+2%)
    rc.rampUp(16_000_000, 0);
    try testing.expectEqual(@as(u32, 1_836_000), rc.bps);
    // 30 s sem problema: esquece o teto e volta a subir rápido
    rc.rampUp(31_000_000, 0);
    try testing.expectEqual(@as(u32, 0), rc.ceiling);
    try testing.expectEqual(@as(u32, 2_106_320), rc.bps);
}

test "RateControl: aviso de espectador lento respeita o piso" {
    var rc: RateControl = .{};
    rc.reset(4_000_000);
    _ = rc.takeChange();
    var t: u64 = 10_000_000;
    for (0..10) |_| {
        _ = rc.congested(.{ .now_us = t, .excess_us = 0, .slow_floor_pct = 50 });
        t += 2_100_000;
    }
    try testing.expectEqual(@as(u32, 2_000_000), rc.bps); // metade do alvo, não menos
    // enquanto tiver aviso recente, não sobe
    rc.rampUp(t, 0);
    try testing.expectEqual(@as(u32, 2_000_000), rc.bps);
}

test "NVENC: a conversão RGB→YUV dele bate com a nossa (BT.601, faixa limitada)" {
    var err: [256]u8 = undefined;
    const w = 64;
    const h = 64;
    var enc = codec.HwEncoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 2_000_000 }, &err) catch return error.SkipZigTest;
    defer enc.deinit();
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    var img: [w * h * 4]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    var y_ref: [w * h]u8 = undefined;
    var u_ref: [w * h / 4]u8 = undefined;
    var v_ref: [w * h / 4]u8 = undefined;
    // vermelho, verde, azul, cinza médio (BGRX)
    const cores = [_][3]u8{ .{ 0, 0, 255 }, .{ 0, 255, 0 }, .{ 255, 0, 0 }, .{ 128, 128, 128 } };
    for (cores) |cor| {
        for (0..w * h) |i| {
            img[i * 4] = cor[0];
            img[i * 4 + 1] = cor[1];
            img[i * 4 + 2] = cor[2];
            img[i * 4 + 3] = 255;
        }
        codec.toI420(&img, w * 4, w, h, .bgrx, &y_ref, &u_ref, &v_ref);
        out.clearRetainingCapacity();
        _ = try enc.encode(&img, w * 4, .bgrx, true, &out);
        const p = (try dec.decode(out.items)).?;
        const c = 32 * p.ys + 32;
        const cu = 16 * p.uvs + 16;
        // quem assiste converte de volta com BT.601 (shader/CPU): as cores têm que bater
        try testing.expect(@abs(@as(i32, y_ref[32 * w + 32]) - p.y[c]) <= 2);
        try testing.expect(@abs(@as(i32, u_ref[16 * 32 + 16]) - p.u[cu]) <= 2);
        try testing.expect(@abs(@as(i32, v_ref[16 * 32 + 16]) - p.v[cu]) <= 2);
    }
}

const voice = @import("voice.zig");

const VoiceSink = struct {
    packets: usize = 0,
    bytes: usize = 0,
    peer: voice.Peer = .{ .id = 1 },
    fn on(ctx: *anyopaque, packet: []const u8) void {
        const sk: *VoiceSink = @ptrCast(@alignCast(ctx));
        sk.packets += 1;
        sk.bytes += packet.len;
        // decodifica do outro lado também (sem tocar: o mixer não abre saída em teste)
        if (sk.peer.dec == null) sk.peer.dec = audio.Decoder.init() catch return;
        const pcm = sk.peer.dec.?.decode(packet) catch return;
        sk.peer.ring.write(pcm);
    }
};

/// Vogal sintética: pulsos glotais (f0) com envelope de formantes.
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
        // vibrato e sílabas (4 por segundo) pra não ser um tom parado
        const syl = 0.5 + 0.5 * @sin(2 * std.math.pi * 4 * t);
        v.* = amp * x * syl;
    }
}

test "voz: silêncio não manda nada; voz manda; ruído parado não abre o portão" {
    var sink: VoiceSink = .{};
    defer sink.peer.deinit();
    const m = try voice.Mic.openDetached(.{ .sensitivity = 0.5 }, &sink, VoiceSink.on);
    defer m.close();
    var buf: [480]f32 = undefined;
    // 1 s de silêncio
    @memset(&buf, 0);
    for (0..100) |_| m.feed(&buf);
    try testing.expectEqual(@as(usize, 0), sink.packets);
    // 2 s de "fala"
    for (0..200) |k| {
        vowel(&buf, k * 480, 130, 0.08);
        m.feed(&buf);
    }
    const speech_packets = sink.packets;
    try testing.expect(speech_packets > 30); // portão aberto boa parte do tempo
    try testing.expect(sink.bytes / speech_packets < 200); // ~40 kbit/s
    try testing.expect(sink.peer.ring.len > 0 or sink.peer.ring.last_write_us != 0);
    // 2 s de ventilador (ruído branco parado): o RNNoise não chama de voz
    var rng = std.Random.DefaultPrng.init(3);
    for (0..200) |_| {
        for (&buf) |*v| v.* = (rng.random().float(f32) - 0.5) * 0.05;
        m.feed(&buf);
    }
    try testing.expect(sink.packets - speech_packets < 20);
}

test "voz: sem supressão de ruído, o portão é por volume" {
    var sink: VoiceSink = .{};
    defer sink.peer.deinit();
    const m = try voice.Mic.openDetached(.{ .noise_suppression = false }, &sink, VoiceSink.on);
    defer m.close();
    var buf: [480]f32 = undefined;
    @memset(&buf, 0.0001);
    for (0..50) |_| m.feed(&buf);
    try testing.expectEqual(@as(usize, 0), sink.packets);
    for (0..100) |k| {
        vowel(&buf, k * 480, 200, 0.1);
        m.feed(&buf);
    }
    try testing.expect(sink.packets > 30);
}

test "config: volume da voz lembrado pelo nome" {
    var v: @import("config.zig").VoiceVolumes = .{};
    v.set("Ana", 150);
    v.set("Bruno", 100); // padrão: não guarda
    v.set("Ana", 40);
    try testing.expectEqual(@as(?u16, 40), v.get("Ana"));
    try testing.expectEqual(@as(?u16, null), v.get("Bruno"));
    try testing.expectEqual(@as(usize, 1), v.n);
}

const aec = @import("aec.zig");

test "eco: o cancelador tira a voz que voltou da caixa e deixa a sua passar" {
    var cn = try aec.Canceller.init();
    defer cn.deinit();
    const n_blocks = 400; // 4 s
    const delay = 1920; // eco chega 40 ms depois
    var far = try std.heap.c_allocator.alloc(f32, n_blocks * 480 + delay);
    defer std.heap.c_allocator.free(far);
    @memset(far[0..delay], 0);
    vowel(far[delay..], 0, 140, 0.25); // quem está do outro lado fala o tempo todo
    var mic: [480]f32 = undefined;
    var ref: [480]f32 = undefined;
    var out: [480]f32 = undefined;
    var e_in: f64 = 0;
    var e_out: f64 = 0;
    var prev: f32 = 0;
    for (0..n_blocks) |k| {
        // referência = o que a caixa tocou agora; microfone = isso 40 ms depois, mais baixo e abafado
        @memcpy(&ref, far[delay + k * 480 ..][0..480]);
        for (&mic, 0..) |*v, i| {
            const x = far[k * 480 + i];
            v.* = 0.5 * (0.6 * x + 0.4 * prev);
            prev = x;
        }
        cn.process(&mic, &ref, &out);
        if (k >= n_blocks - 100) {
            for (mic, out) |a, b| {
                e_in += a * a;
                e_out += b * b;
            }
        }
    }
    const erle = 10 * std.math.log10(e_in / @max(e_out, 1e-12));
    try testing.expect(erle > 15); // medido: ~30 dB

    // agora o outro lado fica quieto e você fala: sua voz tem que passar
    @memset(&ref, 0);
    var near_in: f64 = 0;
    var near_out: f64 = 0;
    for (0..100) |k| {
        vowel(&mic, k * 480, 210, 0.2);
        cn.process(&mic, &ref, &out);
        if (k >= 50) {
            for (mic, out) |a, b| {
                near_in += a * a;
                near_out += b * b;
            }
        }
    }
    const loss = 10 * std.math.log10(near_in / @max(near_out, 1e-12));
    try testing.expect(loss < 3); // medido: ~0 dB
}

/// Caminho de verdade do eco: o mixer entrega blocos de 1024 quadros (estéreo)
/// pro anel de referência, a caixa toca 26 ms depois, o microfone entrega
/// blocos de 441 e anda `drift_ppm` mais rápido que a saída; os callbacks dos
/// dois lados atrasam até `jitter` amostras. Devolve o ERLE (dB) do último
/// 1,5 s.
fn liveEchoErle(drift_ppm: f64, jitter: u32) !f64 {
    return liveEcho(drift_ppm, jitter, 8, false);
}

fn liveEcho(drift_ppm: f64, jitter: u32, seconds: usize, per_second: bool) !f64 {
    aec.reference.clear();
    var cn = try aec.Canceller.init();
    defer cn.deinit();
    const total = 48000 * seconds;
    const far = try std.heap.c_allocator.alloc(f32, total);
    defer std.heap.c_allocator.free(far);
    vowel(far, 0, 140, 0.25);
    const ratio = 1.0 / (1.0 + drift_ppm * 1e-6); // tempo da saída por amostra do microfone
    const l_out: f64 = 1024 + 240;
    var stereo: [2048]f32 = undefined;
    var block: [480]f32 = undefined;
    var out: [480]f32 = undefined;
    var nb: usize = 0;
    var blocks: usize = 0;
    var e_in: f64 = 0;
    var e_out: f64 = 0;
    var k: usize = 0;
    var m: usize = 0;
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var jit_out: f64 = 0;
    var jit_mic: f64 = 0;
    while (true) {
        const t_out = @as(f64, @floatFromInt(k * 1024)) + jit_out;
        const t_mic = @as(f64, @floatFromInt((m + 1) * 441)) * ratio + 120 + jit_mic;
        if (t_out <= t_mic) {
            if ((k + 1) * 1024 > total) break;
            for (0..1024) |i| {
                stereo[2 * i] = far[k * 1024 + i];
                stereo[2 * i + 1] = far[k * 1024 + i];
            }
            aec.reference.pushStereo(&stereo);
            k += 1;
            if (jitter > 0) jit_out = @floatFromInt(rnd.uintLessThan(u32, jitter));
            continue;
        }
        for (0..441) |i| {
            const t = @as(f64, @floatFromInt(m * 441 + i)) * ratio - l_out;
            block[nb] = if (t < 1) 0 else 0.5 * (0.6 * lerp(far, t) + 0.4 * lerp(far, t - 1));
            nb += 1;
            if (nb < 480) continue;
            nb = 0;
            cn.processLive(&block, &out);
            blocks += 1;
            if (per_second) {
                for (block, out) |a, b| {
                    e_in += a * a;
                    e_out += b * b;
                }
                if (blocks % 100 == 0) {
                    std.debug.print("{d:.0} ", .{10 * std.math.log10(e_in / @max(e_out, 1e-12))});
                    e_in = 0;
                    e_out = 0;
                }
            } else if (blocks > total / 480 - 150) for (block, out) |a, b| {
                e_in += a * a;
                e_out += b * b;
            };
        }
        m += 1;
        if (jitter > 0) jit_mic = @floatFromInt(rnd.uintLessThan(u32, jitter));
    }
    return 10 * std.math.log10(e_in / @max(e_out, 1e-12));
}

fn lerp(x: []const f32, t: f64) f32 {
    const i: usize = @intFromFloat(t);
    if (i + 1 >= x.len) return 0;
    const f: f32 = @floatCast(t - @floor(t));
    return x[i] * (1 - f) + x[i + 1] * f;
}

test "eco: referência alinhada com blocos diferentes e relógios desencontrados" {
    // medido: ~35 dB com o mesmo relógio (com ou sem atraso nos callbacks)
    try testing.expect(try liveEchoErle(0, 0) > 30);
    try testing.expect(try liveEchoErle(0, 192) > 30);
    // relógios diferentes, antes da deriva ser medida: o filtro corre atrás (~20 dB)
    try testing.expect(try liveEchoErle(50, 96) > 15);
    try testing.expect(try liveEchoErle(-50, 96) > 15);
    // e o anel não guarda atraso à toa
    try testing.expect(aec.reference.level() < 48000 * 30 / 1000);
}

test "eco: deriva entre os relógios medida e compensada" {
    // microfone 120 ppm mais rápido: depois de ~25 s a deriva é medida e a
    // referência reamostrada (medido: ~32 dB; sem compensar, ~14 dB)
    const erle = try liveEcho(120, 96, 40, false);
    const ppm = aec.reference.driftPpm();
    try testing.expect(ppm < -105 and ppm > -135);
    try testing.expect(erle > 25);
}
