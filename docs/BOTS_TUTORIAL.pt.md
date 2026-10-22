# Criar um bot

<sub>[🇺🇸 English](BOTS_TUTORIAL.md) · [🇧🇷 Português](BOTS_TUTORIAL.pt.md)</sub>

Do zero a um bot que responde comandos, reage, conversa em privado, toca som
e mexe com arquivos. Cada passo roda sozinho; junte o que quiser no final.
Instale o SDK antes (ver [Bots](BOTS.pt.md#instalar-o-sdk)).

> [!TIP]
> Teste numa sala só sua: `./telinha-server --porta 7790 --senha teste` e o
> convite `telinha://127.0.0.1:7790#teste`. Assim você pode reiniciar o bot à
> vontade sem incomodar ninguém.

## 1. Comandos

```python
from telinha import Bot

bot = Bot("telinha://127.0.0.1:7790#teste", "Ajudante")

@bot.command(help="repete o que você disse")
async def diz(ctx, frase: str):
    await ctx.send(frase)

bot.run()
```

- O nome do comando é o da função (`!diz`), ou o que você passar:
  `@bot.command("fala", aliases=["say"])`.
- O primeiro parâmetro é sempre o `ctx` ([Context](BOTS_API.pt.md#context)).
- `ctx.reply(texto)` responde **citando** a mensagem do comando;
  `ctx.send(texto)` manda no mesmo lugar, sem citar. Se o comando veio em
  privado, a resposta vai em privado também.

### Argumentos

Os argumentos saem do texto pelos tipos da função:

```python
@bot.command(help="soma dois números")
async def soma(ctx, a: int, b: int = 0):
    await ctx.reply(str(a + b))
```

| Tipo | Aceita |
|---|---|
| `int`, `float` | número (`3,5` vale como `3.5`); senão o bot avisa "não é um número" |
| `str` | uma palavra; **o último `str` leva o resto da linha**, sem precisar de aspas |
| `Member` | o nome (ou `@nome`) de alguém da sala |
| `bool` | `sim`, `1`, `liga`, `on`... |
| `*palavras` | todas as palavras que sobrarem |

Faltou um argumento obrigatório: o bot responde com o jeito certo de usar
(`Uso: !soma <a> [b]`). Aspas juntam palavras: `!soma "1" 2`.

### Ajuda, anti-flood e admin

- `!ajuda` (e `!help`) lista os comandos com a descrição do `help=`.
- Cada pessoa pode mandar um comando por segundo (`Bot(..., cooldown=1.0)`).
- `@bot.command(admin_only=True)` só obedece quem é admin da sala.
- Um bot ignora comandos de outros bots (`accept_bots=True` muda isso), pra
  dois bots não ficarem se respondendo pra sempre.

## 2. Eventos

Além de comandos, o bot pode reagir a tudo o que acontece na sala:

```python
from telinha import Reaction

@bot.on("join")
async def chegou(member):
    if not member.bot:
        await bot.send(f"Bem-vindo(a), {member.mention}!")

@bot.on("message")
async def mensagem(msg):
    if msg.history or msg.system or msg.author_id == bot.me:
        return  # histórico, avisos do sistema e as minhas próprias
    if "bom dia" in msg.text.casefold():
        await msg.react(Reaction.LOVE)
```

Os eventos: `ready`, `message`, `join`, `leave`, `members`, `reaction`,
`channels`, `notice`, `voice`, `web_link` e `disconnect` (detalhes na
[referência](BOTS_API.pt.md#eventos)). Cada handler roda numa tarefa própria:
pode esperar à vontade (um download, um `sleep`) sem travar o resto.

> [!IMPORTANT]
> O evento `message` também traz as mensagens antigas (`msg.history`), que
> chegam quando o bot entra, e as do próprio bot. Quase sempre você quer
> ignorar as duas, como no exemplo.

## 3. Mensagem que volta com id

`send`, `reply` e `ctx.send` devolvem a mensagem como a sala registrou, com o
`id`. Dá pra reagir nela, citar depois ou acompanhar as reações:

```python
from telinha import Reaction

@bot.command(help="enquete de 1 minuto")
async def enquete(ctx, pergunta: str):
    msg = await ctx.send(f"**{pergunta}** (reaja: curti = sim, amei = não)")
    await msg.react(Reaction.LIKE)
    await msg.react(Reaction.LOVE)
    ...
```

O exemplo inteiro, contando os votos pelo evento `reaction`, está em
[`examples/enquete.py`](../sdk/python/examples/enquete.py).

## 4. Cartões e botões

Um cartão (`Embed`) é uma mensagem com título, campos, barra de progresso e
botões, como o "tocando agora" do bot de música. Cada botão leva um
`on_click`, chamado quando qualquer um da sala clica, com quem clicou e onde
a pessoa está:

```python
from telinha import Embed, Icon

@bot.command(help="joga um dado, com um botão pra jogar de novo")
async def dado(ctx):
    card = Embed(kicker="DADO", title=str(random.randint(1, 6)), color=0x22c55e)

    async def de_novo(click):
        card.title = str(random.randint(1, 6))
        card.footer = f"jogado por {click.member_name}"
        await msg.edit(embed=card)          # muda o cartão no lugar

    card.add_button("Jogar de novo", icon=Icon.DICE, style="primary", on_click=de_novo)
    msg = await ctx.reply_card(card, "jogou um dado")
```

`reply_card` responde citando o comando; o texto é o que app de antes da 3.4
mostra no lugar do cartão. `send(..., image="capa.jpg")` junta uma imagem
(com `thumbnail=True` ela vira a capa do cartão). Tudo sobre cartões está na
[referência](BOTS_API.pt.md#embed).

## 5. Privada, canais e call

```python
await bot.send("só pra você", to=member.id)        # mensagem privada
await bot.join_channel("jogos")                    # troca o chat
await bot.join_call("jogos")                       # entra na call (voz)
await bot.leave_call()
```

O SDK espera sozinho o intervalo que o servidor exige entre trocas (800 ms).
`bot.channel`, `bot.call`, `bot.channels` e `bot.members` mostram onde o bot
está e quem está com ele.

## 6. Som na call

```python
from telinha import Player

player = Player(bot)

@bot.command(help="toca o hino")
async def hino(ctx):
    await ctx.reply("tocando o hino")
    await player.play("hino.mp3")          # volta quando acabar
```

O `Player` usa o ffmpeg pra abrir qualquer coisa (arquivo, rádio `http://`),
manda Opus estéreo no ritmo certo e liga o "microfone" do bot enquanto toca.
`pause()`, `resume()`, `stop()`, `set_volume(0.5)` e `position` fazem o
resto. O [bot de música](BOTS_MUSIC.pt.md) é um exemplo completo, com fila.

## 7. Arquivos

```python
@bot.on("message")
async def guarda(msg):
    if msg.file and not msg.history:
        caminho = await bot.download(msg.file, "recebidos/")
        print("baixei", caminho)

@bot.command(help="manda o relatório")
async def relatorio(ctx):
    await bot.send_file("relatorio.pdf", reply_to=ctx.message.id)
```

Até 256 MB por arquivo. Subindo e baixando, o SDK segue o ritmo das
confirmações do servidor (não atropela a voz e o vídeo da sala).

## 8. Rodando de verdade

- `bot.run()` reconecta sozinho se a conexão cair (de 1 em 1 s, depois até
  30 s). Se a sala **recusar** o bot (senha errada, expulso, banido, sala sem
  bots), ele para com o erro: `Denied` ou `WrongPassword`.
- Dentro de um programa `asyncio` maior, use `await bot.start()` (e
  `await bot.stop()` pra sair) em vez de `run()`.
- Passe `key=` fixa (`Bot(..., key=123456789)`) se quiser que um banimento
  valha entre execuções.
- Convite com a impressão do servidor (`!...` depois do endereço) faz o SDK
  conferir que está falando com a sala certa antes de mandar qualquer coisa.
- `logging.basicConfig(level=logging.INFO)` mostra o que o SDK está fazendo
  (o logger é `telinha`).

Pra deixar ligado numa VPS, o jeito do [bot de música](BOTS_MUSIC.pt.md#deixar-ligado-na-vps)
(systemd) serve pra qualquer bot.
