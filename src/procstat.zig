//! CPU e memória do próprio processo (estatísticas do servidor pro admin).
//! Linux: /proc/self; Windows: GetProcessTimes/K32GetProcessMemoryInfo. Lido
//! só quando alguém está olhando as estatísticas.
const std = @import("std");
const builtin = @import("builtin");

pub const Sample = struct {
    cpu_us: u64 = 0, // tempo de CPU total do processo (usuário + sistema)
    rss_kb: u64 = 0, // memória residente
};

pub fn cores() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

pub fn sample() Sample {
    if (builtin.os.tag == .windows) return sampleWindows();
    if (builtin.os.tag == .linux) return sampleLinux();
    return .{};
}

fn readFile(path: [*:0]const u8, buf: []u8) []const u8 {
    const f = std.c.fopen(path, "r") orelse return "";
    defer _ = std.c.fclose(f);
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

fn sampleLinux() Sample {
    var out: Sample = .{};
    var buf: [1024]u8 = undefined;
    // /proc/self/stat: o nome vem entre parênteses (pode ter espaço); utime e
    // stime são os campos 14 e 15 (11 e 12 depois do ")")
    const st = readFile("/proc/self/stat", &buf);
    if (std.mem.findScalarLast(u8, st, ')')) |close| {
        var it = std.mem.tokenizeScalar(u8, st[close + 1 ..], ' ');
        var i: usize = 0;
        var ticks: u64 = 0;
        while (it.next()) |f| : (i += 1) {
            if (i == 11 or i == 12) ticks += std.fmt.parseInt(u64, f, 10) catch 0;
            if (i == 12) break;
        }
        out.cpu_us = ticks * 10_000; // USER_HZ = 100 em todo Linux que importa
    }
    var mb: [256]u8 = undefined;
    const sm = readFile("/proc/self/statm", &mb);
    var it = std.mem.tokenizeScalar(u8, sm, ' ');
    _ = it.next();
    if (it.next()) |res| out.rss_kb = (std.fmt.parseInt(u64, res, 10) catch 0) * 4;
    return out;
}

const win = if (builtin.os.tag == .windows) struct {
    const W = std.os.windows;
    const FILETIME = extern struct { lo: u32, hi: u32 };
    const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
    };
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) W.HANDLE;
    extern "kernel32" fn GetProcessTimes(h: W.HANDLE, c: *FILETIME, e: *FILETIME, k: *FILETIME, u: *FILETIME) callconv(.winapi) c_int;
    extern "kernel32" fn K32GetProcessMemoryInfo(h: W.HANDLE, pmc: *PROCESS_MEMORY_COUNTERS, cb: u32) callconv(.winapi) c_int;
} else struct {};

fn sampleWindows() Sample {
    if (builtin.os.tag != .windows) return .{};
    var out: Sample = .{};
    const h = win.GetCurrentProcess();
    var c: win.FILETIME = undefined;
    var e: win.FILETIME = undefined;
    var k: win.FILETIME = undefined;
    var u: win.FILETIME = undefined;
    if (win.GetProcessTimes(h, &c, &e, &k, &u) != 0) {
        const kt = (@as(u64, k.hi) << 32) | k.lo;
        const ut = (@as(u64, u.hi) << 32) | u.lo;
        out.cpu_us = (kt + ut) / 10; // unidades de 100 ns
    }
    var pmc: win.PROCESS_MEMORY_COUNTERS = undefined;
    pmc.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS);
    if (win.K32GetProcessMemoryInfo(h, &pmc, pmc.cb) != 0) out.rss_kb = pmc.WorkingSetSize / 1024;
    return out;
}

test "procstat: lê alguma coisa do próprio processo" {
    const s = sample();
    if (builtin.os.tag == .linux) try std.testing.expect(s.rss_kb > 0);
    try std.testing.expect(cores() >= 1);
}
