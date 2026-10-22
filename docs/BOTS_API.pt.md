# Referência da API

<sub>[🇺🇸 English](BOTS_API.md) · [🇧🇷 Português](BOTS_API.pt.md)</sub>

O pacote `telinha` (`sdk/python`), versão 0.1. Tudo é `asyncio`: os métodos
marcados com `await` são corrotinas. Pra começar, veja o
[tutorial](BOTS_TUTORIAL.pt.md).

```python
from telinha import Bot, Client, Player, Reaction, Member, Message, Denied
```

## Client

Uma conexão com a sala, com o estado dela e os eventos. O `Bot` é um `Client`
com comandos; use o `Client` direto quando não precisar de comandos.

```python
Client(invite, name, *, password=None, channel=None, bot_token="", key=None, reconnect=True)
```

| Parâmetro | |
|---|---|
| `invite` | o convite (`telinha://end1,end2/canal!impressão#senha`), ou só `host:porta`; também aceita um `Invite` |
| `name` | o nome na sala (até 32 bytes; repetido ganha ` (2)`) |
| `password` | a senha da sala, se não vier no convite |
| `channel` | canal pra entrar, se não vier no convite (senão o padrão da sala) |
| `bot_token` | o token de bot, se a sala pede (`--token-bots`) |
| `key` | número que identifica o bot pra banimento (padrão: sorteado a cada execução) |
| `reconnect` | reconectar sozinho quando a conexão cai (padrão `True`) |

### Estado

| Atributo | |
|---|---|
| `me` | o id do bot na sala |
| `room` | o nome da sala |
| `welcome` | `Welcome` da última entrada |
| `members` | `dict[int, Member]`: quem o bot enxerga (o canal de texto dele e a call dele) |
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
| `await send(texto, *, reply_to=0, to=0, wait=True)` | manda no chat; `reply_to` cita uma mensagem, `to` manda em privado. Retorna a `Message` registrada (ou `None`). Mais de 4000 bytes vira várias mensagens |
| `await react(message_id, reação, on=True)` | põe (ou tira) uma reação |
| `await join_channel(nome, senha="")` | troca o canal de texto (cria se não existir e o servidor deixar) |
| `await join_call(nome, senha="")` / `await leave_call()` | entra na call de um canal / sai |
| `await set_voice(mic=None, deaf=None)` | microfone ligado (aparece na lista) / surdo |
| `await send_voice(opus)` | um pacote Opus (48 kHz) na call; prefira o `Player` |
| `await send_file(caminho, *, name=None, to=0, reply_to=0, progress=None)` | manda um arquivo (até 256 MB); retorna o id |
| `await download(file_info, destino)` | baixa um arquivo da sala (`msg.file`); `destino` pode ser uma pasta |
| `member(id_ou_nome)` | acha alguém pelo id ou pelo nome (com ou sem `@`) |
| `room_time_us()` | agora, no relógio da sala |

## Eventos

| Evento | Argumentos | Quando |
|---|---|---|
| `ready` | `welcome: Welcome` | entrou na sala (de novo também, depois de reconectar) |
| `message` | `msg: Message` | mensagem no chat do canal ou em privado, inclusive as do próprio bot e as antigas (`msg.history`) |
| `join` | `member: Member` | apareceu alguém (no canal de texto ou na call do bot) |
| `leave` | `member: Member` | saiu |
| `members` | `members: list[Member]` | a lista mudou (qualquer coisa: microfone, transmissão...) |
| `reaction` | `message_id, member_id, reaction, on` | alguém pôs ou tirou uma reação |
| `channels` | `current: str, channels: dict` | a lista de canais mudou (ou o bot trocou) |
| `notice` | `kind, text, extra` | algo que um admin fez com o bot (`Notice`) |
| `voice` | `member_id, seq, opus` | voz de alguém na call (pacote Opus cru) |
| `web_link` | `url` | o link do navegador mudou |
| `disconnect` | `reason` | a conexão caiu (vai tentar de novo) |

Cada handler roda na sua própria tarefa; um erro nele vai pro log e não
derruba o bot.

## Bot

```python
Bot(invite, name, *, prefix="!", help_command="ajuda", cooldown=1.0, accept_bots=False, **opções_do_Client)
```

| Parâmetro | |
|---|---|
| `prefix` | o que vem antes dos comandos |
| `help_command` | nome do comando de ajuda automático (`None` = sem; `help` também funciona) |
| `cooldown` | segundos entre comandos da mesma pessoa |
| `accept_bots` | obedecer comandos de outros bots |

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
| `await reply(texto)` | responde citando (em privado, se ela foi privada) |
| `await respond(texto)` | responde no mesmo lugar, sem citar |
| `await react(reação, on=True)` | |

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
| `await play(fonte, *, volume=None, start=0.0)` | toca um arquivo ou link até o fim; retorna `True` se acabou, `False` se foi parado. Liga o microfone do bot enquanto toca |
| `pause()` / `resume()` | |
| `await stop()` | para (o `play` retorna `False`) |
| `set_volume(0.0–2.0)` | vale em ~meio segundo |
| `playing`, `paused`, `position`, `source`, `volume` | |

Precisa do ffmpeg (`FFmpegMissing` se não tiver).

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
