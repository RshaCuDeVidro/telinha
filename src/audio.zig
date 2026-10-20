//! Áudio das transmissões: captura + Opus de quem transmite, e mixer de quem
//! assiste (uma saída só, somando todas as transmissões assistidas).
const std = @import("std");
const sync = @import("sync.zig");
const aec = @import("aec.zig");
pub const c = @cImport({
    @cInclude("audio.h");
    @cInclude("opus.h");
});
const gpa = std.heap.c_allocator;

pub const rate = 48000;
pub const channels = 2;
/// 10 ms por pacote: latência baixa e o Opus ainda comprime bem.
pub const frame_len = 480;
const bitrate = 96_000;

/// Buffer anti-oscilação: só começa a tocar com 50 ms guardados.
pub const target_samples = rate / 20 * channels;
/// Mais que isso guardado = atrasou (rede engasgou e depois despejou): pula pra frente.
pub const max_samples = target_samples * 4;

/// Áudio recebido de uma transmissão (thread de rede escreve, o mixer lê).
pub const Ring = struct {
    mutex: sync.Mutex = .{},
    buf: []f32 = &.{},
    r: usize = 0,
    len: usize = 0,
    primed: bool = false,
    volume: f32 = 1.0,
    muted: bool = false,
    level: f32 = 0, // nível recente (0..1), pra UI mostrar quem está fazendo barulho
    last_write_us: u64 = 0, // quando chegou som pela última vez

    pub fn deinit(rg: *Ring) void {
        gpa.free(rg.buf);
    }

    // a interface mexe nesses campos enquanto o mixer lê (thread de áudio)
    pub fn setMuted(rg: *Ring, m: bool) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        rg.muted = m;
    }

    pub fn isMuted(rg: *Ring) bool {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        return rg.muted;
    }

    /// 0..2 (o resto é cortado: NaN/infinito estragaria a mixagem inteira).
    pub fn setVolume(rg: *Ring, v: f32) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        rg.volume = if (std.math.isNan(v)) 1 else std.math.clamp(v, 0, 2);
    }

    pub fn getVolume(rg: *Ring) f32 {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        return rg.volume;
    }

    /// Nível recente (zero se nada chegou nos últimos 300 ms). Não depende de
    /// quantos quadros a interface desenha (ela só redesenha quando precisa).
    pub fn takeLevel(rg: *Ring) f32 {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        if (sync.nowUs() -| rg.last_write_us > 300_000) return 0;
        return rg.level;
    }

    pub fn write(rg: *Ring, samples: []const f32) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        if (rg.buf.len == 0) {
            rg.buf = gpa.alloc(f32, rate * channels) catch return; // 1 s
        }
        const cap = rg.buf.len;
        var src = samples;
        if (src.len > cap) src = src[src.len - cap ..];
        // sem espaço: descarta o mais velho
        if (rg.len + src.len > cap) {
            const drop = rg.len + src.len - cap;
            rg.r = (rg.r + drop) % cap;
            rg.len -= drop;
        }
        var w = (rg.r + rg.len) % cap;
        var peak: f32 = 0;
        for (src) |v| {
            rg.buf[w] = v;
            w += 1;
            if (w == cap) w = 0;
            peak = @max(peak, @abs(v));
        }
        rg.len += src.len;
        rg.level = @max(peak, rg.level * 0.9);
        rg.last_write_us = sync.nowUs();
        // a saída estava parada (silêncio longo): liga de novo
        if (mixer.paused.load(.acquire)) mixer.wantResume();
    }

    /// Soma até `out.len` amostras em `out`.
    pub fn mixInto(rg: *Ring, out: []f32, gain: f32) void {
        rg.mutex.lock();
        defer rg.mutex.unlock();
        if (rg.buf.len == 0) return;
        if (!rg.primed) {
            if (rg.len < target_samples) return;
            rg.primed = true;
        }
        // atrasou demais: joga fora o excesso e volta pro alvo
        if (rg.len > max_samples) {
            const drop = rg.len - target_samples;
            rg.r = (rg.r + drop) % rg.buf.len;
            rg.len -= drop;
        }
        const n = @min(rg.len, out.len);
        const cap = rg.buf.len;
        for (0..n) |i| out[i] += rg.buf[(rg.r + i) % cap] * gain;
        rg.r = (rg.r + n) % cap;
        rg.len -= n;
        // acabou o áudio no meio: espera encher de novo antes de voltar a tocar
        if (n < out.len) rg.primed = false;
    }
};

/// Saída de som de quem assiste. Abre na primeira transmissão com áudio.
pub const Mixer = struct {
    mutex: sync.Mutex = .{},
    rings: std.ArrayList(*Ring) = .empty,
    dev: ?*c.audio_dev = null,
    failed: bool = false,
    opening: bool = false, // alguém está abrindo o dispositivo (fora do lock)
    /// Quem transmite áudio no Linux escuta a si mesmo na captura: silencia a saída (sem eco).
    self_mute: std.atomic.Value(bool) = .init(false),
    /// "Surdo" (como no Discord): não toca nada da sala, nem voz nem transmissão.
    deaf: std.atomic.Value(bool) = .init(false),
    /// Saída parada por silêncio (ver housekeep) e quando tocou algo por último.
    paused: std.atomic.Value(bool) = .init(false),
    last_sound_us: std.atomic.Value(u64) = .init(0),
    pause_mutex: sync.Mutex = .{}, // parar/retomar não podem se cruzar

    /// Uma vez por quadro da interface: 5 s sem nada pra tocar → para o
    /// dispositivo (a saída aberta custa CPU e não deixa a placa/fone dormir).
    pub fn housekeep(m: *Mixer) void {
        if (m.paused.load(.acquire)) return;
        const last = m.last_sound_us.load(.monotonic);
        if (last == 0 or sync.nowUs() -| last < 5_000_000) return;
        m.pause_mutex.lock();
        defer m.pause_mutex.unlock();
        m.mutex.lock();
        const dev = m.dev;
        m.mutex.unlock();
        const d = dev orelse return;
        if (c.audio_pause(d) == 0) m.paused.store(true, .release);
    }

    /// Chegou som com a saída parada: liga (fora do callback de áudio).
    fn wantResume(m: *Mixer) void {
        m.pause_mutex.lock();
        defer m.pause_mutex.unlock();
        if (!m.paused.load(.acquire)) return;
        m.mutex.lock();
        const dev = m.dev;
        m.mutex.unlock();
        const d = dev orelse return;
        m.last_sound_us.store(sync.nowUs(), .monotonic);
        _ = c.audio_resume(d);
        m.paused.store(false, .release);
    }

    pub fn add(m: *Mixer, rg: *Ring) void {
        m.mutex.lock();
        // TELINHA_SEM_SOM=1: recebe e decodifica, mas não toca (testes)
        if (m.dev == null and getenv("TELINHA_SEM_SOM") != null) m.failed = true;
        const need_open = m.dev == null and !m.failed and !m.opening;
        if (need_open) m.opening = true;
        if (std.mem.findScalar(*Ring, m.rings.items, rg) == null) m.rings.append(gpa, rg) catch {};
        m.mutex.unlock();
        // abrir a saída leva dezenas de ms: numa thread à parte (quem chama
        // costuma ser a thread de rede, que não pode parar de receber)
        if (need_open) sync.spawn(openOutput, .{m}) catch openOutput(m);
    }

    fn openOutput(m: *Mixer) void {
        var err: [256]u8 = undefined;
        const d = c.audio_output_open(onPlay, m, &err, err.len);
        m.mutex.lock();
        if (d) |dev| m.dev = dev else m.failed = true;
        m.opening = false;
        m.mutex.unlock();
    }

    pub fn remove(m: *Mixer, rg: *Ring) void {
        m.mutex.lock();
        defer m.mutex.unlock();
        if (std.mem.findScalar(*Ring, m.rings.items, rg)) |i| _ = m.rings.swapRemove(i);
    }

    fn onPlay(user: ?*anyopaque, samples: [*c]f32, frames: c_int) callconv(.c) void {
        const m: *Mixer = @ptrCast(@alignCast(user));
        const out = samples[0..@intCast(frames * channels)];
        @memset(out, 0);
        m.mutex.lock();
        defer m.mutex.unlock();
        const self_mute = m.self_mute.load(.monotonic);
        const deaf = m.deaf.load(.monotonic);
        var any = false;
        for (m.rings.items) |rg| {
            if (rg.len > 0) any = true;
            // os avisos tocam mesmo surdo (é assim que se ouve o "surdo ligado")
            const gain: f32 = if (rg.muted or self_mute or (deaf and rg != &chime_ring)) 0 else rg.volume;
            rg.mixInto(out, gain);
        }
        if (any or m.last_sound_us.load(.monotonic) == 0) m.last_sound_us.store(sync.nowUs(), .monotonic);
        for (out) |*v| v.* = std.math.clamp(v.*, -1.0, 1.0);
        // o que vai sair na caixa de som: referência pro cancelamento de eco
        aec.reference.pushStereo(out);
    }
};

pub var mixer: Mixer = .{};

/// Sons de aviso (alguém entrou/saiu, ao vivo, microfone): sintetizados na
/// hora, baixinhos, pelo mesmo mixer.
pub const Chime = enum { join, leave, live, mic_on, mic_off };

var chime_ring: Ring = .{};
var chime_registered = false;

pub fn playChime(kind: Chime) void {
    const notes: []const f32 = switch (kind) {
        .join => &.{ 659.3, 987.8 }, // mi → si (subindo)
        .leave => &.{ 987.8, 587.3 }, // si → ré (descendo)
        .live => &.{ 523.3, 659.3, 784.0 }, // dó-mi-sol
        .mic_on => &.{880.0},
        .mic_off => &.{440.0},
    };
    const note_len = rate * 55 / 1000;
    var buf: [note_len * 3 * channels]f32 = undefined;
    var n: usize = 0;
    for (notes) |f| {
        for (0..note_len) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / rate;
            // ataque de 4 ms e decaimento suave: sem estalo
            const env = @min(1.0, t / 0.004) * @exp(-t * 28);
            const v = 0.14 * env * (@sin(2 * std.math.pi * f * t) + 0.25 * @sin(4 * std.math.pi * f * t));
            buf[n] = v;
            buf[n + 1] = v;
            n += 2;
        }
    }
    chime_ring.write(buf[0..n]);
    if (!chime_registered) {
        chime_registered = true;
        mixer.add(&chime_ring);
    }
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Decodifica os pacotes de uma transmissão.
pub const Decoder = struct {
    dec: *c.OpusDecoder,
    pcm: [5760 * channels]f32 = undefined,

    pub fn init() !Decoder {
        var err: c_int = 0;
        const d = c.opus_decoder_create(rate, channels, &err) orelse return error.OpusInit;
        return .{ .dec = d };
    }
    pub fn deinit(d: *Decoder) void {
        c.opus_decoder_destroy(d.dec);
    }
    /// Recupera o pacote anterior (perdido) pela cópia leve (FEC) que veio
    /// dentro deste. `frames`: o tamanho do perdido (amostras por canal).
    pub fn decodeFec(d: *Decoder, packet: []const u8, frames: usize) ![]const f32 {
        const n = c.opus_decode_float(d.dec, packet.ptr, @intCast(packet.len), &d.pcm, @intCast(frames), 1);
        if (n < 0) return error.OpusDecode;
        return d.pcm[0 .. @as(usize, @intCast(n)) * channels];
    }
    /// Pacote perdido sem nada pra recuperar: o Opus inventa um som parecido (PLC).
    pub fn conceal(d: *Decoder, frames: usize) ![]const f32 {
        const n = c.opus_decode_float(d.dec, null, 0, &d.pcm, @intCast(frames), 0);
        if (n < 0) return error.OpusDecode;
        return d.pcm[0 .. @as(usize, @intCast(n)) * channels];
    }
    /// Retorna as amostras decodificadas (válidas até a próxima chamada).
    pub fn decode(d: *Decoder, packet: []const u8) ![]const f32 {
        const n = c.opus_decode_float(d.dec, packet.ptr, @intCast(packet.len), &d.pcm, 5760, 0);
        if (n < 0) return error.OpusDecode;
        return d.pcm[0 .. @as(usize, @intCast(n)) * channels];
    }
};

/// Captura o som do computador e entrega pacotes Opus de 10 ms.
/// Programas tocando som agora (pra escolher de quem compartilhar o áudio).
pub fn listApps(out: []c.audio_app) usize {
    return @intCast(@max(0, c.audio_list_apps(out.ptr, @intCast(out.len))));
}

pub const Sender = struct {
    dev: ?*c.audio_dev = null,
    mix: ?*MixCapture = null, // Windows, "tudo menos alguns programas"
    exclude_ignored: bool = false, // pediu pra excluir, mas o Windows é antigo demais
    enc: *c.OpusEncoder,
    pending: [frame_len * channels]f32 = undefined,
    n_pending: usize = 0,
    packet: [1500]u8 = undefined,
    on_packet: *const fn (ctx: *anyopaque, packet: []const u8) void,
    ctx: *anyopaque,

    /// De quem é o som: tudo (menos o telinha) ou um programa só.
    pub const Only = struct {
        app: []const u8 = "", // nome, como em listApps
        pid: u32 = 0, // esse processo e os filhos (janela compartilhada no Windows)
        exclude: []const u8 = "", // quando é "tudo": esses programas ficam de fora (nomes separados por \n)
    };

    pub fn create(ctx: *anyopaque, on_packet: *const fn (ctx: *anyopaque, packet: []const u8) void, only: Only, err: []u8) !*Sender {
        @memset(err, 0);
        var e: c_int = 0;
        const enc = c.opus_encoder_create(rate, channels, c.OPUS_APPLICATION_RESTRICTED_LOWDELAY, &e) orelse return error.OpusInit;
        errdefer c.opus_encoder_destroy(enc);
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, bitrate));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 6));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_DTX_REQUEST, @as(c_int, 1)); // silêncio quase não gasta banda
        const s = try gpa.create(Sender);
        s.* = .{ .enc = enc, .on_packet = on_packet, .ctx = ctx };
        const everything = only.app.len == 0 and only.pid == 0;
        if (sync.is_windows and everything and only.exclude.len > 0) {
            // o WASAPI só exclui um processo (o telinha): mistura um por programa
            if (c.audio_process_loopback_ok() != 0) {
                s.mix = MixCapture.start(s, onCapture, only.exclude) catch {
                    gpa.destroy(s);
                    return error.AudioCapture;
                };
                return s;
            }
            s.exclude_ignored = true;
        }
        var app_z: [64]u8 = [_]u8{0} ** 64;
        @memcpy(app_z[0..@min(only.app.len, 63)], only.app[0..@min(only.app.len, 63)]);
        var excl_z: [512]u8 = [_]u8{0} ** 512;
        @memcpy(excl_z[0..@min(only.exclude.len, 511)], only.exclude[0..@min(only.exclude.len, 511)]);
        s.dev = c.audio_capture_open(onCapture, s, &app_z, only.pid, &excl_z, err.ptr, @intCast(err.len)) orelse {
            gpa.destroy(s);
            return error.AudioCapture;
        };
        return s;
    }

    /// A captura também pega o que o próprio app toca (jeito antigo, sem
    /// PipeWire/Windows antigo): quem transmite precisa silenciar o que ouve.
    pub fn hearsSelf(s: *const Sender) bool {
        if (s.mix != null) return false;
        return c.audio_capture_hears_self(s.dev) != 0;
    }

    pub fn destroy(s: *Sender) void {
        if (s.mix) |m| m.destroy();
        if (s.dev) |d| c.audio_close(d); // para o callback antes de liberar
        c.opus_encoder_destroy(s.enc);
        gpa.destroy(s);
    }

    fn onCapture(user: ?*anyopaque, samples: [*c]const f32, frames: c_int) callconv(.c) void {
        const s: *Sender = @ptrCast(@alignCast(user));
        var src = samples[0..@intCast(frames * channels)];
        while (src.len > 0) {
            const take = @min(src.len, s.pending.len - s.n_pending);
            @memcpy(s.pending[s.n_pending..][0..take], src[0..take]);
            s.n_pending += take;
            src = src[take..];
            if (s.n_pending == s.pending.len) {
                s.n_pending = 0;
                const n = c.opus_encode_float(s.enc, &s.pending, frame_len, &s.packet, s.packet.len);
                // DTX: pacotes de 1-2 bytes são silêncio, não precisa mandar
                if (n > 2) s.on_packet(s.ctx, s.packet[0..@intCast(n)]);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Windows: tudo menos o telinha e os programas excluídos. O loopback do WASAPI
// só exclui um processo por captura (o telinha); aqui é uma captura por
// programa tocando (modo "só esse processo") e a mistura delas, a cada 10 ms.
// Só existe quando há exclusões; sem elas é a captura de sempre.

const mix_ring = rate / 2; // 500 ms por programa
const mix_prebuffer = rate / 50; // 20 ms guardados antes de entrar na mistura
const mix_max_latency = rate / 10; // mais que 100 ms guardados: pula pra frente
const mix_max = 16;

/// `name` está na lista (nomes separados por \n, sem diferença de maiúscula)?
pub fn inList(list: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |item| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item, " \r"), name)) return true;
    return false;
}

/// O som de um programa: a captura escreve, o misturador lê (cada um mexe só
/// no próprio índice).
pub const MixSource = struct {
    buf: [mix_ring * channels]f32 = undefined,
    w: std.atomic.Value(usize) = .init(0), // quadros escritos (total)
    r: usize = 0, // quadros lidos (só o misturador)
    primed: bool = false,
    dev: ?*c.audio_dev = null,
    pid: u32 = 0,
    missing: u8 = 0, // listagens seguidas sem esse programa

    pub fn push(s: *MixSource, samples: []const f32) void {
        var w = s.w.load(.monotonic);
        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            const at = (w % mix_ring) * channels;
            s.buf[at] = samples[i];
            s.buf[at + 1] = samples[i + 1];
            w += 1;
        }
        s.w.store(w, .release);
    }

    /// Soma até out.len/2 quadros em `out`. false = não tinha nada pra somar.
    pub fn mixInto(s: *MixSource, out: []f32) bool {
        const w = s.w.load(.acquire);
        var avail = w - s.r;
        if (!s.primed) {
            if (avail < mix_prebuffer) return false;
            s.primed = true;
        }
        // relógios diferentes (ou o misturador atrasou): fica perto do fim
        if (avail > mix_max_latency) {
            s.r = w - mix_prebuffer;
            avail = mix_prebuffer;
        }
        const want = out.len / channels;
        // acabou o que tinha: silêncio e junta de novo (nada de meio quadro, que estala)
        if (avail < want) {
            s.primed = false;
            return false;
        }
        // o relógio da placa e o daqui nunca batem: mantém ~20 ms guardados.
        // Sobrando, lê uma amostra a mais (pula uma); faltando, uma a menos
        // (repete uma). Inaudível, e a latência não anda.
        const after = avail - want;
        const src: usize = if (after > mix_prebuffer * 2) want + 1 else if (after < mix_prebuffer / 2) want - 1 else want;
        for (0..want) |k| {
            const at = ((s.r + k * src / want) % mix_ring) * channels;
            out[k * 2] += s.buf[at];
            out[k * 2 + 1] += s.buf[at + 1];
        }
        s.r += src;
        return true;
    }

    fn onCapture(user: ?*anyopaque, samples: [*c]const f32, frames: c_int) callconv(.c) void {
        const s: *MixSource = @ptrCast(@alignCast(user));
        s.push(samples[0..@intCast(frames * channels)]);
    }
};

pub const MixCapture = struct {
    on_capture: *const fn (?*anyopaque, [*c]const f32, c_int) callconv(.c) void,
    user: *anyopaque,
    exclude: [512]u8 = undefined,
    exclude_len: usize = 0,
    sources: [mix_max]?*MixSource = [_]?*MixSource{null} ** mix_max,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(user: *anyopaque, on_capture: *const fn (?*anyopaque, [*c]const f32, c_int) callconv(.c) void, exclude: []const u8) !*MixCapture {
        const m = try gpa.create(MixCapture);
        m.* = .{ .on_capture = on_capture, .user = user };
        m.exclude_len = @min(exclude.len, m.exclude.len);
        @memcpy(m.exclude[0..m.exclude_len], exclude[0..m.exclude_len]);
        m.thread = std.Thread.spawn(.{}, run, .{m}) catch |e| {
            gpa.destroy(m);
            return e;
        };
        return m;
    }

    pub fn destroy(m: *MixCapture) void {
        m.stop.store(true, .release);
        if (m.thread) |t| t.join();
        for (&m.sources) |*sl| if (sl.*) |s| {
            if (s.dev) |d| c.audio_close(d);
            gpa.destroy(s);
            sl.* = null;
        };
        gpa.destroy(m);
    }

    /// Um quadro de 10 ms: soma o que cada programa tem e entrega.
    pub fn tick(m: *MixCapture, out: *[frame_len * channels]f32) bool {
        @memset(out, 0);
        var any = false;
        for (m.sources) |maybe| if (maybe) |s| {
            if (s.mixInto(out)) any = true;
        };
        if (!any) return false;
        for (out) |*x| x.* = std.math.clamp(x.*, -1.0, 1.0);
        return true;
    }

    fn run(m: *MixCapture) void {
        sync.nameThread("mistura-som");
        var out: [frame_len * channels]f32 = undefined;
        var next_list: u64 = 0;
        var next_tick = sync.nowUs();
        while (!m.stop.load(.acquire)) {
            const now = sync.nowUs();
            if (now >= next_list) {
                m.refresh();
                next_list = now + 1_000_000;
            }
            if (m.tick(&out)) m.on_capture(m.user, &out, frame_len);
            next_tick += 10_000;
            const t = sync.nowUs();
            if (next_tick > t) {
                sync.sleepMs(@intCast((next_tick - t + 999) / 1000));
            } else if (t - next_tick > 100_000) next_tick = t; // atrasou demais: recomeça o relógio
        }
    }

    /// Abre a captura de quem começou a tocar (e não está excluído) e fecha a
    /// de quem sumiu da lista faz 3 s.
    fn refresh(m: *MixCapture) void {
        var excl_z: [513]u8 = undefined;
        @memcpy(excl_z[0..m.exclude_len], m.exclude[0..m.exclude_len]);
        excl_z[m.exclude_len] = 0;
        var pids: [32]u32 = undefined;
        const n: usize = @intCast(@max(0, c.audio_mix_pids(&excl_z, &pids, pids.len)));
        var seen = [_]bool{false} ** mix_max;
        for (pids[0..n]) |pid| {
            const have = for (m.sources, 0..) |maybe, i| {
                if (maybe) |s| if (s.pid == pid) break i;
            } else null;
            if (have) |i| {
                seen[i] = true;
                continue;
            }
            const slot = for (m.sources, 0..) |maybe, i| {
                if (maybe == null) break i;
            } else continue;
            const s = gpa.create(MixSource) catch continue;
            s.* = .{ .pid = pid };
            var err: [128]u8 = [_]u8{0} ** 128;
            s.dev = c.audio_capture_open(MixSource.onCapture, s, "", pid, null, &err, err.len);
            if (s.dev == null) {
                if (sync.debugOn()) std.debug.print("[telinha] som do pid {d}: {s}\n", .{ pid, std.mem.sliceTo(&err, 0) });
                gpa.destroy(s);
                continue;
            }
            m.sources[slot] = s;
            seen[slot] = true;
        }
        for (&m.sources, 0..) |*sl, i| if (sl.*) |s| {
            if (seen[i]) {
                s.missing = 0;
            } else {
                s.missing += 1;
                if (s.missing >= 3) {
                    if (s.dev) |d| c.audio_close(d);
                    gpa.destroy(s);
                    sl.* = null;
                }
            }
        };
    }
};

test "lista de exclusão do som" {
    try std.testing.expect(inList("Discord\nspotify", "discord"));
    try std.testing.expect(inList("Discord\nspotify", "Spotify"));
    try std.testing.expect(!inList("Discord\nspotify", "Disc"));
    try std.testing.expect(!inList("", "Discord"));
    try std.testing.expect(!inList("Discord", ""));
}

test "mistura do som por programa: espera juntar, soma, pula pra frente quando atrasa" {
    const a = try gpa.create(MixSource);
    defer gpa.destroy(a);
    a.* = .{};
    const b = try gpa.create(MixSource);
    defer gpa.destroy(b);
    b.* = .{};
    var out: [frame_len * channels]f32 = undefined;
    var chunk: [frame_len * channels]f32 = undefined;
    // pouco guardado: ainda não entra
    @memset(&chunk, 0.25);
    a.push(chunk[0 .. 240 * channels]);
    @memset(&out, 0);
    try std.testing.expect(!a.mixInto(&out));
    // com 20 ms guardados entra; os dois somam
    a.push(chunk[0 .. 480 * channels]);
    a.push(chunk[0 .. 240 * channels]);
    @memset(&chunk, 0.5);
    b.push(&chunk);
    b.push(&chunk);
    @memset(&out, 0);
    try std.testing.expect(a.mixInto(&out));
    try std.testing.expect(b.mixInto(&out));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), out[out.len - 1], 1e-6);
    // atrasou (500 ms guardados): pula pra ficar com só 20 ms
    for (0..50) |_| b.push(&chunk);
    @memset(&out, 0);
    try std.testing.expect(b.mixInto(&out));
    try std.testing.expectEqual(mix_prebuffer - frame_len, b.w.load(.monotonic) - b.r);
    // acabando: repete uma amostra (sobra pouco) e depois silêncio inteiro, sem meio quadro
    @memset(&out, 0);
    try std.testing.expect(b.mixInto(&out)); // 480 guardados → lê 479
    try std.testing.expectEqual(@as(usize, 1), b.w.load(.monotonic) - b.r);
    @memset(&out, 0);
    try std.testing.expect(!b.mixInto(&out));
    try std.testing.expectEqual(@as(f32, 0), out[0]);
    // sobrando (placa adiantada): lê uma a mais por quadro
    const c2 = try gpa.create(MixSource);
    defer gpa.destroy(c2);
    c2.* = .{};
    for (0..6) |_| c2.push(&chunk); // 60 ms
    @memset(&out, 0);
    try std.testing.expect(c2.mixInto(&out));
    try std.testing.expectEqual(@as(usize, frame_len + 1), c2.r);
}
