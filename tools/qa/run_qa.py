#!/usr/bin/env python3
"""Testes de interface do telinha (ver telinha_qa.py).

    python3 tools/qa/run_qa.py            roda todos
    python3 tools/qa/run_qa.py volume     só os que têm "volume" no nome
    python3 tools/qa/run_qa.py -l         lista

Antes: zig build -Dnative-only=true (usa zig-out/bin/telinha).
"""
import os
import random
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(__file__))
from telinha_qa import QAError, Session, log  # noqa: E402

TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def port():
    return random.randint(42000, 46000)


def expect(cond, msg):
    if not cond:
        raise QAError(msg)


def center(r):
    return ((r[0] + r[2]) / 2, (r[1] + r[3]) / 2)


# ---------------------------------------------------------------------------


@test
def volume_da_transmissao():
    """Controles por cima da transmissão: volume, mudo, destacar e parar de assistir."""
    with Session("volume", audio=True) as s:
        s.play_tone()
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir"])
        bruno = s.app("bruno", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = bruno.member_id("Ana")
        bruno.wait(lambda st: any(v["owner"] == aid and v["shown"] for v in st["views"]), 20, "ver a tela da Ana")
        bruno.wait(lambda st: any(v["owner"] == aid and v["audio"] for v in st["views"]), 20, "ouvir o áudio da Ana")
        tile = bruno.tile(aid)
        mid = center(tile)
        # volume: arrasta o slider até ~50%
        bruno.drag("##vol", 0.5, 0.25, within=tile, hover_first=mid)
        st = bruno.wait(lambda st: abs(next(v for v in st["views"] if v["owner"] == aid)["volume"] - 0.5) < 0.12, 3, "volume em ~50%")
        log(f"volume depois de arrastar: {next(v for v in st['views'] if v['owner'] == aid)['volume']}")
        # mudo e de volta
        bruno.click("##mute", within=tile, hover_first=mid)
        bruno.wait(lambda st: next(v for v in st["views"] if v["owner"] == aid)["muted"], 3, "mudo ligado")
        bruno.click("##mute", within=tile, hover_first=mid)
        bruno.wait(lambda st: not next(v for v in st["views"] if v["owner"] == aid)["muted"], 3, "mudo desligado")
        # destacar e voltar pra grade
        bruno.click("##focus", within=tile, hover_first=mid)
        bruno.wait(lambda st: st["focused"] == aid, 3, "transmissão em destaque")
        tile = bruno.tile(aid)
        bruno.click("##focus", within=tile, hover_first=center(tile))
        bruno.wait(lambda st: st["focused"] is None, 3, "voltar pra grade")
        # parar de assistir
        tile = bruno.tile(aid)
        bruno.click("##close", within=tile, hover_first=center(tile))
        bruno.wait(lambda st: not st["views"], 3, "parar de assistir")


# ---------------------------------------------------------------------------


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if "-l" in sys.argv:
        for t in TESTS:
            print(f"{t.__name__}: {t.__doc__}")
        return 0
    chosen = [t for t in TESTS if not args or any(a in t.__name__ for a in args)]
    failed = []
    for t in chosen:
        log(f"=== {t.__name__}: {t.__doc__}")
        t0 = time.time()
        try:
            t()
            log(f"ok ({time.time() - t0:.1f} s)")
        except Exception as e:  # noqa: BLE001
            failed.append(t.__name__)
            log(f"FALHOU: {e}")
            traceback.print_exc()
    log(f"{len(chosen) - len(failed)}/{len(chosen)} passaram" + (f"; falharam: {', '.join(failed)}" if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
