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
    _ = @import("procstat.zig");
    _ = @import("config.zig");
    _ = @import("hotkey.zig");
    _ = @import("update.zig");
    _ = @import("chatimg.zig");
    _ = @import("i18n.zig");
    _ = @import("udp.zig");
    _ = @import("voice.zig");
    _ = @import("debuglog.zig");
    _ = @import("theme.zig");
    _ = @import("autoq.zig");
    _ = @import("pctest.zig");
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

/// PSNR do brilho de 20 quadros de "texto" rolando, codificado e decodificado na placa.
fn hwRoundTrip(cd: codec.Codec, w: u32, h: u32) !struct { psnr: f64, bytes: usize } {
    var err: [256]u8 = undefined;
    var enc = codec.HwEncoder.init(.{ .codec = cd, .width = w, .height = h, .fps = 30, .bitrate = 2_000_000 }, &err) catch return error.SkipZigTest;
    defer enc.deinit();
    var dec = codec.HwDecoder.init(cd, &err) catch return error.SkipZigTest;
    defer dec.deinit();
    const gpa = std.heap.c_allocator;
    const img = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(img);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var bytes: usize = 0;
    var psnr_sum: f64 = 0;
    for (0..20) |i| {
        for (0..h) |y| for (0..w) |x| {
            const v: u8 = if (((x + i * 3) / 2 + y / 9) % 3 == 0) 230 else 25;
            img[(y * w + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
        };
        out.clearRetainingCapacity();
        const key = try enc.encode(img.ptr, w * 4, .bgrx, i == 0 or i == 10, &out);
        if (i == 0 or i == 10) try testing.expect(key);
        bytes += out.items.len;
        // o quadro tem que sair na mesma chamada
        const f = (try dec.decode(out.items)) orelse return error.DecoderHeldFrame;
        try testing.expectEqual(w, f.w);
        try testing.expectEqual(h, f.h);
        var se: f64 = 0;
        for (0..h) |y| for (0..w) |x| {
            const d = @as(f64, @floatFromInt(f.y[y * w + x])) - (16.0 + @as(f64, @floatFromInt(img[(y * w + x) * 4])) * 219.0 / 255.0);
            se += d * d;
        };
        psnr_sum += 10 * std.math.log10(255.0 * 255.0 / (se / @as(f64, @floatFromInt(w * h))));
    }
    return .{ .psnr = psnr_sum / 20, .bytes = bytes };
}

test "HEVC: NVENC codifica, NVDEC decodifica na hora, e rende mais que o H.264" {
    initPool();
    const hevc = try hwRoundTrip(.hevc, 1280, 720);
    const avc = try hwRoundTrip(.h264, 1280, 720);
    std.debug.print("720p, 2 Mbit/s, texto rolando: HEVC {d:.1} dB ({d} KB) · H.264 {d:.1} dB ({d} KB)\n", .{ hevc.psnr, hevc.bytes / 1024, avc.psnr, avc.bytes / 1024 });
    // mesma banda: o HEVC não pode sair pior
    try testing.expect(hevc.psnr > avc.psnr - 0.3);
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
    try testing.expect(erle > 15); // medido: ~24 dB

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
    return liveEcho(.{ .drift_ppm = drift_ppm, .jitter = jitter });
}

const EchoSim = struct {
    drift_ppm: f64 = 0,
    jitter: u32 = 0,
    seconds: usize = 8,
    /// Atraso a mais no caminho até a caixa (Bluetooth: ~200 ms).
    extra_delay_ms: usize = 0,
    /// Fala irregular (sílabas e pausas aleatórias) em vez da vogal contínua.
    speech: bool = false,
    per_second: bool = false,
};

fn liveEcho(o: EchoSim) !f64 {
    const drift_ppm = o.drift_ppm;
    const jitter = o.jitter;
    const per_second = o.per_second;
    aec.reference.clear();
    aec.reference.base = 0;
    var cn = try aec.Canceller.init();
    defer cn.deinit();
    const total = 48000 * o.seconds;
    const far = try std.heap.c_allocator.alloc(f32, total);
    defer std.heap.c_allocator.free(far);
    if (o.speech) speechLike(far, 7) else vowel(far, 0, 140, 0.25);
    const ratio = 1.0 / (1.0 + drift_ppm * 1e-6); // tempo da saída por amostra do microfone
    const l_out: f64 = @floatFromInt(1024 + 240 + o.extra_delay_ms * 48);
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
            } else if (blocks > total / 480 - 200) for (block, out) |a, b| {
                e_in += a * a;
                e_out += b * b;
            };
        }
        m += 1;
        if (jitter > 0) jit_mic = @floatFromInt(rnd.uintLessThan(u32, jitter));
    }
    return 10 * std.math.log10(e_in / @max(e_out, 1e-12));
}

/// Fala sintética irregular: sílabas com duração, tom, volume e pausas
/// aleatórios (o envelope não se repete, como na fala de verdade).
fn speechLike(buf: []f32, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < buf.len) {
        const syl = 48 * (80 + rnd.uintLessThan(usize, 220)); // 80–300 ms
        const long_pause = rnd.uintLessThan(u8, 6) == 0;
        const gap = 48 * (20 + rnd.uintLessThan(usize, if (long_pause) 700 else 120));
        const f0 = 100 + rnd.float(f32) * 120;
        const amp = 0.1 + rnd.float(f32) * 0.2;
        const n = @min(syl, buf.len - i);
        vowel(buf[i..][0..n], i, f0, amp);
        for (buf[i..][0..n], 0..) |*v, j| v.* *= @sin(std.math.pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(syl)));
        i += n;
        const g = @min(gap, buf.len - i);
        @memset(buf[i..][0..g], 0);
        i += g;
    }
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
    // relógios diferentes, antes da deriva ser medida: o filtro corre atrás (~26 dB)
    try testing.expect(try liveEchoErle(50, 96) > 15);
    try testing.expect(try liveEchoErle(-50, 96) > 15);
    // e o anel não guarda atraso à toa
    try testing.expect(aec.reference.level() < 48000 * 30 / 1000);
}

test "eco: atraso grande (caixa Bluetooth) medido e compensado" {
    // o eco chega ~220 ms depois: fora da cauda do filtro (100 ms), que
    // sozinho não tiraria nada. O detector de atraso acha e atrasa a referência
    const erle = try liveEcho(.{ .extra_delay_ms = 200, .speech = true, .seconds = 14, .jitter = 96 });
    const base = aec.reference.baseMs();
    try testing.expect(base > 180 and base < 230); // medido: 211 ms (200 + 26 do caminho - 15 de alvo)
    try testing.expect(erle > 15); // medido: ~20 dB
}

test "eco: deriva entre os relógios medida e compensada" {
    // microfone 120 ppm mais rápido: depois de ~25 s a deriva é medida e a
    // referência reamostrada (medido: ~33 dB; sem compensar, ~19 dB)
    const erle = try liveEcho(.{ .drift_ppm = 120, .jitter = 96, .seconds = 40 });
    const ppm = aec.reference.driftPpm();
    try testing.expect(ppm < -105 and ppm > -135);
    try testing.expect(erle > 25);
}

test "eco: com fone (sem eco), falar junto com o outro lado não come a sua voz" {
    // referência tocando (o outro lado falando) e o microfone só com a sua voz:
    // o cancelador não pode atenuar nada que não seja eco
    var cn = try aec.Canceller.init();
    defer cn.deinit();
    const n_blocks = 500;
    const far = try std.heap.c_allocator.alloc(f32, n_blocks * 480);
    defer std.heap.c_allocator.free(far);
    speechLike(far, 11);
    var mic: [480]f32 = undefined;
    var out: [480]f32 = undefined;
    var e_in: f64 = 0;
    var e_out: f64 = 0;
    for (0..n_blocks) |k| {
        vowel(&mic, k * 480, 190, 0.15);
        cn.process(&mic, far[k * 480 ..][0..480], &out);
        if (k >= 200) for (mic, out) |a, b| {
            e_in += a * a;
            e_out += b * b;
        };
    }
    const loss = 10 * std.math.log10(e_in / @max(e_out, 1e-12));
    try testing.expect(loss < 2);
}

test "eco: com fone, o cancelador sai do caminho; tirou o fone, volta" {
    // o detector distingue "microfone com a minha voz" de "microfone com eco"
    const far = try std.heap.c_allocator.alloc(f32, 500 * 480);
    defer std.heap.c_allocator.free(far);
    speechLike(far, 3);
    var near: [480]f32 = undefined;
    var de: aec.DelayEstimator = .{};
    for (0..500) |k| {
        vowel(&near, k * 480, 200, 0.1);
        _ = de.feed(&near, far[k * 480 ..][0..480]);
    }
    try testing.expect(de.evals > 0 and de.last_rho < 0.25);
    var de2: aec.DelayEstimator = .{};
    var echo: [480]f32 = undefined;
    for (0..500) |k| {
        for (&echo, 0..) |*v, i| v.* = if (k * 480 + i >= 1440) 0.5 * far[k * 480 + i - 1440] else 0;
        _ = de2.feed(&echo, far[k * 480 ..][0..480]);
    }
    try testing.expect(de2.last_rho > 0.4);

    // 1 min sem eco (120 avaliações) → sai do caminho; eco → volta
    var cn = try aec.Canceller.init();
    defer cn.deinit();
    for (0..119) |_| cn.checkBypass(0.1, 0.3);
    try testing.expect(!cn.bypassed());
    cn.checkBypass(0.1, 0.3);
    try testing.expect(cn.bypassed());
    cn.checkBypass(0.3, 0); // dúvida: não muda nada
    try testing.expect(cn.bypassed());
    cn.checkBypass(0.6, 0);
    try testing.expect(!cn.bypassed());

    // caixa de som, falando junto quase o tempo todo: a correlação fica baixa,
    // mas quando só o outro lado fala o cancelador tira eco — não sai do caminho
    var cn2 = try aec.Canceller.init();
    defer cn2.deinit();
    for (0..400) |k| cn2.checkBypass(0.15, if (k % 20 == 0) 12 else 0.5);
    try testing.expect(!cn2.bypassed());
}

/// Quadrado andando sobre um fundo fixo (conteúdo de tela realista: o resto parado).
fn movingSquare(img: []u8, w: usize, h: usize, f: usize) void {
    for (0..h) |y| for (0..w) |x| {
        const p = (y * w + x) * 4;
        const in_sq = x >= 20 + f * 8 and x < 60 + f * 8 and y >= 100 and y < 140;
        img[p + 0] = if (in_sq) 250 else @intCast(x % 256);
        img[p + 1] = if (in_sq) 30 else @intCast(y % 256);
        img[p + 2] = if (in_sq) 30 else @intCast((x + y) % 256);
        img[p + 3] = 255;
    };
}

test "codec: quadro de não-referência é reconhecido pelo bitstream" {
    // nal_ref_idc nos bits 5-6 do cabeçalho: 0x41 = P de referência, 0x01 = P sem
    try testing.expect(codec.isDroppable(&.{ 0, 0, 0, 1, 0x01, 0x9a, 0, 0, 1, 0x01, 0x9b }));
    try testing.expect(!codec.isDroppable(&.{ 0, 0, 0, 1, 0x01, 0x9a, 0, 0, 1, 0x41, 0x9b }));
    try testing.expect(!codec.isDroppable(&.{ 0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x65, 2 })); // IDR
    try testing.expect(!codec.isDroppable(&.{ 0, 0, 0, 1, 0x06, 5 })); // só SEI, sem fatia
}

test "openh264: duas camadas temporais — quadro sim, quadro não pulável" {
    initPool();
    const w = 320;
    const h = 240;
    const img = try std.heap.c_allocator.alloc(u8, w * h * 4);
    defer std.heap.c_allocator.free(img);
    for ([_]codec.Mode{ .screen, .motion }) |mode| {
        var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 1_000_000, .threads = 1, .mode = mode, .temporal_layers = 2 });
        defer enc.deinit();
        var dec = try codec.Decoder.init();
        defer dec.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.heap.c_allocator);
        var dropped: usize = 0;
        for (0..16) |f| {
            movingSquare(img, w, h, f);
            out.clearRetainingCapacity();
            const key = try enc.encode(img.ptr, w * 4, .bgrx, &out) orelse return error.EncoderSkipped;
            const drop = codec.isDroppable(out.items);
            try testing.expectEqual(f % 2 == 1, drop); // I d P d P d ...
            try testing.expectEqual(f == 0, key);
            if (drop) {
                dropped += 1;
                continue;
            }
            // quem só recebe a base decodifica tudo o que recebe
            _ = (try dec.decode(out.items)) orelse return error.NoPicture;
        }
        try testing.expectEqual(@as(usize, 8), dropped);
    }
}

test "NVENC: duas camadas temporais (quem decide o tipo do quadro somos nós)" {
    initPool();
    const w = 640;
    const h = 360;
    var err: [256]u8 = undefined;
    const img = try std.heap.c_allocator.alloc(u8, w * h * 4);
    defer std.heap.c_allocator.free(img);
    var enc = codec.HwEncoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 2_000_000, .mode = .motion, .temporal_layers = 2 }, &err) catch return error.SkipZigTest;
    defer enc.deinit();
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    var since_idr: usize = 0;
    for (0..16) |f| {
        movingSquare(img, w, h, f);
        out.clearRetainingCapacity();
        const force = f == 0 or f == 9; // alguém entrou no meio
        const key = try enc.encode(img.ptr, w * 4, .bgrx, force, &out);
        try testing.expectEqual(force, key);
        if (key) since_idr = 0;
        const drop = codec.isDroppable(out.items);
        try testing.expectEqual(since_idr % 2 == 1, drop); // recomeça a contagem no IDR
        since_idr += 1;
        if (drop) continue;
        _ = (try dec.decode(out.items)) orelse return error.NoPicture;
    }
}

// ------------------------------------------------------------------- MP4

const mp4 = @import("mp4.zig");
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(f: *anyopaque) c_int;
extern "c" fn fgets(buf: [*]u8, n: c_int, f: *anyopaque) ?[*]u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

/// Roda um comando e devolve a saída (testes; vazio se falhar).
fn run(cmd: [:0]const u8, out: []u8) []const u8 {
    const f = popen(cmd.ptr, "r") orelse return out[0..0];
    var n: usize = 0;
    while (n + 1 < out.len) {
        const line = fgets(out[n..].ptr, @intCast(out.len - n), f) orelse break;
        n += std.mem.len(@as([*:0]u8, @ptrCast(line)));
    }
    _ = pclose(f);
    return out[0..n];
}

/// 45 quadros (1,5 s) com um buraco de 400 ms (tela parada) e um IDR no meio,
/// e som de 1,5 s com um buraco (silêncio que não foi enviado).
const TestMedia = struct {
    video: std.ArrayList(mp4.VideoSample) = .empty,
    audio: std.ArrayList(mp4.AudioSample) = .empty,

    fn make() !TestMedia {
        initPool();
        const gpa = std.heap.c_allocator;
        var m: TestMedia = .{};
        const w = 320;
        const h = 240;
        const img = try gpa.alloc(u8, w * h * 4);
        defer gpa.free(img);
        var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 800_000, .threads = 1 });
        defer enc.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var ts: u64 = 1_000_000;
        for (0..45) |f| {
            movingSquare(img, w, h, f % 30);
            out.clearRetainingCapacity();
            if (f == 30) enc.forceKey();
            const key = try enc.encode(img.ptr, w * 4, .bgrx, &out) orelse continue;
            try m.video.append(gpa, .{ .data = try gpa.dupe(u8, out.items), .ts_us = ts, .key = key });
            ts += if (f == 20) 400_000 else 33_333;
        }
        var err: c_int = 0;
        const oe = audio.c.opus_encoder_create(48000, 2, audio.c.OPUS_APPLICATION_AUDIO, &err) orelse return error.Opus;
        defer audio.c.opus_encoder_destroy(oe);
        var pcm: [480 * 2]f32 = undefined;
        var pkt: [1500]u8 = undefined;
        for (0..190) |i| {
            for (0..480) |k| {
                const t: f32 = @as(f32, @floatFromInt(i * 480 + k)) / 48000.0;
                const v = 0.3 * @sin(2 * std.math.pi * 440 * t);
                pcm[k * 2] = v;
                pcm[k * 2 + 1] = v;
            }
            const n = audio.c.opus_encode_float(oe, &pcm, 480, &pkt, pkt.len);
            if (n <= 0) return error.Opus;
            if (i >= 60 and i < 80) continue; // buraco de 200 ms
            try m.audio.append(gpa, .{ .data = try gpa.dupe(u8, pkt[0..@intCast(n)]), .ts_us = 1_000_000 + @as(u64, i) * 10_000 });
        }
        return m;
    }

    fn deinit(m: *TestMedia) void {
        const gpa = std.heap.c_allocator;
        for (m.video.items) |s| gpa.free(s.data);
        for (m.audio.items) |s| gpa.free(s.data);
        m.video.deinit(gpa);
        m.audio.deinit(gpa);
    }
};

test "mp4: clipe (H.264 + Opus, duração variável) abre e decodifica no ffmpeg" {
    var m = try TestMedia.make();
    defer m.deinit();
    try testing.expect(m.video.items[0].key);
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/telinha-teste-clipe-{d}.mp4", .{getpid()});
    defer _ = unlink(path.ptr);
    try mp4.writeClip(path, 320, 240, m.video.items, m.audio.items);
    if (access("/usr/bin/ffprobe", 0) != 0) return; // sem ffmpeg na máquina: só confere que escreveu
    var cmd_buf: [256]u8 = undefined;
    var out: [2048]u8 = undefined;
    const probe = run(try std.fmt.bufPrintZ(&cmd_buf, "ffprobe -v error -count_frames -show_entries stream=codec_name,width,height,nb_read_frames -of csv=p=0 {s} 2>&1", .{path}), &out);
    try testing.expect(std.mem.find(u8, probe, "h264,320,240,45") != null);
    try testing.expect(std.mem.find(u8, probe, "opus,") != null);
    // duração ~1,9 s (1,5 s de quadros + o buraco de 400 ms)
    const dur = run(try std.fmt.bufPrintZ(&cmd_buf, "ffprobe -v error -show_entries format=duration -of csv=p=0 {s}", .{path}), &out);
    const secs = std.fmt.parseFloat(f64, std.mem.trim(u8, dur, " \n")) catch 0;
    try testing.expect(secs > 1.7 and secs < 2.1);
    // decodifica inteiro sem erro
    const errs = run(try std.fmt.bufPrintZ(&cmd_buf, "ffmpeg -v error -i {s} -f null - 2>&1", .{path}), &out);
    try testing.expectEqualStrings("", errs);
}

test "mp4: gravação fragmentada abre e decodifica no ffmpeg (inclusive sem o fim)" {
    var m = try TestMedia.make();
    defer m.deinit();
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/telinha-teste-grav-{d}.mp4", .{getpid()});
    defer _ = unlink(path.ptr);
    const r = try mp4.Recorder.start(path, 320, 240, m.video.items[0], true);
    var ai: usize = 0;
    for (m.video.items[1..]) |s| {
        while (ai < m.audio.items.len and m.audio.items[ai].ts_us <= s.ts_us) : (ai += 1) try r.addAudio(m.audio.items[ai]);
        try r.addVideo(s);
    }
    try testing.expect(r.durationMs() > 1500);
    r.finish();
    if (access("/usr/bin/ffprobe", 0) != 0) return;
    var cmd_buf: [256]u8 = undefined;
    var out: [2048]u8 = undefined;
    const probe = run(try std.fmt.bufPrintZ(&cmd_buf, "ffprobe -v error -count_frames -show_entries stream=codec_name,nb_read_frames -of csv=p=0 {s} 2>&1", .{path}), &out);
    try testing.expect(std.mem.find(u8, probe, "h264,45") != null);
    try testing.expect(std.mem.find(u8, probe, "opus,") != null);
    const errs = run(try std.fmt.bufPrintZ(&cmd_buf, "ffmpeg -v error -i {s} -f null - 2>&1", .{path}), &out);
    try testing.expectEqualStrings("", errs);
}

test "mp4: HEVC (NVENC) vira hvc1 que o ffmpeg abre e decodifica, clipe e gravação" {
    initPool();
    const gpa = std.heap.c_allocator;
    const w = 640;
    const h = 360;
    var err: [256]u8 = undefined;
    var enc = codec.HwEncoder.init(.{ .codec = .hevc, .width = w, .height = h, .fps = 30, .bitrate = 1_500_000 }, &err) catch return error.SkipZigTest;
    defer enc.deinit();
    const img = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(img);
    var video: std.ArrayList(mp4.VideoSample) = .empty;
    defer {
        for (video.items) |v| gpa.free(v.data);
        video.deinit(gpa);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..40) |f| {
        movingSquare(img, w, h, f % 30);
        out.clearRetainingCapacity();
        const key = try enc.encode(img.ptr, w * 4, .bgrx, f == 0 or f == 25, &out);
        try video.append(gpa, .{ .data = try gpa.dupe(u8, out.items), .ts_us = 1_000_000 + @as(u64, f) * 33_333, .key = key });
    }
    try testing.expect(mp4.isHevc(video.items[0].data));
    const ps = mp4.paramSets(video.items[0].data);
    try testing.expect(ps.hevc and ps.vps.len > 0 and ps.sps.len > 0 and ps.pps.len > 0);
    var path_buf: [96]u8 = undefined;
    const clip_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/telinha-teste-hevc-{d}.mp4", .{getpid()});
    defer _ = unlink(clip_path.ptr);
    try mp4.writeClip(clip_path, w, h, video.items, &.{});
    var rec_buf: [96]u8 = undefined;
    const rec_path = try std.fmt.bufPrintZ(&rec_buf, "/tmp/telinha-teste-hevc-grav-{d}.mp4", .{getpid()});
    defer _ = unlink(rec_path.ptr);
    const r = try mp4.Recorder.start(rec_path, w, h, video.items[0], false);
    for (video.items[1..]) |v| try r.addVideo(v);
    r.finish();
    if (access("/usr/bin/ffprobe", 0) != 0) return;
    var cmd_buf: [256]u8 = undefined;
    var res: [2048]u8 = undefined;
    for ([_][:0]const u8{ clip_path, rec_path }) |path| {
        const probe = run(try std.fmt.bufPrintZ(&cmd_buf, "ffprobe -v error -count_frames -show_entries stream=codec_name,codec_tag_string,width,height,nb_read_frames -of csv=p=0 {s} 2>&1", .{path}), &res);
        try testing.expect(std.mem.find(u8, probe, "hevc,hvc1,640,360,40") != null);
        const errs = run(try std.fmt.bufPrintZ(&cmd_buf, "ffmpeg -v error -i {s} -f null - 2>&1", .{path}), &res);
        try testing.expectEqualStrings("", errs);
    }
}

test "mp4: NAL units do Annex B, SPS/PPS e conversão pra tamanho+NAL" {
    const bs = [_]u8{ 0, 0, 0, 1, 0x67, 0x64, 0, 0x1f, 0xAA, 0, 0, 1, 0x68, 0xEE, 0, 0, 0, 1, 0x65, 0x88, 0x84, 0, 0, 1, 0x09, 0x10 };
    const ps = mp4.paramSets(&bs);
    try testing.expectEqualSlices(u8, &.{ 0x67, 0x64, 0, 0x1f, 0xAA }, ps.sps);
    try testing.expectEqualSlices(u8, &.{ 0x68, 0xEE }, ps.pps);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    try mp4.toAvcc(&out, &bs, false);
    // só a fatia IDR (SPS/PPS vão no avcC; AUD sai)
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 3, 0x65, 0x88, 0x84 }, out.items);
}

// ------------------------------------------------------------------ VA-API
//
// Decodificar H.264 é bit a bit determinístico: o VA-API tem que dar
// exatamente a mesma imagem que o openh264/ffmpeg. Sem placa/driver com
// VA-API (CI), os testes do decoder são pulados.

const hwva = @cImport(@cInclude("hwva.h"));
const oh = @cImport(@cInclude("wels/codec_api.h"));
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *anyopaque) usize;

fn openVaDecoder() ?*hwva.vadec {
    var err: [256]u8 = undefined;
    @memset(&err, 0);
    return hwva.vadec_open(hwva.HW_CODEC_H264, &err, err.len);
}

/// Imagem de referência em I420.
const RefPic = struct { y: [*]const u8, u: [*]const u8, v: [*]const u8, ys: usize, uvs: usize, w: usize, h: usize };

fn refOf(p: codec.Decoder.Picture) RefPic {
    return .{ .y = p.y, .u = p.u, .v = p.v, .ys = p.ys, .uvs = p.uvs, .w = p.w, .h = p.h };
}

/// Decodifica no VA-API e exige a mesma imagem, pixel a pixel (luma e croma).
fn vaExpectSame(d: *hwva.vadec, bits: []const u8, ref: RefPic, what: []const u8, frame: usize) !void {
    var f: hwva.hwdec_frame = undefined;
    const r = hwva.vadec_decode(d, bits.ptr, @intCast(bits.len), &f);
    if (r != 1) {
        std.debug.print("VA-API ({s}, quadro {d}): decode devolveu {d}\n", .{ what, frame, r });
        return error.VaNoPicture;
    }
    if (f.width != ref.w or f.height != ref.h) {
        std.debug.print("VA-API ({s}, quadro {d}): {d}x{d} em vez de {d}x{d}\n", .{ what, frame, f.width, f.height, ref.w, ref.h });
        return error.VaWrongSize;
    }
    const w = ref.w;
    for (0..ref.h) |y| {
        const a = ref.y[y * ref.ys ..][0..w];
        const b = f.y[y * w ..][0..w];
        if (std.mem.findDiff(u8, a, b)) |x| {
            std.debug.print("VA-API ({s}, quadro {d}): luma diferente em ({d},{d}): {d} != {d}\n", .{ what, frame, x, y, a[x], b[x] });
            return error.VaLumaDiffers;
        }
    }
    for (0..ref.h / 2) |y| for (0..w / 2) |x| {
        const u = ref.u[y * ref.uvs + x];
        const v = ref.v[y * ref.uvs + x];
        if (f.uv[y * w + 2 * x] != u or f.uv[y * w + 2 * x + 1] != v) {
            std.debug.print("VA-API ({s}, quadro {d}): croma diferente em ({d},{d})\n", .{ what, frame, x, y });
            return error.VaChromaDiffers;
        }
    };
}

/// Conteúdo com movimento de verdade: degradê deslizando, "texto" rolando e
/// um quadrado andando (vetores de movimento em várias direções).
fn vaScene(img: []u8, w: usize, h: usize, f: usize) void {
    const sq_x = (20 + f * 13) % (w - 48);
    const sq_y = (10 + f * 5) % (h - 48);
    for (0..h) |y| for (0..w) |x| {
        const p = (y * w + x) * 4;
        var r: u8 = @intCast((x + f * 3) % 256);
        var g: u8 = @intCast((y * 2 + f) % 256);
        var b: u8 = @intCast((x ^ y) & 0xff);
        const ty = (y + f * 4) % 32;
        const tx = x % 12;
        if (y > h / 3 and y < h * 2 / 3 and ty < 12 and (tx == 2 or ty == 5 or tx == ty)) {
            r = 20;
            g = 20;
            b = 20;
        }
        if (x >= sq_x and x < sq_x + 40 and y >= sq_y and y < sq_y + 40) {
            r = 240;
            g = @intCast((x * 5) % 256);
            b = 30;
        }
        img[p + 0] = b;
        img[p + 1] = g;
        img[p + 2] = r;
        img[p + 3] = 255;
    };
}

test "VA-API: SPS/PPS do encoder voltam iguais pelo parser do decoder" {
    var err: [256]u8 = undefined;
    @memset(&err, 0);
    if (hwva.hwva_test_headers(&err, err.len) != 0) {
        std.debug.print("hwva_test_headers: {s}\n", .{std.mem.sliceTo(&err, 0)});
        return error.HeaderMismatch;
    }
}

test "VA-API: encoder abre com autoteste ou falha com motivo claro" {
    initPool();
    const w = 1366;
    const h = 768;
    var err: [256]u8 = undefined;
    @memset(&err, 0);
    const e = hwva.vaenc_open(hwva.HW_CODEC_H264, w, h, 30, 3_000_000, 1, 1, &err, err.len) orelse {
        // sem encoder VA-API (ex.: só o driver NVDEC da NVIDIA): tem que dizer por quê
        const msg = std.mem.sliceTo(&err, 0);
        try testing.expect(std.mem.startsWith(u8, msg, "VA-API: "));
        try testing.expect(msg.len > "VA-API: ".len + 5);
        return;
    };
    defer hwva.vaenc_close(e);
    // tem encoder (Intel/AMD): quadros de verdade, decodificados pelo openh264
    try testing.expect(std.mem.startsWith(u8, std.mem.span(hwva.vaenc_name(e)), "VA-API"));
    var dec = try codec.Decoder.init();
    defer dec.deinit();
    const img = try std.heap.c_allocator.alloc(u8, w * h * 4);
    defer std.heap.c_allocator.free(img);
    for (0..10) |f| {
        vaScene(img, w, h, f);
        if (f == 5) hwva.vaenc_set_bitrate(e, 1_500_000);
        var data: [*c]const u8 = null;
        var len: c_int = 0;
        var idr: c_int = 0;
        try testing.expectEqual(@as(c_int, 0), hwva.vaenc_encode(e, img.ptr, w * 4, hwva.HWENC_BGRX, @intFromBool(f == 7), &data, &len, &idr));
        try testing.expectEqual(f == 0 or f == 7, idr != 0);
        const pic = (try dec.decode(data[0..@intCast(len)])) orelse return error.NoPicture;
        try testing.expectEqual(@as(u32, w), pic.w);
    }
}

test "VA-API: decoder igual ao openh264 bit a bit (camadas, fatias, tamanhos, troca de resolução)" {
    initPool();
    const d = openVaDecoder() orelse return error.SkipZigTest;
    defer hwva.vadec_close(d);
    var ref = try codec.Decoder.init();
    defer ref.deinit();
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const Case = struct { w: u32, h: u32, layers: u8, mode: codec.Mode, threads: u32, frames: usize };
    // o mesmo decoder do começo ao fim: cada caso é uma troca de resolução no meio do fluxo
    const cases = [_]Case{
        .{ .w = 640, .h = 360, .layers = 1, .mode = .screen, .threads = 1, .frames = 12 },
        .{ .w = 1366, .h = 768, .layers = 2, .mode = .motion, .threads = 4, .frames = 12 },
        .{ .w = 320, .h = 240, .layers = 2, .mode = .screen, .threads = 2, .frames = 12 },
        .{ .w = 1280, .h = 720, .layers = 1, .mode = .motion, .threads = 3, .frames = 10 },
        .{ .w = 1366, .h = 768, .layers = 1, .mode = .screen, .threads = 4, .frames = 8 },
    };
    for (cases) |c| {
        const img = try gpa.alloc(u8, c.w * c.h * 4);
        defer gpa.free(img);
        var enc = try codec.Encoder.init(.{ .width = c.w, .height = c.h, .fps = 30, .bitrate = 1_500_000, .threads = c.threads, .mode = c.mode, .temporal_layers = c.layers });
        defer enc.deinit();
        for (0..c.frames) |f| {
            vaScene(img, c.w, c.h, f);
            out.clearRetainingCapacity();
            if (f == 9) enc.forceKey(); // IDR no meio
            _ = try enc.encode(img.ptr, c.w * 4, .bgrx, &out) orelse return error.EncoderSkipped;
            const pic = (try ref.decode(out.items)) orelse return error.NoPicture;
            try vaExpectSame(d, out.items, refOf(pic), "openh264", f);
        }
    }
    var st: hwva.vadec_stats = undefined;
    hwva.vadec_get_stats(d, &st);
    try testing.expect(st.multi_slice > 0); // openh264 com várias threads = várias fatias
}

test "VA-API: decoder igual ao openh264 bit a bit com NVENC (High, CABAC, camadas)" {
    initPool();
    const d = openVaDecoder() orelse return error.SkipZigTest;
    defer hwva.vadec_close(d);
    var ref = try codec.Decoder.init();
    defer ref.deinit();
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const Case = struct { w: u32, h: u32, layers: u8, mode: codec.Mode };
    const cases = [_]Case{
        .{ .w = 640, .h = 360, .layers = 1, .mode = .screen },
        .{ .w = 1366, .h = 768, .layers = 2, .mode = .motion },
        .{ .w = 1920, .h = 1080, .layers = 1, .mode = .motion },
    };
    var ran = false;
    for (cases) |c| {
        var err: [256]u8 = undefined;
        var enc = codec.HwEncoder.init(.{ .width = c.w, .height = c.h, .fps = 30, .bitrate = 3_000_000, .mode = c.mode, .temporal_layers = c.layers }, &err) catch continue;
        defer enc.deinit();
        if (!std.mem.eql(u8, enc.name(), "NVENC")) continue;
        ran = true;
        const img = try gpa.alloc(u8, c.w * c.h * 4);
        defer gpa.free(img);
        for (0..14) |f| {
            vaScene(img, c.w, c.h, f);
            out.clearRetainingCapacity();
            _ = try enc.encode(img.ptr, c.w * 4, .bgrx, f == 0 or f == 10, &out);
            const pic = (try ref.decode(out.items)) orelse return error.NoPicture;
            try vaExpectSame(d, out.items, refOf(pic), "NVENC", f);
        }
    }
    if (!ran) return error.SkipZigTest;
}

/// openh264 em modo tela com referências de longo prazo: usa MMCO (marcar
/// longo prazo, limite de índices) e reordenação por long_term_pic_num, que o
/// encoder do app não usa — mas o decoder tem que aguentar fluxos de fora.
const LtrEncoder = struct {
    enc: [*c]oh.ISVCEncoder,
    w: u32,
    h: u32,
    ts: u64 = 0,
    y: []u8,
    u: []u8,
    v: []u8,

    fn init(w: u32, h: u32, cabac: bool) !LtrEncoder {
        var enc: [*c]oh.ISVCEncoder = null;
        if (oh.WelsCreateSVCEncoder(&enc) != 0 or enc == null) return error.EncoderCreate;
        errdefer oh.WelsDestroySVCEncoder(enc);
        var trace: c_int = oh.WELS_LOG_QUIET;
        _ = enc.*.*.SetOption.?(enc, oh.ENCODER_OPTION_TRACE_LEVEL, &trace);
        var p: oh.SEncParamExt = undefined;
        _ = enc.*.*.GetDefaultParams.?(enc, &p);
        p.iUsageType = oh.SCREEN_CONTENT_REAL_TIME;
        p.iPicWidth = @intCast(w);
        p.iPicHeight = @intCast(h);
        p.iTargetBitrate = 1_500_000;
        p.iMaxBitrate = oh.UNSPECIFIED_BIT_RATE;
        p.iRCMode = oh.RC_BITRATE_MODE;
        p.fMaxFrameRate = 30;
        p.iSpatialLayerNum = 1;
        p.iTemporalLayerNum = 1;
        p.uiIntraPeriod = 0;
        p.bEnableFrameSkip = false;
        p.iMultipleThreadIdc = 1;
        p.bEnableLongTermReference = true;
        p.bIsLosslessLink = true; // sem isso o openh264 desliga o LTR em modo tela
        p.iLTRRefNum = 4;
        p.iNumRefFrame = oh.AUTO_REF_PIC_COUNT;
        p.iEntropyCodingModeFlag = @intFromBool(cabac);
        p.eSpsPpsIdStrategy = oh.CONSTANT_ID;
        const l = &p.sSpatialLayers[0];
        l.iVideoWidth = @intCast(w);
        l.iVideoHeight = @intCast(h);
        l.fFrameRate = 30;
        l.iSpatialBitrate = 1_500_000;
        l.iMaxSpatialBitrate = oh.UNSPECIFIED_BIT_RATE;
        l.sSliceArgument.uiSliceMode = oh.SM_FIXEDSLCNUM_SLICE;
        l.sSliceArgument.uiSliceNum = 2;
        if (enc.*.*.InitializeExt.?(enc, &p) != 0) return error.EncoderInit;
        var fmt: c_int = oh.videoFormatI420;
        _ = enc.*.*.SetOption.?(enc, oh.ENCODER_OPTION_DATAFORMAT, &fmt);
        const gpa = std.heap.c_allocator;
        const n = @as(usize, w) * h;
        return .{ .enc = enc, .w = w, .h = h, .y = try gpa.alloc(u8, n), .u = try gpa.alloc(u8, n / 4), .v = try gpa.alloc(u8, n / 4) };
    }

    fn deinit(e: *LtrEncoder) void {
        _ = e.enc.*.*.Uninitialize.?(e.enc);
        oh.WelsDestroySVCEncoder(e.enc);
        const gpa = std.heap.c_allocator;
        gpa.free(e.y);
        gpa.free(e.u);
        gpa.free(e.v);
    }

    fn encode(e: *LtrEncoder, img: []const u8, out: *std.ArrayList(u8)) !void {
        codec.toI420(img.ptr, e.w * 4, e.w, e.h, .bgrx, e.y, e.u, e.v);
        var pic = std.mem.zeroes(oh.SSourcePicture);
        pic.iColorFormat = oh.videoFormatI420;
        pic.iPicWidth = @intCast(e.w);
        pic.iPicHeight = @intCast(e.h);
        pic.iStride[0] = @intCast(e.w);
        pic.iStride[1] = @intCast(e.w / 2);
        pic.iStride[2] = @intCast(e.w / 2);
        pic.pData[0] = e.y.ptr;
        pic.pData[1] = e.u.ptr;
        pic.pData[2] = e.v.ptr;
        pic.uiTimeStamp = @intCast(e.ts);
        e.ts += 33;
        var info = std.mem.zeroes(oh.SFrameBSInfo);
        if (e.enc.*.*.EncodeFrame.?(e.enc, &pic, &info) != 0) return error.Encode;
        if (info.eFrameType == oh.videoFrameTypeSkip) return error.EncoderSkipped;
        for (0..@intCast(info.iLayerNum)) |li| {
            const layer = &info.sLayerInfo[li];
            var len: usize = 0;
            for (0..@intCast(layer.iNalCount)) |ni| len += @intCast(layer.pNalLengthInByte[ni]);
            try out.appendSlice(std.heap.c_allocator, layer.pBsBuf[0..len]);
        }
    }
};

/// Tela de "documento": trechos que somem e voltam (bom pra referência de longo prazo).
fn ltrScene(img: []u8, w: usize, h: usize, f: usize) void {
    const page = (f / 6) % 3; // alterna entre 3 "páginas"
    for (0..h) |y| for (0..w) |x| {
        const p = (y * w + x) * 4;
        const tx = (x + page * 5) % 10;
        const ty = (y + page * 7 + f % 6) % 18;
        const ink = ty < 11 and (tx == 1 or ty == 4 or tx == ty / 2) and ((x / 10 + y / 18 + page) % 4 != 0);
        const v: u8 = if (ink) 25 else @intCast(230 - (y * 20 / h));
        img[p + 0] = v;
        img[p + 1] = v;
        img[p + 2] = if (ink and page == 1) 200 else v;
        img[p + 3] = 255;
    };
}

test "VA-API: decoder com referências de longo prazo e MMCO (openh264 em modo tela)" {
    initPool();
    const d = openVaDecoder() orelse return error.SkipZigTest;
    defer hwva.vadec_close(d);
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const w = 640;
    const h = 368;
    const frames = 48;
    const img = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(img);
    {
        // CAVLC: referência = decoder do openh264
        var ref = try codec.Decoder.init();
        defer ref.deinit();
        var enc = try LtrEncoder.init(w, h, false);
        defer enc.deinit();
        for (0..frames) |f| {
            ltrScene(img, w, h, f);
            out.clearRetainingCapacity();
            try enc.encode(img, &out);
            const pic = (try ref.decode(out.items)) orelse return error.NoPicture;
            try vaExpectSame(d, out.items, refOf(pic), "openh264 LTR", f);
        }
    }
    var st: hwva.vadec_stats = undefined;
    hwva.vadec_get_stats(d, &st);
    try testing.expect(st.long_term > 0 and st.mmco > 0 and st.reorder > 0);
    // CABAC: o decoder do openh264 diverge do ffmpeg nesse fluxo (o VA-API bate
    // com o ffmpeg); a referência aqui é o ffmpeg, se tiver
    if (access("/usr/bin/ffmpeg", 0) != 0) return;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/telinha-teste-va-ltr-{d}.h264", .{getpid()});
    defer _ = unlink(path.ptr);
    var aus: std.ArrayList([]u8) = .empty;
    defer {
        for (aus.items) |au| gpa.free(au);
        aus.deinit(gpa);
    }
    {
        var enc = try LtrEncoder.init(w, h, true);
        defer enc.deinit();
        const fp = std.c.fopen(path.ptr, "w") orelse return error.TmpFile;
        for (0..frames) |f| {
            ltrScene(img, w, h, f);
            out.clearRetainingCapacity();
            try enc.encode(img, &out);
            _ = std.c.fwrite(out.items.ptr, 1, out.items.len, fp);
            try aus.append(gpa, try gpa.dupe(u8, out.items));
        }
        _ = std.c.fclose(fp);
    }
    var yuv: std.ArrayList(u8) = .empty;
    defer yuv.deinit(gpa);
    var cmd_buf: [256]u8 = undefined;
    try readCmd(try std.fmt.bufPrintZ(&cmd_buf, "ffmpeg -v error -i {s} -f rawvideo -pix_fmt yuv420p -", .{path}), &yuv);
    const fsize = w * h * 3 / 2;
    try testing.expectEqual(frames * fsize, yuv.items.len);
    for (aus.items, 0..) |au, f| {
        const base = yuv.items[f * fsize ..].ptr;
        const r: RefPic = .{ .y = base, .u = base + w * h, .v = base + w * h * 5 / 4, .ys = w, .uvs = w / 2, .w = w, .h = h };
        try vaExpectSame(d, au, r, "openh264 LTR CABAC", f);
    }
}

test "VA-API: quadro perdido não quebra; o próximo IDR volta exato" {
    initPool();
    const d = openVaDecoder() orelse return error.SkipZigTest;
    defer hwva.vadec_close(d);
    var ref = try codec.Decoder.init();
    defer ref.deinit();
    const gpa = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const w = 640;
    const h = 360;
    const img = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(img);
    var f_out: hwva.hwdec_frame = undefined;
    {
        // uma camada: perder um P de referência quebra a cadeia até o IDR
        var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 1_000_000, .threads = 2 });
        defer enc.deinit();
        for (0..30) |f| {
            vaScene(img, w, h, f);
            out.clearRetainingCapacity();
            if (f == 16) enc.forceKey();
            const key = try enc.encode(img.ptr, w * 4, .bgrx, &out) orelse return error.EncoderSkipped;
            const pic = (try ref.decode(out.items)) orelse return error.NoPicture;
            if (f == 8) continue; // perdido no caminho
            if (f == 3) {
                // pacote cortado ao meio: pode dar erro ou imagem errada, mas não pode travar
                _ = hwva.vadec_decode(d, out.items.ptr, @intCast(out.items.len / 2), &f_out);
                continue;
            }
            if (f > 3 and f < 8) {
                // depois do pacote cortado: imagem errada é aceitável até o IDR
                _ = hwva.vadec_decode(d, out.items.ptr, @intCast(out.items.len), &f_out);
                continue;
            }
            if (f > 8 and f < 16) {
                // sem a referência: erro (quem chama pede um IDR), nunca imagem montada no escuro
                try testing.expect(!key);
                try testing.expect(hwva.vadec_decode(d, out.items.ptr, @intCast(out.items.len), &f_out) < 0);
                continue;
            }
            try testing.expect(f < 3 or f >= 16);
            try vaExpectSame(d, out.items, refOf(pic), "perda (1 camada)", f);
        }
    }
    {
        // duas camadas: o espectador lento pula os quadros que ninguém referencia, sem erro nenhum
        var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = 1_000_000, .threads = 2, .temporal_layers = 2 });
        defer enc.deinit();
        for (0..20) |f| {
            vaScene(img, w, h, f);
            out.clearRetainingCapacity();
            _ = try enc.encode(img.ptr, w * 4, .bgrx, &out) orelse return error.EncoderSkipped;
            const pic = (try ref.decode(out.items)) orelse return error.NoPicture;
            if (codec.isDroppable(out.items)) continue;
            try vaExpectSame(d, out.items, refOf(pic), "perda (2 camadas)", f);
        }
    }
    // lixo puro também não pode derrubar
    var junk: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    for (0..20) |i| {
        prng.random().bytes(&junk);
        junk[0] = 0;
        junk[1] = 0;
        junk[2] = 1;
        junk[3] = @as(u8, @intCast(i % 2)) * 4 + 0x41 + @as(u8, @intCast(i % 3)) * 0x20; // fatias e IDRs "válidos" no cabeçalho
        _ = hwva.vadec_decode(d, &junk, junk.len, &f_out);
    }
}

/// Lê tudo o que um comando escreve no stdout (binário).
fn readCmd(cmd: [:0]const u8, out: *std.ArrayList(u8)) !void {
    const f = popen(cmd.ptr, "r") orelse return error.Popen;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(std.heap.c_allocator, buf[0..n]);
    }
    _ = pclose(f);
}

/// Separa um fluxo Annex B em quadros (access units): começa um novo no
/// AUD/SPS/PPS/SEI ou na fatia com first_mb_in_slice = 0, se o atual já tem fatia.
fn splitAccessUnits(bits: []const u8, aus: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var has_vcl = false;
    var i: usize = 0;
    while (i + 4 < bits.len) : (i += 1) {
        if (!(bits[i] == 0 and bits[i + 1] == 0 and bits[i + 2] == 1)) continue;
        const nal_at = if (i > 0 and bits[i - 1] == 0) i - 1 else i;
        const typ = bits[i + 3] & 0x1f;
        const vcl = typ == 1 or typ == 5;
        const first_slice = vcl and (bits[i + 4] & 0x80) != 0; // ue(0) = bit 1
        if (has_vcl and (first_slice or typ == 9 or typ == 7 or typ == 8 or typ == 6)) {
            try aus.append(std.heap.c_allocator, bits[start..nal_at]);
            start = nal_at;
            has_vcl = false;
        }
        if (vcl) has_vcl = true;
        i += 2;
    }
    if (has_vcl) try aus.append(std.heap.c_allocator, bits[start..]);
}

test "VA-API: decoder igual ao ffmpeg bit a bit com x264 (CAVLC/CABAC, várias refs, pesos, matrizes, fatias)" {
    const d = openVaDecoder() orelse return error.SkipZigTest;
    defer hwva.vadec_close(d);
    if (access("/usr/bin/ffmpeg", 0) != 0) return error.SkipZigTest;
    var probe: [8192]u8 = undefined;
    if (std.mem.find(u8, run("ffmpeg -hide_banner -encoders 2>/dev/null", &probe), "libx264") == null) return error.SkipZigTest;
    const gpa = std.heap.c_allocator;
    const Case = struct { w: u32, h: u32, profile: []const u8, params: []const u8 };
    const cases = [_]Case{
        // High: CABAC, 8x8, matrizes de quantização (JVT), 4 refs, pesos com referências duplicadas (reordenação), 4 fatias
        .{ .w = 640, .h = 360, .profile = "high", .params = "bframes=0:ref=4:weightp=2:slices=4:cqm=jvt:keyint=20:min-keyint=20:scenecut=0" },
        // Main CAVLC, tamanho quebrado (corte), pesos simples, 3 fatias, sem deblocking
        .{ .w = 1366, .h = 768, .profile = "main", .params = "bframes=0:ref=3:cabac=0:weightp=1:slices=3:no-deblock=1:keyint=25:min-keyint=25:scenecut=0" },
        // Constrained Baseline, intra restrito, 2 fatias
        .{ .w = 352, .h = 288, .profile = "baseline", .params = "bframes=0:ref=2:slices=2:constrained-intra=1:keyint=30:min-keyint=30:scenecut=0" },
        // High com 8 refs, offsets no deblocking e no croma
        .{ .w = 1280, .h = 720, .profile = "high", .params = "bframes=0:ref=8:weightp=2:deblock=-2,1:chroma-qp-offset=3:keyint=40:scenecut=0" },
    };
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/telinha-teste-va-{d}.h264", .{getpid()});
    defer _ = unlink(path.ptr);
    var cmd_buf: [1024]u8 = undefined;
    for (cases, 0..) |c, ci| {
        const frames = 45;
        // fade in/out: o x264 só usa predição com pesos quando o brilho muda
        _ = run(try std.fmt.bufPrintZ(&cmd_buf, "ffmpeg -v error -y -f lavfi -i testsrc2=size={d}x{d}:rate=30 -vf fade=in:0:12,fade=out:30:12,format=yuv420p -frames:v {d} -c:v libx264 -preset faster -profile:v {s} -x264-params {s} -f h264 {s} 2>&1", .{ c.w, c.h, frames, c.profile, c.params, path }), &probe);
        var bits: std.ArrayList(u8) = .empty;
        defer bits.deinit(gpa);
        try readCmd(try std.fmt.bufPrintZ(&cmd_buf, "cat {s}", .{path}), &bits);
        var yuv: std.ArrayList(u8) = .empty;
        defer yuv.deinit(gpa);
        try readCmd(try std.fmt.bufPrintZ(&cmd_buf, "ffmpeg -v error -i {s} -f rawvideo -pix_fmt yuv420p -", .{path}), &yuv);
        var aus: std.ArrayList([]const u8) = .empty;
        defer aus.deinit(gpa);
        try splitAccessUnits(bits.items, &aus);
        const fsize = c.w * c.h * 3 / 2;
        try testing.expectEqual(@as(usize, frames), aus.items.len);
        try testing.expectEqual(frames * fsize, yuv.items.len);
        for (aus.items, 0..) |au, f| {
            const base = yuv.items[f * fsize ..].ptr;
            const r: RefPic = .{ .y = base, .u = base + c.w * c.h, .v = base + c.w * c.h * 5 / 4, .ys = c.w, .uvs = c.w / 2, .w = c.w, .h = c.h };
            var what_buf: [64]u8 = undefined;
            try vaExpectSame(d, au, r, try std.fmt.bufPrint(&what_buf, "x264 caso {d}", .{ci}), f);
        }
        if (ci == 0) {
            // perda num fluxo com várias referências: erro até o próximo IDR (quadro 20), depois exato
            for (aus.items, 0..) |au, f| {
                if (f == 5) continue;
                if (f > 5 and f < 20) {
                    var fr: hwva.hwdec_frame = undefined;
                    try testing.expect(hwva.vadec_decode(d, au.ptr, @intCast(au.len), &fr) < 0);
                    continue;
                }
                const base = yuv.items[f * fsize ..].ptr;
                const r: RefPic = .{ .y = base, .u = base + c.w * c.h, .v = base + c.w * c.h * 5 / 4, .ys = c.w, .uvs = c.w / 2, .w = c.w, .h = c.h };
                try vaExpectSame(d, au, r, "x264 com perda", f);
            }
        }
    }
    var st: hwva.vadec_stats = undefined;
    hwva.vadec_get_stats(d, &st);
    try testing.expect(st.weighted > 0 and st.scaling > 0 and st.multi_slice > 0 and st.reorder > 0);
}

// ------------------------------------------------------------------ idioma

/// Duas letras seguidas fora dos {} (texto pra traduzir, não só formato/ícone).
fn hasWords(s: []const u8) bool {
    var depth: usize = 0;
    var letters: usize = 0;
    for (s) |ch| {
        if (ch == '{') depth += 1 else if (ch == '}' and depth > 0) depth -= 1;
        if (depth == 0 and std.ascii.isAlphabetic(ch)) {
            letters += 1;
            if (letters >= 2) return true;
        } else letters = 0;
    }
    return false;
}

/// Textos passados direto pra interface sem tr()/fmtZ() (a tradução não
/// pegaria). Os "##id" e os que nunca mudam ficam de fora.
fn untranslated(name: []const u8, src: []const u8) usize {
    const calls = [_][]const u8{
        "drawTextF(",       "drawTextWrapF(",     "textColored(",         "tooltipText(",       "primaryButton(",
        "secondaryButton(", "iconButton(",        "igCheckbox(",          "igSelectable_Bool(", "igSmallButton(",
        "igOpenPopup_Str(", "igBeginPopupModal(", "igInputTextWithHint(", "setHomeError(",      "notifyAway(",
        "beginCombo(",      "p.button(",          "igSetTooltip(",        "igButton(",
    };
    const fixed = [_][]const u8{ "telinha", "Português###lang1", "English###lang2" };
    var bad: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var ln: usize = 0;
    while (lines.next()) |line| {
        ln += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//")) continue;
        const relevant = for (calls) |cl| {
            if (std.mem.indexOf(u8, line, cl) != null) break true;
        } else false;
        if (!relevant) continue;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, i, '"')) |q| {
            var e = q + 1;
            while (e < line.len and line[e] != '"') : (e += 1) {
                if (line[e] == '\\') e += 1;
            }
            if (e >= line.len) break;
            const lit = line[q + 1 .. e];
            i = e + 1;
            const before = std.mem.trimEnd(u8, line[0..q], " ");
            const callee = before[0 .. std.mem.lastIndexOfScalar(u8, before, '(') orelse 0];
            const wrapped = std.mem.endsWith(u8, before, "tr(") or std.mem.endsWith(u8, before, "fmtZ(") or
                std.mem.endsWith(u8, callee, "bufPrint") or std.mem.endsWith(u8, callee, "bufPrintZ");
            const is_fixed = for (fixed) |f| {
                if (std.mem.eql(u8, lit, f)) break true;
            } else false;
            if (wrapped or is_fixed or !hasWords(lit[0 .. std.mem.indexOf(u8, lit, "##") orelse lit.len])) continue;
            std.debug.print("{s}:{d}: texto sem tradução: \"{s}\"\n", .{ name, ln, lit });
            bad += 1;
        }
    }
    return bad;
}

test "idioma: todo texto da interface passa pela tradução" {
    const bad = untranslated("src/ui.zig", @embedFile("ui.zig")) + untranslated("src/pip.zig", @embedFile("pip.zig"));
    try testing.expectEqual(@as(usize, 0), bad);
}

/// A conversão escalar que o hwva.c e o hwenc_mf.c faziam antes (referência).
fn nv12Escalar(src: []const u8, stride: usize, w: usize, h: usize, rgbx: bool, y: []u8, ys: usize, uv: []u8, uvs: usize) void {
    const ri: usize = if (rgbx) 0 else 2;
    const bi: usize = if (rgbx) 2 else 0;
    var row: usize = 0;
    while (row < h) : (row += 2) {
        var x: usize = 0;
        while (x < w) : (x += 2) {
            var rs: i32 = 0;
            var gs: i32 = 0;
            var bs: i32 = 0;
            for (0..4) |k| {
                const ry = row + k / 2;
                const px = src[ry * stride + (x + k % 2) * 4 ..];
                const r: i32 = px[ri];
                const g: i32 = px[1];
                const b: i32 = px[bi];
                const yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                y[ry * ys + x + k % 2] = @intCast(@min(yy, 255));
                rs += r;
                gs += g;
                bs += b;
            }
            rs = @divTrunc(rs + 2, 4);
            gs = @divTrunc(gs + 2, 4);
            bs = @divTrunc(bs + 2, 4);
            const u = ((-38 * rs - 74 * gs + 112 * bs + 128) >> 8) + 128;
            const v = ((112 * rs - 94 * gs - 18 * bs + 128) >> 8) + 128;
            uv[row / 2 * uvs + x] = @intCast(std.math.clamp(u, 0, 255));
            uv[row / 2 * uvs + x + 1] = @intCast(std.math.clamp(v, 0, 255));
        }
    }
}

test "NV12 vetorizado: igual bit a bit à conversão escalar antiga (pitch, largura quebrada, BGRX e RGBX)" {
    const sizes = [_][2]usize{ .{ 50, 34 }, .{ 64, 48 }, .{ 1280, 720 }, .{ 2, 2 } };
    for (sizes) |sz| {
        const w = sz[0];
        const h = sz[1];
        const stride = w * 4 + 12;
        const ys = w + 6;
        const uvs = w + 10;
        const gpa = std.testing.allocator;
        const src = try gpa.alloc(u8, stride * h);
        defer gpa.free(src);
        var seed: u32 = @intCast(w * 31 + h);
        for (src) |*b| {
            seed = seed *% 1103515245 +% 12345;
            b.* = @truncate(seed >> 16);
        }
        // cantos extremos (preto e branco puros) no começo
        @memset(src[0..8], 0);
        @memset(src[stride .. stride + 8], 255);
        for ([_]bool{ false, true }) |rgbx| {
            const y1 = try gpa.alloc(u8, ys * h);
            defer gpa.free(y1);
            const y2 = try gpa.alloc(u8, ys * h);
            defer gpa.free(y2);
            const uv1 = try gpa.alloc(u8, uvs * h / 2);
            defer gpa.free(uv1);
            const uv2 = try gpa.alloc(u8, uvs * h / 2);
            defer gpa.free(uv2);
            @memset(y1, 0xAA);
            @memset(y2, 0xAA);
            @memset(uv1, 0xAA);
            @memset(uv2, 0xAA);
            nv12Escalar(src, stride, w, h, rgbx, y1, ys, uv1, uvs);
            codec.toNV12(src.ptr, stride, w, h, if (rgbx) .rgbx else .bgrx, y2, ys, uv2, uvs);
            try std.testing.expectEqualSlices(u8, y1, y2); // inclusive o que fica fora da largura (intocado)
            try std.testing.expectEqualSlices(u8, uv1, uv2);
        }
    }
}

test "escala na placa (CUDA, caminho do Windows) igual à conta na CPU" {
    const cg_c = @cImport(@cInclude("cudagl.h"));
    const g = cg_c.cudagl_open() orelse return error.SkipZigTest; // sem NVIDIA
    defer cg_c.cudagl_close(g);
    const sw = 1920;
    const sh = 1080;
    var rng = std.Random.DefaultPrng.init(7);
    const src = try std.testing.allocator.alloc(u8, sw * sh * 4);
    defer std.testing.allocator.free(src);
    rng.random().bytes(src);
    var sp: c_int = 0;
    const dsrc = cg_c.cudagl_alloc(g, sw * 4, sh, &sp);
    defer cg_c.cudagl_free(g, dsrc);
    try std.testing.expect(dsrc != 0);
    try std.testing.expectEqual(@as(c_int, 0), cg_c.cudagl_host_to_dev(g, src.ptr, sw * 4, dsrc, sp, sw * 4, sh));
    const Case = struct { cx: u32, cy: u32, cw: u32, ch: u32, ow: u32, oh: u32 };
    for ([_]Case{
        .{ .cx = 0, .cy = 0, .cw = sw, .ch = sh, .ow = 1280, .oh = 720 }, // escala
        .{ .cx = 100, .cy = 50, .cw = 800, .ch = 600, .ow = 800, .oh = 600 }, // recorte sem escala
        .{ .cx = 300, .cy = 200, .cw = 1000, .ch = 500, .ow = 640, .oh = 320 }, // recorte + escala
    }) |k| {
        var dp: c_int = 0;
        const ddst = cg_c.cudagl_alloc(g, @intCast(k.ow * 4), @intCast(k.oh), &dp);
        defer cg_c.cudagl_free(g, ddst);
        try std.testing.expectEqual(@as(c_int, 0), cg_c.cudagl_scale(g, dsrc, sp, @intCast(k.cx), @intCast(k.cy), @intCast(k.cw), @intCast(k.ch), ddst, dp, @intCast(k.ow), @intCast(k.oh)));
        const got = try std.testing.allocator.alloc(u8, k.ow * k.oh * 4);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqual(@as(c_int, 0), cg_c.cudagl_dev_to_host(g, ddst, dp, got.ptr, @intCast(k.ow * 4), @intCast(k.ow * 4), @intCast(k.oh)));
        // referência: a mesma conta do kernel (cuda_scale.c)
        var worst: u32 = 0;
        for (0..k.oh) |y| for (0..k.ow) |x| {
            const o = (y * k.ow + x) * 4;
            try std.testing.expectEqual(@as(u8, 255), got[o + 3]);
            if (k.cw == k.ow and k.ch == k.oh) {
                const s = ((k.cy + y) * sw + k.cx + x) * 4;
                try std.testing.expectEqualSlices(u8, src[s..][0..3], got[o..][0..3]);
                continue;
            }
            const fx = @max(0, (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(k.cw)) / @as(f32, @floatFromInt(k.ow)) - 0.5);
            const fy = @max(0, (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(k.ch)) / @as(f32, @floatFromInt(k.oh)) - 0.5);
            const x0: usize = @min(@as(usize, @intFromFloat(fx)), k.cw - 1);
            const y0: usize = @min(@as(usize, @intFromFloat(fy)), k.ch - 1);
            const x1 = @min(x0 + 1, k.cw - 1);
            const y1 = @min(y0 + 1, k.ch - 1);
            const wx: u32 = @intFromFloat((fx - @as(f32, @floatFromInt(x0))) * 256);
            const wy: u32 = @intFromFloat((fy - @as(f32, @floatFromInt(y0))) * 256);
            for (0..3) |ch| {
                const p = struct {
                    fn at(img: []const u8, xx: usize, yy: usize, c: usize) u32 {
                        return img[(yy * sw + xx) * 4 + c];
                    }
                };
                const top = p.at(src, k.cx + x0, k.cy + y0, ch) * (256 - wx) + p.at(src, k.cx + x1, k.cy + y0, ch) * wx;
                const bot = p.at(src, k.cx + x0, k.cy + y1, ch) * (256 - wx) + p.at(src, k.cx + x1, k.cy + y1, ch) * wx;
                const want: u32 = (top * (256 - wy) + bot * wy + 32768) >> 16;
                const d: u32 = @intCast(@abs(@as(i32, @intCast(want)) - @as(i32, got[o + ch])));
                worst = @max(worst, d);
            }
        };
        // a GPU arredonda o float um pouco diferente: no máximo 1-2 níveis
        try std.testing.expect(worst <= 2);
    }
}

test "conversor VA-API (Intel/AMD): abre e passa no autoteste, ou recusa sem travar" {
    const hv = @cImport(@cInclude("hwva.h"));
    var err: [256]u8 = [_]u8{0} ** 256;
    if (hv.vapp_open(&err, err.len)) |vp| {
        // máquina com VPP e encoder: o autoteste de cor já passou na abertura
        hv.vapp_close(vp);
    } else {
        try std.testing.expect(std.mem.sliceTo(&err, 0).len > 0); // diz por quê
        std.debug.print("(conversor VA-API indisponível aqui: {s})\n", .{std.mem.sliceTo(&err, 0)});
    }
}
