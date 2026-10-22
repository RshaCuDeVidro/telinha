//! Protocolo da sala (versão 6). Ver docs/PROTOCOL.md.
//!
//! No fio: handshake em claro (crypto.zig) e depois mensagens
//!     u32 tamanho | ChaCha20-Poly1305( u8 tipo | payload ) | tag(16)
//! Inteiros little-endian, strings = u16 tamanho + bytes UTF-8.
//!
//! Cada pessoa pode ter duas transmissões: a tela e a câmera. Uma transmissão
//! é identificada por um "stream" de 32 bits: o id da pessoa, com o bit de
//! cima ligado se for a câmera (ver streamId).
const std = @import("std");
const sync = @import("sync.zig");
const net = @import("net.zig");
const crypto = @import("crypto.zig");
const udp = @import("udp.zig");

pub const version: u16 = 6;
/// Versão do app (vai no hello/welcome/members pra avisar quem está desatualizado).
pub const app_version = "3.2.0";
pub const max_msg = 32 * 1024 * 1024;
/// Marcador em claro no lugar do tamanho: "senha errada" (o servidor não
/// conseguiu decifrar a primeira mensagem).
pub const wrong_password_marker: u32 = 0xFFFF_FFFF;
pub const gpa = std.heap.c_allocator;

pub const Type = enum(u8) {
    hello = 1, // C→S str nome, str token_admin, u64 chave_do_cliente (aleatória, guardada na config: banimento)
    welcome = 2, // S→C u32 meu_id, str nome_da_sala, u8 sou_admin, u64 relógio_us, u64 instância_do_servidor, u8 rota (por onde eu cheguei)
    denied = 3, // S→C str motivo, u8 código (deny_*): a conexão vai cair e não adianta reconectar
    members = 4, // S→C u8 sala (room_*), u16 n, n×Member (ver docs/PROTOCOL.md)
    chat = 5, // C→S str texto | S→C u32 id, u32 de (0 = sistema), str nome, str texto, u64 hora (relógio da sala, µs), u8 flags (chat_*)
    stream_start = 6, // C→S u8 tipo (kind_*), u16 w, u16 h, u8 fps, u8 flags (1 = com áudio)
    stream_stop = 7, // C→S u8 tipo
    frame = 8, // C→S frame | S→C u32 stream + frame
    watch = 9, // C→S u32 stream, u8 ligado, u8 opções (watch_*)
    keyreq = 10, // S→C u8 tipo: manda um quadro completo (IDR) | C→S u32 stream, u8 motivo (keyreq_*)
    ping = 11, // C→S u64 t
    pong = 12, // S→C u64 t, u64 relógio_do_servidor_us
    kick = 13, // C→S u32 alvo (só admin; o mesmo que admin/admin_kick)
    audio = 14, // C→S áudio | S→C u32 stream + áudio
    ack = 15, // S→C u8 tipo, u32 seq (servidor recebeu seu frame) | C→S u32 stream, u32 seq (espectador recebeu)
    viewer_slow = 16, // S→C u8 tipo, u8 piso: espectador não dá conta; baixe a taxa (até piso% do alvo)
    voice = 17, // C→S u32 seq, Opus | S→C u32 de, u32 seq, Opus (voz da sala)
    voice_state = 18, // C→S u8 flags (1 = microfone ligado, 2 = surdo)
    admin = 19, // C→S u8 ação (admin_*), u32 alvo, u8 valor (só admin)
    notice = 20, // S→C u8 tipo (notice_*), str texto: algo que o admin fez com você
    pointer = 21, // C→S u32 stream, u16 x, u16 y, u8 flags | S→C u32 de, u32 stream, u16 x, u16 y, u8 flags
    react = 22, // C→S u32 id_da_mensagem, u8 reação, u8 ligado | S→C u32 id, u32 de, u8 reação, u8 ligado
    codec = 23, // S→C u8 tipo (kind_*), u8 codecs (bits 1<<codec), [u8 recursos (feat_*)]: o que todo mundo que assiste consegue decodificar / entende
    draw = 24, // C→S u32 stream, u8 flags (draw_*), u16 n, n × (u16 x, u16 y) | S→C u32 de + o mesmo (desenho por cima da transmissão)
    cursor = 25, // C→S u8 tipo, u16 x, u16 y (coord_none = escondido) | S→C u32 stream, u16 x, u16 y: o cursor de quem transmite, fora do vídeo (feat_cursor)
    view_size = 26, // C→S u32 stream, u16 altura (pixels em que aparece; view_full = quer tudo) | S→C u8 tipo, u16 altura (a maior entre quem assiste; view_full = sem limite)
    log_chunk = 27, // C→S u32 id, u8 o_que (log_what_*), u32 total, u32 posição, bytes | S→C u32 de, str nome + o mesmo: log de depuração pro dono da sala, em pedaços
    log_ack = 28, // S→C u32 id, u8 resultado (log_ack_*), u8 quantos donos receberam
    channel = 29, // C→S str canal: entra (cria, se não existir) | S→C str canal_atual, u8 n, n × (str nome, u16 pessoas, u8 flags chan_*)
    stats = 30, // C→S u8 ligado (só quem entrou com o token de admin) | S→C estatísticas do servidor (ver docs/PROTOCOL.md)
    chan_admin = 32, // C→S u8 ação (chan_*_act), str canal, str valor, u32 alvo: admin mexe num canal
    call = 33, // C→S str canal (vazio = sai da call), str senha: entra na call de um canal (a voz e as transmissões; o chat é o do `channel`)
    identity = 31, // S→C [32] chave pública Ed25519 do servidor, [64] assinatura do handshake (crypto.transcript): a primeira mensagem, antes do hello
    _,
};

/// Imagem no chat: vai como um quadro H.264 (IDR) no fim da mensagem de chat
/// (u8 chat_img_*, e se tiver: u16 w, u16 h, u32 tamanho, bytes). Quem recebe
/// decodifica com o mesmo decoder do vídeo: nenhum leitor de PNG/JPEG exposto
/// à rede.
/// Canais (como no IRC): cada um com o seu chat, quem está nele, voz e
/// transmissões; trocar é na mesma conexão. Nome normalizado (ver
/// server.normalizeChannel): minúsculas, sem "#", até channel_name_max bytes.
pub const channel_name_max = 24;
pub const max_channels = 32;
pub const chan_live: u8 = 1; // alguém ao vivo nele
pub const chan_fixed: u8 = 2; // não some quando esvazia (o padrão e os do --canais)
pub const chan_password: u8 = 4; // pede senha pra entrar
pub const chan_locked: u8 = 8; // só admin entra
pub const chan_topic_max = 120;
/// chan_admin: ações
pub const chan_act_fix: u8 = 1; // valor "1" fixa (sobrevive vazio e ao servidor reiniciar), "0" solta
pub const chan_act_lock: u8 = 2; // valor "1" tranca (só admin entra), "0" destranca
pub const chan_act_password: u8 = 3; // valor = senha (vazio = tira)
pub const chan_act_topic: u8 = 4; // valor = tópico (vazio = tira)
pub const chan_act_move: u8 = 5; // leva `alvo` pro canal (o chat e a call)
/// Bits altos do byte de rota de cada membro (lista personalizada): está no
/// meu canal de texto / está na minha call. Servidor antigo: nenhum dos dois.
pub const member_in_chan: u8 = 0x40;
pub const member_in_call: u8 = 0x20;
pub const default_channel = "geral";

/// stats: no máximo tantas pessoas na lista (o resto só conta no total).
pub const stats_max_people = 64;
pub const stats_late: u8 = 1; // atrasando (assistindo alguém)
pub const stats_thin: u8 = 2; // recebendo só metade dos quadros
pub const stats_streaming: u8 = 4;
pub const stats_camera: u8 = 8;
pub const stats_owner: u8 = 16;

/// log_chunk: o que é e limites (o servidor recusa acima disso).
pub const log_what_log: u8 = 0;
pub const log_what_crash: u8 = 1;
pub const log_max = 8 * 1024 * 1024;
pub const log_chunk_max = 64 * 1024;
/// log_ack: o que aconteceu com o log.
pub const log_ack_delivered: u8 = 0; // chegou em quem tem a coroa
pub const log_ack_saved: u8 = 1; // ninguém com a coroa na sala, mas o servidor guardou
pub const log_ack_nobody: u8 = 2; // ninguém pra receber
pub const log_ack_refused: u8 = 3; // grande demais ou cedo demais (um por minuto)

pub const chat_img_none: u8 = 0;
pub const chat_img_h264: u8 = 1;
pub const chat_img_expired: u8 = 2; // era uma imagem, mas saiu do histórico (memória)
pub const chat_image_max = 1_500_000; // bytes
pub const chat_image_side = 1920; // pixels (cada lado)
/// Reações (índice): curti, amei, haha, fogo, uau, triste.
pub const reactions = 6;

pub const member_streaming: u8 = 1; // transmitindo a tela
pub const member_admin: u8 = 2;
pub const member_audio: u8 = 4; // a tela vai com o som do computador
pub const member_mic: u8 = 8; // microfone ligado
pub const member_deaf: u8 = 16; // não está ouvindo a sala
pub const member_muted: u8 = 32; // microfone silenciado pelo admin
pub const member_camera: u8 = 64; // câmera ligada
pub const member_no_draw: u8 = 128; // o admin tirou o pincel

/// members: estado da sala
pub const room_locked: u8 = 1; // ninguém novo entra

/// voice_state
pub const voice_mic: u8 = 1;
pub const voice_deaf: u8 = 2;

/// Tipos de transmissão (o bit de cima do stream)
pub const kind_screen: u8 = 0;
pub const kind_camera: u8 = 1;

pub fn streamId(member: u32, kind: u8) u32 {
    return (member & 0x7FFF_FFFF) | (@as(u32, kind & 1) << 31);
}
pub fn memberOf(stream: u32) u32 {
    return stream & 0x7FFF_FFFF;
}
pub fn kindOf(stream: u32) u8 {
    return @intCast(stream >> 31);
}

/// Por onde a pessoa chegou na sala (o servidor vê pelo endereço dela).
pub const route_unknown: u8 = 0;
pub const route_local: u8 = 1; // nessa mesma máquina
pub const route_lan: u8 = 2; // rede local (ou VPN tipo Tailscale)
pub const route_internet: u8 = 3; // internet, IPv4 (porta aberta no roteador, servidor dedicado)
pub const route_internet6: u8 = 4; // internet, IPv6
pub const route_tunnel: u8 = 5; // link público (túnel)

/// denied: por que a conexão vai cair
pub const deny_generic: u8 = 0;
pub const deny_kicked: u8 = 1;
pub const deny_banned: u8 = 2;
pub const deny_closed: u8 = 3; // o dono fechou a sala
pub const deny_link_closed: u8 = 4; // o link público por onde a pessoa entrou foi desligado
pub const deny_locked: u8 = 5;
pub const deny_full: u8 = 6;

/// admin: ações
pub const admin_kick: u8 = 1;
pub const admin_ban: u8 = 2; // expulsa e não deixa voltar enquanto a sala existir
pub const admin_mute: u8 = 3; // valor 1 = silencia o microfone, 0 = libera
pub const admin_stop_stream: u8 = 4; // valor = tipo da transmissão
pub const admin_set_admin: u8 = 5; // valor 1 = vira admin, 0 = deixa de ser
pub const admin_lock: u8 = 6; // valor 1 = tranca a sala (alvo ignorado)
pub const admin_draw: u8 = 7; // valor 1 = devolve o pincel, 0 = tira (os desenhos dela somem)

/// notice
pub const notice_muted: u8 = 1;
pub const notice_unmuted: u8 = 2;
pub const notice_stream_stopped: u8 = 3; // texto + o tipo vai no primeiro byte depois do texto
pub const notice_admin_on: u8 = 4;
pub const notice_admin_off: u8 = 5;
pub const notice_channel: u8 = 6; // não deu pra entrar no canal (o texto diz por quê)
pub const notice_draw_off: u8 = 7; // o admin tirou seu pincel
pub const notice_draw_on: u8 = 8; // devolveu
pub const notice_moved: u8 = 9; // um admin te levou pra outro canal
/// notice_channel com extra = 1: o canal pede senha (o app pergunta)
pub const notice_channel_needs_password: u8 = 1;
/// Só no app (não vem do servidor): chegou um log mandado pela sala (texto = nome + caminho).
pub const notice_log_received: u8 = 100;

/// chat
pub const chat_history: u8 = 1; // mensagem antiga (quem acabou de entrar): sem som nem notificação

/// keyreq (de quem assiste): por que precisa de um IDR
pub const keyreq_lost: u8 = 0; // o decoder perdeu a referência (atrasou ou deu erro)
pub const keyreq_record: u8 = 1; // gravação começando (sem efeito no controle de atraso)

/// watch: opções
pub const watch_clips: u8 = 1; // guardando os últimos segundos pra clipe: quer IDR de vez em quando

/// pointer
pub const pointer_visible: u8 = 1;
pub const pointer_ping: u8 = 2; // clique: chama atenção pro ponto
/// draw: começo de um traço novo / apagar os traços de quem mandou nessa transmissão
pub const draw_new: u8 = 1;
pub const draw_clear: u8 = 2;
/// bits 2-3: espessura (0 = normal, 1 = fina, 2 = grossa, 3 = marca-texto);
/// bits 4-7: cor da paleta (0 = a cor da pessoa; ver draw_colors). App antigo
/// ignora os dois e desenha na cor da pessoa.
pub const draw_size_shift: u3 = 2;
pub const draw_color_shift: u3 = 4;
pub const draw_colors = [16]u24{ 0, 0xFFFFFF, 0x111111, 0xF23F43, 0xF57731, 0xF0B232, 0x23A55A, 0x00C4CC, 0x3B82F6, 0x7B5CFF, 0xEC4899, 0xA16207, 0x84CC16, 0x94A3B8, 0xFDE047, 0xFF00FF };
pub const draw_max_points = 64; // por mensagem
/// Coordenada de ponteiro/cursor: 0..65534 = posição relativa no quadro, 0xFFFF = nenhum.
pub const coord_none: u16 = 0xFFFF;

/// Recursos que um app entende (hello, depois dos codecs) / que todo mundo
/// que assiste uma transmissão entende (codec, depois dos codecs). App ou
/// servidor antigo não manda o byte: vale 0 (tudo como antes).
/// feat_cursor: desenha a seta de quem transmite a partir da mensagem
/// `cursor` (o cursor não vai pintado no vídeo; mexer o mouse com a tela
/// parada não gera quadro). feat_view_size: avisa em que tamanho cada
/// transmissão aparece (`view_size`); quem transmite manda no maior deles.
pub const feat_cursor: u8 = 1;
pub const feat_view_size: u8 = 2;
/// feat_calls: a call (voz e transmissões) é separada do canal de texto:
/// `channel` troca só o chat, `call` troca a call. App sem isso: os dois juntos.
pub const feat_calls: u8 = 4;
pub const features_mine: u8 = feat_cursor | feat_view_size | feat_calls;
/// view_size: "quero a resolução toda" (tela cheia, gravando, ou app antigo).
pub const view_full: u16 = 0xFFFF;

/// Payload de áudio: u32 seq, u64 hora_da_captura (relógio da sala, µs),
/// pacote Opus (48 kHz estéreo, 10 ms) até o fim.
pub const audio_header_len = 4 + 8;
pub const stream_audio: u8 = 1;

/// Payload de frame: u32 seq, u8 flags, u64 hora_da_captura (relógio do
/// servidor, µs), u16 w, u16 h, u16 cursor_x, u16 cursor_y (coord_none = sem
/// cursor), bitstream H.264 (Annex B) até o fim.
pub const frame_key: u8 = 1;
/// Ninguém usa esse quadro de referência (camada temporal de cima): o servidor
/// pode pular pra quem não está dando conta (metade dos quadros e da banda).
pub const frame_droppable: u8 = 2;
/// Quadro da câmera (não da tela).
pub const frame_camera: u8 = 0x80;
/// O cursor não está pintado no quadro: quem assiste desenha a seta na
/// posição do quadro / da última mensagem `cursor` (feat_cursor).
pub const frame_cursor_apart: u8 = 0x10;
/// Codec do quadro (codec.Codec: 0 H.264, 1 HEVC, 2 AV1) nos bits 2–3 das flags.
pub const frame_codec_shift = 2;
pub const frame_codec_mask: u8 = 0x0C;
/// Codecs que um app decodifica (hello) / que a sala aceita (codec): bits 1<<codec.
pub const codecs_h264: u8 = 1;
pub const frame_header_len = 4 + 1 + 8 + 2 + 2 + 2 + 2;

/// Mensagem pronta pra enviar (em claro; a escritora cifra por conexão),
/// com contagem de referências: o mesmo frame vai pra vários espectadores.
pub const Msg = struct {
    refs: std.atomic.Value(u32),
    typ: Type,
    from: u32 = 0, // frames encaminhados: stream de origem
    flags: u8 = 0, // frames encaminhados: frame_key / frame_droppable
    data: []u8, // u32 (reservado) + tipo + payload

    pub fn payload(m: *Msg) []u8 {
        return m.data[5..];
    }
    pub fn retain(m: *Msg) *Msg {
        _ = m.refs.fetchAdd(1, .monotonic);
        return m;
    }
    pub fn release(m: *Msg) void {
        if (m.refs.fetchSub(1, .acq_rel) == 1) {
            gpa.free(m.data);
            gpa.destroy(m);
        }
    }
    /// Cria uma mensagem com payload não inicializado de `n` bytes.
    pub fn alloc(typ: Type, n: usize) !*Msg {
        const m = try gpa.create(Msg);
        errdefer gpa.destroy(m);
        m.* = .{ .refs = .init(1), .typ = typ, .data = try gpa.alloc(u8, 5 + n) };
        std.mem.writeInt(u32, m.data[0..4], @intCast(1 + n), .little);
        m.data[4] = @intFromEnum(typ);
        return m;
    }
};

/// Monta o payload de uma mensagem.
pub const Builder = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn begin(self: *Builder, typ: Type) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendNTimes(gpa, 0, 4);
        try self.buf.append(gpa, @intFromEnum(typ));
    }
    pub fn u8_(self: *Builder, v: u8) !void {
        try self.buf.append(gpa, v);
    }
    pub fn u16_(self: *Builder, v: u16) !void {
        try self.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }
    pub fn u32_(self: *Builder, v: u32) !void {
        try self.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }
    pub fn u64_(self: *Builder, v: u64) !void {
        try self.buf.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, v)));
    }
    pub fn str(self: *Builder, s: []const u8) !void {
        const n: u16 = @intCast(@min(s.len, 4000));
        try self.u16_(n);
        try self.buf.appendSlice(gpa, s[0..n]);
    }
    pub fn bytes(self: *Builder, s: []const u8) !void {
        try self.buf.appendSlice(gpa, s);
    }
    /// Gera a mensagem (copia o buffer; o Builder pode ser reusado).
    pub fn finish(self: *Builder) !*Msg {
        const m = try Msg.alloc(@enumFromInt(self.buf.items[4]), self.buf.items.len - 5);
        @memcpy(m.data[5..], self.buf.items[5..]);
        return m;
    }
    pub fn deinit(self: *Builder) void {
        self.buf.deinit(gpa);
    }
};

pub fn simple(typ: Type) !*Msg {
    return Msg.alloc(typ, 0);
}

/// Lê campos de um payload.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.data.len - self.pos < n) return error.BadMessage;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }
    pub fn u8_(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    pub fn u16_(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
    pub fn u32_(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    pub fn u64_(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    pub fn str(self: *Reader) ![]const u8 {
        const n = try self.u16_();
        return self.take(n);
    }
    pub fn rest(self: *Reader) []const u8 {
        return self.data[self.pos..];
    }
};

/// Buffers de leitura reaproveitados por conexão.
pub const RecvBuf = struct {
    cipher: std.ArrayList(u8) = .empty,
    plain: std.ArrayList(u8) = .empty,

    pub fn deinit(rb: *RecvBuf) void {
        rb.cipher.deinit(gpa);
        rb.plain.deinit(gpa);
    }

    /// Não guarda buffers gigantes pra sempre (depois de um IDR enorme).
    fn trim(rb: *RecvBuf) void {
        // (passou de 1 MB por causa de uma mensagem rara: IDR enorme, imagem no chat)
        if (rb.cipher.capacity > 1024 * 1024 and rb.cipher.items.len < 256 * 1024) rb.cipher.shrinkAndFree(gpa, rb.cipher.items.len);
        if (rb.plain.capacity > 1024 * 1024 and rb.plain.items.len < 256 * 1024) rb.plain.shrinkAndFree(gpa, rb.plain.items.len);
    }
};

/// Lê e decifra uma mensagem. Retorna o tipo; o payload fica em `rb.plain.items[1..]`.
pub fn recvMsg(s: net.Socket, ch: *crypto.Channel, rb: *RecvBuf) !Type {
    var hdr: [4]u8 = undefined;
    try net.recvAll(s, &hdr);
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len == wrong_password_marker) return error.WrongPassword;
    if (len < 1 + crypto.tag_len or len > max_msg) return error.BadMessage;
    try rb.cipher.resize(gpa, len);
    try net.recvAll(s, rb.cipher.items);
    try rb.plain.resize(gpa, len - crypto.tag_len);
    try ch.open(rb.cipher.items, rb.plain.items);
    rb.trim();
    return @enumFromInt(rb.plain.items[0]);
}

pub fn payloadOf(rb: *RecvBuf) []const u8 {
    return rb.plain.items[1..];
}

/// Quadros enviados e ainda não confirmados (ack). Mede há quanto tempo o mais
/// velho está "no caminho" — nossa fila, kernel, túnel, rede, o outro lado — e
/// o menor atraso de confirmação visto (≈ RTT). A diferença é o atraso que a
/// conexão está acumulando, em qualquer ponto do caminho (o túnel do ngrok
/// tem buffers que o servidor nunca enxergaria só olhando a própria fila).
pub const AckWindow = struct {
    const cap = 128;
    seqs: [cap]u32 = undefined,
    times: [cap]u64 = undefined, // µs em que cada quadro foi enviado
    keys: [cap]bool = undefined,
    head: usize = 0,
    len: usize = 0,
    // menor atraso de confirmação (≈ RTT) em janelas de 10 s: a atual e a
    // anterior. 0 = sem medida.
    min_cur: u64 = 0,
    min_prev: u64 = 0,
    epoch_at: u64 = 0,
    // IDR: é grande, então ele e os frames que vêm atrás chegam mais tarde
    key_pending: bool = false, // tem IDR a caminho
    key_delay_us: u64 = 0, // quanto o último IDR levou pra ser confirmado
    key_acked_at: u64 = 0,

    pub fn reset(w: *AckWindow) void {
        w.head = 0;
        w.len = 0;
        w.key_pending = false;
    }

    pub fn sent(w: *AckWindow, seq: u32, now: u64, key: bool) void {
        if (w.len == cap) { // cheia: esquece o mais velho
            w.head = (w.head + 1) % cap;
            w.len -= 1;
        }
        const i = (w.head + w.len) % cap;
        w.seqs[i] = seq;
        w.times[i] = now;
        w.keys[i] = key;
        w.len += 1;
        if (key) w.key_pending = true;
    }

    /// Confirmação cumulativa: tudo até `seq` chegou.
    pub fn acked(w: *AckWindow, seq: u32, now: u64) void {
        while (w.len > 0) {
            const s = w.seqs[w.head];
            if (@as(i32, @bitCast(s -% seq)) > 0) break; // ainda não chegou nesse
            // IDR não serve de referência: o atraso dele inclui a transferência
            if (s == seq and !w.keys[w.head]) w.sample(now -| w.times[w.head], now);
            if (w.keys[w.head]) {
                w.key_pending = false;
                w.key_delay_us = now -| w.times[w.head];
                w.key_acked_at = now;
            }
            w.head = (w.head + 1) % cap;
            w.len -= 1;
        }
    }

    fn sample(w: *AckWindow, d: u64, now: u64) void {
        const v = @max(d, 1);
        // a cada 10 s começa uma janela nova: se a rota piorou, a referência
        // acompanha em 10-20 s (mas uma fila parada não vira "o normal")
        if (w.epoch_at == 0 or now - w.epoch_at > 10_000_000) {
            w.min_prev = w.min_cur;
            w.min_cur = v;
            w.epoch_at = now;
        } else if (v < w.min_cur) w.min_cur = v;
    }

    /// RTT de referência (o menor atraso recente), limitado a 400 ms: se não
    /// teve nenhum quadro rápido (conexão congestionada desde o começo), as
    /// medidas estão todas infladas e não servem de "normal".
    pub fn baseUs(w: *const AckWindow, default_base: u64) u64 {
        var b: u64 = w.min_cur;
        if (w.min_prev != 0 and (b == 0 or w.min_prev < b)) b = w.min_prev;
        if (b == 0) return default_base;
        return @min(b, 400_000);
    }

    /// Esquece os `n` mais novos (descartados antes de saírem da fila).
    pub fn dropNewest(w: *AckWindow, n: usize) void {
        w.len -= @min(n, w.len);
        w.key_pending = false;
        for (0..w.len) |i| {
            if (w.keys[(w.head + i) % cap]) w.key_pending = true;
        }
    }

    /// Folga extra de atraso por causa de IDR: enquanto ele está a caminho,
    /// muita; depois que chegou, o tempo que ele levou (os frames que vieram
    /// atrás dele ainda estão escoando), diminuindo até zero em 4 s.
    pub fn keyAllowanceUs(w: *const AckWindow, now: u64) u64 {
        if (w.key_pending) return 4_000_000;
        const since = now -| w.key_acked_at;
        if (w.key_acked_at == 0 or since >= 4_000_000) return 0;
        return w.key_delay_us * (4_000_000 - since) / 4_000_000;
    }

    pub fn oldestAgeUs(w: *const AckWindow, now: u64) u64 {
        if (w.len == 0) return 0;
        return now -| w.times[w.head];
    }

    /// Atraso acumulado no caminho, acima do normal da conexão.
    /// `default_base` vale enquanto não há medida.
    pub fn excessUs(w: *const AckWindow, now: u64, default_base: u64) u64 {
        if (w.len == cap) return std.math.maxInt(u32); // nada confirmado há um tempão
        return w.oldestAgeUs(now) -| w.baseUs(default_base);
    }
};

/// Fila de envio com uma thread escritora por conexão.
pub const SendQueue = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Cond = .{},
    items: std.ArrayList(*Msg) = .empty,
    head: usize = 0,
    bytes: usize = 0,
    closed: bool = false,
    sending: bool = false, // a escritora tirou uma mensagem e ainda está mandando
    sent_bytes: std.atomic.Value(u64) = .init(0),

    pub fn push(q: *SendQueue, m: *Msg) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.closed) return;
        q.items.append(gpa, m.retain()) catch {
            m.release();
            return;
        };
        q.bytes += m.data.len;
        q.cond.signal();
    }

    /// Fura a fila (confirmações, voz e som da transmissão: não podem esperar
    /// atrás de quadros; um IDR de 60 KB a 2 Mbit/s segura ~240 ms),
    /// mas fica depois de outras urgentes que já estavam lá (ordem entre elas).
    pub fn pushUrgent(q: *SendQueue, m: *Msg) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.closed) return;
        var at = q.head;
        while (at < q.items.items.len and isUrgent(q.items.items[at].typ)) at += 1;
        if (at == q.head and q.head > 0) {
            q.head -= 1;
            q.items.items[q.head] = m.retain();
        } else {
            q.items.insert(gpa, at, m.retain()) catch {
                m.release();
                return;
            };
        }
        q.bytes += m.data.len;
        q.cond.signal();
    }

    fn isUrgent(t: Type) bool {
        return t == .ack or t == .viewer_slow or t == .voice or t == .pointer or t == .audio or t == .draw or t == .cursor;
    }

    pub fn pushUrgentOwned(q: *SendQueue, m: *Msg) void {
        q.pushUrgent(m);
        m.release();
    }

    /// Enfileira e solta a referência do chamador.
    pub fn pushOwned(q: *SendQueue, m: *Msg) void {
        q.push(m);
        m.release();
    }

    /// Tudo o que entrou na fila já foi entregue ao sistema (ou a escritora morreu).
    pub fn flushed(q: *SendQueue) bool {
        q.mutex.lock();
        defer q.mutex.unlock();
        return q.closed or (q.head == q.items.items.len and !q.sending);
    }

    pub fn queuedBytes(q: *SendQueue) usize {
        q.mutex.lock();
        defer q.mutex.unlock();
        return q.bytes;
    }

    /// Joga fora os frames puláveis (ninguém usa de referência) de `from` que
    /// ainda não saíram: alivia na hora quem acabou de ser afinado.
    pub fn dropDroppable(q: *SendQueue, from: u32) usize {
        q.mutex.lock();
        defer q.mutex.unlock();
        var w: usize = q.head;
        var dropped: usize = 0;
        for (q.items.items[q.head..]) |m| {
            if (m.typ == .frame and m.from == from and m.flags & frame_droppable != 0) {
                q.bytes -= m.data.len;
                m.release();
                dropped += 1;
            } else {
                q.items.items[w] = m;
                w += 1;
            }
        }
        q.items.shrinkRetainingCapacity(w);
        return dropped;
    }

    /// Joga fora frames ainda não enviados (de um remetente, ou todos se
    /// from == null). Retorna quantos descartou.
    pub fn dropFrames(q: *SendQueue, from: ?u32) usize {
        q.mutex.lock();
        defer q.mutex.unlock();
        var w: usize = q.head;
        var dropped: usize = 0;
        for (q.items.items[q.head..]) |m| {
            if (m.typ == .frame and (from == null or m.from == from.?)) {
                q.bytes -= m.data.len;
                m.release();
                dropped += 1;
            } else {
                q.items.items[w] = m;
                w += 1;
            }
        }
        q.items.shrinkRetainingCapacity(w);
        return dropped;
    }

    fn pop(q: *SendQueue) ?*Msg {
        q.mutex.lock();
        defer q.mutex.unlock();
        while (q.head == q.items.items.len and !q.closed) q.cond.wait(&q.mutex);
        if (q.closed) return null;
        const m = q.items.items[q.head];
        q.sending = true;
        q.head += 1;
        if (q.head == q.items.items.len) {
            q.head = 0;
            q.items.clearRetainingCapacity();
        } else if (q.head >= 256 and q.head * 2 >= q.items.items.len) {
            // fila que nunca esvazia (espectador sempre atrasado): compacta
            // de vez em quando em vez de só crescer
            const rest = q.items.items.len - q.head;
            std.mem.copyForwards(*Msg, q.items.items[0..rest], q.items.items[q.head..]);
            q.items.shrinkRetainingCapacity(rest);
            q.head = 0;
        }
        q.bytes -= m.data.len;
        return m;
    }

    /// Próxima mensagem, se já estiver na fila e couber em `limit` (não espera).
    fn tryPop(q: *SendQueue, limit: usize) ?*Msg {
        q.mutex.lock();
        defer q.mutex.unlock();
        if (q.closed or q.head == q.items.items.len) return null;
        const m = q.items.items[q.head];
        if (m.data.len > limit) return null;
        q.head += 1;
        if (q.head == q.items.items.len) {
            q.head = 0;
            q.items.clearRetainingCapacity();
        }
        q.bytes -= m.data.len;
        return m;
    }

    fn doneSending(q: *SendQueue) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        q.sending = false;
    }

    pub fn close(q: *SendQueue) void {
        q.mutex.lock();
        defer q.mutex.unlock();
        q.closed = true;
        for (q.items.items[q.head..]) |m| m.release();
        q.items.clearRetainingCapacity();
        q.head = 0;
        q.bytes = 0;
        q.cond.broadcast();
    }

    pub fn deinit(q: *SendQueue) void {
        q.close();
        q.items.deinit(gpa);
    }

    /// Acrescenta a mensagem cifrada (tamanho + cifrado + tag) em `out`.
    fn sealInto(out: *std.ArrayList(u8), ch: *crypto.Channel, m: *Msg) !void {
        const plain = m.data[4..];
        const at = out.items.len;
        try out.resize(gpa, at + 4 + plain.len + crypto.tag_len);
        std.mem.writeInt(u32, out.items[at..][0..4], @intCast(plain.len + crypto.tag_len), .little);
        ch.seal(plain, out.items[at + 4 ..]);
    }

    /// Loop da thread escritora: cifra e envia. Sai quando a fila fecha ou o envio falha.
    /// `link`: caminho UDP (quadro/som/voz vão por ele quando está de pé).
    pub fn writerLoop(q: *SendQueue, s: net.Socket, ch: *crypto.Channel, link: ?*const std.atomic.Value(?*udp.Link)) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        while (q.pop()) |m| {
            defer m.release();
            if (link) |lk| if (lk.load(.acquire)) |l| if (l.trySend(m)) {
                q.doneSending();
                _ = q.sent_bytes.fetchAdd(m.data.len, .monotonic);
                continue;
            };
            out.clearRetainingCapacity();
            sealInto(&out, ch, m) catch {
                q.close();
                net.shutdown(s);
                return;
            };
            // o que mais já estiver esperando (ack, voz, som, chat...) vai na
            // mesma chamada ao sistema — sem esperar nada que ainda não chegou
            while (out.items.len < 64 * 1024) {
                const nx = q.tryPop(16 * 1024) orelse break;
                defer nx.release();
                if (link) |lk| if (lk.load(.acquire)) |l| if (l.trySend(nx)) {
                    _ = q.sent_bytes.fetchAdd(nx.data.len, .monotonic);
                    continue;
                };
                sealInto(&out, ch, nx) catch break;
            }
            net.sendAll(s, out.items) catch {
                q.close(); // ninguém espera por uma escritora morta
                net.shutdown(s);
                return;
            };
            q.doneSending();
            _ = q.sent_bytes.fetchAdd(out.items.len, .monotonic);
            if (out.capacity > 1024 * 1024 and out.items.len < 256 * 1024) out.shrinkAndFree(gpa, out.items.len);
        }
    }
};

/// Cifra e manda uma mensagem na hora, sem fila (o servidor manda a
/// identidade antes de existir a thread escritora). Solta a mensagem.
pub fn sendNow(s: net.Socket, ch: *crypto.Channel, m: *Msg) !void {
    defer m.release();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try SendQueue.sealInto(&out, ch, m);
    try net.sendAll(s, out.items);
}
