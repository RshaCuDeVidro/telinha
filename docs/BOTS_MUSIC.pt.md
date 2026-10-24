# Bot de música

<sub>[🇺🇸 English](BOTS_MUSIC.md) · [🇧🇷 Português](BOTS_MUSIC.pt.md)</sub>

Toca música na call da sala. Quem está na call ouve, e cada um ajusta o
volume do bot só pra si (clique direito no nome dele). Ele toca:

- **links**: YouTube, SoundCloud, Bandcamp e tudo o que o
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) abre (playlists também, até 50
  músicas). Link de música do Spotify, Deezer, Apple Music e Tidal vira uma
  busca pelo nome da música;
- uma **busca** pelo nome: `!play popular monster` toca o primeiro resultado,
  e `!search` mostra cinco pra escolher nos botões;
- músicas de uma **pasta** (mp3, flac, ogg, opus, m4a, wav...), achando pelo nome;
- **arquivos mandados na sala**: responda o arquivo com `!play`;
- **rádios** online, de uma lista sua.

Ele responde com **cartões**: o do "tocando agora" tem a capa, uma barra de
progresso que anda sozinha e botões (pausar, pular, parar, aleatório, repetir)
que qualquer um da sala pode clicar. O cartão muda no lugar quando algo muda,
em vez de encher o chat.

O som vai como a voz do bot (Opus estéreo, 128 kbit/s, pacotes de 20 ms):
quem transmite não gasta nada com isso, e quem está no navegador também ouve.

Os comandos e as respostas são em inglês (como nos bots de música que todo
mundo conhece); os da 3.3, em português, continuam valendo como apelidos.

## Rodar

Precisa do Python 3.10+, do ffmpeg e do repositório (ou só da pasta
`bots/musica` junto com o SDK instalado). O yt-dlp é opcional: sem ele, o bot
toca só a pasta, os arquivos da sala, as rádios e links diretos de áudio.

```sh
sudo apt install ffmpeg python3-venv        # (Arch: pacman -S ffmpeg python)
git clone https://github.com/RshaCuDeVidro/telinha
cd telinha
python3 -m venv .venv && .venv/bin/pip install ./sdk/python yt-dlp
.venv/bin/python bots/musica/musica.py "telinha://minha.sala:7777#senha" --folder ~/Música
```

| Opção | Variável | |
|---|---|---|
| `convite` | `TELINHA_CONVITE` | o convite da sala (o do botão **Copiar convite**) |
| `--folder` | `TELINHA_MUSICAS` | pasta com as músicas (procura nas subpastas também) |
| `--radios` | `TELINHA_RADIOS` | arquivo com as rádios (abaixo) |
| `--search` | `TELINHA_BUSCA` | onde buscar, em ordem (padrão `youtube,soundcloud`) |
| `--cookies` | `TELINHA_YT_COOKIES` | arquivo de cookies do YouTube, pra servidor que o YouTube bloqueia (abaixo) |
| `--volume` | `TELINHA_VOLUME` | volume inicial, de 0 a 200 (padrão 70) |
| `--name` | `TELINHA_BOT_NOME` | o nome na sala (padrão "Música") |
| `--channel` | | canal pra entrar (senão o do convite) |
| `--bot-token` | `TELINHA_TOKEN_BOTS` | se a sala pede token de bot |
| `--prefix` | | antes dos comandos (padrão `!`) |

Os nomes em português das opções da 3.3 (`--pasta`, `--nome`, `--canal`,
`--token-bots`, `--prefixo`) continuam funcionando.

## Comandos

| Comando | Também | |
|---|---|---|
| `!play nome ou link` | `!p`, `!tocar` | toca, ou põe na fila se já tiver algo tocando |
| `!play` respondendo um arquivo | | toca o arquivo de áudio mandado na sala |
| `!play` | | continua, se estiver pausado |
| `!search nome` | `!find`, `!buscar` | cinco resultados, com um botão pra cada |
| `!queue` | `!q`, `!fila` | o que está tocando e o que vem depois |
| `!skip` | `!s`, `!next`, `!pular` | pula pra próxima |
| `!pause` / `!resume` | `!pausar` / `!continuar` | |
| `!stop` | `!parar` | para e limpa a fila |
| `!volume 80` | `!vol`, `!v` | volume pra todo mundo (0 a 200); sem número, mostra |
| `!np` | `!now`, `!tocando` | manda o cartão do "tocando agora" de novo, no fim do chat |
| `!loop one` | `!repeat`, `!repetir` | `off`, `one` (a atual) ou `all` (a fila); sozinho, vai alternando |
| `!shuffle` | `!aleatorio` | liga/desliga o aleatório |
| `!remove 2` | `!rm`, `!remover` | tira a música 2 da fila |
| `!clear` | `!limpar` | limpa a fila (a atual continua) |
| `!radios` / `!radio nome` | | as rádios (com botões), ou toca uma |
| `!list palavra` | `!library`, `!lista` | as músicas da pasta do bot (com filtro) |
| `!join canal` | `!vem`, `!entra` | o bot entra na call daquele canal |
| `!leave` | `!sair` | sai da call (e para) |
| `!help` | `!ajuda` | o cartão de ajuda |

A busca na pasta ignora acento e maiúscula: `!play cancao` acha
"Canção do Mar.mp3", e várias palavras precisam aparecer todas. A ordem é:
uma rádio com esse nome, depois a pasta, depois a internet.

### Chamar o bot pra qualquer canal

`!join` sem nome traz o bot pra call **de quem pediu**. Como um comando
digitado num canal só chega no bot se ele estiver naquele canal, de qualquer
outro lugar mande em privado:

```text
/msg Música !join
```

Mensagem privada chega no bot de qualquer canal, e ele vem pra call em que
você está (ou pro seu canal, se você não estiver em call). `!join jogos`
também funciona de onde o bot estiver. O nome não precisa de acento nem de
maiúscula (`/msg musica !join` acha o Música), e no app tem o atalho: clique
direito no bot → **Chamar pra minha call**.

Nem precisa do `!join`: `/msg Música !play nome da música` de quem está numa
call traz o bot pra lá e já toca (se ele estiver tocando pra outra call, a
música vai pra fila de lá e ele avisa).

## Rádios

Um arquivo com `nome = endereço` por linha:

```ini
# radios.txt
lofi = https://exemplo.com/lofi.mp3
jazz = https://exemplo.com/jazz.aac
```

```sh
python3 bots/musica/musica.py "telinha://..." --radios radios.txt
```

E na sala: `!radio lofi`, ou `!radios` e um botão. O repositório tem um
exemplo com as rádios da SomaFM, `bots/musica/radios-somafm.txt`.

## YouTube num servidor

O YouTube recusa muitos IPs de datacenter ("Sign in to confirm you're not a
bot"). Quando isso acontece, o bot lembra por 30 minutos e toca a mesma
música pelo **SoundCloud** (pelo nome), então o `!play` continua funcionando;
o rodapé do cartão diz de onde veio o som.

Pra ter o próprio YouTube numa VPS, dê pro bot os cookies de um navegador
logado (de preferência uma conta descartável), exportados no formato
Netscape (a extensão "Get cookies.txt LOCALLY" faz isso):

```sh
musica.py "telinha://..." --cookies /etc/telinha-yt-cookies.txt
```

> [!NOTE]
> Tocar do YouTube e sites parecidos pode ir contra os termos de uso deles.
> É opcional e fica a critério de quem roda o bot: sem o yt-dlp, o bot fica
> na pasta, nos arquivos da sala, nas rádios e nos links diretos.

## Deixar ligado na VPS

Junto do [servidor dedicado](DEPLOY.pt.md), com systemd. Crie um usuário só
pra ele e uma pasta de músicas:

```ini
# /etc/systemd/system/telinha-musica.service
[Unit]
Description=telinha: bot de música
After=network-online.target telinha.service
Wants=network-online.target

[Service]
User=musica
WorkingDirectory=/opt/telinha
EnvironmentFile=/etc/telinha-musica.env
ExecStart=/opt/telinha/.venv/bin/python bots/musica/musica.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/telinha-musica.env  (chmod 600: tem a senha da sala)
TELINHA_CONVITE=telinha://127.0.0.1:7777#senha
TELINHA_MUSICAS=/srv/musicas
TELINHA_TOKEN_BOTS=o-token-de-bots-se-tiver
```

```sh
sudo systemctl enable --now telinha-musica
journalctl -u telinha-musica -f
```

Na mesma máquina do servidor, o convite pode usar `127.0.0.1`. Atualize o
yt-dlp de vez em quando (`.venv/bin/pip install -U yt-dlp`): os sites mudam e
versão velha para de abrir.

## Problemas

- **"precisa do ffmpeg" no log**: instale o ffmpeg (com libopus, que quase
  todo tem).
- **"the room refused the bot"**: a sala está com `--sem-bots`, ou pede
  `--token-bots` e o token não bate.
- **Link não toca**: instale (ou atualize) o yt-dlp no venv do bot.
- **Ninguém ouve**: o bot toca na call em que está. Mande `/msg Música !join`
  da sua call, e confira que ninguém silenciou o bot (o admin, ou o volume
  dele no seu clique direito).
- **App antigo**: app de antes da 3.4 mostra o cartão como texto (o nome da
  música), sem botões; os comandos funcionam igual.
- **Picotando**: é a internet da máquina do bot (ele manda ~130 kbit/s). Numa
  VPS isso some.
