# Changelog

<sub>[🇺🇸 English](CHANGELOG.md) · [🇧🇷 Português](CHANGELOG.pt.md)</sub>

## 3.4.0

Conversa com a 3.3, a 3.2 e a 3.1 (app antigo mostra o cartão como texto, sem botões).

### Destaques

- 🃏 **Cartões de bot**: em vez de texto puro, um bot responde com um cartão com capa, título, campos, uma barra de progresso que anda sozinha e até 5 botões que qualquer um da sala clica. O bot muda o cartão no lugar (o "tocando agora" vira "pausado" sem encher o chat). No app e no navegador.
- 🎵 **Bot de música novo**: toca link do YouTube, SoundCloud e Bandcamp (playlist também), link do Spotify, Deezer, Apple Music e Tidal (vira busca pelo nome), e busca pelo nome: `!play popular monster`, ou `!search` com botões pra escolher. Comandos em inglês (`!play`, `!queue`, `!skip`, `!np`...), e os em português continuam valendo.
- 📍 **O bot vai pra qualquer canal**: `/msg Música !join` de qualquer canal traz o bot pra sua call, e `!join jogos` manda ele pro #jogos.
- 🐍 **SDK 0.2**: `Embed` com botões que chamam a sua função, `edit()` pra mudar a mensagem, imagem e capa no `send`, e o bot sabe onde está quem falou com ele.

<!-- detalhes -->

### Todas as mudanças

- **Cartões** (protocolo): o cartão vai no fim do `chat` (até 8 KB; o servidor
  só confere tamanho e versão, quem desenha valida o resto). Mensagens novas:
  `chat_edit` (42), o autor muda a própria mensagem, no máximo a cada 200 ms; e
  `embed_action` (43), o clique, que vai só pro autor do cartão, no máximo a
  cada 120 ms por pessoa. Bot recebe junto onde está quem falou com ele ou
  clicou (canal e call), inclusive em privada. Ver docs/PROTOCOL.md.
- **No app**: barra da cor do cartão, capa (decodificada pelo mesmo decoder
  do vídeo, sem leitor de PNG/JPEG exposto à rede), título que vira link,
  Markdown, campos lado a lado, barra de progresso que anda sozinha (redesenha
  só a cada meio segundo, e só com o cartão na tela) e botões com ícones.
  Na página do navegador também.
- **Bot de música**: o "tocando agora" com capa, barra e os botões Pausar,
  Pular, Parar, Aleatório e Repetir, fechado como PLAYED/STOPPED quando acaba;
  `!search` com cinco resultados e um botão pra cada; `!queue`, `!np`,
  `!remove`, `!clear`, `!radios` com botões, `!leave`; o cartão de ajuda.
  Links pelo yt-dlp (opcional), playlists até 50 músicas. Quando o YouTube
  recusa o servidor ("Sign in to confirm you're not a bot"), toca a mesma
  música pelo SoundCloud e lembra por 30 minutos; `--cookies` pra ter o
  próprio YouTube. Arquivo da pasta mostra a duração, as tags e a capa
  embutida. Opções em inglês (`--folder`, `--name`...), as antigas continuam.
- **SDK**: `Embed`, `Button`, `Click` (`reply`, `whisper`), `Icon`, `Style`;
  `send(embed=, image=)`, `edit()`, `click()`, `ctx.reply_card()`; eventos
  `action` e `edit`; `Message.embed`, `author_channel`, `author_call`;
  `Player.play(headers=)`; `Bot(lang="en")` pras respostas do próprio SDK.
  Edições seguidas esperam a vez sozinhas (o servidor ignora a menos de
  200 ms) e imagens seguidas também (1,5 s).
- Os testes do bot de música rodam no CI contra o servidor recém-compilado.

## 3.3.0

Conversa com a 3.2 e a 3.1 (as mensagens novas são ignoradas por app e servidor antigos; mensagem privada e arquivo só vão pra quem entende).

### Destaques

- 🌍 **Assistir pelo navegador**: o servidor dedicado serve uma página que toca a transmissão, o som e a voz da call, sem instalar nada. Ele só repassa os mesmos quadros (nada é recodificado), então quem transmite não gasta nada a mais. Com `--web-tunel` o servidor ganha um link HTTPS por um túnel rápido da Cloudflare, sem conta; no app, um botão copia o link com a senha.
- 📎 **Arquivos na sala**: qualquer arquivo de até 256 MB, pelo clipe, arrastando pra janela ou com `/arquivo`. Sobe uma vez pro servidor e cada um baixa quando clicar, em segundo plano, sem atrapalhar vídeo, voz e chat.
- ↩️ **Responder citando** uma mensagem e **mensagem privada** (pelo menu da mensagem, da pessoa ou `/msg nome texto`).
- 🧪 **AV1 experimental** (NVIDIA RTX 40 em diante): mais nítido com a mesma banda, quando todo mundo que assiste decodifica. Desligado por padrão, em Configurações → Desempenho.
- 🤖 **Bots**: um SDK em Python pra fazer os seus (comandos, eventos, privada, música na call, arquivos) e um **bot de música** pronto (pasta, arquivos da sala, rádios). Aparecem com a etiqueta BOT e nunca viram admin.
- 🌐 **Site novo**, com a wiki inteira em português e inglês, busca e o guia de uso: https://rshacudevidro.github.io/telinha/

<!-- detalhes -->

### Todas as mudanças

- **Navegador**: `--web PORTA` sobe a página (WebCodecs: vídeo decodificado
  na placa; som e voz por um AudioWorklet com buffer curto; cursor desenhado
  na página) e um WebSocket que fala o mesmo protocolo. Quem entra pelo
  navegador é um membro normal (rota "navegador"): confirma cada quadro (o
  controle de atraso vale igual), diz o tamanho em que assiste e conversa no
  chat. Senha conferida em tempo constante; o navegador nunca vira admin.
  `--web-tunel` sobe o túnel rápido da Cloudflare (reinicia sozinho se cair)
  e divulga o link pra sala; `--web-link URL` pra quem tem domínio próprio.
  Ver docs/DEPLOY.pt.md.
- **Arquivos**: no servidor ficam no disco cifrados com ChaCha20 (a chave só
  existe na memória), com id sorteado; só baixa quem está no canal (ou os dois
  da conversa privada); somem depois de 2 h; 2 GB no total (`--arquivos`). O
  envio recua quando o atraso das confirmações sobe (como o LEDBAT). No app:
  barra de progresso, cartão no chat com baixar/abrir/pasta (executável só
  abre a pasta), downloads na pasta Downloads com `.parte` até terminar.
- **Resposta citando**: o trecho citado vem do histórico do servidor (ninguém
  forja citação) e quem foi respondido é avisado como numa menção.
- **Mensagem privada**: só os dois veem, em qualquer canal, fora do
  histórico; um app antigo (que mostraria pra todo mundo) não recebe.
- **AV1**: o NVENC na API 12 (o H.264/HEVC continua na 11.1, que roda em
  driver mais antigo); quem assiste decodifica pelo NVDEC (RTX 30 em diante)
  ou no navegador. Se o AV1 não abrir, a transmissão segue em HEVC/H.264.
  Clipes e gravações em AV1 saem em MP4 (av01).
- **Bots** (`sdk/python`, `bots/musica`): o bot se marca no `hello`
  (`feat_bot`) e aparece com a etiqueta BOT na lista e no chat (no app e no
  navegador); nunca vira admin, nem mandando o token do dono. No servidor
  dedicado, `--sem-bots` recusa todos e `--token-bots` pede um token só
  deles. O SDK fala o protocolo nativo (cifrado), reconecta sozinho, confere a
  identidade do servidor, toca som na call pelo ffmpeg (Opus estéreo de 20 ms,
  no ritmo) e manda/baixa arquivos; os testes dele rodam no CI contra o
  servidor recém-compilado. Guia, tutorial e referência no site.
- **Site** (GitHub Pages): gerado dos `.md` do repositório a cada push, com
  busca (Ctrl+K), índice da página, tema claro/escuro e o visual neon; docs
  novos de guia de uso, problemas comuns e bots.
- Os símbolos ▶ ⏸ ⏩ e afins agora carregam a fonte de emoji colorida (antes
  viravam "?").
- A pasta temporária de arquivos da sala criada pelo app não fica mais
  esquecida no /tmp.

## 3.2.0

Conversa com a 3.1 (as mensagens novas são ignoradas por app e servidor antigos).

### Destaques

- 🔄 **Atualiza sozinho** (Windows e Linux): saiu versão nova, o telinha mostra o que muda e instala com um clique (ou sozinho, se você quiser), depois de conferir a assinatura da release. As notas das versões antigas ficam no novo **histórico de versões** (Configurações → Sobre), e logo depois de atualizar aparecem as novidades.
- 🌐 **Mais jeitos de entrar de fora, sem serviço de terceiros**: além do UPnP, a porta no roteador abre também por NAT-PMP e PCP, e tem um guia de conexão, docs/CONNECTING.pt.md (abrir porta na mão, CGNAT, IPv6, VPN de jogo, túnel por SSH sem conta).
- 💬 **Canais, como no IRC**: um servidor, várias salas. Cada canal com o seu chat, e a **call** (voz e transmissões) é separada: dá pra ler um canal e continuar na call de outro. Canal pode ter senha, trava e tópico; os fixos sobrevivem a reiniciar.
- 🔐 **Identidade do servidor conferida**: o convite leva a impressão do servidor e o app confere antes de mandar qualquer coisa.
- 📝 **Markdown no chat**: blocos de código com botão de copiar, `código`, **negrito**, *itálico*, links; Shift+Enter quebra linha. Emoji colorido.
- 🖍️ **Cores e espessuras no pincel** (com marca-texto), esconder os desenhos dos outros, admin tira o pincel de alguém.
- 📊 **Estatísticas do servidor pro admin**: CPU, memória, banda, quem está atrasando e o gargalo provável, em português claro.
- ✨ **Tela inicial nova** com vitrine animada, e o quadro "chamando a galera de fora" mais limpo e com rolagem.
- 🎨 **Layout novo da sala**: barra no topo com quem está ao vivo, o palco no meio, uma cápsula de controles flutuante e um cartão só do lado com quem está na sala e o chat. Nada se sobrepõe, nem em janela pequena.
- 🖥️ **Botão de tela cheia** em cada transmissão; controles e cursor somem com o mouse parado.
- 🪟 **Windows**: Intel/AMD transmitem direto pela placa (processador de vídeo do D3D11 → Media Foundation), alt-tab não para mais a transmissão, janelas minimizadas aparecem na lista e a captura de som ficou mais firme.
- 🎙️ **Microfone baixo sobe sozinho** (ganho automático) e tem volume do microfone.
- 🛡️ **A sala aguenta** alguém entrando e saindo sem parar.
- 📜 **Log de depuração direto pro dono da sala**, e bem mais detalhe nele.

<!-- detalhes -->

### Todas as mudanças

- **Atualização sozinha**: a release traz o `SHA256SUMS` assinado com Ed25519
  (`SHA256SUMS.sig`, a chave fica com o CI); o app confere a assinatura com a
  chave pública que vem nele, baixa o executável da plataforma, confere o sha256
  e só então troca o próprio executável (Linux: rename atômico; Windows: o `.exe`
  em uso vira `.old`, apagado na próxima vez que abrir). "Reiniciar agora" abre
  de novo com os mesmos argumentos, depois que o antigo fecha (sala hospedada
  solta a porta antes). Se a pasta não deixa gravar (instalado como
  administrador), fica só o botão da página da release. Com o app aberto, checa
  de novo a cada 6 h. Opções: *Instalar as versões novas sozinho*, *Pular esta
  versão*.
- **O que muda, no seu idioma**: o aviso mostra todas as seções do changelog
  entre a sua versão e a nova (o `CHANGELOG` anexado à release, conferido pelo
  mesmo `SHA256SUMS`). Depois de atualizar, as *Novidades*; o histórico inteiro
  fica em Configurações → Sobre (os changelogs vão dentro do app).
- **Configurações na tela inicial** (engrenagem no canto): não precisa entrar
  numa sala pra trocar o idioma, a atualização etc.
- **NAT-PMP e PCP** (RFC 6886/6887) quando o roteador não responde ao UPnP: TCP e
  UDP, renovados na metade do prazo, devolvidos ao fechar; roteador que só fala
  PCP é reconhecido pelo erro de versão.
- **Guia de conexão** (`docs/CONNECTING.pt.md`, com link no app): IPv6, abrir a
  porta na mão passo a passo, como saber se é CGNAT e pedir IP público à
  operadora, Radmin/ZeroTier/Tailscale, túnel por SSH sem conta (Pinggy) e túnel
  reverso pra sua própria VPS. O comando do Pinggy entrou na lista do túnel
  próprio.
- **Texto desenhado no tamanho em que foi medido**: o ImGui arredonda o tamanho
  da fonte ao medir e o desenho não arredondava. O texto com markdown (chat,
  changelog) ficava com espaço sobrando entre as palavras e o sublinhado do link
  passava do texto.
- **A call é separada do canal de texto** (como no Discord): `/join` e o clique no
  nome do canal trocam só o chat; o fone de cada canal, `/call nome` ou o botão
  da cápsula entram/saem da call dele — onde ficam a voz e as transmissões (a
  sua transmissão vai junto pra call nova). Entrar na sala põe na call do canal
  de entrada; fora de call, o palco convida a entrar e transmitir entra
  sozinho. O painel mostra quem está no seu chat e, embaixo, quem está na sua
  call lendo outro canal. App antigo continua com chat e call juntos.
- **Admin dos canais**: clique direito num canal pra fixar, trancar (só admin
  entra), pôr senha (o painel pergunta quando alguém tenta entrar) ou tópico (no
  topo do chat); clique direito numa pessoa pra levar ela pra outro canal. Canais
  fixos com as configurações, banidos, silenciados e sem pincel ficam num arquivo
  de estado (`--estado`, do lado da chave por padrão) e voltam quando o servidor
  reinicia.
- **Identidade do servidor**: o servidor tem uma chave Ed25519 fixa e assina as
  duas metades de cada handshake logo depois dele (antes de o app mandar nome ou
  token de admin). O convite leva a impressão
  (`telinha://host!impressão#senha`) e o app exige ela; sem, lembra a primeira
  identidade vista naquele endereço e avisa (com o botão "Confiar na identidade
  nova") se ela mudar. A sala hospedada no app também tem chave fixa; o servidor
  dedicado usa `--chave` (padrão `/var/lib/telinha/servidor.key` ou
  `~/.config/telinha/servidor.key`, permissão 0600) e mostra a impressão.
- **Markdown no chat**: blocos de código entre ```` ``` ```` (fonte monoespaçada,
  a linguagem no canto, botão de copiar), `código`, **negrito**, *itálico*
  (inclinado na hora: a fonte não tem itálico) e links clicáveis. A caixa de
  mensagem é multilinha (Enter manda sem perder o foco, Shift+Enter quebra linha,
  cresce até ~7 linhas, 4000 bytes).
- **Emoji colorido** em nomes, chat e canais, com a fonte de emoji do sistema
  (Noto Color Emoji no Linux, Segoe UI Emoji no Windows) desenhada pelo
  FreeType. A fonte só é carregada quando aparece o primeiro emoji: quem não usa
  não gasta memória. Emoji compostos (família, tom de pele) aparecem na versão
  básica.
- **Clique direito numa mensagem**: copiar o texto ou responder (põe o `@nome` na
  caixa).
- **Escolher a imagem pelo seletor do sistema** no botão de anexar (portal no
  Linux, a janela de abrir arquivo no Windows); colar e arrastar continuam.
- **Pincel**: paleta embaixo da transmissão com 15 cores mais a sua, 4 espessuras
  (fina, normal, grossa, marca-texto), um botão pra esconder os desenhos dos
  outros (só pra você; também em Aparência) e a borracha dos seus. Cor e espessura
  vão em bits livres da mensagem de desenho (app antigo desenha na cor da pessoa).
  O admin pode tirar o pincel de alguém (os desenhos dela somem na hora; lembrado
  pela chave, como o silenciar) e devolver.
- **Canais (como no IRC)**: um servidor tem vários canais; cada um com o seu
  chat (histórico), lista de quem está nele, voz e transmissões (só dá pra
  assistir, apontar ou desenhar em quem está no seu canal). Troca pela lista de
  canais no painel da direita, pelo botão **+** (cria ou entra pelo nome), ou
  com `/join nome` (`/j`, `/canal`) no chat; `/canais` lista. A troca é na
  mesma conexão: a sua tela e a câmera vão junto (são anunciadas de novo no
  canal novo), e quem te assistia no canal velho para. Canal vazio some, a não
  ser que seja fixo. O servidor dedicado aceita `--canais "geral,jogos,..."`
  (canais fixos, o primeiro é o padrão; também `TELINHA_CANAIS`) e
  `--sem-canais-novos` (ninguém cria outros). A tela inicial ganhou o campo
  **Canal** (opcional), e o convite pode levar um:
  `telinha://host:7777/jogos#senha`. Reconectando, volta pro canal em que
  estava. App antigo continua funcionando (fica no canal padrão); app novo em
  servidor antigo só não mostra canais.
- **Estatísticas do servidor** pra quem entrou com o token de admin (botão de
  medidor no topo): CPU e memória do processo, banda saindo/chegando com
  gráfico de 2 minutos, gente (e quantos por UDP), canais, e por pessoa: canal,
  caminho, quanto recebe e manda, a fila de envio e se está atrasando ou
  recebendo metade. A parte "gargalos" explica o que está pegando (CPU do
  servidor, upload do servidor, a conexão de uma pessoa, alguém preso no
  TCP...). O servidor só mede com a janela aberta. Funciona no Linux e no
  Windows (e, com a sala dentro do app, avisa que os números são do app todo).
- **Tela inicial nova**: vitrine animada (uma telinha ao vivo com gente
  assistindo, reações subindo, mensagem do chat aparecendo) e um cartão com a
  escolha Entrar/Criar deslizando, campos com ícone e brilho no foco, e erro numa
  caixa. A animação só roda com o telinha em foco e alguém mexendo o mouse
  (congela depois de 12 s e o app volta a dormir), e dá pra desligar em
  Aparência. Em janela baixa o cartão rola.
- **O cartão "Criar sala" não treme mais**: a altura medida e a posição dele se
  corrigiam a cada quadro (posição em meio pixel).
- **"Chamando a galera de fora"** (sala vazia do anfitrião): link público e porta
  no roteador em dois cartões (um embaixo do outro em janela estreita), e a área
  toda rola — antes, em janela baixa, o fim ficava cortado sem ter como chegar.
  Abrir o "túnel próprio" rola até ele aparecer.
- **Layout novo da sala**: a barra lateral, a faixa da sala e o painel do
  usuário viraram uma barra no topo (sala, conexão, pílulas de quem está ao vivo
  — clique pra assistir — e cadeado/convite/chat/configurações na direita), o
  palco com as transmissões, uma cápsula flutuante (você, microfone, surdo,
  compartilhar, câmera, sair) e um cartão na direita com quem está na sala e o
  chat. Em janela estreita o cartão some (um botão traz de volta), as pílulas
  que não cabem viram "+N ao vivo" e a cápsula tira o seu nome e depois o texto
  do compartilhar. Tema padrão novo (azul tinta com destaque violeta). As
  reações do chat ficam embaixo da mensagem e quebram linha; as contagens
  apareciam erradas ("#") e foram consertadas.
- **Tela cheia** com botão na transmissão (além do clique duplo / F11); com o
  mouse parado um instante, os controles da transmissão e o cursor somem.
- **Windows, Intel/AMD sem passar pela CPU**: a captura DXGI recorta, escala e
  converte a tela pra NV12 no processador de vídeo do D3D11 e o Media
  Foundation codifica essa textura direto; a prévia também vai pela placa.
  Autoteste de cor contra a CPU ao abrir; qualquer falha (sem processador de
  vídeo, autoteste, encoder que não aceita textura, perdeu a tela) volta pro
  caminho da CPU. `TELINHA_SEM_D3DVP=1` desliga.
- **Alt-tab / jogo em tela cheia no Windows**: perder o acesso do DXGI (outro
  programa em tela cheia exclusiva, UAC, tela de bloqueio) é tentado de novo por
  30 s em vez de encerrar a transmissão, e se a transmissão parar sozinha o app
  recomeça (até 3 vezes por minuto).
- **Lista de janelas no Windows** mostra as minimizadas ("— minimizada");
  escolher uma restaura sem roubar o foco.
- **Som no Windows**: o WASAPI abre sem "hardware offloading" e tenta de novo
  com outras configurações (o erro "-2"); se capturar um programa só falhar,
  volta pra todo o som com aviso; aviso quando você exclui o som do próprio
  telinha sem querer. As mensagens da biblioteca de áudio vão pro log.
- **Microfone desmutando sozinho**: o silenciar do admin fica guardado pela
  chave da pessoa, então sair e voltar não tira mais.
- **Microfone baixo**: ganho automático (até +18 dB, medido só na fala pra não
  subir o ruído, desce rápido, nunca estoura) e volume do microfone (25–300%)
  nas configurações de voz.
- **A sala aguenta entra-e-sai**: quem ainda não disse o tamanho em que assiste
  não encolhe mais a transmissão de todo mundo; quem transmite só reduz depois
  de 10 s; pedidos de quadro-chave limitados a um por segundo; no máximo 6
  entradas a cada 30 s por pessoa (pela chave, ou pelo IP sem chave; não vale
  pro link público nem pra mesma máquina).
- **Memória minimizado**: a miniatura da própria tela não é mais pedida nem
  sobe pra placa com a janela minimizada (o driver da AMD juntava esses uploads
  sem trocar a tela: 200 MB → 900 MB em 90 s).
- **Log de depuração pro dono da sala**: terceira opção (além de gofile e
  webhook) que manda o log em pedaços pela própria conexão; o dono recebe em
  `logs-recebidos`, e o servidor dedicado com `--logs PASTA` (ou
  `TELINHA_LOGS`) guarda em disco. Um log por minuto, até 8 MB.
- **Log de depuração**: CPU por thread também no Windows (threads com nome),
  quadros-chave contados por motivo na linha da transmissão, teto de tamanho de
  quem assiste mudando, tempos da captura a cada 5 s, o som no começo (backend,
  saída, microfone padrão, se dá pra capturar um programa só), qual encoder do
  Media Foundation abriu (e quais recusaram), por que o microfone ligou/desligou
  e por que a transmissão parou.
- **Log de depuração no Windows**: não escreve mais por cima do começo do log
  das execuções anteriores (o arquivo ficava com pedaços de duas sessões), e as
  mensagens do código em C e das bibliotecas (miniaudio, encoder, captura)
  finalmente entram nele: num programa de janela elas se perdiam. Quando a
  captura do som falha, o log ganha um teste passo a passo do WASAPI (formato da
  saída e o código de cada tentativa); o motivo de o encoder recusar a textura
  também vai junto.
- **Convite colado no campo do nome** vai pro endereço da sala (antes a senha
  virava o nome, à vista de todo mundo); o servidor também troca um nome assim
  por "anônimo", mesmo de app antigo. O convite pego da área de transferência
  guarda a impressão do servidor (antes ficava só endereço e senha).
- **Rede congestionada com alguém pedindo quadro-chave**: o encoder ficava
  girando sem parar (um núcleo inteiro) até a rede folgar; agora espera o
  próximo quadro.
- **Qualidade automática subindo** dizia "o PC não estava dando conta"; agora
  diz que folgou. O mesmo aviso repetido (clicar várias vezes na câmera ocupada)
  renova o que já está na tela em vez de empilhar.
- **Servidor no systemd**: a chave da identidade vai pro `StateDirectory=` (com
  `DynamicUser` a identidade mudava a cada reinício).

## 3.1.0

Conversa com a 3.0 (os campos novos são opcionais).

### Destaques

- 🚀 **Direto pela placa de vídeo**: transmitir e assistir sem passar pela CPU na NVIDIA (Linux e Windows) e na Intel/AMD no Linux. Uma transmissão 1080p60 custa uns 20% de um núcleo pra quem transmite.
- 📡 **Vídeo, som e voz por UDP**: um pacote perdido não segura mais tudo que vem atrás, e a voz nunca espera o vídeo.
- 🎞️ **HEVC** na NVIDIA quando todo mundo que assiste consegue decodificar: menos banda pela mesma qualidade.
- 🖱️ **Cursor fora do vídeo** e **transmissão no tamanho de quem assiste**: menos placa de vídeo e menos rede pra todo mundo.
- ⌨️ **Atalhos globais**, **apertar pra falar**, **clipes de 5 s a 10 min**, print e desenho por cima da transmissão.
- 🌐 **Interface em inglês**, temas novos e o seu próprio CSS.
- 🐧 **Roda em distro Linux mais antiga**, com instalador de uma linha.

<!-- detalhes -->

### Todas as mudanças

- **Binário Linux roda em distro mais antiga**: compilado contra a glibc 2.31 (Ubuntu/Pop!_OS 20.04 em diante) e com a GLFW embutida, sem depender da GLFW da distro (a 3.3 do Ubuntu 22.04/24.04 era velha demais). X11 ou Wayland continua sendo escolhido na hora de rodar.
- **Instalador de uma linha no Linux** (`install.sh`): baixa a última versão,
  confere o SHA256, põe o telinha no menu de aplicativos e abre os convites
  `telinha://`.
- As estatísticas caem pra zero quando a imagem para ("sem imagem nova há N s"),
  em vez de mostrar o último valor. O relatório de travamento leva o commit e o ID
  da execução, anexa só o log daquela execução, e cada versão publica os símbolos
  certos.
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
  menções (`@nome`) com Tab pra completar, destaque e notificação. A imagem vai como um
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

- **Transmitir sem passar pela CPU no Windows** (NVIDIA): a textura do DXGI é
  recortada e escalada num kernel CUDA e vai direto pro NVENC. Qualquer falha
  volta pro caminho da CPU.
- **Transmitir sem passar pela CPU no Linux com Intel/AMD** (VA-API): o DMA-BUF
  do compositor vira uma superfície, a placa recorta, escala e converte pra NV12,
  e o encoder lê direto. Um autoteste de cor roda ao abrir; qualquer falha volta
  pra CPU.
- **Cursor fora do vídeo**: quem assiste desenha a seta. Mexer o mouse com a tela
  parada não manda nenhum quadro (precisa de todo mundo que assiste na 3.1).
- **Transmissão no tamanho de quem assiste**: se todo mundo vê você num
  quadradinho da grade, não vai 1080p. Sobe na hora em que alguém aumenta e desce
  3 s depois. A gravação sobrevive à mudança de resolução.
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
- Ctrl+M (Ctrl+D) configurado também como atalho do microfone (surdo): um
  aperto não liga e desliga ao mesmo tempo (o Ctrl+M de sempre dá lugar ao
  atalho).
- No inglês, os botões "30 q/s"/"60 q/s" saem como "30 fps"/"60 fps".
- Ícone novo (um husky neon espiando por cima de um terminal) e README em
  inglês, com a versão em português em `README.pt.md` e prints novos.
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
