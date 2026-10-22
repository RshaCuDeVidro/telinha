"""O que o bot enxerga da sala: pessoas, mensagens, canais, arquivos."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from . import wire

if TYPE_CHECKING:
    from .client import Client
    from .embed import Embed


@dataclass
class Member:
    id: int
    name: str
    flags: int = 0
    route: int = 0
    owner: bool = False
    in_channel: bool = True  # está no meu canal de texto
    in_call: bool = True  # está na minha call
    version: str = ""
    bot: bool = False
    watching: list[int] = field(default_factory=list)

    @property
    def admin(self) -> bool:
        return bool(self.flags & wire.MEMBER_ADMIN)

    @property
    def streaming(self) -> bool:
        return bool(self.flags & wire.MEMBER_STREAMING)

    @property
    def camera(self) -> bool:
        return bool(self.flags & wire.MEMBER_CAMERA)

    @property
    def mic(self) -> bool:
        return bool(self.flags & wire.MEMBER_MIC)

    @property
    def deaf(self) -> bool:
        return bool(self.flags & wire.MEMBER_DEAF)

    @property
    def muted(self) -> bool:
        """Silenciado por um admin."""
        return bool(self.flags & wire.MEMBER_MUTED)

    @property
    def mention(self) -> str:
        return "@" + self.name


@dataclass
class Quote:
    id: int
    author_id: int
    author: str
    text: str  # o trecho (até 140 bytes, sem quebra de linha), vem do servidor


@dataclass
class FileInfo:
    id: int
    name: str
    size: int


@dataclass
class Message:
    id: int
    author_id: int  # 0 = aviso do sistema ("Ana entrou na sala")
    author: str
    text: str
    time_us: int  # relógio da sala
    history: bool = False  # mensagem antiga (chegou porque o bot acabou de entrar)
    quote: Quote | None = None  # se é resposta: o trecho citado
    to_id: int = 0  # privada: pra quem (0 = o canal)
    to_name: str = ""
    file: FileInfo | None = None
    has_image: bool = False
    reactions: list[tuple[int, int]] = field(default_factory=list)  # (reação, de)
    channel: str = ""  # o canal de texto em que o bot estava quando chegou
    embed: "Embed | None" = None  # cartão (de outro bot, ou o do próprio bot)
    author_channel: str = ""  # onde quem mandou está (o servidor conta só pra bot)
    author_call: str = ""  # a call de quem mandou ("" = fora de call)
    _client: "Client | None" = field(default=None, repr=False, compare=False)

    @property
    def system(self) -> bool:
        return self.author_id == 0

    @property
    def private(self) -> bool:
        return self.to_id != 0

    def _other(self) -> int:
        # privada: a outra pessoa da conversa (o bot pode ser quem mandou ou quem recebeu)
        return self.author_id if self.to_id == self._client.me else self.to_id

    async def reply(self, text: str) -> "Message | None":
        """Responde citando essa mensagem (em privado, se ela foi privada)."""
        return await self._client.send(text, reply_to=self.id, to=self._other() if self.private else 0)

    async def respond(self, text: str) -> "Message | None":
        """Responde no mesmo lugar (no canal, ou em privado se veio em privado), sem citar."""
        return await self._client.send(text, to=self._other() if self.private else 0)

    async def react(self, reaction: "wire.Reaction | int", on: bool = True) -> None:
        await self._client.react(self.id, reaction, on)

    async def edit(self, text: str | None = None, *, embed: "Embed | None" = None) -> None:
        """Muda a mensagem (só as do próprio bot): o texto e o cartão. A imagem fica."""
        await self._client.edit(self.id, self.text if text is None else text, embed=embed)
        if text is not None:
            self.text = text
        self.embed = embed


@dataclass
class ChannelInfo:
    name: str
    people: int = 0
    in_call: int = 0
    flags: int = 0
    topic: str = ""

    @property
    def live(self) -> bool:
        return bool(self.flags & wire.CHAN_LIVE)

    @property
    def fixed(self) -> bool:
        return bool(self.flags & wire.CHAN_FIXED)

    @property
    def has_password(self) -> bool:
        return bool(self.flags & wire.CHAN_PASSWORD)

    @property
    def locked(self) -> bool:
        return bool(self.flags & wire.CHAN_LOCKED)


@dataclass
class Welcome:
    me: int
    room: str
    admin: bool
    route: int
    server_version: str
    server_features: int
