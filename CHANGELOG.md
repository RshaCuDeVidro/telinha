# Changelog

## 3.1.0

Conversa com a 3.0 (os campos novos são opcionais).

- **Vídeo, som e voz por UDP**: um pacote perdido não segura mais tudo que vem
  atrás (no TCP, a voz ficava presa atrás de um quadro de vídeo, e perda no
  fim de uma rajada custava ~200 ms). Quem recebe pede de volta só o pedaço
  que faltou; som e voz não esperam ninguém. Com 5% de perda simulada nos dois
  sentidos, nada se perdeu de vez e o atraso ficou em ~50 ms. Se o UDP não
  passa (link público, firewall), fica no TCP sozinho; a porta no roteador
  (UPnP) abre o UDP também.
- **HEVC na placa de vídeo** (NVIDIA): mesma qualidade com bem menos banda
  (+4 dB num teste de texto rolando a 2 Mbit/s). A sala negocia: só vai em
  HEVC se todo mundo que assiste decodifica; entrou alguém que não, volta pro
  H.264 na hora, sem ninguém perder a imagem. Clipes e gravações em HEVC
  também.
- **Placa de vídeo pra assistir no Windows** com qualquer placa (Media
  Foundation/DXVA: Intel, AMD, NVIDIA), não só NVIDIA.
- **Placa de vídeo no Linux com Intel/AMD** (VA-API): decodificação bit a bit
  igual à do openh264/ffmpeg; codificação com um autoteste ao abrir (se o
  driver gerar lixo, o telinha percebe e fica no openh264).
- **Som de um programa só**: na janela de compartilhar, escolha entre todo o
  som do computador, só o da janela que está sendo compartilhada, um programa
  que está tocando agora (Spotify, navegador, jogo...) ou nenhum — dá pra
  trocar com a transmissão rolando.
- **Chat**: imagens (cole com Ctrl+V ou arraste o arquivo pra janela; abre em
  tela cheia com um clique), reações (curti, amei, haha, fogo, uau, triste) e
  @menções com Tab pra completar, destaque e notificação. A imagem vai como um
  quadro de vídeo: nada de leitor de PNG/JPEG exposto à rede.
- **Aviso de versão nova**: se alguém na sala estiver numa versão mais nova,
  você fica sabendo; e o app pode perguntar ao GitHub ao abrir (desligável).
  A mensagem de "versão diferente" agora diz quem precisa atualizar.
- Configurações e janela de compartilhar rolam em tela baixa (os botões do fim
  não somem mais).
- **Interface em inglês** (automático pelo idioma do sistema, ou escolhido nas
  configurações). Os textos que vêm do servidor (avisos do chat, motivos de
  recusa) também são traduzidos.
- **Configurações em páginas** (Geral, Aparência, Voz, Câmera, Desempenho,
  Depuração, Sobre), numa janela mais larga com barra lateral.
- **Ícone novo**: um husky espiando por cima da tela (um olho azul e um
  castanho).
- **Excluir programas do som**: compartilhando "todo o som", dá pra deixar
  programas de fora (o Discord, por exemplo, pra quem assiste não ouvir a
  própria voz de volta). No Windows o sistema só deixa excluir um processo
  por captura, então o telinha captura cada programa tocando e mistura.
- **Qualidade automática**: se o PC não dá conta do fps escolhido, a
  transmissão desce a resolução um degrau (1080p → 900p → 720p...) e volta
  sozinha quando sobra folga; quem transmite é avisado. Desligável em
  Desempenho.
- **Testar meu PC** (Desempenho): uns segundos medindo encoder na CPU e na
  placa e o decoder, com a resolução/fps sugeridos e um botão pra usar.
- **Relatório de travamento**: se o app cair, ele anota o motivo e a pilha;
  na próxima abertura pergunta se manda (gofile ou webhook, igual ao log).
- **Tema personalizado**: escolha fundo, painéis, destaque, texto, verde e
  vermelho (o resto sai delas), ou **cole um CSS** e o telinha lê as
  variáveis do `:root` (`--bg-dark`, `--neon-purple`...); dá pra copiar o
  tema como CSS, ou apontar pra um **arquivo .css** que o telinha acompanha
  (salvou o arquivo, o tema muda; uma thread olha a cada 1,5 s e só monta o
  tema se o conteúdo mudou). Fira Code nos temas pwnd, **tamanho da interface** (80% a
  150%) e **efeito CRT** opcional (linhas de tela antiga, sem cobrir o vídeo).
- **Atalho global pra salvar clipe** (Geral → Clipes): uma tecla ou botão do
  mouse que salva o clipe da transmissão em destaque com o jogo em foco
  (Windows e X11; no Wayland, com o telinha em foco).
- **Print de uma transmissão** (botão no quadro): PNG na resolução cheia,
  na pasta dos clipes.
- Gravação com a tela parada no fim não sai mais curta: o último quadro dura
  até a hora em que você parou (e o som vai até lá). Se o pedido de quadro
  completo pra começar a gravação se perder, é pedido de novo.
- **Duração do clipe** escolhível (15 s, 30 s, 1, 2 ou 3 min). Com clipe
  curto, quem assiste pede um quadro completo mais seguido, pro clipe começar
  perto do tempo pedido.
- **Transmitir só um pedaço da tela**: no quadro da sua transmissão, o botão
  de recortar deixa arrastar um retângulo em cima da própria tela (botão
  direito volta pra tela inteira).
- **Desenhar por cima da transmissão**: quem assiste (ou quem transmite) risca
  em cima do vídeo, todo mundo que está vendo aquela tela vê, e o traço some
  sozinho em alguns segundos (botão direito apaga os seus).
- **Apertar pra falar** (Configurações → Voz): a voz só sai com a tecla (ou
  botão lateral do mouse) apertada, valendo com o jogo em foco no Windows e
  no X11; no Wayland, com o telinha em foco.
- **Voz mais resistente a perda**: FEC do Opus (um pacote perdido é
  recuperado pelo seguinte).
- **Temas** (Configurações → Tema, troca na hora): Escuro (o de sempre),
  Claro, pwnd (preto com fúcsia e roxo neon e verde de terminal, cantos quase
  retos), pwnd claro, Nord e Drácula. O texto dos botões escolhe sozinho entre
  branco e escuro pelo contraste.
- **Log de depuração** (Configurações → Depuração): grava num arquivo tudo que
  ajuda a achar um problema de desempenho — sistema, processador, memória,
  placas de vídeo, driver, OpenGL, monitores, configurações (sem senhas) e, a
  cada 2 s, CPU do app e do computador (no Linux, por thread), memória, fps e
  tempo de quadro da interface, ping/fila/UDP da sala, e cada transmissão
  assistida (fps, resolução, banda, codec, decoder, tempo de decodificação,
  atraso) ou enviada (captura, encoder, tempo de codificação, banda alvo,
  congestionamento), além dos avisos, eventos e das mensagens internas de
  depuração. Um botão manda o log: pelo **gofile.io** (sem conta; volta um
  link pra copiar) ou por um **webhook** (Discord etc.: o arquivo chega no
  canal). Fica ligado entre aberturas até desligar; o arquivo é cortado se
  passar de 24 MB.

**Desempenho e memória** (medido antes/depois nos mesmos cenários):

- **Transmitir sem passar pela CPU** (Linux + NVIDIA): o quadro que o
  compositor entrega na placa (DMA-BUF) é recortado, escalado e ganha o
  cursor ali mesmo, e vai pro NVENC por CUDA — nada é lido de volta pra
  RAM. Antes cada quadro 1080p custava uma leitura de 3-5 ms mais uma cópia
  de 8 MB pro encoder; medido em 1080p: 4,7 ms → 0,3 ms de CPU por quadro.
  A prévia da própria tela sai pequena, direto da placa. Se o encoder for
  outro (VA-API, software) ou o compositor mandar memória comum, continua
  como antes. A preparação da placa (shader, registro no CUDA, buffers) é
  feita numa thread à parte com um contexto GL compartilhado: feita na
  thread do PipeWire, ela segurava os buffers do portal por ~80 ms, o portal
  desistia do DMA-BUF e a captura morria ou trocava de caminho no meio.
  Se a captura muda de caminho no meio (a placa falhou, o compositor
  renegociou o formato), o quadro da placa e o quadro pela CPU têm sinais
  separados — antes, um quadro da placa podia ser lido como se estivesse na
  memória, e o app caía (SIGSEGV na escala do quadro).
- **Assistir sem passar pela CPU** (NVIDIA, Linux e Windows): o quadro do
  NVDEC vai direto pra textura que aparece (CUDA ↔ OpenGL), sem as duas
  cópias de 3 MB por quadro (placa → RAM → placa). Quem assiste 1080p60 com
  NVIDIA gasta uns 3% de um núcleo.
- **Interface não fica mais a 60 q/s parada**: o campo do chat com foco
  contava como "atividade" e impedia o laço de dormir (no log do usuário a
  interface redesenhava 60 vezes por segundo o tempo todo).
- Ninguém assistindo (e sem gravar): a captura nem lê o quadro do
  compositor (antes lia 60 vezes por segundo a 3-5 ms cada, pra jogar fora).
- Threads com nome no log de depuração (captura, encoder, decoder, rede,
  udp, sala-…), em vez de "telinha" seis vezes.
- **Atalhos** (página nova nas configurações): salvar clipe, microfone,
  surdo, transmitir/parar, print e um que liga/desliga todos os outros. Cada
  um aceita qualquer tecla, combinação (Ctrl+Shift+K) ou botão do meio/
  laterais do mouse, e vale com o jogo em foco (Windows e X11; no Wayland só
  com o telinha em foco).
- **Duração do clipe livre** (5 s a 10 min), além dos botões de 15 s a 3 min.
- **Menos placa de vídeo pra assistir**: a conversão de cor do vídeo sai no
  tamanho em que ele aparece na tela (um 1080p num quadradinho não converte
  1080p), e quem não está aparecendo (outro em destaque, minimizado) não
  converte nada; se o quadro crescer com a imagem parada, reconverte dos
  planos que já estão na placa. Duas transmissões em grade: 155% → 72% de
  CPU no teste com OpenGL em software (no PC de verdade isso é trabalho da
  placa).
- **Encoder da placa: leve, equilibrado ou qualidade** (Desempenho). O
  padrão agora é o equilibrado (preset P3 do NVENC, antes P4); o leve usa P1
  e desliga o AQ, que roda nos núcleos CUDA — os mesmos do jogo.
- **Limite de quadros da interface** (Desempenho; 60 por padrão): mexer o
  mouse num monitor de 144 Hz não redesenha 144 vezes por segundo.
- Som da transmissão fura a fila de envio (antes esperava atrás de um quadro
  inteiro: um IDR de 60 KB a 2 Mbit/s segurava ~240 ms de som no TCP).
- Minimizado, as transmissões não sobem mais pra GPU (só a que está numa
  janela flutuante).
- Encoders de placa Intel/AMD (VA-API no Linux, Media Foundation no
  Windows): a conversão pra NV12 agora é vetorizada e dividida entre os
  núcleos (era C escalar numa thread só), e no VA-API vai direto pra memória
  do driver, sem o buffer intermediário. 1080p no i5-2400S: 3,5 → 2,5 ms por
  quadro (essa CPU já está perto do limite da memória; em CPU mais nova o
  ganho é maior), mais a cópia de ~3 MB que sumiu.
- Quem assiste: o decode converte o quadro sem trava e a interface sobe pra
  GPU sem segurar o decode (buffer triplo), sem engasgos de um esperando o
  outro.

- Transmitindo sem ninguém assistindo: nada é codificado nem enviado (a
  captura cai pra 5 q/s, só pra prévia) — de ~312% pra ~23% de CPU no teste.
- Som, voz e quadros que chegam não redesenham mais a interface inteira (só o
  quadro já decodificado, e quem começa a falar); animações, avisos e contagens
  pedem o próximo redesenho em vez de redesenhar sem parar; minimizado não
  desenha. Assistindo uma tela parada com som: ~47% menos CPU.
- Sala parada: de ~246 pra ~65 despertares/s (UDP dorme até ter trabalho; ping,
  UPnP e saída de som acordam bem menos; a saída de som pausa depois de 5 s de
  silêncio, deixando placa e fone Bluetooth dormirem).
- A miniatura da própria tela só é gerada quando aparece, a 15 q/s, e a
  textura é atualizada no lugar; o cancelamento de eco não roda com a caixa
  muda; o chat só monta as linhas visíveis.
- Memória: a sala que você fecha é liberada de verdade (antes ficava com o
  histórico e as imagens); um contexto CUDA compartilhado em vez de um por
  transmissão (~37 MB a menos cada); a glibc devolve a memória depois de parar
  transmissão/câmera (antes crescia ~15 MB a cada liga/desliga); imagens do
  chat em miniatura (a inteira só na tela cheia) e no máximo 24 MB guardados;
  o buffer de clipes respeita o teto mesmo sem quadro-chave novo.
- Rede: a escritora junta numa chamada só o que já está na fila; buffers que
  cresceram por causa de uma mensagem grande voltam ao normal.
- Windows: o timer de 1 ms só fica ligado transmitindo ou hospedando.

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
