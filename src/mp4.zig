//! MP4 (ISO BMFF) pros clipes e gravações: o H.264 que já chega da sala (sem
//! recodificar nada) e o Opus do som da transmissão.
//!
//!   Clipe:    MP4 normal com o índice (moov) no começo; toca em qualquer lugar
//!             e já dá pra mandar no WhatsApp/Discord.
//!   Gravação: MP4 fragmentado (moov sem amostras + moof/mdat a cada ~2 s): se
//!             o app cair no meio, o que já foi escrito continua tocável.
//!
//! Vídeo em avc1 (H.264: SPS/PPS no avcC) ou hvc1 (HEVC: VPS/SPS/PPS no
//! hvcC) — o codec é reconhecido pelo primeiro IDR —, quadros com tamanho de 4 bytes na frente,
//! timescale 90 kHz, quadros com duração variável: a tela só manda quando
//! muda). Opus em 'Opus' + dOps, pacotes de 10 ms (480 amostras a 48 kHz);
//! buracos no som (silêncio que nem foi enviado) viram pacotes vazios, que o
//! decoder toca como silêncio.
const std = @import("std");
const gpa = std.heap.c_allocator;

const sync = @import("sync.zig");
pub const cio = @cImport(@cInclude("stdio.h"));

extern "c" fn _wfopen(path: [*:0]const u16, mode: [*:0]const u16) ?*cio.FILE;

/// fopen com caminho UTF-8 (no Windows o fopen comum não entende acento:
/// C:\Users\João\Videos).
pub fn openFile(path: [:0]const u8, mode: [:0]const u8) ?*cio.FILE {
    if (sync.is_windows) {
        var wpath: [1024:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wpath, path) catch return null;
        if (n >= wpath.len) return null;
        wpath[n] = 0;
        var wmode: [8:0]u16 = undefined;
        for (mode, 0..) |ch, i| wmode[i] = ch;
        wmode[mode.len] = 0;
        return _wfopen(&wpath, &wmode);
    }
    return cio.fopen(path.ptr, mode.ptr);
}

pub const video_timescale = 90_000;
pub const audio_timescale = 48_000;
pub const audio_frame = 480; // 10 ms

pub const VideoSample = struct {
    data: []const u8, // H.264 Annex B (como sai do encoder)
    ts_us: u64, // hora da captura
    key: bool,
};

pub const AudioSample = struct {
    data: []const u8, // pacote Opus de 10 ms
    ts_us: u64,
};

// ---------------------------------------------------------------------------
// H.264

pub const ParamSets = struct {
    hevc: bool = false,
    vps: []const u8 = &.{}, // só HEVC
    sps: []const u8 = &.{},
    pps: []const u8 = &.{},

    fn complete(ps: ParamSets) bool {
        return ps.sps.len >= 4 and ps.pps.len > 0 and (!ps.hevc or ps.vps.len > 0);
    }
};

/// Tipo da NAL no HEVC (cabeçalho de 2 bytes).
fn hevcType(nal: []const u8) u8 {
    return (nal[0] >> 1) & 0x3F;
}

/// O bitstream é HEVC? (o IDR do HEVC traz VPS/SPS/PPS — tipos 32–34 com o
/// segundo byte do cabeçalho 0x01 —, coisa que não existe no H.264)
pub fn isHevc(annexb: []const u8) bool {
    var it: NalIter = .{ .data = annexb };
    while (it.next()) |nal| {
        if (nal.len < 3) continue;
        const t = hevcType(nal);
        if (nal[0] & 0x81 == 0 and nal[1] == 0x01 and t >= 32 and t <= 34) return true;
    }
    return false;
}

/// Percorre as NAL units de um bitstream Annex B.
pub const NalIter = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(it: *NalIter) ?[]const u8 {
        const d = it.data;
        // acha o próximo início (00 00 01)
        var i = it.pos;
        while (i + 3 <= d.len and !(d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 1)) i += 1;
        if (i + 3 > d.len) return null;
        const start = i + 3;
        var j = start;
        while (j + 3 <= d.len and !(d[j] == 0 and d[j + 1] == 0 and (d[j + 2] == 1 or (d[j + 2] == 0 and j + 3 < d.len and d[j + 3] == 1)))) j += 1;
        const end = if (j + 3 <= d.len) j else d.len;
        it.pos = end;
        // zeros do fim (antes do próximo 00 00 00 01) não são da NAL
        var e = end;
        while (e > start and d[e - 1] == 0) e -= 1;
        return d[start..e];
    }
};

/// SPS/PPS (e VPS no HEVC) de um quadro (o IDR traz todos).
pub fn paramSets(annexb: []const u8) ParamSets {
    var ps: ParamSets = .{ .hevc = isHevc(annexb) };
    var it: NalIter = .{ .data = annexb };
    if (ps.hevc) {
        while (it.next()) |nal| {
            if (nal.len < 3) continue;
            switch (hevcType(nal)) {
                32 => if (ps.vps.len == 0) {
                    ps.vps = nal;
                },
                33 => if (ps.sps.len == 0) {
                    ps.sps = nal;
                },
                34 => if (ps.pps.len == 0) {
                    ps.pps = nal;
                },
                else => {},
            }
        }
        return ps;
    }
    while (it.next()) |nal| {
        if (nal.len == 0) continue;
        switch (nal[0] & 0x1F) {
            7 => if (ps.sps.len == 0) {
                ps.sps = nal;
            },
            8 => if (ps.pps.len == 0) {
                ps.pps = nal;
            },
            else => {},
        }
    }
    return ps;
}

/// Annex B → tamanho (4 bytes) + NAL, sem SPS/PPS/AUD (vão no avcC/hvcC).
pub fn toAvcc(out: *std.ArrayList(u8), annexb: []const u8, hevc: bool) !void {
    var it: NalIter = .{ .data = annexb };
    while (it.next()) |nal| {
        if (nal.len == 0) continue;
        if (hevc) {
            if (nal.len < 2) continue;
            switch (hevcType(nal)) {
                32, 33, 34, 35 => continue, // VPS, SPS, PPS, AUD
                else => {},
            }
        } else switch (nal[0] & 0x1F) {
            7, 8, 9 => continue,
            else => {},
        }
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(nal.len))));
        try out.appendSlice(gpa, nal);
    }
}

// ---------------------------------------------------------------------------
// Caixas (boxes)

const Box = struct {
    buf: *std.ArrayList(u8),

    fn u8_(b: Box, v: u8) !void {
        try b.buf.append(gpa, v);
    }
    fn u16_(b: Box, v: u16) !void {
        try b.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
    }
    fn u32_(b: Box, v: u32) !void {
        try b.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, v)));
    }
    fn u64_(b: Box, v: u64) !void {
        try b.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u64, v)));
    }
    fn bytes(b: Box, s: []const u8) !void {
        try b.buf.appendSlice(gpa, s);
    }
    fn zeros(b: Box, n: usize) !void {
        try b.buf.appendNTimes(gpa, 0, n);
    }
    /// Abre uma caixa; devolve a posição pra `end` acertar o tamanho.
    fn begin(b: Box, typ: *const [4]u8) !usize {
        const at = b.buf.items.len;
        try b.u32_(0);
        try b.bytes(typ);
        return at;
    }
    fn beginFull(b: Box, typ: *const [4]u8, version: u8, flags: u24) !usize {
        const at = try b.begin(typ);
        try b.u32_((@as(u32, version) << 24) | flags);
        return at;
    }
    fn end(b: Box, at: usize) void {
        std.mem.writeInt(u32, b.buf.items[at..][0..4], @intCast(b.buf.items.len - at), .big);
    }
};

const unity_matrix = [_]u32{ 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };

fn ftyp(b: Box) !void {
    const at = try b.begin("ftyp");
    try b.bytes("isom");
    try b.u32_(512);
    try b.bytes("isomiso2avc1mp41");
    b.end(at);
}

fn mvhd(b: Box, duration_ms: u64, next_track: u32) !void {
    const at = try b.beginFull("mvhd", 0, 0);
    try b.u32_(0); // criação
    try b.u32_(0); // modificação
    try b.u32_(1000);
    try b.u32_(@intCast(@min(duration_ms, std.math.maxInt(u32))));
    try b.u32_(0x00010000); // velocidade 1.0
    try b.u16_(0x0100); // volume 1.0
    try b.zeros(10);
    for (unity_matrix) |m| try b.u32_(m);
    try b.zeros(24);
    try b.u32_(next_track);
    b.end(at);
}

fn tkhd(b: Box, track: u32, duration_ms: u64, video: bool, w: u32, h: u32) !void {
    const at = try b.beginFull("tkhd", 0, 3); // ligada, no filme
    try b.u32_(0);
    try b.u32_(0);
    try b.u32_(track);
    try b.u32_(0);
    try b.u32_(@intCast(@min(duration_ms, std.math.maxInt(u32))));
    try b.zeros(8);
    try b.u16_(0); // camada
    try b.u16_(0); // grupo
    try b.u16_(if (video) 0 else 0x0100);
    try b.u16_(0);
    for (unity_matrix) |m| try b.u32_(m);
    try b.u32_(if (video) w << 16 else 0);
    try b.u32_(if (video) h << 16 else 0);
    b.end(at);
}

/// Lista de edição: a trilha começa `delay_ms` depois do começo do filme.
fn edts(b: Box, delay_ms: u64, duration_ms: u64) !void {
    if (delay_ms == 0) return;
    const at = try b.begin("edts");
    const el = try b.beginFull("elst", 0, 0);
    try b.u32_(2);
    try b.u32_(@intCast(delay_ms)); // vazio
    try b.u32_(0xFFFFFFFF); // media_time -1
    try b.u32_(0x00010000);
    try b.u32_(@intCast(@min(duration_ms, std.math.maxInt(u32))));
    try b.u32_(0); // a mídia desde o começo
    try b.u32_(0x00010000);
    b.end(el);
    b.end(at);
}

fn mdhd(b: Box, timescale: u32, duration: u64) !void {
    const at = try b.beginFull("mdhd", 0, 0);
    try b.u32_(0);
    try b.u32_(0);
    try b.u32_(timescale);
    try b.u32_(@intCast(@min(duration, std.math.maxInt(u32))));
    try b.u16_(0x55C4); // "und"
    try b.u16_(0);
    b.end(at);
}

fn hdlr(b: Box, video: bool) !void {
    const at = try b.beginFull("hdlr", 0, 0);
    try b.u32_(0);
    try b.bytes(if (video) "vide" else "soun");
    try b.zeros(12);
    try b.bytes(if (video) "telinha video\x00" else "telinha audio\x00");
    b.end(at);
}

fn dinf(b: Box) !void {
    const at = try b.begin("dinf");
    const dr = try b.beginFull("dref", 0, 0);
    try b.u32_(1);
    const u = try b.beginFull("url ", 0, 1); // dados no próprio arquivo
    b.end(u);
    b.end(dr);
    b.end(at);
}

/// RBSP (sem os bytes 03 de prevenção) dos primeiros `out.len` bytes da NAL.
fn unescape(nal: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    var zeros: usize = 0;
    for (nal) |byte| {
        if (n == out.len) break;
        if (zeros >= 2 and byte == 3) {
            zeros = 0;
            continue;
        }
        zeros = if (byte == 0) zeros + 1 else 0;
        out[n] = byte;
        n += 1;
    }
    return out[0..n];
}

/// hvc1 + hvcC (ISO 14496-15 §8.3): perfil/nível copiados do SPS; 4:2:0 8 bits.
fn hvc1(b: Box, w: u32, h: u32, ps: ParamSets) !void {
    const at = try b.begin("hvc1");
    try visualHeader(b, w, h);
    const cc = try b.begin("hvcC");
    // SPS: cabeçalho (2), vps_id/max_sub_layers/nesting (1), profile_tier_level
    var buf: [16]u8 = undefined;
    const r = unescape(ps.sps, &buf);
    if (r.len < 16) return error.BadSps;
    try b.u8_(1); // configurationVersion
    try b.u8_(r[3]); // profile_space, tier, profile_idc
    try b.bytes(r[4..8]); // compatibility flags
    try b.bytes(r[8..14]); // constraint flags
    try b.u8_(r[14]); // level_idc
    try b.u16_(0xF000); // min_spatial_segmentation_idc = 0
    try b.u8_(0xFC); // parallelismType = 0
    try b.u8_(0xFC | 1); // chroma 4:2:0
    try b.u8_(0xF8); // 8 bits
    try b.u8_(0xF8);
    try b.u16_(0); // avgFrameRate
    try b.u8_(0x0F); // 1 camada temporal, aninhada; tamanhos de 4 bytes
    try b.u8_(3); // VPS, SPS, PPS
    for ([_][]const u8{ ps.vps, ps.sps, ps.pps }) |nal| {
        try b.u8_(0x80 | hevcType(nal)); // array_completeness
        try b.u16_(1);
        try b.u16_(@intCast(nal.len));
        try b.bytes(nal);
    }
    b.end(cc);
    b.end(at);
}

/// Começo comum das entradas de vídeo (avc1/hvc1).
fn visualHeader(b: Box, w: u32, h: u32) !void {
    try b.zeros(6);
    try b.u16_(1); // data_reference_index
    try b.zeros(16);
    try b.u16_(@intCast(w));
    try b.u16_(@intCast(h));
    try b.u32_(0x00480000); // 72 dpi
    try b.u32_(0x00480000);
    try b.u32_(0);
    try b.u16_(1); // um quadro por amostra
    var name = [_]u8{0} ** 32;
    const n = "telinha";
    name[0] = n.len;
    @memcpy(name[1 .. 1 + n.len], n);
    try b.bytes(&name);
    try b.u16_(0x0018);
    try b.u16_(0xFFFF);
}

fn avc1(b: Box, w: u32, h: u32, ps: ParamSets) !void {
    const at = try b.begin("avc1");
    try visualHeader(b, w, h);
    // avcC
    const cc = try b.begin("avcC");
    try b.u8_(1);
    try b.u8_(if (ps.sps.len > 3) ps.sps[1] else 66); // perfil
    try b.u8_(if (ps.sps.len > 3) ps.sps[2] else 0);
    try b.u8_(if (ps.sps.len > 3) ps.sps[3] else 31); // nível
    try b.u8_(0xFF); // tamanhos de 4 bytes
    try b.u8_(0xE1); // 1 SPS
    try b.u16_(@intCast(ps.sps.len));
    try b.bytes(ps.sps);
    try b.u8_(1); // 1 PPS
    try b.u16_(@intCast(ps.pps.len));
    try b.bytes(ps.pps);
    // perfis High: 4:2:0, 8 bits (ISO 14496-15)
    const profile = if (ps.sps.len > 1) ps.sps[1] else 66;
    if (profile == 100 or profile == 110 or profile == 122 or profile == 144) {
        try b.u8_(0xFC | 1);
        try b.u8_(0xF8);
        try b.u8_(0xF8);
        try b.u8_(0);
    }
    b.end(cc);
    b.end(at);
}

/// Pacote Opus de 10 ms (dOps: 2 canais, 48 kHz).
fn opusEntry(b: Box) !void {
    const at = try b.begin("Opus");
    try b.zeros(6);
    try b.u16_(1);
    try b.zeros(8);
    try b.u16_(2); // canais
    try b.u16_(16);
    try b.u16_(0);
    try b.u16_(0);
    try b.u32_(48000 << 16);
    const d = try b.begin("dOps");
    try b.u8_(0);
    try b.u8_(2);
    try b.u16_(312); // pre-skip (o padrão do libopus)
    try b.u32_(48000);
    try b.u16_(0);
    try b.u8_(0);
    b.end(d);
    b.end(at);
}

fn stsd(b: Box, video: bool, w: u32, h: u32, ps: ParamSets) !void {
    const at = try b.beginFull("stsd", 0, 0);
    try b.u32_(1);
    if (!video) try opusEntry(b) else if (ps.hevc) try hvc1(b, w, h, ps) else try avc1(b, w, h, ps);
    b.end(at);
}

// ---------------------------------------------------------------------------
// Amostras já arrumadas (comum aos dois formatos)

const Track = struct {
    data: std.ArrayList(u8) = .empty, // amostras em sequência
    sizes: std.ArrayList(u32) = .empty,
    durations: std.ArrayList(u32) = .empty, // na timescale da trilha
    keys: std.ArrayList(bool) = .empty,
    start_us: u64 = 0, // hora da primeira amostra

    fn deinit(t: *Track) void {
        t.data.deinit(gpa);
        t.sizes.deinit(gpa);
        t.durations.deinit(gpa);
        t.keys.deinit(gpa);
    }
    fn count(t: *const Track) usize {
        return t.sizes.items.len;
    }
    fn total(t: *const Track) u64 {
        var s: u64 = 0;
        for (t.durations.items) |d| s += d;
        return s;
    }
};

fn usToTicks(us: u64, timescale: u64) u64 {
    return us * timescale / 1_000_000;
}

/// Vídeo: duração de cada quadro = até o próximo (a tela parada fica um
/// quadro só, longo). O último dura `last_us`.
fn buildVideo(t: *Track, samples: []const VideoSample, last_us: u64, hevc: bool) !void {
    t.start_us = samples[0].ts_us;
    var prev_us: u64 = 0;
    for (samples, 0..) |s, i| {
        // hora tem que crescer (quem chama já garante; aqui só por segurança)
        if (s.ts_us < prev_us) return error.TimeGoesBack;
        prev_us = s.ts_us;
        const before = t.data.items.len;
        try toAvcc(&t.data, s.data, hevc);
        const size = t.data.items.len - before;
        if (size == 0) continue;
        try t.sizes.append(gpa, @intCast(size));
        try t.keys.append(gpa, s.key);
        const next_us = if (i + 1 < samples.len) samples[i + 1].ts_us else s.ts_us + last_us;
        // em ticks a partir do começo (sem erro acumulado de arredondamento)
        const a = usToTicks(s.ts_us -| t.start_us, video_timescale);
        const b = usToTicks(@max(next_us, s.ts_us + 1000) -| t.start_us, video_timescale);
        try t.durations.append(gpa, @intCast(@max(b - a, 1)));
    }
}

/// Som: pacotes de 10 ms em sequência; buraco de silêncio (pacote que nem foi
/// enviado) vira pacote vazio. Começa no primeiro pacote depois de `from_us`.
fn buildAudio(t: *Track, samples: []const AudioSample, from_us: u64, until_us: u64) !void {
    var expect_us: u64 = 0;
    var toc: u8 = 0;
    for (samples) |s| {
        if (s.ts_us + 5_000 < from_us or s.ts_us > until_us or s.data.len == 0) continue;
        if (t.count() == 0) {
            t.start_us = @max(s.ts_us, from_us);
            expect_us = t.start_us;
        }
        // buraco: completa com pacotes vazios (código 0, frame de 0 bytes)
        while (s.ts_us >= expect_us + 15_000 and t.count() > 0) {
            try t.data.append(gpa, toc & 0xFC);
            try t.sizes.append(gpa, 1);
            try t.durations.append(gpa, audio_frame);
            try t.keys.append(gpa, true);
            expect_us += 10_000;
        }
        toc = s.data[0];
        try t.data.appendSlice(gpa, s.data);
        try t.sizes.append(gpa, @intCast(s.data.len));
        try t.durations.append(gpa, audio_frame);
        try t.keys.append(gpa, true);
        expect_us = @max(expect_us + 10_000, s.ts_us + 5_000);
    }
}

fn stbl(b: Box, t: *const Track, video: bool, w: u32, h: u32, ps: ParamSets, chunk_offset: u32) !void {
    const at = try b.begin("stbl");
    try stsd(b, video, w, h, ps);
    // stts: durações (agrupadas)
    {
        const s = try b.beginFull("stts", 0, 0);
        const n_at = b.buf.items.len;
        try b.u32_(0);
        var entries: u32 = 0;
        var i: usize = 0;
        while (i < t.durations.items.len) {
            var j = i + 1;
            while (j < t.durations.items.len and t.durations.items[j] == t.durations.items[i]) j += 1;
            try b.u32_(@intCast(j - i));
            try b.u32_(t.durations.items[i]);
            entries += 1;
            i = j;
        }
        std.mem.writeInt(u32, b.buf.items[n_at..][0..4], entries, .big);
        b.end(s);
    }
    if (video) {
        const s = try b.beginFull("stss", 0, 0);
        var keys: u32 = 0;
        for (t.keys.items) |k| keys += @intFromBool(k);
        try b.u32_(keys);
        for (t.keys.items, 0..) |k, i| if (k) try b.u32_(@intCast(i + 1));
        b.end(s);
    }
    {
        // um pedaço (chunk) só com todas as amostras; trilha vazia (gravação: as
        // amostras vêm nos fragmentos) não tem pedaço nenhum
        const s = try b.beginFull("stsc", 0, 0);
        if (t.count() > 0) {
            try b.u32_(1);
            try b.u32_(1);
            try b.u32_(@intCast(t.count()));
            try b.u32_(1);
        } else try b.u32_(0);
        b.end(s);
    }
    {
        const s = try b.beginFull("stsz", 0, 0);
        try b.u32_(0);
        try b.u32_(@intCast(t.count()));
        for (t.sizes.items) |z| try b.u32_(z);
        b.end(s);
    }
    {
        const s = try b.beginFull("stco", 0, 0);
        if (t.count() > 0) {
            try b.u32_(1);
            try b.u32_(chunk_offset);
        } else try b.u32_(0);
        b.end(s);
    }
    b.end(at);
}

fn trak(b: Box, track_id: u32, t: *const Track, video: bool, w: u32, h: u32, ps: ParamSets, chunk_offset: u32, movie_start_us: u64) !void {
    const timescale: u64 = if (video) video_timescale else audio_timescale;
    const dur_ms = t.total() * 1000 / timescale;
    const delay_ms = (t.start_us -| movie_start_us) / 1000;
    const at = try b.begin("trak");
    try tkhd(b, track_id, dur_ms + delay_ms, video, w, h);
    try edts(b, delay_ms, dur_ms);
    const md = try b.begin("mdia");
    try mdhd(b, @intCast(timescale), t.total());
    try hdlr(b, video);
    const mi = try b.begin("minf");
    if (video) {
        const v = try b.beginFull("vmhd", 0, 1);
        try b.zeros(8);
        b.end(v);
    } else {
        const sm = try b.beginFull("smhd", 0, 0);
        try b.zeros(4);
        b.end(sm);
    }
    try dinf(b);
    try stbl(b, t, video, w, h, ps, chunk_offset);
    b.end(mi);
    b.end(md);
    b.end(at);
}

fn writeAll(path: [:0]const u8, parts: []const []const u8) !void {
    const f = openFile(path, "wb") orelse return error.FileOpen;
    defer _ = cio.fclose(f);
    for (parts) |p| {
        if (p.len > 0 and cio.fwrite(p.ptr, 1, p.len, f) != p.len) return error.FileWrite;
    }
}

/// Clipe: MP4 normal com tudo o que veio. O primeiro quadro tem que ser IDR
/// (com SPS/PPS). Áudio pode faltar (lista vazia).
pub fn writeClip(path: [:0]const u8, w: u32, h: u32, video: []const VideoSample, audio_samples: []const AudioSample) !void {
    if (video.len == 0 or !video[0].key) return error.NoKeyframe;
    const ps = paramSets(video[0].data);
    if (!ps.complete()) return error.NoParamSets;
    var vt: Track = .{};
    defer vt.deinit();
    // último quadro: a média (ou 1/30 s)
    const span = video[video.len - 1].ts_us -| video[0].ts_us;
    const last_us: u64 = if (video.len > 1) @max(span / (video.len - 1), 10_000) else 33_333;
    try buildVideo(&vt, video, last_us, ps.hevc);
    var at: Track = .{};
    defer at.deinit();
    const end_us = video[video.len - 1].ts_us + last_us;
    try buildAudio(&at, audio_samples, video[0].ts_us, end_us);
    const has_audio = at.count() > 0;

    // moov primeiro (os offsets das amostras dependem do tamanho dele: monta
    // duas vezes, a segunda com o offset certo)
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    var offset: u32 = 0;
    for (0..2) |_| {
        head.clearRetainingCapacity();
        const b: Box = .{ .buf = &head };
        try ftyp(b);
        const mv = try b.begin("moov");
        const total_ms = (end_us - video[0].ts_us) / 1000;
        try mvhd(b, total_ms, if (has_audio) 3 else 2);
        try trak(b, 1, &vt, true, w, h, ps, offset + 8, video[0].ts_us);
        if (has_audio) try trak(b, 2, &at, false, 0, 0, .{}, offset + 8 + @as(u32, @intCast(vt.data.items.len)), video[0].ts_us);
        b.end(mv);
        offset = @intCast(head.items.len);
    }
    var mdat_hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, mdat_hdr[0..4], @intCast(8 + vt.data.items.len + at.data.items.len), .big);
    @memcpy(mdat_hdr[4..8], "mdat");
    try writeAll(path, &.{ head.items, &mdat_hdr, vt.data.items, at.data.items });
}

// ---------------------------------------------------------------------------
// Gravação (MP4 fragmentado)

pub const Recorder = struct {
    hevc: bool, // codec do arquivo (do primeiro IDR)
    file: *cio.FILE,
    w: u32,
    h: u32,
    with_audio: bool,
    seq: u32 = 1,
    start_us: u64,
    // amostras esperando o próximo fragmento
    video: std.ArrayList(VideoSample) = .empty,
    audio: std.ArrayList(AudioSample) = .empty,
    video_ticks: u64 = 0, // tempo de decodificação já escrito, por trilha
    audio_ticks: u64 = 0,
    audio_toc: u8 = 0,
    audio_next_us: u64 = 0,
    last_video_us: u64 = 0,
    frames: u64 = 0,
    bytes: u64 = 0,

    /// Começa a gravação num IDR (com SPS/PPS).
    pub fn start(path: [:0]const u8, w: u32, h: u32, first: VideoSample, with_audio: bool) !*Recorder {
        if (!first.key) return error.NoKeyframe;
        const ps = paramSets(first.data);
        if (!ps.complete()) return error.NoParamSets;
        const f = openFile(path, "wb") orelse return error.FileOpen;
        errdefer _ = cio.fclose(f);
        const r = try gpa.create(Recorder);
        errdefer gpa.destroy(r);
        r.* = .{ .hevc = ps.hevc, .file = f, .w = w, .h = h, .with_audio = with_audio, .start_us = first.ts_us, .audio_next_us = first.ts_us, .last_video_us = first.ts_us -| 1000 };
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(gpa);
        const b: Box = .{ .buf = &head };
        try ftyp(b);
        const mv = try b.begin("moov");
        try mvhd(b, 0, if (with_audio) 3 else 2);
        const empty: Track = .{};
        try trak(b, 1, &empty, true, w, h, ps, 0, 0);
        if (with_audio) try trak(b, 2, &empty, false, 0, 0, .{}, 0, 0);
        const mvex = try b.begin("mvex");
        const ids = [_]u32{ 1, 2 };
        for (ids[0..if (with_audio) 2 else 1]) |id| {
            const tx = try b.beginFull("trex", 0, 0);
            try b.u32_(id);
            try b.u32_(1);
            try b.u32_(0);
            try b.u32_(0);
            try b.u32_(0);
            b.end(tx);
        }
        b.end(mvex);
        b.end(mv);
        if (cio.fwrite(head.items.ptr, 1, head.items.len, f) != head.items.len) return error.FileWrite;
        try r.addVideo(first);
        return r;
    }

    fn own(data: []const u8) ![]u8 {
        return gpa.dupe(u8, data);
    }

    pub fn addVideo(r: *Recorder, s: VideoSample) !void {
        const ts = @max(s.ts_us, r.last_video_us + 1000); // sempre crescendo
        try r.video.append(gpa, .{ .data = try own(s.data), .ts_us = ts, .key = s.key });
        r.last_video_us = ts;
        // fragmento a cada ~2 s, sempre começando num ponto bom
        if (r.video.items.len > 1 and s.ts_us -| r.video.items[0].ts_us > 2_000_000) try r.flush(false);
    }

    pub fn addAudio(r: *Recorder, s: AudioSample) !void {
        if (!r.with_audio or s.ts_us + 5_000 < r.start_us or s.data.len == 0) return;
        try r.audio.append(gpa, .{ .data = try own(s.data), .ts_us = s.ts_us });
    }

    /// Escreve um fragmento com o que está esperando. O último quadro fica pro
    /// próximo (a duração dele depende de quando vem o seguinte), a não ser no fim.
    fn flush(r: *Recorder, final: bool) !void {
        const n_video = if (final) r.video.items.len else r.video.items.len - 1;
        if (n_video == 0) return;
        var vt: Track = .{};
        defer vt.deinit();
        const until_us = if (final) r.video.items[n_video - 1].ts_us + 33_333 else r.video.items[n_video].ts_us;
        // durações: até o próximo quadro (no fim, 1/30 s)
        for (r.video.items[0..n_video], 0..) |s, i| {
            const before = vt.data.items.len;
            try toAvcc(&vt.data, s.data, r.hevc);
            const size = vt.data.items.len - before;
            if (size == 0) continue;
            try vt.sizes.append(gpa, @intCast(size));
            try vt.keys.append(gpa, s.key);
            const next_us = if (i + 1 < r.video.items.len) r.video.items[i + 1].ts_us else s.ts_us + 33_333;
            const a = usToTicks(s.ts_us -| r.start_us, video_timescale);
            const b2 = usToTicks(@max(next_us, s.ts_us + 1000) -| r.start_us, video_timescale);
            try vt.durations.append(gpa, @intCast(@max(b2 - a, 1)));
        }
        // som até o mesmo ponto
        var at: Track = .{};
        defer at.deinit();
        var used_audio: usize = 0;
        if (r.with_audio) {
            for (r.audio.items) |s| {
                if (s.ts_us >= until_us) break;
                used_audio += 1;
                while (s.ts_us >= r.audio_next_us + 15_000) {
                    try at.data.append(gpa, r.audio_toc & 0xFC);
                    try at.sizes.append(gpa, 1);
                    try at.durations.append(gpa, audio_frame);
                    try at.keys.append(gpa, true);
                    r.audio_next_us += 10_000;
                }
                r.audio_toc = s.data[0];
                try at.data.appendSlice(gpa, s.data);
                try at.sizes.append(gpa, @intCast(s.data.len));
                try at.durations.append(gpa, audio_frame);
                try at.keys.append(gpa, true);
                r.audio_next_us = @max(r.audio_next_us + 10_000, s.ts_us + 5_000);
            }
        }
        try r.writeFragment(&vt, &at);
        r.video_ticks += vt.total();
        r.audio_ticks += at.total();
        r.frames += vt.count();
        for (r.video.items[0..n_video]) |s| gpa.free(s.data);
        std.mem.copyForwards(VideoSample, r.video.items[0 .. r.video.items.len - n_video], r.video.items[n_video..]);
        r.video.items.len -= n_video;
        for (r.audio.items[0..used_audio]) |s| gpa.free(s.data);
        std.mem.copyForwards(AudioSample, r.audio.items[0 .. r.audio.items.len - used_audio], r.audio.items[used_audio..]);
        r.audio.items.len -= used_audio;
    }

    fn writeFragment(r: *Recorder, vt: *const Track, at: *const Track) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const b: Box = .{ .buf = &buf };
        const moof = try b.begin("moof");
        const mf = try b.beginFull("mfhd", 0, 0);
        try b.u32_(r.seq);
        r.seq += 1;
        b.end(mf);
        var offsets: [2]usize = undefined; // onde está o data_offset de cada trun (acerta depois)
        var n_traf: usize = 0;
        for ([_]*const Track{ vt, at }, 0..) |t, ti| {
            if (t.count() == 0) continue;
            const video = ti == 0;
            const tf = try b.begin("traf");
            const th = try b.beginFull("tfhd", 0, 0x020000); // base = moof
            try b.u32_(if (video) 1 else 2);
            b.end(th);
            const td = try b.beginFull("tfdt", 1, 0);
            try b.u64_(if (video) r.video_ticks else r.audio_ticks);
            b.end(td);
            const tr = try b.beginFull("trun", 0, 0x000001 | 0x000100 | 0x000200 | 0x000400);
            try b.u32_(@intCast(t.count()));
            offsets[n_traf] = buf.items.len;
            n_traf += 1;
            try b.u32_(0); // data_offset (acertado abaixo)
            for (0..t.count()) |i| {
                try b.u32_(t.durations.items[i]);
                try b.u32_(t.sizes.items[i]);
                // sem dependência (IDR, som) ou depende de outro e não é ponto de entrada
                try b.u32_(if (t.keys.items[i]) 0x02000000 else 0x01010000);
            }
            b.end(tr);
            b.end(tf);
        }
        b.end(moof);
        const moof_size = buf.items.len;
        // dados: vídeo e depois som, num mdat só
        var k: usize = 0;
        var data_at: usize = moof_size + 8;
        for ([_]*const Track{ vt, at }) |t| {
            if (t.count() == 0) continue;
            std.mem.writeInt(u32, buf.items[offsets[k]..][0..4], @intCast(data_at), .big);
            data_at += t.data.items.len;
            k += 1;
        }
        const md = try b.begin("mdat");
        try b.bytes(vt.data.items);
        try b.bytes(at.data.items);
        b.end(md);
        if (cio.fwrite(buf.items.ptr, 1, buf.items.len, r.file) != buf.items.len) return error.FileWrite;
        _ = cio.fflush(r.file);
        r.bytes += buf.items.len;
    }

    /// Duração gravada até agora (ms).
    pub fn durationMs(r: *const Recorder) u64 {
        return (r.last_video_us -| r.start_us) / 1000;
    }

    /// Escreve o resto e fecha o arquivo.
    pub fn finish(r: *Recorder) void {
        r.flush(true) catch {};
        _ = cio.fclose(r.file);
        for (r.video.items) |s| gpa.free(s.data);
        for (r.audio.items) |s| gpa.free(s.data);
        r.video.deinit(gpa);
        r.audio.deinit(gpa);
        gpa.destroy(r);
    }
};
