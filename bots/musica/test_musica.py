"""Testes do bot de música contra um telinha-server de verdade (sala local).

    python3 -m unittest discover -s bots/musica -v
    TELINHA_TESTE_REDE=1 ...   # também os que buscam no YouTube/SoundCloud
"""
from __future__ import annotations

import asyncio
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python"))
sys.path.insert(0, str(HERE.parents[1] / "sdk" / "python" / "tests"))

from musica import MusicBot, load_radios  # noqa: E402
from sources import Resolver  # noqa: E402
from telinha import Client  # noqa: E402
from test_sdk import Room, server_binary, until  # noqa: E402

REDE = os.environ.get("TELINHA_TESTE_REDE") == "1"


@unittest.skipUnless(os.path.exists(server_binary()) and shutil.which("ffmpeg"), "precisa do telinha-server compilado e do ffmpeg")
class MusicBotTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.room = Room()
        self.dir = tempfile.TemporaryDirectory()
        folder = Path(self.dir.name)
        for name, freq in (("Tom de teste", 440), ("Outro tom", 660)):
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=6",
                            "-metadata", f"title={name}", str(folder / f"{name}.ogg")], check=True)
        self.bot = MusicBot(self.room.invite(), "Música", resolver=Resolver(folder, {"teste": "https://example.invalid/x"}), volume=1.0, cooldown=0, accept_bots=True)
        self.ana = Client(self.room.invite(), "Ana")
        self.tasks = [asyncio.create_task(self.bot.start()), asyncio.create_task(self.ana.start())]
        await self.bot.wait_ready(8)
        await self.ana.wait_ready(8)
        self.got, self.edits, self.voice = [], [], []

        async def on_msg(m):
            self.got.append(m)

        async def on_edit(mid, text, emb):
            self.edits.append((mid, text, emb))

        async def on_voice(frm, seq, opus):
            self.voice.append(time.monotonic())
        self.ana.on("message")(on_msg)
        self.ana.on("edit")(on_edit)
        self.ana.on("voice")(on_voice)

    async def asyncTearDown(self):
        for t in self.tasks:
            t.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        self.bot.tmp.cleanup()
        self.dir.cleanup()
        self.room.close()

    def card(self, kicker: str):
        for m in reversed(self.got):
            if m.author_id == self.bot.me and m.embed and m.embed.kicker == kicker:
                return m
        return None

    async def test_toca_da_pasta_com_cartao_e_botoes(self):
        await self.ana.send("!play tom de teste")
        await until(lambda: self.card("NOW PLAYING"), 10, "o cartão de tocando agora")
        np = self.card("NOW PLAYING")
        self.assertEqual(np.embed.title, "Tom de teste")
        self.assertAlmostEqual(np.embed.progress[1], 6000, delta=100)  # a duração do arquivo (não "ao vivo")
        self.assertEqual([b.label for b in np.embed.buttons], ["Pause", "Skip", "Stop", "Shuffle", "Loop"])
        self.assertIsNotNone(np.embed.progress)
        await until(lambda: len(self.voice) > 20, 5, "o som chegar")
        # pausar pelo botão: o cartão muda no lugar e o som para
        await self.ana.click(np.id, 0)
        await until(lambda: any(e[0] == np.id and e[2] and e[2].kicker == "PAUSED" for e in self.edits), 5, "o cartão pausar")
        await asyncio.sleep(0.4)
        n = len(self.voice)
        await asyncio.sleep(0.6)
        self.assertLessEqual(len(self.voice) - n, 2)
        await self.ana.click(np.id, 0)  # continuar
        await until(lambda: any(e[0] == np.id and e[2] and e[2].kicker == "NOW PLAYING" for e in self.edits[1:]), 5, "o cartão voltar")
        # fila e pular
        await self.ana.send("!play outro tom")
        await until(lambda: self.card("ADDED TO QUEUE"), 5, "o aviso de fila")
        await self.ana.send("!queue")
        await until(lambda: self.card("QUEUE"), 5, "o cartão da fila")
        self.assertIn("Outro tom", self.card("QUEUE").embed.fields[0].value)
        await self.ana.send("!skip")
        await until(lambda: self.card("NOW PLAYING") and self.card("NOW PLAYING").embed.title == "Outro tom", 10, "pular pra próxima")
        await until(lambda: any(e[0] == np.id and e[2] and e[2].kicker == "STOPPED" for e in self.edits), 5, "o cartão anterior fechar")

    async def test_ajuda_e_comandos_em_portugues(self):
        await self.ana.send("!help")
        await until(lambda: self.card("MUSIC BOT"), 5, "a ajuda")
        self.assertGreaterEqual(len(self.card("MUSIC BOT").embed.fields), 4)
        await self.ana.send("!tocar tom de teste")  # o alias em português
        await until(lambda: self.card("NOW PLAYING"), 10, "tocar pelo alias")
        await self.ana.send("!buscar")
        await until(lambda: any(m.author_id == self.bot.me and "Usage" in m.text for m in self.got), 5, "o uso do comando")

    async def test_join_de_qualquer_canal(self):
        await self.ana.send("!join jogos")
        await until(lambda: self.bot.call == "jogos" and self.bot.channel == "jogos", 5, "o bot ir pro #jogos")
        # a Ana, em outro canal e outra call, chama em privado: o bot vai pra call dela
        await self.ana.join_channel("filmes")
        await self.ana.join_call("filmes")
        await until(lambda: self.ana.call == "filmes", 5, "a Ana na call do #filmes")
        await self.ana.send("!join", to=self.bot.me)
        await until(lambda: self.bot.call == "filmes", 5, "o bot ir pra call da Ana")

    @unittest.skipUnless(REDE, "TELINHA_TESTE_REDE=1 pra buscar na internet")
    async def test_busca_com_botoes_e_soundcloud_quando_o_youtube_recusa(self):
        await self.ana.send("!search falling in reverse popular monster")
        await until(lambda: self.card("SEARCH"), 30, "os resultados")
        sr = self.card("SEARCH")
        self.assertGreaterEqual(len(sr.embed.buttons), 3)
        self.bot.src._yt_blocked_until = float("inf")  # finge o IP bloqueado: tem que tocar pelo SoundCloud
        await self.ana.click(sr.id, 0)
        await until(lambda: self.card("NOW PLAYING"), 40, "tocar o escolhido")
        self.assertIn("SoundCloud", self.card("NOW PLAYING").embed.footer)
        await until(lambda: len(self.voice) > 50, 20, "o som da internet chegar")


@unittest.skipUnless(shutil.which("ffmpeg"), "precisa do ffmpeg")
class ProbeTest(unittest.IsolatedAsyncioTestCase):
    async def test_duracao_tags_e_capa_do_arquivo(self):
        with tempfile.TemporaryDirectory() as d:
            capa, musica = Path(d) / "capa.png", Path(d) / "Sem tag.flac"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=200x200", "-frames:v", "1", str(capa)], check=True)
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=3", "-i", str(capa), "-map", "0", "-map", "1",
                            "-disposition:v", "attached_pic", "-metadata", "artist=Fulano", str(musica)], check=True)
            src = Resolver(Path(d), {})
            t = await src.stream(src.file_track(src.search_library("sem tag")[0]))
            self.assertEqual((t.title, t.artist, t.thumbnail), ("Sem tag", "Fulano", str(musica)))
            self.assertAlmostEqual(t.duration_ms, 3000, delta=100)


class RadiosTest(unittest.TestCase):
    def test_arquivo_de_radios(self):
        r = load_radios(str(HERE / "radios-somafm.txt"))
        self.assertIn("defcon", r)
        self.assertTrue(all(u.startswith("https://") for u in r.values()))


if __name__ == "__main__":
    unittest.main()
