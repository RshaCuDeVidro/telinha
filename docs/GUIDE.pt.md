# Guia de uso

<sub>[🇺🇸 English](GUIDE.md) · [🇧🇷 Português](GUIDE.pt.md)</sub>

Tudo o que dá pra fazer no telinha, do primeiro convite às configurações. Se
você só quer começar logo, os três primeiros tópicos bastam.

## Criar uma sala

Abra o telinha e clique em **Criar sala**. A porta padrão é 7777 e a senha é
opcional. Quem cria a sala ganha a coroa 👑 e é o admin dela.

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
3. Clique em **Copiar convite** e mande pra galera.

O convite (`telinha://…`) leva todos os caminhos até a sala: rede local, porta
aberta, IPv6 e link público. Cada pessoa entra pelo mais rápido que funcionar
pra ela. Ele também leva a impressão digital do servidor, então o app confere
que está falando mesmo com a sua sala antes de mandar qualquer coisa.

Não deu certo? O [guia de conexão](CONNECTING.pt.md) tem todos os outros
jeitos: abrir a porta na mão, IPv6, VPN de jogo, túnel por SSH.

## Entrar numa sala

Cole o convite na tela inicial e clique em **Entrar**. Se o convite já estiver
copiado quando você abrir o telinha, ele cola sozinho. No Linux instalado pelo
`install.sh`, clicar num link `telinha://` já abre o app.

Dá pra entrar direto num canal: escreva o nome dele no campo de canal da tela
inicial.

## Transmitir

Clique em **Compartilhar tela** e escolha:

| Opção | O que faz |
|---|---|
| **O que mostrar** | A tela inteira, uma janela só, ou um retângulo que você arrasta em cima da própria prévia. A câmera pode ir junto ou no lugar da tela. |
| **Som** | Sem som, todo o som do computador (menos o telinha), só o som de um programa, ou tudo menos alguns programas (ex.: o Discord). O som do próprio telinha nunca entra, então não tem eco. |
| **Tipo de conteúdo** | *Tela e texto* deixa letra nítida (código, documento, navegador). *Jogo e vídeo* prioriza movimento suave. |
| **Resolução, quadros e qualidade** | A taxa cai sozinha se a internet de alguém não aguentar e volta a subir quando melhora. |
| **Usar a placa de vídeo** | NVIDIA, e no Windows também AMD e Intel. Sem placa que sirva, vai pela CPU. |

Clique em **Ao vivo**. Dá pra mudar tudo com a transmissão rolando, sem
ninguém perder a imagem.

> [!NOTE]
> No Wayland, o sistema abre um seletor pra escolher a tela ou janela na
> primeira vez. Depois ele lembra a escolha.

Várias pessoas podem transmitir ao mesmo tempo. Se todo mundo está vendo você
num quadradinho da grade, o telinha manda a transmissão menor (menos placa,
menos rede pra todos) e volta a subir na hora em que alguém amplia.

## Assistir

Clique em quem está ao vivo. Várias transmissões ficam numa grade que deixa
cada vídeo o maior possível.

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
| Ficar surdo (não ouvir ninguém) | **Ctrl+D** |
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
- Imagens: cole (Ctrl+V) na caixa.
- Reações, @menções (quem é mencionado é avisado) e histórico pra quem chega
  depois.
- **Clique direito numa mensagem**: copiar, responder citando ou mandar
  mensagem privada pra quem escreveu.
- **Responder citando**: a mensagem original aparece em cima da resposta, e
  quem foi respondido é avisado.
- **Mensagem privada**: só os dois veem, em qualquer canal. Pelo menu da
  mensagem, pelo menu da pessoa ou com `/msg nome texto`.
- **Arquivos** de até 256 MB: o clipe 📎, arrastar o arquivo pra janela ou
  `/arquivo caminho`. Ele sobe uma vez pro servidor e cada um baixa quando
  clicar, em segundo plano, sem atrapalhar vídeo e voz. No servidor fica
  cifrado e some depois de 2 horas.
- Notificações do sistema quando o telinha está em segundo plano.

## Canais

Um servidor pode ter várias salas ao mesmo tempo, como no IRC. Cada canal tem
o seu chat, e a **call** (voz e transmissões) é separada: dá pra ler um canal
e continuar na call de outro.

- Clique num canal no painel pra ler o chat dele.
- Clique no fone 🎧 do canal pra entrar na call dele. A sua transmissão vai
  junto.
- O **+** cria um canal. Canal vazio some sozinho, a não ser os fixos do
  servidor.
- O admin pode pôr senha, trancar e mudar o tópico (clique direito no canal).

## Comandos do chat

| Comando | Também | O que faz |
|---|---|---|
| `/join canal` | `/j`, `/canal`, `/entrar` | Vai pro chat desse canal (cria se não existir). |
| `/call canal` | `/voz`, `/voice` | Entra na call desse canal. Sem nome: sai da call. |
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
| **Enter** / **Shift+Enter** | Manda / quebra a linha no chat |

**Atalhos globais** (funcionam com outro programa em foco, como um jogo):
clipe, microfone, surdo, transmitir, print e um que liga e desliga todos. Em
**Configurações → Atalhos**, qualquer tecla, combinação ou botão do mouse.

## Para o admin

Quem cria a sala (ou entra num servidor dedicado com o token de admin) pode,
com o clique direito na pessoa: expulsar, banir, silenciar, parar a
transmissão, tirar o pincel, dar ou tirar o admin. Também pode trancar a sala
e cuidar dos canais.

Num servidor dedicado, o admin vê as **estatísticas do servidor**: CPU,
memória, banda chegando e saindo, gente por canal, quem está atrasando e um
palpite em português claro de qual é o gargalo.

## Assistir pelo navegador

Num [servidor dedicado](DEPLOY.pt.md) com `--web`, aparece na sala um botão 📺
que copia um link. Quem abrir o link assiste pelo navegador, sem instalar
nada: vídeo, som da transmissão, voz da call e chat. O servidor só repassa os
mesmos quadros, então quem transmite não gasta nada a mais.

Pelo navegador dá pra assistir e conversar no chat; transmitir e falar só pelo
app.

## Configurações

A engrenagem ⚙ abre as configurações, na sala ou na tela inicial.

| Página | O que tem |
|---|---|
| **Geral** | Nome, idioma, notificações, estatísticas sempre à mostra, aviso de versão nova (e instalar sozinho), clipes e a duração deles |
| **Aparência** | Temas: escuro, claro, pwnd (neon), pwnd claro, Nord, Drácula ou o seu próprio CSS (atualiza sozinho quando você salva o arquivo); tamanho da interface; efeito CRT; animações da tela inicial; mostrar ou esconder os desenhos dos outros |
| **Voz** | Ativação por voz ou apertar pra falar, microfone, sensibilidade, volume, ganho automático, supressão de ruído, cancelamento de eco, entrar com o microfone ligado, sons de aviso |
| **Atalhos** | Atalhos globais (e um interruptor geral) |
| **Câmera** | Qual câmera e a resolução |
| **Desempenho** | Qualidade automática, cursor fora do vídeo, mandar no tamanho de quem assiste, limite de quadros da interface, peso do encoder da placa, AV1 (experimental) e o **Testar meu PC** |
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
