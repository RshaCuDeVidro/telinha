# Arquitetura

```
 transmissor                              servidor da sala                     espectadores
 ───────────                              ────────────────                     ────────────
 thread de captura                        por conexão:                         por transmissão assistida:
   captura (PipeWire/X11/DXGI/GDI)          thread leitora ──┐                   thread leitora (rede)
     │ acorda quando a tela muda            thread escritora ◄┤ fila própria       │
   escala (pool, por faixas)                                 │ (descarta se     fila (máx. 3)
     │                                    frame recebido ────┘   lento)            │
   NVENC: entrega o BGRX (troca ponteiro)   1 alocação, N referências            thread de decode
   software: BGRX → I420 (SIMD, pool)       só pra quem assiste                    │ H.264 → I420 (openh264)
     │  ─ 3 slots: o encoder pega sempre o quadro mais novo ─                      │ I420 → RGBA (SIMD, pool)
 thread de encode                                                                  ▼
   H.264: NVENC (GPU) ou openh264 (CPU, fatias em threads)                      UI: sobe pra GPU, desenha
     │
   fila de envio ── controle de banda ─► TCP + ChaCha20-Poly1305 ─────────────►
```

## Módulos

| arquivo | responsabilidade |
|---|---|
| `src/main.zig` | janela (GLFW), OpenGL, fontes, loop principal que dorme quando nada acontece |
| `src/ui.zig` | toda a interface (Dear ImGui via cimgui) |
| `src/client.zig` | conexão com a sala, estado (membros, chat, relógio), `View` = transmissão assistida |
| `src/sharer.zig` | thread de transmissão: captura → escala → encode → envio, controle de banda |
| `src/server.zig` | servidor da sala (embutido no app ou no `telinha-server`) |
| `src/server_main.zig` | executável do servidor dedicado |
| `src/codec.zig` | wrapper do openh264 e do NVENC + conversões de cor vetorizadas |
| `src/c/hwenc_nvenc.c` | encoder em hardware NVIDIA (API NVENC 11.1, carregada em runtime) |
| `src/c/hwdec_nvdec.c` | decoder em hardware NVIDIA (NVDEC/nvcuvid, carregado em runtime) |
| `src/gl.zig` | texturas e conversão YUV→RGB num shader |
| `src/audio.zig` | áudio: Opus de quem transmite, anel anti-oscilação e mixer de quem assiste |
| `src/c/audio.c` | captura do som do computador e saída (miniaudio) |
| `src/crypto.zig` | handshake X25519 e canal ChaCha20-Poly1305 |
| `src/proto.zig` | mensagens, filas de envio, framing |
| `src/net.zig` | sockets (POSIX/Winsock) |
| `src/sync.zig` | mutex/condvar nativos, relógio, pool de threads |
| `src/c/capture_*.c` | captura de tela por plataforma |
| `src/tests.zig`, `src/integration_test.zig` | testes |
| `src/bench.zig` | benchmark do pipeline de vídeo |

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

**O atraso nunca acumula.** Três camadas:
1. *Transmissor:* se a própria fila de envio passa de ~250 ms de vídeo, a taxa
   de bits cai 25% e quadros são pulados (não enfileirados). Sem
   congestionamento por 2 s, a taxa sobe 12% por segundo até o alvo.
2. *Servidor:* espectador com mais de 3 MiB pendentes perde o atraso e
   recomeça de um IDR.
3. *Espectador:* se o decode não dá conta (mais de 3 quadros na fila), joga
   fora e pede IDR.

**Quem assiste quase não usa CPU.** Com NVIDIA, o NVDEC decodifica; em
qualquer caso a thread de decode entrega os planos YUV (1,5 byte/pixel) e um
shader converte a cor direto na GPU. Sem shader (OpenGL antigo), a CPU
converte em paralelo, como antes.

**Baseline sempre.** O decoder do openh264 segura um quadro pra reordenação
em perfis Main/High; com Baseline (o que os dois encoders geram) cada quadro
sai na mesma chamada — nada de atraso escondido.

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
