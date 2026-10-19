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
    seen: [32]bool = [_]bool{false} ** 32, // tipos de mensagem já recebidos
    last_slow_floor: u8 = 0,

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
        for (0..2000) |_| {
            const t = try proto.recvMsg(c.sock, &c.ch, &c.rb);
            if (@intFromEnum(t) < c.seen.len) c.seen[@intFromEnum(t)] = true;
            if (t == .viewer_slow) c.last_slow_floor = proto.payloadOf(&c.rb)[0];
            if (t == typ) return proto.payloadOf(&c.rb);
        }
        return error.NotFound;
    }

    /// Espectador: confirma um frame recebido (payload S→C de `frame`).
    fn ackFrame(c: *TestClient, payload: []const u8) !void {
        const m = try proto.Msg.alloc(.ack, 8);
        @memcpy(m.payload()[0..8], payload[0..8]); // u32 de, u32 seq
        try c.send(m);
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
    return frameSeq(key, payload_len, 1);
}

fn frameSeq(key: bool, payload_len: usize, seq: u32) !*proto.Msg {
    const m = try proto.Msg.alloc(.frame, proto.frame_header_len + payload_len);
    const p = m.payload();
    @memset(p, 0xAB);
    std.mem.writeInt(u32, p[0..4], seq, .little);
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
    try streamer.send(try frameSeq(false, 100, 7));
    try streamer.send(try frameSeq(true, 200, 8));
    // o servidor confirma cada frame pro transmissor (controle de banda dele)
    {
        var a: proto.Reader = .{ .data = try streamer.expect(.ack) };
        try testing.expectEqual(@as(u32, 7), try a.u32_());
        a = .{ .data = try streamer.expect(.ack) };
        try testing.expectEqual(@as(u32, 8), try a.u32_());
    }
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

/// Espectador para de ler (sem confirmar) enquanto o transmissor manda 1 s de
/// vídeo; depois lê e confirma tudo o que chegou. Retorna quantos P-frames
/// recebeu (o servidor tem que ter cortado o envio quando o atraso passou do
/// limite).
fn congestAndDrain(streamer: *TestClient, viewer: *TestClient, seq: *u32) !usize {
    for (0..50) |_| {
        try streamer.send(try frameSeq(false, 64 * 1024, seq.*));
        seq.* += 1;
        sync.sleepMs(20);
    }
    net.setRecvTimeout(viewer.sock, 400);
    defer net.setRecvTimeout(viewer.sock, 5000);
    var got: usize = 0;
    while (true) {
        const t = proto.recvMsg(viewer.sock, &viewer.ch, &viewer.rb) catch break;
        if (t != .frame) continue;
        const p = proto.payloadOf(&viewer.rb);
        try testing.expect(p[8] & proto.frame_key == 0);
        try viewer.ackFrame(p);
        got += 1;
    }
    return got;
}

test "sala: espectador que atrasa perde o atraso, escoa e recomeça de um IDR" {
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
    var seq: u32 = 0;
    try streamer.send(try frameSeq(true, 1000, seq));
    seq += 1;
    try viewer.ackFrame(try viewer.expect(.frame));

    for (0..2) |round| {
        const got = try congestAndDrain(&streamer, &viewer, &seq);
        // passou de 500 ms de atraso no meio do segundo: o resto não foi enviado
        try testing.expect(got < 50);
        // escoou: o próximo frame do transmissor faz o servidor pedir um IDR...
        sync.sleepMs(if (round == 0) 200 else 700); // espera da 2ª vez é maior (1 s)
        try streamer.send(try frameSeq(false, 100, seq));
        seq += 1;
        _ = try streamer.expect(.keyreq);
        // ...e o espectador recomeça exatamente nele
        try streamer.send(try frameSeq(true, 1000, seq));
        seq += 1;
        const p = try viewer.expect(.frame);
        try testing.expect(p[8] & proto.frame_key != 0);
        try viewer.ackFrame(p);
    }
    // atrasou duas vezes em menos de 10 s: o transmissor é avisado pra baixar a
    // taxa — o quanto precisar, porque o único espectador é "a maioria"
    try testing.expect(streamer.seen[@intFromEnum(proto.Type.viewer_slow)]);
    try testing.expectEqual(@as(u8, 10), streamer.last_slow_floor);
}

test "sala: espectador pede IDR (keyreq) quando perde a referência" {
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
    try streamer.send(try frameSeq(true, 100, 0));
    try viewer.ackFrame(try viewer.expect(.frame));

    sync.sleepMs(600); // passa o limite de 1 pedido a cada 500 ms
    try b.begin(.keyreq);
    try b.u32_(streamer.id);
    try viewer.send(try b.finish());
    _ = try streamer.expect(.keyreq);
    // P-frames até o IDR não vão pro espectador
    try streamer.send(try frameSeq(false, 100, 1));
    try streamer.send(try frameSeq(true, 100, 2));
    var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
    _ = try r.u32_();
    try testing.expectEqual(@as(u32, 2), try r.u32_());
}

test "sala: tela parada não deixa o espectador preso esperando IDR" {
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
    try streamer.send(try frameSeq(true, 100, 0));
    try viewer.ackFrame(try viewer.expect(.frame));

    // o decoder do espectador perde a referência logo depois do primeiro IDR:
    // o pedido cai no limite de 1 a cada 500 ms, e a tela do transmissor está
    // parada (nenhum quadro novo pra disparar o pedido em forwardFrame)
    try b.begin(.keyreq);
    try b.u32_(streamer.id);
    try viewer.send(try b.finish());
    const t0 = sync.nowMs();
    _ = try streamer.expect(.keyreq);
    try testing.expect(sync.nowMs() - t0 < 4000);
    try streamer.send(try frameSeq(true, 100, 1));
    var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
    _ = try r.u32_();
    try testing.expectEqual(@as(u32, 1), try r.u32_());
}

fn frameFlags(flags: u8, payload_len: usize, seq: u32) !*proto.Msg {
    const m = try frameSeq(false, payload_len, seq);
    m.payload()[4] = flags;
    return m;
}

test "sala: decoder que não dá conta passa a receber só os quadros de referência" {
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

    // antes: todo quadro chega, inclusive os puláveis
    try streamer.send(try frameSeq(true, 100, 0));
    try streamer.send(try frameFlags(proto.frame_droppable, 100, 1));
    for ([_]u32{ 0, 1 }) |want| {
        var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
        _ = try r.u32_();
        try testing.expectEqual(want, try r.u32_());
        try viewer.ackFrame(r.data);
    }

    // o decoder dele ficou pra trás: pede IDR
    sync.sleepMs(600);
    try b.begin(.keyreq);
    try b.u32_(streamer.id);
    try viewer.send(try b.finish());
    _ = try streamer.expect(.keyreq);

    // depois: o IDR chega, o pulável não, o de referência sim
    try streamer.send(try frameSeq(true, 100, 2));
    try streamer.send(try frameFlags(proto.frame_droppable, 100, 3));
    try streamer.send(try frameFlags(0, 100, 4));
    try streamer.send(try frameFlags(proto.frame_droppable, 100, 5));
    try streamer.send(try frameFlags(0, 100, 6));
    for ([_]u32{ 2, 4, 6 }) |want| {
        var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
        _ = try r.u32_();
        try testing.expectEqual(want, try r.u32_());
        try viewer.ackFrame(r.data);
    }
}

test "sala: watch só aceita quem existe" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();

    var viewer = try TestClient.connect(port, "E", "", "");
    defer viewer.close();
    try viewer.welcome();
    var b: proto.Builder = .{};
    defer b.deinit();
    // ids que não existem (e o próprio): ignorados, nada de lista crescendo
    for ([_]u32{ 999, 12345, viewer.id }) |id| {
        try b.begin(.watch);
        try b.u32_(id);
        try b.u8_(1);
        try viewer.send(try b.finish());
    }
    // o servidor continua respondendo normalmente
    try b.begin(.ping);
    try b.u64_(77);
    try viewer.send(try b.finish());
    var r: proto.Reader = .{ .data = try viewer.expect(.pong) };
    try testing.expectEqual(@as(u64, 77), try r.u64_());
    try testing.expectEqual(@as(usize, 0), srv.watchingCount(viewer.id));
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

// ------------------------------------------------------------- link público

const tunnel = @import("tunnel.zig");

/// Servidor de túnel de mentira, falando o protocolo do bore.
const MockBore = struct {
    control: net.Socket,
    public_port: u16,
    visitor: ?net.Socket = null,

    fn frame(s: net.Socket, json: []const u8) !void {
        try net.sendAll(s, json);
        try net.sendAll(s, &[_]u8{0});
    }
    fn readFrame(s: net.Socket, buf: []u8) ![]const u8 {
        var n: usize = 0;
        while (true) {
            var b: [1]u8 = undefined;
            try net.recvAll(s, &b);
            if (b[0] == 0) return buf[0..n];
            buf[n] = b[0];
            n += 1;
        }
    }

    /// Conexão de controle: Hello → porta pública; visitante → Connection.
    fn run(m: *MockBore) void {
        const ctl = net.accept(m.control) catch return;
        var buf: [256]u8 = undefined;
        const hello = readFrame(ctl, &buf) catch return;
        if (tunnel.field(hello, "Hello") == null) return;
        const pub_ls = net.listen(m.public_port) catch return;
        var out: [64]u8 = undefined;
        frame(ctl, std.fmt.bufPrint(&out, "{{\"Hello\":{d}}}", .{m.public_port}) catch return) catch return;
        frame(ctl, "\"Heartbeat\"") catch return;
        m.visitor = net.accept(pub_ls) catch return;
        frame(ctl, "{\"Connection\":\"0b6c1c5e-1111-4222-8333-944455556666\"}") catch return;
        // a conexão de dados chega na porta de controle com o Accept
        const data = net.accept(m.control) catch return;
        const acc = readFrame(data, &buf) catch return;
        const id = tunnel.field(acc, "Accept") orelse return;
        if (!std.mem.eql(u8, id, "0b6c1c5e-1111-4222-8333-944455556666")) return;
        sync.spawn(pipe, .{ m.visitor.?, data }) catch return;
        pipe(data, m.visitor.?);
    }

    fn pipe(from: net.Socket, to: net.Socket) void {
        var b: [16384]u8 = undefined;
        while (true) {
            const n = net.recvSome(from, &b) catch break;
            net.sendAll(to, b[0..n]) catch break;
        }
        net.shutdown(to);
    }
};

test "link público: visitante entra na sala pelo túnel (protocolo do bore)" {
    net.init();
    const room_port = freshPort();
    const srv = try Server.start(.{ .port = room_port, .password = "segredo" });
    defer srv.stop();

    const ctl_port = freshPort();
    var mock: MockBore = .{ .control = try net.listen(ctl_port), .public_port = freshPort() };
    defer net.close(mock.control);
    try sync.spawn(MockBore.run, .{&mock});

    var spec_buf: [32]u8 = undefined;
    const t = try tunnel.Tunnel.start(try std.fmt.bufPrint(&spec_buf, "127.0.0.1:{d}", .{ctl_port}), srv, Server.adoptCallback);
    defer t.stop();
    var st = t.status();
    for (0..100) |_| {
        st = t.status();
        if (st.state != .connecting) break;
        sync.sleepMs(20);
    }
    try testing.expectEqual(tunnel.State.ready, st.state);
    try testing.expectEqual(mock.public_port, st.public_port);
    var addr_buf: [64]u8 = undefined;
    const addr = t.address(&addr_buf);
    try testing.expect(std.mem.endsWith(u8, addr, try std.fmt.bufPrint(&spec_buf, ":{d}", .{mock.public_port})));

    // o visitante conecta na porta pública e entra na sala, com a senha
    var v = try TestClient.connect(mock.public_port, "Visitante", "segredo", "");
    defer v.close();
    try v.welcome();
    try testing.expect(v.id != 0);
}

test "link público: mensagens do protocolo do bore" {
    try testing.expectEqualStrings("41234", tunnel.field("{\"Hello\":41234}", "Hello").?);
    try testing.expectEqualStrings("abc-1", tunnel.field("{\"Connection\":\"abc-1\"}", "Connection").?);
    try testing.expectEqualStrings("port already in use", tunnel.field("{\"Error\":\"port already in use\"}", "Error").?);
    try testing.expect(tunnel.field("\"Heartbeat\"", "Connection") == null);
    try testing.expect(tunnel.field("{\"Hello\":1}", "Error") == null);
}

test "voz: chega em todo mundo menos quem fala e quem está surdo; estado aparece nos membros" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();
    var a = try TestClient.connect(port, "A", "", "");
    defer a.close();
    try a.welcome();
    var b = try TestClient.connect(port, "B", "", "");
    defer b.close();
    try b.welcome();
    var c = try TestClient.connect(port, "C", "", "");
    defer c.close();
    try c.welcome();

    var bb: proto.Builder = .{};
    defer bb.deinit();
    // A liga o microfone; C fica surdo
    try bb.begin(.voice_state);
    try bb.u8_(proto.voice_mic);
    try a.send(try bb.finish());
    try bb.begin(.voice_state);
    try bb.u8_(proto.voice_deaf);
    try c.send(try bb.finish());
    // B vê os dois estados na lista de membros
    var seen_mic = false;
    var seen_deaf = false;
    while (!(seen_mic and seen_deaf)) {
        var r: proto.Reader = .{ .data = try b.expect(.members) };
        const n = try r.u16_();
        seen_mic = false;
        seen_deaf = false;
        for (0..n) |_| {
            const id = try r.u32_();
            _ = try r.str();
            const flags = try r.u8_();
            _ = try r.take(2 + 2 + 1);
            const k = try r.u16_();
            _ = try r.take(@as(usize, k) * 4);
            if (id == a.id and flags & proto.member_mic != 0) seen_mic = true;
            if (id == c.id and flags & proto.member_deaf != 0) seen_deaf = true;
        }
    }

    // A fala
    const pacote = [_]u8{ 0x78, 1, 2, 3, 4, 5 };
    const m = try proto.Msg.alloc(.voice, 4 + pacote.len);
    std.mem.writeInt(u32, m.payload()[0..4], 42, .little);
    @memcpy(m.payload()[4..], &pacote);
    try a.send(m);
    // B recebe, com o remetente certo
    var r: proto.Reader = .{ .data = try b.expect(.voice) };
    try testing.expectEqual(a.id, try r.u32_());
    try testing.expectEqual(@as(u32, 42), try r.u32_());
    try testing.expectEqualSlices(u8, &pacote, r.rest());
    // C (surdo) não recebe: um chat depois da voz chega antes de qualquer voz
    try bb.begin(.chat);
    try bb.str("depois da voz");
    try a.send(try bb.finish());
    while (true) {
        const t = try proto.recvMsg(c.sock, &c.ch, &c.rb);
        try testing.expect(t != .voice);
        if (t == .chat) {
            var cr: proto.Reader = .{ .data = proto.payloadOf(&c.rb) };
            if (try cr.u32_() == a.id) break;
        }
    }
}

// ------------------------------------------------------------------- UPnP

const upnp = @import("upnp.zig");

/// Roteador de mentira: responde ao M-SEARCH (UDP) e à descrição e às ações
/// SOAP (HTTP), anotando o que pediram.
const MockIgd = struct {
    udp: net.Socket,
    udp_port: u16,
    http: net.Socket,
    http_port: u16,
    ext_ip: []const u8 = "203.0.113.7",
    taken_port: u16 = 0, // porta de fora que "outro aparelho" já usa (erro 718)
    mutex: sync.Mutex = .{},
    log: std.ArrayList(u8) = .empty,
    stop: std.atomic.Value(bool) = .init(false),

    fn init(m: *MockIgd) !void {
        m.udp_port = freshPort();
        m.udp = try net.udpBindLocal(m.udp_port);
        net.setRecvTimeout(m.udp, 100);
        m.http_port = freshPort();
        m.http = try net.listen(m.http_port);
        try sync.spawn(runUdp, .{m});
        try sync.spawn(runHttp, .{m});
    }

    fn deinit(m: *MockIgd) void {
        m.stop.store(true, .release);
        net.shutdown(m.http);
        net.close(m.http);
        sync.sleepMs(250); // as threads saem (timeout do UDP / accept falhando)
        net.close(m.udp);
        m.log.deinit(std.heap.c_allocator);
    }

    fn logged(m: *MockIgd, what: []const u8) bool {
        m.mutex.lock();
        defer m.mutex.unlock();
        return std.mem.find(u8, m.log.items, what) != null;
    }

    fn runUdp(m: *MockIgd) void {
        var buf: [1500]u8 = undefined;
        var reply: [256]u8 = undefined;
        const r = std.fmt.bufPrint(&reply, "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nLocation: http://127.0.0.1:{d}/rootDesc.xml\r\n\r\n", .{m.http_port}) catch return;
        while (!m.stop.load(.acquire)) _ = net.udpRecvReply(m.udp, &buf, r);
    }

    fn runHttp(m: *MockIgd) void {
        while (!m.stop.load(.acquire)) {
            const s = net.accept(m.http) catch return;
            defer net.close(s);
            net.setRecvTimeout(s, 2000);
            var req: std.ArrayList(u8) = .empty;
            defer req.deinit(std.heap.c_allocator);
            var buf: [2048]u8 = undefined;
            // lê cabeçalho + corpo (Content-Length)
            while (true) {
                const n = net.recvSome(s, &buf) catch break;
                req.appendSlice(std.heap.c_allocator, buf[0..n]) catch break;
                const he = std.mem.find(u8, req.items, "\r\n\r\n") orelse continue;
                const cl_at = std.ascii.indexOfIgnoreCase(req.items[0..he], "content-length:") orelse break;
                const line_end = std.mem.find(u8, req.items[cl_at..], "\r\n") orelse break;
                const want = std.fmt.parseInt(usize, std.mem.trim(u8, req.items[cl_at + 15 .. cl_at + line_end], " "), 10) catch break;
                if (req.items.len >= he + 4 + want) break;
            }
            m.mutex.lock();
            m.log.appendSlice(std.heap.c_allocator, req.items) catch {};
            m.mutex.unlock();
            var out: [2048]u8 = undefined;
            const resp = m.answer(req.items, &out) catch continue;
            net.sendAll(s, resp) catch {};
        }
    }

    fn answer(m: *MockIgd, req: []const u8, out: []u8) ![]const u8 {
        if (std.mem.startsWith(u8, req, "GET /rootDesc.xml")) {
            const xml = "<?xml version=\"1.0\"?><root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><deviceList><device><serviceList>" ++
                "<service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/ctl/CmnIfCfg</controlURL></service>" ++
                "<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL></service>" ++
                "</serviceList></device></deviceList></device></root>";
            return std.fmt.bufPrint(out, "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\n\r\n{s}", .{ xml.len, xml });
        }
        var body_buf: [512]u8 = undefined;
        var code: u16 = 200;
        const body = if (std.mem.find(u8, req, "#GetExternalIPAddress") != null)
            try std.fmt.bufPrint(&body_buf, "<s:Envelope><s:Body><u:GetExternalIPAddressResponse><NewExternalIPAddress>{s}</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>", .{m.ext_ip})
        else if (std.mem.find(u8, req, "#AddPortMapping") != null) blk: {
            var tp: [32]u8 = undefined;
            const taken = try std.fmt.bufPrint(&tp, "<NewExternalPort>{d}<", .{m.taken_port});
            if (m.taken_port != 0 and std.mem.find(u8, req, taken) != null) {
                code = 500;
                break :blk "<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>718</errorCode><errorDescription>ConflictInMappingEntry</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>";
            }
            break :blk "<s:Envelope><s:Body><u:AddPortMappingResponse/></s:Body></s:Envelope>";
        } else "<s:Envelope><s:Body><u:DeletePortMappingResponse/></s:Body></s:Envelope>";
        return std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\n\r\n{s}", .{ code, if (code == 200) "OK" else "Internal Server Error", body.len, body });
    }
};

test "UPnP: acha o roteador, abre a porta pra esta máquina e fecha" {
    net.init();
    var igd: MockIgd = .{ .udp = undefined, .udp_port = 0, .http = undefined, .http_port = 0 };
    try igd.init();
    defer igd.deinit();

    const router = try upnp.discover(.{ 127, 0, 0, 1 }, igd.udp_port, 2000);
    var mp = try upnp.open(router, 7777);
    try testing.expectEqual([4]u8{ 203, 0, 113, 7 }, mp.ext_ip);
    try testing.expectEqual(@as(u16, 7777), mp.ext_port);
    try testing.expect(igd.logged("POST /ctl/IPConn"));
    try testing.expect(igd.logged("<NewInternalClient>127.0.0.1</NewInternalClient>"));
    try testing.expect(igd.logged("<NewLeaseDuration>3600</NewLeaseDuration>"));
    upnp.close(&mp);
    try testing.expect(igd.logged("#DeletePortMapping"));
}

test "UPnP: porta de fora ocupada por outro aparelho -> usa a próxima" {
    net.init();
    var igd: MockIgd = .{ .udp = undefined, .udp_port = 0, .http = undefined, .http_port = 0, .taken_port = 7777 };
    try igd.init();
    defer igd.deinit();
    const router = try upnp.discover(.{ 127, 0, 0, 1 }, igd.udp_port, 2000);
    var mp = try upnp.open(router, 7777);
    defer upnp.close(&mp);
    try testing.expectEqual(@as(u16, 7778), mp.ext_port);
    try testing.expectEqual(@as(u16, 7777), mp.int_port);
}

test "UPnP: operadora com CGNAT -> avisa em vez de abrir porta à toa" {
    net.init();
    var igd: MockIgd = .{ .udp = undefined, .udp_port = 0, .http = undefined, .http_port = 0, .ext_ip = "100.72.10.3" };
    try igd.init();
    defer igd.deinit();
    const router = try upnp.discover(.{ 127, 0, 0, 1 }, igd.udp_port, 2000);
    try testing.expectError(error.Cgnat, upnp.open(router, 7777));
    try testing.expect(!igd.logged("#AddPortMapping"));
}

test "UPnP: em segundo plano (como a interface usa) e sem roteador" {
    net.init();
    var igd: MockIgd = .{ .udp = undefined, .udp_port = 0, .http = undefined, .http_port = 0 };
    try igd.init();
    defer igd.deinit();
    const m = try upnp.Mapper.start(7777, .{ 127, 0, 0, 1 }, igd.udp_port);
    for (0..100) |_| {
        if (m.status().state != .working) break;
        sync.sleepMs(50);
    }
    try testing.expectEqual(upnp.Mapper.State.ready, m.status().state);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("203.0.113.7:7777", m.address(&buf));
    m.stop();
    for (0..40) |_| {
        if (igd.logged("#DeletePortMapping")) break;
        sync.sleepMs(50);
    }
    try testing.expect(igd.logged("#DeletePortMapping"));

    // ninguém responde: falha com uma mensagem, sem travar
    const none = try upnp.Mapper.start(7777, .{ 127, 0, 0, 1 }, freshPort());
    defer none.stop();
    for (0..100) |_| {
        if (none.status().state != .working) break;
        sync.sleepMs(50);
    }
    try testing.expectEqual(upnp.Mapper.State.failed, none.status().state);
}
