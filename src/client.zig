//! Cliente da sala: conexão cifrada, estado (membros, chat, ping, relógio)
//! e as transmissões assistidas (decodificação H.264).
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const crypto = @import("crypto.zig");
const codec = @import("codec.zig");
const gl = @import("gl.zig");
const gpa = proto.gpa;

/// A UI liga isso quando o shader de YUV→RGB compilou: aí a thread de decode
/// entrega os planos YUV (1,5 byte/pixel) e a GPU converte a cor.
pub var gpu_yuv = std.atomic.Value(bool).init(false);

pub const Layout = enum { rgba, i420, nv12 };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn debugEnabled() bool {
    const S = struct {
        var checked = false;
        var on = false;
    };
    if (!S.checked) {
        S.on = getenv("TELINHA_DEBUG") != null;
        S.checked = true;
    }
    return S.on;
}

pub const Member = struct {
    id: u32,
    name: [48]u8,
    name_len: usize,
    streaming: bool,
    admin: bool,
    w: u16,
    h: u16,
    fps: u8,
    watching: [16]u32,
    n_watching: usize,

    pub fn nameSlice(self: *const Member) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn isWatching(self: *const Member, id: u32) bool {
        return std.mem.findScalar(u32, self.watching[0..self.n_watching], id) != null;
    }
};

pub const ChatLine = struct {
    from: u32,
    name: [48]u8,
    name_len: usize,
    text: []u8,
    hour: u8,
    minute: u8,

    pub fn nameSlice(self: *const ChatLine) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Status = enum { connecting, connected, failed };

/// Uma transmissão que estamos assistindo. Uma thread própria decodifica o
/// H.264 e converte pra RGBA (em paralelo no pool); a interface só sobe o
/// resultado pra GPU.
pub const View = struct {
    owner: u32,
    client: *Client,
    refs: std.atomic.Value(u32) = .init(2), // UI + thread de decode

    mutex: sync.Mutex = .{},
    pixels: []u8 = &.{}, // RGBA, ou planos YUV compactos (ver `layout`)
    layout: Layout = .rgba,
    w: u32 = 0,
    h: u32 = 0,
    resized: bool = false,
    dirty: bool = false,
    capture_ts: u64 = 0, // hora da captura do último quadro (relógio da sala)
    got_first: bool = false,

    qmutex: sync.Mutex = .{},
    qcond: sync.Cond = .{},
    frames: std.ArrayList([]u8) = .empty,
    stop: bool = false,
    waiting_key: bool = true,

    // estatísticas
    fps: f32 = 0,
    kbps: f32 = 0,
    decode_ms: f32 = 0,
    decoder_name: []const u8 = "",
    latency_ms: f32 = 0, // escrita pela UI quando o quadro vai pra tela
    stat_frames: u32 = 0,
    stat_bytes: u64 = 0,
    stat_since: u64 = 0,

    // GPU (só a thread da UI mexe)
    yuv: gl.YuvRenderer.Target = .{},
    tex: u32 = 0,
    tex_w: u32 = 0,
    tex_h: u32 = 0,

    pub fn release(v: *View) void {
        if (v.refs.fetchSub(1, .acq_rel) == 1) {
            for (v.frames.items) |f| gpa.free(f);
            v.frames.deinit(gpa);
            gpa.free(v.pixels);
            v.client.release();
            gpa.destroy(v);
        }
    }

    fn enqueue(v: *View, frame: []u8) void {
        v.qmutex.lock();
        defer v.qmutex.unlock();
        if (v.stop) {
            gpa.free(frame);
            return;
        }
        // decode não está dando conta: descarta tudo e pede um IDR
        if (v.frames.items.len >= 3) {
            for (v.frames.items) |f| gpa.free(f);
            v.frames.clearRetainingCapacity();
            v.waiting_key = true;
            v.client.sendWatch(v.owner, true);
        }
        v.frames.append(gpa, frame) catch {
            gpa.free(frame);
            return;
        };
        v.qcond.signal();
    }

    fn pop(v: *View) ?[]u8 {
        v.qmutex.lock();
        defer v.qmutex.unlock();
        while (v.frames.items.len == 0 and !v.stop) v.qcond.wait(&v.qmutex);
        if (v.stop) return null;
        return v.frames.orderedRemove(0);
    }

    fn shutdown(v: *View) void {
        v.qmutex.lock();
        v.stop = true;
        v.qcond.broadcast();
        v.qmutex.unlock();
    }

    /// Decoder em uso: NVDEC (placa NVIDIA) ou openh264.
    const Decoder = union(enum) {
        hw: codec.HwDecoder,
        sw: codec.Decoder,

        fn deinit(d: *Decoder) void {
            switch (d.*) {
                inline else => |*x| x.deinit(),
            }
        }
    };

    fn decodeLoop(v: *View) void {
        defer v.release();
        var err: [256]u8 = undefined;
        var dec: Decoder = blk: {
            if (v.client.hw_decode) {
                if (codec.HwDecoder.init(&err)) |h| break :blk .{ .hw = h } else |_| {}
            }
            break :blk .{ .sw = codec.Decoder.init() catch return };
        };
        defer dec.deinit();
        v.decoder_name = if (dec == .hw) "NVDEC" else "openh264";
        v.stat_since = sync.nowMs();
        while (v.pop()) |frame| {
            defer gpa.free(frame);
            v.decodeFrame(&dec, frame) catch {
                // perdeu referência ou veio lixo: recomeça do próximo IDR
                if (dec == .hw) {
                    // erro no NVDEC: segue com o openh264 daqui pra frente
                    if (codec.Decoder.init()) |sw| {
                        dec.deinit();
                        dec = .{ .sw = sw };
                        v.decoder_name = "openh264";
                    } else |_| {}
                }
                v.qmutex.lock();
                v.waiting_key = true;
                v.qmutex.unlock();
                v.client.sendWatch(v.owner, true);
            };
        }
    }

    fn decodeFrame(v: *View, dec: *Decoder, frame: []const u8) !void {
        const t0 = sync.nowUs();
        var r: proto.Reader = .{ .data = frame };
        _ = try r.u32_(); // seq
        const flags = try r.u8_();
        const ts = try r.u64_();
        _ = try r.u16_(); // w (o decoder sabe)
        _ = try r.u16_(); // h
        const bitstream = r.rest();
        const key = flags & proto.frame_key != 0;

        v.qmutex.lock();
        const waiting = v.waiting_key;
        if (key) v.waiting_key = false;
        v.qmutex.unlock();
        if (waiting and !key) return; // sem referência ainda: espera o IDR

        const Out = union(enum) { i420: codec.Decoder.Picture, nv12: codec.HwDecoder.Frame };
        const decoded: ?Out = switch (dec.*) {
            .sw => |*d| if (try d.decode(bitstream)) |p| .{ .i420 = p } else null,
            .hw => |*d| if (try d.decode(bitstream)) |f| .{ .nv12 = f } else null,
        };
        const pic = decoded orelse {
            if (debugEnabled()) std.debug.print("[telinha] decoder não devolveu imagem (quadro {s}, {d} bytes)\n", .{ if (key) "IDR" else "P", bitstream.len });
            return;
        };
        const pw: u32 = switch (pic) {
            .i420 => |p| p.w,
            .nv12 => |f| f.w,
        };
        const ph: u32 = switch (pic) {
            .i420 => |p| p.h,
            .nv12 => |f| f.h,
        };
        {
            const gpu = gpu_yuv.load(.acquire);
            const layout: Layout = if (!gpu) .rgba else switch (pic) {
                .i420 => .i420,
                .nv12 => .nv12,
            };
            const n = @as(usize, pw) * ph;
            const need = if (layout == .rgba) n * 4 else n + n / 2;
            v.mutex.lock();
            defer v.mutex.unlock();
            if (pw != v.w or ph != v.h or layout != v.layout or v.pixels.len != need) {
                const px = try gpa.alloc(u8, need);
                gpa.free(v.pixels);
                v.pixels = px;
                v.w = pw;
                v.h = ph;
                v.layout = layout;
                v.resized = true;
            }
            switch (pic) {
                .i420 => |p| if (gpu) {
                    // planos compactos (o decoder usa stride maior que a largura)
                    for (0..ph) |row| @memcpy(v.pixels[row * pw ..][0..pw], p.y[row * p.ys ..][0..pw]);
                    const cw = pw / 2;
                    const chh = ph / 2;
                    for (0..chh) |row| {
                        @memcpy(v.pixels[n + row * cw ..][0..cw], p.u[row * p.uvs ..][0..cw]);
                        @memcpy(v.pixels[n + n / 4 + row * cw ..][0..cw], p.v[row * p.uvs ..][0..cw]);
                    }
                } else codec.toRgba(p.y, p.u, p.v, p.ys, p.uvs, p.w, p.h, v.pixels),
                .nv12 => |f| if (gpu) {
                    @memcpy(v.pixels[0..n], f.y[0..n]);
                    @memcpy(v.pixels[n..][0 .. n / 2], f.uv[0 .. n / 2]);
                } else codec.nv12ToRgba(f.y, f.uv, f.w, f.h, v.pixels),
            }
            v.dirty = true;
            v.capture_ts = ts;
            v.got_first = true;
        }
        v.client.wake();

        v.stat_frames += 1;
        v.stat_bytes += frame.len;
        const dt = @as(f32, @floatFromInt(sync.nowUs() - t0)) / 1000.0;
        v.decode_ms = v.decode_ms * 0.9 + dt * 0.1;
        const now = sync.nowMs();
        if (now - v.stat_since >= 1000) {
            const secs = @as(f32, @floatFromInt(now - v.stat_since)) / 1000.0;
            v.fps = @as(f32, @floatFromInt(v.stat_frames)) / secs;
            v.kbps = @as(f32, @floatFromInt(v.stat_bytes)) / 1024.0 / secs;
            v.stat_frames = 0;
            v.stat_bytes = 0;
            v.stat_since = now;
        }
    }
};

pub const Client = struct {
    refs: std.atomic.Value(u32) = .init(1),
    host: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    pass: [128]u8 = undefined,
    pass_len: usize = 0,
    admin_token: [64]u8 = undefined,
    admin_token_len: usize = 0,
    wake_fn: *const fn () void,
    hw_decode: bool = true,

    sock: net.Socket = undefined,
    sock_ok: std.atomic.Value(bool) = .init(false),
    channel: crypto.Channel = undefined,
    queue: proto.SendQueue = .{},
    closing: std.atomic.Value(bool) = .init(false),
    keyreq: std.atomic.Value(bool) = .init(false),
    /// Relógio da sala = relógio local + offset (µs). Sincronizado pelo ping.
    clock_offset: std.atomic.Value(i64) = .init(0),
    best_rtt_us: u64 = std.math.maxInt(u64),

    /// Protege tudo abaixo.
    mutex: sync.Mutex = .{},
    status: Status = .connecting,
    err: [256]u8 = undefined,
    err_len: usize = 0,
    my_id: u32 = 0,
    is_admin: bool = false,
    room_name: [64]u8 = undefined,
    room_name_len: usize = 0,
    members: std.ArrayList(Member) = .empty,
    chat: std.ArrayList(ChatLine) = .empty,
    chat_count: u64 = 0, // total de mensagens já recebidas (pra rolar o chat)
    views: std.ArrayList(*View) = .empty,
    ping_ms: u32 = 0,

    pub const Options = struct {
        host: []const u8,
        port: u16,
        name: []const u8,
        password: []const u8,
        admin_token: []const u8 = "",
        hw_decode: bool = true,
        wake: *const fn () void,
    };

    pub fn create(o: Options) !*Client {
        const cl = try gpa.create(Client);
        cl.* = .{ .wake_fn = o.wake, .port = o.port, .hw_decode = o.hw_decode };
        copyInto(&cl.host, &cl.host_len, o.host);
        copyInto(cl.name[0..32], &cl.name_len, o.name);
        copyInto(&cl.pass, &cl.pass_len, o.password);
        copyInto(&cl.admin_token, &cl.admin_token_len, o.admin_token);
        _ = cl.refs.fetchAdd(1, .monotonic); // thread de conexão/leitura
        sync.spawn(connectLoop, .{cl}) catch {
            gpa.destroy(cl);
            return error.ThreadFailed;
        };
        return cl;
    }

    fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
    }

    pub fn wake(cl: *Client) void {
        cl.wake_fn();
    }

    pub fn retain(cl: *Client) *Client {
        _ = cl.refs.fetchAdd(1, .monotonic);
        return cl;
    }

    pub fn release(cl: *Client) void {
        if (cl.refs.fetchSub(1, .acq_rel) == 1) {
            cl.queue.deinit();
            cl.members.deinit(gpa);
            for (cl.chat.items) |l| gpa.free(l.text);
            cl.chat.deinit(gpa);
            cl.views.deinit(gpa);
            gpa.destroy(cl);
        }
    }

    /// Sai da sala. As views precisam ser liberadas pela UI (texturas) antes.
    pub fn close(cl: *Client) void {
        cl.closing.store(true, .release);
        if (cl.sock_ok.load(.acquire)) net.shutdown(cl.sock);
        cl.queue.close();
        cl.release();
    }

    /// Relógio da sala em µs.
    pub fn serverNowUs(cl: *const Client) u64 {
        const local: i64 = @intCast(sync.nowUs());
        return @intCast(@max(0, local + cl.clock_offset.load(.monotonic)));
    }

    fn setError(cl: *Client, comptime fmt: []const u8, args: anytype) void {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        cl.status = .failed;
        const s = std.fmt.bufPrint(&cl.err, fmt, args) catch cl.err[0..0];
        cl.err_len = s.len;
    }

    pub fn errSlice(cl: *Client) []const u8 {
        return cl.err[0..cl.err_len];
    }

    fn handshake(cl: *Client) !void {
        net.setRecvTimeout(cl.sock, 10_000);
        const hs = try crypto.Handshake.init();
        try net.sendAll(cl.sock, &hs.helloBytes(proto.version));
        var hb: [crypto.hello_len]u8 = undefined;
        try net.recvAll(cl.sock, &hb);
        const peer = try crypto.parseHello(&hb);
        if (peer.version != proto.version) {
            cl.setError("A sala usa outra versão do telinha (protocolo {d}, o seu é {d}). Atualizem pra mesma versão.", .{ peer.version, proto.version });
            return error.VersionMismatch;
        }
        cl.channel = try crypto.Channel.derive(&hs, peer, true, cl.pass[0..cl.pass_len]);
        net.setRecvTimeout(cl.sock, 0);
    }

    fn connectLoop(cl: *Client) void {
        defer cl.release();
        defer cl.wake();
        cl.sock = net.connect(cl.host[0..cl.host_len], cl.port) catch |e| {
            cl.setError("{s}", .{switch (e) {
                error.UnknownHost => "Não achei esse endereço.",
                error.ConnectionRefused => "Conexão recusada. A sala está aberta? O túnel está ligado?",
                else => "Não consegui conectar.",
            }});
            return;
        };
        if (cl.closing.load(.acquire)) {
            net.close(cl.sock);
            return;
        }
        cl.sock_ok.store(true, .release);
        cl.handshake() catch |e| {
            if (e != error.VersionMismatch) cl.setError("{s}", .{switch (e) {
                error.NotTelinha => "Isso não é uma sala do telinha.",
                else => "A sala não respondeu direito (o endereço está certo?).",
            }});
            net.close(cl.sock);
            return;
        };

        // escritora
        _ = cl.refs.fetchAdd(1, .monotonic);
        sync.spawn(writerLoop, .{cl}) catch {
            _ = cl.refs.fetchSub(1, .monotonic);
            net.close(cl.sock);
            cl.setError("Falha ao criar thread.", .{});
            return;
        };

        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.hello) catch return;
        b.str(cl.name[0..cl.name_len]) catch return;
        b.str(cl.admin_token[0..cl.admin_token_len]) catch return;
        cl.queue.pushOwned(b.finish() catch return);

        var rb: proto.RecvBuf = .{};
        defer rb.deinit();
        while (!cl.closing.load(.acquire)) {
            const typ = proto.recvMsg(cl.sock, &cl.channel, &rb) catch |e| {
                if (e == error.WrongPassword) cl.setError("Senha errada.", .{});
                break;
            };
            cl.handle(typ, proto.payloadOf(&rb)) catch break;
            cl.wake();
        }
        cl.mutex.lock();
        const was = cl.status;
        cl.mutex.unlock();
        if (was != .failed and !cl.closing.load(.acquire)) cl.setError("A conexão com a sala caiu.", .{});
        cl.queue.close();
        net.shutdown(cl.sock);
    }

    fn writerLoop(cl: *Client) void {
        defer cl.release();
        cl.queue.writerLoop(cl.sock, &cl.channel);
        // a escritora sai por último: fecha o socket
        net.close(cl.sock);
    }

    fn pingLoop(cl: *Client) void {
        defer cl.release();
        var n: u32 = 0;
        while (!cl.closing.load(.acquire)) : (n += 1) {
            const m = proto.Msg.alloc(.ping, 8) catch return;
            std.mem.writeInt(u64, m.payload()[0..8], sync.nowUs(), .little);
            cl.queue.pushOwned(m);
            // os primeiros pings vêm rápido pra sincronizar o relógio logo
            const wait: u32 = if (n < 5) 2 else 20;
            var i: u32 = 0;
            while (i < wait and !cl.closing.load(.acquire)) : (i += 1) sync.sleepMs(100);
        }
    }

    fn onPong(cl: *Client, t: u64, server_us: u64) void {
        const now = sync.nowUs();
        const rtt = now -| t;
        // estimativa: o servidor leu o relógio no meio do caminho
        const offset: i64 = @as(i64, @intCast(server_us)) + @as(i64, @intCast(rtt / 2)) - @as(i64, @intCast(now));
        // confia mais nas medições com RTT baixo
        if (rtt <= cl.best_rtt_us +| 2000) {
            cl.best_rtt_us = @min(cl.best_rtt_us, rtt);
            const old = cl.clock_offset.load(.monotonic);
            const new = if (old == 0) offset else old + @divTrunc(offset - old, 4);
            cl.clock_offset.store(new, .monotonic);
        }
        cl.best_rtt_us +|= 200; // deixa a referência "envelhecer" se a rede mudar
        cl.mutex.lock();
        cl.ping_ms = @intCast(@min(rtt / 1000, 99999));
        cl.mutex.unlock();
    }

    fn handle(cl: *Client, typ: proto.Type, payload: []const u8) !void {
        var r: proto.Reader = .{ .data = payload };
        switch (typ) {
            .welcome => {
                cl.mutex.lock();
                defer cl.mutex.unlock();
                cl.my_id = try r.u32_();
                const rn = try r.str();
                copyInto(&cl.room_name, &cl.room_name_len, rn);
                cl.is_admin = (try r.u8_()) != 0;
                const server_us = try r.u64_();
                cl.clock_offset.store(@as(i64, @intCast(server_us)) - @as(i64, @intCast(sync.nowUs())), .monotonic);
                cl.status = .connected;
                _ = cl.refs.fetchAdd(1, .monotonic);
                sync.spawn(pingLoop, .{cl}) catch {
                    _ = cl.refs.fetchSub(1, .monotonic);
                };
            },
            .denied => {
                cl.setError("{s}", .{try r.str()});
                return error.Denied;
            },
            .members => {
                const n = try r.u16_();
                var list: std.ArrayList(Member) = .empty;
                errdefer list.deinit(gpa);
                for (0..n) |_| {
                    var m: Member = undefined;
                    m.id = try r.u32_();
                    const nm = try r.str();
                    copyInto(&m.name, &m.name_len, nm);
                    const flags = try r.u8_();
                    m.streaming = flags & proto.member_streaming != 0;
                    m.admin = flags & proto.member_admin != 0;
                    m.w = try r.u16_();
                    m.h = try r.u16_();
                    m.fps = try r.u8_();
                    const k = try r.u16_();
                    m.n_watching = 0;
                    for (0..k) |_| {
                        const id = try r.u32_();
                        if (m.n_watching < m.watching.len) {
                            m.watching[m.n_watching] = id;
                            m.n_watching += 1;
                        }
                    }
                    try list.append(gpa, m);
                }
                cl.mutex.lock();
                defer cl.mutex.unlock();
                cl.members.deinit(gpa);
                cl.members = list;
            },
            .chat => {
                var line: ChatLine = undefined;
                line.from = try r.u32_();
                copyInto(&line.name, &line.name_len, try r.str());
                line.text = try gpa.dupe(u8, try r.str());
                const t = sync.localTime();
                line.hour = t.h;
                line.minute = t.m;
                cl.mutex.lock();
                defer cl.mutex.unlock();
                if (cl.chat.items.len >= 500) {
                    gpa.free(cl.chat.items[0].text);
                    _ = cl.chat.orderedRemove(0);
                }
                try cl.chat.append(gpa, line);
                cl.chat_count += 1;
            },
            .frame => {
                const from = try r.u32_();
                cl.mutex.lock();
                const view: ?*View = for (cl.views.items) |v| {
                    if (v.owner == from) break v;
                } else null;
                cl.mutex.unlock();
                if (view) |v| v.enqueue(try gpa.dupe(u8, r.rest()));
            },
            .keyreq => cl.keyreq.store(true, .release),
            .pong => {
                const t = try r.u64_();
                const server_us = try r.u64_();
                cl.onPong(t, server_us);
            },
            else => {},
        }
    }

    pub fn sendChat(cl: *Client, text: []const u8) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.chat) catch return;
        b.str(text) catch return;
        cl.queue.pushOwned(b.finish() catch return);
    }

    pub fn sendWatch(cl: *Client, target: u32, on: bool) void {
        const m = proto.Msg.alloc(.watch, 5) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], target, .little);
        m.payload()[4] = @intFromBool(on);
        cl.queue.pushOwned(m);
    }

    pub fn kick(cl: *Client, target: u32) void {
        const m = proto.Msg.alloc(.kick, 4) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], target, .little);
        cl.queue.pushOwned(m);
    }

    pub fn findView(cl: *Client, owner: u32) ?*View {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.views.items) |v| if (v.owner == owner) return v;
        return null;
    }

    /// Começa a assistir alguém. Retorna a view (a UI fica com uma referência).
    pub fn watch(cl: *Client, owner: u32) !*View {
        if (cl.findView(owner)) |v| return v;
        const v = try gpa.create(View);
        v.* = .{ .owner = owner, .client = cl.retain() };
        sync.spawn(View.decodeLoop, .{v}) catch {
            cl.release();
            gpa.destroy(v);
            return error.ThreadFailed;
        };
        cl.mutex.lock();
        cl.views.append(gpa, v) catch {};
        cl.mutex.unlock();
        cl.sendWatch(owner, true);
        return v;
    }

    /// Para de assistir. A UI tem que apagar a textura antes.
    pub fn unwatch(cl: *Client, v: *View) void {
        cl.mutex.lock();
        if (std.mem.findScalar(*View, cl.views.items, v)) |i| _ = cl.views.orderedRemove(i);
        cl.mutex.unlock();
        cl.sendWatch(v.owner, false);
        v.shutdown();
        v.release();
    }
};
