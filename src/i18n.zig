//! Idioma da interface. O texto do código é em português; a tabela no fim
//! dá o inglês de cada frase. `tr("...")`, `bufPrint`/`bufPrintZ` procuram a
//! frase na tabela em tempo de compilação: frase sem tradução não compila
//! (o erro diz qual é). "##id" e "###id" do ImGui ficam de fora da busca e
//! voltam iguais nos dois idiomas (o ID não muda com o idioma).
const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

pub const Lang = enum(u8) { pt, en };

var current = std.atomic.Value(Lang).init(.pt);

pub fn get() Lang {
    return current.load(.monotonic);
}

pub fn set(l: Lang) void {
    current.store(l, .monotonic);
}

pub fn english() bool {
    return get() == .en;
}

/// Idioma ao abrir: TELINHA_IDIOMA (pt/en, testes) manda mais que a configuração.
pub fn init(cfg: []const u8) void {
    var buf: [16]u8 = undefined;
    const env = getEnv("TELINHA_IDIOMA", &buf);
    set(if (parse(env)) |l| l else resolve(cfg));
}

/// "pt", "en" ou "auto" (= o do sistema).
pub fn resolve(cfg: []const u8) Lang {
    return parse(cfg) orelse systemLang();
}

fn parse(s: []const u8) ?Lang {
    if (std.ascii.eqlIgnoreCase(s, "pt")) return .pt;
    if (std.ascii.eqlIgnoreCase(s, "en")) return .en;
    return null;
}

/// Português se o sistema estiver em português; senão inglês.
pub fn systemLang() Lang {
    if (is_windows) {
        // LANG_PORTUGUESE = 0x16 (idioma primário: os 10 bits de baixo)
        return if (GetUserDefaultUILanguage() & 0x3ff == 0x16) .pt else .en;
    }
    var buf: [64]u8 = undefined;
    inline for ([_][:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        const v = getEnv(name, &buf);
        if (v.len > 0) return localeLang(v);
    }
    return .en;
}

/// "pt_BR.UTF-8" → pt; "C", "en_US"... → en.
pub fn localeLang(locale: []const u8) Lang {
    return if (std.ascii.startsWithIgnoreCase(locale, "pt")) .pt else .en;
}

extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Variável de ambiente (só ASCII; "" se não tiver).
fn getEnv(comptime name: [:0]const u8, buf: []u8) []const u8 {
    if (is_windows) {
        var w: [64]u16 = undefined;
        const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &w, w.len);
        if (n == 0 or n >= w.len or n > buf.len) return "";
        for (w[0..n], buf[0..n]) |ch, *o| o.* = if (ch < 128) @intCast(ch) else '?';
        return buf[0..n];
    }
    const v = std.mem.span(getenv(name) orelse return "");
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Tradução

/// Texto da tela: o português, ou o inglês da tabela.
pub fn tr(comptime pt: [:0]const u8) [:0]const u8 {
    const en = comptime translate(pt);
    return if (english()) en else pt;
}

/// std.fmt.bufPrint com o formato traduzido.
pub fn bufPrint(buf: []u8, comptime pt: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    const en = comptime translate(pt);
    return if (english()) std.fmt.bufPrint(buf, en, args) else std.fmt.bufPrint(buf, pt, args);
}

pub fn bufPrintZ(buf: []u8, comptime pt: []const u8, args: anytype) std.fmt.BufPrintError![:0]u8 {
    const en = comptime translate(pt);
    return if (english()) std.fmt.bufPrintZ(buf, en, args) else std.fmt.bufPrintZ(buf, pt, args);
}

/// Tem palavra pra traduzir? (duas letras seguidas fora dos {} do formato)
fn hasWords(comptime s: []const u8) bool {
    var depth: usize = 0;
    var run: usize = 0;
    for (s) |ch| {
        if (ch == '{') depth += 1 else if (ch == '}' and depth > 0) depth -= 1;
        if (depth == 0 and std.ascii.isAlphabetic(ch)) {
            run += 1;
            if (run >= 2) return true;
        } else run = 0;
    }
    return false;
}

fn translate(comptime pt: []const u8) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        const cut = std.mem.indexOf(u8, pt, "##") orelse pt.len;
        const text = pt[0..cut];
        const id = pt[cut..];
        // procura sempre (ex.: "30 q/s" → "30 fps" não tem duas letras
        // seguidas, mas tem tradução); só exige entrada quando tem palavra
        for (table) |p| {
            if (std.mem.eql(u8, p[0], text)) return std.fmt.comptimePrint("{s}{s}", .{ p[1], id });
        }
        if (!hasWords(text)) return std.fmt.comptimePrint("{s}", .{pt});
        @compileError("i18n: falta a tradução em src/i18n.zig: .{ \"" ++ text ++ "\", \"...\" },");
    }
}

/// Frase da tabela (tempo de execução; textos que chegam prontos, do C).
pub fn lookup(text: []const u8) ?[]const u8 {
    for (table) |p| if (std.mem.eql(u8, p[0], text)) return p[1];
    return null;
}

/// Texto pronto (mensagens de erro do código C, nomes das fontes de captura):
/// a frase inteira ou o começo dela (até ":", " (" etc.) se estiver na tabela.
pub fn dynamic(text: []const u8, buf: []u8) []const u8 {
    if (!english()) return text;
    if (lookup(text)) |en| return en;
    var best: ?[2][]const u8 = null;
    for (table) |p| {
        const k = p[0];
        if (k.len < 4 or k.len >= text.len or !std.mem.startsWith(u8, text, k)) continue;
        if (std.mem.indexOfScalar(u8, ":( ;,.", text[k.len]) == null) continue;
        if (best == null or k.len > best.?[0].len) best = p;
    }
    const p = best orelse return text;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ p[1], text[p[0].len..] }) catch text;
}

// ---------------------------------------------------------------------------
// Textos que o servidor manda prontos (em português): traduz aqui, na tela de
// quem recebe, sem mudar o protocolo.

/// "<nome> <frase>" (nome na frente).
const Suffix = struct { []const u8, []const u8 };
const server_suffixes = [_]Suffix{
    .{ " entrou na sala", "{s} joined the room" },
    .{ " saiu da sala", "{s} left the room" },
    .{ " ligou a câmera", "{s} turned on their camera" },
    .{ " começou a transmitir", "{s} started streaming" },
    .{ " destrancou a sala", "{s} unlocked the room" },
    .{ " trancou a sala", "{s} locked the room" },
    .{ " baniu você da sala.", "{s} banned you from the room." },
    .{ " expulsou você da sala.", "{s} kicked you out of the room." },
    .{ " silenciou seu microfone.", "{s} muted your microphone." },
    .{ " liberou seu microfone.", "{s} unmuted your microphone." },
    .{ " parou sua câmera.", "{s} stopped your camera." },
    .{ " parou sua transmissão.", "{s} stopped your stream." },
    .{ " te deu admin na sala.", "{s} made you a room admin." },
    .{ " tirou seu admin.", "{s} removed your admin rights." },
};
/// "<quem> <verbo> <quem>".
const server_infixes = [_]Suffix{
    .{ " baniu ", "{s} banned {s}" },
    .{ " expulsou ", "{s} kicked {s} out" },
};
const server_whole = [_]Suffix{
    .{ "O dono fechou a sala.", "The owner closed the room." },
    .{ "O link público da sala foi desligado.", "The room's public link was turned off." },
    .{ "Você foi removido da sala.", "You were removed from the room." },
    .{ "Você foi banido dessa sala.", "You are banned from this room." },
    .{ "Você continua silenciado pelo admin.", "The admin still has you muted." },
    .{ "Entrando e saindo rápido demais: espera uns segundos e tenta de novo.", "Joining and leaving too fast: wait a few seconds and try again." },
    .{ "A sala está trancada: ninguém novo entra agora.", "The room is locked: no one new can join right now." },
    .{ "A sala está cheia.", "The room is full." },
};

/// Mensagem do servidor (chat do sistema, motivo de recusa, aviso do admin).
pub fn server(text: []const u8, buf: []u8) []const u8 {
    if (!english()) return text;
    for (server_whole) |p| if (std.mem.eql(u8, text, p[0])) return p[1];
    inline for (server_suffixes) |p| {
        if (text.len > p[0].len and std.mem.endsWith(u8, text, p[0]))
            return std.fmt.bufPrint(buf, p[1], .{text[0 .. text.len - p[0].len]}) catch text;
    }
    inline for (server_infixes) |p| {
        if (std.mem.indexOf(u8, text, p[0])) |i| if (i > 0 and i + p[0].len < text.len)
            return std.fmt.bufPrint(buf, p[1], .{ text[0..i], text[i + p[0].len ..] }) catch text;
    }
    return text;
}

// ---------------------------------------------------------------------------
// Tabela: português → inglês. Uma frase por linha; a mesma frase usada em
// vários lugares aparece uma vez só.

const table = [_][2][]const u8{
    // tela inicial
    .{ "compartilha a tela com a galera", "share your screen with friends" },
    .{ "Entrar numa sala", "Join a room" },
    .{ "Criar sala", "Create room" },
    .{ "SEU NOME", "YOUR NAME" },
    .{ "como a galera vai te ver", "how others will see you" },
    .{ "ENDEREÇO DA SALA", "ROOM ADDRESS" },
    .{ "ex.: 0.tcp.sa.ngrok.io:12345 ou o convite telinha://...", "e.g. 0.tcp.sa.ngrok.io:12345 or the telinha://... invite" },
    .{ "Convite colado da área de transferência. É só clicar em Entrar.", "Invite pasted from the clipboard. Just click Join." },
    .{ "SENHA", "PASSWORD" },
    .{ "senha da sala", "room password" },
    .{ "Opções avançadas  {s}", "Advanced options  {s}" },
    .{ "TOKEN DE ADMIN (só em servidor dedicado)", "ADMIN TOKEN (dedicated server only)" },
    .{ "deixe vazio se não souber o que é", "leave empty if you don't know what this is" },
    .{ "Entrar", "Join" },
    .{ "NOME DA SALA", "ROOM NAME" },
    .{ "ex.: Sala do Gabriel", "e.g. Gabriel's room" },
    .{ "PORTA", "PORT" },
    .{ "vazio = sem senha", "empty = no password" },
    .{ "Pra galera de fora entrar, abre um túnel TCP pra essa porta (ngrok tcp, bore, playit...) e manda o endereço que ele mostrar.", "For people outside your network to join, open a TCP tunnel to this port (ngrok tcp, bore, playit...) and send them the address it shows." },
    .{ "{s}  telinha {s} saiu (você tem o {s})", "{s}  telinha {s} is out (you have {s})" },
    .{ "Baixar", "Download" },
    .{ "anônimo", "anonymous" },
    .{ "Põe o endereço com a porta. Ex.: 0.tcp.sa.ngrok.io:12345 (ou cola o convite).", "Enter the address with the port. E.g. 0.tcp.sa.ngrok.io:12345 (or paste the invite)." },
    .{ "Endereço inválido. Ex.: 0.tcp.sa.ngrok.io:12345 (IPv6 entre colchetes: [2804::1]:7777)", "Invalid address. E.g. 0.tcp.sa.ngrok.io:12345 (IPv6 in brackets: [2804::1]:7777)" },
    .{ "Endereço inválido.", "Invalid address." },
    .{ "Porta inválida.", "Invalid port." },
    .{ "Não consegui abrir essa porta. Já tem outra coisa usando? Tenta outra.", "Couldn't open that port. Is something else using it? Try another one." },
    .{ "Sala do {s}", "{s}'s room" },
    .{ "Não consegui reconectar na sala.", "Couldn't reconnect to the room." },

    // conectando / caiu
    .{ "Reconectando em {s}... (tentativa {d} de {d})", "Reconnecting to {s}... (attempt {d} of {d})" },
    .{ "Conectando em {s}...", "Connecting to {s}..." },
    .{ "{d} caminhos", "{d} routes" },
    .{ "Cancelar", "Cancel" },
    .{ "Tentando de novo em {d:.0} s... (tentativa {d} de {d})", "Trying again in {d:.0} s... (attempt {d} of {d})" },
    .{ "Tentar agora", "Try now" },
    .{ "Sair", "Leave" },
    .{ "Voltar ao início", "Back to start" },
    .{ "Reconectar", "Reconnect" },
    .{ "Reconectado!", "Reconnected!" },

    // erros da conexão (client.zig)
    .{ "anterior", "older" },
    .{ "Não achei esse endereço.", "Couldn't find that address." },
    .{ "Conexão recusada. A sala está aberta? O túnel está ligado?", "Connection refused. Is the room open? Is the tunnel on?" },
    .{ "Não consegui conectar (a sala não respondeu por nenhum caminho).", "Couldn't connect (the room didn't answer on any route)." },
    .{ "A sala está numa versão mais nova do telinha (protocolo {d}; o seu {s} usa o {d}). Atualize o seu telinha.", "The room is on a newer version of telinha (protocol {d}; your {s} uses {d}). Update your telinha." },
    .{ "A sala está numa versão mais velha do telinha ({s}). Quem criou a sala precisa atualizar pro {s} ou mais novo.", "The room is on an older version of telinha ({s}). Whoever created the room needs to update to {s} or newer." },
    .{ "Isso não é uma sala do telinha.", "This is not a telinha room." },
    .{ "Falha no handshake.", "Handshake failed." },
    .{ "Falha ao criar thread.", "Couldn't create a thread." },
    .{ "Senha errada.", "Wrong password." },
    .{ "A conexão com a sala caiu.", "The connection to the room dropped." },

    // fechar a sala
    .{ "Fechar a sala", "Close the room" },
    .{ "Fechar a sala?", "Close the room?" },
    .{ "A sala é sua: fechando, a pessoa que está aqui sai da sala (e fica sabendo que você fechou).", "It's your room: if you close it, the person here leaves the room (and is told you closed it)." },
    .{ "A sala é sua: fechando, as {d} pessoas que estão aqui saem da sala (e fica sabendo que você fechou).", "It's your room: if you close it, the {d} people here leave the room (and are told you closed it)." },
    .{ "Sair da sala", "Leave the room" },

    // barra lateral
    .{ "{s} anfitrião · porta {d}", "{s} host · port {d}" },
    .{ "{s} via link público · {s}", "{s} via public link · {s}" },
    .{ "Sala trancada: ninguém novo entra. Clique pra destrancar.", "Room locked: no one new can join. Click to unlock." },
    .{ "Trancar a sala (ninguém novo entra)", "Lock the room (no one new can join)" },
    .{ "Sala trancada: ninguém novo entra", "Room locked: no one new can join" },
    .{ "Copiar convite da sala", "Copy room invite" },
    .{ "{d} ms", "{d} ms" },
    .{ "Conexão criptografada (X25519 + ChaCha20-Poly1305)", "Encrypted connection (X25519 + ChaCha20-Poly1305)" },
    .{ "AO VIVO — {d}", "LIVE — {d}" },
    .{ "MEMBROS — {d}", "MEMBERS — {d}" },
    .{ "AO VIVO", "LIVE" },
    .{ "{s}  Ao vivo (configurar)", "{s}  Live (settings)" },
    .{ "{s}  Compartilhar tela", "{s}  Share screen" },
    .{ "Desligar a câmera", "Turn off camera" },
    .{ "Ligar a câmera", "Turn on camera" },
    .{ "câmera · {d}x{d} · {s} {d}", "camera · {d}x{d} · {s} {d}" },
    .{ "{d}x{d} · {d} fps · {s} · {s} {d}", "{d}x{d} · {d} fps · {s} · {s} {d}" },
    .{ "{d}x{d} · {d} fps · {s} {d}", "{d}x{d} · {d} fps · {s} {d}" },
    .{ "É você!", "It's you!" },
    .{ "Parar de assistir", "Stop watching" },
    .{ "Assistir", "Watch" },
    .{ "\nAssistindo: ", "\nWatching: " },
    .{ "Nessa mesma máquina", "On this same computer" },
    .{ "Rede local (ou VPN tipo Tailscale)", "Local network (or a VPN like Tailscale)" },
    .{ "Direto pela internet (IPv4)", "Direct over the internet (IPv4)" },
    .{ "Direto pela internet (IPv6)", "Direct over the internet (IPv6)" },
    .{ "Pelo link público (túnel)", "Through the public link (tunnel)" },
    .{ "Clique direito: volume da voz e ações de admin", "Right-click: voice volume and admin actions" },
    .{ "Clique direito: volume da voz", "Right-click: voice volume" },
    .{ "Conectado: ", "Connected: " },
    .{ "(você)", "(you)" },
    .{ "Volume da voz", "Voice volume" },
    .{ "Voltar a ouvir", "Unmute" },
    .{ "Silenciar pra mim", "Mute for me" },
    .{ "ADMIN", "ADMIN" },
    .{ "{s}  Liberar o microfone", "{s}  Allow microphone" },
    .{ "{s}  Silenciar o microfone (pra todos)", "{s}  Mute microphone (for everyone)" },
    .{ "{s}  Parar a transmissão", "{s}  Stop the stream" },
    .{ "{s}  Desligar a câmera", "{s}  Turn off the camera" },
    .{ "{s}  Tirar o admin", "{s}  Remove admin" },
    .{ "{s}  Dar admin", "{s}  Make admin" },
    .{ "{s}  Expulsar da sala", "{s}  Kick from the room" },
    .{ "{s}  Banir (não volta mais)", "{s}  Ban (can't come back)" },

    // painel do usuário
    .{ "Online", "Online" },
    .{ "Iniciando...", "Starting..." },
    .{ "Ao vivo", "Live" },
    .{ "O admin silenciou seu microfone", "The admin muted your microphone" },
    .{ "Desligar o microfone", "Turn off microphone" },
    .{ "Ligar o microfone", "Turn on microphone" },
    .{ "Voltar a ouvir a sala", "Undeafen" },
    .{ "Parar de ouvir a sala (surdo)", "Stop hearing the room (deafen)" },
    .{ "Configurações", "Settings" },

    // convite, link público e porta no roteador
    .{ "Pedindo pro roteador abrir a porta…", "Asking the router to open the port…" },
    .{ "Procurando o roteador na rede (UPnP). Leva uns segundos.", "Looking for the router on the network (UPnP). Takes a few seconds." },
    .{ "Porta aberta no roteador: conexão direta, sem túnel.", "Port open on the router: direct connection, no tunnel." },
    .{ "{s}  Copiar convite", "{s}  Copy invite" },
    .{ "{s}  Fechar porta", "{s}  Close port" },
    .{ "{s}  Não deu pra abrir a porta", "{s}  Couldn't open the port" },
    .{ "{s}  Criar link público", "{s}  Create public link" },
    .{ "Fechar", "Close" },
    .{ "{s}  Chamando a galera de fora", "{s}  Inviting people from outside" },
    .{ "Link público: pelo {s}, funciona em qualquer rede.", "Public link: through {s}, works on any network." },
    .{ "Porta no roteador (UPnP): direto, menos atraso. Tudo cifrado.", "Router port (UPnP): direct, less delay. Everything is encrypted." },
    .{ "{s}  Abrir porta no roteador", "{s}  Open port on router" },
    .{ "Abrindo o link público no {s}…", "Opening the public link on {s}…" },
    .{ "Leva só alguns segundos.", "It only takes a few seconds." },
    .{ "Link público no ar. Manda o convite pra galera:", "Public link is up. Send the invite to your friends:" },
    .{ "{s}  Desligar", "{s}  Turn off" },
    .{ "{s}  Não deu pra abrir o link público", "{s}  Couldn't open the public link" },
    .{ "{s}  Tentar de novo", "{s}  Try again" },
    .{ "{s}  Prefere seu próprio túnel? (ngrok, bore, ssh)", "{s}  Prefer your own tunnel? (ngrok, bore, ssh)" },
    .{ "Copiar", "Copy" },
    .{ "Cola aqui o endereço que o túnel mostrou e copia o convite:", "Paste the address the tunnel showed here and copy the invite:" },
    .{ "ex.: 0.tcp.sa.ngrok.io:12345", "e.g. 0.tcp.sa.ngrok.io:12345" },
    .{ "Sala aberta pra fora precisa de senha: ela ganhou a senha {s} (já vai no convite).", "A room open to the outside needs a password: it got the password {s} (already in the invite)." },
    .{ "Espera entrar na sala pra abrir ela pra fora.", "Wait until you're in the room to open it to the outside." },
    .{ "Não consegui abrir o link público.", "Couldn't open the public link." },
    .{ "Não consegui pedir a porta pro roteador.", "Couldn't ask the router for the port." },
    .{ "Não achei nenhum endereço dessa sala. Cria o link público no card \"Chamando a galera de fora\".", "Couldn't find any address for this room. Create the public link in the \"Inviting people from outside\" card." },
    .{ "Convite copiado, mas só funciona na mesma rede. Pra galera de fora: link público ou porta no roteador.", "Invite copied, but it only works on the same network. For people outside: public link or router port." },
    .{ "Convite copiado ({d} caminhos: cada um entra pelo mais rápido que funcionar).", "Invite copied ({d} routes: each person joins through the fastest one that works)." },
    .{ "Convite copiado! Quem receber cola no campo de endereço.", "Invite copied! Whoever gets it pastes it in the address field." },
    .{ "não achei o servidor do túnel (sem internet?)", "couldn't find the tunnel server (no internet?)" },
    .{ "o servidor do túnel não respondeu", "the tunnel server didn't answer" },
    .{ "esse servidor de túnel exige senha", "this tunnel server requires a password" },
    .{ "a conexão com o servidor do túnel caiu", "the connection to the tunnel server dropped" },
    .{ "Nenhum roteador respondeu ao UPnP (ele pode estar desligado nas configurações do roteador).", "No router answered UPnP (it may be turned off in the router settings)." },
    .{ "O roteador respondeu, mas não deixa abrir portas por UPnP.", "The router answered, but doesn't allow opening ports through UPnP." },
    .{ "Sua operadora usa CGNAT (o roteador não tem IP próprio na internet): porta aberta lá não chega aqui. Use o link público.", "Your ISP uses CGNAT (the router has no public IP of its own): a port opened there doesn't reach you. Use the public link." },
    .{ "O roteador recusou abrir a porta.", "The router refused to open the port." },
    .{ "O roteador não respondeu direito.", "The router didn't answer properly." },

    // transmissões
    .{ "Membros e controles", "Members and controls" },
    .{ "Transmissões", "Streams" },
    .{ "{d} na tela", "{d} on screen" },
    .{ "Mostrar chat", "Show chat" },
    .{ " (câmera)", " (camera)" },
    .{ " (rede lenta)", " (slow network)" },
    .{ " (espectador lento)", " (slow viewer)" },
    .{ "Você", "You" },
    .{ "Você (câmera)", "You (camera)" },
    .{ "você", "you" },
    .{ "{d}x{d} · {d:.0} fps · {d:.0} KB/s · {s}", "{d}x{d} · {d:.0} fps · {d:.0} KB/s · {s}" },
    .{ "{d}x{d} · {d:.0} fps · {d} kbit/s{s} · {s} {d:.1} ms · {s}", "{d}x{d} · {d:.0} fps · {d} kbit/s{s} · {s} {d:.1} ms · {s}" },
    .{ "câmera · {d}x{d} · {d:.0} fps · {d} kbit/s · {s} · {s}", "camera · {d}x{d} · {d:.0} fps · {d} kbit/s · {s} · {s}" },
    .{ "tela parada", "screen not changing" },
    .{ "atraso {d:.0} ms · {s} ({s}) {d:.1} ms", "delay {d:.0} ms · {s} ({s}) {d:.1} ms" },
    .{ "Carregando...", "Loading..." },
    .{ "REC (esperando quadro completo)", "REC (waiting for a full frame)" },
    .{ "REC {d:0>2}:{d:0>2}", "REC {d:0>2}:{d:0>2}" },
    .{ "Voltar pra grade", "Back to grid" },
    .{ "Destacar na sala", "Spotlight in the room" },
    .{ "Tela cheia (F11 ou duplo clique)", "Full screen (F11 or double-click)" },
    .{ "Sair da tela cheia (Esc)", "Exit full screen (Esc)" },
    .{ "Desligar o ponteiro", "Turn off the pointer" },
    .{ "Ponteiro: quem assiste vê onde você aponta (clique chama atenção)", "Pointer: viewers see where you point (click to get attention)" },
    .{ "Fechar a janela flutuante", "Close the floating window" },
    .{ "Abrir numa janela flutuante (por cima das outras)", "Open in a floating window (on top of the others)" },
    .{ "Voltar pra janela do telinha (duplo clique também)", "Back to the telinha window (double-click works too)" },
    .{ "Parar de gravar (salva o arquivo)", "Stop recording (saves the file)" },
    .{ "Gravar (MP4, com o som da transmissão, a partir de agora)", "Record (MP4, with the stream's sound, from now on)" },
    .{ "Parar de seguir o cursor", "Stop following the cursor" },
    .{ "Zoom seguindo o cursor de quem transmite (rodinha: aproximar)", "Zoom following the streamer's cursor (mouse wheel: zoom in)" },
    .{ "Seguir o cursor (quem transmite está sem cursor)", "Follow the cursor (the streamer has no cursor)" },
    .{ "Voltar pro tamanho normal (sem zoom)", "Back to normal size (no zoom)" },
    .{ "Ativar som", "Unmute" },
    .{ "Silenciar", "Mute" },
    .{ "Tem gente ao vivo!", "Someone is live!" },
    .{ "Ninguém está transmitindo", "Nobody is streaming" },
    .{ "Escolhe quem assistir. Dá pra assistir várias telas ao mesmo tempo.", "Choose who to watch. You can watch several screens at the same time." },
    .{ "Clica em Compartilhar tela pra começar, ou espera alguém da sala.", "Click Share screen to start, or wait for someone in the room." },
    .{ "{s}  Assistir", "{s}  Watch" },
    .{ "{s}   Compartilhar tela", "{s}   Share screen" },
    .{ "Sem memória.", "Out of memory." },
    .{ "Não consegui iniciar o codificador de vídeo.", "Couldn't start the video encoder." },
    .{ "Falha ao codificar o vídeo.", "Video encoding failed." },
    .{ "A câmera não mandou nenhuma imagem (outro programa está usando ela?).", "The camera didn't send any image (is another program using it?)." },
    .{ "A imagem da tela não chegou (o compositor aceitou compartilhar, mas não mandou nenhum quadro). Tenta de novo; se continuar, reinicia o xdg-desktop-portal.", "The screen image didn't arrive (the compositor agreed to share but sent no frames). Try again; if it keeps happening, restart xdg-desktop-portal." },
    .{ "Configurações aplicadas.", "Settings applied." },
    .{ "Não consegui iniciar a transmissão.", "Couldn't start the stream." },
    .{ "Não consegui ligar a câmera.", "Couldn't turn on the camera." },
    .{ "A câmera parou: {s}", "The camera stopped: {s}" },
    .{ "Transmitindo sem áudio: {s}", "Streaming without audio: {s}" },
    .{ "A transmissão parou: {s}", "The stream stopped: {s}" },
    .{ "A transmissão caiu; retomando…", "The stream dropped; resuming…" },
    .{ "A transmissão caiu várias vezes seguidas; parei de tentar.", "The stream dropped several times in a row; stopped retrying." },

    // clipes, gravação e janela flutuante
    .{ "clipe", "clip" },
    .{ "_clipe", "_clip" },
    .{ "gravacao", "recording" },
    .{ "_gravacao", "_recording" },
    .{ "Calma: ainda salvando os clipes anteriores.", "Hold on: still saving the previous clips." },
    .{ "Ainda não tem nada pra clipar (espera uns segundos).", "Nothing to clip yet (wait a few seconds)." },
    .{ "Não achei a pasta de vídeos pra salvar o clipe.", "Couldn't find the videos folder to save the clip." },
    .{ "Salvando o clipe...", "Saving the clip..." },
    .{ "Clipe salvo ({d:.0} s): {s}", "Clip saved ({d:.0} s): {s}" },
    .{ "Não consegui salvar o clipe em {s}", "Couldn't save the clip to {s}" },
    .{ "Não achei a pasta de vídeos pra gravar.", "Couldn't find the videos folder to record." },
    .{ "Não consegui criar o arquivo da gravação em {s}", "Couldn't create the recording file at {s}" },
    .{ "Gravando: {s}", "Recording: {s}" },
    .{ "Gravação cancelada (não chegou nenhum quadro completo).", "Recording canceled (no full frame arrived)." },
    .{ "Gravação salva ({d}:{d:0>2}): {s}", "Recording saved ({d}:{d:0>2}): {s}" },
    .{ "No máximo 4 janelas flutuantes.", "At most 4 floating windows." },
    .{ "Não consegui abrir a janela flutuante.", "Couldn't open the floating window." },
    .{ "Pasta dos clipes: {s}", "Clips folder: {s}" },

    // chat
    .{ "Chat", "Chat" },
    .{ "Esconder chat", "Hide chat" },
    .{ "MENSAGENS DE ANTES DE VOCÊ ENTRAR", "MESSAGES FROM BEFORE YOU JOINED" },
    .{ "Mensagem, @nome, ou cole/arraste uma imagem", "Message, @name, or paste/drop an image" },
    .{ "Tab", "Tab" },
    .{ "Imagem: arraste o arquivo pra janela ou copie e aperte Ctrl+V aqui", "Image: drop the file on the window, or copy it and press Ctrl+V here" },
    .{ "Enviar", "Send" },
    .{ "Curti", "Like" },
    .{ "Amei", "Love" },
    .{ "Haha", "Haha" },
    .{ "Fogo", "Fire" },
    .{ "Uau", "Wow" },
    .{ "Triste", "Sad" },
    .{ "{d} x {d} · clique ou Esc pra fechar", "{d} x {d} · click or Esc to close" },
    .{ "{s}  imagem com defeito", "{s}  broken image" },
    .{ "{s}  imagem antiga (não está mais guardada na sala)", "{s}  old image (no longer kept in the room)" },
    .{ "{s}  mandando imagem...", "{s}  sending image..." },
    .{ "Entre numa sala pra mandar imagem no chat.", "Join a room to send an image in the chat." },
    .{ "Só dá pra mandar imagem (PNG, JPEG, GIF ou BMP).", "Only images can be sent (PNG, JPEG, GIF or BMP)." },
    .{ "Não mandei a imagem: {s}.", "Didn't send the image: {s}." },
    .{ "Pra mandar imagem: arraste o arquivo pra janela do telinha, ou copie a imagem e aperte Ctrl+V no chat.", "To send an image: drop the file on the telinha window, or copy the image and press Ctrl+V in the chat." },
    .{ "não consegui ler o arquivo", "couldn't read the file" },
    .{ "isso não é uma imagem (PNG, JPEG, GIF ou BMP)", "that's not an image (PNG, JPEG, GIF or BMP)" },
    .{ "não consegui preparar a imagem", "couldn't prepare the image" },
    .{ "imagem detalhada demais pro chat", "image too detailed for the chat" },

    // notificações do sistema
    .{ "{s} começou a transmitir", "{s} started streaming" },
    .{ "{s} entrou na sala", "{s} joined the room" },
    .{ "{s} mencionou você", "{s} mentioned you" },
    .{ "mandou uma imagem", "sent an image" },
    .{ "{d} mensagens novas no chat", "{d} new chat messages" },
    .{ "{s} está no telinha {s} e você no {s}: tem versão nova.{s}", "{s} is on telinha {s} and you're on {s}: there's a new version.{s}" },
    .{ " Baixe em Configurações.", " Download it in Settings." },

    // voz
    .{ "Não consegui abrir o microfone: {s}", "Couldn't open the microphone: {s}" },
    .{ "O admin da sala silenciou seu microfone.", "The room admin muted your microphone." },
    .{ "Microfone ligado (Ctrl+M liga/desliga, Ctrl+D fica surdo).", "Microphone on (Ctrl+M toggles it, Ctrl+D deafens)." },
    .{ "Microfone ligado (Ctrl+M liga/desliga). Cancelamento de eco desligado: sem fone de ouvido, a sala pode ouvir eco da sua caixa de som.", "Microphone on (Ctrl+M toggles it). Echo cancellation is off: without headphones, the room may hear an echo from your speakers." },

    // compartilhar tela
    .{ "Compartilhar tela", "Share screen" },
    .{ "Todo mundo na sala vai poder assistir.", "Everyone in the room will be able to watch." },
    .{ "O QUE MOSTRAR", "WHAT TO SHOW" },
    .{ "Tela", "Screen" },
    .{ "SOM", "SOUND" },
    .{ "Sem som", "No sound" },
    .{ "Só o som da janela ({s})", "Only the window's sound ({s})" },
    .{ "Todo o som do computador (menos o telinha)", "All computer sound (except telinha)" },
    .{ "Só o som do {s}", "Only the sound of {s}" },
    .{ "Programa tocando som aparece na lista (abra de novo esta janela se não aparecer).", "Programs playing sound show up in the list (reopen this window if one doesn't)." },
    .{ "TIPO DE CONTEÚDO", "CONTENT TYPE" },
    .{ "Tela e texto", "Screen and text" },
    .{ "Jogo e vídeo", "Game and video" },
    .{ "RESOLUÇÃO", "RESOLUTION" },
    .{ "Original", "Original" },
    .{ "QUADROS POR SEGUNDO", "FRAMES PER SECOND" },
    .{ "QUALIDADE", "QUALITY" },
    .{ "economia", "economy" },
    .{ "equilibrada", "balanced" },
    .{ "alta", "high" },
    .{ "máxima", "maximum" },
    .{ "%d — {s} · até {d},{d} Mbit/s", "%d — {s} · up to {d}.{d} Mbit/s" },
    .{ "A taxa cai sozinha se a internet de alguém não aguentar, e volta a subir quando melhora.", "The bitrate drops on its own if someone's internet can't keep up, and goes back up when it improves." },
    .{ "Mostrar o cursor do mouse", "Show the mouse cursor" },
    .{ "Usar a placa de vídeo (NVIDIA; no Windows também AMD e Intel), se tiver", "Use the GPU (NVIDIA; on Windows also AMD and Intel), if available" },
    .{ "No Wayland o sistema abre um seletor pra escolher a tela ou janela. Na próxima vez ele lembra a escolha.", "On Wayland the system opens a picker to choose the screen or window. Next time it remembers the choice." },
    .{ "Parar", "Stop" },
    .{ "Aplicar", "Apply" },
    .{ "{s}   Ao vivo", "{s}   Go live" },

    // som: excluir programas
    .{ "Excluir programas do som (ex.: o Discord)", "Exclude programs from the audio (e.g. Discord)" },
    .{ "Fora do som: {s}", "Left out of the audio: {s}" },
    .{ "O Windows não deixou excluir programas do som: vai todo o som do computador (menos o telinha).", "Windows didn't let telinha exclude programs from the audio: all computer audio is going out (except telinha)." },
    .{ "O Windows não deixou separar o som do telinha: enquanto você transmite com som, o que você ouve da sala fica mudo (senão quem assiste ouviria eco).", "Windows didn't let telinha keep its own sound out: while you stream with audio, what you hear from the room is muted (otherwise viewers would hear an echo)." },
    .{ "Quem fica de fora do som da transmissão", "Who stays out of the stream's audio" },
    .{ "Ex.: o Discord, pra quem assiste não ouvir a própria voz de volta.", "E.g. Discord, so viewers don't hear their own voice back." },
    .{ "{s} (não está tocando agora)", "{s} (not playing right now)" },
    .{ "Nenhum programa tocando som agora. Dá o play no que quer excluir e abre de novo.", "No program is playing audio right now. Play something in the one you want to exclude and open this again." },

    // configurações: páginas
    .{ "Geral", "General" },
    .{ "Aparência", "Appearance" },
    .{ "Voz", "Voice" },
    .{ "Câmera", "Camera" },
    .{ "Depuração", "Debugging" },
    .{ "Sobre", "About" },
    .{ "IDIOMA", "LANGUAGE" },
    .{ "telinha {s}", "telinha {s}" },
    .{ "protocolo v{d} · vídeo H.264 (NVENC/NVDEC, Media Foundation ou openh264) · voz Opus + RNNoise + SpeexDSP · criptografia X25519 + ChaCha20-Poly1305", "protocol v{d} · H.264 video (NVENC/NVDEC, Media Foundation or openh264) · Opus voice + RNNoise + SpeexDSP · X25519 + ChaCha20-Poly1305 encryption" },

    // qualidade automática e teste do PC
    .{ "O PC não estava dando conta de {d}p no fps escolhido: transmitindo em {d}p (volta sozinho quando folgar).", "Your PC couldn't keep up with {d}p at the chosen fps: streaming at {d}p (goes back up on its own when there's headroom)." },
    .{ "Folgou: a transmissão voltou pra resolução escolhida.", "Headroom is back: the stream returned to the chosen resolution." },

    .{ "Desempenho", "Performance" },
    .{ "Qualidade automática: baixa a resolução sozinho se o PC não der conta do fps", "Automatic quality: lowers the resolution by itself if the PC can't keep up with the fps" },
    .{ "Quando a transmissão não consegue manter o fps escolhido, desce um degrau (1080p → 900p → 720p...) e volta sozinha quando sobrar folga.", "When the stream can't keep the chosen fps, it steps down (1080p → 900p → 720p...) and goes back up on its own when there's headroom." },
    .{ "TESTAR MEU PC", "TEST MY PC" },
    .{ "Uns segundos medindo quanto esse computador aguenta pra transmitir e pra assistir, e a configuração sugerida.", "A few seconds measuring how much this computer handles for streaming and watching, plus the suggested settings." },
    .{ "{s}  Testar meu PC", "{s}  Test my PC" },
    .{ "Pare de transmitir pra testar (o teste usa o processador todo por uns segundos).", "Stop streaming to run the test (it uses the whole processor for a few seconds)." },
    .{ "Testando... {d}%", "Testing... {d}%" },
    .{ "O teste não conseguiu rodar.", "The test couldn't run." },
    .{ "Transmitir na CPU (openh264): 1080p {d:.1} ms por quadro · 720p {d:.1} ms", "Streaming on the CPU (openh264): 1080p {d:.1} ms per frame · 720p {d:.1} ms" },
    .{ "Transmitir na placa ({s}): 1080p {d:.1} ms por quadro", "Streaming on the GPU ({s}): 1080p {d:.1} ms per frame" },
    .{ "Transmitir na placa: esse PC não tem encoder de vídeo que o telinha use.", "Streaming on the GPU: this PC has no video encoder telinha can use." },
    .{ "Assistir 1080p: CPU {d:.1} ms por quadro · placa ({s}) {d:.1} ms", "Watching 1080p: CPU {d:.1} ms per frame · GPU ({s}) {d:.1} ms" },
    .{ "Assistir 1080p: CPU {d:.1} ms por quadro", "Watching 1080p: CPU {d:.1} ms per frame" },
    .{ "Sugestão: transmitir em {d}p a {d} q/s ({s})", "Suggestion: stream at {d}p, {d} fps ({s})" },
    .{ "na placa de vídeo", "on the GPU" },
    .{ "na CPU", "on the CPU" },
    .{ "Pra assistir, esse PC decodifica uns {d} q/s em 1080p.", "For watching, this PC decodes about {d} fps at 1080p." },
    .{ "Usar a sugestão", "Use the suggestion" },
    .{ "Pronto: a próxima transmissão sai em {d}p a {d} q/s.", "Done: the next stream goes out at {d}p, {d} fps." },

    // relatório de travamento
    .{ "O telinha travou", "telinha crashed" },
    .{ "O telinha fechou do nada da última vez", "telinha closed unexpectedly last time" },
    .{ "Dá pra mandar o relatório (o que deu errado e, se estava ligado, o fim do log de depuração) pra ajudar a consertar. Ele não tem senha nenhuma.", "You can send the report (what went wrong and, if it was on, the end of the debug log) to help fix it. It contains no passwords." },
    .{ "Agora não", "Not now" },
    .{ "{s}  Mandar", "{s}  Send" },
    .{ "Já tem um envio em andamento; tenta de novo daqui a pouco.", "Something is already being sent; try again in a moment." },
    .{ "Não consegui mandar o relatório: {s}", "Couldn't send the report: {s}" },
    .{ "Relatório mandado pro webhook. Valeu!", "Report sent to the webhook. Thanks!" },
    .{ "Relatório mandado: {s} (link copiado, manda pra quem vai consertar)", "Report sent: {s} (link copied, send it to whoever will fix it)" },
    .{ "RELATÓRIO DE TRAVAMENTO", "CRASH REPORT" },
    .{ "Tem um relatório do último travamento, ainda não mandado.", "There's a report from the last crash that hasn't been sent." },
    .{ "{s}  Mandar o relatório", "{s}  Send the report" },
    .{ "Nenhum travamento registrado.", "No crash recorded." },
    .{ "não consegui ler o relatório", "couldn't read the report" },

    .{ "TAMANHO DA INTERFACE", "INTERFACE SIZE" },
    .{ "Efeito CRT (linhas de tela antiga; o vídeo fica de fora)", "CRT effect (old-screen scanlines; video is left out)" },

    .{ "Personalizado", "Custom" },
    .{ "Fundo", "Background" },
    .{ "Painéis", "Panels" },
    .{ "Texto", "Text" },
    .{ "Destaque", "Accent" },
    .{ "Destaque (mouse em cima)", "Accent (hover)" },
    .{ "Verde", "Green" },
    .{ "Vermelho", "Red" },
    .{ "Cantos retos", "Square corners" },
    .{ "Fonte monoespaçada (Fira Code)", "Monospace font (Fira Code)" },
    .{ "{s}  Colar CSS", "{s}  Paste CSS" },
    .{ "{s}  Copiar como CSS", "{s}  Copy as CSS" },
    .{ "Tema montado a partir do CSS.", "Theme built from the CSS." },
    .{ "Não achei as cores no CSS copiado (precisa das variáveis do :root, tipo --bg: #050505).", "Couldn't find the colors in the copied CSS (it needs the :root variables, like --bg: #050505)." },
    .{ "Tema copiado como CSS.", "Theme copied as CSS." },

    // apertar pra falar
    .{ "MODO", "MODE" },
    .{ "Detecção de voz", "Voice activity" },
    .{ "Apertar pra falar", "Push to talk" },
    .{ "Aperte a tecla (ou um botão lateral do mouse)...", "Press the key (or a mouse side button)..." },
    .{ "Tecla:", "Key:" },
    .{ "Botão lateral do mouse no Linux só vale com o telinha em foco (o X não informa ele pra outros programas).", "A mouse side button on Linux only works with telinha focused (X doesn't report it to other programs)." },
    .{ "Espaço", "Space" },
    .{ "Ctrl esq.", "Left Ctrl" },
    .{ "Ctrl dir.", "Right Ctrl" },
    .{ "Shift esq.", "Left Shift" },
    .{ "Shift dir.", "Right Shift" },
    .{ "tecla {d}", "key {d}" },
    .{ "No Wayland a tecla só vale com o telinha em foco (o sistema não deixa ler o teclado de outro programa).", "On Wayland the key only works with telinha focused (the system doesn't let apps read the keyboard of other programs)." },
    .{ "Vale com qualquer programa em foco (no jogo também). Clique no botão pra trocar a tecla.", "Works with any program focused (in-game too). Click the button to change the key." },

    // desenho e recorte
    .{ "Parar de desenhar (botão direito apaga os seus traços)", "Stop drawing (right click erases your strokes)" },
    .{ "Desenhar por cima: quem assiste e quem transmite veem; some sozinho em alguns segundos", "Draw on top: viewers and the streamer see it; fades away after a few seconds" },
    .{ "Cancelar o recorte", "Cancel cropping" },
    .{ "Transmitir só um pedaço da tela", "Stream only part of the screen" },
    .{ "Arraste pra escolher o pedaço · botão direito: tela inteira · Esc: cancelar", "Drag to pick the area · right click: whole screen · Esc: cancel" },

    .{ "ARQUIVO CSS (atualiza sozinho quando você salva o arquivo)", "CSS FILE (updates by itself when you save the file)" },
    .{ "/caminho/do/tema.css", "/path/to/theme.css" },
    .{ "Usar", "Use" },
    .{ "Cole o caminho de um .css com variáveis no :root (--bg, --accent...).", "Paste the path of a .css with :root variables (--bg, --accent...)." },
    .{ "Usando o arquivo: salvou, mudou aqui.", "Using the file: save it and it changes here." },
    .{ "Não achei o arquivo.", "Couldn't find the file." },
    .{ "O arquivo não tem as cores (variáveis do :root, tipo --bg: #050505).", "The file has no colors (:root variables, like --bg: #050505)." },

    .{ "LIMITE DE QUADROS DA INTERFACE", "INTERFACE FRAME LIMIT" },
    .{ "30 q/s", "30 fps" },
    .{ "60 q/s", "60 fps" },
    .{ "O do monitor", "Monitor's" },
    .{ "A interface só redesenha quando algo muda; isso limita quando muda muito (mouse mexendo, vídeo). Menos quadros = menos placa de vídeo.", "The interface only redraws when something changes; this caps it when a lot changes (mouse moving, video). Fewer frames = less GPU." },

    .{ "ENCODER DA PLACA DE VÍDEO (vale na próxima transmissão)", "GPU ENCODER (applies to the next stream)" },
    .{ "Leve", "Light" },
    .{ "Equilibrado", "Balanced" },
    .{ "Qualidade", "Quality" },
    .{ "Leve: menos trabalho na placa (bom pra jogar e transmitir junto), um pouco menos nítido. Qualidade: mais nítido, mais placa.", "Light: less GPU work (good for gaming while streaming), a bit less sharp. Quality: sharper, more GPU." },

    .{ "Ainda não chegou imagem dessa transmissão.", "No image from this stream yet." },
    .{ "print", "screenshot" },
    .{ "_print", "_screenshot" },
    .{ "Não achei a pasta de vídeos pra salvar o print.", "Couldn't find the videos folder to save the screenshot." },
    .{ "Print salvo: {s}", "Screenshot saved: {s}" },
    .{ "Não consegui salvar o print em {s}", "Couldn't save the screenshot to {s}" },
    .{ "Não consegui ler o quadro da placa pro print.", "Couldn't read the frame from the GPU for the screenshot." },
    .{ "Print (PNG, na resolução da transmissão)", "Screenshot (PNG, at the stream's resolution)" },

    .{ "nenhum", "none" },
    .{ "minha_tela", "my_screen" },
    .{ "Nada pra clipar: assista alguém (ou transmita) com os clipes ligados.", "Nothing to clip: watch someone (or stream) with clips on." },
    .{ "ATALHO PRA SALVAR CLIPE (vale com o jogo em foco)", "SAVE CLIP SHORTCUT (works with the game focused)" },
    .{ "Sem atalho", "No shortcut" },
    .{ "Atalhos", "Shortcuts" },
    .{ "Gravação salva ({d}:{d:0>2}) em {d} partes (a resolução mudou no meio): {s}", "Recording saved ({d}:{d:0>2}) in {d} parts (the resolution changed midway): {s}" },
    .{ "Cursor fora do vídeo: mexer o mouse com a tela parada não gera quadro nenhum", "Cursor outside the video: moving the mouse over a still screen sends no frames" },
    .{ "Quem assiste desenha a seta. Só vale se todo mundo que assiste estiver nesta versão; o cursor não aparece nos clipes e gravações de quem assiste (gravando a própria tela, ele volta pro vídeo).", "Viewers draw the arrow themselves. Only applies when everyone watching runs this version; the cursor doesn't show in viewers' clips and recordings (while you record your own screen it goes back into the video)." },
    .{ "Mandar no tamanho em que aparece pra quem assiste", "Send at the size viewers actually see" },
    .{ "Se todo mundo está te vendo num quadradinho da grade, não precisa mandar 1080p: menos placa, menos rede pra todos. Volta na hora quando alguém amplia. Os seus clipes da própria tela saem no tamanho mandado.", "If everyone sees you in a small grid tile there's no need to send 1080p: less GPU and less network for everyone. It goes back up as soon as someone enlarges you. Clips of your own screen are saved at the size being sent." },
    .{ "sem imagem nova há {d} s", "no new image for {d} s" },
    .{ "Atalhos ligados", "Shortcuts enabled" },
    .{ "Atalhos ligados.", "Shortcuts enabled." },
    .{ "Atalhos desligados (só o de ligar de novo continua valendo).", "Shortcuts disabled (only the one that turns them back on still works)." },
    .{ "No Wayland os atalhos só valem com o telinha em foco (o sistema não deixa ler o teclado de outro programa).", "On Wayland shortcuts only work while telinha is focused (the system won't let us read the keyboard from another program)." },
    .{ "Valem com o jogo em foco. Clique na tecla e aperte a nova (pode ser combinação, tipo Ctrl+Shift+K, ou o botão do meio/laterais do mouse); Esc cancela.", "They work while the game is focused. Click the key and press the new one (a combo like Ctrl+Shift+K works, or the middle/side mouse buttons); Esc cancels." },
    .{ "Salvar clipe", "Save clip" },
    .{ "Microfone liga/desliga", "Microphone on/off" },
    .{ "Surdo liga/desliga (não ouve ninguém)", "Deafen on/off (hear no one)" },
    .{ "Transmitir a tela / parar", "Share the screen / stop" },
    .{ "Print da transmissão", "Screenshot of the stream" },
    .{ "Ligar/desligar todos os atalhos (vale sempre)", "Enable/disable all shortcuts (always works)" },
    .{ "Aperte a tecla ou combinação...", "Press the key or combo..." },
    .{ "Outra duração (segundos):", "Other length (seconds):" },
    .{ "O atalho pra salvar clipe fica na página Atalhos.", "The save-clip shortcut is on the Shortcuts page." },
    .{ "Nada pra printar: assista alguém.", "Nothing to screenshot: watch someone." },

    // temas
    .{ "TEMA", "THEME" },
    .{ "Escuro", "Dark" },
    .{ "Claro", "Light" },
    .{ "pwnd", "pwnd" },
    .{ "pwnd claro", "pwnd light" },
    .{ "Nord", "Nord" },
    .{ "Drácula", "Dracula" },

    // depuração (log pra mandar)
    .{ "{s}  Depuração", "{s}  Debugging" },
    .{ "Gravar log de depuração (desempenho, rede, vídeo, erros: tudo)", "Record a debug log (performance, network, video, errors: everything)" },
    .{ "Não consegui criar o arquivo do log.", "Couldn't create the log file." },
    .{ "Liga, usa normalmente até o problema acontecer (fps caindo, travadas...) e manda o log. Ele tem nomes, endereços e as configurações, mas nenhuma senha.", "Turn it on, use the app normally until the problem happens (fps dropping, stutters...) and send the log. It contains names, addresses and your settings, but no passwords." },
    .{ "{s} (vazio)", "{s} (empty)" },
    .{ "{s} ({d:.1} MB)", "{s} ({d:.1} MB)" },
    .{ "{s}  Abrir pasta", "{s}  Open folder" },
    .{ "Apagar log", "Delete log" },
    .{ "MANDAR O LOG", "SEND THE LOG" },
    .{ "gofile.io (gera um link)", "gofile.io (makes a link)" },
    .{ "Webhook (Discord etc.)", "Webhook (Discord etc.)" },
    .{ "https://discord.com/api/webhooks/...", "https://discord.com/api/webhooks/..." },
    .{ "{s}  Enviar log", "{s}  Send log" },
    .{ "Link do webhook inválido (tem que começar com https://).", "Invalid webhook link (it must start with https://)." },
    .{ "Enviando o log...", "Sending the log..." },
    .{ "Não consegui enviar: {s}", "Couldn't send: {s}" },
    .{ "Log enviado pro webhook.", "Log sent to the webhook." },
    .{ "Pronto! Manda esse link pra quem vai olhar o log:", "Done! Send this link to whoever is going to look at the log:" },
    .{ "{s}  Copiar link", "{s}  Copy link" },
    .{ "Link copiado.", "Link copied." },
    .{ "{s}  Abrir", "{s}  Open" },
    .{ "sem conexão com o servidor", "no connection to the server" },
    .{ "sem conexão (ou o curl não está instalado)", "no connection (or curl isn't installed)" },
    .{ "o servidor respondeu", "the server answered" },
    .{ "não consegui criar a thread de envio", "couldn't start the upload thread" },
    .{ "sem pasta de configuração", "no settings folder" },
    .{ "caminho estranho", "odd path" },
    .{ "caminho longo demais", "path too long" },
    .{ "não consegui ler o log (está vazio?)", "couldn't read the log (is it empty?)" },
    .{ "o gofile não devolveu o link", "gofile didn't return the link" },

    // configurações
    .{ "Idioma / Language", "Language / Idioma" },
    .{ "Automático", "Automatic" },
    .{ "SEU NOME (vale na próxima vez que entrar numa sala)", "YOUR NAME (applies the next time you join a room)" },
    .{ "Mostrar estatísticas sempre (não só com o mouse em cima)", "Always show statistics (not only on mouse hover)" },
    .{ "Notificações com o telinha em segundo plano (chat, ao vivo, quem entrou)", "Notifications with telinha in the background (chat, live, who joined)" },
    .{ "Avisar quando sair versão nova (pergunta ao GitHub ao abrir)", "Tell me when a new version is out (asks GitHub on startup)" },
    .{ "Baixar a nova", "Download it" },
    .{ "Clipes: guardar o finalzinho do que você assiste (pra salvar um clipe na hora)", "Clips: keep the latest part of what you watch (to save a clip right away)" },
    .{ "DURAÇÃO DO CLIPE", "CLIP LENGTH" },
    .{ "1 min", "1 min" },
    .{ "2 min", "2 min" },
    .{ "3 min", "3 min" },
    .{ "Usa até ~{d} MB de memória por transmissão assistida (depende da qualidade).", "Uses up to ~{d} MB of memory per watched stream (depends on quality)." },
    .{ "Salvar clipe dos últimos {d} s", "Save a clip of the last {d} s" },
    .{ "Abrir a pasta", "Open folder" },
    .{ "{s}  Voz", "{s}  Voice" },
    .{ "MICROFONE", "MICROPHONE" },
    .{ "Padrão do sistema", "System default" },
    .{ "SENSIBILIDADE (quanto maior, mais fácil o microfone abrir)", "SENSITIVITY (the higher, the easier the microphone opens)" },
    .{ "Liga o microfone pra ver o medidor.", "Turn on the microphone to see the meter." },
    .{ "Supressão de ruído (tira ventilador, teclado, chiado)", "Noise suppression (removes fans, keyboard, hiss)" },
    .{ "Cancelamento de eco (pra quem usa caixa de som em vez de fone)", "Echo cancellation (for speakers instead of headphones)" },
    .{ "Entrar na sala com o microfone ligado", "Join rooms with the microphone on" },
    .{ "Sons de aviso (alguém entrou/saiu, ao vivo, microfone)", "Notification sounds (someone joined/left, live, microphone)" },
    .{ "{s}  Câmera", "{s}  Camera" },
    .{ "Nenhuma câmera encontrada", "No camera found" },
    .{ "A primeira que achar", "The first one found" },
    .{ "telinha {s} · protocolo v{d} · vídeo H.264 (NVENC/NVDEC, Media Foundation ou openh264) · voz Opus + RNNoise + SpeexDSP · criptografia X25519 + ChaCha20-Poly1305", "telinha {s} · protocol v{d} · H.264 video (NVENC/NVDEC, Media Foundation or openh264) · Opus voice + RNNoise + SpeexDSP · X25519 + ChaCha20-Poly1305 encryption" },
    .{ "Atalhos: Ctrl+M microfone · Ctrl+D surdo · F11 tela cheia · duplo clique = modo cinema · Esc sai", "Shortcuts: Ctrl+M microphone · Ctrl+D deafen · F11 full screen · double-click = theater mode · Esc exits" },

    // textos que chegam prontos do código C (ver dynamic): fontes de captura e erros
    .{ "Escolher tela ou janela (seletor do sistema)", "Choose screen or window (system picker)" },
    .{ "Tela inteira (X11)", "Entire screen (X11)" },
    .{ "Janela:", "Window:" },
    .{ "sistema de áudio indisponível", "audio system unavailable" },
    .{ "não consegui abrir o dispositivo de áudio", "couldn't open the audio device" },
    .{ "não consegui iniciar o áudio", "couldn't start audio" },
    .{ "pra capturar o áudio precisa do PulseAudio ou pipewire-pulse", "capturing audio needs PulseAudio or pipewire-pulse" },
    .{ "PipeWire indisponível", "PipeWire unavailable" },
    .{ "não consegui criar a captura no PipeWire", "couldn't create the PipeWire capture" },
    .{ "a câmera parou (desconectada ou em uso por outro programa)", "the camera stopped (disconnected or in use by another program)" },
    .{ "Nenhuma câmera encontrada.", "No camera found." },
    .{ "Não consegui abrir a câmera (outro programa está usando?).", "Couldn't open the camera (is another program using it?)." },
    .{ "Não consegui ler a câmera.", "Couldn't read the camera." },
    .{ "A câmera não aceitou nenhum formato que o telinha entende.", "The camera didn't accept any format telinha understands." },
    .{ "A câmera informou um tamanho inválido.", "The camera reported an invalid size." },
    .{ "Sem memória pra câmera.", "Out of memory for the camera." },
    .{ "Esse Windows não tem Media Foundation (Windows N sem o Media Feature Pack?).", "This Windows has no Media Foundation (Windows N without the Media Feature Pack?)." },
    .{ "Não consegui iniciar o PipeWire pra câmera.", "Couldn't start PipeWire for the camera." },
    .{ "Não consegui conectar no PipeWire (ele está rodando?).", "Couldn't connect to PipeWire (is it running?)." },
    .{ "Não consegui abrir a câmera.", "Couldn't open the camera." },
    .{ "câmera", "camera" },
    .{ "a transmissão foi encerrada", "the stream was ended" },
    .{ "não consegui falar com o xdg-desktop-portal", "couldn't talk to xdg-desktop-portal" },
    .{ "o portal recusou a captura", "the portal refused the capture" },
    .{ "captura cancelada", "capture canceled" },
    .{ "captura cancelada ou negada", "capture canceled or denied" },
    .{ "o portal não devolveu nenhuma tela", "the portal returned no screen" },
    .{ "não consegui abrir o PipeWire", "couldn't open PipeWire" },
    .{ "falha ao iniciar o PipeWire", "failed to start PipeWire" },
    .{ "não consegui conectar no PipeWire", "couldn't connect to PipeWire" },
    .{ "não consegui receber a tela do PipeWire", "couldn't receive the screen from PipeWire" },
    .{ "não consegui abrir o display X11", "couldn't open the X11 display" },
    .{ "o servidor X não tem a extensão MIT-SHM", "the X server has no MIT-SHM extension" },
    .{ "formato de tela X11 não suportado (precisa ser 32 bits)", "unsupported X11 screen format (must be 32-bit)" },
    .{ "XShmGetImage falhou (a resolução mudou?)", "XShmGetImage failed (did the resolution change?)" },
    .{ "perdi o acesso à tela (DXGI)", "lost access to the screen (DXGI)" },
    .{ "a janela foi fechada", "the window was closed" },
    .{ "não consegui preparar a captura da janela", "couldn't prepare the window capture" },
    .{ "a janela não existe mais (abre a lista de novo)", "the window no longer exists (open the list again)" },
    .{ "a janela é pequena demais (minimizada?)", "the window is too small (minimized?)" },
    .{ "não consegui capturar a janela", "couldn't capture the window" },
    .{ "nenhum monitor encontrado", "no monitor found" },
    .{ "sem memória", "out of memory" },
    .{ "não consegui capturar a tela (nem DXGI nem GDI)", "couldn't capture the screen (neither DXGI nor GDI)" },
};

test "i18n: tabela sem frase repetida e com os mesmos {} nos dois idiomas" {
    for (table, 0..) |p, i| {
        for (table[i + 1 ..]) |q| {
            if (std.mem.eql(u8, p[0], q[0])) {
                std.debug.print("frase repetida na tabela: {s}\n", .{p[0]});
                return error.Repetida;
            }
        }
        if (std.mem.count(u8, p[0], "{") != std.mem.count(u8, p[1], "{")) {
            std.debug.print("formato diferente: {s} / {s}\n", .{ p[0], p[1] });
            return error.Formato;
        }
        try std.testing.expect(p[1].len > 0);
    }
}

test "i18n: troca de idioma, ##id e formatos" {
    const was = get();
    defer set(was);
    set(.pt);
    try std.testing.expectEqualStrings("Criar sala##go", tr("Criar sala##go"));
    set(.en);
    try std.testing.expectEqualStrings("Create room##go", tr("Criar sala##go"));
    try std.testing.expectEqualStrings("{s}##camera", tr("{s}##camera"));
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Close the room###fecharsala", tr("Fechar a sala###fecharsala"));
    try std.testing.expectEqualStrings("3 new chat messages", try bufPrint(&buf, "{d} mensagens novas no chat", .{3}));
}

test "i18n: mensagens do servidor viram inglês na tela" {
    const was = get();
    defer set(was);
    var buf: [128]u8 = undefined;
    set(.pt);
    try std.testing.expectEqualStrings("Ana entrou na sala", server("Ana entrou na sala", &buf));
    set(.en);
    try std.testing.expectEqualStrings("Ana joined the room", server("Ana entrou na sala", &buf));
    try std.testing.expectEqualStrings("Ana (2) left the room", server("Ana (2) saiu da sala", &buf));
    try std.testing.expectEqualStrings("Bia banned Caio", server("Bia baniu Caio", &buf));
    try std.testing.expectEqualStrings("Bia kicked you out of the room.", server("Bia expulsou você da sala.", &buf));
    try std.testing.expectEqualStrings("Bia unlocked the room", server("Bia destrancou a sala", &buf));
    try std.testing.expectEqualStrings("The room is full.", server("A sala está cheia.", &buf));
    try std.testing.expectEqualStrings("Bia muted your microphone.", server("Bia silenciou seu microfone.", &buf));
    try std.testing.expectEqualStrings("oi gente", server("oi gente", &buf));
}

test "i18n: idioma do sistema e da configuração" {
    try std.testing.expectEqual(Lang.pt, localeLang("pt_BR.UTF-8"));
    try std.testing.expectEqual(Lang.pt, localeLang("pt"));
    try std.testing.expectEqual(Lang.en, localeLang("C.UTF-8"));
    try std.testing.expectEqual(Lang.en, localeLang("en_US.UTF-8"));
    try std.testing.expectEqual(Lang.pt, resolve("pt"));
    try std.testing.expectEqual(Lang.en, resolve("en"));
}

test "i18n: textos prontos do C (frase inteira ou começo)" {
    const was = get();
    defer set(was);
    var buf: [128]u8 = undefined;
    set(.en);
    try std.testing.expectEqualStrings("Window: Firefox (firefox.exe)", dynamic("Janela: Firefox (firefox.exe)", &buf));
    try std.testing.expectEqualStrings("Monitor 1 — 1920x1080", dynamic("Monitor 1 — 1920x1080", &buf));
    set(.pt);
    try std.testing.expectEqualStrings("Janela: Firefox (firefox.exe)", dynamic("Janela: Firefox (firefox.exe)", &buf));
}
