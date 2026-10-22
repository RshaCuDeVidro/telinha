//! Versão nova do telinha: avisar e atualizar.
//!
//! - na sala: cada pessoa conta a versão do app dela (hello/members); se alguém
//!   estiver numa mais nova, a interface avisa. Não usa internet nenhuma.
//! - no GitHub: se o build souber o repositório (-Drepo=dono/nome, o CI passa)
//!   e a opção estiver ligada, pergunta qual é a última release ao abrir (e a
//!   cada 6 h com o app aberto). TELINHA_ATUALIZACAO_URL troca o endereço (testes).
//!
//! Atualizar sozinho: a release traz o SHA256SUMS assinado (SHA256SUMS.sig,
//! Ed25519, a chave privada só existe no segredo do CI). O app confere a
//! assinatura com a chave pública daqui de baixo, baixa o executável da
//! plataforma, confere o sha256 e só então troca o próprio executável
//! (selfupdate.c). Sem a assinatura certa, não instala nada: só mostra o botão
//! pra abrir a página. O "o que muda" vem do CHANGELOG anexado à release (no
//! idioma da interface), conferido pelo mesmo SHA256SUMS.
const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const changelog = @import("changelog.zig");
const gpa = std.heap.c_allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Chave pública que assina as releases (a privada fica no segredo
/// TELINHA_ASSINATURA do GitHub Actions).
const release_key = hexKey("2f65fdee4b5b476f69b2a749fcafd357a1904db49b1a0117de54dca4dbdac633");

/// O executável desta plataforma nos arquivos da release ("" = não tem).
pub const asset_name: []const u8 = if (builtin.cpu.arch != .x86_64)
    ""
else if (builtin.os.tag == .windows)
    "telinha-windows-x86_64.exe"
else
    "telinha-linux-x86_64";

pub const State = enum(u8) {
    idle,
    checking,
    newer, // tem versão nova (notes() e canInstall() valem)
    current,
    failed,
    downloading,
    installed, // trocou o executável: vale quando abrir de novo
    install_failed, // installError() diz por quê
};

var state: std.atomic.Value(State) = .init(.idle);
var mutex: sync.Mutex = .{};
var latest_buf: [32]u8 = undefined;
var latest_len: usize = 0;
var page_buf: [256]u8 = undefined; // página da release (html_url)
var page_len: usize = 0;
var last_check_ms: u64 = 0;
// preenchidos antes de o estado virar .newer e só trocados numa checagem nova
// (que só começa de .idle/.current/.failed): a interface lê sem trava
var notes_text: []u8 = &.{};
var install_ok = false;
var why_buf: [160]u8 = undefined;
var why_len: usize = 0;
var bin_url: [600]u8 = undefined;
var bin_url_len: usize = 0;
var bin_size: u64 = 0;
var bin_sha: [32]u8 = undefined;
var self_buf: [1024]u8 = undefined;
var self_len: usize = 0;
var err_buf: [200]u8 = undefined;
var err_len: usize = 0;

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

fn hasRelease() bool {
    return switch (getState()) {
        .newer, .downloading, .installed, .install_failed => true,
        else => false,
    };
}

/// O que muda da versão atual até a nova (seções do CHANGELOG, markdown).
pub fn notes() []const u8 {
    return if (hasRelease()) notes_text else "";
}

/// Dá pra instalar sozinho? (senão whyNot() diz por quê e fica o botão da página)
pub fn canInstall() bool {
    return hasRelease() and install_ok;
}

pub fn whyNot() []const u8 {
    return if (hasRelease()) why_buf[0..why_len] else "";
}

pub fn installError() []const u8 {
    return if (getState() == .install_failed) err_buf[0..err_len] else "";
}

/// Quanto já baixou (0 a 1).
pub fn progress() f32 {
    if (getState() != .downloading or bin_size == 0) return 0;
    var pb: [1100]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pb, "{s}.novo", .{self_buf[0..self_len]}) catch return 0;
    const got = upd_file_size(p.ptr);
    if (got <= 0) return 0;
    return @min(1.0, @as(f32, @floatFromInt(got)) / @as(f32, @floatFromInt(bin_size)));
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
/// `english`: o "o que muda" vem no CHANGELOG em inglês.
pub fn checkAsync(repo: []const u8, current: []const u8, english: bool) void {
    const override = getenv("TELINHA_ATUALIZACAO_URL");
    if (override == null and repo.len == 0) return;
    // modo de testes: só fala com a internet se o teste pedir (endereço próprio)
    if (override == null and getenv("TELINHA_QA") != null) return;
    // de novo depois de uma checagem que terminou (a cada 6 h com o app aberto)
    const s = getState();
    if (s == .current or s == .failed) state.store(.idle, .release);
    if (state.cmpxchgStrong(.idle, .checking, .acq_rel, .acquire) != null) return;
    last_check_ms = sync.nowMs();
    var url_buf: [256]u8 = undefined;
    const url = if (override) |o| std.mem.span(o) else std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/releases/latest", .{repo}) catch {
        state.store(.failed, .release);
        return;
    };
    const job = gpa.create(Job) catch {
        state.store(.failed, .release);
        return;
    };
    job.* = .{ .english = english };
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

/// Com o app aberto: checa de novo depois de 6 h (barato: só olha o relógio).
pub fn recheckIfStale(repo: []const u8, current: []const u8, english: bool) void {
    const s = getState();
    if (s != .current and s != .failed) return;
    if (sync.nowMs() - last_check_ms < 6 * 3600 * 1000) return;
    checkAsync(repo, current, english);
}

const Job = struct {
    url: [256]u8 = undefined,
    url_len: usize = 0,
    current: [32]u8 = undefined,
    current_len: usize = 0,
    english: bool,
};

fn debugOn() bool {
    return getenv("TELINHA_DEBUG") != null;
}

fn run(job: *Job) void {
    defer gpa.destroy(job);
    const body = fetch(job.url[0..job.url_len], true, 512 * 1024) catch |e| {
        if (debugOn()) std.debug.print("[telinha] checagem de versão falhou: {s}\n", .{@errorName(e)});
        state.store(.failed, .release);
        return;
    };
    defer gpa.free(body);
    const rel = parseRelease(body) catch |e| {
        if (debugOn()) std.debug.print("[telinha] resposta estranha da checagem de versão: {s}\n", .{@errorName(e)});
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
    const current = job.current[0..job.current_len];
    if (!isNewer(tag, current)) {
        state.store(.current, .release);
        return;
    }
    prepare(rel.value, current, job.english);
    if (debugOn()) std.debug.print("[telinha] versão nova {s}: instala sozinho = {}, {s}\n", .{ tag, install_ok, why_buf[0..why_len] });
    state.store(.newer, .release);
}

fn setWhy(comptime f: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&why_buf, f, args) catch why_buf[0..0];
    why_len = s.len;
}

/// Confere a assinatura, monta o "o que muda" e vê se dá pra trocar o executável.
fn prepare(rel: Release, current: []const u8, english: bool) void {
    if (notes_text.len > 0) gpa.free(notes_text);
    notes_text = &.{};
    install_ok = false;
    why_len = 0;
    // as notas da release (inglês, com a tabela de downloads) até o CHANGELOG chegar
    notes_text = gpa.dupe(u8, releaseNotes(rel.body)) catch &.{};

    const sums_url = assetUrl(rel, "SHA256SUMS") orelse return setWhy("a release não tem o SHA256SUMS", .{});
    const sig_url = assetUrl(rel, "SHA256SUMS.sig") orelse return setWhy("a release não tem a assinatura", .{});
    const sums = fetch(sums_url, false, 64 * 1024) catch return setWhy("não consegui baixar o SHA256SUMS", .{});
    defer gpa.free(sums);
    const sig = fetch(sig_url, false, 1024) catch return setWhy("não consegui baixar a assinatura", .{});
    defer gpa.free(sig);
    if (!verifySums(sums, sig, key())) return setWhy("a assinatura da release não confere", .{});

    // o que muda (no idioma da interface), conferido pelo SHA256SUMS
    const cl_name = if (english) "CHANGELOG.md" else "CHANGELOG.pt.md";
    if (assetUrl(rel, cl_name)) |cu| if (fetch(cu, false, 2 * 1024 * 1024)) |text| {
        defer gpa.free(text);
        if (sumOf(sums, cl_name)) |want| {
            var got: [32]u8 = undefined;
            Sha256.hash(text, &got, .{});
            const part = changelog.between(text, current, rel.tag_name);
            if (std.mem.eql(u8, &got, &want) and part.len > 0) {
                if (gpa.dupe(u8, part)) |d| {
                    gpa.free(notes_text);
                    notes_text = d;
                } else |_| {}
            }
        }
    } else |_| {};

    if (asset_name.len == 0) return setWhy("não tem versão pronta pra este processador", .{});
    const bu = assetUrl(rel, asset_name) orelse return setWhy("a release não tem o {s}", .{asset_name});
    bin_sha = sumOf(sums, asset_name) orelse return setWhy("SHA256SUMS sem o {s}", .{asset_name});
    bin_size = assetSize(rel, asset_name);
    if (bu.len > bin_url.len) return setWhy("endereço longo demais", .{});
    @memcpy(bin_url[0..bu.len], bu);
    bin_url_len = bu.len;
    if (upd_self_path(&self_buf, self_buf.len) != 0) return setWhy("não achei o próprio executável", .{});
    self_len = std.mem.indexOfScalar(u8, &self_buf, 0) orelse return;
    const self = self_buf[0..self_len];
    const sep = std.mem.lastIndexOfAny(u8, self, "/\\") orelse return setWhy("caminho estranho", .{});
    var db: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&db, "{s}", .{self[0..@max(1, sep)]}) catch return;
    if (upd_can_write(dir.ptr) == 0) return setWhy("a pasta do telinha não deixa gravar: {s}", .{self[0..sep]});
    install_ok = true;
}

/// Baixa, confere e troca o executável (numa thread). O app que está aberto
/// continua o antigo até reiniciar.
pub fn installAsync() void {
    if (!canInstall()) return;
    const s = getState();
    if (s != .newer and s != .install_failed) return;
    state.store(.downloading, .release);
    sync.spawn(install, .{}) catch {
        failInstall("não consegui começar", .{});
    };
}

fn failInstall(comptime f: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&err_buf, f, args) catch err_buf[0..0];
    err_len = s.len;
    if (debugOn()) std.debug.print("[telinha] atualização falhou: {s}\n", .{s});
    state.store(.install_failed, .release);
}

fn install() void {
    sync.nameThread("atualizacao");
    var sb: [1100]u8 = undefined;
    var nb: [1110]u8 = undefined;
    var ub: [610]u8 = undefined;
    const self = std.fmt.bufPrintZ(&sb, "{s}", .{self_buf[0..self_len]}) catch return failInstall("caminho longo demais", .{});
    const novo = std.fmt.bufPrintZ(&nb, "{s}.novo", .{self_buf[0..self_len]}) catch return failInstall("caminho longo demais", .{});
    const url = std.fmt.bufPrintZ(&ub, "{s}", .{bin_url[0..bin_url_len]}) catch return failInstall("endereço longo demais", .{});
    if (!urlOk(url)) return failInstall("endereço estranho", .{});
    upd_cleanup(self.ptr);
    const r = upd_download(url.ptr, novo.ptr);
    if (r == -2) return failInstall("precisa do curl instalado pra baixar", .{});
    if (r != 0) return failInstall("não consegui baixar (sem internet?)", .{});
    // confere antes de trocar: tamanho e sha256 do que diz o SHA256SUMS assinado
    var got: [32]u8 = undefined;
    const size = hashFile(novo, &got) catch {
        upd_cleanup(self.ptr);
        return failInstall("não consegui ler o que baixei", .{});
    };
    if ((bin_size != 0 and size != bin_size) or !std.mem.eql(u8, &got, &bin_sha)) {
        upd_cleanup(self.ptr);
        return failInstall("o arquivo baixado não confere com a assinatura: não instalei", .{});
    }
    if (upd_swap(self.ptr, novo.ptr) != 0) {
        upd_cleanup(self.ptr);
        return failInstall("não consegui trocar o executável", .{});
    }
    if (debugOn()) std.debug.print("[telinha] atualização instalada: {s}\n", .{self});
    state.store(.installed, .release);
}

fn hashFile(path: [:0]const u8, out: *[32]u8) !u64 {
    const f = upd_fopen(path.ptr) orelse return error.Open;
    defer _ = fclose(f);
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        h.update(buf[0..n]);
        total += n;
    }
    h.final(out);
    return total;
}

/// Abre o executável de novo (o que acabou de ser instalado). Quem chama
/// fecha o app logo depois; o novo espera este sair.
pub fn restart() bool {
    if (getState() != .installed) return false;
    var sb: [1100]u8 = undefined;
    const self = std.fmt.bufPrintZ(&sb, "{s}", .{self_buf[0..self_len]}) catch return false;
    return upd_relaunch(self.ptr) == 0;
}

/// Ao abrir: espera a versão anterior fechar (reinício depois de atualizar) e
/// apaga as sobras (o .old do Windows, um .novo que ficou pela metade).
pub fn startup() void {
    upd_wait_previous();
    var sb: [1024]u8 = undefined;
    if (upd_self_path(&sb, sb.len) == 0) upd_cleanup(@ptrCast(&sb));
}

fn key() [32]u8 {
    // testes: outra chave (só no modo de testes; fora dele, só a de verdade)
    if (getenv("TELINHA_QA") != null) if (getenv("TELINHA_CHAVE_ATUALIZACAO")) |hex| {
        var k: [32]u8 = undefined;
        if (std.fmt.hexToBytes(&k, std.mem.span(hex))) |_| return k else |_| {}
    };
    return release_key;
}

fn hexKey(comptime hex: []const u8) [32]u8 {
    var k: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&k, hex) catch unreachable;
    return k;
}

/// O SHA256SUMS veio assinado pela chave das releases?
pub fn verifySums(sums: []const u8, sig: []const u8, pk_bytes: [32]u8) bool {
    if (sig.len != Ed25519.Signature.encoded_length) return false;
    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch return false;
    const s = Ed25519.Signature.fromBytes(sig[0..64].*);
    s.verify(sums, pk) catch return false;
    return true;
}

/// O sha256 de um arquivo no SHA256SUMS ("hex  nome" por linha).
pub fn sumOf(sums: []const u8, name: []const u8) ?[32]u8 {
    var it = std.mem.splitScalar(u8, sums, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 66) continue;
        var rest = std.mem.trimStart(u8, line[64..], " ");
        if (rest.len > 0 and rest[0] == '*') rest = rest[1..]; // modo binário do sha256sum
        if (!std.mem.eql(u8, rest, name)) continue;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, line[0..64]) catch return null;
        return out;
    }
    return null;
}

/// As notas da release sem a tabela de downloads (o que sobra quando o
/// CHANGELOG não veio): do primeiro "### " pra frente.
fn releaseNotes(body: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, body, "\n### ") orelse return "";
    return std.mem.trim(u8, body[at + 1 ..], " \r\n");
}

const Asset = struct { name: []const u8 = "", browser_download_url: []const u8 = "", size: u64 = 0 };
const Release = struct {
    tag_name: []const u8,
    html_url: []const u8 = "",
    body: []const u8 = "",
    assets: []const Asset = &.{},
};

fn assetUrl(rel: Release, name: []const u8) ?[]const u8 {
    for (rel.assets) |a| if (std.mem.eql(u8, a.name, name)) return if (urlOkSlice(a.browser_download_url)) a.browser_download_url else null;
    return null;
}

fn assetSize(rel: Release, name: []const u8) u64 {
    for (rel.assets) |a| if (std.mem.eql(u8, a.name, name)) return a.size;
    return 0;
}

/// Endereço que pode virar argumento de comando: https (ou o de testes) e
/// só caracteres de URL comuns.
fn urlOkSlice(url: []const u8) bool {
    const https = std.mem.startsWith(u8, url, "https://");
    const test_url = getenv("TELINHA_ATUALIZACAO_URL") != null and std.mem.startsWith(u8, url, "http://127.0.0.1:");
    if (!https and !test_url) return false;
    for (url) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, ":/._-?=&%~+", ch) != null)) return false;
    }
    return true;
}

fn urlOk(url: [:0]const u8) bool {
    return urlOkSlice(url);
}

/// GET. Sem cliente HTTP/TLS próprio (leve): no Windows o WinHTTP do
/// sistema, no Linux o curl (quase todo sistema tem). `api`: cabeçalho da API
/// do GitHub (os arquivos da release vão sem).
fn fetch(url: []const u8, api: bool, cap: usize) ![]u8 {
    if (!urlOkSlice(url)) return error.BadUrl;
    const body = try gpa.alloc(u8, cap);
    errdefer gpa.free(body);
    var n: usize = 0;
    if (sync.is_windows) {
        var z: [700]u8 = undefined;
        const uz = std.fmt.bufPrintZ(&z, "{s}", .{url}) catch return error.BadUrl;
        const r = http_get_h(uz.ptr, if (api) "Accept: application/vnd.github+json\r\n" else "", body.ptr, @intCast(body.len));
        if (r < 0) return error.HttpFailed;
        n = @intCast(r);
    } else {
        var cmd: [900]u8 = undefined;
        const hdr = if (api) " -H 'Accept: application/vnd.github+json'" else "";
        const cz = std.fmt.bufPrintZ(&cmd, "curl -fsSL --max-time 30 -A telinha{s} '{s}' 2>/dev/null", .{ hdr, url }) catch return error.BadUrl;
        const f = popen(cz.ptr, "r") orelse return error.NoCurl;
        while (n < body.len) {
            const got = fread(body.ptr + n, 1, body.len - n, f);
            if (got == 0) break;
            n += got;
        }
        if (pclose(f) != 0) return error.HttpFailed;
    }
    return gpa.realloc(body, n) catch body[0..n];
}

extern "c" fn http_get_h(url: [*:0]const u8, headers: [*:0]const u8, out: [*]u8, cap: c_int) c_int;
const FILE = opaque {};
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(f: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn upd_self_path(out: [*]u8, cap: c_int) c_int;
extern "c" fn upd_can_write(dir: [*:0]const u8) c_int;
extern "c" fn upd_download(url: [*:0]const u8, path: [*:0]const u8) c_int;
extern "c" fn upd_swap(self: [*:0]const u8, newfile: [*:0]const u8) c_int;
extern "c" fn upd_cleanup(self: [*:0]const u8) void;
extern "c" fn upd_relaunch(self: [*:0]const u8) c_int;
extern "c" fn upd_wait_previous() void;
extern "c" fn upd_file_size(path: [*:0]const u8) c_longlong;
extern "c" fn upd_fopen(path: [*:0]const u8) ?*FILE;

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

test "release do JSON do GitHub (tag, página, arquivos)" {
    const r = try parseRelease(
        \\{"url":"x","tag_name":"v3.2.0","html_url":"https://github.com/a/b/releases/tag/v3.2.0","draft":false,
        \\ "body":"## Download\n| a | b |\n\n### Highlights\n\n- coisa","assets":[{"name":"SHA256SUMS","size":10,
        \\ "browser_download_url":"https://github.com/a/b/releases/download/v3.2.0/SHA256SUMS","id":1}]}
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("v3.2.0", r.value.tag_name);
    try std.testing.expectEqualStrings("https://github.com/a/b/releases/tag/v3.2.0", r.value.html_url);
    try std.testing.expectEqualStrings("https://github.com/a/b/releases/download/v3.2.0/SHA256SUMS", assetUrl(r.value, "SHA256SUMS").?);
    try std.testing.expect(assetUrl(r.value, "outro") == null);
    try std.testing.expectEqual(@as(u64, 10), assetSize(r.value, "SHA256SUMS"));
    try std.testing.expectEqualStrings("### Highlights\n\n- coisa", releaseNotes(r.value.body));
    try std.testing.expectError(error.BadTag, parseRelease("{\"tag_name\":\"\"}"));
}

test "SHA256SUMS assinado (o mesmo formato do openssl pkeyutl -sign -rawin do CI)" {
    // chave de teste (não é a das releases)
    const pk = hexKey("74eb208b9b6df7aa78304e0ba57236c6f0bdb9a8c5647d529f1710437c7a9e41");
    var sig: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sig, "ad8a6e41de69132771d2d844fda5ee9d3e75fbf30f9e6064bb6aee606ee0b67a6864c2511d9fa174892a9264b9c03ecd8587ec829f6cdfd703886e053a319a02");
    const sums = "aaaa  telinha-linux-x86_64\nbbbb  SHA256SUMS\n";
    try std.testing.expect(verifySums(sums, &sig, pk));
    // qualquer mudança no texto, assinatura ou chave: não vale
    try std.testing.expect(!verifySums("aaab  telinha-linux-x86_64\nbbbb  SHA256SUMS\n", &sig, pk));
    try std.testing.expect(!verifySums(sums, sig[0..63], pk));
    try std.testing.expect(!verifySums(sums, &sig, release_key));
    var bad = sig;
    bad[5] ^= 1;
    try std.testing.expect(!verifySums(sums, &bad, pk));
}

test "sha256 de um arquivo no SHA256SUMS" {
    const h = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const sums = "0000000000000000000000000000000000000000000000000000000000000000  telinha-windows-x86_64.exe\n" ++ h ++ " *telinha-linux-x86_64\r\n";
    const got = sumOf(sums, "telinha-linux-x86_64").?;
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, h);
    try std.testing.expectEqualSlices(u8, &want, &got);
    try std.testing.expect(sumOf(sums, "telinha-linux") == null);
    try std.testing.expect(sumOf(sums, "nada") == null);
}
