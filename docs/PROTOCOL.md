# Protocol (version 6)

<sub>[🇺🇸 English](PROTOCOL.md) · [🇧🇷 Português](PROTOCOL.pt.md)</sub>

Everything goes over **one TCP connection** per person, client → room server.
Integers are little-endian. `str` = `u16` length + UTF-8 bytes (the sender
truncates at 4000 bytes).

Field names in the tables below are the identifiers used in the code, which is
written in Portuguese.

Each person can stream two things at the same time: the screen and the camera.
A stream is identified by a 32-bit **stream**:

```
stream = person_id | (type << 31)           type: 0 = screen, 1 = camera
```

The person id never uses the top bit, so the screen's stream is the id itself.

## 1. Handshake (in the clear)

Both sides send, at the same time, 54 bytes:

| field | size | |
|---|---|---|
| `"TLNH"` | 4 | identifies the protocol |
| version | u16 | today `6` |
| X25519 public key | 32 | ephemeral, new for every connection |
| nonce | 16 | random |

If the versions differ, the server still sends its hello (so the client can
report "different version") and closes.

### Invite and several paths

The invite can carry several addresses for the same room, separated by commas,
with the password after the first `#`:

```
telinha://192.168.0.10:7777,203.0.113.7:7777,[2804:14c::1]:7777,bore.pub:41234#password
```

Each address is `host:port`; IPv6 goes **in brackets** (without brackets it is
ambiguous and the address is ignored). Up to 8 addresses; the order is the
preference. The host builds the invite with the local network IP, the port
opened on the router (UPnP), the machine's global IPv6 addresses, the typed
tunnel (ngrok etc.) and the public link last. Whoever joined passes on the paths
they used.

Whoever joins runs a race (`connect.zig`): one attempt per address, attempt *i*
starting *i* × 250 ms after the first (the first ones in the list, the direct
ones, go ahead). Each one connects, sends the hello above and waits for the
other side's (up to 8 s). **The first one that answers a telinha hello with the
same version wins**: the others give up, and the ones that finish later are
closed. A closed port, a silent path and another service on the port (no
`"TLNH"`) fall behind by themselves. The password is only checked afterwards, on
the connection that won (next section). If nobody wins (all failed or 20 s went
by), the error shown follows this order: different version → "not a telinha
room" → connection refused → address not found (only with one address) → did not
connect.

### Key derivation

```
secret    = X25519(my_private, their_public)
password  = SHA-256("telinha-senha-v1" || room_password)
prk       = HKDF-Extract(salt = client_nonce || server_nonce, ikm = secret || password)
k_c2s     = HKDF-Expand(prk, "telinha c2s", 32)
k_s2c     = HKDF-Expand(prk, "telinha s2c", 32)
```

Wrong password → different keys → the client's first message doesn't decrypt.
The server then sends `u32 0xFFFFFFFF` in the clear (= "wrong password") and
closes. Until the encrypted `hello` arrives, every server read has a 10 s
deadline.

## 2. Messages (encrypted)

```
u32 size | ChaCha20-Poly1305( u8 type | payload ) | tag (16 bytes)
```

`size` counts the ciphertext + tag. 12-byte nonce = the direction's `u64` counter
+ 4 zeros (starts at 0, never repeats on a connection). Maximum 32 MiB.

| type | name | direction | payload |
|---|---|---|---|
| 1 | hello | C→S | `str nome`, `str token_admin`, `u64 chave_do_cliente`, `str versão_do_app`, `u8 codecs` (what it decodes, bits `1<<codec`), `u8 recursos` (`feat_*`) |
| 2 | welcome | S→C | `u32 meu_id`, `str nome_da_sala`, `u8 sou_admin`, `u64 relógio_µs`, `u64 instância`, `u8 rota`, `str versão_do_app` (the host's), `u8 udp` (1 = offers UDP), `u32 token_udp` (if 1) |
| 3 | denied | S→C | `str motivo`, `u8 código` (the server closes right after) |
| 4 | members | S→C | `u8 sala` (1 = locked), `u16 n`, n × member (below), n × `str versão_do_app` (same order) |
| 5 | chat | C→S | `str texto`, image (optional, below) |
| 5 | chat | S→C | `u32 id`, `u32 de` (0 = system), `str nome`, `str texto`, `u64 hora` (room clock, µs), `u8 flags` (1 = history), image, `u8 n`, n × (`u8 reação`, `u32 de`) |
| 6 | stream_start | C→S | `u8 tipo`, `u16 w`, `u16 h`, `u8 fps`, `u8 flags` (1 = with audio; screen only) |
| 7 | stream_stop | C→S | `u8 tipo` |
| 8 | frame | C→S | frame (below) |
| 8 | frame | S→C | `u32 stream`, frame |
| 9 | watch | C→S | `u32 stream`, `u8 ligado`, `u8 opções` (1 = clips: wants an IDR now and then) |
| 10 | keyreq | S→C | `u8 tipo` (send an IDR for that stream) |
| 10 | keyreq | C→S | `u32 stream`, `u8 motivo` (0 = I lost the reference, 1 = recording starting) |
| 11 | ping | C→S | `u64 t` |
| 12 | pong | S→C | `u64 t` (echo), `u64 relógio_µs` |
| 13 | kick | C→S | `u32 alvo` (the same as `admin` with action 1; still accepted) |
| 14 | audio | C→S | audio (below) |
| 14 | audio | S→C | `u32 stream` (always the screen's), audio |
| 15 | ack | S→C | `u8 tipo`, `u32 seq` (the server received that frame of yours) |
| 15 | ack | C→S | `u32 stream`, `u32 seq` (I received that frame of `stream`) |
| 16 | viewer_slow | S→C | `u8 tipo`, `u8 piso` (the viewer can't keep up: lower the rate, down to `piso`% of the target) |
| 17 | voice | C→S | `u32 seq`, Opus packet (voice: 48 kHz mono, 20 ms) |
| 17 | voice | S→C | `u32 de`, `u32 seq`, Opus packet |
| 18 | voice_state | C→S | `u8 flags` (1 = microphone on, 2 = deafened) |
| 19 | admin | C→S | `u8 ação`, `u32 alvo`, `u8 valor` (admin only, see §3) |
| 20 | notice | S→C | `u8 tipo`, `str texto`, `u8 extra`: something an admin did to you |
| 21 | pointer | C→S | `u32 stream`, `u16 x`, `u16 y`, `u8 flags` |
| 21 | pointer | S→C | `u32 de`, `u32 stream`, `u16 x`, `u16 y`, `u8 flags` |
| 22 | react | C→S | `u32 id_da_mensagem`, `u8 reação` (0–5), `u8 ligado` |
| 22 | react | S→C | `u32 id_da_mensagem`, `u32 de`, `u8 reação`, `u8 ligado` |
| 23 | codec | S→C | `u8 tipo` (screen/camera), `u8 codecs`: what everyone watching that stream decodes; `u8 recursos`: what everyone watching understands |
| 24 | draw | C→S / S→C | drawing on top of the stream (see `proto.zig`) |
| 25 | cursor | C→S | `u8 tipo`, `u16 x`, `u16 y` (`0xFFFF` = hidden): the streamer's cursor, outside the video |
| 25 | cursor | S→C | `u32 stream`, `u16 x`, `u16 y` |
| 26 | view_size | C→S | `u32 stream`, `u16 altura` at which that stream appears (`0xFFFF` = wants everything: fullscreen, recording) |
| 26 | view_size | S→C | `u8 tipo`, `u16 altura`: the largest among those watching (`0xFFFF` = no limit) |

`versão_do_app` ("3.0.0") only serves to warn whoever is out of date (the
interface shows "so-and-so is on telinha X: there is a new version"); empty = not
informed. It is also a field at the end, read with an empty default.

Some fields at the end are read with a default value (0, or "screen") if
missing: `chave_do_cliente`, `flags` of stream_start, `tipo` of stream_stop,
`opções` of watch, `motivo` of keyreq and `valor` of admin on the server;
`código` of denied, `tipo` of keyreq and `extra` of notice on the client. It's
only tolerance: a different version is already refused in the handshake.

**hello:** `chave_do_cliente` is a random number drawn once and kept in the app's
settings (never 0); it is used for banning. The right `token_admin` = room owner.

**welcome:** `sou_admin` = 1 for the owner. `instância` is drawn when the server
starts (if it changed, the server restarted and the chat ids started over).
`rota` = how you got in:

| rota | |
|---|---|
| 0 | unknown |
| 1 | on this machine (loopback, or connected to its own IP) |
| 2 | local network: 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10 (CGNAT, Tailscale), fe80::/10, fc00::/7 |
| 3 | internet, IPv4 (port opened on the router, dedicated server) |
| 4 | internet, IPv6 |
| 5 | public link (connection delivered by the embedded tunnel) |

**denied:** `código` 0 = generic, 1 = kicked, 2 = banned, 3 = the owner closed
the room, 4 = the public link you came in through was turned off, 5 = room
locked, 6 = room full. With any of them the client doesn't try to reconnect.

**Image in the chat:** `u8 tipo` — 0 = none; 1 = `u16 w`, `u16 h`, `u32 tamanho`,
bytes; 2 = it was an image, but the server no longer keeps it (history). The
bytes are **one H.264 frame (IDR)**: the sender reads the file/clipboard on its
own PC, shrinks it to at most 1600 px and encodes it with openh264; the receiver
decodes it with the same video decoder and checks that the size matches. That way
no PNG/JPEG reader is exposed to what comes from the network. Limits: side
between 16 and 1920 px, up to 1.5 MB, one image every 1.5 s per person (a burst
is ignored); outside that the message is invalid and the server drops the
connection. History keeps up to 24 MB of images; the oldest become type 2.

**Reactions:** 0 like, 1 love, 2 haha, 3 fire, 4 wow, 5 sad. One per person and
per type on each message (turning it on again changes nothing); only on messages
that are still in the history, and not on system notices. In the history, the
chat message already comes with the reactions; after that they arrive one by
one.

**Member:** `u32 id`, `str nome`, `u8 flags`, `u8 rota` (bit `0x80` = owner; the
low 7 = route, table above), `u16 w`, `u16 h`, `u8 fps` (screen), `u16 w`,
`u16 h`, `u8 fps` (camera), `u16 k`, k × `u32` (streams that person watches, at
most 64). A stream that is off goes with size and fps 0. Flags: 1 = streaming
the screen, 2 = admin, 4 = screen with audio, 8 = microphone on, 16 = deafened,
32 = muted by an admin, 64 = camera on.

**Frame** (21-byte header):

| field | size | |
|---|---|---|
| seq | u32 | per stream; goes back to 0 when it restarts |
| flags | u8 | 1 = IDR, 2 = skippable, bits 2–3 = codec (0 H.264, 1 HEVC, 2 AV1), `0x10` = cursor outside the video, `0x80` = camera |
| hora_da_captura | u64 | room clock, µs |
| w, h | u16, u16 | |
| cursor_x, cursor_y | u16, u16 | the streamer's cursor tip, relative to the frame (0..65534); `0xFFFF` = no cursor |

and the Annex B bitstream (H.264 or HEVC, see flags) until the end. Every IDR
carries SPS/PPS (and VPS for HEVC as well). The server figures out the stream
from the camera bit. "Skippable" = nobody uses that frame as reference (all
slices with `nal_ref_idc = 0`; the streamer encodes with two temporal layers, one
frame yes, one no): the server may stop sending it to whoever can't keep up
without breaking the decoding of the following ones. Whoever doesn't know the bit
ignores it. A frame resent with the screen still carries the resend time (it is
the current state of the screen).

**Codec:** everyone decodes H.264 (openh264 in software, if needed); HEVC only
those with a GPU decoder (today NVDEC). In `hello` each one says what it
decodes; the server sends the streamer, on every change in who is watching, the
intersection (`codec`), and the streamer picks the best its encoder can do — HEVC
if it can, otherwise H.264. Someone with only H.264 joined: the stream goes back
to H.264 right away (new encoder, starting on an IDR); those already watching
switch decoders when they see the codec change in the flags.

**Features** (`hello` and `codec`, one byte at the end; an old app or server
doesn't send it and it counts as 0, everything as before):

- `feat_cursor` (1): viewers draw the arrow. If everyone watching understands
  it, the streamer stops painting the cursor into the video, marks the frames
  with the `0x10` flag and sends the position in the `cursor` message (up to
  ~120 per second; the server cuts above 130). Moving the mouse over a still
  screen generates no frame. Someone who doesn't understand joined: the cursor
  goes back into the video right away. Recording your own screen too (the
  recording carries the cursor).
- `feat_view_size` (2): viewers say at what height they show each stream
  (`view_size`, in steps: 360, 480, 540, 720, 900, 1080, 1440, 2160; it goes up
  instantly, and only down after 3 s smaller). The server sends the streamer the
  largest among those watching (whoever doesn't understand counts as
  "everything"), and it uses that as the maximum height — together with the
  chosen one and automatic quality, the smallest wins.

**Audio:** `u32 seq`, `u64 hora_da_captura`, Opus packet until the end (48 kHz,
stereo, 10 ms per packet, ~96 kbit/s). Only the screen has audio.

**Pointer** ("look here"): `x`, `y` relative to the frame (0..65534), `0xFFFF` =
hides it; flags 1 = visible, 2 = click (ring calling attention).

**admin** — actions:

| action | | value |
|---|---|---|
| 1 | kick | — |
| 2 | ban (kicks and doesn't let back in while the room exists) | — |
| 3 | mute the microphone | 1 = mutes, 0 = releases |
| 4 | stop a stream | type (0 = screen, 1 = camera) |
| 5 | give/remove admin (owner only) | 1 = gives, 0 = removes |
| 6 | lock the room (target ignored) | 1 = locks, 0 = unlocks |

**notice** — types: 1 = microphone muted, 2 = microphone released, 3 = stream
stopped (`extra` = its type), 4 = became admin, 5 = is no longer admin. The
`texto` already comes ready ("Ana muted your microphone.").

## 2b. Video, sound and voice over UDP

If the server has the UDP port (the same as TCP) and the connection didn't come
through the public link, `welcome` offers UDP with a token. The client sends
`hello` over UDP to the same address and port (every 250 ms, then every 3 s)
until it receives `hello_ok`; from then on **frames, audio and voice** go over
UDP in both directions — everything else (and whatever doesn't fit) stays on
TCP. With no reply, or 5–6 s with nothing arriving, it goes back to TCP by
itself; the `hello` keeps trying.

Datagram:

| field | size | |
|---|---|---|
| mark | u8 | `0xA7` |
| token | u32 | which connection it is (the server finds the connection by it) |
| number | u64 | per direction, never repeats; it is the nonce |
| ciphertext | rest | ChaCha20-Poly1305 of `u8 type` + body; the header goes in as associated data |

Key for each direction = SHA-256("telinha udp v1" ‖ TCP key in that direction). A
packet that doesn't decrypt, repeats, or is more than 128 numbers behind the
highest already seen is ignored. The server starts replying to the address the
last decrypted packet came from (NAT that changes port).

| type | body |
|---|---|
| 1 hello / 2 hello_ok | — |
| 3 ping / 4 pong | `u64 t` (echo): keeps the NAT open, measures the RTT |
| 5 data | `u32 canal`, `u32 id`, `u16 pedaço`, `u16 total`, bytes (up to 1150) |
| 6 nack | `u32 canal`, `u32 id`, `u16 n`, n × `u16 pedaço` (`n = 0xFFFF` = the whole message) |

A message (`u8 type` + payload, same as TCP) goes in 1150-byte pieces.
**Channel:** frames go in order per stream (channel = stream; from client to
server, `0x80000000` screen / `0x80000001` camera), with ids 1, 2, 3... per
channel; sound and voice use channel `0xFFFFFFFF`, without order (each has its
own sequence and buffer). The receiver reassembles; a missing piece (out of order
for more than ~RTT/4) becomes a NACK, repeated every ~1.25 × RTT; a message of
which nothing arrived is discovered by the next one (a hole in the ids) and
requested whole. The sender keeps what it sent for 1.5 s to resend. It gives up
on a message when the pieces stop arriving for `4 × RTT` (150–400 ms) or after
1 s: the following frames are delivered and the decoder asks for an IDR
(`keyreq`) if needed. Sending is paced (a burst of up to 128 KB, then at most 4×
the average rate), so a big IDR doesn't overflow the router's buffer.

## 3. Server rules

### Entry

- Name without leading/trailing spaces, up to 32 bytes; empty becomes `anônimo`.
  Repeated names get a suffix: `Ana (2)`.
- Whoever isn't the owner is refused (`denied`) if banned (2), if the room is
  locked (5) or full (6; 32 people by default). The owner goes over all of that.
- Right after `welcome`, whoever joins receives the last **50** chat messages
  (with the history flag: no sound or notification); then everyone receives
  "So-and-so joined the room" and the new `members`.

### Streams

- Frames only go to whoever sent `watch` for the stream. You can only watch
  someone who exists and not yourself, up to 2 × the people limit in streams.
  `watch` turned on again for the same stream only changes the options.
- Whoever starts watching (or when the streamer changes resolution with a new
  `stream_start`) only receives from an IDR on; the server sends `keyreq` to the
  streamer (at most one every 500 ms per stream, except for whoever just started
  watching).
- A frame of a stream that isn't on (the admin stopped it and old frames are
  still arriving) is discarded.
- `keyreq` with reason "recording" only asks for the IDR (respecting the 500 ms),
  without touching that viewer's delay control.
- **Clips:** viewers with the clips option keep the last 30 s, and a clip can only
  start on an IDR. Every 250 ms the server checks: if that stream's last IDR is
  older than 20 s and none was requested in that time, it asks for one.
- `ack`, `viewer_slow`, `voice` and `pointer` jump the send queue (they don't wait
  behind frames), keeping their order relative to each other.
- Voice goes to everyone in the room, except the speaker and those deafened; the
  voice of whoever was muted by an admin is thrown away. It is only discarded if
  the recipient's queue passes 6 MiB.
- Audio goes to whoever watches the streamer's screen, without waiting for an
  IDR; it is only discarded if the viewer's queue passes 6 MiB.
- Pointer: only accepted from whoever streams that stream or watches it, at most
  40 per second per person (the rest is thrown away); it goes to the stream's
  owner and to everyone watching, except the sender.

### Chat

Text without leading/trailing spaces; empty is ignored. Every message — including
the system ones (`de` = 0: joined, left, started streaming, turned the camera on,
kicked, locked...) — gets a growing `id` (starts at 1 for each server instance)
and the time on the room clock, and enters a ring with the last 50. The client
ignores a history message with an `id` it has already seen and converts the time
to the local clock.

### Admin

- Only admins; a request from someone who isn't is silently ignored.
- Lock/unlock: any admin. It goes to everyone's chat and `members` comes out with
  the room state.
- The rest needs a target that exists, that isn't you or the owner. A promoted
  admin (not the owner) can't touch another admin. Giving/removing admin is the
  owner's alone.
- Kick/ban: everyone's chat finds out; the target receives `denied` (1 or 2,
  "So-and-so kicked you out of the room.") and leaves. The ban keeps the
  `chave_do_cliente`, the name without the ` (n)` suffix (compared
  case-insensitively) and the IP — the latter doesn't apply to whoever came
  through the public link (everyone there has the tunnel's IP) nor to whoever is
  on the same machine. Hitting any of the three already blocks entry.
- Mute, stop stream and give/remove admin send a `notice` to the target and a new
  `members` to the room; stopping a stream works as if the target had sent
  `stream_stop`.

### Leaving

- Whoever leaves: everyone stops receiving their two streams, receives
  "So-and-so left the room" and the new `members`.
- The server never drops someone without the reason arriving: it sends `denied`,
  waits for their queue to empty (up to 600 ms), closes only the sending side of
  the socket and waits for the client to close (up to 600 ms) before dropping it
  for good.
- Room closing: everyone receives `denied` 3 ("The owner closed the room.").
- Public link turned off: whoever came in through it receives `denied` 4 and
  leaves; the rest carries on.

## 4. End-to-end delay control

Tunnels (ngrok, bore...) have huge buffers: the sender's TCP never feels the
congestion, and looking only at your own queue doesn't help. That is why
everything is measured with acknowledgements — separately for each stream
(someone's screen and camera have independent controls):

- The server sends `ack tipo seq` to the streamer as soon as it receives each
  frame. The streamer keeps the time it queued each frame and computes
  `accumulated delay = age of the oldest unacknowledged frame − reference RTT`
  (the reference RTT is the lowest ack delay in 10 s windows, not counting IDRs —
  their delay includes the transfer — and capped at 400 ms).
- Each viewer sends `ack stream seq` as soon as it receives a frame (before
  decoding). The server does the same math per viewer and per stream.

**Streamer** (`ratectl.zig`), before each frame:
- delay > 100 ms: rate −7% (at most every 500 ms), without skipping a frame;
- delay > 250 ms: skip the frame; if it persists for 300 ms (or comes back in
  less than 1 s), rate −25%. Delay explained by a recent IDR (slack = the time it
  took, decreasing over 4 s) only causes a frame skip, doesn't lower the rate;
- delay < 60 ms and 2 s without trouble: climb 12% up to 90% of the "ceiling" (the
  rate at which there was trouble last time); above that, after 15 s without
  trouble, only +2%/s. After 30 s without trouble the ceiling is forgotten.
- `viewer_slow tipo piso`: −20% (at most every 2 s), not below `piso`% of the
  target; the rate doesn't climb for 12 s.

**Server**, on every frame, for every viewer:
- delay > 500 ms (+ IDR slack) or more than 3 MiB in the queue: discard the frames
  that haven't gone out yet, wait for the ones already out to be acknowledged (the
  IDR can't stay behind them) and restart from an IDR. Whoever lags again in less
  than 10 s waits longer for the next IDR (0.5 → 1 → 2 → 4 → 8 s), so the room
  doesn't fill up with IDRs;
- delayed > 150 ms and not draining (didn't fall 50 ms in 1 s): `viewer_slow` to
  the streamer before reaching the restart point;
- the `viewer_slow` floor is 10% if more than half the viewers are struggling (a
  common bottleneck, e.g. the upload of whoever hosts the room, or there is only
  one viewer) and 50% if it's the minority — whoever can't even with half keeps
  restarting from an IDR now and then, without ruining the others' quality;
- **thinning** (if the stream has skippable frames): whoever lags as the minority
  starts receiving only the reference frames — half the frames, ~half the
  bandwidth —, and the skippable ones still in their queue are discarded right
  away. It stays like that for 10 s (double, up to 1 min, if needed again in less
  than 30 s); when it goes back to receiving everything and lags in the next 3 s,
  it thins again right away. A thinned viewer only counts as "struggling" for
  `viewer_slow` if it can't keep up even then (lagging 3 s after thinning, or
  restarting from an IDR). Whoever asks for an IDR because the decoder couldn't
  keep up is always thinned (half the work for the decoder).

**Viewer:** acknowledges right away; if the decoder falls more than 150 ms behind,
it throws the queue away and sends `keyreq stream` with reason 0 (the server
applies the same growing wait). Frames that already have a newer one waiting are
decoded but don't go to the screen.

The IDR request for a viewer waiting normally goes out when the streamer's next
frame arrives; with their screen still (nothing arriving for 1 s and no request in
the last 2 s), the server asks by itself — checks every 250 ms —, otherwise the
viewer would be stuck on the old picture.

On Linux the sockets use `TCP_NOTSENT_LOWAT` = 32 KB: the kernel holds little
not-yet-sent data and the rest waits in the app's queue, where it can be
discarded.

## 5. Clock and latency

The server has a clock (µs since it started). The client estimates the offset with
the pings (`offset = server_clock + RTT/2 − now`, weighting measurements with a
lower RTT). The streamer marks each frame with the capture time on that clock;
viewers compute `delay = now_in_room − hora_da_captura` when the frame goes to the
GPU. Chat message times also come from that clock.
