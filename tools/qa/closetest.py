#!/usr/bin/env python3
"""Fecha a janela do telinha (como o X do gerenciador de janelas) em vários
estados e confere se o processo termina. uso: closetest.py [cenário...]"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from Xlib import X, protocol  # noqa: E402
from telinha_qa import Session, log  # noqa: E402


def close_window(app):
    d = app.d
    root = d.screen().root
    wm_protocols = d.intern_atom("WM_PROTOCOLS")
    wm_delete = d.intern_atom("WM_DELETE_WINDOW")
    for w in root.query_tree().children:
        try:
            name = w.get_wm_name()
        except Exception:
            name = None
        if name and "telinha" in name:
            ev = protocol.event.ClientMessage(window=w, client_type=wm_protocols, data=(32, [wm_delete, X.CurrentTime, 0, 0, 0]))
            w.send_event(ev, event_mask=X.NoEventMask)
            d.flush()
            return True
    return False


def run(name, args, setup=None, audio=False):
    with Session(f"close-{name}", audio=audio) as s:
        if audio:
            s.play_tone()
        port = str(43000 + hash(name) % 2000)
        gdb = ["gdb", "-q", "-batch", "-ex", "handle SIGPIPE nostop noprint", "-ex", "handle SIG32 nostop noprint", "-ex", "run", "-ex", "thread apply all bt 30", "--args"] if os.environ.get("GDB") else []
        a = s.app("a", 93, [x.replace("PORTA", port) for x in args], wrap=gdb)
        if setup:
            setup(s, a, port)
        time.sleep(4)
        t0 = time.time()
        if not close_window(a):
            log(f"{name}: não achei a janela")
            return False
        while time.time() - t0 < 8 and a.alive():
            time.sleep(0.1)
        if a.alive():
            log(f"{name}: TRAVOU ao fechar (pid {a.proc.pid})")
            os.system(f"for t in /proc/{a.proc.pid}/task/*; do echo $(cat $t/comm) $(cat $t/wchan); done | sort | uniq -c")
            if os.environ.get("GDB"):
                # interrompe o app (filho do gdb): o gdb imprime as pilhas
                os.system(f"pkill -INT -P {a.proc.pid} -x telinha")
                time.sleep(4)
                os.system(f"cp {s.base}/a.log {os.environ['GDB']}")
            return False
        log(f"{name}: fechou em {time.time() - t0:.2f} s (código {a.proc.returncode})")
        return True


def watcher(s, a, port):
    s.app("b", 94, ["--nome", "B", "--entrar", f"127.0.0.1:{port}", "--transmitir"])
    time.sleep(3)


SCENARIOS = {
    "inicio": (["--nome", "A"], None, False),
    "sala": (["--nome", "A", "--criar", "PORTA"], None, False),
    "transmitindo": (["--nome", "A", "--criar", "PORTA", "--transmitir"], None, False),
    "transmitindo_sw": (["--nome", "A", "--criar", "PORTA", "--transmitir", "--software"], None, False),
    "assistindo": (["--nome", "A", "--criar", "PORTA", "--assistir"], watcher, False),
    "audio": (["--nome", "A", "--criar", "PORTA", "--transmitir"], None, True),
}

if __name__ == "__main__":
    names = sys.argv[1:] or list(SCENARIOS)
    ok = all([run(n, *SCENARIOS[n]) for n in names])
    sys.exit(0 if ok else 1)
