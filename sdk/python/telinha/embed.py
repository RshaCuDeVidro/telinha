"""Cartões (embed): o que um bot manda pra aparecer como um cartão no chat,
com barra de cor, capa, título com link, campos, barra de progresso e
botões. Quem não entende cartão (app antigo) vê só o texto da mensagem.

    card = Embed(title="Popular Monster", kicker="NOW PLAYING", color=0xd946ef,
                 description="**Falling In Reverse**", progress=(0, 232_000))
    card.add_field("Requested by", "Ana")
    card.add_button("Skip", icon="next", on_click=skip)
    await bot.send("Now playing: Popular Monster", embed=card, image="cover.jpg")
"""
from __future__ import annotations

import enum
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from . import wire
from .wire import Reader, Writer


class Icon(enum.IntEnum):
    NONE = 0
    PLAY = 1
    PAUSE = 2
    NEXT = 3
    PREVIOUS = 4
    STOP = 5
    SHUFFLE = 6
    REPEAT = 7
    VOLUME_UP = 8
    VOLUME_DOWN = 9
    LIST = 10
    HEART = 11
    MUSIC = 12
    RADIO = 13
    SEARCH = 14
    PLUS = 15
    CHECK = 16
    CLOSE = 17
    LINK = 18
    JOIN = 19
    TRASH = 20
    STAR = 21
    DICE = 22


class Style(enum.IntEnum):
    NEUTRAL = 0
    PRIMARY = 1
    DANGER = 2
    SUCCESS = 3


def _icon(v: "Icon | str | int") -> int:
    if isinstance(v, str):
        return int(Icon[v.upper().replace("-", "_")])
    return int(v)


def _style(v: "Style | str | int") -> int:
    if isinstance(v, str):
        return int(Style[v.upper()])
    return int(v)


@dataclass
class Field:
    name: str
    value: str
    inline: bool = True


@dataclass
class Button:
    label: str = ""
    icon: Icon | str | int = Icon.NONE
    style: Style | str | int = Style.NEUTRAL
    disabled: bool = False
    # chamado quando alguém clica: async def f(click: Click)
    on_click: Callable[["Click"], Awaitable[Any]] | None = field(default=None, repr=False, compare=False)


@dataclass
class Click:
    """Alguém clicou num botão de um cartão do bot."""
    message_id: int
    button: int
    member_id: int
    member_name: str
    channel: str = ""  # o canal de texto de quem clicou
    call: str = ""  # a call de quem clicou ("" = fora de call)
    _client: Any = field(default=None, repr=False, compare=False)

    async def reply(self, text: str, **kw):
        """Responde citando o cartão (no canal do bot)."""
        return await self._client.send(text, reply_to=self.message_id, **kw)

    async def whisper(self, text: str):
        """Responde só pra quem clicou (mensagem privada)."""
        return await self._client.send(text, to=self.member_id)


@dataclass
class Embed:
    title: str = ""
    description: str = ""  # markdown: **negrito**, *itálico*, `código`, [link](https://...)
    url: str = ""  # o título vira link
    color: int = 0  # 0xRRGGBB; 0 = a cor de destaque do tema de quem vê
    kicker: str = ""  # linha pequena em cima do título ("NOW PLAYING")
    footer: str = ""
    thumbnail: bool = False  # a imagem da mensagem vai como capa (canto do cartão)
    big_image: bool = False  # a imagem da mensagem vai grande, embaixo
    progress: tuple[int, int] | None = None  # (posição_ms, total_ms); total 0 = ao vivo
    paused: bool = False
    fields: list[Field] = field(default_factory=list)
    buttons: list[Button] = field(default_factory=list)

    def add_field(self, name: str, value: Any, inline: bool = True) -> "Embed":
        if len(self.fields) >= wire.EMBED_MAX_FIELDS:
            raise ValueError(f"no máximo {wire.EMBED_MAX_FIELDS} campos por cartão")
        self.fields.append(Field(name, str(value), inline))
        return self

    def add_button(self, label: str = "", *, icon: Icon | str | int = Icon.NONE, style: Style | str | int = Style.NEUTRAL,
                   disabled: bool = False, on_click: Callable[[Click], Awaitable[Any]] | None = None) -> "Embed":
        if len(self.buttons) >= wire.EMBED_MAX_BUTTONS:
            raise ValueError(f"no máximo {wire.EMBED_MAX_BUTTONS} botões por cartão")
        self.buttons.append(Button(label, icon, style, disabled, on_click))
        return self

    def encode(self) -> bytes:
        flags = (wire.EMBED_FLAG_THUMB if self.thumbnail else 0) | (wire.EMBED_FLAG_BIG_IMAGE if self.big_image else 0)
        if self.progress is not None:
            flags |= wire.EMBED_FLAG_PROGRESS
        w = Writer(wire.EMBED_VERSION).u32(self.color & 0xFFFFFF).u8(flags)
        w.str(self.kicker, 120).str(self.title, 300).str(self.url, 1000).str(self.description, 3000).str(self.footer, 300)
        if self.progress is not None:
            pos, total = self.progress
            w.u32(max(0, int(pos))).u32(max(0, int(total))).u8(1 if self.paused else 0)
        w.u8(len(self.fields[:wire.EMBED_MAX_FIELDS]))
        for f in self.fields[:wire.EMBED_MAX_FIELDS]:
            w.str(f.name, 120).str(f.value, 600).u8(1 if f.inline else 0)
        w.u8(len(self.buttons[:wire.EMBED_MAX_BUTTONS]))
        for b in self.buttons[:wire.EMBED_MAX_BUTTONS]:
            w.u8(_style(b.style)).u8(_icon(b.icon)).str(b.label, 60).u8(1 if b.disabled else 0)
        out = w.done()
        if len(out) > wire.EMBED_MAX:
            raise ValueError(f"cartão grande demais ({len(out)} bytes; o limite é {wire.EMBED_MAX})")
        return out

    @classmethod
    def decode(cls, b: bytes) -> "Embed | None":
        if not b or b[0] != wire.EMBED_VERSION:
            return None
        try:
            r = Reader(b[1:])
            e = cls(color=r.u32())
            flags = r.u8()
            e.kicker, e.title, e.url, e.description, e.footer = r.str(), r.str(), r.str(), r.str(), r.str()
            e.thumbnail = bool(flags & wire.EMBED_FLAG_THUMB)
            e.big_image = bool(flags & wire.EMBED_FLAG_BIG_IMAGE)
            if flags & wire.EMBED_FLAG_PROGRESS:
                e.progress = (r.u32(), r.u32())
                e.paused = r.u8() != 0
            for _ in range(r.u8()):
                e.fields.append(Field(r.str(), r.str(), r.u8() != 0))
            for _ in range(r.u8()):
                style, icon, label = r.u8(), r.u8(), r.str()
                e.buttons.append(Button(label, icon, style, bool(r.opt(r.u8, 0) & 1)))
            return e
        except wire.Truncated:
            return None
