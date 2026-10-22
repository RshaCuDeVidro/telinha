# Arquitetura

<sub>[🇺🇸 English](ARCHITECTURE.md) · [🇧🇷 Português](ARCHITECTURE.pt.md)</sub>

```
 transmissor                              servidor da sala                     espectadores
 ───────────                              ────────────────                     ────────────
 thread de captura                        por conexão:                         por transmissão assistida:
   tela/câmera (PipeWire/X11/DXGI/WGC)      thread leitora ──┐                   thread leitora (rede, confirma)
     │ acorda quando a tela muda            thread escritora ◄┤ fila própria       │
   escala (pool, por faixas)                                 │ (descarta se     fila (máx. 150 ms)
     │                                    frame recebido ────┘   atrasou)          │
   GPU: entrega o BGRX (troca ponteiro)     1 alocação, N referências            thread de decode
   software: BGRX → I420 (SIMD, pool)       só pra quem assiste                    │ H.264 → I420 (openh264)
     │  ─ 3 slots: o encoder pega sempre o quadro mais novo ─                      │ I420 → RGBA (SIMD, pool)
 thread de encode                                                                  ▼
   H.264: NVENC/MF (GPU) ou openh264 (CPU, fatias em threads)                   UI: sobe pra GPU, desenha
     │
   fila de envio ── controle de taxa ──► TCP + ChaCha20-Poly1305 ─────────────►
        ▲                                     │                                    │
        └──── ack de cada frame ──────────────┘ ◄──── ack de cada frame ───────────┘
```

A tela e a câmera de cada pessoa são duas transmissões independentes (um
`Sharer` e um stream cada, ver [PROTOCOL.md](PROTOCOL.pt.md)), com o mesmo
pipeline, o mesmo controle de taxa e confirmações separadas.

## Módulos

| arquivo | responsabilidade |
|---|---|
| `src/main.zig` | janela (GLFW), OpenGL, loop principal que dorme quando nada acontece; saída com `sync.hardExit` |
| `src/ui.zig` | toda a interface (Dear ImGui via cimgui) |
| `src/fonts.zig` | fontes embutidas (Inter + ícones); cada contexto do ImGui carrega as suas; a fonte de emoji colorida do sistema entra na primeira vez que aparece um emoji (desenhada pelo FreeType no `src/c/emoji_loader.cpp`) |
| `src/markdown.zig` | markdown do chat: separa blocos de código e trechos (código, negrito, itálico, link); quem desenha é a `ui.zig` |
| `src/known.zig` | identidades de servidor já vistas (`servidores.txt`) e a chave fixa da sala hospedada no app |
| `src/c/filepick.c` | seletor de arquivo do sistema (portal no Linux, `GetOpenFileNameW` no Windows) |
| `src/pip.zig` | janela flutuante: segunda janela do GLFW com contexto GL compartilhado e ImGui próprio |
| `src/client.zig` | conexão com a sala, estado (membros, chat, relógio), `View` = transmissão assistida |
| `src/connect.zig` | convite com vários endereços e a corrida entre eles (o primeiro que responder como sala ganha) |
| `src/sharer.zig` | thread de transmissão (tela ou câmera): captura → escala → encode → envio |
| `src/clip.zig` | últimos ~30 s de cada transmissão (clipe) e gravação em andamento; pasta dos vídeos |
| `src/mp4.zig` | escritor de MP4 (H.264 em avc1, HEVC em hvc1 ou AV1 em av01, + Opus, sem recodificar): clipe com `moov` no começo, gravação fragmentada |
| `src/udp.zig` | vídeo/som/voz por UDP: datagramas cifrados, pedaços, remontagem, NACK, ordem por transmissão, cadência |
| `src/update.zig` | versão nova: checagem da última release no GitHub (curl / WinHTTP), `SHA256SUMS` assinado (Ed25519, chave pública aqui), o "o que muda" e a instalação |
| `src/c/selfupdate.c` | atualização: caminho do executável, baixar pra arquivo, trocar o executável (rename atômico no Linux; `.old` no Windows) e abrir de novo |
| `src/changelog.zig` | o CHANGELOG em seções (o aviso de atualização, as novidades, o histórico em Sobre; os changelogs vão embutidos) |
| `src/chatimg.zig`, `src/chatsend.zig` | imagem no chat: reduz e vira um quadro H.264 (e volta); lê arquivo/área de transferência numa thread |
| `src/c/image.c` | stb_image (só arquivos/área de transferência locais) e a imagem copiada no Windows (PNG/DIB) |
| `src/c/audio_apps_win.c` | Windows: programas tocando som (sessões de áudio) |
| `src/c/httpget_win.c` | Windows: GET por WinHTTP (checagem de versão) |
| `src/ratectl.zig` | controle de taxa de bits pelo atraso de ponta a ponta |
| `src/server.zig` | servidor da sala (embutido no app ou no `telinha-server`) |
| `src/server_main.zig` | executável do servidor dedicado |
| `src/tunnel.zig` | link público: cliente do protocolo do bore; cada visitante vira uma conexão da sala |
| `src/upnp.zig` | porta aberta no roteador (UPnP IGD: SSDP + SOAP), com aviso de CGNAT; sem UPnP, cai pro `natpmp.zig` |
| `src/natpmp.zig` | porta aberta pelo NAT-PMP (RFC 6886) ou PCP (RFC 6887) no gateway padrão |
| `src/codec.zig` | wrapper do openh264 e do encoder em hardware + conversões de cor vetorizadas |
| `src/c/hwenc.c` | escolhe o encoder em hardware: NVENC → Media Foundation (Windows) ou VA-API (Linux) → nenhum (openh264) |
| `src/c/hwenc_nvenc.c` | encoder em hardware NVIDIA, H.264 e HEVC (API NVENC 11.1, carregada em runtime); compilado de novo com `NVENC_AV1` na API 12 pro AV1 (experimental, RTX 40+) |
| `src/c/hwenc_mf.c` | Windows: encoder H.264 em hardware de qualquer placa (MFT do Media Foundation: Intel, AMD, NVIDIA) |
| `src/c/hwdec.c` | escolhe o decoder em hardware: NVDEC → Media Foundation (Windows) ou VA-API (Linux) |
| `src/c/hwdec_nvdec.c` | decoder em hardware NVIDIA, H.264, HEVC e AV1 (NVDEC/nvcuvid, carregado em runtime) |
| `src/c/hwdec_mf.c` | Windows: decoder H.264 do Media Foundation com DXVA (qualquer placa), textura copiada pra memória |
| `src/c/hwva.c` | Linux: encoder e decoder H.264 pelo VA-API (Intel/AMD; libva carregada em runtime). O decoder faz a parte "de software" do H.264 (SPS/PPS, POC, referências, MMCO); o encoder se testa ao abrir (3 quadros decodificados pelo openh264) |
| `src/gl.zig` | texturas e conversão YUV→RGB num shader |
| `src/audio.zig` | áudio: Opus de quem transmite, anel anti-oscilação e mixer de quem assiste |
| `src/voice.zig` | voz da sala: microfone → cancelamento de eco → RNNoise → portão → Opus; voz de cada pessoa do outro lado |
| `src/aec.zig` | cancelamento de eco (SpeexDSP) com a saída do mixer como referência, compensando a deriva entre os relógios |
| `src/c/audio_pw.c` | Linux: som dos aplicativos pelo grafo do PipeWire, sem o próprio telinha (ou só de um programa: nome ou árvore de processos) |
| `src/c/audio.c` | captura do som do computador e saída (miniaudio) |
| `src/crypto.zig` | handshake X25519 e canal ChaCha20-Poly1305 |
| `src/proto.zig` | mensagens, filas de envio, framing, janela de confirmações (`AckWindow`) |
| `src/net.zig` | sockets (POSIX/Winsock), rota de quem conectou, endereços da máquina (IPv4 da rede, IPv6 globais) |
| `src/c/netaddr_win.c` | Windows: IPv6 globais da máquina (`GetAdaptersAddresses`) |
| `src/sync.zig` | mutex/condvar nativos, relógio, pool de threads, `hardExit` |
| `src/c/capture_linux.c` | Linux: portal + PipeWire (Wayland, DMA-BUF) ou XShm (X11) |
| `src/c/capture_win.c` | Windows: monitor por DXGI (GDI de reserva); uma janela por Windows.Graphics.Capture (PrintWindow de reserva) |
| `src/c/camera_linux.c`, `src/c/camera_win.c` | webcam: PipeWire (Linux) / Media Foundation (Windows), entregue em BGRX como a tela |
| `src/c/notify_linux.c`, `src/c/notify_win.c` | notificação do sistema: D-Bus (Linux) / balão da bandeja + janela piscando (Windows) |
| `src/qa.zig`, `src/c/qa_hooks.cpp` | modo de testes da interface (`TELINHA_QA`): ganchos do ImGui, `items.tsv` + `state.json` |
| `tools/qa/` | testes de interface: clica nos botões de verdade (XTest no Xvfb); roteador UPnP e túnel do bore de mentira |
| `src/tests.zig`, `src/integration_test.zig` | testes |
| `src/bench.zig` | benchmark do pipeline de vídeo |
| `src/loadtest.zig` | teste de carga do servidor (espectadores lentos, túnel ruim) |
| `src/captest.zig` | diagnóstico da captura de tela |

## Transporte: TCP pra tudo, UDP pro que tem pressa

A conexão é sempre TCP (handshake, chat, membros, confirmações, pedidos de
IDR). Se o caminho UDP abrir (ver `docs/PROTOCOL.pt.md` §2b), a escritora de
cada conexão (`proto.SendQueue.writerLoop`) manda quadro, áudio e voz por ele:
a mensagem é a mesma, só muda o caminho, e quem recebe entrega no mesmo
`handle` do TCP. Isso tira o bloqueio em fila do TCP (um pacote perdido
segurava a voz atrás de um quadro de vídeo, e perda no fim de uma rajada
custava ~200 ms de retransmissão por tempo) sem reescrever o resto: a fila,
o controle de taxa pelas confirmações e o afinamento de espectador lento
continuam iguais (a escritora cadencia o envio, então o que não saiu fica na
fila e conta como atraso, como antes). Perdeu pedaço: NACK e reenvio só dele;
perdeu de vez: o decoder pede IDR, como no TCP quando um quadro chega
estragado. Teste com 5% de perda nos dois sentidos (`TELINHA_UDP_PERDA=5`,
`run_qa.py udp_com_perda`): nenhuma mensagem perdida de vez, ~50 ms de atraso.

## Codec: H.264 sempre, HEVC (ou AV1) quando todo mundo pode

O openh264 garante que qualquer um decodifica H.264. HEVC rende bem mais por
bit em texto (no teste com NVENC/NVDEC, 720p a 2 Mbit/s: +4 dB), mas só sai
em placa de vídeo e nem todo mundo decodifica. Então a sala negocia por
transmissão: cada um diz no `hello` o que decodifica (testado uma vez por
processo), o servidor manda pro transmissor a interseção de quem assiste, e
o encoder é recriado no codec novo quando ela muda (começa num IDR). O codec
vai nas flags de cada quadro; quem assiste troca de decoder ao ver mudar.
Clipes e gravações ficam no codec que chegou (hvc1/hvcC ou av01/av1C no MP4).

O AV1 é experimental e vem desligado (Configurações → Desempenho): só o NVENC
das RTX 40 em diante codifica, pela API 12 do NVENC (o encoder de H.264/HEVC
continua na 11.1, que roda em driver mais antigo). Ele vem primeiro quando todo
mundo que assiste decodifica (NVDEC das RTX 30+, ou navegador); se não abrir,
quem transmite volta pro HEVC/H.264 pelo resto da transmissão.

## Decisões de desempenho

**Encoder em hardware primeiro.** O `hwenc.c` tenta, nessa ordem: NVENC
(placa NVIDIA, driver 470+: codifica 1080p em poucos milissegundos sem usar a
CPU e recebe o BGRX direto, a conversão de cor acontece na GPU); no Windows, o
encoder em hardware do Media Foundation (MFT de Intel Quick Sync, AMD ou
NVIDIA; baixa latência, CBR, sem B-frames, uma camada temporal só, entrada em
NV12); no Linux, o VA-API (Intel/AMD: I e P, CBR com HRD curto, SPS/PPS
nossos, uma camada temporal só, entrada em NV12; antes de ser usado ele
codifica 3 quadros sintéticos e confere com o openh264, então driver com bug
não manda lixo pra ninguém); e, sem nenhum, openh264. Se o encoder em hardware falhar em qualquer
momento, o app cai pro openh264 sem interromper a transmissão. Encoder que
ignora pedido de IDR (o do wine, algum driver por aí) é descoberto na segunda
vez seguida e passa a ser **recriado a cada pedido** — encoder novo sempre
começa com IDR —, senão quem entra depois nunca veria nada (`sharer.zig`).

**Pipeline em duas threads.** Captura+conversão e encode rodam em paralelo,
com 3 slots entre elas: o encoder sempre pega o quadro mais novo e um quadro
velho nunca espera na fila. O tempo por quadro vira o da etapa mais lenta.

**Captura por evento.** PipeWire e DXGI só entregam quadro quando algo mudou;
o loop não fica copiando tela parada. No X11/GDI (polling) um `memcmp` com o
quadro anterior evita codificar quadro repetido.

**Pool de threads compartilhado** (`sync.pool`): escala, conversão de cor e
conversão de volta rodam em faixas de linhas em paralelo. O encoder usa as
próprias threads do openh264 (uma fatia por núcleo).

**Conversão de cor com vetores** (`@Vector(16, i32)`): 16 pixels por iteração,
2 linhas por vez pra calcular o croma 2×2 na mesma passada.

**Zero cópia no relay.** O servidor monta o frame encaminhado uma vez e
enfileira o mesmo buffer (com contagem de referências) pra todo mundo que
assiste; cada escritora cifra com a chave da sua conexão na hora de enviar.

**O atraso nunca acumula — nem dentro de um túnel.** Cada frame é confirmado
(servidor → transmissor, espectador → servidor), então os dois lados sabem
quanto atraso está acumulado no caminho inteiro, inclusive em buffers que o
TCP não enxerga (ngrok, bore…). Detalhes e números no
[PROTOCOL.md](PROTOCOL.pt.md#4-controle-de-atraso-de-ponta-a-ponta).
1. *Transmissor:* atraso começando a crescer → taxa cai um pouco; atrasado de
   verdade → pula quadro e a taxa cai 25%; folgou → sobe rápido até perto de
   onde deu problema e depois só sonda devagar. IDR grande não conta.
2. *Servidor:* espectador que acumula mais de 500 ms perde os frames
   pendentes, espera o que já saiu chegar e recomeça de um IDR; atrasando sem
   escoar, o servidor já pede taxa menor pro transmissor (até metade, se é só
   um espectador entre vários; o quanto precisar, se é a maioria).
3. *Espectador:* se o decode fica 150 ms atrás, joga fora e pede IDR.

`zig build loadtest` testa isso com espectadores em link lento, maioria lenta
e o transmissor atrás de um túnel com buffer sem limite.

**Um espectador lento não derruba a qualidade da sala.** O transmissor
codifica com duas camadas temporais: um quadro sim, um não, ninguém usa de
referência (no openh264 com `iTemporalLayerNum`; no NVENC decidindo o tipo de
cada quadro e marcando `refPicFlag`, o que funciona em qualquer geração de
placa). O servidor reconhece esses quadros pelo bit "pulável" e, pra quem está
atrasando sendo a minoria (ou com o decoder pra trás), manda só os de
referência: 15 q/s em vez de 30, ~metade da banda e do decode, sem mexer em
quem está dando conta. No `zig build loadtest -- 8 60 1`: a taxa da sala fica
em ~89% da meta (antes descia pra 50%) e o lento acompanha com ~90 ms de atraso
(antes ~360 ms). Com texto, o NVENC gasta ~3x mais bits com duas camadas
(medido com `TELINHA_BENCH_CAMADAS=1/2`), então nesse caso fica uma só — e o
servidor volta pro jeito antigo (taxa da sala e recomeço por IDR).

**Quem assiste quase não usa CPU.** Com NVIDIA, o NVDEC decodifica (com
Intel/AMD no Linux, o VA-API, que dá a mesma imagem bit a bit que o openh264
e o ffmpeg — `zig build test` confere); em
qualquer caso a thread de decode entrega os planos YUV (1,5 byte/pixel) e um
shader converte a cor direto na GPU. Sem shader (OpenGL antigo), a CPU
converte em paralelo, como antes.

**Nada de atraso escondido no decoder.** O decoder do openh264 segura um
quadro em perfis Main/High achando que pode haver B-frames; como nunca há, o
`codec.zig` pede pra ele soltar na hora (`FlushFrame`). Assim o NVENC usa
High + CABAC + transformada 8x8 (texto bem mais nítido pela mesma taxa) e o
openh264 continua em Baseline; os dois saem na mesma chamada.

**IDR nítido.** O VBV de 1 quadro (latência mínima) fazia o NVENC mandar o
quadro completo — que sai quando alguém entra na sala — quase no QP máximo, e
a tela ficava borrada até os quadros seguintes refinarem. No IDR o VBV cresce
pra 10 quadros e volta ao normal em seguida: numa tela de código em 1080p o
IDR passa de 34 dB pra 45 dB, com ~60 KB a mais. O controle de atraso trata
IDR grande como esperado, sem baixar a qualidade.

**Captura no Wayland por DMA-BUF.** O portal entrega cada quadro num buffer
da GPU; o telinha importa com EGL (carregado em tempo de execução) e lê na
própria thread. Com memória compartilhada, quem lê a imagem de volta pra RAM
é o compositor, dentro do loop de renderização — a cada quadro, o mouse e as
animações da tela de quem transmite davam uma travadinha. O limite de fps vai
no `maxFramerate` da negociação (o que o portal do Hyprland usa pra decidir
quantas vezes copiar a tela). Se a importação falhar, a stream é renegociada
pra memória compartilhada (32, 24 ou 10 bits por canal, convertidos).

**Cursor no Hyprland.** Pedir o cursor embutido no portal faz o Hyprland
trocar pro cursor em software durante a captura (o mouse fica preso à
renderização). O telinha captura sem cursor, pega a posição pelo IPC do
Hyprland e desenha a seta no quadro.

**Compartilhar uma janela no Windows.** Além do monitor inteiro (DXGI),
dá pra mandar só uma janela: Windows.Graphics.Capture (Windows 10 1903+; a
janela pode estar coberta por outras). Não existe header de C pra WinRT no
MinGW, então as interfaces vão declaradas à mão no `capture_win.c` (vtables na
ordem do SDK, GUIDs conferidos com os IDLs), com `combase.dll`/`d3d11.dll`
carregadas em tempo de execução. Sem isso (Windows antigo, wine), cai pro
`PrintWindow`.

**Câmera.** Cada pessoa pode mandar a webcam junto com a tela (outra
transmissão, mesmo pipeline). No Linux pelo PipeWire (as webcams são nós
Video/Source do WirePlumber; YUYV, NV12, I420, RGB, e MJPEG decodificado com a
libturbojpeg carregada em tempo de execução); no Windows pelo Media
Foundation (`IMFSourceReader` convertendo pra RGB32, DLLs carregadas em tempo
de execução: o .exe abre até no Windows N, só sem câmera). Trocar de câmera
ou de resolução (480p/720p/1080p) não derruba quem assiste.

**Vários caminhos pra mesma sala.** O convite junta todos os endereços que a
sala tem (rede local, porta aberta no roteador, IPv6 globais, túnel digitado,
link público) e o `connect.zig` tenta todos quase juntos: o primeiro da lista
sai na frente e os outros 250 ms depois um do outro; ganha o primeiro que
responder o handshake como sala do telinha na mesma versão. Quem tem IPv6
entra direto; quem não tem cai no link público sozinho. Detalhes no
[PROTOCOL.md](PROTOCOL.pt.md#convite-e-vários-caminhos).

**Reconexão.** Queda de rede depois de entrar (e não expulsão/senha errada/
sala fechada — qualquer `denied`) dispara tentativas automáticas com espera
crescente; ao voltar, a transmissão recomeça e quem você assistia volta pra
tela (procurado pelo nome, já que os ids mudam se o servidor reiniciou).

**Áudio.** Quem transmite captura o som do computador **sem o que o próprio
telinha toca**: no Windows, loopback do WASAPI excluindo o processo; no Linux,
o telinha cria uma entrada no PipeWire que o gerenciador de sessão não liga em
nada e liga nela a saída de cada aplicativo que toca som, menos as do próprio
processo (o mesmo truque do venmic/Vesktop; o PID vem das propriedades
completas do nó). Sem PipeWire, cai pro monitor da saída padrão e aí o que
você assiste fica mudo enquanto você transmite áudio. Pacotes Opus de 10 ms com
DTX (silêncio quase não gasta banda). Quem assiste guarda 50 ms por transmissão
antes de tocar, pula pra frente se o atraso passar de 200 ms e soma tudo numa
saída só. `zig build audiotest` confere que o próprio som não entra na captura.

**Voz.** Microfone mono a 48 kHz em blocos de 10 ms → cancelamento de eco →
RNNoise (supressão de ruído, e a probabilidade de voz dele abre o "portão": abre acima da
sensibilidade, fica aberto 250 ms depois da última sílaba) → Opus VOIP, 20 ms,
~40 kbit/s. Com o portão fechado não sai pacote nenhum. No servidor a voz vai
pra todo mundo menos quem fala e quem está surdo, furando a fila (conversa não
espera atrás de vídeo); do outro lado, um anel por pessoa no mesmo mixer das
transmissões, com volume por pessoa. O microfone só abre quando você liga (o
indicador de microfone do sistema apaga quando desliga).
`zig build voicebot` entra numa sala e "fala" sílabas sintéticas pra testar.

**Cancelamento de eco.** Com caixa de som em vez de fone, o microfone pega de
volta a voz dos outros (e o som das transmissões que você assiste). O mixer
guarda o que acabou de tocar num anel de referência, e o filtro adaptativo do
SpeexDSP (MDF, cauda de 100 ms) mais a supressão do eco que sobra tiram isso do
microfone antes do RNNoise. O difícil não é o filtro, é alimentar ele direito:

1. *A referência tem que chegar antes do eco* (o filtro é causal) e o eco tem
   que cair dentro da cauda. Um detector de atraso correlaciona os envelopes de
   energia (1 ms por ponto, de −30 a +500 ms) do microfone e da referência —
   envelope não tem a ambiguidade do tom da voz, que é periódico — e, se o eco
   estiver fora de 1–40 ms, atrasa ou adianta a referência pra ele ficar em
   15 ms. É o que faz caixa Bluetooth (150–250 ms de atraso) funcionar.
2. *O anel não mexe sozinho*: todo ajuste obriga o filtro a reaprender, e o
   nível mínimo engana (com blocos grandes dos dois lados — 900 × 1200 amostras
   no PipeWire, por exemplo — o vale de verdade aparece pouco). Ele só põe 5 ms
   de folga quando seca (o que acontece logo que a saída começa a tocar).
3. *Relógios diferentes* (USB × placa onboard, até ~100 ppm): deixado solto, o
   eco "escorrega" em relação à referência e o filtro, correndo atrás, perde
   uns 15 dB. A deriva é medida por regressão (quanto a saída produziu × quanto
   o microfone consumiu, último minuto; só vale quando passa de 3σ) e a
   referência é reamostrada nessa proporção.
4. *O resto do eco continua parecendo voz*, e o RNNoise não liga pro volume:
   com a caixa tocando (ou até 120 ms depois — o eco chega atrasado e
   reverbera), bloco em que o cancelador tirou mais de 6 dB não conta como voz
   (falando junto, a sua voz não é cancelada e a saída fica perto da entrada),
   e o portão só abre com 30 ms seguidos de voz.
5. O preprocess do SpeexDSP só aplica a supressão do eco residual com o
   "denoise" ligado; fica ligado com 0 dB de supressão de ruído (ruído é com o
   RNNoise).
6. *Fone de ouvido* (o caso mais comum): sem eco nenhum, o cancelador só
   atrapalha — comia ~1 dB da sua voz quando os dois falam juntos. Depois de
   1 min de fala do outro lado sem eco (o detector não acha correlação *e* o
   cancelador não está tirando nada — com caixa de som, nos momentos em que só
   o outro lado fala ele tira, e a contagem recomeça), sai do caminho; apareceu
   eco (tirou o fone), volta na hora.

Testes: simulação (blocos de 1024 × 441 amostras, atraso nos callbacks,
deriva): ~35 dB com o mesmo relógio, ~33 dB com 120 ppm (sem compensar, ~19);
eco a 220 ms achado e compensado (~20 dB). De ponta a ponta, num PipeWire
isolado com a saída voltando inteira pro "microfone" (`voicebot --ouvinte`):
sem cancelamento, 440 pacotes de eco vazam em 12 s de fala do outro lado; com
ele, 68, todos nos 2 primeiros segundos (depois 21–32 dB, portão fechado). Com
um `pw-loopback` de 200 ms no caminho (Bluetooth): sem cancelamento, 523
pacotes; com ele, o detector acha ~215 ms, e vazam 139 nos primeiros 5 s
(medir o atraso + o filtro aprender de novo), depois nada.

**UI que dorme.** O loop usa `glfwWaitEventsTimeout`; threads de rede e decode
acordam a UI com `glfwPostEmptyEvent` quando há quadro novo. Sem transmissão,
o app praticamente não gasta CPU.

**Clipes e gravação, sem recodificar.** Quem assiste guarda o H.264 e o Opus
como chegam; quem transmite, o que codifica (`clip.zig`). Um clipe só pode
começar num IDR, então o buffer guarda a partir do IDR mais novo que ainda
cobre 30 s (teto de 160 MiB por transmissão); com os clipes ligados o `watch`
leva a opção de clipes e o servidor pede um IDR a cada 20 s, então ficam uns
30–50 s na memória. Salvar roda numa thread à parte e escreve um MP4 normal
com o índice (`moov`) no começo — toca em qualquer lugar. A gravação começa
na hora do clique: o app pede um IDR (`keyreq` com motivo "gravação", que não
mexe no controle de atraso) e o `mp4.Recorder` abre no primeiro que chegar,
escrevendo MP4 fragmentado (`moov` sem amostras + `moof`/`mdat` a cada ~2 s):
se o app cair no meio, o que já foi gravado toca. Vídeo em avc1 com duração
por quadro (a tela só manda quando muda), Opus em `dOps`, buracos de silêncio
viram pacotes vazios. Mudou a resolução, a gravação fecha. Os arquivos vão em
Vídeos/telinha (`XDG_VIDEOS_DIR`; no Windows a pasta do usuário em UTF-16,
aceita acento), ou em `TELINHA_PASTA_CLIPES`.

**Janela flutuante.** Uma transmissão pode ir pra uma janelinha por cima das
outras (`pip.zig`): segunda janela do GLFW com o contexto OpenGL
compartilhado com a principal (desenha a mesma textura do vídeo, sem cópia) e
um contexto próprio do ImGui (o backend do GLFW manda os eventos de cada
janela pro contexto dela; cada contexto carrega as próprias fontes). Fecha
sozinha quando a transmissão acaba.

**Notificações.** Com o telinha em segundo plano (chat, alguém ao vivo, alguém
entrou; no máximo uma a cada 2 s): no Linux, `Notify` do
`org.freedesktop.Notifications` pelo GDBus, sem esperar resposta (a UI não
trava nem sem serviço de notificação); no Windows, balão do ícone da bandeja
e a janela piscando na barra de tarefas.

**Sair sem travar.** Fechar a janela esconde ela na hora; depois o app avisa
a sala e salva a configuração, e termina com `sync.hardExit` (`_exit` /
`TerminateProcess`), sem os destrutores das bibliotecas: o do NVDEC
(libnvcuvid) e o do PipeWire travavam esperando threads internas e o
processo ficava vivo. Se a limpeza travar, um prazo de 4 s sai mesmo assim.

**Modo de testes da interface.** Com `TELINHA_QA=pasta`, os ganchos de teste
do ImGui (`IMGUI_ENABLE_TEST_ENGINE`, em `qa_hooks.cpp`) guardam o retângulo,
o rótulo e o estado de cada item, e a cada ~80 ms o app escreve `items.tsv`
(onde está cada botão) e `state.json` (o estado do app) nessa pasta. O
`tools/qa/` roda o app num Xvfb, clica nos botões de verdade com XTest e
confere o estado — sem tela, caixa de som ou microfone de verdade (PipeWire e
D-Bus privados), com roteador UPnP e túnel do bore de mentira; também roda o
`.exe` no wine. Fora desse modo os ganchos nem são chamados.

## Threads de uma sala típica (3 pessoas, 1 transmitindo)

- Transmissor: UI, captura/encode (de novo pra câmera, se ligada), threads do openh264, leitora, escritora, UDP, ping, pool.
- Servidor (no app do anfitrião ou dedicado): accept + leitora/escritora por pessoa, uma thread do UDP pra todos, relógio.
- Cada espectador: UI, leitora, escritora, UDP, ping, decode por transmissão, pool.
- Mandar imagem no chat: uma thread enquanto lê e codifica. Checagem de versão: uma thread ao abrir.
- Ao entrar: uma thread por caminho do convite, só durante a corrida.
- Salvar um clipe: uma thread enquanto escreve o arquivo.

## Ciclo de vida e memória

Objetos compartilhados entre threads (`Client`, `View`, `Sharer`, conexões do
servidor, mensagens) usam contagem de referências atômica; quem solta a última
referência libera. A UI nunca libera algo que uma thread ainda usa: ela pede
pra parar (`shutdown`/`close`) e solta a referência dela.
