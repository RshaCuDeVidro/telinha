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
        # configurações: a câmera aparece na lista; trocar a resolução com ela ligada reinicia
        dono.click("##gear")
        dono.wait(lambda st: st["cfg"]["cameras"] >= 1, 5, "a lista de câmeras ter a de teste")
        dono.click("##camdev")
        dono.click(contains="Camera de teste", window="##Combo")
        dono.wait(lambda st: st["cfg"]["camera_device"] != "", 5, "escolher a câmera de teste")
        dono.click("##camres")
        dono.click("480p", window="##Combo")
        st = dono.wait(lambda st: st["cfg"]["camera_res"] == 0 and st["camera"] and st["camera"]["state"] == "live" and 0 < st["camera"]["h"] <= 480, 15, "a câmera voltar em 480p")
        log(f"câmera em 480p: {st['camera']}")
        conv.wait(lambda st: any(m["id"] == did and m["camera"] and m.get("cam_h", 480) <= 480 for m in st["members"]), 10, "a sala ver a câmera de novo")
        conv.wait(lambda st: any(v["stream"] == cam and v["shown"] for v in st["views"]), 15, "o convidado continuar vendo a câmera")
        dono.key("Escape")
        dono.wait(lambda st: not st["settings_modal"], 3, "fechar as configurações")
        dono.click("##camera")
        dono.wait(lambda st: st["camera"] is None, 5, "a câmera desligar")
        conv.wait(lambda st: not any(v["stream"] == cam for v in st["views"]), 10, "o quadro da câmera sumir pro convidado")


@test
def tela_inicial():
    """Tela inicial: abas, campos, opções avançadas, erros de endereço/porta, criar sala."""
    with Session("inicio") as s:
        a = s.app("a", 91, [])
        a.wait(lambda st: st["screen"] == "home", 10, "a tela inicial")
        a.fill("##name", "Testador")
        a.wait(lambda st: st["cfg"]["name"] == "Testador", 3, "o nome mudar")
        # entrar sem endereço / com endereço sem porta / porta fechada
        a.fill("##addr", "")
        a.click("Entrar##go")
        a.wait(lambda st: "porta" in st["home_error"], 3, "pedir o endereço com a porta")
        a.fill("##addr", "127.0.0.1:1")
        a.click("Entrar##go")
        a.wait(lambda st: st["screen"] == "home" and "recusada" in st["home_error"], 10, "conexão recusada")
        # convite colado no campo de endereço: separa senha
        a.fill("##addr", "telinha://127.0.0.1:1#segredo")
        a.click("Entrar##go")
        a.wait(lambda st: st["cfg"]["join_pass"] == "segredo" and st["cfg"]["join_addr"] == "127.0.0.1:1", 10, "o convite virar endereço + senha")
        # opções avançadas
        a.click("##adv")
        a.wait(lambda st: st["show_advanced"], 3, "abrir as opções avançadas")
        a.find("##tok")
        a.click("##adv")
        a.wait(lambda st: not st["show_advanced"], 3, "fechar as opções avançadas")
        # aba criar sala
        a.click("Criar sala")
        a.wait(lambda st: st["home_tab"] == 1, 3, "a aba criar sala")
        a.fill("##room", "Sala QA")
        a.fill("##port", "abc")
        a.click("Criar sala##go")
        a.wait(lambda st: "inválida" in st["home_error"], 3, "porta inválida")
        p = port()
        a.fill("##port", str(p))
        a.fill("##hpass", "s3nha")
        a.click("Criar sala##go")
        st = a.wait(lambda st: st["screen"] == "room" and st["status"] == "connected", 10, "a sala abrir")
        expect(st["hosting"] and st["room"] == "Sala QA" and st["admin"], f"sala errada: {st['room']}")
        expect(st["cfg"]["host_pass"] == "s3nha", "senha não guardada")


@test
def sala_controles():
    """Sala: convite, chat (Enter e botão), esconder/mostrar chat, surdo, configurações, compartilhar tela, assistir pela barra lateral e pelo card, modo cinema, F11."""
    with Session("controles") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--senha", "pw1"])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}", "--senha", "pw1"])
        bid = b.wait(lambda st: st["status"] == "connected", 10, "o Bruno entrar")["my_id"]
        aid = b.member_id("Ana")
        # convite: quem hospeda sem link público é avisado; quem entrou copia o endereço que usou
        a.click("##invite")
        a.toasted("link público")
        b.click("##invite")
        b.wait(lambda st: st["clipboard"] == f"telinha://127.0.0.1:{p}#pw1", 3, "o convite na área de transferência")
        # chat: Enter e o botão de enviar
        b.click("##chatin")
        b.type("ola sala\n")
        a.wait(lambda st: any(c["text"] == "ola sala" and c["from"] == bid for c in st["chat"]), 5, "a mensagem chegar (Enter)")
        b.type("segunda")
        b.click("##send")
        a.wait(lambda st: any(c["text"] == "segunda" for c in st["chat"]), 5, "a mensagem chegar (botão)")
        b.wait(lambda st: st["chat_input"] == "", 3, "a caixa esvaziar")
        # esconder e mostrar o chat
        b.click("##hidechat")
        b.wait(lambda st: not st["chat_visible"] and not st["cfg"]["show_chat"], 3, "esconder o chat")
        a.click("##chatin")
        a.type("enquanto escondido\n")
        b.wait(lambda st: st["chat_unread"] >= 1, 5, "contar mensagem não lida")
        b.click("##showchat")
        b.wait(lambda st: st["chat_visible"] and st["chat_unread"] == 0, 3, "mostrar o chat")
        # surdo
        b.click("##deaf")
        b.wait(lambda st: st["deaf"], 3, "ficar surdo")
        a.wait(lambda st: any(m["id"] == bid and m["flags"] & 16 for m in st["members"]), 5, "a sala ver o surdo")
        b.click("##deaf")
        b.wait(lambda st: not st["deaf"], 3, "voltar a ouvir")
        # configurações
        b.click("##gear")
        b.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        before = b.state()["cfg"]
        for label, key in [("Mostrar estatísticas sempre", "stats_always"), ("Sons de aviso", "sounds"),
                           ("Entrar na sala com o microfone ligado", "mic_on_join"), ("Supressão de ruído", "noise_suppression"),
                           ("Cancelamento de eco", "echo_cancellation")]:
            b.click(contains=label)
            b.wait(lambda st, k=key, v=before[key]: st["cfg"][k] != v, 3, f"marcar {label}")
        b.drag("##sens", 0.5, 0.9)
        b.wait(lambda st: st["cfg"]["voice_sensitivity"] > 70, 3, "a sensibilidade subir")
        b.fill("##sname", "Bruno2")
        b.click("Fechar", window="Configura")
        b.wait(lambda st: not st["settings_modal"] and st["cfg"]["name"] == "Bruno2", 3, "fechar as configurações")
        ini = open(os.path.join(b.cfg, "telinha", "config.ini")).read()
        expect("name=Bruno2" in ini and "stats_always=1" in ini, "configuração não foi salva no arquivo")
        # compartilhar tela: modal, opções, cancelar, ao vivo, aplicar, parar
        a.click(contains="Compartilhar tela##share")
        a.wait(lambda st: st["share_modal"], 3, "abrir o compartilhar tela")
        a.click("Jogo e vídeo")
        a.click("720p")
        a.click("15")
        a.wait(lambda st: st["cfg"]["mode"] == 1 and st["cfg"]["resolution"] == 2 and st["cfg"]["fps"] == 15, 3, "as opções mudarem")
        a.drag("##q", 0.5, 0.95)
        a.wait(lambda st: st["cfg"]["quality"] > 85, 3, "a qualidade subir")
        c0 = a.state()["cfg"]
        a.click(contains="Mostrar o cursor")
        a.click(contains="Compartilhar o áudio")
        a.click(contains="Usar a placa de vídeo")
        a.wait(lambda st: st["cfg"]["cursor"] != c0["cursor"] and st["cfg"]["audio"] != c0["audio"] and st["cfg"]["hardware"] != c0["hardware"], 3, "as caixas de marcar")
        a.click("Cancelar", window="Compartilhar")
        a.wait(lambda st: not st["share_modal"] and st["sharer"] is None, 3, "cancelar sem transmitir")
        a.click(contains="Compartilhar tela##share")
        a.click(contains="Ao vivo", window="Compartilhar")
        a.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live", 15, "ficar ao vivo")
        a.click(contains="Ao vivo (configurar)##share")
        a.click("Aplicar")
        a.toasted("Configurações aplicadas")
        # Bruno assiste pela barra lateral e para; depois pelo card
        b.click("live")
        b.wait(lambda st: any(v["stream"] == aid for v in st["views"]), 5, "assistir pela barra lateral")
        b.click("live")
        b.wait(lambda st: not st["views"], 5, "parar de assistir pela barra lateral")
        b.click("card")
        b.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 15, "assistir pelo card")
        # modo cinema (duplo clique) e Esc
        tile = b.tile(aid)
        b.click_at(*[int(x) for x in (b.items()[0][0] + (tile[0] + tile[2]) / 2, b.items()[0][1] + (tile[1] + tile[3]) / 2)], double=True)
        b.wait(lambda st: st["theater"] and st["fullscreen"], 3, "modo cinema")
        b.key("Escape")
        b.wait(lambda st: not st["theater"] and not st["fullscreen"], 3, "sair do modo cinema")
        b.key("F11")
        b.wait(lambda st: st["fullscreen"], 3, "tela cheia (F11)")
        b.key("F11")
        b.wait(lambda st: not st["fullscreen"], 3, "sair da tela cheia")
        # volume da voz de alguém, só pra mim
        b.click_rect(b.member_row(aid), button=3)
        b.click(contains="Silenciar pra mim")
        b.wait(lambda st: any(m["id"] == aid and m["voice_volume"] == 0 for m in st["members"]), 3, "silenciar a voz da Ana pra mim")
        b.click_rect(b.member_row(aid), button=3)
        b.click(contains="Voltar a ouvir")
        b.wait(lambda st: any(m["id"] == aid and m["voice_volume"] == 1 for m in st["members"]), 3, "voltar a ouvir a Ana")
        # parar a transmissão pelo modal
        a.click(contains="Ao vivo (configurar)##share")
        a.click("Parar")
        a.wait(lambda st: st["sharer"] is None, 5, "parar de transmitir")
        b.wait(lambda st: not st["views"], 5, "o Bruno parar de ver a Ana")


@test
def upnp_e_tunel_proprio():
    """Card 'galera de fora': porta no roteador (roteador de mentira), túnel próprio (copiar comandos e convite), link público que falha."""
    with Session("upnp") as s:
        udp, http = port(), port()
        s.spawn("igd", [sys.executable, os.path.join(os.path.dirname(__file__), "mockigd.py"), str(udp), str(http), os.path.join(s.base, "igd.log")], dict(os.environ))
        time.sleep(0.5)
        p, dead = port(), port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--senha", "pw2"], extra_env={"TELINHA_UPNP_SSDP": f"127.0.0.1:{udp}"},
                  config={"tunnel_host": f"127.0.0.1:{dead}"})
        a.wait(lambda st: st["status"] == "connected", 10, "entrar")
        a.click(contains="Abrir porta no roteador")
        st = a.wait(lambda st: st["upnp"] and st["upnp"]["state"] == "ready", 10, "o roteador abrir a porta")
        expect(st["upnp"]["addr"] == f"203.0.113.7:{p}", f"endereço errado: {st['upnp']}")
        a.click(contains="Copiar convite##upnp")
        a.wait(lambda st: st["clipboard"] == f"telinha://203.0.113.7:{p}#pw2", 3, "o convite com o IP de fora")
        a.click(contains="Fechar porta")
        a.wait(lambda st: st["upnp"] is None, 3, "fechar a porta")
        time.sleep(1)
        expect("DeletePortMapping" in open(os.path.join(s.base, "igd.log")).read(), "a porta não foi fechada no roteador")
        # link público com o servidor do túnel fora do ar: falha, tenta de novo, fecha
        a.click(contains="Criar link público")
        a.wait(lambda st: st["tunnel"] and st["tunnel"]["state"] == "failed", 10, "o link público falhar")
        a.click(contains="Tentar de novo")
        a.wait(lambda st: st["tunnel"] is not None, 3, "tentar de novo")
        a.wait(lambda st: st["tunnel"]["state"] == "failed", 10, "falhar de novo")
        a.click("Fechar##tunel")
        a.wait(lambda st: st["tunnel"] is None, 3, "fechar o aviso")
        # túnel próprio: comandos e convite com o endereço digitado
        a.click("##own")
        a.wait(lambda st: st["own_tunnel_open"], 3, "abrir o túnel próprio")
        a.click("##cp")
        a.wait(lambda st: st["clipboard"].startswith("ngrok tcp ") or st["clipboard"].startswith("bore ") or st["clipboard"].startswith("ssh "), 3, "copiar um comando")
        a.fill("##pub", "0.tcp.sa.ngrok.io:12345")
        a.click(contains="Copiar convite##proprio")
        a.wait(lambda st: st["clipboard"] == "telinha://0.tcp.sa.ngrok.io:12345#pw2", 3, "o convite do túnel próprio")


@test
def reconexao():
    """Servidor dedicado cai e volta: o app reconecta sozinho; 'Tentar agora' e 'Sair' na tela de queda."""
    import subprocess
    from telinha_qa import SERVER
    with Session("reconexao") as s:
        p = port()
        srv = s.spawn("srv", [SERVER, "-p", str(p), "-n", "Dedicado"], dict(os.environ))
        time.sleep(0.5)
        a = s.app("a", 91, ["--nome", "Ana", "--entrar", f"127.0.0.1:{p}"])
        a.wait(lambda st: st["status"] == "connected", 10, "entrar")
        s.stop_proc(srv)
        a.wait(lambda st: st["reconnect"]["attempt"] >= 1, 10, "começar a reconectar")
        a.click("Tentar agora")
        a.wait(lambda st: st["reconnect"]["attempt"] >= 2, 10, "tentar de novo na hora")
        s.spawn("srv2", [SERVER, "-p", str(p), "-n", "Dedicado"], dict(os.environ))
        a.wait(lambda st: st["status"] == "connected" and st["reconnect"]["attempt"] == 0, 30, "reconectar sozinho")
        a.toasted("Reconectado")
        # cai de novo e a pessoa desiste
        for name, pr in list(s.procs):
            if name == "srv2":
                s.stop_proc(pr)
        a.wait(lambda st: st["reconnect"]["waiting"], 10, "esperar a próxima tentativa")
        a.click("Sair")
        a.wait(lambda st: st["screen"] == "home", 5, "voltar pro início")


@test
def conectando_cancelar():
    """'Conectando...' numa sala que não responde: Cancelar volta pro início."""
    import socket
    with Session("conectando") as s:
        p = port()
        ls = socket.socket()
        ls.bind(("127.0.0.1", p))
        ls.listen(5)  # aceita a conexão e nunca responde
        try:
            a = s.app("a", 91, ["--nome", "Ana", "--entrar", f"127.0.0.1:{p}"])
            a.wait(lambda st: st["status"] == "connecting", 5, "ficar conectando")
            time.sleep(1)
            a.click("Cancelar")
            a.wait(lambda st: st["screen"] == "home", 5, "cancelar")
        finally:
            ls.close()


@test
def microfone():
    """Microfone (no áudio privado, entrada de mentira): botão, Ctrl+M, Ctrl+D, a sala vê o estado."""
    with Session("microfone", audio=True) as s:
        s.fake_mic()
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p)])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}"])
        aid = a.wait(lambda st: st["status"] == "connected", 10, "entrar")["my_id"]
        b.wait(lambda st: st["status"] == "connected", 10, "o Bruno entrar")
        a.click("##mic")
        a.wait(lambda st: st["mic"], 5, "ligar o microfone")
        b.wait(lambda st: any(m["id"] == aid and m["flags"] & 8 for m in st["members"]), 5, "a sala ver o microfone ligado")
        a.key("m", ctrl=True)
        a.wait(lambda st: not st["mic"], 3, "Ctrl+M desligar")
        a.key("m", ctrl=True)
        a.wait(lambda st: st["mic"], 3, "Ctrl+M ligar")
        a.key("d", ctrl=True)
        a.wait(lambda st: st["deaf"] and not st["mic"], 3, "Ctrl+D surdo (desliga o microfone)")
        a.click("##mic")
        a.wait(lambda st: not st["deaf"] and st["mic"], 3, "ligar o microfone tira o surdo")


@test
def convite_colado():
    """Convite copiado (em outro app) já aparece preenchido em 'Entrar numa sala' ao abrir o telinha."""
    with Session("colar") as s:
        p = port()
        srv = s.app("srv", 91, ["--nome", "Dono", "--criar", str(p), "--senha", "abc123"])
        srv.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        a = s.app("a", 92, ["--nome", "Ana", "--entrar", f"127.0.0.1:{p}", "--senha", "abc123"])
        a.wait(lambda st: st["status"] == "connected", 10, "a Ana entrar")
        a.click("##invite")
        a.wait(lambda st: st["clipboard"] == f"telinha://127.0.0.1:{p}#abc123", 3, "o convite copiado")
        # outro telinha abre na mesma tela (mesma área de transferência)
        b = s.app("b", 92, [])
        b.wait(lambda st: st["cfg"]["join_addr"] == f"127.0.0.1:{p}" and st["cfg"]["join_pass"] == "abc123", 5, "o convite aparecer preenchido")


@test
def zoom_e_ponteiro():
    """Zoom na transmissão (rodinha, seguir o cursor, voltar) e ponteiro 'olha aqui' chegando em quem transmite."""
    with Session("zoom") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir", "--software"])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = b.member_id("Ana")
        bid = b.state()["my_id"]
        b.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 15, "ver a tela da Ana")
        tile = b.tile(aid)
        win = b.items()[0]
        cx, cy = win[0] + (tile[0] + tile[2]) / 2, win[1] + (tile[1] + tile[3]) / 2
        b.scroll(cx, cy, 3)
        st = b.wait(lambda st: next(t for t in st["tiles"] if t["stream"] == aid)["zoom"] > 1.8, 3, "aproximar com a rodinha")
        b.click("##follow", within=tile, hover_first=(cx - win[0], cy - win[1]))
        b.wait(lambda st: next(t for t in st["tiles"] if t["stream"] == aid)["follow"], 3, "seguir o cursor")
        b.click("##zoomreset", within=tile, hover_first=(cx - win[0], cy - win[1]))
        b.wait(lambda st: next(t for t in st["tiles"] if t["stream"] == aid)["zoom"] == 1, 3, "voltar sem zoom")
        # ponteiro: liga, aponta num canto e clica
        b.click("##pointer", within=tile, hover_first=(cx - win[0], cy - win[1]))
        b.wait(lambda st: st["pointer_tile"] == aid, 3, "ligar o ponteiro")
        px, py = win[0] + tile[0] + (tile[2] - tile[0]) * 0.25, win[1] + tile[1] + (tile[3] - tile[1]) * 0.75
        b.move(px, py)
        b.move(px + 3, py + 2)
        b.click_at(px + 3, py + 2)
        st = a.wait(lambda st: any(q["from"] == bid and q["stream"] == aid and q["flags"] & 1 and q["ping"] for q in st["pointers"]), 5, "a Ana ver o ponteiro e o clique do Bruno")
        q = next(q for q in st["pointers"] if q["from"] == bid)
        expect(abs(q["x"] / 65534 - 0.25) < 0.08 and abs(q["y"] / 65534 - 0.75) < 0.08, f"ponteiro no lugar errado: {q}")
        # clicar apontando não destaca o quadro
        expect(b.state()["focused"] is None, "o clique do ponteiro destacou o quadro")
        b.click("##pointer", within=tile, hover_first=(cx - win[0], cy - win[1]))
        b.wait(lambda st: st["pointer_tile"] == -1, 3, "desligar o ponteiro")
        a.wait(lambda st: all(not (q["from"] == bid and q["flags"] & 1) for q in st["pointers"]), 5, "o ponteiro sumir pra Ana")


@test
def notificacoes():
    """Notificação do sistema (D-Bus privado) com o telinha em segundo plano: chat, ao vivo; desligável."""
    with Session("notif", audio=True) as s:
        mon_log = os.path.join(s.base, "dbus.log")
        s.spawn("dbusmon", ["dbus-monitor", "--address", f"unix:path={s.runtime}/bus", "interface='org.freedesktop.Notifications'"], s.audio_env({}))
        time.sleep(0.5)
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p)])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}"])
        b.wait(lambda st: st["status"] == "connected", 10, "o Bruno entrar")
        expect(not b.state()["away"], "a janela começa em foco")
        # com foco: mensagem não notifica
        a.click("##chatin")
        a.type("com foco\n")
        b.wait(lambda st: any(c["text"] == "com foco" for c in st["chat"]), 5, "a mensagem chegar")
        time.sleep(0.4)
        expect(b.state()["notifications_sent"] == 0, "notificou com a janela em foco")
        b.unfocus()
        b.wait(lambda st: st["away"], 3, "o Bruno ir pra outra janela")
        time.sleep(2.1)
        a.click("##chatin")
        a.type("oi bruno\n")
        b.wait(lambda st: st["notifications_sent"] >= 1, 5, "notificar a mensagem")
        time.sleep(0.5)
        logtxt = open(os.path.join(s.base, "dbusmon.log"), errors="replace").read()
        expect('member=Notify' in logtxt and "oi bruno" in logtxt and "Ana" in logtxt, "a notificação não passou no D-Bus:\n" + logtxt[-800:])
        # Ana começa a transmitir: notifica
        n0 = b.state()["notifications_sent"]
        time.sleep(2.1)
        a.click(contains="Compartilhar tela##share")
        a.click(contains="Ao vivo", window="Compartilhar")
        b.wait(lambda st: st["notifications_sent"] > n0, 10, "notificar o ao vivo")
        # desligada nas configurações: nada
        b.click("##gear")
        b.click(contains="Notificações com o telinha")
        b.wait(lambda st: not st["cfg"]["notifications"], 3, "desligar as notificações")
        b.click("Fechar", window="Configura")
        n1 = b.state()["notifications_sent"]
        time.sleep(2.1)
        a.click("##chatin")
        a.type("ninguem avisa\n")
        b.wait(lambda st: any(c["text"] == "ninguem avisa" for c in st["chat"]), 5, "a mensagem chegar")
        time.sleep(0.5)
        expect(b.state()["notifications_sent"] == n1, "notificou com as notificações desligadas")


def probe(path):
    """(quadros de vídeo, duração em s, tem som?) pelo ffprobe; erro de decodificação vira QAError."""
    import subprocess
    out = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries", "stream=codec_name,nb_read_frames:format=duration",
                          "-of", "json", path], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise QAError(f"ffprobe falhou em {path}: {out.stderr[-400:]}")
    import json as _json
    j = _json.loads(out.stdout)
    frames = sum(int(st.get("nb_read_frames", 0)) for st in j["streams"] if st["codec_name"] == "h264")
    audio = any(st["codec_name"] == "opus" for st in j["streams"])
    dec = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-fps_mode", "passthrough", "-f", "null", "-"], capture_output=True, text=True, timeout=60)
    # o muxer nulo do ffmpeg põe vídeo de taxa variável num relógio grosso e
    # reclama de quadros próximos; isso não é erro do arquivo nem de decodificação
    errs = [ln for ln in dec.stderr.splitlines() if ln.strip() and "non monotonically increasing dts to muxer" not in ln and "Last message repeated" not in ln]
    if errs:
        raise QAError(f"ffmpeg reclamou de {path}: {chr(10).join(errs)[-400:]}")
    return frames, float(j["format"].get("duration", 0)), audio


@test
def clipes_e_gravacao():
    """Clipe dos últimos 30 s e gravação (de quem assiste e da própria transmissão), conferidos no ffprobe/ffmpeg."""
    with Session("clipes", audio=True) as s:
        s.play_tone()
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir", "--software"])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = b.member_id("Ana")
        b.wait(lambda st: any(v["stream"] == aid and v["clip_secs"] >= 3 for v in st["views"]), 20, "guardar uns segundos")
        tile = b.tile(aid)
        mid = center(tile)
        b.click("##clip", within=tile, hover_first=mid)
        st = b.wait(lambda st: st["last_saved"] and st["clip_jobs"] == 0 and os.path.exists(st["last_saved"]), 10, "salvar o clipe")
        frames, dur, has_audio = probe(st["last_saved"])
        log(f"clipe do Bruno: {frames} quadros, {dur:.1f} s, som={has_audio} ({os.path.basename(st['last_saved'])})")
        expect(frames >= 10 and dur >= 2.5 and has_audio, "clipe curto demais ou sem som")
        # gravação
        b.click("##rec", within=tile, hover_first=mid)
        b.wait(lambda st: any(v["stream"] == aid and v["recording"] for v in st["views"]), 3, "começar a gravar")
        time.sleep(4)
        b.click("##rec", within=tile, hover_first=mid)
        st = b.wait(lambda st: not any(v["recording"] for v in st["views"]), 3, "parar de gravar")
        rec = st["last_saved"]
        expect("_gravacao" in rec and os.path.exists(rec), f"gravação não apareceu: {rec}")
        frames, dur, has_audio = probe(rec)
        log(f"gravação do Bruno: {frames} quadros, {dur:.1f} s, som={has_audio}")
        # começa no clique (IDR pedido na hora): ~4 s, nada de antes
        expect(frames >= 10 and 3.0 <= dur <= 5.5 and has_audio, "gravação com duração errada ou sem som")
        # clipe da própria transmissão (quem transmite)
        atile = a.tile(0)
        a.click("##clip", within=atile, hover_first=center(atile))
        st = a.wait(lambda st: st["last_saved"] and st["clip_jobs"] == 0 and os.path.exists(st["last_saved"]), 10, "a Ana salvar o próprio clipe")
        frames, dur, has_audio = probe(st["last_saved"])
        log(f"clipe da Ana: {frames} quadros, {dur:.1f} s, som={has_audio}")
        expect(frames >= 10, "clipe da própria transmissão vazio")


@test
def janela_flutuante():
    """Janela flutuante: abre pelo quadro, mostra o vídeo, fecha pelo sistema, pelo botão dela e sozinha quando a transmissão some."""
    S = os.environ.get("QA_SHOTS")
    with Session("pip") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir", "--software"])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}", "--assistir"], size=(1280, 760))
        aid = b.member_id("Ana")
        b.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 15, "ver a tela da Ana")
        tile = b.tile(aid)
        b.click("##pip", within=tile, hover_first=center(tile))
        st = b.wait(lambda st: any(q["stream"] == aid for q in st["pips"]), 5, "abrir a janela flutuante")
        expect(any(n == "telinha · Ana" for n, _ in b.x_windows()), f"janela não apareceu: {[n for n, _ in b.x_windows()]}")
        if S:
            time.sleep(1)
            b.screenshot(os.path.join(S, "pip.png"))
        # fechar pelo sistema (X da barra de título)
        b.close_x_window("telinha · Ana")
        b.wait(lambda st: not st["pips"], 5, "fechar pelo sistema")
        # de novo, e fechar pelo botão dela
        b.click("##pip", within=b.tile(aid), hover_first=center(b.tile(aid)))
        q = b.wait(lambda st: st["pips"], 5, "abrir de novo")["pips"][0]
        b.move(q["x"] + q["w"] / 2, q["y"] + q["h"] / 2)
        time.sleep(0.3)
        b.click_at(q["x"] + q["w"] - 20, q["y"] + 20)
        b.wait(lambda st: not st["pips"], 5, "fechar pelo botão da janelinha")
        # aberta e a Ana para de transmitir: fecha sozinha
        b.click("##pip", within=b.tile(aid), hover_first=center(b.tile(aid)))
        b.wait(lambda st: st["pips"], 5, "abrir de novo")
        a.click(contains="Ao vivo (configurar)##share")
        a.click("Parar")
        b.wait(lambda st: not st["pips"], 10, "fechar sozinha quando a transmissão acaba")


@test
def convite_varios_caminhos():
    """Convite com vários caminhos (rede local, porta no roteador, IPv6, link público): quem entra conecta pelo que responder."""
    with Session("caminhos") as s:
        udp, http, ctl = port(), port(), port()
        s.spawn("igd", [sys.executable, os.path.join(os.path.dirname(__file__), "mockigd.py"), str(udp), str(http), os.path.join(s.base, "igd.log")], dict(os.environ))
        s.spawn("mockbore", [sys.executable, os.path.join(os.path.dirname(__file__), "mockbore.py"), str(ctl)], dict(os.environ))
        time.sleep(0.5)
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--senha", "cam1"], extra_env={"TELINHA_UPNP_SSDP": f"127.0.0.1:{udp}"},
                  config={"tunnel_host": f"127.0.0.1:{ctl}"})
        a.wait(lambda st: st["status"] == "connected", 10, "entrar")
        a.click(contains="Abrir porta no roteador")
        a.wait(lambda st: st["upnp"] and st["upnp"]["state"] == "ready", 10, "a porta abrir")
        a.click(contains="Copiar convite##upnp")
        st = a.wait(lambda st: st["clipboard"].startswith("telinha://"), 3, "copiar o convite")
        inv = st["clipboard"]
        log(f"convite: {inv}")
        paths = inv[len("telinha://"):].split("#")[0].split(",")
        expect(f"203.0.113.7:{p}" in paths, "o convite não tem a porta do roteador")
        expect(inv.endswith("#cam1"), "o convite não tem a senha")
        expect(len(paths) >= 2, "o convite devia ter mais de um caminho (rede local + roteador)")
        a.toasted("caminhos")
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", inv])
        st = b.wait(lambda st: st["status"] == "connected", 15, "o Bruno entrar pelo convite")
        log(f"Bruno entrou pela rota {st['route']}")


@test
def windows_exe():
    """O telinha.exe (wine isolado): entra, assiste, lista janelas, compartilha só uma janela e a câmera avisa que não tem."""
    import subprocess
    from telinha_qa import WINEPREFIX
    with Session("wine") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Linux", "--criar", str(p), "--transmitir", "--software"])
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        s.display(96)
        # outra janela no "Windows" pra compartilhar (o bloco de notas do wine)
        s.spawn("notepad", ["wine", "notepad"], {k: v for k, v in os.environ.items() if k != "WAYLAND_DISPLAY"} | {"DISPLAY": ":96", "WINEPREFIX": WINEPREFIX, "WINEDEBUG": "-all"})
        w = s.wine_app("w", 96, ["--nome", "Windows", "--entrar", f"127.0.0.1:{p}", "--assistir", "--software"])
        # o bloco de notas vai pro lado (senão fica por cima do telinha e pega os cliques)
        expect(w.move_x_window("Untitled - Notepad", 1290, 0, 300, 300), "o bloco de notas não abriu")
        lid = w.member_id("Linux")
        w.wait(lambda st: any(v["stream"] == lid and v["shown"] for v in st["views"]), 40, "o .exe ver a tela do Linux")
        # compartilhar: a lista tem monitor e janelas (o bloco de notas, não o próprio telinha)
        w.click(contains="Compartilhar tela##share")
        st = w.wait(lambda st: st["share_modal"] and any(x["name"].startswith("Janela:") for x in st["sources"]), 20, "a lista de janelas")
        names = [x["name"] for x in st["sources"]]
        log(f"fontes no .exe: {names}")
        expect(not any("telinha" in n.lower() for n in names if n.startswith("Janela:")), "a lista mostrou a janela do próprio telinha")
        w.click("##src")
        w.click(contains="Janela:", window="##Combo")
        w.wait(lambda st: st["sources"][st["source_idx"]]["name"].startswith("Janela:"), 5, "escolher a janela")
        w.click(contains="Ao vivo", window="Compartilhar")
        st = w.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live", 30, "o .exe transmitir a janela")
        st = w.wait(lambda st: st["sharer"]["backend"] != "", 10, "o método de captura")
        log(f"transmitindo a janela: {st['sharer']}")
        wid = a.member_id("Windows")
        a.click_rect(a.live_row(wid))
        sv = a.wait(lambda st: any(v["stream"] == wid and v["shown"] for v in st["views"]), 30, "o Linux ver a janela")
        v = next(v for v in sv["views"] if v["stream"] == wid)
        log(f"o Linux vê a janela em {v['w']}x{v['h']}")
        expect(v["w"] < 1280 or v["h"] < 760, "isso parece a tela inteira, não a janela")
        # câmera: no wine não tem nenhuma; avisa e não trava
        w.click("##camera")
        w.wait(lambda st: st["camera"] is None and any("câmera" in t.lower() for t in st["toasts"]), 20, "avisar que não tem câmera")


@test
def windows_encoder():
    """O .exe (wine) transmitindo com 'usar a placa de vídeo': sem NVIDIA, tenta o Media Foundation e, se não der, openh264 — sempre transmite."""
    with Session("wineenc") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Linux", "--criar", str(p), "--assistir"])
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        mf_sw = os.environ.get("QA_MF_SOFTWARE")
        w = s.wine_app("w", 96, ["--nome", "Windows", "--entrar", f"127.0.0.1:{p}", "--transmitir"],
                       extra_env={"TELINHA_DEBUG": "1"} | ({"TELINHA_MF_SOFTWARE": "1"} if mf_sw else {}))
        st = w.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live" and st["sharer"]["encoder"], 60, "o .exe transmitir")
        log(f"encoder no .exe: {st['sharer']['encoder']} (captura {st['sharer']['backend']})")
        wid = a.member_id("Windows")
        sv = a.wait(lambda st: any(v["stream"] == wid and v["shown"] for v in st["views"]), 30, "o Linux ver a tela do .exe")
        log(f"o Linux vê {next(v for v in sv['views'] if v['stream'] == wid)}")


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
