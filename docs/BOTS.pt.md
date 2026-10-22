# Bots

<sub>[🇺🇸 English](BOTS.md) · [🇧🇷 Português](BOTS.pt.md)</sub>

Um bot é um programa que entra na sala como mais uma pessoa: lê e manda
mensagens, responde comandos (`!dado 20`), reage, troca de canal, toca som na
call e manda arquivos. O telinha vem com um [bot de música](BOTS_MUSIC.pt.md)
pronto e com o **SDK em Python** (`sdk/python` no repositório) pra você fazer
os seus.

Um bot roda em qualquer lugar que alcance a sala: no seu PC, numa VPS, num
Raspberry Pi. Ele não gasta nada do computador de quem transmite.

## Como um bot aparece

- Com a etiqueta **BOT** do lado do nome, na lista de pessoas e no chat.
- **Nunca vira admin**, nem se mandar o token de dono, nem se o dono tentar
  promover.
- O admin expulsa, bane e silencia um bot como qualquer pessoa. Silenciado, a
  voz dele (a música) para de chegar em todo mundo.
- Cada um ajusta o volume do bot só pra si, com o clique direito no nome dele.

## O dono da sala decide

Por padrão, qualquer bot com a senha da sala entra. No
[servidor dedicado](DEPLOY.pt.md):

| Opção | O que faz |
|---|---|
| `--sem-bots` | Recusa todos os bots (`TELINHA_SEM_BOTS=1`). |
| `--token-bots SEGREDO` | Só entra bot que mandar esse token (`TELINHA_TOKEN_BOTS`). Gente comum continua entrando só com a senha da sala. |

> [!NOTE]
> A etiqueta é honesta, não é uma trava: um programa que finja ser o app não
> aparece como bot. Mas ele também não ganha nada com isso, porque um bot
> pode o mesmo que uma pessoa, menos virar admin.

## Instalar o SDK

Precisa do Python 3.10 ou mais novo.

```sh
pip install "git+https://github.com/RshaCuDeVidro/telinha#subdirectory=sdk/python"
```

A única dependência é a `cryptography` (a cifra da sala). Pra tocar som na
call, o **ffmpeg** também (`sudo apt install ffmpeg`, `sudo pacman -S ffmpeg`,
`winget install ffmpeg`).

## O primeiro bot

```python
import random
from telinha import Bot

bot = Bot("telinha://minha.sala:7777#senha", "Dado")

@bot.command(help="joga um dado (padrão: 6 lados)")
async def dado(ctx, lados: int = 6):
    await ctx.reply(f"deu {random.randint(1, lados)}")

bot.run()
```

Rode com `python3 dado.py`, e na sala alguém digita `!dado 20`. O `!ajuda`
lista os comandos sozinho. O convite é o mesmo que você manda pros amigos
(o botão **Copiar convite** do app).

> [!TIP]
> O prefixo é `!` porque o `/` é dos comandos do próprio app (`/join`, `/msg`).

## Próximos passos

- [Bot de música](BOTS_MUSIC.pt.md): instalar, comandos, rádios, deixar ligado na VPS.
- [Criar um bot](BOTS_TUTORIAL.pt.md): passo a passo, de comandos a eventos, enquete, música e arquivos.
- [Referência da API](BOTS_API.pt.md): cada classe, método e evento.
- Exemplos prontos em [`sdk/python/examples`](../sdk/python/examples): `dado.py`, `eco.py`, `enquete.py`, `vigia.py`.

## Testar sem atrapalhar ninguém

Antes de pôr um bot numa sala cheia, teste numa sala só sua: crie uma sala no
app (**Criar sala**) ou rode um `telinha-server` na sua máquina, e aponte o
bot pra ela:

```sh
./telinha-server --porta 7790 --senha teste
python3 dado.py "telinha://127.0.0.1:7790#teste"
```
