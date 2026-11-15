# User guide

<sub>[🇺🇸 English](GUIDE.md) · [🇧🇷 Português](GUIDE.pt.md)</sub>

Everything telinha can do, from the first invite to the settings. If you just
want to get going, the first three sections are enough. Inside the app, the
room's **?** button (or **F1**) explains the basics, and the first time you're
in a room a five-step tour shows where everything is.

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
3. Click **Copy invite** and send it. The **Invite** button, in the top bar,
   copies the same invite any time.

In a room with nobody live, the middle of the screen shows two big cards,
**Share my screen** and **Bring your friends** (which copies the invite), with
the steps below: someone invites, someone shares, everyone else clicks
**Watch**.

The **Invite** button copies a link to the site's invite page
(`https://…/telinha/j/#i=…`): it's clickable on Discord and in the browser, it
opens the app for whoever has it and shows how to install for whoever doesn't.
Inside it goes the invite itself (`telinha://…`), and what comes after the `#`
is never sent to the site.

The invite (`telinha://…`) carries every way into the room: LAN, opened port,
IPv6 and public link. Each person joins through the fastest one that works for
them. It also carries the server's fingerprint, so the app checks it is really
talking to your room before sending anything.

Didn't work? The [connection guide](CONNECTING.md) has every other way:
manual port forwarding, IPv6, gaming VPNs, SSH tunnels.

## Join a room

Paste the invite (the https link or the `telinha://` one) on the home screen
and click **Join**. If the invite is already on your clipboard when you open
telinha, it's pasted for you.

The rooms you joined show up under **Recent rooms**, below the card: one
click joins again (with the password and the channel), and the **x** removes
one from the list. Clicking a `telinha://` link opens the app: on
Windows it registers itself the first time it opens, on Linux `install.sh` does
it. With telinha already open, the link goes to the open window.

You can join straight into a channel: type its name in the channel field on
the home screen.

## The room

| Where | What's there |
|---|---|
| **Top** | The room's name (click it: its menu, with the invite, the browser link and, for admins, lock, clear the chat, banned people and stats), the **channel tabs**, **Invite**, help (**?**) and settings |
| **Middle** | The streams. With nobody being watched, whoever's live shows up here with a **Watch** button. While watching, the bar above says what's playing and has **Grid** or **Spotlight**, **Watch all**, **Stop watching** and **Theater** |
| **Side** | The panel, with two tabs: **Chat** (the channel's chat) and **People** (*Live now*, one card per stream with **Watch**, and who's in the channel). It slides open and closed |
| **Bottom** | The control bar, with a name under every button: **Microphone**, **Hear**, **Camera**, **Share screen** (while live, the red button next to it stops), **Chat** and **People** (they open the panel; the number on top shows new messages and how many are live) and **Leave** |

**Ctrl+J** opens and closes the chat and **Ctrl+B**, the people. Drag the
panel's edge to change its width (double-click goes back to default). In
**Settings → Appearance → Room layout**, the panel moves to the left and the
control bar sits at the bottom, on a side or collapsed. It's all saved.

## Go live

Click **Share screen** and choose:

| Option | What it does |
|---|---|
| **What to show** | The whole screen, a single window (on Windows, as cards with live thumbnails), or just part of it: tick *Just part of the screen* and drag a rectangle as soon as it starts (or later, with the crop button on your preview). The webcam can go along or instead of the screen. |
| **Sound** | No sound, all computer sound (except telinha), just one program's sound, or everything except some programs (e.g. Discord). telinha's own sound never goes in, so there's no echo. |
| **Content type** | *Screen and text* keeps letters sharp (code, documents, a browser). *Game and video* favors smooth motion. |
| **Resolution, frame rate and quality** | The bitrate drops on its own if someone's internet can't keep up, and goes back up when it improves. |
| **Use the GPU** | NVIDIA, and on Windows also AMD and Intel. Without a suitable GPU, it uses the CPU. |

Click **Start streaming**. Everything can be changed while streaming, without
anyone losing the picture. To stop, the red button next to **Live** on the
bottom bar (or the **Stop** on your card in the list).

> [!NOTE]
> On Wayland, the system opens a picker to choose the screen or window the
> first time. After that it remembers your choice.

Several people can be live at once. If everyone is watching you in a small grid
tile, telinha sends a smaller stream (less GPU and bandwidth for everyone) and
scales back up the moment someone enlarges it.

## Watch

Click **Watch** on the card of whoever is live (in the middle of the screen,
or under **People**). Several streams sit in a grid that keeps every
video as large as possible; the stage bar switches to **Spotlight** (one big,
the others below), watches all at once or stops watching everything.

A screen bot (like the [big-screen bot](BOTS_SCREEN.md)) is watched the same
way. If it has a panel, the panel sits docked under the video, with its
buttons (pause, skip...), while its stream is alone or featured. A bot in
another channel shows up under **People**, in *Bots in other channels*:
right-click → **Bring to my call**.

If someone is live in another channel, **People** shows it under *Live in other
channels*: one click and you're there, watching.

The dot next to the streamer's name tells how the stream is arriving: green
flows fine, yellow stuttering, red bad, and why (*your internet*, *your PC*,
*so-and-so's PC or internet*).

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
| Deafen (stop hearing the call; stream audio keeps playing) | **Ctrl+D** |
| Someone's voice volume | right-click them |

In **Settings → Voice**: voice activation (with sensitivity) or
**push-to-talk**, which works even with a game focused; noise suppression
(removes fans, keyboards and hiss); echo cancellation (speakers work as well as
headphones); automatic gain for quiet microphones and a mic volume.

## Chat

- **Enter** sends, **Shift+Enter** adds a new line.
- Markdown: `**bold**`, `*italic*`, `` `code` ``, code blocks with a copy
  button and clickable links. Color emoji.
- Images: paste (Ctrl+V, anywhere in the room) or drag them onto the window. A
  preview asks before sending: **Enter** sends, **Esc** cancels.
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
- **[Bot](BOTS.md) cards**: a cover, fields, a progress bar that moves by
  itself and buttons; clicking a button sends the click to the bot, which
  changes the card in place.
- Desktop notifications while telinha is in the background.

## Channels

A server can hold several rooms at once, IRC-style. The channels are the
**tabs** at the top. Each has its own chat, voice and screens.

- Click a tab to go to that channel: the chat and the call (voice and streams)
  go together, and so does your stream. A red dot on the tab means someone is
  live there.
- Right-click a tab: **Just read the chat** (stay in the current call) or
  **Leave the call** (stay in the chat only; the bottom bar gets a **Join**
  button to get back). For OPs and admins, the channel's options are in the
  same menu.
- **+** next to the tabs creates a channel. It stays in the list even when empty (and if the
  server restarts); it only goes away after 3 days without anyone. Channels
  pinned by an admin stay forever.
- **Whoever creates a channel is its OP**, with a **blue crown** next to their
  name in the list (the yellow one is the room owner's). An OP runs the
  channel: right-click the channel for password, lock, topic and making it
  **invisible** (left out of the list; whoever knows the name and password
  gets in); right-click a person to **make them OP**, **move** them to another
  channel (an open one or one where you're also an OP) and **remove** them
  from the channel for good. An OP can't touch the channel's creator or
  admins; other OPs, only the creator can.
- Only **the creator** deletes the channel (it asks to confirm; whoever was in
  it goes back to the default channel) and takes OP away from others. Room
  admins can do everything, in any channel. The default channel has no OPs.
- A **channel password applies to everyone**, OPs and the creator included: to
  get in, type the password (the app remembers it and goes back to the
  channel on its own if the internet drops). Only room admins get in without
  it, and they also get into locked channels and see invisible ones. Testing
  with two windows on the same PC: both are the same person to the server
  (and with the admin token in *Advanced options*, both are admins).

## Chat commands

| Command | Also | What it does |
|---|---|---|
| `/join channel` | `/j`, `/canal`, `/entrar` | Goes to that channel, chat and call (creates it if it doesn't exist). |
| `/call channel` | `/voz`, `/voice` | Joins only that channel's call. Without a name: leaves the call. |
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
| **Ctrl+J** | Opens and closes the chat |
| **Ctrl+B** | Opens and closes People (who's live) |
| **F1** | How to use (the help) |
| **Enter** / **Shift+Enter** | Send / new line in the chat |

**Global hotkeys** (they work with another program focused, like a game): clip,
microphone, deafen, share, screenshot and a master toggle. In
**Settings → Shortcuts**, any key, combination or mouse button.

## For admins

Whoever creates the room (or joins a dedicated server with the admin token) can,
by right-clicking a person: kick, ban, mute, stop their stream, take their pen
away, give or remove admin. In the room menu (click the room's name, at the
top) they can lock the room and **clear the room's chat** (two clicks): every
channel's history and the files are gone for everyone, without restarting the
server. Channels are managed by right-clicking their tabs.

On a dedicated server, the admin sees the **server stats** (in the room menu): CPU, memory,
bandwidth in and out, people per channel, who is lagging and a plain-language
guess at the bottleneck.

## Watch from a browser

On a [dedicated server](DEPLOY.md) started with `--web`, the room menu gets
**Copy the link to watch in a browser**. Whoever opens it watches in the browser with nothing
to install: video, the stream's sound, the call's voices and the chat. The
server only relays the same frames, so the streamer pays nothing extra.

From a browser you can watch and chat; going live and talking need the app.

## Settings

The gear button opens the settings, in a room or on the home screen.

| Page | What's there |
|---|---|
| **General** | Name, language, notifications, stats always visible, new-version alerts (and installing on its own), clips and how long they are |
| **Appearance** | Themes: Husky (the default, flat), pwnd (neon), dark, neon, aurora, high contrast, light, pwnd light, Nord, Dracula, your own `.kdl` ones or your own CSS (reloads when you save the file); interface size; CRT effect; **room mood** (the background shifts tone with the room's energy, with no constant animation); home screen animations; show or hide other people's drawings; the room layout (panel on the left, control bar) and **Take the room tour again** |
| **Voice** | Voice activation or push-to-talk, microphone, sensitivity, volume, automatic gain, noise suppression, echo cancellation, joining with the mic on, notification sounds |
| **Shortcuts** | Global hotkeys (and a master switch) |
| **Camera** | Which camera and its resolution |
| **Performance** | **Economy mode** (weak PC: interface at 30 fps, no animations or effects), automatic quality, cursor outside the video, viewer-sized streams, interface frame cap, GPU encoder effort, AV1 (experimental) and **Test my PC** |
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
