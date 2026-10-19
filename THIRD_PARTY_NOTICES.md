# Componentes de terceiros

O telinha é MIT (ver [LICENSE](LICENSE)). Ele usa estes projetos:

| Projeto | Uso | Licença | Onde |
|---|---|---|---|
| [openh264](https://github.com/cisco/openh264) 2.6.0 | codec H.264 (compilado do código-fonte) | BSD 2-Clause | baixado pelo `build.zig.zon` |
| [Dear ImGui](https://github.com/ocornut/imgui) 1.93 | interface | MIT | baixado pelo `build.zig.zon` |
| [cimgui](https://github.com/cimgui/cimgui) | binding C do Dear ImGui | MIT | baixado pelo `build.zig.zon` |
| [GLFW](https://www.glfw.org) 3.5.1 | janela/OpenGL (compilado no Windows; biblioteca do sistema no Linux) | zlib | baixado pelo `build.zig.zon` |
| [Opus](https://opus-codec.org) 1.6.1 | codec de áudio | BSD 3-Clause | baixado pelo `build.zig.zon` |
| [miniaudio](https://miniaud.io) 0.11.25 | captura e saída de áudio | MIT-0 / domínio público | baixado pelo `build.zig.zon` |
| [RNNoise](https://gitlab.xiph.org/xiph/rnnoise) 0.2 | supressão de ruído e detecção de voz do microfone | BSD 3-Clause | baixado pelo `build.zig.zon` |
| [SpeexDSP](https://gitlab.xiph.org/xiph/speexdsp) 1.2.1 | cancelamento de eco do microfone | BSD 3-Clause | baixado pelo `build.zig.zon` |
| [stb_image](https://github.com/nothings/stb) 2.30 | lê a imagem (PNG/JPEG/GIF/BMP) que você manda no chat — só no seu PC; pela rede ela vai como um quadro H.264 | MIT / domínio público | baixado pelo `build.zig.zon` |
| [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers) 11.1 | headers do NVENC/NVDEC (as libs vêm do driver) | MIT | baixado pelo `build.zig.zon` |
| [libva](https://github.com/intel/libva) 2.22 | headers do VA-API (a libva e o driver vêm do sistema, carregados em runtime) | MIT | baixado pelo `build.zig.zon` |
| [NASM](https://www.nasm.us) 2.16.03 | só no build: monta o assembly SIMD do openh264 | BSD 2-Clause | baixado pelo `build.zig.zon` |
| [Inter](https://rsms.me/inter/) | fonte da interface | SIL Open Font License 1.1 | `src/assets/Inter-*.ttf` |
| [Font Awesome Free](https://fontawesome.com) 6.7 | ícones | fonte: SIL OFL 1.1; ícones: CC BY 4.0 | `src/assets/fa-solid-900.ttf` |

No Linux o app também usa bibliotecas do sistema: libportal (LGPL-3.0), PipeWire
(MIT), Xlib (MIT) e o GLFW da distro.

## Sobre patentes do H.264

O H.264 é coberto por patentes em alguns países. A Cisco paga os royalties só
dos **binários oficiais** do openh264 baixados do site dela; o telinha compila o
openh264 a partir do código-fonte, então essa cobertura não se aplica. Pra uso
pessoal isso raramente importa, mas se você for distribuir o telinha
comercialmente, se informe sobre a situação no seu país.
