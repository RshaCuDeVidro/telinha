# Music bot

<sub>[🇺🇸 English](BOTS_MUSIC.md) · [🇧🇷 Português](BOTS_MUSIC.pt.md)</sub>

Plays music in the room's call. Everyone in the call hears it, and each person
sets the bot's volume just for themselves (right-click its name). It plays:

- songs from a **folder** (mp3, flac, ogg, opus, m4a, wav...), found by name;
- **files sent in the room**: reply to the file with `!tocar`;
- online **radios**, from your own list;
- direct audio **links**, if you turn them on (`--links`).

The sound goes as the bot's voice (stereo Opus, 128 kbit/s, 20 ms packets): the
streamer pays nothing for it, and people watching from a browser hear it too.

The commands are in Portuguese (with English aliases), like the rest of the
room's vocabulary.

## Running it

You need Python 3.10+, ffmpeg and the repository (or just the `bots/musica`
folder with the SDK installed):

```sh
sudo apt install ffmpeg python3-venv        # (Arch: pacman -S ffmpeg python)
git clone https://github.com/RshaCuDeVidro/telinha
cd telinha
python3 -m venv .venv && .venv/bin/pip install ./sdk/python
.venv/bin/python bots/musica/musica.py "telinha://my.room:7777#password" --pasta ~/Music
```

| Option | Variable | |
|---|---|---|
| `invite` | `TELINHA_CONVITE` | the room invite (from the **Copy invite** button) |
| `--pasta` | `TELINHA_MUSICAS` | the music folder (subfolders included) |
| `--radios` | `TELINHA_RADIOS` | the radio list file (below) |
| `--links` | `TELINHA_LINKS=1` | accept direct `http(s)://` audio links |
| `--volume` | `TELINHA_VOLUME` | starting volume, 0 to 200 (default 70) |
| `--nome` | `TELINHA_BOT_NOME` | the name in the room (default "Música") |
| `--canal` | | channel to join (otherwise the invite's) |
| `--token-bots` | `TELINHA_TOKEN_BOTS` | if the room asks for a bot token |
| `--prefixo` | | before the commands (default `!`) |

## Commands

| Command | Also | |
|---|---|---|
| `!tocar name` | `!play`, `!p` | plays (or queues) the song from the folder with that name, a radio or a link |
| `!tocar` replying to a file | | plays the audio file sent in the room |
| `!fila` | `!queue`, `!q` | what's playing and what's next |
| `!pular` | `!skip`, `!s` | skips to the next one |
| `!pausar` / `!continuar` | `!pause` / `!resume` | |
| `!parar` | `!stop` | stops and clears the queue |
| `!volume 80` | `!vol`, `!v` | volume for everyone (0 to 200); without a number, shows it |
| `!tocando` | `!np`, `!agora` | the current song and how far in it is |
| `!lista word` | `!list`, `!busca` | lists the songs in the folder (with a filter) |
| `!radios` | | the configured radios |
| `!aleatorio` | `!shuffle` | turns shuffle on/off |
| `!repetir uma` | `!repeat`, `!loop` | repeat `nada` (nothing), `uma` (the current one) or the `fila` (queue) |
| `!vem` | `!join`, `!entra` | the bot joins the call of the channel you typed in |
| `!ajuda` | `!help` | every command |

Search ignores accents and case: `!tocar cancao` finds "Canção do Mar.mp3", and
several words must all appear.

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

And in the room: `!tocar lofi`.

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

On the same machine as the server, the invite can use `127.0.0.1`.

> [!NOTE]
> **YouTube and the like are left out.** Downloading from them goes against
> their terms of service, and that's what took down the famous Discord music
> bots. A folder, room files, radios and direct links cover everyday use.

## Troubleshooting

- **"precisa do ffmpeg"** (needs ffmpeg): install ffmpeg (with libopus, which
  almost every build has).
- **"a sala recusou o bot"** (the room refused the bot): the room runs with
  `--sem-bots`, or asks for `--token-bots` and the token doesn't match.
- **Nobody hears it**: the bot plays in the call it's in. Type `!vem` in the
  call's channel, and check nobody muted the bot (an admin, or its volume in
  your right-click menu).
- **Choppy**: it's the internet of the bot's machine (it sends ~130 kbit/s). On
  a VPS this goes away.
