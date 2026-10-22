"""Testes do SDK contra um telinha-server de verdade (compilado do repositório).

Cada teste sobe uma sala nova numa porta livre de 127.0.0.1 e derruba no fim:
nada sai desta máquina. O servidor vem de $TELINHA_SERVER, ou do zig-out.

    zig build server && python3 -m unittest discover -s sdk/python/tests -v
"""
from __future__ import annotations

import asyncio
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from telinha import (Bot, Client, Denied, Deny, IdentityMismatch, Invite, Player, Reaction,  # noqa: E402
                     WrongPassword)
from telinha.bot import TEXTS  # noqa: E402
from telinha.crypto import fingerprint  # noqa: E402

TOP = HERE.parents[2]


def server_binary() -> str:
    env = os.environ.get("TELINHA_SERVER")
    if env:
        return env
    arch = {"x86_64": "x86_64", "AMD64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(platform.machine(), "x86_64")
    return str(TOP / "zig-out" / "bin" / f"telinha-server-{arch}")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Room:
    """Um telinha-server só pra esse teste (porta livre, pasta temporária)."""

    def __init__(self, *args: str, password: str = "segredo"):
        self.dir = tempfile.TemporaryDirectory(prefix="telinha-sdk-")
        self.port = free_port()
        self.password = password
        self.key = Path(self.dir.name) / "servidor.key"
        self.key.write_bytes(bytes(range(32)))  # identidade fixa: dá pra saber a impressão
        cmd = [server_binary(), "--porta", str(self.port), "--chave", str(self.key), "--estado", str(Path(self.dir.name) / "estado.txt"), *args]
        if password:
            cmd += ["--senha", password]
        env = {"PATH": os.environ.get("PATH", ""), "HOME": self.dir.name}
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        else:
            self.close()
            raise RuntimeError("o telinha-server não subiu")

    def invite(self, *, fp: str | None = None, password: str | None = None) -> str:
        pw = self.password if password is None else password
        return f"telinha://127.0.0.1:{self.port}" + (f"!{fp}" if fp else "") + (f"#{pw}" if pw else "")

    def fingerprint(self) -> str:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        pub = Ed25519PrivateKey.from_private_bytes(self.key.read_bytes()).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        return fingerprint(pub)

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.output = self.proc.stdout.read() if self.proc.stdout else ""
        self.dir.cleanup()


async def until(cond, timeout=8.0, what="a condição"):
    deadline = time.monotonic() + timeout
    while not cond():
        if time.monotonic() > deadline:
            raise AssertionError(f"passou {timeout} s esperando {what}")
        await asyncio.sleep(0.02)


@unittest.skipUnless(os.path.exists(server_binary()), "sem telinha-server compilado (zig build server)")
class SdkTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.room = Room()
        self.tasks: list[asyncio.Task] = []

    async def asyncTearDown(self):
        for t in self.tasks:
            t.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        self.room.close()

    async def join(self, c: Client) -> Client:
        self.tasks.append(asyncio.create_task(c.start()))
        await c.wait_ready(8)
        return c

    async def test_entra_ve_bot_na_lista_e_conversa(self):
        ana = await self.join(Client(self.room.invite(), "Ana"))
        bot = await self.join(Client(self.room.invite(), "Robô"))
        await until(lambda: bot.me in ana.members and ana.me in bot.members, what="os dois se verem")
        self.assertTrue(ana.members[bot.me].bot)
        self.assertTrue(bot.members[ana.me].bot)  # o SDK sempre entra como bot
        got: list = []
        ana.on("message")(_collect(got))
        sent = await bot.send("olá, sala")
        await until(lambda: any(m.text == "olá, sala" for m in got), what="a mensagem")
        m = next(m for m in got if m.text == "olá, sala")
        self.assertIsNotNone(sent)
        self.assertEqual(sent.id, m.id)  # o send devolve a mensagem como a sala registrou
        self.assertEqual(m.author_id, bot.me)
        self.assertEqual(m.author, "Robô")
        # responder citando: o trecho vem do servidor
        await m.reply("oi, robô")
        await until(lambda: any(x.text == "oi, robô" for x in got), what="a resposta")
        r = next(x for x in got if x.text == "oi, robô")
        self.assertIsNotNone(r.quote)
        self.assertEqual(r.quote.id, m.id)
        self.assertEqual(r.quote.text, "olá, sala")
        # reação
        reacts: list = []

        async def on_react(mid, frm, reaction, on):
            reacts.append((mid, frm, reaction, on))
        bot.on("reaction")(on_react)
        await ana.react(m.id, Reaction.FIRE)
        await until(lambda: (m.id, ana.me, Reaction.FIRE, True) in reacts, what="a reação")

    async def test_privada_so_os_dois_veem(self):
        ana = await self.join(Client(self.room.invite(), "Ana"))
        bia = await self.join(Client(self.room.invite(), "Bia"))
        caio = await self.join(Client(self.room.invite(), "Caio"))
        await until(lambda: len(ana.members) == 3, what="os três")
        got_bia, got_caio = [], []
        bia.on("message")(_collect(got_bia))
        caio.on("message")(_collect(got_caio))
        await ana.send("segredo nosso", to=bia.me)
        await caio.send("depois")  # marca o tempo: quando ela chegar, a privada já teria chegado
        await until(lambda: any(x.text == "depois" for x in got_bia), what="a mensagem pública")
        dm = next(x for x in got_bia if x.text == "segredo nosso")
        self.assertTrue(dm.private)
        await until(lambda: any(x.text == "depois" for x in got_caio))
        self.assertFalse(any(x.text == "segredo nosso" for x in got_caio))

    async def test_comandos(self):
        bot = Bot(self.room.invite(), "Dado", cooldown=0, accept_bots=True)  # a "Ana" do teste também é do SDK
        calls = []

        @bot.command(help="soma dois números")
        async def soma(ctx, a: int, b: int = 0):
            await ctx.reply(str(a + b))

        @bot.command("diz", aliases=["fala"])
        async def diz(ctx, frase: str):
            calls.append(frase)
            await ctx.send(frase)

        await self.join(bot)
        ana = await self.join(Client(self.room.invite(), "Ana"))
        got: list = []
        ana.on("message")(_collect(got))
        await ana.send("!soma 2 40")
        await until(lambda: any(x.text == "42" for x in got), what="a soma")
        self.assertIsNotNone(next(x for x in got if x.text == "42").quote)
        await ana.send("!fala bom dia, galera")
        await until(lambda: calls == ["bom dia, galera"], what="o comando com o resto da linha")
        await ana.send("!soma dois")
        await until(lambda: any("não é um número" in x.text for x in got), what="o erro de argumento")
        # sem accept_bots, comando de outro bot é ignorado
        quieto = Bot(self.room.invite(), "Quieto", cooldown=0)

        @quieto.command()
        async def eco(ctx, frase: str):
            await ctx.send("eco: " + frase)
        await self.join(quieto)
        await ana.send("!eco oi")
        await ana.send("!ajuda")
        await until(lambda: any(x.text.startswith("**Comandos**") and "!soma <a> [b]" in x.text for x in got), what="a ajuda")
        self.assertFalse(any(x.text == "eco: oi" for x in got))
        # as respostas do próprio SDK em inglês
        bot.texts = TEXTS["en"]
        await ana.send("!soma")
        await until(lambda: any(x.text == "Usage: !soma <a> [b]" for x in got), what="o uso em inglês")

    async def test_senha_errada(self):
        c = Client(self.room.invite(password="errada"), "Mal", reconnect=False)
        with self.assertRaises(WrongPassword):
            await asyncio.wait_for(c.start(), 10)

    async def test_identidade_do_servidor(self):
        fp = self.room.fingerprint()
        ok = await self.join(Client(self.room.invite(fp=fp), "Ana"))
        self.assertEqual(ok.fingerprint, fp)
        bad = Client(self.room.invite(fp="a" * 24), "Mal", reconnect=False)
        with self.assertRaises(IdentityMismatch):
            await asyncio.wait_for(bad.start(), 10)
        # sem impressão no convite: o SDK descobre e mostra
        c = await self.join(Client(self.room.invite(), "Bia"))
        await until(lambda: c.fingerprint == fp, what="a impressão")

    async def test_arquivo_sobe_e_desce(self):
        ana = await self.join(Client(self.room.invite(), "Ana"))
        bia = await self.join(Client(self.room.invite(), "Bia"))
        got: list = []
        bia.on("message")(_collect(got))
        data = os.urandom(300_000)
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "relatório.bin"
            src.write_bytes(data)
            fid = await ana.send_file(src)
            self.assertNotEqual(fid, 0)
            await until(lambda: any(x.file for x in got), what="o arquivo no chat")
            msg = next(x for x in got if x.file)
            self.assertEqual((msg.file.name, msg.file.size), ("relatório.bin", len(data)))
            out = await bia.download(msg.file, Path(d) / "baixado")
            self.assertEqual(out.read_bytes(), data)

    @unittest.skipUnless(shutil.which("ffmpeg"), "sem ffmpeg")
    async def test_toca_som_na_call(self):
        dj = await self.join(Client(self.room.invite(), "DJ"))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        packets = []

        async def on_voice(frm, seq, opus):
            packets.append((frm, seq, len(opus), time.monotonic()))
        ana.on("voice")(on_voice)
        with tempfile.TemporaryDirectory() as d:
            tone = Path(d) / "tom.wav"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", str(tone)], check=True)
            player = Player(dj)
            t0 = time.monotonic()
            finished = await player.play(str(tone))
            took = time.monotonic() - t0
        self.assertTrue(finished)
        await until(lambda: len(packets) >= 45, 3, "a voz chegar")
        self.assertTrue(all(p[0] == dj.me for p in packets))
        seqs = [p[1] for p in packets]
        self.assertEqual(seqs, sorted(seqs))
        # no ritmo: 1 s de som leva ~1 s (não sai tudo de uma vez)
        self.assertGreater(took, 0.85)
        self.assertLess(took, 2.5)
        span = packets[-1][3] - packets[0][3]
        self.assertGreater(span, 0.7)

    async def test_mic_ligado_aparece_pra_sala(self):
        dj = await self.join(Client(self.room.invite(), "DJ"))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        await until(lambda: dj.me in ana.members)
        await dj.set_voice(mic=True)
        await until(lambda: ana.members[dj.me].mic, what="o microfone do bot ligado")

    async def test_cartao_botoes_edicao_e_capa(self):
        from telinha import Embed, Icon
        bot = await self.join(Client(self.room.invite(), "Robô"))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        got, edits, clicks = [], [], []
        ana.on("message")(_collect(got))

        async def on_edit(mid, text, emb):
            edits.append((mid, text, emb))
        ana.on("edit")(on_edit)

        async def pulou(click):
            clicks.append(click)
        card = Embed(title="Popular Monster", kicker="NOW PLAYING", color=0xd946ef, description="**Falling In Reverse**",
                     url="https://example.com/x", progress=(1000, 232_000), thumbnail=True)
        card.add_field("Requested by", "Ana").add_field("Queue", 3)
        card.add_button("Pause", icon="pause", style="primary")
        card.add_button("Skip", icon=Icon.NEXT, on_click=pulou)
        with tempfile.TemporaryDirectory() as d:
            capa = Path(d) / "capa.png"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=400x300", "-frames:v", "1", str(capa)], check=True)
            sent = await bot.send("Now playing: Popular Monster", embed=card, image=capa)
        self.assertIsNotNone(sent)
        await until(lambda: any(m.embed for m in got), what="o cartão chegar")
        m = next(m for m in got if m.embed)
        self.assertTrue(m.has_image)
        self.assertEqual(m.embed.title, "Popular Monster")
        self.assertEqual(m.embed.progress, (1000, 232_000))
        self.assertEqual([b.label for b in m.embed.buttons], ["Pause", "Skip"])
        self.assertEqual([(f.name, f.value) for f in m.embed.fields], [("Requested by", "Ana"), ("Queue", "3")])
        # clique: chega no bot, com onde a Ana está, e chama o on_click do botão certo
        await ana.click(m.id, 1)
        await until(lambda: clicks, what="o clique chegar")
        self.assertEqual((clicks[0].member_id, clicks[0].member_name, clicks[0].channel, clicks[0].call), (ana.me, "Ana", "geral", "geral"))
        # edição: o cartão muda no lugar
        card.paused = True
        card.kicker = "PAUSED"
        await sent.edit("Paused: Popular Monster", embed=card)
        await until(lambda: edits, what="a edição chegar")
        self.assertEqual(edits[0][0], m.id)
        self.assertEqual(edits[0][2].kicker, "PAUSED")
        self.assertTrue(edits[0][2].paused)
        # duas seguidas (continuar e já pular): o servidor ignora a menos de 200 ms,
        # o SDK espera a vez e as duas chegam
        card.paused = False
        card.kicker = "NOW PLAYING"
        await sent.edit(embed=card)
        await sent.edit("Played: Popular Monster", embed=Embed(title="Popular Monster", kicker="PLAYED"))
        await until(lambda: len(edits) == 3, what="as duas edições seguidas")
        self.assertEqual([e[2].kicker for e in edits], ["PAUSED", "NOW PLAYING", "PLAYED"])
        # só o autor edita
        await ana.edit(m.id, "hackeado")
        await bot.send("depois")
        await until(lambda: any(x.text == "depois" for x in got))
        self.assertEqual(len(edits), 3)

    async def test_bot_sabe_onde_quem_falou_esta(self):
        bot = await self.join(Client(self.room.invite(), "Robô"))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        got = []
        bot.on("message")(_collect(got))
        await ana.join_channel("jogos")
        await until(lambda: ana.channel == "jogos")
        await ana.send("me acha", to=bot.me)  # de outro canal, em privado
        await until(lambda: any(x.text == "me acha" for x in got), what="a privada")
        dm = next(x for x in got if x.text == "me acha")
        self.assertEqual((dm.author_channel, dm.author_call), ("jogos", "geral"))

    async def test_canais(self):
        bot = await self.join(Client(self.room.invite(), "Robô"))
        await bot.join_channel("jogos")
        await until(lambda: bot.channel == "jogos", what="trocar de canal")
        self.assertIn("jogos", bot.channels)
        await bot.join_call("jogos")
        await until(lambda: bot.call == "jogos", what="entrar na call")


@unittest.skipUnless(os.path.exists(server_binary()), "sem telinha-server compilado (zig build server)")
class BotPolicyTest(unittest.IsolatedAsyncioTestCase):
    async def test_sala_sem_bots(self):
        room = Room("--sem-bots")
        try:
            with self.assertRaises(Denied) as cm:
                await asyncio.wait_for(Client(room.invite(), "Robô", reconnect=False).start(), 10)
            self.assertEqual(cm.exception.code, Deny.BOTS)
        finally:
            room.close()

    async def test_token_de_bot(self):
        room = Room("--token-bots", "robo123", "--admin", "dono")
        tasks = []
        try:
            with self.assertRaises(Denied):
                await asyncio.wait_for(Client(room.invite(), "Sem token", reconnect=False).start(), 10)
            ok = Client(room.invite(), "Com token", bot_token="robo123")
            tasks.append(asyncio.create_task(ok.start()))
            await ok.wait_ready(8)
            self.assertFalse(ok.welcome.admin)
        finally:
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            room.close()


class InviteTest(unittest.TestCase):
    def test_partes(self):
        inv = Invite.parse("telinha://192.168.0.10:7777,[2804:14c::1]:7777,bore.pub:41234/jogos!abcdef#senha#com#cerquilha")
        self.assertEqual([str(a) for a in inv.addresses], ["192.168.0.10:7777", "[2804:14c::1]:7777", "bore.pub:41234"])
        self.assertEqual(inv.channel, "jogos")
        self.assertEqual(inv.fingerprint, "abcdef")
        self.assertEqual(inv.password, "senha#com#cerquilha")

    def test_ipv6_sem_colchete_e_lixo(self):
        inv = Invite.parse("telinha://2804::1:7777,sala.exemplo:7777,:80,x:0")
        self.assertEqual([str(a) for a in inv.addresses], ["sala.exemplo:7777"])
        with self.assertRaises(ValueError):
            Invite.parse("telinha://nada")

    def test_impressao_igual_a_do_servidor(self):
        # vetor: chave pública Ed25519 de semente 0..31 (o mesmo do teste de servidor)
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        pub = Ed25519PrivateKey.from_private_bytes(bytes(range(32))).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        fp = fingerprint(pub)
        self.assertEqual(len(fp), 24)
        self.assertRegex(fp, "^[a-z2-7]{24}$")


def _collect(into: list):
    async def f(msg):
        into.append(msg)
    return f


if __name__ == "__main__":
    unittest.main()
