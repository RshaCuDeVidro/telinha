# Servidor dedicado

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
docker run -d --name telinha -p 7777:7777 \
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

- Libere a porta TCP escolhida (`ufw allow 7777/tcp`).
- O servidor só encaminha: quase não usa CPU. A banda de **saída** é
  (soma das transmissões) × (espectadores de cada uma). Uma transmissão 1080p
  "equilibrada" gira em 0,3–6 Mbit/s dependendo do que está na tela.

## Sem VPS: túneis

Se quem cria a sala está atrás de NAT/CGNAT, um túnel TCP resolve:

| túnel | comando | observação |
|---|---|---|
| bore | `bore local 7777 --to bore.pub` | grátis, sem conta |
| ngrok | `ngrok tcp 7777` | TCP exige conta com cartão verificado |
| serveo | `ssh -R 0:localhost:7777 serveo.net` | pode estar instável |
| playit.gg | app do playit | grátis, feito pra jogos |
| Tailscale/ZeroTier/Radmin | VPN entre a galera | usa o IP da VPN direto |

O tráfego é criptografado de ponta a ponta entre cada pessoa e o servidor da
sala, então o túnel não vê o conteúdo.
