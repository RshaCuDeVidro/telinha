//! Áudio das transmissões: captura + Opus de quem transmite, e mixer de quem
//! assiste (uma saída só, somando todas as transmissões assistidas).
const std = @import("std");
const sync = @import("sync.zig");
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

    pub fn deinit(rg: *Ring) void {
        gpa.free(rg.buf);
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
    /// Quem transmite áudio no Linux escuta a si mesmo na captura: silencia a saída (sem eco).
    self_mute: std.atomic.Value(bool) = .init(false),

    pub fn add(m: *Mixer, rg: *Ring) void {
        m.mutex.lock();
        // TELINHA_SEM_SOM=1: recebe e decodifica, mas não toca (testes)
        if (m.dev == null and getenv("TELINHA_SEM_SOM") != null) m.failed = true;
        const need_open = m.dev == null and !m.failed;
        if (std.mem.findScalar(*Ring, m.rings.items, rg) == null) m.rings.append(gpa, rg) catch {};
        m.mutex.unlock();
        if (need_open) {
            var err: [256]u8 = undefined;
            const d = c.audio_output_open(onPlay, m, &err, err.len);
            m.mutex.lock();
            if (d) |dev| m.dev = dev else m.failed = true;
            m.mutex.unlock();
        }
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
        const silent = m.self_mute.load(.monotonic);
        for (m.rings.items) |rg| {
            const gain: f32 = if (rg.muted or silent) 0 else rg.volume;
            rg.mixInto(out, gain);
        }
        for (out) |*v| v.* = std.math.clamp(v.*, -1.0, 1.0);
    }
};

pub var mixer: Mixer = .{};

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
    /// Retorna as amostras decodificadas (válidas até a próxima chamada).
    pub fn decode(d: *Decoder, packet: []const u8) ![]const f32 {
        const n = c.opus_decode_float(d.dec, packet.ptr, @intCast(packet.len), &d.pcm, 5760, 0);
        if (n < 0) return error.OpusDecode;
        return d.pcm[0 .. @as(usize, @intCast(n)) * channels];
    }
};

/// Captura o som do computador e entrega pacotes Opus de 10 ms.
pub const Sender = struct {
    dev: ?*c.audio_dev = null,
    enc: *c.OpusEncoder,
    pending: [frame_len * channels]f32 = undefined,
    n_pending: usize = 0,
    packet: [1500]u8 = undefined,
    on_packet: *const fn (ctx: *anyopaque, packet: []const u8) void,
    ctx: *anyopaque,

    pub fn create(ctx: *anyopaque, on_packet: *const fn (ctx: *anyopaque, packet: []const u8) void, err: []u8) !*Sender {
        @memset(err, 0);
        var e: c_int = 0;
        const enc = c.opus_encoder_create(rate, channels, c.OPUS_APPLICATION_RESTRICTED_LOWDELAY, &e) orelse return error.OpusInit;
        errdefer c.opus_encoder_destroy(enc);
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_BITRATE_REQUEST, @as(c_int, bitrate));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_COMPLEXITY_REQUEST, @as(c_int, 6));
        _ = c.opus_encoder_ctl(enc, c.OPUS_SET_DTX_REQUEST, @as(c_int, 1)); // silêncio quase não gasta banda
        const s = try gpa.create(Sender);
        s.* = .{ .enc = enc, .on_packet = on_packet, .ctx = ctx };
        s.dev = c.audio_capture_open(onCapture, s, err.ptr, @intCast(err.len)) orelse {
            gpa.destroy(s);
            return error.AudioCapture;
        };
        return s;
    }

    pub fn destroy(s: *Sender) void {
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

pub fn captureHearsSelf() bool {
    return c.audio_capture_hears_self() != 0;
}
