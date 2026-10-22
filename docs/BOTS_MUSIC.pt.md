# Bot de música

<sub>[🇺🇸 English](BOTS_MUSIC.md) · [🇧🇷 Português](BOTS_MUSIC.pt.md)</sub>

Toca música na call da sala. Quem está na call ouve, e cada um ajusta o
volume do bot só pra si (clique direito no nome dele). Ele toca:

- músicas de uma **pasta** (mp3, flac, ogg, opus, m4a, wav...), achando pelo nome;
- **arquivos mandados na sala**: responda o arquivo com `!tocar`;
- **rádios** online, de uma lista sua;
- **links** diretos de áudio, se você ligar (`--links`).

O som vai como a voz do bot (Opus estéreo, 128 kbit/s, pacotes de 20 ms):
quem transmite não gasta nada com isso, e quem está no navegador também ouve.

## Rodar

Precisa do Python 3.10+, do ffmpeg e do repositório (ou só da pasta
`bots/musica` junto com o SDK instalado):

```sh
sudo apt install ffmpeg python3-venv        # (Arch: pacman -S ffmpeg python)
git clone https://github.com/RshaCuDeVidro/telinha
cd telinha
python3 -m venv .venv && .venv/bin/pip install ./sdk/python
.venv/bin/python bots/musica/musica.py "telinha://minha.sala:7777#senha" --pasta ~/Música
```

| Opção | Variável | |
|---|---|---|
| `convite` | `TELINHA_CONVITE` | o convite da sala (o do botão **Copiar convite**) |
| `--pasta` | `TELINHA_MUSICAS` | pasta com as músicas (procura nas subpastas também) |
| `--radios` | `TELINHA_RADIOS` | arquivo com as rádios (abaixo) |
| `--links` | `TELINHA_LINKS=1` | aceita links `http(s)://` diretos de áudio |
| `--volume` | `TELINHA_VOLUME` | volume inicial, de 0 a 200 (padrão 70) |
| `--nome` | `TELINHA_BOT_NOME` | o nome na sala (padrão "Música") |
| `--canal` | | canal pra entrar (senão o do convite) |
| `--token-bots` | `TELINHA_TOKEN_BOTS` | se a sala pede token de bot |
| `--prefixo` | | antes dos comandos (padrão `!`) |

## Comandos

| Comando | Também | |
|---|---|---|
| `!tocar nome` | `!play`, `!p` | toca (ou põe na fila) a música da pasta que tem esse nome, uma rádio ou um link |
| `!tocar` respondendo um arquivo | | toca o arquivo de áudio mandado na sala |
| `!fila` | `!queue`, `!q` | o que está tocando e o que vem depois |
| `!pular` | `!skip`, `!s` | pula pra próxima |
| `!pausar` / `!continuar` | `!pause` / `!resume` | |
| `!parar` | `!stop` | para e limpa a fila |
| `!volume 80` | `!vol`, `!v` | volume pra todo mundo (0 a 200); sem número, mostra o atual |
| `!tocando` | `!np`, `!agora` | a música atual e quanto já tocou |
| `!lista palavra` | `!busca` | lista as músicas da pasta (com filtro) |
| `!radios` | | as rádios configuradas |
| `!aleatorio` | `!shuffle` | liga/desliga a ordem aleatória |
| `!repetir uma` | `!loop` | repetir `nada`, `uma` (a atual) ou a `fila` |
| `!vem` | `!entra` | o bot entra na call do canal onde você digitou |
| `!ajuda` | | todos os comandos |

A busca não liga pra acento nem maiúscula: `!tocar cancao` acha
"Canção do Mar.mp3", e várias palavras precisam aparecer todas.

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

E na sala: `!tocar lofi`.

## Deixar ligado na VPS

Do lado do [servidor dedicado](DEPLOY.pt.md), com systemd. Crie um usuário só
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

Na mesma máquina do servidor, o convite pode usar `127.0.0.1`.

> [!NOTE]
> **YouTube e afins ficam de fora.** Baixar de lá vai contra os termos de uso
> deles, e foi isso que derrubou os bots de música famosos do Discord. Pasta,
> arquivos da sala, rádios e links diretos cobrem o uso do dia a dia.

## Problemas

- **"precisa do ffmpeg"**: instale o ffmpeg (com libopus, que quase todo tem).
- **"a sala recusou o bot"**: a sala está com `--sem-bots`, ou pede
  `--token-bots` e o token não bate.
- **Ninguém ouve**: o bot toca na call em que está. Digite `!vem` no canal da
  call, e confira que ninguém silenciou o bot (o admin, ou o volume dele no
  seu clique direito).
- **Picotando**: é a internet da máquina do bot (ele manda ~130 kbit/s). Numa
  VPS isso some.
