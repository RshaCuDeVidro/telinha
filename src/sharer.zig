//! Transmissão da tela, em pipeline de duas threads:
//!
//!   thread de captura:  captura → (escala) → BGRX→I420 ─┐  (enquanto isso…)
//!   thread de encode:                    ┌───────────────┘
//!                                         H.264 → fila de envio
//!
//! Enquanto o encoder trabalha no quadro N, a captura já prepara o N+1, então
//! o tempo por quadro é o da etapa mais lenta, não a soma das duas. Se o
//! encoder fica pra trás, o quadro pendente é substituído pelo mais novo
//! (nunca acumula atraso).
//!
//! Controle de banda: ratectl.zig (pelo atraso de ponta a ponta medido com as
//! confirmações do servidor, e pelos avisos de espectador lento).
const std = @import("std");
const tr = @import("i18n.zig").tr;
const sync = @import("sync.zig");
const proto = @import("proto.zig");
const codec = @import("codec.zig");
const audio = @import("audio.zig");
const RateControl = @import("ratectl.zig").RateControl;
const Client = @import("client.zig").Client;
const clip = @import("clip.zig");
const c = @cImport({
    @cInclude("capture.h");
    @cInclude("cudagl.h");
    @cInclude("camera.h");
    @cInclude("hwva.h");
});
const gpa = proto.gpa;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// TELINHA_DEBUG=1 imprime o tempo de cada etapa do pipeline uma vez por segundo.
/// Gravando a própria transmissão (precisa codificar mesmo sem ninguém assistindo).
fn ownRecording(s: *Sharer) bool {
    const cb = s.clip orelse return false;
    return cb.recState().active;
}

fn debugEnabled() bool {
    return sync.debugOn();
}

/// Tempos acumulados (µs) pra diagnóstico.
const Timing = struct {
    capture: std.atomic.Value(u64) = .init(0),
    ingest: std.atomic.Value(u64) = .init(0),
    convert: std.atomic.Value(u64) = .init(0),
    captured: std.atomic.Value(u32) = .init(0),
    encode: std.atomic.Value(u64) = .init(0),
    encoded: std.atomic.Value(u32) = .init(0),
    skipped: std.atomic.Value(u32) = .init(0),
    enc_dropped: std.atomic.Value(u32) = .init(0), // o encoder não gerou nada (controle de taxa do openh264)

    /// `secs`: tempo desde o último relatório (com a tela parada, o encode
    /// quase não roda e o relatório sai com vários segundos de intervalo).
    fn report(t: *Timing, bps: u32, queued: usize, secs: f32) void {
        const nc = @max(1, t.captured.swap(0, .monotonic));
        const ne = @max(1, t.encoded.load(.monotonic));
        std.debug.print("[telinha] captura {d:.0} q/s: espera {d:.1} ms, cópia/escala {d:.1} ms, I420 {d:.1} ms | encode {d:.0} q/s: {d:.1} ms | pulados {d} (+{d} pelo encoder) | {d} kbit/s | fila {d} KB\n", .{
            @as(f32, @floatFromInt(nc)) / secs,
            @as(f64, @floatFromInt(t.capture.swap(0, .monotonic))) / @as(f64, @floatFromInt(nc)) / 1000,
            @as(f64, @floatFromInt(t.ingest.swap(0, .monotonic))) / @as(f64, @floatFromInt(nc)) / 1000,
            @as(f64, @floatFromInt(t.convert.swap(0, .monotonic))) / @as(f64, @floatFromInt(nc)) / 1000,
            @as(f32, @floatFromInt(t.encoded.swap(0, .monotonic))) / secs,
            @as(f64, @floatFromInt(t.encode.swap(0, .monotonic))) / @as(f64, @floatFromInt(ne)) / 1000,
            t.skipped.swap(0, .monotonic),
            t.enc_dropped.swap(0, .monotonic),
            bps / 1000,
            queued / 1024,
        });
    }
};

pub const Settings = struct {
    source: i32 = 0,
    camera_id: [160]u8 = [_]u8{0} ** 160, // câmera (vazio = a primeira)
    fps: u32 = 30,
    quality: u8 = 60, // 20..100
    max_height: u32 = 0, // 0 = resolução original
    cursor: bool = true,
    /// O cursor vai fora do vídeo (só a posição; quem assiste desenha a seta)
    /// quando todo mundo que assiste entende isso.
    cursor_apart: bool = true,
    /// Manda no maior tamanho em que alguém está vendo (não em 1080p pra quem
    /// vê num quadradinho).
    view_size: bool = true,
    mode: codec.Mode = .screen,
    hardware: bool = true, // tenta NVENC antes do encoder em software
    audio: bool = true, // compartilha o som do computador
    audio_app: [64]u8 = [_]u8{0} ** 64, // só o som desse programa (vazio = tudo menos o telinha)
    audio_pid: u32 = 0, // ou desse processo e filhos (a janela compartilhada)
    audio_exclude: [512]u8 = [_]u8{0} ** 512, // "tudo" menos esses programas (nomes separados por \n)
    clips: bool = true, // guarda os últimos 30 s (clipe da própria transmissão)
    auto_quality: bool = true, // baixa a resolução sozinho se o PC não der conta do fps
    crop: [4]f32 = .{ 0, 0, 1, 1 }, // só esse pedaço da tela (x0, y0, x1, y1 de 0 a 1)
    kind: u8 = proto.kind_screen, // tela ou câmera (não muda com a transmissão rolando)
};

/// Taxa de bits alvo pra uma resolução/fps/qualidade.
pub fn targetBitrate(w: u32, h: u32, fps: u32, quality: u8) u32 {
    const q: f64 = @floatFromInt(std.math.clamp(quality, 20, 100));
    const bpp = 0.02 + (q - 20.0) / 80.0 * 0.16; // bits por pixel
    const bps = @as(f64, @floatFromInt(w)) * @as(f64, @floatFromInt(h)) * @as(f64, @floatFromInt(fps)) * bpp;
    return @intFromFloat(std.math.clamp(bps, 250_000, 30_000_000));
}

/// Tamanho de saída respeitando o limite de altura (dimensões pares).
const autoq = @import("autoq.zig");

/// Teste (TELINHA_ENCODE_LENTO=ms): o encode demora esses ms a mais num
/// quadro 1080p (proporcional aos pixels), como num PC fraco.
fn slowEncodeUs(w: u32, h: u32) ?u64 {
    const S = struct {
        var ms: ?u64 = null;
        var read = false;
    };
    if (!S.read) {
        S.read = true;
        if (std.c.getenv("TELINHA_ENCODE_LENTO")) |v| S.ms = std.fmt.parseInt(u64, std.mem.span(v), 10) catch null;
    }
    const ms = S.ms orelse return null;
    return ms * 1000 * w * h / (1920 * 1080);
}
pub const effectiveHeight = autoq.effectiveHeight;
pub const AutoQuality = autoq.AutoQuality;

/// O retângulo do recorte em pixels da fonte (pares, pelo menos 64x64).
pub fn cropRect(crop: [4]f32, fw: u32, fh: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
    if (crop[0] <= 0 and crop[1] <= 0 and crop[2] >= 1 and crop[3] >= 1) return .{ .x = 0, .y = 0, .w = fw, .h = fh };
    const ffw: f32 = @floatFromInt(fw);
    const ffh: f32 = @floatFromInt(fh);
    var x0: u32 = @intFromFloat(std.math.clamp(crop[0], 0, 1) * ffw);
    var y0: u32 = @intFromFloat(std.math.clamp(crop[1], 0, 1) * ffh);
    const x1: u32 = @intFromFloat(std.math.clamp(crop[2], 0, 1) * ffw);
    const y1: u32 = @intFromFloat(std.math.clamp(crop[3], 0, 1) * ffh);
    x0 &= ~@as(u32, 1);
    y0 &= ~@as(u32, 1);
    var w = (x1 -| x0) & ~@as(u32, 1);
    var h = (y1 -| y0) & ~@as(u32, 1);
    w = @max(@min(64, fw), @min(w, fw -| x0));
    h = @max(@min(64, fh), @min(h, fh -| y0));
    if (x0 + w > fw) x0 = fw - w;
    if (y0 + h > fh) y0 = fh - h;
    return .{ .x = x0, .y = y0, .w = w, .h = h };
}

pub fn outputSize(sw: u32, sh: u32, max_height: u32) struct { w: u32, h: u32 } {
    var ow = sw;
    var oh = sh;
    if (max_height > 0 and sh > max_height) {
        oh = max_height;
        ow = sw * oh / sh;
    }
    return .{ .w = @max(16, @min(ow, 8192) & ~@as(u32, 1)), .h = @max(16, @min(oh, 8192) & ~@as(u32, 1)) };
}

pub const State = enum { starting, live, failed, stopped };
pub const StopReason = enum(u8) { none, ui, encoder_ended };

/// Um quadro já convertido pra I420, esperando o encoder.
const Slot = struct {
    y: []u8 = &.{},
    u: []u8 = &.{},
    v: []u8 = &.{},
    bgrx: []u8 = &.{}, // caminho do encoder em hardware (sem conversão na CPU)
    // caminho pela placa (cap_gpu_enable): o quadro é um buffer na placa, da
    // captura (devolvido com cap_gpu_release quando o slot é reaproveitado)
    gpu: ?*anyopaque = null,
    gpu_dev: u64 = 0,
    gpu_pitch: u32 = 0,
    fmt: codec.PixelFormat = .bgrx,
    w: u32 = 0,
    h: u32 = 0,
    ts: u64 = 0, // hora da captura (relógio da sala)
    cursor_x: u16 = proto.coord_none, // ponta do cursor no quadro (0..65534)
    cursor_y: u16 = proto.coord_none,
    cursor_apart: bool = false, // o cursor não está pintado (frame_cursor_apart)

    fn ensure(s: *Slot, w: u32, h: u32) !void {
        const n = @as(usize, w) * h;
        if (s.y.len != n) {
            gpa.free(s.y);
            gpa.free(s.u);
            gpa.free(s.v);
            s.y = &.{};
            s.u = &.{};
            s.v = &.{};
            s.y = try gpa.alloc(u8, n);
            s.u = try gpa.alloc(u8, n / 4);
            s.v = try gpa.alloc(u8, n / 4);
        }
        s.w = w;
        s.h = h;
    }
    fn ensureBgrx(s: *Slot, w: u32, h: u32) !void {
        const n = @as(usize, w) * h * 4;
        if (s.bgrx.len != n) {
            gpa.free(s.bgrx);
            s.bgrx = &.{};
            s.bgrx = try gpa.alloc(u8, n);
        }
        s.w = w;
        s.h = h;
    }
    fn deinit(s: *Slot) void {
        gpa.free(s.bgrx);
        gpa.free(s.y);
        gpa.free(s.u);
        gpa.free(s.v);
    }
};

pub const Sharer = struct {
    refs: std.atomic.Value(u32) = .init(2), // UI + thread de captura
    client: *Client,
    kind: u8, // tela ou câmera (fixo)
    stop_flag: std.atomic.Value(bool) = .init(false),
    /// Quem mandou parar (vai pro log; parar sem a UI pedir = cair e retomar).
    stop_reason: std.atomic.Value(StopReason) = .init(.none),

    mutex: sync.Mutex = .{},
    settings: Settings,
    settings_gen: u32 = 0,
    state: State = .starting,
    err: [256]u8 = undefined,
    err_len: usize = 0,
    backend: [16]u8 = undefined,
    backend_len: usize = 0,
    // estatísticas
    fps: f32 = 0,
    kbps: f32 = 0,
    /// Quando as estatísticas foram recalculadas (ms): elas só andam quando o
    /// encoder solta quadro; parado há mais de 2 s, o que aparece é zero.
    stat_ms: u64 = 0,
    /// Quadros codificados e mandados, e posições de cursor mandadas (total; testes e log).
    frames_sent: std.atomic.Value(u64) = .init(0),
    /// IDRs desde a última linha do log: pedidos pela sala (alguém entrou,
    /// perdeu a referência...) e os do clipe da própria tela (a cada 20 s).
    idr_room: std.atomic.Value(u32) = .init(0),
    idr_clip: std.atomic.Value(u32) = .init(0),
    cursor_msgs: std.atomic.Value(u64) = .init(0),
    encode_ms: f32 = 0,
    bitrate_kbps: u32 = 0,
    congested: bool = false,
    slow_viewer: bool = false, // algum espectador pediu menos nos últimos segundos
    encoder_name: []const u8 = "",
    encoder_name_buf: [48]u8 = undefined, // cópia (o encoder pode ser recriado a qualquer hora)
    audio_on: bool = false, // capturando o som do computador
    audio_hears_self: bool = false, // a captura pega também o que o telinha toca (jeito antigo)
    audio_exclude_ignored: bool = false, // Windows antigo: não deu pra excluir programas do som
    audio_err: [160]u8 = [_]u8{0} ** 160, // por que o áudio não deu (vazio = deu certo ou não pediu)
    w: u32 = 0,
    h: u32 = 0,
    // pré-visualização: buffer de trás preenchido pela captura, trocado com o da frente
    preview: []u8 = &.{},
    preview_w: u32 = 0,
    preview_h: u32 = 0,
    preview_bgr: bool = true,
    preview_new: bool = false,
    preview_tex_w: u32 = 0, // tamanho da textura (da UI) da prévia
    preview_tex_h: u32 = 0,
    /// Quando a interface mostrou a prévia pela última vez (ms): ninguém
    /// olhando (outra tela, minimizado), não gasta gerando a miniatura.
    preview_wanted_ms: std.atomic.Value(u64) = .init(0),
    /// Escolhendo o recorte: a prévia (só na tela de quem transmite) mostra a
    /// tela inteira; a transmissão continua com o recorte de antes.
    preview_full: std.atomic.Value(bool) = .init(false),
    /// Ninguém assistindo e sem gravação: o encoder está parado (a captura
    /// cai pra 5 q/s, só pra prévia e pra ter quadro na hora que alguém entrar).
    idle: std.atomic.Value(bool) = .init(false),
    /// Qualidade automática: altura máxima que ela impôs (0 = nenhuma) e de
    /// quanto era antes (pra avisar quem transmite).
    auto_cap: std.atomic.Value(u32) = .init(0),
    auto_from: std.atomic.Value(u32) = .init(0),
    preview_tex: u32 = 0, // só a UI mexe
    /// Os últimos ~30 s do que codificamos (clipe) e a gravação. null = sem clipes.
    clip: ?*clip.Buffer = null,

    pub fn start(client: *Client, settings: Settings) !*Sharer {
        const s = try gpa.create(Sharer);
        s.* = .{ .client = client.retain(), .settings = settings, .kind = settings.kind };
        if (settings.clips) s.clip = clip.Buffer.create() catch null;
        sync.spawn(run, .{s}) catch {
            client.release();
            gpa.destroy(s);
            return error.ThreadFailed;
        };
        return s;
    }

    pub fn stop(s: *Sharer) void {
        _ = s.stop_reason.cmpxchgStrong(.none, .ui, .acq_rel, .acquire);
        s.stop_flag.store(true, .release);
        s.release();
    }

    /// Muda fps/qualidade/resolução/modo com a transmissão rolando.
    pub fn update(s: *Sharer, settings: Settings) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.settings = settings;
        s.settings_gen += 1;
    }

    fn release(s: *Sharer) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) {
            if (s.clip) |cb| cb.destroy();
            gpa.free(s.preview);
            s.client.release();
            gpa.destroy(s);
        }
    }

    /// q/s e KB/s pra mostrar (com `mutex`): zero se nada saiu nos últimos 2 s.
    pub fn shownFps(s: *const Sharer) f32 {
        return if (sync.nowMs() -| s.stat_ms > 2000) 0 else s.fps;
    }
    pub fn shownKbps(s: *const Sharer) f32 {
        return if (sync.nowMs() -| s.stat_ms > 2000) 0 else s.kbps;
    }

    pub fn errSlice(s: *Sharer) []const u8 {
        return s.err[0..s.err_len];
    }
    pub fn backendSlice(s: *Sharer) []const u8 {
        return s.backend[0..s.backend_len];
    }

    fn fail(s: *Sharer, msg: []const u8) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        if (s.state == .failed) return;
        s.state = .failed;
        s.err_len = @min(msg.len, s.err.len);
        @memcpy(s.err[0..s.err_len], msg[0..s.err_len]);
    }

    fn errorText(e: anyerror) []const u8 {
        return switch (e) {
            error.OutOfMemory => tr("Sem memória."),
            error.EncoderCreate, error.EncoderInit => tr("Não consegui iniciar o codificador de vídeo."),
            error.Encode => tr("Falha ao codificar o vídeo."),
            else => @errorName(e),
        };
    }

    fn run(s: *Sharer) void {
        if (std.c.getenv("TELINHA_VIEW_DESCE_MS")) |v| view_down_ms = std.fmt.parseInt(u64, std.mem.span(v), 10) catch view_down_ms;
        defer s.release();
        defer s.client.wake();
        sync.hiresTimer(true); // cadência de captura/envio em ms
        defer sync.hiresTimer(false);
        var p: Pipeline = .{ .s = s };
        defer p.deinit();
        p.start() catch |e| {
            s.fail(if (e == error.Capture) p.errSlice() else errorText(e));
            return;
        };
        const enc_thread = std.Thread.spawn(.{}, Pipeline.encodeLoop, .{&p}) catch {
            s.fail(tr("Falha ao criar thread."));
            return;
        };
        p.captureLoop() catch |e| s.fail(if (e == error.Capture) p.errSlice() else errorText(e));
        // para o encoder e espera
        p.mutex.lock();
        p.quit = true;
        p.cond.broadcast();
        p.mutex.unlock();
        enc_thread.join();

        // avisa a sala que parou
        if (proto.Msg.alloc(.stream_stop, 1)) |m| {
            m.payload()[0] = s.kind;
            s.client.queue.pushOwned(m);
        } else |_| {}
        s.mutex.lock();
        if (s.state != .failed) s.state = .stopped;
        const final = s.state;
        s.mutex.unlock();
        if (debugEnabled()) std.debug.print("[telinha] transmissão ({s}) terminou: {s}, motivo {s}\n", .{ if (s.kind == proto.kind_camera) "câmera" else "tela", @tagName(final), @tagName(s.stop_reason.load(.acquire)) });
    }
};

/// De onde vêm os quadros: a tela ou a câmera (as duas entregam BGRX).
const Source = union(enum) {
    screen: *c.cap_ctx,
    camera: *c.cam_ctx,

    fn next(src: Source, f: *c.cap_frame, timeout_ms: c_int, err: []u8) c_int {
        return switch (src) {
            .screen => |x| c.cap_next(x, f, timeout_ms, err.ptr, @intCast(err.len)),
            .camera => |x| c.cam_next(x, f, timeout_ms, err.ptr, @intCast(err.len)),
        };
    }
    fn backend(src: Source) [*:0]const u8 {
        return switch (src) {
            .screen => |x| c.cap_backend(x),
            .camera => |x| c.cam_backend(x),
        };
    }
    fn close(src: Source) void {
        switch (src) {
            .screen => |x| c.cap_close(x),
            .camera => |x| c.cam_close(x),
        }
    }
};

/// Quanto tempo pedindo uma altura menor antes de a transmissão descer
/// (subir é na hora). TELINHA_VIEW_DESCE_MS muda (testes).
var view_down_ms: u64 = 10_000;

const Pipeline = struct {
    s: *Sharer,
    cap: ?Source = null,
    event_driven: bool = false, // PipeWire/DXGI só entregam quadro quando algo muda
    err: [256]u8 = [_]u8{0} ** 256,
    settings: Settings = .{},
    gen: u32 = std.math.maxInt(u32),

    // captura
    cur: []u8 = &.{}, // quadro novo (BGRX na resolução de saída)
    prev: []u8 = &.{}, // anterior (só pra detectar repetição em captura por polling)
    have_prev: bool = false,
    preview_back: []u8 = &.{},
    last_preview_us: u64 = 0,
    w: u32 = 0,
    h: u32 = 0,
    fmt: codec.PixelFormat = .bgrx,
    cursor_x: u16 = proto.coord_none,
    cursor_y: u16 = proto.coord_none,
    /// Cursor fora do vídeo (cap_set_cursor_apart ligado) e o que já foi mandado.
    cursor_apart: bool = false,
    cursor_apart_unsupported: bool = false, // essa captura não sabe: nem tenta de novo
    // tamanho de quem assiste (viewCap): o teto aplicado e desde quando pedem menos
    view_cap_set: bool = false,
    view_cap_fresh: bool = true,
    view_cap_cur: u32 = 0,
    view_cap_lower_since: u64 = 0,
    cursor_sent: [2]u16 = .{ proto.coord_none, proto.coord_none },
    cursor_sent_us: u64 = 0,

    // fila de 3 slots entre captura e encode
    mutex: sync.Mutex = .{},
    cond: sync.Cond = .{},
    slots: [3]Slot = .{ .{}, .{}, .{} },
    ready: ?usize = null, // quadro mais novo esperando o encoder
    encoding: ?usize = null, // em uso pelo encoder
    last: ?usize = null, // último codificado (reaproveitado pra IDR sem quadro novo)
    quit: bool = false,
    ready_was_null: bool = false,
    timing: Timing = .{},
    /// Tempo médio de um encode (µs): a captura não vai mais rápido que isso
    /// (quadro capturado e convertido que o encoder não pega é trabalho jogado fora).
    enc_ema_us: std.atomic.Value(u64) = .init(0),
    ing_ema_us: u64 = 0, // conversão/escala por quadro (µs), só a thread de captura
    src_h: u32 = 0, // altura da fonte (o último quadro capturado)
    auto: AutoQuality = .{},
    /// Encoder em hardware em uso? Decidido no início; vira false se o NVENC falhar.
    use_hw: std.atomic.Value(bool) = .init(false),
    /// Caminho pela placa (Linux + NVIDIA): a captura entrega o quadro já na
    /// memória da placa (recorte, escala e cursor feitos lá) e o NVENC lê de
    /// lá. `cg` vive mais que a captura (os buffers são do contexto dele).
    cg: ?*c.cudagl = null,
    /// Intel/AMD no Linux: o conversor VA-API (VPP) no lugar do CUDA.
    vapp: ?*c.vapp = null,
    // Windows: encoders do Media Foundation abertos com o dispositivo da captura
    d3d_on: std.atomic.Value(bool) = .init(false),
    d3d_dev: ?*anyopaque = null,
    gpu_on: bool = false,
    hevc_ok: bool = false, // a placa codifica HEVC (testado no começo)
    audio_sender: ?*audio.Sender = null,
    audio_live: std.atomic.Value(bool) = .init(false), // tem som saindo (vai no anúncio)
    reannounce: std.atomic.Value(bool) = .init(false), // o som mudou: anunciar de novo
    audio_seq: u32 = 0,
    fps_gen: u32 = 0, // muda quando fps/modo/qualidade mudam (encoder recria)
    fps: u32 = 30,
    quality: u8 = 60,
    mode: codec.Mode = .screen,

    fn autoQuality(p: *Pipeline, now: u64) void {
        const s = p.s;
        if (!p.settings.auto_quality or s.idle.load(.acquire) or p.h == 0) {
            if (p.auto.cap != 0 and !p.settings.auto_quality) {
                p.auto.cap = 0;
                s.auto_cap.store(0, .release);
            }
            return;
        }
        const before = p.auto.cap;
        const load = @max(p.enc_ema_us.load(.monotonic), p.ing_ema_us);
        if (!p.auto.step(now, load, p.settings.fps, p.h, p.settings.max_height, p.src_h)) return;
        s.auto_from.store(if (before != 0) before else p.h, .release);
        s.auto_cap.store(p.auto.cap, .release);
        if (debugEnabled()) std.debug.print("[telinha] qualidade automática: {d}p -> {s}{d} (encode {d:.1} ms, captura {d:.1} ms, fps {d})\n", .{ p.h, if (p.auto.cap == 0) "sem teto, " else "", p.auto.cap, @as(f32, @floatFromInt(p.enc_ema_us.load(.monotonic))) / 1000, @as(f32, @floatFromInt(p.ing_ema_us)) / 1000, p.settings.fps });
    }

    fn errSlice(p: *Pipeline) []const u8 {
        return std.mem.sliceTo(&p.err, 0);
    }

    /// Altura máxima de saída: a escolhida, a da qualidade automática e a do
    /// maior tamanho em que alguém está vendo (view_size), o que for menor.
    fn maxHeight(p: *Pipeline) u32 {
        return effectiveHeight(effectiveHeight(p.settings.max_height, p.auto.cap), p.viewCap());
    }

    /// Teto pelo tamanho em que aparece pra quem assiste (0 = nenhum). Não
    /// vale gravando a própria tela (a gravação quer tudo).
    fn viewCap(p: *Pipeline) u32 {
        const s = p.s;
        if (!p.settings.view_size or ownRecording(s)) return 0;
        const w = s.client.view_want[s.kind].load(.acquire);
        const raw: u32 = if (w == proto.view_full) 0 else @max(w, 360);
        // sobe na hora; desce só depois de 10 s pedindo menos: quem entra e sai,
        // minimiza e volta, troca de layout... não fica recriando o encoder
        // (cada troca é um IDR pra todo mundo)
        const now = sync.nowMs();
        // ninguém assistindo: o próximo tamanho pedido vale na hora (é o começo)
        if (!s.client.anyoneWatching(proto.streamId(s.client.myId(), s.kind))) p.view_cap_fresh = true;
        const higher = raw == 0 or (p.view_cap_cur != 0 and raw > p.view_cap_cur);
        const before = p.view_cap_cur;
        defer if (p.view_cap_cur != before and debugEnabled()) std.debug.print("[telinha] tamanho de quem assiste: teto {d} -> {d} linhas (0 = sem teto; pedem {d})\n", .{ before, p.view_cap_cur, raw });
        if (p.view_cap_fresh and raw != 0) {
            p.view_cap_fresh = false;
            p.view_cap_set = true;
            p.view_cap_cur = raw;
            p.view_cap_lower_since = 0;
        } else if (!p.view_cap_set or higher or raw == p.view_cap_cur) {
            p.view_cap_set = true;
            p.view_cap_cur = raw;
            p.view_cap_lower_since = 0;
        } else {
            if (p.view_cap_lower_since == 0) p.view_cap_lower_since = now;
            if (now - p.view_cap_lower_since >= view_down_ms) {
                p.view_cap_cur = raw;
                p.view_cap_lower_since = 0;
            }
        }
        return p.view_cap_cur;
    }

    /// Liga/desliga o cursor fora do vídeo conforme quem assiste entende.
    fn updateCursorMode(p: *Pipeline) void {
        const s = p.s;
        const src = p.cap orelse return;
        if (src != .screen or p.cursor_apart_unsupported) return;
        const want = p.settings.cursor and p.settings.cursor_apart and !ownRecording(s) and
            s.client.features_allowed[s.kind].load(.acquire) & proto.feat_cursor != 0;
        if (want == p.cursor_apart) return;
        if (c.cap_set_cursor_apart(src.screen, @intFromBool(want)) == 0) {
            p.cursor_apart_unsupported = true;
            p.cursor_apart = false;
            return;
        }
        p.cursor_apart = want;
        p.cursor_sent = .{ proto.coord_none ^ 1, proto.coord_none ^ 1 }; // manda a próxima posição de qualquer jeito
        if (debugEnabled()) std.debug.print("[telinha] cursor {s}\n", .{if (want) "fora do vídeo (só a posição)" else "pintado no vídeo"});
    }

    /// Manda a posição do cursor (fora do vídeo) se mudou; no máximo 1 a cada 8 ms.
    fn sendCursor(p: *Pipeline, x: u16, y: u16) void {
        if (!p.cursor_apart or p.s.idle.load(.acquire)) return;
        if (x == p.cursor_sent[0] and y == p.cursor_sent[1]) return;
        const now = sync.nowUs();
        if (now - p.cursor_sent_us < 8_000) return;
        p.cursor_sent_us = now;
        p.cursor_sent = .{ x, y };
        p.s.client.sendCursor(p.s.kind, x, y);
        _ = p.s.cursor_msgs.fetchAdd(1, .monotonic);
    }

    /// Posição relativa (0..65534) no recorte de um ponto da fonte inteira (fw x fh).
    fn cursorInCrop(p: *Pipeline, f: *const c.cap_frame) [2]u16 {
        if (f.cursor_known == 0 or f.width <= 0 or f.height <= 0) return .{ proto.coord_none, proto.coord_none };
        const cr = cropRect(p.settings.crop, @intCast(f.width), @intCast(f.height));
        const cpx = f.cursor_px - @as(c_int, @intCast(cr.x));
        const cpy = f.cursor_py - @as(c_int, @intCast(cr.y));
        if (cpx < 0 or cpy < 0 or cpx >= cr.w or cpy >= cr.h) return .{ proto.coord_none, proto.coord_none };
        return .{
            @intCast(@divTrunc(@as(i64, cpx) * 65534, @max(1, @as(i64, cr.w) - 1))),
            @intCast(@divTrunc(@as(i64, cpy) * 65534, @max(1, @as(i64, cr.h) - 1))),
        };
    }

    fn deinit(p: *Pipeline) void {
        if (p.audio_sender) |a| a.destroy();
        for (&p.slots) |*sl| p.releaseGpu(sl);
        if (p.cap) |cp| cp.close();
        if (p.cg) |cg| c.cudagl_close(cg);
        p.cg = null;
        if (!sync.is_windows) if (p.vapp) |vp| c.vapp_close(vp);
        p.vapp = null;
        p.d3d_on.store(false, .release);
        gpa.free(p.cur);
        gpa.free(p.prev);
        gpa.free(p.preview_back);
        for (&p.slots) |*sl| sl.deinit();
    }

    /// Devolve o buffer da placa de um slot pra captura (se tiver).
    fn releaseGpu(p: *Pipeline, sl: *Slot) void {
        const g = sl.gpu orelse return;
        sl.gpu = null;
        sl.gpu_dev = 0;
        if (p.cap) |src| switch (src) {
            .screen => |x| c.cap_gpu_release(x, g),
            else => {},
        };
    }

    /// Liga o caminho pela placa se o encoder aceita (NVENC) e a captura dá (DMA-BUF).
    fn enableGpu(p: *Pipeline) void {
        const src = p.cap orelse return;
        if (src != .screen) return;
        const cg = c.cudagl_open() orelse return;
        if (c.cap_gpu_enable(src.screen, cg, outputRect, cursorRgba) != 0) {
            p.cg = cg;
            p.gpu_on = true;
        } else c.cudagl_close(cg);
    }

    /// Intel/AMD (VA-API): o conversor da placa recorta, escala e converte pra
    /// NV12, e o encoder lê a superfície dele direto.
    fn enableVa(p: *Pipeline) void {
        if (sync.is_windows) return;
        const src = p.cap orelse return;
        if (src != .screen) return;
        var err: [256]u8 = [_]u8{0} ** 256;
        const vp = c.vapp_open(&err, err.len) orelse {
            if (debugEnabled()) std.debug.print("[telinha] captura pela placa (VA-API) não ligou: {s}\n", .{std.mem.sliceTo(&err, 0)});
            return;
        };
        const ops: c.cap_va_ops = .{
            .ctx = vp,
            .convert = @ptrCast(&c.vapp_convert),
            .surface = @ptrCast(&c.vapp_slot_surface),
            .preview = @ptrCast(&c.vapp_preview),
            .forget = @ptrCast(&c.vapp_forget),
        };
        if (c.cap_gpu_enable_va(src.screen, &ops, outputRect) != 0) {
            p.vapp = vp;
            p.gpu_on = true;
        } else c.vapp_close(vp);
    }

    /// Windows Intel/AMD: captura → processador de vídeo do D3D11 → textura NV12
    /// → encoder do Media Foundation, tudo no mesmo dispositivo.
    fn enableD3d(p: *Pipeline) void {
        if (!sync.is_windows) return;
        const src = p.cap orelse return;
        if (src != .screen) return;
        var err: [256]u8 = [_]u8{0} ** 256;
        if (c.cap_gpu_enable_d3d(src.screen, outputRect, &err, err.len) == 0) {
            if (debugEnabled()) std.debug.print("[telinha] captura pela placa (D3D11) não ligou: {s}\n", .{std.mem.sliceTo(&err, 0)});
            return;
        }
        const dev = c.cap_d3d_device(src.screen);
        // o encoder aceita a textura? (senão segue tudo pela CPU, como antes)
        var e2: [256]u8 = undefined;
        const ok = if (codec.HwEncoder.init(.{ .width = 640, .height = 360, .fps = 30, .bitrate = 1_000_000, .d3d_device = dev }, &e2)) |probe| blk: {
            var pr = probe;
            defer pr.deinit();
            break :blk pr.acceptsD3d();
        } else |_| false;
        if (!ok) {
            if (debugEnabled()) std.debug.print("[telinha] o encoder do Media Foundation não aceitou a textura: tudo pela CPU\n", .{});
            c.cap_gpu_disable(src.screen);
            return;
        }
        p.d3d_dev = dev;
        p.d3d_on.store(true, .release);
        p.gpu_on = true;
    }

    fn disableGpu(p: *Pipeline) void {
        if (!p.gpu_on) return;
        p.gpu_on = false;
        // encoders novos voltam a receber pela CPU
        p.d3d_on.store(false, .release);
        if (p.cap) |src| if (src == .screen) c.cap_gpu_disable(src.screen);
        const s = p.s;
        s.mutex.lock();
        if (std.mem.endsWith(u8, s.backend[0..s.backend_len], "+placa")) s.backend_len -= 6;
        s.mutex.unlock();
        if (debugEnabled()) std.debug.print("[telinha] captura pela placa: desligada\n", .{});
    }

    fn start(p: *Pipeline) !void {
        const s = p.s;
        p.settings = s.settings;
        p.applySettings();
        const fps: c_int = @intCast(std.math.clamp(p.settings.fps, 1, 60));
        if (s.kind == proto.kind_camera) {
            try p.openCamera();
        } else {
            const cap = c.cap_open(p.settings.source, @intFromBool(p.settings.cursor), fps, &p.err, p.err.len) orelse return error.Capture;
            p.cap = .{ .screen = cap };
        }
        if (p.settings.hardware) {
            var err: [256]u8 = undefined;
            if (codec.HwEncoder.init(.{ .width = 640, .height = 360, .fps = 30, .bitrate = 1_000_000 }, &err)) |probe| {
                var pr = probe;
                const cuda = pr.acceptsCuda();
                const is_va = pr.isVa();
                const is_mf = pr.isMf();
                pr.deinit();
                p.use_hw.store(true, .release);
                if (cuda) p.enableGpu() else if (is_va) p.enableVa() else if (is_mf) p.enableD3d();
                if (getenv("TELINHA_SEM_HEVC") == null) {
                    if (codec.HwEncoder.init(.{ .codec = .hevc, .width = 640, .height = 360, .fps = 30, .bitrate = 1_000_000 }, &err)) |hp| {
                        var hh = hp;
                        hh.deinit();
                        p.hevc_ok = true;
                    } else |_| {}
                }
            } else |_| {
                if (debugEnabled()) std.debug.print("[telinha] sem encoder em hardware: {s}\n", .{std.mem.sliceTo(&err, 0)});
            }
        }
        const b = std.mem.span(p.cap.?.backend());
        // PipeWire/DXGI/câmera só entregam quadro quando tem um novo
        p.event_driven = s.kind == proto.kind_camera or std.mem.eql(u8, b, "PipeWire") or std.mem.eql(u8, b, "DXGI") or std.mem.eql(u8, b, "WGC");
        p.openAudio();
        s.mutex.lock();
        s.backend_len = @min(b.len, s.backend.len);
        @memcpy(s.backend[0..s.backend_len], b[0..s.backend_len]);
        if (p.gpu_on and s.backend_len + 6 <= s.backend.len) {
            @memcpy(s.backend[s.backend_len..][0..6], "+placa");
            s.backend_len += 6;
        }
        s.mutex.unlock();
    }

    fn openCamera(p: *Pipeline) !void {
        const fps: c_int = @intCast(std.math.clamp(p.settings.fps, 1, 60));
        const want_h: c_int = if (p.settings.max_height > 0) @intCast(p.settings.max_height) else 720;
        const cam = c.cam_open(@ptrCast(&p.settings.camera_id), @divTrunc(want_h * 16, 9), want_h, fps, &p.err, p.err.len) orelse return error.Capture;
        p.cap = .{ .camera = cam };
    }

    /// Liga o som (de tudo ou de um programa só), conforme as configurações.
    fn openAudio(p: *Pipeline) void {
        const s = p.s;
        if (!p.settings.audio or s.kind != proto.kind_screen) return;
        var err: [160]u8 = [_]u8{0} ** 160;
        if (audio.Sender.create(p, onAudioPacket, .{ .app = std.mem.sliceTo(&p.settings.audio_app, 0), .pid = p.settings.audio_pid, .exclude = std.mem.sliceTo(&p.settings.audio_exclude, 0) }, &err)) |a| {
            p.audio_sender = a;
        } else |_| {}
        p.audio_live.store(p.audio_sender != null, .release);
        s.mutex.lock();
        @memcpy(&s.audio_err, &err);
        s.audio_on = p.audio_sender != null;
        s.audio_hears_self = if (p.audio_sender) |a| a.hearsSelf() else false;
        s.audio_exclude_ignored = if (p.audio_sender) |a| a.exclude_ignored else false;
        s.mutex.unlock();
    }

    fn closeAudio(p: *Pipeline) void {
        if (p.audio_sender) |a| a.destroy();
        p.audio_sender = null;
        p.audio_live.store(false, .release);
        const s = p.s;
        s.mutex.lock();
        s.audio_on = false;
        s.mutex.unlock();
    }

    fn applySettings(p: *Pipeline) void {
        p.mutex.lock();
        defer p.mutex.unlock();
        p.fps = std.math.clamp(p.settings.fps, 1, 60);
        p.quality = p.settings.quality;
        p.mode = p.settings.mode;
        p.fps_gen +%= 1;
    }

    // ------------------------------------------------------------ captura

    fn captureLoop(p: *Pipeline) !void {
        const s = p.s;
        sync.nameThread("captura");
        sync.lowerThreadPriority();
        var next_us: u64 = 0;
        const started_us = sync.nowUs();
        var got_any = false;
        while (!s.stop_flag.load(.acquire)) {
            // configurações mudaram?
            s.mutex.lock();
            const gen = s.settings_gen;
            const old_h = p.settings.max_height;
            const old_cam = p.settings.camera_id;
            const old_audio = p.settings.audio;
            const old_app = p.settings.audio_app;
            const old_pid = p.settings.audio_pid;
            const old_excl = p.settings.audio_exclude;
            if (gen != p.gen) p.settings = s.settings;
            s.mutex.unlock();
            if (gen != p.gen) {
                p.gen = gen;
                p.applySettings();
                // outra câmera ou outra resolução: reabre sem derrubar a
                // transmissão (quem assiste continua assistindo)
                if (s.kind == proto.kind_camera and (old_h != p.settings.max_height or !std.mem.eql(u8, &old_cam, &p.settings.camera_id))) {
                    if (p.cap) |src| src.close();
                    p.cap = null;
                    try p.openCamera();
                }
                // trocou de quem é o som (ou ligou/desligou) com a transmissão rolando
                if (old_audio != p.settings.audio or old_pid != p.settings.audio_pid or !std.mem.eql(u8, &old_app, &p.settings.audio_app) or !std.mem.eql(u8, &old_excl, &p.settings.audio_exclude)) {
                    p.closeAudio();
                    p.openAudio();
                    p.reannounce.store(true, .release);
                }
            }

            // respeita o fps configurado (ninguém assistindo: 5 q/s, só pra prévia)
            const base_us: u64 = if (s.idle.load(.acquire)) 200_000 else 1_000_000 / std.math.clamp(p.settings.fps, 1, 60);
            // encoder mais lento que o fps pedido (openh264 numa CPU fraca):
            // captura no ritmo dele (um pouco antes, pra ter quadro pronto)
            const interval_us: u64 = @max(base_us, p.enc_ema_us.load(.monotonic) * 9 / 10);
            const now = sync.nowUs();
            if (now < next_us) {
                sync.sleepMs(@intCast(@max(1, (next_us - now) / 1000)));
                continue;
            }

            // caminho pela placa: o que ela deve produzir (recorte, altura
            // máxima, prévia) — barato, e assim muda junto com as configurações
            if (p.gpu_on) {
                if (!p.use_hw.load(.acquire) or c.cap_gpu_failed(p.cap.?.screen) != 0) {
                    p.disableGpu();
                } else {
                    const scr = p.cap.?.screen;
                    c.cap_gpu_set_output(scr, &p.settings.crop, @intCast(p.maxHeight()));
                    const wanted = sync.nowMs() -| s.preview_wanted_ms.load(.monotonic) <= 1000 or s.preview.len == 0;
                    const want: c_int = if (s.preview_full.load(.acquire)) 2 else if (wanted) 1 else 0;
                    c.cap_gpu_set_preview(scr, want, if (want == 2) 1280 else 960);
                }
            }

            p.updateCursorMode();
            var f: c.cap_frame = std.mem.zeroes(c.cap_frame);
            const t_cap = sync.nowUs();
            const r = p.cap.?.next(&f, 50, &p.err);
            if (r < 0) return error.Capture;
            if (f.preview != null) p.takePreview(&f);
            if (r == 2) {
                // só o cursor mexeu (fora do vídeo): manda a posição, nada de quadro
                const pos = p.cursorInCrop(&f);
                p.sendCursor(pos[0], pos[1]);
                continue;
            }
            if (r == 0) {
                // o compositor manda o primeiro quadro na hora, mesmo com a tela parada
                if (!got_any and sync.nowUs() - started_us > 10_000_000) {
                    const msg = if (s.kind == proto.kind_camera)
                        tr("A câmera não mandou nenhuma imagem (outro programa está usando ela?).")
                    else
                        tr("A imagem da tela não chegou (o compositor aceitou compartilhar, mas não mandou nenhum quadro). Tenta de novo; se continuar, reinicia o xdg-desktop-portal.");
                    @memcpy(p.err[0..msg.len], msg);
                    p.err[msg.len] = 0;
                    return error.Capture;
                }
                continue;
            }
            got_any = true;
            const ts = s.client.serverNowUs();
            // próximo quadro: no ritmo do fps; se atrasou, não tenta "compensar" em rajada
            next_us = @max(next_us + interval_us, sync.nowUs() + interval_us / 2);

            const t_ing = sync.nowUs();
            if (f.gpu != null) {
                // quadro já pronto na placa: só anota tamanho e cursor
                p.w = @intCast(f.width);
                p.h = @intCast(f.height);
                p.src_h = @intCast(@max(f.gpu_src_h, f.height));
                // Linux: saída do GL em RGBA; Windows: a imagem do DXGI, BGRA
                p.fmt = if (f.format == c.CAP_RGBX) .rgbx else .bgrx;
                p.cursor_x = proto.coord_none;
                p.cursor_y = proto.coord_none;
                if (f.cursor_known != 0 and f.cursor_px >= 0 and f.cursor_py >= 0 and f.cursor_px < f.width and f.cursor_py < f.height) {
                    p.cursor_x = @intCast(@divTrunc(@as(i64, f.cursor_px) * 65534, @max(1, @as(i64, f.width) - 1)));
                    p.cursor_y = @intCast(@divTrunc(@as(i64, f.cursor_py) * 65534, @max(1, @as(i64, f.height) - 1)));
                }
                _ = p.timing.capture.fetchAdd(t_ing - t_cap, .monotonic);
                p.ing_ema_us = (p.ing_ema_us * 7) / 8;
                p.autoQuality(sync.nowUs());
                _ = p.timing.captured.fetchAdd(1, .monotonic);
                p.sendCursor(p.cursor_x, p.cursor_y);
                try p.publishGpu(&f, ts);
                continue;
            }
            // quadro sem pixels (não deveria vir; a captura mudou de caminho no meio): pula
            if (f.data == null) continue;
            try p.ingest(&f);
            _ = p.timing.capture.fetchAdd(t_ing - t_cap, .monotonic);
            const t_end = sync.nowUs();
            _ = p.timing.ingest.fetchAdd(t_end - t_ing, .monotonic);
            const ing = t_end - t_ing; // só a conversão: a espera pelo quadro (compositor) não é trabalho
            p.ing_ema_us = if (p.ing_ema_us == 0) ing else (p.ing_ema_us * 7 + ing) / 8;
            p.autoQuality(t_end);
            _ = p.timing.captured.fetchAdd(1, .monotonic);
            p.sendCursor(p.cursor_x, p.cursor_y);
            if (!p.event_driven) {
                // captura por polling: pula quadro idêntico ao anterior
                if (p.have_prev and std.mem.eql(u8, p.cur, p.prev)) continue;
                std.mem.swap([]u8, &p.cur, &p.prev);
                p.have_prev = true;
            }
            const frame = if (p.event_driven) p.cur else p.prev;
            // a prévia sai antes de entregar o quadro (no hardware o buffer troca de dono)
            if (s.preview_full.load(.acquire)) p.updatePreviewFull(&f) else p.updatePreview(frame);
            try p.publish(frame, ts);
        }
    }

    /// Slot livre: nem o que está sendo codificado, nem o último codificado;
    /// se o "pronto" ainda não foi pego, ele é substituído pelo mais novo.
    fn freeSlot(p: *Pipeline) usize {
        p.mutex.lock();
        defer p.mutex.unlock();
        var idx: usize = 0;
        for (0..3) |i| {
            if (p.encoding == i or p.last == i) continue;
            idx = i;
            if (p.ready != i) break;
        }
        if (p.ready == idx) p.ready = null;
        return idx;
    }

    /// Quadro que já está na placa: o slot só guarda o ponteiro.
    fn publishGpu(p: *Pipeline, f: *const c.cap_frame, ts: u64) !void {
        const idx = p.freeSlot();
        const sl = &p.slots[idx];
        p.releaseGpu(sl);
        sl.ts = ts;
        sl.fmt = p.fmt;
        sl.cursor_x = p.cursor_x;
        sl.cursor_y = p.cursor_y;
        sl.cursor_apart = p.cursor_apart;
        sl.w = p.w;
        sl.h = p.h;
        sl.gpu = f.gpu;
        sl.gpu_dev = f.gpu_dev;
        sl.gpu_pitch = @intCast(f.gpu_pitch);
        p.mutex.lock();
        p.ready = idx;
        p.cond.signal();
        p.mutex.unlock();
    }

    /// Prévia que veio pronta da placa (RGBA, pequena): só copia pra UI.
    fn takePreview(p: *Pipeline, f: *const c.cap_frame) void {
        const s = p.s;
        const pw: usize = @intCast(f.preview_w);
        const ph: usize = @intCast(f.preview_h);
        const need = pw * ph * 4;
        if (need == 0) return;
        if (p.preview_back.len != need) {
            gpa.free(p.preview_back);
            p.preview_back = gpa.alloc(u8, need) catch &.{};
            if (p.preview_back.len != need) return;
        }
        @memcpy(p.preview_back, f.preview[0..need]);
        s.mutex.lock();
        std.mem.swap([]u8, &s.preview, &p.preview_back);
        s.preview_w = @intCast(pw);
        s.preview_h = @intCast(ph);
        s.preview_bgr = false;
        s.preview_new = true;
        s.mutex.unlock();
        s.client.wake();
    }

    /// Converte pra I420 num slot livre e entrega pro encoder.
    fn publish(p: *Pipeline, frame: []const u8, ts: u64) !void {
        const idx = p.freeSlot();
        const sl = &p.slots[idx];
        p.releaseGpu(sl);
        sl.ts = ts;
        sl.fmt = p.fmt;
        sl.cursor_x = p.cursor_x;
        sl.cursor_y = p.cursor_y;
        sl.cursor_apart = p.cursor_apart;
        const t0 = sync.nowUs();
        if (p.use_hw.load(.acquire)) {
            // hardware: o encoder recebe BGRX direto
            try sl.ensureBgrx(p.w, p.h);
            if (p.event_driven and frame.ptr == p.cur.ptr) {
                std.mem.swap([]u8, &p.cur, &sl.bgrx); // sem cópia
            } else {
                @memcpy(sl.bgrx, frame);
            }
        } else {
            try sl.ensure(p.w, p.h);
            codec.toI420(frame.ptr, @as(usize, p.w) * 4, p.w, p.h, p.fmt, sl.y, sl.u, sl.v);
        }
        _ = p.timing.convert.fetchAdd(sync.nowUs() - t0, .monotonic);

        p.mutex.lock();
        p.ready = idx;
        p.cond.signal();
        p.mutex.unlock();
    }

    /// Prévia pra própria tela (até 30x por segundo), sem segurar o lock da UI.
    /// Acima de 1280 px de largura vai em meia resolução (média 2x2): a prévia
    /// aparece num card, e a UI copia 4x menos pra GPU.
    /// Prévia da fonte inteira (sem o recorte), pra escolher o recorte novo:
    /// amostra simples, já que é só pra ver onde arrastar.
    fn updatePreviewFull(p: *Pipeline, f: *const c.cap_frame) void {
        const s = p.s;
        const now = sync.nowUs();
        if (now - p.last_preview_us < 66_000) return;
        p.last_preview_us = now;
        const fw: usize = @intCast(f.width);
        const fh: usize = @intCast(f.height);
        const k: usize = @max(1, (fw + 1279) / 1280);
        const pw = fw / k;
        const ph = fh / k;
        const need = pw * ph * 4;
        if (p.preview_back.len != need) {
            gpa.free(p.preview_back);
            p.preview_back = gpa.alloc(u8, need) catch &.{};
            if (p.preview_back.len != need) return;
        }
        const stride: usize = @intCast(f.stride);
        for (0..ph) |y| {
            const src = f.data + y * k * stride;
            const d = p.preview_back[y * pw * 4 ..][0 .. pw * 4];
            if (k == 1) {
                @memcpy(d, src[0 .. pw * 4]);
            } else for (0..pw) |x| {
                @memcpy(d[x * 4 ..][0..4], src[x * k * 4 ..][0..4]);
            }
            var x: usize = 3;
            while (x < d.len) : (x += 4) d[x] = 255;
        }
        s.mutex.lock();
        std.mem.swap([]u8, &s.preview, &p.preview_back);
        s.preview_w = @intCast(pw);
        s.preview_h = @intCast(ph);
        s.preview_bgr = f.format != c.CAP_RGBX;
        s.preview_new = true;
        s.mutex.unlock();
        s.client.wake();
    }

    fn updatePreview(p: *Pipeline, frame: []const u8) void {
        const s = p.s;
        const now = sync.nowUs();
        // miniatura: 15 q/s basta, e só se a interface estiver mostrando
        if (now - p.last_preview_us < 66_000) return;
        if (sync.nowMs() -| s.preview_wanted_ms.load(.monotonic) > 1000 and s.preview.len > 0) return;
        p.last_preview_us = now;
        const half = p.w > 1280;
        const pw = if (half) p.w / 2 else p.w;
        const ph = if (half) p.h / 2 else p.h;
        const need = @as(usize, pw) * ph * 4;
        if (p.preview_back.len != need) {
            gpa.free(p.preview_back);
            p.preview_back = gpa.alloc(u8, need) catch &.{};
            if (p.preview_back.len != need) return;
        }
        if (half) {
            const src_row = @as(usize, p.w) * 4;
            for (0..ph) |y| {
                const r0 = frame[(y * 2) * src_row ..][0..src_row];
                const r1 = frame[(y * 2 + 1) * src_row ..][0..src_row];
                const d = p.preview_back[y * pw * 4 ..][0 .. pw * 4];
                for (0..pw) |x| {
                    inline for (0..3) |ch| {
                        const sum: u32 = @as(u32, r0[x * 8 + ch]) + r0[x * 8 + 4 + ch] + r1[x * 8 + ch] + r1[x * 8 + 4 + ch];
                        d[x * 4 + ch] = @intCast((sum + 2) / 4);
                    }
                    d[x * 4 + 3] = 255;
                }
            }
        } else {
            @memcpy(p.preview_back, frame);
        }
        s.mutex.lock();
        std.mem.swap([]u8, &s.preview, &p.preview_back);
        s.preview_w = pw;
        s.preview_h = ph;
        s.preview_bgr = p.fmt == .bgrx;
        s.preview_new = true;
        s.mutex.unlock();
        s.client.wake();
    }

    // ---- captura → `cur` (escala opcional, em paralelo)

    const ScaleCtx = struct {
        dst: []u8,
        ow: u32,
        oh: u32,
        src: [*]const u8,
        sw: u32,
        sh: u32,
        stride: u32,
        bands: u32,
    };

    fn scaleBand(ctx: *const ScaleCtx, band: usize) void {
        const rows_per = (ctx.oh + ctx.bands - 1) / ctx.bands;
        const y_start: u32 = @intCast(band * rows_per);
        const y_end = @min(ctx.oh, y_start + rows_per);
        if (ctx.oh == ctx.sh and ctx.ow <= ctx.sw) {
            // mesmo tamanho (no máximo cortando 1 coluna/linha ímpar)
            const row = @as(usize, ctx.ow) * 4;
            var y = y_start;
            while (y < y_end) : (y += 1)
                @memcpy(ctx.dst[@as(usize, y) * row ..][0..row], ctx.src[@as(usize, y) * ctx.stride ..][0..row]);
            return;
        }
        // bilinear em ponto fixo
        const fx: u64 = (@as(u64, ctx.sw) << 16) / ctx.ow;
        const fy: u64 = (@as(u64, ctx.sh) << 16) / ctx.oh;
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const syf: u64 = ((2 * @as(u64, y) + 1) * fy / 2) -| (1 << 15);
            const y0: u32 = @min(@as(u32, @intCast(syf >> 16)), ctx.sh - 1);
            const wy: u32 = @intCast((syf & 0xffff) >> 8);
            const y1: u32 = @min(y0 + 1, ctx.sh - 1);
            const r0 = ctx.src + @as(usize, y0) * ctx.stride;
            const r1 = ctx.src + @as(usize, y1) * ctx.stride;
            const d = ctx.dst[@as(usize, y) * ctx.ow * 4 ..];
            var x: u32 = 0;
            while (x < ctx.ow) : (x += 1) {
                const sxf: u64 = ((2 * @as(u64, x) + 1) * fx / 2) -| (1 << 15);
                const x0: u32 = @min(@as(u32, @intCast(sxf >> 16)), ctx.sw - 1);
                const wx: u32 = @intCast((sxf & 0xffff) >> 8);
                const x1: u32 = @min(x0 + 1, ctx.sw - 1);
                inline for (0..3) |ch| {
                    const a: u32 = r0[x0 * 4 + ch];
                    const b: u32 = r0[x1 * 4 + ch];
                    const cc: u32 = r1[x0 * 4 + ch];
                    const dd: u32 = r1[x1 * 4 + ch];
                    const top = a * (256 - wx) + b * wx;
                    const bot = cc * (256 - wx) + dd * wx;
                    d[x * 4 + ch] = @intCast((top * (256 - wy) + bot * wy + 32768) >> 16);
                }
                d[x * 4 + 3] = 255;
            }
        }
    }

    fn ingest(p: *Pipeline, f: *const c.cap_frame) !void {
        // recorte: a fonte vira só o retângulo escolhido (alinhado em pares)
        const fw: u32 = @intCast(f.width);
        const fh: u32 = @intCast(f.height);
        const cr = cropRect(p.settings.crop, fw, fh);
        const sw: u32 = cr.w;
        const sh: u32 = cr.h;
        const src_ptr: [*]const u8 = f.data + @as(usize, cr.y) * @as(usize, @intCast(f.stride)) + @as(usize, cr.x) * 4;
        const size = outputSize(sw, sh, p.maxHeight());
        // sem escala e altura/largura ímpar: corta 1 linha/coluna (o H.264 quer pares)
        const exact = size.h == (sh & ~@as(u32, 1)) and size.w == (sw & ~@as(u32, 1));
        const ow = size.w;
        const oh = size.h;
        const need = @as(usize, ow) * oh * 4;
        if (p.cur.len != need) {
            gpa.free(p.cur);
            p.cur = &.{};
            p.cur = try gpa.alloc(u8, need);
        }
        if (!p.event_driven and p.prev.len != need) {
            gpa.free(p.prev);
            p.prev = &.{};
            p.prev = try gpa.alloc(u8, need);
            p.have_prev = false;
        }
        const fmt: codec.PixelFormat = if (f.format == c.CAP_RGBX) .rgbx else .bgrx;
        if (fmt != p.fmt) p.have_prev = false;
        p.fmt = fmt;
        p.w = ow;
        p.h = oh;
        p.src_h = sh;

        const bands: u32 = @intCast(@max(1, @min(sync.pool.threads + 1, 16)));
        const ctx: ScaleCtx = .{
            .dst = p.cur,
            .ow = ow,
            .oh = oh,
            .src = src_ptr,
            .sw = if (exact) ow else sw,
            .sh = if (exact) oh else sh,
            .stride = @intCast(f.stride),
            .bands = bands,
        };
        sync.pool.run(bands, &ctx, scaleBand);

        // ponta do cursor, relativa ao quadro (quem assiste dá zoom seguindo ela)
        p.cursor_x = proto.coord_none;
        p.cursor_y = proto.coord_none;
        const cpx = f.cursor_px - @as(c_int, @intCast(cr.x));
        const cpy = f.cursor_py - @as(c_int, @intCast(cr.y));
        if (f.cursor_known != 0 and cpx >= 0 and cpy >= 0 and cpx < sw and cpy < sh) {
            p.cursor_x = @intCast(@divTrunc(@as(i64, cpx) * 65534, @max(1, sw - 1)));
            p.cursor_y = @intCast(@divTrunc(@as(i64, cpy) * 65534, @max(1, sh - 1)));
        }
        if (f.cursor_draw != 0 and !p.cursor_apart) {
            const sx = @as(f32, @floatFromInt(ow)) / @as(f32, @floatFromInt(if (exact) ow else sw));
            const sy = @as(f32, @floatFromInt(oh)) / @as(f32, @floatFromInt(if (exact) oh else sh));
            const cx = f.cursor_x - @as(c_int, @intCast(cr.x));
            const cy = f.cursor_y - @as(c_int, @intCast(cr.y));
            drawCursor(p.cur, ow, oh, @intFromFloat(@as(f32, @floatFromInt(cx)) * sx), @intFromFloat(@as(f32, @floatFromInt(cy)) * sy), f.cursor_scale * sx);
        }
    }

    // ------------------------------------------------------------ encode

    fn encodeLoop(p: *Pipeline) void {
        sync.nameThread("encoder");
        sync.lowerThreadPriority();
        p.encodeLoopInner() catch |e| {
            if (debugEnabled()) std.debug.print("[telinha] o encoder parou com erro: {s}\n", .{@errorName(e)});
            p.s.fail(Sharer.errorText(e));
        };
        // se o encoder morreu, a captura também tem que parar
        _ = p.s.stop_reason.cmpxchgStrong(.none, .encoder_ended, .acq_rel, .acquire);
        p.s.stop_flag.store(true, .release);
    }

    fn encodeLoopInner(p: *Pipeline) !void {
        const s = p.s;
        // teste (TELINHA_TESTE_PARAR_SOZINHO=s): o encoder termina sozinho depois
        // de s segundos, sem erro (a UI tem que perceber e retomar)
        const teste_parar_us: ?u64 = if (std.c.getenv("TELINHA_TESTE_PARAR_SOZINHO")) |v|
            sync.nowUs() + (std.fmt.parseInt(u64, std.mem.span(v), 10) catch 3) * 1_000_000
        else
            null;
        var enc: ?Encoder = null;
        defer if (enc) |*e| e.deinit();
        var enc_gen: u32 = std.math.maxInt(u32);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var msg: proto.Builder = .{};
        defer msg.deinit();
        var seq: u32 = 0;
        const kind = s.kind;
        s.client.resetInflight(kind);
        var bw: RateControl = .{};
        var stat_since = sync.nowUs();
        var report_since: u64 = sync.nowUs(); // tempos da captura no log: a cada 5 s (era todo segundo)
        var stat_frames: u32 = 0;
        var stat_bytes: u64 = 0;
        var last_key_us: u64 = 0;
        // encoder de hardware que ignora o pedido de IDR (o do wine; algum
        // driver por aí): recria o encoder a cada pedido (encoder novo sempre
        // começa com IDR) — senão quem entra depois nunca vê nada
        var key_misses: u8 = 0;
        var hw_ignores_idr = false;
        var watched_until_ms: u64 = sync.nowMs() + 3000; // começo: anuncia e manda o primeiro IDR

        while (true) {
            // espera um quadro novo (ou um pedido de IDR)
            p.mutex.lock();
            while (p.ready == null and !p.quit and !s.client.keyreq[kind].load(.acquire)) p.cond.timedWait(&p.mutex, 50);
            if (p.quit or (teste_parar_us != null and sync.nowUs() > teste_parar_us.?)) {
                p.mutex.unlock();
                return;
            }
            // clipe da própria transmissão: um IDR a cada 20 s (o clipe começa num)
            const clip_key_us = @min(20_000_000, @as(u64, clip.keep_secs.load(.monotonic)) * 500_000);
            const clip_key = s.clip != null and !s.idle.load(.acquire) and last_key_us != 0 and sync.nowUs() - last_key_us > clip_key_us;
            const key = s.client.keyreq[kind].swap(false, .acq_rel) or clip_key;
            const idx: ?usize = if (p.ready) |r| r else if (key) p.last else null;
            p.ready_was_null = p.ready == null;
            if (p.ready != null) p.ready = null;
            p.encoding = idx;
            const fps = p.fps;
            const quality = p.quality;
            const mode = p.mode;
            const gen = p.fps_gen;
            p.mutex.unlock();
            const i = idx orelse continue;
            const sl = &p.slots[i];
            // reenviando o último quadro (tela parada): ele continua sendo o
            // estado atual da tela, então a "hora da captura" é agora
            const resend = p.ready_was_null;
            const want_hw = p.use_hw.load(.acquire);
            // o slot pode ter sido preenchido no formato antigo (logo após trocar de encoder)
            const gpu_slot = sl.gpu != null;
            if (want_hw and !gpu_slot and sl.bgrx.len != @as(usize, sl.w) * sl.h * 4 or !want_hw and (gpu_slot or sl.y.len != @as(usize, sl.w) * sl.h)) {
                p.doneWith(i, false);
                continue;
            }

            // controle de banda: atraso de ponta a ponta crescendo = o
            // caminho até o servidor não está dando conta
            const up = s.client.uplink(kind);
            if (enc != null and bw.congested(.{
                .now_us = sync.nowUs(),
                .excess_us = up.excess_us,
                .key_allowance_us = up.key_allowance_us,
                .queued_bytes = s.client.queue.queuedBytes(),
                .slow_floor_pct = s.client.viewer_slow[kind].swap(0, .acq_rel),
            })) {
                if (bw.takeChange()) |b| enc.?.setBitrate(b);
                _ = p.timing.skipped.fetchAdd(1, .monotonic);
                if (key) s.client.keyreq[kind].store(true, .release);
                p.doneWith(i, false);
                continue;
            }

            // (re)cria o encoder se mudou resolução ou configuração
            const renew = key and hw_ignores_idr and enc != null and enc.?.isHw();
            // HEVC só se a placa codifica e todo mundo que assiste decodifica
            // (a sala avisa: mensagem `codec`); senão H.264
            const allowed = s.client.codecs_allowed[kind].load(.acquire);
            const want_codec: codec.Codec = if (want_hw and p.hevc_ok and allowed & codec.Codec.hevc.bit() != 0) .hevc else .h264;
            if (enc == null or enc.?.width() != sl.w or enc.?.height() != sl.h or gen != enc_gen or enc.?.isHw() != want_hw or enc.?.codecOf() != want_codec or renew) {
                if (enc) |*e| e.deinit();
                enc = null;
                const target = targetBitrate(sl.w, sl.h, fps, quality);
                if (gen != enc_gen) bw.reset(target) else bw.retarget(target);
                _ = bw.takeChange(); // o encoder novo já nasce com a taxa certa
                // duas camadas temporais: o servidor pode mandar só metade dos
                // quadros pra quem não dá conta. No openh264 e no modo jogo é de
                // graça; com texto, o NVENC gasta ~3x mais bits (zig build bench
                // com TELINHA_BENCH_CAMADAS), então lá fica uma camada só
                const layers: u8 = if (want_hw and (mode == .screen or want_codec != .h264)) 1 else 2;
                const opts: codec.EncoderOptions = .{ .codec = want_codec, .width = sl.w, .height = sl.h, .fps = fps, .bitrate = bw.bps, .mode = mode, .temporal_layers = layers, .d3d_device = if (p.d3d_on.load(.acquire)) p.d3d_dev else null };
                if (want_hw) {
                    var err: [256]u8 = undefined;
                    if (codec.HwEncoder.init(opts, &err)) |h| {
                        enc = .{ .hw = h };
                        // encoder novo: buffers da placa de tamanho antigo podem ir embora
                        if (p.cap) |src| if (src == .screen) c.cap_gpu_gc(src.screen);
                    } else |_| if (want_codec != .h264) {
                        // HEVC não abriu nessa resolução: H.264 daqui pra frente
                        if (debugEnabled()) std.debug.print("[telinha] HEVC falhou ({s}), voltando pro H.264\n", .{std.mem.sliceTo(&err, 0)});
                        p.hevc_ok = false;
                        p.doneWith(i, false);
                        s.client.keyreq[kind].store(true, .release);
                        continue;
                    } else {
                        // NVENC falhou nessa resolução: segue em software daqui pra frente
                        if (debugEnabled()) std.debug.print("[telinha] NVENC falhou ({s}), usando software\n", .{std.mem.sliceTo(&err, 0)});
                        p.use_hw.store(false, .release);
                        p.doneWith(i, false);
                        s.client.keyreq[kind].store(true, .release);
                        continue;
                    }
                } else {
                    enc = .{ .sw = try codec.Encoder.init(opts) };
                }
                enc_gen = gen;
                s.mutex.lock();
                const en = if (enc.? == .hw) enc.?.hw.name() else "openh264";
                const k = @min(en.len, s.encoder_name_buf.len);
                @memcpy(s.encoder_name_buf[0..k], en[0..k]);
                s.encoder_name = s.encoder_name_buf[0..k];
                s.mutex.unlock();
                s.mutex.lock();
                s.w = sl.w;
                s.h = sl.h;
                s.mutex.unlock();
                announce(s, kind, sl.w, sl.h, fps, p.audio_live.load(.acquire));
            } else if (p.reannounce.swap(false, .acq_rel)) {
                announce(s, kind, sl.w, sl.h, fps, p.audio_live.load(.acquire));
            }
            // ninguém assistindo (e sem gravar a própria tela): não codifica nem
            // manda nada. Quem entrar faz o servidor pedir um IDR (key), e
            // depois disso segue codificando um tempo enquanto a lista de
            // membros (que diz quem assiste) chega.
            if (key) watched_until_ms = sync.nowMs() + 2000;
            const watched = sync.nowMs() < watched_until_ms or s.client.anyoneWatching(proto.streamId(s.client.myId(), kind)) or ownRecording(s);
            s.idle.store(!watched, .release);
            if (!watched) {
                p.doneWith(i, false);
                continue;
            }
            bw.rampUp(sync.nowUs(), up.excess_us -| up.key_allowance_us);
            if (bw.takeChange()) |b| enc.?.setBitrate(b);

            const t0 = sync.nowUs();
            if (slowEncodeUs(sl.w, sl.h)) |us| sync.sleepMs(@intCast(us / 1000)); // teste: PC lento
            out.clearRetainingCapacity();
            const is_key = enc.?.encode(sl, key, &out) catch |e| blk: {
                if (enc.? != .hw) return e;
                if (debugEnabled()) std.debug.print("[telinha] encoder em hardware ({s}) falhou no meio: {s}; seguindo em software\n", .{ enc.?.hw.name(), @errorName(e) });
                // erro no NVENC no meio da transmissão: cai pro software
                enc.?.deinit();
                enc = null;
                p.use_hw.store(false, .release);
                s.client.keyreq[kind].store(true, .release);
                break :blk null;
            } orelse {
                if (enc != null) _ = p.timing.enc_dropped.fetchAdd(1, .monotonic);
                p.doneWith(i, enc != null);
                continue;
            };
            // cada IDR conta (o log mostra o resumo); só o estranho vira linha
            if (key and is_key) _ = (if (clip_key) &s.idr_clip else &s.idr_room).fetchAdd(1, .monotonic);
            if (key and !is_key and debugEnabled()) std.debug.print("[telinha] IDR pedido, mas o encoder fez um P ({d} bytes)\n", .{out.items.len});
            if (key and !is_key and enc.?.isHw()) {
                // pode ser só atraso de um quadro (encoder assíncrono): pede de
                // novo; na segunda vez seguida, desiste de pedir e recria
                key_misses += 1;
                if (key_misses >= 2 and !hw_ignores_idr) {
                    hw_ignores_idr = true;
                    if (debugEnabled()) std.debug.print("[telinha] o encoder {s} ignora pedido de IDR: recriando a cada pedido\n", .{enc.?.hw.name()});
                }
                s.client.keyreq[kind].store(true, .release);
            } else if (is_key) key_misses = 0;
            const frame_seq = seq;
            seq +%= 1;
            try msg.begin(.frame);
            try msg.u32_(frame_seq);
            const cam: u8 = if (kind == proto.kind_camera) proto.frame_camera else 0;
            const cd = enc.?.codecOf();
            const cflag: u8 = @as(u8, @intFromEnum(cd)) << proto.frame_codec_shift;
            const apart: u8 = if (sl.cursor_apart) proto.frame_cursor_apart else 0;
            try msg.u8_(cam | cflag | apart | if (is_key) proto.frame_key else if (cd == .h264 and codec.isDroppable(out.items)) proto.frame_droppable else 0);
            try msg.u64_(if (resend) s.client.serverNowUs() else sl.ts);
            try msg.u16_(@intCast(sl.w));
            try msg.u16_(@intCast(sl.h));
            try msg.u16_(sl.cursor_x);
            try msg.u16_(sl.cursor_y);
            try msg.bytes(out.items);
            const m = try msg.finish();
            stat_bytes += m.data.len;
            stat_frames += 1;
            if (is_key) last_key_us = sync.nowUs();
            if (s.clip) |cb| cb.addVideo(out.items, if (resend) s.client.serverNowUs() else sl.ts, is_key, @intCast(sl.w), @intCast(sl.h), cd);
            // registra antes de enfileirar: a confirmação pode voltar muito rápido
            s.client.frameSent(kind, frame_seq, is_key);
            _ = s.frames_sent.fetchAdd(1, .monotonic);
            s.client.queue.pushOwned(m);
            p.doneWith(i, true);
            const enc_us = sync.nowUs() - t0;
            const enc_ms = @as(f32, @floatFromInt(enc_us)) / 1000.0;
            _ = p.timing.encode.fetchAdd(enc_us, .monotonic);
            _ = p.timing.encoded.fetchAdd(1, .monotonic);
            const ema = p.enc_ema_us.load(.monotonic);
            p.enc_ema_us.store(if (ema == 0) enc_us else (ema * 7 + enc_us) / 8, .monotonic);

            s.mutex.lock();
            s.state = .live;
            s.encode_ms = s.encode_ms * 0.9 + enc_ms * 0.1;
            s.bitrate_kbps = bw.bps / 1000;
            const tnow = sync.nowUs();
            if (tnow - stat_since >= 1_000_000) {
                const secs = @as(f32, @floatFromInt(tnow - stat_since)) / 1e6;
                s.fps = @as(f32, @floatFromInt(stat_frames)) / secs;
                s.kbps = @as(f32, @floatFromInt(stat_bytes)) / 1024.0 / secs;
                s.stat_ms = sync.nowMs();
                s.congested = tnow - bw.last_congestion_us < 2_000_000;
                s.slow_viewer = bw.last_slow_us != 0 and tnow - bw.last_slow_us < 10_000_000;
                if (debugEnabled() and tnow - report_since >= 5_000_000) {
                    p.timing.report(bw.bps, s.client.queue.queuedBytes(), @as(f32, @floatFromInt(tnow - report_since)) / 1e6);
                    report_since = tnow;
                }
                stat_frames = 0;
                stat_bytes = 0;
                stat_since = tnow;
            }
            s.mutex.unlock();
        }
    }

    /// Libera o slot que o encoder usou (e guarda como "último" se foi codificado).
    fn doneWith(p: *Pipeline, idx: usize, encoded: bool) void {
        p.mutex.lock();
        defer p.mutex.unlock();
        p.encoding = null;
        if (encoded) p.last = idx;
    }

    fn announce(s: *Sharer, kind: u8, w: u32, h: u32, fps: u32, with_audio: bool) void {
        const m = proto.Msg.alloc(.stream_start, 7) catch return;
        const pl = m.payload();
        pl[0] = kind;
        std.mem.writeInt(u16, pl[1..3], @intCast(w), .little);
        std.mem.writeInt(u16, pl[3..5], @intCast(h), .little);
        pl[5] = @intCast(fps);
        pl[6] = if (with_audio) proto.stream_audio else 0;
        s.client.queue.pushOwned(m);
    }

    /// Pacote Opus pronto (thread de áudio): manda pra sala com a hora da captura.
    fn onAudioPacket(ctx: *anyopaque, packet: []const u8) void {
        const p: *Pipeline = @ptrCast(@alignCast(ctx));
        const s = p.s;
        const m = proto.Msg.alloc(.audio, proto.audio_header_len + packet.len) catch return;
        const pl = m.payload();
        std.mem.writeInt(u32, pl[0..4], p.audio_seq, .little);
        p.audio_seq +%= 1;
        // o pacote cobre os últimos 10 ms: a captura foi ~10 ms atrás
        const ts = s.client.serverNowUs() -| 10_000;
        std.mem.writeInt(u64, pl[4..12], ts, .little);
        if (s.clip) |cb| cb.addAudio(packet, ts);
        @memcpy(pl[12..], packet);
        s.client.queue.pushUrgentOwned(m); // som não espera atrás de quadro
    }
};

/// Seta do mouse (contorno preto, miolo branco), desenhada quando o sistema
/// não embute o cursor no quadro. 'X' = preto, '.' = branco.
const arrow = [_][]const u8{
    "X",
    "XX",
    "X.X",
    "X..X",
    "X...X",
    "X....X",
    "X.....X",
    "X......X",
    "X.......X",
    "X........X",
    "X.........X",
    "X..........X",
    "X......XXXXX",
    "X...X..X",
    "X..XX..X",
    "X.X  X..X",
    "XX   X..X",
    "X     X..X",
    "      X..X",
    "       XX",
};

/// Pra captura pela placa (capture.h, cap_rect_fn): recorte e tamanho de
/// saída com as mesmas regras do caminho pela CPU (cropRect/outputSize).
fn outputRect(fw: c_int, fh: c_int, crop: [*c]const f32, max_h: c_int, x: [*c]c_int, y: [*c]c_int, w: [*c]c_int, h: [*c]c_int, ow: [*c]c_int, oh: [*c]c_int) callconv(.c) void {
    const cr = cropRect(crop[0..4].*, @intCast(@max(1, fw)), @intCast(@max(1, fh)));
    const size = outputSize(cr.w, cr.h, @intCast(@max(0, max_h)));
    x.* = @intCast(cr.x);
    y.* = @intCast(cr.y);
    // sem escala e altura/largura ímpar: corta 1 linha/coluna (o H.264 quer pares)
    const exact = size.h == (cr.h & ~@as(u32, 1)) and size.w == (cr.w & ~@as(u32, 1));
    w.* = @intCast(if (exact) size.w else cr.w);
    h.* = @intCast(if (exact) size.h else cr.h);
    ow.* = @intCast(size.w);
    oh.* = @intCast(size.h);
}

/// A seta do cursor em RGBA (cap_cursor_fn), a mesma do drawCursor.
const cursor_w: usize = blk: {
    var maxw: usize = 0;
    for (arrow) |line| maxw = @max(maxw, line.len);
    break :blk maxw;
};
const cursor_px: [arrow.len * cursor_w * 4]u8 = blk: {
    var px: [arrow.len * cursor_w * 4]u8 = undefined;
    for (arrow, 0..) |line, yy| {
        for (0..cursor_w) |xx| {
            const o = (yy * cursor_w + xx) * 4;
            const ch: u8 = if (xx < line.len) line[xx] else ' ';
            const v: u8 = if (ch == '.') 255 else 0;
            px[o] = v;
            px[o + 1] = v;
            px[o + 2] = v;
            px[o + 3] = if (ch == 'X' or ch == '.') 255 else 0;
        }
    }
    break :blk px;
};

fn cursorRgba(w: [*c]c_int, h: [*c]c_int) callconv(.c) [*c]const u8 {
    w.* = @intCast(cursor_w);
    h.* = @intCast(arrow.len);
    return &cursor_px;
}

fn drawCursor(buf: []u8, w: u32, h: u32, x0: i32, y0: i32, logical_scale: f32) void {
    // o cursor real tem ~24 px lógicos de altura; a seta tem 20 linhas
    const k = @max(1.0, logical_scale * 1.2);
    const rows: i32 = @intFromFloat(@as(f32, arrow.len) * k);
    var py: i32 = 0;
    while (py < rows) : (py += 1) {
        const y = y0 + py;
        if (y < 0 or y >= h) continue;
        const ay: usize = @intFromFloat(@as(f32, @floatFromInt(py)) / k);
        if (ay >= arrow.len) continue;
        const line = arrow[ay];
        const cols: i32 = @intFromFloat(@as(f32, @floatFromInt(line.len)) * k);
        var px: i32 = 0;
        while (px < cols) : (px += 1) {
            const x = x0 + px;
            if (x < 0 or x >= w) continue;
            const ax: usize = @intFromFloat(@as(f32, @floatFromInt(px)) / k);
            if (ax >= line.len) continue;
            const v: u8 = switch (line[ax]) {
                'X' => 0,
                '.' => 255,
                else => continue,
            };
            const o = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 4;
            buf[o] = v;
            buf[o + 1] = v;
            buf[o + 2] = v;
        }
    }
}

/// Encoder em uso: hardware (NVENC, recebe BGRX) ou software (openh264, recebe I420).
const Encoder = union(enum) {
    hw: codec.HwEncoder,
    sw: codec.Encoder,

    fn deinit(e: *Encoder) void {
        switch (e.*) {
            inline else => |*x| x.deinit(),
        }
    }
    fn width(e: *const Encoder) u32 {
        return switch (e.*) {
            inline else => |x| x.opts.width,
        };
    }
    fn height(e: *const Encoder) u32 {
        return switch (e.*) {
            inline else => |x| x.opts.height,
        };
    }
    fn isHw(e: *const Encoder) bool {
        return e.* == .hw;
    }
    fn codecOf(e: *const Encoder) codec.Codec {
        return switch (e.*) {
            .hw => |x| x.opts.codec,
            .sw => .h264,
        };
    }
    fn setBitrate(e: *Encoder, bps: u32) void {
        switch (e.*) {
            inline else => |*x| x.setBitrate(bps),
        }
    }
    fn encode(e: *Encoder, sl: *const Slot, key: bool, out: *std.ArrayList(u8)) !?bool {
        switch (e.*) {
            .hw => |*h| {
                const before = out.items.len;
                const is_key = if (sl.gpu != null)
                    try h.encodeDev(sl.gpu_dev, sl.gpu_pitch, sl.fmt, key, out)
                else
                    try h.encode(sl.bgrx.ptr, @as(usize, sl.w) * 4, sl.fmt, key, out);
                // encoder de hardware que ainda não soltou nada (Media Foundation): sem quadro
                if (out.items.len == before) return null;
                return is_key;
            },
            .sw => |*x| {
                if (key) x.forceKey();
                return x.encodeI420(sl.y.ptr, sl.u.ptr, sl.v.ptr, out);
            },
        }
    }
};
