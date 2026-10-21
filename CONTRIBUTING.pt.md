# Contribuindo

<sub>[🇺🇸 English](CONTRIBUTING.md) · [🇧🇷 Português](CONTRIBUTING.pt.md)</sub>

## Ambiente

- Zig **0.16.0** exatamente (a std muda bastante entre versões).
- Linux: as libs listadas no README.pt.md (seção "Compilar"). Windows é cross-compilado do Linux (`zig build` gera o `.exe`).
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
| `zig build voicebot -- host:porta Ouvinte 20 --ouvinte "Monitor of X"` | cancelamento de eco de ponta a ponta: o monitor da saída vira "microfone" (o som tocado volta inteiro); conta o eco que vazou pra sala, segundo a segundo |

O UPnP é testado contra um roteador de mentira (nos testes de integração); pra
testar na interface sem mexer no seu roteador de verdade, aponte a descoberta
pra um roteador de mentira local com `TELINHA_UPNP_SSDP=127.0.0.1:PORTA`.

A captura no Wayland (portal + PipeWire) dá pra testar inteira sem mexer na sua
sessão: um sway headless (`WLR_BACKENDS=headless`) + `xdg-desktop-portal-hyprland`
com `custom_picker_binary` que imprime `[SELECTION]r/screen:HEADLESS-1`, e D-Bus,
PipeWire e WirePlumber próprios (com os monitores de áudio/bluetooth/câmera
desligados) num `XDG_RUNTIME_DIR` separado. O mesmo PipeWire isolado, com uma
saída nula (`support.null-audio-sink`), serve pro teste de eco: nada toca na
sua caixa nem abre o seu microfone (o robô que fala roda com `TELINHA_SEM_SOM=1`,
senão o som dele também volta pro "microfone" do ouvinte).

## Testes de interface (QA)

`python3 tools/qa/run_qa.py` (ou `run_qa.py camera zoom` pra só alguns; `-l`
lista) sobe instâncias do app em telas virtuais escondidas (Xvfb, `:91`–`:96`),
clica nos botões com o XTest e confere o estado. Com `TELINHA_QA=pasta` o app
escreve, a cada ~80 ms, `items.tsv` (todo item do ImGui na tela: rótulo/`##id`,
retângulo, janela) e `state.json` (tela, sala, membros, transmissões, chat,
configurações...). Os ganchos são os do *test engine* do Dear ImGui
(`src/c/qa_hooks.cpp`); combo não registra rótulo sozinho — use o `beginCombo`
do `ui.zig`.

Precisa de `Xvfb`, `python-xlib`, PipeWire + WirePlumber (cada teste com som
sobe os seus num `XDG_RUNTIME_DIR` próprio, com saída nula, microfone e câmera
de mentira) e `ffprobe` (clipes). Os testes do `.exe` usam
`QA_WINEPREFIX=pasta` (um prefixo do wine só pros testes; o harness só mata o
`wineserver` dele). Nada aparece na sua tela, toca na sua caixa, abre seu
microfone/câmera, mexe no seu roteador (UPnP e bore são de mentira) ou grava na
sua pasta de vídeos.

Variáveis úteis pra testar: `TELINHA_SEM_UDP=1` (só TCP), `TELINHA_UDP_PERDA=5`
(joga fora 5% dos datagramas que manda), `TELINHA_SEM_HEVC=1`,
`TELINHA_SEM_NVENC/NVDEC/MF/VAAPI=1`, `TELINHA_SEM_HWDEC_ALT=1` (sem decoder de
placa que não seja NVIDIA), `TELINHA_ATUALIZACAO_URL=http://…` (GitHub de
mentira), `TELINHA_VERSAO_TESTE=9.9.9` (finge outra versão na sala),
`TELINHA_GOFILE_URL=http://…` (gofile de mentira pro envio do log de depuração;
`tools/qa/mockupload.py` faz o papel do gofile e do webhook),
`TELINHA_ENCODE_LENTO=ms` (encoder de mentira lento, pra qualidade automática),
`TELINHA_TESTE_TRAVAR=1` ou `=panic` (derruba o app de propósito, pro relatório de travamento),
`TELINHA_PASTA_CONFIG`/`TELINHA_PASTA_CLIPES`. O build aceita `-Drepo=dono/nome`
(o CI passa) pra checar versão nova no GitHub.

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
- Mudou o protocolo? Suba `proto.version` e atualize `docs/PROTOCOL.md` e `docs/PROTOCOL.pt.md`.

## Soltando uma versão

1. Suba a versão em `build.zig.zon` (`.version`) e escreva a seção nos dois changelogs (`CHANGELOG.md` em inglês e `CHANGELOG.pt.md`).
   As notas do release saem dessa seção do `CHANGELOG.md` (`tools/release_notes.sh`): o que vem
   antes de `<!-- detalhes -->` aparece aberto (os destaques), o resto fica num "Full changelog" que abre com um clique.
2. Commit, depois a tag com o mesmo número:

   ```sh
   git tag v3.1.0
   git push origin main v3.1.0
   ```

3. O CI (`.github/workflows/ci.yml`) roda os testes, compila e publica nos Releases:
   `.exe` do Windows, binário Linux (glibc 2.31, roda em distro antiga), servidor
   x86_64 e aarch64, símbolos (`telinha-simbolos.tar.gz`) e `SHA256SUMS`. Se a tag
   não bater com o `build.zig.zon`, ou se o binário Linux exigir glibc mais nova
   que 2.31, o CI falha antes de publicar.

O build Linux de release dá pra reproduzir localmente:

```sh
zig build -Dnative-only -Dtarget=x86_64-linux-gnu.2.31 -Dcpu=x86_64_v2 --prefix linux-out
```

O `.zig-cache` cresce sem limite (cada variação de build fica guardada); apagar a
pasta é seguro, o próximo build refaz o que precisar.
