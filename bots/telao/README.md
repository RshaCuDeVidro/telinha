# Telão / Big screen

Passa vídeos na tela do bot, na call do telinha: quem está na call clica no
bot e assiste, com som, e o painel (pausar, pular, parar) fica embaixo do
vídeo. O H.264 do YouTube passa direto, sem recodificar: quase não gasta CPU.
Plays videos on the bot's screen in a telinha call: anyone in the call clicks
the bot and watches, with sound, and the control panel (pause, skip, stop)
sits under the video. YouTube's H.264 is passed straight through, without
re-encoding: it barely uses any CPU.

```sh
python3 -m venv .venv && .venv/bin/pip install ./sdk/python yt-dlp
.venv/bin/python bots/telao/telao.py "telinha://minha.sala:7777#senha"
```

`!watch nome ou link`, `!search`, `!queue`, `!skip`, `!pause`, `!stop`,
`!help`; de qualquer canal / from any channel: `/msg Telão !watch link`.

- Guia: https://rshacudevidro.github.io/telinha/docs/bots-screen/
- Guide: https://rshacudevidro.github.io/telinha/en/docs/bots-screen/

Testes / tests: `python3 -m unittest discover -s bots/telao -v`
