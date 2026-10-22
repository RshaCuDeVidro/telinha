//! Transferência em segundo plano (arquivos na sala): anda o mais rápido que
//! a conexão deixa **sem atrapalhar** o resto (vídeo, voz, chat). Como o
//! LEDBAT (o que torrent e atualização do sistema usam): mede quanto cada
//! pedaço demora pra ser confirmado; o menor tempo visto é o caminho vazio;
//! subiu mais que `target` acima disso = tem fila crescendo em algum lugar
//! (provavelmente o vídeo de alguém disputando a mesma conexão) e a janela
//! encolhe na hora. Sem fila, cresce aos poucos.
const std = @import("std");

pub const chunk: u32 = 32 * 1024; // múltiplo de 64 (o bloco do ChaCha20 de quem guarda)
pub const min_window: u32 = chunk;
pub const max_window: u32 = 4 * 1024 * 1024;
/// Atraso a mais tolerado (fila) antes de recuar.
pub const target_us: u64 = 40_000;
/// O "caminho vazio" (menor tempo) é esquecido aos poucos: a rota pode mudar.
const base_window_us: u64 = 10_000_000;

pub const Flow = struct {
    window: u32 = 4 * chunk, // bytes que podem estar no caminho sem confirmação
    base_us: u64 = std.math.maxInt(u64),
    base_at_us: u64 = 0,
    last_cut_us: u64 = 0,

    /// Um pedaço confirmado depois de `rtt_us`.
    pub fn sample(f: *Flow, now_us: u64, rtt_us: u64) void {
        // menor atraso visto (renovado de tempos em tempos)
        if (rtt_us < f.base_us or now_us -| f.base_at_us > base_window_us) {
            f.base_us = rtt_us;
            f.base_at_us = now_us;
        }
        const queue = rtt_us -| f.base_us;
        if (queue > target_us) {
            // fila: recua (no máximo uma vez por atraso de ida e volta, senão
            // uma rajada de amostras atrasadas zeraria a janela)
            if (now_us -| f.last_cut_us > @max(f.base_us, 20_000)) {
                f.window = @max(min_window, f.window / 2);
                f.last_cut_us = now_us;
            }
        } else {
            // sem fila: +1 pedaço por janela inteira confirmada (cresce mais
            // devagar quanto mais perto do alvo)
            const room = target_us - queue;
            const grow = @as(u64, chunk) * chunk / f.window * room / target_us;
            f.window = @intCast(@min(max_window, @as(u64, f.window) + @max(1, grow)));
        }
    }

    /// Dá pra mandar mais um pedaço com `in_flight` bytes ainda sem confirmação?
    pub fn canSend(f: *const Flow, in_flight: u64) bool {
        return in_flight + chunk <= f.window or in_flight == 0;
    }
};

const testing = std.testing;

test "bgflow: cresce sem fila e recua quando o atraso sobe (o vídeo pede passagem)" {
    var f: Flow = .{};
    var t: u64 = 1_000_000;
    // caminho vazio: 20 ms; a janela cresce
    for (0..400) |_| {
        t += 5_000;
        f.sample(t, 20_000);
    }
    const grown = f.window;
    try testing.expect(grown > 16 * chunk);
    // fila de 100 ms: corta pela metade, uma vez por ida e volta
    t += 5_000;
    f.sample(t, 120_000);
    try testing.expectEqual(grown / 2, f.window);
    t += 1_000;
    f.sample(t, 120_000); // logo em seguida: não corta de novo
    try testing.expectEqual(grown / 2, f.window);
    // atraso que continua: vai até o mínimo, nunca abaixo
    for (0..200) |_| {
        t += 30_000;
        f.sample(t, 150_000);
    }
    try testing.expectEqual(min_window, f.window);
    // a fila sumiu: volta a crescer
    for (0..100) |_| {
        t += 5_000;
        f.sample(t, 22_000);
    }
    try testing.expect(f.window > min_window);
}

test "bgflow: janela cheia espera; vazia sempre deixa um pedaço" {
    var f: Flow = .{ .window = 2 * chunk };
    try testing.expect(f.canSend(0));
    try testing.expect(f.canSend(chunk));
    try testing.expect(!f.canSend(2 * chunk));
    f.window = min_window;
    try testing.expect(f.canSend(0));
}
