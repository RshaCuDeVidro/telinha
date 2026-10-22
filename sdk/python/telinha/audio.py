"""Tocar som na call: qualquer coisa que o ffmpeg abra (mp3, flac, ogg,
wav, rádio online...) vira Opus 48 kHz em pacotes de 20 ms, mandados no
ritmo certo como a voz do bot. Quem ouve ajusta o volume do bot como o de
qualquer pessoa (clique direito no nome).

    player = Player(bot)
    await player.play("música.mp3")   # volta quando acabar (ou parar)

Precisa do ffmpeg instalado (com libopus, que quase todo ffmpeg tem).
"""
from __future__ import annotations

import asyncio
import logging
import shutil

from .client import Client

log = logging.getLogger("telinha")

__all__ = ["Player", "FFmpegMissing", "ogg_packets"]

FRAME_S = 0.020  # 20 ms por pacote
MAX_BEHIND = 0.2  # s: atrasou mais que isso (máquina engasgou), recomeça o relógio


class FFmpegMissing(RuntimeError):
    def __init__(self):
        super().__init__("precisa do ffmpeg pra tocar som (apt install ffmpeg / pacman -S ffmpeg / winget install ffmpeg)")


async def ogg_packets(stream: asyncio.StreamReader):
    """Os pacotes de um Ogg/Opus, na ordem (o OpusHead e o OpusTags inclusive)."""
    pending = b""
    while True:
        try:
            head = await stream.readexactly(27)
        except asyncio.IncompleteReadError:
            return
        if head[:4] != b"OggS":
            raise ValueError("o ffmpeg mandou algo que não é Ogg")
        nseg = head[26]
        lacing = await stream.readexactly(nseg)
        body = await stream.readexactly(sum(lacing))
        pos = 0
        for n in lacing:
            pending += body[pos:pos + n]
            pos += n
            if n < 255:  # fim do pacote (255 = continua no próximo segmento)
                yield pending
                pending = b""


class Player:
    def __init__(self, client: Client, *, bitrate: int = 128_000, stereo: bool = True, ffmpeg: str = "ffmpeg"):
        self.client = client
        self.bitrate = bitrate
        self.stereo = stereo
        self.ffmpeg = ffmpeg
        self.volume = 1.0
        self.source: str | None = None
        self.position = 0.0  # segundos tocados da fonte atual
        self._proc: asyncio.subprocess.Process | None = None
        self._resume = asyncio.Event()
        self._resume.set()
        self._stop = False
        self._restart_at: float | None = None

    @property
    def playing(self) -> bool:
        return self.source is not None

    @property
    def paused(self) -> bool:
        return self.playing and not self._resume.is_set()

    async def play(self, source: str, *, volume: float | None = None, start: float = 0.0) -> bool:
        """Toca até o fim. Retorna True se terminou, False se foi parado."""
        if not shutil.which(self.ffmpeg):
            raise FFmpegMissing()
        if self.playing:
            await self.stop()
        if volume is not None:
            self.volume = volume
        self.source = source
        self.position = start
        self._stop = False
        self._resume.set()
        await self.client.set_voice(mic=True)
        try:
            tries = 0
            while True:
                self._restart_at = None
                try:
                    done = await self._run(source, self.position)
                except RuntimeError:
                    # rádio/link soluçou (conexão caiu, demorou a responder): tenta de novo
                    tries += 1
                    if not source.startswith(("http://", "https://")) or tries >= 3 or self._stop:
                        raise
                    log.warning("a fonte %s falhou; tentando de novo (%d)", source, tries)
                    await asyncio.sleep(2)
                    self._restart_at = self.position
                    continue
                if self._restart_at is None:
                    return done and not self._stop
                self.position = self._restart_at  # mudou o volume: continua de onde estava
        finally:
            self.source = None
            self._proc = None
            try:
                await self.client.set_voice(mic=False)
            except Exception:  # a conexão pode ter caído
                pass

    async def _run(self, source: str, start: float) -> bool:
        args = [self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error"]
        if source.startswith(("http://", "https://")):
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
        if start > 0:
            args += ["-ss", f"{start:.2f}"]
        args += ["-i", source, "-vn", "-af", f"volume={self.volume:.3f}", "-ac", "2" if self.stereo else "1", "-ar", "48000",
                 "-c:a", "libopus", "-b:a", str(self.bitrate), "-frame_duration", "20", "-application", "audio",
                 "-f", "ogg", "pipe:1"]
        proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        self._proc = proc
        loop = asyncio.get_running_loop()
        n = 0
        clock = loop.time()
        try:
            async for pkt in ogg_packets(proc.stdout):
                n += 1
                if n <= 2:
                    continue  # OpusHead, OpusTags
                if self._stop or self._restart_at is not None:
                    return False
                if not self._resume.is_set():
                    await self.client.set_voice(mic=False)
                    await self._resume.wait()
                    if self._stop or self._restart_at is not None:
                        return False
                    await self.client.set_voice(mic=True)
                    clock = loop.time()
                clock += FRAME_S
                wait = clock - loop.time()
                if wait > 0:
                    await asyncio.sleep(wait)
                elif wait < -MAX_BEHIND:
                    clock = loop.time()
                await self.client.send_voice(pkt)
                self.position += FRAME_S
            await proc.wait()
            if proc.returncode not in (0, None) and not self._stop and self._restart_at is None:
                err = (await proc.stderr.read()).decode(errors="replace").strip()
                raise RuntimeError(f"o ffmpeg não conseguiu tocar {source!r}: {err[-300:] or proc.returncode}")
            return True
        finally:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()

    def pause(self) -> None:
        self._resume.clear()

    def resume(self) -> None:
        self._resume.set()

    async def stop(self) -> None:
        self._stop = True
        self._resume.set()
        if self._proc and self._proc.returncode is None:
            self._proc.kill()
        while self.playing:
            await asyncio.sleep(0.02)

    def set_volume(self, volume: float) -> None:
        """0.0 a 2.0. Vale em ~meio segundo (o ffmpeg recomeça de onde estava)."""
        self.volume = max(0.0, min(2.0, volume))
        if self.playing and not (self.source or "").startswith(("http://", "https://")):
            self._restart_at = self.position
            if self._proc and self._proc.returncode is None:
                self._proc.kill()
        elif self.playing:
            self._restart_at = 0.0  # rádio: recomeça a transmissão com o volume novo
            if self._proc and self._proc.returncode is None:
                self._proc.kill()
