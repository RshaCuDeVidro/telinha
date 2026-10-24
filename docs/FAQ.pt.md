# Problemas comuns

<sub>[🇺🇸 English](FAQ.md) · [🇧🇷 Português](FAQ.pt.md)</sub>

As dúvidas que mais aparecem, e o que fazer em cada caso. Não achou a sua?
Abra uma [issue](https://github.com/RshaCuDeVidro/telinha/issues) e, se puder,
mande junto o log de depuração (ver [Mandar um log](#mandar-um-log)).

## Instalar e abrir

### O Windows diz que o app pode ser perigoso

O `.exe` não é assinado (um certificado de assinatura custa caro), então o
SmartScreen avisa na primeira vez. Clique em **Mais informações → Executar
assim mesmo**. Cada release publica o `SHA256SUMS` assinado, se você quiser
conferir o arquivo.

### No Linux falta uma biblioteca

O `install.sh` mostra o comando certo pra sua distro. Na mão:

```sh
# Debian / Ubuntu / Pop!_OS / Mint
sudo apt install libportal1 libpipewire-0.3-0
# Arch
sudo pacman -S libportal pipewire
# Fedora
sudo dnf install libportal pipewire-libs
```

O binário roda em qualquer distro com glibc 2.31 ou mais nova.

### Como desinstalo no Linux?

```sh
curl -fsSL https://raw.githubusercontent.com/RshaCuDeVidro/telinha/main/install.sh | sh -s -- --remove
```

Tira o binário, o atalho do menu e o registro dos links `telinha://`. As
configurações (`~/.config/telinha`) e os clipes ficam onde estavam, se quiser
apagar também.

### Tem pra macOS ou celular?

App não. Mas, se a sala estiver num [servidor dedicado](DEPLOY.pt.md) com
`--web`, dá pra **assistir pelo navegador**, inclusive no celular: o botão da TV
na sala copia o link.

## Conectar

### A galera de fora não consegue entrar

1. Na sala, clique em **Abrir porta no roteador**. Se der certo, o convite
   novo já leva o endereço direto.
2. Se não abrir (roteador sem UPnP, ou operadora com CGNAT), clique em
   **Criar link público**. Funciona em qualquer rede.
3. Copie o convite **de novo** depois de mudar alguma coisa: ele leva os
   caminhos que existiam na hora em que foi copiado.

O [guia de conexão](CONNECTING.pt.md) explica cada caso, incluindo abrir a
porta na mão, IPv6, VPN de jogo e túnel por SSH.

### O app avisou que a identidade do servidor mudou

O convite leva a impressão digital do servidor, e o app confere antes de
mandar qualquer coisa. Se ela mudou, ou o servidor foi reinstalado (a chave
foi trocada), ou alguém no caminho está tentando se passar por ele. Confirme
com o dono da sala antes de confiar na nova.

### Quantas pessoas cabem numa sala?

Numa sala criada pelo app, o seu computador é o servidor: cada transmissão sai
da sua internet uma vez pra cada pessoa que assiste. Pra muita gente (ou
internet de upload fraca), use um [servidor dedicado](DEPLOY.pt.md) numa VPS:
aí quem transmite manda uma vez só e o servidor distribui. O servidor
dedicado aceita 32 pessoas por padrão (`--max` muda).

## Transmitir

### No Wayland não aparece o seletor de tela

O telinha usa o portal do sistema (`xdg-desktop-portal`). Ele precisa do
pedaço certo pro seu ambiente:

| Ambiente | Pacote |
|---|---|
| GNOME | `xdg-desktop-portal-gnome` |
| KDE | `xdg-desktop-portal-kde` |
| Hyprland | `xdg-desktop-portal-hyprland` |
| Sway e outros wlroots | `xdg-desktop-portal-wlr` |

Depois de instalar, saia da sessão e entre de novo.

### "O portal recusou a captura: CreateSession failed"

O pedaço do portal do seu ambiente não subiu. O caso mais comum: o systemd do
usuário reiniciou com o compositor aberto e perdeu o `WAYLAND_DISPLAY` que o
compositor tinha passado pra ele; sem isso ele nem tenta subir o
`xdg-desktop-portal-hyprland` (ou o `-wlr`). O telinha percebe isso, repassa
as variáveis da sessão pro systemd e tenta de novo sozinho. Se ainda falhar,
rode num terminal da sessão:

```sh
systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP
systemctl --user restart xdg-desktop-portal
```

e confira se o seu compositor roda o `import-environment` (ou o
`dbus-update-activation-environment --systemd`) ao abrir.

### O jogo fica travando enquanto eu transmito

- Em **Configurações → Desempenho**, ponha o encoder da placa em **Leve**.
- Limite a interface a **30 q/s** (mesma página).
- Diminua a resolução ou os quadros por segundo da transmissão.
- Rode o **Testar meu PC** e use a sugestão.

### O texto fica borrado

Use o tipo de conteúdo **Tela e texto** e uma qualidade mais alta. Se alguém
está te vendo num quadradinho da grade, a transmissão vai menor de propósito
e volta a subir quando a pessoa amplia.

### Alguém reclama que está travando

O telinha já se ajusta sozinho: mede o atraso de cada quadro, baixa a taxa
quando a internet de alguém não aguenta e manda metade dos quadros pra quem
está muito lento, sem piorar pros outros. Se continuar, olhe as estatísticas
em cima do vídeo (atraso e banda) da pessoa e veja o
[guia de conexão](CONNECTING.pt.md): um caminho direto (porta aberta) quase
sempre é melhor que o link público.

## Som e voz

### Tem eco

Ligue o **cancelamento de eco** em **Configurações → Voz**, ou use fone. O som
da transmissão nunca volta pro microfone de quem transmite: o telinha não
captura o próprio som.

### Meu microfone está muito baixo

Em **Configurações → Voz**, ligue o **ganho automático** ou aumente o volume do
microfone.

### O microfone pega o teclado e o ventilador

Ligue a **supressão de ruído**, ou troque pra **apertar pra falar**.

## Atualizações

### A atualização falhou

Baixe a versão nova na [página de Releases](https://github.com/RshaCuDeVidro/telinha/releases/latest)
e substitua o arquivo. No Windows, um antivírus segurando o `.exe` pode
impedir a troca automática. Se o app estiver numa pasta sem permissão de
escrita, ele mostra só o botão pra página da release.

## Mandar um log

Quando algo dá errado, o log ajuda muito a consertar:

1. **Configurações → Depuração → Gravar log de depuração**.
2. Repita o que deu errado.
3. Em **Mandar o log**, mande pro dono da sala (ou salve o arquivo e anexe numa
   issue).

O log não tem senha nenhuma. Se o app cair, na próxima vez que abrir ele
pergunta se pode mandar o relatório do travamento.

## Privacidade

Toda conexão é cifrada (X25519 e ChaCha20-Poly1305), e a senha da sala entra
na derivação das chaves: quem está no caminho não vê nada. Quem hospeda a
sala (o seu PC ou o servidor dedicado) repassa vídeo e voz sem gravar nada; o
histórico do chat fica só na memória dele. Os arquivos mandados na sala ficam
no servidor cifrados, com a chave só na memória, e somem depois de 2 horas.
Não tem conta nem coleta de dados: o app só fala com o GitHub pra ver se tem
versão nova (dá pra desligar), e log ou relatório de travamento só sai se
você mandar.
