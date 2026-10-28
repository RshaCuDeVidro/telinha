//! Tempos por quadro pro log de depuração: em vez de médias (que escondem o
//! engasgo), as últimas amostras de cada etapa e, a cada 2 s, mediana, p95 e
//! máximo. "Engasga" vira "o p95 do intervalo entre quadros na tela foi 180 ms".
//! Desligado (log de depuração desligado), cada amostra custa uma leitura atômica.
const std = @import("std");

/// Ligado junto com o log de depuração (a interface acompanha a cada quadro).
pub var enabled = std.atomic.Value(bool).init(false);

pub const Hist = struct {
    const cap = 256;
    buf: [cap]u32 = [_]u32{0} ** cap,
    n: std.atomic.Value(u32) = .init(0),

    /// Uma amostra (µs). Qualquer thread; a última escrita perdida numa
    /// leitura ao mesmo tempo não importa.
    pub fn add(h: *Hist, us: u64) void {
        if (!enabled.load(.monotonic)) return;
        const i = h.n.fetchAdd(1, .monotonic);
        @atomicStore(u32, &h.buf[i % cap], @intCast(@min(us, std.math.maxInt(u32))), .monotonic);
    }

    pub const Summary = struct {
        n: u32 = 0,
        p50: u32 = 0,
        p95: u32 = 0,
        max: u32 = 0,

        pub fn format(s: Summary, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (s.n == 0) return w.writeAll("-");
            try w.print("{d:.1}/{d:.1}/{d:.1} ms", .{ ms(s.p50), ms(s.p95), ms(s.max) });
        }
        fn ms(us: u32) f64 {
            return @as(f64, @floatFromInt(us)) / 1000.0;
        }
    };

    /// Mediana, p95 e máximo desde a última vez (e recomeça).
    pub fn take(h: *Hist) Summary {
        const n = h.n.swap(0, .monotonic);
        const k: usize = @min(n, cap);
        if (k == 0) return .{};
        var tmp: [cap]u32 = undefined;
        for (0..k) |i| tmp[i] = @atomicLoad(u32, &h.buf[i], .monotonic);
        std.mem.sort(u32, tmp[0..k], {}, std.sort.asc(u32));
        return .{ .n = n, .p50 = tmp[k / 2], .p95 = tmp[@min(k - 1, k * 95 / 100)], .max = tmp[k - 1] };
    }
};

test "trace: mediana, p95 e máximo das amostras; desligado não guarda nada" {
    var h: Hist = .{};
    enabled.store(false, .monotonic);
    h.add(5);
    try std.testing.expectEqual(@as(u32, 0), h.take().n);
    enabled.store(true, .monotonic);
    defer enabled.store(false, .monotonic);
    for (1..101) |i| h.add(i * 1000);
    const s = h.take();
    try std.testing.expectEqual(@as(u32, 100), s.n);
    try std.testing.expectEqual(@as(u32, 51_000), s.p50);
    try std.testing.expectEqual(@as(u32, 96_000), s.p95);
    try std.testing.expectEqual(@as(u32, 100_000), s.max);
    try std.testing.expectEqual(@as(u32, 0), h.take().n); // recomeçou
}
