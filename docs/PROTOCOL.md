# Protocolo (versão 4)

Tudo vai sobre **uma conexão TCP** por pessoa, cliente → servidor da sala.
Inteiros são little-endian. `str` = `u16` tamanho + bytes UTF-8.

## 1. Handshake (em claro)

Os dois lados mandam, ao mesmo tempo, 54 bytes:

| campo | tamanho | |
|---|---|---|
| `"TLNH"` | 4 | identifica o protocolo |
| versão | u16 | hoje `4` |
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
| 11 | ping | C→S | `u64 t` |
| 12 | pong | S→C | `u64 t` (eco), `u64 relógio_µs` |
| 13 | kick | C→S | `u32 alvo` (só admin) |
| 14 | audio | C→S | áudio (abaixo) |
| 14 | audio | S→C | `u32 de`, áudio |

**Membro:** `u32 id`, `str nome`, `u8 flags` (1 = ao vivo, 2 = admin, 4 = transmitindo com áudio),
`u16 w`, `u16 h`, `u8 fps`, `u16 k`, k × `u32` (ids que essa pessoa assiste).

**Frame:** `u32 seq`, `u8 flags` (1 = IDR), `u64 hora_da_captura` (relógio da
sala, µs), `u16 w`, `u16 h`, bitstream H.264 Annex B até o fim. Todo IDR leva
SPS/PPS (perfil Baseline).

**Áudio:** `u32 seq`, `u64 hora_da_captura`, pacote Opus até o fim
(48 kHz, estéreo, 10 ms por pacote, ~96 kbit/s).

## 3. Regras do servidor

- Frames só vão pra quem mandou `watch` pro transmissor.
- Quem começa a assistir (ou muda de resolução) só recebe a partir de um IDR;
  o servidor manda `keyreq` pro transmissor.
- Se a fila de envio de um espectador passa de 3 MiB, os frames pendentes dele
  são descartados, ele volta a esperar um IDR e o transmissor recebe `keyreq`
  (no máximo um a cada 500 ms). Assim um espectador lento nunca atrasa os outros.
- Áudio vai pra quem assiste o transmissor, sem esperar IDR; só é descartado
  se a fila do espectador passar de 6 MiB.
- Nomes repetidos ganham sufixo: `Ana (2)`.

## 4. Relógio e latência

O servidor tem um relógio (µs desde que subiu). O cliente estima o offset com
os pings (`offset = relógio_servidor + RTT/2 − agora`, ponderando as medições
com RTT menor). O transmissor marca cada frame com a hora da captura nesse
relógio; o espectador calcula `atraso = agora_na_sala − hora_da_captura` na
hora em que o quadro vai pra GPU.
