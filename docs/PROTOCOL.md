# Protocolo (versão 5)

Tudo vai sobre **uma conexão TCP** por pessoa, cliente → servidor da sala.
Inteiros são little-endian. `str` = `u16` tamanho + bytes UTF-8.

## 1. Handshake (em claro)

Os dois lados mandam, ao mesmo tempo, 54 bytes:

| campo | tamanho | |
|---|---|---|
| `"TLNH"` | 4 | identifica o protocolo |
| versão | u16 | hoje `5` |
| chave pública X25519 | 32 | efêmera, nova a cada conexão |
| nonce | 16 | aleatório |

Se as versões forem diferentes, o servidor ainda manda o hello dele (pro
cliente poder avisar "versão diferente") e fecha.

### Derivação de chaves

```
segredo   = X25519(minha_secreta, pública_do_outro)
senha     = SHA-256("telinha-senha-v1" || senha_da_sala)
prk       = HKDF-Extract(sal = nonce_cliente || nonce_servidor, ikm = segredo || senha)
k_c2s     = HKDF-Expand(prk, "telinha c2s", 32)
k_s2c     = HKDF-Expand(prk, "telinha s2c", 32)
```

Senha errada → chaves diferentes → a primeira mensagem do cliente não
decifra. O servidor então manda `u32 0xFFFFFFFF` em claro (= "senha errada")
e fecha.

## 2. Mensagens (cifradas)

```
u32 tamanho | ChaCha20-Poly1305( u8 tipo | payload ) | tag (16 bytes)
```

`tamanho` conta o texto cifrado + tag. Nonce de 12 bytes = contador `u64`
da direção + 4 zeros (começa em 0, nunca repete numa conexão). Máximo 32 MiB.

| tipo | nome | direção | payload |
|---|---|---|---|
| 1 | hello | C→S | `str nome`, `str token_admin` |
| 2 | welcome | S→C | `u32 meu_id`, `str nome_da_sala`, `u8 sou_admin`, `u64 relógio_µs` |
| 3 | denied | S→C | `str motivo` (servidor fecha em seguida) |
| 4 | members | S→C | `u16 n`, n × membro (abaixo) |
| 5 | chat | C→S | `str texto` |
| 5 | chat | S→C | `u32 de` (0 = sistema), `str nome`, `str texto` |
| 6 | stream_start | C→S | `u16 w`, `u16 h`, `u8 fps`, `u8 flags` (1 = com áudio) |
| 7 | stream_stop | C→S | — |
| 8 | frame | C→S | frame (abaixo) |
| 8 | frame | S→C | `u32 de`, frame |
| 9 | watch | C→S | `u32 alvo`, `u8 ligado` |
| 10 | keyreq | S→C | — (mande um IDR) |
| 10 | keyreq | C→S | `u32 alvo` (espectador perdeu a referência; quer um IDR) |
| 11 | ping | C→S | `u64 t` |
| 12 | pong | S→C | `u64 t` (eco), `u64 relógio_µs` |
| 13 | kick | C→S | `u32 alvo` (só admin) |
| 14 | audio | C→S | áudio (abaixo) |
| 14 | audio | S→C | `u32 de`, áudio |
| 15 | ack | S→C | `u32 seq` (o servidor recebeu esse frame seu) |
| 15 | ack | C→S | `u32 de`, `u32 seq` (recebi esse frame de `de`) |
| 16 | viewer_slow | S→C | `u8 piso` (espectador não dá conta: baixe a taxa, até `piso`% do alvo) |
| 17 | voice | C→S | `u32 seq`, pacote Opus (voz: 48 kHz mono, 20 ms) |
| 17 | voice | S→C | `u32 de`, `u32 seq`, pacote Opus |
| 18 | voice_state | C→S | `u8 flags` (1 = microfone ligado, 2 = surdo) |

**Membro:** `u32 id`, `str nome`, `u8 flags` (1 = ao vivo, 2 = admin, 4 = transmitindo com áudio, 8 = microfone ligado, 16 = surdo),
`u16 w`, `u16 h`, `u8 fps`, `u16 k`, k × `u32` (ids que essa pessoa assiste).

**Frame:** `u32 seq`, `u8 flags` (1 = IDR, 2 = pulável), `u64 hora_da_captura`
(relógio da sala, µs), `u16 w`, `u16 h`, bitstream H.264 Annex B até o fim. Todo
IDR leva SPS/PPS. "Pulável" = ninguém usa esse quadro de referência (todas as
fatias com `nal_ref_idc = 0`; o transmissor codifica com duas camadas temporais,
um quadro sim, um não): o servidor pode deixar de mandar pra quem não dá conta
sem quebrar a decodificação dos seguintes. Quem não conhece o bit ignora.

**Áudio:** `u32 seq`, `u64 hora_da_captura`, pacote Opus até o fim
(48 kHz, estéreo, 10 ms por pacote, ~96 kbit/s).

## 3. Regras do servidor

- Frames só vão pra quem mandou `watch` pro transmissor.
- Quem começa a assistir (ou muda de resolução) só recebe a partir de um IDR;
  o servidor manda `keyreq` pro transmissor (no máximo um a cada 500 ms, fora
  quem acabou de começar a assistir).
- `ack`, `viewer_slow` e `voice` furam a fila de envio (não esperam atrás de
  frames), mantendo a ordem entre eles.
- Voz vai pra todo mundo da sala, menos quem fala e quem está surdo; só é
  descartada se a fila do destinatário passar de 6 MiB.
- Áudio vai pra quem assiste o transmissor, sem esperar IDR; só é descartado
  se a fila do espectador passar de 6 MiB.
- Nomes repetidos ganham sufixo: `Ana (2)`.

## 4. Controle de atraso de ponta a ponta

Túneis (ngrok, bore…) têm buffers enormes: o TCP de quem manda nunca sente o
congestionamento, e só olhar a própria fila não adianta. Por isso tudo é
medido com confirmações:

- O servidor manda `ack seq` pro transmissor assim que recebe cada frame.
  O transmissor guarda a hora em que enfileirou cada frame e calcula
  `atraso acumulado = idade do frame mais velho sem ack − RTT de referência`
  (o RTT de referência é o menor atraso de ack em janelas de 10 s, sem contar
  IDR — o atraso dele inclui a transferência — e limitado a 400 ms).
- Cada espectador manda `ack de seq` assim que recebe um frame (antes de
  decodificar). O servidor faz a mesma conta por espectador e por transmissor.

**Transmissor** (`ratectl.zig`), antes de cada quadro:
- atraso > 100 ms: taxa −7% (no máximo a cada 500 ms), sem pular quadro;
- atraso > 250 ms: pula o quadro; se persistir 300 ms (ou voltar em menos de
  1 s), taxa −25%. Atraso explicado por um IDR recente (folga = o tempo que
  ele levou, diminuindo em 4 s) só faz pular quadro, não baixa a taxa;
- atraso < 60 ms e 2 s sem problema: sobe 12% até 90% do "teto" (a taxa em que
  deu problema da última vez); acima disso, depois de 15 s sem problema, só
  +2%/s. Depois de 30 s sem problema o teto é esquecido.
- `viewer_slow piso`: −20% (no máximo a cada 2 s), não abaixo de `piso`% do
  alvo; a taxa não sobe por 12 s.

**Servidor**, a cada frame, pra cada espectador:
- atraso > 500 ms (+ folga de IDR) ou mais de 3 MiB na fila: descarta os
  frames que ainda não saíram, espera os que já saíram serem confirmados (o
  IDR não pode ficar atrás deles) e recomeça de um IDR. Quem atrasa de novo em
  menos de 10 s espera mais pelo próximo IDR (0,5 → 1 → 2 → 4 → 8 s), pra não
  encher a sala de IDR;
- atrasado > 150 ms e sem escoar (não caiu 50 ms em 1 s): `viewer_slow` pro
  transmissor antes de chegar no ponto de recomeçar;
- o piso do `viewer_slow` é 10% se mais da metade dos espectadores está com
  dificuldade (gargalo comum, ex.: o upload de quem hospeda a sala, ou só tem
  um espectador) e 50% se é a minoria — quem não dá conta nem com metade fica
  recomeçando de IDR de vez em quando, sem estragar a qualidade dos outros;
- **afinar** (se a transmissão tem quadros puláveis): quem atrasa sendo a
  minoria passa a receber só os quadros de referência — metade dos quadros,
  ~metade da banda —, e os puláveis que ainda estavam na fila dele são
  descartados na hora. Fica assim 10 s (o dobro, até 1 min, se precisar de novo
  em menos de 30 s); quando volta a receber tudo e atrasa nos 3 s seguintes,
  afina de novo na hora. Afinado só conta como "com dificuldade" pro
  `viewer_slow` se nem assim der conta (atrasando 3 s depois de afinar, ou
  recomeçando de IDR). Quem pede IDR porque o decoder não deu conta é afinado
  sempre (metade do trabalho pro decoder).

**Espectador:** confirma na hora; se o decoder fica mais de 150 ms atrasado,
joga a fila fora e manda `keyreq alvo` (o servidor aplica a mesma espera
crescente). Quadros que já têm um mais novo esperando são decodificados mas
não vão pra tela.

O pedido de IDR pra um espectador esperando normalmente sai quando chega o
próximo quadro do transmissor; com a tela dele parada (nada chegando há 1 s e
nenhum pedido nos últimos 2 s), o servidor pede sozinho — verifica a cada
250 ms —, senão o espectador ficaria preso na imagem velha.

No Linux os sockets usam `TCP_NOTSENT_LOWAT` = 32 KB: o kernel segura pouco
dado ainda não enviado e o resto espera na fila do app, onde dá pra descartar.

## 5. Relógio e latência

O servidor tem um relógio (µs desde que subiu). O cliente estima o offset com
os pings (`offset = relógio_servidor + RTT/2 − agora`, ponderando as medições
com RTT menor). O transmissor marca cada frame com a hora da captura nesse
relógio; o espectador calcula `atraso = agora_na_sala − hora_da_captura` na
hora em que o quadro vai pra GPU.
