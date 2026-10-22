# Como a galera de fora entra na sua sala

<sub>[🇺🇸 English](CONNECTING.md) · [🇧🇷 Português](CONNECTING.pt.md)</sub>

Quem está na mesma casa (ou na mesma VPN) entra direto. O problema é quem está
longe: a sua internet normalmente não deixa ninguém de fora chegar no seu PC.
Este guia junta todos os jeitos, do mais direto (menos atraso) ao que funciona
em qualquer rede. **Nenhum deles precisa de chave de API**, e a maioria nem de
conta.

> Seja qual for o caminho, a conversa é cifrada de ponta a ponta (X25519 +
> ChaCha20-Poly1305) e o convite leva a impressão da sala: quem estiver no meio
> (um túnel, uma VPN) só vê bytes embaralhados e não consegue se passar pela sala.

| Caminho | Atraso | Precisa de | Conta? |
|---|---|---|---|
| [Rede local](#1-mesma-rede-ou-mesma-vpn) | o menor | estar na mesma rede | não |
| [IPv6](#2-ipv6-o-convite-já-leva) | baixo | IPv6 nas duas pontas | não |
| [Abrir porta sozinho](#3-abrir-a-porta-sozinho-upnp-nat-pmp-pcp) | baixo | roteador com UPnP, NAT-PMP ou PCP | não |
| [Abrir porta na mão](#4-abrir-a-porta-na-mão) | baixo | entrar no roteador | não |
| [Link público](#5-link-público-um-clique) | médio | nada | não |
| [VPN de jogo](#6-vpn-de-rede-virtual-radmin-zerotier-tailscale) | baixo/médio | o programa nas duas pontas | depende |
| [Túnel por SSH](#7-túnel-por-ssh-sem-instalar-nada) | médio | o `ssh` (já vem no Windows 10/11) | não |
| [Seu servidor](#8-seu-próprio-servidor) | baixo | uma VPS | — |

## 1. Mesma rede (ou mesma VPN)

Automático: o convite sempre leva os endereços da rede local, e o app de quem
entra testa todos ao mesmo tempo (o primeiro que responder ganha).

## 2. IPv6: o convite já leva

Muita operadora no Brasil já entrega IPv6, e com ele **não tem NAT nem CGNAT**:
cada aparelho tem endereço próprio na internet. O telinha põe os seus IPv6
globais no convite sozinho; se quem entra também tem IPv6, conecta direto.

- Pra saber se você tem: abra [test-ipv6.com](https://test-ipv6.com).
- Se tem IPv6 e mesmo assim não conecta, o roteador pode estar bloqueando
  conexões de entrada em IPv6. Procure nas configurações algo como *Firewall
  IPv6*, *Filtro IPv6* ou *Permitir acesso de entrada* e libere a porta da sala
  (7777, TCP e UDP), ou desligue o bloqueio.
- No Windows, a primeira vez que você cria uma sala o firewall pergunta:
  marque **Redes privadas e públicas**.

## 3. Abrir a porta sozinho (UPnP, NAT-PMP, PCP)

No cartão *Chamando a galera de fora*, **Abrir porta no roteador**. O app tenta
os três jeitos que roteadores entendem: UPnP primeiro, depois NAT-PMP e PCP
(comuns em roteadores com OpenWrt/miniupnpd, da Apple e vários de operadora).
A porta fica aberta só enquanto a sala está aberta (é renovada sozinha e
devolvida ao fechar).

Se aparecer *Nenhum roteador respondeu*, o recurso está desligado no roteador:
procure por **UPnP** nas configurações dele e ligue (ou siga o passo 4).

## 4. Abrir a porta na mão

1. **Descubra o endereço do roteador.** Windows: `ipconfig` no Prompt de
   Comando, linha *Gateway Padrão*. Linux: `ip route | grep default`.
   Normalmente é `192.168.0.1` ou `192.168.1.1`.
2. **Descubra o IP do seu PC** na rede (mesmo comando: *Endereço IPv4*, ou
   `ip -4 addr` no Linux), por exemplo `192.168.0.23`.
3. **Entre no roteador** pelo navegador (o endereço do passo 1). A senha
   costuma estar na etiqueta embaixo dele.
4. Procure **Encaminhamento de porta**, *Port Forwarding*, *Servidor Virtual*,
   *NAT* ou *Aplicações*. Crie uma regra:
   - porta externa **7777**, porta interna **7777**
   - protocolo **TCP e UDP** (o vídeo e a voz vão por UDP; só TCP também
     funciona, com um pouco mais de atraso)
   - IP de destino: o do passo 2
5. **Fixe o IP do seu PC** no roteador (*Reserva de DHCP*, *IP fixo*), senão
   ele pode mudar e a regra aponta pro aparelho errado.
6. Crie a sala e copie o convite: o app descobre o seu IP de fora e põe nele.

### Se mesmo assim não chega: CGNAT

Muita operadora (principalmente de fibra e 4G) põe vários clientes atrás do
mesmo IP: é o **CGNAT**. Aí a porta abre no seu roteador, mas a internet nunca
chega nele. Como saber: entre no roteador e veja o *IP WAN* (ou *IP da
internet*). Se começa com **100.64 a 100.127**, ou com **10.**, **172.16 a
172.31** ou **192.168.**, é CGNAT. O telinha também avisa quando percebe.

O que fazer:

- **Use IPv6** (passo 2): o CGNAT só existe no IPv4.
- **Peça um IP público pra operadora.** Muitas tiram do CGNAT de graça, é só
  pedir no atendimento. Um texto que costuma funcionar: *"Preciso de IP público
  (sair do CGNAT) pra acessar minha rede de fora: câmeras e servidor de jogo."*
  Não precisa de "IP fixo" (que costuma ser pago): o público dinâmico basta.
- Ou use um dos caminhos abaixo, que funcionam até com CGNAT.

## 5. Link público (um clique)

**Criar link público** no cartão: o app abre um túnel pelo
[bore.pub](https://github.com/ekzhang/bore) (de graça, sem conta) e o convite
passa a ter um endereço que funciona de qualquer lugar, com CGNAT ou não. É o
jeito mais fácil, com um pouco mais de atraso (o servidor do túnel fica fora do
Brasil). Se o bore.pub estiver fora do ar, use um dos outros.

## 6. VPN de rede virtual (Radmin, ZeroTier, Tailscale)

Esses programas criam uma "rede local de mentira" pela internet: todo mundo
instala, entra na mesma rede, e aí é como estar na mesma casa (passo 1).
Funcionam com CGNAT.

- **[Radmin VPN](https://www.radmin-vpn.com/)**: grátis e **sem cadastro**,
  popular pra jogar com os amigos. Só Windows.
- **[ZeroTier](https://www.zerotier.com/)**: Windows, Linux, celular. Quem cria
  a rede precisa de conta; quem entra só precisa do ID da rede.
- **[Tailscale](https://tailscale.com/)**: entra com conta do Google/GitHub,
  muito fácil de usar.

Depois de todo mundo na mesma rede virtual: em *Prefere seu próprio túnel?*,
cole o seu IP da VPN com a porta (ex.: `26.12.34.56:7777` no Radmin) e copie o
convite. Às vezes nem precisa: o convite já leva os endereços de todas as
redes do seu PC.

## 7. Túnel por SSH (sem instalar nada)

O `ssh` já vem no Windows 10/11 e em todo Linux. Alguns serviços abrem um
túnel TCP de graça e **sem conta** por ele. Exemplo com o
[Pinggy](https://pinggy.io) (na data deste guia: grátis, sem cadastro, túnel
de até 60 minutos):

```sh
ssh -p 443 -R0:localhost:7777 tcp@a.pinggy.io
```

Ele mostra um endereço `tcp://algo.a.free.pinggy.link:12345`: cole
`algo.a.free.pinggy.link:12345` em *Prefere seu próprio túnel?* e copie o
convite. Os comandos ficam prontos pra copiar no próprio app. Outros que fazem
o mesmo: [bore](https://github.com/ekzhang/bore) (`bore local 7777 --to
bore.pub`), ngrok (precisa de conta), [playit.gg](https://playit.gg) (tem
conta de convidado).

> Esses serviços são de terceiros e mudam as regras de vez em quando. O tráfego
> do telinha continua cifrado por dentro do túnel.

## 8. Seu próprio servidor

Tem uma VPS (ou um PC sempre ligado com porta aberta)? Duas opções:

- **Servidor dedicado do telinha**: a sala fica lá, todo mundo entra nela, e
  ninguém precisa abrir porta em casa. Veja [DEPLOY.pt.md](DEPLOY.pt.md).
- **Túnel SSH pra sua VPS**: a sala continua no seu PC e a VPS só repassa.
  Na VPS, ponha `GatewayPorts clientspecified` no `/etc/ssh/sshd_config` e
  reinicie o ssh. No seu PC:

  ```sh
  ssh -N -R 0.0.0.0:7777:localhost:7777 voce@sua-vps
  ```

  O endereço pra pôr no convite é `ip-da-vps:7777` (libere a 7777 no firewall
  da VPS).

## Ainda não conecta?

- Confira se a sala está aberta e se o convite é o mais novo (o endereço muda
  quando o túnel ou a porta mudam).
- Quem entra pode ligar o *log de depuração* (Configurações → Depuração) e
  mandar pro dono da sala: ele mostra cada caminho tentado e por que falhou.
