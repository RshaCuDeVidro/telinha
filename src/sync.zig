//! Primitivas de sincronização, tempo e um pool de threads.
const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

const c = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("pthread.h");
    @cInclude("time.h");
});

// timespec da std (no musl o header C tem bitfield e o translate-c desiste)
const timespec = std.c.timespec;
extern "c" fn clock_gettime(clk: c_int, tp: *timespec) c_int;
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
const CLOCK_REALTIME = 0;
const CLOCK_MONOTONIC = 1;

pub const Mutex = struct {
    m: Impl = std.mem.zeroes(Impl),
    const Impl = if (is_windows) c.SRWLOCK else c.pthread_mutex_t;

    pub fn lock(self: *Mutex) void {
        if (is_windows) c.AcquireSRWLockExclusive(&self.m) else _ = c.pthread_mutex_lock(&self.m);
    }
    pub fn unlock(self: *Mutex) void {
        if (is_windows) c.ReleaseSRWLockExclusive(&self.m) else _ = c.pthread_mutex_unlock(&self.m);
    }
};

pub const Cond = struct {
    cv: Impl = std.mem.zeroes(Impl),
    const Impl = if (is_windows) c.CONDITION_VARIABLE else c.pthread_cond_t;

    pub fn wait(self: *Cond, m: *Mutex) void {
        if (is_windows) _ = c.SleepConditionVariableSRW(&self.cv, &m.m, c.INFINITE, 0) else _ = c.pthread_cond_wait(&self.cv, &m.m);
    }
    /// Pode acordar antes da hora; quem chama confere a condição de novo.
    pub fn timedWait(self: *Cond, m: *Mutex, ms: u32) void {
        if (is_windows) {
            _ = c.SleepConditionVariableSRW(&self.cv, &m.m, ms, 0);
        } else {
            var ts: timespec = undefined;
            _ = clock_gettime(CLOCK_REALTIME, &ts);
            const ns: i64 = @as(i64, ts.nsec) + @as(i64, ms % 1000) * 1_000_000;
            ts.sec += @intCast(ms / 1000 + @as(u32, @intCast(@divTrunc(ns, 1_000_000_000))));
            ts.nsec = @intCast(@mod(ns, 1_000_000_000));
            _ = c.pthread_cond_timedwait(&self.cv, &m.m, @ptrCast(&ts));
        }
    }
    pub fn signal(self: *Cond) void {
        if (is_windows) c.WakeConditionVariable(&self.cv) else _ = c.pthread_cond_signal(&self.cv);
    }
    pub fn broadcast(self: *Cond) void {
        if (is_windows) c.WakeAllConditionVariable(&self.cv) else _ = c.pthread_cond_broadcast(&self.cv);
    }
};

/// Microssegundos num relógio monotônico.
pub fn nowUs() u64 {
    if (is_windows) {
        const S = struct {
            var freq: i64 = 0;
        };
        var t: c.LARGE_INTEGER = undefined;
        if (S.freq == 0) {
            _ = c.QueryPerformanceFrequency(&t);
            S.freq = t.QuadPart;
        }
        _ = c.QueryPerformanceCounter(&t);
        const q: u64 = @intCast(t.QuadPart);
        const f: u64 = @intCast(S.freq);
        return q / f * 1_000_000 + (q % f) * 1_000_000 / f;
    } else {
        var ts: timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
    }
}

pub fn nowMs() u64 {
    return nowUs() / 1000;
}

pub fn sleepMs(ms: u32) void {
    if (is_windows) {
        c.Sleep(ms);
    } else {
        const ts: timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
        _ = nanosleep(&ts, null);
    }
}

/// Horário local (hora, minuto) pra mostrar no chat.
pub fn localTime() struct { h: u8, m: u8 } {
    const t = localTimeAgo(0);
    return .{ .h = t.h, .m = t.m };
}

/// Horário local de `seconds` atrás (mensagem antiga do chat).
pub fn localTimeAgo(seconds: i64) struct { h: u8, m: u8 } {
    if (is_windows) {
        var ft: c.FILETIME = undefined;
        c.GetSystemTimeAsFileTime(&ft);
        var q: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
        q -%= @as(u64, @intCast(@max(seconds, 0))) * 10_000_000;
        const utc: c.FILETIME = .{ .dwLowDateTime = @truncate(q), .dwHighDateTime = @truncate(q >> 32) };
        var local: c.FILETIME = undefined;
        var st: c.SYSTEMTIME = undefined;
        if (c.FileTimeToLocalFileTime(&utc, &local) == 0 or c.FileTimeToSystemTime(&local, &st) == 0) {
            c.GetLocalTime(&st);
        }
        return .{ .h = @intCast(st.wHour), .m = @intCast(st.wMinute) };
    } else {
        var t: c.time_t = c.time(null) - @as(c.time_t, @intCast(@max(seconds, 0)));
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&t, &tm);
        return .{ .h = @intCast(tm.tm_hour), .m = @intCast(tm.tm_min) };
    }
}

pub const DateTime = struct { year: u16, month: u8, day: u8, h: u8, m: u8, s: u8 };

/// Data e hora locais (nome de arquivo dos clipes).
pub fn dateTime() DateTime {
    if (is_windows) {
        var st: c.SYSTEMTIME = undefined;
        c.GetLocalTime(&st);
        return .{ .year = st.wYear, .month = @intCast(st.wMonth), .day = @intCast(st.wDay), .h = @intCast(st.wHour), .m = @intCast(st.wMinute), .s = @intCast(st.wSecond) };
    } else {
        var t: c.time_t = c.time(null);
        var tm: c.struct_tm = undefined;
        _ = c.localtime_r(&t, &tm);
        return .{ .year = @intCast(tm.tm_year + 1900), .month = @intCast(tm.tm_mon + 1), .day = @intCast(tm.tm_mday), .h = @intCast(tm.tm_hour), .m = @intCast(tm.tm_min), .s = @intCast(@min(tm.tm_sec, 59)) };
    }
}

extern "advapi32" fn SystemFunction036(buf: [*]u8, len: u32) callconv(.winapi) u8; // RtlGenRandom
extern "c" fn getrandom(buf: [*]u8, len: usize, flags: c_uint) isize;

/// Bytes aleatórios seguros do sistema operacional.
pub fn osRandom(buf: []u8) void {
    if (is_windows) {
        if (SystemFunction036(buf.ptr, @intCast(buf.len)) == 0) @panic("RtlGenRandom falhou");
    } else {
        var off: usize = 0;
        while (off < buf.len) {
            const n = getrandom(buf[off..].ptr, buf.len - off, 0);
            if (n <= 0) @panic("getrandom falhou");
            off += @intCast(n);
        }
    }
}

extern "c" fn _exit(code: c_int) noreturn;
extern "kernel32" fn TerminateProcess(process: ?*anyopaque, code: c_uint) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;

/// Termina o processo na hora, sem os destrutores das bibliotecas. O do
/// NVDEC (libnvcuvid) e o do PipeWire travam esperando threads internas
/// deles, e o app ficava vivo depois de fechar a janela.
pub fn hardExit(code: u8) noreturn {
    if (is_windows) {
        _ = TerminateProcess(GetCurrentProcess(), code);
        unreachable;
    }
    _exit(code);
}

extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern "c" fn gettid() c_int;
extern "kernel32" fn SetThreadPriority(thread: ?*anyopaque, priority: c_int) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) ?*anyopaque;

/// Baixa a prioridade da thread atual (trabalho pesado de vídeo). Se a CPU
/// apertar, quem perde fps somos nós, não o compositor nem o mouse.
pub fn lowerThreadPriority() void {
    if (is_windows) {
        _ = SetThreadPriority(GetCurrentThread(), -1); // THREAD_PRIORITY_BELOW_NORMAL
    } else {
        _ = setpriority(0, @intCast(gettid()), 5); // PRIO_PROCESS + tid = só esta thread no Linux
    }
}

pub fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 4;
}

pub fn spawn(comptime f: anytype, args: anytype) !void {
    const t = try std.Thread.spawn(.{}, f, args);
    t.detach();
}

/// Contador pra esperar um lote de tarefas terminar.
pub const WaitGroup = struct {
    mutex: Mutex = .{},
    cond: Cond = .{},
    pending: usize = 0,

    pub fn add(self: *WaitGroup, n: usize) void {
        self.mutex.lock();
        self.pending += n;
        self.mutex.unlock();
    }
    pub fn done(self: *WaitGroup) void {
        self.mutex.lock();
        self.pending -= 1;
        if (self.pending == 0) self.cond.broadcast();
        self.mutex.unlock();
    }
    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        while (self.pending > 0) self.cond.wait(&self.mutex);
        self.mutex.unlock();
    }
};

/// Pool de threads compartilhado (encode/decode JPEG, escala de imagem).
pub const Pool = struct {
    const Job = struct {
        func: *const fn (*anyopaque, usize) void,
        ctx: *anyopaque,
        index: usize,
        wg: *WaitGroup,
    };
    const cap = 4096;

    mutex: Mutex = .{},
    cond: Cond = .{},
    jobs: [cap]Job = undefined,
    head: usize = 0,
    len: usize = 0,
    threads: usize = 0,

    pub fn start(self: *Pool, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            spawn(worker, .{self}) catch break;
            self.threads += 1;
        }
    }

    fn worker(self: *Pool) void {
        lowerThreadPriority();
        while (true) {
            self.mutex.lock();
            while (self.len == 0) self.cond.wait(&self.mutex);
            const job = self.jobs[self.head];
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            self.mutex.unlock();
            job.func(job.ctx, job.index);
            job.wg.done();
        }
    }

    /// Roda `func(ctx, i)` pra i em 0..n em paralelo e espera tudo terminar.
    pub fn run(self: *Pool, n: usize, ctx: anytype, comptime func: fn (@TypeOf(ctx), usize) void) void {
        if (n == 0) return;
        const Ctx = @TypeOf(ctx);
        const Wrap = struct {
            fn call(p: *anyopaque, i: usize) void {
                func(@ptrCast(@alignCast(p)), i);
            }
        };
        if (self.threads == 0 or n == 1) {
            var i: usize = 0;
            while (i < n) : (i += 1) func(ctx, i);
            return;
        }
        var wg: WaitGroup = .{};
        wg.add(n);
        // a parte 0 fica com quem chamou; o resto vai pra fila
        var i: usize = 1;
        while (i < n) {
            self.mutex.lock();
            while (i < n and self.len < cap) : (i += 1) {
                self.jobs[(self.head + self.len) % cap] = .{ .func = Wrap.call, .ctx = @ptrCast(@constCast(@as(Ctx, ctx))), .index = i, .wg = &wg };
                self.len += 1;
            }
            self.cond.broadcast();
            self.mutex.unlock();
        }
        // quem chamou trabalha em vez de só esperar: a própria parte e o que
        // ainda estiver na fila (menos uma ida e volta de dormir/acordar)
        func(ctx, 0);
        wg.done();
        while (true) {
            self.mutex.lock();
            if (self.len == 0) {
                self.mutex.unlock();
                break;
            }
            const job = self.jobs[self.head];
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            self.mutex.unlock();
            job.func(job.ctx, job.index);
            job.wg.done();
        }
        wg.wait();
    }
};

pub var pool: Pool = .{};
