# Contributing

<sub>[🇺🇸 English](CONTRIBUTING.md) · [🇧🇷 Português](CONTRIBUTING.pt.md)</sub>

## Environment

- Zig **0.16.0** exactly (the std changes a lot between versions).
- Linux: the libs listed in README.md (section "Building from source"). Windows is cross-compiled from Linux (`zig build` produces the `.exe`).
- Optional: `nasm` on the system (otherwise the build compiles one).

## Before sending a PR

```sh
zig fmt src build.zig tools
zig build test --summary all
zig build -Dcpu=x86_64_v2      # makes sure Linux, Windows and the server build
```

Touched the video pipeline? Run `zig build bench` before and after and put the numbers in the PR
(`TELINHA_BENCH_QUALIDADE=1` also measures quality, in PSNR).

## Test tools

| command | what it tests |
|---|---|
| `zig build loadtest -- 8 40 1` | server under load: normal + slow viewers, delay and IDRs |
| `zig build loadtest -- 4 40 0 2000` | streamer behind a bad tunnel (unbounded buffer, 2 Mbit/s) |
| `zig build captest -- 10 30 frame.ppm` | screen capture (method, format, real fps, saves a frame) |
| `zig build audiotest` | computer sound capture (the app's own sound must not get in) |
| `zig build voicebot -- host:port name` | a bot joins the room and "speaks" synthetic syllables (voice without a microphone) |
| `zig build voicebot -- host:port Listener 20 --ouvinte "Monitor of X"` | end-to-end echo cancellation: the output monitor becomes the "microphone" (the sound played comes back whole); counts the echo that leaked into the room, second by second |

UPnP is tested against a fake router (in the integration tests); to test it in
the interface without touching your real router, point discovery at a local
fake router with `TELINHA_UPNP_SSDP=127.0.0.1:PORT`.

Wayland capture (portal + PipeWire) can be tested in full without touching your
session: a headless sway (`WLR_BACKENDS=headless`) + `xdg-desktop-portal-hyprland`
with a `custom_picker_binary` that prints `[SELECTION]r/screen:HEADLESS-1`, plus
D-Bus, PipeWire and WirePlumber of their own (with the audio/bluetooth/camera
monitors off) in a separate `XDG_RUNTIME_DIR`. The same isolated PipeWire, with
a null sink (`support.null-audio-sink`), serves the echo test: nothing plays on
your speakers or opens your microphone (the speaking robot runs with
`TELINHA_SEM_SOM=1`, otherwise its sound comes back into the listener's
"microphone" too).

## Interface tests (QA)

`python3 tools/qa/run_qa.py` (or `run_qa.py camera zoom` for just a few; `-l`
lists them) starts instances of the app on hidden virtual screens (Xvfb, `:91`–`:96`),
clicks the buttons with XTest and checks the state. With `TELINHA_QA=folder` the
app writes, every ~80 ms, `items.tsv` (every ImGui item on screen: label/`##id`,
rectangle, window) and `state.json` (screen, room, members, streams, chat,
settings...). The hooks are Dear ImGui's *test engine* ones
(`src/c/qa_hooks.cpp`); a combo doesn't register a label by itself — use `ui.zig`'s
`beginCombo`.

You need `Xvfb`, `python-xlib`, PipeWire + WirePlumber (each test with sound
starts its own in a separate `XDG_RUNTIME_DIR`, with a null sink, a fake
microphone and camera) and `ffprobe` (clips). The `.exe` tests use
`QA_WINEPREFIX=folder` (a wine prefix just for the tests; the harness only kills
its own `wineserver`). Nothing shows up on your screen, plays on your speakers,
opens your microphone/camera, touches your router (UPnP and bore are fake) or
writes to your videos folder.

Useful variables for testing: `TELINHA_SEM_UDP=1` (TCP only), `TELINHA_UDP_PERDA=5`
(throws away 5% of the datagrams it sends), `TELINHA_SEM_HEVC=1`,
`TELINHA_SEM_NVENC/NVDEC/MF/VAAPI=1`, `TELINHA_SEM_HWDEC_ALT=1` (no GPU decoder
other than NVIDIA), `TELINHA_ATUALIZACAO_URL=http://…` (fake GitHub),
`TELINHA_VERSAO_TESTE=9.9.9` (pretends to be another version in the room),
`TELINHA_GOFILE_URL=http://…` (fake gofile for the debug log upload;
`tools/qa/mockupload.py` plays the part of gofile and the webhook),
`TELINHA_ENCODE_LENTO=ms` (fake slow encoder, for automatic quality),
`TELINHA_TESTE_TRAVAR=1` or `=panic` (crashes the app on purpose, for the crash
report), `TELINHA_PASTA_CONFIG`/`TELINHA_PASTA_CLIPES`. The build accepts
`-Drepo=owner/name` (the CI passes it) to check for a new version on GitHub.

## Testing by hand without messing up your screen

You can start several instances on virtual screens (Xvfb), each with its own
config folder:

```sh
Xvfb :99 -screen 0 1600x900x24 &
DISPLAY=:99 XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= XDG_CONFIG_HOME=/tmp/a \
  zig-out/bin/telinha --janela 0,0,800,450 --nome A --criar 7777 --transmitir --estatisticas &
DISPLAY=:99 XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= XDG_CONFIG_HOME=/tmp/b \
  zig-out/bin/telinha --janela 800,0,800,450 --nome B --entrar 127.0.0.1:7777 --assistir --estatisticas &
```

The `.exe` runs on wine the same way (without NVENC/NVDEC, it falls back to
openh264). On some wine versions `wineserver` sometimes dies on its own with
`sock_poll_event: Assertion ... failed` — that's a wine bug (it doesn't happen
on Windows); just run it again.

## Style

- Code and comments in Portuguese, short, explaining the *why*.
- No allocation in the video hot path if a buffer can be reused.
- Objects shared between threads use reference counting; the UI never frees something another thread still uses.
- Changed the protocol? Bump `proto.version` and update `docs/PROTOCOL.md`.

## Cutting a release

1. Bump the version in `build.zig.zon` (`.version`) and `src/proto.zig` (`app_version`), and write the section in both changelogs (`CHANGELOG.md` and the Portuguese `CHANGELOG.pt.md`).
   The release notes come from that `CHANGELOG.md` section (`tools/release_notes.sh`): whatever is
   before `<!-- detalhes -->` is shown open (the highlights), the rest goes into a collapsible "Full changelog".
2. Commit, then tag with the same number:

   ```sh
   git tag v3.2.0
   git push origin main v3.2.0
   ```

3. CI (`.github/workflows/ci.yml`) runs the tests, builds and publishes to Releases:
   the Windows `.exe`, the Linux binary (glibc 2.31, runs on old distros), the
   x86_64 and aarch64 server, symbols (`telinha-simbolos.tar.gz`) and `SHA256SUMS`.
   If the tag doesn't match `build.zig.zon`, or the Linux binary requires a glibc
   newer than 2.31, CI fails before publishing.
4. **Signature**: CI signs `SHA256SUMS` (`SHA256SUMS.sig`) with the key in the
   `TELINHA_ASSINATURA` secret (Ed25519, PEM). The app's updater only installs what
   carries that signature, checked against the public key in `src/update.zig`
   (`release_key`). A tag without the secret, or with another key, fails CI. Keep a
   copy of the private key outside GitHub: lose it and installed versions can no
   longer update themselves (people would download once by hand, with the new key
   in the app). To rotate: `openssl genpkey -algorithm ed25519 -out key.pem`, the
   public key (`openssl pkey -in key.pem -pubout -outform DER | tail -c 32 | od -An
   -tx1 | tr -d ' \n'`) into `release_key`, and
   `gh secret set TELINHA_ASSINATURA < key.pem`.

You can reproduce the Linux release build locally:

```sh
zig build -Dnative-only -Dtarget=x86_64-linux-gnu.2.31 -Dcpu=x86_64_v2 --prefix linux-out
```

`.zig-cache` grows without limit (every build variation is kept); deleting the
folder is safe, the next build redoes whatever it needs.
