//! Log de depuração (configurações → Depuração): grava tudo o que dá pra
//! achar problema de desempenho depois — sistema, placa, o que o app
//! escolheu (captura, encoder, decoder, codec, UDP), os tempos de cada etapa
//! que o app já mede, e a cada 2 s o estado da sala, CPU e memória (do app e
//! do PC inteiro). O arquivo fica na pasta de configuração e dá pra mandar
//! pelo gofile.io (sai um link) ou por um webhook (Discord etc.).
//!
//! Tudo vai pela saída de erro do processo, desviada pro arquivo: o que o C,
//! os drivers e as bibliotecas já imprimem entra junto.
const std = @import("std");
const c = @cImport(@cInclude("debugsys.h"));
const sync = @import("sync.zig");
const config = @import("config.zig");
const mp4 = @import("mp4.zig");
const proto = @import("proto.zig");
const crash = @import("crash.zig");
const gpa = std.heap.c_allocator;
const cio = mp4.cio;

pub const file_name = "telinha-debug.log";
const send_name = "telinha-debug-envio.txt";
/// Arquivo maior que isso, ao ligar, fica só com o fim (o mais recente).
const max_file = 24 * 1024 * 1024;
const keep_on_trim = 6 * 1024 * 1024;
/// Webhook do Discord aceita ~10 MB: manda o fim do log.
const max_webhook = 9 * 1024 * 1024;
const max_gofile = 60 * 1024 * 1024;

var active: std.atomic.Value(bool) = .init(false);
var start_ms: u64 = 0;

pub fn on() bool {
    return active.load(.acquire);
}

/// Caminho do arquivo (UTF-8).
pub fn path(buf: []u8) ?[:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const dir = config.dirPath(&dir_buf) orelse return null;
    const sep = if (sync.is_windows) "\\" else "/";
    return std.fmt.bufPrintZ(buf, "{s}" ++ sep ++ "{s}", .{ dir, file_name }) catch null;
}

/// Liga: desvia a saída de erro pro arquivo e escreve o cabeçalho.
pub fn start() void {
    if (on()) return;
    var pb: [600]u8 = undefined;
    const p = path(&pb) orelse return;
    trimFile(p);
    if (c.dbg_redirect_stderr(p.ptr) != 0) return;
    c.dbg_set_env(1);
    sync.debug_flag.store(true, .release);
    start_ms = sync.nowMs();
    active.store(true, .release);
    header();
}

/// Desliga (a saída de erro volta pra onde estava).
pub fn stop() void {
    if (!on()) return;
    line("log de depuração desligado", .{});
    active.store(false, .release);
    sync.debug_flag.store(false, .release);
    c.dbg_set_env(0);
    _ = c.dbg_restore_stderr();
}

/// Uma linha no log (com a hora desde que ligou).
pub fn line(comptime fmt: []const u8, args: anytype) void {
    if (!on()) return;
    const t = sync.nowMs() - start_ms;
    std.debug.print("[{d}.{d:0>3}] " ++ fmt ++ "\n", .{ t / 1000, t % 1000 } ++ args);
}

/// Arquivo grande demais: fica só o fim.
fn trimFile(p: [:0]const u8) void {
    const f = mp4.openFile(p, "rb") orelse return;
    _ = cio.fseek(f, 0, cio.SEEK_END);
    const size: usize = @intCast(@max(0, cio.ftell(f)));
    if (size <= max_file) {
        _ = cio.fclose(f);
        return;
    }
    const keep = gpa.alloc(u8, keep_on_trim) catch {
        _ = cio.fclose(f);
        return;
    };
    defer gpa.free(keep);
    _ = cio.fseek(f, @intCast(size - keep_on_trim), cio.SEEK_SET);
    const n = cio.fread(keep.ptr, 1, keep.len, f);
    _ = cio.fclose(f);
    const w = mp4.openFile(p, "wb") orelse return;
    defer _ = cio.fclose(w);
    const msg = "[... começo do log cortado (arquivo grande demais) ...]\n";
    _ = cio.fwrite(msg.ptr, 1, msg.len, w);
    _ = cio.fwrite(keep.ptr, 1, n, w);
}

/// Tamanho atual do arquivo (bytes).
pub fn fileSize() usize {
    var pb: [600]u8 = undefined;
    const p = path(&pb) orelse return 0;
    const f = mp4.openFile(p, "rb") orelse return 0;
    defer _ = cio.fclose(f);
    _ = cio.fseek(f, 0, cio.SEEK_END);
    return @intCast(@max(0, cio.ftell(f)));
}

/// Apaga o arquivo (continua gravando, se estiver ligado).
pub fn clear() void {
    var pb: [600]u8 = undefined;
    const p = path(&pb) orelse return;
    const was = on();
    if (was) stop();
    if (mp4.openFile(p, "wb")) |f| _ = cio.fclose(f);
    if (was) start();
}

// ---------------------------------------------------------------------------
// Cabeçalho: o sistema

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn header() void {
    const dt = sync.dateTime();
    line("==================== telinha {s} (protocolo {d}) — log de depuração ligado em {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ====================", .{ proto.app_version, proto.version, dt.year, dt.month, dt.day, dt.h, dt.m, dt.s });
    line("build: {s} {s}, {d} threads no pool, {d} núcleos", .{ @tagName(@import("builtin").os.tag), @tagName(@import("builtin").cpu.arch), sync.pool.threads, sync.cpuCount() });
    if (sync.is_windows) {
        var buf: [2048]u8 = undefined;
        const n = c.dbg_sysinfo(&buf, buf.len);
        var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(@max(0, n))], '\n');
        while (it.next()) |l| line("{s}", .{l});
    } else {
        var b1: [4096]u8 = undefined;
        if (firstLine("/etc/os-release", "PRETTY_NAME=", &b1)) |v| line("sistema: {s}", .{std.mem.trim(u8, v, "\"")});
        var b2: [4096]u8 = undefined;
        if (firstLine("/proc/version", "", &b2)) |v| line("kernel: {s}", .{v});
        var b3: [16384]u8 = undefined;
        if (firstLine("/proc/cpuinfo", "model name", &b3)) |v| line("processador: {s}", .{std.mem.trim(u8, v, " \t:")});
        var b4: [4096]u8 = undefined;
        if (firstLine("/proc/meminfo", "MemTotal:", &b4)) |v| line("memória: {s}", .{std.mem.trim(u8, v, " ")});
        var b5: [4096]u8 = undefined;
        if (firstLine("/proc/driver/nvidia/version", "", &b5)) |v| line("driver NVIDIA: {s}", .{v});
        inline for (.{ "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE" }) |k| {
            if (getenv(k)) |v| line("{s}={s}", .{ k, if (std.mem.eql(u8, k, "HYPRLAND_INSTANCE_SIGNATURE")) "sim" else std.mem.span(v) });
        }
    }
}

/// Primeira linha do arquivo que começa com `prefix` (sem o prefixo).
fn firstLine(file: [:0]const u8, prefix: []const u8, buf: []u8) ?[]const u8 {
    const f = cio.fopen(file.ptr, "rb") orelse return null;
    defer _ = cio.fclose(f);
    const n = cio.fread(buf.ptr, 1, buf.len, f);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, prefix)) return l[prefix.len..];
    }
    return null;
}

// ---------------------------------------------------------------------------
// CPU e memória (do app e do PC), a cada amostra

pub const Usage = struct {
    proc_pct: f32 = 0, // % de um núcleo (100 = um núcleo inteiro)
    sys_pct: f32 = 0, // % do PC inteiro (todos os núcleos)
    rss_mb: u64 = 0,
    ram_free_mb: u64 = 0,
    top: [6]Thread = undefined, // threads que mais gastaram (Linux)
    n_top: usize = 0,

    pub const Thread = struct { name: [16]u8, len: usize, pct: f32 };
};

var last_ms: u64 = 0;
var last_proc_ms: u64 = 0;
var last_sys_total: u64 = 0;
var last_sys_idle: u64 = 0;
var last_threads: [256]struct { tid: u32, ticks: u64 } = undefined;
var n_last_threads: usize = 0;

pub fn usage() Usage {
    var u: Usage = .{};
    const now = sync.nowMs();
    const dt_ms = @max(1, now -| last_ms);
    var proc_ms: u64 = 0;
    var sys_total: u64 = 0;
    var sys_idle: u64 = 0;
    if (sync.is_windows) {
        var st: c.dbg_stats = undefined;
        _ = c.dbg_proc_stats(&st);
        proc_ms = st.proc_cpu_ms;
        sys_total = st.sys_total_ms;
        sys_idle = st.sys_idle_ms;
        u.rss_mb = st.rss_kb / 1024;
        u.ram_free_mb = st.ram_free_kb / 1024;
    } else {
        const tick_ms: u64 = 10; // USER_HZ = 100
        var b: [1024]u8 = undefined;
        if (readFile("/proc/self/stat", &b)) |t| proc_ms = statTicks(t) * tick_ms;
        var bs: [512]u8 = undefined;
        if (readFile("/proc/stat", &bs)) |t| {
            var it = std.mem.tokenizeAny(u8, t, " \n");
            _ = it.next(); // "cpu"
            var i: usize = 0;
            while (it.next()) |v| : (i += 1) {
                if (i >= 8) break;
                const x = std.fmt.parseInt(u64, v, 10) catch break;
                sys_total += x * tick_ms;
                if (i == 3 or i == 4) sys_idle += x * tick_ms; // idle + iowait
            }
        }
        var bm: [4096]u8 = undefined;
        if (readFile("/proc/self/status", &bm)) |t| u.rss_mb = field(t, "VmRSS:") / 1024;
        var bi: [4096]u8 = undefined;
        if (readFile("/proc/meminfo", &bi)) |t| u.ram_free_mb = field(t, "MemAvailable:") / 1024;
        threadTop(&u, dt_ms);
    }
    if (last_ms != 0) {
        u.proc_pct = @as(f32, @floatFromInt(proc_ms -| last_proc_ms)) * 100 / @as(f32, @floatFromInt(dt_ms));
        const dt_sys = sys_total -| last_sys_total;
        if (dt_sys > 0) u.sys_pct = 100 * (1 - @as(f32, @floatFromInt(sys_idle -| last_sys_idle)) / @as(f32, @floatFromInt(dt_sys)));
    }
    last_ms = now;
    last_proc_ms = proc_ms;
    last_sys_total = sys_total;
    last_sys_idle = sys_idle;
    return u;
}

/// Linux: CPU de cada thread desde a última amostra (as que mais gastaram).
fn threadTop(u: *Usage, dt_ms: u64) void {
    const dir = std.c.opendir("/proc/self/task") orelse return;
    defer _ = std.c.closedir(dir);
    var now_list: [256]struct { tid: u32, ticks: u64, name: [16]u8, len: usize } = undefined;
    var n: usize = 0;
    while (std.c.readdir(dir)) |ent| {
        const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        const tid = std.fmt.parseInt(u32, nm, 10) catch continue;
        if (n == now_list.len) break;
        var pb: [64]u8 = undefined;
        const sp = std.fmt.bufPrintZ(&pb, "/proc/self/task/{d}/stat", .{tid}) catch continue;
        var b: [1024]u8 = undefined;
        const t = readFile(sp, &b) orelse continue;
        var e = &now_list[n];
        e.tid = tid;
        e.ticks = statTicks(t);
        // nome: entre os parênteses
        const a = std.mem.indexOfScalar(u8, t, '(') orelse continue;
        const z = std.mem.lastIndexOfScalar(u8, t, ')') orelse continue;
        e.len = @min(z - a - 1, 15);
        @memcpy(e.name[0..e.len], t[a + 1 ..][0..e.len]);
        n += 1;
        _ = &e;
    }
    // diferença com a amostra anterior, ordenada
    var deltas: [256]struct { i: usize, d: u64 } = undefined;
    var nd: usize = 0;
    for (now_list[0..n], 0..) |e, i| {
        var prev: u64 = 0;
        for (last_threads[0..n_last_threads]) |l| if (l.tid == e.tid) {
            prev = l.ticks;
        };
        const d = e.ticks -| prev;
        if (d > 0 and n_last_threads > 0) {
            deltas[nd] = .{ .i = i, .d = d };
            nd += 1;
        }
    }
    std.mem.sort(@TypeOf(deltas[0]), deltas[0..nd], {}, struct {
        fn lt(_: void, x: @TypeOf(deltas[0]), y: @TypeOf(deltas[0])) bool {
            return x.d > y.d;
        }
    }.lt);
    for (deltas[0..@min(nd, u.top.len)]) |d| {
        const e = now_list[d.i];
        u.top[u.n_top] = .{ .name = e.name, .len = e.len, .pct = @as(f32, @floatFromInt(d.d * 10)) * 100 / @as(f32, @floatFromInt(dt_ms)) };
        u.n_top += 1;
    }
    n_last_threads = n;
    for (now_list[0..n], 0..) |e, i| last_threads[i] = .{ .tid = e.tid, .ticks = e.ticks };
}

/// utime + stime (campos 14 e 15) de um /proc/.../stat.
fn statTicks(t: []const u8) u64 {
    const z = std.mem.lastIndexOfScalar(u8, t, ')') orelse return 0;
    var it = std.mem.tokenizeScalar(u8, t[z + 1 ..], ' ');
    var i: usize = 0;
    var sum: u64 = 0;
    while (it.next()) |v| : (i += 1) {
        if (i == 11 or i == 12) sum += std.fmt.parseInt(u64, v, 10) catch 0;
        if (i == 12) break;
    }
    return sum;
}

fn field(t: []const u8, name: []const u8) u64 {
    const i = std.mem.indexOf(u8, t, name) orelse return 0;
    var it = std.mem.tokenizeAny(u8, t[i + name.len ..], " \t");
    return std.fmt.parseInt(u64, it.next() orelse return 0, 10) catch 0;
}

fn readFile(p: [:0]const u8, buf: []u8) ?[]const u8 {
    const f = cio.fopen(p.ptr, "rb") orelse return null;
    defer _ = cio.fclose(f);
    const n = cio.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Mandar o log

pub const Method = enum(u8) { gofile, webhook };
pub const SendState = enum(u8) { idle, sending, done, failed };

var send_state: std.atomic.Value(SendState) = .init(.idle);
var send_mutex: sync.Mutex = .{};
var send_result: [512]u8 = undefined; // link (gofile) ou mensagem de erro
var send_result_len: usize = 0;

pub fn sendState() SendState {
    return send_state.load(.acquire);
}

/// Link do gofile, ou o motivo de ter falhado.
pub fn sendResult(buf: []u8) []const u8 {
    send_mutex.lock();
    defer send_mutex.unlock();
    const n = @min(buf.len, send_result_len);
    @memcpy(buf[0..n], send_result[0..n]);
    return buf[0..n];
}

fn setResult(st: SendState, msg: []const u8) void {
    send_mutex.lock();
    send_result_len = @min(msg.len, send_result.len);
    @memcpy(send_result[0..send_result_len], msg[0..send_result_len]);
    send_mutex.unlock();
    send_state.store(st, .release);
}

/// O que mandar: o log de depuração ou o relatório de travamento (com o fim do log junto).
pub const What = enum(u8) { log, crash };

const Job = struct { method: Method, what: What, url: [512]u8, url_len: usize, who: [64]u8, who_len: usize };

/// Manda o log (numa thread). `webhook`: a URL (só pro método webhook).
/// `who`: o nome de quem manda (vai na mensagem do webhook).
pub fn send(method: Method, webhook: []const u8, who: []const u8) error{ BadUrl, Busy, OutOfMemory }!void {
    return sendWhat(method, .log, webhook, who);
}

pub fn sendWhat(method: Method, what: What, webhook: []const u8, who: []const u8) error{ BadUrl, Busy, OutOfMemory }!void {
    if (sendState() == .sending) return error.Busy;
    if (method == .webhook and !validUrl(webhook)) return error.BadUrl;
    const j = try gpa.create(Job);
    j.* = .{ .method = method, .what = what, .url = undefined, .url_len = @min(webhook.len, 512), .who = undefined, .who_len = @min(who.len, 64) };
    @memcpy(j.url[0..j.url_len], webhook[0..j.url_len]);
    @memcpy(j.who[0..j.who_len], who[0..j.who_len]);
    send_state.store(.sending, .release);
    sync.spawn(sendJob, .{j}) catch {
        gpa.destroy(j);
        setResult(.failed, "não consegui criar a thread de envio");
    };
}

/// Webhook: http(s)://, sem espaço nem aspas (vai como argumento do curl).
pub fn validUrl(u: []const u8) bool {
    if (!(std.mem.startsWith(u8, u, "https://") or std.mem.startsWith(u8, u, "http://"))) return false;
    if (u.len < 12 or u.len > 500) return false;
    for (u) |ch| if (ch <= ' ' or ch == '"' or ch == '\'' or ch == '\\' or ch >= 0x7f) return false;
    return true;
}

fn sendJob(j: *Job) void {
    defer gpa.destroy(j);
    line("enviando o log ({s})", .{@tagName(j.method)});
    // cópia do fim do log (o arquivo continua sendo escrito)
    var pb: [600]u8 = undefined;
    const p = path(&pb) orelse return setResult(.failed, "sem pasta de configuração");
    var sb: [600]u8 = undefined;
    const dir_end = std.mem.lastIndexOfAny(u8, p, "/\\") orelse return setResult(.failed, "caminho estranho");
    const sp = std.fmt.bufPrintZ(&sb, "{s}{s}", .{ p[0 .. dir_end + 1], send_name }) catch return setResult(.failed, "caminho longo demais");
    const max: usize = if (j.method == .webhook) max_webhook else max_gofile;
    if (j.what == .crash) {
        // relatório: o que deu errado + o fim do log (se tiver)
        var cb2: [600]u8 = undefined;
        const cp = crash.path(&cb2) orelse return setResult(.failed, "sem pasta de configuração");
        const w = mp4.openFile(sp, "wb") orelse return setResult(.failed, "não consegui ler o relatório");
        defer _ = cio.fclose(w);
        appendTail(w, cp, 1024 * 1024) catch return setResult(.failed, "não consegui ler o relatório");
        const sep = "\n\n--- fim do log de depuração (se estava ligado) ---\n";
        _ = cio.fwrite(sep.ptr, 1, sep.len, w);
        appendTail(w, p, max - 1024 * 1024) catch {};
    } else snapshot(p, sp, max) catch return setResult(.failed, "não consegui ler o log (está vazio?)");
    var out: [8192]u8 = undefined;
    const url_z = blk: {
        var ub: [600]u8 = undefined;
        if (j.method == .gofile) {
            const over = getenv("TELINHA_GOFILE_URL");
            break :blk std.fmt.bufPrintZ(&ub, "{s}", .{if (over) |o| std.mem.span(o) else "https://upload.gofile.io/uploadfile"}) catch unreachable;
        }
        break :blk std.fmt.bufPrintZ(&ub, "{s}", .{j.url[0..j.url_len]}) catch unreachable;
    };
    var cb: [256]u8 = undefined;
    const content = std.fmt.bufPrintZ(&cb, "{s} do telinha {s} ({s})", .{ if (j.what == .crash) "Relatório de travamento" else "Log de depuração", proto.app_version, j.who[0..j.who_len] }) catch "";
    const code = c.dbg_http_post_file(url_z.ptr, sp.ptr, "file", if (j.what == .crash) "telinha-travou.txt" else "telinha-debug.txt", if (j.method == .webhook) content.ptr else "", &out, out.len);
    const body = std.mem.sliceTo(&out, 0);
    if (code < 200 or code >= 300) {
        var eb: [200]u8 = undefined;
        const msg = if (code < 0)
            (if (sync.is_windows) "sem conexão com o servidor" else "sem conexão (ou o curl não está instalado)")
        else
            std.fmt.bufPrint(&eb, "o servidor respondeu {d}", .{code}) catch "erro";
        line("envio do log falhou: {s} {s}", .{ msg, body[0..@min(body.len, 200)] });
        return setResult(.failed, msg);
    }
    if (j.method == .webhook) {
        line("{s} enviado pro webhook", .{if (j.what == .crash) "relatório de travamento" else "log"});
        if (j.what == .crash) crash.dismiss();
        return setResult(.done, "");
    }
    // gofile: {"status":"ok","data":{"downloadPage":"https://gofile.io/d/xxxx",...}}
    const link = gofileLink(body) orelse {
        line("gofile respondeu sem link: {s}", .{body[0..@min(body.len, 300)]});
        return setResult(.failed, "o gofile não devolveu o link");
    };
    line("{s} enviado: {s}", .{ if (j.what == .crash) "relatório de travamento" else "log", link });
    if (j.what == .crash) crash.dismiss();
    setResult(.done, link);
}

pub fn gofileLink(body: []const u8) ?[]const u8 {
    const key = "\"downloadPage\"";
    const i = std.mem.indexOf(u8, body, key) orelse return null;
    const rest = body[i + key.len ..];
    const a = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const z = std.mem.indexOfScalarPos(u8, rest, a + 1, '"') orelse return null;
    const link = rest[a + 1 .. z];
    if (!std.mem.startsWith(u8, link, "https://")) return null;
    return link;
}

/// Copia o fim do log (até `max` bytes) pra outro arquivo.
fn snapshot(src: [:0]const u8, dst: [:0]const u8, max: usize) !void {
    const w = mp4.openFile(dst, "wb") orelse return error.Open;
    defer _ = cio.fclose(w);
    try appendTail(w, src, max);
}

/// Copia o fim de `src` (até `max` bytes) no fim de `w`.
fn appendTail(w: *cio.FILE, src: [:0]const u8, max: usize) !void {
    const f = mp4.openFile(src, "rb") orelse return error.Open;
    defer _ = cio.fclose(f);
    _ = cio.fseek(f, 0, cio.SEEK_END);
    const size: usize = @intCast(@max(0, cio.ftell(f)));
    if (size == 0) return error.Empty;
    const n = @min(size, max);
    _ = cio.fseek(f, @intCast(size - n), cio.SEEK_SET);
    if (n < size) {
        const msg = "[... começo do log cortado pro envio ...]\n";
        _ = cio.fwrite(msg.ptr, 1, msg.len, w);
    }
    var buf: [64 * 1024]u8 = undefined;
    var left = n;
    while (left > 0) {
        const got = cio.fread(&buf, 1, @min(buf.len, left), f);
        if (got == 0) break;
        _ = cio.fwrite(&buf, 1, got, w);
        left -= got;
    }
}

test "link do gofile e URL de webhook" {
    try std.testing.expectEqualStrings("https://gofile.io/d/AbC123", gofileLink("{\"status\":\"ok\",\"data\":{\"downloadPage\":\"https://gofile.io/d/AbC123\",\"code\":\"AbC123\"}}").?);
    try std.testing.expect(gofileLink("{\"status\":\"error-rateLimit\"}") == null);
    try std.testing.expect(validUrl("https://discord.com/api/webhooks/123/abc-DEF_x"));
    try std.testing.expect(!validUrl("https://x.com/a b"));
    try std.testing.expect(!validUrl("ftp://x.com/a"));
    try std.testing.expect(!validUrl("https://x.com/a\";rm -rf"));
}
