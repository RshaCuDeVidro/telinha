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
| `src/codec.zig` | wrapper do openh264 e do NVENC + conversões de cor vetorizadas |
| `src/c/hwenc_nvenc.c` | encoder em hardware NVIDIA (API NVENC 11.1, carregada em runtime) |
| `src/c/hwdec_nvdec.c` | decoder em hardware NVIDIA (NVDEC/nvcuvid, carregado em runtime) |
| `src/gl.zig` | texturas e conversão YUV→RGB num shader |
| `src/audio.zig` | áudio: Opus de quem transmite, anel anti-oscilação e mixer de quem assiste |
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

**Quem assiste quase não usa CPU.** Com NVIDIA, o NVDEC decodifica; em
qualquer caso a thread de decode entrega os planos YUV (1,5 byte/pixel) e um
shader converte a cor direto na GPU. Sem shader (OpenGL antigo), a CPU
converte em paralelo, como antes.

**Baseline sempre.** O decoder do openh264 segura um quadro pra reordenação
em perfis Main/High; com Baseline (o que os dois encoders geram) cada quadro
sai na mesma chamada — nada de atraso escondido.

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

**Áudio.** Quem transmite captura o som do computador (WASAPI loopback
excluindo o próprio processo no Windows; monitor da saída padrão no Linux) e
manda pacotes Opus de 10 ms com DTX (silêncio quase não gasta banda). Quem
assiste guarda 50 ms por transmissão antes de tocar, pula pra frente se o
atraso passar de 200 ms e soma tudo numa saída só. No Linux, enquanto você
transmite áudio, o que você assiste fica mudo (a captura escutaria o próprio
app e viraria eco).

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
