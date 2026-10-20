//! "Testar meu PC" (Configurações → Desempenho): uns segundos medindo quanto
//! esse computador aguenta pra transmitir (encoder na CPU e na placa) e pra
//! assistir (decoder), e a configuração sugerida. Roda numa thread; nada fica
//! aberto depois.

const std = @import("std");
const sync = @import("sync.zig");
const codec = @import("codec.zig");
const gpa = std.heap.c_allocator;

pub const Result = struct {
    sw1080_ms: f32 = 0, // openh264, 1080p (por quadro)
    sw720_ms: f32 = 0,
    hw_name: [48]u8 = [_]u8{0} ** 48, // encoder da placa ("" = não tem)
    hw1080_ms: f32 = 0,
    dec_sw_ms: f32 = 0, // openh264, 1080p
    dec_hw_name: [48]u8 = [_]u8{0} ** 48,
    dec_hw_ms: f32 = 0,
    conv_ms: f32 = 0, // BGRX → I420 1080p
    threads: u32 = 0,

    pub fn hwName(r: *const Result) []const u8 {
        return std.mem.sliceTo(&r.hw_name, 0);
    }
    pub fn decHwName(r: *const Result) []const u8 {
        return std.mem.sliceTo(&r.dec_hw_name, 0);
    }
};

/// O que dá pra usar com folga (20% de margem).
pub const Suggestion = struct {
    height: u32, // 1080, 720 ou 480
    fps: u32, // 60, 30 ou 15
    hardware: bool,
    watch_fps: u32, // quantos q/s em 1080p esse PC decodifica
};

pub fn suggest(r: *const Result) Suggestion {
    const watch_ms = if (r.dec_hw_ms > 0) @min(r.dec_hw_ms, r.dec_sw_ms) else r.dec_sw_ms;
    const watch: u32 = if (watch_ms > 0) @intFromFloat(@min(240, 1000.0 / (watch_ms * 1.2))) else 0;
    if (r.hw1080_ms > 0) {
        const f = 1000.0 / (r.hw1080_ms * 1.2);
        return .{ .height = 1080, .fps = if (f >= 60) 60 else if (f >= 30) 30 else 15, .hardware = true, .watch_fps = watch };
    }
    const f1080 = 1000.0 / (@max(r.sw1080_ms, r.conv_ms) * 1.2);
    const f720 = 1000.0 / (r.sw720_ms * 1.2);
    if (f1080 >= 60) return .{ .height = 1080, .fps = 60, .hardware = false, .watch_fps = watch };
    if (f1080 >= 30) return .{ .height = 1080, .fps = 30, .hardware = false, .watch_fps = watch };
    if (f720 >= 30) return .{ .height = 720, .fps = 30, .hardware = false, .watch_fps = watch };
    if (f720 >= 15) return .{ .height = 720, .fps = 15, .hardware = false, .watch_fps = watch };
    return .{ .height = 480, .fps = 15, .hardware = false, .watch_fps = watch };
}

pub const State = enum(u8) { idle, running, done, failed };

var state: std.atomic.Value(State) = .init(.idle);
var progress: std.atomic.Value(u8) = .init(0); // 0..100
var mutex: sync.Mutex = .{};
var result: Result = .{};

pub fn getState() State {
    return state.load(.acquire);
}
pub fn getProgress() u8 {
    return progress.load(.monotonic);
}
pub fn getResult() Result {
    mutex.lock();
    defer mutex.unlock();
    return result;
}

/// Começa o teste numa thread (false = já está rodando).
pub fn start() bool {
    if (state.cmpxchgStrong(.idle, .running, .acq_rel, .acquire) != null and
        state.cmpxchgStrong(.done, .running, .acq_rel, .acquire) != null and
        state.cmpxchgStrong(.failed, .running, .acq_rel, .acquire) != null) return false;
    progress.store(0, .release);
    sync.spawn(run, .{}) catch {
        state.store(.failed, .release);
        return false;
    };
    return true;
}

fn run() void {
    var r: Result = .{ .threads = @intCast(sync.cpuCount()) };
    measure(&r) catch {
        state.store(.failed, .release);
        return;
    };
    mutex.lock();
    result = r;
    mutex.unlock();
    progress.store(100, .release);
    state.store(.done, .release);
}

/// Imagens de teste: "movimento" (o pior caso: jogo, vídeo).
fn scene(img: []u8, w: usize, h: usize, f: usize) void {
    for (0..h) |y| {
        const row = img[y * w * 4 ..][0 .. w * 4];
        for (0..w) |x| {
            const v: u32 = @intCast((x * 3 + y * 2 + f * 37) & 0xff);
            const u: u32 = @intCast((x ^ (y + f * 11)) & 0xff);
            row[x * 4] = @intCast(v);
            row[x * 4 + 1] = @intCast(u);
            row[x * 4 + 2] = @intCast((v + u) / 2);
            row[x * 4 + 3] = 255;
        }
    }
}

const frames = 18; // 3 de aquecimento

fn measure(r: *Result) !void {
    const w1: usize = 1920;
    const h1: usize = 1080;
    var imgs: [3][]u8 = undefined;
    for (&imgs, 0..) |*im, i| {
        im.* = try gpa.alloc(u8, w1 * h1 * 4);
        scene(im.*, w1, h1, i);
    }
    defer for (imgs) |im| gpa.free(im);
    var small: [3][]u8 = undefined;
    for (&small, 0..) |*im, i| {
        im.* = try gpa.alloc(u8, 1280 * 720 * 4);
        scene(im.*, 1280, 720, i);
    }
    defer for (small) |im| gpa.free(im);
    progress.store(10, .release);

    // conversão de cor (o que a captura faz antes do openh264)
    {
        const y = try gpa.alloc(u8, w1 * h1 * 3 / 2);
        defer gpa.free(y);
        const t0 = sync.nowUs();
        for (0..10) |i| codec.toI420(imgs[i % 3].ptr, w1 * 4, w1, h1, .bgrx, y[0 .. w1 * h1], y[w1 * h1 ..][0 .. w1 * h1 / 4], y[w1 * h1 + w1 * h1 / 4 ..][0 .. w1 * h1 / 4]);
        r.conv_ms = msPer(t0, 10);
    }

    // encoder na CPU, 1080p (e guarda o vídeo pra medir o decoder)
    var stream: std.ArrayList([]u8) = .empty;
    defer {
        for (stream.items) |b| gpa.free(b);
        stream.deinit(gpa);
    }
    {
        var enc = try codec.Encoder.init(.{ .width = w1, .height = h1, .fps = 30, .bitrate = 6_000_000, .mode = .motion });
        defer enc.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var t0: u64 = 0;
        for (0..frames) |i| {
            if (i == 3) t0 = sync.nowUs();
            out.clearRetainingCapacity();
            _ = try enc.encode(imgs[i % 3].ptr, w1 * 4, .bgrx, &out);
            try stream.append(gpa, try gpa.dupe(u8, out.items));
        }
        r.sw1080_ms = msPer(t0, frames - 3);
    }
    progress.store(35, .release);
    {
        var enc = try codec.Encoder.init(.{ .width = 1280, .height = 720, .fps = 30, .bitrate = 4_000_000, .mode = .motion });
        defer enc.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var t0: u64 = 0;
        for (0..frames) |i| {
            if (i == 3) t0 = sync.nowUs();
            out.clearRetainingCapacity();
            _ = try enc.encode(small[i % 3].ptr, 1280 * 4, .bgrx, &out);
        }
        r.sw720_ms = msPer(t0, frames - 3);
    }
    progress.store(55, .release);

    // encoder da placa (se tiver)
    {
        var err: [256]u8 = undefined;
        if (codec.HwEncoder.init(.{ .width = w1, .height = h1, .fps = 30, .bitrate = 6_000_000, .mode = .motion }, &err)) |e| {
            var enc = e;
            defer enc.deinit();
            const nm = enc.name();
            @memcpy(r.hw_name[0..@min(nm.len, 47)], nm[0..@min(nm.len, 47)]);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var t0: u64 = 0;
            for (0..frames + 12) |i| {
                if (i == 3) t0 = sync.nowUs();
                out.clearRetainingCapacity();
                _ = enc.encode(imgs[i % 3].ptr, w1 * 4, .bgrx, i == 0, &out) catch break;
            }
            r.hw1080_ms = msPer(t0, frames + 9);
        } else |_| {}
    }
    progress.store(75, .release);

    // decoder na CPU e na placa, com o vídeo de 1080p de cima
    {
        var dec = try codec.Decoder.init();
        defer dec.deinit();
        var t0: u64 = 0;
        for (stream.items, 0..) |b, i| {
            if (i == 3) t0 = sync.nowUs();
            _ = dec.decode(b) catch {};
        }
        r.dec_sw_ms = msPer(t0, stream.items.len - 3);
    }
    {
        var err: [256]u8 = undefined;
        if (codec.HwDecoder.init(.h264, &err)) |d| {
            var dec = d;
            defer dec.deinit();
            const nm = dec.name();
            var t0: u64 = 0;
            var ok = true;
            for (stream.items, 0..) |b, i| {
                if (i == 3) t0 = sync.nowUs();
                _ = dec.decode(b) catch {
                    ok = false;
                    break;
                };
            }
            if (ok) {
                @memcpy(r.dec_hw_name[0..@min(nm.len, 47)], nm[0..@min(nm.len, 47)]);
                r.dec_hw_ms = msPer(t0, stream.items.len - 3);
            }
        } else |_| {}
    }
    progress.store(95, .release);
}

fn msPer(t0: u64, n: usize) f32 {
    return @as(f32, @floatFromInt(sync.nowUs() - t0)) / 1000.0 / @as(f32, @floatFromInt(@max(n, 1)));
}

test "sugestão do teste do PC" {
    // placa rápida: 1080p 60
    var r: Result = .{ .sw1080_ms = 25, .sw720_ms = 12, .hw1080_ms = 6, .dec_sw_ms = 10, .dec_hw_ms = 3 };
    var s = suggest(&r);
    try std.testing.expect(s.hardware and s.height == 1080 and s.fps == 60);
    try std.testing.expect(s.watch_fps >= 200);
    // sem placa, CPU média: 1080p dá 30 com folga
    r = .{ .sw1080_ms = 22, .sw720_ms = 10, .dec_sw_ms = 9 };
    s = suggest(&r);
    try std.testing.expect(!s.hardware and s.height == 1080 and s.fps == 30);
    // CPU fraca: 720p 30
    r = .{ .sw1080_ms = 45, .sw720_ms = 20, .dec_sw_ms = 15 };
    s = suggest(&r);
    try std.testing.expect(s.height == 720 and s.fps == 30);
    // muito fraca: 480p 15
    r = .{ .sw1080_ms = 200, .sw720_ms = 90, .dec_sw_ms = 40 };
    s = suggest(&r);
    try std.testing.expect(s.height == 480 and s.fps == 15);
}
