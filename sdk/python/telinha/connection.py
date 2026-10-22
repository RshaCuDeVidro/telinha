"""Uma conexão com a sala: a corrida entre os endereços do convite, o
handshake, a identidade do servidor e as mensagens cifradas.
"""
from __future__ import annotations

import asyncio
import struct

from . import crypto, wire
from .invite import Address, Invite

RACE_STAGGER = 0.25  # s entre uma tentativa e a próxima (os primeiros endereços saem na frente)
HELLO_TIMEOUT = 8.0
RACE_TIMEOUT = 20.0


class ConnectError(Exception):
    """Não deu pra conectar (o motivo vai na mensagem)."""


class WrongPassword(ConnectError):
    pass


class IdentityMismatch(ConnectError):
    """O servidor não provou ser quem o convite diz (impressão diferente)."""


class Connection:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, hs: crypto.Handshake, server: crypto.Hello, address: Address):
        self.reader = reader
        self.writer = writer
        self.hs = hs
        self.server_hello = server
        self.address = address
        self.channel: crypto.Channel | None = None
        self.fingerprint: str | None = None  # do servidor (se ele tiver identidade)
        self._send_lock = asyncio.Lock()

    async def send(self, payload: bytes) -> None:
        """Manda uma mensagem (u8 tipo + payload), cifrada."""
        async with self._send_lock:
            cipher = self.channel.seal(payload)
            self.writer.write(struct.pack("<I", len(cipher)) + cipher)
            await self.writer.drain()

    async def recv(self) -> tuple[int, bytes]:
        """Próxima mensagem: (tipo, payload)."""
        head = await self.reader.readexactly(4)
        (n,) = struct.unpack("<I", head)
        if n == wire.WRONG_PASSWORD:
            raise WrongPassword("senha errada")
        if n < crypto.TAG_LEN + 1 or n > wire.MAX_MESSAGE:
            raise ConnectError(f"mensagem de tamanho inválido ({n})")
        plain = self.channel.open(await self.reader.readexactly(n))
        return plain[0], plain[1:]

    async def close(self) -> None:
        try:
            self.writer.close()
            await asyncio.wait_for(self.writer.wait_closed(), 2)
        except (OSError, asyncio.TimeoutError):
            pass


async def _try(addr: Address, version: int) -> Connection:
    reader, writer = await asyncio.open_connection(addr.host, addr.port)
    try:
        hs = crypto.Handshake(version)
        writer.write(hs.hello.to_bytes())
        await writer.drain()
        server = crypto.Hello.parse(await asyncio.wait_for(reader.readexactly(crypto.HELLO_LEN), HELLO_TIMEOUT))
        if server.version != version:
            raise ConnectError(f"a sala usa o protocolo {server.version}; este SDK fala o {version}")
        return Connection(reader, writer, hs, server, addr)
    except BaseException:
        writer.close()
        raise


async def race(invite: Invite, version: int = wire.PROTOCOL_VERSION) -> Connection:
    """Tenta todos os endereços quase juntos (como o app) e fica com o primeiro
    que responder como uma sala do telinha na mesma versão."""
    errors: list[BaseException] = []

    async def attempt(i: int, addr: Address) -> Connection:
        await asyncio.sleep(i * RACE_STAGGER)
        return await _try(addr, version)

    tasks = [asyncio.create_task(attempt(i, a)) for i, a in enumerate(invite.addresses)]
    winner: Connection | None = None
    try:
        for fut in asyncio.as_completed(tasks, timeout=RACE_TIMEOUT):
            try:
                winner = await fut
                break
            except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError, crypto.NotTelinha, ConnectError) as e:
                errors.append(e)
    except asyncio.TimeoutError:
        pass
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
        # quem conectou depois do vencedor é fechado
        for t in tasks:
            if t.done() and not t.cancelled() and t.exception() is None and t.result() is not winner:
                await t.result().close()
    if winner:
        return winner
    for e in errors:  # o erro mais útil primeiro
        if isinstance(e, ConnectError):
            raise e
    if any(isinstance(e, crypto.NotTelinha) for e in errors):
        raise ConnectError("respondeu, mas não é uma sala do telinha")
    if any(isinstance(e, ConnectionRefusedError) for e in errors):
        raise ConnectError("conexão recusada (porta fechada?)")
    raise ConnectError("não conectou em nenhum endereço do convite: " + ", ".join(str(a) for a in invite.addresses))


async def secure(conn: Connection, invite: Invite, password: str) -> None:
    """Deriva as chaves e confere a identidade do servidor, que vem antes de
    tudo. Com impressão no convite, ela tem que bater."""
    conn.channel = conn.hs.channel(conn.server_hello, password)
    if invite.fingerprint is None:
        return  # sem impressão no convite: aceita (quem chama pode conferir conn.fingerprint)
    try:
        typ, payload = await asyncio.wait_for(conn.recv(), 10)
    except crypto.AuthFailed:
        raise WrongPassword("senha errada") from None
    except asyncio.TimeoutError:
        raise IdentityMismatch("o servidor não mandou identidade, mas o convite pede uma") from None
    if typ != wire.MsgType.IDENTITY or len(payload) < 96:
        raise IdentityMismatch("o servidor não mandou identidade, mas o convite pede uma")
    public, sig = payload[:32], payload[32:96]
    if not crypto.verify_identity(public, sig, crypto.transcript(conn.hs.hello, conn.server_hello)):
        raise IdentityMismatch("a assinatura do servidor não confere (alguém no meio do caminho?)")
    conn.fingerprint = crypto.fingerprint(public)
    if conn.fingerprint != invite.fingerprint:
        raise IdentityMismatch(f"impressão do servidor {conn.fingerprint}, o convite pede {invite.fingerprint}")
