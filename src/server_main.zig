//! telinha-server — servidor dedicado da sala (sem interface).
//!
//! Roda numa VPS/servidor com porta aberta (ninguém precisa de túnel), ou em
//! qualquer máquina com --publico (abre um link público pelo bore.pub) ou
//! --upnp (pede pro roteador abrir a porta: conexão direta).
//! Binário estático, sem dependências. Ver docs/DEPLOY.md.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const Server = @import("server.zig").Server;
const tunnel = @import("tunnel.zig");
const upnp = @import("upnp.zig");
const crypto = @import("crypto.zig");

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
    \\  -e, --estado ARQUIVO   onde guardar o que sobrevive a reiniciar: canais
    \\                         fixos (senha, trava, tópico), banidos, silenciados
    \\                         ($TELINHA_ESTADO; padrão: do lado da --chave)
    \\  -k, --chave ARQUIVO    a identidade do servidor ($TELINHA_CHAVE; criada na
    \\                         primeira vez). Padrão: /var/lib/telinha/servidor.key
    \\                         (root) ou ~/.config/telinha/servidor.key. A impressão
    \\                         vai no convite (telinha://...!impressão) e o app
    \\                         confere que é mesmo este servidor
    \\  --publico [SERVIDOR]   abre um link público pelo túnel (padrão bore.pub);
    \\                         sem --senha, cria uma senha aleatória
    \\  --upnp                 pede pro roteador abrir a porta (UPnP): conexão
    \\                         direta, sem túnel; também cria senha se não tiver
    \\  -h, --help             mostra isso
    \\
;

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getuid() c_uint;
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
    const t = sync.localTime();
    std.debug.print("[{d:0>2}:{d:0>2}] {s}\n", .{ t.h, t.m, msg });
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
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
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: u16 = 7777;
    var password: []const u8 = env("TELINHA_SENHA") orelse "";
    var room: []const u8 = env("TELINHA_NOME") orelse "telinha";
    var admin: []const u8 = env("TELINHA_ADMIN") orelse "";
    var logs_dir: []const u8 = env("TELINHA_LOGS") orelse "";
    var max: u32 = 32;
    var channels: []const u8 = env("TELINHA_CANAIS") orelse "";
    var new_channels = true;
    var key_path: []const u8 = env("TELINHA_CHAVE") orelse "";
    var state_path: []const u8 = env("TELINHA_ESTADO") orelse "";
    var public_host: ?[]const u8 = null;
    var use_upnp = false;
    if (env("TELINHA_PORTA")) |p| port = std.fmt.parseInt(u16, p, 10) catch die("TELINHA_PORTA inválida: {s}", .{p});

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (std.mem.eql(u8, a, "--upnp")) {
            use_upnp = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--sem-canais-novos")) {
            new_channels = false;
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
        } else if (std.mem.eql(u8, a, "-k") or std.mem.eql(u8, a, "--chave")) {
            key_path = v;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--canais")) {
            channels = v;
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--max")) {
            max = std.fmt.parseInt(u32, v, 10) catch die("número inválido: {s}", .{v});
        } else die("opção desconhecida: {s} (veja --help)", .{a});
    }

    net.init();
    var pw_buf: [8]u8 = undefined;
    if ((public_host != null or use_upnp) and password.len == 0) {
        // endereço público sem senha: qualquer um que achasse a porta entraria
        const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        for (&pw_buf, rnd) |*ch, r| ch.* = alphabet[r % alphabet.len];
        password = &pw_buf;
    }
    if (logs_dir.len > 0) {
        var lb: [300]u8 = undefined;
        const z = std.fmt.bufPrintZ(&lb, "{s}", .{logs_dir}) catch die("pasta de logs longa demais", .{});
        _ = mkdir(z.ptr, 0o750);
    }
    const srv = Server.start(.{ .port = port, .password = password, .room_name = room, .admin_token = admin, .max_members = max, .log = log, .logs_dir = logs_dir, .channels = channels, .new_channels = new_channels, .identity_seed = loadKey(key_path, &key_used), .state_path = statePath(state_path, key_used[0..key_used_len]) }) catch
        die("não consegui abrir a porta {d} (já está em uso?)", .{port});

    var buf: [256]u8 = undefined;
    log(std.fmt.bufPrint(&buf, "sala \"{s}\" aberta na porta {d} (protocolo v{d}, {s}, máx. {d} pessoas)", .{
        room, port, proto.version, if (password.len > 0) "com senha" else "sem senha", max,
    }) catch "sala aberta");
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
    }

    // estatística a cada minuto
    var last_bytes: u64 = 0;
    while (true) {
        sync.sleepMs(60_000);
        const total = srv.relayed_bytes.load(.monotonic);
        const n = srv.memberCount();
        if (n > 0) log(std.fmt.bufPrint(&buf, "{d} na sala, {d:.1} MB encaminhados no último minuto", .{
            n, @as(f64, @floatFromInt(total - last_bytes)) / (1024 * 1024),
        }) catch "");
        last_bytes = total;
    }
}
