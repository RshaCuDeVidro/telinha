# Changelog

## 3.0.0

Protocolo v6 (não conversa com a 2.x: todo mundo precisa atualizar).

**Consertos que vieram de uso de verdade**

- **Volume da transmissão funciona**: os botões por cima do vídeo (volume,
  mudo, destacar, parar) sumiam no clique porque eram desenhados só enquanto o
  mouse estava "em cima" do vídeo — e clicar num botão tirava o "em cima" do
  vídeo. Agora eles ganham o clique de verdade.
- **Fechar a sala derruba todo mundo na hora**, inclusive quem entrou pelo link
  público, com o aviso "o dono fechou a sala" (antes a conexão do túnel ficava
  pendurada e parecia que o link público era de mentira). O servidor espera a
  mensagem de despedida sair antes de fechar o socket.
- **Cada pessoa mostra por onde entrou**: rede local, internet (porta no
  roteador), IPv6 ou *via link público* — dá pra ver que o túnel é de verdade.
- **O programa morre ao fechar a janela** (antes, destrutores do driver da
  NVIDIA/PipeWire podiam travar a saída e o processo ficava vivo).

**Novidades**

- **Dono da sala é admin de verdade**: expulsar, banir (vale pra reconectar),
  silenciar, parar a transmissão de alguém, dar/tirar admin e trancar a sala
  (ninguém novo entra). Admin promovido não mexe em outro admin; ninguém mexe
  no dono. "Sair" de quem hospeda pergunta antes (fecha a sala pra todos).
- **Convite com vários caminhos**: `telinha://IP:porta,[IPv6]:porta,bore.pub:N#senha`.
  Quem entra tenta todos quase juntos e fica com o primeiro que responder como
  sala do telinha — quem tem IPv6 entra direto, quem não tem cai no link
  público sozinho.
- **Convite colado sozinho**: copiou um `telinha://…`, abriu o telinha, o campo
  já vem preenchido.
- **Câmera (webcam)** como uma transmissão a mais (PipeWire no Linux, inclusive
  MJPEG; Media Foundation no Windows). Escolha da câmera e 480p/720p/1080p nas
  configurações, trocando na hora sem derrubar quem assiste.
- **Zoom na transmissão**: roda do mouse aproxima, arrastar move, botão de
  *seguir o cursor* (o zoom anda junto com o mouse de quem transmite) e um
  minimapa. O transmissor manda a posição do cursor junto de cada quadro.
- **Ponteiro "olha aqui"**: liga o modo ponteiro e clica no vídeo — aparece um
  círculo com seu nome pra todo mundo que está vendo aquela transmissão.
- **Clipe dos últimos 30 s** (botão de tesoura) e **gravação em MP4**, sem
  recodificar nada: o H.264 que chega é guardado como veio (com o som). Vale pra
  quem assiste e pra própria transmissão. Pasta: Vídeos/telinha.
- **Janela flutuante** (picture-in-picture): uma transmissão numa janelinha por
  cima das outras, com volume; duplo clique volta. No Hyprland, regra de janela
  pelo título `telinha · …`.
- **Histórico do chat**: quem entra depois vê as últimas 50 mensagens (separadas
  por uma linha "mensagens de antes de você entrar").
- **Notificações do sistema** com o telinha em segundo plano: mensagem no chat,
  alguém ao vivo, alguém entrou (Linux: notificação do desktop; Windows: balão
  na bandeja + ícone piscando na barra de tarefas).
- **Windows: compartilhar só uma janela** (Windows.Graphics.Capture; PrintWindow
  de reserva onde não tiver), não só o monitor inteiro.
- **Windows: encoder na placa de qualquer marca** (Intel Quick Sync, AMD, NVIDIA)
  pelo Media Foundation quando não tem NVENC; openh264 se nada der. Encoder que
  ignora pedido de quadro-chave (alguns drivers) é recriado a cada pedido, pra
  quem entra depois não ficar com tela preta.

**Testes**

- **Testes de interface de verdade** (`tools/qa/run_qa.py`): o app roda em telas
  virtuais escondidas (Xvfb) e um robô clica nos botões pelo X11 e confere o
  estado que o app exporta (`TELINHA_QA=pasta`): volume da transmissão, fechar
  a sala, link público (com bore de mentira), menu de admin, câmera de teste,
  tela inicial, controles da sala, UPnP (roteador de mentira), reconexão,
  microfone de teste, convite colado, zoom e ponteiro, notificações, clipes e
  gravação (conferidos com ffprobe), janela flutuante, convite com vários
  caminhos e o `.exe` no wine (janela única, encoder). Nada aparece na sua tela,
  toca na sua caixa, abre seu microfone/câmera ou mexe no seu roteador.

## 2.1.0

- **Porta aberta no roteador (UPnP)**: conexão direta pra galera de fora, sem
  túnel no meio — menos atraso que o link público (que passa por outro
  continente) e sem o limite de banda dele. Detecta CGNAT da operadora e avisa
  (aí o link público é o caminho). No servidor dedicado: `--upnp`. A porta é
  renovada enquanto a sala está aberta, fechada quando ela fecha, e some
  sozinha em até 1 h se o app cair.
- **Espectador lento não derruba mais a qualidade de todo mundo**: a
  transmissão sai em duas camadas temporais e o servidor passa a mandar só
  metade dos quadros (os que os outros usam de referência) pra quem não está
  dando conta — por banda ou por CPU no decoder. Teste de carga com 8
  espectadores + 1 num link de 2 Mbit/s: a taxa da sala ficou em ~89% (antes
  caía pra 50%) e o lento com ~90 ms de atraso (antes ~360 ms), a 15 q/s.
- **Cancelamento de eco** (SpeexDSP) na voz: dá pra falar com caixa de som em
  vez de fone sem a sala se ouvir de volta. A referência é o que o mixer
  acabou de tocar; um detector de atraso acha onde o eco está (até 500 ms:
  caixa Bluetooth funciona) e alinha a referência; a deriva entre os relógios
  da caixa e do microfone é medida e compensada (reamostragem), o que vale uns
  15 dB a mais quando eles são dispositivos diferentes (ex.: microfone USB +
  placa onboard); e o resto de eco não abre o portão de voz. Testado de ponta
  a ponta num PipeWire isolado: o eco para de vazar em ~2 s de fala do outro
  lado. Liga/desliga nas configurações (ligado por padrão).
- Tela parada não deixa mais o espectador preso na imagem velha depois de um
  recomeço: o servidor pede o IDR sozinho (antes esperava o próximo quadro do
  transmissor, que com a tela parada não vinha).
- Sensibilidade do microfone muda na hora (antes só reabria o microfone em
  alguns casos e a mudança podia se perder); sons de aviso tocam mesmo com
  "surdo" ligado (dá pra ouvir o surdo ligando).
- Robustez: o servidor ignora `watch` de quem não existe (a lista não cresce
  sem limite), recusa entrada no meio do fechamento da sala, e descarta voz
  vazia; o mixer não abre a saída de som duas vezes quando duas transmissões
  chegam juntas; a captura do PipeWire aguenta grafos grandes (4096 portas).
- **Voz na sala, tipo Discord**: microfone com supressão de ruído (RNNoise) e
  ativação por voz, Opus 40 kbit/s. Anel verde em quem fala, ícones de
  microfone desligado e "surdo" na lista, botões de microfone/surdo no painel,
  volume da voz por pessoa (clique direito), escolha de microfone e
  sensibilidade com medidor nas configurações. O microfone começa desligado
  (opção pra entrar com ele ligado). A voz fura a fila do vídeo.
- Painel de baixo no estilo do Discord: faixa com "Compartilhar tela" e sair;
  microfone, fone e configurações no painel do usuário.
- Chat: o que se digitava logo depois do Enter perdia a primeira letra (a
  caixa perdia o foco e só voltava quadros depois). Agora ela continua ativa
  e é esvaziada no mesmo quadro do Enter.
- Atalhos Ctrl+M (microfone) e Ctrl+D (surdo); contorno verde na transmissão
  de quem está falando; sons de aviso sintetizados (entrou/saiu, ao vivo,
  microfone — dá pra desligar); volume da voz de cada pessoa lembrado pelo nome.

- Controle de atraso de ponta a ponta (protocolo v5): confirmação de cada frame
  nos dois trechos (transmissor → servidor → espectador). O atraso fica
  limitado mesmo atrás de túneis com buffer enorme (ngrok, bore…).
- Controle de taxa novo (`ratectl.zig`): desce de leve quando o atraso começa a
  crescer, pula quadro quando atrasa de verdade, sobe rápido até perto do teto
  e depois só sonda. IDR grande não derruba a qualidade.
- Espectador que não dá conta: recomeça de um IDR com espera crescente (a sala
  não enche de IDR) e pede taxa menor ao transmissor — até a metade se for só
  ele, o quanto precisar se for a maioria (ex.: upload de quem hospeda a sala).
- Fila do decoder por tempo (150 ms) em vez de 3 quadros: um IDR grande não
  causa mais recomeço; quadros atrasados são decodificados sem ir pra tela.
- Linux: `TCP_NOTSENT_LOWAT` em vez de buffer de envio fixo.
- `zig build loadtest`: teste de carga com link lento, maioria lenta e túnel ruim.
- Captura no Wayland por **DMA-BUF**: o compositor copia a tela GPU→GPU, sem
  ler a imagem de volta pra RAM no próprio loop de renderização (era isso que
  travava o mouse de leve enquanto compartilhava). A leitura acontece na thread
  do telinha, via EGL carregado em tempo de execução; sem EGL/suporte, volta
  pra memória compartilhada sozinho.
- O limite de fps agora vai no `maxFramerate`, que é o que o portal do
  Hyprland usa: antes ele copiava a tela na taxa do monitor (ex.: 144x/s)
  mesmo transmitindo a 30 fps.
- Memória compartilhada em 24 bits e 10 bits por canal (monitor HDR/10 bits)
  é aceita e convertida; antes a negociação falhava nesses casos.
- Erro claro se o compositor aceitar compartilhar mas não mandar nenhum quadro.
- `zig build captest`: diagnóstico da captura (método, formato, fps real,
  custo por quadro, salva um quadro em PPM).
- **Link público embutido**: *Criar link público* abre um túnel pelo protocolo
  do bore (bore.pub), sem instalar nada; o convite já sai com o endereço.
  Sala pública sempre tem senha (criada se faltar). Reconecta pedindo a mesma
  porta. Também no servidor dedicado: `telinha-server --publico`.
- A opção de áudio agora é lembrada entre execuções (era salva mas não lida).
- **NVENC com bem mais qualidade** (medida com PSNR no `zig build bench`):
  perfil High + CABAC + transformada 8x8, preset P4 (até 1080p60), taxa média
  = alvo (era 75%) e IDR com folga no VBV. Numa tela de código em 1080p: de
  ~37 para 57 dB, e o quadro completo que sai quando alguém entra na sala deixou
  de ficar borrado (34 → 45 dB). O decoder do openh264 agora solta a imagem na
  hora também em perfil High (FlushFrame).
- `zig build bench` mede qualidade (PSNR) x tempo por encoder/preset,
  inclusive com uma captura de tela de verdade.
- **Linux: áudio sem eco e sem silenciar o que você assiste.** A captura liga
  cada aplicativo direto numa entrada do telinha no grafo do PipeWire, menos o
  próprio telinha (antes: monitor da saída, que pegava tudo, e o app silenciava
  o que você assistia enquanto compartilhava áudio). `zig build audiotest`.

## 2.0.0

Reescrita completa.

- Interface nova estilo Discord (Dear ImGui): salas, chat, membros, várias transmissões em grade, destaque, modo cinema.
- Qualquer pessoa da sala transmite e assiste; Linux ↔ Windows nos dois sentidos.
- Vídeo H.264: NVIDIA NVENC/NVDEC quando disponível, openh264 (SIMD, multithread) como alternativa; conversão de cor de quem assiste num shader.
- Reconexão automática com retomada da transmissão e de quem você assistia.
- Áudio do computador junto com a tela (Opus, 10 ms, volume e mudo por transmissão).
- Pipeline em duas threads (captura ∥ encode), controle de banda adaptativo, descarte de atraso por espectador.
- Criptografia X25519 + ChaCha20-Poly1305 com a senha da sala na derivação das chaves.
- Captura: PipeWire/xdg-desktop-portal (Wayland), X11, DXGI (Windows); no Hyprland o cursor é desenhado pelo telinha pra não deixar o mouse com lag.
- Latência de ponta a ponta medida e mostrada nas estatísticas.
- Servidor dedicado estático (`telinha-server`, Linux x86_64/aarch64), Docker, systemd.
- Admin com expulsão, convites `telinha://`, configurações salvas.
- Testes de unidade e integração, benchmark, CI no GitHub Actions.

## 1.0.0

- Primeira versão: um servidor Linux (wlr-screencopy) e um visualizador Windows, JPEG por tiles.
