# Changelog

## 2.1.0

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
