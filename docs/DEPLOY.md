# Dedicated server

<sub>[🇺🇸 English](DEPLOY.md) · [🇧🇷 Português](DEPLOY.pt.md)</sub>

By default whoever creates the room is the server (and needs a tunnel or an
open port). If you have a VPS or a PC with an open port, you can keep a room
always up with `telinha-server`: a static ~400 KB binary with no dependencies.

Everyone joins with **Join a room** → `vps-ip:7777` + password.

## Running it directly

```sh
zig build server            # produces zig-out/bin/telinha-server-{x86_64,aarch64}
./telinha-server-x86_64 --porta 7777 --senha "a good password" --nome "The gang's room" --admin "secret-token"
```

Or through the `TELINHA_PORTA`, `TELINHA_SENHA`, `TELINHA_NOME`, `TELINHA_ADMIN`
variables.

`--admin` is a token: whoever joins with it (in the app: *Join a room* →
*Advanced options* → admin token, or `--admin TOKEN` on the command line) gets
the crown and can kick people (right-click the member).

## Docker

```sh
docker build -t telinha-server .
docker run -d --name telinha -p 7777:7777/tcp -p 7777:7777/udp \
  -e TELINHA_SENHA="a good password" -e TELINHA_NOME="The gang's room" -e TELINHA_ADMIN="secret-token" \
  --restart unless-stopped telinha-server
```

Or with `docker compose up -d` using [`docker-compose.yml`](../docker-compose.yml).
The final image is `FROM scratch` (just the binary). It works on amd64 and arm64.

## systemd

`/etc/systemd/system/telinha.service`:

```ini
[Unit]
Description=telinha - room server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/telinha-server --porta 7777 --nome "The gang's room"
Environment=TELINHA_SENHA=a-good-password
Environment=TELINHA_ADMIN=secret-token
# debug logs that people send "to the room owner" are also kept here
Environment=TELINHA_LOGS=/var/lib/telinha/logs
StateDirectory=telinha
DynamicUser=yes
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
```

```sh
sudo install -m755 zig-out/bin/telinha-server-x86_64 /usr/local/bin/telinha-server
sudo systemctl enable --now telinha
journalctl -u telinha -f
```

## Debug logs from players

In the app, *Settings → Debugging → To the room owner* sends the log through the
room itself. It reaches everyone who joined with the admin token (it lands in
their `logs-recebidos` folder, next to the config). With `--logs DIR` (or
`TELINHA_LOGS`), the dedicated server also keeps a copy, so a log sent while no
admin is around isn't lost. Each person can send one log per minute, up to 8 MB.

## Channels

One server can hold several rooms at once, IRC-style: each channel has its own
chat, people, voice and streams, and people hop between them without
reconnecting (the panel on the right, or `/join name` in the chat). The first
channel is the default.

```sh
telinha-server --canais "geral,games,movies"      # fixed channels; anyone can create more
telinha-server --canais "geral,games" --sem-canais-novos   # only these
```

(or `TELINHA_CANAIS`). A channel someone created disappears when it empties. An
invite can point straight at a channel: `telinha://host:7777/games#password`.

### Channel admin, calls, and what survives a restart

Each channel has its own chat; the **call** (voice and streams) is separate: people
can read one channel while staying in another's call (the headphones icon on
each channel, `/call name`, or the dock button). Whoever joined with the admin
token can right-click a channel to **pin** it, **lock** it (admins only), set a
**password** or a **topic**, and right-click a person to move them to another
channel. Pinned channels (with their password, lock and topic), bans, admin mutes
and pen removals are written to a state file (`--estado FILE` / `TELINHA_ESTADO`;
by default `estado.txt` next to the key) and come back after a restart.

## Watching in a browser

People without the app watch through a link, nothing to install. The server
serves the page and forwards the same frames it already sends to the apps (the
streamer spends nothing extra). Browsers only decode video on an **https** page,
so the web port stays on `127.0.0.1` and needs HTTPS in front:

- **No account, no domain:** `--web 7778 --web-tunel` starts a Cloudflare quick
  tunnel (`cloudflared`, [download](https://github.com/cloudflare/cloudflared/releases))
  and announces the `https://….trycloudflare.com` address in the room; in the app,
  the screen button (next to the invite) copies the link with the password. The
  address changes every time the tunnel starts — the app always gets the current one.
- **With your own domain** (Cloudflare named tunnel, Caddy, nginx...): point HTTPS
  at `http://127.0.0.1:7778` (with WebSocket) and use
  `--web 7778 --web-link https://screen.yourdomain.com`.

Under systemd, add it to the `ExecStart` options (e.g. `--web 7778 --web-tunel`)
with `cloudflared` in `/usr/local/bin`.

## Bots

[Bots](BOTS.md) (the Python SDK, the [music bot](BOTS_MUSIC.md)) join with the
room password and show up with a BOT tag; they never become admin. To decide
who gets in:

- `--sem-bots` (`TELINHA_SEM_BOTS=1`): refuses every bot.
- `--token-bots SECRET` (`TELINHA_TOKEN_BOTS`): only bots sending this token
  (`Bot(..., bot_token="SECRET")`, `--token-bots` in the music bot). People
  still join with just the password.

## Files

People in the room send files (up to 256 MB) and everyone downloads when they
want. The server keeps them on disk, encrypted with a key that only exists in its
memory (restart it and leftovers are deleted), in `--arquivos DIR` /
`TELINHA_ARQUIVOS` (by default the `arquivos` folder next to the state file; with
the systemd unit above, `/var/lib/telinha/arquivos`). They expire 2 h after being
sent, 2 GB at most in total. Without a writable folder the room has no files (chat
images still work).

## Server identity

The server keeps a fixed key (`--chave FILE` / `TELINHA_CHAVE`; by default
`servidor.key` in systemd's `StateDirectory=`,
`/var/lib/telinha/servidor.key` when running as root, otherwise
`~/.config/telinha/servidor.key`), created on the first run with mode 0600. Its
fingerprint is printed at startup and goes in invites
(`telinha://host:7777!fingerprint#password`): the app checks that it's really
this server before sending anything. Keep the key file across reinstalls — a new
key makes everyone who joined before see a "the server's identity changed"
warning.

## Server statistics

Whoever joins with the admin token (`--admin`) gets a gauge button at the top of
the room: CPU and memory of the server process, bandwidth in and out, people per
channel, UDP or TCP, what each person is receiving, their send queue, and a
plain-language guess at the bottleneck (server CPU, the server's upload, one
person's connection). The server only measures while someone has that window
open.

## Firewall and bandwidth

- Open the chosen port in **TCP and UDP** (`ufw allow 7777`). TCP carries control
  and chat; UDP, on the same port, carries video, sound and voice. It works
  without UDP, but everything goes over TCP (a lost packet holds back what comes
  behind it).
- In the cloud (Oracle, AWS, GCP...) there is also the network firewall, outside
  the machine (security list / security group): open TCP and UDP 7777 there too.
- On Oracle's Ubuntu images, iptables rejects everything before UFW; the rule
  goes before the REJECT: `sudo iptables -I INPUT <REJECT line> -p udp --dport 7777 -j ACCEPT`
  (and the same with `-p tcp`), saving it in `/etc/iptables/rules.v4`.
- The server only forwards: it barely uses CPU. **Outgoing** bandwidth is
  (sum of the streams) × (viewers of each one). A "balanced" 1080p stream runs at
  0.3–6 Mbit/s depending on what is on screen.

## No VPS: public link

If whoever creates the room is behind NAT/CGNAT, telinha itself opens a tunnel
([bore](https://github.com/ekzhang/bore) protocol, bore.pub server): in the app,
*Create public link*; on the dedicated server, `--publico`:

```sh
./telinha-server --publico
# [21:03] public link: bore.pub:41234  —  invite: telinha://bore.pub:41234#k3m9qx2a
```

Without `--senha`, a random password is created (the address is public). If the
tunnel drops, it reconnects asking for the same port, so the invite keeps
working. Another bore server (yours, for example): `--publico my.server.com` (or
`tunnel_host=` in the app's `config.ini`).

## No VPS: port opened on the router (UPnP)

With the home router allowing it (most come with UPnP on), you can have a
**direct** connection, with no tunnel in the middle: lower delay (bore.pub is on
another continent) and without its bandwidth limit. In the app, *Open port on
router*; on the dedicated server, `--upnp`:

```sh
./telinha-server --upnp
# [21:03] port opened on the router: 177.45.10.8:7777  —  invite: telinha://177.45.10.8:7777#k3m9qx2a
```

The port stays open (renewed every 25 min) while the room is open and is closed
when it closes; if the process dies without closing it, the router removes it
by itself within 1 h. If the carrier uses **CGNAT** (the router has no internet
IP of its own — common on fiber and 4G), telinha notices and warns you: then the
way is the public link. The machine's own firewall also has to let the port in.

Or an external tunnel:

| tunnel | command | note |
|---|---|---|
| bore | `bore local 7777 --to bore.pub` | free, no account |
| ngrok | `ngrok tcp 7777` | TCP requires an account with a verified card |
| serveo | `ssh -R 0:localhost:7777 serveo.net` | can be unstable |
| playit.gg | the playit app | free, made for games |
| Tailscale/ZeroTier/Radmin | VPN between the gang | use the VPN IP directly |

Traffic is end-to-end encrypted between each person and the room server, so the
tunnel doesn't see the content.
