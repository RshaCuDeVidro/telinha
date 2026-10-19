# Arquitetura

```
 transmissor                              servidor da sala                     espectadores
 ───────────                              ────────────────                     ────────────
 thread de captura                        por conexão:                         por transmissão assistida:
   captura (PipeWire/X11/DXGI/GDI)          thread leitora ──┐                   thread leitora (rede, confirma)
     │ acorda quando a tela muda            thread escritora ◄┤ fila própria       │
   escala (pool, por faixas)                                 │ (descarta se     fila (máx. 150 ms)
     │                                    frame recebido ────┘   atrasou)          │
   NVENC: entrega o BGRX (troca ponteiro)   1 alocação, N referências            thread de decode
   software: BGRX → I420 (SIMD, pool)       só pra quem assiste                    │ H.264 → I420 (openh264)
     │  ─ 3 slots: o encoder pega sempre o quadro mais novo ─                      │ I420 → RGBA (SIMD, pool)
 thread de encode                                                                  ▼
   H.264: NVENC (GPU) ou openh264 (CPU, fatias em threads)                      UI: sobe pra GPU, desenha
     │
   fila de envio ── controle de taxa ──► TCP + ChaCha20-Poly1305 ─────────────►
        ▲                                     │                                    │
        └──── ack de cada frame ──────────────┘ ◄──── ack de cada frame ───────────┘
```

## Módulos

| arquivo | responsabilidade |
|---|---|
| `src/main.zig` | janela (GLFW), OpenGL, fontes, loop principal que dorme quando nada acontece |
| `src/ui.zig` | toda a interface (Dear ImGui via cimgui) |
| `src/client.zig` | conexão com a sala, estado (membros, chat, relógio), `View` = transmissão assistida |
| `src/sharer.zig` | thread de transmissão: captura → escala → encode → envio |
| `src/ratectl.zig` | controle de taxa de bits pelo atraso de ponta a ponta |
| `src/server.zig` | servidor da sala (embutido no app ou no `telinha-server`) |
| `src/server_main.zig` | executável do servidor dedicado |
| `src/tunnel.zig` | link público: cliente do protocolo do bore; cada visitante vira uma conexão da sala |
| `src/upnp.zig` | porta aberta no roteador (UPnP IGD: SSDP + SOAP), com aviso de CGNAT |
| `src/codec.zig` | wrapper do openh264 e do NVENC + conversões de cor vetorizadas |
| `src/c/hwenc_nvenc.c` | encoder em hardware NVIDIA (API NVENC 11.1, carregada em runtime) |
| `src/c/hwdec_nvdec.c` | decoder em hardware NVIDIA (NVDEC/nvcuvid, carregado em runtime) |
| `src/gl.zig` | texturas e conversão YUV→RGB num shader |
| `src/audio.zig` | áudio: Opus de quem transmite, anel anti-oscilação e mixer de quem assiste |
| `src/voice.zig` | voz da sala: microfone → cancelamento de eco → RNNoise → portão → Opus; voz de cada pessoa do outro lado |
| `src/aec.zig` | cancelamento de eco (SpeexDSP) com a saída do mixer como referência, compensando a deriva entre os relógios |
| `src/c/audio_pw.c` | Linux: som dos aplicativos pelo grafo do PipeWire, sem o próprio telinha |
| `src/c/audio.c` | captura do som do computador e saída (miniaudio) |
| `src/crypto.zig` | handshake X25519 e canal ChaCha20-Poly1305 |
| `src/proto.zig` | mensagens, filas de envio, framing, janela de confirmações (`AckWindow`) |
| `src/net.zig` | sockets (POSIX/Winsock) |
| `src/sync.zig` | mutex/condvar nativos, relógio, pool de threads |
| `src/c/capture_*.c` | captura de tela por plataforma |
| `src/tests.zig`, `src/integration_test.zig` | testes |
| `src/bench.zig` | benchmark do pipeline de vídeo |
| `src/loadtest.zig` | teste de carga do servidor (espectadores lentos, túnel ruim) |
| `src/captest.zig` | diagnóstico da captura de tela |

## Decisões de desempenho

**Encoder em hardware primeiro.** Se tiver placa NVIDIA (driver 470+), o
NVENC codifica 1080p em poucos milissegundos sem usar a CPU, e recebe o BGRX
direto (a conversão de cor acontece na GPU). Sem NVIDIA, ou se o NVENC falhar
em qualquer momento, o app cai pro openh264 sem interromper a transmissão.

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
[PROTOCOL.md](PROTOCOL.md#4-controle-de-atraso-de-ponta-a-ponta).
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

**Quem assiste quase não usa CPU.** Com NVIDIA, o NVDEC decodifica; em
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

**Reconexão.** Queda de rede depois de entrar (e não expulsão/senha errada)
dispara tentativas automáticas com espera crescente; ao voltar, a transmissão
recomeça e quem você assistia volta pra tela (procurado pelo nome, já que os
ids mudam se o servidor reiniciou).

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

## Threads de uma sala típica (3 pessoas, 1 transmitindo)

- Transmissor: UI, captura/encode, threads do openh264, leitora, escritora, ping, pool.
- Servidor (no app do anfitrião ou dedicado): accept + leitora/escritora por pessoa.
- Cada espectador: UI, leitora, escritora, ping, decode por transmissão, pool.

## Ciclo de vida e memória

Objetos compartilhados entre threads (`Client`, `View`, `Sharer`, conexões do
servidor, mensagens) usam contagem de referências atômica; quem solta a última
referência libera. A UI nunca libera algo que uma thread ainda usa: ela pede
pra parar (`shutdown`/`close`) e solta a referência dela.
