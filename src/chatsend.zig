//! Mandar imagem no chat: arquivo solto na janela ou imagem colada (Ctrl+V).
//! A leitura (stb_image) e a codificação (chatimg.zig) rodam numa thread, pra
//! interface não engasgar; o resultado fica esperando (prévia com Enviar e
//! Cancelar na interface) e só vai pra sala quando a pessoa confirma.
const std = @import("std");
const tr = @import("i18n.zig").tr;
const c = @import("c.zig").c;
const sync = @import("sync.zig");
const mp4 = @import("mp4.zig");
const chatimg = @import("chatimg.zig");
const Client = @import("client.zig").Client;
const gpa = std.heap.c_allocator;
const cio = mp4.cio;

/// Maior arquivo de imagem que a gente aceita ler.
const max_file = 40 * 1024 * 1024;

/// Imagens sendo preparadas agora, e o último erro (pra interface avisar).
pub var running: std.atomic.Value(u32) = .init(0);
pub var sent: std.atomic.Value(u32) = .init(0);
pub var failed: std.atomic.Value(u32) = .init(0); // conta falhas (a interface compara)
pub var last_error: std.atomic.Value(u8) = .init(0);

pub const Failure = enum(u8) { none, read, not_image, encode, too_big };

pub fn failureText(f: Failure) []const u8 {
    return switch (f) {
        .none => "",
        .read => tr("não consegui ler o arquivo"),
        .not_image => tr("isso não é uma imagem (PNG, JPEG, GIF ou BMP)"),
        .encode => tr("não consegui preparar a imagem"),
        .too_big => tr("imagem detalhada demais pro chat"),
    };
}

const Source = union(enum) {
    path: [:0]u8, // arquivo (gpa)
    bytes: []u8, // PNG/JPEG já lido (gpa)
    rgba: struct { px: []u8, w: usize, h: usize }, // já decodificado (gpa)
};

const Job = struct {
    cl: *Client,
    src: Source,
};

fn start(cl: *Client, src: Source) void {
    const job = gpa.create(Job) catch return freeSource(src);
    job.* = .{ .cl = cl.retain(), .src = src };
    _ = running.fetchAdd(1, .acq_rel);
    sync.spawn(run, .{job}) catch {
        _ = running.fetchSub(1, .acq_rel);
        cl.release();
        freeSource(src);
        gpa.destroy(job);
    };
}

fn freeSource(src: Source) void {
    switch (src) {
        .path => |p| gpa.free(p),
        .bytes => |b| gpa.free(b),
        .rgba => |r| gpa.free(r.px),
    }
}

/// Arquivo (caminho em UTF-8).
pub fn sendFile(cl: *Client, path: []const u8) void {
    const p = gpa.dupeZ(u8, path) catch return;
    start(cl, .{ .path = p });
}

fn fail(f: Failure) void {
    last_error.store(@intFromEnum(f), .release);
    _ = failed.fetchAdd(1, .acq_rel);
}

fn run(job: *Job) void {
    defer {
        freeSource(job.src);
        job.cl.release();
        gpa.destroy(job);
        _ = running.fetchSub(1, .acq_rel);
    }
    var w: usize = 0;
    var h: usize = 0;
    var stb_px: ?[*]u8 = null;
    defer if (stb_px) |p| c.img_free(p);
    const px: []const u8 = switch (job.src) {
        .rgba => |r| blk: {
            w = r.w;
            h = r.h;
            break :blk r.px;
        },
        .path, .bytes => blk: {
            const data = switch (job.src) {
                .path => |p| readFile(p) orelse return fail(.read),
                .bytes => |b| b,
                else => unreachable,
            };
            defer if (job.src == .path) gpa.free(data);
            var iw: c_int = 0;
            var ih: c_int = 0;
            stb_px = c.img_decode(data.ptr, @intCast(data.len), &iw, &ih) orelse return fail(.not_image);
            w = @intCast(iw);
            h = @intCast(ih);
            break :blk stb_px.?[0 .. w * h * 4];
        },
    };
    var enc = chatimg.encode(px, w, h) catch |e| return fail(if (e == error.TooBig) .too_big else .encode);
    errdefer enc.deinit();
    // prévia pequena (RGBX) pra interface mostrar antes de mandar
    const scale = @min(1.0, @min(@as(f32, preview_side) / @as(f32, @floatFromInt(w)), @as(f32, preview_side) / @as(f32, @floatFromInt(h))));
    const tw: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(w)) * scale)));
    const th: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(h)) * scale)));
    const thumb = gpa.alloc(u8, tw * th * 4) catch {
        enc.deinit();
        return fail(.encode);
    };
    chatimg.resample(px, w, h, thumb, tw, th);
    const r = gpa.create(Ready) catch {
        gpa.free(thumb);
        enc.deinit();
        return fail(.encode);
    };
    r.* = .{ .enc = enc, .thumb = thumb, .tw = tw, .th = th, .w = w, .h = h };
    ready_mutex.lock();
    const old = ready;
    ready = r;
    ready_mutex.unlock();
    if (old) |o| o.destroy(); // duas prontas antes da interface pegar: vale a última
    if (on_ready) |f| f(); // acorda a interface (ela dorme sem evento)
}

/// Chamado (da thread) quando uma imagem fica pronta.
pub var on_ready: ?*const fn () void = null;

/// Lado maior da prévia.
pub const preview_side = 480;

/// Imagem pronta, esperando a pessoa confirmar.
pub const Ready = struct {
    enc: chatimg.Encoded,
    thumb: []u8, // RGBX tw x th
    tw: usize,
    th: usize,
    w: usize, // tamanho original
    h: usize,

    pub fn destroy(r: *Ready) void {
        r.enc.deinit();
        gpa.free(r.thumb);
        gpa.destroy(r);
    }
};

var ready_mutex: sync.Mutex = .{};
var ready: ?*Ready = null;

/// A imagem nova que ficou pronta (a interface fica com ela: mostra a prévia
/// e depois chama send ou drop). null = nada novo.
pub fn take() ?*Ready {
    ready_mutex.lock();
    defer ready_mutex.unlock();
    const r = ready;
    ready = null;
    return r;
}

/// Manda (com a legenda, se tiver) e libera.
pub fn send(cl: *Client, r: *Ready, caption: []const u8) void {
    cl.sendChatImage(caption, r.enc.w, r.enc.h, r.enc.data);
    _ = sent.fetchAdd(1, .acq_rel);
    r.destroy();
}

/// Desiste e libera.
pub fn drop(r: *Ready) void {
    r.destroy();
}

fn readFile(path: [:0]const u8) ?[]u8 {
    const f = mp4.openFile(path, "rb") orelse return null;
    defer _ = cio.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = cio.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        if (list.items.len + n > max_file) {
            list.deinit(gpa);
            return null;
        }
        list.appendSlice(gpa, buf[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

// ---------------------------------------------------------------------------
// Colar (Ctrl+V)

/// Tenta mandar a imagem da área de transferência. false = não tinha imagem
/// (aí o texto colado, se houver, segue normal).
pub fn paste(cl: *Client) bool {
    return if (sync.is_windows) pasteWindows(cl) else pasteLinux(cl);
}

fn pasteWindows(cl: *Client) bool {
    {
        var w: c_int = 0;
        var h: c_int = 0;
        var path: [1024]u16 = undefined;
        if (c.img_clipboard(&w, &h, @ptrCast(&path), path.len)) |p| {
            const n: usize = @intCast(@as(c_int, w) * h * 4);
            const copy = gpa.dupe(u8, p[0..n]) catch {
                std.c.free(p);
                return true;
            };
            std.c.free(p);
            start(cl, .{ .rgba = .{ .px = copy, .w = @intCast(w), .h = @intCast(h) } });
            return true;
        }
        if (path[0] != 0) {
            // arquivo copiado no Explorer
            const len = std.mem.indexOfScalar(u16, &path, 0) orelse return false;
            var u8buf: [2048]u8 = undefined;
            const n = std.unicode.utf16LeToUtf8(&u8buf, path[0..len]) catch return false;
            if (!looksLikeImage(u8buf[0..n])) return false;
            sendFile(cl, u8buf[0..n]);
            return true;
        }
        return false;
    }
}

/// Linux: wl-paste (Wayland) ou xclip (X11); o GLFW só entrega texto.
fn pasteLinux(cl: *Client) bool {
    const wayland = std.c.getenv("WAYLAND_DISPLAY") != null;
    const types = capture(if (wayland) "timeout 2 wl-paste --list-types 2>/dev/null" else "timeout 2 xclip -selection clipboard -t TARGETS -o 2>/dev/null", 64 * 1024) orelse return false;
    defer gpa.free(types);
    const mime: ?[]const u8 = for ([_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/bmp" }) |m| {
        if (hasLine(types, m)) break m;
    } else null;
    if (mime) |m| {
        var cmd: [160]u8 = undefined;
        const cz = (if (wayland)
            std.fmt.bufPrintZ(&cmd, "timeout 3 wl-paste --no-newline -t {s} 2>/dev/null", .{m})
        else
            std.fmt.bufPrintZ(&cmd, "timeout 3 xclip -selection clipboard -t {s} -o 2>/dev/null", .{m})) catch return false;
        const data = capture(cz, max_file) orelse return false;
        if (data.len == 0) {
            gpa.free(data);
            return false;
        }
        start(cl, .{ .bytes = data });
        return true;
    }
    // arquivo copiado no gerenciador de arquivos
    if (hasLine(types, "text/uri-list")) {
        const list = capture(if (wayland) "timeout 2 wl-paste --no-newline -t text/uri-list 2>/dev/null" else "timeout 2 xclip -selection clipboard -t text/uri-list -o 2>/dev/null", 64 * 1024) orelse return false;
        defer gpa.free(list);
        var it = std.mem.tokenizeAny(u8, list, "\r\n");
        while (it.next()) |uri| {
            if (!std.mem.startsWith(u8, uri, "file://")) continue;
            var pb: [2048]u8 = undefined;
            const path = uriPath(uri["file://".len..], &pb) orelse continue;
            if (!looksLikeImage(path)) continue;
            sendFile(cl, path);
            return true;
        }
    }
    return false;
}

fn hasLine(list: []const u8, want: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, "\r\n");
    while (it.next()) |l| {
        if (std.mem.eql(u8, std.mem.trim(u8, l, " "), want)) return true;
    }
    return false;
}

pub fn looksLikeImage(path: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp" };
    for (exts) |e| {
        if (path.len > e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

/// "/home/a/Imagens/foto%20boa.png" (de file://) → caminho de verdade.
fn uriPath(raw: []const u8, out: []u8) ?[]const u8 {
    // file://host/caminho: o host costuma vir vazio
    const start_i = std.mem.indexOfScalar(u8, raw, '/') orelse return null;
    const s = raw[start_i..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (n == out.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        } else out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

/// Roda um comando fixo e devolve a saída (até `max` bytes).
fn capture(cmd: [:0]const u8, max: usize) ?[]u8 {
    const f = popen(cmd.ptr, "r") orelse return null;
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    var ok = true;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        if (list.items.len + n > max) {
            ok = false;
            break;
        }
        list.appendSlice(gpa, buf[0..n]) catch {
            ok = false;
            break;
        };
    }
    _ = pclose(f);
    if (!ok) {
        list.deinit(gpa);
        return null;
    }
    return list.toOwnedSlice(gpa) catch null;
}

const FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(f: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *FILE) usize;
