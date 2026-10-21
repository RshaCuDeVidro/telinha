#!/bin/sh
# Instala o telinha no Linux (só pro seu usuário, sem sudo):
#   curl -fsSL https://raw.githubusercontent.com/RshaCuDeVidro/telinha/main/install.sh | sh
#
# - baixa a última versão dos Releases e confere o SHA256
# - binário em ~/.local/bin/telinha
# - atalho no menu de aplicativos, com ícone, e links telinha:// abrindo no telinha
# - avisa se faltar alguma biblioteca do sistema (e o comando pra instalar)
#
# Remover: sh install.sh --remove
set -eu

REPO="RshaCuDeVidro/telinha"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_DIR/applications"
ICON_DIR="$DATA_DIR/icons/hicolor/scalable/apps"
BIN="$BIN_DIR/telinha"
DESKTOP="$APPS_DIR/telinha.desktop"
ICON="$ICON_DIR/telinha.svg"

say() { printf '\033[1;35m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merro:\033[0m %s\n' "$*" >&2; exit 1; }

refresh_menus() {
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$APPS_DIR" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA_DIR/icons/hicolor" 2>/dev/null || true
}

if [ "${1:-}" = "--remove" ] || [ "${1:-}" = "--uninstall" ]; then
    rm -f "$BIN" "$DESKTOP" "$ICON"
    refresh_menus
    say "telinha removido (configurações e clipes ficaram onde estavam)"
    exit 0
fi

[ "$(uname -s)" = "Linux" ] || die "este instalador é pro Linux; no Windows baixe o .exe dos Releases"
[ "$(uname -m)" = "x86_64" ] || die "só tem binário pra x86-64 por enquanto (essa máquina é $(uname -m))"

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -qO "$2" "$1"; }
else
    die "precisa do curl ou do wget"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# TELINHA_DOWNLOAD_URL / TELINHA_ICON_URL: outro lugar pra baixar (espelho, teste)
BASE="${TELINHA_DOWNLOAD_URL:-https://github.com/$REPO/releases/latest/download}"
say "baixando a última versão do telinha"
fetch "$BASE/telinha-linux-x86_64" "$TMP/telinha" || die "não consegui baixar o binário (sem internet, ou o repositório não é público?)"
if fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" 2>/dev/null && command -v sha256sum >/dev/null 2>&1; then
    want=$(awk '$2 == "telinha-linux-x86_64" { print $1 }' "$TMP/SHA256SUMS")
    got=$(sha256sum "$TMP/telinha" | awk '{ print $1 }')
    [ -n "$want" ] && [ "$want" != "$got" ] && die "o SHA256 não bate (download corrompido?); nada foi instalado"
    [ -n "$want" ] && say "SHA256 conferido"
fi
fetch "${TELINHA_ICON_URL:-https://raw.githubusercontent.com/$REPO/main/assets/telinha.svg}" "$TMP/telinha.svg" 2>/dev/null || true

mkdir -p "$BIN_DIR" "$APPS_DIR" "$ICON_DIR"
install -m 755 "$TMP/telinha" "$BIN"
[ -s "$TMP/telinha.svg" ] && install -m 644 "$TMP/telinha.svg" "$ICON"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=telinha
GenericName=Screen sharing
GenericName[pt_BR]=Compartilhamento de tela
Comment=Share your screen with friends, with low latency
Comment[pt_BR]=Compartilhe a tela com a galera, com pouca latência
Exec="$BIN" %u
Icon=telinha
Terminal=false
Categories=Network;VideoConference;Chat;
Keywords=screen;share;stream;voice;tela;transmitir;
MimeType=x-scheme-handler/telinha;
StartupWMClass=telinha
EOF
# links telinha:// abrem no telinha: pelo xdg-mime; se ele não registrar (acontece
# fora do GNOME/KDE), direto no mimeapps.list, sem mexer no resto do arquivo
command -v xdg-mime >/dev/null 2>&1 && xdg-mime default telinha.desktop x-scheme-handler/telinha 2>/dev/null || true
if [ "$(xdg-mime query default x-scheme-handler/telinha 2>/dev/null)" != "telinha.desktop" ]; then
    MIMEAPPS="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
    mkdir -p "$(dirname "$MIMEAPPS")"
    touch "$MIMEAPPS"
    awk 'BEGIN { done = 0 }
         /^x-scheme-handler\/telinha=/ { next }
         { print }
         /^\[Default Applications\]/ && !done { print "x-scheme-handler/telinha=telinha.desktop"; done = 1 }
         END { if (!done) { print ""; print "[Default Applications]"; print "x-scheme-handler/telinha=telinha.desktop" } }' \
        "$MIMEAPPS" > "$MIMEAPPS.telinha-tmp" && mv "$MIMEAPPS.telinha-tmp" "$MIMEAPPS"
fi
refresh_menus
say "instalado em $BIN"

# bibliotecas do sistema que faltam (o telinha abre as do X11/Wayland sozinho)
missing=$(ldd "$BIN" 2>/dev/null | awk '/not found/ { print $1 }' | tr '\n' ' ')
if [ -n "$missing" ]; then
    printf '\n'
    say "faltam bibliotecas do sistema: $missing"
    if command -v apt-get >/dev/null 2>&1; then
        echo "   sudo apt install libportal1 libpipewire-0.3-0 libgl1"
    elif command -v pacman >/dev/null 2>&1; then
        echo "   sudo pacman -S libportal pipewire libglvnd"
    elif command -v dnf >/dev/null 2>&1; then
        echo "   sudo dnf install libportal pipewire-libs libglvnd-glx"
    elif command -v zypper >/dev/null 2>&1; then
        echo "   sudo zypper install libportal-1-1 libpipewire-0_3-0 Mesa-libGL1"
    else
        echo "   instale pelo gerenciador de pacotes da sua distro"
    fi
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) say "pronto: abra pelo menu de aplicativos ou rode 'telinha'" ;;
    *)
        say "pronto: abra pelo menu de aplicativos ou rode '$BIN'"
        echo "   ($BIN_DIR não está no seu PATH; adicione no ~/.profile pra rodar só 'telinha')"
        ;;
esac
