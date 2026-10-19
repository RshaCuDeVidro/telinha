//! Testes: `zig build test`.
const std = @import("std");
const testing = std.testing;
const sync = @import("sync.zig");
const codec = @import("codec.zig");
const crypto = @import("crypto.zig");
const proto = @import("proto.zig");

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
    q.dropFrames(1);
    try testing.expectEqual(before - 15, q.queuedBytes());
    q.dropFrames(null);
    try testing.expectEqual(@as(usize, 8), q.queuedBytes());
}
