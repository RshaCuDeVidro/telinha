# Changelog

<sub>[🇺🇸 English](CHANGELOG.md) · [🇧🇷 Português](CHANGELOG.pt.md)</sub>

## 3.6.2

Talks to 3.6, 3.5, 3.4, 3.3, 3.2 and 3.1.

### Highlights

- 🔁 **Updating no longer crashes the app**: on Linux, with the debug log on, the new version crashed right after installing itself and reopening (it happened on 3.6.0 and 3.6.1; opening it again by hand worked).

<!-- detalhes -->

### All changes

- **Updater (Linux)**: the new version removed the variable holding the old
  process from the environment (`unsetenv`), which shortened the environment
  list Zig keeps from the start of the process: the last entry became null and
  the first `std.debug.print` (the debug log) hit it. Now the value becomes
  "0" (the list keeps its size). The updater test restarts with the debug log
  on and checks that the new process stays up.

## 3.6.1

Talks to 3.6, 3.5, 3.4, 3.3, 3.2 and 3.1 (an older app doesn't show "delete channel", and on an older server a channel's creator still gets in without the password).

### Highlights

- 🔒 **A channel password applies to everyone**: whoever created the channel also types the password to get in (before, they walked straight in, and a second app window on the same PC counted as "the creator"). Only room admins get in without it.
- 🗑️ **Delete a channel**: its creator (or an admin) deletes it by right-clicking the channel, with a confirmation; whoever was in it goes back to the default channel. Once empty, it still goes away on its own in 3 days.
- 🖱️ **The arrow doesn't shimmer anymore**: the arrow on the start screen (and the streamer's, drawn over the video) is painted once with a smooth edge and placed on whole pixels. No more white tip poking out of the outline.
- 🪟 **"The portal refused the capture: CreateSession failed"** on Hyprland/Sway: when the user systemd loses `WAYLAND_DISPLAY`, telinha passes the session's variables along and tries again on its own.

<!-- detalhes -->

### All changes

- **Server**: the channel password is checked for anyone who isn't a room
  admin, the creator included (they still run it: change and remove the
  password, lock it, remove people, delete it). `hello` carries the password of
  the requested channel (the app sends the last one it used there), so
  dropping and coming back no longer throws anyone into the default channel.
  New `chan_admin` action 8 = delete channel (never the default; a pinned one,
  admins only); `srv_chan_delete` (8) feature in `welcome`.
- **SDK 0.3.1**: `Client(channel_password=...)`, and the password from
  `join_channel` and `join_call` goes along when the bot reconnects.
- **Linux capture**: if the portal's `CreateSession` fails and the user
  systemd has no `WAYLAND_DISPLAY` or `XDG_CURRENT_DESKTOP`, the app passes the
  session's variables to systemd and D-Bus (like
  `dbus-update-activation-environment --systemd`) and tries once more. FAQ
  entry on what to do if it still fails.
- **Interface**: the arrow the interface draws became an image painted from
  the distance to the outline, at the scale's size, once (and again only if
  the scale changes).

## 3.6.0

Talks to 3.5, 3.4, 3.3, 3.2 and 3.1 (an older app shows a bot's panel only in the chat and doesn't list bots from other channels). 3.5.0 never made it to auto-update (packaging got stuck): whoever is on 3.4 gets both together.

### Highlights

- 📺 **Big-screen bot (Telão)**: `!watch link or name` plays the video **on the bot's screen**, with sound, for everyone in the call to watch together. YouTube video (H.264) is passed straight through, without re-encoding: it barely uses any CPU on the bot's machine.
- 🎛️ **Bot panel under the video**: the card a bot marks as its panel sits docked under its stream, with the buttons (pause, skip, stop) working for whoever is watching.
- 🧭 **A new look, easier for newcomers**: the pwnd (neon) theme is the default for new installs; the empty stage of whoever joins a room shows the three steps (call your friends, share your screen, they click Watch); the invite became the **Invite** button in the top bar; streams got viewfinder corners and the panel headings a terminal look.
- 🤖 **Call a bot from any channel**: bots show up in the panel even while in another channel (*Bots in other channels*), and right-click → **Bring to my call** brings them over.
- 🎞️ **Video with B-frames without stutter**: the software decoder (openh264) dropped to 2 or 3 frames per second on video with B-frames (the way YouTube encodes); now it runs at 30 from the first frame.

<!-- detalhes -->

### All changes

- **Software decoder**: openh264 holds the picture on the Main and High
  profiles waiting for reordering, and we forced it out on every frame (our
  own encoders never use B-frames). With real B-frames, that scrambled the
  order. Now, if the SPS says frames come out of order
  (`max_num_reorder_frames` > 0 in the VUI) or a B slice arrives, the decoder
  keeps the right order; our own streams still have no added delay.
- **SDK 0.3**: `telinha.video` with `Screen` (a still image: one full frame
  per image, sent again to whoever starts watching) and `VideoPlayer` (a file
  or link; H.264 passes through, everything else ffmpeg re-encodes; the sound
  goes as the stream's sound, on the same clock as the picture). On `Client`:
  `start_stream`, `stop_stream`, `send_frame`, `send_stream_audio`, and the
  `keyreq` and `pointer` events (where a viewer pointed or clicked, from 0 to
  1). `Embed(panel=True)` marks the card as a panel. Reconnected in the middle
  of a stream: it goes live again.
- **Telão** (`bots/telao`): `!watch`, `!search`, `!queue`, `!skip`, `!pause`,
  `!resume`, `!stop`, `!join`, `!leave` (with Portuguese aliases); through
  yt-dlp it asks for H.264 up to the chosen height (720p by default) with the
  sound separate; a queue, a panel with what's playing and what's next, and
  the screen goes away when the queue ends. Guide under *Bots → Big-screen bot*.
- **Server**: bots go in everyone's list, whatever channel they're in (without
  the "in my channel" and "in my call" marks; older apps ignore anyone with
  neither).
- **Interface**: pwnd theme as the default for a new configuration (whoever
  already has a theme saved keeps it); three steps on the empty stage, with
  **Copy invite** and **Share screen**; **Invite** with text in the top bar;
  viewfinder corners around streams and the stage's husky; a LIVE tag and an
  accent border on the cards of whoever is live; panel section headings with
  `>`. All static: nothing extra to redraw.
- **CI**: the Telão tests run along with the SDK and music bot ones.

## 3.5.0

Talks to 3.4, 3.3, 3.2 and 3.1 (an older app shows "cleared the chat" as a notice and doesn't know invisible channels or channel owners).

### Highlights

- 🔇 **Windows: sound without telinha itself, for real**. Per-program capture had never worked on Windows (the audio library looked for the device in the wrong place): now "all sound except telinha", "just this program" and "everything except Discord" work on Windows 10 2004 and later, and the room's sound is no longer muted while you stream.
- 📱 **Watching on a phone**: on Firefox for Android (no WebCodecs) the video plays through another path; on Chrome it no longer flickers or stutters; a phone layout, with the video at full width and only the video when the phone is sideways.
- 🏠 **Channels that stay**: a channel you create stays in the list even when empty (and if the server restarts), and **whoever created it runs it**: password, lock, topic, **invisible channel** and removing someone for good.
- 🖼️ **Image preview**: pasting (Ctrl+V anywhere in the room) or dragging shows the image before sending; Enter sends, Esc cancels.
- 🟢 **Stream health**: a green/yellow/red dot on the streamer's name, with the reason (your internet, your PC, the streamer's PC or internet).
- 🧭 **Landed in the wrong channel**: if someone is live in another channel, a button takes you there and starts watching.
- 🪶 **Economy mode** for weak PCs, **room mood** (the background shifts tone with the room's energy, no constant animation), **adjustable chat panel width** and **clear the room's chat** without restarting the server.

<!-- detalhes -->

### All changes

- **Sound on Windows**: per-process capture the way Microsoft does it
  (`ActivateAudioInterfaceAsync` on `VAD\Process_Loopback`, a format we pick,
  its own thread reading the packets). miniaudio 0.11.25 tried to find the
  virtual device in the regular list and failed on every Windows. Before 10
  2004 the old way stays (captures everything and mutes the room while you
  stream), and the "Streaming without audio" notice no longer shows up when the
  sound is going.
- **Browser page**: without `VideoDecoder`, H.264 becomes fragmented MP4 (one
  piece per frame) and plays in a `<video>` through MSE, always near live;
  decoder lag is now measured by time (a phone's hardware decoder holds frames
  on purpose, and "queue over 6" kept asking for a full frame); on touch, the
  canvas no longer uses the low-latency mode that flickers on Android; 100dvh,
  controls that show on tap, a 16 px chat field (the iPhone zoomed in). The
  page also clears the chat when an admin does.
- **Channels**: one created by someone stays in the list empty for 3 days (or
  until its slot is needed) and goes into the state file; the server keeps the
  creator's app key. The creator (or a room admin) sets a password, locks it
  (and still gets in), changes the topic, makes it invisible (left out of the
  list for whoever isn't in it) and removes someone for good (by key).
  Protocol: `chan_mine`, `chan_hidden`, `chan_act_hide` and `chan_act_ban`.
- **Admin**: clear the room's chat (`admin` 8): every channel's history,
  private messages included, and the room's files; everyone in the room gets
  notice 12 and the app erases what it shows.
- **Sharing**: on Windows the sources become cards with live thumbnails
  (monitors through BitBlt, windows through PrintWindow, one at a time every
  120 ms and only with the dialog open); "just part of the screen" opens the
  crop tool as soon as the stream starts; the options scroll and the buttons
  always stay in view.
- **Stream health**: a viewer looks at the local decoder, packet loss on their
  own connection and latency; a streamer, the upload, the encoder and slow
  viewers. The reason shows next to the dot.
- **Chat**: `/msg` ignores accents and capitals; a bot's menu has "Bring to my
  call". A pasted or dragged image is prepared on a thread and waits for
  confirmation.
- **Music bot**: `!volume` no longer restarts the song (SDK 0.2.1 applies the
  gain to the samples, between two ffmpeg processes, instead of restarting
  with `-ss`: radios and links went back to the start); `!play` in private
  from someone in a call brings the bot there; the card's progress bar starts
  at zero on the next song; "Ke$ha" finds "Kesha"; when YouTube refuses and
  SoundCloud only has a remix or cover, it plays the closest one and says so
  in the footer.
- **Mouse arrow** (the home screen's and the streamer's) without the white
  sliver at the bottom.
- **Economy mode**: interface at 30 fps, no animations, no CRT effect, no room
  mood. **Room mood**: the stage's bottom color is checked every 3 s and
  changes over half a second; still the rest of the time.
- **Debug log**: on Windows, an unnamed thread shows the DLL it started in
  (video driver, Media Foundation...), to find who's using CPU; the pool
  threads have names.
- **Build**: the tools that run during the build use zig's glibc (gcc 16's
  `crt1.o` has `.sframe`, which zig 0.16 can't link).

## 3.4.0

Talks to 3.3, 3.2 and 3.1 (older apps show a card as text, without buttons).

### Highlights

- 🃏 **Bot cards**: instead of plain text, a bot answers with a card with a cover, a title, fields, a progress bar that moves by itself and up to 5 buttons anyone in the room can click. The bot changes the card in place ("now playing" becomes "paused" without flooding the chat). In the app and the browser.
- 🎵 **New music bot**: plays YouTube, SoundCloud and Bandcamp links (playlists too), Spotify, Deezer, Apple Music and Tidal links (they become a search by name), and searches by name: `!play popular monster`, or `!search` with buttons to pick. Commands in English (`!play`, `!queue`, `!skip`, `!np`...); the Portuguese ones still work.
- 📍 **The bot goes to any channel**: `/msg Música !join` from any channel brings the bot to your call, and `!join games` sends it to #games.
- 🐍 **SDK 0.2**: `Embed` with buttons that call your function, `edit()` to change a message, images and covers in `send`, and the bot knows where whoever talked to it is.

<!-- detalhes -->

### All changes

- **Cards** (protocol): the card rides at the end of `chat` (up to 8 KB; the
  server only checks size and version, whoever draws validates the rest). New
  messages: `chat_edit` (42), the author changes their own message, at most
  every 200 ms; and `embed_action` (43), the click, which goes only to the
  card's author, at most every 120 ms per person. A bot also gets where
  whoever talked to it or clicked is (channel and call), in private too. See
  docs/PROTOCOL.md.
- **In the app**: a bar in the card's color, the cover (decoded by the same
  decoder as the video, no PNG/JPEG reader exposed to the network), a title
  that becomes a link, Markdown, side-by-side fields, a progress bar that moves
  by itself (it only redraws every half second, and only with the card on
  screen) and buttons with icons. On the browser page too.
- **Music bot**: "now playing" with the cover, the bar and the Pause, Skip,
  Stop, Shuffle and Loop buttons, closed as PLAYED/STOPPED when it ends;
  `!search` with five results and a button for each; `!queue`, `!np`,
  `!remove`, `!clear`, `!radios` with buttons, `!leave`; the help card. Links
  through yt-dlp (optional), playlists up to 50 songs. When YouTube refuses the
  server ("Sign in to confirm you're not a bot"), it plays the same song from
  SoundCloud and remembers it for 30 minutes; `--cookies` to get YouTube
  itself. Folder files show their length, tags and embedded cover. Options in
  English (`--folder`, `--name`...); the old ones still work.
- **SDK**: `Embed`, `Button`, `Click` (`reply`, `whisper`), `Icon`, `Style`;
  `send(embed=, image=)`, `edit()`, `click()`, `ctx.reply_card()`; the
  `action` and `edit` events; `Message.embed`, `author_channel`,
  `author_call`; `Player.play(headers=)`; `Bot(lang="en")` for the SDK's own
  answers. Edits in a row wait for their turn by themselves (the server
  ignores them under 200 ms), and so do images in a row (1.5 s).
- The music bot's tests run in CI against the freshly built server.

## 3.3.0

Talks to 3.2 and 3.1 (the new messages are ignored by older apps and servers; private messages and files only go to those who understand them).

### Highlights

- 🌍 **Watch from a browser**: the dedicated server serves a page that plays the stream, its sound and the call's voices, with nothing to install. It only relays the same frames (nothing is re-encoded), so the streamer pays nothing extra. With `--web-tunel` the server gets an HTTPS link through a Cloudflare quick tunnel, no account; in the app, a button copies the link with the password.
- 📎 **Files in the room**: any file up to 256 MB, through the paperclip, dragging it onto the window or with `/arquivo`. It's uploaded once to the server and each person downloads it when they click, in the background, without hurting video, voice or chat.
- ↩️ **Reply quoting** a message and **private messages** (from the message's menu, the person's menu or `/msg name text`).
- 🧪 **Experimental AV1** (NVIDIA RTX 40 and newer): sharper at the same bandwidth, when everyone watching can decode it. Off by default, under Settings → Performance.
- 🤖 **Bots**: a Python SDK for making your own (commands, events, private messages, music in the call, files) and a ready-made **music bot** (a folder, room files, radios). They show up with a BOT tag and never become admin.
- 🌐 **New website**, with the whole wiki in English and Portuguese, search and a user guide: https://rshacudevidro.github.io/telinha/en/

<!-- detalhes -->

### All changes

- **Browser**: `--web PORT` serves the page (WebCodecs: video decoded on the
  GPU; sound and voice through an AudioWorklet with a short buffer; the cursor
  drawn by the page) and a WebSocket that speaks the same protocol. Whoever
  joins from a browser is a regular member (route "browser"): it acknowledges
  every frame (latency control works the same), says the size it's watching at
  and chats. The password is checked in constant time; a browser never becomes
  admin. `--web-tunel` starts the Cloudflare quick tunnel (restarting it if it
  drops) and announces the link to the room; `--web-link URL` for your own
  domain. See docs/DEPLOY.md.
- **Files**: on the server they sit on disk encrypted with ChaCha20 (the key
  only exists in memory), under a random id; only people in the channel (or
  the two in a private conversation) can download; they're gone after 2 h; 2 GB
  in total (`--arquivos`). Uploads back off when acknowledgement delay rises
  (like LEDBAT). In the app: a progress bar, a card in the chat with
  download/open/folder (executables only open the folder), downloads in the
  Downloads folder with `.parte` until finished.
- **Quoted replies**: the quoted text comes from the server's history (nobody
  can forge a quote) and the person replied to is notified like a mention.
- **Private messages**: only the two of you see them, in any channel, outside
  the history; an old app (which would show it to everyone) doesn't get them.
- **AV1**: NVENC through API 12 (H.264/HEVC stays on 11.1, which runs on older
  drivers); viewers decode with NVDEC (RTX 30 and newer) or in the browser. If
  AV1 doesn't open, the stream carries on in HEVC/H.264. Clips and recordings
  in AV1 come out as MP4 (av01).
- **Bots** (`sdk/python`, `bots/musica`): a bot labels itself in `hello`
  (`feat_bot`) and shows up with a BOT tag in the list and the chat (in the app
  and the browser); it never becomes admin, not even by sending the owner
  token. On a dedicated server, `--sem-bots` refuses them all and
  `--token-bots` requires a token just for them. The SDK speaks the native
  (encrypted) protocol, reconnects by itself, checks the server identity,
  plays sound in the call through ffmpeg (paced 20 ms stereo Opus) and
  sends/downloads files; its tests run in CI against the freshly built server.
  Guide, tutorial and reference on the website.
- **Website** (GitHub Pages): generated from the repository's `.md` files on
  every push, with search (Ctrl+K), a per-page outline, light/dark themes and
  the neon look; new docs for the user guide, troubleshooting and bots.
- The ▶ ⏸ ⏩ symbols and the like now load the color emoji font (they used to
  show up as "?").
- The temporary room-files folder created by the app is no longer left behind
  in /tmp.

## 3.2.0

Talks to 3.1 (the new messages are ignored by older apps and servers).

### Highlights

- 🔄 **Updates itself** (Windows and Linux): when a new version is out, telinha shows what changes and installs it with one click (or on its own, if you want), after checking the release signature. Older versions' notes are in the new **version history** (Settings → About), and right after updating you see what's new.
- 🌐 **More ways in from outside, no third-party service**: besides UPnP, the router port now also opens through NAT-PMP and PCP, and there's a connection guide, docs/CONNECTING.md (manual port forwarding, CGNAT, IPv6, gaming VPNs, SSH tunnels with no account).
- 💬 **Channels, IRC-style**: one server, many rooms. Each channel has its own chat, and the **call** (voice and streams) is separate, so you can read one channel while staying in another's call. Channels can have a password, a lock and a topic; pinned ones survive a restart.
- 🔐 **Verified server identity**: the invite carries the server's fingerprint and the app checks it before sending anything.
- 📝 **Markdown in the chat**: code blocks with a copy button, `code`, **bold**, *italic*, links; Shift+Enter for a new line. Color emoji.
- 🖍️ **Pen colors and widths** (highlighter too), hide other people's drawings, admins can take someone's pen away.
- 📊 **Server stats for the admin**: CPU, memory, bandwidth, who's lagging and the likely bottleneck, in plain language.
- ✨ **New home screen** with an animated showcase, and a cleaner "invite people from outside" panel that scrolls.
- 🎨 **New room layout**: a top bar with who's live, the stage in the middle, a floating control dock and a single side card with the members and the chat. Nothing overlaps, even in a small window.
- 🖥️ **Fullscreen button** on each stream; controls and cursor hide when the mouse stops.
- 🪟 **Windows**: Intel/AMD streams straight from the GPU (D3D11 video processor → Media Foundation), alt-tab no longer stops the stream, minimized windows show up in the list, and sound capture is sturdier.
- 🎙️ **Quiet microphones get louder** (automatic gain) and there's a mic volume slider.
- 🛡️ **Rooms hold up** against someone joining and leaving over and over.
- 📜 **Debug log straight to the room owner**, and much more detail in it.

<!-- detalhes -->

### All changes

- **Auto-update**: the release ships `SHA256SUMS` signed with Ed25519
  (`SHA256SUMS.sig`, key held by CI); the app checks the signature against the
  public key built into it, downloads its platform's binary, checks the sha256
  and only then swaps its own executable (Linux: atomic rename; Windows: the
  running `.exe` becomes `.old`, deleted on the next start). "Restart now" reopens
  with the same arguments, after the old one closes (a hosted room frees its port
  first). If the folder isn't writable (installed as admin), only the
  release-page button shows. It also checks again every 6 h while open. Options:
  *Install new versions on its own*, *Skip this version*.
- **What changes, in your language**: the update dialog shows every changelog
  section between your version and the new one (the `CHANGELOG` attached to the
  release, verified by the same `SHA256SUMS`). After updating, a *What's new*
  dialog; the full history is in Settings → About (the changelogs are built into
  the app).
- **Settings from the home screen** (gear at the top right): no need to join a
  room to change the language, updates and so on.
- **NAT-PMP and PCP** (RFC 6886/6887) when the router doesn't answer UPnP: TCP and
  UDP, renewed at half the lease, given back on close; a PCP-only router is
  detected by the version error.
- **Connection guide** (`docs/CONNECTING.md`, linked in the app): IPv6, manual port
  forwarding step by step, how to spot CGNAT and ask the ISP for a public IP,
  Radmin/ZeroTier/Tailscale, SSH tunnels with no account (Pinggy) and a reverse
  tunnel to your own VPS. The Pinggy command is in the app's own-tunnel list.
- **Text drawn at the size it was measured**: ImGui rounds the font size when
  measuring; drawing didn't. Markdown text (chat, changelog) had gaps between
  words and link underlines ran past the text.
- **The call is separate from the text channel** (like Discord): `/join` and
  clicking a channel's name change only the chat; the headphones on each
  channel, `/call name` or the dock button join/leave its call — where voice and
  streams live (your stream follows you to the new call). Joining the room puts
  you in the call of the channel you joined; out of a call, the stage invites you
  into one and sharing joins it for you. The panel lists who's in your chat and,
  below, who's in your call reading another channel. Older apps keep chat and
  call together.
- **Channel admin**: right-click a channel to pin it, lock it (admins only), set
  a password (the panel asks for it when someone tries to get in) or a topic
  (shown at the top of the chat); right-click a person to move them to another
  channel. Pinned channels with their settings, bans, admin mutes and pen
  removals are kept in a state file (`--estado`, next to the key by default) and
  come back when the server restarts.
- **Server identity**: the server has a fixed Ed25519 key and signs both halves of
  each handshake right after it (before the app sends name or admin token).
  Invites carry the fingerprint (`telinha://host!fingerprint#password`) and the
  app requires it; without one, it remembers the first identity seen at that
  address and warns (with a "Trust the new identity" button) if it changes. The
  room hosted inside the app has a fixed key too; the dedicated server uses
  `--chave` (default `/var/lib/telinha/servidor.key` or
  `~/.config/telinha/servidor.key`, mode 0600) and prints the fingerprint.
- **Markdown in the chat**: ```` ``` ```` code blocks (monospace, language label,
  copy button), `inline code`, **bold**, *italic* (slanted on the fly: the font has
  no italic) and clickable links. The message box is multi-line (Enter sends
  without losing focus, Shift+Enter adds a line, it grows up to ~7 lines, 4000
  bytes).
- **Color emoji** in names, chat and channels, using the system emoji font (Noto
  Color Emoji on Linux, Segoe UI Emoji on Windows) drawn by FreeType. The font is
  only loaded when the first emoji shows up: no memory spent if you never see
  one. Composed emoji (families, skin tones) show their basic form.
- **Right-click a message** to copy its text or reply (puts the `@name` in the box).
- **Pick the image with the system file picker** from the attach button (portal
  on Linux, the open-file dialog on Windows); paste and drag still work.
- **Pen**: a palette under the stream with 15 colors plus your own, 4 widths
  (thin, normal, thick, highlighter), a toggle to hide other people's drawings
  (just for you; also in Appearance) and an eraser for yours. Color and width ride
  in spare bits of the drawing message (older apps draw in the person's color).
  Admins can take someone's pen away (their drawings disappear right away;
  remembered by key, like mutes) and give it back.
- **Channels (IRC-style)**: a server holds several channels; each has its own
  chat (history), member list, voice, and streams (you only watch, point at or
  draw on someone in your channel). Switch from the channel list in the right
  panel, the **+** button (create or join by name), or `/join name` (`/j`,
  `/canal`) in the chat; `/canais` lists them. Switching happens on the same
  connection: your screen and camera follow you (they're announced again in the
  new channel), and whoever watched you in the old one stops. A channel nobody
  is in disappears unless it's fixed. The dedicated server takes
  `--canais "geral,games,..."` (fixed channels, first = default; also
  `TELINHA_CANAIS`) and `--sem-canais-novos` (no new ones). The home screen has
  an optional **Channel** field, and invites can carry one:
  `telinha://host:7777/games#password`. Reconnecting goes back to the channel
  you were in. Older apps keep working (they stay in the default channel); the
  new app on an older server simply shows no channels.
- **Server statistics** for whoever joined with the admin token (gauge button at
  the top): process CPU and memory, bandwidth out/in with a 2-minute graph,
  people (and how many over UDP), channels, and per person: channel, path,
  what they get and send, their send queue and whether they're lagging or
  thinned. A "bottlenecks" section explains what's wrong (server CPU, the
  server's upload, one person's connection, someone stuck on TCP...). The server
  only measures while the window is open. Works on Linux and Windows (and when
  the room runs inside the app, it says the numbers are the whole app's).
- **New home screen**: an animated showcase (a little live screen with people
  watching, reactions floating up, a chat message popping in) and a card with a
  sliding Join/Create switch, fields with icons and a focus glow, and errors in
  a box. The animation only runs while telinha is focused and someone is moving
  the mouse (it freezes after 12 s and the app goes back to sleep), and can be
  turned off in Appearance. In a short window the card scrolls.
- **The "Create room" card no longer flickers**: its measured height and its
  position were correcting each other every frame (half-pixel positions).
- **"Inviting people from outside"** (empty room of the host): public link and
  router port as two cards (stacked in a narrow window), and the whole area
  scrolls — before, in a short window, the bottom was cut off with no way to
  reach it. Opening "your own tunnel" scrolls it into view.
- **New room layout**: the old sidebar, room strip and user panel became a top
  bar (room, connection, live pills you click to watch, lock/invite/chat/settings
  on the right), the stage with the streams, a floating dock (you, mic, deafen,
  share, camera, leave) and a right card with who's in the room and the chat.
  In a narrow window the card hides (a button brings it back), the live pills
  that don't fit become "+N live", and the dock drops your name and then the
  share label. New default theme (ink blue with a violet accent). Chat reactions
  sit under the message and wrap; their counts were wrong ("#") and are fixed.
- **Fullscreen** button on the stream (besides double click / F11); with the
  mouse still for a moment, the stream's controls and the cursor hide.
- **Windows, Intel/AMD without the CPU**: the DXGI capture crops, scales and
  converts the screen to NV12 on the D3D11 video processor and Media Foundation
  encodes that texture directly; preview through the GPU too. A color self-test
  against the CPU runs on start; any failure (no video processor, self-test,
  encoder that won't take textures, lost screen) falls back to the CPU path.
  `TELINHA_SEM_D3DVP=1` turns it off.
- **Alt-tab / fullscreen games on Windows**: losing DXGI access (another app
  going exclusive fullscreen, UAC, lock screen) is retried for 30 s instead of
  ending the stream, and if a stream stops by itself the app restarts it (up to
  3 times a minute).
- **Window list on Windows** includes minimized windows ("— minimized"); picking
  one restores it without stealing focus.
- **Windows sound**: WASAPI opens without hardware offloading and retries with
  other settings (the "-2" error); if capturing a single program fails it falls
  back to all the sound with a warning; a warning when you exclude telinha's own
  sound by mistake. The audio library's own messages go to the debug log.
- **Microphone unmuting by itself**: an admin mute is remembered by the person's
  key, so leaving and coming back no longer clears it.
- **Quiet microphones**: automatic gain (up to +18 dB, measured only while
  speaking so it doesn't raise the noise, drops fast, never clips) and a mic
  volume (25–300%) in Voice settings.
- **Rooms survive join/leave storms**: a viewer that hasn't reported its size
  no longer shrinks the stream for everyone; the streamer only downscales after
  10 s; key frame requests limited to one per second; at most 6 joins per 30 s
  per person (by key, or by IP without one; not for the public link or local).
- **Memory while minimized**: the preview of your own screen is no longer
  requested nor uploaded to the GPU while the window is minimized (the AMD
  driver piled up those uploads without a buffer swap: 200 MB → 900 MB in 90 s).
- **Debug log to the room owner**: a third option (besides gofile and a
  webhook) sends the log in pieces over the room connection; the owner gets it
  in `logs-recebidos`, and a dedicated server started with `--logs DIR` (or
  `TELINHA_LOGS`) keeps it on disk. One log per minute, up to 8 MB.
- **Debug log**: per-thread CPU on Windows too (named threads), key frames
  counted by reason in the stream line, viewer size cap changes, capture timing
  every 5 s, the sound setup at start (backend, output, default mic, whether a
  single program can be captured), which Media Foundation encoder opened (and
  which refused), why the mic turned on/off and why a stream stopped.
- **Debug log on Windows**: no longer writes over the start of the previous
  runs' log (the file ended up with pieces of two sessions), and messages from
  the C code and libraries (miniaudio, encoder, capture) finally make it in: in
  a windowed program they were lost. When sound capture fails, the log gets a
  step-by-step WASAPI test (output format and each attempt's code); why the
  encoder refused the texture is logged too.
- **An invite pasted in the name field** goes to the room address (the password
  used to become your name, visible to everyone); the server also turns such a
  name into "anonymous", even from older apps. The invite picked up from the
  clipboard keeps the server fingerprint (it used to keep only address and
  password).
- **Congested network with someone asking for a key frame**: the encoder kept
  spinning (a whole core) until the network cleared; now it waits for the next
  frame.
- **Auto quality going up** said "your PC couldn't keep up"; now it says there's
  headroom. The same notice again (clicking a busy camera several times)
  refreshes the one on screen instead of stacking.
- **Server under systemd**: the identity key goes in `StateDirectory=` (with
  `DynamicUser` the identity changed on every restart).

## 3.1.0

Talks to 3.0 (the new fields are optional).

### Highlights

- 🚀 **Straight through the GPU**: streaming and watching skip the CPU on NVIDIA (Linux and Windows) and on Intel/AMD on Linux. A 1080p60 stream costs the streamer about 20% of one core.
- 📡 **Video, sound and voice over UDP**: a lost packet no longer holds up everything behind it, and voice never waits for video.
- 🎞️ **HEVC** on NVIDIA when everyone watching can decode it: less bandwidth for the same quality.
- 🖱️ **Cursor outside the video** and **streams sized to what viewers see**: less GPU and less network for everyone.
- ⌨️ **Global shortcuts**, **push-to-talk**, **clips from 5 s to 10 min**, screenshots and drawing over the stream.
- 🌐 **English interface**, new themes and your own CSS.
- 🐧 **Runs on older Linux distros**, with a one-line installer.

<!-- detalhes -->

### All changes

- **Linux binary runs on older distros**: built against glibc 2.31 (Ubuntu/Pop!_OS 20.04 and newer) with GLFW built in, so it no longer needs the distro's GLFW (3.3 on Ubuntu 22.04/24.04 was too old). X11 and Wayland are picked at runtime, as before.
- **One-line Linux installer** (`install.sh`): downloads the latest release,
  checks the SHA256, adds telinha to the app menu and opens `telinha://` invite
  links.
- Stats drop to zero when the image stops ("no new frame for N s"), instead of
  showing the last value. Crash reports carry the commit and run ID, attach only
  that run's log, and each release ships the matching debug symbols.
- **Video, sound and voice over UDP**: a lost packet no longer holds back
  everything behind it (over TCP, voice got stuck behind a video frame, and a
  loss at the end of a burst cost ~200 ms). The receiver asks back only for the
  piece that went missing; sound and voice wait for nobody. With 5% simulated
  loss in both directions, nothing was lost for good and the delay stayed
  around 50 ms. If UDP doesn't get through (public link, firewall), it stays on
  TCP by itself; the router port (UPnP) opens UDP too.
- **HEVC on the GPU** (NVIDIA): the same quality with much less bandwidth
  (+4 dB in a scrolling-text test at 2 Mbit/s). The room negotiates: it only
  goes HEVC if everyone watching can decode it; if someone who can't joins, it
  falls back to H.264 right away, with nobody losing the picture. Clips and
  recordings in HEVC too.
- **GPU decoding on Windows with any card** (Media Foundation/DXVA: Intel, AMD,
  NVIDIA), not only NVIDIA.
- **GPU on Linux with Intel/AMD** (VA-API): decoding bit-for-bit identical to
  openh264/ffmpeg; encoding with a self-test on startup (if the driver produces
  garbage, telinha notices and stays on openh264).
- **Sound from a single program**: in the share window, choose between all the
  computer's sound, only the window being shared, a program that is playing
  right now (Spotify, browser, game...) or none — and you can switch with the
  stream running.
- **Chat**: images (paste with Ctrl+V or drag the file into the window; opens
  fullscreen with one click), reactions (like, love, haha, fire, wow, sad) and
  mentions (`@name`) with Tab to complete, highlight and notification. The image travels
  as a video frame: no PNG/JPEG reader exposed to the network.
- **New version warning**: if someone in the room is on a newer version, you
  find out; and the app can ask GitHub on startup (can be turned off). The
  "different version" message now says who needs to update.
- Settings and the share window scroll on short screens (the buttons at the
  bottom no longer disappear).
- **English interface** (automatic from the system language, or chosen in the
  settings). Texts that come from the server (chat notices, refusal reasons)
  are translated too.
- **Settings in pages** (General, Appearance, Voice, Camera, Performance,
  Debugging, About), in a wider window with a sidebar.
- **New icon**: a husky peeking over the top of the screen (one blue eye and
  one brown).
- **Exclude programs from the sound**: when sharing "all sound", you can leave
  programs out (Discord, for example, so viewers don't hear their own voice
  coming back). On Windows the system only lets you exclude one process per
  capture, so telinha captures each program playing and mixes them.
- **Automatic quality**: if the PC can't keep up with the chosen frame rate,
  the stream drops the resolution one step (1080p → 900p → 720p...) and climbs
  back by itself when there is slack; the streamer is told. Can be turned off
  in Performance.
- **Test my PC** (Performance): a few seconds measuring the encoder on the CPU
  and on the GPU plus the decoder, with the suggested resolution/frame rate and
  a button to use it.
- **Crash report**: if the app goes down, it writes down the reason and the
  stack; on the next launch it asks whether to send them (gofile or webhook,
  same as the log).
- **Custom theme**: choose background, panels, accent, text, green and red (the
  rest comes from them), or **paste some CSS** and telinha reads the `:root`
  variables (`--bg-dark`, `--neon-purple`...); you can copy the theme as CSS,
  or point to a **.css file** that telinha watches (save the file, the theme
  changes; a thread checks every 1.5 s and only rebuilds the theme if the
  content changed). Fira Code in the pwnd themes, **interface size** (80% to
  150%) and an optional **CRT effect** (old-screen lines, without covering the
  video).
- **Global shortcut to save a clip** (General → Clips): a key or mouse button
  that saves a clip of the spotlighted stream with the game focused (Windows
  and X11; on Wayland, with telinha focused).
- **Screenshot of a stream** (button on the tile): PNG at full resolution, in
  the clips folder.
- A recording that ends on a still screen no longer comes out short: the last
  frame lasts until the moment you stopped (and the sound goes that far). If
  the request for a full frame to start the recording gets lost, it is asked
  for again.
- **Clip length** is choosable (15 s, 30 s, 1, 2 or 3 min). With short clips,
  viewers ask for a full frame more often, so the clip starts near the
  requested time.
- **Stream just a piece of the screen**: on your own stream's tile, the crop
  button lets you drag a rectangle over your own screen (right-click goes back
  to the whole screen).
- **Draw over the stream**: whoever is watching (or the streamer) draws on top
  of the video, everyone watching that screen sees it, and the stroke fades by
  itself after a few seconds (right-click erases yours).
- **Push to talk** (Settings → Voice): voice only goes out while the key (or
  side mouse button) is held, working with the game focused on Windows and
  X11; on Wayland, with telinha focused.
- **Voice more resistant to loss**: Opus FEC (a lost packet is recovered by the
  next one).
- **Themes** (Settings → Theme, switches instantly): Dark (the usual one),
  Light, pwnd (black with fuchsia and neon purple plus terminal green, almost
  square corners), pwnd light, Nord and Dracula. Button text picks white or
  dark by itself, by contrast.
- **Debug log** (Settings → Debugging): writes to a file everything that helps
  find a performance problem — system, processor, memory, GPUs, driver, OpenGL,
  monitors, settings (without passwords) and, every 2 s, app and computer CPU
  (on Linux, per thread), memory, frame rate and UI frame time, room
  ping/queue/UDP, and every stream being watched (fps, resolution, bandwidth,
  codec, decoder, decode time, delay) or sent (capture, encoder, encode time,
  target bitrate, congestion), plus warnings, events and the internal debug
  messages. A button sends the log: through **gofile.io** (no account; you get
  a link back to copy) or through a **webhook** (Discord etc.: the file arrives
  in the channel). It stays on between launches until you turn it off; the file
  is trimmed when it passes 24 MB.

**Performance and memory** (measured before/after in the same scenarios):

- **Stream without going through the CPU on Windows** (NVIDIA): the DXGI
  texture is cropped and scaled by a CUDA kernel and goes straight to NVENC. Any
  failure falls back to the CPU path.
- **Stream without going through the CPU on Linux with Intel/AMD** (VA-API): the
  compositor's DMA-BUF is imported as a surface, the GPU crops, scales and
  converts it to NV12, and the encoder reads it directly. A color self-test runs
  when it opens; any failure falls back to the CPU.
- **Cursor outside the video**: viewers draw the arrow themselves, so moving the
  mouse over a still screen sends no frames at all (needs everyone watching on
  3.1).
- **Stream at the size viewers see**: if everyone watches you in a small grid
  tile, no 1080p is sent. It goes back up the moment someone enlarges it, and
  goes down 3 s later. Recordings survive resolution changes.
- **Stream without going through the CPU** (Linux + NVIDIA): the frame the
  compositor hands over on the GPU (DMA-BUF) is cropped, scaled and gets the
  cursor right there, and goes to NVENC through CUDA — nothing is read back to
  RAM. Before, each 1080p frame cost a 3-5 ms read plus an 8 MB copy to the
  encoder; measured at 1080p: 4.7 ms → 0.3 ms of CPU per frame. The preview of
  your own screen comes out small, straight from the GPU. If the encoder is a
  different one (VA-API, software) or the compositor sends ordinary memory, it
  stays as before. Preparing the GPU (shader, CUDA registration, buffers) is
  done on a separate thread with a shared GL context: done on the PipeWire
  thread, it held the portal's buffers for ~80 ms, the portal gave up on
  DMA-BUF and capture died or switched paths halfway. If capture changes path
  in the middle (the GPU failed, the compositor renegotiated the format), the
  GPU frame and the CPU frame have separate signals — before, a GPU frame could
  be read as if it were in memory, and the app crashed (SIGSEGV scaling the
  frame).
- **Watch without going through the CPU** (NVIDIA, Linux and Windows): the
  NVDEC frame goes straight to the texture that appears on screen (CUDA ↔
  OpenGL), without the two 3 MB copies per frame (GPU → RAM → GPU). Watching
  1080p60 with NVIDIA costs about 3% of one core.
- **The interface no longer sits at 60 fps when idle**: the focused chat field
  counted as "activity" and kept the loop from sleeping (in the user's log the
  interface was redrawing 60 times per second the whole time).
- Nobody watching (and not recording): capture doesn't even read the
  compositor's frame (before, it read 60 times per second at 3-5 ms each, to
  throw it away).
- Named threads in the debug log (capture, encoder, decoder, net, udp,
  room-...), instead of "telinha" six times.
- **Shortcuts** (new settings page): save clip, microphone, deafen,
  start/stop stream, screenshot and one that turns all the others on and off.
  Each accepts any key, combination (Ctrl+Shift+K) or middle/side mouse button,
  and works with the game focused (Windows and X11; on Wayland only with
  telinha focused).
- **Free clip length** (5 s to 10 min), besides the 15 s to 3 min buttons.
- Ctrl+M (Ctrl+D) also set up as the microphone (deafen) shortcut: one press
  doesn't turn it on and off at the same time (the usual Ctrl+M gives way to
  the shortcut).
- In Portuguese, the "30 fps"/"60 fps" buttons come out as "30 q/s"/"60 q/s".
- New icon (a neon husky peeking over a terminal) and README in English, with
  the Portuguese version in `README.pt.md` and new screenshots.
- **Less GPU to watch**: video color conversion happens at the size it appears
  on screen (a 1080p in a small tile doesn't convert 1080p), and whatever isn't
  visible (someone else spotlighted, minimized) doesn't convert anything; if
  the tile grows with the picture still, it reconverts from the planes already
  on the GPU. Two streams in a grid: 155% → 72% CPU in the software-OpenGL test
  (on a real PC that work belongs to the GPU).
- **GPU encoder: light, balanced or quality** (Performance). The default is now
  balanced (NVENC preset P3, before P4); light uses P1 and turns off AQ, which
  runs on the CUDA cores — the same ones the game uses.
- **UI frame limit** (Performance; 60 by default): moving the mouse on a
  144 Hz monitor doesn't redraw 144 times per second.
- Stream sound jumps the send queue (before it waited behind a whole frame: a
  60 KB IDR at 2 Mbit/s held ~240 ms of sound on TCP).
- Minimized, streams no longer go up to the GPU (only the one in a floating
  window).
- Intel/AMD GPU encoders (VA-API on Linux, Media Foundation on Windows):
  conversion to NV12 is now vectorized and split across cores (it was scalar C
  on a single thread), and on VA-API it goes straight into the driver's memory,
  without the intermediate buffer. 1080p on the i5-2400S: 3.5 → 2.5 ms per
  frame (that CPU is already near the memory limit; on a newer CPU the gain is
  bigger), plus the ~3 MB copy that went away.
- Watching: decode converts the frame without stalling and the interface goes
  up to the GPU without holding decode (triple buffer), with no hiccups from
  one waiting on the other.

- Streaming with nobody watching: nothing is encoded or sent (capture drops to
  5 fps, just for the preview) — from ~312% to ~23% CPU in the test.
- Sound, voice and incoming frames no longer redraw the whole interface (only
  the already-decoded frame, and whoever starts talking); animations, warnings
  and countdowns ask for the next redraw instead of redrawing nonstop;
  minimized it doesn't draw. Watching a still screen with sound: ~47% less CPU.
- Idle room: from ~246 to ~65 wakeups/s (UDP sleeps until there is work; ping,
  UPnP and audio output wake up far less; audio output pauses after 5 s of
  silence, letting the GPU and Bluetooth headset sleep).
- The thumbnail of your own screen is only generated when it appears, at 15
  fps, and the texture is updated in place; echo cancellation doesn't run with
  the box muted; chat only builds the visible lines.
- Memory: the room you close is really freed (before it kept the history and
  the images); one shared CUDA context instead of one per stream (~37 MB less
  each); glibc returns the memory after stream/camera stops (before it grew ~15
  MB with every on/off); chat images in thumbnail (the full one only
  fullscreen) and at most 24 MB kept; the clip buffer respects the cap even
  without a new keyframe.
- Network: the writer joins what is already in the queue into a single call;
  buffers that grew because of a big message go back to normal.
- Windows: the 1 ms timer only stays on while streaming or hosting.

## 3.0.0

Protocol v6 (doesn't talk to 2.x: everyone needs to update).

**Fixes that came from real use**

- **Stream volume works**: the buttons over the video (volume, mute,
  spotlight, stop) disappeared on click because they were only drawn while the
  mouse was "over" the video — and clicking a button took the "over" away from
  the video. Now they really get the click.
- **Closing the room drops everyone right away**, including whoever joined
  through the public link, with the notice "the owner closed the room" (before,
  the tunnel connection hung around and it looked like the public link was
  fake). The server waits for the goodbye message to go out before closing the
  socket.
- **Each person shows how they got in**: local network, internet (router
  port), IPv6 or *via public link* — you can see that the tunnel is real.
- **The program dies when you close the window** (before, NVIDIA/PipeWire
  driver destructors could hold up the exit and the process stayed alive).

**New**

- **The room owner is a real admin**: kick, ban (applies to reconnecting),
  mute, stop someone's stream, give/remove admin and lock the room (nobody new
  gets in). A promoted admin can't touch another admin; nobody touches the
  owner. "Leave" for the host asks first (it closes the room for everyone).
- **Invite with several paths**: `telinha://IP:port,[IPv6]:port,bore.pub:N#password`.
  Whoever joins tries them all almost together and keeps the first one that
  answers as a telinha room — whoever has IPv6 gets in directly, whoever
  doesn't falls back to the public link by itself.
- **Invite pasted by itself**: copied a `telinha://…`, opened telinha, the
  field is already filled in.
- **Camera (webcam)** as one more stream (PipeWire on Linux, including MJPEG;
  Media Foundation on Windows). Camera choice and 480p/720p/1080p in the
  settings, switching instantly without dropping viewers.
- **Zoom on the stream**: mouse wheel zooms in, dragging moves, a *follow the
  cursor* button (the zoom goes along with the streamer's mouse) and a minimap.
  The streamer sends the cursor position with each frame.
- **"Look here" pointer**: turn on pointer mode and click on the video — a
  circle with your name appears for everyone watching that stream.
- **Clip of the last 30 s** (scissors button) and **MP4 recording**, without
  re-encoding anything: the H.264 that arrives is stored as it came (with the
  sound). Works for viewers and for your own stream. Folder: Videos/telinha.
- **Floating window** (picture-in-picture): a stream in a little window on top
  of the others, with volume; double-click goes back. On Hyprland, a window
  rule by the title `telinha · …`.
- **Chat history**: whoever joins later sees the last 50 messages (separated by
  a "messages from before you joined" line).
- **Desktop notifications** with telinha in the background: chat message,
  someone live, someone joined (Linux: desktop notification; Windows: tray
  balloon + taskbar icon blinking).
- **Windows: share just one window** (Windows.Graphics.Capture; PrintWindow as
  a fallback where it isn't available), not just the whole monitor.
- **Windows: GPU encoder on any brand** (Intel Quick Sync, AMD, NVIDIA) through
  Media Foundation when there is no NVENC; openh264 if nothing works. An
  encoder that ignores a keyframe request (some drivers) is recreated on every
  request, so whoever joins later doesn't get a black screen.

**Tests**

- **Real interface tests** (`tools/qa/run_qa.py`): the app runs on hidden
  virtual screens (Xvfb) and a robot clicks the buttons through X11 and checks
  the state the app exports (`TELINHA_QA=folder`): stream volume, closing the
  room, public link (with a fake bore), admin menu, test camera, home screen,
  room controls, UPnP (fake router), reconnection, test microphone, pasted
  invite, zoom and pointer, notifications, clips and recording (checked with
  ffprobe), floating window, invite with several paths and the `.exe` on wine
  (single window, encoder). Nothing shows up on your screen, plays on your
  speakers, opens your microphone/camera or touches your router.

## 2.1.0

- **Router port opened (UPnP)**: a direct connection for people outside,
  without a tunnel in the middle — lower delay than the public link (which goes
  through another continent) and without its bandwidth limit. Detects the
  carrier's CGNAT and warns you (then the public link is the way). On the
  dedicated server: `--upnp`. The port is renewed while the room is open,
  closed when it closes, and disappears by itself within 1 h if the app goes
  down.
- **A slow viewer no longer drags everyone's quality down**: the stream goes
  out in two temporal layers and the server starts sending only half of the
  frames (the ones the others use as reference) to whoever can't keep up —
  because of bandwidth or decoder CPU. Load test with 8 viewers + 1 on a 2
  Mbit/s link: the room's bitrate stayed at ~89% (before it fell to 50%) and
  the slow one at ~90 ms delay (before ~360 ms), at 15 fps.
- **Echo cancellation** (SpeexDSP) on voice: you can talk on speakers instead
  of a headset without the room hearing itself back. The reference is what the
  mixer just played; a delay detector finds where the echo is (up to 500 ms: a
  Bluetooth speaker works) and aligns the reference; the drift between the
  speaker's and the microphone's clocks is measured and compensated
  (resampling), which is worth about 15 dB more when they are different devices
  (e.g. USB microphone + onboard card); and leftover echo doesn't open the
  voice gate. Tested end to end in an isolated PipeWire: echo stops leaking in
  ~2 s of speech from the other side. On/off in the settings (on by default).
- A still screen no longer leaves the viewer stuck on the old picture after a
  restart: the server asks for the IDR by itself (before it waited for the
  streamer's next frame, which with a still screen never came).
- Microphone sensitivity changes instantly (before it only reopened the
  microphone in some cases and the change could be lost); warning sounds play
  even with "deafen" on (you can hear deafen turning on).
- Robustness: the server ignores `watch` from someone who doesn't exist (the
  list doesn't grow without limit), refuses entry in the middle of closing the
  room, and discards empty voice; the mixer doesn't open the audio output twice
  when two streams arrive together; PipeWire capture handles big graphs (4096
  ports).
- **Voice in the room, Discord style**: microphone with noise suppression
  (RNNoise) and voice activation, Opus 40 kbit/s. Green ring on whoever is
  talking, muted microphone and "deafen" icons in the list, microphone/deafen
  buttons in the panel, per-person voice volume (right-click), microphone
  choice and sensitivity with a meter in the settings. The microphone starts
  off (option to join with it on). Voice jumps the video queue.
- Bottom panel in the Discord style: a bar with "Share screen" and leave;
  microphone, headset and settings in the user panel.
- Chat: whatever you typed right after Enter lost the first letter (the box
  lost focus and only got it back frames later). Now it stays active and is
  cleared on the same frame as Enter.
- Ctrl+M (microphone) and Ctrl+D (deafen) shortcuts; green outline on the
  stream of whoever is talking; synthesized warning sounds (joined/left, live,
  microphone — can be turned off); each person's voice volume remembered by
  name.

- End-to-end delay control (protocol v5): every frame acknowledged on both legs
  (streamer → server → viewer). The delay stays bounded even behind tunnels
  with huge buffers (ngrok, bore...).
- New rate control (`ratectl.zig`): eases down when the delay starts to grow,
  skips a frame when it really lags, climbs fast up to near the ceiling and
  then only probes. A big IDR doesn't bring quality down.
- Viewer that can't keep up: restarts from an IDR with growing wait (the room
  doesn't fill up with IDRs) and asks the streamer for a lower bitrate — down
  to half if it's just them, as much as needed if it's the majority (e.g. the
  upload of whoever hosts the room).
- Decoder queue by time (150 ms) instead of 3 frames: a big IDR no longer
  causes a restart; late frames are decoded without going to the screen.
- Linux: `TCP_NOTSENT_LOWAT` instead of a fixed send buffer.
- `zig build loadtest`: load test with a slow link, slow majority and a bad
  tunnel.
- Wayland capture through **DMA-BUF**: the compositor copies the screen
  GPU→GPU, without reading the picture back to RAM inside its own render loop
  (that was what made the mouse stutter slightly while sharing). The read
  happens on telinha's thread, through EGL loaded at runtime; without
  EGL/support, it falls back to shared memory by itself.
- The fps limit now goes in `maxFramerate`, which is what the Hyprland portal
  uses: before it copied the screen at the monitor's rate (e.g. 144x/s) even
  when streaming at 30 fps.
- Shared memory at 24 bits and 10 bits per channel (HDR/10-bit monitor) is
  accepted and converted; before, negotiation failed in those cases.
- Clear error if the compositor agrees to share but sends no frame at all.
- `zig build captest`: capture diagnostics (method, format, real fps, cost per
  frame, saves a frame as PPM).
- **Built-in public link**: *Create public link* opens a tunnel through the
  bore protocol (bore.pub), without installing anything; the invite already
  comes out with the address. A public room always has a password (created if
  missing). Reconnects asking for the same port. Also on the dedicated server:
  `telinha-server --publico`.
- The audio option is now remembered between runs (it was saved but never
  read).
- **NVENC with much better quality** (measured with PSNR in `zig build bench`):
  High profile + CABAC + 8x8 transform, preset P4 (up to 1080p60), average
  bitrate = target (it was 75%) and IDR with VBV headroom. On a 1080p code
  screen: from ~37 to 57 dB, and the full frame that goes out when someone
  joins the room is no longer blurry (34 → 45 dB). The openh264 decoder now
  also releases the picture immediately in High profile (FlushFrame).
- `zig build bench` measures quality (PSNR) × time per encoder/preset,
  including with a real screen capture.
- **Linux: audio without echo and without muting what you're watching.**
  Capture connects each application straight into a telinha input in the
  PipeWire graph, except telinha itself (before: monitor of the output, which
  caught everything, and the app muted what you were watching while sharing
  audio). `zig build audiotest`.

## 2.0.0

Complete rewrite.

- New Discord-style interface (Dear ImGui): rooms, chat, members, several
  streams in a grid, spotlight, theater mode.
- Anyone in the room streams and watches; Linux ↔ Windows in both directions.
- H.264 video: NVIDIA NVENC/NVDEC when available, openh264 (SIMD, multithread)
  as an alternative; viewer-side color conversion in a shader.
- Automatic reconnection that resumes your stream and the streams you were
  watching.
- Computer audio together with the screen (Opus, 10 ms, volume and mute per
  stream).
- Two-thread pipeline (capture ∥ encode), adaptive bandwidth control, delay
  dropping per viewer.
- X25519 + ChaCha20-Poly1305 encryption with the room password in the key
  derivation.
- Capture: PipeWire/xdg-desktop-portal (Wayland), X11, DXGI (Windows); on
  Hyprland the cursor is drawn by telinha to keep the mouse from lagging.
- End-to-end latency measured and shown in the stats.
- Static dedicated server (`telinha-server`, Linux x86_64/aarch64), Docker,
  systemd.
- Admin with kick, `telinha://` invites, saved settings.
- Unit and integration tests, benchmark, GitHub Actions CI.

## 1.0.0

- First version: a Linux server (wlr-screencopy) and a Windows viewer, JPEG in
  tiles.
