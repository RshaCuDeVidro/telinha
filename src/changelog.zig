//! CHANGELOG em pedaços: as seções "## X.Y.Z" (a mais nova primeiro), o que
//! muda entre duas versões (o aviso de atualização e as novidades depois de
//! atualizar) e as linhas de cada seção pro histórico. O texto do próprio app
//! vem embutido (build.zig: changelog_pt / changelog_en); o da versão nova vem
//! anexado à release.
const std = @import("std");
const update = @import("update.zig");

pub const Section = struct {
    title: []const u8, // "3.1.0", "Ainda não lançada"
    body: []const u8, // sem a linha do título
};

/// Seções na ordem do arquivo. Chame `next` até dar null.
pub const Iter = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *Iter) ?Section {
        const start = findHeader(it.text, it.pos) orelse return null;
        const title_end = std.mem.indexOfScalarPos(u8, it.text, start, '\n') orelse it.text.len;
        const body_start = @min(it.text.len, title_end + 1);
        const end = findHeader(it.text, body_start) orelse it.text.len;
        it.pos = end;
        return .{
            .title = std.mem.trim(u8, it.text[start + 3 .. title_end], " \r"),
            .body = std.mem.trim(u8, it.text[body_start..end], "\r\n"),
        };
    }
};

/// Começo da próxima linha "## " (não "### ") a partir de `from`.
fn findHeader(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        if (std.mem.startsWith(u8, text[i..line_end], "## ")) return i;
        i = line_end + 1;
    }
    return null;
}

/// Tem alguma seção "## "?
pub fn hasSections(text: []const u8) bool {
    return findHeader(text, 0) != null;
}

/// É título de versão ("3.1.0", não "Ainda não lançada")?
pub fn isVersion(title: []const u8) bool {
    return title.len > 0 and std.ascii.isDigit(title[0]) and update.isNewer(title, "0.0.0");
}

/// O trecho com as seções das versões mais novas que `after` e até `upto`
/// (inclusive), do jeito que está no arquivo (títulos "## " incluídos).
/// "" se não tiver nenhuma.
pub fn between(text: []const u8, after: []const u8, upto: []const u8) []const u8 {
    var it: Iter = .{ .text = text };
    var first: ?usize = null;
    var last_end: usize = 0;
    while (true) {
        const at = findHeader(text, it.pos) orelse break;
        const s = it.next() orelse break;
        if (!isVersion(s.title)) continue;
        const in_range = update.isNewer(s.title, after) and !update.isNewer(s.title, upto);
        if (in_range) {
            if (first == null) first = at;
            last_end = it.pos;
        } else if (first != null) break;
    }
    const f = first orelse return "";
    return std.mem.trimEnd(u8, text[f..last_end], "\r\n");
}

/// Só a seção de uma versão (título incluído); "" se não tiver.
pub fn section(text: []const u8, ver: []const u8) []const u8 {
    var it: Iter = .{ .text = text };
    while (true) {
        const at = findHeader(text, it.pos) orelse return "";
        const s = it.next() orelse return "";
        if (isVersion(s.title) and !update.isNewer(s.title, ver) and !update.isNewer(ver, s.title))
            return std.mem.trimEnd(u8, text[at..it.pos], "\r\n");
    }
}

/// Uma linha da seção pra desenhar.
pub const Line = union(enum) {
    sub: []const u8, // "### Destaques"
    bullet: []const u8, // "- texto" (as continuações já juntas)
    para: []const u8, // texto solto
    gap,
};

/// Linhas de uma seção. As continuações de um item (linhas que começam com
/// espaço) vêm juntas num pedaço só; `scratch` guarda o texto juntado.
pub const LineIter = struct {
    body: []const u8,
    pos: usize = 0,
    scratch: []u8,

    pub fn next(it: *LineIter) ?Line {
        while (it.pos < it.body.len) {
            const end = std.mem.indexOfScalarPos(u8, it.body, it.pos, '\n') orelse it.body.len;
            const raw = std.mem.trimEnd(u8, it.body[it.pos..end], "\r");
            it.pos = @min(it.body.len, end + 1);
            const line = std.mem.trim(u8, raw, " ");
            if (line.len == 0) return .gap;
            // marcador do resumo das notas, links de idioma: não aparecem
            if (std.mem.startsWith(u8, line, "<!--") or std.mem.startsWith(u8, line, "<sub>")) continue;
            if (std.mem.startsWith(u8, line, "### ")) return .{ .sub = line[4..] };
            const is_bullet = std.mem.startsWith(u8, line, "- ");
            // junta as continuações (indentadas) num texto só
            var n: usize = 0;
            const first = if (is_bullet) line[2..] else line;
            n = append(it.scratch, n, first);
            while (it.pos < it.body.len) {
                const e2 = std.mem.indexOfScalarPos(u8, it.body, it.pos, '\n') orelse it.body.len;
                const nxt = std.mem.trimEnd(u8, it.body[it.pos..e2], "\r");
                const t = std.mem.trim(u8, nxt, " ");
                if (t.len == 0 or nxt[0] != ' ' or std.mem.startsWith(u8, t, "- ")) break;
                n = append(it.scratch, n, " ");
                n = append(it.scratch, n, t);
                it.pos = @min(it.body.len, e2 + 1);
            }
            const joined = it.scratch[0..n];
            return if (is_bullet) .{ .bullet = joined } else .{ .para = joined };
        }
        return null;
    }
};

fn append(buf: []u8, n: usize, s: []const u8) usize {
    const k = @min(s.len, buf.len - n);
    @memcpy(buf[n .. n + k], s[0..k]);
    return n + k;
}

const testing = std.testing;

const sample =
    \\# Changelog
    \\
    \\<sub>[en](CHANGELOG.md)</sub>
    \\
    \\## Ainda não lançada
    \\
    \\- coisa nova
    \\
    \\## 3.2.0
    \\
    \\### Destaques
    \\
    \\- **Atualizador**: baixa e troca
    \\  o executável sozinho.
    \\- outra
    \\
    \\## 3.1.0
    \\
    \\Conversa com a 3.0.
    \\
    \\- três um
    \\
    \\## 3.0.0
    \\
    \\- três
;

test "changelog: seções na ordem, com e sem versão" {
    var it: Iter = .{ .text = sample };
    const a = it.next().?;
    try testing.expectEqualStrings("Ainda não lançada", a.title);
    try testing.expect(!isVersion(a.title));
    try testing.expectEqualStrings("- coisa nova", a.body);
    try testing.expectEqualStrings("3.2.0", it.next().?.title);
    try testing.expectEqualStrings("3.1.0", it.next().?.title);
    const z = it.next().?;
    try testing.expectEqualStrings("3.0.0", z.title);
    try testing.expectEqualStrings("- três", z.body);
    try testing.expect(it.next() == null);
}

test "changelog: o que muda entre duas versões" {
    // de 3.0.0 pra 3.2.0: as duas seções (sem a "Ainda não lançada")
    const b = between(sample, "3.0.0", "v3.2.0");
    try testing.expect(std.mem.startsWith(u8, b, "## 3.2.0"));
    try testing.expect(std.mem.indexOf(u8, b, "## 3.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, b, "## 3.0.0") == null);
    try testing.expect(std.mem.endsWith(u8, b, "- três um"));
    // uma só
    const c = between(sample, "3.1.0", "3.2.0");
    try testing.expect(std.mem.startsWith(u8, c, "## 3.2.0"));
    try testing.expect(std.mem.indexOf(u8, c, "3.1.0") == null);
    // nada novo
    try testing.expectEqualStrings("", between(sample, "3.2.0", "3.2.0"));
}

test "changelog: uma seção só" {
    const s = section(sample, "v3.1.0");
    try testing.expect(std.mem.startsWith(u8, s, "## 3.1.0"));
    try testing.expect(std.mem.endsWith(u8, s, "- três um"));
    try testing.expectEqualStrings("", section(sample, "9.9.9"));
}

test "changelog: os embutidos no app têm a seção da versão do build" {
    const ver = @import("proto.zig").app_version;
    for ([_][]const u8{ @embedFile("changelog_pt"), @embedFile("changelog_en") }) |text| {
        try testing.expect(section(text, ver).len > 0);
    }
}

test "changelog: linhas (itens com continuação juntos, subtítulos, sem os marcadores)" {
    var it: Iter = .{ .text = sample };
    _ = it.next();
    const s = it.next().?;
    var scratch: [512]u8 = undefined;
    var li: LineIter = .{ .body = s.body, .scratch = &scratch };
    try testing.expectEqualStrings("Destaques", li.next().?.sub);
    try testing.expect(li.next().? == .gap);
    try testing.expectEqualStrings("**Atualizador**: baixa e troca o executável sozinho.", li.next().?.bullet);
    try testing.expectEqualStrings("outra", li.next().?.bullet);
    try testing.expect(li.next() == null);
}
