# Troubleshooting

<sub>[🇺🇸 English](FAQ.md) · [🇧🇷 Português](FAQ.pt.md)</sub>

The questions that come up most, and what to do about each. Not here? Open an
[issue](https://github.com/RshaCuDeVidro/telinha/issues) and, if you can,
attach the debug log (see [Send a log](#send-a-log)).

## Installing and starting

### Windows says the app might be dangerous

The `.exe` isn't code-signed (a signing certificate is expensive), so
SmartScreen warns on first launch. Click **More info → Run anyway**. Every
release ships a signed `SHA256SUMS` if you want to check the file.

### A library is missing on Linux

`install.sh` prints the right command for your distro. By hand:

```sh
# Debian / Ubuntu / Pop!_OS / Mint
sudo apt install libportal1 libpipewire-0.3-0
# Arch
sudo pacman -S libportal pipewire
# Fedora
sudo dnf install libportal pipewire-libs
```

The binary runs on any distro with glibc 2.31 or newer.

### How do I uninstall on Linux?

```sh
curl -fsSL https://raw.githubusercontent.com/RshaCuDeVidro/telinha/main/install.sh | sh -s -- --remove
```

It removes the binary, the menu entry and the `telinha://` link handler. Your
settings (`~/.config/telinha`) and clips stay where they are, if you want to
delete them too.

### Is there a macOS or phone app?

No app. But if the room is on a [dedicated server](DEPLOY.md) with `--web`, you
can **watch from a browser**, phones included: the TV button in the room copies
the link.

## Connecting

### Friends outside can't join

1. In the room, click **Open port on router**. If it works, a new invite
   already carries the direct address.
2. If it doesn't open (router without UPnP, or an ISP with CGNAT), click
   **Create public link**. It works on any network.
3. Copy the invite **again** after changing anything: it carries the ways in
   that existed when it was copied.

The [connection guide](CONNECTING.md) covers every case, including manual port
forwarding, IPv6, gaming VPNs and SSH tunnels.

### The app warned that the server identity changed

The invite carries the server's fingerprint, and the app checks it before
sending anything. If it changed, either the server was reinstalled (its key was
replaced) or someone in the middle is trying to pose as it. Check with the room
owner before trusting the new one.

### How many people fit in a room?

In a room created by the app, your computer is the server: each stream leaves
your internet connection once per viewer. For lots of people (or a weak
upload), use a [dedicated server](DEPLOY.md) on a VPS: the streamer then sends
once and the server fans it out. The dedicated server accepts 32 people by
default (`--max` changes it).

### I put a password on a channel (and made it invisible), and another window of mine got in without it

Room admins get into any channel, with a password or locked, and see invisible
ones. If you put the admin token in *Advanced options* on the join screen,
every telinha window on that PC joins as an admin (they share the same
settings), and the channel menu says "You're a room admin". Someone who isn't
an admin needs the password, can't get into a locked channel and doesn't see
an invisible one. To test as another person, use another PC, or clear the
token before opening the second window. Two windows on the same PC are also
the same person when it comes to being a channel OP.

## Streaming

### On Wayland the screen picker doesn't show up

telinha uses the system portal (`xdg-desktop-portal`). It needs the right
backend for your desktop:

| Desktop | Package |
|---|---|
| GNOME | `xdg-desktop-portal-gnome` |
| KDE | `xdg-desktop-portal-kde` |
| Hyprland | `xdg-desktop-portal-hyprland` |
| Sway and other wlroots | `xdg-desktop-portal-wlr` |

After installing it, log out and back in.

### "The portal refused the capture: CreateSession failed"

Your desktop's portal backend didn't start. The most common case: the user
systemd restarted with the compositor still open and lost the
`WAYLAND_DISPLAY` the compositor had passed to it; without it, it doesn't even
try to start `xdg-desktop-portal-hyprland` (or `-wlr`). telinha notices this,
passes the session's variables to systemd and tries again on its own. If it
still fails, run this in a terminal in the session:

```sh
systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP
systemctl --user restart xdg-desktop-portal
```

and check that your compositor runs `import-environment` (or
`dbus-update-activation-environment --systemd`) when it starts.

### My game stutters while I stream

- In **Settings → Performance**, set the GPU encoder to **Light**.
- Cap the interface at **30 fps** (same page).
- Lower the stream's resolution or frame rate.
- Run **Test my PC** and use its suggestion.

### Text looks blurry

Use the **Screen and text** content type and a higher quality. If someone is
watching you in a small grid tile, the stream is smaller on purpose and goes
back up when they enlarge it.

### Someone says it's lagging

telinha adjusts on its own: it measures the latency of every frame, lowers the
bitrate when someone's internet can't keep up and sends half the frames to
whoever is far behind, without making it worse for anyone else. If it keeps
happening, look at that person's stats over the video (latency and bandwidth)
and see the [connection guide](CONNECTING.md): a direct path (an opened port) is
almost always better than the public link.

## Sound and voice

### There's echo

Turn on **echo cancellation** in **Settings → Voice**, or use headphones. The
stream's sound never loops back into the streamer's microphone: telinha
doesn't capture its own sound.

### My microphone is too quiet

In **Settings → Voice**, turn on **automatic gain** or raise the microphone
volume.

### The mic picks up my keyboard and fan

Turn on **noise suppression**, or switch to **push-to-talk**.

## Updates

### The update failed

Download the new version from the [Releases page](https://github.com/RshaCuDeVidro/telinha/releases/latest)
and replace the file. On Windows, an antivirus holding the `.exe` can block the
automatic swap. If the app sits in a folder it can't write to, it only shows the
button to the release page.

## Send a log

When something goes wrong, the log helps a lot:

1. **Settings → Debugging → Record a debug log**.
2. Do whatever went wrong again.
3. Under **Send the log**, send it to the room owner (or save the file and attach
   it to an issue).

The log contains no passwords. If the app crashes, it asks the next time it
opens whether it can send the crash report.

## Privacy

Every connection is encrypted (X25519 and ChaCha20-Poly1305), and the room
password goes into the key derivation: nobody along the way sees anything.
Whoever hosts the room (your PC or the dedicated server) relays video and voice
without recording anything; the chat history lives only in its memory. Files
sent in the room sit on the server encrypted, with the key only in memory, and
are gone after 2 hours. No accounts and no data collection: the app only talks
to GitHub to check for new versions (you can turn that off), and a log or crash
report only goes out if you send it.
