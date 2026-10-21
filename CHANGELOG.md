# Changelog

<sub>[🇺🇸 English](CHANGELOG.md) · [🇧🇷 Português](CHANGELOG.pt.md)</sub>

## Unreleased

Talks to 3.1 (the new messages are ignored by older apps and servers).

### Highlights

- 🎨 **New room layout**: a top bar with who's live, the stage in the middle, a floating control dock and a single side card with the members and the chat. Nothing overlaps, even in a small window.
- 🖥️ **Fullscreen button** on each stream; controls and cursor hide when the mouse stops.
- 🪟 **Windows**: Intel/AMD streams straight from the GPU (D3D11 video processor → Media Foundation), alt-tab no longer stops the stream, minimized windows show up in the list, and sound capture is sturdier.
- 🎙️ **Quiet microphones get louder** (automatic gain) and there's a mic volume slider.
- 🛡️ **Rooms hold up** against someone joining and leaving over and over.
- 📜 **Debug log straight to the room owner**, and much more detail in it.

<!-- detalhes -->

### All changes

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
  @mentions with Tab to complete, highlight and notification. The image travels
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
