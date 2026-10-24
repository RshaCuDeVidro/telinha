//! Comparar nomes sem ligar pra maiúscula nem acento ("musica" acha "Música").
const std = @import("std");

/// A letra sem acento e minúscula (só o Latin-1, que é o que aparece nos nomes).
fn base(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xC5, 0xE0...0xE5 => 'a',
        0xC7, 0xE7 => 'c',
        0xC8...0xCB, 0xE8...0xEB => 'e',
        0xCC...0xCF, 0xEC...0xEF => 'i',
        0xD1, 0xF1 => 'n',
        0xD2...0xD6, 0xF2...0xF6 => 'o',
        0xD9...0xDC, 0xF9...0xFC => 'u',
        0xDD, 0xFD, 0xFF => 'y',
        else => cp,
    };
}

/// Próxima letra de `s` a partir de `i` (byte inválido vale ele mesmo).
fn next(s: []const u8, i: *usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[i.*]) catch 1;
    if (i.* + n <= s.len) if (std.unicode.utf8Decode(s[i.* .. i.* + n])) |cp| {
        i.* += n;
        return base(cp);
    } else |_| {};
    i.* += 1;
    return s[i.* - 1];
}

/// Se `text` começa com `name` (sem maiúscula nem acento), quantos bytes de
/// `text` isso ocupa; senão null.
pub fn prefix(text: []const u8, name: []const u8) ?usize {
    var i: usize = 0;
    var j: usize = 0;
    while (j < name.len) {
        if (i >= text.len) return null;
        if (next(text, &i) != next(name, &j)) return null;
    }
    return i;
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return if (prefix(a, b)) |n| n == a.len else false;
}

test "nomes sem acento nem maiúscula" {
    try std.testing.expectEqual(@as(?usize, 6), prefix("musica !join", "Música"));
    try std.testing.expectEqual(@as(?usize, 7), prefix("MÚSICA oi", "musica"));
    try std.testing.expectEqual(@as(?usize, null), prefix("mus", "Música"));
    try std.testing.expectEqual(@as(?usize, null), prefix("massa", "Música"));
    try std.testing.expect(eql("joao", "João"));
    try std.testing.expect(!eql("joaoo", "João"));
    try std.testing.expect(eql("", ""));
}
