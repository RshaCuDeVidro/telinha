//! Versão nova do telinha. Dois jeitos de saber, nenhum obrigatório:
//!
//! - na sala: cada pessoa conta a versão do app dela (hello/members); se alguém
//!   estiver numa mais nova, a interface avisa. Não usa internet nenhuma.
//! - no GitHub: se o build souber o repositório (-Drepo=dono/nome, o CI passa)
//!   e a opção estiver ligada, pergunta uma vez ao abrir qual é a última
//!   release. TELINHA_ATUALIZACAO_URL troca o endereço (testes).
const std = @import("std");
const sync = @import("sync.zig");
const gpa = std.heap.c_allocator;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const State = enum(u8) { idle, checking, newer, current, failed };

var state: std.atomic.Value(State) = .init(.idle);
var latest_buf: [32]u8 = undefined;
var latest_len: usize = 0;
var page_buf: [256]u8 = undefined; // página da release (html_url)
var page_len: usize = 0;
var mutex: sync.Mutex = .{};

pub fn getState() State {
    return state.load(.acquire);
}

/// Versão da última release (vale quando getState() == .newer).
pub fn latest(buf: []u8) []const u8 {
    mutex.lock();
    defer mutex.unlock();
    const n = @min(buf.len, latest_len);
    @memcpy(buf[0..n], latest_buf[0..n]);
    return buf[0..n];
}

/// Página da release nova no GitHub ("" se não veio).
pub fn page(buf: []u8) []const u8 {
    mutex.lock();
    defer mutex.unlock();
    const n = @min(buf.len, page_len);
    @memcpy(buf[0..n], page_buf[0..n]);
    return buf[0..n];
}

/// "3.1.0" > "3.0.2"? Aceita "v" na frente e ignora sufixos ("-rc1").
pub fn isNewer(candidate: []const u8, current: []const u8) bool {
    const a = parse(candidate) orelse return false;
    const b = parse(current) orelse return false;
    for (0..3) |i| {
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
}

fn parse(v: []const u8) ?[3]u32 {
    var s = std.mem.trim(u8, v, " \t\r\n");
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    var out: [3]u32 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 3) break;
        var end: usize = 0;
        while (end < part.len and std.ascii.isDigit(part[end])) end += 1;
        if (end == 0) return if (i == 0) null else out;
        out[i] = std.fmt.parseInt(u32, part[0..end], 10) catch return null;
        if (end < part.len) break; // "0-rc1": o resto é sufixo
    }
    return if (i == 0) null else out;
}

/// Pergunta ao GitHub (numa thread) se tem versão mais nova que `current`.
pub fn checkAsync(repo: []const u8, current: []const u8) void {
    const override = getenv("TELINHA_ATUALIZACAO_URL");
    if (override == null and repo.len == 0) return;
    // modo de testes: só fala com a internet se o teste pedir (endereço próprio)
    if (override == null and getenv("TELINHA_QA") != null) return;
    if (state.cmpxchgStrong(.idle, .checking, .acq_rel, .acquire) != null) return;
    var url_buf: [256]u8 = undefined;
    const url = if (override) |o| std.mem.span(o) else std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/releases/latest", .{repo}) catch {
        state.store(.failed, .release);
        return;
    };
    const job = gpa.create(Job) catch {
        state.store(.failed, .release);
        return;
    };
    job.* = .{};
    const n = @min(url.len, job.url.len);
    @memcpy(job.url[0..n], url[0..n]);
    job.url_len = n;
    const m = @min(current.len, job.current.len);
    @memcpy(job.current[0..m], current[0..m]);
    job.current_len = m;
    sync.spawn(run, .{job}) catch {
        gpa.destroy(job);
        state.store(.failed, .release);
    };
}

const Job = struct {
    url: [256]u8 = undefined,
    url_len: usize = 0,
    current: [32]u8 = undefined,
    current_len: usize = 0,
};

fn run(job: *Job) void {
    defer gpa.destroy(job);
    const rel = fetchRelease(job.url[0..job.url_len]) catch |e| {
        if (getenv("TELINHA_DEBUG") != null) std.debug.print("[telinha] checagem de versão falhou: {s}\n", .{@errorName(e)});
        state.store(.failed, .release);
        return;
    };
    defer rel.deinit();
    const tag = rel.value.tag_name;
    mutex.lock();
    const n = @min(tag.len, latest_buf.len);
    @memcpy(latest_buf[0..n], tag[0..n]);
    latest_len = n;
    // só abre página do próprio GitHub (o endereço veio da rede)
    const url = rel.value.html_url;
    if (std.mem.startsWith(u8, url, "https://github.com/") and url.len <= page_buf.len and std.mem.indexOfAny(u8, url, " \"'`$\\") == null) {
        @memcpy(page_buf[0..url.len], url);
        page_len = url.len;
    }
    mutex.unlock();
    state.store(if (isNewer(tag, job.current[0..job.current_len])) .newer else .current, .release);
}

const Release = struct { tag_name: []const u8, html_url: []const u8 = "" };

/// GET na API de releases. Sem cliente HTTP/TLS próprio (leve): no Windows o
/// WinHTTP do sistema, no Linux o curl (quase todo sistema tem).
fn fetchRelease(url: []const u8) !std.json.Parsed(Release) {
    // o endereço vira argumento de comando: só caracteres de URL comuns
    for (url) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, ":/._-?=&%~+", ch) != null)) return error.BadUrl;
    }
    const body = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(body);
    var n: usize = 0;
    if (sync.is_windows) {
        var z: [300]u8 = undefined;
        const uz = std.fmt.bufPrintZ(&z, "{s}", .{url}) catch return error.BadUrl;
        const r = http_get(uz.ptr, body.ptr, @intCast(body.len));
        if (r < 0) return error.HttpFailed;
        n = @intCast(r);
    } else {
        var cmd: [400]u8 = undefined;
        const cz = std.fmt.bufPrintZ(&cmd, "curl -fsSL --max-time 15 -A telinha -H 'Accept: application/vnd.github+json' '{s}' 2>/dev/null", .{url}) catch return error.BadUrl;
        const f = popen(cz.ptr, "r") orelse return error.NoCurl;
        while (n < body.len) {
            const got = fread(body.ptr + n, 1, body.len - n, f);
            if (got == 0) break;
            n += got;
        }
        if (pclose(f) != 0) return error.HttpFailed;
    }
    return parseRelease(body[0..n]);
}

extern "c" fn http_get(url: [*:0]const u8, out: [*]u8, cap: c_int) c_int;
const FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(f: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *FILE) usize;

fn parseRelease(json: []const u8) !std.json.Parsed(Release) {
    const parsed = try std.json.parseFromSlice(Release, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.tag_name.len == 0 or parsed.value.tag_name.len > 31) return error.BadTag;
    return parsed;
}

test "comparação de versões" {
    try std.testing.expect(isNewer("v3.1.0", "3.0.0"));
    try std.testing.expect(isNewer("3.0.1", "3.0.0"));
    try std.testing.expect(isNewer("4", "3.9.9"));
    try std.testing.expect(!isNewer("v3.0.0", "3.0.0"));
    try std.testing.expect(!isNewer("2.9.0", "3.0.0"));
    try std.testing.expect(!isNewer("3.0.0-rc1", "3.0.0"));
    try std.testing.expect(isNewer("3.1.0-rc1", "3.0.0"));
    try std.testing.expect(!isNewer("lixo", "3.0.0"));
}

test "tag do JSON do GitHub" {
    const r = try parseRelease("{\"url\":\"x\",\"tag_name\":\"v3.2.0\",\"html_url\":\"https://github.com/a/b/releases/tag/v3.2.0\",\"assets\":[{\"a\":1}],\"draft\":false}");
    defer r.deinit();
    try std.testing.expectEqualStrings("v3.2.0", r.value.tag_name);
    try std.testing.expectEqualStrings("https://github.com/a/b/releases/tag/v3.2.0", r.value.html_url);
    try std.testing.expectError(error.BadTag, parseRelease("{\"tag_name\":\"\"}"));
}
