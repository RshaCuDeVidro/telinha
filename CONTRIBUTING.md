# Contribuindo

## Ambiente

- Zig **0.16.0** exatamente (a std muda bastante entre versões).
- Linux: as libs listadas no README. Windows é cross-compilado do Linux (`zig build` gera o `.exe`).
- Opcional: `nasm` no sistema (senão o build compila um).

## Antes de mandar um PR

```sh
zig fmt src build.zig tools
zig build test --summary all
zig build -Dcpu=x86_64_v2      # garante que Linux, Windows e servidor compilam
```

Mexeu no pipeline de vídeo? Rode `zig build bench` antes e depois e coloque os números no PR
(`TELINHA_BENCH_QUALIDADE=1` mede também a qualidade, em PSNR).

## Ferramentas de teste

| comando | o que testa |
|---|---|
| `zig build loadtest -- 8 40 1` | servidor sob carga: espectadores normais + lentos, atraso e IDRs |
| `zig build loadtest -- 4 40 0 2000` | transmissor atrás de um túnel ruim (buffer sem limite, 2 Mbit/s) |
| `zig build captest -- 10 30 quadro.ppm` | captura de tela (método, formato, fps real, salva um quadro) |
| `zig build audiotest` | captura do som do computador (o som do próprio app não pode entrar) |
| `zig build voicebot -- host:porta nome` | um robô entra na sala e "fala" sílabas sintéticas (voz sem microfone) |

A captura no Wayland (portal + PipeWire) dá pra testar inteira sem mexer na sua
sessão: um sway headless (`WLR_BACKENDS=headless`) + `xdg-desktop-portal-hyprland`
com `custom_picker_binary` que imprime `[SELECTION]r/screen:HEADLESS-1`, e D-Bus,
PipeWire e WirePlumber próprios (com os monitores de áudio/bluetooth/câmera
desligados) num `XDG_RUNTIME_DIR` separado.

## Testando na mão sem bagunçar sua tela

Dá pra subir várias instâncias em telas virtuais (Xvfb), cada uma com sua pasta de configuração:

```sh
Xvfb :99 -screen 0 1600x900x24 &
DISPLAY=:99 XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= XDG_CONFIG_HOME=/tmp/a \
  zig-out/bin/telinha --janela 0,0,800,450 --nome A --criar 7777 --transmitir --estatisticas &
DISPLAY=:99 XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= XDG_CONFIG_HOME=/tmp/b \
  zig-out/bin/telinha --janela 800,0,800,450 --nome B --entrar 127.0.0.1:7777 --assistir --estatisticas &
```

O `.exe` roda no wine do mesmo jeito (sem NVENC/NVDEC, ele cai pro openh264).
O `wineserver` de algumas versões do wine às vezes cai sozinho com
`sock_poll_event: Assertion ... failed` — é bug do wine (não acontece no
Windows); é só rodar de novo.

## Estilo

- Código e comentários em português, curtos, explicando o *porquê*.
- Nada de alocação no caminho quente do vídeo se der pra reaproveitar buffer.
- Objetos compartilhados entre threads usam contagem de referências; a UI nunca libera algo que outra thread ainda usa.
- Mudou o protocolo? Suba `proto.version` e atualize `docs/PROTOCOL.md`.
