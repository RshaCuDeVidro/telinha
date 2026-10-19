//! Cancelamento de eco (SpeexDSP: filtro adaptativo MDF + supressão do eco
//! que sobra). Tira do microfone o som que saiu da caixa de som — as vozes da
//! sala e as transmissões que você assiste — pra quem não usa fone não fazer
//! os outros ouvirem a própria voz de volta.
//!
//! A referência é a saída do mixer, guardada num anel (a thread de saída
//! escreve, a do microfone lê). Ela tem que chegar ao cancelador ANTES do eco
//! aparecer no microfone (o filtro é causal), e o eco tem que cair dentro da
//! cauda do filtro (100 ms). Quem cuida disso é o detector de atraso
//! (`DelayEstimator`): mede onde o eco está e, se precisar, atrasa ou adianta
//! a referência. O anel em si só guarda uns 5 ms de folga, posta quando ele
//! seca, e não mexe sozinho: todo ajuste obriga o filtro a aprender de novo.
//!
//! Os dois dispositivos andam em relógios próprios (USB e placa onboard
//! chegam a ~100 ppm de diferença). Deixado solto, o eco "escorrega" devagar
//! em relação à referência e o filtro, correndo atrás, perde uns 15 dB. Então
//! a diferença é medida (regressão de quanto a saída produziu contra quanto o
//! microfone consumiu, no último minuto) e a referência é reamostrada nessa
//! proporção.
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
const ring_cap = rate;
/// Folga que entra quando o anel seca.
const ring_target = rate * 5 / 1000;
/// Atraso extra que o detector de atraso pode pôr na referência (caixa
/// Bluetooth: 150–250 ms).
const max_base = rate * 400 / 1000;
/// Uma janela = 50 leituras de 10 ms (0,5 s): a cada uma, um ponto da deriva
/// e o menor nível do anel (os das 8 últimas limitam quanto dá pra adiantar
/// a referência sem secar).
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
    pending: isize = 0, // ajuste a fazer na próxima leitura: > 0 tira amostras, < 0 põe silêncio
    base: isize = 0, // atraso extra da referência (amostras), posto pelo detector de atraso
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
        level_sum: u64 = 0, // soma do nível depois de cada leitura (média = level_sum / pops)
        min_level: usize = std.math.maxInt(usize),
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
            // adianta a referência: tira de uma vez o que o anel tiver
            const d = @min(@as(usize, @intCast(rg.pending)), rg.len);
            rg.stat.dropped += d;
            rg.skip(d);
            rg.pending -= @intCast(d);
            if (rg.pending == 0) rg.restartLows();
        } else if (rg.pending < 0) {
            // atrasa: silêncio no lugar dela (o anel enche, já que nada sai)
            const k = @min(@as(usize, @intCast(-rg.pending)), dst.len);
            rg.stat.inserted += k;
            @memset(dst[0..k], 0);
            dst = dst[k..];
            rg.pending += @intCast(k);
            if (rg.pending == 0) rg.restartLows();
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
        rg.stat.level_sum += rg.len;
        rg.stat.min_level = @min(rg.stat.min_level, rg.len);
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
            return;
        }
        rg.updateDrift();
        if (rg.pending != 0) return; // ajuste em andamento: mede depois
        rg.lows[rg.n_lows % windows] = cur_low;
        rg.n_lows += 1;
        // Secou (o anel começa vazio, então isso acontece logo que a saída
        // começa a tocar; depois, só se ela parar e voltar): o que estava
        // guardado se perdeu, então põe de novo a folga mais o atraso extra
        // (um adiantamento se perde: o detector refaz se precisar). Fora isso
        // o anel não mexe sozinho: todo ajuste faz o filtro reaprender, e o
        // nível mínimo engana (com blocos grandes dos dois lados, o vale de
        // verdade aparece pouco). Quem cuida do alinhamento é o detector.
        if (cur_low == 0) {
            if (rg.base < 0) rg.base = 0;
            rg.pending = -(ring_target + rg.base);
        }
    }

    fn restartLows(rg: *RefRing) void {
        rg.n_lows = 0;
        rg.cur_low = std.math.maxInt(usize);
    }

    /// Atrasa (d > 0) ou adianta (d < 0) a referência: o detector de atraso
    /// achou o eco longe de onde o filtro procura. Adiantar gasta o que o
    /// anel tem guardado: no máximo até sobrar 1 ms no menor nível recente.
    /// Devolve quanto mudou de verdade.
    pub fn shift(rg: *RefRing, d: isize) isize {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        var real = @min(d, max_base - rg.base);
        if (real < 0) {
            var low: usize = rg.cur_low;
            for (rg.lows[0..@min(rg.n_lows, windows)]) |l| low = @min(low, l);
            var spare: isize = if (low == std.math.maxInt(usize)) 0 else @as(isize, @intCast(low)) - rate / 1000;
            if (spare < 0) spare = 0;
            if (real < -spare) real = -spare;
        }
        rg.base += real;
        rg.pending -= real;
        rg.restartLows();
        return real;
    }

    /// Atraso extra posto na referência, em ms.
    pub fn baseMs(rg: *RefRing) f32 {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        return @as(f32, @floatFromInt(rg.base)) / (rate / 1000);
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

    /// Microfone abrindo: começa do que está tocando agora. O atraso extra
    /// fica (é do caminho caixa → microfone, que não mudou).
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

/// Atraso grosso do eco, pela correlação dos envelopes de energia (1 ms por
/// ponto) do microfone com a referência. Caixa Bluetooth chega a 150–250 ms,
/// mais que a cauda do filtro; e mesmo com fio, quanto menos atraso sobrar pro
/// filtro cobrir, mais rápido ele aprende. Envelope não tem a ambiguidade do
/// tom da voz (que é periódico), e alguns ms de precisão bastam: o filtro
/// cobre o resto.
pub const DelayEstimator = struct {
    const sub = rate / 1000; // amostras por ponto do envelope (1 ms)
    const max_lag = 500;
    const neg = 30; // atrasos negativos medidos (até -30 ms): corr[neg + atraso]
    const n_lags = max_lag + neg + 1;
    const hist = max_lag + 1;
    // históricos dos envelopes, escritos duas vezes (em i e i + hist) pra ler
    // qualquer trecho sem dar a volta
    hm: [2 * hist]f32 = @splat(0),
    hr: [2 * hist]f32 = @splat(0),
    pos: usize = 0,
    mean_m: f32 = 0,
    mean_r: f32 = 0,
    corr: [n_lags]f32 = @splat(0),
    e_m: f32 = 0,
    e_r: f32 = 0,
    blocks: u32 = 0,
    active: u32 = 0, // blocos com a caixa tocando, desde a última avaliação
    candidate: ?i32 = null,

    /// Um bloco de 10 ms; devolve o atraso do eco (ms) quando confirmado em
    /// duas avaliações seguidas (a cada 0,5 s).
    pub fn feed(de: *DelayEstimator, mic: *const [frame]f32, ref: *const [frame]f32) ?i32 {
        var far: f32 = 0;
        for (0..frame / sub) |k| {
            var em: f32 = 0;
            var er: f32 = 0;
            for (mic[k * sub ..][0..sub], ref[k * sub ..][0..sub]) |a, b| {
                em += a * a;
                er += b * b;
            }
            far += er;
            // envelope sem a média lenta (passa-alta ~1,6 Hz): fica a
            // modulação das sílabas, que é o que identifica o atraso
            const am = @sqrt(em / sub);
            const ar = @sqrt(er / sub);
            de.mean_m += 0.01 * (am - de.mean_m);
            de.mean_r += 0.01 * (ar - de.mean_r);
            const xm = am - de.mean_m;
            const xr = ar - de.mean_r;
            de.hm[de.pos] = xm;
            de.hm[de.pos + hist] = xm;
            de.hr[de.pos] = xr;
            de.hr[de.pos + hist] = xr;
            const now = de.pos + hist; // hm[now - l] = l ms atrás
            // atraso l ≥ 0: microfone agora × referência de l ms atrás
            for (0..max_lag + 1) |l| de.corr[neg + l] += xm * de.hr[now - l];
            // atraso negativo (eco antes da referência): microfone de l ms atrás × referência agora
            for (1..neg + 1) |l| de.corr[neg - l] += de.hm[now - l] * xr;
            de.e_m += xm * xm;
            de.e_r += xr * xr;
            de.pos = (de.pos + 1) % hist;
        }
        // memória de ~2 s
        for (&de.corr) |*v| v.* *= 0.995;
        de.e_m *= 0.995;
        de.e_r *= 0.995;
        if (far > frame * 1e-6) de.active += 1; // caixa tocando (> -60 dBFS)
        de.blocks += 1;
        if (de.blocks < 50) return null;
        const active = de.active;
        de.blocks = 0;
        de.active = 0;
        if (active < 25 or de.e_m <= 0 or de.e_r <= 0) return null; // caixa quieta: nada a medir
        var best: usize = 0;
        for (de.corr, 0..) |v, i| if (v > de.corr[best]) {
            best = i;
        };
        const norm = 1 / @sqrt(de.e_m * de.e_r);
        const rho = de.corr[best] * norm;
        // pico forte e único: longe dele (±30 ms), nada parecido
        var other: f32 = 0;
        for (de.corr, 0..) |v, i| if (i + 30 < best or i > best + 30) {
            other = @max(other, v);
        };
        if (rho < 0.4 or other * norm > 0.8 * rho) {
            de.candidate = null;
            return null;
        }
        const lag = @as(i32, @intCast(best)) - neg;
        last_measured.store(lag, .monotonic);
        if (de.candidate) |c| if (@abs(c - lag) <= 4) return lag;
        de.candidate = lag;
        return null;
    }
};

/// Diagnóstico: última medida de atraso do eco (ms, confirmada ou não).
pub var last_measured: std.atomic.Value(i32) = .init(std.math.minInt(i32));

/// Onde o eco deve ficar pro filtro (ms depois da referência) quando precisar
/// mexer: um pouco depois do começo da cauda, com margem se a medida errou.
const echo_want_ms = 15;
/// Eco entre esses atrasos: o filtro (cauda de 100 ms) dá conta, deixa como
/// está. Antes disso ele não consegue (o eco chegaria antes da referência);
/// depois, o resto do eco (a reverberação) não caberia na cauda.
const echo_min_ms = 1;
const echo_max_ms = 40;

pub const Canceller = struct {
    echo: *sp.SpeexEchoState,
    pre: *sp.SpeexPreprocessState,
    est: DelayEstimator = .{},

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
        if (cn.est.feed(mic, ref)) |lag| cn.realign(lag);
        cn.process(mic, ref, out);
    }

    /// O eco está `lag` ms depois da referência: se estiver longe de onde o
    /// filtro procura, muda o atraso da referência e o filtro recomeça.
    fn realign(cn: *Canceller, lag: i32) void {
        if (lag >= echo_min_ms and lag <= echo_max_ms) return;
        const moved = reference.shift(@as(isize, lag - echo_want_ms) * (rate / 1000));
        cn.est = .{}; // os atrasos medidos eram relativos ao alinhamento antigo
        if (moved != 0) sp.speex_echo_state_reset(cn.echo);
    }
};

fn toI16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v * 32767, -32768, 32767));
}
