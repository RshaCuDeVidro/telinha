# Referência da API

<sub>[🇺🇸 English](BOTS_API.md) · [🇧🇷 Português](BOTS_API.pt.md)</sub>

O pacote `telinha` (`sdk/python`), versão 0.3. Tudo é `asyncio`: os métodos
marcados com `await` são corrotinas. Pra começar, veja o
[tutorial](BOTS_TUTORIAL.pt.md).

```python
from telinha import Bot, Client, Player, Reaction, Member, Message, Denied
from telinha import Embed, Button, Click, Icon, Style
from telinha import Screen, VideoPlayer
```

## Client

Uma conexão com a sala, com o estado dela e os eventos. O `Bot` é um `Client`
com comandos; use o `Client` direto quando não precisar de comandos.

```python
Client(invite, name, *, password=None, channel=None, channel_password="", bot_token="", key=None, reconnect=True)
```

| Parâmetro | |
|---|---|
| `invite` | o convite (`telinha://end1,end2/canal!impressão#senha`), ou só `host:porta`; também aceita um `Invite` |
| `name` | o nome na sala (até 32 bytes; repetido ganha ` (2)`) |
| `password` | a senha da sala, se não vier no convite |
| `channel` | canal pra entrar, se não vier no convite (senão o padrão da sala) |
| `channel_password` | a senha desse canal, se ele tiver (a do `join_channel`/`join_call` o SDK lembra sozinho pra reconectar) |
| `bot_token` | o token de bot, se a sala pede (`--token-bots`) |
| `key` | número que identifica o bot pra banimento (padrão: sorteado a cada execução) |
| `reconnect` | reconectar sozinho quando a conexão cai (padrão `True`) |

### Estado

| Atributo | |
|---|---|
| `me` | o id do bot na sala |
| `room` | o nome da sala |
| `welcome` | `Welcome` da última entrada |
| `members` | `dict[int, Member]`: quem o bot enxerga (o canal de texto dele, a call dele e os bots de qualquer canal) |
| `streaming` | o bot está transmitindo a tela |
| `channel` | o canal de texto atual |
| `call` | a call atual (`""` = nenhuma) |
| `channels` | `dict[str, ChannelInfo]` |
| `room_locked` | a sala está trancada |
| `fingerprint` | a impressão da identidade do servidor (ou `None`, se ele não tiver) |
| `web_link` | o link pra assistir pelo navegador (`""` = não tem) |

### Métodos

| Método | |
|---|---|
| `run()` | roda até parar (Ctrl+C também); bloqueia |
| `await start()` | o mesmo, dentro de um programa `asyncio`; levanta `Denied` / `WrongPassword` |
| `await stop()` | sai da sala |
| `await wait_ready(timeout=None)` | espera o bot estar dentro da sala |
| `on(evento)` | decorador de handler: `@client.on("message")` |
| `off(evento, fn)` | tira um handler |
| `await send(texto, *, embed=None, image=None, reply_to=0, to=0, wait=True)` | manda no chat; `reply_to` cita uma mensagem, `to` manda em privado, `embed` junta um [cartão](#embed), `image` uma imagem (arquivo, link ou `ChatImage`; precisa do ffmpeg). Retorna a `Message` registrada (ou `None`). Mais de 4000 bytes vira várias mensagens |
| `await edit(message_id, texto, *, embed=None)` | muda uma mensagem do próprio bot (o texto e o cartão; a imagem fica) |
| `await click(message_id, botão)` | clica num botão do cartão de outro bot |
| `await react(message_id, reação, on=True)` | põe (ou tira) uma reação |
| `await join_channel(nome, senha="")` | troca o canal de texto (cria se não existir e o servidor deixar) |
| `await join_call(nome, senha="")` / `await leave_call()` | entra na call de um canal / sai |
| `await set_voice(mic=None, deaf=None)` | microfone ligado (aparece na lista) / surdo |
| `await send_voice(opus)` | um pacote Opus (48 kHz) na call; prefira o `Player` |
| `await send_file(caminho, *, name=None, to=0, reply_to=0, progress=None)` | manda um arquivo (até 256 MB); retorna o id |
| `await download(file_info, destino)` | baixa um arquivo da sala (`msg.file`); `destino` pode ser uma pasta |
| `await start_stream(largura, altura, fps=30, *, audio=False)` / `await stop_stream()` | começa (ou muda o tamanho de) a transmissão de tela do bot / para; prefira [`Screen` e `VideoPlayer`](#transmitir-a-tela) |
| `await send_frame(h264, *, key, width, height, droppable=False)` | um quadro H.264 (Annex B, um access unit) da transmissão |
| `await send_stream_audio(opus)` | um pacote Opus (48 kHz estéreo, 10 ms) do som da transmissão: vai só pra quem assiste |
| `member(id_ou_nome)` | acha alguém pelo id ou pelo nome (com ou sem `@`) |
| `room_time_us()` | agora, no relógio da sala |

## Eventos

| Evento | Argumentos | Quando |
|---|---|---|
| `ready` | `welcome: Welcome` | entrou na sala (de novo também, depois de reconectar) |
| `message` | `msg: Message` | mensagem no chat do canal ou em privado, inclusive as do próprio bot e as antigas (`msg.history`) |
| `join` | `member: Member` | apareceu alguém (no canal de texto ou na call do bot; bot, em qualquer canal) |
| `leave` | `member: Member` | saiu |
| `members` | `members: list[Member]` | a lista mudou (qualquer coisa: microfone, transmissão...) |
| `reaction` | `message_id, member_id, reaction, on` | alguém pôs ou tirou uma reação |
| `action` | `click: Click` | alguém clicou num botão de um cartão do bot (o `on_click` do botão também é chamado) |
| `edit` | `message_id, text, embed` | uma mensagem mudou (um bot atualizando o cartão) |
| `channels` | `current: str, channels: dict` | a lista de canais mudou (ou o bot trocou) |
| `notice` | `kind, text, extra` | algo que um admin fez com o bot (`Notice`) |
| `voice` | `member_id, seq, opus` | voz de alguém na call (pacote Opus cru) |
| `web_link` | `url` | o link do navegador mudou |
| `keyreq` | `kind` | a sala quer um quadro completo da transmissão do bot (alguém começou a assistir); a `Screen` responde sozinha |
| `pointer` | `member_id, x, y, flags` | o ponteiro de quem assiste o bot: `x`, `y` de 0 a 1 no vídeo; `flags & 2` = clique |
| `disconnect` | `reason` | a conexão caiu (vai tentar de novo) |

Cada handler roda na sua própria tarefa; um erro nele vai pro log e não
derruba o bot.

## Bot

```python
Bot(invite, name, *, prefix="!", help_command="ajuda", cooldown=1.0, accept_bots=False, lang="pt", **opções_do_Client)
```

| Parâmetro | |
|---|---|
| `prefix` | o que vem antes dos comandos |
| `help_command` | nome do comando de ajuda automático (`None` = sem; `help` também funciona) |
| `cooldown` | segundos entre comandos da mesma pessoa |
| `accept_bots` | obedecer comandos de outros bots |
| `lang` | idioma do que o SDK responde sozinho (uso errado, erro, ajuda): `"pt"` ou `"en"` |

`@bot.command(name=None, *, help="", aliases=(), admin_only=False)` registra
um comando. A função recebe `ctx` e os argumentos, convertidos pelos tipos
(`int`, `float`, `str`, `bool`, `Member`, `*resto`); o último `str` leva o
resto da linha. `bot.commands` tem todos.

Levantar `CommandError("texto")` dentro do comando responde o texto pra quem
chamou. Qualquer outro erro vai pro log e o bot responde "Deu erro aqui".

## Context

| | |
|---|---|
| `ctx.bot` | o bot |
| `ctx.message` | a `Message` do comando |
| `ctx.command` | o `Command` |
| `ctx.args` | o texto depois do comando, cru |
| `ctx.author` | o `Member` que chamou (ou `None` se já saiu) |
| `await ctx.reply(texto)` | responde citando; retorna a `Message` |
| `await ctx.send(texto)` | manda no mesmo lugar (canal ou privada); retorna a `Message` |
| `await ctx.reply_card(embed, texto="", *, image=None)` | responde com um cartão, citando; `texto` é o que app de antes da 3.4 mostra no lugar |

## Message

| | |
|---|---|
| `id` | o id na sala |
| `author_id`, `author` | quem mandou (`0` = aviso do sistema) |
| `text` | o texto (Markdown do jeito que a pessoa escreveu) |
| `time_us` | a hora no relógio da sala |
| `history` | é antiga (chegou porque o bot acabou de entrar) |
| `system` | é aviso do sistema ("Ana entrou na sala") |
| `quote` | se é resposta: `Quote(id, author_id, author, text)` |
| `private`, `to_id`, `to_name` | privada, e pra quem |
| `file` | se tem arquivo: `FileInfo(id, name, size)` |
| `has_image` | tem imagem (o SDK não decodifica imagem) |
| `reactions` | `[(reação, member_id)]` (só nas antigas; as novas vêm pelo evento) |
| `channel` | o canal de texto do bot quando ela chegou |
| `embed` | o cartão (`Embed`), se tiver |
| `author_channel`, `author_call` | onde o autor está (canal de texto e call; `""` = fora de call). O servidor só conta isso pra bot, e vale na privada também: é assim que o `/msg Bot !join` sabe pra onde ir |
| `await reply(texto)` | responde citando (em privado, se ela foi privada) |
| `await respond(texto)` | responde no mesmo lugar, sem citar |
| `await react(reação, on=True)` | |
| `await edit(texto=None, *, embed=None)` | muda a mensagem (só as do próprio bot) |

## Member

| | |
|---|---|
| `id`, `name`, `mention` | `mention` = `"@nome"` |
| `bot` | é um bot |
| `owner`, `admin` | criou a sala / é admin |
| `streaming`, `camera` | transmitindo a tela / a câmera |
| `mic`, `deaf`, `muted` | microfone ligado / surdo / silenciado por um admin |
| `in_channel`, `in_call` | está no canal de texto do bot / na call do bot |
| `route` | por onde chegou (1 nessa máquina, 2 rede local, 3–4 internet, 5 link público, 6 navegador) |
| `version` | a versão do app dela |
| `watching` | as transmissões que ela está vendo |

## ChannelInfo

`name`, `people` (no chat), `in_call`, `topic`, e `live`, `fixed`,
`has_password`, `locked`.

## Player

```python
Player(client, *, bitrate=128_000, stereo=True, ffmpeg="ffmpeg")
```

| | |
|---|---|
| `await play(fonte, *, volume=None, start=0.0, headers=None)` | toca um arquivo ou link até o fim; retorna `True` se acabou, `False` se foi parado. Liga o microfone do bot enquanto toca. `headers`: cabeçalhos HTTP pro link (os que o yt-dlp manda usar) |
| `pause()` / `resume()` | |
| `await stop()` | para (o `play` retorna `False`) |
| `set_volume(0.0–2.0)` | vale em ~meio segundo, sem recomeçar a música (o ganho é aplicado nas amostras) |
| `playing`, `paused`, `position`, `source`, `volume` | |

Precisa do ffmpeg (`FFmpegMissing` se não tiver).

## Transmitir a tela

O bot também transmite, como qualquer pessoa: quem está na mesma call clica
nele e assiste. Duas peças prontas, em `telinha.video`:

```python
screen = Screen(bot)
await screen.show("placar.png")     # arquivo, link, bytes, imagem do Pillow ou ChatImage
await screen.clear()                # para de transmitir

player = VideoPlayer(bot, max_height=720)
await player.play("filme.mp4")      # ou player.play(video_url, audio_url, headers=...)
```

**`Screen(client, *, max_side=1280)`**: uma imagem parada (um painel, um
placar, a pergunta de um quiz). Cada `show` vira um quadro completo, e quem
começa a assistir depois recebe a última de novo: sem imagem nova, não sai
nada (quase zero de CPU e de banda). Junto com o evento `pointer`, dá pra fazer
uma tela que a galera clica.

**`VideoPlayer(client, *, max_height=720, bitrate=2_500_000, audio_bitrate=128_000)`**:

| | |
|---|---|
| `await probe(fonte, headers=None)` | `VideoInfo` (codec, `width`, `height`, `fps`, `duration`, `has_audio`) pelo ffprobe |
| `await play(video, audio=None, *, headers=None, start=0.0, info=None)` | toca até o fim; `True` se acabou, `False` se foi parado. `audio`: o som num link separado (o YouTube manda assim). A transmissão continua ligada no fim, pra emendar a próxima |
| `pause()` / `resume()` / `await stop()` | pausar segura a imagem e o som juntos |
| `playing`, `paused`, `position`, `info`, `passthrough` | `passthrough`: o vídeo passa sem recodificar |

H.264 até `max_height` **passa direto**: os pacotes vão como vieram, sem
decodificar nem codificar de novo (o vídeo do YouTube em até 1080p é H.264).
Gasta quase nada de CPU; quadros B que ninguém usa de referência vão como
puláveis (a sala tira eles de quem não dá conta). Outro codec (VP9, AV1) o
ffmpeg recodifica pra H.264, e aí pesa (~1 núcleo pra 720p). O som vai como o
som da transmissão (Opus de 10 ms, no mesmo relógio da imagem), só pra quem
assiste. Quem assiste com app de antes da 3.6 sem decodificador na placa vê
vídeo com quadros B engasgando.

## Embed

Um cartão no chat: barra colorida, uma linha pequena em cima (`kicker`),
título (link, com `url`), texto em Markdown, campos lado a lado, uma barra de
progresso que anda sozinha em cada app e até 5 botões. App de antes da 3.4
mostra só o texto da mensagem.

```python
card = Embed(title="Popular Monster", kicker="NOW PLAYING", color=0xd946ef,
             description="by **Falling In Reverse**", url="https://...",
             progress=(31_000, 232_000), thumbnail=True, footer="SoundCloud")
card.add_field("Pedido por", "Ana").add_field("Depois", "Voices in My Head")
card.add_button("Pausar", icon=Icon.PAUSE, style="primary", on_click=pausar)
card.add_button("Pular", icon="next", on_click=pular)
msg = await bot.send("Tocando: Popular Monster", embed=card, image="capa.jpg")
...
card.kicker, card.paused = "PAUSADO", True
await msg.edit(embed=card)
```

| | |
|---|---|
| `title`, `url`, `kicker`, `description`, `footer` | texto (a descrição aceita `**negrito**`, `*itálico*`, `` `código` `` e `[links](https://...)`) |
| `color` | `0xRRGGBB` da barra (`0` = a cor de destaque do tema de quem vê) |
| `thumbnail` / `big_image` | a imagem da mensagem vai como capa (no canto) / grande, embaixo |
| `progress`, `paused` | `(posição_ms, total_ms)`; total `0` = ao vivo. Cada app anda sozinho até `paused` |
| `panel` | painel da transmissão do bot: quem assiste a tela dele (app 3.6+) vê o cartão encaixado embaixo do vídeo, com os botões; no chat ele continua igual |
| `add_field(nome, valor, inline=True)` | até 12 |
| `add_button(label="", *, icon=Icon.NONE, style="neutral", disabled=False, on_click=None)` | até 5. `style`: `neutral`, `primary`, `danger`, `success`. `on_click`: `async def f(click: Click)` |

`Icon`: `PLAY`, `PAUSE`, `NEXT`, `PREVIOUS`, `STOP`, `SHUFFLE`, `REPEAT`,
`VOLUME_UP`, `VOLUME_DOWN`, `LIST`, `HEART`, `MUSIC`, `RADIO`, `SEARCH`,
`PLUS`, `CHECK`, `CLOSE`, `LINK`, `JOIN`, `TRASH`, `STAR`, `DICE` (ou o nome
em texto: `icon="next"`).

O clique chega só no autor do cartão, no máximo a cada 120 ms por pessoa, e
edição no máximo a cada 200 ms (o SDK espera a vez, então duas edições
seguidas chegam as duas). O SDK lembra os botões dos últimos 300 cartões.

### Click

| | |
|---|---|
| `message_id`, `button` | qual cartão e qual botão (a partir de 0) |
| `member_id`, `member_name` | quem clicou |
| `channel`, `call` | onde a pessoa está |
| `await reply(texto, **kw)` | responde citando o cartão |
| `await whisper(texto)` | responde só pra quem clicou (privada) |

## Invite

`Invite.parse(texto)` → `addresses` (lista de `Address(host, port)`),
`password`, `channel`, `fingerprint`. `str(invite)` monta o convite de volta.

## Erros

| | |
|---|---|
| `Denied` | a sala recusou ou tirou o bot; `reason` e `code` (`Deny`: `KICKED`, `BANNED`, `CLOSED`, `LOCKED`, `FULL`, `BOTS`...). Não reconecta |
| `WrongPassword` | senha errada |
| `IdentityMismatch` | o servidor não provou ser o do convite (impressão diferente) |
| `ConnectError` | não conectou (o motivo vem na mensagem) |
| `BadInvite` | convite sem endereço que dê pra usar |
| `CommandError` | dentro de um comando: responde o texto pra quem chamou |

## Constantes

- `Reaction`: `LIKE`, `LOVE`, `HAHA`, `FIRE`, `WOW`, `SAD` (as seis reações do app, nessa ordem).
- `Notice`: `MUTED`, `UNMUTED`, `ADMIN_ON`, `ADMIN_OFF`, `CHANNEL`, `MOVED`, `DM`, `FILE_GONE`...
- `Deny`: os motivos de recusa (acima).

O protocolo por baixo está em [Protocolo](PROTOCOL.pt.md).
