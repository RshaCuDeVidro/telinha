//! Identidades de servidor já vistas (servidores.txt na pasta de
//! configuração): "endereço impressão" por linha. Sem impressão no convite,
//! o app aceita a primeira que vê num endereço e, das próximas vezes, exige a
//! mesma (como o SSH faz). Ver crypto.Identity.
const std = @import("std");
const config = @import("config.zig");
const crypto = @import("crypto.zig");
const c = config.c;

const max_lines = 256;
const Line = struct { addr: [128]u8 = undefined, addr_len: usize = 0, fp: [crypto.fp_len]u8 = undefined };

fn load(out: []Line) usize {
    const f = config.openNamed("servidores.txt", false) orelse return 0;
    defer _ = c.fclose(f);
    var buf: [64 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    var k: usize = 0;
    while (it.next()) |raw| {
        if (k == out.len) break;
        const line = std.mem.trim(u8, raw, " \r");
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const addr = line[0..sp];
        const fp = line[sp + 1 ..];
        if (fp.len != crypto.fp_len or addr.len == 0 or addr.len > 128) continue;
        out[k] = .{};
        @memcpy(out[k].addr[0..addr.len], addr);
        out[k].addr_len = addr.len;
        @memcpy(&out[k].fp, fp);
        k += 1;
    }
    return k;
}

/// A impressão já vista em algum dos endereços da lista (separada por vírgula).
pub fn lookup(addrs: []const u8) ?[crypto.fp_len]u8 {
    var lines: [max_lines]Line = undefined;
    const n = load(&lines);
    var it = std.mem.tokenizeScalar(u8, addrs, ',');
    while (it.next()) |a| {
        const addr = std.mem.trim(u8, a, " ");
        for (lines[0..n]) |*l| if (std.mem.eql(u8, l.addr[0..l.addr_len], addr)) return l.fp;
    }
    return null;
}

/// Guarda (ou troca) a impressão de todos os endereços da lista.
pub fn remember(addrs: []const u8, fp: []const u8) void {
    if (fp.len != crypto.fp_len) return;
    var lines: [max_lines]Line = undefined;
    var n = load(&lines);
    var it = std.mem.tokenizeScalar(u8, addrs, ',');
    while (it.next()) |a| {
        const addr = std.mem.trim(u8, a, " ");
        if (addr.len == 0 or addr.len > 128) continue;
        const slot = for (lines[0..n]) |*l| {
            if (std.mem.eql(u8, l.addr[0..l.addr_len], addr)) break l;
        } else blk: {
            if (n == lines.len) {
                // cheio: sai a mais velha (a primeira)
                std.mem.copyForwards(Line, lines[0 .. n - 1], lines[1..n]);
                n -= 1;
            }
            lines[n] = .{};
            @memcpy(lines[n].addr[0..addr.len], addr);
            lines[n].addr_len = addr.len;
            n += 1;
            break :blk &lines[n - 1];
        };
        @memcpy(&slot.fp, fp);
    }
    const f = config.openNamed("servidores.txt", true) orelse return;
    defer _ = c.fclose(f);
    for (lines[0..n]) |*l| {
        var lb: [160]u8 = undefined;
        const s = std.fmt.bufPrint(&lb, "{s} {s}\n", .{ l.addr[0..l.addr_len], &l.fp }) catch continue;
        _ = c.fwrite(s.ptr, 1, s.len, f);
    }
}

/// A semente da identidade da sala hospedada neste app (servidor.key; criada
/// na primeira vez). Quem entra vê sempre a mesma impressão.
pub fn hostSeed() ?[32]u8 {
    if (config.openNamed("servidor.key", false)) |f| {
        defer _ = c.fclose(f);
        var seed: [32]u8 = undefined;
        if (c.fread(&seed, 1, 32, f) == 32) return seed;
    }
    const seed = crypto.Identity.newSeed();
    const f = config.openNamed("servidor.key", true) orelse return seed;
    _ = c.fwrite(&seed, 1, 32, f);
    _ = c.fclose(f);
    // a semente é segredo: só o dono lê
    if (!config.is_windows) {
        var b: [600]u8 = undefined;
        if (config.dirPath(b[0..512])) |d| {
            const p = std.fmt.bufPrintZ(&b, "{s}/servidor.key", .{d}) catch return seed;
            _ = c.chmod(p.ptr, 0o600);
        }
    }
    return seed;
}
