//! Voz da sala (tipo Discord): microfone → cancelamento de eco (SpeexDSP) →
//! supressão de ruído (RNNoise) → portão de voz → Opus → sala. Quem recebe
//! guarda um anel por pessoa no mixer de audio.zig (o mesmo das transmissões).
//!
//! O portão usa a probabilidade de voz do próprio RNNoise: abre quando ela
//! passa da sensibilidade e fica aberto 250 ms depois da última sílaba. Com ele
//! fechado não sai pacote nenhum (zero banda).
const std = @import("std");
const audio = @import("audio.zig");
const aec = @import("aec.zig");
const c = audio.c;
const rn = @cImport(@cInclude("rnnoise.h"));
const gpa = std.heap.c_allocator;

pub const rate = 48000;
/// 20 ms por pacote: o padrão de VoIP (o RNNoise trabalha em blocos de 10 ms).
pub const frame_samples = 960;
const block = 480;
const bitrate = 40_000;
/// Depois da última sílaba, o portão fica aberto mais esse tanto (blocos de 10 ms).
const hangover_blocks = 25;

pub const Options = struct {
    /// Nome do microfone (vazio = padrão do sistema).
    device: []const u8 = "",
    noise_suppression: bool = true,
    /// Tira do microfone o que saiu da caixa de som (pra quem não usa fone).
    echo_cancellation: bool = true,
    /// 0..1: quanto menor, mais fácil o portão abrir.
    sensitivity: f32 = 0.5,
};

/// Recebe cada pacote Opus pronto (na thread de áudio).
pub const PacketFn = *const fn (ctx: *anyopaque, packet: []const u8) void;

pub const Mic = struct {
    dev: ?*c.audio_dev = null,
    enc: *c.OpusEncoder,
    rnn: ?*rn.DenoiseState,
    echo: ?aec.Canceller = null,
    threshold_bits: std.atomic.Value(u32), // f32: a interface muda com o microfone aberto
    on_packet: PacketFn,
    ctx: *anyopaque,

    in_buf: [block]f32 = undefined,
    n_in: usize = 0,
    out_buf: [frame_samples]f32 = undefined,
    n_out: usize = 0,
    packet: [1500]u8 = undefined,
    hang: u32 = 0,
    speech_run: u32 = 0, // blocos seguidos com voz
    far_hold: u32 = 0, // blocos desde que a caixa tocou algo (o eco chega depois e dura a cauda)
    was_open: bool = false,

    /// Pra interface: falando agora (portão aberto) e nível do microfone (0..1).
    speaking: std.atomic.Value(bool) = .init(false),
    level_bits: std.atomic.Value(u32) = .init(0),
    // diagnóstico do eco: energia antes/depois do cancelador, a cada 1 s
    e_in: f64 = 0,
    e_out: f64 = 0,
    e_ref: f64 = 0,
    e_blocks: u32 = 0,
    stats_bits: [3]std.atomic.Value(u32) = .{ .init(0), .init(0), .init(0) },

    pub fn open(opts: Options, ctx: *anyopaque, on_packet: PacketFn, err: []u8) !*Mic {
        return create(opts, ctx, on_packet, err, true);
    }

    /// Sem dispositivo: as amostras entram por `feed` (testes).
    pub fn openDetached(opts: Options, ctx: *anyopaque, on_packet: PacketFn) !*Mic {
        var err: [8]u8 = undefined;
        return create(opts, ctx, on_packet, &err, false);
    }

    fn create(opts: Options, ctx: *anyopaque, on_packet: PacketFn, err: []u8, with_device: bool) !*Mic {
        @memset(err, 0);
        var e: c_int = 0;
        const enc = c.opus_encoder_create(rate, 1, c.OPUS_APPLICATION_VOIP, &e) orelse return error.OpusInit;
        errdefer c.opus_encoder_destroy(enc);
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, bitrate));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 8));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_SIGNAL_REQUEST, @as(c_int, c.OPUS_SIGNAL_VOICE));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_DTX_REQUEST, @as(c_int, 1));
        const m = try gpa.create(Mic);
        errdefer gpa.destroy(m);
        m.* = .{
            .enc = enc,
            .rnn = if (opts.noise_suppression) rn.rnnoise_create(null) else null,
            .threshold_bits = .init(@bitCast(clampSensitivity(opts.sensitivity))),
            .on_packet = on_packet,
            .ctx = ctx,
        };
        if (!with_device) return m;
        // o cancelador usa a referência do mixer, que só existe com dispositivo de verdade
        if (opts.echo_cancellation) {
            m.echo = aec.Canceller.init() catch null;
            aec.reference.clear();
        }
        var name: [128]u8 = undefined;
        const n = @min(opts.device.len, name.len - 1);
        @memcpy(name[0..n], opts.device[0..n]);
        name[n] = 0;
        m.dev = c.audio_mic_open(onCapture, m, &name, err.ptr, @intCast(err.len)) orelse {
            if (m.echo) |*ec| ec.deinit();
            if (m.rnn) |r| rn.rnnoise_destroy(r);
            return error.MicOpen;
        };
        return m;
    }

    pub fn close(m: *Mic) void {
        if (m.dev) |d| c.audio_close(d); // para o callback antes de liberar
        if (m.echo) |*e| e.deinit();
        if (m.rnn) |r| rn.rnnoise_destroy(r);
        c.opus_encoder_destroy(m.enc);
        gpa.destroy(m);
    }

    /// Sensibilidade nova na hora (o medidor da configuração mostra o efeito).
    pub fn setSensitivity(m: *Mic, sensitivity: f32) void {
        m.threshold_bits.store(@bitCast(clampSensitivity(sensitivity)), .monotonic);
    }

    fn clampSensitivity(v: f32) f32 {
        return std.math.clamp(v, 0.05, 0.95);
    }

    pub fn level(m: *const Mic) f32 {
        return @bitCast(m.level_bits.load(.monotonic));
    }

    fn onCapture(user: ?*anyopaque, samples: [*c]const f32, frames: c_int) callconv(.c) void {
        const m: *Mic = @ptrCast(@alignCast(user));
        m.feed(samples[0..@intCast(frames)]);
    }

    /// Amostras mono do microfone (também usado pelos testes).
    pub fn feed(m: *Mic, samples: []const f32) void {
        var src = samples;
        while (src.len > 0) {
            const take = @min(src.len, block - m.n_in);
            @memcpy(m.in_buf[m.n_in..][0..take], src[0..take]);
            m.n_in += take;
            src = src[take..];
            if (m.n_in == block) {
                m.n_in = 0;
                m.processBlock();
            }
        }
    }

    /// Último segundo: { nível antes do cancelador, depois, da referência } em dBFS.
    pub fn echoStats(m: *const Mic) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, &m.stats_bits) |*o, *b| o.* = @bitCast(b.load(.monotonic));
        return out;
    }

    fn processBlock(m: *Mic) void {
        var in = m.in_buf;
        var ref: [block]f32 = @splat(0);
        if (m.echo) |*e| e.processLiveRef(&m.in_buf, &in, &ref);
        var b_in: f32 = 0;
        var b_out: f32 = 0;
        var b_ref: f32 = 0;
        for (m.in_buf, in, ref) |a, b, r| {
            b_in += a * a;
            b_out += b * b;
            b_ref += r * r;
        }
        // a caixa está tocando e o cancelador tirou quase tudo (> 6 dB): o que
        // sobrou é resto de eco, não a sua voz (falando junto, a sua voz não é
        // cancelada e a saída fica perto da entrada). O RNNoise ainda acharia
        // que é voz (ele não liga pro volume), e o portão abriria no eco.
        // a caixa "está tocando" até 120 ms depois do último som: o eco chega
        // atrasado e reverbera (é o que a cauda do filtro cobre)
        const cancelling = if (m.echo) |*e| !e.bypassed() else false;
        if (cancelling and b_ref > block * 1e-7) m.far_hold = 12 else m.far_hold -|= 1;
        const far_active = m.far_hold > 0;
        const echo_only = far_active and b_out < b_in * 0.25;
        m.e_in += b_in;
        m.e_out += b_out;
        m.e_ref += b_ref;
        m.e_blocks += 1;
        if (m.e_blocks == 100) {
            const n: f64 = 100 * block;
            for (&m.stats_bits, [3]f64{ m.e_in, m.e_out, m.e_ref }) |*bits, e| {
                const db: f32 = @floatCast(10 * std.math.log10(@max(e / n, 1e-12)));
                bits.store(@bitCast(db), .monotonic);
            }
            m.e_in = 0;
            m.e_out = 0;
            m.e_ref = 0;
            m.e_blocks = 0;
        }
        var out: [block]f32 = undefined;
        var peak: f32 = 0;
        var vad: f32 = 0;
        if (m.rnn) |r| {
            // o RNNoise trabalha na escala de 16 bits
            var scaled: [block]f32 = undefined;
            for (&scaled, in) |*d, v| d.* = v * 32768;
            vad = rn.rnnoise_process_frame(r, &out, &scaled);
            for (&out) |*v| v.* /= 32768;
        } else {
            out = in;
            var sum: f32 = 0;
            for (out) |v| sum += v * v;
            // sem RNNoise: portão por volume (RMS acima de ~-40 dBFS)
            vad = if (@sqrt(sum / block) > 0.01) 1 else 0;
        }
        for (out) |v| peak = @max(peak, @abs(v));
        const old: f32 = @bitCast(m.level_bits.load(.monotonic));
        m.level_bits.store(@bitCast(@max(peak, old * 0.85)), .monotonic);

        if (!echo_only and vad >= @as(f32, @bitCast(m.threshold_bits.load(.monotonic)))) {
            m.speech_run += 1;
        } else {
            m.speech_run = 0;
        }
        // com a caixa tocando, um bloco solto em que o cancelador escorregou
        // não abre o portão (abriria por 250 ms): voz de verdade dura mais
        // que 30 ms
        if (m.speech_run >= @as(u32, if (far_active) 3 else 1)) {
            m.hang = hangover_blocks;
        } else if (m.hang > 0) {
            m.hang -= 1;
        }
        const gate_open = m.hang > 0;
        m.speaking.store(gate_open, .monotonic);
        if (!gate_open) {
            // fechado: nada vai pro Opus (nem os pacotes de silêncio do DTX)
            m.was_open = false;
            m.n_out = 0;
            return;
        }
        if (!m.was_open) {
            // abriu de novo: começa limpo (sem resto de áudio da última fala)
            m.was_open = true;
            _ = c.opus_encoder_ctl(m.enc, c.OPUS_RESET_STATE);
        }

        @memcpy(m.out_buf[m.n_out..][0..block], &out);
        m.n_out += block;
        if (m.n_out == frame_samples) {
            m.n_out = 0;
            const n = c.opus_encode_float(m.enc, &m.out_buf, frame_samples, &m.packet, m.packet.len);
            if (n > 2) m.on_packet(m.ctx, m.packet[0..@intCast(n)]);
        }
    }
};

/// Voz de uma pessoa da sala, do lado de quem ouve.
pub const Peer = struct {
    id: u32,
    ring: audio.Ring = .{},
    dec: ?audio.Decoder = null,
    registered: bool = false,

    pub fn deinit(p: *Peer) void {
        if (p.registered) audio.mixer.remove(&p.ring);
        if (p.dec) |*d| d.deinit();
        p.ring.deinit();
    }

    pub fn push(p: *Peer, packet: []const u8) void {
        if (p.dec == null) p.dec = audio.Decoder.init() catch return;
        const pcm = p.dec.?.decode(packet) catch return;
        p.ring.write(pcm);
        if (!p.registered) {
            p.registered = true;
            audio.mixer.add(&p.ring);
        }
    }

    /// Falando agora (pacote nos últimos 250 ms com algum som).
    pub fn speaking(p: *Peer, now_us: u64) bool {
        p.ring.mutex.lock();
        defer p.ring.mutex.unlock();
        // -|: um pacote pode ter chegado depois de `now_us` ser lido
        return p.ring.last_write_us != 0 and now_us -| p.ring.last_write_us < 250_000 and p.ring.level > 0.01;
    }
};
