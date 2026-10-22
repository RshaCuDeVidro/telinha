# Make a bot

<sub>[🇺🇸 English](BOTS_TUTORIAL.md) · [🇧🇷 Português](BOTS_TUTORIAL.pt.md)</sub>

From zero to a bot that answers commands, reacts, talks in private, plays sound
and handles files. Each step runs on its own; combine whatever you like at the
end. Install the SDK first (see [Bots](BOTS.md#install-the-sdk)).

> [!TIP]
> Test in a room of your own: `./telinha-server --porta 7790 --senha test` and
> the invite `telinha://127.0.0.1:7790#test`. That way you can restart the bot
> as often as you like without bothering anyone.

## 1. Commands

```python
from telinha import Bot

bot = Bot("telinha://127.0.0.1:7790#test", "Helper")

@bot.command(help="repeats what you said")
async def say(ctx, phrase: str):
    await ctx.send(phrase)

bot.run()
```

- The command's name is the function's (`!say`), or whatever you pass:
  `@bot.command("fala", aliases=["speak"])`.
- The first parameter is always `ctx` ([Context](BOTS_API.md#context)).
- `ctx.reply(text)` answers **quoting** the command's message; `ctx.send(text)`
  sends to the same place, without quoting. If the command came in private,
  the answer goes in private too.

### Arguments

Arguments come out of the text by the function's types:

```python
@bot.command(help="adds two numbers")
async def add(ctx, a: int, b: int = 0):
    await ctx.reply(str(a + b))
```

| Type | Accepts |
|---|---|
| `int`, `float` | a number (`3,5` counts as `3.5`); otherwise the bot says it isn't a number |
| `str` | one word; **the last `str` takes the rest of the line**, no quotes needed |
| `Member` | the name (or `@name`) of someone in the room |
| `bool` | `yes`-ish words: `sim`, `1`, `on`, `liga`... |
| `*words` | every remaining word |

A required argument is missing: the bot replies with the right usage
(`Uso: !add <a> [b]`). Quotes group words: `!add "1" 2`.

### Help, flood control and admin

- `!ajuda` (and `!help`) lists the commands with their `help=` text.
- Each person can send one command per second (`Bot(..., cooldown=1.0)`).
- `@bot.command(admin_only=True)` only obeys room admins.
- A bot ignores commands from other bots (`accept_bots=True` changes that), so
  two bots don't keep answering each other forever.

## 2. Events

Besides commands, the bot can react to everything happening in the room:

```python
from telinha import Reaction

@bot.on("join")
async def arrived(member):
    if not member.bot:
        await bot.send(f"Welcome, {member.mention}!")

@bot.on("message")
async def message(msg):
    if msg.history or msg.system or msg.author_id == bot.me:
        return  # history, system notices and my own
    if "good morning" in msg.text.casefold():
        await msg.react(Reaction.LOVE)
```

The events: `ready`, `message`, `join`, `leave`, `members`, `reaction`,
`channels`, `notice`, `voice`, `web_link` and `disconnect` (details in the
[reference](BOTS_API.md#events)). Each handler runs in its own task: it can wait
as long as it likes (a download, a `sleep`) without blocking the rest.

> [!IMPORTANT]
> The `message` event also delivers old messages (`msg.history`), which arrive
> when the bot joins, and the bot's own. You almost always want to ignore both,
> as in the example.

## 3. Messages come back with an id

`send`, `reply` and `ctx.send` return the message as the room recorded it,
with its `id`. You can react to it, quote it later or follow its reactions:

```python
from telinha import Reaction

@bot.command(help="1-minute poll")
async def poll(ctx, question: str):
    msg = await ctx.send(f"**{question}** (react: like = yes, love = no)")
    await msg.react(Reaction.LIKE)
    await msg.react(Reaction.LOVE)
    ...
```

The whole example, counting votes through the `reaction` event, is in
[`examples/enquete.py`](../sdk/python/examples/enquete.py).

## 4. Cards and buttons

A card (`Embed`) is a message with a title, fields, a progress bar and buttons,
like the music bot's "now playing". Each button takes an `on_click`, called
when anyone in the room clicks it, with who clicked and where they are:

```python
from telinha import Embed, Icon

@bot.command(help="rolls a die, with a button to roll again")
async def roll(ctx):
    card = Embed(kicker="DICE", title=str(random.randint(1, 6)), color=0x22c55e)

    async def again(click):
        card.title = str(random.randint(1, 6))
        card.footer = f"rolled by {click.member_name}"
        await msg.edit(embed=card)          # changes the card in place

    card.add_button("Roll again", icon=Icon.DICE, style="primary", on_click=again)
    msg = await ctx.reply_card(card, "rolled a die")
```

`reply_card` answers quoting the command; the text is what apps before 3.4
show instead of the card. `send(..., image="cover.jpg")` attaches an image
(with `thumbnail=True` it becomes the card's cover). Everything about cards is
in the [reference](BOTS_API.md#embed).

## 5. Private messages, channels and the call

```python
await bot.send("just for you", to=member.id)       # private message
await bot.join_channel("games")                    # switches the chat
await bot.join_call("games")                       # joins the call (voice)
await bot.leave_call()
```

The SDK waits by itself for the gap the server requires between switches
(800 ms). `bot.channel`, `bot.call`, `bot.channels` and `bot.members` show where
the bot is and who's with it.

## 6. Sound in the call

```python
from telinha import Player

player = Player(bot)

@bot.command(help="plays the anthem")
async def anthem(ctx):
    await ctx.reply("playing the anthem")
    await player.play("anthem.mp3")        # returns when it ends
```

`Player` uses ffmpeg to open anything (a file, an `http://` radio), sends stereo
Opus at the right pace and turns the bot's "microphone" on while it plays.
`pause()`, `resume()`, `stop()`, `set_volume(0.5)` and `position` do the rest.
The [music bot](BOTS_MUSIC.md) is a complete example, with a queue.

## 7. Files

```python
@bot.on("message")
async def keep(msg):
    if msg.file and not msg.history:
        path = await bot.download(msg.file, "received/")
        print("downloaded", path)

@bot.command(help="sends the report")
async def report(ctx):
    await bot.send_file("report.pdf", reply_to=ctx.message.id)
```

Up to 256 MB per file. Uploading and downloading, the SDK follows the pace of
the server's acknowledgements (it doesn't trample the room's voice and video).

## 8. Running it for real

- `bot.run()` reconnects by itself if the connection drops (every 1 s, backing
  off to 30 s). If the room **refuses** the bot (wrong password, kicked, banned,
  a room without bots), it stops with the error: `Denied` or `WrongPassword`.
- Inside a larger `asyncio` program, use `await bot.start()` (and
  `await bot.stop()` to leave) instead of `run()`.
- Pass a fixed `key=` (`Bot(..., key=123456789)`) if you want a ban to stick
  across runs.
- An invite with the server's fingerprint (`!...` after the address) makes the
  SDK check it's talking to the right room before sending anything.
- `logging.basicConfig(level=logging.INFO)` shows what the SDK is doing (the
  logger is `telinha`).

To keep it running on a VPS, the [music bot's](BOTS_MUSIC.md#keeping-it-on-a-vps)
systemd setup works for any bot.
