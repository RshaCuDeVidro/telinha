//! Vídeo e som por UDP (o resto continua no TCP).
//!
//! Por quê: no TCP, um pacote perdido segura tudo o que vem atrás até ele ser
//! reenviado — inclusive a voz e o som, que não têm nada a ver com o quadro
//! perdido —, e se a perda é no fim de uma rajada o reenvio só sai depois de
//! ~200 ms. Aqui cada mensagem (quadro, pacote de som, de voz) vai em pedaços
//! de ~1,1 KB num datagrama cifrado; quem recebe remonta e, se faltar pedaço,
//! pede só aquele de volta (NACK). Quadros de uma transmissão saem em ordem
//! (o decoder precisa), mas cada transmissão anda sozinha, e som/voz não
//! esperam por ninguém (têm a própria ordem e o próprio buffer).
//!
//! Datagrama: u8 marca, u32 token (de quem é), u64 número do pacote (nonce),
//! e o resto cifrado com ChaCha20-Poly1305 (o cabeçalho entra como dado
//! associado). As chaves saem das do TCP (outro rótulo); pacote repetido ou
//! velho demais é jogado fora.
//!
//! Por dentro: u8 tipo +
//!   hello / hello_ok           (abre o caminho; o cliente começa)
//!   ping u64 t / pong u64 t    (mantém o NAT aberto e mede o RTT)
//!   data u32 canal, u32 id, u16 pedaço, u16 total, bytes
//!   nack u32 canal, u32 id, u16 n, n × u16 pedaço (n = 0xFFFF: a mensagem toda)
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const gpa = std.heap.c_allocator;

pub const magic: u8 = 0xA7;
pub const header_len = 1 + 4 + 8;
/// Bytes de mensagem por datagrama (cabe com folga em qualquer MTU, até em túnel/VPN).
pub const chunk = 1150;
const max_datagram = header_len + 1 + 12 + chunk + Aead.tag_length;
/// Mensagem maior que isso vai pelo TCP (um IDR 4K absurdo).
const max_frags = 4096;
/// Canal sem ordem (som, voz: cada um tem a própria sequência).
pub const unordered: u32 = 0xFFFF_FFFF;

const P = enum(u8) { hello = 1, hello_ok = 2, ping = 3, pong = 4, data = 5, nack = 6, _ };

/// Por onde sai o datagrama: socket conectado (cliente) ou endereço (servidor).
pub const Wire = struct {
    sock: net.Socket,
    to: ?*const net.UdpAddr = null,

    fn send(w: Wire, bytes: []const u8) bool {
        return net.udpSend(w.sock, w.to, bytes);
    }
};

/// Chave do UDP derivada da do TCP (mesma direção, outro rótulo).
pub fn deriveKey(tcp_key: [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    var h = Sha256.init(.{});
    h.update("telinha udp v1");
    h.update(&tcp_key);
    h.final(&out);
    return out;
}

/// Token do datagrama (os 4 bytes depois da marca), sem decifrar.
pub fn peekToken(pkt: []const u8) ?u32 {
    if (pkt.len < header_len + 1 + Aead.tag_length or pkt[0] != magic) return null;
    return std.mem.readInt(u32, pkt[1..5], .little);
}

pub const Event = enum { none, hello, hello_ok };

/// Mensagem remontada, pronta pra ir pro tratamento normal (tipo + payload).
pub const Deliver = *const fn (ctx: *anyopaque, typ: proto.Type, payload: []const u8) void;

pub const Stats = struct {
    sent_pkts: u64 = 0,
    resent_pkts: u64 = 0,
    nacks_sent: u64 = 0,
    lost_msgs: u64 = 0, // desistiu de esperar
    late_drops: u64 = 0,
};

const Sent = struct { channel: u32 = 0, id: u32 = 0, msg: ?*proto.Msg = null, at_ms: u64 = 0 };
const TxChan = struct { channel: u32, next: u32 };

const Partial = struct {
    channel: u32,
    id: u32,
    count: u16,
    got_n: u16 = 0,
    got: []u64,
    buf: []u8,
    last_len: usize = 0,
    first_ms: u64,
    last_ms: u64,
    nacked_ms: u64 = 0,
    nacks: u8 = 0,

    fn has(p: *const Partial, k: usize) bool {
        return p.got[k / 64] & (@as(u64, 1) << @intCast(k % 64)) != 0;
    }

    fn free(p: *Partial) void {
        gpa.free(p.got);
        gpa.free(p.buf);
        gpa.destroy(p);
    }
};

const Held = struct { id: u32, data: []u8 };

const RxChan = struct {
    channel: u32,
    next: u32,
    held: std.ArrayList(Held) = .empty, // completas, esperando a vez (ordem por id)
    gap_ms: u64 = 0, // desde quando falta a `next`
    asked_ms: u64 = 0, // último pedido da mensagem inteira
};

pub const Endpoint = struct {
    mutex: sync.Mutex = .{},
    token: u32,
    send_key: [32]u8,
    recv_key: [32]u8,
    pn: std.atomic.Value(u64) = .init(1),
    // anti-repetição: maior número visto + janela dos 128 anteriores
    max_pn: u64 = 0,
    window: u128 = 0,
    // envio
    tx: std.ArrayList(TxChan) = .empty,
    sent: [1024]Sent = [_]Sent{.{}} ** 1024,
    sent_head: usize = 0,
    pace_tokens: f64 = 128 * 1024,
    pace_last_us: u64 = 0,
    rate_avg: f64 = 0, // bytes/s enviados (média ~1 s), pra cadenciar com folga
    rate_last_us: u64 = 0,
    // recepção
    partials: std.ArrayList(*Partial) = .empty,
    rx: std.ArrayList(RxChan) = .empty,
    done_unordered: [256]u32 = [_]u32{0} ** 256, // ids sem ordem já entregues (repetição)
    done_head: usize = 0,
    rtt_us: std.atomic.Value(u64) = .init(40_000),
    last_rx_ms: std.atomic.Value(u64) = .init(0),
    stats: Stats = .{},
    drop_pct: u32 = 0, // teste: joga fora essa % do que manda (TELINHA_UDP_PERDA)
    rng: std.Random.DefaultPrng,

    pub fn create(token: u32, tcp_send_key: [32]u8, tcp_recv_key: [32]u8) !*Endpoint {
        const ep = try gpa.create(Endpoint);
        var seed: u64 = undefined;
        sync.osRandom(std.mem.asBytes(&seed));
        ep.* = .{ .token = token, .send_key = deriveKey(tcp_send_key), .recv_key = deriveKey(tcp_recv_key), .rng = .init(seed) };
        if (std.c.getenv("TELINHA_UDP_PERDA")) |v| ep.drop_pct = std.fmt.parseInt(u32, std.mem.span(v), 10) catch 0;
        return ep;
    }

    pub fn destroy(ep: *Endpoint) void {
        for (&ep.sent) |*s| if (s.msg) |m| m.release();
        for (ep.partials.items) |p| p.free();
        ep.partials.deinit(gpa);
        for (ep.rx.items) |*ch| {
            for (ch.held.items) |h| gpa.free(h.data);
            ch.held.deinit(gpa);
        }
        ep.rx.deinit(gpa);
        ep.tx.deinit(gpa);
        gpa.destroy(ep);
    }

    /// Tem trabalho com prazo (pedaço faltando, mensagem esperando a vez)?
    /// Sem isso, ninguém precisa acordar a cada 10 ms.
    pub fn busy(ep: *Endpoint) bool {
        ep.mutex.lock();
        defer ep.mutex.unlock();
        if (ep.partials.items.len > 0) return true;
        for (ep.rx.items) |*ch| if (ch.held.items.len > 0) return true;
        return false;
    }

    pub fn rttMs(ep: *Endpoint) u64 {
        return ep.rtt_us.load(.monotonic) / 1000;
    }

    // ---------------------------------------------------------------- cifra

    fn seal(ep: *Endpoint, wire: Wire, inner: []const u8) void {
        var buf: [max_datagram + 16]u8 = undefined;
        const pn = ep.pn.fetchAdd(1, .monotonic);
        buf[0] = magic;
        std.mem.writeInt(u32, buf[1..5], ep.token, .little);
        std.mem.writeInt(u64, buf[5..13], pn, .little);
        const n = inner.len;
        Aead.encrypt(buf[header_len..][0..n], buf[header_len + n ..][0..Aead.tag_length], inner, buf[0..header_len], nonce(pn), ep.send_key);
        if (ep.drop_pct > 0 and ep.rng.random().uintLessThan(u32, 100) < ep.drop_pct) return; // perda de mentira (testes)
        _ = wire.send(buf[0 .. header_len + n + Aead.tag_length]);
    }

    fn nonce(pn: u64) [Aead.nonce_length]u8 {
        var n = [_]u8{0xFF} ** Aead.nonce_length;
        std.mem.writeInt(u64, n[0..8], pn, .little);
        return n;
    }

    /// Decifra e confere repetição. Chamado com o mutex travado.
    fn open(ep: *Endpoint, pkt: []const u8, out: []u8) ?[]u8 {
        if (pkt.len < header_len + 1 + Aead.tag_length or pkt[0] != magic) return null;
        const pn = std.mem.readInt(u64, pkt[5..13], .little);
        // repetido ou velho demais pra janela
        if (pn + 128 <= ep.max_pn) return null;
        if (pn <= ep.max_pn and ep.window & (@as(u128, 1) << @intCast(ep.max_pn - pn)) != 0) return null;
        const n = pkt.len - header_len - Aead.tag_length;
        if (n > out.len) return null;
        Aead.decrypt(out[0..n], pkt[header_len..][0..n], pkt[pkt.len - Aead.tag_length ..][0..Aead.tag_length].*, pkt[0..header_len], nonce(pn), ep.recv_key) catch return null;
        if (pn > ep.max_pn) {
            const shift = pn - ep.max_pn;
            ep.window = if (shift >= 128) 0 else ep.window << @intCast(shift);
            ep.window |= 1;
            ep.max_pn = pn;
        } else ep.window |= @as(u128, 1) << @intCast(ep.max_pn - pn);
        return out[0..n];
    }

    // ---------------------------------------------------------------- envio

    pub fn sendHello(ep: *Endpoint, wire: Wire) void {
        ep.seal(wire, &.{@intFromEnum(P.hello)});
    }

    pub fn sendPing(ep: *Endpoint, wire: Wire) void {
        var b: [9]u8 = undefined;
        b[0] = @intFromEnum(P.ping);
        std.mem.writeInt(u64, b[1..9], sync.nowUs(), .little);
        ep.seal(wire, &b);
    }

    /// Manda uma mensagem (tipo + payload, como no TCP) em pedaços, no ritmo.
    /// false = grande demais pro UDP (quem chama manda pelo TCP).
    pub fn sendMsg(ep: *Endpoint, wire: Wire, m: *proto.Msg, channel: u32) bool {
        const plain = m.data[4..];
        const count = @max(1, (plain.len + chunk - 1) / chunk);
        if (count > max_frags) return false;
        ep.mutex.lock();
        const id = ep.nextId(channel);
        // guarda pra reenviar se alguém pedir
        const slot = &ep.sent[ep.sent_head];
        if (slot.msg) |old| old.release();
        slot.* = .{ .channel = channel, .id = id, .msg = m.retain(), .at_ms = sync.nowMs() };
        ep.sent_head = (ep.sent_head + 1) % ep.sent.len;
        ep.mutex.unlock();
        for (0..count) |k| {
            ep.pace(chunk + 64);
            ep.sendFrag(wire, channel, id, plain, k, count);
        }
        return true;
    }

    fn nextId(ep: *Endpoint, channel: u32) u32 {
        for (ep.tx.items) |*t| {
            if (t.channel == channel) {
                t.next +%= 1;
                return t.next;
            }
        }
        ep.tx.append(gpa, .{ .channel = channel, .next = 1 }) catch {};
        return 1;
    }

    fn sendFrag(ep: *Endpoint, wire: Wire, channel: u32, id: u32, plain: []const u8, k: usize, count: usize) void {
        var inner: [1 + 12 + chunk]u8 = undefined;
        inner[0] = @intFromEnum(P.data);
        std.mem.writeInt(u32, inner[1..5], channel, .little);
        std.mem.writeInt(u32, inner[5..9], id, .little);
        std.mem.writeInt(u16, inner[9..11], @intCast(k), .little);
        std.mem.writeInt(u16, inner[11..13], @intCast(count), .little);
        const from = k * chunk;
        const to = @min(plain.len, from + chunk);
        @memcpy(inner[13..][0 .. to - from], plain[from..to]);
        ep.seal(wire, inner[0 .. 13 + to - from]);
        ep.stats.sent_pkts += 1;
    }

    /// Cadência: uma rajada de ~128 KB passa direto; além disso, no máximo
    /// 4x a taxa média recente (mín. 12 Mbit/s). Um IDR grande não chega
    /// todo de uma vez no roteador (que jogaria fora o que não coube).
    fn pace(ep: *Endpoint, bytes: usize) void {
        const now = sync.nowUs();
        // bytes enviados no último ~1 s (média que esquece aos poucos) ≈ bytes/s
        if (ep.rate_last_us != 0) {
            const dt = @as(f64, @floatFromInt(now -| ep.rate_last_us)) / 1e6;
            ep.rate_avg *= @max(0.0, 1.0 - dt);
        }
        ep.rate_last_us = now;
        ep.rate_avg += @floatFromInt(bytes);
        const rate = @max(1.5e6, ep.rate_avg * 4); // bytes/s
        const burst = 128.0 * 1024;
        if (ep.pace_last_us != 0) {
            const dt = @as(f64, @floatFromInt(now -| ep.pace_last_us)) / 1e6;
            ep.pace_tokens = @min(burst, ep.pace_tokens + dt * rate);
        }
        ep.pace_last_us = now;
        const need: f64 = @floatFromInt(bytes);
        if (ep.pace_tokens < need) {
            const wait_us: u64 = @intFromFloat((need - ep.pace_tokens) / rate * 1e6);
            if (wait_us >= 1000) sync.sleepMs(@intCast(wait_us / 1000));
            const now2 = sync.nowUs();
            ep.pace_tokens += @as(f64, @floatFromInt(now2 -| now)) / 1e6 * rate;
            ep.pace_last_us = now2;
        }
        ep.pace_tokens -= need;
    }

    fn resend(ep: *Endpoint, wire: Wire, channel: u32, id: u32, frags: []const u16, all: bool) void {
        ep.mutex.lock();
        var msg: ?*proto.Msg = null;
        for (&ep.sent) |*s| {
            if (s.msg != null and s.channel == channel and s.id == id) {
                msg = s.msg.?.retain();
                break;
            }
        }
        ep.mutex.unlock();
        const m = msg orelse return; // velha demais: quem pediu vai desistir
        defer m.release();
        const plain = m.data[4..];
        const count = @max(1, (plain.len + chunk - 1) / chunk);
        if (all) {
            for (0..count) |k| ep.sendFrag(wire, channel, id, plain, k, count);
            ep.stats.resent_pkts += count;
        } else for (frags) |k| {
            if (k >= count) continue;
            ep.sendFrag(wire, channel, id, plain, k, count);
            ep.stats.resent_pkts += 1;
        }
    }

    // ------------------------------------------------------------ recepção

    /// Um datagrama que chegou (o token já bateu com esse ponto).
    pub fn handle(ep: *Endpoint, wire: Wire, pkt: []const u8, deliver: Deliver, ctx: *anyopaque) Event {
        var buf: [max_datagram]u8 = undefined;
        var ready: std.ArrayList(Ready) = .empty;
        defer ready.deinit(gpa);
        var ev: Event = .none;
        var nack: ?struct { channel: u32, id: u32, frags: [600]u16, n: usize, all: bool } = null;
        {
            ep.mutex.lock();
            defer ep.mutex.unlock();
            const inner = ep.open(pkt, &buf) orelse return .none;
            ep.last_rx_ms.store(sync.nowMs(), .monotonic);
            const body = inner[1..];
            switch (@as(P, @enumFromInt(inner[0]))) {
                .hello => ev = .hello,
                .hello_ok => ev = .hello_ok,
                .ping => if (body.len >= 8) {
                    var b: [9]u8 = undefined;
                    b[0] = @intFromEnum(P.pong);
                    @memcpy(b[1..9], body[0..8]);
                    ep.mutex.unlock();
                    ep.seal(wire, &b);
                    ep.mutex.lock();
                },
                .pong => if (body.len >= 8) {
                    const rtt = sync.nowUs() -| std.mem.readInt(u64, body[0..8], .little);
                    const old = ep.rtt_us.load(.monotonic);
                    ep.rtt_us.store((old * 7 + rtt) / 8, .monotonic);
                },
                .data => if (body.len >= 12) ep.onData(body, &ready),
                .nack => if (body.len >= 10) {
                    const n = std.mem.readInt(u16, body[8..10], .little);
                    var x: @TypeOf(nack.?) = .{ .channel = std.mem.readInt(u32, body[0..4], .little), .id = std.mem.readInt(u32, body[4..8], .little), .frags = undefined, .n = 0, .all = n == 0xFFFF };
                    if (!x.all) {
                        const have = @min(n, (body.len - 10) / 2, x.frags.len);
                        for (0..have) |i| x.frags[i] = std.mem.readInt(u16, body[10 + i * 2 ..][0..2], .little);
                        x.n = have;
                    }
                    nack = x;
                },
                _ => {},
            }
        }
        if (ev == .hello) ep.seal(wire, &.{@intFromEnum(P.hello_ok)});
        if (nack) |x| ep.resend(wire, x.channel, x.id, x.frags[0..x.n], x.all);
        for (ready.items) |r| {
            if (r.data.len > 0) deliver(ctx, @enumFromInt(r.data[0]), r.data[1..]);
            gpa.free(r.data);
        }
        return ev;
    }

    const Ready = struct { data: []u8 };

    /// Pedaço de mensagem. Mutex travado.
    fn onData(ep: *Endpoint, body: []const u8, ready: *std.ArrayList(Ready)) void {
        const channel = std.mem.readInt(u32, body[0..4], .little);
        const id = std.mem.readInt(u32, body[4..8], .little);
        const k = std.mem.readInt(u16, body[8..10], .little);
        const count = std.mem.readInt(u16, body[10..12], .little);
        const bytes = body[12..];
        if (count == 0 or count > max_frags or k >= count or bytes.len == 0 or bytes.len > chunk) return;
        if (k + 1 < count and bytes.len != chunk) return;
        if (ep.alreadyDone(channel, id)) {
            ep.stats.late_drops += 1;
            return;
        }
        const now = sync.nowMs();
        if (count == 1) {
            const copy = gpa.dupe(u8, bytes) catch return;
            ep.complete(channel, id, copy, ready, now);
            return;
        }
        const p = ep.findPartial(channel, id) orelse blk: {
            if (ep.partials.items.len >= 64) return; // lixo demais pendurado
            const np = gpa.create(Partial) catch return;
            np.* = .{ .channel = channel, .id = id, .count = count, .got = gpa.alloc(u64, (count + 63) / 64) catch {
                gpa.destroy(np);
                return;
            }, .buf = gpa.alloc(u8, @as(usize, count) * chunk) catch {
                gpa.destroy(np);
                return;
            }, .first_ms = now, .last_ms = now };
            @memset(np.got, 0);
            ep.partials.append(gpa, np) catch {
                np.free();
                return;
            };
            break :blk np;
        };
        if (p.count != count or p.has(k)) return;
        p.got[k / 64] |= @as(u64, 1) << @intCast(k % 64);
        p.got_n += 1;
        p.last_ms = now;
        @memcpy(p.buf[@as(usize, k) * chunk ..][0..bytes.len], bytes);
        if (k + 1 == count) p.last_len = bytes.len;
        if (p.got_n == p.count) {
            const len = (@as(usize, count) - 1) * chunk + p.last_len;
            const data = gpa.dupe(u8, p.buf[0..len]) catch return;
            ep.removePartial(p);
            ep.complete(channel, id, data, ready, now);
        }
    }

    fn findPartial(ep: *Endpoint, channel: u32, id: u32) ?*Partial {
        for (ep.partials.items) |p| if (p.channel == channel and p.id == id) return p;
        return null;
    }

    fn removePartial(ep: *Endpoint, p: *Partial) void {
        for (ep.partials.items, 0..) |x, i| {
            if (x == p) {
                _ = ep.partials.swapRemove(i);
                break;
            }
        }
        p.free();
    }

    fn rxChan(ep: *Endpoint, channel: u32) ?*RxChan {
        for (ep.rx.items) |*c| if (c.channel == channel) return c;
        // os ids de cada canal começam em 1 do lado de quem manda
        ep.rx.append(gpa, .{ .channel = channel, .next = 1 }) catch return null;
        return &ep.rx.items[ep.rx.items.len - 1];
    }

    fn alreadyDone(ep: *Endpoint, channel: u32, id: u32) bool {
        if (channel == unordered) {
            for (ep.done_unordered) |d| if (d == id) return true;
            return false;
        }
        for (ep.rx.items) |*c| if (c.channel == channel) return idBefore(id, c.next);
        return false;
    }

    /// Mensagem inteira: sem ordem vai direto; com ordem, espera a vez.
    fn complete(ep: *Endpoint, channel: u32, id: u32, data: []u8, ready: *std.ArrayList(Ready), now: u64) void {
        if (channel == unordered) {
            ep.done_unordered[ep.done_head] = id;
            ep.done_head = (ep.done_head + 1) % ep.done_unordered.len;
            ready.append(gpa, .{ .data = data }) catch gpa.free(data);
            return;
        }
        const ch = ep.rxChan(channel) orelse {
            gpa.free(data);
            return;
        };
        if (id == ch.next) {
            ready.append(gpa, .{ .data = data }) catch gpa.free(data);
            ch.next +%= 1;
            ep.flushHeld(ch, ready, now);
            return;
        }
        if (idBefore(id, ch.next)) {
            gpa.free(data);
            return;
        }
        // chegou adiantada: guarda em ordem
        var i: usize = ch.held.items.len;
        while (i > 0 and idBefore(id, ch.held.items[i - 1].id)) i -= 1;
        if (i > 0 and ch.held.items[i - 1].id == id) {
            gpa.free(data);
            return;
        }
        ch.held.insert(gpa, i, .{ .id = id, .data = data }) catch {
            gpa.free(data);
            return;
        };
        if (ch.gap_ms == 0) ch.gap_ms = now;
    }

    fn flushHeld(ep: *Endpoint, ch: *RxChan, ready: *std.ArrayList(Ready), now: u64) void {
        _ = ep;
        while (ch.held.items.len > 0 and ch.held.items[0].id == ch.next) {
            const h = ch.held.orderedRemove(0);
            ready.append(gpa, .{ .data = h.data }) catch gpa.free(h.data);
            ch.next +%= 1;
        }
        ch.gap_ms = if (ch.held.items.len > 0) now else 0;
        ch.asked_ms = 0;
    }

    /// Relógio (a cada ~10 ms): pede pedaço que falta, desiste do que demorou
    /// demais e libera o que estava esperando atrás.
    pub fn tick(ep: *Endpoint, wire: Wire, deliver: Deliver, ctx: *anyopaque) void {
        const now = sync.nowMs();
        const rtt = @max(2, ep.rttMs());
        const nack_every = @max(20, rtt + rtt / 4);
        const give_up = std.math.clamp(rtt * 4, 150, 400);
        var ready: std.ArrayList(Ready) = .empty;
        defer ready.deinit(gpa);
        const Nack = struct { channel: u32, id: u32, frags: [500]u16 = undefined, n: usize = 0, all: bool = false };
        var nacks: std.ArrayList(Nack) = .empty;
        defer nacks.deinit(gpa);
        {
            ep.mutex.lock();
            defer ep.mutex.unlock();
            // pedaços faltando
            var i: usize = ep.partials.items.len;
            while (i > 0) {
                i -= 1;
                const p = ep.partials.items[i];
                // desiste quando para de chegar pedaço (ou demorou demais no total)
                if (now - p.last_ms > give_up or now - p.first_ms > 1000) {
                    ep.stats.lost_msgs += 1;
                    _ = ep.partials.swapRemove(i);
                    p.free();
                    continue;
                }
                // espera um pouco (pode estar só fora de ordem) e não repete cedo demais
                if (now - p.last_ms < @max(5, rtt / 4) or now - p.nacked_ms < nack_every or p.nacks >= 6) continue;
                var nk: Nack = .{ .channel = p.channel, .id = p.id };
                for (0..p.count) |k| {
                    if (p.has(k)) continue;
                    if (nk.n == nk.frags.len) break;
                    nk.frags[nk.n] = @intCast(k);
                    nk.n += 1;
                }
                p.nacked_ms = now;
                p.nacks += 1;
                nacks.append(gpa, nk) catch {};
            }
            // mensagens inteiras faltando (nem um pedaço chegou) e desistência
            for (ep.rx.items) |*ch| {
                if (ch.held.items.len == 0) continue;
                const waiting = now - ch.gap_ms;
                // a que falta ainda está chegando (pedaços sendo reenviados): espera ela
                if (ep.findPartial(ch.channel, ch.next) != null) continue;
                if (waiting > give_up) {
                    // pula o buraco: entrega o que estava esperando
                    var lost = ch.held.items[0].id -% ch.next;
                    while (lost > 0) : (lost -= 1) ep.stats.lost_msgs += 1;
                    // descarta pedaços das que ficaram pra trás
                    var j: usize = ep.partials.items.len;
                    while (j > 0) {
                        j -= 1;
                        const p = ep.partials.items[j];
                        if (p.channel == ch.channel and idBefore(p.id, ch.held.items[0].id)) {
                            _ = ep.partials.swapRemove(j);
                            p.free();
                        }
                    }
                    ch.next = ch.held.items[0].id;
                    ep.flushHeld(ch, &ready, now);
                    continue;
                }
                if (waiting >= @max(10, rtt / 2) and now - ch.asked_ms >= nack_every) {
                    ch.asked_ms = now;
                    var id = ch.next;
                    var asked: usize = 0;
                    while (idBefore(id, ch.held.items[0].id) and asked < 8) : ({
                        id +%= 1;
                        asked += 1;
                    }) {
                        if (ep.findPartial(ch.channel, id) != null) continue; // essa já pede pedaço por pedaço
                        nacks.append(gpa, .{ .channel = ch.channel, .id = id, .all = true }) catch {};
                    }
                }
            }
            // o que já foi enviado há mais de 1,5 s não vai mais ser pedido
            for (&ep.sent) |*s| {
                if (s.msg != null and now - s.at_ms > 1500) {
                    s.msg.?.release();
                    s.msg = null;
                }
            }
        }
        for (nacks.items) |nk| {
            var b: [10 + 1000]u8 = undefined;
            b[0] = @intFromEnum(P.nack);
            std.mem.writeInt(u32, b[1..5], nk.channel, .little);
            std.mem.writeInt(u32, b[5..9], nk.id, .little);
            std.mem.writeInt(u16, b[9..11], if (nk.all) 0xFFFF else @intCast(nk.n), .little);
            for (nk.frags[0..nk.n], 0..) |f, k| std.mem.writeInt(u16, b[11 + k * 2 ..][0..2], f, .little);
            ep.seal(wire, b[0 .. 11 + nk.n * 2]);
            ep.stats.nacks_sent += 1;
        }
        for (ready.items) |r| {
            if (r.data.len > 0) deliver(ctx, @enumFromInt(r.data[0]), r.data[1..]);
            gpa.free(r.data);
        }
    }
};

/// O caminho UDP de uma conexão, do jeito que a escritora (proto.SendQueue)
/// usa: se estiver de pé, quadro/som/voz vão por aqui; senão, pelo TCP.
pub const Link = struct {
    ep: *Endpoint,
    sock: net.Socket,
    server: bool, // somos o servidor (manda pro endereço que o cliente usou)
    addr_mutex: sync.Mutex = .{},
    addr: net.UdpAddr = .{},
    active: std.atomic.Value(bool) = .init(false),

    pub fn create(token: u32, tcp_send_key: [32]u8, tcp_recv_key: [32]u8, sock: net.Socket, server: bool) !*Link {
        const l = try gpa.create(Link);
        errdefer gpa.destroy(l);
        l.* = .{ .ep = try Endpoint.create(token, tcp_send_key, tcp_recv_key), .sock = sock, .server = server };
        return l;
    }

    pub fn destroy(l: *Link) void {
        l.ep.destroy();
        gpa.destroy(l);
    }

    pub fn isActive(l: *Link) bool {
        return l.active.load(.acquire);
    }

    /// Endereço do outro lado (servidor: de onde o cliente falou por último).
    pub fn setAddr(l: *Link, a: *const net.UdpAddr) void {
        l.addr_mutex.lock();
        defer l.addr_mutex.unlock();
        l.addr = a.*;
    }

    /// Cópia do caminho pra mandar (o endereço pode mudar: NAT).
    pub fn wire(l: *Link, addr_copy: *net.UdpAddr) Wire {
        if (!l.server) return .{ .sock = l.sock };
        l.addr_mutex.lock();
        addr_copy.* = l.addr;
        l.addr_mutex.unlock();
        return .{ .sock = l.sock, .to = addr_copy };
    }

    /// true = foi pelo UDP; false = quem chama manda pelo TCP.
    pub fn trySend(l: *Link, m: *proto.Msg) bool {
        if (!l.isActive()) return false;
        const channel = channelOf(m, l.server) orelse return false;
        var a: net.UdpAddr = .{};
        return l.ep.sendMsg(l.wire(&a), m, channel);
    }
};

/// a < b, com volta (os ids dão a volta em 2^32).
fn idBefore(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// Canal de uma mensagem: quadros andam em ordem por transmissão; som e voz sem ordem.
/// `server`: quem manda é o servidor (o quadro já leva o stream na frente).
pub fn channelOf(m: *const proto.Msg, server: bool) ?u32 {
    return switch (m.typ) {
        .frame => if (server) m.from else blk: {
            // cliente → servidor: a transmissão é a tela ou a câmera (bit nas flags)
            const flags = m.data[5 + 4];
            break :blk if (flags & proto.frame_camera != 0) 0x8000_0001 else 0x8000_0000;
        },
        .audio, .voice => unordered,
        else => null, // o resto vai pelo TCP
    };
}

// ---------------------------------------------------------------------------
// Testes: dois pontos conversando por um par de sockets UDP locais

const TestSide = struct {
    got: std.ArrayList([]u8) = .empty,
    fn deliver(ctx: *anyopaque, typ: proto.Type, payload: []const u8) void {
        const t: *TestSide = @ptrCast(@alignCast(ctx));
        var copy = gpa.alloc(u8, 1 + payload.len) catch return;
        copy[0] = @intFromEnum(typ);
        @memcpy(copy[1..], payload);
        t.got.append(gpa, copy) catch gpa.free(copy);
    }
};

fn testPair(drop_pct: u32) !struct { a: *Endpoint, b: *Endpoint, sa: net.Socket, sb: net.Socket } {
    net.init();
    const ka = [_]u8{1} ** 32;
    const kb = [_]u8{2} ** 32;
    const a = try Endpoint.create(7, ka, kb);
    const b = try Endpoint.create(7, kb, ka);
    a.drop_pct = drop_pct;
    b.drop_pct = drop_pct;
    // máquina carregada (testes em paralelo) não pode parecer rede ruim:
    // RTT "alto" dá folga pros prazos de desistência
    a.rtt_us.store(100_000, .monotonic);
    b.rtt_us.store(100_000, .monotonic);
    // dois sockets conectados um no outro (porta aleatória)
    var port: u16 = 0;
    var sa: net.Socket = undefined;
    var sb: net.Socket = undefined;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        var rb: [2]u8 = undefined;
        sync.osRandom(&rb);
        port = 20000 + @as(u16, std.mem.readInt(u16, &rb, .little) % 30000);
        sa = net.udpBindLocal(port) catch continue;
        sb = net.udpBindLocal(port + 1) catch {
            net.close(sa);
            continue;
        };
        break;
    }
    try std.testing.expect(tries < 50);
    return .{ .a = a, .b = b, .sa = sa, .sb = sb };
}

fn localAddr(port: u16) net.UdpAddr {
    var a: net.UdpAddr = .{};
    const st = std.mem.asBytes(&a.st);
    // sockaddr_in: família, porta (big endian), 127.0.0.1
    std.mem.writeInt(u16, st[0..2], 2, .little);
    std.mem.writeInt(u16, st[2..4], port, .big);
    st[4] = 127;
    st[5] = 0;
    st[6] = 0;
    st[7] = 1;
    a.len = 16;
    return a;
}

test "udp: quadros grandes chegam inteiros e em ordem, mesmo perdendo 10% dos pacotes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var pr = try testPair(10);
    defer {
        pr.a.destroy();
        pr.b.destroy();
        net.close(pr.sa);
        net.close(pr.sb);
    }
    const pa = net.localPortOf(pr.sa);
    const pb = net.localPortOf(pr.sb);
    const addr_b = localAddr(pb);
    const addr_a = localAddr(pa);
    const wa: Wire = .{ .sock = pr.sa, .to = &addr_b };
    const wb: Wire = .{ .sock = pr.sb, .to = &addr_a };
    net.setRecvTimeout(pr.sa, 5);
    net.setRecvTimeout(pr.sb, 5);
    var side: TestSide = .{};
    defer {
        for (side.got.items) |g| gpa.free(g);
        side.got.deinit(gpa);
    }
    var dummy: TestSide = .{};
    const n_msgs = 40;
    var sizes: [n_msgs]usize = undefined;
    for (0..n_msgs) |i| {
        sizes[i] = if (i % 10 == 0) 120_000 else 3_000 + i * 97;
        const m = try proto.Msg.alloc(.frame, sizes[i]);
        defer m.release();
        m.from = 0x42;
        for (m.payload(), 0..) |*x, j| x.* = @truncate(i * 31 + j);
        try std.testing.expect(pr.a.sendMsg(wa, m, 0x42));
        // os dois lados processam o que chegou (pedidos de reenvio e pedaços)
        pump(pr.a, pr.b, pr.sa, pr.sb, wa, wb, &side, &dummy, 2);
    }
    // numa transmissão o próximo quadro sempre vem (é ele que revela a
    // perda de uma mensagem inteira): manda mais alguns pequenos no fim
    for (0..4) |_| {
        const m = try proto.Msg.alloc(.frame, 100);
        defer m.release();
        m.from = 0x42;
        @memset(m.payload(), 0);
        try std.testing.expect(pr.a.sendMsg(wa, m, 0x42));
        pump(pr.a, pr.b, pr.sa, pr.sb, wa, wb, &side, &dummy, 2);
    }
    var waited: usize = 0;
    while (side.got.items.len < n_msgs and waited < 300) : (waited += 1) pump(pr.a, pr.b, pr.sa, pr.sb, wa, wb, &side, &dummy, 1);
    try std.testing.expect(side.got.items.len >= n_msgs);
    for (side.got.items[0..n_msgs], 0..) |g, i| {
        try std.testing.expectEqual(sizes[i], g.len - 1);
        try std.testing.expectEqual(@as(u8, @truncate(i * 31 + 5)), g[1 + 5]);
    }
    try std.testing.expect(pr.b.stats.nacks_sent > 0);
    try std.testing.expect(pr.a.stats.resent_pkts > 0);
}

test "udp: sem ordem (voz) chega sem esperar; pacote repetido não entra duas vezes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var pr = try testPair(0);
    defer {
        pr.a.destroy();
        pr.b.destroy();
        net.close(pr.sa);
        net.close(pr.sb);
    }
    const addr_b = localAddr(net.localPortOf(pr.sb));
    const addr_a = localAddr(net.localPortOf(pr.sa));
    const wa: Wire = .{ .sock = pr.sa, .to = &addr_b };
    const wb: Wire = .{ .sock = pr.sb, .to = &addr_a };
    net.setRecvTimeout(pr.sa, 5);
    net.setRecvTimeout(pr.sb, 5);
    var side: TestSide = .{};
    defer {
        for (side.got.items) |g| gpa.free(g);
        side.got.deinit(gpa);
    }
    var dummy: TestSide = .{};
    const m = try proto.Msg.alloc(.voice, 60);
    defer m.release();
    @memset(m.payload(), 9);
    try std.testing.expect(pr.a.sendMsg(wa, m, unordered));
    pump(pr.a, pr.b, pr.sa, pr.sb, wa, wb, &side, &dummy, 3);
    try std.testing.expectEqual(@as(usize, 1), side.got.items.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(proto.Type.voice)), side.got.items[0][0]);
    // o mesmo pedaço de novo (reenvio atrasado): ignorado
    pr.a.resend(wa, unordered, 1, &.{}, true);
    pump(pr.a, pr.b, pr.sa, pr.sb, wa, wb, &side, &dummy, 3);
    try std.testing.expectEqual(@as(usize, 1), side.got.items.len);
    // token/chave errada: nem decifra
    const other = try Endpoint.create(7, [_]u8{3} ** 32, [_]u8{4} ** 32);
    defer other.destroy();
    try std.testing.expect(other.sendMsg(wa, m, unordered));
    pump(pr.a, pr.b, pr.sa, pr.sb, wa, wb, &side, &dummy, 3);
    try std.testing.expectEqual(@as(usize, 1), side.got.items.len);
}

fn pump(a: *Endpoint, b: *Endpoint, sa: net.Socket, sb: net.Socket, wa: Wire, wb: Wire, side: *TestSide, dummy: *TestSide, rounds: usize) void {
    var buf: [2048]u8 = undefined;
    for (0..rounds) |_| {
        while (net.udpRecvFrom(sb, &buf, null)) |n| _ = b.handle(wb, buf[0..n], TestSide.deliver, side);
        while (net.udpRecvFrom(sa, &buf, null)) |n| _ = a.handle(wa, buf[0..n], TestSide.deliver, dummy);
        b.tick(wb, TestSide.deliver, side);
        a.tick(wa, TestSide.deliver, dummy);
    }
}
