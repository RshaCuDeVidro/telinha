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
        bruno.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 20, "ver a tela da Ana")
        bruno.wait(lambda st: any(v["stream"] == aid and v["audio"] for v in st["views"]), 20, "ouvir o áudio da Ana")
        tile = bruno.tile(aid)
        mid = center(tile)
        # volume: arrasta o slider até ~50%
        bruno.drag("##vol", 0.5, 0.25, within=tile, hover_first=mid)
        st = bruno.wait(lambda st: abs(next(v for v in st["views"] if v["stream"] == aid)["volume"] - 0.5) < 0.12, 3, "volume em ~50%")
        log(f"volume depois de arrastar: {next(v for v in st['views'] if v['stream'] == aid)['volume']}")
        # mudo e de volta
        bruno.click("##mute", within=tile, hover_first=mid)
        bruno.wait(lambda st: next(v for v in st["views"] if v["stream"] == aid)["muted"], 3, "mudo ligado")
        bruno.click("##mute", within=tile, hover_first=mid)
        bruno.wait(lambda st: not next(v for v in st["views"] if v["stream"] == aid)["muted"], 3, "mudo desligado")
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


@test
def fechar_sala():
    """Dono fecha a sala (com confirmação): quem estava fica sabendo e não fica tentando reconectar."""
    with Session("fechar") as s:
        p = port()
        dono = s.app("dono", 91, ["--nome", "Dono", "--criar", str(p)])
        conv = s.app("conv", 92, ["--nome", "Conv", "--entrar", f"127.0.0.1:{p}"])
        conv.wait(lambda st: st["status"] == "connected", 10, "o convidado entrar")
        dono.wait(lambda st: len(st["members"]) == 2, 10, "o dono ver o convidado")
        dono.click("##leave")
        dono.wait(lambda st: st["leave_confirm"], 3, "a confirmação de fechar a sala")
        dono.click("Fechar a sala", window="Fechar a sala")
        dono.wait(lambda st: st["screen"] == "home", 5, "o dono voltar pro início")
        st = conv.wait(lambda st: st["final"] and st["status"] == "failed", 5, "o convidado saber que a sala fechou")
        expect(st["deny"] == 3 and "fechou a sala" in st["error"], f"motivo errado: {st['deny']} {st['error']!r}")
        time.sleep(3)
        st = conv.state()
        expect(st["reconnect"]["attempt"] == 0, f"tentou reconectar numa sala fechada: {st['reconnect']}")
        conv.click("Voltar ao início")
        conv.wait(lambda st: st["screen"] == "home", 3, "voltar pro início")


@test
def link_publico():
    """Link público (túnel de mentira local): o convidado entra por ele, aparece como 'link público', e 'Desligar' tira ele da sala."""
    import subprocess
    with Session("link") as s:
        p, ctl = port(), port()
        s.spawn("mockbore", [sys.executable, os.path.join(os.path.dirname(__file__), "mockbore.py"), str(ctl)], dict(os.environ))
        time.sleep(0.5)
        dono = s.app("dono", 91, ["--nome", "Dono", "--criar", str(p), "--senha", "segredo1"], config={"tunnel_host": f"127.0.0.1:{ctl}"})
        dono.wait(lambda st: st["status"] == "connected", 10, "o dono entrar")
        dono.click(contains="Criar link público")
        st = dono.wait(lambda st: st["tunnel"] and st["tunnel"]["state"] == "ready", 10, "o link público ficar pronto")
        pub = int(st["tunnel"]["addr"].rsplit(":", 1)[1])
        expect(pub != p, "o link público tem que ser outra porta")
        conv = s.app("conv", 92, ["--nome", "Conv", "--entrar", f"127.0.0.1:{pub}", "--senha", "segredo1"])
        st = conv.wait(lambda st: st["status"] == "connected", 10, "o convidado entrar pelo link")
        expect(st["route"] == 5, f"o convidado deveria estar 'via link público', está na rota {st['route']}")
        cid = st["my_id"]
        dono.wait(lambda st: any(m["id"] == cid and m["route"] == 5 for m in st["members"]), 5, "o dono ver o convidado vindo pelo link")
        dono.click(contains="Desligar")
        st = conv.wait(lambda st: st["final"], 6, "o convidado sair quando o link é desligado")
        expect(st["deny"] == 4, f"motivo errado: {st['deny']} {st['error']!r}")
        dono.wait(lambda st: len(st["members"]) == 1 and st["tunnel"] is None, 5, "o dono ficar sozinho e sem link")


@test
def admin_menu():
    """Menu de admin (clique direito): silenciar, liberar, dar admin, trancar a sala, expulsar."""
    with Session("admin") as s:
        p = port()
        dono = s.app("dono", 91, ["--nome", "Dono", "--criar", str(p)])
        conv = s.app("conv", 92, ["--nome", "Conv", "--entrar", f"127.0.0.1:{p}"])
        cid = conv.wait(lambda st: st["status"] == "connected", 10, "o convidado entrar")["my_id"]

        def menu(item):
            dono.click_rect(dono.member_row(cid), button=3)
            dono.click(contains=item)

        menu("Silenciar o microfone")
        conv.wait(lambda st: st["admin_muted"], 5, "o convidado ser silenciado")
        dono.wait(lambda st: any(m["id"] == cid and m["muted"] for m in st["members"]), 5, "o dono ver o convidado silenciado")
        menu("Liberar o microfone")
        conv.wait(lambda st: not st["admin_muted"], 5, "o microfone ser liberado")
        menu("Dar admin")
        conv.wait(lambda st: st["admin"], 5, "o convidado virar admin")
        menu("Tirar o admin")
        conv.wait(lambda st: not st["admin"], 5, "o convidado perder o admin")
        # tranca a sala: ninguém novo entra
        dono.click("##lockroom")
        dono.wait(lambda st: st["locked"], 5, "a sala trancar")
        outro = s.app("outro", 93, ["--nome", "Outro", "--entrar", f"127.0.0.1:{p}"])
        outro.wait(lambda st: st["screen"] == "home" and "trancada" in st["home_error"], 10, "a entrada ser recusada")
        dono.click("##lockroom")
        dono.wait(lambda st: not st["locked"], 5, "a sala destrancar")
        menu("Expulsar da sala")
        st = conv.wait(lambda st: st["final"], 5, "o convidado ser expulso")
        expect(st["deny"] == 1, f"motivo errado: {st['deny']}")


@test
def camera():
    """Câmera (de teste, no PipeWire isolado): liga, aparece pra sala, quem assiste vê."""
    import subprocess
    with Session("camera", audio=True) as s:
        s.fake_camera()
        p = port()
        dono = s.app("dono", 91, ["--nome", "Dono", "--criar", str(p)])
        conv = s.app("conv", 92, ["--nome", "Conv", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        dono.wait(lambda st: st["status"] == "connected", 10, "o dono entrar")
        did = dono.state()["my_id"]
        dono.click("##camera")
        st = dono.wait(lambda st: st["camera"] and st["camera"]["state"] == "live", 15, "a câmera ficar ao vivo")
        log(f"câmera: {st['camera']}")
        cam = did | 0x80000000
        conv.wait(lambda st: any(m["id"] == did and m["camera"] for m in st["members"]), 10, "a sala ver a câmera ligada")
        conv.wait(lambda st: any(v["stream"] == cam and v["shown"] for v in st["views"]), 15, "o convidado ver a câmera")
        dono.click("##camera")
        dono.wait(lambda st: st["camera"] is None, 5, "a câmera desligar")
        conv.wait(lambda st: not any(v["stream"] == cam for v in st["views"]), 10, "o quadro da câmera sumir pro convidado")


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
