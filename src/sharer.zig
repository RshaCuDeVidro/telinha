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
    @cInclude("camera.h");
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
    mode: codec.Mode = .screen,
    hardware: bool = true, // tenta NVENC antes do encoder em software
    audio: bool = true, // compartilha o som do computador
    audio_app: [64]u8 = [_]u8{0} ** 64, // só o som desse programa (vazio = tudo menos o telinha)
    audio_pid: u32 = 0, // ou desse processo e filhos (a janela compartilhada)
    clips: bool = true, // guarda os últimos 30 s (clipe da própria transmissão)
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

/// Um quadro já convertido pra I420, esperando o encoder.
const Slot = struct {
    y: []u8 = &.{},
    u: []u8 = &.{},
    v: []u8 = &.{},
    bgrx: []u8 = &.{}, // caminho do encoder em hardware (sem conversão na CPU)
    fmt: codec.PixelFormat = .bgrx,
    w: u32 = 0,
    h: u32 = 0,
    ts: u64 = 0, // hora da captura (relógio da sala)
    cursor_x: u16 = proto.coord_none, // ponta do cursor no quadro (0..65534)
    cursor_y: u16 = proto.coord_none,

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
    encode_ms: f32 = 0,
    bitrate_kbps: u32 = 0,
    congested: bool = false,
    slow_viewer: bool = false, // algum espectador pediu menos nos últimos segundos
    encoder_name: []const u8 = "",
    encoder_name_buf: [48]u8 = undefined, // cópia (o encoder pode ser recriado a qualquer hora)
    audio_on: bool = false, // capturando o som do computador
    audio_hears_self: bool = false, // a captura pega também o que o telinha toca (jeito antigo)
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
    /// Ninguém assistindo e sem gravação: o encoder está parado (a captura
    /// cai pra 5 q/s, só pra prévia e pra ter quadro na hora que alguém entrar).
    idle: std.atomic.Value(bool) = .init(false),
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
        s.mutex.unlock();
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
    /// Encoder em hardware em uso? Decidido no início; vira false se o NVENC falhar.
    use_hw: std.atomic.Value(bool) = .init(false),
    hevc_ok: bool = false, // a placa codifica HEVC (testado no começo)
    audio_sender: ?*audio.Sender = null,
    audio_live: std.atomic.Value(bool) = .init(false), // tem som saindo (vai no anúncio)
    reannounce: std.atomic.Value(bool) = .init(false), // o som mudou: anunciar de novo
    audio_seq: u32 = 0,
    fps_gen: u32 = 0, // muda quando fps/modo/qualidade mudam (encoder recria)
    fps: u32 = 30,
    quality: u8 = 60,
    mode: codec.Mode = .screen,

    fn errSlice(p: *Pipeline) []const u8 {
        return std.mem.sliceTo(&p.err, 0);
    }

    fn deinit(p: *Pipeline) void {
        if (p.audio_sender) |a| a.destroy();
        if (p.cap) |cp| cp.close();
        gpa.free(p.cur);
        gpa.free(p.prev);
        gpa.free(p.preview_back);
        for (&p.slots) |*sl| sl.deinit();
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
                pr.deinit();
                p.use_hw.store(true, .release);
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
        if (audio.Sender.create(p, onAudioPacket, .{ .app = std.mem.sliceTo(&p.settings.audio_app, 0), .pid = p.settings.audio_pid }, &err)) |a| {
            p.audio_sender = a;
        } else |_| {}
        p.audio_live.store(p.audio_sender != null, .release);
        s.mutex.lock();
        @memcpy(&s.audio_err, &err);
        s.audio_on = p.audio_sender != null;
        s.audio_hears_self = if (p.audio_sender) |a| a.hearsSelf() else false;
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
                if (old_audio != p.settings.audio or old_pid != p.settings.audio_pid or !std.mem.eql(u8, &old_app, &p.settings.audio_app)) {
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

            var f: c.cap_frame = std.mem.zeroes(c.cap_frame);
            const t_cap = sync.nowUs();
            const r = p.cap.?.next(&f, 50, &p.err);
            if (r < 0) return error.Capture;
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
            try p.ingest(&f);
            _ = p.timing.capture.fetchAdd(t_ing - t_cap, .monotonic);
            _ = p.timing.ingest.fetchAdd(sync.nowUs() - t_ing, .monotonic);
            _ = p.timing.captured.fetchAdd(1, .monotonic);
            if (!p.event_driven) {
                // captura por polling: pula quadro idêntico ao anterior
                if (p.have_prev and std.mem.eql(u8, p.cur, p.prev)) continue;
                std.mem.swap([]u8, &p.cur, &p.prev);
                p.have_prev = true;
            }
            const frame = if (p.event_driven) p.cur else p.prev;
            // a prévia sai antes de entregar o quadro (no hardware o buffer troca de dono)
            p.updatePreview(frame);
            try p.publish(frame, ts);
        }
    }

    /// Converte pra I420 num slot livre e entrega pro encoder.
    fn publish(p: *Pipeline, frame: []const u8, ts: u64) !void {
        p.mutex.lock();
        // slot livre: nem o que está sendo codificado, nem o último codificado;
        // se o "pronto" ainda não foi pego, ele é substituído pelo mais novo
        var idx: usize = 0;
        for (0..3) |i| {
            if (p.encoding == i or p.last == i) continue;
            idx = i;
            if (p.ready != i) break;
        }
        if (p.ready == idx) p.ready = null;
        p.mutex.unlock();

        const sl = &p.slots[idx];
        sl.ts = ts;
        sl.fmt = p.fmt;
        sl.cursor_x = p.cursor_x;
        sl.cursor_y = p.cursor_y;
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
        const sw: u32 = @intCast(f.width);
        const sh: u32 = @intCast(f.height);
        const size = outputSize(sw, sh, p.settings.max_height);
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

        const bands: u32 = @intCast(@max(1, @min(sync.pool.threads + 1, 16)));
        const ctx: ScaleCtx = .{
            .dst = p.cur,
            .ow = ow,
            .oh = oh,
            .src = f.data,
            .sw = if (exact) ow else sw,
            .sh = if (exact) oh else sh,
            .stride = @intCast(f.stride),
            .bands = bands,
        };
        sync.pool.run(bands, &ctx, scaleBand);

        // ponta do cursor, relativa ao quadro (quem assiste dá zoom seguindo ela)
        p.cursor_x = proto.coord_none;
        p.cursor_y = proto.coord_none;
        if (f.cursor_known != 0 and f.cursor_px >= 0 and f.cursor_py >= 0 and f.cursor_px < f.width and f.cursor_py < f.height) {
            p.cursor_x = @intCast(@divTrunc(@as(i64, f.cursor_px) * 65534, @max(1, f.width - 1)));
            p.cursor_y = @intCast(@divTrunc(@as(i64, f.cursor_py) * 65534, @max(1, f.height - 1)));
        }
        if (f.cursor_draw != 0) {
            const sx = @as(f32, @floatFromInt(ow)) / @as(f32, @floatFromInt(if (exact) ow else sw));
            const sy = @as(f32, @floatFromInt(oh)) / @as(f32, @floatFromInt(if (exact) oh else sh));
            drawCursor(p.cur, ow, oh, @intFromFloat(@as(f32, @floatFromInt(f.cursor_x)) * sx), @intFromFloat(@as(f32, @floatFromInt(f.cursor_y)) * sy), f.cursor_scale * sx);
        }
    }

    // ------------------------------------------------------------ encode

    fn encodeLoop(p: *Pipeline) void {
        sync.lowerThreadPriority();
        p.encodeLoopInner() catch |e| p.s.fail(Sharer.errorText(e));
        // se o encoder morreu, a captura também tem que parar
        p.s.stop_flag.store(true, .release);
    }

    fn encodeLoopInner(p: *Pipeline) !void {
        const s = p.s;
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
            if (p.quit) {
                p.mutex.unlock();
                return;
            }
            // clipe da própria transmissão: um IDR a cada 20 s (o clipe começa num)
            if (s.clip != null and !s.idle.load(.acquire) and last_key_us != 0 and sync.nowUs() - last_key_us > 20_000_000) s.client.keyreq[kind].store(true, .release);
            const key = s.client.keyreq[kind].swap(false, .acq_rel);
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
            if (want_hw and sl.bgrx.len != @as(usize, sl.w) * sl.h * 4 or !want_hw and sl.y.len != @as(usize, sl.w) * sl.h) {
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
                const opts: codec.EncoderOptions = .{ .codec = want_codec, .width = sl.w, .height = sl.h, .fps = fps, .bitrate = bw.bps, .mode = mode, .temporal_layers = layers };
                if (want_hw) {
                    var err: [256]u8 = undefined;
                    if (codec.HwEncoder.init(opts, &err)) |h| {
                        enc = .{ .hw = h };
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
            if (key and debugEnabled()) std.debug.print("[telinha] IDR pedido: codificado como {s} ({d} bytes)\n", .{ if (is_key) "IDR" else "P (!)", out.items.len });
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
            try msg.u8_(cam | cflag | if (is_key) proto.frame_key else if (cd == .h264 and codec.isDroppable(out.items)) proto.frame_droppable else 0);
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
                s.congested = tnow - bw.last_congestion_us < 2_000_000;
                s.slow_viewer = bw.last_slow_us != 0 and tnow - bw.last_slow_us < 10_000_000;
                if (debugEnabled()) p.timing.report(bw.bps, s.client.queue.queuedBytes(), secs);
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
        s.client.queue.pushOwned(m);
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
                const is_key = try h.encode(sl.bgrx.ptr, @as(usize, sl.w) * 4, sl.fmt, key, out);
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
