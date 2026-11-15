# Guia de uso

<sub>[🇺🇸 English](GUIDE.md) · [🇧🇷 Português](GUIDE.pt.md)</sub>

Tudo o que dá pra fazer no telinha, do primeiro convite às configurações. Se
você só quer começar logo, os três primeiros tópicos bastam. Dentro do app, o
botão **?** (ou **F1**) da sala explica o básico, e na primeira vez numa sala
um tour de cinco passos mostra onde fica cada coisa.

## Criar uma sala

Abra o telinha e clique em **Criar sala**. A porta padrão é 7777 e a senha é
opcional. Quem cria a sala ganha a coroa e é o admin dela.

A sala fica no seu computador enquanto o telinha estiver aberto. Pra ter uma
sala sempre ligada, mesmo com o seu PC desligado, use um
[servidor dedicado](DEPLOY.pt.md).

## Chamar a galera

No card *Chamando a galera de fora*:

1. Clique em **Abrir porta no roteador**. É o caminho direto, com o menor
   atraso. Funciona na maioria dos roteadores (UPnP, NAT-PMP ou PCP).
2. Se a operadora usa CGNAT, a porta não abre. Aí clique em
   **Criar link público**: a sala ganha um endereço que funciona em qualquer
   rede, sem configurar nada.
3. Clique em **Copiar convite** e mande pra galera. O botão **Convidar**, na
   barra de cima, copia o mesmo convite a qualquer hora.

Numa sala sem ninguém ao vivo, o meio da tela mostra dois cartões grandes,
**Compartilhar a minha tela** e **Chamar a galera** (que copia o convite), e
embaixo o passo a passo: alguém convida, alguém compartilha, os outros clicam
em **Assistir**.

O botão **Convidar** copia um link da página de convite do site
(`https://…/telinha/j/#i=…`): ele é clicável no Discord e no navegador, abre o
app de quem já tem e mostra como instalar pra quem não tem. Dentro dele vai o
convite em si (`telinha://…`), e o que vem depois do `#` nunca é enviado pro
site.

O convite (`telinha://…`) leva todos os caminhos até a sala: rede local, porta
aberta, IPv6 e link público. Cada pessoa entra pelo mais rápido que funcionar
pra ela. Ele também leva a impressão digital do servidor, então o app confere
que está falando mesmo com a sua sala antes de mandar qualquer coisa.

Não deu certo? O [guia de conexão](CONNECTING.pt.md) tem todos os outros
jeitos: abrir a porta na mão, IPv6, VPN de jogo, túnel por SSH.

## Entrar numa sala

Cole o convite (o link https ou o `telinha://`) na tela inicial e clique em
**Entrar**. Se o convite já estiver copiado quando você abrir o telinha, ele
cola sozinho.

As salas em que você entrou aparecem em **Salas recentes**, embaixo do
cartão: um clique entra de novo (com a senha e o canal), e o **x** tira da
lista. Clicar num link `telinha://` abre o app: no Windows ele se
registra sozinho ao abrir pela primeira vez, no Linux o `install.sh` registra.
Com o telinha já aberto, o link vai pra janela aberta.

Dá pra entrar direto num canal: escreva o nome dele no campo de canal da tela
inicial.

## A sala

| Onde | O que tem |
|---|---|
| **Em cima** | O nome da sala (clique: o menu dela, com o convite, o link do navegador e, pra quem é admin, trancar, limpar o chat, banidos e estatísticas), as **abas dos canais**, o **Convidar**, a ajuda (**?**) e as configurações |
| **No meio** | As transmissões. Sem ninguém assistido, quem está ao vivo aparece aqui com o botão **Assistir**. Assistindo, a barra em cima diz o que está passando e tem **Grade** ou **Destaque**, **Assistir todas**, **Parar de assistir** e **Cinema** |
| **Do lado** | O painel, com duas abas: **Chat** (o chat do canal) e **Pessoas** (*Ao vivo agora*, um cartão por transmissão com o **Assistir**, e quem está no canal). Ele abre e fecha deslizando |
| **Embaixo** | A barra de controles, com o nome de cada botão: **Microfone**, **Ouvir**, **Câmera**, **Compartilhar tela** (ao vivo, o botão vermelho do lado para), **Chat** e **Pessoas** (abrem o painel; o número em cima diz as mensagens novas e quantos estão ao vivo) e **Sair** |

**Ctrl+J** abre e fecha o chat e **Ctrl+B**, as pessoas. A borda do painel
muda de largura arrastando (duplo clique volta ao normal). Em
**Configurações → Aparência → Layout da sala**, o painel vai pra esquerda e a
barra de controles fica embaixo, de lado ou recolhida. Tudo fica salvo.

## Transmitir

Clique em **Compartilhar tela** e escolha:

| Opção | O que faz |
|---|---|
| **O que mostrar** | A tela inteira, uma janela só (no Windows, em cartões com miniatura ao vivo), ou só um pedaço: marque *Só um pedaço da tela* e arraste um retângulo assim que começar (ou depois, pelo botão de recorte na sua prévia). A câmera pode ir junto ou no lugar da tela. |
| **Som** | Sem som, todo o som do computador (menos o telinha), só o som de um programa, ou tudo menos alguns programas (ex.: o Discord). O som do próprio telinha nunca entra, então não tem eco. |
| **Tipo de conteúdo** | *Tela e texto* deixa letra nítida (código, documento, navegador). *Jogo e vídeo* prioriza movimento suave. |
| **Resolução, quadros e qualidade** | A taxa cai sozinha se a internet de alguém não aguentar e volta a subir quando melhora. |
| **Usar a placa de vídeo** | NVIDIA, e no Windows também AMD e Intel. Sem placa que sirva, vai pela CPU. |

Clique em **Começar a transmitir**. Dá pra mudar tudo com a transmissão
rolando, sem ninguém perder a imagem. Pra parar, o botão vermelho do lado do
**Ao vivo**, na barra de baixo (ou o **Parar** do seu cartão na lista).

> [!NOTE]
> No Wayland, o sistema abre um seletor pra escolher a tela ou janela na
> primeira vez. Depois ele lembra a escolha.

Várias pessoas podem transmitir ao mesmo tempo. Se todo mundo está vendo você
num quadradinho da grade, o telinha manda a transmissão menor (menos placa,
menos rede pra todos) e volta a subir na hora em que alguém amplia.

## Assistir

Clique em **Assistir** no cartão de quem está ao vivo (no meio da tela, ou em
**Pessoas**). Várias transmissões ficam numa grade que deixa cada vídeo o
maior possível; a barra do palco troca pra **Destaque** (uma grande e as
outras embaixo), assiste todas de uma vez ou para de assistir tudo. Se tem
gente ao vivo em outro canal, **Pessoas** mostra em *Ao vivo em outros
canais*: um clique e você já está lá, assistindo.

Um bot de tela (como o [Telão](BOTS_SCREEN.pt.md)) se assiste do mesmo jeito.
Se ele tem um painel, o painel fica encaixado embaixo do vídeo, com os botões
dele (pausar, pular...), enquanto a transmissão dele está sozinha ou em
destaque. Bot em outro canal aparece em **Pessoas**, em *Bots em outros
canais*: clique direito → **Chamar pra minha call**.

A bolinha do lado do nome de quem transmite diz como a transmissão está
chegando: verde flui bem, amarela engasgando, vermelha ruim, e o porquê (*sua
internet*, *seu PC*, *o PC ou a internet de Fulano*).

| Ação | Como |
|---|---|
| Tela cheia | **F11**, ou o botão no canto do vídeo |
| Modo cinema | duplo clique no vídeo |
| Sair da tela cheia / do modo cinema | **Esc** |
| Janela flutuante (picture-in-picture) | botão no vídeo |
| Zoom | roda do mouse; arraste pra mover, ou siga o cursor de quem transmite (com minimapa) |
| Volume da transmissão | controle em cima do vídeo |

Por cima de qualquer transmissão:

- **Ponteiro "olha aqui"**: aparece pra todo mundo que está vendo.
- **Desenhar**: 15 cores e 4 espessuras, com marca-texto. Dá pra esconder os
  desenhos dos outros, e o admin pode tirar o pincel de alguém.
- **Clipe**: salva os últimos segundos (de 5 s a 10 min, você escolhe) num
  clique ou num atalho global, em MP4.
- **Gravação**: MP4 sem recodificar, com o som. Sobrevive a mudança de
  resolução.
- **Print**: PNG na resolução da transmissão.

Os clipes e gravações vão pra pasta de vídeos (`Vídeos/telinha`).

## Falar

| Ação | Como |
|---|---|
| Ligar e desligar o microfone | **Ctrl+M** |
| Ficar surdo (não ouvir a call; o som das transmissões continua) | **Ctrl+D** |
| Volume da voz de alguém | clique direito na pessoa |

Em **Configurações → Voz**: ativação por voz (com sensibilidade) ou
**apertar pra falar**, que vale até com o jogo em foco; supressão de ruído
(tira ventilador, teclado e chiado); cancelamento de eco (caixa de som
funciona tão bem quanto fone); ganho automático pra microfone baixo e o volume
do microfone.

## Chat

- **Enter** manda, **Shift+Enter** quebra a linha.
- Markdown: `**negrito**`, `*itálico*`, `` `código` ``, blocos de código com
  botão de copiar e links clicáveis. Emoji colorido.
- Imagens: cole (Ctrl+V, em qualquer lugar da sala) ou arraste pra janela. Uma
  prévia pergunta antes de mandar: **Enter** manda, **Esc** desiste.
- Reações, @menções (quem é mencionado é avisado) e histórico pra quem chega
  depois.
- **Clique direito numa mensagem**: copiar, responder citando ou mandar
  mensagem privada pra quem escreveu.
- **Responder citando**: a mensagem original aparece em cima da resposta, e
  quem foi respondido é avisado.
- **Mensagem privada**: só os dois veem, em qualquer canal. Pelo menu da
  mensagem, pelo menu da pessoa ou com `/msg nome texto`.
- **Arquivos** de até 256 MB: o botão do clipe, arrastar o arquivo pra janela ou
  `/arquivo caminho`. Ele sobe uma vez pro servidor e cada um baixa quando
  clicar, em segundo plano, sem atrapalhar vídeo e voz. No servidor fica
  cifrado e some depois de 2 horas.
- **Cartões de [bot](BOTS.pt.md)**: capa, campos, barra de progresso que anda
  sozinha e botões; clicar num botão manda o clique pro bot, que muda o cartão
  no lugar.
- Notificações do sistema quando o telinha está em segundo plano.

## Canais

Um servidor pode ter várias salas ao mesmo tempo, como no IRC. Os canais são
as **abas** em cima. Cada um tem o seu chat, a sua voz e as suas telas.

- Clique numa aba pra ir pro canal: o chat e a call (voz e transmissões) vão
  juntos, e a sua transmissão também. A bolinha vermelha na aba diz que tem
  gente ao vivo lá.
- Clique direito na aba: **Só ler o chat** (continua na call de agora) ou
  **Sair da call** (fica só no chat; a barra de baixo ganha o **Entrar** pra
  voltar). Pra quem é OP ou admin, as opções do canal ficam no mesmo menu.
- O **+** do lado das abas cria um canal. Ele continua na lista mesmo vazio (e se o servidor
  reiniciar); só some depois de 3 dias sem ninguém. Os fixados pelo admin ficam
  pra sempre.
- **Quem cria o canal é OP dele**, com uma **coroa azul** do lado do nome na
  lista (a amarela é do dono da sala). O OP manda no canal: pelo clique
  direito na aba, senha, trancar, tópico e deixar **invisível** (fora da
  lista; entra quem sabe o nome e a senha); pelo clique direito na pessoa,
  **dar OP** pra ela, **levar** ela pra outro canal (um aberto ou um em que
  você também é OP) e **tirar** ela do canal sem volta. Em quem criou o canal
  e em admin o OP não mexe; em outro OP, só quem criou.
- Só **quem criou** apaga o canal (pede confirmação; quem estava nele volta
  pro canal padrão) e tira o OP dos outros. O admin da sala pode tudo, em
  qualquer canal. O canal padrão não tem OP.
- A **senha do canal vale pra todo mundo**, inclusive pros OPs e pra quem
  criou: pra entrar, digita a senha (o app lembra dela e volta pro canal
  sozinho se a internet cair). Só o admin da sala entra sem, e também entra no
  trancado e vê os invisíveis. Testando com duas janelas no mesmo PC: as duas
  são a mesma pessoa pro servidor (e, com o token de admin em *Opções
  avançadas*, as duas são admin).

## Comandos do chat

| Comando | Também | O que faz |
|---|---|---|
| `/join canal` | `/j`, `/canal`, `/entrar` | Vai pra esse canal, o chat e a call (cria se não existir). |
| `/call canal` | `/voz`, `/voice` | Entra só na call desse canal. Sem nome: sai da call. |
| `/canais` | `/channels`, `/list` | Mostra os canais e quantas pessoas tem em cada. |
| `/msg nome texto` | `/m`, `/w`, `/pm`, `/dm`, `/privado` | Mensagem privada. Só o nome: a caixa passa a mandar em privado pra essa pessoa. |
| `/arquivo caminho` | `/file`, `/enviar` | Manda um arquivo (ou arraste o arquivo pra janela). |

Qualquer outra coisa começando com `/` vai pro chat como texto normal.

## Atalhos

| Tecla | O que faz |
|---|---|
| **F11** | Tela cheia |
| **Esc** | Sai da tela cheia e do modo cinema |
| duplo clique | Modo cinema |
| **Ctrl+M** | Microfone |
| **Ctrl+D** | Surdo |
| **Ctrl+J** | Abre e fecha o chat |
| **Ctrl+B** | Abre e fecha Pessoas (quem está ao vivo) |
| **F1** | Como usar (a ajuda) |
| **Enter** / **Shift+Enter** | Manda / quebra a linha no chat |

**Atalhos globais** (funcionam com outro programa em foco, como um jogo):
clipe, microfone, surdo, transmitir, print e um que liga e desliga todos. Em
**Configurações → Atalhos**, qualquer tecla, combinação ou botão do mouse.

## Para o admin

Quem cria a sala (ou entra num servidor dedicado com o token de admin) pode,
com o clique direito na pessoa: expulsar, banir, silenciar, parar a
transmissão, tirar o pincel, dar ou tirar o admin. No menu da sala (clique no
nome dela, em cima), pode trancar a sala e **limpar o chat da sala** (dois
cliques): o histórico de todos os canais e os arquivos somem pra todo mundo,
sem reiniciar o servidor. Os canais ele cuida pelo clique direito nas abas.

Num servidor dedicado, o admin vê as **estatísticas do servidor** (no menu da sala): CPU,
memória, banda chegando e saindo, gente por canal, quem está atrasando e um
palpite em português claro de qual é o gargalo.

## Assistir pelo navegador

Num [servidor dedicado](DEPLOY.pt.md) com `--web`, o menu da sala ganha o
**Copiar o link pra assistir no navegador**. Quem abrir o link assiste pelo navegador, sem instalar
nada: vídeo, som da transmissão, voz da call e chat. O servidor só repassa os
mesmos quadros, então quem transmite não gasta nada a mais.

Pelo navegador dá pra assistir e conversar no chat; transmitir e falar só pelo
app.

## Configurações

O botão da engrenagem abre as configurações, na sala ou na tela inicial.

| Página | O que tem |
|---|---|
| **Geral** | Nome, idioma, notificações, estatísticas sempre à mostra, aviso de versão nova (e instalar sozinho), clipes e a duração deles |
| **Aparência** | Temas: Husky (o padrão, chapado), pwnd (neon), escuro, neon, aurora, alto contraste, claro, pwnd claro, Nord, Drácula, os seus em `.kdl` ou o seu próprio CSS (atualiza sozinho quando você salva o arquivo); tamanho da interface; efeito CRT; **clima da sala** (o fundo muda de tom com a energia da sala, sem animação contínua); animações da tela inicial; mostrar ou esconder os desenhos dos outros; o layout da sala (painel na esquerda, barra de controles) e **Fazer o tour da sala de novo** |
| **Voz** | Ativação por voz ou apertar pra falar, microfone, sensibilidade, volume, ganho automático, supressão de ruído, cancelamento de eco, entrar com o microfone ligado, sons de aviso |
| **Atalhos** | Atalhos globais (e um interruptor geral) |
| **Câmera** | Qual câmera e a resolução |
| **Desempenho** | **Modo econômico** (PC fraco: interface a 30 q/s, sem animações nem efeitos), qualidade automática, cursor fora do vídeo, mandar no tamanho de quem assiste, limite de quadros da interface, peso do encoder da placa, AV1 (experimental) e o **Testar meu PC** |
| **Depuração** | Log de depuração, mandar o log pro dono da sala, relatório de travamento |
| **Sobre** | Versão e histórico de versões |

> [!TIP]
> O **Testar meu PC** mede por uns segundos quanto o computador aguenta pra
> transmitir e pra assistir, e sugere a configuração. Um clique em
> *Usar a sugestão* aplica.

## Atualizações

O telinha (Windows e Linux) avisa quando sai versão nova, mostra o que muda e
instala com um clique, depois de conferir a assinatura da release. Nas
configurações dá pra deixar ele instalar sozinho ou pular uma versão. O
histórico fica em **Configurações → Sobre**.

## Onde ficam as coisas

| O quê | Linux | Windows |
|---|---|---|
| Configurações | `~/.config/telinha/config.ini` | `%APPDATA%\telinha\config.ini` |
| Clipes e gravações | `Vídeos/telinha` (a pasta de vídeos do sistema) | `Vídeos\telinha` |
| Arquivos baixados da sala | `Downloads` | `Downloads` |

Pra deixar o telinha portátil (num pendrive, por exemplo), as variáveis
`TELINHA_PASTA_CONFIG` e `TELINHA_PASTA_CLIPES` trocam essas pastas.
