//! telinha-server — servidor dedicado da sala (sem interface).
//!
//! Roda numa VPS/servidor com porta aberta: ninguém precisa de túnel.
//! Binário estático, sem dependências. Ver docs/DEPLOY.md.
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const proto = @import("proto.zig");
const Server = @import("server.zig").Server;

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
    if (env("TELINHA_PORTA")) |p| port = std.fmt.parseInt(u16, p, 10) catch die("TELINHA_PORTA inválida: {s}", .{p});

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
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
    const srv = Server.start(.{ .port = port, .password = password, .room_name = room, .admin_token = admin, .max_members = max, .log = log }) catch
        die("não consegui abrir a porta {d} (já está em uso?)", .{port});

    var buf: [256]u8 = undefined;
    log(std.fmt.bufPrint(&buf, "sala \"{s}\" aberta na porta {d} (protocolo v{d}, {s}, máx. {d} pessoas)", .{
        room, port, proto.version, if (password.len > 0) "com senha" else "sem senha", max,
    }) catch "sala aberta");
    if (admin.len == 0) log("dica: use --admin TOKEN pra poder expulsar gente pelo app");

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
