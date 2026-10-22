# Bot de música / Music bot

Toca música na call do telinha, com cartões e botões: links (YouTube,
SoundCloud, Spotify...), busca pelo nome, pasta, arquivos da sala, rádios.
Plays music in a telinha call, with cards and buttons: links (YouTube,
SoundCloud, Spotify...), search by name, a folder, room files, radios.

```sh
python3 -m venv .venv && .venv/bin/pip install ./sdk/python yt-dlp
.venv/bin/python bots/musica/musica.py "telinha://minha.sala:7777#senha" --folder ~/Música
```

`!play nome ou link`, `!search`, `!queue`, `!skip`, `!np`, `!help`; de qualquer
canal / from any channel: `/msg Música !join`.

- Guia: https://rshacudevidro.github.io/telinha/docs/bots-music/
- Guide: https://rshacudevidro.github.io/telinha/en/docs/bots-music/

Testes / tests: `python3 -m unittest discover -s bots/musica -v`
(`TELINHA_TESTE_REDE=1` inclui os que buscam na internet / includes the ones
that search the internet).
