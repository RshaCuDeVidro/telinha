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
