"""Bot de teste do QA (cartao_de_bot): manda um cartão com capa, progresso e
botões; quem clicar em "Skip" faz ele editar o cartão e responder no chat."""
import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sdk", "python"))
from telinha import Client, Embed  # noqa: E402

capa = sys.argv[2]
bot = Client(sys.argv[1], "Cartao")


async def main():
    task = asyncio.create_task(bot.start())
    await bot.wait_ready(10)
    card = Embed(title="Popular Monster", kicker="NOW PLAYING", color=0xd946ef, url="https://example.com/musica",
                 description="**Falling In Reverse** · *Popular Monster*", progress=(30_000, 232_000), thumbnail=True,
                 footer="telinha · music")
    card.add_field("Requested by", "Bia").add_field("Queue", "3 tracks").add_field("Volume", "70%")

    async def skip(click):
        card.kicker = "SKIPPED"
        card.paused = True
        await sent.edit("skipped", embed=card)
        await bot.send(f"clicou: Skip ({click.member_name} em #{click.channel})")

    card.add_button("Pause", icon="pause", style="primary")
    card.add_button("Skip", icon="next", on_click=skip)
    card.add_button("Stop", icon="stop", style="danger")
    card.add_button("Shuffle", icon="shuffle")
    sent = await bot.send("Now playing: Popular Monster", embed=card, image=capa)
    await task

asyncio.run(main())
