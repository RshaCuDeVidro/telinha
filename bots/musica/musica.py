#!/usr/bin/env python3
"""Music bot for telinha: plays in the room's call, with live cards.

    python3 musica.py "telinha://room.example:7777#password" --folder ~/Music

Plays songs from a folder, files sent in the room (reply to the file with
!play), radios from a list, links (YouTube, SoundCloud, Bandcamp and anything
yt-dlp opens; Spotify, Deezer, Apple Music and Tidal become a search by name) and
text searches. The "now playing" card has a progress bar that moves by
itself and buttons (pause, skip, stop, shuffle, loop) that work for anyone.

Commands: !play, !search, !queue, !skip, !pause, !resume, !stop, !volume,
!np, !loop, !shuffle, !remove, !clear, !radios, !list, !join, !leave, !help.
Portuguese aliases work too (!tocar, !fila, !pular...). From any channel:
/msg Música !join (the bot comes to your call).
Guide: https://rshacudevidro.github.io/telinha/en/docs/bots-music/
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import random
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python"))  # rodando de dentro do repositório

from sources import Resolver, Track, fold, nice_source  # noqa: E402
from telinha import Bot, Click, CommandError, Context, Denied, Embed, FileInfo, Icon, Message, Player  # noqa: E402
from telinha.image import ImageError, encode as encode_image  # noqa: E402

log = logging.getLogger("musica")

ACCENT = 0xD946EF  # fúcsia do pwnd
ACCENT_PAUSED = 0x9333EA
ACCENT_RADIO = 0x06B6D4
ACCENT_INFO = 0x7C3AED
SHOW = 10


def human(ms: int) -> str:
    s = max(0, int(ms // 1000))
    return f"{s // 3600}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


class MusicBot(Bot):
    def __init__(self, invite: str, name: str, *, resolver: Resolver, volume: float, **kw):
        super().__init__(invite, name, help_command=None, lang="en", **kw)
        self.src = resolver
        self.player = Player(self)
        self.player.volume = volume
        self.queue: list[Track] = []
        self.current: Track | None = None
        self.shuffle = False
        self.loop = "off"  # off | one | all
        self.card: Message | None = None  # o "now playing" (editado quando o estado muda)
        self.recent_files: OrderedDict[int, FileInfo] = OrderedDict()
        self.tmp = tempfile.TemporaryDirectory(prefix="telinha-musica-")
        self._wake: asyncio.Event | None = None
        self._loop_task: asyncio.Task | None = None
        self.on("message")(self._remember_file)
        self.on("ready")(self._on_ready)
        self._register()

    # ---------------------------------------------------------------- base
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

    def enqueue(self, tracks: list[Track]) -> int:
        self.queue.extend(tracks)
        self.wake.set()
        return len(self.queue)

    # ---------------------------------------------------------------- tocando
    async def _play_loop(self) -> None:
        while True:
            if not self.queue:
                self.wake.clear()
                await self.wake.wait()
                continue
            i = random.randrange(len(self.queue)) if self.shuffle else 0
            asked = track = self.queue.pop(i)
            self.current = track
            done = resolved = False
            try:
                # o que toca de verdade: o stream (o YouTube recusou? veio do SoundCloud),
                # ou o arquivo com a duração e as tags
                track = await self.src.stream(asked)
                resolved = True
                self.current = track
                await self._post_card(track)
                done = await self.player.play(track.play, headers=track.headers)
            except Exception as e:  # noqa: BLE001
                log.warning("couldn't play %s: %s", track.title, e)
                # o motivo do resolver já vem em inglês; o do ffmpeg fica só no log
                why = "." if resolved else f": {str(e)[:200]}"
                await self._say(f"Couldn't play **{track.title}**{why}")
            finally:
                self.current = None
            await self._close_card(track, done)
            if done and self.loop == "one":
                self.queue.insert(0, asked)  # o pedido (o link de stream expira)
            elif done and self.loop == "all":
                self.queue.append(asked)
            elif asked.temp:
                Path(asked.play).unlink(missing_ok=True)

    async def _say(self, text: str, **kw) -> Message | None:
        try:
            return await self.send(text, **kw)
        except Exception:  # noqa: BLE001 (a conexão pode ter caído)
            return None

    # ---------------------------------------------------------------- cartões
    def _np_embed(self, t: Track, *, closing: str = "") -> Embed:
        paused = self.player.paused and not closing
        e = Embed(
            title=t.title[:200],
            url=t.page if t.page.startswith(("http://", "https://")) else "",
            kicker=closing or ("LIVE RADIO" if t.live else "PAUSED" if paused else "NOW PLAYING"),
            color=ACCENT_RADIO if t.live else ACCENT_PAUSED if paused or closing else ACCENT,
            description=(f"by **{t.artist}**" if t.artist else ""),
            thumbnail=bool(t.thumbnail),
            footer=f"{nice_source(t)} · volume {round(self.player.volume * 100)}%" + (" · shuffle" if self.shuffle else "") + (f" · loop {self.loop}" if self.loop != "off" else ""),
        )
        if not closing:
            e.progress = (int(self.player.position * 1000), 0 if t.live else t.duration_ms)
            e.paused = paused
        e.add_field("Requested by", t.requested_by or "—")
        nxt = self.queue[0].title if self.queue and not self.shuffle else (f"{len(self.queue)} in the queue (shuffle)" if self.queue else "—")
        e.add_field("Up next", nxt[:80])
        if not closing:
            e.add_button("Resume" if paused else "Pause", icon=Icon.PLAY if paused else Icon.PAUSE, style="primary", on_click=self._btn_pause)
            e.add_button("Skip", icon=Icon.NEXT, on_click=self._btn_skip, disabled=False)
            e.add_button("Stop", icon=Icon.STOP, style="danger", on_click=self._btn_stop)
            e.add_button("Shuffle", icon=Icon.SHUFFLE, style="success" if self.shuffle else "neutral", on_click=self._btn_shuffle)
            e.add_button(f"Loop {self.loop}" if self.loop != "off" else "Loop", icon=Icon.REPEAT, style="success" if self.loop != "off" else "neutral", on_click=self._btn_loop)
        return e

    async def _post_card(self, t: Track) -> None:
        img = None
        if t.thumbnail:
            try:
                img = await encode_image(t.thumbnail, square=320)
            except (ImageError, OSError) as e:
                log.info("no cover for %s: %s", t.title, str(e)[:120])
        emb = self._np_embed(t)
        emb.thumbnail = img is not None
        self.card = await self._say(f"Now playing: {t.title}" + (f" — {t.artist}" if t.artist else ""), embed=emb, image=img)

    async def _refresh_card(self) -> None:
        if self.card and self.current:
            emb = self._np_embed(self.current)
            emb.thumbnail = self.card.embed.thumbnail if self.card.embed else False
            try:
                await self.card.edit(embed=emb)
            except Exception as e:  # noqa: BLE001
                log.info("couldn't update the card: %s", e)

    async def _close_card(self, t: Track, done: bool) -> None:
        if not self.card:
            return
        emb = self._np_embed(t, closing="PLAYED" if done else "STOPPED")
        emb.thumbnail = self.card.embed.thumbnail if self.card.embed else False
        try:
            await self.card.edit(f"Played: {t.title}", embed=emb)
        except Exception as e:  # noqa: BLE001
            log.info("couldn't close the card: %s", e)
        self.card = None

    # ---------------------------------------------------------------- botões do cartão
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

    async def _btn_shuffle(self, click: Click) -> None:
        self.shuffle = not self.shuffle
        await self._refresh_card()

    async def _btn_loop(self, click: Click) -> None:
        self.loop = {"off": "one", "one": "all", "all": "off"}[self.loop]
        await self._refresh_card()

    # ---------------------------------------------------------------- resolver um pedido
    async def _resolve(self, ctx: Context, query: str) -> list[Track]:
        who = ctx.message.author
        msg = ctx.message
        if not query and msg.quote and msg.quote.id in self.recent_files:
            f = self.recent_files[msg.quote.id]
            path = await self.download(f, Path(self.tmp.name) / f"{f.id}-{Path(f.name).name}")
            return [Track(Path(f.name).stem, "room", str(path), requested_by=who, temp=True)]
        if not query:
            raise CommandError(f"Usage: `{self.prefix}play song name`, a link, or reply to an audio file with `{self.prefix}play`.")
        if query.startswith(("http://", "https://")):
            tracks = await self.src.from_url(query)
        elif r := self.src.radio(query):
            tracks = [r]
        elif local := self.src.search_library(query):
            tracks = [self.src.file_track(local[0])]
        else:
            tracks = await self.src.find(query)
        if not tracks:
            raise CommandError(f'Nothing found for "{query}".')
        for t in tracks:
            t.requested_by = who
        return tracks

    async def _added(self, ctx: Context, tracks: list[Track]) -> None:
        was_idle = self.current is None and not self.queue
        pos = self.enqueue(tracks)
        if was_idle and len(tracks) == 1:
            return  # o cartão do "now playing" já responde
        t = tracks[0]
        e = Embed(kicker="ADDED TO QUEUE", color=ACCENT_INFO, title=t.title[:200] if len(tracks) == 1 else f"{len(tracks)} tracks",
                  url=t.page if len(tracks) == 1 and t.page.startswith("http") else "",
                  description=(f"by **{t.artist}**" if len(tracks) == 1 and t.artist else ", ".join(x.title for x in tracks[:3])[:300]))
        e.add_field("Position", f"#{pos - len(tracks) + 1}" if len(tracks) == 1 else f"#{pos - len(tracks) + 1}–#{pos}")
        if len(tracks) == 1 and t.duration_ms:
            e.add_field("Length", human(t.duration_ms))
        e.add_field("Source", nice_source(t))
        await ctx.reply_card(e, f"Queued: {t.title}")

    # ---------------------------------------------------------------- comandos
    def _register(self) -> None:
        cmd = self.command

        @cmd("play", aliases=["p", "tocar"], help="plays a song (name, link, radio) or queues it; reply to an audio file to play it")
        async def play(ctx: Context, query: str = ""):
            if not query and self.player.paused:
                self.player.resume()
                await self._refresh_card()
                return
            await self._added(ctx, await self._resolve(ctx, query))

        @cmd("search", aliases=["find", "busca", "buscar"], help="shows 5 results to pick with the buttons")
        async def search(ctx: Context, query: str):
            found = await self.src.search(query, 5)
            if not found:
                raise CommandError(f'Nothing found for "{query}".')
            e = Embed(kicker="SEARCH", title=query[:120], color=ACCENT_INFO, footer="pick with the buttons · the card expires in 2 minutes")
            for i, t in enumerate(found, 1):
                e.add_field(f"{i}. {nice_source(t)}" + (f" · {human(t.duration_ms)}" if t.duration_ms else ""),
                            f"**{t.title[:90]}**" + (f"\n{t.artist[:60]}" if t.artist else ""), inline=False)
            sent: list[Message] = []

            def pick(t: Track):
                async def go(click: Click):
                    if not sent:
                        return
                    t.requested_by = click.member_name
                    pos = self.enqueue([t])
                    done = Embed(kicker="PICKED", title=t.title[:200], url=t.page if t.page.startswith("http") else "", color=ACCENT_INFO,
                                 description=f"{click.member_name} picked it · position #{pos}")
                    await sent[0].edit(embed=done)
                    sent.clear()
                return go
            for i, t in enumerate(found, 1):
                e.add_button(str(i), icon=Icon.PLAY, style="primary" if i == 1 else "neutral", on_click=pick(t))
            m = await ctx.reply_card(e, "Results for " + query)
            if m:
                sent.append(m)

                async def expire():
                    await asyncio.sleep(120)
                    if sent:
                        await m.edit(embed=Embed(kicker="SEARCH", title=query[:120], color=ACCENT_INFO, description="This search expired."))
                        sent.clear()
                asyncio.create_task(expire())

        @cmd("queue", aliases=["q", "fila"], help="what's playing and what's next")
        async def queue(ctx: Context):
            e = Embed(kicker="QUEUE", color=ACCENT_INFO, title=self.current.title[:200] if self.current else "Nothing playing",
                      description=(f"now · {human(int(self.player.position * 1000))}" + (f" / {human(self.current.duration_ms)}" if self.current and self.current.duration_ms else "")) if self.current else "")
            for i, t in enumerate(self.queue[:SHOW], 1):
                e.add_field(f"{i}. " + (human(t.duration_ms) if t.duration_ms else nice_source(t)), f"{t.title[:80]}\n*{t.requested_by}*", inline=False)
            extra = len(self.queue) - SHOW
            e.footer = (f"+{extra} more · " if extra > 0 else "") + f"{len(self.queue)} in the queue" + (" · shuffle" if self.shuffle else "") + (f" · loop {self.loop}" if self.loop != "off" else "")
            await ctx.reply_card(e, f"{len(self.queue)} in the queue")

        @cmd("skip", aliases=["s", "next", "pular"], help="skips to the next one")
        async def skip(ctx: Context):
            if not self.current:
                raise CommandError("Nothing is playing.")
            await self.player.stop()

        @cmd("pause", aliases=["pausar"], help="pauses")
        async def pause(ctx: Context):
            if self.player.playing and not self.player.paused:
                self.player.pause()
                await self._refresh_card()

        @cmd("resume", aliases=["unpause", "continuar"], help="resumes")
        async def resume(ctx: Context):
            if self.player.paused:
                self.player.resume()
                await self._refresh_card()

        @cmd("stop", aliases=["parar"], help="stops and clears the queue")
        async def stop(ctx: Context):
            self.queue.clear()
            await self.player.stop()

        @cmd("volume", aliases=["vol", "v"], help="volume for everyone, 0 to 200 (each person can also set their own)")
        async def volume(ctx: Context, amount: int = -1):
            if amount >= 0:
                self.player.set_volume(min(amount, 200) / 100)
                await self._refresh_card()
            await ctx.send(f"Volume: {round(self.player.volume * 100)}%")

        @cmd("np", aliases=["nowplaying", "now", "tocando"], help="shows the now playing card again")
        async def np(ctx: Context):
            if not self.current:
                raise CommandError("Nothing is playing.")
            old = self.card
            await self._post_card(self.current)
            if old:
                try:
                    await old.edit(f"Played: {self.current.title}", embed=self._np_embed(self.current, closing="MOVED DOWN"))
                except Exception:  # noqa: BLE001
                    pass

        @cmd("loop", aliases=["repeat", "repetir"], help="loop: off, one (the current song) or all (the queue)")
        async def loop(ctx: Context, mode: str = ""):
            m = fold(mode)
            m = {"nada": "off", "uma": "one", "fila": "all", "single": "one", "queue": "all"}.get(m, m)
            self.loop = m if m in ("off", "one", "all") else {"off": "one", "one": "all", "all": "off"}[self.loop]
            await self._refresh_card()
            await ctx.send(f"Loop: {self.loop}")

        @cmd("shuffle", aliases=["aleatorio", "aleatório"], help="turns shuffle on/off")
        async def shuffle(ctx: Context):
            self.shuffle = not self.shuffle
            await self._refresh_card()
            await ctx.send("Shuffle on." if self.shuffle else "Shuffle off.")

        @cmd("remove", aliases=["rm", "remover"], help="removes a song from the queue by its number")
        async def remove(ctx: Context, number: int):
            if not 1 <= number <= len(self.queue):
                raise CommandError(f"The queue has {len(self.queue)} songs.")
            t = self.queue.pop(number - 1)
            await ctx.send(f"Removed: {t.title}")

        @cmd("clear", aliases=["limpar"], help="clears the queue (the current song keeps playing)")
        async def clear(ctx: Context):
            self.queue.clear()
            await self._refresh_card()
            await ctx.send("Queue cleared.")

        @cmd("radios", aliases=["radio", "rádios", "rádio"], help="the radios, or plays one: !radio name")
        async def radios(ctx: Context, name: str = ""):
            if name:
                r = self.src.radio(name)
                if not r:
                    raise CommandError(f'No radio called "{name}". Try `{self.prefix}radios`.')
                r.requested_by = ctx.message.author
                return await self._added(ctx, [r])
            if not self.src.radios:
                raise CommandError("No radios configured.")
            e = Embed(kicker="RADIOS", title="Live radios", color=ACCENT_RADIO, description=f"`{self.prefix}radio name` or a button below")
            names = list(self.src.radios)
            for n in names:
                e.add_field(n, "live", inline=True)

            def start(n: str):
                async def go(click: Click):
                    r = self.src.radio(n)
                    r.requested_by = click.member_name
                    self.enqueue([r])
                return go
            for n in names[:5]:
                e.add_button(n, icon=Icon.RADIO, on_click=start(n))
            await ctx.reply_card(e, "Radios: " + ", ".join(names))

        @cmd("list", aliases=["library", "lista"], help="lists the songs in the bot's folder (with a filter)")
        async def library(ctx: Context, word: str = ""):
            if not self.src.folder:
                raise CommandError("This bot has no music folder.")
            found = self.src.search_library(word) if word else self.src.library()
            if not found:
                raise CommandError("Nothing here.")
            e = Embed(kicker="LIBRARY", title=f"{len(found)} songs", color=ACCENT_INFO,
                      description="\n".join(f"• {p.stem}" for p in found[:20]) + (f"\n… and {len(found) - 20} more" if len(found) > 20 else ""))
            await ctx.reply_card(e, f"{len(found)} songs")

        @cmd("join", aliases=["vem", "entra", "come"], help="joins a channel's call: !join name, or from any channel /msg the bot !join")
        async def join(ctx: Context, channel: str = ""):
            target = channel.lstrip("#") or ctx.message.author_call or ctx.message.author_channel or self.channel
            await self.join_channel(target)
            await self.join_call(target)
            for _ in range(30):
                if self.call == target:
                    break
                await asyncio.sleep(0.1)
            if self.call != target:
                raise CommandError(f"Couldn't join #{target} (it may have a password or be locked).")
            await ctx.send(f"Joined the call in #{target}.")

        @cmd("leave", aliases=["sair"], help="leaves the call (the queue stops)")
        async def leave(ctx: Context):
            self.queue.clear()
            await self.player.stop()
            await self.leave_call()
            await ctx.send("Left the call.")

        @cmd("help", aliases=["ajuda", "commands", "comandos"], help="this card")
        async def help_(ctx: Context):
            p = self.prefix
            e = Embed(kicker="MUSIC BOT", title="Commands", color=ACCENT, description=f"From any channel: `/msg {self.name} {p}join` brings the bot to your call.")
            e.add_field("Play", f"`{p}play name or link`\n`{p}search name`\n`{p}radio name`", inline=True)
            e.add_field("Control", f"`{p}pause` `{p}resume`\n`{p}skip` `{p}stop`\n`{p}volume 80`", inline=True)
            e.add_field("Queue", f"`{p}queue` `{p}np`\n`{p}loop` `{p}shuffle`\n`{p}remove 2` `{p}clear`", inline=True)
            e.add_field("Where", f"`{p}join [channel]` `{p}leave`\n`{p}radios` `{p}list`", inline=False)
            e.footer = "YouTube, SoundCloud, Bandcamp links · Spotify, Deezer and Apple Music become a search · reply to an audio file with !play"
            await ctx.reply_card(e, "Commands: " + ", ".join(sorted({c.name for c in self.commands.values()})))


def load_radios(path: str | None) -> dict[str, str]:
    """A file with one radio per line: name = url (# lines are comments)."""
    if not path:
        return {}
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, url = (x.strip() for x in line.split("=", 1))
        if name and url.startswith(("http://", "https://")):
            out[name] = url
    return out


def main() -> None:
    env = os.environ.get
    ap = argparse.ArgumentParser(description="telinha music bot")
    ap.add_argument("invite", nargs="?", default=env("TELINHA_CONVITE"), help="telinha://... (or $TELINHA_CONVITE)")
    ap.add_argument("--name", "--nome", default=env("TELINHA_BOT_NOME", "Música"))
    ap.add_argument("--folder", "--pasta", default=env("TELINHA_MUSICAS"), help="music folder ($TELINHA_MUSICAS)")
    ap.add_argument("--radios", default=env("TELINHA_RADIOS"), help="file with 'name = url' per line")
    ap.add_argument("--cookies", default=env("TELINHA_YT_COOKIES"), help="YouTube cookies file (Netscape format) for servers YouTube blocks")
    ap.add_argument("--search", default=env("TELINHA_BUSCA", "youtube,soundcloud"), help="search order (default youtube,soundcloud)")
    ap.add_argument("--volume", type=int, default=int(env("TELINHA_VOLUME", "70")), help="0 to 200 (default 70)")
    ap.add_argument("--channel", "--canal", default=None, help="channel to join (otherwise the invite's)")
    ap.add_argument("--bot-token", "--token-bots", default=env("TELINHA_TOKEN_BOTS", ""), help="if the room asks for a bot token")
    ap.add_argument("--prefix", "--prefixo", default="!")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    if not args.invite:
        ap.error("missing the invite (telinha://...)")
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    folder = Path(args.folder).expanduser() if args.folder else None
    if folder and not folder.is_dir():
        ap.error(f"folder doesn't exist: {folder}")
    order = tuple(x.strip().lower() for x in args.search.split(",") if x.strip())
    resolver = Resolver(folder, load_radios(args.radios), cookies=args.cookies, order=order)
    bot = MusicBot(args.invite, args.name, resolver=resolver, volume=max(0, min(args.volume, 200)) / 100,
                   channel=args.channel, bot_token=args.bot_token, prefix=args.prefix)
    if folder:
        log.info("%d songs in %s", len(resolver.library()), folder)
    try:
        bot.run()
    except Denied as e:
        log.error("the room refused the bot: %s", e.reason)
        sys.exit(2)
    finally:
        bot.tmp.cleanup()


if __name__ == "__main__":
    main()
