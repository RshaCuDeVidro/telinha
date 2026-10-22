#!/usr/bin/env python3
"""Bot de música do telinha: toca na call da sala.

    python3 musica.py "telinha://sala.exemplo:7777#senha" --pasta ~/Música

Toca músicas de uma pasta, arquivos mandados na sala (responda o arquivo com
!tocar), rádios de uma lista e, se você deixar (--links), links diretos de
áudio. Quem está na call ouve; cada um ajusta o volume do bot como o de
qualquer pessoa (clique direito no nome).

Comandos (no chat): !tocar, !fila, !pular, !pausar, !continuar, !parar,
!volume, !tocando, !lista, !radios, !aleatorio, !repetir, !vem, !ajuda.
Guia: https://rshacudevidro.github.io/telinha/docs/bots-music/
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import random
import sys
import tempfile
import unicodedata
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python"))  # rodando de dentro do repositório

from telinha import Bot, Context, Denied, FileInfo, Message, Player  # noqa: E402

log = logging.getLogger("musica")

AUDIO_EXT = {".mp3", ".flac", ".ogg", ".opus", ".m4a", ".aac", ".wav", ".wma", ".webm", ".mka", ".aiff", ".alac"}
SHOW = 10  # itens nas listas do chat


@dataclass
class Track:
    title: str
    source: str  # caminho, url ou arquivo baixado da sala
    asked_by: str
    temp: bool = False  # arquivo da sala baixado: apagar depois de tocar


def fold(s: str) -> str:
    """Pra busca: minúsculas e sem acento."""
    return "".join(c for c in unicodedata.normalize("NFD", s.casefold()) if unicodedata.category(c) != "Mn")


def human(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60}:{s % 60:02d}"


class MusicBot(Bot):
    def __init__(self, invite: str, name: str, *, folder: Path | None, radios: dict[str, str], allow_links: bool,
                 volume: float, **kw):
        super().__init__(invite, name, **kw)
        self.folder = folder
        self.radios = radios
        self.allow_links = allow_links
        self.player = Player(self)
        self.player.volume = volume
        self.queue: list[Track] = []
        self.current: Track | None = None
        self.shuffle = False
        self.repeat = "nada"  # nada | uma | fila
        self.recent_files: OrderedDict[int, FileInfo] = OrderedDict()  # arquivos que apareceram no chat
        self.tmp = tempfile.TemporaryDirectory(prefix="telinha-musica-")
        self._wake = asyncio.Event()
        self._library: list[Path] = []
        self.on("message")(self._remember_file)
        self.on("ready")(self._on_ready)
        self._register()

    # ---------------------------------------------------------------- biblioteca
    def library(self) -> list[Path]:
        if self.folder and not self._library:
            self._library = sorted(p for p in self.folder.rglob("*") if p.suffix.lower() in AUDIO_EXT and p.is_file())
        return self._library

    def search(self, query: str) -> list[Path]:
        words = fold(query).split()
        return [p for p in self.library() if all(w in fold(str(p.relative_to(self.folder))) for w in words)]

    async def _remember_file(self, msg: Message) -> None:
        if msg.file:
            self.recent_files[msg.id] = msg.file
            while len(self.recent_files) > 50:
                self.recent_files.popitem(last=False)

    async def _on_ready(self, _welcome) -> None:
        if not hasattr(self, "_loop_task"):
            self._loop_task = asyncio.create_task(self._play_loop())

    # ---------------------------------------------------------------- tocando
    async def _play_loop(self) -> None:
        while True:
            if not self.queue:
                self._wake.clear()
                await self._wake.wait()
                continue
            i = random.randrange(len(self.queue)) if self.shuffle else 0
            track = self.queue.pop(i)
            self.current = track
            try:
                done = await self.player.play(track.source)
            except Exception as e:
                log.warning("não tocou %s: %s", track.title, e)
                await self._say(f"Não consegui tocar **{track.title}**. 😕")
                done = False
            finally:
                self.current = None
            if done and self.repeat == "uma":
                self.queue.insert(0, track)
            elif done and self.repeat == "fila":
                self.queue.append(track)
            elif track.temp:
                Path(track.source).unlink(missing_ok=True)

    async def _say(self, text: str) -> None:
        try:
            await self.send(text)
        except Exception:
            pass

    def enqueue(self, track: Track) -> int:
        self.queue.append(track)
        self._wake.set()
        return len(self.queue)

    # ---------------------------------------------------------------- comandos
    def _register(self) -> None:
        cmd = self.command

        @cmd("tocar", aliases=["play", "p"], help="toca (ou põe na fila): nome da música, rádio ou link; respondendo um arquivo da sala, toca ele")
        async def tocar(ctx: Context, busca: str = ""):
            msg = ctx.message
            if not busca and msg.quote and msg.quote.id in self.recent_files:
                f = self.recent_files[msg.quote.id]
                if f.size > 256 * 1024 * 1024:
                    return await ctx.reply("Arquivo grande demais.")
                path = await self.download(f, Path(self.tmp.name) / f"{f.id}-{Path(f.name).name}")
                return await self._added(ctx, Track(f.name, str(path), ctx.message.author, temp=True))
            if not busca:
                if self.player.paused:
                    self.player.resume()
                    return await ctx.reply("🎶 Continuando.")
                return await ctx.reply(f"Uso: `{self.prefix}tocar nome da música` (ou responda um arquivo de áudio da sala com `{self.prefix}tocar`).")
            if busca.startswith(("http://", "https://")):
                if not self.allow_links:
                    return await ctx.reply("Links estão desligados nesse bot (quem cuida dele liga com `--links`).")
                return await self._added(ctx, Track(busca, busca, ctx.message.author))
            radio = next((n for n in self.radios if fold(n) == fold(busca)), None)
            if radio:
                return await self._added(ctx, Track(f"📻 {radio}", self.radios[radio], ctx.message.author))
            found = self.search(busca)
            if not found:
                extra = f" Rádios: {', '.join(self.radios)}." if self.radios else ""
                return await ctx.reply(f"Não achei nada com \"{busca}\".{extra}")
            if len(found) > 1 and len(busca) < 3:
                return await ctx.reply(f"Muita coisa com \"{busca}\": seja mais específico (ou `{self.prefix}lista {busca}`).")
            p = found[0]
            await self._added(ctx, Track(p.stem, str(p), ctx.message.author))

        @cmd("fila", aliases=["queue", "q"], help="o que vem depois")
        async def fila(ctx: Context):
            if not self.current and not self.queue:
                return await ctx.send("A fila está vazia.")
            lines = []
            if self.current:
                lines.append(f"🎶 **{self.current.title}** · {human(self.player.position)} (pediu {self.current.asked_by})")
            for i, t in enumerate(self.queue[:SHOW], 1):
                lines.append(f"{i}. {t.title} (pediu {t.asked_by})")
            if len(self.queue) > SHOW:
                lines.append(f"… e mais {len(self.queue) - SHOW}")
            flags = [x for x in ("🔀 aleatório" if self.shuffle else "", f"🔁 repetindo {self.repeat}" if self.repeat != "nada" else "") if x]
            if flags:
                lines.append(" · ".join(flags))
            await ctx.send("\n".join(lines))

        @cmd("pular", aliases=["skip", "s"], help="pula pra próxima")
        async def pular(ctx: Context):
            if not self.current:
                return await ctx.reply("Não está tocando nada.")
            title = self.current.title
            await self.player.stop()
            await ctx.send(f"👋 Pulou **{title}**.")

        @cmd("pausar", aliases=["pause"], help="pausa")
        async def pausar(ctx: Context):
            if self.player.playing:
                self.player.pause()
                await ctx.send("😴 Pausado.")

        @cmd("continuar", aliases=["resume"], help="continua de onde pausou")
        async def continuar(ctx: Context):
            if self.player.paused:
                self.player.resume()
                await ctx.send("🎶 Continuando.")

        @cmd("parar", aliases=["stop"], help="para e limpa a fila")
        async def parar(ctx: Context):
            self.queue.clear()
            await self.player.stop()
            await ctx.send("🛑 Parei e limpei a fila.")

        @cmd("volume", aliases=["vol", "v"], help="volume de 0 a 200 (pra todo mundo; cada um também ajusta o seu no app)")
        async def volume(ctx: Context, quanto: int = -1):
            if quanto < 0:
                return await ctx.send(f"🔊 Volume: {round(self.player.volume * 100)}")
            self.player.set_volume(min(quanto, 200) / 100)
            await ctx.send(f"🔊 Volume: {round(self.player.volume * 100)}")

        @cmd("tocando", aliases=["np", "agora"], help="o que está tocando")
        async def tocando(ctx: Context):
            if not self.current:
                return await ctx.send("Não está tocando nada.")
            state = "😴" if self.player.paused else "🎶"
            await ctx.send(f"{state} **{self.current.title}** · {human(self.player.position)} (pediu {self.current.asked_by})")

        @cmd("lista", aliases=["list", "busca"], help="lista as músicas da pasta (com um filtro, se quiser)")
        async def lista(ctx: Context, filtro: str = ""):
            if not self.folder:
                return await ctx.reply("Esse bot não tem pasta de músicas.")
            found = self.search(filtro) if filtro else self.library()
            if not found:
                return await ctx.reply("Nada por aqui.")
            lines = [f"• {p.stem}" for p in found[:SHOW * 2]]
            if len(found) > SHOW * 2:
                lines.append(f"… e mais {len(found) - SHOW * 2} (filtre: `{self.prefix}lista palavra`)")
            await ctx.send(f"🎵 **{len(found)} músicas**\n" + "\n".join(lines))

        @cmd("radios", aliases=["rádios", "radio"], help="as rádios que dá pra tocar")
        async def radios(ctx: Context):
            if not self.radios:
                return await ctx.send("Nenhuma rádio configurada.")
            await ctx.send("📻 " + ", ".join(f"`{n}`" for n in self.radios) + f"\n`{self.prefix}tocar nome-da-rádio`")

        @cmd("aleatorio", aliases=["aleatório", "shuffle"], help="liga/desliga a ordem aleatória da fila")
        async def aleatorio(ctx: Context):
            self.shuffle = not self.shuffle
            await ctx.send("🔀 Aleatório ligado." if self.shuffle else "Aleatório desligado.")

        @cmd("repetir", aliases=["repeat", "loop"], help="repetir: nada, uma (a atual) ou fila")
        async def repetir(ctx: Context, modo: str = ""):
            modos = ["nada", "uma", "fila"]
            m = fold(modo)
            self.repeat = m if m in modos else modos[(modos.index(self.repeat) + 1) % 3]
            await ctx.send(f"🔁 Repetindo: {self.repeat}.")

        @cmd("vem", aliases=["join", "entra"], help="o bot entra na call deste canal")
        async def vem(ctx: Context):
            await self.join_call(self.channel)
            await ctx.send(f"Tô na call do #{self.channel}. 🎧")

    async def _added(self, ctx: Context, track: Track) -> None:
        pos = self.enqueue(track)
        if not self.current and pos == 1:
            await ctx.reply(f"🎶 Tocando **{track.title}**.")
        else:
            await ctx.reply(f"Na fila ({pos}º): **{track.title}**.")


def load_radios(path: str | None) -> dict[str, str]:
    """Arquivo com uma rádio por linha: nome = url (linhas com # são comentário)."""
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
    ap = argparse.ArgumentParser(description="Bot de música do telinha")
    ap.add_argument("convite", nargs="?", default=os.environ.get("TELINHA_CONVITE"), help="telinha://... (ou $TELINHA_CONVITE)")
    ap.add_argument("--nome", default=os.environ.get("TELINHA_BOT_NOME", "Música"))
    ap.add_argument("--pasta", default=os.environ.get("TELINHA_MUSICAS"), help="pasta com as músicas ($TELINHA_MUSICAS)")
    ap.add_argument("--radios", default=os.environ.get("TELINHA_RADIOS"), help="arquivo com 'nome = url' por linha")
    ap.add_argument("--links", action="store_true", default=os.environ.get("TELINHA_LINKS") == "1", help="aceita links http(s) diretos de áudio")
    ap.add_argument("--volume", type=int, default=int(os.environ.get("TELINHA_VOLUME", "70")), help="0 a 200 (padrão 70)")
    ap.add_argument("--canal", default=None, help="canal pra entrar (senão o do convite)")
    ap.add_argument("--token-bots", default=os.environ.get("TELINHA_TOKEN_BOTS", ""), help="se a sala pede token de bot")
    ap.add_argument("--prefixo", default="!")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    if not args.convite:
        ap.error("faltou o convite (telinha://...)")
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(name)s: %(message)s", datefmt="%H:%M:%S")
    folder = Path(args.pasta).expanduser() if args.pasta else None
    if folder and not folder.is_dir():
        ap.error(f"pasta não existe: {folder}")
    bot = MusicBot(args.convite, args.nome, folder=folder, radios=load_radios(args.radios), allow_links=args.links,
                   volume=max(0, min(args.volume, 200)) / 100, channel=args.canal, bot_token=args.token_bots, prefix=args.prefixo)
    if folder:
        log.info("%d músicas em %s", len(bot.library()), folder)
    try:
        bot.run()
    except Denied as e:
        log.error("a sala recusou o bot: %s", e.reason)
        sys.exit(2)
    finally:
        bot.tmp.cleanup()


if __name__ == "__main__":
    main()
