#!/bin/sh
# Notas do release a partir do CHANGELOG.md (usado pelo CI numa tag vX.Y.Z).
#   sh tools/release_notes.sh v3.1.0 dono/repo > notas.md
# O que vem antes de "<!-- detalhes -->" na seção da versão aparece aberto; o
# resto vai dentro de um "Full changelog" que abre com um clique.
set -eu
tag=$1
repo=$2
v=${tag#v}
anchor=$(printf '%s' "$v" | tr -d .)
dl="https://github.com/$repo/releases/download/$tag"

section=$(awk -v v="$v" '$0 == "## " v { f = 1; next } f && /^## / { exit } f' CHANGELOG.md)
[ -n "$section" ] || { echo "CHANGELOG.md não tem a seção ## $v" >&2; exit 1; }

cat <<NOTES
## Download

| Platform | File |
|---|---|
| **Windows 10/11** | [telinha-windows-x86_64.exe]($dl/telinha-windows-x86_64.exe) |
| **Linux** (glibc 2.31+: Ubuntu/Pop!_OS 20.04+, Debian 11+, Fedora, Arch) | [telinha-linux-x86_64]($dl/telinha-linux-x86_64) · [.tar.gz]($dl/telinha-linux-x86_64.tar.gz) |
| **Dedicated server** | [x86-64]($dl/telinha-server-linux-x86_64) · [ARM64]($dl/telinha-server-linux-aarch64) |

**Linux in one command** (no sudo; adds telinha to your app menu):

\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/$repo/main/install.sh | sh
\`\`\`

> The Windows \`.exe\` isn't code-signed: on first launch, SmartScreen asks; choose **More info → Run anyway**.

**Already have telinha 3.2 or newer?** It updates itself: it shows what changes and installs after checking the signature (\`SHA256SUMS.sig\`). Coming from 3.1 or older, download it by hand once.

NOTES

printf '%s\n' "$section" | awk '
    /^<!-- detalhes -->/ { print "<details>\n<summary><b>Full changelog</b></summary>\n"; inside = 1; next }
    { print }
    END { if (inside) print "\n</details>" }'

cat <<NOTES

🇧🇷 [Novidades em português](https://github.com/$repo/blob/$tag/CHANGELOG.pt.md#$anchor) · checksums in \`SHA256SUMS\` · debug symbols in \`telinha-simbolos.tar.gz\`
NOTES
