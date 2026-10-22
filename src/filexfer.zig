//! Arquivos na sala, do lado do app: subir (quem manda) e baixar (quem
//! clica). Cada um numa thread, em segundo plano (bgflow.zig): o ritmo vem do
//! atraso das confirmações e recua quando a conexão começa a encher, pra não
//! atrapalhar o vídeo, a voz e o chat de ninguém.
const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const proto = @import("proto.zig");
const bgflow = @import("bgflow.zig");
const files = @import("files.zig");
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const gpa = std.heap.c_allocator;
const cio = files.cio;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Kind = enum { up, down };
pub const State = enum(u8) { waiting, running, done, failed, canceled };

pub const Transfer = struct {
    refs: std.atomic.Value(u32) = .init(2), // a lista + a thread
    kind: Kind,
    local: u32 = 0, // subida: o número do pedido (até o servidor dar o id)
    file_id: std.atomic.Value(u32) = .init(0),
    name: [proto.file_name_max]u8 = undefined,
    name_len: usize = 0,
    size: u64,
    to: u32 = 0,
    reply_to: u32 = 0,
    path: [1024]u8 = undefined, // subida: de onde lê; descida: onde salvou
    path_len: usize = 0,
    done_bytes: std.atomic.Value(u64) = .init(0), // confirmados (subida) / gravados (descida)
    state: std.atomic.Value(State) = .init(.waiting),
    err: [200]u8 = undefined,
    err_len: usize = 0,
    started_us: u64,
    // controle (com o mutex)
    mutex: sync.Mutex = .{},
    cond: sync.Cond = .{},
    flow: bgflow.Flow = .{},
    sent: u64 = 0, // subida: mandado; descida: pedido
    ring: [512]Sent = undefined, // o que está no caminho (pra medir o atraso)
    ring_head: usize = 0,
    ring_len: usize = 0,
    out: ?*cio.FILE = null, // descida: o .parte sendo gravado

    const Sent = struct { end: u64, at_us: u64 };

    pub fn nameSlice(t: *const Transfer) []const u8 {
        return t.name[0..t.name_len];
    }
    pub fn pathSlice(t: *const Transfer) []const u8 {
        return t.path[0..t.path_len];
    }
    pub fn errSlice(t: *const Transfer) []const u8 {
        return t.err[0..t.err_len];
    }

    /// 0 a 1.
    pub fn progress(t: *const Transfer) f32 {
        if (t.size == 0) return 1;
        return @floatCast(@as(f64, @floatFromInt(t.done_bytes.load(.acquire))) / @as(f64, @floatFromInt(t.size)));
    }

    /// Bytes por segundo desde que começou.
    pub fn rate(t: *const Transfer) u64 {
        const dt = sync.nowUs() -| t.started_us;
        if (dt < 200_000) return 0;
        return t.done_bytes.load(.acquire) * 1_000_000 / dt;
    }

    pub fn cancel(t: *Transfer) void {
        t.mutex.lock();
        defer t.mutex.unlock();
        const s = t.state.load(.acquire);
        if (s == .waiting or s == .running) t.state.store(.canceled, .release);
        t.cond.broadcast();
    }

    fn fail(t: *Transfer, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&t.err, f, args) catch t.err[0..0];
        t.err_len = s.len;
        t.state.store(.failed, .release);
    }

    pub fn release(t: *Transfer) void {
        if (t.refs.fetchSub(1, .acq_rel) == 1) {
            if (t.out) |f| _ = cio.fclose(f);
            gpa.destroy(t);
        }
    }

    /// Chegou a confirmação até `upto` (subida: o ack; descida: o pedaço gravado).
    fn confirmed(t: *Transfer, upto: u64) void {
        const now = sync.nowUs();
        var last: ?u64 = null;
        while (t.ring_len > 0 and t.ring[t.ring_head].end <= upto) {
            last = t.ring[t.ring_head].at_us;
            t.ring_head = (t.ring_head + 1) % t.ring.len;
            t.ring_len -= 1;
        }
        if (last) |at| t.flow.sample(now, now -| at);
        t.done_bytes.store(upto, .release);
        t.cond.broadcast();
    }

    fn track(t: *Transfer, end: u64) void {
        if (t.ring_len == t.ring.len) {
            t.ring_head = (t.ring_head + 1) % t.ring.len;
            t.ring_len -= 1;
        }
        t.ring[(t.ring_head + t.ring_len) % t.ring.len] = .{ .end = end, .at_us = sync.nowUs() };
        t.ring_len += 1;
    }
};

/// As transferências de uma sala (o Client tem uma).
pub const Registry = struct {
    mutex: sync.Mutex = .{},
    items: std.ArrayList(*Transfer) = .empty,
    next_local: u32 = 1,

    pub fn deinit(r: *Registry) void {
        for (r.items.items) |t| {
            t.cancel();
            t.release();
        }
        r.items.deinit(gpa);
    }

    /// Cópia da lista (cada uma com uma referência a mais: solte com `release`).
    pub fn snapshot(r: *Registry, out: []*Transfer) usize {
        r.mutex.lock();
        defer r.mutex.unlock();
        var n: usize = 0;
        for (r.items.items) |t| {
            if (n == out.len) break;
            _ = t.refs.fetchAdd(1, .monotonic);
            out[n] = t;
            n += 1;
        }
        return n;
    }

    /// Esquece as que terminaram (a UI já mostrou).
    pub fn forget(r: *Registry, t: *Transfer) void {
        r.mutex.lock();
        defer r.mutex.unlock();
        const i = std.mem.indexOfScalar(*Transfer, r.items.items, t) orelse return;
        _ = r.items.swapRemove(i);
        t.release();
    }

    fn findBy(r: *Registry, comptime field: enum { local, id }, v: u32, kind: Kind) ?*Transfer {
        r.mutex.lock();
        defer r.mutex.unlock();
        for (r.items.items) |t| {
            if (t.kind != kind) continue;
            const match = switch (field) {
                .local => t.local == v,
                .id => t.file_id.load(.acquire) == v,
            };
            if (match) {
                _ = t.refs.fetchAdd(1, .monotonic);
                return t;
            }
        }
        return null;
    }

    /// A descida desse arquivo, se tiver (com referência a mais).
    pub fn download(r: *Registry, id: u32) ?*Transfer {
        return r.findBy(.id, id, .down);
    }

    // --------------------------------------------- mensagens do servidor

    pub fn onReady(r: *Registry, local: u32, id: u32, why: []const u8) void {
        const t = r.findBy(.local, local, .up) orelse return;
        defer t.release();
        t.mutex.lock();
        defer t.mutex.unlock();
        if (id == 0) {
            t.fail("{s}", .{why});
        } else {
            t.file_id.store(id, .release);
            if (t.state.load(.acquire) == .waiting) t.state.store(.running, .release);
        }
        t.cond.broadcast();
    }

    pub fn onAck(r: *Registry, id: u32, received: u64) void {
        const t = r.findBy(.id, id, .up) orelse return;
        defer t.release();
        t.mutex.lock();
        defer t.mutex.unlock();
        t.confirmed(received);
    }

    /// Um pedaço baixado: grava (em ordem) e confirma.
    pub fn onData(r: *Registry, id: u32, offset: u64, bytes: []const u8) void {
        const t = r.findBy(.id, id, .down) orelse return;
        defer t.release();
        t.mutex.lock();
        defer t.mutex.unlock();
        const have = t.done_bytes.load(.acquire);
        if (offset != have or t.state.load(.acquire) != .running) return;
        const f = t.out orelse return;
        if (cio.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) {
            t.fail("não consegui gravar no disco (cheio?)", .{});
            t.cond.broadcast();
            return;
        }
        t.confirmed(have + bytes.len);
    }
};

// ------------------------------------------------------------- subir

/// Manda o arquivo `path` na sala (`to` ≠ 0 = privada; `reply_to` = resposta).
/// O progresso aparece na lista (Registry.snapshot).
pub fn upload(cl: *Client, path: []const u8, to: u32, reply_to: u32) !void {
    var pz: [1024]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return error.BadPath;
    const f = files.openFile(p, "rb") orelse return error.CantOpen;
    const size = fileSize(f);
    _ = cio.fclose(f);
    if (size == 0) return error.Empty;
    if (size > proto.file_max) return error.TooBig;
    const t = try gpa.create(Transfer);
    t.* = .{ .kind = .up, .size = size, .to = to, .reply_to = reply_to, .started_us = sync.nowUs() };
    @memcpy(t.path[0..path.len], path);
    t.path_len = path.len;
    var nb: [proto.file_name_max]u8 = undefined;
    const name = files.cleanName(path, &nb);
    @memcpy(t.name[0..name.len], name);
    t.name_len = name.len;
    const reg = &cl.xfers;
    reg.mutex.lock();
    t.local = reg.next_local;
    reg.next_local +%= 1;
    reg.items.append(gpa, t) catch {
        reg.mutex.unlock();
        gpa.destroy(t);
        return error.OutOfMemory;
    };
    reg.mutex.unlock();
    _ = cl.retain();
    sync.spawn(upLoop, .{ cl, t }) catch {
        cl.release();
        t.fail("não consegui começar", .{});
        t.release();
    };
}

fn upLoop(cl: *Client, t: *Transfer) void {
    sync.nameThread("arquivo-sobe");
    defer cl.release();
    defer t.release();
    var pz: [1024]u8 = undefined;
    const f = files.openFile(std.fmt.bufPrintZ(&pz, "{s}", .{t.pathSlice()}) catch return t.fail("caminho estranho", .{}), "rb") orelse return t.fail("não consegui abrir o arquivo", .{});
    defer _ = cio.fclose(f);
    // pede o lugar no servidor
    {
        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.file_put) catch return;
        b.u32_(t.local) catch return;
        b.str(t.nameSlice()) catch return;
        b.u64_(t.size) catch return;
        b.u32_(t.to) catch return;
        b.u32_(t.reply_to) catch return;
        cl.queue.pushOwned(b.finish() catch return);
    }
    t.mutex.lock();
    const deadline = sync.nowMs() + 15_000;
    while (t.state.load(.acquire) == .waiting and sync.nowMs() < deadline and !cl.closing.load(.acquire)) t.cond.timedWait(&t.mutex, 200);
    if (t.state.load(.acquire) == .waiting) t.fail("o servidor não respondeu", .{});
    t.mutex.unlock();
    var buf: [bgflow.chunk]u8 = undefined;
    while (true) {
        t.mutex.lock();
        var st = t.state.load(.acquire);
        while (st == .running and !cl.closing.load(.acquire) and t.sent < t.size and !t.flow.canSend(t.sent - t.done_bytes.load(.acquire))) {
            t.cond.timedWait(&t.mutex, 200);
            st = t.state.load(.acquire);
        }
        if (cl.closing.load(.acquire) and st == .running) t.fail("saiu da sala", .{});
        st = t.state.load(.acquire);
        const off = t.sent;
        if (st != .running or off >= t.size) {
            t.mutex.unlock();
            break;
        }
        t.mutex.unlock();
        const n: usize = @intCast(@min(buf.len, t.size - off));
        if (cio.fread(&buf, 1, n, f) != n) {
            t.fail("o arquivo mudou enquanto subia", .{});
            break;
        }
        const m = proto.Msg.alloc(.file_data, 12 + n) catch break;
        std.mem.writeInt(u32, m.payload()[0..4], t.file_id.load(.acquire), .little);
        std.mem.writeInt(u64, m.payload()[4..12], off, .little);
        @memcpy(m.payload()[12..][0..n], buf[0..n]);
        t.mutex.lock();
        t.track(off + n);
        t.sent = off + n;
        t.mutex.unlock();
        cl.queue.pushOwned(m);
    }
    // espera o servidor confirmar o fim (ou desiste)
    t.mutex.lock();
    defer t.mutex.unlock();
    const st = t.state.load(.acquire);
    if (st == .canceled or st == .failed) {
        if (t.file_id.load(.acquire) != 0) {
            const m = proto.Msg.alloc(.file_cancel, 4) catch return;
            std.mem.writeInt(u32, m.payload()[0..4], t.file_id.load(.acquire), .little);
            cl.queue.pushOwned(m);
        }
        return;
    }
    const until = sync.nowMs() + 60_000;
    while (t.done_bytes.load(.acquire) < t.size and t.state.load(.acquire) == .running and sync.nowMs() < until and !cl.closing.load(.acquire)) t.cond.timedWait(&t.mutex, 200);
    if (t.done_bytes.load(.acquire) == t.size) t.state.store(.done, .release) else if (t.state.load(.acquire) == .running) t.fail("o servidor parou de confirmar", .{});
}

// ------------------------------------------------------------- baixar

/// Baixa o arquivo `id` pra pasta de downloads. Já baixando: devolve a mesma.
/// Devolve com uma referência a mais (quem chamou solta com `release`).
pub fn download(cl: *Client, id: u32, name: []const u8, size: u64) !*Transfer {
    if (cl.xfers.download(id)) |t| return t;
    const t = try gpa.create(Transfer);
    errdefer gpa.destroy(t);
    t.* = .{ .kind = .down, .size = size, .started_us = sync.nowUs() };
    t.file_id.store(id, .release);
    var nb: [proto.file_name_max]u8 = undefined;
    const clean = files.cleanName(name, &nb);
    @memcpy(t.name[0..clean.len], clean);
    t.name_len = clean.len;
    // destino: Downloads/nome (ou "nome (2).ext" se já existir); grava num .parte
    var db: [700]u8 = undefined;
    const dir = downloadsDir(&db);
    if (dir.len == 0) return error.NoFolder;
    const dest = uniquePath(dir, clean, &t.path) orelse return error.NoFolder;
    t.path_len = dest.len;
    var pb: [1100]u8 = undefined;
    const part = std.fmt.bufPrintZ(&pb, "{s}.parte", .{dest}) catch return error.NoFolder;
    t.out = files.openFile(part, "wb") orelse return error.CantWrite;
    t.state.store(.running, .release);
    t.refs.store(3, .release); // a lista + a thread + quem chamou
    const reg = &cl.xfers;
    reg.mutex.lock();
    reg.items.append(gpa, t) catch {
        reg.mutex.unlock();
        _ = cio.fclose(t.out.?);
        t.out = null;
        files.removeFile(part);
        return error.OutOfMemory;
    };
    reg.mutex.unlock();
    _ = cl.retain();
    sync.spawn(downLoop, .{ cl, t }) catch {
        cl.release();
        t.fail("não consegui começar", .{});
        t.release();
    };
    return t;
}

fn downLoop(cl: *Client, t: *Transfer) void {
    sync.nameThread("arquivo-desce");
    defer cl.release();
    defer t.release();
    const id = t.file_id.load(.acquire);
    var last_progress_ms = sync.nowMs();
    var last_done: u64 = 0;
    t.mutex.lock();
    while (true) {
        const st = t.state.load(.acquire);
        const have = t.done_bytes.load(.acquire);
        if (st != .running or have >= t.size) break;
        if (cl.closing.load(.acquire)) {
            t.fail("saiu da sala", .{});
            break;
        }
        // pede mais enquanto a janela deixar
        while (t.sent < t.size and t.flow.canSend(t.sent - have)) {
            const n: u32 = @intCast(@min(bgflow.chunk, t.size - t.sent));
            const m = proto.Msg.alloc(.file_get, 16) catch break;
            std.mem.writeInt(u32, m.payload()[0..4], id, .little);
            std.mem.writeInt(u64, m.payload()[4..12], t.sent, .little);
            std.mem.writeInt(u32, m.payload()[12..16], n, .little);
            t.track(t.sent + n);
            t.sent += n;
            cl.queue.pushOwned(m);
        }
        t.cond.timedWait(&t.mutex, 250);
        // nada chegando: o arquivo saiu da sala (expirou) ou a conexão caiu
        const now = sync.nowMs();
        if (t.done_bytes.load(.acquire) != last_done) {
            last_done = t.done_bytes.load(.acquire);
            last_progress_ms = now;
        } else if (now -| last_progress_ms > 15_000) {
            t.fail("o arquivo parou de chegar (ele expira 2 h depois de mandado)", .{});
            break;
        }
    }
    const ok = t.done_bytes.load(.acquire) == t.size and t.state.load(.acquire) == .running;
    if (t.out) |f| _ = cio.fclose(f);
    t.out = null;
    var pb: [1100]u8 = undefined;
    const part = std.fmt.bufPrintZ(&pb, "{s}.parte", .{t.pathSlice()}) catch {
        t.mutex.unlock();
        return;
    };
    if (ok) {
        var db: [1024]u8 = undefined;
        const dest = std.fmt.bufPrintZ(&db, "{s}", .{t.pathSlice()}) catch "";
        if (renameFile(part, dest)) t.state.store(.done, .release) else t.fail("não consegui dar o nome final ao arquivo", .{});
    } else files.removeFile(part);
    t.mutex.unlock();
}

// ------------------------------------------------------------- pastas

/// A pasta de downloads: TELINHA_PASTA_ARQUIVOS (testes), senão a do usuário
/// (XDG_DOWNLOAD_DIR no Linux, %USERPROFILE%\Downloads no Windows).
pub fn downloadsDir(buf: []u8) []const u8 {
    if (getenv("TELINHA_PASTA_ARQUIVOS")) |p| {
        const s = std.mem.span(p);
        if (s.len >= buf.len) return "";
        @memcpy(buf[0..s.len], s);
        buf[s.len] = 0;
        files.makeDir(buf[0..s.len :0]);
        return buf[0..s.len];
    }
    if (builtin.os.tag == .windows) {
        var w: [512]u16 = undefined;
        const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"), &w, w.len);
        if (n == 0 or n >= w.len) return "";
        var up: [600]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&up, w[0..n]) catch return "";
        const d = std.fmt.bufPrintZ(buf, "{s}\\Downloads", .{up[0..len]}) catch return "";
        files.makeDir(d);
        return d;
    }
    const home = std.mem.span(getenv("HOME") orelse "/tmp");
    var cfg: [600]u8 = undefined;
    const dirs = (if (getenv("XDG_CONFIG_HOME")) |x|
        std.fmt.bufPrintZ(&cfg, "{s}/user-dirs.dirs", .{std.mem.span(x)})
    else
        std.fmt.bufPrintZ(&cfg, "{s}/.config/user-dirs.dirs", .{home})) catch return "";
    if (cio.fopen(dirs.ptr, "r")) |f| {
        defer _ = cio.fclose(f);
        var line: [600]u8 = undefined;
        while (cio.fgets(&line, line.len, f) != null) {
            const l = std.mem.trimEnd(u8, std.mem.sliceTo(&line, 0), "\r\n");
            if (!std.mem.startsWith(u8, l, "XDG_DOWNLOAD_DIR=")) continue;
            var v = std.mem.trim(u8, l["XDG_DOWNLOAD_DIR=".len..], "\"");
            const d = if (std.mem.startsWith(u8, v, "$HOME")) blk: {
                v = v["$HOME".len..];
                break :blk std.fmt.bufPrintZ(buf, "{s}{s}", .{ home, v }) catch return "";
            } else std.fmt.bufPrintZ(buf, "{s}", .{v}) catch return "";
            files.makeDir(d);
            return d;
        }
    }
    const d = std.fmt.bufPrintZ(buf, "{s}/Downloads", .{home}) catch return "";
    files.makeDir(d);
    return d;
}

/// dir/nome, ou dir/nome (2).ext... o primeiro que não existe (nem o .parte dele).
fn uniquePath(dir: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    const sep = if (builtin.os.tag == .windows) "\\" else "/";
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot) |d| (if (d > 0) name[0..d] else name) else name;
    const ext = if (dot) |d| (if (d > 0) name[d..] else "") else "";
    var i: u32 = 1;
    while (i < 1000) : (i += 1) {
        const p = (if (i == 1)
            std.fmt.bufPrint(out, "{s}{s}{s}", .{ dir, sep, name })
        else
            std.fmt.bufPrint(out, "{s}{s}{s} ({d}){s}", .{ dir, sep, stem, i, ext })) catch return null;
        if (!exists(p)) {
            var pb: [1100]u8 = undefined;
            const part = std.fmt.bufPrint(&pb, "{s}.parte", .{p}) catch return null;
            if (!exists(part)) return p;
        }
    }
    return null;
}

fn exists(path: []const u8) bool {
    var b: [1100]u8 = undefined;
    const z = std.fmt.bufPrintZ(&b, "{s}", .{path}) catch return false;
    const f = files.openFile(z, "rb") orelse return false;
    _ = cio.fclose(f);
    return true;
}

fn fileSize(f: *cio.FILE) u64 {
    if (builtin.os.tag == .windows) {
        _ = _fseeki64(f, 0, cio.SEEK_END);
        const n = _ftelli64(f);
        _ = _fseeki64(f, 0, cio.SEEK_SET);
        return @intCast(@max(0, n));
    }
    _ = fseeko(f, 0, cio.SEEK_END);
    const n = ftello(f);
    _ = fseeko(f, 0, cio.SEEK_SET);
    return @intCast(@max(0, n));
}

fn renameFile(from: [:0]const u8, to: [:0]const u8) bool {
    if (builtin.os.tag == .windows) {
        var a: [1024:0]u16 = undefined;
        var b: [1024:0]u16 = undefined;
        const na = std.unicode.utf8ToUtf16Le(&a, from) catch return false;
        const nb = std.unicode.utf8ToUtf16Le(&b, to) catch return false;
        if (na >= a.len or nb >= b.len) return false;
        a[na] = 0;
        b[nb] = 0;
        return MoveFileExW(&a, &b, 1) != 0; // MOVEFILE_REPLACE_EXISTING
    }
    return rename(from.ptr, to.ptr) == 0;
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) c_int;
extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;
extern "c" fn _fseeki64(f: *cio.FILE, off: i64, whence: c_int) c_int;
extern "c" fn _ftelli64(f: *cio.FILE) i64;
extern "c" fn fseeko(f: *cio.FILE, off: i64, whence: c_int) c_int;
extern "c" fn ftello(f: *cio.FILE) i64;
