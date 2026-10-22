"""Imagem no chat: o telinha manda imagem como um quadro H.264 (IDR), que o
app decodifica com o mesmo decoder do vídeo (nenhum leitor de PNG/JPEG
exposto à rede). Aqui o ffmpeg faz essa conversão a partir de um arquivo ou
de um link (a capa de uma música, por exemplo).
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
from dataclasses import dataclass

MAX_SIDE = 1920
MAX_BYTES = 1_500_000


class ImageError(RuntimeError):
    pass


@dataclass(frozen=True)
class ChatImage:
    width: int
    height: int
    data: bytes  # H.264 Annex B: SPS, PPS e o quadro IDR


async def _run(*args: str, timeout: float = 30) -> bytes:
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise ImageError("o ffmpeg demorou demais com a imagem") from None
    if proc.returncode != 0:
        raise ImageError(err.decode(errors="replace").strip()[-300:] or f"ffmpeg saiu com {proc.returncode}")
    return out


async def encode(source: "str | os.PathLike", *, max_side: int = 640, square: int | None = None,
                 ffmpeg: str = "ffmpeg", ffprobe: str = "ffprobe") -> ChatImage:
    """Arquivo ou link (http/https) → ChatImage. `square=320` corta o centro
    num quadrado (capa); senão cabe em `max_side` mantendo a proporção."""
    if not shutil.which(ffmpeg):
        raise ImageError("precisa do ffmpeg pra mandar imagem")
    src = os.fspath(source)
    if square:
        side = max(16, min(int(square), MAX_SIDE)) // 2 * 2
        w = h = side
        vf = f"scale={side}:{side}:force_original_aspect_ratio=increase,crop={side}:{side}"
    else:
        if not shutil.which(ffprobe):
            raise ImageError("precisa do ffprobe (vem com o ffmpeg)")
        info = json.loads(await _run(ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", src))
        st = (info.get("streams") or [{}])[0]
        iw, ih = int(st.get("width") or 0), int(st.get("height") or 0)
        if iw < 1 or ih < 1:
            raise ImageError("não deu pra ler o tamanho da imagem")
        k = min(1.0, max_side / max(iw, ih))
        w = max(16, int(iw * k) // 2 * 2)
        h = max(16, int(ih * k) // 2 * 2)
        vf = f"scale={w}:{h}"
    data = await _run(ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", src, "-frames:v", "1", "-vf", vf + ",format=yuv420p",
                      "-c:v", "libx264", "-profile:v", "baseline", "-preset", "veryfast", "-crf", "20", "-bf", "0", "-g", "1",
                      "-f", "h264", "pipe:1")
    if not data or len(data) > MAX_BYTES:
        raise ImageError("a imagem ficou grande demais pro chat (até 1,5 MB)")
    return ChatImage(w, h, data)
