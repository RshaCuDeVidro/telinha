//! Protocolo da sala (versão 3). Ver docs/PROTOCOL.md.
//!
//! No fio: handshake em claro (crypto.zig) e depois mensagens
//!     u32 tamanho | ChaCha20-Poly1305( u8 tipo | payload ) | tag(16)
//! Inteiros little-endian, strings = u16 tamanho + bytes UTF-8.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const crypto = @import("crypto.zig");

pub const version: u16 = 3;
pub const max_msg = 32 * 1024 * 1024;
/// Marcador em claro no lugar do tamanho: "senha errada" (o servidor não
/// conseguiu decifrar a primeira mensagem).
pub const wrong_password_marker: u32 = 0xFFFF_FFFF;
pub const gpa = std.heap.c_allocator;

pub const Type = enum(u8) {
    hello = 1, // C→S str nome, str token_admin
    welcome = 2, // S→C u32 meu_id, str nome_da_sala, u8 sou_admin, u64 relógio_do_servidor_us
    denied = 3, // S→C str motivo
    members = 4, // S→C u16 n, n×{u32 id, str nome, u8 flags, u16 w, u16 h, u8 fps, u16 k, k×u32 assistindo}
    chat = 5, // C→S str texto | S→C u32 de (0 = sistema), str nome, str texto
    stream_start = 6, // C→S u16 w, u16 h, u8 fps
    stream_stop = 7, // C→S
    frame = 8, // C→S frame | S→C u32 de + frame
    watch = 9, // C→S u32 alvo, u8 ligado
    keyreq = 10, // S→C manda um quadro completo (IDR)
    ping = 11, // C→S u64 t
    pong = 12, // S→C u64 t, u64 relógio_do_servidor_us
    kick = 13, // C→S u32 alvo (só admin)
    _,
};

pub const member_streaming: u8 = 1;
pub const member_admin: u8 = 2;

/// Payload de frame: u32 seq, u8 flags, u64 hora_da_captura (relógio do
/// servidor, µs), u16 w, u16 h, bitstream H.264 (Annex B) até o fim.
pub const frame_key: u8 = 1;
pub const frame_header_len = 4 + 1 + 8 + 2 + 2;

/// Mensagem pronta pra enviar (em claro; a escritora cifra por conexão),
/// com contagem de referências: o mesmo frame vai pra vários espectadores.
pub const Msg = struct {
    refs: std.atomic.Value(u32),
    typ: Type,
    from: u32 = 0, // remetente de frames encaminhados
    flags: u8 = 0,
    data: []u8, // u32 (reservado) + tipo + payload

    pub fn payload(m: *Msg) []u8 {
        return m.data[5..];
    }
    pub fn retain(m: *Msg) *Msg {
        _ = m.refs.fetchAdd(1, .monotonic);
        return m;
    }
    pub fn release(m: *Msg) void {
        if (m.refs.fetchSub(1, .acq_rel) == 1) {
            gpa.free(m.data);
            gpa.destroy(m);
        }
    }
    /// Cria uma mensagem com payload não inicializado de `n` bytes.
    pub fn alloc(typ: Type, n: usize) !*Msg {
        const m = try gpa.create(Msg);
        errdefer gpa.destroy(m);
        m.* = .{ .refs = .init(1), .typ = typ, .data = try gpa.alloc(u8, 5 + n) };
        std.mem.writeInt(u32, m.data[0..4], @intCast(1 + n), .little);
        m.data[4] = @intFromEnum(typ);
        return m;
    }
};

/// Monta o payload de uma mensagem.
pub const Builder = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn begin(self: *Builder, typ: Type) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendNTimes(gpa, 0, 4);
        try self.buf.append(gpa, @intFromEnum(typ));
    }
    pub fn u8_(self: *Builder, v: u8) !void {
        try self.buf.append(gpa, v);
    }
    pub fn u16_(self: *Builder, v: u16) !void {
        try self.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }
    pub fn u32_(self: *Builder, v: u32) !void {
        try self.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }
    pub fn u64_(self: *Builder, v: u64) !void {
        try self.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
    }
    pub fn str(self: *Builder, s: []const u8) !void {
        const n: u16 = @intCast(@min(s.len, 4000));
        try self.u16_(n);
        try self.buf.appendSlice(gpa, s[0..n]);
    }
    pub fn bytes(self: *Builder, s: []const u8) !void {
        try self.buf.appendSlice(gpa, s);
    }
    /// Gera a mensagem (copia o buffer; o Builder pode ser reusado).
    pub fn finish(self: *Builder) !*Msg {
        const m = try Msg.alloc(@enumFromInt(self.buf.items[4]), self.buf.items.len - 5);
        @memcpy(m.data[5..], self.buf.items[5..]);
        return m;
    }
    pub fn deinit(self: *Builder) void {
        self.buf.deinit(gpa);
    }
};

pub fn simple(typ: Type) !*Msg {
    return Msg.alloc(typ, 0);
}

/// Lê campos de um payload.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.data.len - self.pos < n) return error.BadMessage;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }
    pub fn u8_(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    pub fn u16_(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
    pub fn u32_(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    pub fn u64_(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    pub fn str(self: *Reader) ![]const u8 {
        const n = try self.u16_();
        return self.take(n);
    }
    pub fn rest(self: *Reader) []const u8 {
        return self.data[self.pos..];
    }
};

/// Buffers de leitura reaproveitados por conexão.
pub const RecvBuf = struct {
    cipher: std.ArrayList(u8) = .empty,
    plain: std.ArrayList(u8) = .empty,

    pub fn deinit(rb: *RecvBuf) void {
        rb.cipher.deinit(gpa);
        rb.plain.deinit(gpa);
    }

    /// Não guarda buffers gigantes pra sempre (depois de um IDR enorme).
    fn trim(rb: *RecvBuf) void {
        if (rb.cipher.capacity > 4 * 1024 * 1024 and rb.cipher.items.len < 256 * 1024) rb.cipher.shrinkAndFree(gpa, rb.cipher.items.len);
        if (rb.plain.capacity > 4 * 1024 * 1024 and rb.plain.items.len < 256 * 1024) rb.plain.shrinkAndFree(gpa, rb.plain.items.len);
    }
};

/// Lê e decifra uma mensagem. Retorna o tipo; o payload fica em `rb.plain.items[1..]`.
pub fn recvMsg(s: net.Socket, ch: *crypto.Channel, rb: *RecvBuf) !Type {
    var hdr: [4]u8 = undefined;
    try net.recvAll(s, &hdr);
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len == wrong_password_marker) return error.WrongPassword;
    if (len < 1 + crypto.tag_len or len > max_msg) return error.BadMessage;
    try rb.cipher.resize(gpa, len);
    try net.recvAll(s, rb.cipher.items);
    try rb.plain.resize(gpa, len - crypto.tag_len);
    try ch.open(rb.cipher.items, rb.plain.items);
    rb.trim();
    return @enumFromInt(rb.plain.items[0]);
}

pub fn payloadOf(rb: *RecvBuf) []const u8 {
    return rb.plain.items[1..];
}

/// Fila de envio com uma thread escritora por conexão.
pub const SendQueue = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Cond = .{},
    items: std.ArrayList(*Msg) = .empty,
    head: usize = 0,
    bytes: usize = 0,
    closed: bool = false,
    sent_bytes: std.atomic.Value(u64) = .init(0),

    pub fn push(q: *SendQueue, m: *Msg) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.closed) return;
        q.items.append(gpa, m.retain()) catch {
            m.release();
            return;
        };
        q.bytes += m.data.len;
        q.cond.signal();
    }

    /// Enfileira e solta a referência do chamador.
    pub fn pushOwned(q: *SendQueue, m: *Msg) void {
        q.push(m);
        m.release();
    }

    pub fn queuedBytes(q: *SendQueue) usize {
        q.mutex.lock();
        defer q.mutex.unlock();
        return q.bytes;
    }

    /// Joga fora frames ainda não enviados (de um remetente, ou todos se from == null).
    pub fn dropFrames(q: *SendQueue, from: ?u32) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        var w: usize = q.head;
        for (q.items.items[q.head..]) |m| {
            if (m.typ == .frame and (from == null or m.from == from.?)) {
                q.bytes -= m.data.len;
                m.release();
            } else {
                q.items.items[w] = m;
                w += 1;
            }
        }
        q.items.shrinkRetainingCapacity(w);
    }

    fn pop(q: *SendQueue) ?*Msg {
        q.mutex.lock();
        defer q.mutex.unlock();
        while (q.head == q.items.items.len and !q.closed) q.cond.wait(&q.mutex);
        if (q.closed) return null;
        const m = q.items.items[q.head];
        q.head += 1;
        if (q.head == q.items.items.len) {
            q.head = 0;
            q.items.clearRetainingCapacity();
        }
        q.bytes -= m.data.len;
        return m;
    }

    pub fn close(q: *SendQueue) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        q.closed = true;
        for (q.items.items[q.head..]) |m| m.release();
        q.items.clearRetainingCapacity();
        q.head = 0;
        q.bytes = 0;
        q.cond.broadcast();
    }

    pub fn deinit(q: *SendQueue) void {
        q.close();
        q.items.deinit(gpa);
    }

    /// Loop da thread escritora: cifra e envia. Sai quando a fila fecha ou o envio falha.
    pub fn writerLoop(q: *SendQueue, s: net.Socket, ch: *crypto.Channel) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        while (q.pop()) |m| {
            defer m.release();
            const plain = m.data[4..];
            out.resize(gpa, 4 + plain.len + crypto.tag_len) catch {
                net.shutdown(s);
                return;
            };
            std.mem.writeInt(u32, out.items[0..4], @intCast(plain.len + crypto.tag_len), .little);
            ch.seal(plain, out.items[4..]);
            net.sendAll(s, out.items) catch {
                net.shutdown(s);
                return;
            };
            _ = q.sent_bytes.fetchAdd(out.items.len, .monotonic);
            if (out.capacity > 4 * 1024 * 1024 and out.items.len < 256 * 1024) out.shrinkAndFree(gpa, out.items.len);
        }
    }
};
