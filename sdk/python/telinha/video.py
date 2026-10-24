"""Transmitir na tela do bot. Quem está na call clica no bot e assiste, como
assiste a tela de qualquer pessoa.

- Screen: uma imagem parada (um painel, um placar, uma pergunta de quiz). Só
  manda quadro quando a imagem muda, então quase não gasta CPU nem banda.
- VideoPlayer: um vídeo (arquivo ou link, o que o ffmpeg abrir). Se ele já
  vem em H.264 (o caso do YouTube em até 1080p), os pacotes passam direto,
  sem decodificar nem codificar de novo: gasta quase nada de CPU. Senão,
  o ffmpeg recodifica (aí pesa: ~1 núcleo pra 720p).

    screen = Screen(bot)
    await screen.show("placar.png")

    player = VideoPlayer(bot)
    await player.play("filme.mp4")   # volta quando acabar (ou parar)

O som do vídeo vai junto com a imagem (o "som da transmissão"), só pra quem
assiste. Precisa do ffmpeg e do ffprobe (vêm juntos).
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import tempfile

from . import wire
from .audio import FFmpegMissing, ogg_packets, reap
from .client import Client
from .image import ChatImage, encode as encode_image

log = logging.getLogger("telinha")

__all__ = ["Screen", "VideoPlayer", "VideoInfo", "access_units", "is_idr", "is_droppable"]

AUDIO_FRAME_S = 0.010  # o som da transmissão vai em pacotes de 10 ms
MAX_BEHIND = 0.5  # s: atrasou mais que isso (máquina engasgou), recomeça o relógio


# ---------------------------------------------------------------- H.264
def _nals(au: bytes):
    """(posição, cabeçalho) de cada NAL de um trecho Annex B."""
    i = au.find(b"\x00\x00\x01")
    while 0 <= i < len(au) - 3:
        yield i + 3, au[i + 3]
        i = au.find(b"\x00\x00\x01", i + 3)


def is_idr(au: bytes) -> bool:
    return any(h & 0x1F == 5 for _, h in _nals(au))


def is_droppable(au: bytes) -> bool:
    """Ninguém usa esse quadro de referência (todas as fatias com
    nal_ref_idc = 0, como os quadros B do YouTube): a sala pode pular ele pra
    quem não está dando conta."""
    slices = [h for _, h in _nals(au) if h & 0x1F in (1, 5)]
    return bool(slices) and all(h & 0x60 == 0 for h in slices)


def access_units(buf: bytearray, final: bool = False) -> list[bytes]:
    """Tira de `buf` os access units completos (separados pelo AUD, NAL 9).
    O que sobra (o último, ainda chegando) fica em `buf`; com final=True sai tudo."""
    out = []
    marks = []
    i = buf.find(b"\x00\x00\x01\x09")
    while i >= 0:
        marks.append(i - 1 if i > 0 and buf[i - 1] == 0 else i)
        i = buf.find(b"\x00\x00\x01\x09", i + 4)
    if final:
        marks.append(len(buf))
    for a, b in zip(marks, marks[1:]):
        if b > a:
            out.append(bytes(buf[a:b]))
    if len(marks) >= 2:
        del buf[:marks[-1]]
    return out


# ---------------------------------------------------------------- Screen
class Screen:
    """Uma imagem parada na tela do bot. Cada imagem nova vira um quadro
    completo; quem começa a assistir depois recebe a última de novo."""

    def __init__(self, client: Client, *, max_side: int = 1280, ffmpeg: str = "ffmpeg", ffprobe: str = "ffprobe"):
        self.client = client
        self.max_side = max_side
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.image: ChatImage | None = None
        client.on("keyreq")(self._on_keyreq)

    async def show(self, source) -> ChatImage:
        """Mostra uma imagem: arquivo, link, bytes de PNG/JPEG, uma imagem do
        Pillow (PIL.Image) ou uma ChatImage já pronta."""
        img = source if isinstance(source, ChatImage) else await self._encode(source)
        if not self.client.streaming or not self.image or (img.width, img.height) != (self.image.width, self.image.height):
            await self.client.start_stream(img.width, img.height, 30)
        self.image = img
        await self.client.send_frame(img.data, key=True, width=img.width, height=img.height)
        return img

    async def clear(self) -> None:
        """Para de transmitir."""
        self.image = None
        await self.client.stop_stream()

    async def _encode(self, source) -> ChatImage:
        if isinstance(source, (bytes, bytearray)) or hasattr(source, "save"):
            with tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, "tela.png")
                if hasattr(source, "save"):
                    source.save(path, "PNG")
                else:
                    with open(path, "wb") as f:
                        f.write(source)
                return await encode_image(path, max_side=self.max_side, ffmpeg=self.ffmpeg, ffprobe=self.ffprobe)
        return await encode_image(source, max_side=self.max_side, ffmpeg=self.ffmpeg, ffprobe=self.ffprobe)

    async def _on_keyreq(self, kind: int) -> None:
        img = self.image
        if img and kind == wire.KIND_SCREEN and self.client.streaming:
            await self.client.send_frame(img.data, key=True, width=img.width, height=img.height)


# ---------------------------------------------------------------- VideoPlayer
class VideoInfo:
    def __init__(self, codec: str, width: int, height: int, fps: float, pix_fmt: str = "", has_audio: bool = True,
                 duration: float = 0.0):
        self.codec = codec
        self.duration = duration  # segundos (0 = não sei / ao vivo)
        self.width = width
        self.height = height
        self.fps = fps
        self.pix_fmt = pix_fmt
        self.has_audio = has_audio

    def __repr__(self) -> str:
        return f"VideoInfo({self.codec} {self.width}x{self.height} @ {self.fps:.2f}, {self.pix_fmt}, som={self.has_audio})"


def _rate(s: str) -> float:
    try:
        a, _, b = (s or "0/1").partition("/")
        return float(a) / float(b or 1)
    except (ValueError, ZeroDivisionError):
        return 0.0


class VideoPlayer:
    """Toca um vídeo na tela do bot, no ritmo certo, com o som junto."""

    def __init__(self, client: Client, *, max_height: int = 720, bitrate: int = 2_500_000, audio_bitrate: int = 128_000,
                 ffmpeg: str = "ffmpeg", ffprobe: str = "ffprobe"):
        self.client = client
        self.max_height = max_height
        self.bitrate = bitrate  # só quando precisa recodificar
        self.audio_bitrate = audio_bitrate
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.source: str | None = None
        self.info: VideoInfo | None = None
        self.passthrough = False  # os pacotes do vídeo passam sem recodificar
        self.position = 0.0  # segundos do vídeo já mostrados
        self._procs: list[asyncio.subprocess.Process] = []
        self._resume = asyncio.Event()
        self._resume.set()
        self._stop = False
        self._base = 0.0  # hora (loop) em que a posição 0 desta rodada toca
        self._paused_at: float | None = None
        self._clock = asyncio.Event()  # os dois lados (imagem e som) já têm o primeiro pedaço

    @property
    def playing(self) -> bool:
        return self.source is not None

    @property
    def paused(self) -> bool:
        return self.playing and not self._resume.is_set()

    async def probe(self, source: str, headers: dict | None = None) -> VideoInfo:
        if not shutil.which(self.ffprobe):
            raise FFmpegMissing()
        args = [self.ffprobe, "-v", "error"]
        if headers:
            args += ["-headers", "".join(f"{k}: {v}\r\n" for k, v in headers.items())]
        args += ["-show_entries", "stream=codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,pix_fmt:format=duration",
                 "-of", "json", source]
        proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(proc.communicate(), 30)
        except asyncio.TimeoutError:
            await reap(proc)
            raise RuntimeError(f"o ffprobe demorou demais pra abrir {source!r}") from None
        if proc.returncode != 0:
            raise RuntimeError(f"o ffprobe não abriu {source!r}: {err.decode(errors='replace').strip()[-300:]}")
        data = json.loads(out or b"{}")
        streams = data.get("streams") or []
        v = next((s for s in streams if s.get("codec_type") == "video"), None)
        if not v:
            raise RuntimeError(f"{source!r} não tem vídeo")
        fps = _rate(v.get("avg_frame_rate")) or _rate(v.get("r_frame_rate")) or 30.0
        return VideoInfo(v.get("codec_name") or "", int(v.get("width") or 0), int(v.get("height") or 0), fps,
                         v.get("pix_fmt") or "", any(s.get("codec_type") == "audio" for s in streams),
                         float((data.get("format") or {}).get("duration") or 0))

    async def play(self, video: str, audio: str | None = None, *, headers: dict | None = None, start: float = 0.0,
                   info: VideoInfo | None = None) -> bool:
        """Toca até o fim. Retorna True se terminou, False se foi parado.
        `audio`: o som num link separado (o YouTube manda assim); sem ele, o
        som vem do próprio vídeo. `headers`: cabeçalhos HTTP (os do yt-dlp).
        A transmissão continua ligada no fim (a próxima da fila emenda sem o
        pessoal ter que clicar de novo); pra desligar, client.stop_stream()."""
        if not shutil.which(self.ffmpeg):
            raise FFmpegMissing()
        if self.playing:
            await self.stop()
        self.info = info or await self.probe(video, headers)
        if audio:
            self.info.has_audio = True
        self.source = video
        self.position = start
        self._stop = False
        self._resume.set()
        self._paused_at = None
        self._clock = asyncio.Event()
        try:
            return await self._run(video, audio, headers or {}, start)
        finally:
            self.source = None
            self._procs = []

    def _input(self, src: str, headers: dict, start: float) -> list[str]:
        args = [self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error"]
        if src.startswith(("http://", "https://")):
            args += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5"]
            if headers:
                args += ["-headers", "".join(f"{k}: {v}\r\n" for k, v in headers.items())]
        if start > 0:
            args += ["-ss", f"{start:.2f}"]
        return args + ["-i", src]

    async def _run(self, video: str, audio: str | None, headers: dict, start: float) -> bool:
        info = self.info
        fps = info.fps if 1 <= info.fps <= 120 else 30.0
        self.passthrough = (info.codec == "h264" and 0 < info.height <= self.max_height
                            and info.pix_fmt in ("yuv420p", "yuvj420p", ""))
        if self.passthrough:
            w, h = info.width, info.height
            vargs = self._input(video, headers, start) + [
                "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "h264_mp4toannexb,h264_metadata=aud=insert", "-f", "h264", "pipe:1"]
        else:
            h = min(info.height or self.max_height, self.max_height) // 2 * 2
            w = max(16, round((info.width or 16 * h // 9) * h / max(info.height, 1) / 2) * 2)
            g = max(1, round(fps * 2))
            vargs = self._input(video, headers, start) + [
                "-map", "0:v:0", "-vf", f"scale={w}:{h},format=yuv420p", "-c:v", "libx264", "-preset", "veryfast",
                "-tune", "zerolatency", "-bf", "0", "-g", str(g), "-b:v", str(self.bitrate), "-maxrate", str(self.bitrate),
                "-bufsize", str(self.bitrate), "-x264-params", "aud=1:repeat-headers=1", "-f", "h264", "pipe:1"]
        log.info("vídeo %s: %r, %s", video[:80], info, "repassando sem recodificar" if self.passthrough else f"recodificando pra {w}x{h}")
        vproc = await asyncio.create_subprocess_exec(*vargs, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                                                     limit=8 * 1024 * 1024)
        self._procs = [vproc]
        aproc = None
        if info.has_audio:
            aargs = self._input(audio or video, headers, start) + [
                "-map", "0:a:0", "-vn", "-ac", "2", "-ar", "48000", "-c:a", "libopus", "-b:a", str(self.audio_bitrate),
                "-frame_duration", "10", "-application", "audio", "-f", "ogg", "pipe:1"]
            aproc = await asyncio.create_subprocess_exec(*aargs, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            self._procs.append(aproc)
        await self.client.start_stream(w, h, round(fps), audio=aproc is not None)
        ready = {"v": False, "a": aproc is None}
        tasks = [asyncio.create_task(self._video(vproc, fps, w, h, ready, start))]
        if aproc:
            tasks.append(asyncio.create_task(self._audio(aproc, ready)))
        try:
            await tasks[0]  # o vídeo manda: acabou a imagem, acabou
            if not self._stop:
                try:  # a imagem acabou: o ffmpeg está saindo (sem matar: o código de saída diz se deu erro)
                    await asyncio.wait_for(vproc.wait(), 10)
                except asyncio.TimeoutError:
                    pass
            if vproc.returncode not in (0, None) and not self._stop:
                err = (await vproc.stderr.read()).decode(errors="replace").strip()
                raise RuntimeError(f"o ffmpeg não conseguiu abrir {video[:120]!r}: {err[-300:] or vproc.returncode}")
            return not self._stop
        finally:
            for t in tasks:
                t.cancel()
            for proc in self._procs:
                await reap(proc)

    async def _wait_start(self, ready: dict, side: str) -> None:
        """Os dois lados esperam o primeiro pedaço um do outro: o relógio só
        começa quando a imagem e o som estão prontos (senão um sai atrasado)."""
        ready[side] = True
        if not all(ready.values()):
            try:
                await asyncio.wait_for(self._clock.wait(), 8)
            except asyncio.TimeoutError:
                pass  # o outro lado não veio (vídeo sem som de verdade): segue sem ele
        if not self._clock.is_set():
            self._base = asyncio.get_running_loop().time()
            self._clock.set()

    async def _due(self, t: float) -> bool:
        """Espera a hora de mandar o que toca em `t` s (desde o começo desta
        rodada), segurando enquanto estiver pausado. False = parou."""
        loop = asyncio.get_running_loop()
        while True:
            if self._stop:
                return False
            if not self._resume.is_set():
                if self._paused_at is None:
                    self._paused_at = loop.time()
                await self._resume.wait()
                continue
            if self._paused_at is not None:
                self._base += loop.time() - self._paused_at
                self._paused_at = None
            wait = self._base + t - loop.time()
            if wait < -MAX_BEHIND:
                self._base -= wait  # a máquina engasgou: segue daqui, sem correr pra alcançar
                return True
            if wait <= 0:
                return True
            await asyncio.sleep(min(wait, 0.1))

    async def _video(self, proc, fps: float, w: int, h: int, ready: dict, start: float) -> None:
        buf = bytearray()
        n = 0
        started = False
        eof = False
        while not eof:
            chunk = await proc.stdout.read(256 * 1024)
            if not chunk:
                eof = True
            buf += chunk
            for au in access_units(buf, final=eof):
                if not started:
                    if not is_idr(au):
                        continue  # começa num quadro completo
                    started = True
                    await self._wait_start(ready, "v")
                if not await self._due(n / fps):
                    return
                await self.client.send_frame(au, key=is_idr(au), droppable=is_droppable(au), width=w, height=h)
                n += 1
                self.position = start + n / fps

    async def _audio(self, proc, ready: dict) -> None:
        n = 0
        first = True
        async for pkt in ogg_packets(proc.stdout):
            n += 1
            if n <= 2:
                continue  # OpusHead, OpusTags
            if first:
                first = False
                await self._wait_start(ready, "a")
            if not await self._due((n - 3) * AUDIO_FRAME_S):
                return
            await self.client.send_stream_audio(pkt)

    def pause(self) -> None:
        self._resume.clear()

    def resume(self) -> None:
        self._resume.set()

    async def stop(self) -> None:
        self._stop = True
        self._resume.set()
        for proc in self._procs:
            if proc.returncode is None:
                proc.kill()
        while self.playing:
            await asyncio.sleep(0.02)
