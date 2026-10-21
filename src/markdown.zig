//! Markdown do chat (o pouco que faz sentido numa conversa): blocos de código
//! entre ```, `código` no meio da frase, **negrito**, *itálico* (ou _itálico_)
//! e links http(s) clicáveis. Só separa os trechos; quem desenha é a ui.zig.
//! O texto vai pela rede como está: app antigo mostra os símbolos, e só.
const std = @import("std");

pub const Style = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    link: bool = false,
    _pad: u4 = 0,
};

pub const Span = struct { text: []const u8, style: Style };

pub const Block = union(enum) {
    text: []const u8,
    code: struct { lang: []const u8, body: []const u8 },
};

/// Tem alguma coisa pra formatar? (senão a mensagem é desenhada do jeito simples)
pub fn hasMarkup(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "`*_") != null or std.mem.indexOf(u8, text, "http") != null;
}

/// Próximo bloco a partir de `pos.*` (texto corrido ou bloco de código).
/// null = acabou. Bloco de código sem o ``` de fechar vira texto.
pub fn nextBlock(text: []const u8, pos: *usize) ?Block {
    if (pos.* >= text.len) return null;
    const rest = text[pos.*..];
    const open = std.mem.indexOf(u8, rest, "```") orelse {
        pos.* = text.len;
        return .{ .text = rest };
    };
    if (open > 0) {
        // o texto antes do bloco (sem a quebra de linha que encosta no ```)
        pos.* += open;
        return .{ .text = std.mem.trimEnd(u8, rest[0..open], "\n") };
    }
    const close_rel = std.mem.indexOf(u8, rest[3..], "```") orelse {
        pos.* = text.len;
        return .{ .text = rest };
    };
    var inner = rest[3 .. 3 + close_rel];
    var lang: []const u8 = "";
    // ```zig\n...: a primeira linha é a linguagem (uma palavra curta)
    if (std.mem.indexOfScalar(u8, inner, '\n')) |nl| {
        const first = std.mem.trim(u8, inner[0..nl], " \r");
        if (first.len <= 16 and std.mem.indexOfAny(u8, first, " \t") == null) {
            lang = first;
            inner = inner[nl + 1 ..];
        }
    }
    pos.* += 3 + close_rel + 3;
    if (pos.* < text.len and text[pos.*] == '\n') pos.* += 1;
    return .{ .code = .{ .lang = lang, .body = std.mem.trim(u8, inner, "\n\r") } };
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}

fn lineEnd(text: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
}

/// Acha o fechamento de um marcador (mesma linha, com algo dentro, sem espaço
/// colado nele por dentro). Pro "_", não fecha no meio de palavra (snake_case).
fn findClose(text: []const u8, from: usize, mark: []const u8) ?usize {
    const end = lineEnd(text, from);
    var j = from;
    while (j + mark.len <= end) : (j += 1) {
        if (!std.mem.eql(u8, text[j .. j + mark.len], mark)) continue;
        if (j == from or text[j - 1] == ' ') continue;
        if (mark.len == 1 and mark[0] == '*' and j + 1 < text.len and text[j + 1] == '*') {
            j += 1; // é um "**", não fecha o itálico
            continue;
        }
        if (mark[0] == '_' and j + mark.len < text.len and isWordChar(text[j + mark.len])) continue;
        return j;
    }
    return null;
}

/// Os trechos de um bloco de texto corrido, cada um com o seu estilo. Cabem
/// até `out.len`; o que sobrar vai junto no último, sem estilo.
pub fn spans(text: []const u8, out: []Span) usize {
    var n: usize = 0;
    var style: Style = .{};
    var italic_mark: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    const flush = struct {
        fn f(o: []Span, count: *usize, t: []const u8, st: Style) void {
            if (t.len == 0 or count.* == o.len) return;
            o[count.*] = .{ .text = t, .style = st };
            count.* += 1;
        }
    }.f;
    while (i < text.len) {
        if (n + 2 >= out.len) break;
        const ch = text[i];
        // `código`
        if (ch == '`') {
            if (std.mem.indexOfScalarPos(u8, text[0..lineEnd(text, i)], i + 1, '`')) |j| if (j > i + 1) {
                flush(out, &n, text[start..i], style);
                var cs = style;
                cs.code = true;
                flush(out, &n, text[i + 1 .. j], cs);
                i = j + 1;
                start = i;
                continue;
            };
        }
        // **negrito**
        if (ch == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (style.bold) {
                flush(out, &n, text[start..i], style);
                style.bold = false;
                i += 2;
                start = i;
                continue;
            }
            if (i + 2 < text.len and text[i + 2] != ' ' and findClose(text, i + 2, "**") != null) {
                flush(out, &n, text[start..i], style);
                style.bold = true;
                i += 2;
                start = i;
                continue;
            }
        }
        // *itálico* / _itálico_
        if ((ch == '*' or ch == '_') and !(ch == '*' and i + 1 < text.len and text[i + 1] == '*')) {
            if (style.italic and ch == italic_mark and i > 0 and text[i - 1] != ' ') {
                flush(out, &n, text[start..i], style);
                style.italic = false;
                i += 1;
                start = i;
                continue;
            }
            const word_start = i == 0 or !isWordChar(text[i - 1]);
            if (!style.italic and word_start and i + 1 < text.len and text[i + 1] != ' ' and findClose(text, i + 1, text[i .. i + 1]) != null) {
                flush(out, &n, text[start..i], style);
                style.italic = true;
                italic_mark = ch;
                i += 1;
                start = i;
                continue;
            }
        }
        // link
        if (ch == 'h' and (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\n' or text[i - 1] == '(') and
            (std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://")))
        {
            var j = i;
            while (j < text.len and text[j] != ' ' and text[j] != '\n' and text[j] != '\t') : (j += 1) {}
            // pontuação no fim não faz parte do link ("veja https://x.com.")
            while (j > i and std.mem.indexOfScalar(u8, ".,;:!?)'\"", text[j - 1]) != null) j -= 1;
            const scheme_len: usize = if (text[i + 4] == 's') 8 else 7;
            if (j > i + scheme_len) {
                flush(out, &n, text[start..i], style);
                var ls = style;
                ls.link = true;
                flush(out, &n, text[i..j], ls);
                i = j;
                start = i;
                continue;
            }
        }
        i += 1;
    }
    flush(out, &n, text[start..], if (n + 1 >= out.len) Style{} else style);
    return n;
}

const testing = std.testing;

fn expectSpans(text: []const u8, want: []const struct { []const u8, Style }) !void {
    var out: [32]Span = undefined;
    const n = spans(text, &out);
    try testing.expectEqual(want.len, n);
    for (want, out[0..n]) |w, got| {
        try testing.expectEqualStrings(w[0], got.text);
        try testing.expectEqual(w[1], got.style);
    }
}

test "markdown: código, negrito, itálico e link" {
    try expectSpans("olha `x = 1` aqui", &.{ .{ "olha ", .{} }, .{ "x = 1", .{ .code = true } }, .{ " aqui", .{} } });
    try expectSpans("isso é **muito** bom", &.{ .{ "isso é ", .{} }, .{ "muito", .{ .bold = true } }, .{ " bom", .{} } });
    try expectSpans("um *pouco* só", &.{ .{ "um ", .{} }, .{ "pouco", .{ .italic = true } }, .{ " só", .{} } });
    try expectSpans("_tá_ ok", &.{ .{ "tá", .{ .italic = true } }, .{ " ok", .{} } });
    try expectSpans("veja https://telinha.dev/x.", &.{ .{ "veja ", .{} }, .{ "https://telinha.dev/x", .{ .link = true } }, .{ ".", .{} } });
    // o que não é markdown fica como está
    try expectSpans("snake_case_aqui", &.{.{ "snake_case_aqui", .{} }});
    try expectSpans("2 * 3 * 4", &.{.{ "2 * 3 * 4", .{} }});
    try expectSpans("um ` só", &.{.{ "um ` só", .{} }});
    try expectSpans("**sem fim", &.{.{ "**sem fim", .{} }});
    try expectSpans("http:// nada", &.{.{ "http:// nada", .{} }});
}

test "markdown: blocos de código (com e sem linguagem, sem fechar vira texto)" {
    const t = "antes\n```zig\nconst x = 1;\n```\ndepois";
    var pos: usize = 0;
    try testing.expectEqualStrings("antes", nextBlock(t, &pos).?.text);
    const cb = nextBlock(t, &pos).?.code;
    try testing.expectEqualStrings("zig", cb.lang);
    try testing.expectEqualStrings("const x = 1;", cb.body);
    try testing.expectEqualStrings("depois", nextBlock(t, &pos).?.text);
    try testing.expect(nextBlock(t, &pos) == null);
    // sem linguagem, numa linha só
    pos = 0;
    const one = nextBlock("```a b c```", &pos).?.code;
    try testing.expectEqualStrings("", one.lang);
    try testing.expectEqualStrings("a b c", one.body);
    // sem fechar: texto
    pos = 0;
    try testing.expectEqualStrings("```nada", nextBlock("```nada", &pos).?.text);
    try testing.expect(!hasMarkup("só texto normal"));
    try testing.expect(hasMarkup("tem `código`"));
}
