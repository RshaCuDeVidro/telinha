"""Enquete com reações: !enquete pizza ou hambúrguer?

O bot manda a pergunta (o send devolve a mensagem, com o id), reage com 👍 e
❤️ pra começar e, depois de um minuto, conta quem reagiu (cada reação chega
como evento).

    python3 enquete.py "telinha://sala.exemplo:7777#senha"
"""
import asyncio
import sys

from telinha import Bot, Reaction

bot = Bot(sys.argv[1], "Enquete")
votes: dict[int, dict[int, set[int]]] = {}  # mensagem -> reação -> quem


@bot.on("reaction")
async def contou(message_id, member_id, reaction, on):
    if message_id in votes and member_id != bot.me:
        who = votes[message_id].setdefault(reaction, set())
        (who.add if on else who.discard)(member_id)


@bot.command(help="abre uma enquete de 1 minuto: 👍 = sim, ❤️ = não")
async def enquete(ctx, pergunta: str):
    msg = await ctx.send(f"📊 **{pergunta}**\nReaja: 👍 sim · ❤️ não (1 minuto)")
    if not msg:
        return
    votes[msg.id] = {}
    await msg.react(Reaction.LIKE)
    await msg.react(Reaction.LOVE)
    await asyncio.sleep(60)
    v = votes.pop(msg.id)
    sim, nao = len(v.get(Reaction.LIKE, set()) - {bot.me}), len(v.get(Reaction.LOVE, set()) - {bot.me})
    await msg.reply(f"Resultado: 👍 {sim} · ❤️ {nao}")


bot.run()
