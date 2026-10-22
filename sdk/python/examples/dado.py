"""O bot mais simples: !dado e !moeda.

    python3 dado.py "telinha://sala.exemplo:7777#senha"
"""
import random
import sys

from telinha import Bot

bot = Bot(sys.argv[1], "Dado")


@bot.command(help="joga um dado (padrão: 6 lados)")
async def dado(ctx, lados: int = 6):
    if not 2 <= lados <= 1000:
        return await ctx.reply("Entre 2 e 1000 lados.")
    await ctx.reply(f"🎲 {random.randint(1, lados)}")


@bot.command(help="cara ou coroa")
async def moeda(ctx):
    await ctx.reply(random.choice(["🪙 cara", "🪙 coroa"]))


bot.run()
