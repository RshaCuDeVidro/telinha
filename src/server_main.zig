//! telinha-server — servidor dedicado da sala (sem interface).
//!
//! Roda numa VPS/servidor com porta aberta (ninguém precisa de túnel), ou em
//! qualquer máquina com --publico (abre um link público pelo bore.pub).
//! Binário estático, sem dependências. Ver docs/DEPLOY.md.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const Server = @import("server.zig").Server;
const tunnel = @import("tunnel.zig");

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
    \\  --publico [SERVIDOR]   abre um link público pelo túnel (padrão bore.pub);
    \\                         sem --senha, cria uma senha aleatória
    \\  -h, --help             mostra isso
    \\
;

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
                .ready => log(std.fmt.bufPrint(&buf, "link público: {s}:{d}  —  convite: telinha://{s}:{d}#{s}", .{
                    t.hostSlice(), st.public_port, t.hostSlice(), st.public_port, password,
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
    var max: u32 = 32;
    var public_host: ?[]const u8 = null;
    if (env("TELINHA_PORTA")) |p| port = std.fmt.parseInt(u16, p, 10) catch die("TELINHA_PORTA inválida: {s}", .{p});

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
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
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--max")) {
            max = std.fmt.parseInt(u32, v, 10) catch die("número inválido: {s}", .{v});
        } else die("opção desconhecida: {s} (veja --help)", .{a});
    }

    net.init();
    var pw_buf: [8]u8 = undefined;
    if (public_host != null and password.len == 0) {
        // link público sem senha: qualquer um que achasse a porta entraria
        const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        for (&pw_buf, rnd) |*ch, r| ch.* = alphabet[r % alphabet.len];
        password = &pw_buf;
    }
    const srv = Server.start(.{ .port = port, .password = password, .room_name = room, .admin_token = admin, .max_members = max, .log = log }) catch
        die("não consegui abrir a porta {d} (já está em uso?)", .{port});

    var buf: [256]u8 = undefined;
    log(std.fmt.bufPrint(&buf, "sala \"{s}\" aberta na porta {d} (protocolo v{d}, {s}, máx. {d} pessoas)", .{
        room, port, proto.version, if (password.len > 0) "com senha" else "sem senha", max,
    }) catch "sala aberta");
    if (admin.len == 0) log("dica: use --admin TOKEN pra poder expulsar gente pelo app");
    if (public_host) |h| {
        const t = tunnel.Tunnel.start(h, srv, Server.adoptCallback) catch die("não consegui iniciar o túnel", .{});
        sync.spawn(watchTunnel, .{ t, password }) catch {};
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
