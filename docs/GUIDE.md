# User guide

<sub>[🇺🇸 English](GUIDE.md) · [🇧🇷 Português](GUIDE.pt.md)</sub>

Everything telinha can do, from the first invite to the settings. If you just
want to get going, the first three sections are enough.

## Create a room

Open telinha and click **Create room**. The default port is 7777 and the
password is optional. Whoever creates the room gets the crown and is its
admin.

The room lives on your computer while telinha is open. For a room that is
always on, even with your PC off, use a [dedicated server](DEPLOY.md).

## Invite people

In the *Inviting people from outside* card:

1. Click **Open port on router**. It's the direct path, with the lowest
   latency. It works on most routers (UPnP, NAT-PMP or PCP).
2. If your ISP uses CGNAT, the port won't open. Then click
   **Create public link**: the room gets an address that works on any
   network, with nothing to configure.
3. Click **Copy invite** and send it.

The invite (`telinha://…`) carries every way into the room: LAN, opened port,
IPv6 and public link. Each person joins through the fastest one that works for
them. It also carries the server's fingerprint, so the app checks it is really
talking to your room before sending anything.

Didn't work? The [connection guide](CONNECTING.md) has every other way:
manual port forwarding, IPv6, gaming VPNs, SSH tunnels.

## Join a room

Paste the invite on the home screen and click **Join**. If the invite is
already on your clipboard when you open telinha, it's pasted for you. On Linux,
when installed with `install.sh`, clicking a `telinha://` link opens the app.

You can join straight into a channel: type its name in the channel field on
the home screen.

## Go live

Click **Share screen** and choose:

| Option | What it does |
|---|---|
| **What to show** | The whole screen, a single window, or a rectangle you drag over your own preview. The webcam can go along or instead of the screen. |
| **Sound** | No sound, all computer sound (except telinha), just one program's sound, or everything except some programs (e.g. Discord). telinha's own sound never goes in, so there's no echo. |
| **Content type** | *Screen and text* keeps letters sharp (code, documents, a browser). *Game and video* favors smooth motion. |
| **Resolution, frame rate and quality** | The bitrate drops on its own if someone's internet can't keep up, and goes back up when it improves. |
| **Use the GPU** | NVIDIA, and on Windows also AMD and Intel. Without a suitable GPU, it uses the CPU. |

Click **Go live**. Everything can be changed while streaming, without anyone
losing the picture.

> [!NOTE]
> On Wayland, the system opens a picker to choose the screen or window the
> first time. After that it remembers your choice.

Several people can be live at once. If everyone is watching you in a small grid
tile, telinha sends a smaller stream (less GPU and bandwidth for everyone) and
scales back up the moment someone enlarges it.

## Watch

Click anyone who is live. Several streams sit in a grid that keeps every video
as large as possible.

| Action | How |
|---|---|
| Fullscreen | **F11**, or the button in the video's corner |
| Theater mode | double-click the video |
| Leave fullscreen / theater mode | **Esc** |
| Floating window (picture-in-picture) | button on the video |
| Zoom | mouse wheel; drag to pan, or follow the streamer's cursor (with a minimap) |
| Stream volume | control over the video |

On top of any stream:

- **"Look here" pointer**: everyone watching sees it.
- **Drawing**: 15 colors and 4 widths, highlighter included. You can hide other
  people's drawings, and admins can take someone's pen away.
- **Clip**: saves the last seconds (5 s to 10 min, your choice) with one click
  or a global hotkey, as MP4.
- **Recording**: MP4 without re-encoding, with sound. Survives resolution
  changes.
- **Screenshot**: PNG at the stream's resolution.

Clips and recordings go to your videos folder (`Videos/telinha`).

## Talk

| Action | How |
|---|---|
| Toggle the microphone | **Ctrl+M** |
| Deafen (hear nobody) | **Ctrl+D** |
| Someone's voice volume | right-click them |

In **Settings → Voice**: voice activation (with sensitivity) or
**push-to-talk**, which works even with a game focused; noise suppression
(removes fans, keyboards and hiss); echo cancellation (speakers work as well as
headphones); automatic gain for quiet microphones and a mic volume.

## Chat

- **Enter** sends, **Shift+Enter** adds a new line.
- Markdown: `**bold**`, `*italic*`, `` `code` ``, code blocks with a copy
  button and clickable links. Color emoji.
- Images: paste (Ctrl+V) into the box.
- Reactions, @mentions (the person mentioned is notified) and history for late
  joiners.
- **Right-click a message**: copy, reply quoting it, or send its author a
  private message.
- **Quoted replies**: the original message shows above the reply, and the
  person replied to is notified.
- **Private messages**: only the two of you see them, in any channel. From the
  message's menu, the person's menu or `/msg name text`.
- **Files** up to 256 MB: the paperclip button, dragging the file onto the window
  or `/arquivo path`. It's uploaded once to the server and each person
  downloads it when they click, in the background, without hurting video and
  voice. On the server it's encrypted and gone after 2 hours.
- Desktop notifications while telinha is in the background.

## Channels

A server can hold several rooms at once, IRC-style. Each channel has its own
chat, and the **call** (voice and streams) is separate: you can read one channel
while staying in another's call.

- Click a channel in the panel to read its chat.
- Click a channel's headphones icon to join its call. Your stream comes along.
- **+** creates a channel. An empty channel disappears on its own, except the
  server's pinned ones.
- Admins can set a password, lock it and change the topic (right-click the
  channel).

## Chat commands

| Command | Also | What it does |
|---|---|---|
| `/join channel` | `/j`, `/canal`, `/entrar` | Goes to that channel's chat (creates it if it doesn't exist). |
| `/call channel` | `/voz`, `/voice` | Joins that channel's call. Without a name: leaves the call. |
| `/channels` | `/canais`, `/list` | Shows the channels and how many people are in each. |
| `/msg name text` | `/m`, `/w`, `/pm`, `/dm`, `/privado` | Private message. Just the name: the box switches to sending privately to that person. |
| `/file path` | `/arquivo`, `/enviar` | Sends a file (or drag the file onto the window). |

Anything else starting with `/` goes to the chat as normal text.

## Shortcuts

| Key | What it does |
|---|---|
| **F11** | Fullscreen |
| **Esc** | Leaves fullscreen and theater mode |
| double-click | Theater mode |
| **Ctrl+M** | Microphone |
| **Ctrl+D** | Deafen |
| **Enter** / **Shift+Enter** | Send / new line in the chat |

**Global hotkeys** (they work with another program focused, like a game): clip,
microphone, deafen, share, screenshot and a master toggle. In
**Settings → Shortcuts**, any key, combination or mouse button.

## For admins

Whoever creates the room (or joins a dedicated server with the admin token) can,
by right-clicking a person: kick, ban, mute, stop their stream, take their pen
away, give or remove admin. They can also lock the room and manage channels.

On a dedicated server, the admin sees the **server stats**: CPU, memory,
bandwidth in and out, people per channel, who is lagging and a plain-language
guess at the bottleneck.

## Watch from a browser

On a [dedicated server](DEPLOY.md) started with `--web`, the room shows a TV
button that copies a link. Whoever opens it watches in the browser with nothing
to install: video, the stream's sound, the call's voices and the chat. The
server only relays the same frames, so the streamer pays nothing extra.

From a browser you can watch and chat; going live and talking need the app.

## Settings

The gear button opens the settings, in a room or on the home screen.

| Page | What's there |
|---|---|
| **General** | Name, language, notifications, stats always visible, new-version alerts (and installing on its own), clips and how long they are |
| **Appearance** | Themes: dark, light, pwnd (neon), pwnd light, Nord, Dracula or your own CSS (reloads when you save the file); interface size; CRT effect; home screen animations; show or hide other people's drawings |
| **Voice** | Voice activation or push-to-talk, microphone, sensitivity, volume, automatic gain, noise suppression, echo cancellation, joining with the mic on, notification sounds |
| **Shortcuts** | Global hotkeys (and a master switch) |
| **Camera** | Which camera and its resolution |
| **Performance** | Automatic quality, cursor outside the video, viewer-sized streams, interface frame cap, GPU encoder effort, AV1 (experimental) and **Test my PC** |
| **Debugging** | Debug log, sending the log to the room owner, crash reports |
| **About** | Version and version history |

> [!TIP]
> **Test my PC** measures for a few seconds how much your computer can handle
> for streaming and watching, and suggests settings. One click on
> *Use the suggestion* applies them.

## Updates

telinha (Windows and Linux) tells you when a new version is out, shows what
changes and installs it with one click, after checking the release signature.
In the settings you can let it install on its own or skip a version. The
history is in **Settings → About**.

## Where things are

| What | Linux | Windows |
|---|---|---|
| Settings | `~/.config/telinha/config.ini` | `%APPDATA%\telinha\config.ini` |
| Clips and recordings | `Videos/telinha` (the system's videos folder) | `Videos\telinha` |
| Files downloaded from the room | `Downloads` | `Downloads` |

For a portable setup (on a USB stick, say), the `TELINHA_PASTA_CONFIG` and
`TELINHA_PASTA_CLIPES` variables change these folders.
