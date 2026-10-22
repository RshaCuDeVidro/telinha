"""De onde vem a música: pasta, rádio, links (YouTube, SoundCloud, Bandcamp
e tudo que o yt-dlp abre), Spotify/Deezer/Apple Music (viram uma busca pelo
nome, porque o áudio deles é protegido) e busca por texto.

Busca: YouTube primeiro; se o YouTube recusar (IP de datacenter costuma
cair no "confirme que não é um robô"), SoundCloud — e o bot lembra disso
por meia hora pra não perder tempo tentando de novo. Com um arquivo de
cookies do YouTube (--cookies), o YouTube volta a funcionar.
"""
from __future__ import annotations

import asyncio
import html
import json
import logging
import re
import time
import unicodedata
import urllib.parse
import urllib.request
from dataclasses import dataclass, field, replace
from pathlib import Path

log = logging.getLogger("musica")

try:
    import yt_dlp  # opcional: sem ele, só pasta, rádio, arquivo da sala e link direto
except ImportError:  # pragma: no cover
    yt_dlp = None

AUDIO_EXT = {".mp3", ".flac", ".ogg", ".opus", ".m4a", ".aac", ".wav", ".wma", ".webm", ".mka", ".aiff", ".alac"}
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
BLOCKED_FOR = 1800  # s sem tentar o YouTube depois de ele recusar


@dataclass
class Track:
    title: str
    source: str  # "file", "radio", "room", "youtube", "soundcloud", "link"...
    play: str  # o que tocar: caminho, link de stream, ou a página (resolvida na hora de tocar)
    page: str = ""  # link da música (o título do cartão vira link pra cá)
    artist: str = ""
    duration_ms: int = 0  # 0 = não sei / ao vivo
    thumbnail: str = ""  # capa (arquivo ou link)
    requested_by: str = ""
    temp: bool = False  # arquivo baixado da sala: apagar depois
    needs_resolve: bool = False  # `play` é uma página: pegar o stream na hora (o link expira)
    headers: dict = field(default_factory=dict)

    @property
    def live(self) -> bool:
        return self.source == "radio"


def fold(s: str) -> str:
    """Pra busca: minúsculas e sem acento."""
    return "".join(c for c in unicodedata.normalize("NFD", s.casefold()) if unicodedata.category(c) != "Mn")


_NOISE = {"cover", "remix", "live", "karaoke", "instrumental", "nightcore", "sped", "slowed", "reverb", "8d", "acoustic", "lyrics", "lyric",
          "bootleg", "edit", "mashup", "flip", "rework", "vip", "tribute", "parody", "along", "drum", "drums", "playthrough",
          "tutorial", "reaction"}


def _words(s: str) -> set[str]:
    return set(re.sub(r"[^a-z0-9]+", " ", fold(s)).split())


def best_match(query: str, found: list[Track]) -> Track | None:
    """O resultado que mais parece o pedido (o primeiro da busca nem sempre é:
    outra música da mesma banda, um cover, um remix). Empate = a ordem da busca."""
    want = _words(query)
    if not found or not want:
        return found[0] if found else None

    def score(t: Track) -> float:
        got = _words(f"{t.artist} {t.title}")
        hit = len(want & got) / len(want)
        return hit - 0.3 * len((got & _NOISE) - want)
    return max(found, key=score)  # max devolve o primeiro entre os empatados


def nice_source(t: Track) -> str:
    return {"file": "Library", "radio": "Radio", "room": "Room file", "youtube": "YouTube", "soundcloud": "SoundCloud",
            "bandcamp": "Bandcamp", "link": "Link"}.get(t.source, t.source.title())


class Resolver:
    def __init__(self, folder: Path | None, radios: dict[str, str], cookies: str | None = None, order: tuple[str, ...] = ("youtube", "soundcloud")):
        self.folder = folder
        self.radios = radios
        self.cookies = cookies
        self.order = order
        self._library: list[Path] | None = None
        self._yt_blocked_until = 0.0

    # ---------------------------------------------------------------- pasta e rádio
    def library(self) -> list[Path]:
        if self._library is None:
            self._library = sorted(p for p in self.folder.rglob("*") if p.suffix.lower() in AUDIO_EXT and p.is_file()) if self.folder else []
        return self._library

    def search_library(self, query: str) -> list[Path]:
        words = fold(query).split()
        return [p for p in self.library() if all(w in fold(str(p.relative_to(self.folder))) for w in words)]

    def file_track(self, p: Path) -> Track:
        return Track(p.stem, "file", str(p))

    @staticmethod
    async def probe(t: Track) -> Track:
        """Arquivo (da pasta ou da sala): duração, título/artista das tags e
        se tem capa embutida, pelo ffprobe. Sem ffprobe fica como está."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "ffprobe", "-v", "error", "-show_entries", "format=duration:format_tags=title,artist:stream=codec_type:stream_disposition=attached_pic",
                "-of", "json", t.play, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), 10)
            info = json.loads(out or b"{}")
        except (OSError, asyncio.TimeoutError, ValueError):
            return t
        fmt = info.get("format") or {}
        tags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
        try:
            dur = int(float(fmt.get("duration") or 0) * 1000)
        except ValueError:
            dur = 0
        cover = any(st.get("codec_type") == "video" and (st.get("disposition") or {}).get("attached_pic") for st in info.get("streams") or [])
        return replace(t, duration_ms=t.duration_ms or dur, title=(tags.get("title") or t.title)[:200], artist=t.artist or tags.get("artist", "")[:120],
                       thumbnail=t.thumbnail or (t.play if cover else ""))

    def radio(self, name: str) -> Track | None:
        key = next((n for n in self.radios if fold(n) == fold(name)), None)
        if key is None:
            return None
        return Track(key, "radio", self.radios[key], page=self.radios[key])

    # ---------------------------------------------------------------- yt-dlp
    def _ydl(self, **extra):
        opts = {"quiet": True, "no_warnings": True, "noplaylist": True, "socket_timeout": 15, "skip_download": True,
                "extract_flat": False, "format": "bestaudio/best"}
        if self.cookies:
            opts["cookiefile"] = self.cookies
        opts.update(extra)
        return yt_dlp.YoutubeDL(opts)

    def _yt_ok(self) -> bool:
        return time.monotonic() >= self._yt_blocked_until

    def _yt_failed(self, e: Exception) -> None:
        msg = str(e)
        if "not a bot" in msg or "Sign in" in msg or "HTTP Error 429" in msg:
            if self._yt_ok():
                log.warning("o YouTube recusou este IP; buscando no SoundCloud por %d min", BLOCKED_FOR // 60)
            self._yt_blocked_until = time.monotonic() + BLOCKED_FOR

    @staticmethod
    def _from_info(info: dict, requested_by: str = "") -> Track:
        extractor = (info.get("extractor_key") or info.get("ie_key") or "link").lower()
        source = "youtube" if "youtube" in extractor else "soundcloud" if "soundcloud" in extractor else "bandcamp" if "bandcamp" in extractor else "link"
        page = info.get("webpage_url") or info.get("original_url") or info.get("url") or ""
        thumb = info.get("thumbnail") or ""
        if not thumb and info.get("thumbnails"):
            thumb = info["thumbnails"][-1].get("url", "")
        if not thumb and source == "youtube" and info.get("id"):
            thumb = f"https://i.ytimg.com/vi/{info['id']}/hqdefault.jpg"
        return Track(info.get("track") or info.get("title") or "?", source, page, page=page,
                     artist=info.get("artist") or (info.get("artists") or [""])[0] or info.get("uploader") or info.get("channel") or "",
                     duration_ms=int((info.get("duration") or 0) * 1000), thumbnail=thumb, requested_by=requested_by,
                     needs_resolve=True)

    @staticmethod
    def _is_preview(info: dict) -> bool:
        # SoundCloud Go+: só 30 s de prévia
        url = info.get("url") or ""
        extractor = (info.get("extractor_key") or info.get("ie_key") or "").lower()
        return "/preview/" in url or (0 < (info.get("duration") or 0) <= 31 and "soundcloud" in extractor)

    async def search(self, query: str, n: int = 5) -> list[Track]:
        """Busca por texto: YouTube, e SoundCloud se o YouTube não deixar."""
        if yt_dlp is None:
            return []
        for provider in self.order:
            if provider == "youtube" and not self._yt_ok():
                continue
            try:
                found = await asyncio.to_thread(self._search_sync, provider, query, n)
            except Exception as e:  # noqa: BLE001 (erros de rede/extração variam)
                log.info("busca no %s falhou: %s", provider, str(e)[:160])
                if provider == "youtube":
                    self._yt_failed(e)
                continue
            if found:
                return found
        return []

    def _search_sync(self, provider: str, query: str, n: int) -> list[Track]:
        if provider == "youtube":
            # só a lista (rápido); se o YouTube recusar o áudio na hora de tocar,
            # stream() cai pro SoundCloud pelo nome e lembra disso por um tempo
            with self._ydl(extract_flat="in_playlist") as y:
                info = y.extract_info(f"ytsearch{n}:{query}", download=False)
            return [self._from_info(e) for e in (info.get("entries") or []) if e]
        # a lista rasa já traz duração (as prévias de 30 s saem por ela), artista,
        # capa e a página: abrir cada faixa custava ~1,5 s cada
        with self._ydl(extract_flat="in_playlist") as y:
            info = y.extract_info(f"scsearch{n + 3}:{query}", download=False)
        return [self._from_info(e) for e in (info.get("entries") or []) if e and not self._is_preview(e)][:n]

    async def stream(self, t: Track) -> Track:
        """Na hora de tocar: o link de áudio (expira em algumas horas) e os
        cabeçalhos; de arquivo, a duração, as tags e a capa."""
        if t.source in ("file", "room") and not t.duration_ms:
            return await self.probe(t)
        if not t.needs_resolve:
            return t
        if t.source == "youtube" and not self._yt_ok():
            return await self._fallback(t)
        try:
            info = await asyncio.to_thread(self._extract_sync, t.page)
        except Exception as e:  # noqa: BLE001
            if t.source == "youtube":
                self._yt_failed(e)
                return await self._fallback(t)
            raise
        return replace(t, play=info["url"], headers=info.get("http_headers") or {}, needs_resolve=False,
                       duration_ms=t.duration_ms or int((info.get("duration") or 0) * 1000))

    def _extract_sync(self, url: str) -> dict:
        with self._ydl() as y:
            info = y.extract_info(url, download=False)
        if info.get("_type") == "playlist":
            info = (info.get("entries") or [None])[0] or {}
        if not info.get("url"):
            raise RuntimeError("no audio link")
        return info

    async def find(self, query: str) -> list[Track]:
        """Uma música pelo nome: busca alguns e fica com o que mais parece."""
        best = best_match(query, await self.search(query, 5))
        return [best] if best else []

    async def _fallback(self, t: Track) -> Track:
        """YouTube recusou: a mesma música pelo nome no SoundCloud (só se achar
        ela mesma; outra da banda, não)."""
        title = re.sub(r"\((official|lyric|lyrics|audio|video|official video|official audio|music video|visualizer|hd|4k|feat\.?|ft\.?)[^)]*\)|\[[^\]]*\]", "", t.title, flags=re.I)
        title = re.sub(r"\s+(feat\.?|ft\.?)\s.*$", "", title, flags=re.I)  # "Música ft. Fulano"
        artist = re.sub(r"\s*(vevo|- topic|official|records)\s*$", "", t.artist, flags=re.I).strip()
        # o título do YouTube quase sempre já tem "Banda - Música"; o canal só entra se não tiver
        q = title if " - " in title or not artist or fold(artist) in fold(title) else f"{artist} {title}"
        q = " ".join(re.sub(r"[\"“”'‘’]|\s+-\s+", " ", q).split())  # Banda - "Música" → Banda Música
        alt = best_match(q, await self.search_provider("soundcloud", q, 4))
        name = _words(title.split(" - ", 1)[-1]) - _words(artist)  # as palavras da música, sem a banda
        got = _words(f"{alt.artist} {alt.title}") if alt else set()
        # outra música da banda, ou um remix/cover dela: melhor avisar do que tocar outra coisa
        if not alt or (name and len(name & got) < 0.6 * len(name)) or (got & _NOISE) - _words(t.title):
            raise RuntimeError(f"YouTube refused it and \"{q}\" isn't on SoundCloud either")
        alt = replace(alt, requested_by=t.requested_by)
        log.info("YouTube recusou %r: tocando %r do SoundCloud", t.title, alt.title)
        return await self.stream(alt)

    async def search_provider(self, provider: str, query: str, n: int = 3) -> list[Track]:
        try:
            return await asyncio.to_thread(self._search_sync, provider, query, n)
        except Exception as e:  # noqa: BLE001
            log.info("busca no %s falhou: %s", provider, str(e)[:160])
            return []

    # ---------------------------------------------------------------- links
    async def from_url(self, url: str) -> list[Track]:
        """Um link → as músicas (uma, ou várias se for playlist/álbum)."""
        host = urllib.parse.urlsplit(url).netloc.lower()
        if "spotify.com" in host or "deezer" in host or "music.apple.com" in host or "tidal.com" in host:
            q = await asyncio.to_thread(self._name_from_store, url)
            if not q:
                raise RuntimeError("couldn't read the song name from that link")
            found = await self.find(q)
            if not found:
                raise RuntimeError(f"couldn't find \"{q}\" to play")
            return found
        if re.search(r"\.(mp3|ogg|opus|flac|m4a|aac|wav)(\?|$)", url, re.I) or yt_dlp is None:
            name = urllib.parse.unquote(Path(urllib.parse.urlsplit(url).path).stem) or url
            return [Track(name, "link", url, page=url)]
        if ("youtube.com" in host or "youtu.be" in host) and not self._yt_ok() and "list=" not in url:
            # YouTube bloqueado aqui: o nome pela oEmbed e o resto vem do fallback
            title = await asyncio.to_thread(self._yt_oembed_title, url)
            return [Track(title or url, "youtube", url, page=url, needs_resolve=True)]
        try:
            info = await asyncio.to_thread(self._flat_sync, url)
        except Exception as e:  # noqa: BLE001
            if "youtube" in host or "youtu.be" in host:
                self._yt_failed(e)
                title = await asyncio.to_thread(self._yt_oembed_title, url)
                if title:
                    return [Track(title, "youtube", url, page=url, needs_resolve=True)]
            raise RuntimeError(f"couldn't open that link ({str(e)[:120]})") from None
        if info.get("_type") == "playlist":
            return [self._from_info(e) for e in (info.get("entries") or []) if e][:50]
        return [self._from_info(info)]

    def _flat_sync(self, url: str) -> dict:
        with self._ydl(noplaylist=False, extract_flat="in_playlist") as y:
            return y.extract_info(url, download=False)

    @staticmethod
    def _fetch(url: str, timeout: int = 10) -> str:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en"})
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (só http/https de lojas conhecidas)
            return r.read(600_000).decode("utf-8", errors="replace")

    def _yt_oembed_title(self, url: str) -> str:
        try:
            data = json.loads(self._fetch("https://www.youtube.com/oembed?format=json&url=" + urllib.parse.quote(url, safe="")))
            return data.get("title", "")
        except Exception:  # noqa: BLE001
            return ""

    def _name_from_store(self, url: str) -> str:
        """"artista título" de um link do Spotify, Deezer, Apple Music ou Tidal."""
        host = urllib.parse.urlsplit(url).netloc.lower()
        if "deezer" in host:
            m = re.search(r"/track/(\d+)", url)
            if not m:  # link curto: segue o redirecionamento
                page = self._fetch(url)
                m = re.search(r"/track/(\d+)", page)
            if m:
                d = json.loads(self._fetch(f"https://api.deezer.com/track/{m.group(1)}"))
                return f"{d.get('artist', {}).get('name', '')} {d.get('title', '')}".strip()
        if "spotify" in host:
            # a página normal é um app em JS; a do embed traz título e artistas num JSON
            m = re.search(r"/track/([A-Za-z0-9]+)", url)
            if not m:
                return ""
            page = self._fetch(f"https://open.spotify.com/embed/track/{m.group(1)}")
            t = re.search(r'"title":("(?:[^"\\]|\\.)*")', page)
            a = re.search(r'"artists":\[\{"name":("(?:[^"\\]|\\.)*")', page)
            title = json.loads(t.group(1)) if t else ""
            artist = json.loads(a.group(1)) if a else ""
            return "" if not t or "not found" in title.lower() else f"{artist} {title}".strip()
        page = self._fetch(url)

        def meta(prop: str) -> str:
            m = re.search(rf'<meta[^>]+(?:property|name)="{prop}"[^>]+content="([^"]*)"', page) or \
                re.search(rf'<meta[^>]+content="([^"]*)"[^>]+(?:property|name)="{prop}"', page)
            return html.unescape(m.group(1)) if m else ""
        title = meta("og:title")
        desc = meta("og:description")
        if "apple.com" in host:
            # "Popular Monster - Song by Falling In Reverse - Apple Music" / "Popular Monster by Falling In Reverse on Apple Music"
            t = re.sub(r"\s*[-–]\s*Apple Music$|\s+on Apple Music$", "", title)
            m = re.match(r"(.+?)\s*[-–]\s*(?:Song|Single|Album|EP) by (.+)$", t) or re.match(r"(.+?) by (.+)$", t)
            return f"{m.group(2)} {m.group(1)}" if m else t
        return f"{desc} {title}".strip() if "tidal" in host else title
