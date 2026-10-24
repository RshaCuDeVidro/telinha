"""Client: uma pessoa (bot) na sala. Conecta, mantém o estado (quem está,
canais, mensagens) e chama os seus handlers de evento. Reconecta sozinho se
a conexão cair; se a sala recusar (expulsou, baniu, não aceita bots...), para.

    client = Client("telinha://sala.exemplo:7777#senha", "Meu bot")

    @client.on("message")
    async def oi(msg):
        if msg.text == "oi":
            await msg.respond("olá!")

    client.run()
"""
from __future__ import annotations

import asyncio
import inspect
import logging
import os
import random
import time
from collections.abc import Awaitable, Callable
from pathlib import Path

from . import wire
from .connection import Connection, ConnectError, WrongPassword, race, secure
from .crypto import AuthFailed, fingerprint, transcript, verify_identity
from .embed import Click, Embed
from .image import ChatImage, encode as encode_image
from .invite import Invite
from .models import ChannelInfo, FileInfo, Member, Message, Quote, Welcome
from .wire import MsgType, Reader, Writer

log = logging.getLogger("telinha")

__all__ = ["Client", "Denied", "EVENTS"]

SDK_VERSION = "0.2.1"
PING_EVERY = 10.0  # s
DEAD_AFTER = 45.0  # s sem nada chegando: a conexão morreu
FILE_CHUNK = 32 * 1024
FILE_WINDOW = 8  # pedaços sem confirmação no ar (subindo)
GET_CHUNK = 64 * 1024
GET_WINDOW = 4  # pedidos no ar (baixando)
SWITCH_GAP = 0.85  # s entre trocas de canal/call (o servidor recusa mais rápido que 800 ms)
IMAGE_GAP = 1.6  # s entre imagens (o servidor descarta mais rápido que 1,5 s)
EDIT_GAP = 0.25  # s entre edições (o servidor ignora mais rápido que 200 ms)

EVENTS = (
    "ready",  # (welcome: Welcome) entrou (de novo, depois de reconectar também)
    "message",  # (msg: Message) mensagem no chat (do canal ou privada; inclui as do próprio bot)
    "join",  # (member: Member) apareceu alguém na sala (no meu canal ou na minha call)
    "leave",  # (member: Member) saiu
    "members",  # (members: list[Member]) a lista mudou
    "reaction",  # (message_id: int, member_id: int, reaction: int, on: bool)
    "channels",  # (current: str, channels: dict[str, ChannelInfo])
    "notice",  # (kind: int, text: str, extra: int) algo que um admin fez com o bot
    "voice",  # (member_id: int, seq: int, opus: bytes) voz de alguém na call
    "web_link",  # (url: str) link pra assistir pelo navegador
    "action",  # (click: Click) alguém clicou num botão de um cartão do bot
    "edit",  # (message_id: int, text: str, embed: Embed | None) uma mensagem mudou
    "keyreq",  # (kind: int) a sala quer um quadro completo da transmissão do bot (alguém começou a assistir)
    "pointer",  # (member_id: int, x: float, y: float, flags: int) ponteiro de quem assiste o bot (x, y de 0 a 1; flags & POINTER_PING = clique)
    "disconnect",  # (reason: str) caiu (vai tentar de novo, a não ser que tenha sido recusado)
)


class Denied(Exception):
    """A sala recusou o bot ou tirou ele (o motivo vem da sala). Não reconecta."""

    def __init__(self, reason: str, code: int):
        super().__init__(reason)
        self.reason = reason
        self.code = wire.Deny(code) if code in wire.Deny._value2member_map_ else code


class Client:
    def __init__(
        self,
        invite: str | Invite,
        name: str,
        *,
        password: str | None = None,
        channel: str | None = None,
        bot_token: str = "",
        key: int | None = None,
        reconnect: bool = True,
    ):
        """
        invite: o convite (telinha://...), ou só host:porta.
        name: o nome que aparece na sala (até 32 bytes).
        password: a senha da sala (se não vier no convite).
        channel: canal pra entrar (se não vier no convite; senão o padrão).
        bot_token: se a sala pede um token de bot (telinha-server --token-bots).
        key: identifica o bot pra banimento (padrão: sorteada e fixa por nome
             durante o processo; passe uma fixa pra o ban valer entre execuções).
        """
        self.invite = invite if isinstance(invite, Invite) else Invite.parse(invite)
        self.name = name
        self.password = password if password is not None else self.invite.password
        self.want_channel = channel if channel is not None else (self.invite.channel or "")
        self.bot_token = bot_token
        self.key = key or random.SystemRandom().randrange(1, 2**63)
        self.reconnect = reconnect

        # estado da sala (atualizado pelas mensagens)
        self.me = 0
        self.room = ""
        self.welcome: Welcome | None = None
        self.members: dict[int, Member] = {}
        self.channel = ""  # canal de texto atual
        self.call = ""  # call atual ("" = nenhuma)
        self.channels: dict[str, ChannelInfo] = {}
        self.room_locked = False
        self.fingerprint: str | None = None
        self.web_link = ""
        self.clock_offset_us = 0  # relógio da sala - o meu

        self._handlers: dict[str, list[Callable[..., Awaitable[None]]]] = {e: [] for e in EVENTS}
        self._conn: Connection | None = None
        self._stopping = False
        self._ready_ev: asyncio.Event | None = None
        self._next_req = 1
        self._file_ready: dict[int, asyncio.Future] = {}
        self._uploads: dict[int, "_Upload"] = {}
        self._downloads: dict[int, "_Download"] = {}
        self._voice_seq = 0
        self._frame_seq = 0
        self._audio_seq = 0
        self.streaming = False  # o bot está transmitindo (ver telinha.video)
        self._stream_args: tuple[int, int, int, bool] | None = None
        self._last_rx = 0.0
        self._ping_rtt_us = 0
        self._mic = False
        self._deaf = False
        self._last_switch = 0.0
        self._last_image = 0.0
        self._next_edit = 0.0  # quando a próxima edição pode sair
        self._echo: list[tuple[str, int, asyncio.Future]] = []  # mensagens minhas esperando voltar (pra pegar o id)
        self._tasks: set[asyncio.Task] = set()  # handlers rodando
        self._buttons: dict[int, list] = {}  # id da mensagem → callbacks dos botões dela

    # ------------------------------------------------------------ eventos
    def on(self, event: str):
        """Decorador: @client.on("message") async def f(msg): ..."""
        if event not in self._handlers:
            raise ValueError(f"evento desconhecido: {event} (tem: {', '.join(EVENTS)})")

        def deco(fn):
            if not inspect.iscoroutinefunction(fn):
                raise TypeError("o handler precisa ser async def")
            self._handlers[event].append(fn)
            return fn
        return deco

    def off(self, event: str, fn) -> None:
        """Tira um handler colocado com on()."""
        if fn in self._handlers.get(event, []):
            self._handlers[event].remove(fn)

    async def _emit(self, event: str, *args) -> None:
        # cada handler numa tarefa: um handler que espera algo da sala (send
        # esperando a mensagem voltar, um download) não trava a leitura
        for fn in list(self._handlers[event]):
            t = asyncio.create_task(self._run_handler(event, fn, args))
            self._tasks.add(t)
            t.add_done_callback(self._tasks.discard)

    async def _run_handler(self, event: str, fn, args) -> None:
        try:
            await fn(*args)
        except Exception:
            log.exception("erro no handler de %s", event)

    # ------------------------------------------------------------ ciclo de vida
    def run(self) -> None:
        """Roda até parar (Ctrl+C também para)."""
        try:
            asyncio.run(self.start())
        except KeyboardInterrupt:
            pass

    async def start(self) -> None:
        """Conecta e fica na sala; reconecta se cair. Retorna quando `stop()`;
        levanta Denied se a sala recusar ou tirar o bot."""
        self._stopping = False
        try:
            await self._loop()
        finally:
            for t in list(self._tasks):
                t.cancel()

    async def _loop(self) -> None:
        backoff = 1.0
        while not self._stopping:
            try:
                await self._session()
                backoff = 1.0
            except Denied:
                raise
            except WrongPassword:
                raise
            except (ConnectError, OSError, asyncio.IncompleteReadError, AuthFailed, wire.Truncated, asyncio.TimeoutError) as e:
                if self._stopping:
                    break
                if not self.reconnect:
                    raise
                await self._emit("disconnect", str(e) or type(e).__name__)
                log.warning("sem conexão com a sala (%s); tentando de novo em %.0f s", e or type(e).__name__, backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30.0)
            finally:
                self._ready.clear()

    async def stop(self) -> None:
        self._stopping = True
        if self._conn:
            await self._conn.close()
        for t in list(self._tasks):
            t.cancel()

    async def wait_ready(self, timeout: float | None = None) -> None:
        """Espera o bot estar dentro da sala."""
        await asyncio.wait_for(self._ready.wait(), timeout)

    @property
    def _ready(self) -> asyncio.Event:
        # criado no loop em que o bot roda (asyncio.Event fora de um loop não serve)
        if self._ready_ev is None:
            self._ready_ev = asyncio.Event()
        return self._ready_ev

    async def _session(self) -> None:
        conn = await race(self.invite)
        self._conn = conn
        try:
            await secure(conn, self.invite, self.password)
            self.fingerprint = conn.fingerprint
            await conn.send(
                Writer(MsgType.HELLO).str(self.name, 32).str("").u64(self.key).str(f"sdk-python/{SDK_VERSION}")
                .u8(1).u8(wire.FEAT_BOT | wire.FEAT_DM | wire.FEAT_CALLS | wire.FEAT_EMBED).str(self.want_channel).str(self.bot_token).done()
            )
            self._last_rx = time.monotonic()
            pinger = asyncio.create_task(self._pinger(conn))
            try:
                welcomed = False
                while True:
                    try:
                        typ, payload = await conn.recv()
                    except AuthFailed:
                        # antes de entrar, não decifrar só pode ser a senha
                        if not welcomed:
                            raise WrongPassword("senha errada") from None
                        raise
                    self._last_rx = time.monotonic()
                    if typ == MsgType.WELCOME:
                        welcomed = True
                    await self._dispatch(typ, payload)
            finally:
                pinger.cancel()
        finally:
            self._conn = None
            for fut in self._file_ready.values():
                if not fut.done():
                    fut.set_exception(ConnectError("a conexão caiu"))
            self._file_ready.clear()
            for up in self._uploads.values():
                up.fail(ConnectError("a conexão caiu"))
            self._uploads.clear()
            for dl in self._downloads.values():
                dl.fail(ConnectError("a conexão caiu"))
            self._downloads.clear()
            await conn.close()

    async def _pinger(self, conn: Connection) -> None:
        while True:
            await asyncio.sleep(PING_EVERY)
            if time.monotonic() - self._last_rx > DEAD_AFTER:
                log.warning("nada chegou da sala em %.0f s: reconectando", DEAD_AFTER)
                await conn.close()
                return
            try:
                await conn.send(Writer(MsgType.PING).u64(time.monotonic_ns() // 1000).done())
            except OSError:
                return

    async def _send(self, payload: bytes) -> None:
        if not self._conn or not self._conn.channel:
            raise ConnectError("o bot não está conectado na sala")
        await self._conn.send(payload)

    # ------------------------------------------------------------ recebendo
    async def _dispatch(self, typ: int, p: bytes) -> None:
        r = Reader(p)
        if typ == MsgType.IDENTITY:
            if len(p) >= 96 and verify_identity(p[:32], p[32:96], transcript(self._conn.hs.hello, self._conn.server_hello)):
                self.fingerprint = fingerprint(p[:32])
        elif typ == MsgType.WELCOME:
            self.me = r.u32()
            self.room = r.str()
            admin = r.u8() != 0
            server_clock = r.u64()
            self.clock_offset_us = server_clock - time.monotonic_ns() // 1000
            r.u64()  # instância
            route = r.u8()
            ver = r.opt(r.str, "")
            udp = r.opt(r.u8, 0)
            if udp:
                r.u32()  # token do UDP (o SDK fica só no TCP)
            feats = r.opt(r.u8, 0)
            self.welcome = Welcome(self.me, self.room, admin, route, ver, feats)
            self._mic = self._deaf = False
            self.streaming = False
            if self._stream_args:  # reconectou no meio de uma transmissão: volta a transmitir
                w, h, fps, audio = self._stream_args
                await self.start_stream(w, h, fps, audio=audio)
            log.info("dentro da sala %r como %s (id %d)", self.room, self.name, self.me)
            self._ready.set()
            await self._emit("ready", self.welcome)
        elif typ == MsgType.DENIED:
            reason = r.str()
            code = r.opt(r.u8, 0)
            raise Denied(reason, code)
        elif typ == MsgType.MEMBERS:
            await self._on_members(r)
        elif typ == MsgType.CHAT:
            msg = self._parse_chat(r)
            if msg.author_id == self.me and not msg.history:
                for i, (text, to, fut) in enumerate(self._echo):
                    if text == msg.text and to == msg.to_id and not fut.done():
                        fut.set_result(msg)
                        del self._echo[i]
                        break
            await self._emit("message", msg)
        elif typ == MsgType.REACT:
            mid, frm, reaction, on = r.u32(), r.u32(), r.u8(), r.u8() != 0
            await self._emit("reaction", mid, frm, reaction, on)
        elif typ == MsgType.CHANNEL:
            await self._on_channels(r)
        elif typ == MsgType.NOTICE:
            kind, text = r.u8(), r.str()
            extra = r.opt(r.u8, 0)
            if kind == wire.Notice.FILE_GONE:
                for dl in list(self._downloads.values()):
                    dl.fail(FileNotFoundError(text))
            await self._emit("notice", kind, text, extra)
        elif typ == MsgType.PONG:
            t, server = r.u64(), r.u64()
            now = time.monotonic_ns() // 1000
            rtt = max(0, now - t)
            self._ping_rtt_us = rtt
            self.clock_offset_us = server + rtt // 2 - now
        elif typ == MsgType.VOICE:
            frm, seq = r.u32(), r.u32()
            if self._handlers["voice"]:
                await self._emit("voice", frm, seq, r.rest())
        elif typ == MsgType.FILE_READY:
            req, fid, reason = r.u32(), r.u32(), r.opt(r.str, "")
            fut = self._file_ready.pop(req, None)
            if fut and not fut.done():
                fut.set_result((fid, reason))
        elif typ == MsgType.FILE_ACK:
            fid, got = r.u32(), r.u64()
            up = self._uploads.get(fid)
            if up:
                up.ack(got)
        elif typ == MsgType.FILE_DATA:
            fid, pos = r.u32(), r.u64()
            dl = self._downloads.get(fid)
            if dl:
                dl.data(pos, r.rest())
        elif typ == MsgType.WEB_LINK:
            self.web_link = r.str()
            await self._emit("web_link", self.web_link)
        elif typ == MsgType.EMBED_ACTION:
            click = Click(r.u32(), r.u8(), r.u32(), r.str(), _client=self)
            click.channel = r.opt(r.str, "")
            click.call = r.opt(r.str, "")
            cbs = self._buttons.get(click.message_id) or []
            if click.button < len(cbs) and cbs[click.button]:
                t = asyncio.create_task(self._run_handler("action", cbs[click.button], (click,)))
                self._tasks.add(t)
                t.add_done_callback(self._tasks.discard)
            await self._emit("action", click)
        elif typ == MsgType.CHAT_EDIT:
            mid, text = r.u32(), r.str()
            n = r.opt(r.u32, 0)
            emb = Embed.decode(r.take(n)) if n else None
            await self._emit("edit", mid, text, emb)
        elif typ == MsgType.KEYREQ:
            await self._emit("keyreq", r.opt(r.u8, wire.KIND_SCREEN))
        elif typ == MsgType.POINTER:
            frm, stream, x, y, flags = r.u32(), r.u32(), r.u16(), r.u16(), r.u8()
            if stream == self.me & 0x7FFFFFFF and x != wire.COORD_NONE:
                await self._emit("pointer", frm, x / 65534, y / 65534, flags)
        # o resto (quadros, cursor, desenhos...) é de quem assiste transmissão

    async def _on_members(self, r: Reader) -> None:
        self.room_locked = bool(r.u8() & wire.ROOM_LOCKED)
        n = r.u16()
        members: list[Member] = []
        for _ in range(n):
            mid, name, flags, route = r.u32(), r.str(), r.u8(), r.u8()
            r.take(5 + 5)  # tamanho/fps da tela e da câmera
            k = r.u16()
            watching = [r.u32() for _ in range(k)]
            members.append(Member(mid, name, flags, route & 0x1F, bool(route & 0x80), bool(route & wire.MEMBER_IN_CHAN), bool(route & wire.MEMBER_IN_CALL), watching=watching))
        for m in members:
            m.version = r.opt(r.str, "")
        for m in members:
            m.bot = bool(r.opt(r.u8, 0) & wire.MEMBER_KIND_BOT)
        # servidor antigo não marca canal/call: todo mundo está em tudo
        if not any(m.in_channel for m in members):
            for m in members:
                m.in_channel = m.in_call = True
        old = self.members
        self.members = {m.id: m for m in members}
        for m in members:
            if m.id not in old and m.id != self.me and old:
                await self._emit("join", m)
        for mid, m in old.items():
            if mid not in self.members:
                await self._emit("leave", m)
        await self._emit("members", members)

    async def _on_channels(self, r: Reader) -> None:
        current = r.str()
        n = r.u8()
        chans = [ChannelInfo(r.str(), r.u16(), 0, r.u8()) for _ in range(n)]
        for c in chans:
            c.in_call = r.opt(r.u16, 0)
        for c in chans:
            c.topic = r.opt(r.str, "")
        self.call = r.opt(r.str, current)
        self.channel = current
        self.channels = {c.name: c for c in chans}
        await self._emit("channels", current, self.channels)

    def _parse_chat(self, r: Reader) -> Message:
        m = Message(r.u32(), r.u32(), r.str(), r.str(), r.u64(), _client=self, channel=self.channel)
        m.history = bool(r.u8() & wire.CHAT_HISTORY)
        img = r.opt(r.u8, 0)
        if img == wire.CHAT_IMG_H264:
            r.u16(), r.u16()
            r.take(r.u32())
            m.has_image = True
        elif img == wire.CHAT_IMG_EXPIRED:
            m.has_image = True
        for _ in range(r.opt(r.u8, 0)):
            m.reactions.append((r.u8(), r.u32()))
        reply = r.opt(r.u32, 0)
        if reply:
            m.quote = Quote(reply, r.u32(), r.str(), r.str())
        m.to_id = r.opt(r.u32, 0)
        if m.to_id:
            m.to_name = r.str()
        fid = r.opt(r.u32, 0)
        if fid:
            m.file = FileInfo(fid, r.str(), r.u64())
        n = r.opt(r.u32, 0)
        if n:
            m.embed = Embed.decode(r.take(n))
        # só bot recebe: onde quem mandou está
        m.author_channel = r.opt(r.str, "")
        m.author_call = r.opt(r.str, "")
        return m

    # ------------------------------------------------------------ mandando
    async def send(self, text: str = "", *, embed: Embed | None = None, image: "str | os.PathLike | ChatImage | None" = None,
                   reply_to: int = 0, to: int = 0, wait: bool = True) -> Message | None:
        """Manda no chat do canal atual (ou em privado, com `to` = id da pessoa).

        `embed`: um cartão (Embed); o `text` vira o que app antigo mostra no lugar.
        `image`: arquivo, link ou ChatImage (com Embed(thumbnail=True) vira a capa).
        `reply_to`: id da mensagem que está respondendo (cita ela).
        Texto maior que 4000 bytes vai em mais de uma mensagem.

        Retorna a mensagem como a sala registrou (com o id, pra reagir, citar
        ou editar depois), ou None com wait=False / se ela não voltar em 5 s.
        Os botões do cartão com on_click passam a responder."""
        img = image if isinstance(image, ChatImage) or image is None else await encode_image(image, **({"square": 320} if embed and embed.thumbnail else {}))
        if img is not None:
            # o servidor descarta a mensagem inteira se vier imagem a menos de 1,5 s
            # da anterior: espera o que faltar (até 1,6 s) em vez de perder a mensagem
            wait_img = self._last_image + IMAGE_GAP - time.monotonic()
            if wait_img > 0:
                await asyncio.sleep(wait_img)
            self._last_image = time.monotonic()
        embed_bytes = embed.encode() if embed else b""
        parts = _split(text) if text else [""]
        first: asyncio.Future | None = None
        for i, part in enumerate(parts):
            if wait and first is None:
                first = asyncio.get_running_loop().create_future()
                self._echo.append((part.strip(), to, first))
            w = Writer(MsgType.CHAT).str(part)
            if img and i == 0:
                w.u8(wire.CHAT_IMG_H264).u16(img.width).u16(img.height).u32(len(img.data)).bytes(img.data)
            else:
                w.u8(wire.CHAT_IMG_NONE)
            w.u32(reply_to).u32(to)
            last = i == len(parts) - 1
            w.u32(len(embed_bytes) if last else 0).bytes(embed_bytes if last else b"")
            await self._send(w.done())
            reply_to = 0  # só a primeira parte cita
        if first is None:
            return None
        try:
            msg = await asyncio.wait_for(first, 5)
        except asyncio.TimeoutError:
            return None
        finally:
            self._echo = [e for e in self._echo if e[2] is not first]
        if embed and any(b.on_click for b in embed.buttons):
            self._remember_buttons(msg.id, embed)
        return msg

    async def edit(self, message_id: int, text: str, *, embed: Embed | None = None) -> None:
        """Muda uma mensagem do próprio bot (o texto e o cartão; a imagem fica).
        Bom pra atualizar um "tocando agora" no lugar de mandar outro."""
        e = embed.encode() if embed else b""
        # o servidor ignora edição a menos de 200 ms da anterior: cada uma
        # reserva a sua vez (duas seguidas, tipo "continuar" e "pular", saem as duas)
        now = time.monotonic()
        at = max(now, self._next_edit)
        self._next_edit = at + EDIT_GAP
        if at > now:
            await asyncio.sleep(at - now)
        await self._send(Writer(MsgType.CHAT_EDIT).u32(message_id).str(text).u32(len(e)).bytes(e).done())
        if embed is not None:
            self._remember_buttons(message_id, embed)

    def _remember_buttons(self, message_id: int, embed: Embed) -> None:
        self._buttons[message_id] = [b.on_click for b in embed.buttons]
        while len(self._buttons) > 300:  # os mais velhos saem
            self._buttons.pop(next(iter(self._buttons)))

    async def click(self, message_id: int, button: int) -> None:
        """Clica num botão de um cartão (de outro bot)."""
        await self._send(Writer(MsgType.EMBED_ACTION).u32(message_id).u8(button).done())

    async def react(self, message_id: int, reaction: wire.Reaction | int, on: bool = True) -> None:
        await self._send(Writer(MsgType.REACT).u32(message_id).u8(int(reaction)).u8(int(on)).done())

    async def join_channel(self, name: str, password: str = "") -> None:
        """Troca o canal de texto (o chat). Cria se não existir e o servidor deixar."""
        await self._switch_pause()
        await self._send(Writer(MsgType.CHANNEL).str(name).str(password).done())

    async def join_call(self, name: str, password: str = "") -> None:
        """Entra na call (voz) de um canal. Vazio = sai da call."""
        await self._switch_pause()
        await self._send(Writer(MsgType.CALL).str(name).str(password).done())

    async def _switch_pause(self) -> None:
        # o servidor aceita uma troca (canal ou call) a cada 800 ms: espera o que faltar
        wait = self._last_switch + SWITCH_GAP - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        self._last_switch = time.monotonic()

    async def leave_call(self) -> None:
        await self.join_call("")

    async def set_voice(self, mic: bool | None = None, deaf: bool | None = None) -> None:
        """Microfone ligado (aparece pra todo mundo) / surdo (não recebe voz)."""
        if mic is not None:
            self._mic = mic
        if deaf is not None:
            self._deaf = deaf
        await self._send(Writer(MsgType.VOICE_STATE).u8((wire.VOICE_MIC if self._mic else 0) | (wire.VOICE_DEAF if self._deaf else 0)).done())

    async def send_voice(self, opus_packet: bytes) -> None:
        """Um pacote Opus (48 kHz, mono ou estéreo) na call. Quem toca áudio
        deve mandar no ritmo (ver telinha.audio.Player)."""
        self._voice_seq = (self._voice_seq + 1) & 0xFFFFFFFF
        await self._send(Writer(MsgType.VOICE).u32(self._voice_seq).bytes(opus_packet).done())

    # ------------------------------------------------------------ transmissão
    async def start_stream(self, width: int, height: int, fps: int = 30, *, audio: bool = False) -> None:
        """Começa (ou muda a resolução de) a transmissão de tela do bot. Os
        quadros vão com send_frame; telinha.video faz isso pra você."""
        self._stream_args = (width, height, fps, audio)
        await self._send(Writer(MsgType.STREAM_START).u8(wire.KIND_SCREEN).u16(width).u16(height)
                         .u8(max(1, min(fps, 240))).u8(wire.STREAM_AUDIO if audio else 0).done())
        self.streaming = True

    async def stop_stream(self) -> None:
        self._stream_args = None
        if not self.streaming:
            return
        self.streaming = False
        try:
            await self._send(Writer(MsgType.STREAM_STOP).u8(wire.KIND_SCREEN).done())
        except ConnectError:
            pass

    async def send_frame(self, h264: bytes, *, key: bool, width: int, height: int, droppable: bool = False,
                         capture_us: int | None = None) -> None:
        """Um quadro H.264 (Annex B, um access unit) da transmissão do bot."""
        self._frame_seq = (self._frame_seq + 1) & 0xFFFFFFFF
        flags = (wire.FRAME_KEY if key else 0) | (wire.FRAME_DROPPABLE if droppable and not key else 0)
        ts = self.room_time_us() if capture_us is None else capture_us
        await self._send(Writer(MsgType.FRAME).u32(self._frame_seq).u8(flags).u64(ts).u16(width).u16(height)
                         .u16(wire.COORD_NONE).u16(wire.COORD_NONE).bytes(h264).done())

    async def send_stream_audio(self, opus_packet: bytes, *, capture_us: int | None = None) -> None:
        """Um pacote Opus (48 kHz estéreo, 10 ms) do som da transmissão: vai
        só pra quem assiste, junto com o vídeo (diferente da voz)."""
        self._audio_seq = (self._audio_seq + 1) & 0xFFFFFFFF
        ts = self.room_time_us() if capture_us is None else capture_us
        await self._send(Writer(MsgType.AUDIO).u32(self._audio_seq).u64(ts).bytes(opus_packet).done())

    # ------------------------------------------------------------ arquivos
    async def send_file(self, path: str | os.PathLike, *, name: str | None = None, to: int = 0, reply_to: int = 0,
                        progress: Callable[[int, int], None] | None = None) -> int:
        """Manda um arquivo (até 256 MB) pro chat do canal (ou em privado).
        Retorna o id do arquivo na sala."""
        if not self.welcome or not self.welcome.server_features & wire.SRV_FILES:
            raise ConnectError("essa sala não aceita arquivos (servidor antigo)")
        path = Path(path)
        size = path.stat().st_size
        req = self._next_req
        self._next_req += 1
        fut = asyncio.get_running_loop().create_future()
        self._file_ready[req] = fut
        await self._send(Writer(MsgType.FILE_PUT).u32(req).str(name or path.name, 120).u64(size).u32(to).u32(reply_to).done())
        fid, reason = await asyncio.wait_for(fut, 30)
        if not fid:
            raise ConnectError(reason or "a sala recusou o arquivo")
        up = _Upload(size)
        self._uploads[fid] = up
        try:
            with path.open("rb") as f:
                pos = 0
                while pos < size:
                    await up.room()
                    chunk = f.read(FILE_CHUNK)
                    if not chunk:
                        raise OSError("o arquivo diminuiu enquanto subia")
                    await self._send(Writer(MsgType.FILE_DATA).u32(fid).u64(pos).bytes(chunk).done())
                    pos += len(chunk)
                    up.sent = pos
                    if progress:
                        progress(up.acked, size)
            await up.finished()
            if progress:
                progress(size, size)
        except BaseException:
            if self._conn:
                try:
                    await self._send(Writer(MsgType.FILE_CANCEL).u32(fid).done())
                except (OSError, ConnectError):
                    pass
            raise
        finally:
            self._uploads.pop(fid, None)
        return fid

    async def download(self, file: FileInfo, dest: str | os.PathLike) -> Path:
        """Baixa um arquivo da sala (de uma mensagem: msg.file). `dest` pode ser
        uma pasta (usa o nome do arquivo) ou o caminho final."""
        dest = Path(dest)
        if dest.is_dir():
            dest = dest / Path(file.name).name
        part = dest.with_name(dest.name + ".parte")
        dl = _Download(file.size)
        self._downloads[file.id] = dl
        try:
            with part.open("wb") as f:
                asked = 0
                while dl.written < file.size:
                    while asked < file.size and asked - dl.written < GET_CHUNK * GET_WINDOW:
                        n = min(GET_CHUNK, file.size - asked)
                        await self._send(Writer(MsgType.FILE_GET).u32(file.id).u64(asked).u32(n).done())
                        asked += n
                    await dl.write_ready(f)
            part.replace(dest)
            return dest
        except BaseException:
            part.unlink(missing_ok=True)
            raise
        finally:
            self._downloads.pop(file.id, None)

    # ------------------------------------------------------------ ajudas
    def member(self, ident: int | str) -> Member | None:
        """Pelo id, ou pelo nome (sem diferença de maiúsculas, com ou sem @)."""
        if isinstance(ident, int):
            return self.members.get(ident)
        name = ident.lstrip("@").casefold()
        for m in self.members.values():
            if m.name.casefold() == name:
                return m
        return None

    def room_time_us(self) -> int:
        """Agora, no relógio da sala (o das mensagens)."""
        return time.monotonic_ns() // 1000 + self.clock_offset_us


def _split(text: str) -> list[str]:
    b = text.encode("utf-8")
    if len(b) <= wire.MAX_TEXT:
        return [text]
    parts = []
    while b:
        piece = wire.cut_utf8(b, wire.MAX_TEXT)
        cut = piece.rfind(b"\n")
        if cut > wire.MAX_TEXT // 2:
            piece = piece[:cut + 1]
        parts.append(piece.decode("utf-8"))
        b = b[len(piece):]
    return parts


class _Upload:
    """Ritmo da subida: até FILE_WINDOW pedaços sem confirmação."""

    def __init__(self, size: int):
        self.size = size
        self.sent = 0
        self.acked = 0
        self.error: BaseException | None = None
        self.cond = asyncio.Condition()

    def ack(self, got: int) -> None:
        self.acked = max(self.acked, got)
        asyncio.get_running_loop().create_task(self._wake())

    def fail(self, e: BaseException) -> None:
        self.error = e
        asyncio.get_running_loop().create_task(self._wake())

    async def _wake(self) -> None:
        async with self.cond:
            self.cond.notify_all()

    async def room(self) -> None:
        async with self.cond:
            await asyncio.wait_for(self.cond.wait_for(lambda: self.error or self.sent - self.acked < FILE_CHUNK * FILE_WINDOW), 120)
        if self.error:
            raise self.error

    async def finished(self) -> None:
        async with self.cond:
            await asyncio.wait_for(self.cond.wait_for(lambda: self.error or self.acked >= self.size), 120)
        if self.error:
            raise self.error


class _Download:
    def __init__(self, size: int):
        self.size = size
        self.written = 0
        self.pending: dict[int, bytes] = {}
        self.error: BaseException | None = None
        self.event = asyncio.Event()

    def data(self, pos: int, b: bytes) -> None:
        if pos >= self.written:
            self.pending[pos] = b
        self.event.set()

    def fail(self, e: BaseException) -> None:
        self.error = e
        self.event.set()

    async def write_ready(self, f) -> None:
        await asyncio.wait_for(self.event.wait(), 60)
        self.event.clear()
        if self.error:
            raise self.error
        while self.written in self.pending:
            b = self.pending.pop(self.written)
            f.write(b)
            self.written += len(b)
