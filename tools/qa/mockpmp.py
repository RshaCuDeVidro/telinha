"""Roteador de mentira do NAT-PMP (RFC 6886) pros testes: responde em
127.0.0.1:PORTA com o IP de fora 203.0.113.8 e anota cada pedido no log.
Uso: python3 mockpmp.py PORTA ARQUIVO_DE_LOG"""
import socket
import struct
import sys

port, logf = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", port))
with open(logf, "a", buffering=1) as log:
    while True:
        b, addr = s.recvfrom(1100)
        if len(b) >= 2 and b[0] == 0 and b[1] == 0:
            log.write("externo\n")
            s.sendto(bytes([0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 8]), addr)
        elif len(b) >= 12 and b[0] == 0 and b[1] in (1, 2):
            internal, external, life = struct.unpack(">HHI", b[4:12])
            proto = "udp" if b[1] == 1 else "tcp"
            log.write(f"{'apaga' if life == 0 else 'mapeia'} {proto} {internal}->{external} {life}\n")
            s.sendto(bytes([0, b[1] + 128, 0, 0, 0, 0, 0, 1]) + struct.pack(">HHI", internal, external, life), addr)
