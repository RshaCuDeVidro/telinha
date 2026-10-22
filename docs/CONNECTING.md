# How friends outside your network join your room

<sub>[🇺🇸 English](CONNECTING.md) · [🇧🇷 Português](CONNECTING.pt.md)</sub>

People in the same house (or the same VPN) join directly. The tricky part is
people far away: your internet usually doesn't let anyone outside reach your PC.
This guide collects every way, from the most direct (least delay) to the one that
works on any network. **None of them needs an API key**, and most don't even need
an account.

> Whatever the path, the conversation is end-to-end encrypted (X25519 +
> ChaCha20-Poly1305) and the invite carries the room's fingerprint: whoever is in
> the middle (a tunnel, a VPN) only sees scrambled bytes and can't impersonate the
> room.

| Path | Delay | Needs | Account? |
|---|---|---|---|
| [Local network](#1-same-network-or-same-vpn) | lowest | being on the same network | no |
| [IPv6](#2-ipv6-the-invite-already-has-it) | low | IPv6 on both ends | no |
| [Open the port automatically](#3-open-the-port-automatically-upnp-nat-pmp-pcp) | low | a router with UPnP, NAT-PMP or PCP | no |
| [Open the port by hand](#4-open-the-port-by-hand) | low | access to the router | no |
| [Public link](#5-public-link-one-click) | medium | nothing | no |
| [Gaming VPN](#6-virtual-network-vpn-radmin-zerotier-tailscale) | low/medium | the app on both ends | depends |
| [SSH tunnel](#7-ssh-tunnel-nothing-to-install) | medium | `ssh` (built into Windows 10/11) | no |
| [Your server](#8-your-own-server) | low | a VPS | — |

## 1. Same network (or same VPN)

Automatic: the invite always carries the local network addresses, and the joining
app tries all of them at once (the first to answer wins).

## 2. IPv6: the invite already has it

Many ISPs already provide IPv6, and with it **there's no NAT or CGNAT**: every
device has its own internet address. telinha puts your global IPv6 addresses in
the invite on its own; if the person joining also has IPv6, it connects directly.

- To check whether you have it: open [test-ipv6.com](https://test-ipv6.com).
- If you have IPv6 and it still doesn't connect, the router may be blocking
  inbound IPv6. Look for *IPv6 Firewall*, *IPv6 Filter* or *Allow inbound access*
  in its settings and allow the room's port (7777, TCP and UDP), or turn the block
  off.
- On Windows, the first time you create a room the firewall asks: tick **Private
  and public networks**.

## 3. Open the port automatically (UPnP, NAT-PMP, PCP)

In the *Inviting people from outside* card, **Open port on router**. The app tries
the three ways routers understand: UPnP first, then NAT-PMP and PCP (common on
OpenWrt/miniupnpd, Apple and many ISP routers). The port stays open only while the
room is open (renewed automatically and given back on close).

If it says *No router answered*, the feature is off on the router: look for
**UPnP** in its settings and turn it on (or follow step 4).

## 4. Open the port by hand

1. **Find the router's address.** Windows: `ipconfig` in the Command Prompt, the
   *Default Gateway* line. Linux: `ip route | grep default`. Usually
   `192.168.0.1` or `192.168.1.1`.
2. **Find your PC's address** on the network (same command: *IPv4 Address*, or
   `ip -4 addr` on Linux), e.g. `192.168.0.23`.
3. **Log into the router** in the browser (the address from step 1). The password
   is often on a sticker under it.
4. Look for **Port Forwarding**, *Virtual Server*, *NAT* or *Applications*. Add a
   rule:
   - external port **7777**, internal port **7777**
   - protocol **TCP and UDP** (video and voice go over UDP; TCP alone works too,
     with a little more delay)
   - destination IP: the one from step 2
5. **Pin your PC's address** on the router (*DHCP reservation*, *static IP*),
   otherwise it can change and the rule points at the wrong device.
6. Create the room and copy the invite: the app finds your outside IP and puts it
   in.

### If it still doesn't reach you: CGNAT

Many ISPs (especially fiber and 4G) put several customers behind the same IP:
that's **CGNAT**. The port opens on your router, but the internet never reaches
it. How to tell: log into the router and look at the *WAN IP* (or *Internet IP*).
If it starts with **100.64 to 100.127**, or **10.**, **172.16 to 172.31** or
**192.168.**, it's CGNAT. telinha also warns when it notices.

What to do:

- **Use IPv6** (step 2): CGNAT only exists on IPv4.
- **Ask your ISP for a public IP.** Many take you off CGNAT for free if you ask
  support (something like *"I need a public IP, off CGNAT, to reach my home network
  from outside"*). You don't need a "static IP" (usually paid): a dynamic public
  one is enough.
- Or use one of the paths below, which work even behind CGNAT.

## 5. Public link (one click)

**Create public link** in the card: the app opens a tunnel through
[bore.pub](https://github.com/ekzhang/bore) (free, no account) and the invite gets
an address that works from anywhere, CGNAT or not. Easiest, with a bit more delay
(the tunnel server is far away). If bore.pub is down, use another path.

## 6. Virtual network VPN (Radmin, ZeroTier, Tailscale)

These create a "fake local network" over the internet: everyone installs it, joins
the same network, and it's like being in the same house (step 1). They work behind
CGNAT.

- **[Radmin VPN](https://www.radmin-vpn.com/)**: free and **no sign-up**, popular
  for gaming with friends. Windows only.
- **[ZeroTier](https://www.zerotier.com/)**: Windows, Linux, phones. Whoever creates
  the network needs an account; whoever joins only needs the network ID.
- **[Tailscale](https://tailscale.com/)**: log in with Google/GitHub, very easy.

Once everyone is on the same virtual network: in *Prefer your own tunnel?*, paste
your VPN address with the port (e.g. `26.12.34.56:7777` on Radmin) and copy the
invite. Often you don't even need to: the invite already carries the addresses of
all your PC's networks.

## 7. SSH tunnel (nothing to install)

`ssh` comes with Windows 10/11 and every Linux. Some services open a free TCP
tunnel through it **without an account**. Example with
[Pinggy](https://pinggy.io) (at the time of writing: free, no sign-up, tunnels of
up to 60 minutes):

```sh
ssh -p 443 -R0:localhost:7777 tcp@a.pinggy.io
```

It shows an address like `tcp://something.a.free.pinggy.link:12345`: paste
`something.a.free.pinggy.link:12345` in *Prefer your own tunnel?* and copy the
invite. The commands are ready to copy in the app. Others that do the same:
[bore](https://github.com/ekzhang/bore) (`bore local 7777 --to bore.pub`), ngrok
(needs an account), [playit.gg](https://playit.gg) (has a guest account).

> These are third-party services and change their rules now and then. telinha's
> traffic stays encrypted inside the tunnel.

## 8. Your own server

Have a VPS (or an always-on PC with an open port)? Two options:

- **telinha dedicated server**: the room lives there, everyone joins it, nobody
  opens ports at home. See [DEPLOY.md](DEPLOY.md).
- **SSH tunnel to your VPS**: the room stays on your PC and the VPS just forwards.
  On the VPS, set `GatewayPorts clientspecified` in `/etc/ssh/sshd_config` and
  restart ssh. On your PC:

  ```sh
  ssh -N -R 0.0.0.0:7777:localhost:7777 you@your-vps
  ```

  The address for the invite is `vps-ip:7777` (open 7777 in the VPS firewall).

## Still can't connect?

- Check the room is open and the invite is the latest one (the address changes
  when the tunnel or the port changes).
- The person joining can turn on the *debug log* (Settings → Debug) and send it to
  the room owner: it shows every path tried and why it failed.
