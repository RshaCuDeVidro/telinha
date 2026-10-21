//! Cliente da sala: conexão cifrada, estado (membros, chat, ping, relógio)
//! e as transmissões assistidas (decodificação H.264).
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const udp = @import("udp.zig");
const crypto = @import("crypto.zig");
const codec = @import("codec.zig");
const gl = @import("gl.zig");
const audio = @import("audio.zig");
const voice = @import("voice.zig");
const clip = @import("clip.zig");
const debuglog = @import("debuglog.zig");
const connect_mod = @import("connect.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const gpa = proto.gpa;

/// A UI liga isso quando o shader de YUV→RGB compilou: aí a thread de decode
/// entrega os planos YUV (1,5 byte/pixel) e a GPU converte a cor.
pub var gpu_yuv = std.atomic.Value(bool).init(false);

/// `nv12_dev`: os planos estão na memória da placa (`Pic.dev`), não em `data`.
pub const Layout = enum { rgba, i420, nv12, nv12_dev };

/// Quadro NV12 na memória da placa (NVDEC → textura sem passar pela CPU):
/// luma em `ptr` (h linhas de `pitch`), croma logo depois (h/2 linhas).
/// Contado por referência: quem segura é o Pic (back/ready/front).
pub const DevBuf = struct {
    ptr: u64,
    pitch: u32,
    w: u32,
    h: u32,
    refs: std.atomic.Value(u32) = .init(0),

    pub fn uv(b: *const DevBuf) u64 {
        return b.ptr + @as(u64, b.pitch) * b.h;
    }
};

/// Um quadro decodificado pronto pra subir pra GPU.
pub const Pic = struct {
    data: []u8 = &.{}, // RGBA, ou planos YUV compactos (ver `layout`)
    layout: Layout = .rgba,
    w: u32 = 0,
    h: u32 = 0,
    ts: u64 = 0, // hora da captura (relógio da sala)
    dev: ?*DevBuf = null, // layout nv12_dev

    /// Solta o buffer da placa (se tiver); `data` continua alocado.
    pub fn dropDev(p: *Pic) void {
        if (p.dev) |d| _ = d.refs.fetchSub(1, .acq_rel);
        p.dev = null;
    }
};

/// NVDEC → textura direto (cudagl.c): ligado pela interface se o OpenGL é da
/// NVIDIA. Volta a false se uma cópia falhar (aí tudo segue pela CPU).
pub var gpu_interop = std.atomic.Value(bool).init(false);

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Codecs que esse PC decodifica (H.264 sempre; HEVC se a placa decodifica).
/// Testado uma vez por processo (abrir o decoder da placa leva ~100 ms).
var decode_codecs: std.atomic.Value(u8) = .init(0);

pub fn decodeCodecs() u8 {
    const known = decode_codecs.load(.acquire);
    if (known != 0) return known;
    var mask: u8 = proto.codecs_h264;
    if (getenv("TELINHA_SEM_HEVC") == null and codec.HwDecoder.supports(.hevc)) mask |= codec.Codec.hevc.bit();
    decode_codecs.store(mask, .release);
    return mask;
}
fn debugEnabled() bool {
    return sync.debugOn();
}

pub const Member = struct {
    pub fn versionSlice(m: *const Member) []const u8 {
        return m.version[0..m.version_len];
    }

    id: u32,
    name: [48]u8,
    name_len: usize,
    streaming: bool, // tela
    admin: bool,
    owner: bool, // criou a sala
    audio: bool,
    flags: u8,
    route: u8, // por onde chegou (proto.route_*)
    version: [16]u8 = undefined, // versão do app dela ("" = não contou)
    version_len: u8 = 0,
    w: u16,
    h: u16,
    fps: u8,
    cam_w: u16,
    cam_h: u16,
    cam_fps: u8,
    watching: [64]u32, // streams (o servidor manda até 64)
    n_watching: usize,

    pub fn nameSlice(self: *const Member) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn micOn(self: *const Member) bool {
        return self.flags & proto.member_mic != 0;
    }
    pub fn deaf(self: *const Member) bool {
        return self.flags & proto.member_deaf != 0;
    }
    /// Microfone silenciado pelo admin.
    pub fn muted(self: *const Member) bool {
        return self.flags & proto.member_muted != 0;
    }
    pub fn camera(self: *const Member) bool {
        return self.flags & proto.member_camera != 0;
    }
    pub fn noDraw(self: *const Member) bool {
        return self.flags & proto.member_no_draw != 0;
    }
    /// Essa transmissão (tela ou câmera) dela está no ar?
    pub fn live(self: *const Member, kind: u8) bool {
        return if (kind == proto.kind_camera) self.camera() else self.streaming;
    }
    pub fn isWatching(self: *const Member, stream: u32) bool {
        return std.mem.findScalar(u32, self.watching[0..self.n_watching], stream) != null;
    }
};

pub const ChatLine = struct {
    id: u32,
    from: u32,
    name: [48]u8,
    name_len: usize,
    text: []u8,
    hour: u8,
    minute: u8,
    history: bool, // já estava na sala antes da gente entrar
    img: ?[]u8 = null, // imagem: um quadro H.264 (decodifica na hora de mostrar)
    img_w: u16 = 0,
    img_h: u16 = 0,
    img_expired: bool = false, // era imagem, mas saiu do histórico da sala
    reacts: [32]React = undefined,
    n_reacts: u8 = 0,

    pub const React = struct { emoji: u8, from: u32 };

    pub fn nameSlice(self: *const ChatLine) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Quantas pessoas deram essa reação, e se `me` está entre elas.
    pub fn reactCount(self: *const ChatLine, emoji: u8, me: u32) struct { n: u32, mine: bool } {
        var n: u32 = 0;
        var mine = false;
        for (self.reacts[0..self.n_reacts]) |rc| {
            if (rc.emoji != emoji) continue;
            n += 1;
            if (rc.from == me) mine = true;
        }
        return .{ .n = n, .mine = mine };
    }

    fn setReact(self: *ChatLine, emoji: u8, from: u32, on: bool) void {
        for (self.reacts[0..self.n_reacts], 0..) |rc, i| {
            if (rc.emoji == emoji and rc.from == from) {
                if (!on) {
                    self.n_reacts -= 1;
                    self.reacts[i] = self.reacts[self.n_reacts];
                }
                return;
            }
        }
        if (on and self.n_reacts < self.reacts.len) {
            self.reacts[self.n_reacts] = .{ .emoji = emoji, .from = from };
            self.n_reacts += 1;
        }
    }

    fn free(self: *ChatLine) void {
        gpa.free(self.text);
        if (self.img) |im| gpa.free(im);
    }
};

/// Algo que o admin fez com a gente (a UI mostra e reage).
/// Um canal do servidor (lista que ele manda; ver proto.Type.channel).
/// O servidor provou quem é? (crypto.Identity)
pub const IdState = enum { unknown, verified, none, mismatch };

pub const ChanInfo = struct {
    name: [proto.channel_name_max]u8 = undefined,
    name_len: u8 = 0,
    people: u16 = 0,
    flags: u8 = 0, // proto.chan_*

    pub fn nameSlice(ch: *const ChanInfo) []const u8 {
        return ch.name[0..ch.name_len];
    }
};

/// Estatísticas do servidor (só pra quem entrou com o token de admin).
pub const ServerStats = struct {
    uptime_s: u32 = 0,
    cpu_permille: u32 = 0, // CPU do processo em milésimos de um núcleo
    cores: u8 = 1,
    rss_kb: u32 = 0,
    out_bps: u32 = 0, // bytes/s
    in_bps: u32 = 0,
    conns: u16 = 0,
    udp_conns: u16 = 0,
    max_members: u16 = 0,
    channels: u8 = 0,
    resyncs: u16 = 0, // na janela
    thins: u16 = 0,
    keyreqs: u16 = 0,
    slow: u16 = 0,
    window_ms: u32 = 0,
    flags: u8 = 0, // 1 = dentro do app, 2 = trancada, 4 = canais novos liberados
    n_people: usize = 0,
    people: [proto.stats_max_people]Person = undefined,

    pub const Person = struct {
        id: u32,
        name: [48]u8,
        name_len: u8,
        chan: [proto.channel_name_max]u8,
        chan_len: u8,
        route: u8,
        flags: u8, // proto.stats_*
        udp: bool,
        rtt_ms: u16,
        tx_bps: u32,
        rx_bps: u32,
        queued: u32,
        watching: u16,

        pub fn nameSlice(p: *const Person) []const u8 {
            return p.name[0..p.name_len];
        }
        pub fn chanSlice(p: *const Person) []const u8 {
            return p.chan[0..p.chan_len];
        }
    };

    pub fn hosted(st: *const ServerStats) bool {
        return st.flags & 1 != 0;
    }
};

const IncomingLog = struct {
    from: u32,
    id: u32,
    what: u8,
    total: u32,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    data: std.ArrayList(u8) = .empty,
};

pub const Notice = struct {
    kind: u8,
    extra: u8,
    text: [400]u8,
    len: usize,

    pub fn textSlice(n: *const Notice) []const u8 {
        return n.text[0..n.len];
    }
};

/// Ponteiro "olha aqui" de alguém em cima de uma transmissão.
pub const Pointer = struct {
    from: u32,
    stream: u32,
    x: u16,
    y: u16,
    flags: u8,
    at_us: u64, // quando chegou (some sozinho depois de um tempo parado)
    ping_us: u64, // último clique (anel que se expande)
};

/// Um traço desenhado por cima de uma transmissão (coordenadas 0..65535 no quadro).
pub const Stroke = struct {
    pub const max_points = 512;
    from: u32,
    stream: u32,
    n: u16 = 0,
    pts: [max_points][2]u16 = undefined,
    last_us: u64 = 0, // último ponto (o traço some uns segundos depois)
    style: u8 = 0, // cor e espessura (os bits altos das flags, proto.draw_*_shift)
};

pub const Status = enum { connecting, connected, failed };

/// Uma transmissão que estamos assistindo. Uma thread própria decodifica o
/// H.264 e converte pra RGBA (em paralelo no pool); a interface só sobe o
/// resultado pra GPU.
pub const View = struct {
    stream: u32, // proto.streamId (pessoa + tela/câmera)
    client: *Client,
    refs: std.atomic.Value(u32) = .init(2), // UI + thread de decode

    // Buffer triplo: o decode escreve no `back` sem trava e troca com o
    // `ready`; a UI troca o `ready` com o `front` e sobe o `front` pra GPU.
    // A trava (`mutex`) só cobre as trocas, nunca a conversão nem o upload.
    mutex: sync.Mutex = .{},
    back: Pic = .{}, // só a thread de decode
    ready: Pic = .{},
    fresh: bool = false, // o `ready` tem quadro que a UI ainda não pegou
    front: Pic = .{}, // só a UI
    w: u32 = 0, // tamanho do último quadro decodificado (estatística)
    h: u32 = 0,
    // onde está o cursor de quem transmite (proto.coord_none = sem cursor)
    cursor_x: std.atomic.Value(u16) = .init(proto.coord_none),
    cursor_y: std.atomic.Value(u16) = .init(proto.coord_none),
    /// O cursor não vem pintado no vídeo (frame_cursor_apart): a interface
    /// desenha a seta em cursor_x/cursor_y (atualizados também pela mensagem `cursor`).
    cursor_apart: std.atomic.Value(bool) = .init(false),
    /// Altura que a interface já disse pro servidor (view_size) e o maior
    /// tamanho visto na janela de medida atual (só a thread da UI mexe).
    view_sent_h: u16 = 0,
    view_peak_h: u32 = 0,
    view_peak_since_ms: u64 = 0,
    view_lower_since_ms: u64 = 0,

    qmutex: sync.Mutex = .{},
    amutex: sync.Mutex = .{}, // som da transmissão (separado da fila de quadros: não disputam)
    audio_stop: bool = false,
    qcond: sync.Cond = .{},
    frames: std.ArrayList([]u8) = .empty,
    arrivals: std.ArrayList(u64) = .empty, // hora (µs) em que cada quadro da fila chegou
    stop: bool = false,
    waiting_key: bool = true,

    // estatísticas
    fps: f32 = 0,
    kbps: f32 = 0,
    decode_ms: f32 = 0,
    decoder_name: []const u8 = "",
    codec: codec.Codec = .h264, // codec da transmissão (o último quadro)
    latency_ms: f32 = 0, // escrita pela UI quando o quadro vai pra tela
    stat_frames: u32 = 0,
    stat_bytes: u64 = 0,
    stat_since: u64 = 0,
    last_shown_us: u64 = 0, // último quadro entregue pra tela
    /// Quando chegou (decodificado) o último quadro, em ms: as estatísticas só
    /// são recalculadas quando chega quadro, então sem isso o "60 fps" ficava
    /// na tela pra sempre depois que a imagem parava.
    last_frame_ms: std.atomic.Value(u64) = .init(0),

    /// Os últimos ~30 s (clipe) e a gravação. null = clipes desligados.
    clip: ?*clip.Buffer = null,
    clip_key_us: u64 = 0, // último IDR que chegou (clipe curto pede mais)
    clip_req_us: u64 = 0,

    // áudio (a thread de rede decodifica, o mixer toca)
    audio_ring: audio.Ring = .{},
    audio_dec: ?audio.Decoder = null,
    audio_registered: bool = false,

    /// Buffers na placa (nv12_dev), reaproveitados; só a thread de decode
    /// escolhe, e só vão embora com o View (a UI pode estar copiando de um).
    dev_pool: [5]?*DevBuf = .{null} ** 5,

    // GPU (só a thread da UI mexe)
    yuv: gl.YuvRenderer.Target = .{},
    gl_stale: bool = false, // quadro novo que ainda não foi pra placa (não estava aparecendo)
    disp_px_w: u32 = 0, // tamanho em que apareceu no último desenho (pixels; 0 = não apareceu)
    disp_px_h: u32 = 0,
    tex: u32 = 0,
    tex_w: u32 = 0,
    tex_h: u32 = 0,

    /// Há quanto tempo (ms) não chega quadro novo (0 = nunca chegou ou chegou agora).
    pub fn idleMs(v: *const View) u64 {
        const l = v.last_frame_ms.load(.acquire);
        return if (l == 0) 0 else sync.nowMs() -| l;
    }
    /// q/s e KB/s pra mostrar: zero se não chega quadro há mais de 1,5 s.
    pub fn shownFps(v: *const View) f32 {
        return if (v.idleMs() > 1500) 0 else v.fps;
    }
    pub fn shownKbps(v: *const View) f32 {
        return if (v.idleMs() > 1500) 0 else v.kbps;
    }

    pub fn member(v: *const View) u32 {
        return proto.memberOf(v.stream);
    }
    pub fn kind(v: *const View) u8 {
        return proto.kindOf(v.stream);
    }

    fn retain(v: *View) *View {
        _ = v.refs.fetchAdd(1, .monotonic);
        return v;
    }

    pub fn release(v: *View) void {
        if (v.refs.fetchSub(1, .acq_rel) == 1) {
            if (v.audio_dec) |*d| d.deinit();
            if (v.clip) |cb| cb.destroy();
            v.audio_ring.deinit();
            for (v.frames.items) |f| gpa.free(f);
            v.frames.deinit(gpa);
            v.arrivals.deinit(gpa);
            for ([_][]u8{ v.back.data, v.ready.data, v.front.data }) |d| gpa.free(d);
            for (v.dev_pool) |maybe| if (maybe) |b| {
                gl.cudagl_free(gl.cudagl, b.ptr);
                gpa.destroy(b);
            };
            v.client.release();
            gpa.destroy(v);
        }
    }

    /// Atraso máximo esperando o decoder antes de desistir e pedir um IDR.
    /// Folga pra um soluço (um IDR grande demora mais), sem deixar acumular.
    const max_decode_backlog_us = 150_000;

    fn enqueue(v: *View, frame: []u8) void {
        if (frame.len > 4) v.cursor_apart.store(frame[4] & proto.frame_cursor_apart != 0, .release);
        // clipe/gravação: guarda o quadro como veio (antes de qualquer descarte do decoder)
        if (v.clip) |cb| {
            if (frame.len > proto.frame_header_len) {
                const flags = frame[4];
                const ts = std.mem.readInt(u64, frame[5..13], .little);
                const fw = std.mem.readInt(u16, frame[13..15], .little);
                const fh = std.mem.readInt(u16, frame[15..17], .little);
                const key = flags & proto.frame_key != 0;
                cb.addVideo(frame[proto.frame_header_len..], ts, key, fw, fh, codec.Codec.fromFlags(flags));
                // clipe curto (menos de 30 s): o servidor só pede IDR a cada
                // 20 s; aqui pede um a cada metade da duração (o clipe começa num)
                const now = sync.nowUs();
                if (key) v.clip_key_us = now;
                const half: u64 = @as(u64, clip.keep_secs.load(.monotonic)) * 500_000;
                if (half < 15_000_000 and v.clip_key_us != 0 and now - v.clip_key_us > half and now - v.clip_req_us > half) {
                    v.clip_req_us = now;
                    v.client.sendKeyreqReason(v.stream, proto.keyreq_record);
                }
                // gravação esperando o quadro completo: se o pedido se perdeu (o
                // servidor junta pedidos próximos), pede de novo
                if (!key and now - v.clip_req_us > 1_500_000 and cb.recState().waiting) {
                    v.clip_req_us = now;
                    v.client.sendKeyreqReason(v.stream, proto.keyreq_record);
                }
            }
        }
        v.qmutex.lock();
        defer v.qmutex.unlock();
        if (v.stop) {
            gpa.free(frame);
            return;
        }
        const now = sync.nowUs();
        // decode não está dando conta: descarta tudo e pede um IDR
        if (v.frames.items.len >= 30 or (v.arrivals.items.len > 0 and now - v.arrivals.items[0] > max_decode_backlog_us)) {
            for (v.frames.items) |f| gpa.free(f);
            v.frames.clearRetainingCapacity();
            v.arrivals.clearRetainingCapacity();
            v.waiting_key = true;
            v.client.sendKeyreq(v.stream);
        }
        v.arrivals.append(gpa, now) catch {
            gpa.free(frame);
            return;
        };
        v.frames.append(gpa, frame) catch {
            v.arrivals.items.len -= 1;
            gpa.free(frame);
            return;
        };
        v.qcond.signal();
    }

    /// Próximo quadro e se já tem outro esperando atrás dele.
    fn pop(v: *View) ?struct { []u8, bool } {
        v.qmutex.lock();
        defer v.qmutex.unlock();
        while (v.frames.items.len == 0 and !v.stop) v.qcond.wait(&v.qmutex);
        if (v.stop) return null;
        _ = v.arrivals.orderedRemove(0);
        const f = v.frames.orderedRemove(0);
        return .{ f, v.frames.items.len > 0 };
    }

    fn shutdown(v: *View) void {
        v.qmutex.lock();
        v.stop = true;
        v.qcond.broadcast();
        v.qmutex.unlock();
        v.amutex.lock();
        v.audio_stop = true;
        v.amutex.unlock();
        // depois de `audio_stop`, ninguém mais registra no mixer; tira se já estava
        audio.mixer.remove(&v.audio_ring);
    }

    /// Pacote Opus recebido (thread de rede), com a hora da captura.
    fn pushAudio(v: *View, packet: []const u8, ts_us: u64) void {
        if (v.clip) |cb| cb.addAudio(packet, ts_us);
        v.amutex.lock();
        defer v.amutex.unlock();
        if (v.audio_stop) return;
        if (v.audio_dec == null) v.audio_dec = audio.Decoder.init() catch return;
        const pcm = v.audio_dec.?.decode(packet) catch return;
        v.audio_ring.write(pcm);
        if (!v.audio_registered) {
            v.audio_registered = true;
            audio.mixer.add(&v.audio_ring);
        }
    }

    /// Decoder em uso: em hardware (NVDEC, VA-API, Media Foundation) ou openh264.
    const Decoder = union(enum) {
        hw: codec.HwDecoder,
        sw: codec.Decoder,
        none: void, // codec que esse PC não decodifica (espera a sala voltar pro H.264)

        fn deinit(d: *Decoder) void {
            switch (d.*) {
                .none => {},
                inline else => |*x| x.deinit(),
            }
        }

        /// Decoder pra esse codec: H.264 na placa (se der) ou openh264; HEVC/AV1 só na placa.
        fn open(cd: codec.Codec, hw_ok: bool) Decoder {
            var err: [256]u8 = undefined;
            if (hw_ok or cd != .h264) {
                if (codec.HwDecoder.init(cd, &err)) |h| return .{ .hw = h } else |_| {}
            }
            if (cd != .h264) return .none;
            return .{ .sw = codec.Decoder.init() catch return .none };
        }
    };

    fn decodeLoop(v: *View) void {
        sync.nameThread("decoder");
        defer v.release();
        var dec_codec: codec.Codec = .h264;
        var dec = Decoder.open(.h264, v.client.hw_decode);
        if (dec == .none) return;
        defer dec.deinit();
        v.decoder_name = switch (dec) {
            .hw => |*h| h.name(),
            .sw => "openh264",
            .none => "nenhum",
        };
        v.stat_since = sync.nowMs();
        while (v.pop()) |item| {
            const frame, const behind = item;
            defer gpa.free(frame);
            // a transmissão trocou de codec (alguém entrou sem HEVC, ou saiu): outro decoder
            if (frame.len > 4) {
                const cd = codec.Codec.fromFlags(frame[4]);
                if (cd != dec_codec) {
                    dec.deinit();
                    dec = Decoder.open(cd, v.client.hw_decode);
                    dec_codec = cd;
                    v.decoder_name = switch (dec) {
                        .hw => |*h| h.name(),
                        .sw => "openh264",
                        .none => "nenhum",
                    };
                    v.codec = cd;
                    v.qmutex.lock();
                    v.waiting_key = true;
                    v.qmutex.unlock();
                }
            }
            if (dec == .none) continue; // espera um codec que dê
            v.decodeFrame(&dec, frame, behind) catch {
                // perdeu referência ou veio lixo: recomeça do próximo IDR
                if (dec == .hw) {
                    // erro no decoder em hardware: segue com o openh264 daqui pra frente
                    if (codec.Decoder.init()) |sw| {
                        dec.deinit();
                        dec = .{ .sw = sw };
                        v.decoder_name = "openh264";
                    } else |_| {}
                }
                v.qmutex.lock();
                v.waiting_key = true;
                v.qmutex.unlock();
                v.client.sendKeyreq(v.stream);
            };
        }
    }

    /// Um buffer da placa livre (ninguém segurando) do tamanho pedido; aloca
    /// se precisar. null = sem CUDA ou todos ocupados (aí o quadro sai pela CPU).
    fn pickDevBuf(v: *View, w: u32, h: u32) ?*DevBuf {
        const g = gl.cudagl orelse return null;
        var empty: ?usize = null;
        for (&v.dev_pool, 0..) |*slot, i| {
            const b = slot.* orelse {
                if (empty == null) empty = i;
                continue;
            };
            if (b.refs.load(.acquire) != 0) continue;
            if (b.w == w and b.h == h) return b;
            // tamanho velho: solta e aloca de novo
            gl.cudagl_free(g, b.ptr);
            gpa.destroy(b);
            slot.* = null;
            if (empty == null) empty = i;
        }
        const i = empty orelse return null;
        var pitch: c_int = 0;
        const ptr = gl.cudagl_alloc(g, @intCast(w), @intCast(h + h / 2), &pitch);
        if (ptr == 0) return null;
        const b = gpa.create(DevBuf) catch {
            gl.cudagl_free(g, ptr);
            return null;
        };
        b.* = .{ .ptr = ptr, .pitch = @intCast(pitch), .w = w, .h = h };
        v.dev_pool[i] = b;
        return b;
    }

    /// `behind`: já tem quadro mais novo esperando — decodifica (precisa pra
    /// referência) mas não gasta tempo entregando uma imagem que vai ser
    /// substituída em seguida. Só que um decoder que vive atrás (CPU fraca)
    /// sempre tem quadro esperando: aí entrega um a cada 50 ms mesmo assim.
    fn decodeFrame(v: *View, dec: *Decoder, frame: []const u8, behind: bool) !void {
        const t0 = sync.nowUs();
        var r: proto.Reader = .{ .data = frame };
        _ = try r.u32_(); // seq
        const flags = try r.u8_();
        const ts = try r.u64_();
        const fw = try r.u16_(); // tamanho anunciado (o decoder confere)
        const fh = try r.u16_();
        v.cursor_x.store(try r.u16_(), .monotonic);
        v.cursor_y.store(try r.u16_(), .monotonic);
        const bitstream = r.rest();
        const key = flags & proto.frame_key != 0;

        v.qmutex.lock();
        const waiting = v.waiting_key;
        if (key) v.waiting_key = false;
        v.qmutex.unlock();
        if (waiting and !key) return; // sem referência ainda: espera o IDR

        const Out = union(enum) { i420: codec.Decoder.Picture, nv12: codec.HwDecoder.Frame };
        // NVIDIA: o quadro vai do NVDEC pra um buffer da placa e de lá pra
        // textura, sem passar pela CPU (nv12_dev)
        const dev: ?*DevBuf = if (dec.* == .hw and gpu_interop.load(.acquire) and gpu_yuv.load(.acquire) and fw >= 2 and fh >= 2)
            v.pickDevBuf(fw, fh)
        else
            null;
        const decoded: ?Out = switch (dec.*) {
            .sw => |*d| if (try d.decode(bitstream)) |p| .{ .i420 = p } else null,
            .hw => |*d| if (dev) |db|
                (if (try d.decodeTo(bitstream, db.ptr, db.uv(), db.pitch, db.w, db.h)) |f| .{ .nv12 = f } else null)
            else
                (if (try d.decode(bitstream)) |f| .{ .nv12 = f } else null),
            .none => null,
        };
        const pic = decoded orelse {
            if (debugEnabled()) std.debug.print("[telinha] decoder não devolveu imagem (quadro {s}, {d} bytes)\n", .{ if (key) "IDR" else "P", bitstream.len });
            return;
        };
        v.stat_bytes += frame.len;
        if (behind and t0 - v.last_shown_us < 50_000) return;
        v.last_shown_us = t0;
        v.stat_frames += 1; // fps = quadros que foram pra tela
        const pw: u32 = switch (pic) {
            .i420 => |p| p.w,
            .nv12 => |f| f.w,
        };
        const ph: u32 = switch (pic) {
            .i420 => |p| p.h,
            .nv12 => |f| f.h,
        };
        {
            const gpu = gpu_yuv.load(.acquire);
            const on_device = pic == .nv12 and pic.nv12.on_device and dev != null;
            const layout: Layout = if (!gpu) .rgba else if (on_device) .nv12_dev else switch (pic) {
                .i420 => .i420,
                .nv12 => .nv12,
            };
            const n = @as(usize, pw) * ph;
            const need = if (layout == .rgba) n * 4 else n + n / 2;
            const b = &v.back;
            b.dropDev();
            if (on_device) {
                // já está na placa: o Pic só segura o buffer
                _ = dev.?.refs.fetchAdd(1, .acq_rel);
                b.* = .{ .data = b.data, .layout = .nv12_dev, .w = pw, .h = ph, .ts = ts, .dev = dev };
            } else {
                if (b.data.len != need) {
                    const px = try gpa.alloc(u8, need);
                    gpa.free(b.data);
                    b.data = px;
                }
                b.* = .{ .data = b.data, .layout = layout, .w = pw, .h = ph, .ts = ts };
            }
            if (!on_device) switch (pic) {
                .i420 => |p| if (gpu) {
                    // planos compactos (o decoder usa stride maior que a largura)
                    for (0..ph) |row| @memcpy(b.data[row * pw ..][0..pw], p.y[row * p.ys ..][0..pw]);
                    const cw = pw / 2;
                    const chh = ph / 2;
                    for (0..chh) |row| {
                        @memcpy(b.data[n + row * cw ..][0..cw], p.u[row * p.uvs ..][0..cw]);
                        @memcpy(b.data[n + n / 4 + row * cw ..][0..cw], p.v[row * p.uvs ..][0..cw]);
                    }
                } else codec.toRgba(p.y, p.u, p.v, p.ys, p.uvs, p.w, p.h, b.data),
                .nv12 => |f| if (gpu) {
                    @memcpy(b.data[0..n], f.y[0..n]);
                    @memcpy(b.data[n..][0 .. n / 2], f.uv[0 .. n / 2]);
                } else codec.nv12ToRgba(f.y, f.uv, f.w, f.h, b.data),
            };
            v.mutex.lock();
            std.mem.swap(Pic, &v.back, &v.ready);
            v.fresh = true;
            v.w = pw;
            v.h = ph;
            v.mutex.unlock();
        }
        v.client.wake();

        const dt = @as(f32, @floatFromInt(sync.nowUs() - t0)) / 1000.0;
        v.decode_ms = v.decode_ms * 0.9 + dt * 0.1;
        v.last_frame_ms.store(sync.nowMs(), .release);
        const now = sync.nowMs();
        if (now - v.stat_since >= 1000) {
            const secs = @as(f32, @floatFromInt(now - v.stat_since)) / 1000.0;
            v.fps = @as(f32, @floatFromInt(v.stat_frames)) / secs;
            v.kbps = @as(f32, @floatFromInt(v.stat_bytes)) / 1024.0 / secs;
            v.stat_frames = 0;
            v.stat_bytes = 0;
            v.stat_since = now;
        }
    }
};

pub const Client = struct {
    refs: std.atomic.Value(u32) = .init(1),
    /// Caminhos pra sala, em ordem de preferência (ver connect.zig).
    targets: [connect_mod.max_targets]connect_mod.Target = undefined,
    n_targets: usize = 0,
    /// Qual caminho ganhou a corrida (vale depois de conectar).
    via: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),
    name: [48]u8 = undefined,
    name_len: usize = 0,
    pass: [128]u8 = undefined,
    pass_len: usize = 0,
    admin_token: [64]u8 = undefined,
    admin_token_len: usize = 0,
    client_key: u64 = 0,
    wake_fn: *const fn () void,
    hw_decode: bool = true,

    sock: net.Socket = undefined,
    sock_ok: std.atomic.Value(bool) = .init(false),
    channel: crypto.Channel = undefined,
    queue: proto.SendQueue = .{},
    closing: std.atomic.Value(bool) = .init(false),
    /// Pedido de IDR do servidor, por tipo de transmissão (tela, câmera).
    keyreq: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    /// Codecs que a sala libera pra cada transmissão nossa (tela, câmera):
    /// o que todo mundo que assiste decodifica (mensagem `codec`).
    codecs_allowed: [2]std.atomic.Value(u8) = .{ .init(proto.codecs_h264), .init(proto.codecs_h264) },
    /// Recursos (feat_*) que todo mundo que assiste cada transmissão minha entende (codec).
    features_allowed: [2]std.atomic.Value(u8) = .{ .init(0), .init(0) },
    /// A maior altura em que alguém mostra cada transmissão minha (view_size; view_full = sem limite).
    view_want: [2]std.atomic.Value(u16) = .{ .init(proto.view_full), .init(proto.view_full) },
    /// Vídeo/som por UDP (a sala ofereceu e o caminho abriu); null = só TCP.
    udp: std.atomic.Value(?*udp.Link) = .init(null),
    /// Algum espectador não está dando conta da nossa taxa de bits: piso (% do
    /// alvo) até onde baixar. 0 = nenhum aviso pendente. Por tipo.
    viewer_slow: [2]std.atomic.Value(u8) = .{ .init(0), .init(0) },
    /// Nossos frames que o servidor ainda não confirmou (controle de banda), por tipo.
    inflight_mutex: sync.Mutex = .{},
    inflight: [2]proto.AckWindow = .{ .{}, .{} },
    /// Relógio da sala = relógio local + offset (µs). Sincronizado pelo ping.
    clock_offset: std.atomic.Value(i64) = .init(0),
    best_rtt_us: u64 = std.math.maxInt(u64),

    /// Protege tudo abaixo.
    mutex: sync.Mutex = .{},
    status: Status = .connecting,
    /// Queda definitiva (expulso, senha errada, versão diferente): não adianta reconectar.
    final: bool = false,
    deny_code: u8 = proto.deny_generic, // por que a sala recusou/derrubou (quando final)
    err: [256]u8 = undefined,
    err_len: usize = 0,
    my_id: u32 = 0,
    is_admin: bool = false,
    route: u8 = proto.route_unknown, // por onde a gente chegou (o servidor que diz)
    room_locked: bool = false,
    room_name: [64]u8 = undefined,
    room_name_len: usize = 0,
    members: std.ArrayList(Member) = .empty,
    chat: std.ArrayList(ChatLine) = .empty,
    chat_count: u64 = 0, // total de mensagens já recebidas (pra rolar o chat)
    chat_new: u64 = 0, // mensagens novas (não de histórico) — notificação
    chat_react_gen: u32 = 0, // muda quando chega reação (a UI redesenha)
    /// Último id de mensagem visto (o histórico que chega depois não repete).
    chat_last_id: u32 = 0,
    instance: u64 = 0,
    server_version: [16]u8 = undefined, // versão do app/servidor que hospeda
    server_version_len: usize = 0,
    notices: std.ArrayList(Notice) = .empty,
    /// Logs chegando pela sala (somos o dono): remontados aqui até completar.
    incoming_logs: [4]?*IncomingLog = .{ null, null, null, null },
    log_seq: std.atomic.Value(u32) = .init(1),
    pointers: std.ArrayList(Pointer) = .empty,
    /// Traços desenhados por cima das transmissões (somem sozinhos; ver ui.zig).
    strokes: std.ArrayList(Stroke) = .empty,
    views: std.ArrayList(*View) = .empty,
    ping_ms: u32 = 0,
    /// Voz de cada pessoa da sala (criada quando chega o primeiro pacote).
    voice_peers: std.ArrayList(*voice.Peer) = .empty,
    /// Volume da voz escolhido por pessoa (vale também pra quem ainda não falou).
    voice_volumes: std.AutoHashMapUnmanaged(u32, f32) = .empty,
    /// Estado de voz que mandamos (reenviado ao reconectar).
    voice_flags: std.atomic.Value(u8) = .init(0),
    /// O servidor já aceitou (welcome). Antes disso, voz não sai: o primeiro
    /// pacote tem que ser o hello, e a voz fura a fila.
    welcomed: std.atomic.Value(bool) = .init(false),
    voice_seq: std.atomic.Value(u32) = .init(0),
    // canais (servidor antigo não manda: chans_supported fica false)
    chans_supported: bool = false,
    chan_name: [proto.channel_name_max]u8 = undefined, // em que canal a gente está
    chan_name_len: usize = 0,
    chans: [proto.max_channels]ChanInfo = undefined,
    n_chans: usize = 0,
    /// Muda a cada troca de canal: a UI para de assistir o que era do canal
    /// velho e o transmissor anuncia de novo (a transmissão vai junto).
    channel_gen: std.atomic.Value(u32) = .init(0),
    want_chan: [proto.channel_name_max]u8 = undefined, // o canal pedido ao entrar (hello)
    want_chan_len: usize = 0,
    stats: ServerStats = .{},
    // identidade do servidor (crypto.Identity)
    expect_fp: [crypto.fp_len]u8 = undefined,
    expect_fp_len: usize = 0,
    tofu: bool = false,
    transcript: [32]u8 = undefined,
    server_fp: [crypto.fp_len]u8 = undefined, // a que o servidor provou
    id_state: IdState = .unknown,
    stats_gen: u32 = 0, // muda a cada estatística que chega (0 = nenhuma ainda)

    pub const Options = struct {
        /// "host:porta" ou vários separados por vírgula (convite com vários caminhos).
        addrs: []const u8,
        name: []const u8,
        password: []const u8,
        admin_token: []const u8 = "",
        /// Identifica esse app (aleatória, guardada na config): banimento.
        client_key: u64 = 0,
        hw_decode: bool = true,
        /// Canal pra entrar (vazio = o padrão do servidor).
        channel: []const u8 = "",
        /// Impressão da identidade que o servidor tem que provar (do convite,
        /// ou a vista da última vez: `tofu`). Vazio = aceita a que vier.
        expect_fp: []const u8 = "",
        tofu: bool = false,
        wake: *const fn () void,
    };

    pub fn create(o: Options) !*Client {
        const cl = try gpa.create(Client);
        cl.* = .{ .wake_fn = o.wake, .hw_decode = o.hw_decode, .client_key = o.client_key };
        cl.n_targets = connect_mod.parseList(o.addrs, &cl.targets);
        if (cl.n_targets == 0) {
            gpa.destroy(cl);
            return error.BadAddress;
        }
        copyInto(cl.name[0..32], &cl.name_len, o.name);
        copyInto(&cl.pass, &cl.pass_len, o.password);
        copyInto(&cl.admin_token, &cl.admin_token_len, o.admin_token);
        copyInto(&cl.want_chan, &cl.want_chan_len, o.channel);
        copyInto(&cl.expect_fp, &cl.expect_fp_len, o.expect_fp);
        cl.tofu = o.tofu;
        _ = cl.refs.fetchAdd(1, .monotonic); // thread de conexão/leitura
        sync.spawn(connectLoop, .{cl}) catch {
            gpa.destroy(cl);
            return error.ThreadFailed;
        };
        return cl;
    }

    fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
        len.* = @min(src.len, dst.len);
        @memcpy(dst[0..len.*], src[0..len.*]);
    }

    pub fn wake(cl: *Client) void {
        cl.wake_fn();
    }

    pub fn isConnected(cl: *Client) bool {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        return cl.status == .connected;
    }

    pub fn retain(cl: *Client) *Client {
        _ = cl.refs.fetchAdd(1, .monotonic);
        return cl;
    }

    pub fn release(cl: *Client) void {
        if (cl.refs.fetchSub(1, .acq_rel) == 1) {
            cl.queue.deinit();
            cl.members.deinit(gpa);
            for (cl.chat.items) |*l| l.free();
            cl.chat.deinit(gpa);
            cl.notices.deinit(gpa);
            for (&cl.incoming_logs) |*sl| if (sl.*) |l| {
                l.data.deinit(gpa);
                gpa.destroy(l);
                sl.* = null;
            };
            cl.pointers.deinit(gpa);
            cl.strokes.deinit(gpa);
            cl.views.deinit(gpa);
            for (cl.voice_peers.items) |p| {
                p.deinit();
                gpa.destroy(p);
            }
            cl.voice_peers.deinit(gpa);
            cl.voice_volumes.deinit(gpa);
            if (cl.udp.load(.acquire)) |l| {
                net.close(l.sock);
                l.destroy();
            }
            gpa.destroy(cl);
        }
    }

    /// Sai da sala. As views precisam ser liberadas pela UI (texturas) antes.
    pub fn close(cl: *Client) void {
        cl.closing.store(true, .release);
        if (cl.sock_ok.load(.acquire)) net.shutdown(cl.sock);
        cl.queue.close();
        cl.release();
    }

    /// Relógio da sala em µs.
    pub fn serverNowUs(cl: *const Client) u64 {
        const local: i64 = @intCast(sync.nowUs());
        return @intCast(@max(0, local + cl.clock_offset.load(.monotonic)));
    }

    fn setFinal(cl: *Client) void {
        cl.mutex.lock();
        cl.final = true;
        cl.mutex.unlock();
    }

    fn setError(cl: *Client, comptime fmt: []const u8, args: anytype) void {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        cl.status = .failed;
        const s = i18n.bufPrint(&cl.err, fmt, args) catch cl.err[0..0];
        cl.err_len = s.len;
    }

    pub fn errSlice(cl: *Client) []const u8 {
        return cl.err[0..cl.err_len];
    }

    /// O caminho que ganhou (pra mostrar onde conectou).
    pub fn viaTarget(cl: *const Client) ?*const connect_mod.Target {
        const i = cl.via.load(.acquire);
        return if (i < cl.n_targets) &cl.targets[i] else null;
    }

    /// Versão do app que fala cada protocolo antigo (pra mensagem de erro).
    fn protoAppName(v: u16) []const u8 {
        return switch (v) {
            0...4 => "1.x",
            5 => "2.x",
            else => tr("anterior"),
        };
    }

    fn connectLoop(cl: *Client) void {
        sync.nameThread("rede");
        defer cl.release();
        defer cl.wake();
        // todos os caminhos do convite ao mesmo tempo (os primeiros com vantagem)
        var fail: connect_mod.Failure = .{ .err = error.ConnectFailed };
        const won = connect_mod.race(cl.targets[0..cl.n_targets], proto.version, 20_000, &cl.closing, &fail) catch |e| {
            switch (e) {
                error.Cancelled => {},
                error.VersionMismatch => {
                    cl.setFinal();
                    if (fail.server_version > proto.version)
                        cl.setError("A sala está numa versão mais nova do telinha (protocolo {d}; o seu {s} usa o {d}). Atualize o seu telinha.", .{ fail.server_version, proto.app_version, proto.version })
                    else
                        cl.setError("A sala está numa versão mais velha do telinha ({s}). Quem criou a sala precisa atualizar pro {s} ou mais novo.", .{ protoAppName(fail.server_version), proto.app_version });
                },
                error.NotTelinha => {
                    cl.setFinal();
                    cl.setError("Isso não é uma sala do telinha.", .{});
                },
                else => cl.setError("{s}", .{switch (e) {
                    error.UnknownHost => tr("Não achei esse endereço."),
                    error.ConnectionRefused => tr("Conexão recusada. A sala está aberta? O túnel está ligado?"),
                    else => tr("Não consegui conectar (a sala não respondeu por nenhum caminho)."),
                }}),
            }
            return;
        };
        cl.sock = won.sock;
        cl.via.store(@intCast(won.index), .release);
        if (cl.closing.load(.acquire)) {
            net.close(cl.sock);
            return;
        }
        cl.sock_ok.store(true, .release);
        cl.channel = crypto.Channel.derive(&won.hs, won.peer, true, cl.pass[0..cl.pass_len]) catch {
            cl.setError("Falha no handshake.", .{});
            net.close(cl.sock);
            return;
        };

        cl.transcript = crypto.transcript(crypto.myHello(&won.hs, proto.version), won.peer);

        // escritora
        _ = cl.refs.fetchAdd(1, .monotonic);
        sync.spawn(writerLoop, .{cl}) catch {
            _ = cl.refs.fetchSub(1, .monotonic);
            net.close(cl.sock);
            cl.setError("Falha ao criar thread.", .{});
            return;
        };

        var rb: proto.RecvBuf = .{};
        defer rb.deinit();
        // tem identidade esperada: o servidor prova quem é antes de a gente
        // mandar nome e token (quem estiver no meio não leva nada)
        if (cl.expect_fp_len > 0) {
            net.setRecvTimeout(cl.sock, 8000);
            const ok = blk: {
                const typ = proto.recvMsg(cl.sock, &cl.channel, &rb) catch |e| {
                    cl.setFinal();
                    if (e == error.AuthFailed or e == error.WrongPassword) {
                        cl.setError("Senha errada.", .{});
                    } else cl.setError("O servidor não provou quem é (versão antiga do telinha, ou alguém no meio do caminho). Não mandei nada.", .{});
                    break :blk false;
                };
                if (typ != .identity) {
                    cl.setFinal();
                    cl.setError("O servidor não provou quem é (versão antiga do telinha, ou alguém no meio do caminho). Não mandei nada.", .{});
                    break :blk false;
                }
                break :blk cl.checkIdentity(proto.payloadOf(&rb));
            };
            if (!ok) {
                cl.queue.close();
                net.shutdown(cl.sock);
                return;
            }
            net.setRecvTimeout(cl.sock, 0);
        }

        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.hello) catch return;
        b.str(cl.name[0..cl.name_len]) catch return;
        b.str(cl.admin_token[0..cl.admin_token_len]) catch return;
        b.u64_(cl.client_key) catch return;
        // TELINHA_VERSAO_TESTE: finge outra versão (testes do aviso de versão nova)
        b.str(if (getenv("TELINHA_VERSAO_TESTE")) |v| std.mem.span(v) else proto.app_version) catch return;
        b.u8_(if (cl.hw_decode) decodeCodecs() else proto.codecs_h264) catch return;
        b.u8_(proto.features_mine) catch return;
        b.str(cl.want_chan[0..cl.want_chan_len]) catch return;
        cl.queue.pushOwned(b.finish() catch return);

        while (!cl.closing.load(.acquire)) {
            const typ = proto.recvMsg(cl.sock, &cl.channel, &rb) catch |e| {
                // servidor novo manda a identidade primeiro: com a senha errada
                // ela não decifra (antes de entrar, isso só pode ser a senha)
                if (e == error.WrongPassword or (e == error.AuthFailed and !cl.welcomed.load(.acquire))) {
                    cl.setFinal();
                    cl.setError("Senha errada.", .{});
                }
                break;
            };
            cl.handle(typ, proto.payloadOf(&rb)) catch break;
            // quadro/som/voz não mudam a tela por si (o quadro acorda depois
            // de decodificado; a voz, quando alguém começa a falar)
            switch (typ) {
                .frame, .audio, .voice, .ack => {},
                else => cl.wake(),
            }
        }
        cl.mutex.lock();
        const was = cl.status;
        cl.mutex.unlock();
        if (was != .failed and !cl.closing.load(.acquire)) cl.setError("A conexão com a sala caiu.", .{});
        cl.queue.close();
        net.shutdown(cl.sock);
    }

    fn writerLoop(cl: *Client) void {
        sync.nameThread("rede-envio");
        defer cl.release();
        cl.queue.writerLoop(cl.sock, &cl.channel, &cl.udp);
        // a escritora sai por último: fecha o socket
        net.close(cl.sock);
    }

    fn startUdp(cl: *Client, token: u32) void {
        const sock = net.udpConnectLike(cl.sock) catch return;
        const l = udp.Link.create(token, cl.channel.send_key, cl.channel.recv_key, sock, false) catch {
            net.close(sock);
            return;
        };
        cl.udp.store(l, .release);
        _ = cl.refs.fetchAdd(1, .monotonic);
        sync.spawn(udpLoop, .{ cl, l }) catch {
            _ = cl.refs.fetchSub(1, .monotonic);
        };
    }

    /// Thread do UDP: abre o caminho (hello até a sala responder), recebe
    /// quadro/som/voz, pede reenvio do que falta e mantém o NAT aberto. Se a
    /// sala para de responder, volta pro TCP e continua tentando.
    fn udpLoop(cl: *Client, l: *udp.Link) void {
        sync.nameThread("udp");
        defer cl.release();
        var timeout_ms: u32 = 10;
        net.setRecvTimeout(l.sock, timeout_ms);
        const wire: udp.Wire = .{ .sock = l.sock };
        var buf: [2048]u8 = undefined;
        var last_hello: u64 = 0;
        var last_ping: u64 = 0;
        var last_tick: u64 = 0;
        var hellos: u32 = 0;
        while (!cl.closing.load(.acquire)) {
            const now = sync.nowMs();
            if (!l.isActive()) {
                // no começo, rápido; depois de desistir, de vez em quando
                const every: u64 = if (hellos < 12) 250 else 3000;
                if (now - last_hello >= every) {
                    l.ep.sendHello(wire);
                    last_hello = now;
                    hellos += 1;
                }
            } else if (now - last_ping >= 1000) {
                l.ep.sendPing(wire);
                last_ping = now;
                if (now -| l.ep.last_rx_ms.load(.monotonic) > 5000) {
                    l.active.store(false, .release); // a escritora volta pro TCP
                    hellos = 0;
                    if (debugEnabled()) std.debug.print("[telinha] UDP parou de responder: voltando pro TCP\n", .{});
                }
            }
            if (net.udpRecvFrom(l.sock, &buf, null)) |n| {
                if (l.ep.handle(wire, buf[0..n], deliverUdp, cl) == .hello_ok and !l.isActive()) {
                    l.active.store(true, .release);
                    if (debugEnabled()) std.debug.print("[telinha] vídeo e som por UDP (RTT {d} ms)\n", .{l.ep.rttMs()});
                }
            }
            const busy = l.ep.busy();
            if (busy and now - last_tick >= 10) {
                last_tick = now;
                l.ep.tick(wire, deliverUdp, cl);
            }
            // dorme até ter o que fazer: reenvio pendente (10 ms), próximo
            // hello ou próximo ping — datagrama que chega acorda na hora
            const want: u32 = if (busy) 10 else if (!l.isActive()) 250 else @intCast(std.math.clamp(1000 -| (sync.nowMs() -| last_ping), 10, 1000));
            if (want != timeout_ms) {
                timeout_ms = want;
                net.setRecvTimeout(l.sock, timeout_ms);
            }
        }
    }

    fn deliverUdp(ctx: *anyopaque, typ: proto.Type, payload: []const u8) void {
        const cl: *Client = @ptrCast(@alignCast(ctx));
        switch (typ) {
            .frame, .audio, .voice => cl.handle(typ, payload) catch {},
            else => {},
        }
    }

    /// Alguém (fora a gente) está assistindo esse stream? (lista de membros)
    pub fn anyoneWatching(cl: *Client, stream: u32) bool {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.members.items) |*m| {
            if (m.id != cl.my_id and m.isWatching(stream)) return true;
        }
        return false;
    }

    pub fn myId(cl: *Client) u32 {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        return cl.my_id;
    }

    /// Vídeo/som estão indo por UDP agora?
    pub fn udpActive(cl: *Client) bool {
        const l = cl.udp.load(.acquire) orelse return false;
        return l.isActive();
    }

    fn pingLoop(cl: *Client) void {
        sync.nameThread("ping");
        defer cl.release();
        var n: u32 = 0;
        while (!cl.closing.load(.acquire)) : (n += 1) {
            const m = proto.Msg.alloc(.ping, 8) catch return;
            std.mem.writeInt(u64, m.payload()[0..8], sync.nowUs(), .little);
            cl.queue.pushOwned(m);
            // os primeiros pings vêm rápido pra sincronizar o relógio logo
            // (em fatias de 500 ms: só pra perceber a saída da sala)
            const wait: u32 = if (n < 5) 1 else 4;
            const slice: u32 = if (n < 5) 200 else 500;
            var i: u32 = 0;
            while (i < wait and !cl.closing.load(.acquire)) : (i += 1) sync.sleepMs(slice);
        }
    }

    fn onPong(cl: *Client, t: u64, server_us: u64) void {
        const now = sync.nowUs();
        const rtt = now -| t;
        // estimativa: o servidor leu o relógio no meio do caminho
        const offset: i64 = @as(i64, @intCast(server_us)) + @as(i64, @intCast(rtt / 2)) - @as(i64, @intCast(now));
        // confia mais nas medições com RTT baixo
        if (rtt <= cl.best_rtt_us +| 2000) {
            cl.best_rtt_us = @min(cl.best_rtt_us, rtt);
            const old = cl.clock_offset.load(.monotonic);
            const new = if (old == 0) offset else old + @divTrunc(offset - old, 4);
            cl.clock_offset.store(new, .monotonic);
        }
        cl.best_rtt_us +|= 200; // deixa a referência "envelhecer" se a rede mudar
        cl.mutex.lock();
        cl.ping_ms = @intCast(@min(rtt / 1000, 99999));
        cl.mutex.unlock();
    }

    fn handle(cl: *Client, typ: proto.Type, payload: []const u8) !void {
        var r: proto.Reader = .{ .data = payload };
        switch (typ) {
            .welcome => {
                cl.mutex.lock();
                defer cl.mutex.unlock();
                cl.my_id = try r.u32_();
                const rn = try r.str();
                copyInto(&cl.room_name, &cl.room_name_len, rn);
                cl.is_admin = (try r.u8_()) != 0;
                const server_us = try r.u64_();
                cl.instance = try r.u64_();
                cl.route = try r.u8_();
                const sv = r.str() catch "";
                cl.server_version_len = @min(sv.len, cl.server_version.len);
                @memcpy(cl.server_version[0..cl.server_version_len], sv[0..cl.server_version_len]);
                // a sala oferece UDP pro vídeo/som: abre o caminho (se não der, fica no TCP)
                if ((r.u8_() catch 0) == 1) {
                    const token = r.u32_() catch 0;
                    if (token != 0 and getenv("TELINHA_SEM_UDP") == null and cl.udp.load(.acquire) == null) cl.startUdp(token);
                }
                cl.clock_offset.store(@as(i64, @intCast(server_us)) - @as(i64, @intCast(sync.nowUs())), .monotonic);
                cl.status = .connected;
                // servidor sem identidade (versão antiga, ou sem chave): nada a conferir
                if (cl.id_state == .unknown) cl.id_state = .none;
                cl.welcomed.store(true, .release);
                _ = cl.refs.fetchAdd(1, .monotonic);
                sync.spawn(pingLoop, .{cl}) catch {
                    _ = cl.refs.fetchSub(1, .monotonic);
                };
                const vf = cl.voice_flags.load(.monotonic);
                if (vf != 0) cl.pushVoiceState(vf);
            },
            .denied => {
                const reason = try r.str();
                const code: u8 = r.u8_() catch proto.deny_generic;
                cl.mutex.lock();
                cl.deny_code = code;
                cl.mutex.unlock();
                cl.setFinal();
                // o motivo vem do servidor em português
                var rb: [256]u8 = undefined;
                cl.setError("{s}", .{i18n.server(reason, &rb)});
                return error.Denied;
            },
            .members => {
                const room_flags = try r.u8_();
                const n = try r.u16_();
                var list: std.ArrayList(Member) = .empty;
                errdefer list.deinit(gpa);
                for (0..n) |_| {
                    var m: Member = undefined;
                    m.id = try r.u32_();
                    const nm = try r.str();
                    copyInto(&m.name, &m.name_len, nm);
                    const flags = try r.u8_();
                    m.flags = flags;
                    m.streaming = flags & proto.member_streaming != 0;
                    m.admin = flags & proto.member_admin != 0;
                    m.audio = flags & proto.member_audio != 0;
                    const route = try r.u8_();
                    m.owner = route & 0x80 != 0;
                    m.route = route & 0x7F;
                    m.w = try r.u16_();
                    m.h = try r.u16_();
                    m.fps = try r.u8_();
                    m.cam_w = try r.u16_();
                    m.cam_h = try r.u16_();
                    m.cam_fps = try r.u8_();
                    const k = try r.u16_();
                    m.n_watching = 0;
                    for (0..k) |_| {
                        const id = try r.u32_();
                        if (m.n_watching < m.watching.len) {
                            m.watching[m.n_watching] = id;
                            m.n_watching += 1;
                        }
                    }
                    m.version_len = 0;
                    try list.append(gpa, m);
                }
                for (list.items) |*m| {
                    const v = r.str() catch break;
                    m.version_len = @intCast(@min(v.len, m.version.len));
                    @memcpy(m.version[0..m.version_len], v[0..m.version_len]);
                }
                cl.mutex.lock();
                defer cl.mutex.unlock();
                cl.room_locked = room_flags & proto.room_locked != 0;
                cl.members.deinit(gpa);
                cl.members = list;
                // admin muda com a lista (alguém deu ou tirou)
                for (list.items) |*m| {
                    if (m.id == cl.my_id) cl.is_admin = m.admin;
                }
                // o admin tirou o pincel de alguém: os traços dessa pessoa somem
                var si: usize = cl.strokes.items.len;
                while (si > 0) {
                    si -= 1;
                    const from = cl.strokes.items[si].from;
                    for (list.items) |*m| if (m.id == from and m.noDraw()) {
                        _ = cl.strokes.orderedRemove(si);
                        break;
                    };
                }
                // voz de quem saiu da sala
                var i: usize = cl.voice_peers.items.len;
                while (i > 0) {
                    i -= 1;
                    const p = cl.voice_peers.items[i];
                    const still = for (list.items) |m| {
                        if (m.id == p.id) break true;
                    } else false;
                    if (!still) {
                        _ = cl.voice_peers.swapRemove(i);
                        p.deinit();
                        gpa.destroy(p);
                    }
                }
                // ponteiros de quem saiu, ou em transmissão que acabou
                var j: usize = cl.pointers.items.len;
                while (j > 0) {
                    j -= 1;
                    const pt = cl.pointers.items[j];
                    const ok = for (list.items) |*m| {
                        if (m.id == proto.memberOf(pt.stream)) break m.live(proto.kindOf(pt.stream));
                    } else false;
                    if (!ok) _ = cl.pointers.swapRemove(j);
                }
            },
            .voice => {
                const from = try r.u32_();
                const seq = try r.u32_();
                const packet = r.rest();
                if (packet.len == 0) return; // pro Opus, vazio = "perdi um pacote"
                cl.mutex.lock();
                var peer: ?*voice.Peer = null;
                for (cl.voice_peers.items) |p| if (p.id == from) {
                    peer = p;
                    break;
                };
                if (peer == null) {
                    // só de quem está na sala (um servidor ruim inventando ids
                    // criaria um decoder + 1 s de anel por id)
                    const known = for (cl.members.items) |*mb| {
                        if (mb.id == from) break true;
                    } else false;
                    if (!known or cl.voice_peers.items.len >= 64) {
                        cl.mutex.unlock();
                        return;
                    }
                    const p = gpa.create(voice.Peer) catch {
                        cl.mutex.unlock();
                        return;
                    };
                    p.* = .{ .id = from };
                    if (cl.voice_volumes.get(from)) |vol| p.ring.volume = vol;
                    cl.voice_peers.append(gpa, p) catch {
                        gpa.destroy(p);
                        cl.mutex.unlock();
                        return;
                    };
                    peer = p;
                }
                cl.mutex.unlock();
                // começou a falar: a interface acende a bolinha (parar ela vê sozinha)
                const was = peer.?.speaking(sync.nowUs());
                // só a thread de rede mexe na lista fora do lock (e ela está aqui)
                peer.?.push(seq, packet);
                if (!was) cl.wake();
            },
            .chat => {
                var line: ChatLine = undefined;
                line.id = try r.u32_();
                line.from = try r.u32_();
                copyInto(&line.name, &line.name_len, try r.str());
                const text = try r.str();
                const at_us = try r.u64_();
                const flags = try r.u8_();
                line.history = flags & proto.chat_history != 0;
                line.img = null;
                line.img_w = 0;
                line.img_h = 0;
                line.img_expired = false;
                line.n_reacts = 0;
                var img_bytes: ?[]const u8 = null;
                switch (r.u8_() catch proto.chat_img_none) {
                    proto.chat_img_h264 => {
                        line.img_w = try r.u16_();
                        line.img_h = try r.u16_();
                        const len = try r.u32_();
                        if (len > proto.chat_image_max or line.img_w > proto.chat_image_side or line.img_h > proto.chat_image_side) return error.BadMessage;
                        img_bytes = try r.take(len);
                    },
                    proto.chat_img_expired => line.img_expired = true,
                    else => {},
                }
                const n_reacts = r.u8_() catch 0;
                for (0..n_reacts) |_| {
                    const emoji = try r.u8_();
                    const from = try r.u32_();
                    if (emoji < proto.reactions) line.setReact(emoji, from, true);
                }
                cl.mutex.lock();
                defer cl.mutex.unlock();
                // histórico que já chegou (não deveria repetir, mas não custa)
                if (line.history and line.id <= cl.chat_last_id) return;
                if (line.id > cl.chat_last_id) cl.chat_last_id = line.id;
                // hora local de quando a mensagem foi mandada (a sala tem outro relógio)
                const age_s: i64 = @intCast((cl.serverNowUs() -| at_us) / 1_000_000);
                const t = sync.localTimeAgo(age_s);
                line.hour = t.h;
                line.minute = t.m;
                line.text = try gpa.dupe(u8, text);
                if (img_bytes) |ib| line.img = gpa.dupe(u8, ib) catch null;
                if (cl.chat.items.len >= 500) {
                    cl.chat.items[0].free();
                    _ = cl.chat.orderedRemove(0);
                }
                cl.chat.append(gpa, line) catch |e| {
                    line.free();
                    return e;
                };
                // no máximo ~24 MB de imagens guardadas (como o servidor): as
                // mais velhas viram "imagem antiga"
                var img_total: usize = 0;
                var k = cl.chat.items.len;
                while (k > 0) {
                    k -= 1;
                    const ln = &cl.chat.items[k];
                    const im = ln.img orelse continue;
                    img_total += im.len;
                    if (img_total > 24 * 1024 * 1024) {
                        gpa.free(im);
                        ln.img = null;
                        ln.img_expired = true;
                    }
                }
                cl.chat_count += 1;
                if (!line.history) cl.chat_new += 1;
            },
            .react => {
                const id = try r.u32_();
                const from = try r.u32_();
                const emoji = try r.u8_();
                const on = (try r.u8_()) != 0;
                if (emoji >= proto.reactions) return;
                cl.mutex.lock();
                defer cl.mutex.unlock();
                var i = cl.chat.items.len;
                while (i > 0) {
                    i -= 1;
                    if (cl.chat.items[i].id == id) {
                        cl.chat.items[i].setReact(emoji, from, on);
                        cl.chat_react_gen +%= 1;
                        break;
                    }
                }
            },
            .codec => {
                const kind = try r.u8_();
                const mask = try r.u8_();
                if (kind <= proto.kind_camera) {
                    cl.codecs_allowed[kind].store(mask | proto.codecs_h264, .release);
                    // servidor antigo não manda: nada de recurso novo
                    cl.features_allowed[kind].store(r.u8_() catch 0, .release);
                }
            },
            .view_size => {
                const kind = try r.u8_();
                const h = try r.u16_();
                if (kind <= proto.kind_camera) cl.view_want[kind].store(h, .release);
            },
            .cursor => {
                const v = cl.viewRetained(try r.u32_()) orelse return;
                defer v.release();
                v.cursor_x.store(try r.u16_(), .monotonic);
                v.cursor_y.store(try r.u16_(), .monotonic);
                cl.wake();
            },
            .frame => {
                const stream = try r.u32_();
                const frame = r.rest();
                if (frame.len < proto.frame_header_len) return error.BadMessage;
                // confirma na hora (o servidor mede o atraso do nosso download com isso)
                const ack = try proto.Msg.alloc(.ack, 8);
                std.mem.writeInt(u32, ack.payload()[0..4], stream, .little);
                @memcpy(ack.payload()[4..8], frame[0..4]);
                cl.queue.pushUrgentOwned(ack);
                const v = cl.viewRetained(stream) orelse return;
                defer v.release();
                v.enqueue(try gpa.dupe(u8, frame));
            },
            .ack => {
                const kind = try r.u8_();
                const seq = try r.u32_();
                if (kind > proto.kind_camera) return;
                cl.inflight_mutex.lock();
                defer cl.inflight_mutex.unlock();
                cl.inflight[kind].acked(seq, sync.nowUs());
            },
            .viewer_slow => {
                const kind = try r.u8_();
                const floor = try r.u8_();
                if (kind > proto.kind_camera) return;
                cl.viewer_slow[kind].store(std.math.clamp(floor, 1, 100), .release);
            },
            .audio => {
                const v = cl.viewRetained(try r.u32_()) orelse return;
                defer v.release();
                _ = try r.u32_(); // seq
                const ts = try r.u64_(); // hora da captura
                v.pushAudio(r.rest(), ts);
            },
            .keyreq => {
                const kind: u8 = r.u8_() catch proto.kind_screen;
                if (kind > proto.kind_camera) return;
                cl.keyreq[kind].store(true, .release);
            },
            .pong => {
                const t = try r.u64_();
                const server_us = try r.u64_();
                cl.onPong(t, server_us);
            },
            .log_chunk => try cl.onLogChunk(&r),
            .identity => if (cl.id_state == .unknown and !cl.checkIdentity(payload)) return error.Identity,
            .channel => try cl.onChannels(&r),
            .stats => try cl.onStats(&r),
            .log_ack => {
                _ = try r.u32_(); // id
                const result = try r.u8_();
                const count = r.u8_() catch 0;
                debuglog.roomAck(result, count);
            },
            .notice => {
                var n: Notice = .{ .kind = try r.u8_(), .extra = 0, .text = undefined, .len = 0 };
                copyInto(&n.text, &n.len, try r.str());
                n.extra = r.u8_() catch 0;
                cl.mutex.lock();
                defer cl.mutex.unlock();
                if (cl.notices.items.len < 32) try cl.notices.append(gpa, n);
            },
            .draw => {
                const from = try r.u32_();
                const stream = try r.u32_();
                const flags = try r.u8_();
                const n = try r.u16_();
                if (n > proto.draw_max_points) return error.BadMessage;
                var pts: [proto.draw_max_points][2]u16 = undefined;
                for (pts[0..n]) |*p| p.* = .{ try r.u16_(), try r.u16_() };
                cl.addDraw(from, stream, flags, pts[0..n]);
                cl.wake();
            },
            .pointer => {
                const from = try r.u32_();
                const stream = try r.u32_();
                const x = try r.u16_();
                const y = try r.u16_();
                const flags = try r.u8_();
                const now = sync.nowUs();
                cl.mutex.lock();
                defer cl.mutex.unlock();
                const found = for (cl.pointers.items) |*p| {
                    if (p.from == from) break p;
                } else null;
                const p = found orelse blk: {
                    if (cl.pointers.items.len >= 64) return;
                    try cl.pointers.append(gpa, .{ .from = from, .stream = stream, .x = 0, .y = 0, .flags = 0, .at_us = 0, .ping_us = 0 });
                    break :blk &cl.pointers.items[cl.pointers.items.len - 1];
                };
                p.stream = stream;
                p.x = x;
                p.y = y;
                p.flags = flags;
                p.at_us = now;
                if (flags & proto.pointer_ping != 0) p.ping_us = now;
            },
            else => {},
        }
    }

    /// Confere a identidade que o servidor mandou (a assinatura deste
    /// handshake e, se tiver, a impressão esperada). false = recusa (o erro já
    /// fica escrito, e não adianta reconectar).
    fn checkIdentity(cl: *Client, payload: []const u8) bool {
        if (payload.len < 96) return false;
        const public = payload[0..32].*;
        const sig = payload[32..96].*;
        if (!crypto.verifyIdentity(public, sig, cl.transcript)) {
            cl.setFinal();
            cl.setError("A assinatura do servidor não confere: alguém pode estar no meio do caminho. Não entrei.", .{});
            cl.id_state = .mismatch;
            return false;
        }
        const fp = crypto.fingerprint(public);
        cl.mutex.lock();
        cl.server_fp = fp;
        cl.mutex.unlock();
        if (cl.expect_fp_len > 0 and !std.mem.eql(u8, &fp, cl.expect_fp[0..cl.expect_fp_len])) {
            cl.id_state = .mismatch;
            cl.setFinal();
            if (cl.tofu)
                cl.setError("A identidade do servidor mudou desde a última vez ({s} → {s}). Se o dono reinstalou o servidor, confie na nova; senão, alguém pode estar no meio do caminho.", .{ cl.expect_fp[0..cl.expect_fp_len], &fp })
            else
                cl.setError("A identidade do servidor não bate com a do convite ({s}, o convite diz {s}): alguém pode estar no meio do caminho. Peça um convite novo.", .{ &fp, cl.expect_fp[0..cl.expect_fp_len] });
            return false;
        }
        cl.id_state = .verified;
        return true;
    }

    /// Em que canal a gente está e quais existem. Canal diferente do que a
    /// gente sabia = trocou: o chat recomeça (o servidor manda o histórico do
    /// canal novo logo depois).
    fn onChannels(cl: *Client, r: *proto.Reader) !void {
        const cur = try r.str();
        const n = try r.u8_();
        var list: [proto.max_channels]ChanInfo = undefined;
        var k: usize = 0;
        for (0..n) |_| {
            const nm = try r.str();
            const people = try r.u16_();
            const flags = try r.u8_();
            if (k == list.len) continue;
            list[k] = .{ .people = people, .flags = flags };
            const l = @min(nm.len, proto.channel_name_max);
            @memcpy(list[k].name[0..l], nm[0..l]);
            list[k].name_len = @intCast(l);
            k += 1;
        }
        cl.mutex.lock();
        defer cl.mutex.unlock();
        const changed = cl.chans_supported and !std.mem.eql(u8, cur, cl.chan_name[0..cl.chan_name_len]);
        cl.chans_supported = true;
        copyInto(&cl.chan_name, &cl.chan_name_len, cur);
        copyInto(&cl.want_chan, &cl.want_chan_len, cur); // reconectando, volta pra cá
        @memcpy(cl.chans[0..k], list[0..k]);
        cl.n_chans = k;
        if (!changed) return;
        for (cl.chat.items) |*l| l.free();
        cl.chat.clearRetainingCapacity();
        cl.chat_last_id = 0;
        cl.chat_count += 1;
        cl.pointers.clearRetainingCapacity();
        cl.strokes.clearRetainingCapacity();
        _ = cl.channel_gen.fetchAdd(1, .acq_rel);
        // a transmissão vai junto: o transmissor anuncia de novo e manda um IDR
        cl.keyreq[0].store(true, .release);
        cl.keyreq[1].store(true, .release);
    }

    fn onStats(cl: *Client, r: *proto.Reader) !void {
        var st: ServerStats = .{};
        st.uptime_s = try r.u32_();
        st.cpu_permille = try r.u32_();
        st.cores = try r.u8_();
        st.rss_kb = try r.u32_();
        st.out_bps = try r.u32_();
        st.in_bps = try r.u32_();
        st.conns = try r.u16_();
        st.udp_conns = try r.u16_();
        st.max_members = try r.u16_();
        st.channels = try r.u8_();
        st.resyncs = try r.u16_();
        st.thins = try r.u16_();
        st.keyreqs = try r.u16_();
        st.slow = try r.u16_();
        st.window_ms = try r.u32_();
        st.flags = try r.u8_();
        const n = try r.u16_();
        for (0..n) |_| {
            var p: ServerStats.Person = undefined;
            p.id = try r.u32_();
            const nm = try r.str();
            p.name_len = @intCast(@min(nm.len, p.name.len));
            @memcpy(p.name[0..p.name_len], nm[0..p.name_len]);
            const ch = try r.str();
            p.chan_len = @intCast(@min(ch.len, p.chan.len));
            @memcpy(p.chan[0..p.chan_len], ch[0..p.chan_len]);
            p.route = try r.u8_();
            p.flags = try r.u8_();
            p.udp = (try r.u8_()) != 0;
            p.rtt_ms = try r.u16_();
            p.tx_bps = try r.u32_();
            p.rx_bps = try r.u32_();
            p.queued = try r.u32_();
            p.watching = try r.u16_();
            if (st.n_people < st.people.len) {
                st.people[st.n_people] = p;
                st.n_people += 1;
            }
        }
        cl.mutex.lock();
        defer cl.mutex.unlock();
        cl.stats = st;
        cl.stats_gen +%= 1;
        if (cl.stats_gen == 0) cl.stats_gen = 1;
    }

    /// Entra num canal (cria se não existir, se o servidor deixar).
    pub fn joinChannel(cl: *Client, name: []const u8) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.channel) catch return;
        b.str(name) catch return;
        cl.queue.pushOwned(b.finish() catch return);
    }

    /// Liga/desliga as estatísticas do servidor (o servidor só manda pro dono).
    pub fn wantStats(cl: *Client, on: bool) void {
        const m = proto.Msg.alloc(.stats, 1) catch return;
        m.payload()[0] = @intFromBool(on);
        cl.queue.pushOwned(m);
    }

    /// Próximo aviso do admin pra UI (null = nenhum).
    pub fn takeNotice(cl: *Client) ?Notice {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        if (cl.notices.items.len == 0) return null;
        return cl.notices.orderedRemove(0);
    }

    pub fn sendChat(cl: *Client, text: []const u8) void {
        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.chat) catch return;
        b.str(text) catch return;
        cl.queue.pushOwned(b.finish() catch return);
    }

    /// Imagem no chat (um quadro H.264, ver chatimg.zig), com legenda opcional.
    pub fn sendChatImage(cl: *Client, text: []const u8, w: u16, h: u16, h264: []const u8) void {
        if (h264.len > proto.chat_image_max) return;
        var b: proto.Builder = .{};
        defer b.deinit();
        b.begin(.chat) catch return;
        b.str(text) catch return;
        b.u8_(proto.chat_img_h264) catch return;
        b.u16_(w) catch return;
        b.u16_(h) catch return;
        b.u32_(@intCast(h264.len)) catch return;
        b.bytes(h264) catch return;
        cl.queue.pushOwned(b.finish() catch return);
    }

    pub fn sendReact(cl: *Client, chat_id: u32, emoji: u8, on: bool) void {
        const m = proto.Msg.alloc(.react, 6) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], chat_id, .little);
        m.payload()[4] = emoji;
        m.payload()[5] = @intFromBool(on);
        cl.queue.pushOwned(m);
    }

    pub fn sendWatch(cl: *Client, stream: u32, on: bool, opts: u8) void {
        const m = proto.Msg.alloc(.watch, 6) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], stream, .little);
        m.payload()[4] = @intFromBool(on);
        m.payload()[5] = opts;
        cl.queue.pushOwned(m);
    }

    /// Pacote de voz nosso (thread de áudio): fura a fila, conversa não espera vídeo.
    pub fn sendVoice(cl: *Client, seq: u32, packet: []const u8) void {
        if (!cl.welcomed.load(.acquire)) return;
        const m = proto.Msg.alloc(.voice, 4 + packet.len) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], seq, .little);
        @memcpy(m.payload()[4..], packet);
        cl.queue.pushUrgentOwned(m);
    }

    /// Microfone ligado / surdo (proto.voice_*). Vale também depois de reconectar.
    pub fn sendVoiceState(cl: *Client, flags: u8) void {
        cl.voice_flags.store(flags, .monotonic);
        // antes do welcome só guarda: o welcome manda o estado guardado
        if (cl.welcomed.load(.acquire)) cl.pushVoiceState(flags);
    }

    fn pushVoiceState(cl: *Client, flags: u8) void {
        const m = proto.Msg.alloc(.voice_state, 1) catch return;
        m.payload()[0] = flags;
        cl.queue.pushOwned(m);
    }

    /// Pontos de um traço (de quem quer que seja, inclusive os meus).
    pub fn addDraw(cl: *Client, from: u32, stream: u32, flags: u8, pts: []const [2]u16) void {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        if (flags & proto.draw_clear != 0) {
            var i: usize = cl.strokes.items.len;
            while (i > 0) {
                i -= 1;
                const st = &cl.strokes.items[i];
                if (st.from == from and st.stream == stream) _ = cl.strokes.orderedRemove(i);
            }
            return;
        }
        const now = sync.nowUs();
        // o traço aberto dessa pessoa nessa transmissão (o último dela)
        var cur: ?*Stroke = null;
        if (flags & proto.draw_new == 0) {
            var i: usize = cl.strokes.items.len;
            while (i > 0) {
                i -= 1;
                const st = &cl.strokes.items[i];
                if (st.from == from and st.stream == stream) {
                    cur = st;
                    break;
                }
            }
        }
        if (cur == null or cur.?.n + pts.len > Stroke.max_points) {
            if (cl.strokes.items.len >= 64) _ = cl.strokes.orderedRemove(0); // o mais velho sai
            cl.strokes.append(gpa, .{ .from = from, .stream = stream }) catch return;
            cur = &cl.strokes.items[cl.strokes.items.len - 1];
        }
        const st = cur.?;
        st.style = flags & 0xFC;
        for (pts) |p| {
            if (st.n == Stroke.max_points) break;
            st.pts[st.n] = p;
            st.n += 1;
        }
        st.last_us = now;
    }

    pub fn sendDraw(cl: *Client, stream: u32, flags: u8, pts: []const [2]u16) void {
        if (!cl.welcomed.load(.acquire) or pts.len > proto.draw_max_points) return;
        const m = proto.Msg.alloc(.draw, 7 + pts.len * 4) catch return;
        const pl = m.payload();
        std.mem.writeInt(u32, pl[0..4], stream, .little);
        pl[4] = flags;
        std.mem.writeInt(u16, pl[5..7], @intCast(pts.len), .little);
        for (pts, 0..) |p, i| {
            std.mem.writeInt(u16, pl[7 + i * 4 ..][0..2], p[0], .little);
            std.mem.writeInt(u16, pl[9 + i * 4 ..][0..2], p[1], .little);
        }
        cl.queue.pushUrgentOwned(m);
    }

    /// Tira os traços que já sumiram (mais velhos que `max_age_us`).
    pub fn pruneStrokes(cl: *Client, now: u64, max_age_us: u64) void {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        var i: usize = cl.strokes.items.len;
        while (i > 0) {
            i -= 1;
            if (now -| cl.strokes.items[i].last_us > max_age_us) _ = cl.strokes.orderedRemove(i);
        }
    }

    /// Ponteiro "olha aqui" sobre uma transmissão (x, y em 0..65534; proto.coord_none esconde).
    /// Onde está o meu cursor (transmissão `kind`, fora do vídeo).
    pub fn sendCursor(cl: *Client, kind: u8, x: u16, y: u16) void {
        if (!cl.welcomed.load(.acquire)) return;
        const m = proto.Msg.alloc(.cursor, 5) catch return;
        const pl = m.payload();
        pl[0] = kind;
        std.mem.writeInt(u16, pl[1..3], x, .little);
        std.mem.writeInt(u16, pl[3..5], y, .little);
        cl.queue.pushUrgentOwned(m);
    }

    /// Em que altura (pixels) eu mostro essa transmissão (view_full = quero tudo).
    pub fn sendViewSize(cl: *Client, stream: u32, h: u16) void {
        if (!cl.welcomed.load(.acquire)) return;
        const m = proto.Msg.alloc(.view_size, 6) catch return;
        const pl = m.payload();
        std.mem.writeInt(u32, pl[0..4], stream, .little);
        std.mem.writeInt(u16, pl[4..6], h, .little);
        cl.queue.pushOwned(m);
    }

    pub fn sendPointer(cl: *Client, stream: u32, x: u16, y: u16, flags: u8) void {
        if (!cl.welcomed.load(.acquire)) return;
        const m = proto.Msg.alloc(.pointer, 9) catch return;
        const pl = m.payload();
        std.mem.writeInt(u32, pl[0..4], stream, .little);
        std.mem.writeInt(u16, pl[4..6], x, .little);
        std.mem.writeInt(u16, pl[6..8], y, .little);
        pl[8] = flags;
        cl.queue.pushUrgentOwned(m);
    }

    /// Alguém falando agora (pra bolinha verde em volta do avatar).
    pub fn speaking(cl: *Client, id: u32) bool {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        const now = sync.nowUs();
        for (cl.voice_peers.items) |p| if (p.id == id) return p.speaking(now);
        return false;
    }

    /// Volume da voz de alguém, só pra mim (0 = mudo, 1 = normal, até 2).
    pub fn setVoiceVolume(cl: *Client, id: u32, vol: f32) void {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        cl.voice_volumes.put(gpa, id, vol) catch {};
        for (cl.voice_peers.items) |p| if (p.id == id) p.ring.setVolume(vol); // com o lock do anel (o mixer lê)
    }

    pub fn voiceVolume(cl: *Client, id: u32) f32 {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        return cl.voice_volumes.get(id) orelse 1.0;
    }

    /// Pede um quadro completo de quem estamos assistindo (perdemos a referência).
    pub fn sendKeyreq(cl: *Client, stream: u32) void {
        cl.sendKeyreqReason(stream, proto.keyreq_lost);
    }

    /// keyreq com motivo (proto.keyreq_*): gravação começando só pede o IDR.
    /// Log de depuração pro dono da sala, em pedaços (o servidor repassa).
    pub fn sendLogFile(cl: *Client, data: []const u8, what: u8) bool {
        if (data.len == 0 or data.len > proto.log_max) return false;
        const id = cl.log_seq.fetchAdd(1, .monotonic);
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(proto.log_chunk_max, data.len - off);
            const m = proto.Msg.alloc(.log_chunk, 13 + n) catch return false;
            const p = m.payload();
            std.mem.writeInt(u32, p[0..4], id, .little);
            p[4] = what;
            std.mem.writeInt(u32, p[5..9], @intCast(data.len), .little);
            std.mem.writeInt(u32, p[9..13], @intCast(off), .little);
            @memcpy(p[13..][0..n], data[off..][0..n]);
            cl.queue.pushOwned(m);
            off += n;
        }
        return true;
    }

    /// Um pedaço de log de alguém (somos o dono): junta e, completo, salva e avisa a UI.
    fn onLogChunk(cl: *Client, r: *proto.Reader) !void {
        const from = try r.u32_();
        const name = try r.str();
        const id = try r.u32_();
        const what = try r.u8_();
        const total = try r.u32_();
        const off = try r.u32_();
        const bytes = r.rest();
        if (total == 0 or total > proto.log_max or bytes.len > proto.log_chunk_max or @as(u64, off) + bytes.len > total) return;
        var slot: ?*IncomingLog = null;
        for (cl.incoming_logs) |maybe| if (maybe) |l| {
            if (l.from == from and l.id == id) slot = l;
        };
        if (slot == null) {
            if (off != 0) return; // começo perdido (entrou depois)
            const free = for (&cl.incoming_logs) |*sl| {
                if (sl.* == null) break sl;
            } else blk: {
                // cheio: descarta o mais velho
                const old = cl.incoming_logs[0].?;
                old.data.deinit(gpa);
                gpa.destroy(old);
                cl.incoming_logs[0] = null;
                break :blk &cl.incoming_logs[0];
            };
            const l = try gpa.create(IncomingLog);
            l.* = .{ .from = from, .id = id, .what = what, .total = total };
            l.name_len = @min(name.len, l.name.len);
            @memcpy(l.name[0..l.name_len], name[0..l.name_len]);
            free.* = l;
            slot = l;
        }
        const l = slot.?;
        if (off != l.data.items.len) return; // fora de ordem (não acontece no TCP)
        try l.data.appendSlice(gpa, bytes);
        if (l.data.items.len < l.total) return;
        // completo: salva e avisa
        var pb: [700]u8 = undefined;
        const saved = debuglog.saveReceived(l.name[0..l.name_len], l.what, l.data.items, &pb);
        var n: Notice = .{ .kind = proto.notice_log_received, .extra = l.what, .text = undefined, .len = 0 };
        var tb: [800]u8 = undefined;
        const text = std.fmt.bufPrint(&tb, "{s} mandou um log: {s}", .{ l.name[0..l.name_len], saved orelse "(não consegui salvar)" }) catch "";
        copyInto(&n.text, &n.len, text);
        for (&cl.incoming_logs) |*sl| if (sl.* == l) {
            sl.* = null;
        };
        l.data.deinit(gpa);
        gpa.destroy(l);
        cl.mutex.lock();
        defer cl.mutex.unlock();
        if (cl.notices.items.len < 32) try cl.notices.append(gpa, n);
    }

    pub fn sendKeyreqReason(cl: *Client, stream: u32, reason: u8) void {
        const m = proto.Msg.alloc(.keyreq, 5) catch return;
        std.mem.writeInt(u32, m.payload()[0..4], stream, .little);
        m.payload()[4] = reason;
        cl.queue.pushOwned(m);
    }

    /// Transmissor: frame `seq` (tela ou câmera) entrou na fila de envio.
    pub fn frameSent(cl: *Client, kind: u8, seq: u32, key: bool) void {
        cl.inflight_mutex.lock();
        defer cl.inflight_mutex.unlock();
        cl.inflight[kind].sent(seq, sync.nowUs(), key);
    }

    pub const Uplink = struct {
        excess_us: u64, // atraso acumulado acima do normal
        key_allowance_us: u64, // quanto disso se explica por um IDR recente
    };

    /// Transmissor: atraso que nosso upload está acumulando (por tipo de transmissão).
    pub fn uplink(cl: *Client, kind: u8) Uplink {
        cl.inflight_mutex.lock();
        defer cl.inflight_mutex.unlock();
        const now = sync.nowUs();
        return .{ .excess_us = cl.inflight[kind].excessUs(now, 300_000), .key_allowance_us = cl.inflight[kind].keyAllowanceUs(now) };
    }

    /// Transmissor: começou uma transmissão nova (seq volta pra 0).
    pub fn resetInflight(cl: *Client, kind: u8) void {
        cl.inflight_mutex.lock();
        defer cl.inflight_mutex.unlock();
        cl.inflight[kind].reset();
    }

    /// Ação de admin (proto.admin_*). O servidor confere se a gente pode.
    pub fn admin(cl: *Client, action: u8, target: u32, value: u8) void {
        const m = proto.Msg.alloc(.admin, 6) catch return;
        const pl = m.payload();
        pl[0] = action;
        std.mem.writeInt(u32, pl[1..5], target, .little);
        pl[5] = value;
        cl.queue.pushOwned(m);
    }

    pub fn kick(cl: *Client, target: u32) void {
        cl.admin(proto.admin_kick, target, 0);
    }

    /// Acha a view de um stream e segura uma referência (a UI pode parar de
    /// assistir a qualquer momento).
    fn viewRetained(cl: *Client, stream: u32) ?*View {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.views.items) |v| if (v.stream == stream) return v.retain();
        return null;
    }

    pub fn findView(cl: *Client, stream: u32) ?*View {
        cl.mutex.lock();
        defer cl.mutex.unlock();
        for (cl.views.items) |v| if (v.stream == stream) return v;
        return null;
    }

    /// Começa a assistir um stream. Retorna a view (a UI fica com uma referência).
    pub fn watch(cl: *Client, stream: u32, opts: u8) !*View {
        if (cl.findView(stream)) |v| return v;
        const v = try gpa.create(View);
        v.* = .{ .stream = stream, .client = cl.retain() };
        if (opts & proto.watch_clips != 0) v.clip = clip.Buffer.create() catch null;
        sync.spawn(View.decodeLoop, .{v}) catch {
            cl.release();
            gpa.destroy(v);
            return error.ThreadFailed;
        };
        cl.mutex.lock();
        cl.views.append(gpa, v) catch {};
        cl.mutex.unlock();
        cl.sendWatch(stream, true, opts);
        return v;
    }

    /// Para de assistir. A UI tem que apagar a textura antes.
    pub fn unwatch(cl: *Client, v: *View) void {
        cl.mutex.lock();
        if (std.mem.findScalar(*View, cl.views.items, v)) |i| _ = cl.views.orderedRemove(i);
        cl.mutex.unlock();
        cl.sendWatch(v.stream, false, 0);
        v.shutdown();
        v.release();
    }
};
