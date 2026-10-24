# API reference

<sub>[🇺🇸 English](BOTS_API.md) · [🇧🇷 Português](BOTS_API.pt.md)</sub>

The `telinha` package (`sdk/python`), version 0.2. Everything is `asyncio`:
methods marked `await` are coroutines. To get started, see the
[tutorial](BOTS_TUTORIAL.md).

```python
from telinha import Bot, Client, Player, Reaction, Member, Message, Denied
from telinha import Embed, Button, Click, Icon, Style
```

## Client

A connection to the room, with its state and events. `Bot` is a `Client` with
commands; use `Client` directly when you don't need commands.

```python
Client(invite, name, *, password=None, channel=None, bot_token="", key=None, reconnect=True)
```

| Parameter | |
|---|---|
| `invite` | the invite (`telinha://addr1,addr2/channel!fingerprint#password`), or just `host:port`; an `Invite` works too |
| `name` | the name in the room (up to 32 bytes; a repeated one gets ` (2)`) |
| `password` | the room password, if the invite doesn't carry it |
| `channel` | channel to join, if the invite doesn't carry one (otherwise the room's default) |
| `bot_token` | the bot token, if the room asks for one (`--token-bots`) |
| `key` | a number identifying the bot for bans (default: drawn on every run) |
| `reconnect` | reconnect by itself when the connection drops (default `True`) |

### State

| Attribute | |
|---|---|
| `me` | the bot's id in the room |
| `room` | the room's name |
| `welcome` | the `Welcome` from the last join |
| `members` | `dict[int, Member]`: who the bot can see (its text channel and its call) |
| `channel` | the current text channel |
| `call` | the current call (`""` = none) |
| `channels` | `dict[str, ChannelInfo]` |
| `room_locked` | the room is locked |
| `fingerprint` | the server identity's fingerprint (or `None` if it has none) |
| `web_link` | the link to watch from a browser (`""` = none) |

### Methods

| Method | |
|---|---|
| `run()` | runs until stopped (Ctrl+C too); blocks |
| `await start()` | the same, inside an `asyncio` program; raises `Denied` / `WrongPassword` |
| `await stop()` | leaves the room |
| `await wait_ready(timeout=None)` | waits until the bot is in the room |
| `on(event)` | handler decorator: `@client.on("message")` |
| `off(event, fn)` | removes a handler |
| `await send(text, *, embed=None, image=None, reply_to=0, to=0, wait=True)` | sends to the chat; `reply_to` quotes a message, `to` sends privately, `embed` attaches a [card](#embed), `image` an image (a file, a link or a `ChatImage`; needs ffmpeg). Returns the recorded `Message` (or `None`). Over 4000 bytes becomes several messages |
| `await edit(message_id, text, *, embed=None)` | changes one of the bot's own messages (text and card; the image stays) |
| `await click(message_id, button)` | clicks a button on another bot's card |
| `await react(message_id, reaction, on=True)` | adds (or removes) a reaction |
| `await join_channel(name, password="")` | switches the text channel (creates it if missing and the server allows) |
| `await join_call(name, password="")` / `await leave_call()` | joins a channel's call / leaves it |
| `await set_voice(mic=None, deaf=None)` | microphone on (shown in the list) / deafened |
| `await send_voice(opus)` | one Opus packet (48 kHz) in the call; prefer `Player` |
| `await send_file(path, *, name=None, to=0, reply_to=0, progress=None)` | sends a file (up to 256 MB); returns its id |
| `await download(file_info, dest)` | downloads a room file (`msg.file`); `dest` can be a folder |
| `member(id_or_name)` | finds someone by id or name (with or without `@`) |
| `room_time_us()` | now, on the room clock |

## Events

| Event | Arguments | When |
|---|---|---|
| `ready` | `welcome: Welcome` | joined the room (again too, after reconnecting) |
| `message` | `msg: Message` | a message in the channel chat or in private, including the bot's own and old ones (`msg.history`) |
| `join` | `member: Member` | someone appeared (in the bot's text channel or call) |
| `leave` | `member: Member` | someone left |
| `members` | `members: list[Member]` | the list changed (anything: mic, stream...) |
| `reaction` | `message_id, member_id, reaction, on` | someone added or removed a reaction |
| `action` | `click: Click` | someone clicked a button on one of the bot's cards (the button's `on_click` is called too) |
| `edit` | `message_id, text, embed` | a message changed (a bot updating its card) |
| `channels` | `current: str, channels: dict` | the channel list changed (or the bot switched) |
| `notice` | `kind, text, extra` | something an admin did to the bot (`Notice`) |
| `voice` | `member_id, seq, opus` | someone's voice in the call (raw Opus packet) |
| `web_link` | `url` | the browser link changed |
| `disconnect` | `reason` | the connection dropped (it will retry) |

Each handler runs in its own task; an error in one goes to the log and doesn't
bring the bot down.

## Bot

```python
Bot(invite, name, *, prefix="!", help_command="ajuda", cooldown=1.0, accept_bots=False, lang="pt", **client_options)
```

| Parameter | |
|---|---|
| `prefix` | what comes before commands |
| `help_command` | the automatic help command's name (`None` = none; `help` also works) |
| `cooldown` | seconds between commands from the same person |
| `accept_bots` | obey commands from other bots |
| `lang` | language of what the SDK answers by itself (wrong usage, errors, help): `"pt"` or `"en"` |

`@bot.command(name=None, *, help="", aliases=(), admin_only=False)` registers a
command. The function receives `ctx` and the arguments, converted by their
types (`int`, `float`, `str`, `bool`, `Member`, `*rest`); the last `str` takes
the rest of the line. `bot.commands` holds them all.

Raising `CommandError("text")` inside a command replies with that text to
whoever called it. Any other error goes to the log and the bot answers with a
generic error message.

## Context

| | |
|---|---|
| `ctx.bot` | the bot |
| `ctx.message` | the command's `Message` |
| `ctx.command` | the `Command` |
| `ctx.args` | the raw text after the command |
| `ctx.author` | the calling `Member` (or `None` if they already left) |
| `await ctx.reply(text)` | answers quoting; returns the `Message` |
| `await ctx.send(text)` | sends to the same place (channel or private); returns the `Message` |
| `await ctx.reply_card(embed, text="", *, image=None)` | answers with a card, quoting; `text` is what apps before 3.4 show instead |

## Message

| | |
|---|---|
| `id` | the id in the room |
| `author_id`, `author` | who sent it (`0` = system notice) |
| `text` | the text (Markdown as typed) |
| `time_us` | the time on the room clock |
| `history` | it's old (arrived because the bot just joined) |
| `system` | it's a system notice ("Ana joined the room") |
| `quote` | if it's a reply: `Quote(id, author_id, author, text)` |
| `private`, `to_id`, `to_name` | private, and to whom |
| `file` | if it has a file: `FileInfo(id, name, size)` |
| `has_image` | has an image (the SDK doesn't decode images) |
| `reactions` | `[(reaction, member_id)]` (only on old ones; new ones come through the event) |
| `channel` | the bot's text channel when it arrived |
| `embed` | the card (`Embed`), if it has one |
| `author_channel`, `author_call` | where the author is (text channel and call; `""` = not in a call). The server only tells bots, and it works in private too: that's how `/msg Bot !join` knows where to go |
| `await reply(text)` | answers quoting (privately if it was private) |
| `await respond(text)` | answers in the same place, without quoting |
| `await react(reaction, on=True)` | |
| `await edit(text=None, *, embed=None)` | changes the message (only the bot's own) |

## Member

| | |
|---|---|
| `id`, `name`, `mention` | `mention` = `"@name"` |
| `bot` | is a bot |
| `owner`, `admin` | created the room / is an admin |
| `streaming`, `camera` | streaming the screen / the camera |
| `mic`, `deaf`, `muted` | microphone on / deafened / muted by an admin |
| `in_channel`, `in_call` | is in the bot's text channel / the bot's call |
| `route` | how they got in (1 this machine, 2 LAN, 3–4 internet, 5 public link, 6 browser) |
| `version` | their app version |
| `watching` | the streams they're watching |

## ChannelInfo

`name`, `people` (in the chat), `in_call`, `topic`, plus `live`, `fixed`,
`has_password`, `locked`.

## Player

```python
Player(client, *, bitrate=128_000, stereo=True, ffmpeg="ffmpeg")
```

| | |
|---|---|
| `await play(source, *, volume=None, start=0.0, headers=None)` | plays a file or link to the end; returns `True` if it finished, `False` if stopped. Turns the bot's mic on while playing. `headers`: HTTP headers for the link (what yt-dlp says to use) |
| `pause()` / `resume()` | |
| `await stop()` | stops (`play` returns `False`) |
| `set_volume(0.0–2.0)` | takes effect in about half a second, without restarting the song (the gain is applied to the samples) |
| `playing`, `paused`, `position`, `source`, `volume` | |

Needs ffmpeg (`FFmpegMissing` if absent).

## Embed

A card in the chat: a colored bar, a small line on top (`kicker`), a title
(a link, with `url`), Markdown text, fields side by side, a progress bar that
moves by itself in each app, and up to 5 buttons. Apps before 3.4 show only
the message text.

```python
card = Embed(title="Popular Monster", kicker="NOW PLAYING", color=0xd946ef,
             description="by **Falling In Reverse**", url="https://...",
             progress=(31_000, 232_000), thumbnail=True, footer="SoundCloud")
card.add_field("Requested by", "Ana").add_field("Up next", "Voices in My Head")
card.add_button("Pause", icon=Icon.PAUSE, style="primary", on_click=pause)
card.add_button("Skip", icon="next", on_click=skip)
msg = await bot.send("Now playing: Popular Monster", embed=card, image="cover.jpg")
...
card.kicker, card.paused = "PAUSED", True
await msg.edit(embed=card)
```

| | |
|---|---|
| `title`, `url`, `kicker`, `description`, `footer` | text (the description takes `**bold**`, `*italic*`, `` `code` `` and `[links](https://...)`) |
| `color` | `0xRRGGBB` of the bar (`0` = the viewer's theme accent) |
| `thumbnail` / `big_image` | the message's image goes as the cover (in the corner) / large, below |
| `progress`, `paused` | `(position_ms, total_ms)`; total `0` = live. Each app moves it by itself until `paused` |
| `add_field(name, value, inline=True)` | up to 12 |
| `add_button(label="", *, icon=Icon.NONE, style="neutral", disabled=False, on_click=None)` | up to 5. `style`: `neutral`, `primary`, `danger`, `success`. `on_click`: `async def f(click: Click)` |

`Icon`: `PLAY`, `PAUSE`, `NEXT`, `PREVIOUS`, `STOP`, `SHUFFLE`, `REPEAT`,
`VOLUME_UP`, `VOLUME_DOWN`, `LIST`, `HEART`, `MUSIC`, `RADIO`, `SEARCH`,
`PLUS`, `CHECK`, `CLOSE`, `LINK`, `JOIN`, `TRASH`, `STAR`, `DICE` (or the name
as text: `icon="next"`).

A click reaches only the card's author, at most every 120 ms per person, and
edits at most every 200 ms (the SDK waits for its turn, so two edits in a row
both get through). The SDK remembers the buttons of the last 300 cards.

### Click

| | |
|---|---|
| `message_id`, `button` | which card and which button (from 0) |
| `member_id`, `member_name` | who clicked |
| `channel`, `call` | where they are |
| `await reply(text, **kw)` | answers quoting the card |
| `await whisper(text)` | answers only to whoever clicked (private) |

## Invite

`Invite.parse(text)` → `addresses` (a list of `Address(host, port)`),
`password`, `channel`, `fingerprint`. `str(invite)` builds the invite back.

## Errors

| | |
|---|---|
| `Denied` | the room refused or removed the bot; `reason` and `code` (`Deny`: `KICKED`, `BANNED`, `CLOSED`, `LOCKED`, `FULL`, `BOTS`...). Doesn't reconnect |
| `WrongPassword` | wrong password |
| `IdentityMismatch` | the server didn't prove it's the invite's (different fingerprint) |
| `ConnectError` | couldn't connect (the reason is in the message) |
| `BadInvite` | an invite with no usable address |
| `CommandError` | inside a command: replies the text to whoever called it |

## Constants

- `Reaction`: `LIKE`, `LOVE`, `HAHA`, `FIRE`, `WOW`, `SAD` (the six reactions in the app, in that order).
- `Notice`: `MUTED`, `UNMUTED`, `ADMIN_ON`, `ADMIN_OFF`, `CHANNEL`, `MOVED`, `DM`, `FILE_GONE`...
- `Deny`: the refusal reasons (above).

The protocol underneath is in [Protocol](PROTOCOL.md).
