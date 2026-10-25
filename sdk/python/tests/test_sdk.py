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
from telinha import wire  # noqa: E402
from telinha.crypto import fingerprint  # noqa: E402
from telinha.wire import MsgType, Writer  # noqa: E402

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

    @unittest.skipUnless(shutil.which("ffmpeg"), "sem ffmpeg")
    async def test_volume_muda_sem_recomecar(self):
        dj = await self.join(Client(self.room.invite(), "DJ"))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        packets = []

        async def on_voice(frm, seq, opus):
            packets.append(seq)
        ana.on("voice")(on_voice)
        with tempfile.TemporaryDirectory() as d:
            tone = Path(d) / "tom.wav"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", str(tone)], check=True)
            player = Player(dj)
            task = asyncio.create_task(player.play(str(tone)))
            await until(lambda: player.position > 0.6, 3, "começar a tocar")
            proc = player._proc
            player.set_volume(0.5)
            await asyncio.sleep(0.3)
            # o mesmo ffmpeg, e a posição seguiu (antes o volume matava o ffmpeg e recomeçava)
            self.assertIs(player._proc, proc)
            self.assertGreater(player.position, 0.8)
            self.assertTrue(await task)
        await until(lambda: len(packets) >= 95, 3, "a voz chegar")
        self.assertLess(len(packets), 110)  # nada repetido
        # o ganho nas amostras
        from array import array
        p2 = Player(dj)
        p2.volume = 0.5
        out = array("f")
        out.frombytes(p2._gain(array("f", [1.0, -0.5, 0.25]).tobytes()))
        self.assertEqual(list(out), [0.5, -0.25, 0.125])

    async def _watcher(self, name: str, target: Client):
        """Alguém (pelo SDK) na call assistindo a tela de `target`: guarda os quadros e o som que chegam."""
        from telinha.wire import MsgType, Writer
        w = await self.join(Client(self.room.invite(), name))
        await target.join_call("geral")
        await w.join_call("geral")
        got = {"frames": [], "audio": []}
        orig = w._dispatch

        async def spy(typ, p):
            if typ == MsgType.FRAME:
                got["frames"].append((p[8] if len(p) > 8 else 0, p[25:], time.monotonic()))  # u32 stream, u32 seq, u8 flags...
            elif typ == MsgType.AUDIO:
                got["audio"].append(time.monotonic())
            await orig(typ, p)
        w._dispatch = spy

        async def watch():
            await w._send(Writer(MsgType.WATCH).u32(target.me).u8(1).u8(0).done())
        return w, got, watch

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "sem ffmpeg")
    async def test_tela_parada_e_ponteiro(self):
        from telinha import Screen
        from telinha.wire import MsgType, Writer
        bot = await self.join(Client(self.room.invite(), "Placar"))
        ana, got, watch = await self._watcher("Ana", bot)
        screen = Screen(bot)
        clicks = []

        async def on_pointer(frm, x, y, flags):
            clicks.append((frm, round(x, 2), round(y, 2), flags))
        bot.on("pointer")(on_pointer)
        with tempfile.TemporaryDirectory() as d:
            img = Path(d) / "placar.png"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360", "-frames:v", "1", str(img)], check=True)
            shown = await screen.show(img)
        self.assertEqual((shown.width, shown.height), (640, 360))
        await until(lambda: bot.me in ana.members and ana.members[bot.me].streaming, what="o bot ao vivo")
        await asyncio.sleep(0.3)
        self.assertEqual(got["frames"], [])  # ninguém assistindo: nada chega
        # começou a assistir: a sala pede um quadro completo e a Screen manda a imagem de novo
        await watch()
        await until(lambda: len(got["frames"]) >= 1, what="a imagem chegar pra quem começou a assistir")
        self.assertEqual(got["frames"][0][0] & 1, 1)  # quadro-chave
        self.assertEqual(got["frames"][0][1], shown.data)
        # clique no vídeo vai pro bot, com a posição de 0 a 1
        await ana._send(Writer(MsgType.POINTER).u32(bot.me).u16(16383).u16(49151).u8(3).done())
        await until(lambda: clicks, what="o clique chegar no bot")
        self.assertEqual(clicks[0], (ana.me, 0.25, 0.75, 3))
        await screen.clear()
        await until(lambda: not ana.members[bot.me].streaming, what="o bot parar de transmitir")

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "sem ffmpeg")
    async def test_video_passa_direto_no_ritmo(self):
        from telinha import VideoPlayer
        bot = await self.join(Client(self.room.invite(), "Telão"))
        ana, got, watch = await self._watcher("Ana", bot)
        with tempfile.TemporaryDirectory() as d:
            mp4 = Path(d) / "filme.mp4"
            # 2 s, 30 q/s, H.264 High com quadros B (o jeito do YouTube) e som
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=30", "-f", "lavfi",
                            "-i", "sine=f=440:r=48000", "-t", "2", "-c:v", "libx264", "-profile:v", "high", "-bf", "3", "-g", "30",
                            "-c:a", "aac", "-shortest", str(mp4)], check=True)
            player = VideoPlayer(bot)
            info = await player.probe(str(mp4))
            self.assertEqual((info.codec, info.width, info.height, round(info.fps)), ("h264", 320, 180, 30))
            self.assertAlmostEqual(info.duration, 2.0, delta=0.15)
            await watch()
            await asyncio.sleep(0.2)
            t0 = time.monotonic()
            self.assertTrue(await player.play(str(mp4), info=info))
            took = time.monotonic() - t0
        self.assertTrue(player.passthrough)
        await until(lambda: len(got["frames"]) >= 55 and len(got["audio"]) >= 150, 3, "o vídeo e o som chegarem")
        self.assertEqual(got["frames"][0][0] & 1, 1)  # começa num quadro completo
        self.assertTrue(any(f[0] & 2 for f in got["frames"]))  # quadros B sem referência vão como puláveis
        # no ritmo: 2 s de vídeo levam ~2 s, e os quadros chegam espalhados
        self.assertGreater(took, 1.7)
        self.assertLess(took, 4.0)
        self.assertGreater(got["frames"][-1][2] - got["frames"][0][2], 1.5)
        self.assertTrue(bot.streaming)  # continua ao vivo pra emendar a próxima
        await bot.stop_stream()

    def test_painel_vai_no_cartao(self):
        from telinha import Embed
        e = Embed(title="filme", panel=True, progress=(0, 1000))
        back = Embed.decode(e.encode())
        self.assertTrue(back.panel)
        self.assertFalse(Embed.decode(Embed(title="x").encode()).panel)

    def test_access_units(self):
        from telinha.video import access_units, is_droppable, is_idr
        aud = b"\x00\x00\x00\x01\x09\xf0"
        idr = aud + b"\x00\x00\x00\x01\x67\x64" + b"\x00\x00\x01\x65\x88"
        p = aud + b"\x00\x00\x01\x41\x9a"
        b = aud + b"\x00\x00\x01\x01\x9e"  # nal_ref_idc 0
        buf = bytearray(idr + p + b[:4])
        self.assertEqual(access_units(buf), [idr])  # o P ainda pode crescer
        buf += b[4:]
        self.assertEqual(access_units(buf, final=True), [p, b])
        self.assertEqual(buf, bytearray())
        self.assertTrue(is_idr(idr) and not is_idr(p))
        self.assertTrue(is_droppable(b) and not is_droppable(p) and not is_droppable(idr))

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

    async def chan_admin(self, c: Client, action: int, name: str, value: str = "", target: int = 0) -> None:
        await c._send(Writer(MsgType.CHAN_ADMIN).u8(action).str(name).str(value).u32(target).done())

    async def test_senha_do_canal_vale_ate_pra_outra_janela_de_quem_criou(self):
        dono = await self.join(Client(self.room.invite(), "Dono", key=4242))
        await dono.join_channel("zika")
        await until(lambda: dono.channel == "zika", what="criar o canal")
        await self.chan_admin(dono, 3, "zika", "abc")
        await until(lambda: dono.channels["zika"].flags & wire.CHAN_PASSWORD, what="a senha valer")
        # a mesma instalação (mesma chave) numa segunda janela: pede a senha
        outra = await self.join(Client(self.room.invite(), "Dono", key=4242))
        notes: list = []

        async def on_notice(kind, text, extra):
            notes.append(text)
        outra.on("notice")(on_notice)
        await asyncio.sleep(0.9)  # o servidor aceita uma troca a cada 800 ms
        await outra.join_call("zika")
        await outra.join_channel("zika")
        await until(lambda: len(notes) >= 2, what="os dois avisos de senha")
        self.assertEqual((outra.channel, outra.call), ("geral", "geral"))
        self.assertTrue(all("senha" in n for n in notes))
        # pelo convite direto no canal, sem senha: começa no padrão
        sem = await self.join(Client(self.room.invite(), "Sem", channel="zika"))
        self.assertEqual(sem.channel, "geral")
        # com a senha certa entra, e voltando a conectar continua lá
        com = await self.join(Client(self.room.invite(), "Com", channel="zika", channel_password="abc"))
        await until(lambda: com.channel == "zika", what="entrar com a senha no hello")
        old_id = com.me
        com._conn.writer.transport.abort()  # cai a conexão: o SDK reconecta
        await until(lambda: com.me != old_id and com.me in dono.members, 15, "reconectar")
        await until(lambda: com.channel == "zika", what="voltar pro canal com senha")
        await asyncio.sleep(0.9)
        await outra.join_channel("zika", "abc")
        await until(lambda: outra.channel == "zika", what="a outra janela entrar com a senha")
        # quem criou continua mandando: tira a senha
        await self.chan_admin(dono, 3, "zika", "")
        await until(lambda: not dono.channels["zika"].flags & wire.CHAN_PASSWORD, what="tirar a senha")

    async def test_canal_invisivel_com_senha_e_trancado_pra_quem_e_de_fora(self):
        dono = await self.join(Client(self.room.invite(), "Dono", key=4242))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        bia = await self.join(Client(self.room.invite(), "Bia"))
        said: list = []
        bia.on("message")(_collect(said))
        await dono.join_channel("zika")
        await until(lambda: dono.channel == "zika" and "zika" in ana.channels, what="criar o canal")
        await self.chan_admin(dono, 6, "zika", "1")
        await self.chan_admin(dono, 3, "zika", "abc")
        await until(lambda: "zika" not in ana.channels, what="sumir da lista de quem é de fora")
        await until(lambda: dono.channels["zika"].flags & wire.CHAN_PASSWORD, what="a senha valer")
        said.clear()  # ("Dono foi pro #zika" foi antes de ficar invisível)
        notes: list = []

        async def on_notice(kind, text, extra):
            notes.append(text)
        ana.on("notice")(on_notice)
        # sabendo o nome, sem a senha: não entra nem no chat nem na call
        await ana.join_call("zika")
        await ana.join_channel("zika")
        await until(lambda: len(notes) >= 2, what="os dois avisos de senha")
        self.assertEqual((ana.channel, ana.call), ("geral", "geral"))
        self.assertNotIn("zika", ana.channels)
        # pelo convite direto no canal, sem senha: começa no padrão e não vê o canal
        sem = await self.join(Client(self.room.invite(), "Sem", channel="zika"))
        self.assertEqual(sem.channel, "geral")
        self.assertNotIn("zika", sem.channels)
        # com a senha entra (e aí vê o canal); quem ficou no #geral não fica sabendo o nome
        await ana.join_channel("zika", "abc")
        await until(lambda: ana.channel == "zika" and "zika" in ana.channels, what="entrar com a senha")
        await until(lambda: any(m.text.startswith("Ana ") for m in said), what="o aviso de que a Ana saiu")
        self.assertEqual([m.text for m in said if m.text.startswith("Ana ")], ["Ana foi pra outro canal"])
        # trancado: nem com a senha
        await self.chan_admin(dono, 2, "zika", "1")
        await until(lambda: dono.channels["zika"].flags & wire.CHAN_LOCKED, what="trancar")
        await sem.join_channel("zika", "abc")
        await asyncio.sleep(0.5)
        self.assertEqual(sem.channel, "geral")
        self.assertNotIn("zika", sem.channels)

    async def test_op_do_canal(self):
        dono = await self.join(Client(self.room.invite(), "Dono", key=4242))
        ana = await self.join(Client(self.room.invite(), "Ana", key=5151))
        bia = await self.join(Client(self.room.invite(), "Bia"))
        await dono.join_channel("zika")
        await until(lambda: dono.channel == "zika", what="criar o canal")
        mine = wire.CHAN_MINE | wire.CHAN_CREATOR
        self.assertEqual(dono.channels["zika"].flags & mine, mine)
        await ana.join_channel("zika")
        await bia.join_channel("zika")
        await until(lambda: ana.channel == "zika" and bia.channel == "zika", what="as duas entrarem")
        # quem criou aparece como OP pra quem está no canal
        await until(lambda: ana.members[dono.me].op and not ana.members[bia.me].op, what="o dono aparecer como OP")
        self.assertFalse(ana.channels["zika"].flags & wire.CHAN_MINE)
        # sem OP não manda
        await self.chan_admin(ana, 4, "zika", "tópico da Ana")
        await self.chan_admin(ana, 9, "zika", "1", bia.me)
        await asyncio.sleep(0.4)
        self.assertEqual(dono.channels["zika"].topic, "")
        self.assertFalse(dono.members[bia.me].op)
        # o dono dá OP pra Ana: ela vê que manda, todo mundo vê a coroa
        await self.chan_admin(dono, 9, "zika", "1", ana.me)
        await until(lambda: ana.channels["zika"].flags & mine == wire.CHAN_MINE, what="a Ana virar OP")
        await until(lambda: bia.members[ana.me].op, what="a Bia ver a Ana como OP")
        # OP: tópico, invisível, trava, senha
        await self.chan_admin(ana, 4, "zika", "agora é da Ana")
        await self.chan_admin(ana, 6, "zika", "1")
        await self.chan_admin(ana, 2, "zika", "1")
        await self.chan_admin(ana, 3, "zika", "abc")
        want = wire.CHAN_HIDDEN | wire.CHAN_LOCKED | wire.CHAN_PASSWORD
        await until(lambda: dono.channels["zika"].flags & want == want and dono.channels["zika"].topic == "agora é da Ana", what="as mudanças da OP")
        # OP não apaga o canal, não tira o OP de quem criou nem tira ele do canal
        await self.chan_admin(ana, 8, "zika")
        await self.chan_admin(ana, 9, "zika", "0", dono.me)
        await self.chan_admin(ana, 7, "zika", "", dono.me)
        await asyncio.sleep(0.4)
        self.assertEqual(dono.channel, "zika")
        self.assertIn("zika", dono.channels)
        self.assertTrue(bia.members[dono.me].op)
        # OP leva gente do canal dela: pra um canal aberto vai; pra um com senha de outro, não
        carla = await self.join(Client(self.room.invite(), "Carla"))
        await carla.join_channel("outro")
        await until(lambda: carla.channel == "outro", what="a Carla criar o #outro")
        await self.chan_admin(carla, 3, "outro", "xyz")
        await until(lambda: ana.channels.get("outro") and ana.channels["outro"].flags & wire.CHAN_PASSWORD, what="a senha do #outro")
        await self.chan_admin(ana, 5, "outro", "", bia.me)
        await asyncio.sleep(0.4)
        self.assertEqual(bia.channel, "zika")
        # e não leva quem está em outro canal
        await self.chan_admin(ana, 5, "zika", "", carla.me)
        await asyncio.sleep(0.4)
        self.assertEqual(carla.channel, "outro")
        await self.chan_admin(ana, 5, "geral", "", bia.me)
        await until(lambda: bia.channel == "geral", what="a OP levar a Bia pro #geral")
        # tirada do canal por uma OP: não volta (nem com a senha)
        await self.chan_admin(ana, 7, "zika", "", bia.me)
        await asyncio.sleep(0.9)
        await bia.join_channel("zika", "abc")
        await asyncio.sleep(0.5)
        self.assertEqual(bia.channel, "geral")
        # o OP fica gravado
        state = (Path(self.room.dir.name) / "estado.txt").read_text()
        self.assertIn(f"op\tzika\t{5151:x}", state)
        # quem criou tira o OP da Ana
        await self.chan_admin(dono, 9, "zika", "0", ana.me)
        await until(lambda: not ana.channels["zika"].flags & wire.CHAN_MINE, what="a Ana perder o OP")
        await until(lambda: not dono.members[ana.me].op, what="a coroa da Ana sumir")
        await self.chan_admin(ana, 4, "zika", "de novo")
        await asyncio.sleep(0.4)
        self.assertEqual(dono.channels["zika"].topic, "agora é da Ana")
        # o padrão não tem OP
        await self.chan_admin(dono, 9, "geral", "1", bia.me)
        await asyncio.sleep(0.4)
        self.assertFalse(dono.channels["geral"].flags & wire.CHAN_MINE)

    async def test_apagar_canal(self):
        dono = await self.join(Client(self.room.invite(), "Dono"))
        ana = await self.join(Client(self.room.invite(), "Ana"))
        await dono.join_channel("zika")
        await until(lambda: dono.channel == "zika", what="criar o canal")
        await ana.join_channel("zika")
        await until(lambda: ana.channel == "zika", what="a Ana entrar")
        await asyncio.sleep(0.9)
        await ana.join_call("zika")
        await until(lambda: ana.call == "zika", what="a Ana na call")
        # quem não criou não apaga
        await self.chan_admin(ana, 8, "zika")
        await asyncio.sleep(0.5)
        self.assertIn("zika", dono.channels)
        # o padrão ninguém apaga
        await self.chan_admin(dono, 8, "geral")
        # quem criou apaga: todo mundo vai pro padrão e a call acaba
        await self.chan_admin(dono, 8, "zika")
        await until(lambda: "zika" not in ana.channels and "zika" not in dono.channels, what="o canal sumir")
        await until(lambda: ana.channel == "geral" and dono.channel == "geral" and ana.call == "", what="todo mundo no padrão")
        self.assertIn("geral", dono.channels)


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
