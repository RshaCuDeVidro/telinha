//! Tema personalizado a partir de um arquivo CSS que atualiza sozinho: uma
//! thread olha o arquivo a cada 1,5 s (lê e compara o hash; só monta o tema
//! de novo se o conteúdo mudou) e acorda a interface. Nada de redesenho pra
//! ficar checando: a interface só pega o tema novo quando ele muda.
const std = @import("std");
const sync = @import("sync.zig");
const theme = @import("theme.zig");
const mp4 = @import("mp4.zig");
const cio = mp4.cio;
const gpa = std.heap.c_allocator;

pub const Status = enum(u8) { off, ok, missing, no_colors };

const max_size = 512 * 1024;

var mutex: sync.Mutex = .{};
var path_buf: [512:0]u8 = [_:0]u8{0} ** 512;
var gen: u32 = 0; // muda quando o caminho muda (a thread velha para sozinha)
var last_hash: u64 = 0;
var pending: ?theme.Base = null;
var status: std.atomic.Value(Status) = .init(.off);

/// Chamado (da thread) quando o tema do arquivo mudou.
pub var on_change: ?*const fn () void = null;

/// Começa a olhar esse arquivo (vazio = para).
pub fn watch(p: []const u8) void {
    mutex.lock();
    gen +%= 1;
    const my_gen = gen;
    const n = @min(p.len, path_buf.len - 1);
    @memcpy(path_buf[0..n], p[0..n]);
    path_buf[n] = 0;
    last_hash = 0;
    pending = null;
    mutex.unlock();
    if (n == 0) {
        status.store(.off, .release);
        return;
    }
    check(my_gen); // a primeira leitura é na hora
    sync.spawn(loop, .{my_gen}) catch {};
}

pub fn getStatus() Status {
    return status.load(.acquire);
}

/// O tema novo, se o arquivo mudou desde a última vez (só uma vez cada).
pub fn take() ?theme.Base {
    mutex.lock();
    defer mutex.unlock();
    const b = pending;
    pending = null;
    return b;
}

fn loop(my_gen: u32) void {
    while (true) {
        sync.sleepMs(1500);
        mutex.lock();
        const alive = gen == my_gen;
        mutex.unlock();
        if (!alive) return;
        check(my_gen);
    }
}

fn check(my_gen: u32) void {
    var pb: [512:0]u8 = undefined;
    mutex.lock();
    if (gen != my_gen) {
        mutex.unlock();
        return;
    }
    pb = path_buf;
    mutex.unlock();
    const p = std.mem.sliceTo(&pb, 0);
    const f = mp4.openFile(pb[0..p.len :0], "rb") orelse {
        status.store(.missing, .release);
        return;
    };
    defer _ = cio.fclose(f);
    const buf = gpa.alloc(u8, max_size) catch return;
    defer gpa.free(buf);
    const n = cio.fread(buf.ptr, 1, buf.len, f);
    const h = std.hash.Wyhash.hash(0, buf[0..n]);
    mutex.lock();
    const same = h == last_hash and gen == my_gen;
    if (!same) last_hash = h;
    mutex.unlock();
    if (same) return;
    const b = theme.parseCss(buf[0..n]) orelse {
        status.store(.no_colors, .release);
        return;
    };
    mutex.lock();
    if (gen == my_gen) pending = b;
    mutex.unlock();
    status.store(.ok, .release);
    if (on_change) |cb| cb();
}
