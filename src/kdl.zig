//! Leitor de KDL (https://kdl.dev), o formato dos temas: nós com argumentos,
//! propriedades (chave=valor) e filhos entre chaves.
//!
//!     // comentário
//!     theme "pwnd" author="telinha"
//!     colors {
//!         accent "#9333EA"
//!         hover "alpha(@accent, 0.12)"
//!     }
//!     fonts ui="Atkinson Hyperlegible" size=15
//!
//! O que entra: nomes e textos sem aspas (identificadores), "textos" com
//! escapes (\n \t \" \\ \u{...}), textos crus #"..."#, números (com sinal,
//! decimal, expoente, 0x), #true/#false/#null (e true/false do KDL 1), `;`
//! ou fim de linha separando nós, \ continuando a linha, // e /* */ e o /-
//! que comenta o próximo nó, argumento ou bloco. Tudo fica numa arena: liberar
//! o documento é liberar a arena.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    null_,

    pub fn str(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    pub fn num(v: Value) ?f64 {
        return switch (v) {
            .number => |n| n,
            else => null,
        };
    }
    pub fn boolean_(v: Value) ?bool {
        return switch (v) {
            .boolean => |b| b,
            else => null,
        };
    }
};

pub const Prop = struct { key: []const u8, value: Value };

pub const Node = struct {
    name: []const u8,
    args: []const Value = &.{},
    props: []const Prop = &.{},
    children: []const Node = &.{},

    /// A última propriedade com essa chave (KDL: a última vale).
    pub fn prop(n: *const Node, key: []const u8) ?Value {
        var i = n.props.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, n.props[i].key, key)) return n.props[i].value;
        }
        return null;
    }
    pub fn propStr(n: *const Node, key: []const u8) ?[]const u8 {
        return if (n.prop(key)) |v| v.str() else null;
    }
    pub fn propNum(n: *const Node, key: []const u8) ?f64 {
        return if (n.prop(key)) |v| v.num() else null;
    }
    pub fn propBool(n: *const Node, key: []const u8) ?bool {
        return if (n.prop(key)) |v| v.boolean_() else null;
    }
    pub fn arg(n: *const Node, i: usize) ?Value {
        return if (i < n.args.len) n.args[i] else null;
    }
    pub fn argStr(n: *const Node, i: usize) ?[]const u8 {
        return if (n.arg(i)) |v| v.str() else null;
    }
    pub fn argNum(n: *const Node, i: usize) ?f64 {
        return if (n.arg(i)) |v| v.num() else null;
    }
    /// O primeiro filho com esse nome.
    pub fn child(n: *const Node, name: []const u8) ?*const Node {
        for (n.children) |*ch| if (std.mem.eql(u8, ch.name, name)) return ch;
        return null;
    }
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,

    pub fn deinit(d: *Doc) void {
        d.arena.deinit();
    }

    /// O primeiro nó do topo com esse nome.
    pub fn find(d: *const Doc, name: []const u8) ?*const Node {
        for (d.nodes) |*n| if (std.mem.eql(u8, n.name, name)) return n;
        return null;
    }
};

pub const Error = error{ Syntax, OutOfMemory, TooDeep };

/// Onde o erro aconteceu (linha começando em 1), pra mostrar pra quem escreveu o tema.
pub const Diag = struct { line: u32 = 0, msg: []const u8 = "" };

pub fn parse(gpa: std.mem.Allocator, src: []const u8, diag: ?*Diag) Error!Doc {
    var doc: Doc = .{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &.{} };
    errdefer doc.arena.deinit();
    var p: Parser = .{ .src = src, .a = doc.arena.allocator(), .diag = diag };
    // BOM do UTF-8 (editor do Windows)
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) p.i = 3;
    doc.nodes = try p.nodes(0, false);
    return doc;
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    a: std.mem.Allocator,
    diag: ?*Diag,

    fn fail(p: *Parser, msg: []const u8) Error {
        if (p.diag) |d| {
            var line: u32 = 1;
            for (p.src[0..@min(p.i, p.src.len)]) |ch| {
                if (ch == '\n') line += 1;
            }
            d.* = .{ .line = line, .msg = msg };
        }
        return error.Syntax;
    }

    fn peek(p: *Parser) u8 {
        return if (p.i < p.src.len) p.src[p.i] else 0;
    }
    fn at(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.i..], s);
    }

    /// Pula espaços e comentários; `newlines`: também as quebras de linha.
    /// Devolve se passou por alguma quebra de linha.
    fn space(p: *Parser, newlines: bool) Error!bool {
        var saw_nl = false;
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                p.i += 1;
            } else if (ch == '\n') {
                if (!newlines) break;
                saw_nl = true;
                p.i += 1;
            } else if (p.at("//")) {
                while (p.i < p.src.len and p.src[p.i] != '\n') p.i += 1;
            } else if (p.at("/*")) {
                // aninhados contam (KDL)
                var depth: usize = 0;
                while (p.i < p.src.len) {
                    if (p.at("/*")) {
                        depth += 1;
                        p.i += 2;
                    } else if (p.at("*/")) {
                        depth -= 1;
                        p.i += 2;
                        if (depth == 0) break;
                    } else p.i += 1;
                }
                if (depth != 0) return p.fail("comentário /* sem */");
            } else if (ch == '\\') {
                // continuação de linha: \ e o resto da linha (com comentário) até o \n
                p.i += 1;
                while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t' or p.src[p.i] == '\r')) p.i += 1;
                if (p.at("//")) while (p.i < p.src.len and p.src[p.i] != '\n') {
                    p.i += 1;
                };
                if (p.peek() == '\n') p.i += 1 else if (p.i < p.src.len) return p.fail("\\ no meio da linha");
            } else break;
        }
        return saw_nl;
    }

    fn nodes(p: *Parser, depth: usize, in_block: bool) Error![]const Node {
        if (depth > 32) return error.TooDeep;
        var list: std.ArrayList(Node) = .empty;
        while (true) {
            _ = try p.space(true);
            while (p.peek() == ';') {
                p.i += 1;
                _ = try p.space(true);
            }
            if (p.i >= p.src.len) {
                if (in_block) return p.fail("faltou fechar o bloco com }");
                break;
            }
            if (p.peek() == '}') {
                if (!in_block) return p.fail("} sobrando");
                p.i += 1;
                break;
            }
            var skip = false;
            if (p.at("/-")) {
                skip = true;
                p.i += 2;
                _ = try p.space(true);
            }
            const n = try p.node(depth);
            if (!skip) try list.append(p.a, n);
        }
        return list.toOwnedSlice(p.a);
    }

    fn node(p: *Parser, depth: usize) Error!Node {
        const name = try p.string();
        var args: std.ArrayList(Value) = .empty;
        var props: std.ArrayList(Prop) = .empty;
        var children: []const Node = &.{};
        while (true) {
            const nl = try p.space(false);
            _ = nl;
            const ch = p.peek();
            if (ch == 0 or ch == '\n' or ch == ';') {
                if (ch != 0) p.i += 1;
                break;
            }
            if (ch == '}') break; // fecha o bloco de cima (o nó acabou)
            var skip = false;
            if (p.at("/-")) {
                skip = true;
                p.i += 2;
                _ = try p.space(false);
            }
            if (p.peek() == '{') {
                p.i += 1;
                const kids = try p.nodes(depth + 1, true);
                if (!skip) children = kids;
                continue;
            }
            // propriedade (chave=valor) ou argumento
            const start = p.i;
            const v = try p.value();
            if (p.peek() == '=') {
                const key = switch (v) {
                    .string => |s| s,
                    else => {
                        p.i = start;
                        return p.fail("a chave de uma propriedade tem que ser um nome");
                    },
                };
                p.i += 1;
                const pv = try p.value();
                if (!skip) try props.append(p.a, .{ .key = key, .value = pv });
            } else if (!skip) try args.append(p.a, v);
        }
        return .{ .name = name, .args = try args.toOwnedSlice(p.a), .props = try props.toOwnedSlice(p.a), .children = children };
    }

    fn value(p: *Parser) Error!Value {
        const ch = p.peek();
        if (ch == '#') {
            if (p.at("#true")) {
                p.i += 5;
                return .{ .boolean = true };
            }
            if (p.at("#false")) {
                p.i += 6;
                return .{ .boolean = false };
            }
            if (p.at("#null")) {
                p.i += 5;
                return .null_;
            }
            return .{ .string = try p.string() }; // texto cru #"..."#
        }
        if (ch == '"') return .{ .string = try p.string() };
        if (std.ascii.isDigit(ch) or ((ch == '-' or ch == '+') and p.i + 1 < p.src.len and std.ascii.isDigit(p.src[p.i + 1]))) return .{ .number = try p.number() };
        const s = try p.string();
        // KDL 1: true/false/null sem #
        if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, s, "null")) return .null_;
        return .{ .string = s };
    }

    fn number(p: *Parser) Error!f64 {
        const start = p.i;
        if (p.peek() == '-' or p.peek() == '+') p.i += 1;
        if (p.at("0x") or p.at("0X")) {
            p.i += 2;
            const hs = p.i;
            while (p.i < p.src.len and (std.ascii.isHex(p.src[p.i]) or p.src[p.i] == '_')) p.i += 1;
            var buf: [32]u8 = undefined;
            var n: usize = 0;
            for (p.src[hs..p.i]) |ch| if (ch != '_' and n < buf.len) {
                buf[n] = ch;
                n += 1;
            };
            const x = std.fmt.parseInt(u64, buf[0..n], 16) catch return p.fail("número hexadecimal inválido");
            const f: f64 = @floatFromInt(x);
            return if (p.src[start] == '-') -f else f;
        }
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (std.ascii.isDigit(ch) or ch == '.' or ch == '_' or ch == 'e' or ch == 'E' or
                ((ch == '-' or ch == '+') and p.i > start and (p.src[p.i - 1] == 'e' or p.src[p.i - 1] == 'E'))) p.i += 1 else break;
        }
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (p.src[start..p.i]) |ch| if (ch != '_' and n < buf.len) {
            buf[n] = ch;
            n += 1;
        };
        return std.fmt.parseFloat(f64, buf[0..n]) catch p.fail("número inválido");
    }

    fn isIdentChar(ch: u8) bool {
        return switch (ch) {
            0...0x20, '\\', '/', '(', ')', '{', '}', ';', '[', ']', '=', '"', '#' => false,
            else => true,
        };
    }

    /// Nome ou texto: "com aspas", #"cru"#, ou identificador.
    fn string(p: *Parser) Error![]const u8 {
        const ch = p.peek();
        if (ch == '"') return p.quoted();
        if (ch == '#') {
            var hashes: usize = 0;
            while (p.peek() == '#') {
                hashes += 1;
                p.i += 1;
            }
            if (p.peek() != '"') return p.fail("texto cru sem aspas");
            p.i += 1;
            const start = p.i;
            while (p.i < p.src.len) : (p.i += 1) {
                if (p.src[p.i] != '"') continue;
                var k: usize = 0;
                while (k < hashes and p.i + 1 + k < p.src.len and p.src[p.i + 1 + k] == '#') k += 1;
                if (k == hashes) {
                    const s = p.src[start..p.i];
                    p.i += 1 + hashes;
                    return s;
                }
            }
            return p.fail("texto cru sem fim");
        }
        const start = p.i;
        while (p.i < p.src.len and isIdentChar(p.src[p.i])) p.i += 1;
        if (p.i == start) return p.fail("esperava um nome ou um valor");
        return p.src[start..p.i];
    }

    fn quoted(p: *Parser) Error![]const u8 {
        p.i += 1; // "
        const start = p.i;
        // sem escape: devolve o pedaço do texto original
        while (p.i < p.src.len and p.src[p.i] != '"' and p.src[p.i] != '\\') p.i += 1;
        if (p.i < p.src.len and p.src[p.i] == '"') {
            const s = p.src[start..p.i];
            p.i += 1;
            return s;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.a, p.src[start..p.i]);
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (ch == '"') {
                p.i += 1;
                return out.toOwnedSlice(p.a);
            }
            if (ch != '\\') {
                try out.append(p.a, ch);
                p.i += 1;
                continue;
            }
            p.i += 1;
            const e = p.peek();
            p.i += 1;
            switch (e) {
                'n' => try out.append(p.a, '\n'),
                't' => try out.append(p.a, '\t'),
                'r' => try out.append(p.a, '\r'),
                '"' => try out.append(p.a, '"'),
                '\\' => try out.append(p.a, '\\'),
                '/' => try out.append(p.a, '/'),
                'b' => try out.append(p.a, 8),
                'f' => try out.append(p.a, 12),
                's' => try out.append(p.a, ' '),
                'u' => {
                    if (p.peek() != '{') return p.fail("\\u sem {");
                    p.i += 1;
                    const hs = p.i;
                    while (p.i < p.src.len and std.ascii.isHex(p.src[p.i])) p.i += 1;
                    if (p.peek() != '}' or p.i == hs or p.i - hs > 6) return p.fail("\\u{...} inválido");
                    const cp = std.fmt.parseInt(u21, p.src[hs..p.i], 16) catch return p.fail("\\u{...} inválido");
                    p.i += 1;
                    var ub: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &ub) catch return p.fail("\\u{...} fora do Unicode");
                    try out.appendSlice(p.a, ub[0..n]);
                },
                '\n', ' ', '\t', '\r' => {
                    // escape de espaço: some com os espaços e quebras seguintes
                    while (p.i < p.src.len and std.ascii.isWhitespace(p.src[p.i])) p.i += 1;
                },
                else => return p.fail("escape desconhecido no texto"),
            }
        }
        return p.fail("texto sem as aspas do fim");
    }
};

test "kdl: nós, argumentos, propriedades, filhos e comentários" {
    const src =
        \\// tema de teste
        \\theme "pwnd" author="telinha" version=2 /- ignorado="sim"
        \\colors {
        \\    bg "#050505"; text "#E5E7EB" // dois na mesma linha
        \\    hover "alpha(@accent, 0.12)"
        \\    /- antigo "#000"
        \\    /* bloco
        \\       comentado */
        \\    accent #"#9333EA"#
        \\}
        \\fonts ui="Atkinson Hyperlegible" \
        \\      size=15.5 mono=#false neg=-2 hex=0x10
        \\/-desligado { nada }
        \\nota "linha\num" "tab\tx" "\u{2192}"
    ;
    var diag: Diag = .{};
    var doc = try parse(std.testing.allocator, src, &diag);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 4), doc.nodes.len);
    const t = doc.find("theme").?;
    try std.testing.expectEqualStrings("pwnd", t.argStr(0).?);
    try std.testing.expectEqualStrings("telinha", t.propStr("author").?);
    try std.testing.expectEqual(@as(f64, 2), t.propNum("version").?);
    try std.testing.expect(t.prop("ignorado") == null);
    const colors = doc.find("colors").?;
    try std.testing.expectEqual(@as(usize, 4), colors.children.len);
    try std.testing.expectEqualStrings("#050505", colors.child("bg").?.argStr(0).?);
    try std.testing.expectEqualStrings("#E5E7EB", colors.child("text").?.argStr(0).?);
    try std.testing.expectEqualStrings("alpha(@accent, 0.12)", colors.child("hover").?.argStr(0).?);
    try std.testing.expectEqualStrings("#9333EA", colors.child("accent").?.argStr(0).?);
    try std.testing.expect(colors.child("antigo") == null);
    const f = doc.find("fonts").?;
    try std.testing.expectEqualStrings("Atkinson Hyperlegible", f.propStr("ui").?);
    try std.testing.expectEqual(@as(f64, 15.5), f.propNum("size").?);
    try std.testing.expectEqual(false, f.propBool("mono").?);
    try std.testing.expectEqual(@as(f64, -2), f.propNum("neg").?);
    try std.testing.expectEqual(@as(f64, 16), f.propNum("hex").?);
    try std.testing.expect(doc.find("desligado") == null);
    const nota = doc.find("nota").?;
    try std.testing.expectEqualStrings("linha\num", nota.argStr(0).?);
    try std.testing.expectEqualStrings("tab\tx", nota.argStr(1).?);
    try std.testing.expectEqualStrings("→", nota.argStr(2).?);
}

test "kdl: erros dizem a linha; lixo não quebra" {
    var diag: Diag = .{};
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a {\n b 1\n", &diag));
    try std.testing.expect(diag.line >= 2);
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a \"sem fim", &diag));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "}", &diag));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a 1=2", &diag));
    // nada de travar ou estourar com entrada estranha
    const junk = [_][]const u8{ "", "\n\n", "/* ", "a /- ", "a \\ b", "#", "a #\"x", "\xEF\xBB\xBFtema", "a \"\\u{110000}\"", "{{{{" };
    for (junk) |j| {
        var d = parse(std.testing.allocator, j, null) catch continue;
        d.deinit();
    }
    var deep: [200]u8 = undefined;
    for (0..100) |k| {
        deep[k * 2] = 'a';
        deep[k * 2 + 1] = '{';
    }
    try std.testing.expectError(error.TooDeep, parse(std.testing.allocator, &deep, null));
}
