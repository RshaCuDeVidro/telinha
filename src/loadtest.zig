//! Teste de carga: `zig build loadtest -- [espectadores] [segundos] [lentos] [upload_kbps]`.
//!
//! Sobe uma sala local, um transmissor mandando H.264 de verdade a 30 fps
//! (~4 Mbit/s), N espectadores e um espectador LENTO: link de 2 Mbit/s (metade
//! do que a transmissão precisa). Mede se todo mundo recebe os quadros, se o lento não atrapalha
//! os outros (nem com IDR demais), se o atraso do lento fica limitado em vez
//! de crescer sem parar, e se a memória do servidor fica estável.
//!
//! Com `upload_kbps`, o transmissor fala com o servidor através de um túnel
//! ruim (como ngrok/bore com upload limitado): buffer sem limite, então o TCP
//! dele nunca sente o congestionamento — só as confirmações de ponta a ponta
//! revelam o atraso, e o controle de taxa de verdade (ratectl.zig) tem que
//! trazer a transmissão pra dentro do link.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const crypto = @import("crypto.zig");
const codec = @import("codec.zig");
const Server = @import("server.zig").Server;
const RateControl = @import("ratectl.zig").RateControl;
const gpa = std.heap.c_allocator;

const Conn = struct {
    sock: net.Socket,
    ch: crypto.Channel,
    rb: proto.RecvBuf = .{},
    id: u32 = 0,
    send_mutex: sync.Mutex = .{},

    fn open(port: u16, name: []const u8, slow_link: bool) !*Conn {
        const s = try net.connect("127.0.0.1", port);
        // link lento simulado: janela TCP pequena, a pressão chega no servidor
        if (slow_link) net.setRecvBuffer(s, 32 * 1024);
        const hs = try crypto.Handshake.init();
        try net.sendAll(s, &hs.helloBytes(proto.version));
        var hb: [crypto.hello_len]u8 = undefined;
        try net.recvAll(s, &hb);
        const c = try gpa.create(Conn);
        c.* = .{ .sock = s, .ch = try crypto.Channel.derive(&hs, try crypto.parseHello(&hb), true, "") };
        var b: proto.Builder = .{};
        defer b.deinit();
        try b.begin(.hello);
        try b.str(name);
        try b.str("");
        try c.send(try b.finish());
        while (true) {
            const t = try proto.recvMsg(c.sock, &c.ch, &c.rb);
            if (t == .welcome) {
                var r: proto.Reader = .{ .data = proto.payloadOf(&c.rb) };
                c.id = try r.u32_();
                return c;
            }
        }
    }

    /// Confirma um frame recebido (como o cliente de verdade faz).
    fn ack(c: *Conn, payload: []const u8) void {
        const m = proto.Msg.alloc(.ack, 8) catch return;
        @memcpy(m.payload()[0..8], payload[0..8]); // u32 de, u32 seq
        c.send(m) catch {};
    }

    fn send(c: *Conn, m: *proto.Msg) !void {
        defer m.release();
        c.send_mutex.lock();
        defer c.send_mutex.unlock();
        const plain = m.data[4..];
        var out = try gpa.alloc(u8, 4 + plain.len + crypto.tag_len);
        defer gpa.free(out);
        std.mem.writeInt(u32, out[0..4], @intCast(plain.len + crypto.tag_len), .little);
        c.ch.seal(plain, out[4..]);
        try net.sendAll(c.sock, out);
    }
};

const Stats = struct {
    frames: std.atomic.Value(u32) = .init(0),
    keys: std.atomic.Value(u32) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    lat_sum_us: std.atomic.Value(u64) = .init(0),
    lat_max_us: std.atomic.Value(u64) = .init(0),
    // último quarto do teste (depois que a taxa já se ajustou)
    end_frames: std.atomic.Value(u32) = .init(0),
    end_lat_sum_us: std.atomic.Value(u64) = .init(0),
};

const slow_link_kbps = 2000;
var running = std.atomic.Value(bool).init(true);
var trace = false;
var final_quarter = std.atomic.Value(bool).init(false);
var keyreq = std.atomic.Value(bool).init(false);
var keyreqs = std.atomic.Value(u32).init(0);
var slow_hints = std.atomic.Value(u32).init(0);
var slow_floor = std.atomic.Value(u8).init(0);

fn viewerLoop(c: *Conn, st: *Stats, slow: bool) void {
    while (running.load(.acquire)) {
        const t = proto.recvMsg(c.sock, &c.ch, &c.rb) catch return;
        if (t != .frame) continue;
        const p = proto.payloadOf(&c.rb);
        if (p.len < 4 + proto.frame_header_len) continue;
        // atraso = agora - hora da captura (mesmo processo, mesmo relógio)
        const lat = sync.nowUs() -| std.mem.readInt(u64, p[9..17], .little);
        _ = st.lat_sum_us.fetchAdd(lat, .monotonic);
        _ = st.lat_max_us.fetchMax(lat, .monotonic);
        if (final_quarter.load(.monotonic)) {
            _ = st.end_frames.fetchAdd(1, .monotonic);
            _ = st.end_lat_sum_us.fetchAdd(lat, .monotonic);
        }
        _ = st.frames.fetchAdd(1, .monotonic);
        _ = st.bytes.fetchAdd(p.len, .monotonic);
        if (p[8] & proto.frame_key != 0) _ = st.keys.fetchAdd(1, .monotonic);
        if (slow and trace) std.debug.print("TRACE {d} seq={d} key={d} lat={d}ms len={d}\n", .{ sync.nowMs() % 100000, std.mem.readInt(u32, p[4..8], .little), p[8], lat / 1000, p.len });
        // link lento: cada byte leva o tempo de um link de 2 Mbit/s pra chegar
        if (slow) sync.sleepMs(@intCast(p.len * 8 / slow_link_kbps));
        c.ack(p);
    }
}

// frames do transmissor a caminho (confirmados pelo servidor)
var inflight_mutex: sync.Mutex = .{};
var inflight: proto.AckWindow = .{};

fn streamerReader(c: *Conn) void {
    while (running.load(.acquire)) {
        const t = proto.recvMsg(c.sock, &c.ch, &c.rb) catch return;
        switch (t) {
            .ack => {
                const seq = std.mem.readInt(u32, proto.payloadOf(&c.rb)[0..4], .little);
                inflight_mutex.lock();
                inflight.acked(seq, sync.nowUs());
                inflight_mutex.unlock();
            },
            .keyreq => {
                keyreq.store(true, .release);
                _ = keyreqs.fetchAdd(1, .monotonic);
            },
            .viewer_slow => {
                _ = slow_hints.fetchAdd(1, .monotonic);
                slow_floor.store(proto.payloadOf(&c.rb)[0], .release);
            },
            else => {},
        }
    }
}

/// Um sentido do túnel: lê tudo o que chega na hora (buffer sem limite) e
/// entrega depois de `delay_ms`, no máximo a `kbps` (0 = sem limite).
const Pipe = struct {
    from: net.Socket,
    to: net.Socket,
    kbps: u32,
    delay_ms: u32,
    mutex: sync.Mutex = .{},
    cond: sync.Cond = .{},
    chunks: std.ArrayList(Chunk) = .empty,
    max_buffered: usize = 0,
    buffered: usize = 0,

    const Chunk = struct { data: []u8, t: u64 };

    fn start(from: net.Socket, to: net.Socket, kbps: u32, delay_ms: u32) !*Pipe {
        const p = try gpa.create(Pipe);
        p.* = .{ .from = from, .to = to, .kbps = kbps, .delay_ms = delay_ms };
        try sync.spawn(reader, .{p});
        try sync.spawn(writer, .{p});
        return p;
    }

    fn reader(p: *Pipe) void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = net.recvSome(p.from, &buf) catch return;
            const d = gpa.dupe(u8, buf[0..n]) catch return;
            p.mutex.lock();
            p.chunks.append(gpa, .{ .data = d, .t = sync.nowUs() }) catch {};
            p.buffered += n;
            p.max_buffered = @max(p.max_buffered, p.buffered);
            p.cond.signal();
            p.mutex.unlock();
        }
    }

    fn writer(p: *Pipe) void {
        var next_us: u64 = 0;
        while (true) {
            p.mutex.lock();
            while (p.chunks.items.len == 0) p.cond.wait(&p.mutex);
            const ch = p.chunks.orderedRemove(0);
            p.mutex.unlock();
            defer gpa.free(ch.data);
            const due = ch.t + @as(u64, p.delay_ms) * 1000;
            var now = sync.nowUs();
            if (due > now) sync.sleepMs(@intCast((due - now + 999) / 1000));
            var off: usize = 0;
            while (off < ch.data.len) {
                const piece: usize = @min(ch.data.len - off, 4096);
                if (p.kbps != 0) {
                    now = sync.nowUs();
                    next_us = @max(next_us, now);
                    if (next_us > now + 1000) sync.sleepMs(@intCast((next_us - now) / 1000));
                    next_us += piece * 8 * 1000 / p.kbps;
                }
                net.sendAll(p.to, ch.data[off..][0..piece]) catch return;
                off += piece;
            }
            p.mutex.lock();
            p.buffered -= ch.data.len;
            p.mutex.unlock();
        }
    }
};

var tunnel_up: ?*Pipe = null;

/// Túnel ruim entre o transmissor e o servidor (40 ms de cada lado).
fn tunnelAccept(ls: net.Socket, server_port: u16, kbps: u32) void {
    const a = net.accept(ls) catch return;
    const b = net.connect("127.0.0.1", server_port) catch return;
    tunnel_up = Pipe.start(a, b, kbps, 40) catch return;
    _ = Pipe.start(b, a, 0, 40) catch return;
}

fn rssKb() u64 {
    var buf: [4096]u8 = undefined;
    const f = std.c.fopen("/proc/self/status", "r") orelse return 0;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    const text = buf[0..n];
    const i = std.mem.find(u8, text, "VmRSS:") orelse return 0;
    var it = std.mem.tokenizeAny(u8, text[i + 6 ..], " \t\nk");
    return std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const n_viewers: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 8;
    const seconds: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 40;
    const n_slow: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 1;
    const upload_kbps: u32 = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 0;
    trace = std.c.getenv("TELINHA_TRACE") != null;
    net.init();
    sync.pool.start(@max(2, sync.cpuCount() - 1));

    const port: u16 = 47900;
    const srv = try Server.start(.{ .port = port, .room_name = "carga", .log = if (trace) logLine else null });
    defer srv.stop();

    // transmissor (direto ou pelo túnel ruim)
    const streamer = if (upload_kbps == 0) try Conn.open(port, "transmissor", false) else blk: {
        const ls = try net.listen(port + 1);
        try sync.spawn(tunnelAccept, .{ ls, port, upload_kbps });
        break :blk try Conn.open(port + 1, "transmissor", false);
    };
    {
        const m = try proto.Msg.alloc(.stream_start, 6);
        const p = m.payload();
        std.mem.writeInt(u16, p[0..2], 1280, .little);
        std.mem.writeInt(u16, p[2..4], 720, .little);
        p[4] = 30;
        p[5] = 0;
        try streamer.send(m);
    }
    try sync.spawn(streamerReader, .{streamer});

    // espectadores
    const stats = try gpa.alloc(Stats, n_viewers + n_slow);
    for (stats) |*s| s.* = .{};
    for (0..n_viewers + n_slow) |i| {
        var name_buf: [32]u8 = undefined;
        const slow = i >= n_viewers;
        const name = try std.fmt.bufPrint(&name_buf, "{s} {d}", .{ if (slow) "lento" else "espectador", i });
        const v = try Conn.open(port, name, slow);
        const m = try proto.Msg.alloc(.watch, 5);
        std.mem.writeInt(u32, m.payload()[0..4], streamer.id, .little);
        m.payload()[4] = 1;
        try v.send(m);
        try sync.spawn(viewerLoop, .{ v, &stats[i], slow });
    }

    // vídeo de verdade: 1280x720, faixa rolando + bloco se mexendo + um
    // retângulo de ruído novo a cada quadro (força o controle de taxa a trabalhar)
    const w = 1280;
    const h = 720;
    const target_bps: u32 = 4_000_000;
    var rc: RateControl = .{};
    rc.reset(target_bps);
    _ = rc.takeChange();
    var skipped: u32 = 0;
    var end_sent_bytes: u64 = 0; // enviado pelo transmissor no último quarto
    var enc = try codec.Encoder.init(.{ .width = w, .height = h, .fps = 30, .bitrate = target_bps });
    defer enc.deinit();
    const img = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(img);
    var rng = std.Random.DefaultPrng.init(7);
    for (img) |*b| b.* = rng.random().int(u8) | 0x80;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    std.debug.print("telinha loadtest: {d} espectadores + {d} lento(s) (link de {d} kbit/s), {d} s, 1280x720 @ 30 fps, {d} kbit/s\n", .{ n_viewers, n_slow, slow_link_kbps, seconds, target_bps / 1000 });
    if (upload_kbps != 0) std.debug.print("transmissor atrás de um túnel com buffer sem limite: upload de {d} kbit/s, 40 ms de cada lado\n", .{upload_kbps});
    const rss_start = rssKb();
    var sent: u32 = 0;
    var seq: u32 = 0;
    const t0 = sync.nowUs();
    var next = t0;
    while (sync.nowUs() - t0 < @as(u64, seconds) * 1_000_000) {
        if (sync.nowUs() - t0 > @as(u64, seconds) * 750_000) final_quarter.store(true, .monotonic);
        // anima: rola o topo e mexe um bloco
        const f: usize = sent;
        std.mem.copyForwards(u8, img[0 .. w * 4 * 200], img[w * 4 * 2 .. w * 4 * 202]);
        const bx = (f * 9) % (w - 200);
        for (300..500) |y| @memset(img[(y * w + bx) * 4 ..][0 .. 200 * 4], @intCast(f % 256));
        for (198..200) |y| rng.random().bytes(img[y * w * 4 ..][0 .. w * 4]);
        for (560..680) |y| rng.random().bytes(img[(y * w + 900) * 4 ..][0 .. 160 * 4]);

        // o mesmo controle de taxa do transmissor de verdade
        const now = sync.nowUs();
        inflight_mutex.lock();
        const sig: RateControl.Signals = .{
            .now_us = now,
            .excess_us = inflight.excessUs(now, 300_000),
            .key_allowance_us = inflight.keyAllowanceUs(now),
            .slow_floor_pct = slow_floor.swap(0, .acq_rel),
        };
        inflight_mutex.unlock();
        const skip = rc.congested(sig);
        if (!skip) rc.rampUp(now, sig.excess_us -| sig.key_allowance_us);
        if (rc.takeChange()) |b| {
            enc.setBitrate(b);
            if (trace) std.debug.print("STREAMER {d} taxa -> {d} kbit/s\n", .{ sync.nowMs() % 100000, b / 1000 });
        }
        if (skip) {
            skipped += 1;
            next += 33_333;
            const n2 = sync.nowUs();
            if (next > n2) sync.sleepMs(@intCast((next - n2) / 1000));
            continue;
        }
        if (keyreq.swap(false, .acq_rel)) enc.forceKey();
        out.clearRetainingCapacity();
        const key = (try enc.encode(img.ptr, w * 4, .bgrx, &out)) orelse false;
        const m = try proto.Msg.alloc(.frame, proto.frame_header_len + out.items.len);
        const p = m.payload();
        std.mem.writeInt(u32, p[0..4], seq, .little);
        seq +%= 1;
        p[4] = if (key) proto.frame_key else 0;
        std.mem.writeInt(u64, p[5..13], sync.nowUs(), .little);
        std.mem.writeInt(u16, p[13..15], w, .little);
        std.mem.writeInt(u16, p[15..17], h, .little);
        @memcpy(p[17..], out.items);
        inflight_mutex.lock();
        inflight.sent(seq -% 1, sync.nowUs(), key);
        inflight_mutex.unlock();
        if (final_quarter.load(.monotonic)) end_sent_bytes += m.data.len;
        try streamer.send(m);
        sent += 1;

        next += 33_333;
        const n3 = sync.nowUs();
        if (next > n3) sync.sleepMs(@intCast((next - n3) / 1000));
    }
    sync.sleepMs(500);
    running.store(false, .release);
    const rss_end = rssKb();

    std.debug.print("\nenviados: {d} quadros, {d} pulados ({d} IDR pedidos pelo servidor, {d} avisos de espectador lento; taxa final {d} kbit/s)\n", .{ sent, skipped, keyreqs.load(.monotonic), slow_hints.load(.monotonic), rc.bps / 1000 });
    if (tunnel_up) |t| std.debug.print("  túnel: maior acúmulo no buffer {d} KB\n", .{t.max_buffered / 1024});
    var min_frames: u32 = std.math.maxInt(u32);
    var max_keys: u32 = 0;
    var max_lat: u64 = 0;
    var end_lat: u64 = 0; // pior atraso médio no último quarto
    var total_bytes: u64 = 0;
    for (stats[0..n_viewers], 0..) |*s, i| {
        const fr = s.frames.load(.monotonic);
        min_frames = @min(min_frames, fr);
        max_keys = @max(max_keys, s.keys.load(.monotonic));
        max_lat = @max(max_lat, s.lat_max_us.load(.monotonic));
        end_lat = @max(end_lat, s.end_lat_sum_us.load(.monotonic) / @max(1, s.end_frames.load(.monotonic)));
        total_bytes += s.bytes.load(.monotonic);
        if (i < 3) std.debug.print("  espectador {d}: {d} quadros ({d:.1}%), {d} IDR, atraso médio {d:.1} ms (máx {d:.1})\n", .{
            i,                                                                 fr,
            @as(f64, @floatFromInt(fr)) * 100 / @as(f64, @floatFromInt(sent)), s.keys.load(.monotonic),
            ms(s.lat_sum_us.load(.monotonic) / @max(1, fr)),                   ms(s.lat_max_us.load(.monotonic)),
        });
    }
    if (n_viewers > 0) std.debug.print("  ...\n  pior espectador normal: {d:.1}% dos quadros, até {d} IDR, atraso máx {d:.1} ms, no último quarto {d:.1} ms\n", .{ @as(f64, @floatFromInt(min_frames)) * 100 / @as(f64, @floatFromInt(sent)), max_keys, ms(max_lat), ms(end_lat) });
    var slow_keys: u32 = std.math.maxInt(u32);
    var slow_max: u64 = 0;
    var slow_end_lat: u64 = 0; // pior média do último quarto
    var slow_end_frames: u32 = std.math.maxInt(u32);
    for (stats[n_viewers..]) |*slow| {
        const fr = slow.frames.load(.monotonic);
        const end_fr = slow.end_frames.load(.monotonic);
        const slow_lat = slow.end_lat_sum_us.load(.monotonic) / @max(1, end_fr);
        slow_keys = @min(slow_keys, slow.keys.load(.monotonic));
        slow_max = @max(slow_max, slow.lat_max_us.load(.monotonic));
        slow_end_lat = @max(slow_end_lat, slow_lat);
        slow_end_frames = @min(slow_end_frames, end_fr);
        total_bytes += slow.bytes.load(.monotonic);
        std.debug.print("  espectador lento: {d} quadros, recomeçou de um IDR {d}x, atraso médio {d:.0} ms (máx {d:.0}); no último quarto: {d:.0} q/s, atraso médio {d:.0} ms\n", .{
            fr,                                                                       slow.keys.load(.monotonic),
            ms(slow.lat_sum_us.load(.monotonic) / @max(1, fr)),                       ms(slow.lat_max_us.load(.monotonic)),
            @as(f64, @floatFromInt(end_fr)) / (@as(f64, @floatFromInt(seconds)) / 4), ms(slow_lat),
        });
    }
    if (n_slow == 0) slow_keys = 2;
    std.debug.print("  banda total entregue: {d:.1} Mbit/s\n", .{@as(f64, @floatFromInt(total_bytes)) * 8 / 1e6 / @as(f64, @floatFromInt(seconds))});
    std.debug.print("  memória do processo: {d} MB -> {d} MB\n", .{ rss_start / 1024, rss_end / 1024 });

    var ok = true;
    if (n_viewers == 0) min_frames = sent;
    check(&ok, min_frames * 100 >= sent * 95, "todo espectador normal recebeu >= 95% dos quadros");
    if (upload_kbps == 0) {
        check(&ok, max_lat < 500_000, "nenhum espectador normal passou de 500 ms de atraso");
    } else {
        // pelo túnel: o começo atrasa (IDR enorme num upload estreito), mas o
        // controle de taxa tem que trazer a transmissão pra dentro do link
        check(&ok, end_lat < 400_000, "no fim, atraso < 400 ms mesmo com o túnel escondendo o congestionamento");
        const end_kbps = end_sent_bytes * 8 / 1000 / (seconds / 4);
        std.debug.print("  transmissor no último quarto: {d} kbit/s (upload do túnel: {d})\n", .{ end_kbps, upload_kbps });
        check(&ok, end_kbps <= upload_kbps, "a taxa média desceu pra caber no upload");
    }
    // o lento custa no máximo ~1 IDR a cada 2,5 s pra sala (espera cresce até 8 s)
    check(&ok, max_keys <= 2 + seconds * 2 / 5, "o espectador lento não encheu a sala de IDR");
    check(&ok, slow_keys >= 2, "o espectador lento se recuperou (recebeu IDR de novo)");
    check(&ok, slow_max < 3_000_000, "o atraso do espectador lento ficou limitado (< 3 s)");
    if (n_slow > 0) {
        // depois de a taxa se ajustar, o lento acompanha: quase todos os quadros, pouco atraso
        check(&ok, slow_end_lat < 600_000, "no fim, o espectador lento acompanha com < 600 ms de atraso");
        check(&ok, slow_end_frames * 4 * 100 >= sent * 80, "no fim, o espectador lento recebe >= 80% dos quadros");
    }
    if (!ok) std.process.exit(1);
}

fn logLine(line: []const u8) void {
    std.debug.print("SERVER {d} {s}\n", .{ sync.nowMs() % 100000, line });
}

fn ms(us: u64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000;
}

fn check(ok: *bool, cond: bool, what: []const u8) void {
    std.debug.print("{s}: {s}\n", .{ if (cond) "OK" else "FALHOU", what });
    if (!cond) ok.* = false;
}
