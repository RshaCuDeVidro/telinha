"""Handshake e cifra (espelho do src/crypto.zig; ver docs/PROTOCOL.md §1).

Os dois lados mandam 54 bytes em claro: "TLNH", versão, chave X25519
efêmera e um nonce. As chaves de cada sentido saem do HKDF-SHA256 sobre o
segredo do X25519 e o SHA-256 da senha da sala; depois disso cada mensagem
vai cifrada com ChaCha20-Poly1305 (nonce = contador do sentido).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import struct
from dataclasses import dataclass

from cryptography.exceptions import InvalidSignature, InvalidTag
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

MAGIC = b"TLNH"
HELLO_LEN = 54
TAG_LEN = 16


class NotTelinha(Exception):
    """Do outro lado não é uma sala do telinha."""


class AuthFailed(Exception):
    """A mensagem não decifrou (senha errada, ou alguém mexeu no caminho)."""


@dataclass(frozen=True)
class Hello:
    version: int
    public: bytes  # 32
    nonce: bytes  # 16

    def to_bytes(self) -> bytes:
        return MAGIC + struct.pack("<H", self.version) + self.public + self.nonce

    @classmethod
    def parse(cls, b: bytes) -> "Hello":
        if len(b) != HELLO_LEN or b[:4] != MAGIC:
            raise NotTelinha
        return cls(struct.unpack_from("<H", b, 4)[0], b[6:38], b[38:54])


class Handshake:
    """O meu lado do handshake (uma conexão)."""

    def __init__(self, version: int):
        self._key = X25519PrivateKey.generate()
        self.hello = Hello(version, self._key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), os.urandom(16))

    def channel(self, server: Hello, password: str) -> "Channel":
        shared = self._key.exchange(X25519PublicKey.from_public_bytes(server.public))
        pw = hashlib.sha256(b"telinha-senha-v1" + password.encode("utf-8")).digest()
        prk = hmac.new(self.hello.nonce + server.nonce, shared + pw, hashlib.sha256).digest()  # HKDF-Extract
        return Channel(send_key=_hkdf_expand(prk, b"telinha c2s"), recv_key=_hkdf_expand(prk, b"telinha s2c"))


def _hkdf_expand(prk: bytes, info: bytes) -> bytes:
    # 32 bytes = um bloco do HKDF-Expand (RFC 5869)
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()


def _nonce(ctr: int) -> bytes:
    return struct.pack("<Q", ctr) + b"\x00\x00\x00\x00"


class Channel:
    """A cifra dos dois sentidos de uma conexão (contadores separados)."""

    def __init__(self, send_key: bytes, recv_key: bytes):
        self._send = ChaCha20Poly1305(send_key)
        self._recv = ChaCha20Poly1305(recv_key)
        self.send_ctr = 0
        self.recv_ctr = 0

    def seal(self, plain: bytes) -> bytes:
        out = self._send.encrypt(_nonce(self.send_ctr), plain, None)
        self.send_ctr += 1
        return out

    def open(self, cipher: bytes) -> bytes:
        try:
            out = self._recv.decrypt(_nonce(self.recv_ctr), cipher, None)
        except InvalidTag:
            raise AuthFailed from None
        self.recv_ctr += 1
        return out


def transcript(client: Hello, server: Hello) -> bytes:
    """O que o servidor assina (as duas metades do handshake)."""
    return hashlib.sha256(b"telinha-identidade-v1" + client.public + client.nonce + server.public + server.nonce).digest()


def verify_identity(public: bytes, signature: bytes, t: bytes) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(public).verify(signature, t)
        return True
    except (InvalidSignature, ValueError):
        return False


def fingerprint(public: bytes) -> str:
    """Impressão da identidade do servidor: base32 (minúsculo) dos primeiros
    15 bytes do SHA-256 da chave pública — 24 caracteres, vai no convite."""
    return base64.b32encode(hashlib.sha256(public).digest()[:15]).decode("ascii").lower()
