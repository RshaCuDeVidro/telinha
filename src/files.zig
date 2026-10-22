//! Arquivos mandados na sala, do lado do servidor: quem manda sobe uma vez e
//! cada um baixa quando quiser (no ritmo dele). Ficam no disco, não na
//! memória (a VPS pequena tem 1 GB), cifrados com ChaCha20 e uma chave que só
//! existe na memória do servidor: reiniciou, o que sobrou no disco é lixo
//! ilegível (e é apagado ao subir). Expiram em 2 h; no máximo 2 GB no total (o
//! mais velho sai primeiro).
const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const proto = @import("proto.zig");
const gpa = std.heap.c_allocator;
const ChaCha = std.crypto.stream.chacha.ChaCha20IETF;
pub const cio = @cImport(@cInclude("stdio.h"));

pub const expire_ms: u64 = 2 * 3600 * 1000;
pub const stall_ms: u64 = 120 * 1000; // subida parada há 2 min: desiste
pub const budget: u64 = 2 * 1024 * 1024 * 1024;
const prefix = "telinha-arq-";

pub const Entry = struct {
    id: u32,
    name: [proto.file_name_max]u8 = undefined,
    name_len: usize = 0,
    size: u64,
    received: u64 = 0,
    from: u32, // id de quem subiu
    from_name: [48]u8 = undefined,
    from_name_len: usize = 0,
    to: u32 = 0, // privada: só `from` e `to` baixam
    chan: [proto.channel_name_max]u8 = undefined, // canal onde foi postado (quem está nele baixa)
    chan_len: usize = 0,
    reply_to: u32 = 0,
    complete: bool = false,
    last_ms: u64,
    nonce: [12]u8,
    path: [600]u8 = undefined,
    path_len: usize = 0,
    file: ?*cio.FILE = null, // aberto enquanto sobe; depois, pra ler
    mutex: sync.Mutex = .{},

    pub fn nameSlice(e: *const Entry) []const u8 {
        return e.name[0..e.name_len];
    }
    pub fn chanSlice(e: *const Entry) []const u8 {
        return e.chan[0..e.chan_len];
    }
    fn pathZ(e: *Entry) [:0]const u8 {
        e.path[e.path_len] = 0;
        return e.path[0..e.path_len :0];
    }
};

pub const Store = struct {
    dir: [480]u8 = undefined,
    dir_len: usize = 0,
    key: [32]u8 = undefined,
    items: std.ArrayList(*Entry) = .empty,
    total: u64 = 0,
    ok: bool = false,

    /// `dir`: onde guardar (criada se não existir; sobras de antes são apagadas).
    /// Sem pasta que dê pra escrever, a sala fica sem arquivos (ok = false).
    pub fn init(st: *Store, dir: []const u8) void {
        sync.osRandom(&st.key);
        if (dir.len == 0 or dir.len >= st.dir.len - 1) return;
        @memcpy(st.dir[0..dir.len], dir);
        st.dir_len = dir.len;
        st.dir[dir.len] = 0;
        makeDir(st.dir[0..dir.len :0]);
        wipeOld(st.dir[0..dir.len :0]);
        // dá pra escrever?
        var tb: [600]u8 = undefined;
        const t = std.fmt.bufPrintZ(&tb, "{s}{s}{s}teste", .{ dir, sep, prefix }) catch return;
        const f = openFile(t, "wb") orelse return;
        _ = cio.fclose(f);
        removeFile(t);
        st.ok = true;
    }

    pub fn deinit(st: *Store) void {
        for (st.items.items) |e| destroy(e);
        st.items.deinit(gpa);
        st.total = 0;
        // a pasta vazia também sai (a da sala do app é uma por processo; a do
        // servidor dedicado é criada de novo na próxima vez)
        if (st.dir_len > 0) removeDir(st.dir[0..st.dir_len :0]);
    }

    fn destroy(e: *Entry) void {
        if (e.file) |f| _ = cio.fclose(f);
        removeFile(e.pathZ());
        gpa.destroy(e);
    }

    pub fn find(st: *Store, id: u32) ?*Entry {
        for (st.items.items) |e| if (e.id == id) return e;
        return null;
    }

    /// Um arquivo novo pra subir. Abre espaço (os mais velhos saem) se precisar.
    pub fn create(st: *Store, name: []const u8, size: u64, from: u32, from_name: []const u8, to: u32, chan: []const u8, reply_to: u32) !*Entry {
        if (!st.ok) return error.NoStorage;
        if (size == 0 or size > proto.file_max) return error.TooBig;
        while (st.total + size > budget) {
            // o mais velho que já terminou (subindo não sai)
            var oldest: ?usize = null;
            for (st.items.items, 0..) |e, i| {
                if (e.complete and (oldest == null or e.last_ms < st.items.items[oldest.?].last_ms)) oldest = i;
            }
            const i = oldest orelse return error.Full;
            st.removeAt(i);
        }
        const e = try gpa.create(Entry);
        errdefer gpa.destroy(e);
        e.* = .{ .id = st.freshId(), .size = size, .from = from, .to = to, .reply_to = reply_to, .last_ms = sync.nowMs(), .nonce = undefined };
        sync.osRandom(&e.nonce);
        copy(&e.name, &e.name_len, name);
        copy(&e.from_name, &e.from_name_len, from_name);
        copy(&e.chan, &e.chan_len, chan);
        const p = try std.fmt.bufPrint(e.path[0 .. e.path.len - 1], "{s}{s}{s}{x:0>8}.bin", .{ st.dir[0..st.dir_len], sep, prefix, e.id });
        e.path_len = p.len;
        e.file = openFile(e.pathZ(), "wb") orelse return error.NoStorage;
        try st.items.append(gpa, e);
        st.total += size;
        return e;
    }

    /// id sorteado (ninguém adivinha o de um arquivo que não viu), nunca 0 nem repetido.
    fn freshId(st: *Store) u32 {
        while (true) {
            var b: [4]u8 = undefined;
            sync.osRandom(&b);
            const id = std.mem.readInt(u32, &b, .little);
            if (id != 0 and st.find(id) == null) return id;
        }
    }

    pub fn remove(st: *Store, id: u32) void {
        for (st.items.items, 0..) |e, i| if (e.id == id) return st.removeAt(i);
    }

    fn removeAt(st: *Store, i: usize) void {
        const e = st.items.swapRemove(i);
        st.total -|= e.size;
        destroy(e);
    }

    /// Expirados (2 h depois de completos) e subidas paradas. Devolve quantos saíram.
    pub fn expire(st: *Store, now_ms: u64) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < st.items.items.len) {
            const e = st.items.items[i];
            const limit = if (e.complete) expire_ms else stall_ms;
            if (now_ms -| e.last_ms > limit) {
                st.removeAt(i);
                n += 1;
            } else i += 1;
        }
        return n;
    }

    /// Pedaço que chegou (em ordem). Devolve até onde chegou.
    pub fn write(st: *Store, e: *Entry, offset: u64, bytes: []const u8) !u64 {
        e.mutex.lock();
        defer e.mutex.unlock();
        if (e.complete or offset != e.received or offset % 64 != 0 or offset + bytes.len > e.size) return error.BadChunk;
        const f = e.file orelse return error.BadChunk;
        var buf: [64 * 1024]u8 = undefined;
        if (bytes.len > buf.len) return error.BadChunk;
        ChaCha.xor(buf[0..bytes.len], bytes, @intCast(offset / 64), st.key, e.nonce);
        if (cio.fwrite(&buf, 1, bytes.len, f) != bytes.len) return error.NoStorage;
        e.received += bytes.len;
        e.last_ms = sync.nowMs();
        if (e.received == e.size) {
            _ = cio.fclose(f);
            e.file = null;
            e.complete = true;
        }
        return e.received;
    }

    /// Lê (e decifra) um pedaço de um arquivo completo. `offset` múltiplo de 64.
    pub fn read(st: *Store, e: *Entry, offset: u64, out: []u8) !usize {
        e.mutex.lock();
        defer e.mutex.unlock();
        if (!e.complete or offset % 64 != 0 or offset >= e.size) return error.BadChunk;
        if (e.file == null) e.file = openFile(e.pathZ(), "rb") orelse return error.NoStorage;
        const f = e.file.?;
        if (fseek64(f, offset) != 0) return error.NoStorage;
        const want: usize = @intCast(@min(out.len, e.size - offset));
        var buf: [64 * 1024]u8 = undefined;
        if (want > buf.len) return error.BadChunk;
        const got = cio.fread(&buf, 1, want, f);
        if (got != want) return error.NoStorage;
        ChaCha.xor(out[0..got], buf[0..got], @intCast(offset / 64), st.key, e.nonce);
        e.last_ms = @max(e.last_ms, sync.nowMs() -| expire_ms / 2); // baixando: não expira no meio
        return got;
    }
};

/// Nome que vai pro disco de quem baixa: sem pasta, sem caracteres que algum
/// sistema não aceita, sem ponto/espaço no fim, nunca vazio.
pub fn cleanName(raw: []const u8, out: []u8) []const u8 {
    var base = raw;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    var n = @min(base.len, out.len);
    // não corta um caractere UTF-8 no meio
    while (n > 0 and n < base.len and base[n] & 0xC0 == 0x80) n -= 1;
    for (base[0..n], 0..) |ch, i| {
        out[i] = if (ch < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", ch) != null) '_' else ch;
    }
    var s = std.mem.trimEnd(u8, out[0..n], ". ");
    s = std.mem.trimStart(u8, s, " ");
    if (s.len == 0 or std.mem.eql(u8, s, "..") or std.mem.eql(u8, s, ".")) return "arquivo";
    return s;
}

fn copy(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

const sep = if (builtin.os.tag == .windows) "\\" else "/";

// ------------------------------------------------- sistema de arquivos

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, attrs: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) c_int;
extern "c" fn _wfopen(path: [*:0]const u16, mode: [*:0]const u16) ?*cio.FILE;
extern "c" fn _fseeki64(f: *cio.FILE, off: i64, whence: c_int) c_int;
extern "c" fn fseeko(f: *cio.FILE, off: i64, whence: c_int) c_int;

fn wide(path: []const u8, out: *[1024:0]u16) bool {
    const n = std.unicode.utf8ToUtf16Le(out, path) catch return false;
    if (n >= out.len) return false;
    out[n] = 0;
    return true;
}

pub fn openFile(path: [:0]const u8, mode: [:0]const u8) ?*cio.FILE {
    if (builtin.os.tag == .windows) {
        var w: [1024:0]u16 = undefined;
        if (!wide(path, &w)) return null;
        var m: [8:0]u16 = undefined;
        for (mode, 0..) |ch, i| m[i] = ch;
        m[mode.len] = 0;
        return _wfopen(&w, &m);
    }
    return cio.fopen(path.ptr, mode.ptr);
}

fn fseek64(f: *cio.FILE, off: u64) c_int {
    if (builtin.os.tag == .windows) return _fseeki64(f, @intCast(off), cio.SEEK_SET);
    return fseeko(f, @intCast(off), cio.SEEK_SET);
}

pub fn makeDir(path: [:0]const u8) void {
    if (builtin.os.tag == .windows) {
        var w: [1024:0]u16 = undefined;
        if (wide(path, &w)) _ = CreateDirectoryW(&w, null);
    } else _ = mkdir(path.ptr, 0o700);
}

pub fn removeFile(path: [:0]const u8) void {
    if (builtin.os.tag == .windows) {
        var w: [1024:0]u16 = undefined;
        if (wide(path, &w)) _ = DeleteFileW(&w);
    } else _ = unlink(path.ptr);
}

/// Só sai se estiver vazia (outra coisa que alguém pôs lá fica).
fn removeDir(path: [:0]const u8) void {
    if (builtin.os.tag == .windows) {
        var w: [1024:0]u16 = undefined;
        if (wide(path, &w)) _ = RemoveDirectoryW(&w);
    } else _ = rmdir(path.ptr);
}

/// Apaga o que sobrou de outra vez (a chave daquela vez já não existe).
fn wipeOld(dir: [:0]const u8) void {
    if (builtin.os.tag == .windows) return; // pasta temporária própria: o sistema limpa
    const d = std.c.opendir(dir.ptr) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        var pb: [600]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pb, "{s}/{s}", .{ dir, name }) catch continue;
        _ = unlink(p.ptr);
    }
}

const testing = std.testing;

test "arquivos: sobe em ordem, cifrado no disco, lê de volta; expira; abre espaço" {
    var dir_buf: [300]u8 = undefined;
    const tmp = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/telinha-teste-arquivos-{d}", .{ tmp, std.c.getpid() });
    var st: Store = .{};
    st.init(dir);
    defer st.deinit();
    try testing.expect(st.ok);
    const data = "conteúdo do arquivo de teste, mais de 64 bytes pra passar de um bloco do ChaCha20 sem problema nenhum!" ** 3;
    const e = try st.create("relatório.pdf", data.len, 7, "Ana", 0, "geral", 0);
    try testing.expect(e.id != 0);
    // fora de ordem: recusa
    try testing.expectError(error.BadChunk, st.write(e, 64, data[64..]));
    try testing.expectEqual(@as(u64, 128), try st.write(e, 0, data[0..128]));
    try testing.expectEqual(@as(u64, data.len), try st.write(e, 128, data[128..]));
    try testing.expect(e.complete);
    // no disco não está em claro
    var raw: [data.len]u8 = undefined;
    const f = openFile(e.pathZ(), "rb").?;
    try testing.expectEqual(data.len, cio.fread(&raw, 1, raw.len, f));
    _ = cio.fclose(f);
    try testing.expect(std.mem.indexOf(u8, &raw, "conteúdo") == null);
    // lê de volta (de um ponto no meio também)
    var out: [data.len]u8 = undefined;
    try testing.expectEqual(data.len, try st.read(e, 0, &out));
    try testing.expectEqualStrings(data, &out);
    var mid: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 64), try st.read(e, 128, &mid));
    try testing.expectEqualStrings(data[128..192], &mid);
    try testing.expectError(error.BadChunk, st.read(e, 3, &mid));
    // grande demais
    try testing.expectError(error.TooBig, st.create("x", proto.file_max + 1, 7, "Ana", 0, "geral", 0));
    // expira 2 h depois
    try testing.expectEqual(@as(usize, 0), st.expire(sync.nowMs()));
    try testing.expectEqual(@as(usize, 1), st.expire(sync.nowMs() + expire_ms + 1000));
    try testing.expect(st.find(e.id) == null);
}

test "arquivos: nome seguro pra qualquer sistema" {
    var b: [proto.file_name_max]u8 = undefined;
    try testing.expectEqualStrings("foto.png", cleanName("/home/ana/foto.png", &b));
    try testing.expectEqualStrings("foto.png", cleanName("C:\\Users\\ana\\foto.png", &b));
    try testing.expectEqualStrings("a_b_c.txt", cleanName("a:b?c.txt", &b));
    try testing.expectEqualStrings("arquivo", cleanName("..", &b));
    try testing.expectEqualStrings("arquivo", cleanName("", &b));
    try testing.expectEqualStrings("nome", cleanName("nome. . ", &b));
    try testing.expectEqualStrings("relatório final.pdf", cleanName("relatório final.pdf", &b));
}
