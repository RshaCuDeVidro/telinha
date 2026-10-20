#!/usr/bin/env python3
"""Lê PTX da entrada e escreve um header C com ele numa string (ver src/c/cuda_scale.c)."""
import sys

ptx = sys.stdin.read()
print("// Gerado por tools/ptx_header.py a partir de src/c/cuda_scale.c (não editar à mão).")
print("#pragma once")
print("static const char telinha_scale_ptx[] =")
for line in ptx.splitlines():
    esc = line.replace("\\", "\\\\").replace('"', '\\"')
    print(f'    "{esc}\\n"')
print(";")
