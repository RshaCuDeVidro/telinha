# Bot de tela (Telão)

<sub>[🇺🇸 English](BOTS_SCREEN.md) · [🇧🇷 Português](BOTS_SCREEN.pt.md)</sub>

Passa vídeos **na tela do bot**: ele transmite como qualquer pessoa da call, e
quem quiser clica nele e assiste, com som. Os controles ficam num **painel
encaixado embaixo do vídeo** (pausar, pular, parar, o que vem depois), que
qualquer um que está assistindo usa; o mesmo painel aparece no chat.

Ele passa:

- **links**: YouTube e tudo o que o [yt-dlp](https://github.com/yt-dlp/yt-dlp)
  abre (playlists também, até 50 vídeos), e links diretos de vídeo (`.mp4`,
  `.mkv`, `.webm`...);
- uma **busca** pelo nome: `!watch trailer` passa o primeiro resultado, e
  `!search` mostra cinco pra escolher nos botões;
- **vídeos mandados na sala**: responda o arquivo com `!watch`.

**Quase não gasta CPU**: o vídeo do YouTube já vem em H.264, o mesmo que o
telinha usa, então os pacotes passam direto, sem decodificar nem codificar de
novo. Vídeo em outro formato (VP9, AV1) o ffmpeg recodifica, e aí pesa (cerca
de um núcleo pra 720p).

## Rodar

Precisa do Python 3.10+, do ffmpeg (com o ffprobe, que vem junto) e do
repositório. O yt-dlp é opcional: sem ele, o bot passa só links diretos e os
vídeos da sala.

```sh
sudo apt install ffmpeg python3-venv        # (Arch: pacman -S ffmpeg python)
git clone https://github.com/RshaCuDeVidro/telinha
cd telinha
python3 -m venv .venv && .venv/bin/pip install ./sdk/python yt-dlp
.venv/bin/python bots/telao/telao.py "telinha://minha.sala:7777#senha"
```

| Opção | Variável | |
|---|---|---|
| `convite` | `TELINHA_CONVITE` | o convite da sala (o do botão **Convidar**) |
| `--max-height` | `TELINHA_ALTURA` | resolução máxima, de 144 a 1080 (padrão 720) |
| `--cookies` | `TELINHA_YT_COOKIES` | arquivo de cookies do YouTube, pra servidor que o YouTube bloqueia (abaixo) |
| `--name` | `TELINHA_BOT_NOME` | o nome na sala (padrão "Telão") |
| `--channel` | | canal pra entrar (senão o do convite) |
| `--bot-token` | `TELINHA_TOKEN_BOTS` | se a sala pede token de bot |
| `--prefix` | | antes dos comandos (padrão `!`) |

## Comandos

| Comando | Também | |
|---|---|---|
| `!watch nome ou link` | `!w`, `!play`, `!assistir`, `!ver` | passa o vídeo, ou põe na fila |
| `!watch` respondendo um vídeo | | passa o vídeo mandado na sala |
| `!search nome` | `!find`, `!buscar` | cinco resultados, com um botão pra cada |
| `!queue` | `!q`, `!fila` | o que está passando e o que vem depois |
| `!skip` | `!s`, `!next`, `!pular` | pula pro próximo |
| `!pause` / `!resume` | `!pausar` / `!continuar` | segura a imagem e o som juntos |
| `!stop` | `!parar` | para, limpa a fila e a tela some |
| `!join canal` | `!vem`, `!entra` | o bot entra na call daquele canal |
| `!leave` | `!sair` | sai da call |
| `!help` | `!ajuda` | o cartão de ajuda |

Quando a fila acaba, o bot para de transmitir; o próximo `!watch` liga de
novo.

### Chamar o bot pra sua call

O bot só transmite pra quem está na mesma call. De qualquer canal:

```text
/msg Telão !watch https://youtu.be/...
```

traz o bot pra call em que você está e já passa o vídeo. No app, o bot
aparece no painel mesmo estando em outro canal (em **Bots em outros
canais**): clique direito nele → **Chamar pra minha call**.

## Assistir

Clique no bot (no palco, em **Assistir**, ou no nome dele) como numa pessoa
transmitindo. O painel fica embaixo do vídeo enquanto ele está sozinho ou em
destaque no palco; em tela cheia, ele some (o chat continua com o mesmo
cartão).

Quem assiste pelo app 3.6 ou mais novo vê a 30 q/s em qualquer PC. App mais
velho, sem decodificador na placa de vídeo, engasga com o vídeo do YouTube
(ele usa quadros B, que o decodificador por software antigo não aguentava):
o app se atualiza sozinho.

## YouTube num servidor

O YouTube recusa muitos IPs de datacenter ("Sign in to confirm you're not a
bot"), e aí o `!watch` de um link do YouTube falha. Pra ter o YouTube numa VPS,
dê pro bot os cookies de um navegador logado (de preferência uma conta
descartável), exportados no formato Netscape (a extensão "Get cookies.txt
LOCALLY" faz isso):

```sh
telao.py "telinha://..." --cookies /etc/telinha-yt-cookies.txt
```

Links diretos e os outros sites continuam funcionando sem isso.

> [!NOTE]
> Passar vídeo do YouTube e sites parecidos pode ir contra os termos de uso
> deles. É opcional e fica a critério de quem roda o bot.

## Custo

- **CPU**: repassando H.264, quase nada (ler e mandar pacotes). Recodificando,
  cerca de um núcleo pra 720p a 30 q/s.
- **Internet**: o bot manda o vídeo uma vez pro servidor (1,5 a 3 Mbit/s em
  720p, conforme o vídeo), e o servidor manda uma cópia pra cada um que
  assiste. Na mesma máquina do servidor, a subida do bot nem passa pela
  internet.

## Deixar ligado na VPS

Igual ao [bot de música](BOTS_MUSIC.pt.md#deixar-ligado-na-vps): um usuário
só pra ele e um serviço do systemd.

```ini
# /etc/systemd/system/telinha-telao.service
[Unit]
Description=telinha: bot de tela
After=network-online.target telinha.service
Wants=network-online.target

[Service]
User=telao
WorkingDirectory=/opt/telinha
EnvironmentFile=/etc/telinha-telao.env
ExecStart=/opt/telinha/.venv/bin/python bots/telao/telao.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/telinha-telao.env  (chmod 600: tem a senha da sala)
TELINHA_CONVITE=telinha://127.0.0.1:7777#senha
TELINHA_TOKEN_BOTS=o-token-de-bots-se-tiver
```

## Fazer o seu

O bot é um exemplo do SDK: a peça que transmite é o
[`VideoPlayer`](BOTS_API.pt.md#transmitir-a-tela), e o painel é um
[cartão](BOTS_API.pt.md#embed) com `panel=True`. Pra uma tela que não é vídeo
(um placar, um quiz, um painel que a galera clica), use a `Screen`: ela só
manda imagem quando muda.

## Problemas

- **"precisa do ffmpeg" no log**: instale o ffmpeg (o ffprobe vem junto).
- **"YouTube refused this server"**: o IP da máquina está bloqueado pelo
  YouTube; use `--cookies` (acima).
- **Ninguém vê o bot**: ele transmite pra call em que está. Mande
  `/msg Telão !join` da sua call, ou use o **Chamar pra minha call**.
- **Engasgando pra uma pessoa só**: o app dela é antigo (atualize) ou o PC
  dela não dá conta; a bolinha de saúde no nome do bot diz o porquê.
