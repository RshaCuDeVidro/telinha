//! Preferências salvas entre execuções.
//! Linux: ~/.config/telinha/config.ini   Windows: %APPDATA%\telinha\config.ini
const std = @import("std");
const sync = @import("sync.zig");
const is_windows = sync.is_windows;

const c = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("stdio.h");
}) else @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
});

pub const Config = struct {
    name: [33]u8 = zstr("", 33),
    join_addr: [256]u8 = zstr("", 256),
    join_pass: [129]u8 = zstr("", 129),
    room_name: [65]u8 = zstr("", 65),
    host_port: i32 = 7777,
    host_pass: [129]u8 = zstr("", 129),
    fps: i32 = 30,
    quality: i32 = 60,
    mode: i32 = 0, // 0 tela/texto, 1 jogo/vídeo
    resolution: i32 = 0, // 0 original, 1 1080p, 2 720p, 3 480p
    cursor: bool = true,
    show_chat: bool = true,
    stats_always: bool = false,
    hardware: bool = true, // encoder na placa de vídeo (NVENC) quando der
    audio: bool = true, // compartilhar o som do computador junto
    admin_token: [65]u8 = zstr("", 65), // pra entrar como admin num servidor dedicado
    public_addr: [256]u8 = zstr("", 256), // endereço do túnel (pra montar o convite)
    tunnel_host: [128]u8 = zstr("bore.pub", 128), // servidor do link público (protocolo do bore)
    // voz
    mic_device: [128]u8 = zstr("", 128), // vazio = padrão do sistema
    noise_suppression: bool = true,
    echo_cancellation: bool = true, // tira do microfone o que sai da caixa de som
    voice_sensitivity: i32 = 50, // 0..100: quanto maior, mais fácil o microfone abrir
    mic_on_join: bool = false, // entrar na sala com o microfone ligado
    sounds: bool = true, // sons de aviso (entrou/saiu, ao vivo, microfone)
    /// Identifica esse app pra sala (aleatória, criada na primeira vez): é o
    /// que o banimento usa pra reconhecer quem volta.
    client_key: u64 = 0,
    notifications: bool = true, // notificação do sistema com o telinha em segundo plano
    check_updates: bool = true, // pergunta ao GitHub se tem versão nova (só com -Drepo)
    audio_app: [64]u8 = zstr("", 64), // som de um programa só ("" = tudo; "*janela" = o da janela)
    audio_exclude: [512]u8 = zstr("", 512), // "tudo" menos esses programas (separados por "|" no arquivo)
    debug_log: bool = false, // grava o log de depuração (tudo) num arquivo
    debug_send: i32 = 0, // como mandar o log: 0 = gofile.io (link), 1 = webhook
    debug_webhook: [512]u8 = zstr("", 512), // URL do webhook (Discord etc.)
    clips: bool = true, // guardar os últimos 30 s do que assiste (pra clipe)
    camera_device: [160]u8 = zstr("", 160), // vazio = a primeira câmera
    camera_res: i32 = 1, // 0 = 480p, 1 = 720p, 2 = 1080p
    language: [8]u8 = zstr("auto", 8), // idioma: "auto" (o do sistema), "pt" ou "en"
    theme: [24]u8 = zstr("escuro", 24), // tema da interface (id em theme.zig)
    auto_quality: bool = true, // transmitindo: baixa a resolução sozinho se o PC não der conta
};

fn zstr(comptime s: []const u8, comptime n: usize) [n]u8 {
    var out = [_]u8{0} ** n;
    @memcpy(out[0..s.len], s);
    return out;
}

pub fn setStr(buf: []u8, s: []const u8) void {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

pub fn getStr(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

fn openFile(write: bool) ?*c.FILE {
    return openNamed("config.ini", write);
}

/// Arquivo na pasta de configuração do telinha (criada se faltar).
/// TELINHA_PASTA_CONFIG troca a pasta inteira (testes; telinha "portátil").
/// Pasta de configuração (criada se faltar), em UTF-8: `buf` + nome de arquivo.
pub fn dirPath(buf: []u8) ?[]const u8 {
    if (is_windows) {
        var dir: [600]u16 = undefined;
        var n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("TELINHA_PASTA_CONFIG"), &dir, 500);
        const sub = std.unicode.utf8ToUtf16LeStringLiteral("\\telinha");
        if (n == 0 or n >= 500) {
            n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"), &dir, 500);
            if (n == 0 or n >= 500) return null;
            @memcpy(dir[n..][0..sub.len], sub);
            n += sub.len;
        }
        dir[n] = 0;
        _ = c.CreateDirectoryW(&dir, null);
        const len = std.unicode.utf16LeToUtf8(buf, dir[0..n]) catch return null;
        return buf[0..len];
    }
    const xdg = c.getenv("XDG_CONFIG_HOME");
    const own = c.getenv("TELINHA_PASTA_CONFIG");
    const base = if (own != null and own[0] != 0)
        std.fmt.bufPrintZ(buf, "{s}", .{std.mem.span(own)}) catch return null
    else if (xdg != null and xdg[0] != 0)
        std.fmt.bufPrintZ(buf, "{s}/telinha", .{std.mem.span(xdg)}) catch return null
    else
        std.fmt.bufPrintZ(buf, "{s}/.config/telinha", .{std.mem.span(c.getenv("HOME") orelse return null)}) catch return null;
    _ = c.mkdir(base.ptr, 0o700);
    return base;
}

fn openNamed(comptime name: []const u8, write: bool) ?*c.FILE {
    if (is_windows) {
        var dir: [600]u16 = undefined;
        var n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("TELINHA_PASTA_CONFIG"), &dir, 500);
        const sub = std.unicode.utf8ToUtf16LeStringLiteral("\\telinha");
        if (n == 0 or n >= 500) {
            n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"), &dir, 500);
            if (n == 0 or n >= 500) return null;
            @memcpy(dir[n..][0..sub.len], sub);
            n += sub.len;
        }
        dir[n] = 0;
        _ = c.CreateDirectoryW(&dir, null);
        const file = std.unicode.utf8ToUtf16LeStringLiteral("\\" ++ name);
        @memcpy(dir[n..][0..file.len], file);
        dir[n + file.len] = 0;
        const mode = if (write) std.unicode.utf8ToUtf16LeStringLiteral("wb") else std.unicode.utf8ToUtf16LeStringLiteral("rb");
        return c._wfopen(&dir, mode);
    } else {
        var path: [512]u8 = undefined;
        const xdg = c.getenv("XDG_CONFIG_HOME");
        const own = c.getenv("TELINHA_PASTA_CONFIG");
        const base = if (own != null and own[0] != 0)
            std.fmt.bufPrintZ(&path, "{s}", .{std.mem.span(own)}) catch return null
        else if (xdg != null and xdg[0] != 0)
            std.fmt.bufPrintZ(&path, "{s}/telinha", .{std.mem.span(xdg)}) catch return null
        else
            std.fmt.bufPrintZ(&path, "{s}/.config/telinha", .{std.mem.span(c.getenv("HOME") orelse return null)}) catch return null;
        _ = c.mkdir(base.ptr, 0o700);
        var full: [600]u8 = undefined;
        const p = std.fmt.bufPrintZ(&full, "{s}/" ++ name, .{base}) catch return null;
        return c.fopen(p.ptr, if (write) "wb" else "rb");
    }
}

pub fn load() Config {
    var cfg = loadFile();
    if (cfg.client_key == 0) {
        var rnd: [8]u8 = undefined;
        sync.osRandom(&rnd);
        cfg.client_key = std.mem.readInt(u64, &rnd, .little) | 1;
        save(&cfg);
    }
    return cfg;
}

fn loadFile() Config {
    var cfg: Config = .{};
    const f = openFile(false) orelse return cfg;
    defer _ = c.fclose(f);
    var line: [512]u8 = undefined;
    while (c.fgets(&line, line.len, f) != null) {
        const l = std.mem.trimEnd(u8, std.mem.sliceTo(&line, 0), "\r\n");
        const eq = std.mem.findScalar(u8, l, '=') orelse continue;
        const k = l[0..eq];
        const v = l[eq + 1 ..];
        const int = std.fmt.parseInt(i32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "name")) setStr(&cfg.name, v) else if (std.mem.eql(u8, k, "join_addr")) setStr(&cfg.join_addr, v) else if (std.mem.eql(u8, k, "join_pass")) setStr(&cfg.join_pass, v) else if (std.mem.eql(u8, k, "room_name")) setStr(&cfg.room_name, v) else if (std.mem.eql(u8, k, "host_pass")) setStr(&cfg.host_pass, v) else if (std.mem.eql(u8, k, "host_port")) cfg.host_port = std.math.clamp(int, 1, 65535) else if (std.mem.eql(u8, k, "fps")) cfg.fps = std.math.clamp(int, 1, 60) else if (std.mem.eql(u8, k, "quality")) cfg.quality = std.math.clamp(int, 20, 100) else if (std.mem.eql(u8, k, "mode")) cfg.mode = std.math.clamp(int, 0, 1) else if (std.mem.eql(u8, k, "stats_always")) cfg.stats_always = int != 0 else if (std.mem.eql(u8, k, "hardware")) cfg.hardware = int != 0 else if (std.mem.eql(u8, k, "admin_token")) setStr(&cfg.admin_token, v) else if (std.mem.eql(u8, k, "public_addr")) setStr(&cfg.public_addr, v) else if (std.mem.eql(u8, k, "resolution")) cfg.resolution = std.math.clamp(int, 0, 3) else if (std.mem.eql(u8, k, "cursor")) cfg.cursor = int != 0 else if (std.mem.eql(u8, k, "show_chat")) cfg.show_chat = int != 0 else if (std.mem.eql(u8, k, "audio")) cfg.audio = int != 0 else if (std.mem.eql(u8, k, "tunnel_host")) setStr(&cfg.tunnel_host, v) else if (std.mem.eql(u8, k, "mic_device")) setStr(&cfg.mic_device, v) else if (std.mem.eql(u8, k, "noise_suppression")) cfg.noise_suppression = int != 0 else if (std.mem.eql(u8, k, "echo_cancellation")) cfg.echo_cancellation = int != 0 else if (std.mem.eql(u8, k, "voice_sensitivity")) cfg.voice_sensitivity = std.math.clamp(int, 0, 100) else if (std.mem.eql(u8, k, "mic_on_join")) cfg.mic_on_join = int != 0 else if (std.mem.eql(u8, k, "sounds")) cfg.sounds = int != 0 else loadMore(&cfg, k, v, int);
    }
    return cfg;
}

fn loadMore(cfg: *Config, k: []const u8, v: []const u8, int: i32) void {
    if (std.mem.eql(u8, k, "client_key")) {
        cfg.client_key = std.fmt.parseInt(u64, v, 16) catch 0;
    } else if (std.mem.eql(u8, k, "notifications")) {
        cfg.notifications = int != 0;
    } else if (std.mem.eql(u8, k, "audio_app")) {
        setStr(&cfg.audio_app, v);
    } else if (std.mem.eql(u8, k, "audio_exclude")) {
        // uma linha no arquivo: "|" separa os nomes
        setStr(&cfg.audio_exclude, v);
        std.mem.replaceScalar(u8, &cfg.audio_exclude, '|', '\n');
    } else if (std.mem.eql(u8, k, "debug_log")) {
        cfg.debug_log = int != 0;
    } else if (std.mem.eql(u8, k, "debug_send")) {
        cfg.debug_send = std.math.clamp(int, 0, 1);
    } else if (std.mem.eql(u8, k, "debug_webhook")) {
        setStr(&cfg.debug_webhook, v);
    } else if (std.mem.eql(u8, k, "check_updates")) {
        cfg.check_updates = int != 0;
    } else if (std.mem.eql(u8, k, "clips")) {
        cfg.clips = int != 0;
    } else if (std.mem.eql(u8, k, "camera_device")) {
        setStr(&cfg.camera_device, v);
    } else if (std.mem.eql(u8, k, "camera_res")) {
        cfg.camera_res = std.math.clamp(int, 0, 2);
    } else if (std.mem.eql(u8, k, "language")) {
        setStr(&cfg.language, v);
    } else if (std.mem.eql(u8, k, "auto_quality")) {
        cfg.auto_quality = int != 0;
    } else if (std.mem.eql(u8, k, "theme")) {
        setStr(&cfg.theme, v);
    }
}

pub fn save(cfg: *const Config) void {
    const f = openFile(true) orelse return;
    defer _ = c.fclose(f);
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf,
        \\name={s}
        \\join_addr={s}
        \\join_pass={s}
        \\room_name={s}
        \\host_pass={s}
        \\host_port={d}
        \\fps={d}
        \\quality={d}
        \\resolution={d}
        \\cursor={d}
        \\show_chat={d}
        \\mode={d}
        \\stats_always={d}
        \\hardware={d}
        \\audio={d}
        \\admin_token={s}
        \\public_addr={s}
        \\tunnel_host={s}
        \\mic_device={s}
        \\noise_suppression={d}
        \\echo_cancellation={d}
        \\voice_sensitivity={d}
        \\mic_on_join={d}
        \\sounds={d}
        \\
    , .{
        getStr(&cfg.name),                   getStr(&cfg.join_addr),     getStr(&cfg.join_pass),        getStr(&cfg.room_name),
        getStr(&cfg.host_pass),              cfg.host_port,              cfg.fps,                       cfg.quality,
        cfg.resolution,                      @intFromBool(cfg.cursor),   @intFromBool(cfg.show_chat),   cfg.mode,
        @intFromBool(cfg.stats_always),      @intFromBool(cfg.hardware), @intFromBool(cfg.audio),       getStr(&cfg.admin_token),
        getStr(&cfg.public_addr),            getStr(&cfg.tunnel_host),   getStr(&cfg.mic_device),       @intFromBool(cfg.noise_suppression),
        @intFromBool(cfg.echo_cancellation), cfg.voice_sensitivity,      @intFromBool(cfg.mic_on_join), @intFromBool(cfg.sounds),
    }) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
    var more: [1280]u8 = undefined;
    const m = std.fmt.bufPrint(&more, "client_key={x}\nnotifications={d}\nclips={d}\ncamera_device={s}\ncamera_res={d}\ncheck_updates={d}\naudio_app={s}\nlanguage={s}\ntheme={s}\nauto_quality={d}\ndebug_log={d}\ndebug_send={d}\ndebug_webhook={s}\n", .{
        cfg.client_key, @intFromBool(cfg.notifications), @intFromBool(cfg.clips), getStr(&cfg.camera_device), cfg.camera_res, @intFromBool(cfg.check_updates), getStr(&cfg.audio_app), getStr(&cfg.language), getStr(&cfg.theme), @intFromBool(cfg.auto_quality), @intFromBool(cfg.debug_log), cfg.debug_send, getStr(&cfg.debug_webhook),
    }) catch return;
    _ = c.fwrite(m.ptr, 1, m.len, f);
    var excl: [512]u8 = cfg.audio_exclude;
    std.mem.replaceScalar(u8, &excl, '\n', '|');
    var eb: [560]u8 = undefined;
    const e = std.fmt.bufPrint(&eb, "audio_exclude={s}\n", .{getStr(&excl)}) catch return;
    _ = c.fwrite(e.ptr, 1, e.len, f);
}

/// Volume da voz de cada pessoa, lembrado pelo nome entre uma sala e outra
/// (volumes.ini: "nome<TAB>porcentagem" por linha).
pub const VoiceVolumes = struct {
    const max = 64;
    names: [max][48]u8 = undefined,
    lens: [max]usize = undefined,
    pcts: [max]u16 = undefined,
    n: usize = 0,

    /// TAB e quebra de linha separam os campos do arquivo: viram espaço.
    fn clean(raw: []const u8, buf: *[48]u8) ?[]const u8 {
        if (raw.len == 0 or raw.len > buf.len) return null;
        for (buf[0..raw.len], raw) |*d, ch| d.* = if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch;
        return buf[0..raw.len];
    }

    pub fn get(v: *const VoiceVolumes, raw_name: []const u8) ?u16 {
        var buf: [48]u8 = undefined;
        const name = clean(raw_name, &buf) orelse return null;
        for (0..v.n) |i| if (std.mem.eql(u8, v.names[i][0..v.lens[i]], name)) return v.pcts[i];
        return null;
    }

    pub fn set(v: *VoiceVolumes, raw_name: []const u8, pct: u16) void {
        var buf: [48]u8 = undefined;
        const name = clean(raw_name, &buf) orelse return;
        for (0..v.n) |i| if (std.mem.eql(u8, v.names[i][0..v.lens[i]], name)) {
            v.pcts[i] = pct;
            return;
        };
        if (pct == 100) return; // padrão: nem guarda
        const i = if (v.n < max) v.n else max - 1; // cheio: troca o último
        if (v.n < max) v.n += 1;
        @memcpy(v.names[i][0..name.len], name);
        v.lens[i] = name.len;
        v.pcts[i] = pct;
    }

    pub fn load() VoiceVolumes {
        var v: VoiceVolumes = .{};
        const f = openNamed("volumes.ini", false) orelse return v;
        defer _ = c.fclose(f);
        var line: [128]u8 = undefined;
        while (c.fgets(&line, line.len, f) != null) {
            const l = std.mem.trimEnd(u8, std.mem.sliceTo(&line, 0), "\r\n");
            const tab = std.mem.findScalarLast(u8, l, '\t') orelse continue;
            const pct = std.fmt.parseInt(u16, l[tab + 1 ..], 10) catch continue;
            v.set(l[0..tab], @min(pct, 200));
        }
        return v;
    }

    pub fn save(v: *const VoiceVolumes) void {
        const f = openNamed("volumes.ini", true) orelse return;
        defer _ = c.fclose(f);
        for (0..v.n) |i| {
            if (v.pcts[i] == 100) continue;
            var buf: [80]u8 = undefined;
            const l = std.fmt.bufPrint(&buf, "{s}\t{d}\n", .{ v.names[i][0..v.lens[i]], v.pcts[i] }) catch continue;
            _ = c.fwrite(l.ptr, 1, l.len, f);
        }
    }
};
