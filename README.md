<p align="center">
  <img src="assets/icon.png" width="112" alt="telinha logo">
</p>

<h1 align="center">telinha</h1>

<p align="center">
  <strong>Low-latency group screen sharing for Linux and Windows.</strong><br>
  A Discord-style room where anyone can go live and everyone can watch, talk and chat.
</p>

<p align="center">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-Linux%20%7C%20Windows-5865f2?style=flat-square">
  <img alt="Zig 0.16" src="https://img.shields.io/badge/zig-0.16-f7a41d?style=flat-square">
  <img alt="Version 3.1.0" src="https://img.shields.io/badge/version-3.1.0-9333ea?style=flat-square">
  <img alt="MIT license" src="https://img.shields.io/badge/license-MIT-22c55e?style=flat-square">
</p>

<p align="center">
  <a href="../../releases/latest"><b>Download</b></a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#features">Features</a> ·
  <a href="#performance">Performance</a> ·
  <a href="#building-from-source">Build</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a> ·
  <a href="README.pt.md">🇧🇷 Português</a>
</p>

<p align="center">
  <img src="docs/img/en/room.jpg" alt="A room with a live stream, the member list and the chat" width="900">
</p>

---

## Why telinha

- **Fast.** Capture, encoding and decoding stay on the GPU when one is available. End-to-end latency is measured on every frame, and the stream adapts before a delay builds up.
- **Zero setup for friends.** A single invite link carries every way into the room: LAN, an opened router port, IPv6 or a built-in public tunnel. Each person joins through the fastest one that works for them.
- **Private.** Every connection is end-to-end encrypted with X25519 and ChaCha20-Poly1305. The room password is part of the key derivation.
- **Light.** The interface only redraws when something changes. Features you don't use cost nothing.
- **Portable.** Windows ships as a single `.exe` with nothing to install. Linux runs on Wayland and X11.

## Download

Grab the latest build from the [Releases page](../../releases/latest).

| Platform | File |
|---|---|
| Windows 10/11 (x86-64) | `telinha-windows-x86_64.exe` |
| Linux (x86-64) | `telinha-linux-x86_64.tar.gz` |
| Dedicated server | `telinha-server-linux-x86_64` / `telinha-server-linux-aarch64`, or build the Docker image (see [DEPLOY.md](docs/DEPLOY.md)) |
| Debug symbols for crash reports | `telinha-simbolos.tar.gz` |

> [!NOTE]
> The Windows executable is not code-signed, so SmartScreen will warn on first launch. Choose **More info → Run anyway**.

## Quick start

1. **Create a room.** Open telinha and pick **Create room**. The default port is 7777 and the password is optional.
2. **Invite friends from outside your network.** In the *Inviting people from outside* card, click **Open port on router** for a direct, lowest-latency connection. If your ISP uses CGNAT, click **Create public link** instead. Then **Copy invite** and send it.
3. **Join.** Paste the `telinha://…` invite on the home screen. telinha pre-fills it if it's already on your clipboard.
4. **Go live.** Click **Share screen**, choose resolution, frame rate, quality and content type, then **Go live**. Everything can be changed mid-stream.
5. **Watch.** Click anyone who is live. Press **F11** for fullscreen, **double-click** for theater mode and **Esc** to leave.
6. **Talk.** Toggle the microphone with **Ctrl+M** and deafen with **Ctrl+D**. Right-click a member to change their voice volume.

On Wayland, the system asks which screen or window to share the first time and remembers your choice.

## Features

<table>
<tr>
<td width="50%" valign="top">

### 🖥️ Streaming
- Several people live at once, in a grid that keeps every video as large as possible.
- Spotlight, fullscreen, theater mode and a floating **picture-in-picture** window.
- Share a full screen, a single window, or a rectangle you drag over your own preview.
- Webcam alongside or instead of the screen.
- **Computer audio** from everything, everything except chosen apps, or a single app. telinha never captures its own sound, so there is no echo.

</td>
<td width="50%" valign="top">

### 👀 Watching
- **Zoom** with the mouse wheel, drag to pan, or follow the streamer's cursor, with a minimap.
- A **"look here" pointer** and **drawing on the stream**, visible to everyone watching.
- **Clips** of the last 5 s to 10 min with one click or a global hotkey.
- **MP4 recording** without re-encoding, including audio. Recordings survive resolution changes.
- PNG screenshots at the stream's native resolution.

</td>
</tr>
<tr>
<td valign="top">

### 🎙️ Voice and chat
- Acoustic echo cancellation, so speakers work as well as headphones.
- RNNoise noise suppression for fans, keyboards and hiss.
- Voice activation or **push-to-talk** that works while a game is focused.
- Opus with FEC, sent ahead of video so it never waits behind a frame.
- Chat with images, reactions, @mentions and history for late joiners.
- Desktop notifications while telinha is in the background.

</td>
<td valign="top">

### 🛡️ Rooms and control
- The room creator gets the crown and can kick, ban, mute, stop a stream, give or remove admin and lock the room.
- **Automatic reconnection** that resumes your stream and the streams you were watching.
- Live stats: resolution, frame rate, bandwidth and measured end-to-end latency.
- **Configurable global hotkeys** for clip, mic, deafen, share, screenshot and a master toggle.
- Themes: dark, light, pwnd neon, pwnd light, Nord, Dracula, or your own CSS.

</td>
</tr>
</table>

### ⚡ Under the hood

| | |
|---|---|
| **Codecs** | H.264, plus HEVC on NVIDIA when every viewer can decode it, for less bandwidth at the same quality. |
| **GPU encode and decode** | NVIDIA NVENC/NVDEC everywhere. Intel and AMD through Media Foundation on Windows and VA-API on Linux. Otherwise openh264 with SIMD across threads. |
| **Zero-copy pipeline** | On Linux, the compositor's DMA-BUF goes straight to the encoder, through CUDA on NVIDIA and through VA-API VPP on Intel/AMD. On Windows, DXGI textures go through a CUDA kernel into NVENC. Viewers decode with NVDEC straight into an OpenGL texture. Any failure falls back to the CPU path. |
| **Cursor outside the video** | Viewers draw the arrow themselves, so moving the mouse over a still screen sends no frames at all. |
| **Sized for the viewer** | If everyone watches you in a small grid tile, telinha sends a smaller stream and scales back up the moment someone enlarges it. |
| **Transport** | Video, audio and voice over UDP, with only lost fragments resent. Control traffic over TCP. Everything falls back to TCP when UDP is blocked. |
| **Congestion control** | Every frame is acknowledged, so real latency is measured even inside tunnels that hide congestion. A slow viewer drops to half the frames without affecting anyone else. |
| **Native capture** | PipeWire and xdg-desktop-portal on Wayland (Hyprland, GNOME, KDE, Sway), X11, DXGI Desktop Duplication and Windows.Graphics.Capture. |
| **Diagnostics** | One-click debug log and crash reports, with debug symbols published per release so a stack trace can be translated back to source lines. |

## Screenshots

| | |
|---|---|
| <img src="docs/img/en/share.png" alt="Share screen dialog"> | <img src="docs/img/en/room_pwnd.jpg" alt="The pwnd neon theme"> |
| **Going live.** Pick what to show, which audio to send, the content type, resolution, frame rate and quality. | **Themes.** The pwnd neon theme, one of six built-ins. You can also bring your own CSS. |
| <img src="docs/img/en/shortcuts.png" alt="Shortcuts settings"> | <img src="docs/img/en/performance.png" alt="Performance settings"> |
| **Global hotkeys.** Any key, combination or mouse button, active while a game is focused. | **Performance.** Automatic quality, cursor outside the video, viewer-sized streams and a built-in PC test. |

## Performance

Measured on an **Intel i5-2400S** from 2011 (4 cores) with a **GTX 1050 Ti**, at 1080p, using `zig build bench`.

| Content and encoder | Color conversion | Encode | Decode | Bandwidth at 30 fps |
|---|---|---|---|---|
| Scrolling text, openh264 | 3.7 ms | 23 ms | 4 ms | ~200 KB/s |
| Motion, openh264 | 3.9 ms | 13 ms | 13 ms | ~730 KB/s |
| Scrolling text, **NVENC + NVDEC** | on the GPU | **7.5 ms** | **6 ms** | ~500 KB/s |
| Motion, **NVENC + NVDEC** | on the GPU | **8 ms** | **6 ms** | ~630 KB/s |

With the zero-copy path, a 1080p60 HEVC stream on the same machine costs the streamer about **20% of one core**, and the viewer about 10%. End-to-end latency stays around **17 ms** on a local network. These numbers were measured in a headless Sway session on the same GPU, with the real PipeWire portal.

On a real 1080p code screen, NVENC reaches **57 dB PSNR at 0.36 Mbit/s**, including the full keyframe sent when someone joins. On any modern CPU, openh264 alone handles 1080p60.

## Building from source

You need [Zig 0.16](https://ziglang.org/download/). The C and C++ dependencies are fetched by `zig build`: openh264, Dear ImGui, GLFW, NASM, and the NVENC and VA-API headers.

On Linux, install the system libraries for the UI and capture:

```sh
# Arch
sudo pacman -S glfw libportal pipewire libx11 libxext libxfixes
# Debian / Ubuntu
sudo apt install libglfw3-dev libgl-dev libportal-dev libpipewire-0.3-dev libx11-dev libxext-dev libxfixes-dev
```

Then build:

```sh
zig build                          # Linux app + Windows .exe + dedicated server
zig build run                      # run the app
zig build test                     # unit, server integration and codec tests
zig build bench                    # video pipeline benchmark
zig build loadtest -- 8 40 1       # 8 viewers plus one on a 2 Mbit/s link, for 40 s
zig build server -Dserver-only     # server only, without the app dependencies
```

Binaries land in `zig-out/bin/`. Add `-Dcpu=x86_64_v2` for portable builds that run on x86-64 CPUs from about 2009 on, as CI does.

<details>
<summary><b>Command-line options</b></summary>

> The flags are in Portuguese, matching the codebase.

```
--nome X              your display name
--criar [port]        create a room
--entrar host:port    join a room (also accepts a telinha://… invite)
--senha X             room password
--admin TOKEN         join a dedicated server as admin
--publico             with --criar: open the public link right away
--transmitir          go live as soon as you connect
--assistir            watch everyone who is live
--fps N --qualidade N --modo tela|jogo --software
--estatisticas        always show stats
```

</details>

<details>
<summary><b>Environment variables for troubleshooting</b></summary>

| Variable | Effect |
|---|---|
| `TELINHA_DEBUG=1` | Print the timing of every pipeline stage. Without a terminal, use *Settings → Debugging* instead. |
| `TELINHA_IDIOMA=en\|pt` | Force the interface language. |
| `TELINHA_PASTA_CONFIG`, `TELINHA_PASTA_CLIPES` | Use other config and clips folders for a portable setup. |
| `TELINHA_SEM_GPU_CAPTURA=1` | Disable the zero-copy GPU capture path. |
| `TELINHA_SEM_CUDAGL=1` | Disable CUDA–OpenGL sharing: NVDEC straight to a texture when watching, and NVIDIA zero-copy capture when streaming. |
| `TELINHA_SEM_SHADER=1` | Do color conversion on the CPU. |
| `TELINHA_SEM_DMABUF=1` | Capture through shared memory instead of DMA-BUF. |
| `TELINHA_CURSOR_EMBUTIDO=1` | Let the compositor draw the cursor into the video (Hyprland). |
| `TELINHA_SEM_VAAPI=1` | Skip the VA-API encoder on Linux. |
| `TELINHA_SEM_NVENC=1` | Skip the NVENC encoder. |
| `TELINHA_SEM_MF=1` | Skip the Media Foundation encoder on Windows. |
| `TELINHA_SEM_WGC=1` | Capture windows with PrintWindow on Windows. |
| `TELINHA_SEM_SOM=1` | Don't play received audio. |

If capture fails or is slow, `zig build captest` reports the method, the pixel format and the real frame rate, and saves a frame.

To turn a crash report's stack trace into source lines, use `tools/simbolos.py` with `telinha-simbolos.tar.gz` from the same release.

</details>

## Documentation

- [Architecture](docs/ARCHITECTURE.md): threads, the video pipeline, bandwidth control and performance decisions.
- [Protocol](docs/PROTOCOL.md): handshake, encryption and every message type.
- [Dedicated server](docs/DEPLOY.md): static binary, Docker and systemd.
- [Contributing](CONTRIBUTING.md) and the [changelog](CHANGELOG.md).

The deeper docs are written in Portuguese.

## License

MIT. See [LICENSE](LICENSE). Third-party components and their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
