"""O básico dos eventos: responde "oi" e dá boas-vindas a quem entra.

    python3 eco.py "telinha://sala.exemplo:7777#senha"
"""
import sys

from telinha import Client

client = Client(sys.argv[1], "Eco")


@client.on("ready")
async def pronto(welcome):
    print(f"dentro da sala {welcome.room!r} com o id {welcome.me}")


@client.on("message")
async def mensagem(msg):
    if msg.history or msg.system or msg.author_id == client.me:
        return  # histórico, avisos do sistema e as minhas
    if msg.text.casefold() in ("oi", "olá", "ola"):
        await msg.reply(f"oi, {msg.author}! 👋")


@client.on("join")
async def entrou(member):
    if not member.bot:
        await client.send(f"Bem-vindo(a), {member.mention}! 🎉")


client.run()
