//! Cancelamento de eco (SpeexDSP: filtro adaptativo MDF + supressão do eco
//! que sobra). Tira do microfone o som que saiu da caixa de som — as vozes da
//! sala e as transmissões que você assiste — pra quem não usa fone não fazer
//! os outros ouvirem a própria voz de volta.
//!
//! A referência é a saída do mixer, guardada num anel (a thread de saída
//! escreve, a do microfone lê). Ela tem que chegar ao cancelador ANTES do eco
//! aparecer no microfone (o filtro é causal), então o anel fica quase vazio:
//! uns 5 ms de folga, medidos pelo menor nível dos últimos 4 s (que não
//! depende do tamanho dos blocos de cada lado). O atraso de verdade — buffer
//! de saída + ar + buffer de entrada, uns 20–80 ms — o filtro (cauda de
//! 100 ms) descobre sozinho.
//!
//! Os dois dispositivos andam em relógios próprios (USB e placa onboard
//! chegam a ~100 ppm de diferença). Deixado solto, o eco "escorrega" devagar
//! em relação à referência e o filtro, correndo atrás, perde uns 15 dB. Então
//! a diferença é medida (regressão de quanto a saída produziu contra quanto o
//! microfone consumiu, no último minuto) e a referência é reamostrada nessa
//! proporção. Ajuste grosso no anel (que obriga o filtro a aprender de novo)
//! só quando secou ou passou de 10 ms: no começo, ou se algo travar.
const std = @import("std");
const sync = @import("sync.zig");
const sp = @cImport({
    @cInclude("speex/speex_echo.h");
    @cInclude("speex/speex_preprocess.h");
});

pub const rate = 48000;
/// 10 ms: o mesmo bloco do RNNoise.
pub const frame = 480;
/// Cauda do filtro: 100 ms. Mais longa cobre mais atraso, mas o filtro demora
/// muito mais pra aprender (medido com voz de verdade passando pelo Opus:
/// 200 ms chegava a 5 dB em 2 s de fala; 100 ms, a 17 dB).
const tail = rate / 10;
const ring_cap = rate / 2;
/// Folga depois de um ajuste.
const ring_target = rate * 5 / 1000;
/// Folga máxima: mais que isso arrisca a referência chegar depois do eco.
const ring_high = rate * 10 / 1000;
/// Uma janela = 50 leituras de 10 ms; o mínimo vale sobre as 8 últimas (4 s).
const window_pops = 50;
const windows = 8;

/// Pontos (um por janela) da regressão da deriva: 64 s; usa a partir de 20 s.
const drift_points = 128;
const drift_min_points = 40;
/// Ponto mais longe que isso da reta: algo travou, a medida recomeça.
const drift_break = rate * 20 / 1000;

/// Referência (mono) do que a caixa de som tocou.
pub const RefRing = struct {
    mutex: sync.Mutex = .{},
    buf: [ring_cap]f32 = undefined,
    r: usize = 0,
    len: usize = 0,
    // menor nível depois de uma leitura, por janela
    lows: [windows]usize = undefined,
    n_lows: usize = 0,
    cur_low: usize = std.math.maxInt(usize),
    pops: u32 = 0,
    win_pushes: u32 = 0, // escritas da saída na janela atual
    settle: u32 = 0, // janelas desde que a saída começou a tocar
    centered: bool = false, // já centrou depois que a saída começou
    pending: isize = 0, // ajuste a fazer na próxima leitura: > 0 tira amostras, < 0 põe silêncio
    // deriva entre os relógios
    pushed: u64 = 0, // amostras que a saída produziu
    delivered: u64 = 0, // amostras entregues ao microfone
    cur_gap: i64 = std.math.maxInt(i64), // menor (produzido - entregue) na janela
    pts_x: [drift_points]f64 = undefined,
    pts_y: [drift_points]f64 = undefined,
    n_pts: usize = 0,
    step: f64 = 1, // amostras do anel por amostra entregue (1 + deriva)
    frac: f64 = 0, // posição fracionária entre buf[r] e buf[r + 1]
    // diagnóstico
    stat: Stats = .{},

    pub const Stats = struct {
        pushes: u32 = 0,
        max_push: usize = 0,
        pops: u32 = 0,
        dry: usize = 0, // amostras de silêncio porque o anel secou
        inserted: usize = 0,
        dropped: usize = 0,
        max_level: usize = 0,
    };

    /// Diagnóstico desde a última chamada.
    pub fn takeStats(rg: *RefRing) Stats {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        const st = rg.stat;
        rg.stat = .{};
        return st;
    }

    /// Thread de saída: amostras estéreo intercaladas que acabaram de ser mixadas.
    pub fn pushStereo(rg: *RefRing, samples: []const f32) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            if (rg.len == ring_cap) {
                // ninguém lendo (microfone desligado): fica com o mais novo
                rg.r = (rg.r + 1) % ring_cap;
                rg.len -= 1;
            }
            rg.buf[(rg.r + rg.len) % ring_cap] = (samples[i] + samples[i + 1]) * 0.5;
            rg.len += 1;
        }
        rg.pushed += samples.len / 2;
        rg.win_pushes += 1;
        rg.stat.pushes += 1;
        rg.stat.max_push = @max(rg.stat.max_push, samples.len / 2);
        rg.stat.max_level = @max(rg.stat.max_level, rg.len);
    }

    /// Thread do microfone: as próximas `out.len` amostras (zeros se faltar).
    pub fn pop(rg: *RefRing, out: []f32) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        var dst = out;
        if (rg.pending > 0) {
            const d = @min(@as(usize, @intCast(rg.pending)), rg.len);
            rg.stat.dropped += d;
            rg.skip(d);
            rg.shiftLows(-@as(isize, @intCast(d)));
            rg.pending = 0;
        } else if (rg.pending < 0) {
            // silêncio no lugar de amostras que o anel tinha: ele fica mais cheio
            const k = @min(@as(usize, @intCast(-rg.pending)), dst.len, rg.len);
            rg.stat.inserted += k;
            @memset(dst[0..k], 0);
            dst = dst[k..];
            rg.shiftLows(@intCast(k));
            rg.pending += @intCast(k);
        }
        // reamostra na proporção dos relógios (interpolação linear: a deriva
        // é tão pequena que a posição fracionária quase não muda num bloco)
        var i: usize = 0;
        while (i < dst.len and rg.len >= 2) : (i += 1) {
            const a = rg.buf[rg.r];
            const b = rg.buf[(rg.r + 1) % ring_cap];
            dst[i] = a + (b - a) * @as(f32, @floatCast(rg.frac));
            rg.frac += rg.step;
            const adv = @floor(rg.frac);
            rg.frac -= adv;
            rg.skip(@min(@as(usize, @intFromFloat(adv)), rg.len));
        }
        @memset(dst[i..], 0); // secou
        rg.stat.dry += dst.len - i;
        rg.stat.pops += 1;
        rg.delivered += out.len;
        rg.cur_gap = @min(rg.cur_gap, @as(i64, @intCast(rg.pushed)) - @as(i64, @intCast(rg.delivered)));
        rg.cur_low = @min(rg.cur_low, rg.len);
        rg.pops += 1;
        if (rg.pops >= window_pops) rg.endWindow();
    }

    fn endWindow(rg: *RefRing) void {
        const playing = rg.win_pushes > 0;
        const cur_low = rg.cur_low;
        rg.pops = 0;
        rg.win_pushes = 0;
        rg.cur_low = std.math.maxInt(usize);
        if (!playing) {
            // a saída não está tocando (ainda não abriu, ou parou): quando
            // voltar, as medidas recomeçam do zero
            rg.n_lows = 0;
            rg.n_pts = 0;
            rg.pending = 0;
            rg.settle = 0;
            rg.centered = false;
            return;
        }
        rg.updateDrift();
        if (!rg.centered) {
            // a primeira janela com a saída tocando quase sempre pega o meio
            // da abertura; a segunda (0,5–1 s depois) já mostra o ritmo dos
            // dois lados. Centra nela, enquanto o filtro ainda não aprendeu nada
            rg.settle += 1;
            if (rg.settle < 2) return;
            rg.centered = true;
            rg.lows[0] = cur_low;
            rg.n_lows = 1;
            rg.pending = @as(isize, @intCast(cur_low)) - ring_target;
            return;
        }
        rg.lows[rg.n_lows % windows] = cur_low;
        rg.n_lows += 1;
        var low: usize = std.math.maxInt(usize);
        for (rg.lows[0..@min(rg.n_lows, windows)]) |l| low = @min(low, l);
        // depois, só quando secou ou encheu demais: volta pro alvo de uma vez
        if (low == 0 or low > ring_high) rg.pending = @as(isize, @intCast(low)) - ring_target;
    }

    /// Reta de (produzido - entregue) contra o entregue: a inclinação é a
    /// deriva entre os relógios.
    fn updateDrift(rg: *RefRing) void {
        const x: f64 = @floatFromInt(rg.delivered);
        const y: f64 = @floatFromInt(rg.cur_gap);
        rg.cur_gap = std.math.maxInt(i64);
        const n = @min(rg.n_pts, drift_points);
        if (n >= drift_min_points) {
            const fit = rg.line(n);
            if (@abs(y - (fit[0] + fit[1] * x)) > drift_break) rg.n_pts = 0; // travou: recomeça a medida
        }
        rg.pts_x[rg.n_pts % drift_points] = x;
        rg.pts_y[rg.n_pts % drift_points] = y;
        rg.n_pts += 1;
        const m = @min(rg.n_pts, drift_points);
        if (m < drift_min_points) return;
        const fit = rg.line(m);
        // só usa a medida quando ela é bem maior que o erro dela (3σ): com o
        // mesmo relógio dos dois lados, reamostrar pelo ruído só atrapalharia
        rg.step = if (@abs(fit[1]) > 3 * fit[2]) 1 + std.math.clamp(fit[1], -1e-3, 1e-3) else 1;
    }

    /// Mínimos quadrados sobre os `n` pontos guardados: { a, b, σ de b } de y = a + b·x.
    fn line(rg: *const RefRing, n: usize) [3]f64 {
        var mx: f64 = 0;
        var my: f64 = 0;
        for (rg.pts_x[0..n], rg.pts_y[0..n]) |x, y| {
            mx += x;
            my += y;
        }
        const nf: f64 = @floatFromInt(n);
        mx /= nf;
        my /= nf;
        var sxx: f64 = 0;
        var sxy: f64 = 0;
        for (rg.pts_x[0..n], rg.pts_y[0..n]) |x, y| {
            sxx += (x - mx) * (x - mx);
            sxy += (x - mx) * (y - my);
        }
        if (sxx == 0) return .{ my, 0, std.math.inf(f64) };
        const b = sxy / sxx;
        const a = my - b * mx;
        var sse: f64 = 0;
        for (rg.pts_x[0..n], rg.pts_y[0..n]) |x, y| sse += (y - a - b * x) * (y - a - b * x);
        return .{ a, b, @sqrt(sse / (nf - 2) / sxx) };
    }

    /// Quanto a saída anda mais rápido que o microfone, em ppm (0 até a medida
    /// ficar confiável).
    pub fn driftPpm(rg: *RefRing) f64 {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        return (rg.step - 1) * 1e6;
    }

    /// O nível mudou por correção nossa: as janelas guardadas mudam junto.
    fn shiftLows(rg: *RefRing, d: isize) void {
        for (rg.lows[0..@min(rg.n_lows, windows)]) |*l| {
            l.* = if (d < 0) l.* -| @as(usize, @intCast(-d)) else l.* + @as(usize, @intCast(d));
        }
        if (rg.cur_low != std.math.maxInt(usize)) {
            rg.cur_low = if (d < 0) rg.cur_low -| @as(usize, @intCast(-d)) else rg.cur_low + @as(usize, @intCast(d));
        }
    }

    /// Microfone abrindo: começa do que está tocando agora.
    pub fn clear(rg: *RefRing) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        rg.skip(rg.len);
        rg.n_lows = 0;
        rg.cur_low = std.math.maxInt(usize);
        rg.pops = 0;
        rg.pending = 0;
        rg.pushed = 0;
        rg.delivered = 0;
        rg.cur_gap = std.math.maxInt(i64);
        rg.n_pts = 0;
        rg.step = 1;
        rg.frac = 0;
        rg.win_pushes = 0;
        rg.settle = 0;
        rg.centered = false;
    }

    fn skip(rg: *RefRing, n: usize) void {
        rg.r = (rg.r + n) % ring_cap;
        rg.len -= n;
    }

    pub fn level(rg: *RefRing) usize {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        return rg.len;
    }
};

/// O que o mixer tocou (audio.zig escreve a cada bloco de saída).
pub var reference: RefRing = .{};

pub const Canceller = struct {
    echo: *sp.SpeexEchoState,
    pre: *sp.SpeexPreprocessState,

    pub fn init() !Canceller {
        const echo = sp.speex_echo_state_init(frame, tail) orelse return error.AecInit;
        errdefer sp.speex_echo_state_destroy(echo);
        var r: c_int = rate;
        _ = sp.speex_echo_ctl(echo, sp.SPEEX_ECHO_SET_SAMPLING_RATE, &r);
        const pre = sp.speex_preprocess_state_init(frame, rate) orelse return error.AecInit;
        // só a supressão do eco que sobra: ruído é com o RNNoise. O "denoise"
        // tem que ficar ligado (sem ele o preprocess não aplica ganho nenhum,
        // nem o do eco), mas com 0 dB de supressão de ruído. O VAD já vem
        // desligado (mexer nele imprime um aviso).
        var off: c_int = 0;
        _ = sp.speex_preprocess_ctl(pre, sp.SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &off);
        _ = sp.speex_preprocess_ctl(pre, sp.SPEEX_PREPROCESS_SET_AGC, &off);
        _ = sp.speex_preprocess_ctl(pre, sp.SPEEX_PREPROCESS_SET_DEREVERB, &off);
        _ = sp.speex_preprocess_ctl(pre, sp.SPEEX_PREPROCESS_SET_ECHO_STATE, echo);
        return .{ .echo = echo, .pre = pre };
    }

    pub fn deinit(cn: *Canceller) void {
        sp.speex_preprocess_state_destroy(cn.pre);
        sp.speex_echo_state_destroy(cn.echo);
    }

    /// Um bloco de 10 ms do microfone (float, ±1), com a referência tirada de `ref`.
    pub fn process(cn: *Canceller, mic: *const [frame]f32, ref: *const [frame]f32, out: *[frame]f32) void {
        var m: [frame]i16 = undefined;
        var r: [frame]i16 = undefined;
        var o: [frame]i16 = undefined;
        for (&m, mic) |*d, v| d.* = toI16(v);
        for (&r, ref) |*d, v| d.* = toI16(v);
        sp.speex_echo_cancellation(cn.echo, &m, &r, &o);
        _ = sp.speex_preprocess_run(cn.pre, &o);
        for (out, o) |*d, v| d.* = @as(f32, @floatFromInt(v)) / 32768;
    }

    /// Bloco do microfone com a referência do que acabou de tocar.
    pub fn processLive(cn: *Canceller, mic: *const [frame]f32, out: *[frame]f32) void {
        var ref: [frame]f32 = undefined;
        cn.processLiveRef(mic, out, &ref);
    }

    /// Igual, devolvendo também a referência usada.
    pub fn processLiveRef(cn: *Canceller, mic: *const [frame]f32, out: *[frame]f32, ref: *[frame]f32) void {
        reference.pop(ref);
        cn.process(mic, ref, out);
    }
};

fn toI16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v * 32767, -32768, 32767));
}
