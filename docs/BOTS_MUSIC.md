# Music bot

<sub>[🇺🇸 English](BOTS_MUSIC.md) · [🇧🇷 Português](BOTS_MUSIC.pt.md)</sub>

Plays music in the room's call. Everyone in the call hears it, and each person
sets the bot's volume just for themselves (right-click its name). It plays:

- **links**: YouTube, SoundCloud, Bandcamp and anything else
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) opens (playlists too, up to 50
  songs). Spotify, Deezer, Apple Music and Tidal song links become a search by
  the song's name;
- a **search** by name: `!play popular monster` plays the first result, and
  `!search` shows five to pick with the buttons;
- songs from a **folder** (mp3, flac, ogg, opus, m4a, wav...), found by name;
- **files sent in the room**: reply to the file with `!play`;
- online **radios**, from your own list.

It answers with **cards**: the "now playing" card has the cover, a progress bar
that moves by itself and buttons (pause, skip, stop, shuffle, loop) that anyone
in the room can click. The card changes in place when something changes,
instead of filling the chat.

The sound goes as the bot's voice (stereo Opus, 128 kbit/s, 20 ms packets): the
streamer pays nothing for it, and people watching from a browser hear it too.

## Running it

You need Python 3.10+, ffmpeg and the repository (or just the `bots/musica`
folder with the SDK installed). yt-dlp is optional: without it the bot only
plays the folder, room files, radios and direct audio links.

```sh
sudo apt install ffmpeg python3-venv        # (Arch: pacman -S ffmpeg python)
git clone https://github.com/RshaCuDeVidro/telinha
cd telinha
python3 -m venv .venv && .venv/bin/pip install ./sdk/python yt-dlp
.venv/bin/python bots/musica/musica.py "telinha://my.room:7777#password" --folder ~/Music
```

| Option | Variable | |
|---|---|---|
| `invite` | `TELINHA_CONVITE` | the room invite (from the **Copy invite** button) |
| `--folder` | `TELINHA_MUSICAS` | the music folder (subfolders included) |
| `--radios` | `TELINHA_RADIOS` | the radio list file (below) |
| `--search` | `TELINHA_BUSCA` | where to search, in order (default `youtube,soundcloud`) |
| `--cookies` | `TELINHA_YT_COOKIES` | a YouTube cookies file, for servers YouTube blocks (below) |
| `--volume` | `TELINHA_VOLUME` | starting volume, 0 to 200 (default 70) |
| `--name` | `TELINHA_BOT_NOME` | the name in the room (default "Música") |
| `--channel` | | channel to join (otherwise the invite's) |
| `--bot-token` | `TELINHA_TOKEN_BOTS` | if the room asks for a bot token |
| `--prefix` | | before the commands (default `!`) |

The Portuguese spellings of the options from 3.3 (`--pasta`, `--nome`,
`--canal`, `--token-bots`, `--prefixo`) still work.

## Commands

| Command | Also | |
|---|---|---|
| `!play name or link` | `!p` | plays it, or queues it if something is playing |
| `!play` replying to a file | | plays the audio file sent in the room |
| `!play` | | resumes, when paused |
| `!search name` | `!find` | five results, with a button for each |
| `!queue` | `!q` | what's playing and what's next |
| `!skip` | `!s`, `!next` | skips to the next one |
| `!pause` / `!resume` | | |
| `!stop` | | stops and clears the queue |
| `!volume 80` | `!vol`, `!v` | volume for everyone (0 to 200); without a number, shows it |
| `!np` | `!now` | posts the "now playing" card again, at the bottom of the chat |
| `!loop one` | `!repeat` | `off`, `one` (the current song) or `all` (the queue); alone, cycles through them |
| `!shuffle` | | turns shuffle on/off |
| `!remove 2` | `!rm` | takes song 2 out of the queue |
| `!clear` | | clears the queue (the current song keeps playing) |
| `!radios` / `!radio name` | | the radios (with buttons), or plays one |
| `!list word` | `!library` | the songs in the bot's folder (with a filter) |
| `!join channel` | `!come` | the bot joins that channel's call |
| `!leave` | | leaves the call (and stops) |
| `!help` | `!commands` | the help card |

The 3.3 Portuguese commands work as aliases (`!tocar`, `!fila`, `!pular`,
`!parar`, `!vem`...).

Folder search ignores accents and case: `!play cancao` finds
"Canção do Mar.mp3", and several words must all appear. The order is: a radio
with that name, then the folder, then the internet.

### Bringing the bot to any channel

`!join` with no name brings the bot to the call **of whoever asked**. Since a
command typed in a channel only reaches the bot if it's in that channel, from
anywhere else send it in private:

```text
/msg Música !join
```

Private messages reach the bot from any channel, and it comes to the call
you're in (or to your channel, if you're not in a call). `!join games` also
works from wherever the bot is.

## Radios

A file with `name = address` per line:

```ini
# radios.txt
lofi = https://example.com/lofi.mp3
jazz = https://example.com/jazz.aac
```

```sh
python3 bots/musica/musica.py "telinha://..." --radios radios.txt
```

And in the room: `!radio lofi`, or `!radios` and a button. The repository has
an example with SomaFM stations, `bots/musica/radios-somafm.txt`.

## YouTube on a server

YouTube refuses many data-center IPs ("Sign in to confirm you're not a bot").
When that happens the bot remembers it for 30 minutes and plays the same song
from **SoundCloud** (by name), so `!play` keeps working; the card's footer
says where the sound came from.

To have YouTube itself on a VPS, give the bot the cookies of a logged-in
browser (preferably a throwaway account), exported in the Netscape format
(the "Get cookies.txt LOCALLY" extension does this):

```sh
musica.py "telinha://..." --cookies /etc/telinha-yt-cookies.txt
```

> [!NOTE]
> Playing from YouTube and similar sites may go against their terms of
> service. It's optional and up to whoever runs the bot: without yt-dlp, the
> bot sticks to the folder, room files, radios and direct links.

## Keeping it on a VPS

Next to the [dedicated server](DEPLOY.md), with systemd. Create a user just for
it and a music folder:

```ini
# /etc/systemd/system/telinha-musica.service
[Unit]
Description=telinha: music bot
After=network-online.target telinha.service
Wants=network-online.target

[Service]
User=musica
WorkingDirectory=/opt/telinha
EnvironmentFile=/etc/telinha-musica.env
ExecStart=/opt/telinha/.venv/bin/python bots/musica/musica.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/telinha-musica.env  (chmod 600: it holds the room password)
TELINHA_CONVITE=telinha://127.0.0.1:7777#password
TELINHA_MUSICAS=/srv/music
TELINHA_TOKEN_BOTS=the-bot-token-if-any
```

```sh
sudo systemctl enable --now telinha-musica
journalctl -u telinha-musica -f
```

On the same machine as the server, the invite can use `127.0.0.1`. Update
yt-dlp now and then (`.venv/bin/pip install -U yt-dlp`): sites change and old
versions stop opening them.

## Troubleshooting

- **"precisa do ffmpeg" in the log** (the SDK's messages are in Portuguese):
  install ffmpeg (with libopus, which almost every build has).
- **"the room refused the bot"**: the room runs with `--sem-bots`, or asks for
  `--token-bots` and the token doesn't match.
- **Links don't play**: install (or update) yt-dlp in the bot's venv.
- **Nobody hears it**: the bot plays in the call it's in. Send it
  `/msg Música !join` from your call, and check nobody muted the bot (an
  admin, or its volume in your right-click menu).
- **Old app**: apps before 3.4 show the card as plain text (the song's name),
  without buttons; the commands still work.
- **Choppy**: it's the internet of the bot's machine (it sends ~130 kbit/s). On
  a VPS this goes away.
