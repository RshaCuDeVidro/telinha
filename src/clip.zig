//! Os últimos ~30 s (escolhível: 15 s a 3 min) de uma transmissão (o H.264 e o Opus como chegam), pra
//! salvar um clipe na hora, e a gravação em andamento. Quem assiste guarda o
//! que recebe; quem transmite guarda o que codifica.
//!
//! Um clipe só pode começar num quadro completo (IDR): o buffer guarda a
//! partir do IDR mais novo que ainda cobre os 30 s. O servidor pede um IDR de
//! vez em quando pra quem tem clipes ligados (proto.watch_clips), então isso
//! fica perto de 30-50 s de vídeo na memória.
const std = @import("std");
const sync = @import("sync.zig");
const mp4 = @import("mp4.zig");
const codec = @import("codec.zig");
const gpa = std.heap.c_allocator;

/// Duração do clipe (segundos), escolhida nas configurações.
pub var keep_secs: std.atomic.Value(u32) = .init(30);

fn keepUs() u64 {
    return @as(u64, keep_secs.load(.monotonic)) * 1_000_000;
}

/// Teto por transmissão (vídeo pesado não come a RAM): ~3 MB por segundo guardado.
fn maxBytes() usize {
    return @max(32 * 1024 * 1024, @as(usize, keep_secs.load(.monotonic)) * 3 * 1024 * 1024);
}

const Frame = struct { data: []u8, ts_us: u64, key: bool, w: u16, h: u16, hevc: bool };
const Packet = struct { data: []u8, ts_us: u64 };

pub const Buffer = struct {
    mutex: sync.Mutex = .{},
    frames: std.ArrayList(Frame) = .empty,
    packets: std.ArrayList(Packet) = .empty,
    bytes: usize = 0,
    last_ts_us: u64 = 0,
    // gravação
    recorder: ?*mp4.Recorder = null,
    rec_path: [512:0]u8 = [_:0]u8{0} ** 512,
    rec_waiting: bool = false, // esperando o próximo IDR pra começar
    rec_error: bool = false,

    pub fn create() !*Buffer {
        const b = try gpa.create(Buffer);
        b.* = .{};
        return b;
    }

    pub fn destroy(b: *Buffer) void {
        _ = b.stopRecording();
        for (b.frames.items) |f| gpa.free(f.data);
        for (b.packets.items) |p| gpa.free(p.data);
        b.frames.deinit(gpa);
        b.packets.deinit(gpa);
        gpa.destroy(b);
    }

    /// Um quadro (Annex B) com a hora da captura.
    pub fn addVideo(b: *Buffer, data: []const u8, ts_in: u64, key: bool, w: u16, h: u16, cd: codec.Codec) void {
        const hevc = cd == .hevc;
        b.mutex.lock();
        defer b.mutex.unlock();
        // hora sempre crescendo (um IDR reenviado com a tela parada leva a hora
        // do reenvio, e o quadro seguinte pode ter sido capturado um pouco antes)
        const ts_us = @max(ts_in, b.last_ts_us + 1000);
        b.last_ts_us = ts_us;
        // mudou a resolução ou o codec: o que tinha antes não entra no mesmo arquivo
        if (key and b.frames.items.len > 0) {
            const last = b.frames.items[b.frames.items.len - 1];
            if (last.w != w or last.h != h or last.hevc != hevc) b.dropBefore(b.frames.items.len);
        }
        if (b.frames.items.len == 0 and !key) {
            b.feedRecorder(data, ts_us, key, w, h, hevc);
            return; // sem IDR ainda: nada pra guardar
        }
        const copy = gpa.dupe(u8, data) catch return;
        b.frames.append(gpa, .{ .data = copy, .ts_us = ts_us, .key = key, .w = w, .h = h, .hevc = hevc }) catch {
            gpa.free(copy);
            return;
        };
        b.bytes += copy.len;
        b.trim(ts_us);
        b.feedRecorder(data, ts_us, key, w, h, hevc);
    }

    pub fn addAudio(b: *Buffer, data: []const u8, ts_us: u64) void {
        b.mutex.lock();
        defer b.mutex.unlock();
        if (b.recorder) |r| r.addAudio(.{ .data = data, .ts_us = ts_us }) catch {};
        if (b.frames.items.len == 0) return;
        if (ts_us + 1_000_000 < b.frames.items[0].ts_us) return;
        const copy = gpa.dupe(u8, data) catch return;
        b.packets.append(gpa, .{ .data = copy, .ts_us = ts_us }) catch {
            gpa.free(copy);
            return;
        };
        b.bytes += copy.len;
    }

    /// Guarda a partir do IDR mais novo que ainda cobre `keep_us` (e respeita o teto de memória).
    fn trim(b: *Buffer, now_us: u64) void {
        while (true) {
            // o segundo IDR: dá pra jogar fora tudo antes dele?
            var second: ?usize = null;
            for (b.frames.items[1..], 1..) |f, i| if (f.key) {
                second = i;
                break;
            };
            const i = second orelse {
                // um IDR só: se passou do teto (ou os IDRs pararam de vir e
                // isso só cresce), joga tudo fora e recomeça no próximo IDR
                const old_us = now_us -| b.frames.items[0].ts_us;
                if (b.bytes > maxBytes() or old_us > 3 * keepUs()) b.dropBefore(b.frames.items.len);
                return;
            };
            const covers = now_us -| b.frames.items[i].ts_us >= keepUs();
            if (!covers and b.bytes <= maxBytes()) return;
            b.dropBefore(i);
        }
    }

    fn dropBefore(b: *Buffer, n: usize) void {
        for (b.frames.items[0..n]) |f| {
            b.bytes -= f.data.len;
            gpa.free(f.data);
        }
        std.mem.copyForwards(Frame, b.frames.items[0 .. b.frames.items.len - n], b.frames.items[n..]);
        b.frames.items.len -= n;
        // som de antes do primeiro quadro que sobrou
        const first_us = if (b.frames.items.len > 0) b.frames.items[0].ts_us else std.math.maxInt(u64);
        var k: usize = 0;
        while (k < b.packets.items.len and b.packets.items[k].ts_us + 50_000 < first_us) k += 1;
        for (b.packets.items[0..k]) |p| {
            b.bytes -= p.data.len;
            gpa.free(p.data);
        }
        std.mem.copyForwards(Packet, b.packets.items[0 .. b.packets.items.len - k], b.packets.items[k..]);
        b.packets.items.len -= k;
    }

    /// Segundos guardados (o tamanho do clipe se salvar agora).
    pub fn seconds(b: *Buffer) f32 {
        b.mutex.lock();
        defer b.mutex.unlock();
        if (b.frames.items.len < 2) return 0;
        const span = b.frames.items[b.frames.items.len - 1].ts_us - b.frames.items[0].ts_us;
        return @as(f32, @floatFromInt(@min(span, keepUs() + 30_000_000))) / 1e6;
    }

    /// Cópia do que está guardado (pra escrever o arquivo fora do lock).
    pub const Snapshot = struct {
        video: []mp4.VideoSample,
        audio: []mp4.AudioSample,
        w: u32,
        h: u32,

        pub fn deinit(s: *Snapshot) void {
            for (s.video) |v| gpa.free(v.data);
            for (s.audio) |a| gpa.free(a.data);
            gpa.free(s.video);
            gpa.free(s.audio);
        }
    };

    /// Os últimos `keep_us` (a partir do IDR mais novo que os cobre).
    pub fn snapshot(b: *Buffer) !Snapshot {
        b.mutex.lock();
        defer b.mutex.unlock();
        if (b.frames.items.len == 0) return error.Empty;
        const newest = b.frames.items[b.frames.items.len - 1].ts_us;
        var start: usize = 0;
        for (b.frames.items, 0..) |f, i| {
            if (f.key and newest -| f.ts_us >= keepUs()) start = i;
        }
        const frames = b.frames.items[start..];
        var video = try gpa.alloc(mp4.VideoSample, frames.len);
        var nv: usize = 0;
        errdefer {
            for (video[0..nv]) |v| gpa.free(v.data);
            gpa.free(video);
        }
        for (frames) |f| {
            video[nv] = .{ .data = try gpa.dupe(u8, f.data), .ts_us = f.ts_us, .key = f.key };
            nv += 1;
        }
        var na: usize = 0;
        for (b.packets.items) |p| na += @intFromBool(p.ts_us + 5_000 >= frames[0].ts_us);
        const audio = try gpa.alloc(mp4.AudioSample, na);
        var k: usize = 0;
        for (b.packets.items) |p| {
            if (p.ts_us + 5_000 < frames[0].ts_us) continue;
            audio[k] = .{ .data = gpa.dupe(u8, p.data) catch {
                for (audio[0..k]) |x| gpa.free(x.data);
                gpa.free(audio);
                return error.OutOfMemory;
            }, .ts_us = p.ts_us };
            k += 1;
        }
        return .{ .video = video, .audio = audio, .w = frames[0].w, .h = frames[0].h };
    }

    // -------------------------------------------------------------- gravação

    /// Começa a gravar em `path` no próximo IDR (quem chama pede um: a
    /// gravação começa na hora do clique, sem nada de antes).
    pub fn startRecording(b: *Buffer, path: []const u8) void {
        b.mutex.lock();
        defer b.mutex.unlock();
        if (b.recorder != null or b.rec_waiting) return;
        const n = @min(path.len, b.rec_path.len);
        @memcpy(b.rec_path[0..n], path[0..n]);
        b.rec_path[n] = 0;
        b.rec_error = false;
        b.rec_waiting = true;
    }

    fn feedRecorder(b: *Buffer, data: []const u8, ts_us: u64, key: bool, w: u16, h: u16, hevc: bool) void {
        if (b.rec_waiting and key) {
            b.rec_waiting = false;
            const n = std.mem.len(@as([*:0]const u8, &b.rec_path));
            b.recorder = mp4.Recorder.start(b.rec_path[0..n :0], w, h, .{ .data = data, .ts_us = ts_us, .key = true }, true) catch {
                b.rec_error = true;
                return;
            };
            return;
        }
        const r = b.recorder orelse return;
        if (key and (w != r.w or h != r.h or hevc != r.hevc)) {
            // resolução ou codec mudou no meio: fecha esse arquivo (o próximo IDR não cabe nele)
            r.finish();
            b.recorder = null;
            return;
        }
        r.addVideo(.{ .data = data, .ts_us = ts_us, .key = key }) catch {
            b.rec_error = true;
        };
    }

    pub const RecState = struct { active: bool, waiting: bool, ms: u64, failed: bool };

    pub fn recState(b: *Buffer) RecState {
        b.mutex.lock();
        defer b.mutex.unlock();
        return .{
            .active = b.recorder != null or b.rec_waiting,
            .waiting = b.rec_waiting,
            .ms = if (b.recorder) |r| r.durationMs() else 0,
            .failed = b.rec_error,
        };
    }

    /// Termina a gravação. Retorna a duração (ms), 0 se não tinha nada.
    pub fn stopRecording(b: *Buffer) u64 {
        b.mutex.lock();
        defer b.mutex.unlock();
        b.rec_waiting = false;
        const r = b.recorder orelse return 0;
        const ms = r.durationMs();
        r.finish();
        b.recorder = null;
        return ms;
    }
};

// ---------------------------------------------------------------------------
// Onde salvar

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const cio = @cImport({
    @cInclude("stdio.h");
});
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, attrs: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;

fn makeDir(path: [:0]const u8) void {
    if (sync.is_windows) {
        var w: [1024:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&w, path) catch return;
        if (n >= w.len) return;
        w[n] = 0;
        _ = CreateDirectoryW(&w, null);
    } else _ = mkdir(path.ptr, 0o755);
}

/// %USERPROFILE% em UTF-8 (a pasta do usuário pode ter acento).
fn userProfile(buf: []u8) []const u8 {
    var w: [512]u16 = undefined;
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"), &w, w.len);
    if (n == 0 or n >= w.len) return "C:\\";
    const len = std.unicode.utf16LeToUtf8(buf, w[0..n]) catch return "C:\\";
    return buf[0..len];
}

/// Pasta dos clipes: TELINHA_PASTA_CLIPES, senão Vídeos/telinha (a pasta de
/// vídeos do usuário: XDG_VIDEOS_DIR no Linux, %USERPROFILE%\Videos no Windows).
pub fn folder(buf: []u8) []const u8 {
    if (getenv("TELINHA_PASTA_CLIPES")) |p| {
        const s = std.mem.span(p);
        const n = @min(s.len, buf.len - 1);
        @memcpy(buf[0..n], s[0..n]);
        buf[n] = 0;
        makeDir(buf[0..n :0]);
        return buf[0..n];
    }
    var base_buf: [400]u8 = undefined;
    var up_buf: [512]u8 = undefined;
    const base: []const u8 = if (sync.is_windows)
        std.fmt.bufPrint(&base_buf, "{s}\\Videos", .{userProfile(&up_buf)}) catch "C:\\"
    else
        videosDir(&base_buf);
    var tmp: [400:0]u8 = undefined;
    const b0 = std.fmt.bufPrintZ(&tmp, "{s}", .{base}) catch return buf[0..0];
    makeDir(b0);
    const out = std.fmt.bufPrintZ(buf, "{s}{s}telinha", .{ base, if (sync.is_windows) "\\" else "/" }) catch return buf[0..0];
    makeDir(out);
    return out;
}

/// XDG_VIDEOS_DIR de ~/.config/user-dirs.dirs (ex.: ~/Vídeos), senão ~/Videos.
fn videosDir(buf: []u8) []const u8 {
    const home = std.mem.span(getenv("HOME") orelse "/tmp");
    var path_buf: [512]u8 = undefined;
    const cfg_home = if (getenv("XDG_CONFIG_HOME")) |x| std.mem.span(x) else "";
    const dirs = (if (cfg_home.len > 0)
        std.fmt.bufPrintZ(&path_buf, "{s}/user-dirs.dirs", .{cfg_home})
    else
        std.fmt.bufPrintZ(&path_buf, "{s}/.config/user-dirs.dirs", .{home})) catch return home;
    if (cio.fopen(dirs.ptr, "r")) |f| {
        defer _ = cio.fclose(f);
        var line: [512]u8 = undefined;
        while (cio.fgets(&line, line.len, f) != null) {
            const l = std.mem.trimEnd(u8, std.mem.sliceTo(&line, 0), "\r\n");
            if (!std.mem.startsWith(u8, l, "XDG_VIDEOS_DIR=")) continue;
            var v = std.mem.trim(u8, l["XDG_VIDEOS_DIR=".len..], "\"");
            if (std.mem.startsWith(u8, v, "$HOME")) {
                v = v["$HOME".len..];
                return std.fmt.bufPrint(buf, "{s}{s}", .{ home, v }) catch home;
            }
            return std.fmt.bufPrint(buf, "{s}", .{v}) catch home;
        }
    }
    return std.fmt.bufPrint(buf, "{s}/Videos", .{home}) catch home;
}

/// Caminho de um arquivo novo: <pasta>/telinha_<quem>_<data-hora>[_tipo].mp4
pub fn newPath(buf: []u8, who: []const u8, kind: []const u8) ![:0]const u8 {
    return newPathExt(buf, who, kind, ".mp4");
}

pub fn newPathExt(buf: []u8, who: []const u8, kind: []const u8, ext: []const u8) ![:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = folder(&dir_buf);
    if (dir.len == 0) return error.NoFolder;
    var clean: [48]u8 = undefined;
    var n: usize = 0;
    for (who) |ch| {
        if (n == clean.len) break;
        // nome vira algo seguro pra arquivo (letras, números, - _)
        clean[n] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else if (ch >= 0x80) ch else '_';
        n += 1;
    }
    const t = sync.dateTime();
    return std.fmt.bufPrintZ(buf, "{s}{s}telinha_{s}_{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}{s}{s}", .{
        dir, if (sync.is_windows) "\\" else "/", clean[0..n], t.year, t.month, t.day, t.h, t.m, t.s, kind, ext,
    });
}
