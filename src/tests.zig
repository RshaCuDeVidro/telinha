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
