//! telinha-server — servidor dedicado da sala (sem interface).
//!
//! Roda numa VPS/servidor com porta aberta (ninguém precisa de túnel), ou em
//! qualquer máquina com --publico (abre um link público pelo bore.pub) ou
//! --upnp (pede pro roteador abrir a porta: conexão direta).
//! Binário estático, sem dependências. Ver docs/DEPLOY.md.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const web = @import("web.zig");
const proto = @import("proto.zig");
const Server = @import("server.zig").Server;
const tunnel = @import("tunnel.zig");
const upnp = @import("upnp.zig");
const crypto = @import("crypto.zig");
const update = @import("update.zig");
const server_options = @import("server_options");

const usage =
    \\telinha-server — servidor dedicado de salas do telinha
    \\
    \\uso: telinha-server [opções]
    \\  -p, --porta N          porta TCP (padrão 7777, ou $TELINHA_PORTA)
    \\  -s, --senha TXT        senha da sala ($TELINHA_SENHA; vazio = sem senha)
    \\  -n, --nome TXT         nome da sala ($TELINHA_NOME)
    \\  -a, --admin TXT        token de admin: quem entrar com ele pode expulsar
    \\                         ($TELINHA_ADMIN; no app: campo "token de admin")
    \\  -m, --max N            máximo de pessoas (padrão 32)
    \\  -l, --logs PASTA       guarda os logs de depuração que mandarem pela sala
    \\                         ($TELINHA_LOGS; sem isso eles vão só pra quem
    \\                         estiver na sala com o token de admin)
    \\  -c, --canais LISTA     canais fixos, separados por vírgula ($TELINHA_CANAIS);
    \\                         o primeiro é o padrão (sem isso: só "geral").
    \\                         Quem entra num nome que não existe cria o canal
    \\                         (some quando esvazia)
    \\  --sem-canais-novos     ninguém cria canal: só os da lista
    \\  --atualizar-sozinho    baixa a versão nova (assinada) e reinicia quando a
    \\                         sala ficar 2 min vazia ($TELINHA_ATUALIZAR=1)
    \\  --coletar-logs         o dono (quem entra com o token de admin) pode pegar o
    \\                         log de depuração de quem está na sala, sem pedir
    \\                         ($TELINHA_COLETAR_LOGS=1). O app avisa ao entrar,
    \\                         grava o log enquanto está na sala e quem desligar
    \\                         nas configurações recusa. Guardados em --logs
    \\                         (padrão: "logs" do lado do --estado)
    \\  --exigir-logs          o mesmo, mas o app manda mesmo com a opção desligada
    \\                         ($TELINHA_EXIGIR_LOGS=1): o aviso ao entrar diz que
    \\                         a sala exige o log, e quem não quiser sai
    \\  --sem-bots             recusa bots (o sdk/python e afins; $TELINHA_SEM_BOTS=1)
    \\  --so-protocolo-novo    recusa apps de antes da 3.8 (protocolo 6: a senha deles
    \\                         dá pra testar offline a partir de uma conexão;
    \\                         $TELINHA_SO_PROTOCOLO_NOVO=1)
    \\  --token-bots TXT       só aceita bots que mandarem esse token
    \\                         ($TELINHA_TOKEN_BOTS); sem isso, qualquer bot com
    \\                         a senha da sala entra. Bot nunca vira admin
    \\  -e, --estado ARQUIVO   onde guardar o que sobrevive a reiniciar: canais
    \\                         fixos (senha, trava, tópico), banidos, silenciados
    \\                         ($TELINHA_ESTADO; padrão: do lado da --chave)
    \\  --arquivos PASTA       onde guardar os arquivos mandados na sala, cifrados
    \\                         ($TELINHA_ARQUIVOS; padrão: "arquivos" do lado do
    \\                         --estado). Expiram em 2 h; no máximo 2 GB
    \\  -k, --chave ARQUIVO    a identidade do servidor ($TELINHA_CHAVE; criada na
    \\                         primeira vez). Padrão: /var/lib/telinha/servidor.key
    \\                         (root) ou ~/.config/telinha/servidor.key. A impressão
    \\                         vai no convite (telinha://...!impressão) e o app
    \\                         confere que é mesmo este servidor
    \\  --publico [SERVIDOR]   abre um link público pelo túnel (padrão bore.pub);
    \\                         sem --senha, cria uma senha aleatória
    \\  --upnp                 pede pro roteador abrir a porta (UPnP): conexão
    \\                         direta, sem túnel; também cria senha se não tiver
    \\  --web PORTA            assistir pelo navegador: a página e o WebSocket em
    \\                         127.0.0.1:PORTA ($TELINHA_WEB), pra ficar atrás de
    \\                         um HTTPS (o navegador só decodifica em página segura)
    \\  --web-tunel            sobe um túnel rápido da Cloudflare (cloudflared, sem
    \\                         conta) pra porta web e divulga o link na sala
    \\                         ($TELINHA_WEB_TUNEL=1); muda a cada vez que sobe
    \\  --web-link URL         o endereço HTTPS fixo da porta web (domínio seu,
    \\                         túnel nomeado, outro proxy) em vez do túnel rápido
    \\  --cloudflared CAMINHO  o executável (padrão: cloudflared do PATH)
    \\  -v, --versao           mostra a versão e sai
    \\  -h, --help             mostra isso
    \\
;

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

// ---------------------------------------------- túnel rápido da Cloudflare

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, actions: ?*const anyopaque, attrs: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *anyopaque, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *anyopaque) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

/// Mantém o túnel rápido (cloudflared, sem conta) apontando pra porta web e
/// divulga o endereço na sala; caiu, sobe de novo (o endereço muda).
/// O cloudflared rodando (pra matar junto quando o servidor fecha).
var tunnel_pid = std.atomic.Value(c_int).init(0);
/// A porta aberta no roteador (pra fechar quando o servidor fecha).
var upnp_mapper: ?*upnp.Mapper = null;

extern "c" fn sigemptyset(set: *[128]u8) c_int;
extern "c" fn sigaddset(set: *[128]u8, sig: c_int) c_int;
extern "c" fn pthread_sigmask(how: c_int, set: *const [128]u8, old: ?*[128]u8) c_int;
extern "c" fn sigtimedwait(set: *const [128]u8, info: ?*[128]u8, timeout: *const Timespec) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
const Timespec = extern struct { sec: isize, nsec: isize };
const SIG_BLOCK = 0;
const SIGHUP = 1;
const SIGINT = 2;
const SIGTERM = 15;

fn webTunnel(srv: *Server, exe: []const u8, port: u16) void {
    sync.nameThread("web-tunel");
    var exe_z: [400]u8 = undefined;
    var url_arg: [64]u8 = undefined;
    const ez = std.fmt.bufPrintZ(&exe_z, "{s}", .{exe}) catch return;
    const uz = std.fmt.bufPrintZ(&url_arg, "http://127.0.0.1:{d}", .{port}) catch return;
    var backoff: u32 = 2_000;
    while (true) {
        var fds: [2]c_int = undefined;
        if (pipe(&fds) != 0) return;
        var fa: [128]u8 align(16) = undefined; // posix_spawn_file_actions_t (opaco)
        _ = posix_spawn_file_actions_init(&fa);
        _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
        _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
        _ = posix_spawn_file_actions_addclose(&fa, fds[0]);
        const argv = [_:null]?[*:0]const u8{ ez.ptr, "tunnel", "--no-autoupdate", "--url", uz.ptr, null };
        var pid: c_int = 0;
        const rc = posix_spawnp(&pid, ez.ptr, &fa, null, &argv, environ);
        if (rc == 0) tunnel_pid.store(pid, .release);
        _ = posix_spawn_file_actions_destroy(&fa);
        _ = close(fds[1]);
        if (rc != 0) {
            _ = close(fds[0]);
            log("não achei o cloudflared (instale ou use --cloudflared CAMINHO): sem link pro navegador");
            return;
        }
        // lê o que ele imprime até achar o endereço (e continua lendo, pra ele não travar)
        var line: [1024]u8 = undefined;
        var n: usize = 0;
        var announced = false;
        while (true) {
            var b: [512]u8 = undefined;
            const got = read(fds[0], &b, b.len);
            if (got <= 0) break;
            for (b[0..@intCast(got)]) |ch| {
                if (ch == '\n' or n == line.len) {
                    if (!announced) if (web.findTryCloudflare(line[0..n])) |url| {
                        srv.setWebLink(url);
                        var lb: [400]u8 = undefined;
                        log(std.fmt.bufPrint(&lb, "link pra assistir no navegador: {s}", .{url}) catch "");
                        announced = true;
                        backoff = 2_000;
                    };
                    n = 0;
                } else {
                    line[n] = ch;
                    n += 1;
                }
            }
        }
        _ = close(fds[0]);
        _ = waitpid(pid, null, 0);
        tunnel_pid.store(0, .release);
        srv.setWebLink("");
        log("o túnel do navegador caiu; subindo de novo");
        sync.sleepMs(backoff);
        backoff = @min(backoff * 2, 60_000);
    }
}
extern "c" fn getuid() c_uint;
extern "c" fn creat(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;

// ------------------------------------------------------------ quedas
// O servidor caía (panic) e reiniciava sem ninguém saber por quê: o panic
// grava o motivo e a pilha em queda.txt (do lado do estado), e um marcador
// "rodando" denuncia quem morreu sem panic (sinal, falta de memória). Ao
// voltar, o motivo vai pro journal, pro chat do canal padrão e fica em
// ultima-queda.txt.

pub const panic = std.debug.FullPanic(onPanic);
var queda_buf: [480]u8 = undefined;
var queda_path: ?[:0]const u8 = null;

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (queda_path) |qp| {
        const fd = creat(qp.ptr, 0o640);
        if (fd >= 0) {
            var hb: [600]u8 = undefined;
            const t = sync.dateTime();
            const h = std.fmt.bufPrint(&hb, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} telinha-server {s}: panic: {s}\n", .{ t.year, t.month, t.day, t.h, t.m, t.s, proto.app_version, msg }) catch "panic\n";
            _ = write(fd, h.ptr, h.len);
            // a pilha (com arquivo e linha: o servidor vai com símbolos) sai no arquivo;
            // no journal ela aparece quando o servidor volta
            _ = dup2(fd, 2);
        }
    }
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

/// Caminho de `name` do lado do arquivo de estado.
fn besideState(state: []const u8, name: []const u8, buf: []u8) ?[:0]const u8 {
    const dir = if (std.mem.lastIndexOfScalar(u8, state, '/')) |i| state[0..i] else ".";
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch null;
}

/// A última vez terminou mal? Devolve o motivo (curto, pro chat) e deixa o
/// arquivo em ultima-queda.txt. Também arma o panic e o marcador desta vez.
fn checkLastCrash(state: []const u8, reason_buf: []u8) ?[]const u8 {
    var mb: [480]u8 = undefined;
    var ub: [480]u8 = undefined;
    const marker = besideState(state, "rodando", &mb) orelse return null;
    queda_path = besideState(state, "queda.txt", &queda_buf);
    const last = besideState(state, "ultima-queda.txt", &ub) orelse return null;
    var reason: ?[]const u8 = null;
    if (queda_path) |qp| if (std.c.fopen(qp.ptr, "rb")) |f| {
        var data: [16 * 1024]u8 = undefined;
        const n = std.c.fread(&data, 1, data.len, f);
        _ = std.c.fclose(f);
        const text = data[0..n];
        std.debug.print("[queda] a última execução caiu:\n{s}\n", .{text});
        // "...: panic: integer overflow" + o primeiro src/arquivo.zig:linha da pilha
        const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const what = if (std.mem.indexOf(u8, first, "panic: ")) |i| first[i..] else first;
        var where: []const u8 = "";
        if (std.mem.indexOf(u8, text, "/src/")) |i| {
            const rest = text[i + 1 ..];
            const end = std.mem.indexOf(u8, rest, ": 0x") orelse std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            where = rest[0..end];
        }
        reason = if (where.len > 0) std.fmt.bufPrint(reason_buf, "{s} em {s}", .{ what, where }) catch what else std.fmt.bufPrint(reason_buf, "{s}", .{what}) catch null;
        _ = rename(qp.ptr, last.ptr);
    };
    const had_marker = if (std.c.fopen(marker.ptr, "rb")) |f| blk: {
        _ = std.c.fclose(f);
        break :blk true;
    } else false;
    if (reason == null and had_marker) {
        reason = "parou sem avisar (sinal, falta de memória ou a máquina reiniciou)";
        if (std.c.fopen(last.ptr, "wb")) |w| {
            const t = sync.dateTime();
            var lb: [200]u8 = undefined;
            const l = std.fmt.bufPrint(&lb, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} (hora em que voltou) {s}\n", .{ t.year, t.month, t.day, t.h, t.m, t.s, reason.? }) catch "";
            _ = std.c.fwrite(l.ptr, 1, l.len, w);
            _ = std.c.fclose(w);
        }
    }
    // marcador desta execução (sai no fechamento limpo e ao se atualizar)
    marker_path = besideState(state, "rodando", &marker_buf);
    if (marker_path) |mp| if (std.c.fopen(mp.ptr, "wb")) |w| {
        _ = std.c.fclose(w);
    };
    return reason;
}
var marker_buf: [480]u8 = undefined;
var marker_path: ?[:0]const u8 = null;

/// Fechamento limpo (sinal, atualização): não é queda.
fn cleanExit() void {
    if (marker_path) |mp| _ = unlink(mp.ptr);
}
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;

/// "!impressão" pro convite (vazio sem identidade).
var fp_suffix: [crypto.fp_len + 1]u8 = undefined;
var fp_suffix_len: usize = 0;
fn fpSuffix() []const u8 {
    return fp_suffix[0..fp_suffix_len];
}

/// Lê (ou cria, só o dono lendo) a semente da identidade do servidor.
var key_used: [400]u8 = undefined;
var key_used_len: usize = 0;
var state_buf: [420]u8 = undefined;

var files_buf: [480]u8 = undefined;
var logs_buf: [480]u8 = undefined;

/// A pasta dos arquivos da sala: a dada, ou "arquivos" do lado do estado.
fn filesDir(given: []const u8, state: []const u8) []const u8 {
    if (given.len > 0) return given;
    const dir = if (std.mem.lastIndexOfScalar(u8, state, '/')) |i| state[0..i] else ".";
    return std.fmt.bufPrint(&files_buf, "{s}/arquivos", .{dir}) catch "";
}

/// Pasta dos logs coletados (--coletar-logs sem --logs): "logs" do lado do estado.
fn logsDir(state: []const u8) []const u8 {
    const dir = if (std.mem.lastIndexOfScalar(u8, state, '/')) |i| state[0..i] else ".";
    return std.fmt.bufPrint(&logs_buf, "{s}/logs", .{dir}) catch "";
}

/// O arquivo de estado: o dado, ou "estado.txt" na pasta da chave.
fn statePath(given: []const u8, key: []const u8) []const u8 {
    if (given.len > 0) return given;
    const dir = if (std.mem.lastIndexOfScalar(u8, key, '/')) |i| key[0..i] else ".";
    return std.fmt.bufPrint(&state_buf, "{s}/estado.txt", .{dir}) catch "";
}

fn loadKey(given: []const u8, used: *[400]u8) ?[32]u8 {
    var pb: [400]u8 = undefined;
    const path: [:0]const u8 = if (given.len > 0)
        std.fmt.bufPrintZ(&pb, "{s}", .{given}) catch return null
    else if (getenv("STATE_DIRECTORY")) |sd| blk: {
        // systemd com StateDirectory= (o DynamicUser não tem casa nem é root)
        const dirs = std.mem.span(sd);
        const dir = dirs[0 .. std.mem.indexOfScalar(u8, dirs, ':') orelse dirs.len];
        break :blk std.fmt.bufPrintZ(&pb, "{s}/servidor.key", .{dir}) catch return null;
    } else if (getuid() == 0) blk: {
        _ = mkdir("/var/lib/telinha", 0o750);
        break :blk "/var/lib/telinha/servidor.key";
    } else blk: {
        const home = std.mem.span(getenv("HOME") orelse break :blk "telinha-servidor.key");
        const d1 = std.fmt.bufPrintZ(&pb, "{s}/.config", .{home}) catch return null;
        _ = mkdir(d1.ptr, 0o755);
        const d2 = std.fmt.bufPrintZ(&pb, "{s}/.config/telinha", .{home}) catch return null;
        _ = mkdir(d2.ptr, 0o700);
        break :blk std.fmt.bufPrintZ(&pb, "{s}/.config/telinha/servidor.key", .{home}) catch return null;
    };
    key_used_len = @min(path.len, used.len);
    @memcpy(used[0..key_used_len], path[0..key_used_len]);
    if (std.c.fopen(path.ptr, "rb")) |f| {
        defer _ = std.c.fclose(f);
        var seed: [32]u8 = undefined;
        if (std.c.fread(&seed, 1, 32, f) == 32) {
            var lb: [500]u8 = undefined;
            log(std.fmt.bufPrint(&lb, "identidade: {s}", .{path}) catch "identidade carregada");
            return seed;
        }
    }
    const seed = crypto.Identity.newSeed();
    const f = std.c.fopen(path.ptr, "wb") orelse {
        var lb: [500]u8 = undefined;
        log(std.fmt.bufPrint(&lb, "não consegui criar {s}: a identidade muda a cada vez que o servidor sobe (use --chave)", .{path}) catch "sem arquivo de identidade");
        return seed;
    };
    _ = std.c.fwrite(&seed, 1, 32, f);
    _ = std.c.fclose(f);
    _ = chmod(path.ptr, 0o600);
    var lb: [500]u8 = undefined;
    log(std.fmt.bufPrint(&lb, "identidade nova criada em {s} (guarde: trocar de chave faz o app avisar quem já entrou)", .{path}) catch "identidade nova");
    return seed;
}

fn log(msg: []const u8) void {
    // com segundos: no journal dá pra casar o log com o que a pessoa conta
    const t = sync.dateTime();
    std.debug.print("[{d:0>2}:{d:0>2}:{d:0>2}] {s}\n", .{ t.h, t.m, t.s, msg });
}

/// --atualizar-sozinho: confere a cada 6 h (a primeira 5 min depois de abrir),
/// baixa e confere a assinatura, e só reinicia com a sala vazia há 2 min
/// (bots não contam: o de música fica conectado o tempo todo). Reinicia no
/// mesmo processo; se a versão nova cair antes de 10 s, a próxima abertura
/// volta pra anterior (update.serverStartup).
const AutoUpdate = struct {
    next_check_ms: u64,
    empty_ms: u64,
    empty_since_ms: u64 = 0,
    told: update.State = .idle,

    fn tick(au: *AutoUpdate, srv: *Server) void {
        var buf: [300]u8 = undefined;
        const now = sync.nowMs();
        const st = update.getState();
        var vb: [32]u8 = undefined;
        const v = update.latest(&vb);
        defer au.told = st;
        switch (st) {
            .idle, .current, .failed => if (now >= au.next_check_ms) {
                au.next_check_ms = now + 6 * 3600_000;
                update.checkAsync(server_options.repo, proto.app_version, false);
            },
            .newer => if (update.canInstall()) {
                log(std.fmt.bufPrint(&buf, "versão nova {s}: baixando", .{v}) catch "versão nova: baixando");
                update.installAsync();
            } else if (au.told != .newer) {
                log(std.fmt.bufPrint(&buf, "versão nova {s}, mas não dá pra trocar sozinho: {s}", .{ v, update.whyNot() }) catch "versão nova");
            },
            .install_failed => {
                if (au.told != .install_failed) log(std.fmt.bufPrint(&buf, "a atualização falhou: {s} (tento de novo em 6 h)", .{update.installError()}) catch "a atualização falhou");
                if (now >= au.next_check_ms) {
                    au.next_check_ms = now + 6 * 3600_000;
                    update.installAsync();
                }
            },
            .installed => {
                if (au.told != .installed) log(std.fmt.bufPrint(&buf, "versão {s} instalada: reinicio quando a sala ficar vazia por 2 min", .{v}) catch "versão nova instalada");
                if (srv.humanCount() > 0) {
                    au.empty_since_ms = 0;
                    return;
                }
                if (au.empty_since_ms == 0) au.empty_since_ms = now;
                if (now -| au.empty_since_ms < au.empty_ms) return;
                log(std.fmt.bufPrint(&buf, "sala vazia: reiniciando na versão {s}", .{v}) catch "reiniciando na versão nova");
                const tp = tunnel_pid.load(.acquire);
                if (tp > 0) _ = kill(tp, SIGTERM);
                if (upnp_mapper) |m| m.stopAndWait(2000);
                cleanExit();
                update.serverRestart(); // só volta se não deu
                log(std.fmt.bufPrint(&buf, "não consegui reabrir na versão nova: {s}", .{update.installError()}) catch "não consegui reabrir");
            },
            else => {},
        }
    }
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cleanExit(); // não abriu: não é queda
    std.debug.print("erro: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Mostra o endereço público (e o convite) sempre que o túnel muda de estado.
fn watchTunnel(t: *tunnel.Tunnel, password: []const u8) void {
    var last: tunnel.State = .connecting;
    var last_port: u16 = 0;
    var buf: [400]u8 = undefined;
    log(std.fmt.bufPrint(&buf, "abrindo o link público em {s}...", .{t.hostSlice()}) catch "abrindo o link público...");
    while (true) {
        const st = t.status();
        if (st.state != last or st.public_port != last_port) {
            switch (st.state) {
                .ready => log(std.fmt.bufPrint(&buf, "link público: {s}:{d}  —  convite: telinha://{s}:{d}{s}#{s}", .{
                    t.hostSlice(), st.public_port, t.hostSlice(), st.public_port, fpSuffix(), password,
                }) catch "link público pronto"),
                .connecting => log("o túnel caiu; reconectando..."),
                .failed => log(std.fmt.bufPrint(&buf, "link público falhou: {s} (tentando de novo)", .{st.err}) catch "link público falhou"),
            }
            last = st.state;
            last_port = st.public_port;
        }
        sync.sleepMs(500);
    }
}

/// Mostra o endereço (e o convite) quando o roteador abrir a porta.
fn watchUpnp(m: *upnp.Mapper, password: []const u8) void {
    log("pedindo pro roteador abrir a porta (UPnP)...");
    var buf: [400]u8 = undefined;
    while (true) {
        const st = m.status();
        switch (st.state) {
            .working => {},
            .ready => {
                var abuf: [64]u8 = undefined;
                const addr = m.address(&abuf);
                log(std.fmt.bufPrint(&buf, "porta aberta no roteador: {s}  —  convite: telinha://{s}{s}#{s}", .{ addr, addr, fpSuffix(), password }) catch "porta aberta no roteador");
                return;
            },
            .failed => {
                log(std.fmt.bufPrint(&buf, "UPnP: {s}", .{st.err}) catch "UPnP falhou");
                return;
            },
        }
        sync.sleepMs(200);
    }
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    return std.mem.span(v);
}

pub fn main(init: std.process.Init) !void {
    // os sinais de fechar ficam pro laço do fim do main (sigtimedwait):
    // bloqueados aqui, antes de qualquer thread, valem pra todas
    var sigset: [128]u8 = undefined;
    _ = sigemptyset(&sigset);
    for ([_]c_int{ SIGHUP, SIGINT, SIGTERM }) |sgn| _ = sigaddset(&sigset, sgn);
    _ = pthread_sigmask(SIG_BLOCK, &sigset, null);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 7777;
    var password: []const u8 = env("TELINHA_SENHA") orelse "";
    var room: []const u8 = env("TELINHA_NOME") orelse "telinha";
    var admin: []const u8 = env("TELINHA_ADMIN") orelse "";
    var logs_dir: []const u8 = env("TELINHA_LOGS") orelse "";
    var max: u32 = 32;
    var channels: []const u8 = env("TELINHA_CANAIS") orelse "";
    var new_channels = true;
    var no_bots = if (env("TELINHA_SEM_BOTS")) |v| std.mem.eql(u8, v, "1") else false;
    var collect_logs = if (env("TELINHA_COLETAR_LOGS")) |v| std.mem.eql(u8, v, "1") else false;
    var require_logs = if (env("TELINHA_EXIGIR_LOGS")) |v| std.mem.eql(u8, v, "1") else false;
    var only_new = if (env("TELINHA_SO_PROTOCOLO_NOVO")) |v| std.mem.eql(u8, v, "1") else false;
    var bot_token: []const u8 = env("TELINHA_TOKEN_BOTS") orelse "";
    var key_path: []const u8 = env("TELINHA_CHAVE") orelse "";
    var state_path: []const u8 = env("TELINHA_ESTADO") orelse "";
    var files_dir: []const u8 = env("TELINHA_ARQUIVOS") orelse "";
    var public_host: ?[]const u8 = null;
    var use_upnp = false;
    var web_port: u16 = 0;
    if (env("TELINHA_WEB")) |w| web_port = std.fmt.parseInt(u16, w, 10) catch die("TELINHA_WEB inválida: {s}", .{w});
    var web_tunnel = if (env("TELINHA_WEB_TUNEL")) |v| std.mem.eql(u8, v, "1") else false;
    var web_link: []const u8 = env("TELINHA_WEB_LINK") orelse "";
    var cloudflared: []const u8 = env("TELINHA_CLOUDFLARED") orelse "cloudflared";
    if (env("TELINHA_PORTA")) |p| port = std.fmt.parseInt(u16, p, 10) catch die("TELINHA_PORTA inválida: {s}", .{p});
    var auto_update = if (env("TELINHA_ATUALIZAR")) |v| std.mem.eql(u8, v, "1") else false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--versao") or std.mem.eql(u8, a, "--version")) {
            std.debug.print("telinha-server {s} (protocolo {d})\n", .{ proto.app_version, proto.version });
            return;
        }
        if (std.mem.eql(u8, a, "--upnp")) {
            use_upnp = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--web-tunel")) {
            web_tunnel = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--sem-canais-novos")) {
            new_channels = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--atualizar-sozinho")) {
            auto_update = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--sem-bots")) {
            no_bots = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--coletar-logs")) {
            collect_logs = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--exigir-logs")) {
            require_logs = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--so-protocolo-novo")) {
            only_new = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--publico")) {
            public_host = tunnel.default_host;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                public_host = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (i + 1 >= args.len) die("faltou o valor de {s} (veja --help)", .{a});
        const v: []const u8 = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--porta")) {
            port = std.fmt.parseInt(u16, v, 10) catch die("porta inválida: {s}", .{v});
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--senha")) {
            password = v;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--nome")) {
            room = v;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--admin")) {
            admin = v;
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--logs")) {
            logs_dir = v;
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--estado")) {
            state_path = v;
        } else if (std.mem.eql(u8, a, "--token-bots")) {
            bot_token = v;
        } else if (std.mem.eql(u8, a, "--arquivos")) {
            files_dir = v;
        } else if (std.mem.eql(u8, a, "--web")) {
            web_port = std.fmt.parseInt(u16, v, 10) catch die("porta web inválida: {s}", .{v});
        } else if (std.mem.eql(u8, a, "--web-link")) {
            web_link = v;
        } else if (std.mem.eql(u8, a, "--cloudflared")) {
            cloudflared = v;
        } else if (std.mem.eql(u8, a, "-k") or std.mem.eql(u8, a, "--chave")) {
            key_path = v;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--canais")) {
            channels = v;
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--max")) {
            max = std.fmt.parseInt(u32, v, 10) catch die("número inválido: {s}", .{v});
        } else die("opção desconhecida: {s} (veja --help)", .{a});
    }

    if (auto_update) {
        if (server_options.repo.len == 0 and env("TELINHA_ATUALIZACAO_URL") == null)
            die("--atualizar-sozinho: este binário não sabe de onde vem a versão nova (compile com -Drepo=dono/nome)", .{});
        update.for_server = true;
        // a versão nova caiu logo depois de trocar? volta pra anterior (antes de abrir as portas)
        if (update.serverStartup()) |m| log(m);
    }

    net.init();
    var pw_buf: [16]u8 = undefined; // ~79 bits: 8 letras caíam por força bruta offline
    if ((public_host != null or use_upnp) and password.len == 0) {
        // endereço público sem senha: qualquer um que achasse a porta entraria
        const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
        var rnd: [16]u8 = undefined;
        sync.osRandom(&rnd);
        for (&pw_buf, rnd) |*ch, r| ch.* = alphabet[r % alphabet.len];
        password = &pw_buf;
    }
    const seed = loadKey(key_path, &key_used);
    const state_file = statePath(state_path, key_used[0..key_used_len]);
    var crash_reason_buf: [400]u8 = undefined;
    const crash_reason = checkLastCrash(state_file, &crash_reason_buf);
    if (require_logs) collect_logs = true;
    if (collect_logs and logs_dir.len == 0) logs_dir = logsDir(state_file);
    if (logs_dir.len > 0) {
        var lb: [300]u8 = undefined;
        const z = std.fmt.bufPrintZ(&lb, "{s}", .{logs_dir}) catch die("pasta de logs longa demais", .{});
        _ = mkdir(z.ptr, 0o750);
    }
    const srv = Server.start(.{ .port = port, .password = password, .room_name = room, .admin_token = admin, .max_members = max, .log = log, .logs_dir = logs_dir, .channels = channels, .new_channels = new_channels, .identity_seed = seed, .state_path = state_file, .files_dir = filesDir(files_dir, state_file), .no_bots = no_bots, .bot_token = bot_token, .accept_old = !only_new, .collect_logs = collect_logs, .require_logs = require_logs }) catch
        die("não consegui abrir a porta {d} (já está em uso?)", .{port});

    var buf: [256]u8 = undefined;
    log(std.fmt.bufPrint(&buf, "sala \"{s}\" aberta na porta {d} (protocolo v{d}, {s}, máx. {d} pessoas)", .{
        room, port, proto.version, if (password.len > 0) "com senha" else "sem senha", max,
    }) catch "sala aberta");
    // QA: cai de propósito (o aviso de queda na volta)
    if (env("TELINHA_TESTE_QUEDA") != null) @panic("queda de teste");
    if (crash_reason) |why| {
        log(std.fmt.bufPrint(&buf, "a última execução caiu: {s} (detalhes em ultima-queda.txt)", .{why}) catch "a última execução caiu");
        var cb: [500]u8 = undefined;
        srv.announce(std.fmt.bufPrint(&cb, "O servidor reiniciou depois de uma queda (motivo: {s}). Quem estava na sala volta sozinho.", .{why}) catch "O servidor reiniciou depois de uma queda.");
    }
    if (collect_logs) log(std.fmt.bufPrint(&buf, "coletando logs{s}: o dono pode pedir o log de quem está na sala (guardados em {s})", .{ if (require_logs) " (exigidos: vai até de quem desligou)" else "", logs_dir }) catch "coletando logs");
    if (srv.fingerprint()) |f| {
        fp_suffix[0] = '!';
        @memcpy(fp_suffix[1..], &f);
        fp_suffix_len = f.len + 1;
        log(std.fmt.bufPrint(&buf, "impressão da identidade: {s}  (no convite: telinha://ENDEREÇO:{d}!{s}#senha)", .{ &f, port, &f }) catch "");
    }
    if (admin.len == 0) log("dica: use --admin TOKEN pra poder expulsar gente e ver as estatísticas do servidor pelo app");
    if (channels.len > 0) log(std.fmt.bufPrint(&buf, "canais: {s}{s}", .{ channels, if (new_channels) " (e quem quiser cria outros)" else " (só esses)" }) catch "");
    if (public_host) |h| {
        const t = tunnel.Tunnel.start(h, srv, Server.adoptCallback) catch die("não consegui iniciar o túnel", .{});
        sync.spawn(watchTunnel, .{ t, password }) catch {};
    }
    if (use_upnp) {
        // a porta fica aberta (renovada) enquanto o servidor roda; se ele for
        // derrubado sem fechar, o roteador apaga sozinho em até 1 h
        const to, const to_port = upnp.discoveryTarget();
        const m = upnp.Mapper.start(port, to, to_port) catch die("não consegui iniciar o UPnP", .{});
        sync.spawn(watchUpnp, .{ m, password }) catch {};
        upnp_mapper = m;
    }

    if (web_port != 0) {
        srv.startWeb(web_port) catch die("não consegui abrir a porta web {d} (já está em uso?)", .{web_port});
        log(std.fmt.bufPrint(&buf, "assistir pelo navegador: http://127.0.0.1:{d} (precisa de HTTPS na frente)", .{web_port}) catch "");
        if (web_link.len > 0) {
            srv.setWebLink(web_link);
            log(std.fmt.bufPrint(&buf, "link pra assistir no navegador: {s}", .{web_link}) catch "");
        } else if (web_tunnel) {
            sync.spawn(webTunnel, .{ srv, cloudflared, web_port }) catch {};
        }
    } else if (web_tunnel or web_link.len > 0) die("--web-tunel e --web-link precisam do --web PORTA", .{});

    // estatística a cada minuto; SIGTERM/SIGINT/SIGHUP (docker stop, systemctl
    // stop, Ctrl+C) fecham direito: mata o cloudflared e apaga a porta do
    // roteador (antes: docker stop esperava 10 s e matava,
    // o cloudflared ficava órfão segurando a porta)
    var last_bytes: u64 = 0;
    // TELINHA_ATUALIZAR_TESTE: confere na hora e reinicia com 3 s de sala vazia (QA)
    const au_test = env("TELINHA_ATUALIZAR_TESTE") != null;
    var au: AutoUpdate = .{ .next_check_ms = sync.nowMs() + @as(u64, if (au_test) 0 else 5 * 60_000), .empty_ms = @as(u64, if (au_test) 3_000 else 120_000) };
    var last_stats_ms = sync.nowMs();
    while (true) {
        const sig = sigtimedwait(&sigset, null, &.{ .sec = @as(isize, if (au_test and auto_update) 1 else if (auto_update) 30 else 60), .nsec = 0 });
        if (sig > 0) {
            log(std.fmt.bufPrint(&buf, "recebi o sinal {d}: fechando a sala", .{sig}) catch "fechando");
            const tp = tunnel_pid.load(.acquire);
            if (tp > 0) _ = kill(tp, SIGTERM);
            if (upnp_mapper) |m| m.stopAndWait(2000);
            // sem srv.stop(): ele avisa "o dono fechou a sala" e o app não
            // tentaria voltar; num restart (atualização, systemctl restart) a
            // conexão só cai e todo mundo reconecta sozinho
            cleanExit();
            std.process.exit(0);
        }
        if (auto_update) au.tick(srv);
        const now_ms = sync.nowMs();
        if (now_ms -| last_stats_ms < 59_000) continue;
        const secs = @as(f64, @floatFromInt(now_ms -| last_stats_ms)) / 1000;
        last_stats_ms = now_ms;
        const total = srv.relayed_bytes.load(.monotonic);
        const n = srv.memberCount();
        var rates_buf: [512]u8 = undefined;
        const rates = srv.streamerRates(&rates_buf, secs);
        var line: [768]u8 = undefined;
        const mb = @as(f64, @floatFromInt(total - last_bytes)) / (1024 * 1024);
        const sep: []const u8 = if (rates.len > 0) "; chegando de quem transmite: " else "";
        if (n > 0) log(std.fmt.bufPrint(&line, "{d} na sala, {d:.1} MB encaminhados no último minuto{s}{s}", .{ n, mb, sep, rates }) catch "");
        last_bytes = total;
    }
}
