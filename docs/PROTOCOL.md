# Protocolo (versão 6)

Tudo vai sobre **uma conexão TCP** por pessoa, cliente → servidor da sala.
Inteiros são little-endian. `str` = `u16` tamanho + bytes UTF-8 (quem monta
corta em 4000 bytes).

Cada pessoa pode transmitir duas coisas ao mesmo tempo: a tela e a câmera.
Uma transmissão é identificada por um **stream** de 32 bits:

```
stream = id_da_pessoa | (tipo << 31)        tipo: 0 = tela, 1 = câmera
```

O id da pessoa nunca usa o bit de cima, então o stream da tela é o próprio id.

## 1. Handshake (em claro)

Os dois lados mandam, ao mesmo tempo, 54 bytes:

| campo | tamanho | |
|---|---|---|
| `"TLNH"` | 4 | identifica o protocolo |
| versão | u16 | hoje `6` |
| chave pública X25519 | 32 | efêmera, nova a cada conexão |
| nonce | 16 | aleatório |

Se as versões forem diferentes, o servidor ainda manda o hello dele (pro
cliente poder avisar "versão diferente") e fecha.

### Convite e vários caminhos

O convite pode trazer vários endereços pra mesma sala, separados por vírgula,
com a senha depois do primeiro `#`:

```
telinha://192.168.0.10:7777,203.0.113.7:7777,[2804:14c::1]:7777,bore.pub:41234#senha
```

Cada endereço é `host:porta`; IPv6 vai **entre colchetes** (sem colchete é
ambíguo e o endereço é ignorado). Até 8 endereços; a ordem é a preferência.
Quem hospeda monta o convite com o IP da rede local, a porta aberta no
roteador (UPnP), os IPv6 globais da máquina, o túnel digitado (ngrok etc.) e o
link público por último. Quem entrou passa adiante os caminhos que usou.

Quem entra faz uma corrida (`connect.zig`): uma tentativa por endereço, a
tentativa *i* começando *i* × 250 ms depois da primeira (os primeiros da
lista, os diretos, saem na frente). Cada uma conecta, manda o hello acima e
espera o do outro lado (até 8 s). **Ganha a primeira que responder um hello
do telinha com a mesma versão**: as outras desistem, e as que terminarem
depois são fechadas. Porta fechada, caminho mudo e outro serviço na porta (sem
`"TLNH"`) ficam pra trás sozinhos. A senha só é conferida depois, na conexão
que ganhou (próxima seção). Se ninguém ganhar (todas falharam ou passaram
20 s), o erro mostrado segue esta ordem: versão diferente → "não é uma sala do
telinha" → conexão recusada → endereço não encontrado (só com um endereço) →
não conectou.

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
e fecha. Até o `hello` cifrado chegar, cada leitura do servidor tem prazo de
10 s.

## 2. Mensagens (cifradas)

```
u32 tamanho | ChaCha20-Poly1305( u8 tipo | payload ) | tag (16 bytes)
```

`tamanho` conta o texto cifrado + tag. Nonce de 12 bytes = contador `u64`
da direção + 4 zeros (começa em 0, nunca repete numa conexão). Máximo 32 MiB.

| tipo | nome | direção | payload |
|---|---|---|---|
| 1 | hello | C→S | `str nome`, `str token_admin`, `u64 chave_do_cliente`, `str versão_do_app`, `u8 codecs` (o que decodifica, bits `1<<codec`) |
| 2 | welcome | S→C | `u32 meu_id`, `str nome_da_sala`, `u8 sou_admin`, `u64 relógio_µs`, `u64 instância`, `u8 rota`, `str versão_do_app` (de quem hospeda), `u8 udp` (1 = oferece UDP), `u32 token_udp` (se 1) |
| 3 | denied | S→C | `str motivo`, `u8 código` (servidor fecha em seguida) |
| 4 | members | S→C | `u8 sala` (1 = trancada), `u16 n`, n × membro (abaixo), n × `str versão_do_app` (mesma ordem) |
| 5 | chat | C→S | `str texto`, imagem (opcional, abaixo) |
| 5 | chat | S→C | `u32 id`, `u32 de` (0 = sistema), `str nome`, `str texto`, `u64 hora` (relógio da sala, µs), `u8 flags` (1 = histórico), imagem, `u8 n`, n × (`u8 reação`, `u32 de`) |
| 6 | stream_start | C→S | `u8 tipo`, `u16 w`, `u16 h`, `u8 fps`, `u8 flags` (1 = com áudio; só vale pra tela) |
| 7 | stream_stop | C→S | `u8 tipo` |
| 8 | frame | C→S | frame (abaixo) |
| 8 | frame | S→C | `u32 stream`, frame |
| 9 | watch | C→S | `u32 stream`, `u8 ligado`, `u8 opções` (1 = clipes: quer IDR de vez em quando) |
| 10 | keyreq | S→C | `u8 tipo` (mande um IDR dessa transmissão) |
| 10 | keyreq | C→S | `u32 stream`, `u8 motivo` (0 = perdi a referência, 1 = gravação começando) |
| 11 | ping | C→S | `u64 t` |
| 12 | pong | S→C | `u64 t` (eco), `u64 relógio_µs` |
| 13 | kick | C→S | `u32 alvo` (o mesmo que `admin` com ação 1; ainda aceito) |
| 14 | audio | C→S | áudio (abaixo) |
| 14 | audio | S→C | `u32 stream` (sempre o da tela), áudio |
| 15 | ack | S→C | `u8 tipo`, `u32 seq` (o servidor recebeu esse frame seu) |
| 15 | ack | C→S | `u32 stream`, `u32 seq` (recebi esse frame de `stream`) |
| 16 | viewer_slow | S→C | `u8 tipo`, `u8 piso` (espectador não dá conta: baixe a taxa, até `piso`% do alvo) |
| 17 | voice | C→S | `u32 seq`, pacote Opus (voz: 48 kHz mono, 20 ms) |
| 17 | voice | S→C | `u32 de`, `u32 seq`, pacote Opus |
| 18 | voice_state | C→S | `u8 flags` (1 = microfone ligado, 2 = surdo) |
| 19 | admin | C→S | `u8 ação`, `u32 alvo`, `u8 valor` (só admin, ver §3) |
| 20 | notice | S→C | `u8 tipo`, `str texto`, `u8 extra`: algo que um admin fez com você |
| 21 | pointer | C→S | `u32 stream`, `u16 x`, `u16 y`, `u8 flags` |
| 21 | pointer | S→C | `u32 de`, `u32 stream`, `u16 x`, `u16 y`, `u8 flags` |
| 22 | react | C→S | `u32 id_da_mensagem`, `u8 reação` (0–5), `u8 ligado` |
| 22 | react | S→C | `u32 id_da_mensagem`, `u32 de`, `u8 reação`, `u8 ligado` |
| 23 | codec | S→C | `u8 tipo` (tela/câmera), `u8 codecs`: o que todo mundo que assiste essa transmissão decodifica |

`versão_do_app` ("3.0.0") serve só pra avisar quem está desatualizado (a
interface mostra "fulano está no telinha X: tem versão nova"); vazia = não
informou. Também é campo do fim, lido com padrão vazio.

Alguns campos do fim são lidos com valor padrão (0, ou "tela") se faltarem:
`chave_do_cliente`, `flags` do stream_start, `tipo` do stream_stop, `opções`
do watch, `motivo` do keyreq e `valor` do admin no servidor; `código` do
denied, `tipo` do keyreq e `extra` do notice no cliente. É só tolerância:
versão diferente já é recusada no handshake.

**hello:** `chave_do_cliente` é um número aleatório sorteado uma vez e
guardado na configuração do app (nunca 0); serve pro banimento.
`token_admin` certo = dono da sala.

**welcome:** `sou_admin` = 1 pro dono. `instância` é sorteada quando o
servidor sobe (se mudou, o servidor reiniciou e os ids do chat recomeçaram).
`rota` = por onde você chegou:

| rota | |
|---|---|
| 0 | desconhecida |
| 1 | nessa máquina (loopback, ou conectou no próprio IP) |
| 2 | rede local: 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10 (CGNAT, Tailscale), fe80::/10, fc00::/7 |
| 3 | internet, IPv4 (porta aberta no roteador, servidor dedicado) |
| 4 | internet, IPv6 |
| 5 | link público (conexão entregue pelo túnel embutido) |

**denied:** `código` 0 = genérico, 1 = expulso, 2 = banido, 3 = o dono fechou
a sala, 4 = o link público por onde você entrou foi desligado, 5 = sala
trancada, 6 = sala cheia. Com qualquer um o cliente não tenta reconectar.

**Imagem no chat:** `u8 tipo` — 0 = nenhuma; 1 = `u16 w`, `u16 h`, `u32 tamanho`,
bytes; 2 = era uma imagem, mas o servidor já não guarda (histórico). Os bytes
são **um quadro H.264 (IDR)**: quem manda lê o arquivo/área de transferência no
próprio PC, reduz pra no máximo 1600 px e codifica com o openh264; quem
recebe decodifica com o mesmo decoder do vídeo e confere que o tamanho bate.
Assim nenhum leitor de PNG/JPEG fica exposto ao que vem da rede. Limites:
lado entre 16 e 1920 px, até 1,5 MB, uma imagem a cada 1,5 s por pessoa
(rajada é ignorada); fora disso a mensagem é inválida e o servidor derruba a
conexão. O histórico guarda até 24 MB de imagens; as mais velhas viram tipo 2.

**Reações:** 0 curti, 1 amei, 2 haha, 3 fogo, 4 uau, 5 triste. Uma por pessoa
e por tipo em cada mensagem (ligar de novo não muda nada); só em mensagens que
ainda estão no histórico, e não em avisos do sistema. No histórico, a
mensagem de chat já vem com as reações; depois disso elas chegam uma a uma.

**Membro:** `u32 id`, `str nome`, `u8 flags`, `u8 rota` (bit `0x80` = dono;
os 7 de baixo = rota, tabela acima), `u16 w`, `u16 h`, `u8 fps` (tela),
`u16 w`, `u16 h`, `u8 fps` (câmera), `u16 k`, k × `u32` (streams que essa
pessoa assiste, no máximo 64). Transmissão desligada vai com tamanho e fps 0.
Flags: 1 = transmitindo a tela, 2 = admin, 4 = tela com áudio, 8 = microfone
ligado, 16 = surdo, 32 = silenciado pelo admin, 64 = câmera ligada.

**Frame** (cabeçalho de 21 bytes):

| campo | tamanho | |
|---|---|---|
| seq | u32 | por transmissão; volta pra 0 quando ela recomeça |
| flags | u8 | 1 = IDR, 2 = pulável, bits 2–3 = codec (0 H.264, 1 HEVC, 2 AV1), `0x80` = câmera |
| hora_da_captura | u64 | relógio da sala, µs |
| w, h | u16, u16 | |
| cursor_x, cursor_y | u16, u16 | ponta do cursor de quem transmite, relativa ao quadro (0..65534); `0xFFFF` = sem cursor |

e o bitstream Annex B (H.264 ou HEVC, ver flags) até o fim. Todo IDR leva
SPS/PPS (no HEVC também o VPS). O servidor
descobre o stream pelo bit de câmera. "Pulável" = ninguém usa esse quadro de
referência (todas as fatias com `nal_ref_idc = 0`; o transmissor codifica com
duas camadas temporais, um quadro sim, um não): o servidor pode deixar de
mandar pra quem não dá conta sem quebrar a decodificação dos seguintes. Quem
não conhece o bit ignora. Um quadro reenviado com a tela parada leva a hora do
reenvio (ele é o estado atual da tela).

**Codec:** H.264 todo mundo decodifica (openh264 em software, se preciso);
HEVC só quem tem decoder na placa (hoje NVDEC). No `hello` cada um diz o que
decodifica; o servidor manda pro transmissor, a cada mudança de quem assiste,
a interseção (`codec`), e ele escolhe o melhor que o encoder dele faz — HEVC
se puder, senão H.264. Entrou alguém que só tem H.264: a transmissão volta pro
H.264 na hora (encoder novo, começando num IDR); quem já assistia troca de
decoder ao ver o codec mudar nas flags.

**Áudio:** `u32 seq`, `u64 hora_da_captura`, pacote Opus até o fim
(48 kHz, estéreo, 10 ms por pacote, ~96 kbit/s). Só a tela tem áudio.

**Ponteiro** ("olha aqui"): `x`, `y` relativos ao quadro (0..65534),
`0xFFFF` = esconde; flags 1 = visível, 2 = clique (anel chamando atenção).

**admin** — ações:

| ação | | valor |
|---|---|---|
| 1 | expulsar | — |
| 2 | banir (expulsa e não deixa voltar enquanto a sala existir) | — |
| 3 | silenciar o microfone | 1 = silencia, 0 = libera |
| 4 | parar uma transmissão | tipo (0 = tela, 1 = câmera) |
| 5 | dar/tirar admin (só o dono) | 1 = dá, 0 = tira |
| 6 | trancar a sala (alvo ignorado) | 1 = tranca, 0 = destranca |

**notice** — tipos: 1 = microfone silenciado, 2 = microfone liberado, 3 =
transmissão parada (`extra` = tipo dela), 4 = virou admin, 5 = deixou de ser
admin. O `texto` já vem pronto ("Ana silenciou seu microfone.").

## 2b. Vídeo, som e voz por UDP

Se o servidor tem a porta UDP (a mesma do TCP) e a conexão não veio pelo link
público, o `welcome` oferece UDP com um token. O cliente manda `hello` por UDP
pro mesmo endereço e porta (de 250 em 250 ms, depois de 3 em 3 s) até
receber `hello_ok`; daí em diante **quadro, áudio e voz** vão por UDP nos dois
sentidos — todo o resto (e o que não couber) continua no TCP. Sem resposta, ou
5–6 s sem nada chegar, volta pro TCP sozinho; o `hello` continua tentando.

Datagrama:

| campo | tamanho | |
|---|---|---|
| marca | u8 | `0xA7` |
| token | u32 | de que conexão é (o servidor acha a conexão por ele) |
| número | u64 | por sentido, nunca repete; é o nonce |
| cifrado | resto | ChaCha20-Poly1305 de `u8 tipo` + corpo; o cabeçalho entra como dado associado |

Chave de cada sentido = SHA-256("telinha udp v1" ‖ chave do TCP nesse
sentido). Pacote que não decifra, repetido, ou mais de 128 números atrás do
maior já visto é ignorado. O servidor passa a responder pro endereço de onde
veio o último pacote que decifrou (NAT que muda de porta).

| tipo | corpo |
|---|---|
| 1 hello / 2 hello_ok | — |
| 3 ping / 4 pong | `u64 t` (eco): mantém o NAT aberto, mede o RTT |
| 5 dados | `u32 canal`, `u32 id`, `u16 pedaço`, `u16 total`, bytes (até 1150) |
| 6 nack | `u32 canal`, `u32 id`, `u16 n`, n × `u16 pedaço` (`n = 0xFFFF` = a mensagem inteira) |

Uma mensagem (`u8 tipo` + payload, igual ao TCP) vai em pedaços de 1150
bytes. **Canal:** quadros andam em ordem por transmissão (canal = stream; do
cliente pro servidor, `0x80000000` tela / `0x80000001` câmera), com ids
1, 2, 3... por canal; som e voz usam o canal `0xFFFFFFFF`, sem ordem (cada um
tem a própria sequência e buffer). Quem recebe remonta; pedaço faltando (fora
de ordem por mais de ~RTT/4) vira NACK, repetido a cada ~1,25 × RTT; mensagem
de que nada chegou é descoberta pela seguinte (buraco nos ids) e pedida
inteira. Quem manda guarda o que mandou por 1,5 s pra reenviar. Desiste de
uma mensagem quando os pedaços param de chegar por `4 × RTT` (150–400 ms) ou
depois de 1 s: os quadros seguintes são entregues e o decoder pede um IDR
(`keyreq`) se precisar. O envio é cadenciado (rajada de até 128 KB, depois no
máximo 4× a taxa média), pra um IDR grande não estourar o buffer do roteador.

## 3. Regras do servidor

### Entrada

- Nome sem espaços nas pontas, até 32 bytes; vazio vira `anônimo`. Nomes
  repetidos ganham sufixo: `Ana (2)`.
- Quem não é o dono é recusado (`denied`) se estiver banido (2), se a sala
  estiver trancada (5) ou cheia (6; 32 pessoas por padrão). O dono passa por
  cima de tudo isso.
- Logo depois do `welcome`, quem entra recebe as últimas **50** mensagens do
  chat (com a flag de histórico: sem som nem notificação); depois todo mundo
  recebe "Fulano entrou na sala" e o `members` novo.

### Transmissões

- Frames só vão pra quem mandou `watch` pro stream. Só dá pra assistir quem
  existe e não a si mesmo, até 2 × o limite de pessoas em streams. `watch`
  ligado de novo pro mesmo stream só muda as opções.
- Quem começa a assistir (ou quando o transmissor muda de resolução com um
  `stream_start` novo) só recebe a partir de um IDR; o servidor manda
  `keyreq` pro transmissor (no máximo um a cada 500 ms por transmissão, fora
  quem acabou de começar a assistir).
- Frame de transmissão que não está ligada (o admin parou e ainda está
  chegando quadro velho) é descartado.
- `keyreq` com motivo "gravação" só pede o IDR (respeitando os 500 ms), sem
  mexer no controle de atraso daquele espectador.
- **Clipes:** quem assiste com a opção de clipes guarda os últimos 30 s, e um
  clipe só começa num IDR. A cada 250 ms o servidor confere: se o último IDR
  daquela transmissão tem mais de 20 s e não pediu nenhum nesse tempo, pede.
- `ack`, `viewer_slow`, `voice` e `pointer` furam a fila de envio (não
  esperam atrás de frames), mantendo a ordem entre eles.
- Voz vai pra todo mundo da sala, menos quem fala e quem está surdo; a de quem
  foi silenciado pelo admin é jogada fora. Só é descartada se a fila do
  destinatário passar de 6 MiB.
- Áudio vai pra quem assiste a tela do transmissor, sem esperar IDR; só é
  descartado se a fila do espectador passar de 6 MiB.
- Ponteiro: só é aceito de quem transmite aquele stream ou assiste ele, no
  máximo 40 por segundo por pessoa (o resto é jogado fora); vai pro dono do
  stream e pra todo mundo que assiste, menos quem mandou.

### Chat

Texto sem espaços nas pontas; vazio é ignorado. Toda mensagem — inclusive as
do sistema (`de` = 0: entrou, saiu, começou a transmitir, ligou a câmera,
expulsou, trancou...) — ganha um `id` crescente (começa em 1 a cada
instância do servidor) e a hora no relógio da sala, e entra num anel com as
últimas 50. O cliente ignora mensagem de histórico com `id` que já viu e
converte a hora pro relógio local.

### Admin

- Só quem é admin; pedido de quem não é é ignorado em silêncio.
- Trancar/destrancar: qualquer admin. Vai pro chat de todo mundo e o
  `members` sai com o estado da sala.
- O resto precisa de um alvo que existe, que não seja você nem o dono.
  Admin promovido (não dono) não mexe em outro admin. Dar/tirar admin é só
  do dono.
- Expulsar/banir: o chat de todo mundo fica sabendo; o alvo recebe `denied`
  (1 ou 2, "Fulano expulsou você da sala.") e sai. O banimento guarda a
  `chave_do_cliente`, o nome sem o sufixo ` (n)` (comparado sem diferenciar
  maiúsculas) e o IP — esse último não vale pra quem veio pelo link público
  (todo mundo ali tem o IP do túnel) nem pra quem está na mesma máquina.
  Bater em qualquer um dos três já barra a entrada.
- Silenciar, parar transmissão e dar/tirar admin mandam um `notice` pro alvo
  e um `members` novo pra sala; parar transmissão funciona como se o alvo
  tivesse mandado `stream_stop`.

### Saída

- Quem sai: todo mundo para de receber as duas transmissões dele, recebe
  "Fulano saiu da sala" e o `members` novo.
- O servidor nunca derruba alguém sem o motivo chegar: manda o `denied`,
  espera a fila dele esvaziar (até 600 ms), fecha só o lado de envio do socket
  e espera o cliente fechar (até 600 ms) antes de derrubar de vez.
- Sala fechando: todo mundo recebe `denied` 3 ("O dono fechou a sala.").
- Link público desligado: quem entrou por ele recebe `denied` 4 e sai; o
  resto continua.

## 4. Controle de atraso de ponta a ponta

Túneis (ngrok, bore…) têm buffers enormes: o TCP de quem manda nunca sente o
congestionamento, e só olhar a própria fila não adianta. Por isso tudo é
medido com confirmações — separadamente pra cada transmissão (a tela e a
câmera de alguém têm controles independentes):

- O servidor manda `ack tipo seq` pro transmissor assim que recebe cada frame.
  O transmissor guarda a hora em que enfileirou cada frame e calcula
  `atraso acumulado = idade do frame mais velho sem ack − RTT de referência`
  (o RTT de referência é o menor atraso de ack em janelas de 10 s, sem contar
  IDR — o atraso dele inclui a transferência — e limitado a 400 ms).
- Cada espectador manda `ack stream seq` assim que recebe um frame (antes de
  decodificar). O servidor faz a mesma conta por espectador e por stream.

**Transmissor** (`ratectl.zig`), antes de cada quadro:
- atraso > 100 ms: taxa −7% (no máximo a cada 500 ms), sem pular quadro;
- atraso > 250 ms: pula o quadro; se persistir 300 ms (ou voltar em menos de
  1 s), taxa −25%. Atraso explicado por um IDR recente (folga = o tempo que
  ele levou, diminuindo em 4 s) só faz pular quadro, não baixa a taxa;
- atraso < 60 ms e 2 s sem problema: sobe 12% até 90% do "teto" (a taxa em que
  deu problema da última vez); acima disso, depois de 15 s sem problema, só
  +2%/s. Depois de 30 s sem problema o teto é esquecido.
- `viewer_slow tipo piso`: −20% (no máximo a cada 2 s), não abaixo de `piso`%
  do alvo; a taxa não sobe por 12 s.

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
joga a fila fora e manda `keyreq stream` com motivo 0 (o servidor aplica a
mesma espera crescente). Quadros que já têm um mais novo esperando são
decodificados mas não vão pra tela.

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
hora em que o quadro vai pra GPU. A hora das mensagens do chat também vem
nesse relógio.
