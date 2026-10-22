# telinha (SDK em Python)

<sub>[🇺🇸 English](README.md) · [🇧🇷 Português](README.pt.md)</sub>

Bots pro [telinha](https://rshacudevidro.github.io/telinha/), o app de
compartilhar a tela em grupo com atraso baixo: chat, comandos, reações,
privadas, canais, música na call e arquivos.

```sh
pip install "git+https://github.com/RshaCuDeVidro/telinha#subdirectory=sdk/python"
```

```python
import random
from telinha import Bot

bot = Bot("telinha://minha.sala:7777#senha", "Dado")

@bot.command(help="joga um dado")
async def dado(ctx, lados: int = 6):
    await ctx.reply(f"🎲 {random.randint(1, lados)}")

bot.run()
```

O bot aparece na sala com a etiqueta **BOT** e nunca vira admin. Python 3.10+,
`cryptography`, e o ffmpeg pra tocar som.

- Guia: https://rshacudevidro.github.io/telinha/docs/bots/
- Tutorial: https://rshacudevidro.github.io/telinha/docs/bots-tutorial/
- Referência da API: https://rshacudevidro.github.io/telinha/docs/bots-api/
- Exemplos: [`examples/`](examples)

Os testes rodam contra um `telinha-server` de verdade, compilado do
repositório (cada teste sobe uma sala privada em 127.0.0.1):

```sh
zig build server && python3 -m unittest discover -s sdk/python/tests -v
```

Licença MIT.
