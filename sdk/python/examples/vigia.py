"""Avisa no chat quando um servidor (jogo, site...) cai ou volta.

    python3 vigia.py "telinha://sala.exemplo:7777#senha" mc.exemplo.com:25565

Confere a porta TCP a cada 30 s. Não precisa de comando: só avisa.
"""
import asyncio
import sys

from telinha import Client

alvo = sys.argv[2]
host, _, port = alvo.rpartition(":")
client = Client(sys.argv[1], "Vigia")


async def no_ar() -> bool:
    try:
        _, w = await asyncio.wait_for(asyncio.open_connection(host, int(port)), 5)
        w.close()
        return True
    except (OSError, asyncio.TimeoutError):
        return False


async def vigiar():
    await client.wait_ready()
    estava = await no_ar()
    while True:
        await asyncio.sleep(30)
        agora = await no_ar()
        if agora != estava:
            await client.send(f"🟢 {alvo} voltou!" if agora else f"🔴 {alvo} caiu.")
            estava = agora


async def main():
    tarefa = asyncio.create_task(vigiar())
    try:
        await client.start()
    finally:
        tarefa.cancel()


asyncio.run(main())
