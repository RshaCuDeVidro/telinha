# Bots

<sub>[🇺🇸 English](BOTS.md) · [🇧🇷 Português](BOTS.pt.md)</sub>

A bot is a program that joins the room as one more person: it reads and sends
messages, answers commands (`!dado 20`), reacts, switches channels, plays sound
in the call, streams its own screen and sends files. telinha ships a
ready-made [music bot](BOTS_MUSIC.md) and [big-screen bot](BOTS_SCREEN.md)
(plays videos for everyone to watch together), and a **Python SDK**
(`sdk/python` in the repository) for making your own.

A bot runs anywhere that can reach the room: your PC, a VPS, a Raspberry Pi. It
costs the streamer nothing.

## How a bot shows up

- With a **BOT** tag next to its name, in the member list and in the chat.
- **It never becomes admin**, not even by sending the owner token, and not even
  if the owner tries to promote it.
- Admins kick, ban and mute a bot like anyone else. Muted, its voice (the
  music) stops reaching everyone.
- Each person sets the bot's volume just for themselves, by right-clicking its
  name.

## The room owner decides

By default, any bot with the room password gets in. On a
[dedicated server](DEPLOY.md):

| Option | What it does |
|---|---|
| `--sem-bots` | Refuses every bot (`TELINHA_SEM_BOTS=1`). |
| `--token-bots SECRET` | Only bots that send this token get in (`TELINHA_TOKEN_BOTS`). People still join with just the room password. |

> [!NOTE]
> The tag is honest, not a lock: a program pretending to be the app doesn't
> show up as a bot. But it gains nothing by doing so, because a bot can do
> everything a person can, except become admin.

## Install the SDK

You need Python 3.10 or newer.

```sh
pip install "git+https://github.com/RshaCuDeVidro/telinha#subdirectory=sdk/python"
```

Its only dependency is `cryptography` (the room's encryption). To play sound in
the call, you also need **ffmpeg** (`sudo apt install ffmpeg`,
`sudo pacman -S ffmpeg`, `winget install ffmpeg`).

## Your first bot

```python
import random
from telinha import Bot

bot = Bot("telinha://my.room:7777#password", "Dice")

@bot.command("dado", help="rolls a die (default: 6 sides)")
async def dado(ctx, sides: int = 6):
    await ctx.reply(f"rolled {random.randint(1, sides)}")

bot.run()
```

Run it with `python3 dice.py`, and someone in the room types `!dado 20`. `!ajuda`
(or `!help`) lists the commands by itself. The invite is the same one you send
your friends (the app's **Copy invite** button).

> [!TIP]
> The prefix is `!` because `/` belongs to the app's own commands (`/join`,
> `/msg`).

## Next steps

- [Music bot](BOTS_MUSIC.md): install it, commands, radios, keeping it on a VPS.
- [Big-screen bot](BOTS_SCREEN.md): videos on the bot's screen, with the panel under the video.
- [Make a bot](BOTS_TUTORIAL.md): step by step, from commands to events, polls, music and files.
- [API reference](BOTS_API.md): every class, method and event.
- Ready-made examples in [`sdk/python/examples`](../sdk/python/examples): `dado.py`, `eco.py`, `enquete.py`, `vigia.py`.

## Testing without bothering anyone

Before putting a bot in a busy room, test it in a room of your own: create a
room in the app (**Create room**) or run a `telinha-server` on your machine,
and point the bot at it:

```sh
./telinha-server --porta 7790 --senha test
python3 dice.py "telinha://127.0.0.1:7790#test"
```
