"""Bot: um Client com comandos de chat (!dado 20, !tocar música.mp3).

    bot = Bot("telinha://sala:7777#senha", "Dado")

    @bot.command("dado", help="joga um dado (padrão: 6 lados)")
    async def dado(ctx, lados: int = 6):
        await ctx.reply(f"🎲 {random.randint(1, lados)}")

    bot.run()

Os argumentos saem do texto pelos tipos da função: int, float, str (uma
palavra), Member (nome ou @nome de alguém da sala) e o último `str` pode ser
`*texto` pra pegar o resto da linha. `!ajuda` lista os comandos sozinho.
"""
from __future__ import annotations

import inspect
import logging
import shlex
import time
import typing
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from .client import Client
from .models import Member, Message

log = logging.getLogger("telinha")

__all__ = ["Bot", "Context", "Command", "CommandError"]


class CommandError(Exception):
    """Erro que o bot responde no chat (uso errado, argumento inválido)."""


# o que o próprio SDK responde no chat, por idioma (Bot(lang="en"))
TEXTS = {
    "pt": {"admin": "Esse comando é só pra admin da sala.", "error": "Deu erro aqui, foi mal. 😵",
           "usage": "Uso: {}", "number": "{}: '{}' não é um número", "member": "Não achei ninguém chamado {} na sala.",
           "commands": "Comandos", "help": "mostra os comandos", "yes": ("1", "sim", "s", "true", "on", "liga", "yes")},
    "en": {"admin": "That command is for room admins only.", "error": "Something went wrong, sorry. 😵",
           "usage": "Usage: {}", "number": "{}: '{}' is not a number", "member": "There's nobody called {} in the room.",
           "commands": "Commands", "help": "shows the commands", "yes": ("1", "yes", "y", "true", "on", "sim")},
}


@dataclass
class Command:
    name: str
    fn: Callable[..., Awaitable[None]]
    help: str = ""
    aliases: tuple[str, ...] = ()
    admin_only: bool = False
    params: list[inspect.Parameter] = field(default_factory=list)

    @property
    def usage(self) -> str:
        parts = []
        for p in self.params:
            label = p.name
            if p.kind is inspect.Parameter.VAR_POSITIONAL:
                label += "..."
            parts.append(f"[{label}]" if p.default is not inspect.Parameter.empty or p.kind is inspect.Parameter.VAR_POSITIONAL else f"<{label}>")
        return " ".join(parts)


@dataclass
class Context:
    """O que o comando recebe: a mensagem, o bot e quem chamou."""
    bot: "Bot"
    message: Message
    command: Command
    args: str  # o texto depois do comando, cru

    @property
    def author(self) -> Member | None:
        return self.bot.member(self.message.author_id)

    async def reply(self, text: str) -> Message | None:
        """Responde citando a mensagem do comando. Retorna a resposta (com o id)."""
        return await self.message.reply(text)

    async def send(self, text: str) -> Message | None:
        """Manda no mesmo lugar (canal ou privada), sem citar. Retorna a mensagem (com o id)."""
        return await self.message.respond(text)

    async def reply_card(self, embed, text: str = "", *, image=None) -> Message | None:
        """Responde com um cartão (Embed), citando o comando. `text` é o que app
        antigo mostra no lugar do cartão."""
        m = self.message
        to = (m.author_id if m.to_id == self.bot.me else m.to_id) if m.private else 0
        return await self.bot.send(text or embed.title or " ", embed=embed, image=image, reply_to=m.id, to=to)


class Bot(Client):
    def __init__(self, invite, name, *, prefix: str = "!", help_command: str | None = "ajuda",
                 cooldown: float = 1.0, accept_bots: bool = False, lang: str = "pt", **kw):
        """
        prefix: o que vem antes do comando ("!" por padrão; "/" é dos comandos do app).
        help_command: nome do comando de ajuda automático (None = sem).
        cooldown: segundos entre comandos da mesma pessoa (anti-flood).
        accept_bots: obedece comandos de outros bots (padrão: não, pra dois bots
                     não ficarem se respondendo pra sempre).
        lang: idioma do que o SDK responde sozinho (uso errado, erro, ajuda): "pt" ou "en".
        """
        super().__init__(invite, name, **kw)
        self.prefix = prefix
        self.cooldown = cooldown
        self.accept_bots = accept_bots
        self.texts = TEXTS.get(lang, TEXTS["pt"])
        self.commands: dict[str, Command] = {}
        self._last_cmd: dict[int, float] = {}
        if help_command:
            self.command(help_command, help=self.texts["help"], aliases=("help",))(self._help)
        self.on("message")(self._on_message)

    def command(self, name: str | None = None, *, help: str = "", aliases: tuple[str, ...] | list[str] = (), admin_only: bool = False):
        """Decorador de comando. O nome padrão é o da função."""
        def deco(fn):
            if not inspect.iscoroutinefunction(fn):
                raise TypeError("o comando precisa ser async def")
            sig = inspect.signature(fn)
            params = list(sig.parameters.values())[1:]  # o primeiro é o ctx
            hints = typing.get_type_hints(fn)
            for p in params:
                if p.kind in (p.KEYWORD_ONLY, p.VAR_KEYWORD):
                    raise TypeError(f"{fn.__name__}: só argumentos posicionais (e *resto) nos comandos")
            cmd = Command(name or fn.__name__, fn, help or (inspect.getdoc(fn) or "").split("\n")[0], tuple(aliases), admin_only,
                          [p.replace(annotation=hints.get(p.name, str)) for p in params])
            for n in (cmd.name, *cmd.aliases):
                self.commands[n.casefold()] = cmd
            return fn
        return deco

    async def _on_message(self, msg: Message) -> None:
        if msg.history or msg.system or msg.author_id == self.me or not msg.text.startswith(self.prefix):
            return
        body = msg.text[len(self.prefix):].strip()
        if not body:
            return
        name, _, rest = body.partition(" ")
        cmd = self.commands.get(name.casefold())
        if not cmd:
            return
        author = self.member(msg.author_id)
        if author and author.bot and not self.accept_bots:
            return  # bot não manda em bot (evita dois bots conversando pra sempre)
        now = time.monotonic()
        if now - self._last_cmd.get(msg.author_id, 0) < self.cooldown:
            return
        self._last_cmd[msg.author_id] = now
        ctx = Context(self, msg, cmd, rest.strip())
        if cmd.admin_only and not (author and author.admin):
            await ctx.reply(self.texts["admin"])
            return
        try:
            args = self._parse(cmd, ctx.args)
            await cmd.fn(ctx, *args)
        except CommandError as e:
            await ctx.reply(str(e))
        except Exception:
            log.exception("erro no comando %s", cmd.name)
            await ctx.reply(self.texts["error"])

    def _parse(self, cmd: Command, text: str) -> list:
        try:
            words = shlex.split(text)
        except ValueError:
            words = text.split()
        out = []
        for i, p in enumerate(cmd.params):
            if p.kind is inspect.Parameter.VAR_POSITIONAL:
                out.extend(self._convert(p.annotation, w, p.name) for w in words[i:])
                return out
            if i >= len(words):
                if p.default is inspect.Parameter.empty:
                    raise CommandError(self.texts["usage"].format(f"{self.prefix}{cmd.name} {cmd.usage}"))
                out.append(p.default)
                continue
            # o último str leva o resto da linha (pra frases sem aspas)
            if i == len(cmd.params) - 1 and p.annotation is str:
                out.append(" ".join(words[i:]))
                return out
            out.append(self._convert(p.annotation, words[i], p.name))
        return out

    def _convert(self, ann, word: str, pname: str):
        if ann in (str, inspect.Parameter.empty):
            return word
        if ann is int or ann is float:
            try:
                return ann(word.replace(",", ".") if ann is float else word)
            except ValueError:
                raise CommandError(self.texts["number"].format(pname, word)) from None
        if ann is bool:
            return word.casefold() in self.texts["yes"]
        if ann is Member:
            m = self.member(word)
            if not m:
                raise CommandError(self.texts["member"].format(word))
            return m
        return ann(word)

    async def _help(self, ctx: Context) -> None:
        seen, lines = set(), []
        for cmd in self.commands.values():
            if id(cmd) in seen:
                continue
            seen.add(id(cmd))
            usage = f" {cmd.usage}" if cmd.usage else ""
            lines.append(f"`{self.prefix}{cmd.name}{usage}`" + (f" — {cmd.help}" if cmd.help else ""))
        await ctx.send(f"**{self.texts['commands']}**\n" + "\n".join(lines))
