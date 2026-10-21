//! Testes de integração do servidor: sobe uma sala de verdade (localhost)
//! e conversa com ela pelo protocolo cifrado.
const std = @import("std");
const testing = std.testing;
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const crypto = @import("crypto.zig");
const server_mod = @import("server.zig");
const Server = server_mod.Server;

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
    route: u8 = 0,
    seen: [32]bool = [_]bool{false} ** 32, // tipos de mensagem já recebidos
    last_slow_floor: u8 = 0,

    fn connect(port: u16, name: []const u8, password: []const u8, token: []const u8) !TestClient {
        return connectKey(port, name, password, token, 0);
    }

    fn connectKey(port: u16, name: []const u8, password: []const u8, token: []const u8, key: u64) !TestClient {
        return connectCaps(port, name, password, token, key, proto.codecs_h264);
    }

    /// Com os codecs que esse "app" decodifica (bits 1<<codec).
    fn connectCaps(port: u16, name: []const u8, password: []const u8, token: []const u8, key: u64, codecs: u8) !TestClient {
        return connectFull(port, name, password, token, key, codecs, null);
    }

    /// Pedindo um canal no hello (null = app antigo, que não manda o campo).
    fn connectChan(port: u16, name: []const u8, token: []const u8, chan: []const u8) !TestClient {
        return connectFull(port, name, "", token, 0, proto.codecs_h264, chan);
    }

    fn connectFull(port: u16, name: []const u8, password: []const u8, token: []const u8, key: u64, codecs: u8, chan: ?[]const u8) !TestClient {
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
        try b.u64_(key);
        try b.str(proto.app_version);
        try b.u8_(codecs);
        if (chan) |ch| {
            try b.u8_(0); // recursos
            try b.str(ch);
        }
        try c.send(try b.finish());
        return c;
    }

    /// Próxima mensagem `channel`: o canal atual e quantos/quais existem.
    fn channels(c: *TestClient) !ChanList {
        var r: proto.Reader = .{ .data = try c.expect(.channel) };
        var l: ChanList = .{};
        const cur = try r.str();
        @memcpy(l.cur[0..cur.len], cur);
        l.cur_len = cur.len;
        const n = try r.u8_();
        for (0..n) |_| {
            const nm = try r.str();
            const people = try r.u16_();
            const flags = try r.u8_();
            if (l.n == l.names.len) continue;
            @memcpy(l.names[l.n][0..nm.len], nm);
            l.lens[l.n] = nm.len;
            l.people[l.n] = people;
            l.flags[l.n] = flags;
            l.n += 1;
        }
        return l;
    }

    /// Lê até uma lista de canais em que `cond` vale.
    fn waitChannels(c: *TestClient, ctx: anytype, cond: fn (@TypeOf(ctx), *const ChanList) bool) !ChanList {
        while (true) {
            const l = try c.channels();
            if (cond(ctx, &l)) return l;
        }
    }

    fn joinChannel(c: *TestClient, name: []const u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.channel);
        try b.str(name);
        try c.send(try b.finish());
    }

    /// Próxima mensagem de chat de alguém (pula os avisos do sistema).
    fn userChat(c: *TestClient, out_text: []u8) !struct { from: u32, text: []const u8, history: bool } {
        while (true) {
            var r: proto.Reader = .{ .data = try c.expect(.chat) };
            _ = try r.u32_();
            const from = try r.u32_();
            _ = try r.str();
            const text = try r.str();
            _ = try r.u64_();
            const flags = try r.u8_();
            if (from == 0) continue;
            @memcpy(out_text[0..text.len], text);
            return .{ .from = from, .text = out_text[0..text.len], .history = flags & proto.chat_history != 0 };
        }
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
            if (t == .viewer_slow) c.last_slow_floor = proto.payloadOf(&c.rb)[1];
            if (t == typ) return proto.payloadOf(&c.rb);
        }
        return error.NotFound;
    }

    /// Espectador: confirma um frame recebido (payload S→C de `frame`).
    fn ackFrame(c: *TestClient, payload: []const u8) !void {
        const m = try proto.Msg.alloc(.ack, 8);
        @memcpy(m.payload()[0..8], payload[0..8]); // u32 stream, u32 seq
        try c.send(m);
    }

    fn welcome(c: *TestClient) !void {
        var r: proto.Reader = .{ .data = try c.expect(.welcome) };
        c.id = try r.u32_();
        _ = try r.str(); // sala
        _ = try r.u8_(); // admin
        _ = try r.u64_(); // relógio
        _ = try r.u64_(); // instância
        c.route = try r.u8_();
    }

    fn streamStart(c: *TestClient, kind: u8, flags: u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.stream_start);
        try b.u8_(kind);
        try b.u16_(64);
        try b.u16_(64);
        try b.u8_(30);
        try b.u8_(flags);
        try c.send(try b.finish());
    }

    fn watch(c: *TestClient, stream: u32, opts: u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.watch);
        try b.u32_(stream);
        try b.u8_(1);
        try b.u8_(opts);
        try c.send(try b.finish());
    }

    fn admin(c: *TestClient, action: u8, target: u32, value: u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.admin);
        try b.u8_(action);
        try b.u32_(target);
        try b.u8_(value);
        try c.send(try b.finish());
    }

    fn chat(c: *TestClient, text: []const u8) !void {
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.chat);
        try b.str(text);
        try c.send(try b.finish());
    }

    /// Próxima lista de membros (já decodificada).
    fn members(c: *TestClient) !MemberList {
        return parseMembers(try c.expect(.members));
    }

    /// Espera o motivo da saída (denied) e fecha, como o app faz: retorna o código.
    fn denied(c: *TestClient) !u8 {
        var r: proto.Reader = .{ .data = try c.expect(.denied) };
        _ = try r.str();
        const code = try r.u8_();
        net.shutdown(c.sock);
        return code;
    }

    /// Lê listas de membros até `id` aparecer com `flag` ligada (ou desligada).
    fn waitFlag(c: *TestClient, id: u32, flag: u8, on: bool) !MemberList {
        while (true) {
            const l = try c.members();
            const m = l.get(id) orelse continue;
            if ((m.flags & flag != 0) == on) return l;
        }
    }

    fn close(c: *TestClient) void {
        c.rb.deinit();
        net.close(c.sock);
    }
};

const ChanList = struct {
    cur: [proto.channel_name_max]u8 = undefined,
    cur_len: usize = 0,
    n: usize = 0,
    names: [proto.max_channels][proto.channel_name_max]u8 = undefined,
    lens: [proto.max_channels]usize = undefined,
    people: [proto.max_channels]u16 = undefined,
    flags: [proto.max_channels]u8 = undefined,

    fn current(l: *const ChanList) []const u8 {
        return l.cur[0..l.cur_len];
    }
    fn has(l: *const ChanList, name: []const u8) bool {
        for (0..l.n) |i| if (std.mem.eql(u8, l.names[i][0..l.lens[i]], name)) return true;
        return false;
    }
    fn peopleIn(l: *const ChanList, name: []const u8) u16 {
        for (0..l.n) |i| if (std.mem.eql(u8, l.names[i][0..l.lens[i]], name)) return l.people[i];
        return 0;
    }
};

const MemberInfo = struct { id: u32, flags: u8, route: u8, owner: bool, cam_w: u16 };
const MemberList = struct {
    room_flags: u8,
    n: usize,
    items: [16]MemberInfo,

    fn get(l: *const MemberList, id: u32) ?MemberInfo {
        for (l.items[0..l.n]) |m| if (m.id == id) return m;
        return null;
    }
};

fn parseMembers(payload: []const u8) !MemberList {
    var r: proto.Reader = .{ .data = payload };
    var l: MemberList = .{ .room_flags = try r.u8_(), .n = 0, .items = undefined };
    const n = try r.u16_();
    for (0..n) |_| {
        var m: MemberInfo = undefined;
        m.id = try r.u32_();
        _ = try r.str();
        m.flags = try r.u8_();
        const route = try r.u8_();
        m.route = route & 0x7F;
        m.owner = route & 0x80 != 0;
        _ = try r.take(2 + 2 + 1); // tela
        m.cam_w = try r.u16_();
        _ = try r.take(2 + 1);
        const k = try r.u16_();
        _ = try r.take(@as(usize, k) * 4);
        if (l.n < l.items.len) {
            l.items[l.n] = m;
            l.n += 1;
        }
    }
    return l;
}

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
    std.mem.writeInt(u16, p[17..19], proto.coord_none, .little);
    std.mem.writeInt(u16, p[19..21], proto.coord_none, .little);
    return m;
}

/// Transmissor com uma tela no ar e um espectador assistindo, já no primeiro IDR.
fn liveRoom(streamer: *TestClient, viewer: *TestClient) !void {
    try streamer.streamStart(proto.kind_screen, 0);
    try viewer.watch(streamer.id, 0);
    _ = try streamer.expect(.keyreq);
}

test "sala: entrar, senha errada, chat" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .password = "abc", .room_name = "Sala de teste" });
    defer srv.stop();

    var a = try TestClient.connect(port, "Ana", "abc", "");
    defer a.close();
    try a.welcome();
    // conectou em 127.0.0.1: "nessa máquina"
    try testing.expectEqual(proto.route_local, a.route);

    // senha errada: servidor manda o marcador e fecha
    var bad = try TestClient.connect(port, "Mal", "errada", "");
    defer bad.close();
    try testing.expectError(error.WrongPassword, proto.recvMsg(bad.sock, &bad.ch, &bad.rb));

    var b = try TestClient.connect(port, "Ana", "abc", ""); // nome repetido
    defer b.close();
    try b.welcome();
    try b.chat("olá sala");

    // a Ana original recebe a mensagem do "Ana (2)"
    while (true) {
        var r: proto.Reader = .{ .data = try a.expect(.chat) };
        const id = try r.u32_();
        const from = try r.u32_();
        const name = try r.str();
        const text = try r.str();
        _ = try r.u64_(); // hora
        const flags = try r.u8_();
        if (from == 0) continue; // mensagens do sistema
        try testing.expect(id != 0);
        try testing.expectEqual(b.id, from);
        try testing.expectEqualStrings("Ana (2)", name);
        try testing.expectEqualStrings("olá sala", text);
        try testing.expectEqual(@as(u8, 0), flags & proto.chat_history);
        break;
    }
}

test "chat: quem entra depois recebe o histórico (marcado como antigo)" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();
    var a = try TestClient.connect(port, "A", "", "");
    defer a.close();
    try a.welcome();
    try a.chat("primeira");
    try a.chat("segunda");
    // espera as duas voltarem (o servidor já guardou)
    var got: usize = 0;
    while (got < 2) {
        var r: proto.Reader = .{ .data = try a.expect(.chat) };
        _ = try r.u32_();
        if (try r.u32_() == a.id) got += 1;
    }
    var b = try TestClient.connect(port, "B", "", "");
    defer b.close();
    try b.welcome();
    var texts: [8][]const u8 = undefined;
    var bufs: [8][32]u8 = undefined;
    var n: usize = 0;
    var last_id: u32 = 0;
    while (n < 3) {
        var r: proto.Reader = .{ .data = try b.expect(.chat) };
        const id = try r.u32_();
        const from = try r.u32_();
        _ = try r.str();
        const text = try r.str();
        _ = try r.u64_();
        const flags = try r.u8_();
        try testing.expect(id > last_id); // em ordem
        last_id = id;
        if (flags & proto.chat_history == 0) {
            // a primeira mensagem nova é o "B entrou na sala" (depois do histórico)
            try testing.expectEqual(@as(u32, 0), from);
            break;
        }
        const k = @min(text.len, 32);
        @memcpy(bufs[n][0..k], text[0..k]);
        texts[n] = bufs[n][0..k];
        n += 1;
    }
    // "A entrou na sala" + as duas mensagens
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("primeira", texts[1]);
    try testing.expectEqualStrings("segunda", texts[2]);
}

/// Mensagem de chat decodificada (com imagem e reações, se tiver).
const ChatMsg = struct {
    id: u32,
    from: u32,
    flags: u8,
    img: u8,
    img_w: u16 = 0,
    img_h: u16 = 0,
    img_len: usize = 0,
    img_first: u8 = 0,
    n_reacts: u8 = 0,
    react0: u8 = 0,
};

fn readChat(c: *TestClient) !ChatMsg {
    var r: proto.Reader = .{ .data = try c.expect(.chat) };
    var m: ChatMsg = .{ .id = try r.u32_(), .from = try r.u32_(), .flags = 0, .img = 0 };
    _ = try r.str();
    _ = try r.str();
    _ = try r.u64_();
    m.flags = try r.u8_();
    m.img = try r.u8_();
    if (m.img == proto.chat_img_h264) {
        m.img_w = try r.u16_();
        m.img_h = try r.u16_();
        const len = try r.u32_();
        const data = try r.take(len);
        m.img_len = data.len;
        m.img_first = data[0];
    }
    m.n_reacts = try r.u8_();
    if (m.n_reacts > 0) {
        m.react0 = try r.u8_();
        _ = try r.u32_();
    }
    return m;
}

fn chatImage(c: *TestClient, w: u16, h: u16, len: usize, fill: u8) !void {
    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.chat);
    try b.str("olha isso");
    try b.u8_(proto.chat_img_h264);
    try b.u16_(w);
    try b.u16_(h);
    try b.u32_(@intCast(len));
    const data = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(data);
    @memset(data, fill);
    try b.bytes(data);
    try c.send(try b.finish());
}

/// Próxima mensagem de chat de alguém (pula os avisos do sistema).
fn nextUserChat(c: *TestClient) !ChatMsg {
    while (true) {
        const m = try readChat(c);
        if (m.from != 0) return m;
    }
}

test "chat: imagem chega pra todos e no histórico; reações; limites" {
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
    try chatImage(&a, 640, 360, 50_000, 0x5A);
    const got = try nextUserChat(&b);
    try testing.expectEqual(proto.chat_img_h264, got.img);
    try testing.expectEqual(@as(u16, 640), got.img_w);
    try testing.expectEqual(@as(usize, 50_000), got.img_len);
    try testing.expectEqual(@as(u8, 0x5A), got.img_first);
    // rajada: a segunda imagem logo em seguida é ignorada; texto passa
    try chatImage(&a, 640, 360, 1000, 1);
    try a.chat("depois");
    const next = try nextUserChat(&b);
    try testing.expectEqual(proto.chat_img_none, next.img);
    // reação: B curte a imagem; todo mundo recebe
    {
        const m = try proto.Msg.alloc(.react, 6);
        std.mem.writeInt(u32, m.payload()[0..4], got.id, .little);
        m.payload()[4] = 1;
        m.payload()[5] = 1;
        try b.send(m);
    }
    var r: proto.Reader = .{ .data = try a.expect(.react) };
    try testing.expectEqual(got.id, try r.u32_());
    try testing.expectEqual(b.id, try r.u32_());
    try testing.expectEqual(@as(u8, 1), try r.u8_());
    try testing.expectEqual(@as(u8, 1), try r.u8_());
    // quem entra depois vê a imagem e a reação no histórico
    var c = try TestClient.connect(port, "C", "", "");
    defer c.close();
    try c.welcome();
    const hist = try nextUserChat(&c);
    try testing.expect(hist.flags & proto.chat_history != 0);
    try testing.expectEqual(proto.chat_img_h264, hist.img);
    try testing.expectEqual(@as(usize, 50_000), hist.img_len);
    try testing.expectEqual(@as(u8, 1), hist.n_reacts);
    try testing.expectEqual(@as(u8, 1), hist.react0);
    // imagem fora dos limites derruba quem mandou (mensagem inválida): o
    // servidor fecha e a leitura termina com erro bem antes do prazo de 5 s
    try chatImage(&c, 4000, 360, 100, 1);
    const t0 = sync.nowMs();
    while (true) {
        _ = proto.recvMsg(c.sock, &c.ch, &c.rb) catch break;
    }
    try testing.expect(sync.nowMs() - t0 < 4000);
}

/// Próxima mensagem `codec` (tipo, codecs liberados).
fn nextCodec(c: *TestClient) ![2]u8 {
    const p = try c.expect(.codec);
    return .{ p[0], p[1] };
}

test "codec: a transmissão só usa HEVC se todo mundo que assiste decodifica" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();
    const hevc: u8 = proto.codecs_h264 | 2;
    var a = try TestClient.connect(port, "A", "", "");
    defer a.close();
    try a.welcome();
    try a.streamStart(proto.kind_screen, 0);
    // ninguém assistindo: libera tudo
    var m = try nextCodec(&a);
    try testing.expectEqual(proto.kind_screen, m[0]);
    try testing.expect(m[1] & 2 != 0);
    // quem decodifica HEVC entra assistindo: HEVC continua liberado
    var b = try TestClient.connectCaps(port, "B", "", "", 0, hevc);
    defer b.close();
    try b.welcome();
    try b.watch(a.id, 0);
    m = try nextCodec(&a);
    try testing.expectEqual(hevc, m[1]);
    // quem só tem H.264 entra assistindo: volta pro H.264
    var c = try TestClient.connectCaps(port, "C", "", "", 0, proto.codecs_h264);
    defer c.close();
    try c.welcome();
    try c.watch(a.id, 0);
    m = try nextCodec(&a);
    try testing.expectEqual(proto.codecs_h264, m[1]);
    // ele para de assistir: HEVC de novo
    {
        const w = try proto.Msg.alloc(.watch, 6);
        std.mem.writeInt(u32, w.payload()[0..4], a.id, .little);
        w.payload()[4] = 0;
        w.payload()[5] = 0;
        try c.send(w);
    }
    m = try nextCodec(&a);
    try testing.expectEqual(hevc, m[1]);
    // a câmera é outra transmissão, com a própria negociação
    try a.streamStart(proto.kind_camera, 0);
    m = try nextCodec(&a);
    try testing.expectEqual(proto.kind_camera, m[0]);
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

    // o servidor pede um IDR pro transmissor
    try liveRoom(&streamer, &viewer);
    // um P-frame antes do IDR não pode chegar no espectador
    try streamer.send(try frameSeq(false, 100, 7));
    try streamer.send(try frameSeq(true, 200, 8));
    // o servidor confirma cada frame pro transmissor (controle de banda dele)
    {
        var a: proto.Reader = .{ .data = try streamer.expect(.ack) };
        try testing.expectEqual(proto.kind_screen, try a.u8_());
        try testing.expectEqual(@as(u32, 7), try a.u32_());
        a = .{ .data = try streamer.expect(.ack) };
        _ = try a.u8_();
        try testing.expectEqual(@as(u32, 8), try a.u32_());
    }
    var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
    try testing.expectEqual(streamer.id, try r.u32_());
    _ = try r.u32_(); // seq
    try testing.expectEqual(proto.frame_key, try r.u8_());
    try testing.expectEqual(@as(usize, 8 + 2 + 2 + 2 + 2 + 200), r.rest().len);
}

test "câmera: transmissão própria (stream com o bit de câmera), separada da tela" {
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

    try streamer.streamStart(proto.kind_screen, 0);
    try streamer.streamStart(proto.kind_camera, 0);
    const cam = proto.streamId(streamer.id, proto.kind_camera);
    // os membros mostram a câmera ligada
    while (true) {
        const l = try viewer.members();
        const m = l.get(streamer.id) orelse continue;
        if (m.flags & proto.member_camera != 0 and m.flags & proto.member_streaming != 0) {
            try testing.expectEqual(@as(u16, 64), m.cam_w);
            break;
        }
    }
    // assiste só a câmera: o pedido de IDR é da câmera
    try viewer.watch(cam, 0);
    var k: proto.Reader = .{ .data = try streamer.expect(.keyreq) };
    try testing.expectEqual(proto.kind_camera, try k.u8_());
    // quadro da tela não chega; o da câmera sim, com o stream da câmera
    try streamer.send(try frameSeq(true, 50, 1));
    const cm = try frameSeq(true, 60, 2);
    cm.payload()[4] |= proto.frame_camera;
    try streamer.send(cm);
    var r: proto.Reader = .{ .data = try viewer.expect(.frame) };
    try testing.expectEqual(cam, try r.u32_());
    try testing.expectEqual(@as(u32, 2), try r.u32_());
    // a câmera desliga: o espectador para de receber, a tela continua no ar
    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.stream_stop);
    try b.u8_(proto.kind_camera);
    try streamer.send(try b.finish());
    while (true) {
        const l = try viewer.members();
        const m = l.get(streamer.id) orelse continue;
        if (m.flags & proto.member_camera == 0) {
            try testing.expect(m.flags & proto.member_streaming != 0);
            break;
        }
    }
}

test "sala: dono fecha a sala -> todo mundo fica sabendo (e não tenta reconectar)" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "dono" });
    var a = try TestClient.connect(port, "A", "", "");
    defer a.close();
    try a.welcome();
    var b = try TestClient.connect(port, "B", "", "");
    defer b.close();
    try b.welcome();
    // cliente mandando coisa enquanto a sala fecha (o aviso não pode virar RST)
    try a.chat("oi");
    srv.stop();
    try testing.expectEqual(proto.deny_closed, try a.denied());
    try testing.expectEqual(proto.deny_closed, try b.denied());
}

test "admin: expulsa, bane (não volta), silencia, para transmissão, dá admin e tranca a sala" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "token-do-dono" });
    defer srv.stop();

    var dono = try TestClient.connect(port, "Dono", "", "token-do-dono");
    defer dono.close();
    try dono.welcome();
    var v = try TestClient.connectKey(port, "Visita", "", "", 0x1234);
    defer v.close();
    try v.welcome();
    var w = try TestClient.connect(port, "Outra", "", "");
    defer w.close();
    try w.welcome();

    // membro comum não manda em ninguém
    try v.admin(proto.admin_kick, dono.id, 0);
    try v.admin(proto.admin_mute, w.id, 1);
    // dono silencia a visita: ela recebe o aviso, os membros mostram, a voz dela some
    try dono.admin(proto.admin_mute, v.id, 1);
    {
        var r: proto.Reader = .{ .data = try v.expect(.notice) };
        try testing.expectEqual(proto.notice_muted, try r.u8_());
    }
    while (true) {
        const l = try w.members();
        if (l.get(v.id)) |m| if (m.flags & proto.member_muted != 0) {
            try testing.expect(l.get(w.id).?.flags & proto.member_muted == 0); // a outra não
            try testing.expect(l.get(dono.id).?.owner);
            break;
        };
    }
    const pac = try proto.Msg.alloc(.voice, 8);
    @memset(pac.payload(), 0x55);
    try v.send(pac);
    try v.chat("marcador");
    while (true) {
        const t = try proto.recvMsg(w.sock, &w.ch, &w.rb);
        try testing.expect(t != .voice);
        if (t == .chat) {
            var r: proto.Reader = .{ .data = proto.payloadOf(&w.rb) };
            _ = try r.u32_();
            if (try r.u32_() == v.id) break;
        }
    }
    // dono para a transmissão da outra
    try w.streamStart(proto.kind_screen, 0);
    _ = try dono.waitFlag(w.id, proto.member_streaming, true);
    try dono.admin(proto.admin_stop_stream, w.id, proto.kind_screen);
    {
        var r: proto.Reader = .{ .data = try w.expect(.notice) };
        try testing.expectEqual(proto.notice_stream_stopped, try r.u8_());
        _ = try r.str();
        try testing.expectEqual(proto.kind_screen, try r.u8_());
    }
    _ = try dono.waitFlag(w.id, proto.member_streaming, false);
    // dá admin pra outra: ela pode expulsar membro comum, mas não o dono
    try dono.admin(proto.admin_set_admin, w.id, 1);
    {
        var r: proto.Reader = .{ .data = try w.expect(.notice) };
        try testing.expectEqual(proto.notice_admin_on, try r.u8_());
    }
    try w.admin(proto.admin_kick, dono.id, 0);
    // dono bane a visita: sai com o motivo e não volta (nem com outro nome, pela chave do app)
    try dono.admin(proto.admin_ban, v.id, 0);
    try testing.expectEqual(proto.deny_banned, try v.denied());
    sync.sleepMs(300);
    try testing.expectEqual(@as(usize, 2), srv.memberCount());
    var v2 = try TestClient.connectKey(port, "Disfarce", "", "", 0x1234);
    defer v2.close();
    try testing.expectEqual(proto.deny_banned, try v2.denied());
    var v3 = try TestClient.connect(port, "visita", "", ""); // mesmo nome (maiúscula/minúscula não importa)
    defer v3.close();
    try testing.expectEqual(proto.deny_banned, try v3.denied());
    // tranca: ninguém novo entra; destranca: entra
    try dono.admin(proto.admin_lock, 0, 1);
    while ((try dono.members()).room_flags & proto.room_locked == 0) {}
    var x = try TestClient.connect(port, "Novo", "", "");
    defer x.close();
    try testing.expectEqual(proto.deny_locked, try x.denied());
    try dono.admin(proto.admin_lock, 0, 0);
    while ((try dono.members()).room_flags & proto.room_locked != 0) {}
    var y = try TestClient.connect(port, "Novo", "", "");
    defer y.close();
    try y.welcome();
    // o dono ainda está lá (ninguém conseguiu expulsar)
    try testing.expectEqual(@as(usize, 3), srv.memberCount());
}

test "admin: quem foi silenciado continua silenciado se cair e voltar (pela chave do app)" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "token-do-dono" });
    defer srv.stop();

    var dono = try TestClient.connect(port, "Dono", "", "token-do-dono");
    defer dono.close();
    try dono.welcome();
    var v = try TestClient.connectKey(port, "Visita", "", "", 0x777);
    try v.welcome();
    try dono.admin(proto.admin_mute, v.id, 1);
    {
        var r: proto.Reader = .{ .data = try v.expect(.notice) };
        try testing.expectEqual(proto.notice_muted, try r.u8_());
    }
    // cai e volta (outra conexão, mesma chave): o aviso chega de novo e a lista mostra silenciado
    v.close();
    while (srv.memberCount() != 1) sync.sleepMs(20);
    var v2 = try TestClient.connectKey(port, "Visita", "", "", 0x777);
    try v2.welcome();
    {
        var r: proto.Reader = .{ .data = try v2.expect(.notice) };
        try testing.expectEqual(proto.notice_muted, try r.u8_());
    }
    while (true) {
        const l = try dono.members();
        if (l.get(v2.id)) |m| if (m.flags & proto.member_muted != 0) break;
    }
    // liberou: quem cai e volta entra liberado
    try dono.admin(proto.admin_mute, v2.id, 0);
    {
        var r: proto.Reader = .{ .data = try v2.expect(.notice) };
        try testing.expectEqual(proto.notice_unmuted, try r.u8_());
    }
    v2.close();
    while (srv.memberCount() != 1) sync.sleepMs(20);
    var v3 = try TestClient.connectKey(port, "Visita", "", "", 0x777);
    defer v3.close();
    try v3.welcome();
    while (true) {
        const l = try dono.members();
        if (l.get(v3.id)) |m| {
            try testing.expect(m.flags & proto.member_muted == 0);
            break;
        }
    }
}

test "ponteiro: chega em quem assiste e em quem transmite, não nos outros" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();
    var t = try TestClient.connect(port, "T", "", "");
    defer t.close();
    try t.welcome();
    var e = try TestClient.connect(port, "E", "", "");
    defer e.close();
    try e.welcome();
    var o = try TestClient.connect(port, "O", "", "");
    defer o.close();
    try o.welcome();
    var f = try TestClient.connect(port, "F", "", "");
    defer f.close();
    try f.welcome();
    try liveRoom(&t, &e);
    try o.watch(t.id, 0);
    // espera os dois aparecerem assistindo
    while (true) {
        const l = try t.members();
        _ = l;
        if (srv.watchingCount(o.id) == 1 and srv.watchingCount(e.id) == 1) break;
    }
    const m = try proto.Msg.alloc(.pointer, 9);
    std.mem.writeInt(u32, m.payload()[0..4], t.id, .little);
    std.mem.writeInt(u16, m.payload()[4..6], 1000, .little);
    std.mem.writeInt(u16, m.payload()[6..8], 2000, .little);
    m.payload()[8] = proto.pointer_visible | proto.pointer_ping;
    try e.send(m);
    for ([_]*TestClient{ &t, &o }) |who| {
        var r: proto.Reader = .{ .data = try who.expect(.pointer) };
        try testing.expectEqual(e.id, try r.u32_());
        try testing.expectEqual(t.id, try r.u32_());
        try testing.expectEqual(@as(u16, 1000), try r.u16_());
        try testing.expectEqual(@as(u16, 2000), try r.u16_());
    }
    // F não assiste: o próximo chat chega antes de qualquer ponteiro
    try e.chat("fim");
    while (true) {
        const ty = try proto.recvMsg(f.sock, &f.ch, &f.rb);
        try testing.expect(ty != .pointer);
        if (ty == .chat) {
            var r: proto.Reader = .{ .data = proto.payloadOf(&f.rb) };
            _ = try r.u32_();
            if (try r.u32_() == e.id) break;
        }
    }
}

test "clipes: quem guarda clipes recebe IDR de vez em quando" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .clip_key_interval_ms = 600 });
    defer srv.stop();
    var t = try TestClient.connect(port, "T", "", "");
    defer t.close();
    try t.welcome();
    var e = try TestClient.connect(port, "E", "", "");
    defer e.close();
    try e.welcome();
    try t.streamStart(proto.kind_screen, 0);
    try e.watch(t.id, proto.watch_clips);
    _ = try t.expect(.keyreq);
    try t.send(try frameSeq(true, 100, 0));
    try e.ackFrame(try e.expect(.frame));
    // tela parada: mesmo assim, passado o intervalo, o servidor pede outro IDR
    const t0 = sync.nowMs();
    _ = try t.expect(.keyreq);
    try testing.expect(sync.nowMs() - t0 >= 300);
}

test "sala: membro comum não expulsa ninguém; o dono sim" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "token-do-dono" });
    defer srv.stop();

    var dono = try TestClient.connect(port, "Dono", "", "token-do-dono");
    defer dono.close();
    try dono.welcome();
    var other = try TestClient.connect(port, "Visita", "", "");
    defer other.close();
    try other.welcome();

    var b: proto.Builder = .{};
    defer b.deinit();
    // visita tenta expulsar o dono: nada acontece (mensagem antiga, kick)
    try b.begin(.kick);
    try b.u32_(dono.id);
    try other.send(try b.finish());
    // dono expulsa a visita
    try b.begin(.kick);
    try b.u32_(other.id);
    try dono.send(try b.finish());

    var r: proto.Reader = .{ .data = try other.expect(.denied) };
    try testing.expect(std.mem.find(u8, try r.str(), "expulsou") != null);
    try testing.expectEqual(proto.deny_kicked, try r.u8_());
    net.shutdown(other.sock); // como o app faz depois do aviso
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

    try liveRoom(&streamer, &viewer);
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

    try liveRoom(&streamer, &viewer);
    try streamer.send(try frameSeq(true, 100, 0));
    try viewer.ackFrame(try viewer.expect(.frame));

    var b: proto.Builder = .{};
    defer b.deinit();
    sync.sleepMs(1100); // passa o limite de 1 pedido por segundo
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

    try liveRoom(&streamer, &viewer);
    try streamer.send(try frameSeq(true, 100, 0));
    try viewer.ackFrame(try viewer.expect(.frame));

    // o decoder do espectador perde a referência logo depois do primeiro IDR:
    // o pedido cai no limite de 1 a cada 500 ms, e a tela do transmissor está
    // parada (nenhum quadro novo pra disparar o pedido em forwardFrame)
    var b: proto.Builder = .{};
    defer b.deinit();
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

    try liveRoom(&streamer, &viewer);

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
    var b: proto.Builder = .{};
    defer b.deinit();
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

test "sala: quem entra e sai sem parar não derruba a sala (IDR no máximo 1/s, entrada recusada depois de 6 em 30 s)" {
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
    try liveRoom(&streamer, &viewer);

    // alguém (mesma chave do app) entra, começa a assistir e sai, 8 vezes seguidas
    const t0 = sync.nowMs();
    var refused: usize = 0;
    for (0..8) |i| {
        var p = try TestClient.connectKey(port, "Pisca", "", "", 0xF1A9);
        defer p.close();
        if (i < 6) {
            try p.welcome();
            try p.watch(streamer.id, 0);
            sync.sleepMs(120);
        } else {
            try testing.expectEqual(proto.deny_generic, try p.denied());
            refused += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), refused);
    // quem transmite recebeu no máximo um pedido de IDR por segundo
    net.setRecvTimeout(streamer.sock, 300);
    var keyreqs: usize = 0;
    while (true) {
        const t = proto.recvMsg(streamer.sock, &streamer.ch, &streamer.rb) catch break;
        if (t == .keyreq) keyreqs += 1;
    }
    const secs = (sync.nowMs() - t0) / 1000;
    try testing.expect(keyreqs <= secs + 1);
}

extern "c" fn system(cmd: [*:0]const u8) c_int;
const c_system = system;

fn sendLog(c: *TestClient, id: u32, data: []const u8, chunk: usize) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(chunk, data.len - off);
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.log_chunk);
        try b.u32_(id);
        try b.u8_(proto.log_what_log);
        try b.u32_(@intCast(data.len));
        try b.u32_(@intCast(off));
        try b.bytes(data[off..][0..n]);
        try c.send(try b.finish());
        off += n;
    }
}

test "log pela sala: chega em pedaços em quem tem a coroa, quem mandou fica sabendo, um por minuto; servidor com pasta guarda" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "coroa" });
    defer srv.stop();
    var dono = try TestClient.connect(port, "Dono", "", "coroa");
    defer dono.close();
    try dono.welcome();
    var v = try TestClient.connect(port, "Visita", "", "");
    defer v.close();
    try v.welcome();

    var data: [150_000]u8 = undefined;
    for (&data, 0..) |*x, i| x.* = @intCast(i % 251);
    try sendLog(&v, 7, &data, proto.log_chunk_max);
    // o dono recebe os pedaços, com quem mandou
    var got: usize = 0;
    while (got < data.len) {
        var r: proto.Reader = .{ .data = try dono.expect(.log_chunk) };
        try testing.expectEqual(v.id, try r.u32_());
        try testing.expectEqualStrings("Visita", try r.str());
        try testing.expectEqual(@as(u32, 7), try r.u32_());
        _ = try r.u8_();
        try testing.expectEqual(@as(u32, data.len), try r.u32_());
        try testing.expectEqual(@as(u32, @intCast(got)), try r.u32_());
        const part = r.rest();
        try testing.expectEqualSlices(u8, data[got..][0..part.len], part);
        got += part.len;
    }
    {
        var r: proto.Reader = .{ .data = try v.expect(.log_ack) };
        try testing.expectEqual(@as(u32, 7), try r.u32_());
        try testing.expectEqual(proto.log_ack_delivered, try r.u8_());
        try testing.expectEqual(@as(u8, 1), try r.u8_());
    }
    // outro logo em seguida: recusado (um por minuto)
    try sendLog(&v, 8, data[0..1000], proto.log_chunk_max);
    {
        var r: proto.Reader = .{ .data = try v.expect(.log_ack) };
        try testing.expectEqual(@as(u32, 8), try r.u32_());
        try testing.expectEqual(proto.log_ack_refused, try r.u8_());
    }

    // servidor dedicado com pasta e ninguém com a coroa: guarda em disco
    const port2 = freshPort();
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/telinha-teste-logs-{d}", .{port2});
    _ = std.c.mkdir(dir.ptr, 0o700);
    const srv2 = try Server.start(.{ .port = port2, .logs_dir = dir });
    defer srv2.stop();
    var w = try TestClient.connect(port2, "Sozinho", "", "");
    defer w.close();
    try w.welcome();
    try sendLog(&w, 1, data[0..5000], 4096);
    {
        var r: proto.Reader = .{ .data = try w.expect(.log_ack) };
        _ = try r.u32_();
        try testing.expectEqual(proto.log_ack_saved, try r.u8_());
    }
    // o arquivo está lá, com o conteúdo inteiro
    var cmd_buf: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrintZ(&cmd_buf, "test $(cat {s}/*_Sozinho_log.txt | wc -c) = 5000 && rm -rf {s}", .{ dir, dir });
    try testing.expectEqual(@as(c_int, 0), c_system(cmd.ptr));
}

test "sala: watch só aceita quem existe" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port });
    defer srv.stop();

    var viewer = try TestClient.connect(port, "E", "", "");
    defer viewer.close();
    try viewer.welcome();
    // ids que não existem (e o próprio): ignorados, nada de lista crescendo
    for ([_]u32{ 999, 12345, viewer.id, proto.streamId(viewer.id, proto.kind_camera) }) |id| try viewer.watch(id, 0);
    // o servidor continua respondendo normalmente
    var b: proto.Builder = .{};
    defer b.deinit();
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

    try streamer.streamStart(proto.kind_screen, proto.stream_audio);
    try viewer.watch(streamer.id, 0);

    // a lista de membros marca que a transmissão tem áudio
    while (true) {
        const l = try viewer.members();
        if (l.get(streamer.id)) |m| if (m.flags & proto.member_audio != 0) break;
    }
    // o "assistir" vem por outra conexão (outra thread no servidor): a bandeira
    // de áudio pode chegar antes dele valer, e o áudio mandado antes não vai pra ninguém
    var waited: u32 = 0;
    while (srv.watchingCount(viewer.id) == 0 and waited < 3000) : (waited += 10) sync.sleepMs(10);

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
    // o servidor sabe que ele veio pelo túnel
    try testing.expectEqual(proto.route_tunnel, v.route);
    // quem entrou direto continua quando o link é desligado; o visitante sai
    var d = try TestClient.connect(room_port, "Direto", "segredo", "");
    defer d.close();
    try d.welcome();
    srv.closeTunnelConns();
    try testing.expectEqual(proto.deny_link_closed, try v.denied());
    sync.sleepMs(300);
    try testing.expectEqual(@as(usize, 1), srv.memberCount());
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
        const l = try b.members();
        seen_mic = if (l.get(a.id)) |m| m.flags & proto.member_mic != 0 else false;
        seen_deaf = if (l.get(c.id)) |m| m.flags & proto.member_deaf != 0 else false;
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
            _ = try cr.u32_();
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

// ------------------------------------------------------- vários caminhos

const connect_mod = @import("connect.zig");

test "convite: vários caminhos, IPv6 entre colchetes, senha" {
    const inv = connect_mod.splitInvite("telinha://192.168.0.5:7777,[2804:14c:1::1]:7777,bore.pub:41234#abc#d");
    try testing.expectEqualStrings("abc#d", inv.password.?);
    var t: [connect_mod.max_targets]connect_mod.Target = undefined;
    const n = connect_mod.parseList(inv.addrs, &t);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("192.168.0.5", t[0].hostSlice());
    try testing.expectEqualStrings("2804:14c:1::1", t[1].hostSlice());
    try testing.expectEqual(@as(u16, 7777), t[1].port);
    try testing.expectEqualStrings("bore.pub", t[2].hostSlice());
    try testing.expectEqual(@as(u16, 41234), t[2].port);
    // sem colchete o IPv6 é ambíguo; lixo e porta zero ficam de fora
    try testing.expect(connect_mod.parseOne("2804::1:7777") == null);
    try testing.expect(connect_mod.parseOne("host:0") == null);
    try testing.expectEqual(@as(usize, 1), connect_mod.parseList(" , nada, tcp://a.b:5/ ", &t));
    try testing.expectEqualStrings("a.b", t[0].hostSlice());
    // endereço só, sem convite
    try testing.expect(connect_mod.splitInvite("x:1").password == null);
    // com canal: telinha://endereços/canal#senha
    const ic = connect_mod.splitInvite("telinha://a.com:7777,[2804::1]:7777/jogos#pw");
    try testing.expectEqualStrings("a.com:7777,[2804::1]:7777", ic.addrs);
    try testing.expectEqualStrings("jogos", ic.channel.?);
    try testing.expectEqualStrings("pw", ic.password.?);
    try testing.expect(connect_mod.splitInvite("telinha://a.com:7777/").channel == null);
    try testing.expectEqualStrings("a.com:7777", connect_mod.splitInvite("a.com:7777/").addrs);
    // forma curta do IPv6
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("[2804:14c::1]", net.fmtIp6(.{ 0x28, 0x04, 0x01, 0x4c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &buf));
    try testing.expectEqualStrings("[::1]", net.fmtIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &buf));
    try testing.expectEqualStrings("[2001:db8:0:1::1]", net.fmtIp6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1 }, &buf));
}

/// Escuta e aceita, mas nunca responde (caminho que "não chega": firewall que
/// deixa o SYN passar mas nada mais, túnel travado).
fn silentListener(ls: net.Socket) void {
    var held: [8]net.Socket = undefined;
    var n: usize = 0;
    while (n < held.len) {
        held[n] = net.accept(ls) catch return;
        n += 1;
    }
}

/// Responde lixo (outro serviço na mesma porta, numa rede que não é a da sala).
fn garbageListener(ls: net.Socket) void {
    while (true) {
        const s = net.accept(ls) catch return;
        net.sendAll(s, "HTTP/1.1 400 Bad Request\r\n\r\n" ++ "x" ** 64) catch {};
        sync.sleepMs(200);
        net.close(s);
    }
}

test "vários caminhos: entra pelo que responde (fechado, mudo e lixo ficam pra trás), inclusive IPv6" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .password = "pw" });
    defer srv.stop();
    const mute_port = freshPort();
    const mute = try net.listen(mute_port);
    defer net.close(mute);
    try sync.spawn(silentListener, .{mute});
    const junk_port = freshPort();
    const junk = try net.listen(junk_port);
    defer net.close(junk);
    try sync.spawn(garbageListener, .{junk});
    const closed_port = freshPort(); // ninguém escuta

    var list_buf: [200]u8 = undefined;
    const list = try std.fmt.bufPrint(&list_buf, "127.0.0.1:{d},127.0.0.1:{d},127.0.0.1:{d},[::1]:{d}", .{ mute_port, closed_port, junk_port, port });
    var targets: [connect_mod.max_targets]connect_mod.Target = undefined;
    const n = connect_mod.parseList(list, &targets);
    try testing.expectEqual(@as(usize, 4), n);
    var cancel = std.atomic.Value(bool).init(false);
    var fail: connect_mod.Failure = .{ .err = error.ConnectFailed };
    const t0 = sync.nowMs();
    const w = try connect_mod.race(targets[0..n], proto.version, 10_000, &cancel, &fail);
    defer net.close(w.sock);
    // o caminho bom é o último da lista: sai 750 ms depois do primeiro e ganha
    try testing.expectEqual(@as(usize, 3), w.index);
    try testing.expect(sync.nowMs() - t0 < 2500);
    // e a conexão funciona: dá pra entrar na sala por ela
    var ch = try crypto.Channel.derive(&w.hs, w.peer, true, "pw");
    var b: proto.Builder = .{};
    defer b.deinit();
    try b.begin(.hello);
    try b.str("Corredor");
    try b.str("");
    try b.u64_(0);
    const m = try b.finish();
    defer m.release();
    const plain = m.data[4..];
    var out: [256]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(plain.len + crypto.tag_len), .little);
    ch.seal(plain, out[4..][0 .. plain.len + crypto.tag_len]);
    try net.sendAll(w.sock, out[0 .. 4 + plain.len + crypto.tag_len]);
    var rb: proto.RecvBuf = .{};
    defer rb.deinit();
    try testing.expectEqual(proto.Type.welcome, try proto.recvMsg(w.sock, &ch, &rb));

    // só caminhos ruins: falha com o motivo certo, sem travar
    const only_bad = try std.fmt.bufPrint(&list_buf, "127.0.0.1:{d},127.0.0.1:{d}", .{ closed_port, junk_port });
    const nb = connect_mod.parseList(only_bad, &targets);
    try testing.expectError(error.NotTelinha, connect_mod.race(targets[0..nb], proto.version, 5_000, &cancel, &fail));
}

test "canais: nome normalizado (sem #, minúsculas, espaço vira -, acento ok, até 24 bytes)" {
    var b: [proto.channel_name_max]u8 = undefined;
    try testing.expectEqualStrings("jogos", server_mod.normalizeChannel("#Jogos", &b).?);
    try testing.expectEqualStrings("filmes-antigos", server_mod.normalizeChannel("  Filmes  Antigos ", &b).?);
    try testing.expectEqualStrings("ação_2.0", server_mod.normalizeChannel("Ação_2.0", &b).?);
    try testing.expect(server_mod.normalizeChannel("a/b", &b) == null);
    try testing.expect(server_mod.normalizeChannel("###", &b) == null);
    try testing.expect(server_mod.normalizeChannel("", &b) == null);
    try testing.expectEqual(@as(usize, 24), server_mod.normalizeChannel("abcdefghijklmnopqrstuvwxyz0123", &b).?.len);
    // não corta letra acentuada no meio
    const n = server_mod.normalizeChannel("aaaaaaaaaaaaaaaaaaaaaaaçç", &b).?;
    try testing.expect(std.unicode.utf8ValidateSlice(n));
}

test "canais: cada um com o seu chat, membros e voz; nome novo cria; trocar leva o histórico; vazio some; app antigo cai no padrão" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .channels = "geral,Jogos" });
    defer srv.stop();
    var tb: [256]u8 = undefined;

    // app antigo (sem o campo do canal): o padrão
    var a = try TestClient.connect(port, "Ana", "", "");
    defer a.close();
    try a.welcome();
    var l = try a.channels();
    try testing.expectEqualStrings("geral", l.current());
    try testing.expect(l.has("geral") and l.has("jogos"));

    var b = try TestClient.connectChan(port, "Bia", "", "jogos");
    defer b.close();
    try b.welcome();
    l = try b.channels();
    try testing.expectEqualStrings("jogos", l.current());

    // canal que não existe: cria (normalizado)
    var c = try TestClient.connectChan(port, "Caio", "", "#Filmes Antigos");
    defer c.close();
    try c.welcome();
    l = try c.channels();
    try testing.expectEqualStrings("filmes-antigos", l.current());
    try testing.expectEqual(@as(usize, 3), l.n);

    // membros: só quem está no mesmo canal
    const ml = try b.members();
    try testing.expect(ml.get(b.id) != null and ml.get(a.id) == null and ml.get(c.id) == null);

    // chat: fica no canal
    try b.chat("bora jogar");
    try a.chat("oi geral");
    const got = try a.userChat(&tb);
    try testing.expectEqualStrings("oi geral", got.text);
    try testing.expectEqual(a.id, got.from);

    // voz: só pra quem está no mesmo canal (Ana fala; Bia não ouve)
    const pacote = [_]u8{ 0x78, 1, 2, 3 };
    const vm = try proto.Msg.alloc(.voice, 4 + pacote.len);
    std.mem.writeInt(u32, vm.payload()[0..4], 1, .little);
    @memcpy(vm.payload()[4..], &pacote);
    try a.send(vm);
    try a.chat("marcador");
    while (true) {
        const t = try proto.recvMsg(b.sock, &b.ch, &b.rb);
        try testing.expect(t != .voice);
        // a Bia não vê o chat do geral: o próximo de alguém é o dela mesma, depois nada
        if (t == .chat) {
            var r: proto.Reader = .{ .data = proto.payloadOf(&b.rb) };
            _ = try r.u32_();
            const from = try r.u32_();
            _ = try r.str();
            const text = try r.str();
            if (from == 0) continue;
            try testing.expectEqualStrings("bora jogar", text);
            break;
        }
    }

    // assistir alguém de outro canal: recusado
    try b.streamStart(proto.kind_screen, 0);
    try a.watch(b.id, 0);
    sync.sleepMs(150);
    try testing.expectEqual(@as(usize, 0), srv.watchingCount(a.id));

    // Caio vai pro jogos: recebe o canal novo e o histórico dele; o filmes-antigos some
    try c.watch(b.id, 0); // ainda em outro canal: não vale
    try c.joinChannel("JOGOS");
    l = try c.waitChannels({}, struct {
        fn f(_: void, x: *const ChanList) bool {
            return std.mem.eql(u8, x.current(), "jogos");
        }
    }.f);
    try testing.expect(!l.has("filmes-antigos"));
    const hist = try c.userChat(&tb);
    try testing.expect(hist.history);
    try testing.expectEqualStrings("bora jogar", hist.text);
    // agora dá pra assistir a Bia
    try c.watch(b.id, 0);
    _ = try b.expect(.keyreq);
    try testing.expectEqual(@as(usize, 1), srv.watchingCount(c.id));

    // a Bia vai pro geral: o Caio para de assistir ela (ficou no jogos)
    sync.sleepMs(900); // limite de troca
    try b.joinChannel("geral");
    _ = try b.waitChannels({}, struct {
        fn f(_: void, x: *const ChanList) bool {
            return std.mem.eql(u8, x.current(), "geral");
        }
    }.f);
    sync.sleepMs(100);
    try testing.expectEqual(@as(usize, 0), srv.watchingCount(c.id));
    // e a Ana vê a Bia na lista de membros do geral
    while (true) {
        const m2 = try a.members();
        if (m2.get(b.id) != null) break;
    }
    // jogos é fixo: vazio continua na lista (com 1 pessoa: o Caio)
    l = try a.waitChannels({}, struct {
        fn f(_: void, x: *const ChanList) bool {
            return x.peopleIn("geral") == 2;
        }
    }.f);
    try testing.expect(l.has("jogos"));
}

test "canais: servidor sem canais novos não deixa criar; nome inválido avisa" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .channels = "sala-a,sala-b", .new_channels = false });
    defer srv.stop();
    var a = try TestClient.connectChan(port, "Ana", "", "outra");
    defer a.close();
    try a.welcome();
    var l = try a.channels();
    try testing.expectEqualStrings("sala-a", l.current()); // não existe e não pode criar: o padrão
    try a.joinChannel("nova");
    var r: proto.Reader = .{ .data = try a.expect(.notice) };
    try testing.expectEqual(proto.notice_channel, try r.u8_());
    sync.sleepMs(900);
    try a.joinChannel("a/b");
    r = .{ .data = try a.expect(.notice) };
    try testing.expectEqual(proto.notice_channel, try r.u8_());
    try a.joinChannel("sala-b");
    l = try a.waitChannels({}, struct {
        fn f(_: void, x: *const ChanList) bool {
            return std.mem.eql(u8, x.current(), "sala-b");
        }
    }.f);
    try testing.expectEqual(@as(usize, 2), l.n);
}

test "estatísticas: só quem entrou com o token de admin recebe; pessoas, canais e banda" {
    net.init();
    const port = freshPort();
    const srv = try Server.start(.{ .port = port, .admin_token = "tok" });
    defer srv.stop();
    var dono = try TestClient.connectChan(port, "Dono", "tok", "");
    defer dono.close();
    try dono.welcome();
    var b = try TestClient.connectChan(port, "Bia", "", "outro");
    defer b.close();
    try b.welcome();

    // quem não é dono pede: nada
    var sb: proto.Builder = .{};
    defer sb.deinit();
    try sb.begin(.stats);
    try sb.u8_(1);
    try b.send(try sb.finish());
    // o dono pede: chega na hora
    try sb.begin(.stats);
    try sb.u8_(1);
    try dono.send(try sb.finish());
    var r: proto.Reader = .{ .data = try dono.expect(.stats) };
    _ = try r.u32_(); // uptime
    _ = try r.u32_(); // cpu
    try testing.expect((try r.u8_()) >= 1); // núcleos
    _ = try r.u32_(); // memória
    _ = try r.u32_();
    _ = try r.u32_();
    try testing.expectEqual(@as(u16, 2), try r.u16_()); // pessoas
    _ = try r.u16_(); // udp
    _ = try r.u16_(); // máximo
    try testing.expectEqual(@as(u8, 2), try r.u8_()); // canais: geral + outro
    _ = try r.take(2 * 4 + 4 + 1);
    try testing.expectEqual(@as(u16, 2), try r.u16_());
    var saw_bia = false;
    for (0..2) |_| {
        _ = try r.u32_();
        const nm = try r.str();
        const ch = try r.str();
        if (std.mem.eql(u8, nm, "Bia")) {
            saw_bia = true;
            try testing.expectEqualStrings("outro", ch);
        }
        _ = try r.take(1 + 1 + 1 + 2 + 4 + 4 + 4 + 2);
    }
    try testing.expect(saw_bia);
    // a Bia não recebeu estatística nenhuma (um chat depois chega antes)
    try dono.chat("marcador");
    try b.chat("marcador");
    while (true) {
        const t = try proto.recvMsg(b.sock, &b.ch, &b.rb);
        try testing.expect(t != .stats);
        if (t == .chat) {
            var cr: proto.Reader = .{ .data = proto.payloadOf(&b.rb) };
            _ = try cr.u32_();
            if ((try cr.u32_()) == b.id) break;
        }
    }
    // a cada 2 s chega outra, enquanto estiver ligado
    _ = try dono.expect(.stats);
}
