"""Bot de teste do QA (painel_do_bot): põe um painel (set_panel) com um
contador; o botão "Mais" soma 1 e conta no painel quem clicou e de onde."""
import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sdk", "python"))
from telinha import Client, Embed  # noqa: E402

bot = Client(sys.argv[1], "Painel")
n = 0


def panel(who: str = "") -> Embed:
    e = Embed(kicker="CONTROLES", title=f"Painel {n}", color=0xd946ef, description=who or "ninguém clicou ainda",
              progress=(10_000, 200_000), footer="telinha · painel")
    e.add_field("Fila", "2 músicas")
    e.add_button("Mais", icon="plus", style="primary", on_click=more)
    e.add_button("Nada", icon="close")
    return e


async def more(click):
    global n
    n += 1
    await bot.set_panel(panel(f"{click.member_name} em #{click.channel} (painel: {click.panel})"))


async def main():
    task = asyncio.create_task(bot.start())
    await bot.wait_ready(10)
    await bot.set_panel(panel())
    await task

asyncio.run(main())
