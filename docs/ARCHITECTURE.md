# Architecture

<sub>[🇺🇸 English](ARCHITECTURE.md) · [🇧🇷 Português](ARCHITECTURE.pt.md)</sub>

```
 streamer                                    room server                          viewers
 ────────                                    ───────────                          ───────
 capture thread                              per connection:                      per watched stream:
   screen/camera (PipeWire/X11/DXGI/WGC)       reader thread ──┐                   reader thread (network, acks)
     │ wakes up when the screen changes        writer thread ◄┤ own queue           │
   scale (pool, in stripes)                                   │ (drops it if     queue (max. 150 ms)
     │                                      received frame ───┘  it got late)       │
   GPU: hands over BGRX (swaps pointer)       1 allocation, N references          decode thread
   software: BGRX → I420 (SIMD, pool)         only for those watching               │ H.264 → I420 (openh264)
     │  ─ 3 slots: the encoder always takes the newest frame ─                      │ I420 → RGBA (SIMD, pool)
 encode thread                                                                       ▼
   H.264: NVENC/MF (GPU) or openh264 (CPU, slices on threads)                     UI: uploads to the GPU, draws
     │
   send queue ── rate control ──► TCP + ChaCha20-Poly1305 ───────────────────────►
        ▲                                      │                                      │
        └──── ack of every frame ──────────────┘ ◄──── ack of every frame ───────────┘
```

Each person's screen and camera are two independent streams (one `Sharer` and
one stream each, see [PROTOCOL.md](PROTOCOL.md)), with the same pipeline, the
same rate control and separate acknowledgements.

## Modules

| file | responsibility |
|---|---|
| `src/main.zig` | window (GLFW), OpenGL, main loop that sleeps when nothing happens; exit with `sync.hardExit` |
| `src/ui.zig` | the whole interface (Dear ImGui through cimgui) |
| `src/fonts.zig` | embedded fonts (Inter + icons); each ImGui context loads its own |
| `src/pip.zig` | floating window: second GLFW window with a shared GL context and its own ImGui |
| `src/client.zig` | room connection, state (members, chat, clock), `View` = watched stream |
| `src/connect.zig` | invite with several addresses and the race between them (the first that answers as a room wins) |
| `src/sharer.zig` | streaming thread (screen or camera): capture → scale → encode → send |
| `src/clip.zig` | last ~30 s of each stream (clip) and recording in progress; videos folder |
| `src/mp4.zig` | MP4 writer (H.264 in avc1 or HEVC in hvc1, + Opus, without re-encoding): clip with `moov` at the start, fragmented recording |
| `src/udp.zig` | video/sound/voice over UDP: encrypted datagrams, pieces, reassembly, NACK, per-stream ordering, pacing |
| `src/update.zig` | new version: version comparison and last release check on GitHub (curl / WinHTTP) |
| `src/chatimg.zig`, `src/chatsend.zig` | image in the chat: shrinks and becomes an H.264 frame (and back); reads file/clipboard on a thread |
| `src/c/image.c` | stb_image (local files/clipboard only) and the image copied on Windows (PNG/DIB) |
| `src/c/audio_apps_win.c` | Windows: programs playing sound (audio sessions) |
| `src/c/httpget_win.c` | Windows: GET through WinHTTP (version check) |
| `src/ratectl.zig` | bitrate control from the end-to-end delay |
| `src/server.zig` | room server (embedded in the app or in `telinha-server`) |
| `src/server_main.zig` | dedicated server executable |
| `src/tunnel.zig` | public link: bore protocol client; each visitor becomes a room connection |
| `src/upnp.zig` | port opened on the router (UPnP IGD: SSDP + SOAP), with a CGNAT warning |
| `src/codec.zig` | openh264 and hardware encoder wrapper + vectorized color conversions |
| `src/c/hwenc.c` | picks the hardware encoder: NVENC → Media Foundation (Windows) or VA-API (Linux) → none (openh264) |
| `src/c/hwenc_nvenc.c` | NVIDIA hardware encoder, H.264 and HEVC (NVENC API 11.1, loaded at runtime) |
| `src/c/hwenc_mf.c` | Windows: hardware H.264 encoder on any card (Media Foundation MFT: Intel, AMD, NVIDIA) |
| `src/c/hwdec.c` | picks the hardware decoder: NVDEC → Media Foundation (Windows) or VA-API (Linux) |
| `src/c/hwdec_nvdec.c` | NVIDIA hardware decoder, H.264 and HEVC (NVDEC/nvcuvid, loaded at runtime) |
| `src/c/hwdec_mf.c` | Windows: Media Foundation H.264 decoder with DXVA (any card), texture copied to memory |
| `src/c/hwva.c` | Linux: H.264 encoder and decoder through VA-API (Intel/AMD; libva loaded at runtime). The decoder does the "software" part of H.264 (SPS/PPS, POC, references, MMCO); the encoder tests itself on startup (3 frames decoded by openh264) |
| `src/gl.zig` | textures and YUV→RGB conversion in a shader |
| `src/audio.zig` | audio: streamer-side Opus, anti-oscillation ring and viewer-side mixer |
| `src/voice.zig` | room voice: microphone → echo cancellation → RNNoise → gate → Opus; each person's voice on the other side |
| `src/aec.zig` | echo cancellation (SpeexDSP) with the mixer output as reference, compensating for the drift between clocks |
| `src/c/audio_pw.c` | Linux: application sound through the PipeWire graph, without telinha itself (or from a single program: name or process tree) |
| `src/c/audio.c` | computer sound capture and output (miniaudio) |
| `src/crypto.zig` | X25519 handshake and ChaCha20-Poly1305 channel |
| `src/proto.zig` | messages, send queues, framing, acknowledgement window (`AckWindow`) |
| `src/net.zig` | sockets (POSIX/Winsock), route of whoever connected, machine addresses (network IPv4, global IPv6) |
| `src/c/netaddr_win.c` | Windows: the machine's global IPv6 addresses (`GetAdaptersAddresses`) |
| `src/sync.zig` | native mutex/condvar, clock, thread pool, `hardExit` |
| `src/c/capture_linux.c` | Linux: portal + PipeWire (Wayland, DMA-BUF) or XShm (X11) |
| `src/c/capture_win.c` | Windows: monitor through DXGI (GDI fallback); one window through Windows.Graphics.Capture (PrintWindow fallback) |
| `src/c/camera_linux.c`, `src/c/camera_win.c` | webcam: PipeWire (Linux) / Media Foundation (Windows), delivered as BGRX like the screen |
| `src/c/notify_linux.c`, `src/c/notify_win.c` | desktop notification: D-Bus (Linux) / tray balloon + blinking window (Windows) |
| `src/qa.zig`, `src/c/qa_hooks.cpp` | interface test mode (`TELINHA_QA`): ImGui hooks, `items.tsv` + `state.json` |
| `tools/qa/` | interface tests: really clicks the buttons (XTest on Xvfb); fake UPnP router and bore tunnel |
| `src/tests.zig`, `src/integration_test.zig` | tests |
| `src/bench.zig` | video pipeline benchmark |
| `src/loadtest.zig` | server load test (slow viewers, bad tunnel) |
| `src/captest.zig` | screen capture diagnostics |

## Transport: TCP for everything, UDP for what's in a hurry

The connection is always TCP (handshake, chat, members, acknowledgements, IDR
requests). If the UDP path opens up (see `docs/PROTOCOL.md` §2b), each
connection's writer (`proto.SendQueue.writerLoop`) sends frames, audio and voice
over it: the message is the same, only the path changes, and the receiver
delivers it in the same TCP `handle`. That removes the TCP head-of-line blocking
(a lost packet held voice behind a video frame, and a loss at the end of a burst
cost ~200 ms of time-based retransmission) without rewriting the rest: the
queue, the rate control driven by acknowledgements and the slow-viewer thinning
stay the same (the writer paces the sending, so whatever didn't go out stays in
the queue and counts as delay, as before). A piece lost: NACK and resend just
that piece; lost for good: the decoder asks for an IDR, as on TCP when a frame
arrives damaged. Tested with 5% loss in both directions
(`TELINHA_UDP_PERDA=5`, `run_qa.py udp_com_perda`): no message lost for good,
~50 ms of delay.

## Codec: H.264 always, HEVC when everyone can

openh264 guarantees that anyone can decode H.264. HEVC does much better per bit
on text (in the NVENC/NVDEC test, 720p at 2 Mbit/s: +4 dB), but it only comes out
of a GPU and not everyone can decode it. So the room negotiates per stream: each
person says in `hello` what they can decode (tested once per process), the server
sends the streamer the intersection of those watching, and the encoder is
recreated in the new codec when it changes (starting on an IDR). The codec goes
in each frame's flags; viewers switch decoders when they see it change. Clips and
recordings stay in the codec that arrived (hvc1/hvcC in the MP4).

## Performance decisions

**Hardware encoder first.** `hwenc.c` tries, in this order: NVENC (NVIDIA card,
driver 470+: encodes 1080p in a few milliseconds without using the CPU and takes
BGRX directly, with the color conversion happening on the GPU); on Windows, the
Media Foundation hardware encoder (Intel Quick Sync, AMD or NVIDIA MFT; low
latency, CBR, no B-frames, a single temporal layer, NV12 input); on Linux,
VA-API (Intel/AMD: I and P, CBR with short HRD, our own SPS/PPS, a single
temporal layer, NV12 input; before being used it encodes 3 synthetic frames and
checks them against openh264, so a driver with a bug doesn't send garbage to
anyone); and, without any of them, openh264. If the hardware encoder fails at any
point, the app falls back to openh264 without interrupting the stream. An encoder
that ignores an IDR request (wine's, some driver out there) is found out the
second time in a row and is then **recreated on every request** — a new encoder
always starts with an IDR —, otherwise whoever joins later would never see
anything (`sharer.zig`).

**Two-thread pipeline.** Capture+conversion and encode run in parallel, with 3
slots between them: the encoder always takes the newest frame and an old frame
never waits in the queue. The per-frame time becomes that of the slower stage.

**Event-driven capture.** PipeWire and DXGI only deliver a frame when something
changed; the loop doesn't keep copying a still screen. On X11/GDI (polling), a
`memcmp` against the previous frame avoids encoding a repeated frame.

**Shared thread pool** (`sync.pool`): scaling, color conversion and conversion
back run in parallel stripes of lines. The encoder uses openh264's own threads
(one slice per core).

**Vectorized color conversion** (`@Vector(16, i32)`): 16 pixels per iteration, 2
lines at a time to compute the 2×2 chroma in the same pass.

**Zero copy in the relay.** The server builds the forwarded frame once and
queues the same buffer (with reference counting) for everyone watching; each
writer encrypts with its own connection key when sending.

**Delay never accumulates — not even inside a tunnel.** Every frame is
acknowledged (server → streamer, viewer → server), so both sides know how much
delay has accumulated along the whole path, including in buffers TCP can't see
(ngrok, bore...). Details and numbers in
[PROTOCOL.md](PROTOCOL.md#4-end-to-end-delay-control).
1. *Streamer:* delay starting to grow → rate drops a little; really late → skip a
   frame and the rate drops 25%; slack → climb fast to near where it had trouble
   and then only probe slowly. A big IDR doesn't count.
2. *Server:* a viewer accumulating more than 500 ms loses the pending frames,
   waits for what already went out to arrive and restarts from an IDR; lagging
   without draining, the server asks the streamer for a lower rate right away
   (down to half, if it's one viewer among several; as much as needed, if it's
   the majority).
3. *Viewer:* if decode falls 150 ms behind, it throws the queue away and asks for
   an IDR.

`zig build loadtest` tests this with viewers on a slow link, a slow majority and
the streamer behind a tunnel with an unbounded buffer.

**A slow viewer doesn't drag the room's quality down.** The streamer encodes with
two temporal layers: one frame yes, one no, nobody uses it as reference (in
openh264 with `iTemporalLayerNum`; in NVENC by deciding each frame's type and
marking `refPicFlag`, which works on any GPU generation). The server recognizes
those frames by the "skippable" bit and, for whoever is lagging as the minority
(or with the decoder behind), sends only the reference ones: 15 fps instead of
30, ~half the bandwidth and decode, without touching those who are keeping up. In
`zig build loadtest -- 8 60 1`: the room's bitrate stays at ~89% of the target
(before it fell to 50%) and the slow one keeps up with ~90 ms of delay (before
~360 ms). With text, NVENC spends ~3x more bits with two layers (measured with
`TELINHA_BENCH_CAMADAS=1/2`), so in that case it stays at one — and the server
goes back to the old way (room bitrate and restart by IDR).

**Viewers barely use the CPU.** With NVIDIA, NVDEC decodes (with Intel/AMD on
Linux, VA-API, which gives the same picture bit for bit as openh264 and ffmpeg —
`zig build test` checks it); in any case the decode thread hands over the YUV
planes (1.5 bytes/pixel) and a shader converts the color right on the GPU.
Without a shader (old OpenGL), the CPU converts in parallel, as before.

**No hidden delay in the decoder.** The openh264 decoder holds one frame in
Main/High profiles thinking there might be B-frames; since there never are,
`codec.zig` asks it to release immediately (`FlushFrame`). That way NVENC uses
High + CABAC + 8x8 transform (much sharper text at the same bitrate) and openh264
stays on Baseline; both come out in the same call.

**Sharp IDR.** The 1-frame VBV (minimum latency) made NVENC send the full frame —
the one that goes out when someone joins the room — almost at the maximum QP, and
the screen stayed blurry until the following frames refined it. On an IDR the VBV
grows to 10 frames and goes back to normal right after: on a 1080p code screen
the IDR goes from 34 dB to 45 dB, with ~60 KB more. The delay control treats a big
IDR as expected, without lowering quality.

**Wayland capture through DMA-BUF.** The portal delivers each frame in a GPU
buffer; telinha imports it with EGL (loaded at runtime) and reads it on its own
thread. With shared memory, whoever reads the picture back to RAM is the
compositor, inside the render loop — on every frame, the mouse and the screen
animations of whoever is streaming stuttered slightly. The fps limit goes in the
negotiation's `maxFramerate` (what the Hyprland portal uses to decide how many
times to copy the screen). If the import fails, the stream is renegotiated to
shared memory (32, 24 or 10 bits per channel, converted).

**Cursor on Hyprland.** Asking for the embedded cursor at the portal makes
Hyprland switch to the software cursor during capture (the mouse gets tied to
rendering). telinha captures without the cursor, gets the position through
Hyprland's IPC and draws the arrow into the frame.

**Sharing one window on Windows.** Besides the whole monitor (DXGI), you can send
just one window: Windows.Graphics.Capture (Windows 10 1903+; the window can be
covered by others). There is no C header for WinRT in MinGW, so the interfaces are
declared by hand in `capture_win.c` (vtables in SDK order, GUIDs checked against
the IDLs), with `combase.dll`/`d3d11.dll` loaded at runtime. Without that (old
Windows, wine), it falls back to `PrintWindow`.

**Camera.** Each person can send the webcam along with the screen (another
stream, same pipeline). On Linux through PipeWire (webcams are WirePlumber
Video/Source nodes; YUYV, NV12, I420, RGB, and MJPEG decoded with libturbojpeg
loaded at runtime); on Windows through Media Foundation (`IMFSourceReader`
converting to RGB32, DLLs loaded at runtime: the .exe even opens on Windows N,
just without a camera). Switching camera or resolution (480p/720p/1080p) doesn't
drop viewers.

**Several paths to the same room.** The invite gathers every address the room has
(local network, port opened on the router, global IPv6, typed tunnel, public
link) and `connect.zig` tries them all almost together: the first in the list
goes ahead and the others 250 ms after one another; the first one that answers
the handshake as a telinha room on the same version wins. Whoever has IPv6 gets
in directly; whoever doesn't falls back to the public link by itself. Details in
[PROTOCOL.md](PROTOCOL.md#invite-and-several-paths).

**Reconnection.** A network drop after joining (and not a kick/wrong
password/closed room — any `denied`) triggers automatic attempts with growing
waits; when it comes back, the stream restarts and the streams you were watching
return to the screen (looked up by name, since the ids change if the server
restarted).

**Audio.** The streamer captures the computer's sound **without what telinha
itself plays**: on Windows, WASAPI loopback excluding the process; on Linux,
telinha creates an input in PipeWire that the session manager doesn't connect to
anything and connects to it the output of each application playing sound, except
those of its own process (the same trick as venmic/Vesktop; the PID comes from
the node's full properties). Without PipeWire, it falls back to the default
output monitor, and then what you're watching goes mute while you stream audio.
10 ms Opus packets with DTX (silence barely spends bandwidth). Viewers keep 50 ms
per stream before playing, skip ahead if the delay passes 200 ms and sum
everything into a single output. `zig build audiotest` checks that the app's own
sound doesn't get into the capture.

**Voice.** Mono microphone at 48 kHz in 10 ms blocks → echo cancellation →
RNNoise (noise suppression, and its voice probability opens the "gate": opens
above the sensitivity, stays open 250 ms after the last syllable) → Opus VOIP,
20 ms, ~40 kbit/s. With the gate closed no packet goes out. On the server, voice
goes to everyone except the speaker and those deafened, jumping the queue
(conversation doesn't wait behind video); on the other side, one ring per person
in the same mixer as the streams, with per-person volume. The microphone only
opens when you turn it on (the system microphone indicator goes dark when you
turn it off). `zig build voicebot` joins a room and "speaks" synthetic syllables
to test.

**Echo cancellation.** With speakers instead of a headset, the microphone picks
up the others' voice again (and the sound of the streams you're watching). The
mixer keeps what it just played in a reference ring, and SpeexDSP's adaptive
filter (MDF, 100 ms tail) plus suppression of the leftover echo take that out of
the microphone before RNNoise. The hard part isn't the filter, it's feeding it
right:

1. *The reference has to arrive before the echo* (the filter is causal) and the
   echo has to fall inside the tail. A delay detector correlates the energy
   envelopes (1 ms per point, from −30 to +500 ms) of the microphone and the
   reference — an envelope doesn't have the ambiguity of voice pitch, which is
   periodic — and, if the echo is outside 1–40 ms, it delays or advances the
   reference so it lands at 15 ms. That's what makes a Bluetooth speaker
   (150–250 ms of delay) work.
2. *The ring doesn't move by itself*: every adjustment forces the filter to
   relearn, and the minimum level is misleading (with big blocks on both sides —
   900 × 1200 samples on PipeWire, for example — the real valley barely shows).
   It only adds 5 ms of slack when it runs dry (which happens as soon as the
   output starts playing).
3. *Different clocks* (USB × onboard card, up to ~100 ppm): left loose, the echo
   "slides" relative to the reference and the filter, chasing it, loses about 15
   dB. The drift is measured by regression (how much the output produced × how
   much the microphone consumed, last minute; only valid past 3σ) and the
   reference is resampled at that ratio.
4. *The leftover echo still looks like voice*, and RNNoise doesn't care about
   volume: with the speaker playing (or up to 120 ms after — the echo arrives late
   and reverberates), a block in which the canceller removed more than 6 dB
   doesn't count as voice (talking at the same time, your voice isn't cancelled
   and the output stays close to the input), and the gate only opens after 30 ms
   of continuous voice.
5. SpeexDSP's preprocess only applies residual echo suppression with "denoise"
   on; it stays on with 0 dB of noise suppression (noise is RNNoise's job).
6. *Headset* (the most common case): with no echo at all, the canceller only gets
   in the way — it ate ~1 dB of your voice when both talk at the same time. After
   1 min of speech from the other side with no echo (the detector finds no
   correlation *and* the canceller isn't removing anything — with speakers, in the
   moments when only the other side speaks it does, and the count starts over),
   it steps aside; echo shows up (headset taken off), it comes back right away.

Tests: simulation (1024 × 441 sample blocks, delay in the callbacks, drift): ~35
dB with the same clock, ~33 dB with 120 ppm (without compensating, ~19); echo at
220 ms found and compensated (~20 dB). End to end, in an isolated PipeWire with
the output going back whole into the "microphone" (`voicebot --ouvinte`): without
cancellation, 440 echo packets leak in 12 s of speech from the other side; with
it, 68, all in the first 2 seconds (then 21–32 dB, gate closed). With a 200 ms
`pw-loopback` in the path (Bluetooth): without cancellation, 523 packets; with
it, the detector finds ~215 ms, and 139 leak in the first 5 s (measuring the
delay + the filter relearning), then nothing.

**A UI that sleeps.** The loop uses `glfwWaitEventsTimeout`; network and decode
threads wake the UI with `glfwPostEmptyEvent` when there is a new frame. With no
stream, the app barely uses CPU.

**Clips and recording, without re-encoding.** Viewers keep the H.264 and Opus as
they arrive; streamers keep what they encode (`clip.zig`). A clip can only start
on an IDR, so the buffer keeps from the newest IDR that still covers 30 s (cap of
160 MiB per stream); with clips on, `watch` carries the clips option and the
server asks for an IDR every 20 s, so 30–50 s stay in memory. Saving runs on a
separate thread and writes a normal MP4 with the index (`moov`) at the start —
plays anywhere. Recording starts at the moment of the click: the app asks for an
IDR (`keyreq` with reason "recording", which doesn't interfere with the delay
control) and `mp4.Recorder` opens on the first one that arrives, writing a
fragmented MP4 (`moov` without samples + `moof`/`mdat` every ~2 s): if the app
crashes midway, what was already recorded plays. Video in avc1 with per-frame
duration (the screen only sends when it changes), Opus in `dOps`, silence gaps
become empty packets. If the resolution changes, the recording closes. Files go
to Videos/telinha (`XDG_VIDEOS_DIR`; on Windows the user folder in UTF-16,
accents accepted), or to `TELINHA_PASTA_CLIPES`.

**Floating window.** A stream can go to a little window on top of the others
(`pip.zig`): second GLFW window with the OpenGL context shared with the main one
(draws the same video texture, without a copy) and its own ImGui context (the
GLFW backend sends each window's events to its context; each context loads its
own fonts). It closes by itself when the stream ends.

**Notifications.** With telinha in the background (chat, someone live, someone
joined; at most one every 2 s): on Linux, `Notify` from
`org.freedesktop.Notifications` through GDBus, without waiting for a reply (the UI
doesn't freeze, even with no notification service); on Windows, tray icon balloon
and the window blinking in the taskbar.

**Leaving without freezing.** Closing the window hides it right away; then the app
tells the room and saves the settings, and exits with `sync.hardExit` (`_exit` /
`TerminateProcess`), without the library destructors: NVDEC's (libnvcuvid) and
PipeWire's froze waiting for internal threads and the process stayed alive. If
cleanup freezes, a 4 s deadline exits anyway.

**Interface test mode.** With `TELINHA_QA=folder`, ImGui's test hooks
(`IMGUI_ENABLE_TEST_ENGINE`, in `qa_hooks.cpp`) keep each item's rectangle, label
and state, and every ~80 ms the app writes `items.tsv` (where each button is) and
`state.json` (the app state) into that folder. `tools/qa/` runs the app on an
Xvfb, really clicks the buttons with XTest and checks the state — with no real
screen, speakers or microphone (private PipeWire and D-Bus), with a fake UPnP
router and bore tunnel; it also runs the `.exe` on wine. Outside that mode the
hooks aren't even called.

## Threads of a typical room (3 people, 1 streaming)

- Streamer: UI, capture/encode (again for the camera, if on), openh264 threads, reader, writer, UDP, ping, pool.
- Server (in the host's app or dedicated): accept + reader/writer per person, one UDP thread for everyone, clock.
- Each viewer: UI, reader, writer, UDP, ping, decode per stream, pool.
- Sending an image in the chat: one thread while it reads and encodes. Version check: one thread on startup.
- On join: one thread per invite path, only during the race.
- Saving a clip: one thread while it writes the file.

## Lifecycle and memory

Objects shared between threads (`Client`, `View`, `Sharer`, server connections,
messages) use atomic reference counting; whoever releases the last reference
frees it. The UI never frees something a thread still uses: it asks it to stop
(`shutdown`/`close`) and releases its own reference.
