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

Mexeu no pipeline de vídeo? Rode `zig build bench` antes e depois e coloque os números no PR.

## Testando na mão sem bagunçar sua tela

Dá pra subir várias instâncias em telas virtuais (Xvfb), cada uma com sua pasta de configuração:

```sh
Xvfb :99 -screen 0 1600x900x24 &
DISPLAY=:99 XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= XDG_CONFIG_HOME=/tmp/a \
  zig-out/bin/telinha --janela 0,0,800,450 --nome A --criar 7777 --transmitir --estatisticas &
DISPLAY=:99 XDG_SESSION_TYPE=x11 WAYLAND_DISPLAY= XDG_CONFIG_HOME=/tmp/b \
  zig-out/bin/telinha --janela 800,0,800,450 --nome B --entrar 127.0.0.1:7777 --assistir --estatisticas &
```

O `.exe` roda no wine do mesmo jeito (sem NVENC, ele cai pro openh264).

## Estilo

- Código e comentários em português, curtos, explicando o *porquê*.
- Nada de alocação no caminho quente do vídeo se der pra reaproveitar buffer.
- Objetos compartilhados entre threads usam contagem de referências; a UI nunca libera algo que outra thread ainda usa.
- Mudou o protocolo? Suba `proto.version` e atualize `docs/PROTOCOL.md`.
