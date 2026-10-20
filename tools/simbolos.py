#!/usr/bin/env python3
"""Traduz a pilha de um relatório de travamento do telinha (telinha-travou.txt)
em função, arquivo e linha.

Uso: python3 tools/simbolos.py RELATORIO [PASTA_DO_BUILD]

PASTA_DO_BUILD (padrão: zig-out/bin) tem os símbolos do MESMO build que
travou: `telinha.debug` (Linux) ou `telinha.exe` + `telinha.pdb` (Windows).
Um build separado do mesmo código não serve (o layout muda); o relatório
traz o commit pra conferir.

Linux: addr2line nos endereços (o binário não é PIE). Windows: o relatório
traz "telinha.exe+0xDESLOC"; llvm-symbolizer lê o .pdb.
"""
import os
import re
import shutil
import subprocess
import sys


REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def short(path):
    """Caminho curto: relativo ao repositório (ou "std/..." pra biblioteca do Zig)."""
    p = os.path.normpath(os.path.join(os.path.join(REPO, "zig-out", "bin"), path)) if not os.path.isabs(path) else path
    if p.startswith(REPO + os.sep):
        return os.path.relpath(p, REPO)
    i = p.find(os.sep + "std" + os.sep)
    return p[i + 1:] if i >= 0 else p


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    report = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    bindir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin")

    m = re.search(r"\(commit ([^)]+)\)", report)
    if m:
        here = subprocess.run(["git", "describe", "--always", "--dirty=-modificado", "--abbrev=10"],
                              capture_output=True, text=True, cwd=os.path.dirname(os.path.abspath(__file__))).stdout.strip()
        print(f"relatório do commit {m.group(1)}; este repositório está em {here or '?'}")
        if here and here != m.group(1):
            print("  atenção: os símbolos só batem com o build do mesmo commit")

    linux_addrs = re.findall(r"^\S*/?telinha\([^)]*\) \[(0x[0-9a-f]+)\]", report, re.M)
    win = list(dict.fromkeys(re.findall(r"^\s+telinha\.exe\+(0x[0-9a-f]+)", report, re.M)))

    if linux_addrs:
        dbg = os.path.join(bindir, "telinha.debug")
        if not os.path.exists(dbg):
            dbg = os.path.join(bindir, "telinha")
        tool = shutil.which("addr2line") or shutil.which("llvm-addr2line")
        for a in linux_addrs:
            # endereço de volta: a chamada está no byte anterior
            q = hex(int(a, 16) - 1)
            out = subprocess.run([tool, "-f", "-C", "-i", "-e", dbg, q], capture_output=True, text=True).stdout.strip().splitlines()
            pairs = [f"{out[i]} ({short(out[i + 1])})" for i in range(0, len(out) - 1, 2)]
            print(f"{a}: " + " <- ".join(pairs))
    if win:
        exe = os.path.join(bindir, "telinha.exe")
        tool = shutil.which("llvm-symbolizer")
        if not tool:
            print("precisa do llvm-symbolizer pra ler o .pdb")
            return 1
        for a in win:
            q = hex(int(a, 16) - 1)
            out = subprocess.run([tool, "--relative-address", "--obj", exe, q], capture_output=True, text=True).stdout.strip().splitlines()
            pairs = [f"{out[i]} ({short(out[i + 1])})" for i in range(0, len(out) - 1, 2)]
            print(f"telinha.exe+{a}: " + " <- ".join(pairs))
    if not linux_addrs and not win:
        print("nenhum endereço do telinha no relatório")
    return 0


if __name__ == "__main__":
    sys.exit(main())
