# telinha (Python SDK)

<sub>[🇺🇸 English](README.md) · [🇧🇷 Português](README.pt.md)</sub>

Bots for [telinha](https://rshacudevidro.github.io/telinha/en/), the low-latency
group screen-sharing app: chat, commands, reactions, private messages, channels,
music in the call and files.

```sh
pip install "git+https://github.com/RshaCuDeVidro/telinha#subdirectory=sdk/python"
```

```python
import random
from telinha import Bot

bot = Bot("telinha://my.room:7777#password", "Dice")

@bot.command("dado", help="rolls a die")
async def dado(ctx, sides: int = 6):
    await ctx.reply(f"🎲 {random.randint(1, sides)}")

bot.run()
```

Bots show up in the room with a **BOT** tag and never become admin. Python 3.10+,
`cryptography`, and ffmpeg to play sound.

- Guide: https://rshacudevidro.github.io/telinha/en/docs/bots/
- Tutorial: https://rshacudevidro.github.io/telinha/en/docs/bots-tutorial/
- API reference: https://rshacudevidro.github.io/telinha/en/docs/bots-api/
- Examples: [`examples/`](examples)

Tests run against a real `telinha-server` built from the repository (each test
starts a private room on 127.0.0.1):

```sh
zig build server && python3 -m unittest discover -s sdk/python/tests -v
```

MIT license.
