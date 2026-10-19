# Changelog

## 2.0.0

Reescrita completa.

- Interface nova estilo Discord (Dear ImGui): salas, chat, membros, várias transmissões em grade, destaque, modo cinema.
- Qualquer pessoa da sala transmite e assiste; Linux ↔ Windows nos dois sentidos.
- Vídeo H.264: NVIDIA NVENC/NVDEC quando disponível, openh264 (SIMD, multithread) como alternativa; conversão de cor de quem assiste num shader.
- Reconexão automática com retomada da transmissão e de quem você assistia.
- Pipeline em duas threads (captura ∥ encode), controle de banda adaptativo, descarte de atraso por espectador.
- Criptografia X25519 + ChaCha20-Poly1305 com a senha da sala na derivação das chaves.
- Captura: PipeWire/xdg-desktop-portal (Wayland), X11, DXGI (Windows); no Hyprland o cursor é desenhado pelo telinha pra não deixar o mouse com lag.
- Latência de ponta a ponta medida e mostrada nas estatísticas.
- Servidor dedicado estático (`telinha-server`, Linux x86_64/aarch64), Docker, systemd.
- Admin com expulsão, convites `telinha://`, configurações salvas.
- Testes de unidade e integração, benchmark, CI no GitHub Actions.

## 1.0.0

- Primeira versão: um servidor Linux (wlr-screencopy) e um visualizador Windows, JPEG por tiles.
