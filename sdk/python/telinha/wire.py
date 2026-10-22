"""Os bytes no fio: tipos de mensagem, constantes e leitura/escrita.

Espelho do src/proto.zig (ver docs/PROTOCOL.md). Inteiros little-endian,
`str` = u16 tamanho + UTF-8.
"""
from __future__ import annotations

import enum
import struct

PROTOCOL_VERSION = 6
MAX_MESSAGE = 32 * 1024 * 1024
WRONG_PASSWORD = 0xFFFFFFFF
MAX_TEXT = 4000  # bytes; quem monta corta aí


class MsgType(enum.IntEnum):
    HELLO = 1
    WELCOME = 2
    DENIED = 3
    MEMBERS = 4
    CHAT = 5
    STREAM_START = 6
    STREAM_STOP = 7
    FRAME = 8
    WATCH = 9
    KEYREQ = 10
    PING = 11
    PONG = 12
    KICK = 13
    AUDIO = 14
    ACK = 15
    VIEWER_SLOW = 16
    VOICE = 17
    VOICE_STATE = 18
    ADMIN = 19
    NOTICE = 20
    POINTER = 21
    REACT = 22
    CODEC = 23
    DRAW = 24
    CURSOR = 25
    VIEW_SIZE = 26
    LOG_CHUNK = 27
    LOG_ACK = 28
    CHANNEL = 29
    STATS = 30
    IDENTITY = 31
    CHAN_ADMIN = 32
    CALL = 33
    FILE_PUT = 34
    FILE_READY = 35
    FILE_DATA = 36
    FILE_ACK = 37
    FILE_GET = 38
    FILE_CANCEL = 39
    WEB_HELLO = 40
    WEB_LINK = 41
    CHAT_EDIT = 42
    EMBED_ACTION = 43


# hello: o que este cliente entende (feat_*)
FEAT_CURSOR = 1
FEAT_VIEW_SIZE = 2
FEAT_CALLS = 4
FEAT_DM = 8
FEAT_BOT = 16
FEAT_EMBED = 32

# welcome: o que o servidor sabe fazer (srv_*)
SRV_DM = 1
SRV_FILES = 2
SRV_EMBED = 4

# cartões (embed): ver docs/PROTOCOL.md "Cartões"
EMBED_VERSION = 1
EMBED_MAX = 8 * 1024
EMBED_MAX_FIELDS = 12
EMBED_MAX_BUTTONS = 5
EMBED_FLAG_THUMB = 1
EMBED_FLAG_PROGRESS = 2
EMBED_FLAG_BIG_IMAGE = 4

# members: flags de cada pessoa
MEMBER_STREAMING = 1
MEMBER_ADMIN = 2
MEMBER_AUDIO = 4
MEMBER_MIC = 8
MEMBER_DEAF = 16
MEMBER_MUTED = 32
MEMBER_CAMERA = 64
MEMBER_NO_DRAW = 128
MEMBER_IN_CHAN = 0x40
MEMBER_IN_CALL = 0x20
MEMBER_KIND_BOT = 1
ROOM_LOCKED = 1

# voice_state
VOICE_MIC = 1
VOICE_DEAF = 2

# chat
CHAT_HISTORY = 1
CHAT_IMG_NONE = 0
CHAT_IMG_H264 = 1
CHAT_IMG_EXPIRED = 2

# channel (S→C): flags de cada canal
CHAN_LIVE = 1
CHAN_FIXED = 2
CHAN_PASSWORD = 4
CHAN_LOCKED = 8


class Deny(enum.IntEnum):
    GENERIC = 0
    KICKED = 1
    BANNED = 2
    CLOSED = 3
    LINK_CLOSED = 4
    LOCKED = 5
    FULL = 6
    BOTS = 7


class Notice(enum.IntEnum):
    MUTED = 1
    UNMUTED = 2
    STREAM_STOPPED = 3
    ADMIN_ON = 4
    ADMIN_OFF = 5
    CHANNEL = 6
    DRAW_OFF = 7
    DRAW_ON = 8
    MOVED = 9
    DM = 10
    FILE_GONE = 11


class Reaction(enum.IntEnum):
    """Reações (índice no protocolo)."""
    LIKE = 0
    LOVE = 1
    HAHA = 2
    FIRE = 3
    WOW = 4
    SAD = 5


REACTION_EMOJI = {Reaction.LIKE: "👍", Reaction.LOVE: "❤️", Reaction.HAHA: "😂", Reaction.FIRE: "🔥", Reaction.WOW: "😮", Reaction.SAD: "😢"}


class Truncated(Exception):
    """A mensagem acabou antes do campo."""


class Reader:
    __slots__ = ("data", "pos")

    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def take(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise Truncated
        b = self.data[self.pos:self.pos + n]
        self.pos += n
        return b

    def _unpack(self, fmt: str, n: int):
        return struct.unpack_from(fmt, self.take(n))[0]

    def u8(self) -> int:
        return self._unpack("<B", 1)

    def u16(self) -> int:
        return self._unpack("<H", 2)

    def u32(self) -> int:
        return self._unpack("<I", 4)

    def u64(self) -> int:
        return self._unpack("<Q", 8)

    def str(self) -> str:
        n = self.u16()
        return self.take(n).decode("utf-8", errors="replace")

    def rest(self) -> bytes:
        b = self.data[self.pos:]
        self.pos = len(self.data)
        return b

    def left(self) -> int:
        return len(self.data) - self.pos

    def opt(self, fn, default):
        """Campo do fim que versão antiga não manda."""
        try:
            return fn()
        except Truncated:
            return default


class Writer:
    __slots__ = ("buf",)

    def __init__(self, typ: MsgType):
        self.buf = bytearray([int(typ)])

    def u8(self, v: int) -> "Writer":
        self.buf += struct.pack("<B", v)
        return self

    def u16(self, v: int) -> "Writer":
        self.buf += struct.pack("<H", v)
        return self

    def u32(self, v: int) -> "Writer":
        self.buf += struct.pack("<I", v)
        return self

    def u64(self, v: int) -> "Writer":
        self.buf += struct.pack("<Q", v)
        return self

    def str(self, s: str, limit: int = MAX_TEXT) -> "Writer":
        b = cut_utf8(s.encode("utf-8"), limit)
        self.u16(len(b))
        self.buf += b
        return self

    def bytes(self, b: bytes) -> "Writer":
        self.buf += b
        return self

    def done(self) -> bytes:
        return bytes(self.buf)


def cut_utf8(b: bytes, limit: int) -> bytes:
    """Corta em `limit` bytes sem quebrar um caractere no meio."""
    if len(b) <= limit:
        return b
    b = b[:limit]
    while b and (b[-1] & 0xC0) == 0x80:
        b = b[:-1]
    if b and b[-1] >= 0xC0:
        b = b[:-1]
    return b
