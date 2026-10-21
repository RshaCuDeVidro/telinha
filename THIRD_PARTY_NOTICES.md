# Third-party components

<sub>[🇺🇸 English](THIRD_PARTY_NOTICES.md) · [🇧🇷 Português](THIRD_PARTY_NOTICES.pt.md)</sub>

telinha is MIT (see [LICENSE](LICENSE)). It uses these projects:

| Project | Use | License | Where |
|---|---|---|---|
| [openh264](https://github.com/cisco/openh264) 2.6.0 | H.264 codec (compiled from source) | BSD 2-Clause | fetched by `build.zig.zon` |
| [Dear ImGui](https://github.com/ocornut/imgui) 1.93 | interface | MIT | fetched by `build.zig.zon` |
| [cimgui](https://github.com/cimgui/cimgui) | C binding for Dear ImGui | MIT | fetched by `build.zig.zon` |
| [GLFW](https://www.glfw.org) 3.5.1 | window/OpenGL (compiled on Windows; system library on Linux) | zlib | fetched by `build.zig.zon` |
| [Opus](https://opus-codec.org) 1.6.1 | audio codec | BSD 3-Clause | fetched by `build.zig.zon` |
| [miniaudio](https://miniaud.io) 0.11.25 | audio capture and output | MIT-0 / public domain | fetched by `build.zig.zon` |
| [RNNoise](https://gitlab.xiph.org/xiph/rnnoise) 0.2 | noise suppression and microphone voice detection | BSD 3-Clause | fetched by `build.zig.zon` |
| [SpeexDSP](https://gitlab.xiph.org/xiph/speexdsp) 1.2.1 | microphone echo cancellation | BSD 3-Clause | fetched by `build.zig.zon` |
| [stb_image](https://github.com/nothings/stb) 2.30 | reads the image (PNG/JPEG/GIF/BMP) you send in the chat — only on your PC; over the network it travels as an H.264 frame | MIT / public domain | fetched by `build.zig.zon` |
| [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers) 11.1 | NVENC/NVDEC headers (the libs come from the driver) | MIT | fetched by `build.zig.zon` |
| [libva](https://github.com/intel/libva) 2.22 | VA-API headers (libva and the driver come from the system, loaded at runtime) | MIT | fetched by `build.zig.zon` |
| [FreeType](https://freetype.org) 2.13.3 | draws color emoji (the emoji font comes from the system) | FreeType License (FTL)¹ | fetched by `build.zig.zon` |
| [libpng](http://www.libpng.org/pub/png/libpng.html) 1.6.44 | reads the PNG emoji in the emoji font, for FreeType | PNG Reference Library License v2 | fetched by `build.zig.zon` |
| [zlib](https://zlib.net) 1.3.1 | decompression, for libpng | zlib | fetched by `build.zig.zon` |
| [NASM](https://www.nasm.us) 2.16.03 | build only: assembles the openh264 SIMD assembly | BSD 2-Clause | fetched by `build.zig.zon` |
| [Inter](https://rsms.me/inter/) | interface font | SIL Open Font License 1.1 | `src/assets/Inter-*.ttf` |
| [Fira Code](https://github.com/tonsky/FiraCode) | font of the pwnd themes (400/600/700 instances of the variable font, Latin alphabet only) | SIL Open Font License 1.1 | `src/assets/FiraCode-*.ttf` |
| [Font Awesome Free](https://fontawesome.com) 6.7 | icons | font: SIL OFL 1.1; icons: CC BY 4.0 | `src/assets/fa-solid-900.ttf` |

¹ Portions of this software are copyright © 2024 The FreeType Project
(www.freetype.org). All rights reserved.

On Linux the app also uses system libraries: libportal (LGPL-3.0), PipeWire
(MIT), Xlib (MIT) and the distro's GLFW.

## About H.264 patents

H.264 is covered by patents in some countries. Cisco pays the royalties only
for the **official binaries** of openh264 downloaded from its website; telinha
compiles openh264 from source, so that coverage does not apply. For personal
use this rarely matters, but if you are going to distribute telinha
commercially, look into the situation in your country.
