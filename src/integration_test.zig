//! Testes de integração do servidor: sobe uma sala de verdade (localhost)
//! e conversa com ela pelo protocolo cifrado.
const std = @import("std");
const testing = std.testing;
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const crypto = @import("crypto.zig");
const Server = @import("server.zig").Server;

var next_port: u16 = 47100;
fn freshPort() u16 {
    next_port += 1;
    return next_port;
}

/// Cliente mínimo, síncrono, pra teste.
const TestClient = struct {
    sock: net.Socket,
    ch: crypto.Channel,
    rb: proto.RecvBuf = .{},
    id: u32 = 0,

    fn connect(port: u16, name: []const u8, password: []const u8, token: []const u8) !TestClient {
        const s = try net.connect("127.0.0.1", port);
        errdefer net.close(s);
        net.setRecvTimeout(s, 5000);
        const hs = try crypto.Handshake.init();
        try net.sendAll(s, &hs.helloBytes(proto.version));
        var hb: [crypto.hello_len]u8 = undefined;
        try net.recvAll(s, &hb);
        var c: TestClient = .{ .sock = s, .ch = try crypto.Channel.derive(&hs, try crypto.parseHello(&hb), true, password) };
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.hello);
        try b.str(name);
        try b.str(token);
        try c.send(try b.finish());
        return c;
    }

    fn send(c: *TestClient, m: *proto.Msg) !void {
        defer m.release();
        const plain = m.data[4..];
        var out = try std.heap.c_allocator.alloc(u8, 4 + plain.len + crypto.tag_len);
        defer std.heap.c_allocator.free(out);
        std.mem.writeInt(u32, out[0..4], @intCast(plain.len + crypto.tag_len), .little);
        c.ch.seal(plain, out[4..]);
        try net.sendAll(c.sock, out);
    }

    /// Lê mensagens até achar uma do tipo pedido.
    fn expect(c: *TestClient, typ: proto.Type) ![]const u8 {
        for (0..50) |_| {
            const t = try proto.recvMsg(c.sock, &c.ch, &c.rb);
            if (t == typ) return proto.payloadOf(&c.rb);
        }
        return error.NotFound;
    }

    fn welcome(c: *TestClient) !void {
        var r: proto.Reader = .{ .data = try c.expect(.welcome) };
        c.id = try r.u32_();
    }

    fn close(c: *TestClient) void {
        c.rb.deinit();
        net.close(c.sock);
    }
};

fn frameMsg(key: bool, payload_len: usize) !*proto.Msg {
    const m = try proto.Msg.alloc(.frame, proto.frame_header_len + payload_len);
    const p = m.payload();
    @memset(p, 0xAB);
    std.mem.writeInt(u32, p[0..4], 1, .little);
    p[4] = if (key) proto.frame_key else 0;
    std.mem.writeInt(u64, p[5..13], 0, .little);
    std.mem.writeInt(u16, p[13..15], 64, .little);
    std.mem.writeInt(u16, p[15..17], 64, .little);
    return m;
}

test "sala: entrar, senha errada, chat" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .password = "abc", .room_name = "Sala de teste" });
    defer srv.stop();

    var a = try TestClient.connect(port, "Ana", "abc", "");
    defer a.close();
    try a.welcome();

    // senha errada: servidor manda o marcador e fecha
    var bad = try TestClient.connect(port, "Mal", "errada", "");
    defer bad.close();
    try testing.expectError(error.WrongPassword, proto.recvMsg(bad.sock, &bad.ch, &bad.rb));

    var b = try TestClient.connect(port, "Ana", "abc", ""); // nome repetido
    defer b.close();
    try b.welcome();

    var m: proto.Builder = .{};
    defer m.deinit();
    try m.begin(.chat);
    try m.str("olá sala");
    try b.send(try m.finish());

    // a Ana original recebe a mensagem do "Ana (2)"
    while (true) {
        var r: proto.Reader = .{ .data = try a.expect(.chat) };
        const from = try r.u32_();
        const name = try r.str();
        const text = try r.str();
        if (from == 0) continue; // mensagens do sistema
        try testing.expectEqual(b.id, from);
        try testing.expectEqualStrings("Ana (2)", name);
        try testing.expectEqualStrings("olá sala", text);
        break;
    }
}

test "sala: frames só vão pra quem assiste, começando por IDR" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();

    var streamer = try TestClient.connect(port, "Transmissor", "", "");
    defer streamer.close();
    try streamer.welcome();
    var viewer = try TestClient.connect(port, "Espectador", "", "");
    defer viewer.close();
    try viewer.welcome();

    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.stream_start);
    try b.u16_(64);
    try b.u16_(64);
    try b.u8_(30);
    try streamer.send(try b.finish());

    try b.begin(.watch);
    try b.u32_(streamer.id);
    try b.u8_(1);
    try viewer.send(try b.finish());

    // o servidor pede um IDR pro transmissor
    _ = try streamer.expect(.keyreq);
    // um P-frame antes do IDR não pode chegar no espectador
    try streamer.send(try frameMsg(false, 100));
    try streamer.send(try frameMsg(true, 200));
    var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
    try testing.expectEqual(streamer.id, try r.u32_());
    _ = try r.u32_(); // seq
    try testing.expectEqual(proto.frame_key, try r.u8_());
    try testing.expectEqual(@as(usize, 8 + 2 + 2 + 200), r.rest().len);
}

test "sala: admin expulsa, membro comum não" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "token-do-dono" });
    defer srv.stop();

    var admin = try TestClient.connect(port, "Dono", "", "token-do-dono");
    defer admin.close();
    try admin.welcome();
    var other = try TestClient.connect(port, "Visita", "", "");
    defer other.close();
    try other.welcome();

    var b: proto.Builder = .{};
    defer b.deinit();
    // visita tenta expulsar o dono: nada acontece
    try b.begin(.kick);
    try b.u32_(admin.id);
    try other.send(try b.finish());
    // dono expulsa a visita
    try b.begin(.kick);
    try b.u32_(other.id);
    try admin.send(try b.finish());

    var r: proto.Reader = .{ .data = try other.expect(.denied) };
    try testing.expectEqualStrings("Você foi removido da sala.", try r.str());
    sync.sleepMs(500);
    try testing.expectEqual(@as(usize, 1), srv.memberCount());
}

test "sala: espectador lento perde o atraso e recebe IDR de novo" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();

    var streamer = try TestClient.connect(port, "T", "", "");
    defer streamer.close();
    try streamer.welcome();
    var viewer = try TestClient.connect(port, "E", "", "");
    defer viewer.close();
    try viewer.welcome();

    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.stream_start);
    try b.u16_(64);
    try b.u16_(64);
    try b.u8_(30);
    try streamer.send(try b.finish());
    try b.begin(.watch);
    try b.u32_(streamer.id);
    try b.u8_(1);
    try viewer.send(try b.finish());
    _ = try streamer.expect(.keyreq);
    try streamer.send(try frameMsg(true, 1000));

    // o espectador para de ler; o transmissor manda bem mais que a fila aguenta
    for (0..120) |_| try streamer.send(try frameMsg(false, 256 * 1024));
    // o servidor tem que pedir outro IDR
    _ = try streamer.expect(.keyreq);
}

test "sala: áudio chega em quem assiste, com o remetente certo" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();

    var streamer = try TestClient.connect(port, "T", "", "");
    defer streamer.close();
    try streamer.welcome();
    var viewer = try TestClient.connect(port, "E", "", "");
    defer viewer.close();
    try viewer.welcome();

    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.stream_start);
    try b.u16_(64);
    try b.u16_(64);
    try b.u8_(30);
    try b.u8_(proto.stream_audio);
    try streamer.send(try b.finish());
    try b.begin(.watch);
    try b.u32_(streamer.id);
    try b.u8_(1);
    try viewer.send(try b.finish());

    // a lista de membros marca que a transmissão tem áudio
    while (true) {
        var r: proto.Reader = .{ .data = try viewer.expect(.members) };
        const n = try r.u16_();
        var found = false;
        for (0..n) |_| {
            const id = try r.u32_();
            _ = try r.str();
            const flags = try r.u8_();
            _ = try r.take(2 + 2 + 1);
            const k = try r.u16_();
            _ = try r.take(@as(usize, k) * 4);
            if (id == streamer.id and flags & proto.member_audio != 0) found = true;
        }
        if (found) break;
    }

    const opus_fake = [_]u8{ 0xfc, 1, 2, 3, 4, 5, 6, 7 };
    const m = try proto.Msg.alloc(.audio, proto.audio_header_len + opus_fake.len);
    std.mem.writeInt(u32, m.payload()[0..4], 7, .little);
    std.mem.writeInt(u64, m.payload()[4..12], 123, .little);
    @memcpy(m.payload()[12..], &opus_fake);
    try streamer.send(m);

    var r: proto.Reader = .{ .data = try viewer.expect(.audio) };
    try testing.expectEqual(streamer.id, try r.u32_());
    try testing.expectEqual(@as(u32, 7), try r.u32_());
    try testing.expectEqual(@as(u64, 123), try r.u64_());
    try testing.expectEqualSlices(u8, &opus_fake, r.rest());
}
