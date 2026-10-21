//! H.264 (openh264, com SIMD) + conversão de cor BGRX/RGBX <-> I420.
//!
//! As conversões usam vetores do Zig (16 pixels por vez) e rodam em faixas
//! no pool de threads; em 1080p levam ~1 ms.
const std = @import("std");
const sync = @import("sync.zig");
const oh = @cImport(@cInclude("wels/codec_api.h"));
const hw = @cImport({
    @cInclude("hwenc.h");
    @cInclude("hwdec.h");
});
const gpa = std.heap.c_allocator;

pub const PixelFormat = enum { bgrx, rgbx };

pub const Mode = enum {
    /// tela/texto: compressão boa pra janelas, código e rolagem
    screen,
    /// movimento: jogos e vídeo
    motion,
};

// ---------------------------------------------------------------------------
// Conversão de cor (BT.601, faixa limitada — o que todo decoder H.264 espera)

const V16 = @Vector(16, i32);

fn channelMask(comptime ch: usize) @Vector(16, i32) {
    var m: [16]i32 = undefined;
    for (0..16) |i| m[i] = @intCast(i * 4 + ch);
    return m;
}

inline fn load16(px: *const [64]u8, comptime ch: usize) V16 {
    const v: @Vector(64, u8) = px.*;
    const s: @Vector(16, u8) = @shuffle(u8, v, undefined, channelMask(ch));
    return @intCast(s);
}

inline fn clamp8(v: V16) @Vector(16, u8) {
    const lo: V16 = @splat(0);
    const hi: V16 = @splat(255);
    return @intCast(@min(@max(v, lo), hi));
}

const ToYuvCtx = struct {
    src: [*]const u8,
    stride: usize,
    w: usize,
    h: usize,
    fmt: PixelFormat,
    y: []u8,
    u: []u8, // NV12: U e V intercalados
    v: []u8, // NV12: não usado
    ys: usize, // bytes por linha de Y
    uvs: usize, // bytes por linha de U/V (NV12: da linha UV)
    nv12: bool = false,
    bands: usize,
};

/// Intercala 8 U com 8 V (U0 V0 U1 V1 ...).
fn uvMask() @Vector(16, i32) {
    var m: [16]i32 = undefined;
    for (0..8) |i| {
        m[i * 2] = @intCast(i);
        m[i * 2 + 1] = ~@as(i32, @intCast(i));
    }
    return m;
}

fn evenMask() @Vector(8, i32) {
    var m: [8]i32 = undefined;
    for (0..8) |i| m[i] = @intCast(i * 2);
    return m;
}
fn oddMask() @Vector(8, i32) {
    var m: [8]i32 = undefined;
    for (0..8) |i| m[i] = @intCast(i * 2 + 1);
    return m;
}

const V8 = @Vector(8, i32);

inline fn lumaY(r: V16, g: V16, b: V16) @Vector(16, u8) {
    const yv = (r * @as(V16, @splat(66)) + g * @as(V16, @splat(129)) + b * @as(V16, @splat(25)) + @as(V16, @splat(128))) >> @splat(8);
    return clamp8(yv + @as(V16, @splat(16)));
}

/// Soma pares de pixels vizinhos (16 -> 8).
inline fn pairSum(v: V16) V8 {
    return @shuffle(i32, v, undefined, evenMask()) + @shuffle(i32, v, undefined, oddMask());
}

inline fn clamp8x8(v: V8) @Vector(8, u8) {
    return @intCast(@min(@max(v, @as(V8, @splat(0))), @as(V8, @splat(255))));
}

fn toYuvBand(ctx: *const ToYuvCtx, band: usize) void {
    const pairs = ctx.h / 2;
    const per = (pairs + ctx.bands - 1) / ctx.bands;
    const p0 = band * per;
    const p1 = @min(pairs, p0 + per);
    const ri: usize = if (ctx.fmt == .bgrx) 2 else 0;
    const bi: usize = if (ctx.fmt == .bgrx) 0 else 2;
    const w = ctx.w;
    const cw = w / 2;
    var p = p0;
    while (p < p1) : (p += 1) {
        const y0 = p * 2;
        const row0 = ctx.src + y0 * ctx.stride;
        const row1 = row0 + ctx.stride;
        const yo0 = ctx.y[y0 * ctx.ys ..][0..w];
        const yo1 = ctx.y[(y0 + 1) * ctx.ys ..][0..w];
        const uo = ctx.u[p * ctx.uvs ..][0..if (ctx.nv12) w else cw];
        const vo = if (ctx.nv12) uo else ctx.v[p * ctx.uvs ..][0..cw];
        // 2 linhas x 16 pixels por vez: 32 Y + 8 U + 8 V
        var x: usize = 0;
        while (x + 16 <= w) : (x += 16) {
            const a: *const [64]u8 = @ptrCast(row0 + x * 4);
            const b: *const [64]u8 = @ptrCast(row1 + x * 4);
            const r0 = if (ri == 2) load16(a, 2) else load16(a, 0);
            const g0 = load16(a, 1);
            const b0 = if (bi == 0) load16(a, 0) else load16(a, 2);
            const r1 = if (ri == 2) load16(b, 2) else load16(b, 0);
            const g1 = load16(b, 1);
            const b1 = if (bi == 0) load16(b, 0) else load16(b, 2);
            yo0[x..][0..16].* = lumaY(r0, g0, b0);
            yo1[x..][0..16].* = lumaY(r1, g1, b1);
            const two: V8 = @splat(2);
            const r = (pairSum(r0 + r1) + two) >> @splat(2);
            const g = (pairSum(g0 + g1) + two) >> @splat(2);
            const bb = (pairSum(b0 + b1) + two) >> @splat(2);
            const half: V8 = @splat(128);
            const uu = ((r * @as(V8, @splat(-38)) - g * @as(V8, @splat(74)) + bb * @as(V8, @splat(112)) + half) >> @splat(8)) + half;
            const vv = ((r * @as(V8, @splat(112)) - g * @as(V8, @splat(94)) - bb * @as(V8, @splat(18)) + half) >> @splat(8)) + half;
            if (ctx.nv12) {
                uo[x..][0..16].* = @shuffle(u8, clamp8x8(uu), clamp8x8(vv), uvMask());
            } else {
                uo[x / 2 ..][0..8].* = clamp8x8(uu);
                vo[x / 2 ..][0..8].* = clamp8x8(vv);
            }
        }
        // resto (largura não múltipla de 16)
        while (x < w) : (x += 2) {
            var rs: i32 = 0;
            var gs: i32 = 0;
            var bs: i32 = 0;
            inline for (0..2) |k| {
                const row = if (k == 0) row0 else row1;
                const yo = if (k == 0) yo0 else yo1;
                inline for (0..2) |dx| {
                    const q = row + (x + dx) * 4;
                    const r: i32 = q[ri];
                    const g: i32 = q[1];
                    const b: i32 = q[bi];
                    yo[x + dx] = @intCast(std.math.clamp(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16, 0, 255));
                    rs += r;
                    gs += g;
                    bs += b;
                }
            }
            rs = (rs + 2) >> 2;
            gs = (gs + 2) >> 2;
            bs = (bs + 2) >> 2;
            const uu: u8 = @intCast(std.math.clamp(((-38 * rs - 74 * gs + 112 * bs + 128) >> 8) + 128, 0, 255));
            const vv: u8 = @intCast(std.math.clamp(((112 * rs - 94 * gs - 18 * bs + 128) >> 8) + 128, 0, 255));
            if (ctx.nv12) {
                uo[x] = uu;
                uo[x + 1] = vv;
            } else {
                uo[x / 2] = uu;
                vo[x / 2] = vv;
            }
        }
    }
}

/// Converte uma imagem BGRX/RGBX (largura e altura pares) pra I420.
pub fn toI420(src: [*]const u8, stride: usize, w: usize, h: usize, fmt: PixelFormat, y: []u8, u: []u8, v: []u8) void {
    std.debug.assert(w % 2 == 0 and h % 2 == 0);
    const bands = @max(1, @min(sync.pool.threads + 1, h / 32));
    const ctx: ToYuvCtx = .{ .src = src, .stride = stride, .w = w, .h = h, .fmt = fmt, .y = y, .u = u, .v = v, .ys = w, .uvs = w / 2, .bands = bands };
    sync.pool.run(bands, &ctx, toYuvBand);
}

/// BGRX/RGBX (largura e altura pares) → NV12, com o pitch de cada plano
/// (escreve direto na memória do encoder). Mesma conta do toI420.
pub fn toNV12(src: [*]const u8, stride: usize, w: usize, h: usize, fmt: PixelFormat, y: []u8, ys: usize, uv: []u8, uvs: usize) void {
    std.debug.assert(w % 2 == 0 and h % 2 == 0 and ys >= w and uvs >= w);
    const bands = @max(1, @min(sync.pool.threads + 1, h / 32));
    const ctx: ToYuvCtx = .{ .src = src, .stride = stride, .w = w, .h = h, .fmt = fmt, .y = y, .u = uv, .v = uv, .ys = ys, .uvs = uvs, .nv12 = true, .bands = bands };
    sync.pool.run(bands, &ctx, toYuvBand);
}

/// toNV12 pros encoders em C (VA-API, Media Foundation); `format` é o
/// HWENC_BGRX/HWENC_RGBX do hwenc.h.
export fn telinha_to_nv12(src: [*]const u8, stride: c_int, w: c_int, h: c_int, format: c_int, y: [*]u8, ys: c_int, uv: [*]u8, uvs: c_int) void {
    const W: usize = @intCast(w);
    const H: usize = @intCast(h);
    const YS: usize = @intCast(ys);
    const UVS: usize = @intCast(uvs);
    toNV12(src, @intCast(stride), W, H, if (format == 1) .rgbx else .bgrx, y[0 .. YS * (H - 1) + W], YS, uv[0 .. UVS * (H / 2 - 1) + W], UVS);
}

const ToRgbCtx = struct {
    y: [*]const u8,
    u: [*]const u8,
    v: [*]const u8,
    ys: usize,
    uvs: usize,
    w: usize,
    h: usize,
    dst: []u8,
    bands: usize,
};

fn interleaveMask() @Vector(64, i32) {
    var m: [64]i32 = undefined;
    for (0..16) |p| {
        m[p * 4 + 0] = @intCast(p); // R (vetor a, 0..15)
        m[p * 4 + 1] = @intCast(16 + p); // G (vetor a, 16..31)
        m[p * 4 + 2] = ~@as(i32, @intCast(p)); // B (vetor b, 0..15)
        m[p * 4 + 3] = ~@as(i32, @intCast(16 + p)); // A (vetor b, 16..31)
    }
    return m;
}

fn dupMask() @Vector(16, i32) {
    var m: [16]i32 = undefined;
    for (0..16) |i| m[i] = @intCast(i / 2);
    return m;
}

fn toRgbBand(ctx: *const ToRgbCtx, band: usize) void {
    const per = ((ctx.h + ctx.bands - 1) / ctx.bands + 1) & ~@as(usize, 1);
    const r0 = band * per;
    const r1 = @min(ctx.h, r0 + per);
    const w = ctx.w;
    var row = r0;
    while (row < r1) : (row += 1) {
        const yr = ctx.y + row * ctx.ys;
        const ur = ctx.u + (row / 2) * ctx.uvs;
        const vr = ctx.v + (row / 2) * ctx.uvs;
        const out = ctx.dst[row * w * 4 ..][0 .. w * 4];
        var x: usize = 0;
        while (x + 16 <= w) : (x += 16) {
            const yv: V16 = @intCast(@as(@Vector(16, u8), yr[x..][0..16].*));
            const u8v: @Vector(8, u8) = ur[x / 2 ..][0..8].*;
            const v8v: @Vector(8, u8) = vr[x / 2 ..][0..8].*;
            const uu: V16 = @intCast(@shuffle(u8, u8v, undefined, dupMask()));
            const vv: V16 = @intCast(@shuffle(u8, v8v, undefined, dupMask()));
            const c = (yv - @as(V16, @splat(16))) * @as(V16, @splat(298));
            const d = uu - @as(V16, @splat(128));
            const e = vv - @as(V16, @splat(128));
            const half: V16 = @splat(128);
            const r = clamp8((c + e * @as(V16, @splat(409)) + half) >> @splat(8));
            const g = clamp8((c - d * @as(V16, @splat(100)) - e * @as(V16, @splat(208)) + half) >> @splat(8));
            const b = clamp8((c + d * @as(V16, @splat(516)) + half) >> @splat(8));
            const a: @Vector(16, u8) = @splat(255);
            const rg: @Vector(32, u8) = std.simd.join(r, g);
            const ba: @Vector(32, u8) = std.simd.join(b, a);
            out[x * 4 ..][0..64].* = @shuffle(u8, rg, ba, interleaveMask());
        }
        while (x < w) : (x += 1) {
            const c = (@as(i32, yr[x]) - 16) * 298;
            const d = @as(i32, ur[x / 2]) - 128;
            const e = @as(i32, vr[x / 2]) - 128;
            out[x * 4 + 0] = @intCast(std.math.clamp((c + 409 * e + 128) >> 8, 0, 255));
            out[x * 4 + 1] = @intCast(std.math.clamp((c - 100 * d - 208 * e + 128) >> 8, 0, 255));
            out[x * 4 + 2] = @intCast(std.math.clamp((c + 516 * d + 128) >> 8, 0, 255));
            out[x * 4 + 3] = 255;
        }
    }
}

const ToRgbNv12Ctx = struct {
    y: [*]const u8,
    uv: [*]const u8,
    w: usize,
    h: usize,
    dst: []u8,
    bands: usize,
};

fn uMask() @Vector(16, i32) {
    var m: [16]i32 = undefined;
    for (0..16) |i| m[i] = @intCast((i / 2) * 2); // U0 U0 U1 U1 ...
    return m;
}
fn vMask() @Vector(16, i32) {
    var m: [16]i32 = undefined;
    for (0..16) |i| m[i] = @intCast((i / 2) * 2 + 1);
    return m;
}

fn toRgbNv12Band(ctx: *const ToRgbNv12Ctx, band: usize) void {
    const per = ((ctx.h + ctx.bands - 1) / ctx.bands + 1) & ~@as(usize, 1);
    const r0 = band * per;
    const r1 = @min(ctx.h, r0 + per);
    const w = ctx.w;
    var row = r0;
    while (row < r1) : (row += 1) {
        const yr = ctx.y + row * w;
        const uvr = ctx.uv + (row / 2) * w;
        const out = ctx.dst[row * w * 4 ..][0 .. w * 4];
        var x: usize = 0;
        while (x + 16 <= w) : (x += 16) {
            const yv: V16 = @intCast(@as(@Vector(16, u8), yr[x..][0..16].*));
            const uvv: @Vector(16, u8) = uvr[x..][0..16].*; // 8 pares U,V
            const uu: V16 = @intCast(@shuffle(u8, uvv, undefined, uMask()));
            const vv: V16 = @intCast(@shuffle(u8, uvv, undefined, vMask()));
            const c = (yv - @as(V16, @splat(16))) * @as(V16, @splat(298));
            const d = uu - @as(V16, @splat(128));
            const e = vv - @as(V16, @splat(128));
            const half: V16 = @splat(128);
            const r = clamp8((c + e * @as(V16, @splat(409)) + half) >> @splat(8));
            const g = clamp8((c - d * @as(V16, @splat(100)) - e * @as(V16, @splat(208)) + half) >> @splat(8));
            const b = clamp8((c + d * @as(V16, @splat(516)) + half) >> @splat(8));
            const a: @Vector(16, u8) = @splat(255);
            out[x * 4 ..][0..64].* = @shuffle(u8, std.simd.join(r, g), std.simd.join(b, a), interleaveMask());
        }
        while (x < w) : (x += 1) {
            const c = (@as(i32, yr[x]) - 16) * 298;
            const d = @as(i32, uvr[(x / 2) * 2]) - 128;
            const e = @as(i32, uvr[(x / 2) * 2 + 1]) - 128;
            out[x * 4 + 0] = @intCast(std.math.clamp((c + 409 * e + 128) >> 8, 0, 255));
            out[x * 4 + 1] = @intCast(std.math.clamp((c - 100 * d - 208 * e + 128) >> 8, 0, 255));
            out[x * 4 + 2] = @intCast(std.math.clamp((c + 516 * d + 128) >> 8, 0, 255));
            out[x * 4 + 3] = 255;
        }
    }
}

/// Converte NV12 (saída do NVDEC) pra RGBA.
pub fn nv12ToRgba(y: [*]const u8, uv: [*]const u8, w: usize, h: usize, dst: []u8) void {
    const bands = @max(1, @min(sync.pool.threads + 1, h / 32));
    const ctx: ToRgbNv12Ctx = .{ .y = y, .uv = uv, .w = w, .h = h, .dst = dst, .bands = bands };
    sync.pool.run(bands, &ctx, toRgbNv12Band);
}

/// Converte I420 pra RGBA (pronto pra subir numa textura).
pub fn toRgba(y: [*]const u8, u: [*]const u8, v: [*]const u8, ys: usize, uvs: usize, w: usize, h: usize, dst: []u8) void {
    const bands = @max(1, @min(sync.pool.threads + 1, h / 32));
    const ctx: ToRgbCtx = .{ .y = y, .u = u, .v = v, .ys = ys, .uvs = uvs, .w = w, .h = h, .dst = dst, .bands = bands };
    sync.pool.run(bands, &ctx, toRgbBand);
}

// ---------------------------------------------------------------------------
// Encoder

/// Codecs de vídeo (mesmos números do protocolo e do hwenc.h/hwdec.h).
/// H.264 sempre funciona (openh264); HEVC e AV1 só na placa de vídeo.
pub const Codec = enum(u8) {
    h264 = 0,
    hevc = 1,
    av1 = 2,

    pub fn bit(cd: Codec) u8 {
        return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(cd)));
    }
    /// Bits 2–3 das flags do quadro (valor desconhecido = H.264).
    pub fn fromFlags(flags: u8) Codec {
        return switch ((flags >> 2) & 3) {
            1 => .hevc,
            2 => .av1,
            else => .h264,
        };
    }

    pub fn name(cd: Codec) []const u8 {
        return switch (cd) {
            .h264 => "H.264",
            .hevc => "HEVC",
            .av1 => "AV1",
        };
    }
};

pub const EncoderOptions = struct {
    codec: Codec = .h264, // só o encoder em hardware faz outro que não H.264
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32, // bits/s
    mode: Mode = .screen,
    threads: u32 = 0, // 0 = automático
    /// 2 = quadros alternados que ninguém usa de referência (dá pra pular
    /// pra um espectador que não dá conta sem estragar a decodificação).
    temporal_layers: u8 = 1,
    /// Windows: dispositivo D3D11 da captura (o Media Foundation recebe a textura dela).
    d3d_device: ?*anyopaque = null,
};

pub const Encoder = struct {
    enc: [*c]oh.ISVCEncoder,
    opts: EncoderOptions,
    y: []u8,
    u: []u8,
    v: []u8,
    ts_ms: u64 = 0,

    pub fn init(opts: EncoderOptions) !Encoder {
        std.debug.assert(opts.width % 2 == 0 and opts.height % 2 == 0);
        var enc: [*c]oh.ISVCEncoder = null;
        if (oh.WelsCreateSVCEncoder(&enc) != 0 or enc == null) return error.EncoderCreate;
        errdefer oh.WelsDestroySVCEncoder(enc);

        var trace: c_int = oh.WELS_LOG_QUIET;
        _ = enc.*.*.SetOption.?(enc, oh.ENCODER_OPTION_TRACE_LEVEL, &trace);
        var p: oh.SEncParamExt = undefined;
        _ = enc.*.*.GetDefaultParams.?(enc, &p);
        const threads: c_int = if (opts.threads > 0) @intCast(opts.threads) else @intCast(std.math.clamp(sync.cpuCount(), 1, 8));
        p.iUsageType = if (opts.mode == .screen) oh.SCREEN_CONTENT_REAL_TIME else oh.CAMERA_VIDEO_REAL_TIME;
        p.iPicWidth = @intCast(opts.width);
        p.iPicHeight = @intCast(opts.height);
        p.iTargetBitrate = @intCast(opts.bitrate);
        p.iMaxBitrate = oh.UNSPECIFIED_BIT_RATE;
        p.iRCMode = oh.RC_BITRATE_MODE;
        p.fMaxFrameRate = @floatFromInt(std.math.clamp(opts.fps, 1, 60));
        p.iSpatialLayerNum = 1;
        p.iTemporalLayerNum = opts.temporal_layers;
        p.uiIntraPeriod = 0; // IDR só quando pedirem (gente entrando / atrasada)
        p.bEnableFrameSkip = false; // quem decide pular frame é o sharer (controle de banda)
        p.iMultipleThreadIdc = @intCast(threads);
        p.iComplexityMode = oh.LOW_COMPLEXITY;
        p.bEnableDenoise = false;
        p.bEnableBackgroundDetection = opts.mode == .motion;
        p.bEnableAdaptiveQuant = opts.mode == .motion;
        p.bEnableSceneChangeDetect = true;
        p.bEnableLongTermReference = false;
        p.eSpsPpsIdStrategy = oh.CONSTANT_ID;
        p.iLoopFilterDisableIdc = 0;
        p.iEntropyCodingModeFlag = 0;
        p.iMinQp = 12;
        p.iMaxQp = 42;
        const l = &p.sSpatialLayers[0];
        l.iVideoWidth = @intCast(opts.width);
        l.iVideoHeight = @intCast(opts.height);
        l.fFrameRate = p.fMaxFrameRate;
        l.iSpatialBitrate = @intCast(opts.bitrate);
        l.iMaxSpatialBitrate = oh.UNSPECIFIED_BIT_RATE;
        l.sSliceArgument.uiSliceMode = oh.SM_FIXEDSLCNUM_SLICE;
        l.sSliceArgument.uiSliceNum = @intCast(threads * 2); // fatias menores balanceiam melhor entre as threads
        if (enc.*.*.InitializeExt.?(enc, &p) != 0) return error.EncoderInit;
        var fmt: c_int = oh.videoFormatI420;
        _ = enc.*.*.SetOption.?(enc, oh.ENCODER_OPTION_DATAFORMAT, &fmt);

        const n = @as(usize, opts.width) * opts.height;
        const y = try gpa.alloc(u8, n);
        errdefer gpa.free(y);
        const u = try gpa.alloc(u8, n / 4);
        errdefer gpa.free(u);
        const v = try gpa.alloc(u8, n / 4);
        return .{ .enc = enc, .opts = opts, .y = y, .u = u, .v = v };
    }

    pub fn deinit(e: *Encoder) void {
        _ = e.enc.*.*.Uninitialize.?(e.enc);
        oh.WelsDestroySVCEncoder(e.enc);
        gpa.free(e.y);
        gpa.free(e.u);
        gpa.free(e.v);
    }

    pub fn setBitrate(e: *Encoder, bps: u32) void {
        var info: oh.SBitrateInfo = .{ .iLayer = oh.SPATIAL_LAYER_ALL, .iBitrate = @intCast(bps) };
        _ = e.enc.*.*.SetOption.?(e.enc, oh.ENCODER_OPTION_BITRATE, &info);
    }

    pub fn forceKey(e: *Encoder) void {
        _ = e.enc.*.*.ForceIntraFrame.?(e.enc, true);
    }

    /// Converte e codifica um frame. Anexa o bitstream em `out`.
    /// Retorna se foi um IDR (null se o encoder não produziu nada).
    pub fn encode(e: *Encoder, src: [*]const u8, stride: usize, fmt: PixelFormat, out: *std.ArrayList(u8)) !?bool {
        toI420(src, stride, e.opts.width, e.opts.height, fmt, e.y, e.u, e.v);
        return e.encodeI420(e.y.ptr, e.u.ptr, e.v.ptr, out);
    }

    /// Codifica um frame que já está em I420 (largura x altura do encoder).
    pub fn encodeI420(e: *Encoder, y: [*]const u8, u: [*]const u8, v: [*]const u8, out: *std.ArrayList(u8)) !?bool {
        var pic = std.mem.zeroes(oh.SSourcePicture);
        pic.iColorFormat = oh.videoFormatI420;
        pic.iPicWidth = @intCast(e.opts.width);
        pic.iPicHeight = @intCast(e.opts.height);
        pic.iStride[0] = @intCast(e.opts.width);
        pic.iStride[1] = @intCast(e.opts.width / 2);
        pic.iStride[2] = @intCast(e.opts.width / 2);
        pic.pData[0] = @constCast(y);
        pic.pData[1] = @constCast(u);
        pic.pData[2] = @constCast(v);
        pic.uiTimeStamp = @intCast(e.ts_ms);
        e.ts_ms += 1000 / @max(1, e.opts.fps);

        var info = std.mem.zeroes(oh.SFrameBSInfo);
        if (e.enc.*.*.EncodeFrame.?(e.enc, &pic, &info) != 0) return error.Encode;
        if (info.eFrameType == oh.videoFrameTypeSkip or info.eFrameType == oh.videoFrameTypeInvalid) return null;
        for (0..@intCast(info.iLayerNum)) |li| {
            const layer = &info.sLayerInfo[li];
            var len: usize = 0;
            for (0..@intCast(layer.iNalCount)) |ni| len += @intCast(layer.pNalLengthInByte[ni]);
            try out.appendSlice(gpa, layer.pBsBuf[0..len]);
        }
        return info.eFrameType == oh.videoFrameTypeIDR;
    }
};

// ---------------------------------------------------------------------------
// Encoder em hardware (NVENC): recebe BGRX/RGBX direto, sem conversão na CPU

/// Peso do encoder da placa (0 = leve, 1 = equilibrado, 2 = qualidade); vale no próximo que abrir.
pub fn setHwEffort(effort: u8) void {
    hw.hwenc_set_effort(effort);
}

pub const HwEncoder = struct {
    h: *hw.hwenc,
    opts: EncoderOptions,

    /// Falha (com o motivo em `err`) se não houver GPU/driver compatível.
    pub fn init(opts: EncoderOptions, err: []u8) !HwEncoder {
        @memset(err, 0);
        const h = (if (opts.d3d_device) |dev|
            hw.hwenc_open_d3d(dev, @intFromEnum(opts.codec), @intCast(opts.width), @intCast(opts.height), @intCast(@max(1, opts.fps)), @intCast(opts.bitrate), @intFromBool(opts.mode == .screen), opts.temporal_layers, err.ptr, @intCast(err.len))
        else
            hw.hwenc_open(@intFromEnum(opts.codec), @intCast(opts.width), @intCast(opts.height), @intCast(@max(1, opts.fps)), @intCast(opts.bitrate), @intFromBool(opts.mode == .screen), opts.temporal_layers, err.ptr, @intCast(err.len))) orelse return error.HwUnavailable;
        return .{ .h = h, .opts = opts };
    }

    pub fn deinit(e: *HwEncoder) void {
        hw.hwenc_close(e.h);
    }

    pub fn setBitrate(e: *HwEncoder, bps: u32) void {
        hw.hwenc_set_bitrate(e.h, @intCast(bps));
    }

    pub fn name(e: *HwEncoder) []const u8 {
        return std.mem.span(hw.hwenc_name(e.h));
    }

    /// Aceita quadro que já está na placa (ponteiro CUDA; ver cudagl.c)? Só o NVENC.
    pub fn acceptsCuda(e: *HwEncoder) bool {
        return hw.hwenc_accepts_cuda(e.h) != 0;
    }

    /// É o VA-API (Intel/AMD no Linux)?
    pub fn isVa(e: *HwEncoder) bool {
        return hw.hwenc_is_va(e.h) != 0;
    }

    /// É o Media Foundation (Windows: Intel, AMD, qualquer placa)?
    pub fn isMf(e: *HwEncoder) bool {
        return hw.hwenc_is_mf(e.h) != 0;
    }

    /// Windows: recebe a textura NV12 da captura direto (dispositivo da captura ligado)?
    pub fn acceptsD3d(e: *HwEncoder) bool {
        return hw.hwenc_accepts_d3d(e.h) != 0;
    }

    /// Codifica um quadro RGBX/BGRX que já está na placa (acceptsCuda). Retorna se foi IDR.
    pub fn encodeDev(e: *HwEncoder, dev: u64, pitch: u32, fmt: PixelFormat, force_key: bool, out: *std.ArrayList(u8)) !bool {
        var data: [*c]const u8 = null;
        var len: c_int = 0;
        var idr: c_int = 0;
        const f: c_int = if (fmt == .rgbx) hw.HWENC_RGBX else hw.HWENC_BGRX;
        if (hw.hwenc_encode_dev(e.h, dev, @intCast(pitch), f, @intFromBool(force_key), &data, &len, &idr) != 0) return error.Encode;
        const bits = data[0..@intCast(len)];
        try out.appendSlice(gpa, bits);
        return idr != 0 or hasKeyNal(e.opts.codec, bits);
    }

    /// Codifica um quadro. Retorna se foi IDR.
    pub fn encode(e: *HwEncoder, src: [*]const u8, stride: usize, fmt: PixelFormat, force_key: bool, out: *std.ArrayList(u8)) !bool {
        var data: [*c]const u8 = null;
        var len: c_int = 0;
        var idr: c_int = 0;
        const f: c_int = if (fmt == .rgbx) hw.HWENC_RGBX else hw.HWENC_BGRX;
        if (hw.hwenc_encode(e.h, src, @intCast(stride), f, @intFromBool(force_key), &data, &len, &idr) != 0) return error.Encode;
        const bits = data[0..@intCast(len)];
        try out.appendSlice(gpa, bits);
        // o tipo de quadro que o driver informa nem sempre é confiável: olha o bitstream
        return idr != 0 or hasKeyNal(e.opts.codec, bits);
    }
};

/// Quadro que ninguém usa de referência (todas as fatias com nal_ref_idc = 0):
/// pode ser pulado sem quebrar a decodificação dos seguintes.
pub fn isDroppable(bits: []const u8) bool {
    var slices: usize = 0;
    var i: usize = 0;
    while (i + 3 < bits.len) : (i += 1) {
        if (bits[i] == 0 and bits[i + 1] == 0 and bits[i + 2] == 1) {
            const hdr = bits[i + 3];
            const typ = hdr & 0x1f;
            if (typ == 1 or typ == 5) {
                if (hdr & 0x60 != 0) return false; // nal_ref_idc != 0: é referência
                slices += 1;
            }
            i += 2;
        }
    }
    return slices > 0;
}

/// Quadro-chave nesse codec? (H.264: IDR; HEVC: IRAP, tipos 16–21)
pub fn hasKeyNal(cd: Codec, bits: []const u8) bool {
    if (cd == .h264) return hasIdrNal(bits);
    if (cd != .hevc) return false;
    var i: usize = 0;
    while (i + 3 < bits.len) : (i += 1) {
        if (bits[i] == 0 and bits[i + 1] == 0 and bits[i + 2] == 1) {
            const typ = (bits[i + 3] >> 1) & 0x3f;
            if (typ >= 16 and typ <= 21) return true;
            i += 2;
        }
    }
    return false;
}

/// Tem um NAL de IDR (tipo 5) no bitstream Annex B?
pub fn hasIdrNal(bits: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < bits.len) : (i += 1) {
        if (bits[i] == 0 and bits[i + 1] == 0 and bits[i + 2] == 1) {
            if (bits[i + 3] & 0x1f == 5) return true;
            i += 2;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Decoder em hardware (NVDEC; VA-API no Linux, Media Foundation no Windows)

pub const HwDecoder = struct {
    h: *hw.hwdec,

    /// A placa decodifica esse codec? (só pergunta; barato)
    pub fn supports(cd: Codec) bool {
        return hw.hwdec_supports(@intFromEnum(cd)) != 0;
    }

    pub fn init(cd: Codec, err: []u8) !HwDecoder {
        @memset(err, 0);
        const h = hw.hwdec_open(@intFromEnum(cd), err.ptr, @intCast(err.len)) orelse return error.HwUnavailable;
        return .{ .h = h };
    }

    pub fn deinit(d: *HwDecoder) void {
        hw.hwdec_close(d.h);
    }

    /// "NVDEC", "VA-API", "Media Foundation"
    pub fn name(d: *HwDecoder) []const u8 {
        return std.mem.span(hw.hwdec_name(d.h));
    }

    /// `on_device`: o quadro foi pro buffer da placa pedido (y/uv não valem).
    pub const Frame = struct { y: [*]const u8, uv: [*]const u8, w: u32, h: u32, on_device: bool = false };

    /// Decodifica um quadro completo. A imagem vale até a próxima chamada.
    pub fn decode(d: *HwDecoder, data: []const u8) !?Frame {
        var f: hw.hwdec_frame = undefined;
        const r = hw.hwdec_decode(d.h, data.ptr, @intCast(data.len), &f);
        if (r < 0) return error.Decode;
        if (r == 0) return null;
        return .{ .y = f.y, .uv = f.uv, .w = @intCast(f.width), .h = @intCast(f.height) };
    }

    /// Decodifica direto pra memória da placa (NVDEC; ver hwdec.h). Se o
    /// decoder não faz isso, a imagem sai pela CPU (on_device = false).
    pub fn decodeTo(d: *HwDecoder, data: []const u8, dst_y: u64, dst_uv: u64, pitch: u32, w: u32, h: u32) !?Frame {
        var f: hw.hwdec_frame = undefined;
        const r = hw.hwdec_decode_to(d.h, data.ptr, @intCast(data.len), &f, dst_y, dst_uv, @intCast(pitch), @intCast(w), @intCast(h));
        if (r < 0) return error.Decode;
        if (r == 0) return null;
        return .{ .y = f.y, .uv = f.uv, .w = @intCast(f.width), .h = @intCast(f.height), .on_device = f.on_device != 0 };
    }
};

// ---------------------------------------------------------------------------
// Decoder

pub const Decoder = struct {
    dec: [*c]oh.ISVCDecoder,

    /// Uma thread só, de propósito: o modo com threads do openh264 2.6
    /// (DECODER_OPTION_NUM_OF_THREADS) rende ~1,7x com 2 threads, mas a imagem
    /// sai 2 quadros atrasada e ele dá segfault ao destruir o decoder com
    /// quadros em andamento (com 3 threads, já no decode). Medido no bench.
    pub fn init() !Decoder {
        var dec: [*c]oh.ISVCDecoder = null;
        if (oh.WelsCreateDecoder(&dec) != 0 or dec == null) return error.DecoderCreate;
        errdefer oh.WelsDestroyDecoder(dec);
        var trace: c_int = oh.WELS_LOG_QUIET;
        _ = dec.*.*.SetOption.?(dec, oh.DECODER_OPTION_TRACE_LEVEL, &trace);
        var p = std.mem.zeroes(oh.SDecodingParam);
        p.sVideoProperty.eVideoBsType = oh.VIDEO_BITSTREAM_AVC;
        p.eEcActiveIdc = oh.ERROR_CON_DISABLE; // sem "remendo": se perder referência, pedimos um IDR
        p.uiTargetDqLayer = 0xff;
        if (dec.*.*.Initialize.?(dec, &p) != 0) return error.DecoderInit;
        return .{ .dec = dec };
    }

    pub fn deinit(d: *Decoder) void {
        _ = d.dec.*.*.Uninitialize.?(d.dec);
        oh.WelsDestroyDecoder(d.dec);
    }

    pub const Picture = struct { y: [*]const u8, u: [*]const u8, v: [*]const u8, ys: usize, uvs: usize, w: u32, h: u32 };

    /// Decodifica um frame. Retorna a imagem (válida até a próxima chamada) ou null.
    pub fn decode(d: *Decoder, data: []const u8) !?Picture {
        var planes: [3][*c]u8 = .{ null, null, null };
        var info = std.mem.zeroes(oh.SBufferInfo);
        const st = d.dec.*.*.DecodeFrameNoDelay.?(d.dec, data.ptr, @intCast(data.len), &planes, &info);
        if (st != oh.dsErrorFree) return error.Decode;
        // perfis Main/High: o openh264 segura a imagem esperando reordenação
        // (B-frames), mesmo sem nenhum B-frame no fluxo. Como nunca usamos
        // B-frames, a imagem já pode sair: pede pra soltar.
        if (info.iBufferStatus != 1) _ = d.dec.*.*.FlushFrame.?(d.dec, &planes, &info);
        if (info.iBufferStatus != 1 or planes[0] == null) return null;
        const sb = info.UsrData.sSystemBuffer;
        return .{
            .y = planes[0],
            .u = planes[1],
            .v = planes[2],
            .ys = @intCast(sb.iStride[0]),
            .uvs = @intCast(sb.iStride[1]),
            .w = @intCast(sb.iWidth),
            .h = @intCast(sb.iHeight),
        };
    }
};
