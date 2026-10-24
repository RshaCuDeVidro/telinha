# Big-screen bot (Telão)

<sub>[🇺🇸 English](BOTS_SCREEN.md) · [🇧🇷 Português](BOTS_SCREEN.pt.md)</sub>

Plays videos **on the bot's own screen**: it goes live like anyone in the
call, and whoever wants clicks it and watches, with sound. The controls sit
in a **panel docked under the video** (pause, skip, stop, what's next) that
anyone watching can use; the same panel shows up in the chat.

It plays:

- **links**: YouTube and anything [yt-dlp](https://github.com/yt-dlp/yt-dlp)
  opens (playlists too, up to 50 videos), and direct video links (`.mp4`,
  `.mkv`, `.webm`...);
- a **search** by name: `!watch trailer` plays the first result, and `!search`
  shows five to pick with the buttons;
- **videos sent in the room**: reply to the file with `!watch`.

**It barely uses any CPU**: YouTube video already comes as H.264, the same
codec telinha uses, so the packets are passed straight through, without
decoding or encoding again. Video in another format (VP9, AV1) gets
re-encoded by ffmpeg, and that's heavy (about one core for 720p).

## Running it

You need Python 3.10+, ffmpeg (with ffprobe, which comes along) and the
repository. yt-dlp is optional: without it the bot only plays direct links
and room videos.

```sh
sudo apt install ffmpeg python3-venv        # (Arch: pacman -S ffmpeg python)
git clone https://github.com/RshaCuDeVidro/telinha
cd telinha
python3 -m venv .venv && .venv/bin/pip install ./sdk/python yt-dlp
.venv/bin/python bots/telao/telao.py "telinha://my.room:7777#password"
```

| Option | Variable | |
|---|---|---|
| `invite` | `TELINHA_CONVITE` | the room invite (from the **Invite** button) |
| `--max-height` | `TELINHA_ALTURA` | highest resolution, 144 to 1080 (default 720) |
| `--cookies` | `TELINHA_YT_COOKIES` | a YouTube cookies file, for servers YouTube blocks (below) |
| `--name` | `TELINHA_BOT_NOME` | the name in the room (default "Telão") |
| `--channel` | | channel to join (otherwise the invite's) |
| `--bot-token` | `TELINHA_TOKEN_BOTS` | if the room asks for a bot token |
| `--prefix` | | before the commands (default `!`) |

## Commands

| Command | Also | |
|---|---|---|
| `!watch name or link` | `!w`, `!play` | plays the video, or queues it |
| `!watch` replying to a video | | plays the video sent in the room |
| `!search name` | `!find` | five results, with a button for each |
| `!queue` | `!q` | what's playing and what's next |
| `!skip` | `!s`, `!next` | skips to the next one |
| `!pause` / `!resume` | | holds the picture and the sound together |
| `!stop` | | stops, clears the queue and the screen goes away |
| `!join channel` | `!come` | the bot joins that channel's call |
| `!leave` | | leaves the call |
| `!help` | `!commands` | the help card |

Portuguese aliases work too (`!assistir`, `!fila`, `!pular`...). When the
queue ends, the bot stops streaming; the next `!watch` turns it on again.

### Bringing the bot to your call

The bot only streams to people in its call. From any channel:

```text
/msg Telão !watch https://youtu.be/...
```

brings the bot to the call you're in and plays the video. In the app, the bot
shows up in the panel even while it's in another channel (under **Bots in
other channels**): right-click it → **Bring to my call**.

## Watching

Click the bot (on the stage, **Watch**, or its name) like someone streaming.
The panel stays under the video while it's alone or featured on the stage; in
full screen it goes away (the chat keeps the same card).

Viewers on app 3.6 or newer get 30 fps on any PC. Older apps without a
hardware video decoder stutter on YouTube video (it uses B-frames, which the
old software decoder couldn't take): the app updates itself.

## YouTube on a server

YouTube refuses many data-center IPs ("Sign in to confirm you're not a bot"),
and then `!watch` of a YouTube link fails. To have YouTube on a VPS, give the
bot the cookies of a logged-in browser (preferably a throwaway account),
exported in the Netscape format (the "Get cookies.txt LOCALLY" extension does
this):

```sh
telao.py "telinha://..." --cookies /etc/telinha-yt-cookies.txt
```

Direct links and the other sites keep working without it.

> [!NOTE]
> Playing video from YouTube and similar sites may go against their terms of
> service. It's optional and up to whoever runs the bot.

## Cost

- **CPU**: passing H.264 through, almost nothing (reading and sending
  packets). Re-encoding, about one core for 720p at 30 fps.
- **Internet**: the bot sends the video once to the server (1.5 to 3 Mbit/s at
  720p, depending on the video), and the server sends one copy to each viewer.
  On the same machine as the server, the bot's upload doesn't even touch the
  internet.

## Keeping it on a VPS

Same as the [music bot](BOTS_MUSIC.md#keeping-it-on-a-vps): a user just for it
and a systemd service.

```ini
# /etc/systemd/system/telinha-telao.service
[Unit]
Description=telinha: big-screen bot
After=network-online.target telinha.service
Wants=network-online.target

[Service]
User=telao
WorkingDirectory=/opt/telinha
EnvironmentFile=/etc/telinha-telao.env
ExecStart=/opt/telinha/.venv/bin/python bots/telao/telao.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/telinha-telao.env  (chmod 600: it holds the room password)
TELINHA_CONVITE=telinha://127.0.0.1:7777#password
TELINHA_TOKEN_BOTS=the-bot-token-if-any
```

## Making your own

The bot is an SDK example: the piece that streams is the
[`VideoPlayer`](BOTS_API.md#streaming-the-screen), and the panel is a
[card](BOTS_API.md#embed) with `panel=True`. For a screen that isn't a video
(a scoreboard, a quiz, a panel people click), use `Screen`: it only sends an
image when it changes.

## Troubleshooting

- **"precisa do ffmpeg" in the log** (the SDK's messages are in Portuguese):
  install ffmpeg (ffprobe comes along).
- **"YouTube refused this server"**: YouTube blocks the machine's IP; use
  `--cookies` (above).
- **Nobody sees the bot**: it streams to the call it's in. Send
  `/msg Telão !join` from your call, or use **Bring to my call**.
- **Stuttering for one person only**: their app is old (update it) or their PC
  can't keep up; the health dot on the bot's name says why.
