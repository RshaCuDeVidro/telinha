# Servidor dedicado

<sub>[🇺🇸 English](DEPLOY.md) · [🇧🇷 Português](DEPLOY.pt.md)</sub>

Por padrão quem cria a sala é o servidor (e precisa de túnel/porta aberta). Se
você tem uma VPS ou um PC com porta aberta, pode deixar uma sala sempre no ar
com o `telinha-server`: um binário estático de ~400 KB, sem dependências.

Todo mundo entra com **Entrar numa sala** → `ip-da-vps:7777` + senha.

## Rodando direto

```sh
zig build server            # gera zig-out/bin/telinha-server-{x86_64,aarch64}
./telinha-server-x86_64 --porta 7777 --senha "uma senha boa" --nome "Sala da galera" --admin "token-secreto"
```

Ou pelas variáveis `TELINHA_PORTA`, `TELINHA_SENHA`, `TELINHA_NOME`, `TELINHA_ADMIN`.

O `--admin` é um token: quem entrar com ele (no app: *Entrar numa sala* →
*Opções avançadas* → token de admin, ou `--admin TOKEN` na linha de comando)
ganha a coroa e pode expulsar gente (clique direito no membro).

## Docker

```sh
docker build -t telinha-server .
docker run -d --name telinha -p 7777:7777/tcp -p 7777:7777/udp \
  -e TELINHA_SENHA="uma senha boa" -e TELINHA_NOME="Sala da galera" -e TELINHA_ADMIN="token-secreto" \
  --restart unless-stopped telinha-server
```

Ou com `docker compose up -d` usando o [`docker-compose.yml`](../docker-compose.yml).
A imagem final é `FROM scratch` (só o binário). Funciona em amd64 e arm64.

## systemd

`/etc/systemd/system/telinha.service`:

```ini
[Unit]
Description=telinha - servidor de sala
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/telinha-server --porta 7777 --nome "Sala da galera"
Environment=TELINHA_SENHA=uma-senha-boa
Environment=TELINHA_ADMIN=token-secreto
DynamicUser=yes
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
```

```sh
sudo install -m755 zig-out/bin/telinha-server-x86_64 /usr/local/bin/telinha-server
sudo systemctl enable --now telinha
journalctl -u telinha -f
```

## Firewall e banda

- Libere a porta escolhida em **TCP e UDP** (`ufw allow 7777`). O TCP leva o controle e o
  chat; o UDP, na mesma porta, leva vídeo, som e voz. Sem o UDP funciona, mas tudo vai
  pelo TCP (perda de pacote segura o que vem atrás).
- Na nuvem (Oracle, AWS, GCP...) tem também o firewall da rede, fora da máquina
  (security list / security group): libere TCP e UDP 7777 lá também.
- Nas imagens Ubuntu da Oracle, o iptables rejeita tudo antes do UFW; a regra vai
  antes do REJECT: `sudo iptables -I INPUT <linha do REJECT> -p udp --dport 7777 -j ACCEPT`
  (e o mesmo com `-p tcp`), salvando em `/etc/iptables/rules.v4`.
- O servidor só encaminha: quase não usa CPU. A banda de **saída** é
  (soma das transmissões) × (espectadores de cada uma). Uma transmissão 1080p
  "equilibrada" gira em 0,3–6 Mbit/s dependendo do que está na tela.

## Sem VPS: link público

Se quem cria a sala está atrás de NAT/CGNAT, o próprio telinha abre um túnel
(protocolo do [bore](https://github.com/ekzhang/bore), servidor bore.pub):
no app, *Criar link público*; no servidor dedicado, `--publico`:

```sh
./telinha-server --publico
# [21:03] link público: bore.pub:41234  —  convite: telinha://bore.pub:41234#k3m9qx2a
```

Sem `--senha`, uma senha aleatória é criada (o endereço é público). Se o túnel
cair, ele reconecta pedindo a mesma porta, então o convite continua valendo.
Outro servidor bore (o seu, por exemplo): `--publico meu.servidor.com` (ou
`tunnel_host=` no `config.ini` do app).

## Sem VPS: porta aberta no roteador (UPnP)

Com o roteador de casa deixando (a maioria vem com UPnP ligado), dá pra ter
conexão **direta**, sem túnel no meio: menos atraso (o bore.pub fica em outro
continente) e sem o limite de banda dele. No app, *Abrir porta no roteador*; no
servidor dedicado, `--upnp`:

```sh
./telinha-server --upnp
# [21:03] porta aberta no roteador: 177.45.10.8:7777  —  convite: telinha://177.45.10.8:7777#k3m9qx2a
```

A porta fica aberta (renovada a cada 25 min) enquanto a sala está aberta e é
fechada quando ela fecha; se o processo cair sem fechar, o roteador apaga
sozinho em até 1 h. Se a operadora usa **CGNAT** (o roteador não tem IP próprio
na internet — comum em fibra e 4G), o telinha percebe e avisa: aí o caminho é o
link público. O firewall da própria máquina também precisa deixar a porta entrar.

Ou um túnel externo:

| túnel | comando | observação |
|---|---|---|
| bore | `bore local 7777 --to bore.pub` | grátis, sem conta |
| ngrok | `ngrok tcp 7777` | TCP exige conta com cartão verificado |
| serveo | `ssh -R 0:localhost:7777 serveo.net` | pode estar instável |
| playit.gg | app do playit | grátis, feito pra jogos |
| Tailscale/ZeroTier/Radmin | VPN entre a galera | usa o IP da VPN direto |

O tráfego é criptografado de ponta a ponta entre cada pessoa e o servidor da
sala, então o túnel não vê o conteúdo.
