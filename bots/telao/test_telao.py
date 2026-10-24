"""Testes do bot de tela contra um telinha-server de verdade (sala local).

    python3 -m unittest discover -s bots/telao -v
"""
from __future__ import annotations

import asyncio
import functools
import http.server
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python"))
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python" / "tests"))

from telao import FORMAT, Resolver, ScreenBot, _codec, _short  # noqa: E402
from telinha import Client  # noqa: E402
from telinha.wire import MsgType, Writer  # noqa: E402
from test_sdk import Room, server_binary, until  # noqa: E402


class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


@unittest.skipUnless(Path(server_binary()).exists() and shutil.which("ffmpeg") and shutil.which("ffprobe"),
                     "precisa do telinha-server compilado e do ffmpeg")
class ScreenBotTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.room = Room()
        self.dir = tempfile.TemporaryDirectory()
        # 4 s de H.264 com quadros B e som, servido por http (o índice no começo: o servidor de teste não pula pedaços)
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=30", "-f", "lavfi",
                        "-i", "sine=f=440:r=48000", "-t", "4", "-c:v", "libx264", "-profile:v", "high", "-bf", "3", "-g", "30",
                        "-c:a", "aac", "-shortest", "-movflags", "+faststart", str(Path(self.dir.name) / "filme.mp4")], check=True)
        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(_Quiet, directory=self.dir.name))
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.http.server_address[1]}/filme.mp4"
        self.bot = ScreenBot(self.room.invite(), "Telão", resolver=Resolver(720), cooldown=0, accept_bots=True)
        self.ana = Client(self.room.invite(), "Ana")
        self.tasks = [asyncio.create_task(self.bot.start()), asyncio.create_task(self.ana.start())]
        await self.bot.wait_ready(8)
        await self.ana.wait_ready(8)
        self.got, self.edits, self.frames = [], [], []

        async def on_msg(m):
            self.got.append(m)

        async def on_edit(mid, text, emb):
            self.edits.append((mid, text, emb))
            for m in self.got:
                if m.id == mid:
                    m.text, m.embed = text, emb
        self.ana.on("message")(on_msg)
        self.ana.on("edit")(on_edit)
        orig = self.ana._dispatch

        async def spy(typ, p):
            if typ == MsgType.FRAME:
                self.frames.append(time.monotonic())
            await orig(typ, p)
        self.ana._dispatch = spy

    async def asyncTearDown(self):
        self.bot.queue.clear()
        try:
            await asyncio.wait_for(self.bot.player.stop(), 5)
        except TimeoutError:
            pass
        if self.bot._loop_task:
            self.tasks.append(self.bot._loop_task)
        for t in self.tasks:
            t.cancel()
        try:
            await asyncio.wait_for(asyncio.gather(*self.tasks, return_exceptions=True), 15)
        except TimeoutError:
            pass
        self.http.shutdown()
        self.bot.tmp.cleanup()
        self.dir.cleanup()
        self.room.close()

    def card(self, kicker: str):
        for m in reversed(self.got):
            if m.author_id == self.bot.me and m.embed and m.embed.kicker == kicker:
                return m
        return None

    async def test_assiste_um_link_com_painel(self):
        await self.ana.join_call("geral")
        await self.ana.send("!join")
        await until(lambda: self.bot.call == "geral", 5, "o bot na call")
        await self.ana.send("!watch " + self.url)
        await until(lambda: self.card("NOW SHOWING"), 10, "o painel")
        np = self.card("NOW SHOWING")
        self.assertTrue(np.embed.panel)
        self.assertEqual([b.label for b in np.embed.buttons], ["Pause", "Skip", "Stop"])
        self.assertAlmostEqual(np.embed.progress[1], 4000, delta=200)  # a duração do arquivo (não "ao vivo")
        await until(lambda: self.ana.members[self.bot.me].streaming, 5, "o bot ao vivo")
        await self.ana._send(Writer(MsgType.WATCH).u32(self.bot.me).u8(1).u8(0).done())
        await until(lambda: len(self.frames) > 15, 5, "os quadros chegarem")
        self.assertTrue(self.bot.player.passthrough)
        # pausar pelo botão do painel: os quadros param
        await self.ana.click(np.id, 0)
        await until(lambda: any(e[0] == np.id and e[2] and e[2].kicker == "PAUSED" for e in self.edits), 5, "o painel pausar")
        await asyncio.sleep(0.3)
        n = len(self.frames)
        await asyncio.sleep(0.6)
        self.assertLessEqual(len(self.frames) - n, 1)
        await self.ana.click(np.id, 0)  # continuar
        await until(lambda: len(self.frames) > n + 10, 5, "voltar a passar")
        # acabou a fila: o cartão fecha e a tela some
        await until(lambda: any(e[0] == np.id and e[2] and e[2].kicker == "SHOWN" for e in self.edits), 10, "o painel fechar no fim")
        await until(lambda: not self.ana.members[self.bot.me].streaming, 5, "a tela sumir")

    async def test_ajuda(self):
        await self.ana.send("!ajuda")
        await until(lambda: self.card("BIG SCREEN"), 5, "a ajuda")
        self.assertGreaterEqual(len(self.card("BIG SCREEN").embed.fields), 3)


class ScreenBotUnitTest(unittest.TestCase):
    def test_codec_do_ytdlp(self):
        self.assertEqual(_codec("avc1.64001F"), "h264")
        self.assertEqual(_codec("vp09.00.40.08"), "vp09")
        self.assertEqual(_codec("av01.0.08M.08"), "av01")
        self.assertIn("[vcodec^=avc1][height<=480]", FORMAT.format(h=480))

    def test_erro_curto(self):
        self.assertIn("cookies", _short(RuntimeError("ERROR: [youtube] x: Sign in to confirm you're not a bot")))
        self.assertLessEqual(len(_short(RuntimeError("x" * 900))), 200)


if __name__ == "__main__":
    unittest.main()
