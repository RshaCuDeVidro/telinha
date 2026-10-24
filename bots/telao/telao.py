#!/usr/bin/env python3
"""Big-screen bot for telinha: plays videos on its own screen in the call.

    python3 telao.py "telinha://room.example:7777#password"

`!watch name or link` plays a video (YouTube and anything yt-dlp opens, a
direct .mp4 link, a video file sent in the room) as the bot's screen share:
everyone in the call clicks the bot and watches, with the sound. The control
panel (pause, skip, stop) sits right under the video, for anyone watching.

YouTube's H.264 is passed straight through, without decoding or encoding
again, so the machine running the bot barely works. Other codecs get
re-encoded by ffmpeg (that one costs about a CPU core at 720p).

Commands: !watch, !search, !queue, !skip, !pause, !resume, !stop, !join,
!leave, !help. Portuguese aliases work too (!assistir, !fila, !pular...).
From any channel: /msg Telão !watch link (the bot comes to your call).
Guide: https://rshacudevidro.github.io/telinha/en/docs/bots-screen/
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import re
import sys
import tempfile
import urllib.parse
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python"))  # rodando de dentro do repositório

from telinha import Bot, Click, CommandError, Context, Denied, Embed, FileInfo, Icon, Message, VideoInfo, VideoPlayer  # noqa: E402
from telinha.image import ImageError, encode as encode_image  # noqa: E402

try:
    import yt_dlp  # opcional: sem ele, só arquivo da sala e link direto
except ImportError:  # pragma: no cover
    yt_dlp = None

log = logging.getLogger("telao")

ACCENT = 0x22D3EE  # ciano neon
ACCENT_PAUSED = 0x9333EA
ACCENT_INFO = 0x7C3AED
VIDEO_EXT = {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".ts", ".flv"}
SHOW = 10
# H.264 até a altura pedida (passa direto), com o som separado; senão o melhor que tiver (recodifica)
FORMAT = ("bv*[vcodec^=avc1][height<={h}]+ba[acodec=opus]/bv*[vcodec^=avc1][height<={h}]+ba"
          "/b[vcodec^=avc1][height<={h}]/bv*[height<={h}]+ba/b[height<={h}]/b")


def human(ms: int) -> str:
    s = max(0, int(ms // 1000))
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


@dataclass
class Video:
    title: str
    page: str  # o link pedido (ou o arquivo); resolvido na hora de tocar (os links do YouTube expiram)
    uploader: str = ""
    duration_ms: int = 0
    thumbnail: str = ""
    requested_by: str = ""
    temp: bool = False  # arquivo baixado da sala: apagar depois
    # na hora de tocar
    video: str = ""
    audio: str | None = None
    headers: dict = field(default_factory=dict)
    info: VideoInfo | None = None


def _codec(vcodec: str) -> str:
    v = (vcodec or "").lower()
    return "h264" if v.startswith(("avc1", "avc3", "h264")) else v.split(".")[0]


class Resolver:
    def __init__(self, max_height: int, cookies: str | None = None):
        self.max_height = max_height
        self.cookies = cookies

    def _ydl(self, **extra):
        opts = {"quiet": True, "no_warnings": True, "noplaylist": True, "socket_timeout": 15, "skip_download": True,
                "format": FORMAT.format(h=self.max_height)}
        if self.cookies:
            opts["cookiefile"] = self.cookies
        opts.update(extra)
        return yt_dlp.YoutubeDL(opts)

    @staticmethod
    def _from_info(info: dict) -> Video:
        page = info.get("webpage_url") or info.get("original_url") or info.get("url") or ""
        thumb = info.get("thumbnail") or ""
        if not thumb and info.get("thumbnails"):
            thumb = info["thumbnails"][-1].get("url", "")
        if not thumb and "youtube" in (info.get("ie_key") or info.get("extractor_key") or "").lower() and info.get("id"):
            thumb = f"https://i.ytimg.com/vi/{info['id']}/hqdefault.jpg"
        return Video(info.get("title") or "?", page, uploader=info.get("uploader") or info.get("channel") or "",
                     duration_ms=int((info.get("duration") or 0) * 1000), thumbnail=thumb)

    async def search(self, query: str, n: int = 5) -> list[Video]:
        if yt_dlp is None:
            return []

        def run():
            with self._ydl(extract_flat="in_playlist") as y:
                info = y.extract_info(f"ytsearch{n}:{query}", download=False)
            return [self._from_info(e) for e in (info.get("entries") or []) if e]
        return await asyncio.to_thread(run)

    async def from_url(self, url: str) -> list[Video]:
        path = urllib.parse.urlsplit(url).path
        if Path(path).suffix.lower() in VIDEO_EXT or yt_dlp is None:
            return [Video(urllib.parse.unquote(Path(path).stem) or url, url)]

        def run():
            with self._ydl(noplaylist=False, extract_flat="in_playlist") as y:
                return y.extract_info(url, download=False)
        try:
            info = await asyncio.to_thread(run)
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(f"couldn't open that link ({_short(e)})") from None
        if info.get("_type") == "playlist":
            return [self._from_info(e) for e in (info.get("entries") or []) if e][:50]
        return [self._from_info(info)]

    async def resolve(self, v: Video) -> Video:
        """Na hora de tocar: os links de vídeo e de som (o YouTube manda
        separados), os cabeçalhos e o codec/tamanho/fps."""
        if v.video:
            return v
        if not v.page.startswith(("http://", "https://")) or Path(urllib.parse.urlsplit(v.page).path).suffix.lower() in VIDEO_EXT or yt_dlp is None:
            v.video = v.page  # arquivo ou link direto: o VideoPlayer pergunta pro ffprobe
            return v

        def run():
            with self._ydl() as y:
                info = y.extract_info(v.page, download=False)
            if info.get("_type") == "playlist":
                info = (info.get("entries") or [None])[0] or {}
            return info
        try:
            info = await asyncio.to_thread(run)
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(_short(e)) from None
        fmts = info.get("requested_formats") or [info]
        vf = next((f for f in fmts if (f.get("vcodec") or "none") != "none"), None)
        af = next((f for f in fmts if f is not vf and (f.get("acodec") or "none") != "none"), None)
        if not vf or not vf.get("url"):
            raise RuntimeError("no video in that link")
        v.video = vf["url"]
        v.audio = af["url"] if af else None
        v.headers = vf.get("http_headers") or info.get("http_headers") or {}
        has_audio = af is not None or (vf.get("acodec") or "none") != "none"
        v.info = VideoInfo(_codec(vf.get("vcodec") or ""), int(vf.get("width") or 0), int(vf.get("height") or 0),
                           float(vf.get("fps") or 30), "", has_audio) if vf.get("vcodec") and vf.get("height") else None
        v.duration_ms = v.duration_ms or int((info.get("duration") or 0) * 1000)
        if not v.uploader:
            v.uploader = info.get("uploader") or info.get("channel") or ""
        return v


def _short(e: Exception) -> str:
    msg = re.sub(r"\x1b\[[0-9;]*m", "", str(e)).replace("ERROR: ", "")
    if "not a bot" in msg or "Sign in" in msg:
        return "YouTube refused this server (needs cookies, see the guide)"
    return msg[:200]


class ScreenBot(Bot):
    def __init__(self, invite: str, name: str, *, resolver: Resolver, **kw):
        super().__init__(invite, name, help_command=None, lang="en", **kw)
        self.src = resolver
        self.player = VideoPlayer(self, max_height=resolver.max_height)
        self.queue: list[Video] = []
        self.current: Video | None = None
        self.card: Message | None = None  # o painel (embaixo da transmissão, e no chat)
        self.recent_files: OrderedDict[int, FileInfo] = OrderedDict()
        self.tmp = tempfile.TemporaryDirectory(prefix="telinha-telao-")
        self._wake: asyncio.Event | None = None
        self._loop_task: asyncio.Task | None = None
        self.on("message")(self._remember_file)
        self.on("ready")(self._on_ready)
        self._register()

    @property
    def wake(self) -> asyncio.Event:
        if self._wake is None:
            self._wake = asyncio.Event()
        return self._wake

    async def _remember_file(self, msg: Message) -> None:
        if msg.file:
            self.recent_files[msg.id] = msg.file
            while len(self.recent_files) > 50:
                self.recent_files.popitem(last=False)

    async def _on_ready(self, _welcome) -> None:
        if self._loop_task is None:
            self._loop_task = asyncio.create_task(self._play_loop())

    # ---------------------------------------------------------------- tocando
    async def _play_loop(self) -> None:
        while True:
            if not self.queue:
                if self.streaming:
                    await self.stop_stream()  # a fila acabou: a tela some
                self.wake.clear()
                await self.wake.wait()
                continue
            v = self.queue.pop(0)
            self.current = v
            done = False
            try:
                await self.src.resolve(v)
                if not v.info:
                    v.info = await self.player.probe(v.video, v.headers)
                v.duration_ms = v.duration_ms or int(v.info.duration * 1000)
                await self._post_card(v)
                done = await self.player.play(v.video, v.audio, headers=v.headers, info=v.info)
                log.info("%s: %s at %.1f s", v.title, "done" if done else "stopped", self.player.position)
            except Exception as e:  # noqa: BLE001
                log.warning("couldn't play %s: %s", v.title, e)
                await self._say(f"Couldn't play **{v.title}**: {str(e)[:200]}")
            finally:
                self.current = None
            await self._close_card(v, done)
            if v.temp:
                Path(v.page).unlink(missing_ok=True)

    async def _say(self, text: str, **kw) -> Message | None:
        try:
            return await self.send(text, **kw)
        except Exception:  # noqa: BLE001 (a conexão pode ter caído)
            return None

    def _panel(self, v: Video, *, closing: str = "") -> Embed:
        paused = self.player.paused
        pos = int(self.player.position * 1000)
        e = Embed(kicker=closing or ("PAUSED" if paused else "NOW SHOWING"), title=v.title[:200],
                  url=v.page if v.page.startswith("http") else "", color=ACCENT_PAUSED if paused or closing else ACCENT,
                  description=" · ".join(x for x in (f"**{v.uploader}**" if v.uploader else "", f"asked by {v.requested_by}" if v.requested_by else "") if x))
        if not closing:
            e.progress = (pos, v.duration_ms)
            e.paused = paused
            e.panel = True
            if self.queue:
                e.add_field("Up next", self.queue[0].title[:120] + (f" (+{len(self.queue) - 1})" if len(self.queue) > 1 else ""))
            info = self.player.info
            if info:
                e.footer = f"{info.height}p · {info.fps:.0f} fps · " + ("H.264 passed through" if self.player.passthrough else "re-encoded")
            e.add_button("Resume" if paused else "Pause", icon=Icon.PLAY if paused else Icon.PAUSE, style="primary", on_click=self._btn_pause)
            e.add_button("Skip", icon=Icon.NEXT, on_click=self._btn_skip)
            e.add_button("Stop", icon=Icon.STOP, style="danger", on_click=self._btn_stop)
        return e

    async def _post_card(self, v: Video) -> None:
        img = None
        if v.thumbnail:
            try:
                img = await encode_image(v.thumbnail, square=320)
            except (ImageError, OSError) as e:
                log.info("no thumbnail for %s: %s", v.title, str(e)[:120])
        emb = self._panel(v)
        emb.thumbnail = img is not None
        self.card = await self._say(f"Now showing: {v.title}", embed=emb, image=img)
        # o tamanho e o fps só são conhecidos depois que o vídeo abre
        asyncio.get_running_loop().call_later(4, lambda: asyncio.ensure_future(self._refresh_card()))

    async def _refresh_card(self) -> None:
        if self.card and self.current:
            emb = self._panel(self.current)
            emb.thumbnail = self.card.embed.thumbnail if self.card.embed else False
            try:
                await self.card.edit(embed=emb)
            except Exception as e:  # noqa: BLE001
                log.info("couldn't update the panel: %s", e)

    async def _close_card(self, v: Video, done: bool) -> None:
        if not self.card:
            return
        emb = self._panel(v, closing="SHOWN" if done else "STOPPED")
        emb.thumbnail = self.card.embed.thumbnail if self.card.embed else False
        try:
            await self.card.edit(f"Shown: {v.title}", embed=emb)
        except Exception as e:  # noqa: BLE001
            log.info("couldn't close the panel: %s", e)
        self.card = None

    async def _btn_pause(self, click: Click) -> None:
        if self.player.paused:
            self.player.resume()
        elif self.player.playing:
            self.player.pause()
        await self._refresh_card()

    async def _btn_skip(self, click: Click) -> None:
        if self.current:
            await self.player.stop()

    async def _btn_stop(self, click: Click) -> None:
        self.queue.clear()
        await self.player.stop()

    # ---------------------------------------------------------------- pedidos
    async def _resolve(self, ctx: Context, query: str) -> list[Video]:
        who = ctx.message.author
        msg = ctx.message
        if not query and msg.quote and msg.quote.id in self.recent_files:
            f = self.recent_files[msg.quote.id]
            path = await self.download(f, Path(self.tmp.name) / f"{f.id}-{Path(f.name).name}")
            return [Video(Path(f.name).stem, str(path), requested_by=who, temp=True)]
        if not query:
            raise CommandError(f"Usage: `{self.prefix}watch name or link`, or reply to a video file with `{self.prefix}watch`.")
        try:
            if query.startswith(("http://", "https://")):
                found = await self.src.from_url(query)
            else:
                found = (await self.src.search(query, 1))[:1]
        except Exception as e:  # noqa: BLE001
            raise CommandError(_short(e)) from None
        if not found:
            raise CommandError(f'Nothing found for "{query[:200]}".')
        for v in found:
            v.requested_by = who
        return found

    async def _added(self, ctx: Context, found: list[Video]) -> None:
        was_idle = self.current is None and not self.queue
        self.queue.extend(found)
        self.wake.set()
        if was_idle and len(found) == 1:
            return  # o painel já responde
        v = found[0]
        e = Embed(kicker="ADDED TO QUEUE", color=ACCENT_INFO, title=v.title[:200] if len(found) == 1 else f"{len(found)} videos",
                  url=v.page if len(found) == 1 and v.page.startswith("http") else "")
        e.add_field("Position", f"#{len(self.queue) - len(found) + 1}")
        if len(found) == 1 and v.duration_ms:
            e.add_field("Length", human(v.duration_ms))
        await ctx.reply_card(e, f"Queued: {v.title}")
        await self._refresh_card()

    async def _go(self, target: str) -> bool:
        await self.join_channel(target)
        await self.join_call(target)
        for _ in range(30):
            if self.call == target:
                return True
            await asyncio.sleep(0.1)
        return self.call == target

    async def _follow(self, ctx: Context) -> None:
        """!watch em privado de quem está numa call: o bot vai pra lá."""
        m = ctx.message
        target = m.author_call
        if not m.private or not target or target == self.call:
            return
        if self.call and (self.current or self.queue):
            await ctx.send(f"I'm showing something in #{self.call} right now; it goes to the queue there.")
            return
        await self._go(target)

    def _register(self) -> None:
        cmd = self.command

        @cmd("watch", aliases=["w", "play", "p", "assistir", "ver"], help="plays a video (name or link) on the bot's screen, or queues it")
        async def watch(ctx: Context, query: str = ""):
            if not query and self.player.paused:
                self.player.resume()
                await self._refresh_card()
                return
            await self._follow(ctx)
            if not self.call:
                raise CommandError(f"I'm not in a call. `{self.prefix}join` from your call, or `/msg {self.name} {self.prefix}watch link`.")
            await self._added(ctx, await self._resolve(ctx, query))

        @cmd("search", aliases=["find", "buscar", "busca"], help="shows 5 videos to pick with the buttons")
        async def search(ctx: Context, query: str):
            try:
                found = await self.src.search(query, 5)
            except Exception as e:  # noqa: BLE001
                raise CommandError(_short(e)) from None
            if not found:
                raise CommandError(f'Nothing found for "{query[:200]}".')
            e = Embed(kicker="SEARCH", title=query[:200], color=ACCENT_INFO,
                      description="\n".join(f"**{i + 1}.** {v.title[:90]}" + (f" ({human(v.duration_ms)})" if v.duration_ms else "")
                                            for i, v in enumerate(found)))

            def pick(v: Video):
                async def go(click: Click):
                    v.requested_by = click.name
                    if not self.call:
                        return
                    was_idle = self.current is None and not self.queue
                    self.queue.append(v)
                    self.wake.set()
                    if not was_idle:
                        await self._refresh_card()
                return go
            for i, v in enumerate(found):
                e.add_button(str(i + 1), icon=Icon.PLAY, on_click=pick(v))
            await ctx.reply_card(e, f"Results for {query[:200]}")

        @cmd("queue", aliases=["q", "fila"], help="what's showing and what's next")
        async def queue(ctx: Context):
            if not self.current and not self.queue:
                raise CommandError("Nothing in the queue.")
            lines = [f"**Now:** {self.current.title}"] if self.current else []
            lines += [f"**{i + 1}.** {v.title[:90]}" for i, v in enumerate(self.queue[:SHOW])]
            if len(self.queue) > SHOW:
                lines.append(f"… and {len(self.queue) - SHOW} more")
            await ctx.reply_card(Embed(kicker="QUEUE", title=f"{len(self.queue)} waiting", color=ACCENT_INFO, description="\n".join(lines)),
                                 f"{len(self.queue)} in the queue")

        @cmd("skip", aliases=["s", "next", "pular"], help="skips to the next video")
        async def skip(ctx: Context):
            if not self.current:
                raise CommandError("Nothing is showing.")
            await self.player.stop()

        @cmd("pause", aliases=["pausar"], help="pauses")
        async def pause(ctx: Context):
            if not self.player.playing:
                raise CommandError("Nothing is showing.")
            self.player.pause()
            await self._refresh_card()

        @cmd("resume", aliases=["continuar"], help="resumes")
        async def resume(ctx: Context):
            self.player.resume()
            await self._refresh_card()

        @cmd("stop", aliases=["parar"], help="stops and clears the queue (the screen goes away)")
        async def stop(ctx: Context):
            self.queue.clear()
            await self.player.stop()

        @cmd("join", aliases=["vem", "entra", "come"], help="joins a channel's call: !join name, or from any channel /msg the bot !join")
        async def join(ctx: Context, channel: str = ""):
            target = channel.lstrip("#") or ctx.message.author_call or ctx.message.author_channel or self.channel
            if not await self._go(target):
                raise CommandError(f"Couldn't join #{target} (it may have a password or be locked).")
            await ctx.send(f"Joined the call in #{target}. `{self.prefix}watch name or link` and click me to watch.")

        @cmd("leave", aliases=["sair"], help="leaves the call (the queue stops)")
        async def leave(ctx: Context):
            self.queue.clear()
            await self.player.stop()
            await self.stop_stream()
            await self.leave_call()
            await ctx.send("Left the call.")

        @cmd("help", aliases=["ajuda", "commands", "comandos"], help="this card")
        async def help_(ctx: Context):
            p = self.prefix
            e = Embed(kicker="BIG SCREEN", title="Commands", color=ACCENT,
                      description=f"Videos play on my screen: click me in the call to watch. From any channel: `/msg {self.name} {p}watch link`.")
            e.add_field("Watch", f"`{p}watch name or link`\n`{p}search name`", inline=True)
            e.add_field("Control", f"`{p}pause` `{p}resume`\n`{p}skip` `{p}stop`", inline=True)
            e.add_field("Where", f"`{p}join [channel]` `{p}leave`\n`{p}queue`", inline=True)
            e.footer = "YouTube and anything yt-dlp opens · direct video links · reply to a video file with !watch"
            await ctx.reply_card(e, "Commands: " + ", ".join(sorted({c.name for c in self.commands.values()})))


def main() -> None:
    env = os.environ.get
    ap = argparse.ArgumentParser(description="telinha big-screen bot")
    ap.add_argument("invite", nargs="?", default=env("TELINHA_CONVITE"), help="telinha://... (or $TELINHA_CONVITE)")
    ap.add_argument("--name", "--nome", default=env("TELINHA_BOT_NOME", "Telão"))
    ap.add_argument("--max-height", type=int, default=int(env("TELINHA_ALTURA", "720")), help="highest resolution (default 720)")
    ap.add_argument("--cookies", default=env("TELINHA_YT_COOKIES"), help="YouTube cookies file (Netscape format) for servers YouTube blocks")
    ap.add_argument("--channel", "--canal", default=None, help="channel to join (otherwise the invite's)")
    ap.add_argument("--bot-token", "--token-bots", default=env("TELINHA_TOKEN_BOTS", ""), help="if the room asks for a bot token")
    ap.add_argument("--prefix", "--prefixo", default="!")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    if not args.invite:
        ap.error("missing the invite (telinha://...)")
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    bot = ScreenBot(args.invite, args.name, resolver=Resolver(max(144, min(args.max_height, 1080)), cookies=args.cookies),
                    channel=args.channel, bot_token=args.bot_token, prefix=args.prefix)
    try:
        bot.run()
    except Denied as e:
        log.error("the room refused the bot: %s", e.reason)
        sys.exit(2)
    finally:
        bot.tmp.cleanup()


if __name__ == "__main__":
    main()
