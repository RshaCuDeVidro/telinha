<p align="center">
  <img src="assets/icon.png" width="96" alt="telinha">
</p>

<h1 align="center">telinha</h1>

<p align="center">
  Compartilhamento de tela em grupo, com cara de Discord, pra Linux e Windows.<br>
  Várias pessoas na mesma sala, qualquer uma transmite, todo mundo assiste — com pouca latência.
</p>

<p align="center">
  <img src="docs/img/sala.jpg" alt="Sala com duas transmissões e chat" width="900">
</p>

## O que tem

- **Salas** — alguém cria (ou sobe um [servidor dedicado](docs/DEPLOY.md)), a galera entra com endereço + senha ou com um **convite** `telinha://…`.
- **Várias transmissões ao mesmo tempo**, em grade que se ajusta pra deixar os vídeos o maior possível; destaque, tela cheia e modo cinema.
- **Voz, tipo Discord**: microfone com cancelamento de eco (dá pra usar caixa de som em vez de fone), supressão de ruído (RNNoise: tira ventilador, teclado, chiado) e ativação por voz, em Opus. Bolinha verde em quem está falando, botão de microfone e de "surdo", volume da voz de cada pessoa (clique direito). A voz fura a fila: não espera atrás do vídeo.
- **Áudio do computador junto** (vídeo, jogo, música), em Opus com pouca latência, com volume e mudo por transmissão. O som que o próprio telinha toca nunca entra na captura (Windows: loopback excluindo o processo; Linux: cada aplicativo ligado direto na captura pelo grafo do PipeWire, menos o telinha) — sem eco, e você continua ouvindo o que assiste enquanto compartilha.
- **Chat**, lista de membros, quem está ao vivo, quem está assistindo quem, ping.
- **H.264 com pouca latência**: encode e decode na **placa de vídeo (NVIDIA NVENC/NVDEC)** quando tem, senão **openh264** com SIMD em várias threads. Só manda quadro quando a tela muda; a conversão de cor de quem assiste roda num shader na GPU.
- **Atraso controlado de ponta a ponta, até atrás de túnel**: cada quadro é confirmado, então o telinha mede o atraso real do caminho inteiro — inclusive dentro de ngrok/bore, que escondem o congestionamento. Se o upload não aguenta, a taxa cai e quadros são pulados em vez de acumular atraso; se um espectador não aguenta, ele recomeça de um quadro completo sem travar os outros, e a qualidade só cai pra todo mundo se a maioria estiver sofrendo.
- **Criptografia de ponta a ponta** entre cada pessoa e a sala (X25519 + ChaCha20-Poly1305); a senha da sala entra na derivação das chaves.
- **Reconexão automática**: se a internet oscilar ou o servidor reiniciar, o app volta sozinho, retoma a transmissão e volta a assistir quem estava assistindo.
- **Admin**: quem cria a sala ganha a coroa e pode expulsar gente.
- **Estatísticas ao vivo**: resolução, fps, banda e **atraso de ponta a ponta medido** (captura no transmissor → tela de quem assiste).
- **Captura nativa**: PipeWire + xdg-desktop-portal no Wayland (Hyprland, GNOME, KDE, Sway…) com **DMA-BUF** (o compositor copia a tela GPU→GPU, sem travar a própria renderização), X11, e DXGI Desktop Duplication no Windows. O compositor só copia a tela no fps que você escolheu, e no Hyprland o cursor é desenhado pelo telinha — o mouse não fica com lag enquanto você compartilha.
- **Windows**: um `.exe` só, sem instalar nada.

| | |
|---|---|
| <img src="docs/img/inicio.png" alt="Tela inicial"> | <img src="docs/img/compartilhar.png" alt="Compartilhar tela"> |

## Como usar

1. **Criar sala**: abre o telinha → *Criar sala* (porta padrão 7777, senha opcional).
2. **Galera de fora**: no card *Chamando a galera de fora*, clica em **Criar link público** → *Copiar convite* e manda pra galera. Não precisa instalar nada: o telinha abre um túnel pelo protocolo do [bore](https://github.com/ekzhang/bore) (bore.pub). O conteúdo continua cifrado de ponta a ponta — o túnel só vê bytes embaralhados — e sala pública sempre tem senha (se você não pôs, o telinha cria uma e já coloca no convite).
   Prefere outro túnel (ngrok, serveo, playit…)? Abre *Prefere seu próprio túnel?* no mesmo card. Na mesma rede (ou Tailscale/ZeroTier/Radmin) é só usar o IP. Tem VPS? Use o [servidor dedicado](docs/DEPLOY.md).
3. **Entrar**: *Entrar numa sala* → cola o convite (ou endereço + senha).
4. **Transmitir**: botão de tela no canto de baixo da barra lateral → escolhe resolução, fps, qualidade e tipo de conteúdo → *Ao vivo*. Dá pra mudar tudo com a transmissão rolando.
5. **Assistir**: clica em quem está ao vivo. **F11** tela cheia · **duplo clique** modo cinema · **Esc** sai.
6. **Falar**: botão de microfone no painel de baixo (ou **Ctrl+M**; **Ctrl+D** pra ficar surdo). Clique direito em alguém pra mudar o volume da voz dessa pessoa. Com caixa de som funciona (tem cancelamento de eco), mas fone de ouvido ainda é o melhor.

No Wayland o sistema pergunta qual tela/janela compartilhar na primeira vez e depois lembra.
No Windows, como o `.exe` não é assinado, o SmartScreen avisa: *Mais informações → Executar assim mesmo*.

## Desempenho

Medido num **Intel i5-2400S (2011, 4 núcleos)** com GTX 1050 Ti, 1080p, via `zig build bench`:

| | conversão de cor | encode | decode | banda (30 fps) |
|---|---|---|---|---|
| texto rolando — openh264 | 3,7 ms | 23 ms | 4 ms | ~200 KB/s |
| movimento — openh264 | 3,9 ms | 13 ms | 13 ms | ~730 KB/s (no teto de 6 Mbit/s) |
| texto rolando — **NVENC + NVDEC** | — (na GPU) | **7,5 ms** | **6 ms** | ~500 KB/s |
| movimento — **NVENC + NVDEC** | — (na GPU) | **8 ms** | **6 ms** | ~630 KB/s |

Qualidade numa tela de código de verdade em 1080p (`TELINHA_BENCH_QUALIDADE=1 zig build bench`, PSNR do brilho): NVENC **57 dB com 0,36 Mbit/s**, inclusive no quadro completo (IDR) que sai quando alguém entra na sala; openh264 58 dB com 0,44 Mbit/s.

Ponta a ponta, numa sala local com conteúdo pesado (tela inteira mudando a cada quadro): **30–50 fps em 1080p com 31–64 ms de atraso** usando NVENC/NVDEC. Em CPU moderna o openh264 sozinho já faz 1080p60.

## Compilar

Precisa do [Zig 0.16](https://ziglang.org/download/). As dependências de C/C++ (openh264, Dear ImGui, GLFW, NASM, headers do NVENC) são baixadas pelo próprio `zig build`.

No Linux, as bibliotecas do sistema pra interface e captura:

```sh
# Arch
sudo pacman -S glfw libportal pipewire libx11 libxext libxfixes
# Debian/Ubuntu
sudo apt install libglfw3-dev libgl-dev libportal-dev libpipewire-0.3-dev libx11-dev libxext-dev libxfixes-dev
```

```sh
zig build                       # app Linux + app Windows (.exe) + servidor dedicado
zig build run                   # roda o app
zig build test                  # testes (unidade + integração do servidor + codec)
zig build bench                 # benchmark do pipeline de vídeo
zig build loadtest -- 8 40 1    # carga: 8 espectadores + 1 em link de 2 Mbit/s, 40 s
zig build loadtest -- 4 40 0 2000  # transmissor atrás de um túnel ruim de 2 Mbit/s
zig build server -Dserver-only  # só o servidor (não baixa as dependências do app)
```

Saída em `zig-out/bin/`: `telinha`, `telinha.exe`, `telinha-server-x86_64`, `telinha-server-aarch64`.
Pra binários que rodam em qualquer CPU x86-64 (como no CI): `zig build -Dcpu=x86_64_v2`.

<details>
<summary>Linha de comando do app</summary>

```
--nome X              seu nome
--criar [porta]       cria uma sala
--entrar host:porta   entra numa sala (aceita convite telinha://…)
--senha X             senha da sala
--admin TOKEN         entra como admin num servidor dedicado
--publico             com --criar: já abre o link público
--transmitir          começa a transmitir assim que conectar
--assistir            assiste todo mundo que estiver ao vivo
--fps N --qualidade N --modo tela|jogo --software
--estatisticas        estatísticas sempre visíveis
```
`TELINHA_DEBUG=1` imprime o tempo de cada etapa do pipeline. `TELINHA_SEM_SHADER=1` força a conversão de cor na CPU; `TELINHA_CURSOR_EMBUTIDO=1` deixa o compositor desenhar o cursor (Hyprland); `TELINHA_SEM_DMABUF=1` captura por memória compartilhada em vez de DMA-BUF; `TELINHA_SEM_SOM=1` não toca o áudio recebido.

Se a captura não funcionar ou estiver lenta, `zig build captest` (ou `zig-out/tools/captest 10 30 quadro.ppm`) mostra o método, o formato, o fps real e salva um quadro.
</details>

## Documentação

- [Arquitetura](docs/ARCHITECTURE.md) — threads, pipeline, controle de banda, decisões de desempenho
- [Protocolo](docs/PROTOCOL.md) — handshake, criptografia, mensagens
- [Servidor dedicado / deploy](docs/DEPLOY.md) — binário estático, Docker, systemd
- [Contribuindo](CONTRIBUTING.md)

## Licença

MIT — ver [LICENSE](LICENSE). Componentes de terceiros e licenças em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
