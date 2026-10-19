#!/usr/bin/env python3
"""Servidor de túnel local que fala o protocolo do bore (pra testar o link público
sem sair da máquina). uso: mockbore.py PORTA_CONTROLE"""
import asyncio, json, sys, uuid

conns = {}

async def read_frame(r):
    data = await r.readuntil(b"\0")
    return json.loads(data[:-1])

async def send(w, obj):
    w.write(json.dumps(obj).encode() + b"\0")
    await w.drain()

async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        w.close()

async def control(r, w):
    msg = await read_frame(r)
    if "Hello" in msg:
        async def visitor(vr, vw):
            cid = str(uuid.uuid4())
            conns[cid] = (vr, vw)
            await send(w, {"Connection": cid})
        srv = await asyncio.start_server(visitor, "127.0.0.1", msg["Hello"] or 0)
        port = srv.sockets[0].getsockname()[1]
        print(f"túnel aberto na porta {port}", flush=True)
        await send(w, {"Hello": port})
        try:
            while True:
                await asyncio.sleep(0.5)
                await send(w, "Heartbeat")
        except Exception:
            srv.close()
    elif "Accept" in msg:
        vr, vw = conns.pop(msg["Accept"])
        await asyncio.gather(pipe(r, vw), pipe(vr, w))

async def main():
    srv = await asyncio.start_server(control, "127.0.0.1", int(sys.argv[1]))
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
