"""Convite: telinha://end1,end2/canal!impressão#senha (espelho do src/connect.zig).

Canal, impressão e senha são opcionais. Cada endereço é host:porta; IPv6 vai
entre colchetes ([2804::1]:7777). A ordem é a preferência.
"""
from __future__ import annotations

from dataclasses import dataclass, field

MAX_ADDRESSES = 8


class BadInvite(ValueError):
    """O convite não tem nenhum endereço que dê pra usar."""


@dataclass(frozen=True)
class Address:
    host: str
    port: int

    def __str__(self) -> str:
        return f"[{self.host}]:{self.port}" if ":" in self.host else f"{self.host}:{self.port}"


@dataclass(frozen=True)
class Invite:
    addresses: tuple[Address, ...]
    password: str = ""
    channel: str | None = None
    fingerprint: str | None = None
    extra: dict = field(default_factory=dict, compare=False)

    @classmethod
    def parse(cls, raw: str) -> "Invite":
        s = raw.strip()
        if s.startswith("telinha://"):
            s = s[len("telinha://"):]
        password = ""
        if "#" in s:
            s, password = s.split("#", 1)
        fingerprint = None
        if "!" in s:  # a impressão vem depois do "!" (endereço e canal nunca têm "!")
            s, fp = s.split("!", 1)
            fingerprint = fp.strip() or None
        channel = None
        if "/" in s:  # endereço nunca tem "/" (IPv6 vai entre colchetes)
            s, ch = s.split("/", 1)
            channel = ch.strip("/ ") or None
        addrs = []
        for part in s.split(","):
            a = parse_address(part)
            if a and len(addrs) < MAX_ADDRESSES:
                addrs.append(a)
        if not addrs:
            raise BadInvite(f"convite sem endereço válido: {raw!r}")
        return cls(tuple(addrs), password, channel, fingerprint)

    def __str__(self) -> str:
        out = "telinha://" + ",".join(str(a) for a in self.addresses)
        if self.channel:
            out += "/" + self.channel
        if self.fingerprint:
            out += "!" + self.fingerprint
        if self.password:
            out += "#" + self.password
        return out


def parse_address(raw: str) -> Address | None:
    """host:porta ou [ipv6]:porta (aceita "tcp://" e barra no fim)."""
    a = raw.strip()
    if "://" in a:
        a = a.split("://", 1)[1]
    a = a.rstrip("/")
    if ":" not in a:
        return None
    host, _, port = a.rpartition(":")
    if len(host) >= 2 and host[0] == "[" and host[-1] == "]":
        host = host[1:-1]
    elif ":" in host:
        return None  # IPv6 sem colchete é ambíguo
    try:
        p = int(port)
    except ValueError:
        return None
    if not host or len(host) > 255 or not 0 < p < 65536:
        return None
    return Address(host, p)
