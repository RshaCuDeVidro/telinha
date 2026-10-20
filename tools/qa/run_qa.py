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
        dono.click("##cfg-camera")
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
        # convite: quem hospeda copia todos os caminhos que tem (rede local, IPv6 se tiver);
        # sem nenhum que chegue de fora, é avisado do link público
        a.click("##invite")
        st = a.wait(lambda st: st["clipboard"].startswith("telinha://") and st["clipboard"].endswith("#pw1") and st["toasts"], 3, "o convite de quem hospeda")
        expect(any("link público" in t or "caminhos" in t for t in st["toasts"]), f"aviso inesperado: {st['toasts']}")
        expect(f":{p}" in st["clipboard"], f"convite sem a porta da sala: {st['clipboard']}")
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
        for page, label, key in [("geral", "Mostrar estatísticas sempre", "stats_always"), ("voz", "Sons de aviso", "sounds"),
                                 ("voz", "Entrar na sala com o microfone ligado", "mic_on_join"), ("voz", "Supressão de ruído", "noise_suppression"),
                                 ("voz", "Cancelamento de eco", "echo_cancellation")]:
            b.click(f"##cfg-{page}")
            b.click(contains=label)
            b.wait(lambda st, k=key, v=before[key]: st["cfg"][k] != v, 3, f"marcar {label}")
        b.drag("##sens", 0.5, 0.9)
        b.wait(lambda st: st["cfg"]["voice_sensitivity"] > 70, 3, "a sensibilidade subir")
        b.click("##cfg-geral")
        b.fill("##sname", "Bruno2")
        settings_click(b, "Fechar")
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
        a.click("##audio")
        a.click("Sem som", window="##Combo")
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
        # o convite leva o IP de fora entre os caminhos (rede local primeiro: na mesma casa é o mais rápido)
        a.wait(lambda st: st["clipboard"].endswith("#pw2") and f"203.0.113.7:{p}" in st["clipboard"][len("telinha://"):-len("#pw2")].split(","), 3, "o convite com o IP de fora")
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
        a.wait(lambda st: st["clipboard"].endswith("#pw2") and "0.tcp.sa.ngrok.io:12345" in st["clipboard"][len("telinha://"):-len("#pw2")].split(","), 3, "o convite do túnel próprio")


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
def apertar_pra_falar():
    """Apertar pra falar: escolhe a tecla nas configurações; segurando, a voz sai (mesmo com o microfone em silêncio); soltando, para."""
    with Session("ptt", audio=True) as s:
        s.fake_mic()
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p)])
        b = s.app("b", 92, ["--nome", "Bruno", "--entrar", f"127.0.0.1:{p}"])
        a.wait(lambda st: st["status"] == "connected", 10, "entrar")
        b.wait(lambda st: st["status"] == "connected", 10, "o Bruno entrar")
        a.click("##mic")
        a.wait(lambda st: st["mic"], 5, "ligar o microfone")
        time.sleep(1)
        expect(not a.state()["speaking"], "o portão abriu sozinho com o microfone em silêncio")
        a.click("##gear")
        a.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        a.click("##cfg-voz")
        a.click("Apertar pra falar")
        a.wait(lambda st: st["cfg"]["voice_ptt"], 3, "ligar o apertar pra falar")
        a.click("##pttkey")
        time.sleep(0.3)
        a.key("g")
        a.wait(lambda st: st["cfg"]["ptt_key"] == 71, 3, "escolher a tecla G")
        settings_click(a, "Fechar")
        a.wait(lambda st: not st["settings_modal"], 3, "fechar as configurações")
        time.sleep(0.5)
        expect(not a.state()["speaking"], "falando sem apertar a tecla")
        a.key_down("g")
        try:
            a.wait(lambda st: st["speaking"], 3, "a voz sair com a tecla apertada")
            time.sleep(1)
            expect(a.state()["speaking"], "parou de falar com a tecla ainda apertada")
        finally:
            a.key_up("g")
        a.wait(lambda st: not st["speaking"], 3, "parar de falar ao soltar")
        # sem o telinha em foco (como com o jogo na frente): o teclado não vai
        # pra janela nenhuma; só a leitura global (XQueryKeymap) vê a tecla
        from Xlib import X as XX
        a.d.set_input_focus(XX.NONE, XX.RevertToNone, XX.CurrentTime)
        a.d.sync()
        time.sleep(0.5)
        a.key_down("g")
        try:
            a.wait(lambda st: st["speaking"], 3, "a voz sair com outro programa em foco")
        finally:
            a.key_up("g")
        a.wait(lambda st: not st["speaking"], 3, "parar de falar ao soltar (sem foco)")
        ini = open(os.path.join(a.cfg, "telinha", "config.ini")).read()
        expect("voice_ptt=1" in ini and "ptt_key=71" in ini, "não salvou o apertar pra falar")


def drag_abs(app, x0, y0, x1, y1, steps=10):
    """Arrasta de (x0, y0) até (x1, y1), coordenadas da janela."""
    win, _ = app.items()
    app.move(win[0] + x0, win[1] + y0)
    app.press()
    for i in range(1, steps + 1):
        app.move(win[0] + x0 + (x1 - x0) * i / steps, win[1] + y0 + (y1 - y0) * i / steps)
    app.release()


@test
def recorte_e_desenho():
    """Transmitir só um pedaço da tela (arrastando na própria prévia) e desenhar por cima (quem assiste desenha, quem transmite vê)."""
    with Session("recorte") as s:
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir", "--software"])
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = bia.member_id("Ana")
        bia.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 20, "a Bia ver a Ana")
        st = ana.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live" and st["sharer"]["w"] > 0, 10, "a Ana transmitindo")
        full_w, full_h = st["sharer"]["w"], st["sharer"]["h"]
        # recorte: a metade do meio
        t = ana.tile(0)  # a própria prévia
        ana.click("##crop", within=t, hover_first=center(t))
        time.sleep(0.8)
        t = ana.tile(0)
        w, h = t[2] - t[0], t[3] - t[1]
        drag_abs(ana, t[0] + w * 0.25, t[1] + h * 0.25, t[0] + w * 0.75, t[1] + h * 0.75)
        st = ana.wait(lambda st: st["sharer"]["w"] < full_w * 0.6 and st["crop"][0] > 0.2, 10, "a transmissão virar só o pedaço")
        log(f"recortado: {st['sharer']['w']}x{st['sharer']['h']} (era {full_w}x{full_h}), recorte {st['crop']}")
        bia.wait(lambda st: any(v["stream"] == aid and v["w"] < full_w * 0.6 for v in st["views"]), 10, "a Bia ver só o pedaço")
        # botão direito no modo recorte: tela inteira de novo
        t = ana.tile(0)
        ana.click("##crop", within=t, hover_first=center(t))
        time.sleep(0.5)
        t = ana.tile(0)
        ana.click_rect(t, button=3)
        ana.wait(lambda st: st["sharer"]["w"] == full_w and st["crop"] == [0, 0, 1, 1], 10, "voltar pra tela inteira")
        # desenho: a Bia risca, a Ana vê o traço da Bia na transmissão dela
        bid = ana.member_id("Bia")
        t = bia.tile(aid)
        bia.click("##draw", within=t, hover_first=center(t))
        t = bia.tile(aid)
        w, h = t[2] - t[0], t[3] - t[1]
        drag_abs(bia, t[0] + w * 0.3, t[1] + h * 0.5, t[0] + w * 0.7, t[1] + h * 0.6, steps=16)
        st = ana.wait(lambda st: any(x["from"] == bid and x["stream"] == aid and x["n"] >= 3 for x in st["strokes"]), 5, "a Ana ver o traço da Bia")
        log(f"traços na Ana: {st['strokes']}")
        bia.wait(lambda st: any(x["stream"] == aid for x in st["strokes"]), 2, "a Bia ver o próprio traço")
        # some sozinho
        ana.wait(lambda st: not st["strokes"], 10, "o traço sumir")


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
        settings_click(b, "Fechar")
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


def capture_links(s):
    """Quais nós estão ligados na entrada do telinha (pw-link no áudio privado)."""
    import subprocess
    out = subprocess.run(["pw-link", "-l", "-I"], env=s.audio_env({}), capture_output=True, text=True, timeout=10).stdout
    srcs, cur = set(), None
    for line in out.splitlines():
        if "|<-" not in line and "|->" not in line:
            cur = line.split()[-1] if line.strip() else None
        elif "|<-" in line and cur and cur.startswith("telinha-captura:"):
            srcs.add(line.split("|<-")[1].strip().split()[-1].split(":")[0])
    return srcs


@test
def som_de_um_programa():
    """Som de um programa só: dois programas tocando, escolhe um na janela de compartilhar (e troca com a transmissão rolando)."""
    with Session("somapp", audio=True) as s:
        s.play_tone("tom-a", freq=440, app="Tocador A")
        s.play_tone("tom-b", freq=880, app="Tocador B")
        time.sleep(1)
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p)])
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        ana.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        ana.click(contains="Compartilhar tela##share")
        ana.wait(lambda st: st["share_modal"], 5, "a janela de compartilhar")
        ana.click("##audio")
        ana.click(contains="Só o som do Tocador A", window="##Combo")
        ana.wait(lambda st: st["cfg"]["audio_app"] == "Tocador A", 3, "escolher o Tocador A")
        ana.click(contains="Ao vivo", window="Compartilhar")
        st = ana.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live" and st["sharer"]["audio"], 20, "transmitir com som")
        aid = bia.member_id("Ana")
        bia.wait(lambda st: any(v["stream"] == aid and v["audio"] for v in st["views"]), 20, "a Bia ouvir o som da Ana")
        t0 = time.time()
        while time.time() - t0 < 10 and capture_links(s) != {"tom-a"}:
            time.sleep(0.3)
        links = capture_links(s)
        log(f"ligados na captura: {links}")
        expect(links == {"tom-a"}, f"só o Tocador A deveria estar ligado, está: {links}")
        # troca pra tudo com a transmissão rolando
        ana.click(contains="Ao vivo (configurar)##share")
        ana.wait(lambda st: st["share_modal"], 5, "abrir as configurações da transmissão")
        ana.click("##audio")
        ana.click(contains="Todo o som do computador", window="##Combo")
        ana.click(contains="Aplicar", window="Compartilhar")
        t0 = time.time()
        while time.time() - t0 < 10 and capture_links(s) != {"tom-a", "tom-b"}:
            time.sleep(0.3)
        links = capture_links(s)
        log(f"depois de trocar pra tudo: {links}")
        expect(links == {"tom-a", "tom-b"}, f"os dois deveriam estar ligados, está: {links}")
        expect(ana.state()["sharer"]["audio"], "o som parou depois de trocar")


@test
def excluir_programa_do_som():
    """Todo o som menos um programa (ex.: o Discord): exclui com a transmissão rolando, fica salvo, e tirar da lista volta a pegar."""
    with Session("somexcl", audio=True) as s:
        s.play_tone("tom-a", freq=440, app="Tocador A")
        s.play_tone("tom-b", freq=880, app="Discord")
        time.sleep(1)
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p)])
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        ana.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        ana.click(contains="Compartilhar tela##share")
        ana.wait(lambda st: st["share_modal"], 5, "a janela de compartilhar")
        ana.click(contains="Ao vivo", window="Compartilhar")
        ana.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live" and st["sharer"]["audio"], 20, "transmitir com som")
        aid = bia.member_id("Ana")
        bia.wait(lambda st: any(v["stream"] == aid and v["audio"] for v in st["views"]), 20, "a Bia ouvir o som da Ana")
        t0 = time.time()
        while time.time() - t0 < 10 and capture_links(s) != {"tom-a", "tom-b"}:
            time.sleep(0.3)
        expect(capture_links(s) == {"tom-a", "tom-b"}, f"os dois deveriam estar ligados: {capture_links(s)}")
        # exclui o "Discord" com a transmissão rolando
        ana.click(contains="Ao vivo (configurar)##share")
        ana.wait(lambda st: st["share_modal"], 5, "abrir as configurações da transmissão")
        ana.click("##audioexcl")
        ana.click(contains="Discord###excl")
        ana.wait(lambda st: st["cfg"]["audio_exclude"] == "Discord", 3, "excluir o Discord")
        t0 = time.time()
        while time.time() - t0 < 10 and capture_links(s) != {"tom-a"}:
            time.sleep(0.3)
        links = capture_links(s)
        log(f"com o Discord excluído: {links}")
        expect(links == {"tom-a"}, f"só o Tocador A deveria estar ligado: {links}")
        expect(ana.state()["sharer"]["audio"], "o som parou depois de excluir")
        ini = open(os.path.join(ana.cfg, "telinha", "config.ini")).read()
        expect("audio_exclude=Discord" in ini, "a exclusão não foi salva")
        # tira da lista: volta a pegar os dois
        ana.click(contains="Discord###excl")
        ana.wait(lambda st: st["cfg"]["audio_exclude"] == "", 3, "tirar o Discord da lista")
        t0 = time.time()
        while time.time() - t0 < 10 and capture_links(s) != {"tom-a", "tom-b"}:
            time.sleep(0.3)
        expect(capture_links(s) == {"tom-a", "tom-b"}, f"os dois deveriam voltar: {capture_links(s)}")


def write_png(path, w, h):
    """PNG de teste (degradê com listras), sem depender de biblioteca de imagem."""
    import struct
    import zlib
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes((x * 255 // w, y * 255 // h, 230 if (x // 8) % 2 else 40))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


@test
def chat_imagem_reacao_mencao():
    """Chat: @menção com Tab, imagem colada (Ctrl+V), abrir a imagem, reações e tudo isso no histórico de quem entra depois."""
    with Session("chatimg") as s:
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p)])
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}"])
        bia.wait(lambda st: st["status"] == "connected", 10, "a Bia entrar")
        ana.wait(lambda st: len(st["members"]) == 2, 10, "a Ana ver a Bia")
        # @menção: "@an" sugere Ana; Tab completa
        bia.click("##chatin")
        bia.type("@an")
        bia.wait(lambda st: st["mention_sugg"] == ["Ana"], 3, "sugerir a Ana")
        bia.key("Tab")
        bia.wait(lambda st: st["chat_input"] == "@Ana ", 3, "completar com @Ana")
        bia.type("olha isso\n")
        ana.wait(lambda st: any(l["text"] == "@Ana olha isso" for l in st["chat"]), 5, "a Ana receber a menção")
        # imagem colada: PNG na área de transferência da tela da Ana, Ctrl+V no chat
        png = os.path.join(s.base, "teste.png")
        write_png(png, 300, 200)
        s.spawn("xclip", ["xclip", "-quiet", "-selection", "clipboard", "-t", "image/png", "-i", png], dict(os.environ, DISPLAY=f":{ana.num}"))
        time.sleep(0.5)
        ana.click("##chatin")
        ana.key("v", ctrl=True)
        st = bia.wait(lambda st: any(l["img"] and l["img_ready"] for l in st["chat"]), 10, "a imagem aparecer pra Bia")
        img = next(l for l in st["chat"] if l["img"])
        log(f"imagem: {img['img_w']}x{img['img_h']}, {img['img_bytes']} bytes")
        expect((img["img_w"], img["img_h"]) == (300, 200), f"tamanho errado: {img['img_w']}x{img['img_h']}")
        # abre em tela cheia e fecha
        bia.click(f"##img{img['id']}")
        bia.wait(lambda st: st["img_view"] == img["id"], 3, "abrir a imagem")
        bia.key("Escape")
        bia.wait(lambda st: st["img_view"] is None, 3, "fechar a imagem")
        # reação pela barra que aparece com o mouse em cima
        it = bia.find(f"##img{img['id']}")
        bia.move(*bia._abs(it, 0.5, 0.5))
        bia.wait(lambda st: st["react_hover"] == img["id"], 3, "a barra de reações aparecer")
        it2 = bia.click(f"##r{img['id']}_1")
        if os.environ.get("QA_DEBUG"):
            log(f"clique em {it2}")
            time.sleep(0.5)
            bia.screenshot(os.path.join(s.base, "reacao.png"))
            log(f"bia: {[l['reacts'] for l in bia.state()['chat'] if l['img']]} hover={bia.state()['react_hover']}")
        ana.wait(lambda st: next(l for l in st["chat"] if l["id"] == img["id"])["reacts"][1] == 1, 5, "a Ana ver o coração")
        # a Ana clica no mesmo coração (embaixo da mensagem): 2
        ana.click(f"##chip{img['id']}_1")
        bia.wait(lambda st: next(l for l in st["chat"] if l["id"] == img["id"])["reacts"][1] == 2, 5, "dois corações")
        # quem entra depois vê a imagem e as reações
        cai = s.app("cai", 93, ["--nome", "Caio", "--entrar", f"127.0.0.1:{p}"])
        st = cai.wait(lambda st: any(l["img"] and l["img_ready"] for l in st["chat"]), 10, "o Caio ver a imagem do histórico")
        h = next(l for l in st["chat"] if l["img"])
        expect(h["history"] and h["reacts"][1] == 2, f"histórico sem as reações: {h}")


@test
def hevc():
    """HEVC na placa: transmite em HEVC quando todo mundo decodifica; quem entra só com H.264 faz voltar pro H.264 (e quem já assistia continua vendo)."""
    with Session("hevc") as s:
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir"])
        st = ana.wait(lambda st: st["sharer"] and st["sharer"]["state"] == "live" and st["sharer"]["encoder"], 20, "a Ana transmitir")
        if "NVENC" not in st["sharer"]["encoder"]:
            log(f"sem NVENC aqui ({st['sharer']['encoder']}): pulando")
            return
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = bia.member_id("Ana")
        st = bia.wait(lambda st: any(v["stream"] == aid and v["shown"] and v["codec"] == "HEVC" for v in st["views"]), 20, "a Bia ver em HEVC")
        log(f"Bia: {next(v for v in st['views'] if v['stream'] == aid)}")
        ana.wait(lambda st: st["sharer"]["encoder"] == "NVENC (HEVC)", 5, "a Ana codificar em HEVC")
        # quem não decodifica HEVC entra: tudo volta pro H.264
        caio = s.app("caio", 93, ["--nome", "Caio", "--entrar", f"127.0.0.1:{p}", "--assistir"], extra_env={"TELINHA_SEM_HEVC": "1"})
        caio.wait(lambda st: any(v["stream"] == aid and v["shown"] and v["codec"] == "H.264" for v in st["views"]), 20, "o Caio ver em H.264")
        ana.wait(lambda st: st["sharer"]["encoder"] == "NVENC", 5, "a Ana voltar pro H.264")
        bia.wait(lambda st: any(v["stream"] == aid and v["codec"] == "H.264" for v in st["views"]), 10, "a Bia trocar pro H.264")
        f0 = next(v for v in bia.state()["views"] if v["stream"] == aid)
        time.sleep(1.5)
        f1 = next(v for v in bia.state()["views"] if v["stream"] == aid)
        expect(f1["shown"] and f1["fps"] > 0, f"a Bia parou de ver depois da troca: {f0} → {f1}")
        # o Caio sai: HEVC de novo
        caio.stop()
        ana.wait(lambda st: st["sharer"]["encoder"] == "NVENC (HEVC)", 15, "a Ana voltar pro HEVC")
        bia.wait(lambda st: any(v["stream"] == aid and v["codec"] == "HEVC" and v["shown"] for v in st["views"]), 10, "a Bia ver em HEVC de novo")


@test
def udp_com_perda():
    """Vídeo por UDP com 5% de perda simulada nos dois sentidos: quem assiste continua vendo (reenvio do que falta), sem travar."""
    with Session("udp", audio=True) as s:
        s.play_tone()
        perda = {"TELINHA_UDP_PERDA": "5"}
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir", "--fps", "30"], extra_env=perda)
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"], extra_env=perda)
        aid = bia.member_id("Ana")
        bia.wait(lambda st: st["udp"] and st["udp"]["active"], 10, "a Bia abrir o UDP")
        bia.wait(lambda st: any(v["stream"] == aid and v["shown"] and v["audio"] for v in st["views"]), 20, "a Bia ver e ouvir a Ana")
        # tela mexendo (a Ana abre e fecha o chat): quadros de verdade passando
        samples = []
        t0 = time.time()
        while time.time() - t0 < 12:
            ana.click("##hidechat") if ana.find("##hidechat", timeout=0.3, need=False) else ana.click("##showchat")
            time.sleep(0.4)
            v = next((v for v in bia.state()["views"] if v["stream"] == aid), None)
            if v:
                samples.append((v["fps"], v["latency"]))
        st_a, st_b = ana.state()["udp"], bia.state()["udp"]
        log(f"Bia: fps/atraso {samples[-8:]}")
        log(f"UDP Ana {st_a} · Bia {st_b}")
        expect(st_a["active"] and st_b["active"], "o UDP caiu")
        expect(st_a["resent"] + st_b["resent"] > 0 and st_a["nacks"] + st_b["nacks"] > 0, "nenhum reenvio com 5% de perda?")
        expect(min(f for f, _ in samples[-10:]) > 0, f"a imagem travou: {samples}")


@test
def udp_bloqueado():
    """UDP bloqueado (firewall): fica no TCP e funciona igual."""
    with Session("udpblq") as s:
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir"])
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"], extra_env={"TELINHA_UDP_PERDA": "100"})
        aid = bia.member_id("Ana")
        bia.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 20, "a Bia ver a Ana pelo TCP")
        time.sleep(2)
        st = bia.state()
        expect(st["udp"] is not None and not st["udp"]["active"], f"o UDP não devia ter aberto: {st['udp']}")


@test
def versao_nova():
    """Aviso de versão nova: pelo GitHub (de mentira, local) na tela inicial, e por alguém da sala que está numa versão mais nova."""
    with Session("versao") as s:
        gh = port()
        s.spawn("github", [sys.executable, os.path.join(os.path.dirname(__file__), "mockgithub.py"), str(gh), "v9.1.0"], dict(os.environ))
        time.sleep(0.5)
        a = s.app("a", 91, ["--nome", "Ana"], extra_env={"TELINHA_ATUALIZACAO_URL": f"http://127.0.0.1:{gh}/repos/teste/telinha/releases/latest"})
        st = a.wait(lambda st: st["update"] in ("newer", "current", "failed"), 10, "a checagem de versão")
        expect(st["update"] == "newer" and st["update_latest"] == "v9.1.0", f"checagem: {st['update']} {st['update_latest']}")
        a.click("Baixar##update")
        a.wait(lambda st: st["opened"] == "https://github.com/teste/telinha/releases/tag/v9.1.0", 3, "abrir a página da release")
        expect("telinha" in open(os.path.join(s.base, "github.log")).read(), "o app não se identificou (user-agent)")
        # na sala: alguém com o telinha mais novo
        p = port()
        a.click("Criar sala")
        a.wait(lambda st: st["home_tab"] == 1, 3, "a aba criar sala")
        a.fill("##port", str(p))
        a.click("Criar sala##go")
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        b = s.app("b", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}"], extra_env={"TELINHA_VERSAO_TESTE": "9.2.0"})
        b.wait(lambda st: st["status"] == "connected", 10, "a Bia entrar")
        a.toasted("telinha 9.2.0")
        # quem está na versão mais nova não é avisado de nada
        time.sleep(1)
        expect(not any("versão nova" in t for t in b.state()["toasts"]), f"aviso errado pra quem está na nova: {b.state()['toasts']}")


@test
def idioma_ingles():
    """Interface em inglês (TELINHA_IDIOMA=en): tela inicial, recusa do servidor traduzida, sala, compartilhar, configurações; trocar o idioma nas configurações muda na hora."""
    with Session("idioma") as s:
        p = port()
        dono = s.app("dono", 91, ["--nome", "Dono", "--criar", str(p)])
        dono.wait(lambda st: st["status"] == "connected", 10, "o dono entrar")
        a = s.app("a", 92, [], extra_env={"TELINHA_IDIOMA": "en"})
        st = a.wait(lambda st: st["screen"] == "home", 10, "a tela inicial")
        expect(st["lang"] == "en", f"idioma errado: {st['lang']}")
        for label in ["Join a room", "Create room", "Join##go"]:
            a.find(label)
        expect(a.find("Entrar numa sala", timeout=0.5, need=False) is None, "texto em português na tela inicial em inglês")
        a.fill("##name", "Ana")
        # aba criar: erro em inglês
        a.click("Create room")
        a.wait(lambda st: st["home_tab"] == 1, 3, "a aba criar sala")
        a.fill("##port", "abc")
        a.click("Create room##go")
        a.wait(lambda st: st["home_error"] == "Invalid port.", 3, "o erro de porta em inglês")
        # sala trancada: o motivo vem do servidor em português e aparece em inglês
        dono.click("##lockroom")
        dono.wait(lambda st: st["locked"], 5, "a sala trancar")
        a.click("Join a room")
        a.fill("##addr", f"127.0.0.1:{p}")
        a.click("Join##go")
        a.wait(lambda st: st["screen"] == "home" and st["home_error"] == "The room is locked: no one new can join right now.", 10, "a recusa em inglês")
        dono.click("##lockroom")
        dono.wait(lambda st: not st["locked"], 5, "a sala destrancar")
        a.click("Join##go")
        a.wait(lambda st: st["screen"] == "room" and st["status"] == "connected", 10, "entrar na sala")
        # sala e compartilhar tela
        a.find(contains="Share screen##share")
        a.click(contains="Share screen##share")
        a.wait(lambda st: st["share_modal"], 3, "abrir o compartilhar tela")
        for label in ["Game and video", "Original"]:
            a.find(label, window="Share screen")
        a.find(contains="Show the mouse cursor", window="Share screen")
        a.click("Cancel", window="Share screen")
        a.wait(lambda st: not st["share_modal"], 3, "fechar o compartilhar tela")
        # configurações em inglês; trocar pra português muda tudo na hora (e fica salvo)
        a.click("##gear")
        a.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        a.find("Close", window="Settings")
        a.find(contains="Always show statistics", window="Settings")
        a.click("##lang")
        a.click("Português", window="##Combo")
        a.wait(lambda st: st["lang"] == "pt" and st["cfg"]["language"] == "pt", 3, "trocar pra português")
        # (o nome guardado da janela aberta não muda; o ID "###configuracoes" é o mesmo)
        a.find("Fechar", window="###configuracoes")
        a.find(contains="Mostrar estatísticas sempre", window="###configuracoes")
        expect(a.find(contains="Always show statistics", timeout=0.5, need=False) is None, "ficou texto em inglês depois de trocar")
        ini = open(os.path.join(a.cfg, "telinha", "config.ini")).read()
        expect("language=pt" in ini, "o idioma não foi salvo no arquivo")
        # e de volta pro inglês
        a.click("##lang")
        a.click("English", window="##Combo")
        a.wait(lambda st: st["lang"] == "en" and st["cfg"]["language"] == "en", 3, "voltar pro inglês")
        settings_click(a, "Close")
        a.wait(lambda st: not st["settings_modal"], 3, "fechar as configurações")
        a.find(contains="Share screen##share")


def settings_find(a, label, tries=12):
    """Rola as configurações até achar o item (a janela é mais alta que a tela)."""
    for _ in range(tries):
        it = a.find(label, window="###configuracoes", timeout=0.4, need=False)
        if it is not None and it["vy1"] - it["vy0"] >= it["y1"] - it["y0"] - 1:
            return it
        win, _ = a.items()
        a.scroll(win[0] + a.size[0] / 2, win[1] + a.size[1] / 2, -4)
        time.sleep(0.2)
    raise QAError(f"[{a.name}] não achei {label!r} nas configurações")


def settings_top(a):
    win, _ = a.items()
    a.scroll(win[0] + a.size[0] / 2, win[1] + a.size[1] / 2, 30)
    time.sleep(0.3)


def settings_click(a, label):
    settings_find(a, label)
    a.click(label, window="###configuracoes")


def multipart_has_log(path):
    body = open(path, "rb").read()
    return b'name="file"' in body and b"telinha-debug.txt" in body and b"cpu app=" in body, body


@test
def log_depuracao():
    """Log de depuração: liga nas configurações, grava o sistema e as amostras, manda pro gofile (de mentira: devolve o link) e pro webhook (de mentira)."""
    with Session("debuglog") as s:
        gf, wh = port(), port()
        here = os.path.dirname(__file__)
        s.spawn("gofile", [sys.executable, os.path.join(here, "mockupload.py"), str(gf), "gofile", os.path.join(s.base, "gofile")], dict(os.environ))
        s.spawn("webhook", [sys.executable, os.path.join(here, "mockupload.py"), str(wh), "webhook", os.path.join(s.base, "webhook")], dict(os.environ))
        time.sleep(0.5)
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir"], extra_env={"TELINHA_GOFILE_URL": f"http://127.0.0.1:{gf}/uploadfile"})
        b = s.app("b", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = b.member_id("Ana")
        b.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 20, "a Bia ver a Ana")
        a.click("##gear")
        a.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        a.click("##cfg-depuracao")
        settings_click(a, "##debuglog")
        st = a.wait(lambda st: st["debug_on"], 3, "o log ligar")
        expect(st["cfg"].get("debug_log", True), "não salvou")
        logf = os.path.join(a.cfg, "telinha", "telinha-debug.log")
        t0 = time.time()
        txt = ""
        while time.time() - t0 < 12:
            txt = open(logf, errors="replace").read() if os.path.exists(logf) else ""
            if "cpu app=" in txt and "transmitindo" in txt:
                break
            time.sleep(0.3)
        log("log:\n" + "\n".join(txt.splitlines()[:40]))
        for part in ["OpenGL:", "config:", "cpu app=", "sala:", "transmitindo"]:
            expect(part in txt, f"faltou {part!r} no log")
        expect("senha" not in txt.lower() or "senha=" not in txt.lower(), "senha no log?")
        # gofile: devolve o link
        settings_click(a, "##dbgsend")
        st = a.wait(lambda st: st["debug_send"] in ("done", "failed"), 30, "o envio pro gofile")
        expect(st["debug_send"] == "done" and st["debug_result"] == "https://gofile.io/d/teste1", f"gofile: {st['debug_send']} {st['debug_result']}")
        ok, body = multipart_has_log(os.path.join(s.base, "gofile", "post1.bin"))
        expect(ok, f"o gofile não recebeu o log: {body[:300]!r}")
        settings_click(a, "##dbgcopy")
        a.wait(lambda st: st["clipboard"] == "https://gofile.io/d/teste1", 3, "copiar o link")
        settings_click(a, "##dbgopen")
        a.wait(lambda st: st["opened"] == "https://gofile.io/d/teste1", 3, "abrir o link")
        # webhook: link inválido não deixa mandar; o certo manda com a mensagem
        settings_click(a, "Webhook (Discord etc.)")
        a.wait(lambda st: st["cfg"]["debug_send"] == 1, 3, "escolher webhook")
        settings_find(a, "##dbghook")
        a.fill("##dbghook", "ftp://errado")
        a.key("Return")
        settings_click(a, "##dbgsend")  # desabilitado: não manda nada
        time.sleep(1)
        expect(not os.path.exists(os.path.join(s.base, "webhook", "post1.bin")), "mandou pra um link inválido")
        a.fill("##dbghook", f"http://127.0.0.1:{wh}/api/webhooks/1/abc")
        a.key("Return")
        a.wait(lambda st: st["cfg"]["debug_webhook"].startswith("http://127.0.0.1"), 3, "guardar o webhook")
        settings_click(a, "##dbgsend")
        st = a.wait(lambda st: st["debug_send"] == "done" and st["debug_result"] == "", 30, "o envio pro webhook")
        ok, body = multipart_has_log(os.path.join(s.base, "webhook", "post1.bin"))
        expect(ok and b'name="content"' in body and b"Ana" in body, f"o webhook não recebeu o log: {body[:300]!r}")
        # webhook fora do ar: avisa o erro
        a.fill("##dbghook", "http://127.0.0.1:1/x")
        a.key("Return")
        settings_click(a, "##dbgsend")
        st = a.wait(lambda st: st["debug_send"] == "failed", 30, "o erro do envio")
        log(f"erro: {st['debug_result']}")
        # desliga: para de gravar e fica salvo desligado
        a.click("##cfg-depuracao")
        settings_click(a, "##debuglog")
        a.wait(lambda st: not st["debug_on"], 3, "o log desligar")
        ini = open(os.path.join(a.cfg, "telinha", "config.ini")).read()
        expect("debug_log=0" in ini and "debug_send=1" in ini, "configuração não salva")
        size = os.path.getsize(logf)
        time.sleep(2.5)
        expect(os.path.getsize(logf) == size, "continuou gravando depois de desligar")


@test
def temas():
    """Temas: troca nas configurações na hora (claro, pwnd...), fica salvo e volta igual ao abrir de novo."""
    with Session("temas") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(p)])
        st = a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        expect(st["cfg"]["theme"] == "escuro", f"tema inicial: {st['cfg']['theme']}")
        a.click("##gear")
        a.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        a.click("##cfg-aparencia")
        for t in ["claro", "pwnd", "pwnd-claro", "nord", "dracula", "pwnd"]:
            a.click(f"##tema-{t}", window="###configuracoes")
            a.wait(lambda st: st["cfg"]["theme"] == t, 3, f"trocar pro tema {t}")
        ini = open(os.path.join(a.cfg, "telinha", "config.ini")).read()
        expect("theme=pwnd" in ini, "o tema não foi salvo")
        # personalizado: cola o CSS do pwnd.blog e copia de volta
        css = os.path.join(s.base, "tema.css")
        with open(css, "w") as f:
            f.write(":root {\n  --neon-fuchsia: #d946ef;\n  --neon-purple: #9333ea;\n  --terminal-green: #22c55e;\n  --bg-dark: #050505;\n  --bg-card: #0a050f;\n  --text-main: #e5e7eb;\n}\n")
        s.spawn("xclip", ["xclip", "-quiet", "-selection", "clipboard", "-i", css], dict(os.environ, DISPLAY=f":{a.num}"))
        time.sleep(0.8)
        a.click("##tema-personalizado", window="###configuracoes")
        a.wait(lambda st: st["cfg"]["theme"] == "personalizado", 3, "escolher o personalizado")
        settings_click(a, "##csspaste")
        a.wait(lambda st: st["cfg"]["custom_theme"].startswith("050505,0a050f,9333ea,d946ef,e5e7eb,22c55e"), 3, "montar o tema do CSS")
        settings_click(a, "##csscopy")
        a.wait(lambda st: "--bg: #050505" in st["clipboard"] and "--accent: #9333ea" in st["clipboard"], 3, "copiar o tema como CSS")
        # tamanho da interface e efeito CRT
        settings_click(a, "115%")
        a.wait(lambda st: st["cfg"]["ui_zoom"] == 115, 3, "zoom em 115%")
        settings_click(a, "##crt")
        a.wait(lambda st: st["cfg"]["crt"], 3, "ligar o CRT")
        settings_click(a, "100%")
        a.wait(lambda st: st["cfg"]["ui_zoom"] == 100, 3, "zoom de volta")
        settings_click(a, "##tema-pwnd")
        a.wait(lambda st: st["cfg"]["theme"] == "pwnd", 3, "voltar pro pwnd")
        settings_click(a, "Fechar")
        a.wait(lambda st: not st["settings_modal"], 3, "fechar as configurações")
        a.stop()
        b = s.app("b", 92, ["--nome", "Ana"], config={"theme": "pwnd"})
        st = b.wait(lambda st: st["screen"] == "home", 10, "abrir de novo")
        expect(st["cfg"]["theme"] == "pwnd", f"tema depois de abrir de novo: {st['cfg']['theme']}")
        # id desconhecido (config de versão futura): cai no padrão sem quebrar
        c2 = s.app("c", 93, ["--nome", "Ana"], config={"theme": "nao-existe"})
        c2.wait(lambda st: st["screen"] == "home", 10, "abrir com tema desconhecido")


@test
def qualidade_automatica():
    """PC lento (encoder de mentira lento): a transmissão desce a resolução sozinha até dar conta do fps e avisa; desligando nas configurações, volta pra escolhida."""
    with Session("autoq") as s:
        p = port()
        ana = s.app("ana", 91, ["--nome", "Ana", "--criar", str(p), "--transmitir", "--software"], extra_env={"TELINHA_ENCODE_LENTO": "100"})
        bia = s.app("bia", 92, ["--nome", "Bia", "--entrar", f"127.0.0.1:{p}", "--assistir"])
        aid = bia.member_id("Ana")
        bia.wait(lambda st: any(v["stream"] == aid and v["shown"] for v in st["views"]), 20, "a Bia ver a Ana")
        st = ana.wait(lambda st: st["sharer"] and st["sharer"]["auto_cap"] == 540 and st["sharer"]["h"] == 540, 40, "a resolução descer até 540p")
        ana.toasted("transmitindo em")
        log(f"transmitindo: {st['sharer']['w']}x{st['sharer']['h']} a {st['sharer']['fps']} q/s")
        bia.wait(lambda st: any(v["stream"] == aid and v["h"] == 540 for v in st["views"]), 10, "a Bia ver em 540p")
        # em 540p o encode cabe no tempo de um quadro: para de descer
        # (o fps aqui não serve de medida: a tela de teste só muda a 15 q/s)
        time.sleep(8)
        st = ana.state()["sharer"]
        expect(st["auto_cap"] == 540 and st["h"] == 540, f"não ficou em 540p: {st}")
        # desliga a qualidade automática: volta pra resolução da tela
        ana.click("##gear")
        ana.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        ana.click("##cfg-desempenho")
        ana.click("##autoq")
        ana.wait(lambda st: not st["cfg"]["auto_quality"], 3, "desligar a qualidade automática")
        settings_click(ana, "Fechar")
        ana.wait(lambda st: st["sharer"]["auto_cap"] == 0 and st["sharer"]["h"] > 540, 15, "voltar pra resolução original")


@test
def testar_pc():
    """Testar meu PC (Configurações → Desempenho): roda, mostra o resultado e 'Usar a sugestão' muda a configuração da transmissão."""
    with Session("pctest") as s:
        a = s.app("a", 91, ["--nome", "Ana", "--criar", str(port())], config={"resolution": "0", "fps": "60", "name": "Ana"})
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        a.click("##gear")
        a.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        a.click("##cfg-desempenho")
        a.click("##pctest")
        a.wait(lambda st: st["pctest"] == "done", 60, "o teste do PC terminar")
        settings_click(a, "##pcuse")
        st = a.wait(lambda st: st["cfg"]["resolution_idx"] != 0, 3, "usar a sugestão")
        log(f"sugestão aplicada: resolução {st['cfg']['resolution_idx']}, {st['cfg']['fps']} q/s, placa={st['cfg']['hardware']}")
        a.toasted("próxima transmissão")


def crash_run(s, name, num, how, wine=False):
    """Abre o app com TELINHA_TESTE_TRAVAR e espera ele cair (sem passar pela janela)."""
    import subprocess
    from telinha_qa import App, APP, EXE
    a = App(s, name, num, [], (1280, 760), {"TELINHA_TESTE_TRAVAR": how}, False)
    if wine:
        a.wine = True
    a.d = s.display(a.num, "1280x760")
    cmd = (["wine", EXE] if wine else [APP]) + ["--janela", "0,0,1280,760", "--nome", "Ana"]
    p = s.spawn(name + "-trava", cmd, a.env())
    t0 = time.time()
    while p.poll() is None and time.time() - t0 < (60 if wine else 15):
        time.sleep(0.2)
    expect(p.poll() is not None, "o app não caiu")
    log(f"caiu com código {p.returncode}")
    return a


@test
def relatorio_de_travamento():
    """O app cai (falha de memória e panic): na próxima abertura pergunta se manda o relatório; mandando, o gofile (de mentira) recebe o motivo e a pilha."""
    with Session("travou") as s:
        gf = port()
        s.spawn("gofile", [sys.executable, os.path.join(os.path.dirname(__file__), "mockupload.py"), str(gf), "gofile", os.path.join(s.base, "gofile")], dict(os.environ))
        a = crash_run(s, "a", 91, "1")
        rep = open(os.path.join(a.cfg, "telinha", "telinha-travou.txt"), errors="replace").read()
        log("relatório:\n" + rep[:1500])
        expect("SIGSEGV" in rep and "pilha:" in rep and "telinha 3." in rep, "relatório incompleto")
        b = s.app("a", 91, ["--nome", "Ana"], extra_env={"TELINHA_GOFILE_URL": f"http://127.0.0.1:{gf}/uploadfile"})
        b.wait(lambda st: st["crash_prompt"] and st["crash_pending"], 10, "o aviso de que travou")
        b.click("##travoumandar")
        b.toasted("Relatório mandado", 30)
        b.wait(lambda st: not st["crash_pending"] and not st["crash_prompt"], 5, "o relatório sair da fila")
        body = open(os.path.join(s.base, "gofile", "post1.bin"), "rb").read()
        expect(b"SIGSEGV" in body and b"telinha-travou.txt" in body, f"o gofile não recebeu o relatório: {body[:300]!r}")
        b.stop()
        # panic do Zig: a mensagem vai junto; "Agora não" não pergunta de novo
        crash_run(s, "a", 91, "panic")
        rep = open(os.path.join(a.cfg, "telinha", "telinha-travou.txt"), errors="replace").read()
        expect("teste de travamento" in rep and "SIGABRT" in rep, f"panic sem a mensagem: {rep[:600]}")
        c2 = s.app("a", 91, ["--nome", "Ana"])
        c2.wait(lambda st: st["crash_prompt"], 10, "o aviso de novo")
        c2.click("##travounao")
        c2.wait(lambda st: not st["crash_prompt"] and not st["crash_pending"], 5, "dispensar")
        expect(os.path.exists(os.path.join(a.cfg, "telinha", "telinha-travou-antigo.txt")), "o relatório dispensado sumiu (devia ficar o antigo)")


@test
def windows_exe():
    """O telinha.exe (wine isolado): entra, assiste, lista janelas, compartilha só uma janela e a câmera avisa que não tem."""
    import subprocess
    from telinha_qa import WINEPREFIX
    with Session("wine") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Linux", "--criar", str(p), "--transmitir", "--software"])
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        tela = 96 + int(os.environ.get("QA_TELAS", "0"))
        s.display(tela)
        # outra janela no "Windows" pra compartilhar (o bloco de notas do wine)
        s.spawn("notepad", ["wine", "notepad"], {k: v for k, v in os.environ.items() if k != "WAYLAND_DISPLAY"} | {"DISPLAY": f":{tela}", "WINEPREFIX": WINEPREFIX, "WINEDEBUG": "-all"})
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
def windows_log_depuracao():
    """O .exe (wine) com o log de depuração ligado: dados do Windows no cabeçalho, amostras, e o envio pelo WinHTTP (gofile de mentira)."""
    with Session("windebug") as s:
        gf = port()
        s.spawn("gofile", [sys.executable, os.path.join(os.path.dirname(__file__), "mockupload.py"), str(gf), "gofile", os.path.join(s.base, "gofile")], dict(os.environ))
        p = port()
        a = s.app("a", 91, ["--nome", "Linux", "--criar", str(p), "--transmitir", "--software"])
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        w = s.wine_app("w", 96, ["--nome", "Windows", "--entrar", f"127.0.0.1:{p}", "--assistir", "--software"],
                       extra_env={"TELINHA_GOFILE_URL": f"http://127.0.0.1:{gf}/uploadfile"}, config={"debug_log": "1", "debug_send": "0", "name": "Windows"})
        lid = w.member_id("Linux")
        w.wait(lambda st: any(v["stream"] == lid and v["shown"] for v in st["views"]), 40, "o .exe ver a tela do Linux")
        st = w.wait(lambda st: st["debug_on"], 5, "o log ligado (da configuração)")
        logf = os.path.join(w.dir, "appdata", "telinha-debug.log")
        t0 = time.time()
        txt = ""
        while time.time() - t0 < 15:
            txt = open(logf, errors="replace").read() if os.path.exists(logf) else ""
            if "cpu app=" in txt and "assistindo" in txt:
                break
            time.sleep(0.3)
        log("log do .exe:\n" + "\n".join(l for l in txt.splitlines() if not l.startswith("[telinha]"))[:2500])
        for part in ["windows", "processador:", "OpenGL:", "cpu app=", "assistindo"]:
            expect(part in txt, f"faltou {part!r} no log do .exe")
        w.click("##gear")
        w.wait(lambda st: st["settings_modal"], 3, "abrir as configurações")
        w.click("##cfg-depuracao")
        settings_click(w, "##dbgsend")
        st = w.wait(lambda st: st["debug_send"] in ("done", "failed"), 40, "o envio pelo WinHTTP")
        expect(st["debug_send"] == "done" and st["debug_result"] == "https://gofile.io/d/teste1", f"envio: {st['debug_send']} {st['debug_result']}")
        ok, body = multipart_has_log(os.path.join(s.base, "gofile", "post1.bin"))
        expect(ok, f"o gofile não recebeu o log do .exe: {body[:300]!r}")


@test
def windows_relatorio_de_travamento():
    """O .exe (wine) cai: o filtro de exceção do Windows escreve o motivo e a pilha (módulo+deslocamento)."""
    with Session("wintravou") as s:
        a = crash_run(s, "w", 96, "1", wine=True)
        path = os.path.join(a.dir, "appdata", "telinha-travou.txt")
        expect(os.path.exists(path), "o .exe não escreveu o relatório")
        rep = open(path, errors="replace").read()
        log("relatório do .exe:\n" + rep[:1500])
        expect("acesso inválido à memória" in rep and "telinha.exe+0x" in rep and "pilha:" in rep, "relatório do .exe incompleto")


@test
def windows_chat_imagem():
    """O .exe (wine) cola uma imagem no chat (área de transferência do Windows) e o Linux vê."""
    with Session("winchat") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Linux", "--criar", str(p)])
        a.wait(lambda st: st["status"] == "connected", 10, "a sala abrir")
        w = s.wine_app("w", 96, ["--nome", "Windows", "--entrar", f"127.0.0.1:{p}"], extra_env={"TELINHA_DEBUG": "1"})
        w.wait(lambda st: st["status"] == "connected", 60, "o .exe entrar")
        png = os.path.join(s.base, "teste.png")
        write_png(png, 320, 180)
        s.spawn("xclip", ["xclip", "-quiet", "-selection", "clipboard", "-t", "image/png", "-i", png], dict(os.environ, DISPLAY=f":{w.num}"))
        time.sleep(1)
        w.click("##chatin")
        w.key("v", ctrl=True)
        st = a.wait(lambda st: any(l["img"] and l["img_ready"] for l in st["chat"]), 30, "o Linux ver a imagem colada no .exe")
        img = next(l for l in st["chat"] if l["img"])
        log(f"imagem do .exe: {img['img_w']}x{img['img_h']}, {img['img_bytes']} bytes")
        expect((img["img_w"], img["img_h"]) == (320, 180), f"tamanho errado: {img['img_w']}x{img['img_h']}")
        w.wait(lambda st: any(l["img"] and l["img_ready"] for l in st["chat"]), 10, "o .exe mostrar a própria imagem")


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


def imagem_do_quadro(app, owner, path):
    """Foto da transmissão de `owner` na tela do app: (fração verde pura, cores diferentes), ou None sem PIL.
    NV12 zerado vira verde puro: é o sinal de um decoder que "entregou" uma imagem vazia."""
    try:
        from PIL import Image
    except ImportError:
        return None
    r = app.tile(owner)
    win, _ = app.items()
    app.screenshot(path)
    im = Image.open(path).convert("RGB")
    # o meio do quadro (sem os botões e etiquetas por cima)
    w, h = r[2] - r[0], r[3] - r[1]
    box = (int(win[0] + r[0] + w * 0.15), int(win[1] + r[1] + h * 0.15), int(win[0] + r[2] - w * 0.15), int(win[1] + r[3] - h * 0.15))
    raw = im.crop(box).tobytes()
    px = [tuple(raw[i:i + 3]) for i in range(0, len(raw) - 2, 3)]
    verde = sum(1 for (cr, cg, cb) in px if cg > 100 and cr < 40 and cb < 40) / max(len(px), 1)
    return verde, len(set(px))


@test
def windows_decoder():
    """O .exe (wine) assistindo com 'usar a placa de vídeo': sem NVIDIA, Media Foundation (QA_MF_SOFTWARE=1) ou openh264; a imagem certa, inclusive quando a resolução muda."""
    with Session("winedec") as s:
        p = port()
        a = s.app("a", 91, ["--nome", "Linux", "--criar", str(p), "--transmitir", "--software"])
        a.wait(lambda st: st["status"] == "connected" and st["sharer"] and st["sharer"]["state"] == "live", 15, "a sala abrir transmitindo")
        # no wine o decoder aceita o Direct3D, mas a imagem sairia zerada (o
        # wined3d não lê textura NV12): o app recusa e fica no openh264.
        # QA_MF_SOFTWARE=1 faz o Media Foundation decodificar em software
        mf_sw = os.environ.get("QA_MF_SOFTWARE")
        esperado = "Media Foundation" if mf_sw else "openh264"
        env = {"TELINHA_DEBUG": "1", "TELINHA_SEM_NVDEC": "1"} | ({"TELINHA_MF_SOFTWARE": "1"} if mf_sw else {})
        if os.environ.get("QA_WINEDEBUG"):
            env["WINEDEBUG"] = os.environ["QA_WINEDEBUG"]  # canais de log do wine (diagnóstico)
        w = s.wine_app("w", 96, ["--nome", "Windows", "--entrar", f"127.0.0.1:{p}", "--assistir"], extra_env=env)
        lid = w.member_id("Linux")

        def vista(st):
            return next((v for v in st["views"] if v["stream"] == lid), None)

        def vendo(st, h=None):
            v = vista(st)
            return v and v["shown"] and v["fps"] > 0 and v["decoder"] and (h is None or v["h"] == h)

        v = vista(w.wait(vendo, 60, "o .exe ver a tela do Linux"))
        log(f"o .exe vê {v['w']}x{v['h']} a {v['fps']} fps com {v['decoder']}")
        expect(v["decoder"] == esperado, f"o decoder devia ser {esperado}, foi {v['decoder']}")
        if mf_sw:
            expect("[telinha] decoder: Media Foundation" in w.log_tail(400), "o log do .exe não diz que usou o Media Foundation")

        def confere(nome):
            img = imagem_do_quadro(w, lid, os.path.join(s.base, nome))
            if img is not None:
                log(f"imagem ({nome}): {img[0] * 100:.0f}% verde puro, {img[1]} cores")
                expect(img[0] < 0.5 and img[1] > 8, "a imagem decodificada está vazia (verde) ou lisa demais")

        confere("mf_antes.png")
        h0 = v["h"]
        # quem transmite muda a resolução: SPS novo no meio, o decoder renegocia
        a.click(contains="Ao vivo (configurar)##share")
        a.wait(lambda st: st["share_modal"], 3, "abrir as configurações da transmissão")
        a.click("480p")
        a.click("Aplicar")
        a.toasted("Configurações aplicadas")
        v = vista(w.wait(lambda st: vendo(st, 480), 30, "o .exe ver a tela em 480p"))
        log(f"depois de mudar: {v['w']}x{v['h']} (antes {h0}) a {v['fps']} fps com {v['decoder']}")
        expect(h0 != 480, "a resolução não mudou")
        time.sleep(2)
        v = vista(w.wait(vendo, 10, "o .exe continuar vendo"))
        expect(v["decoder"] == esperado, f"o decoder virou {v['decoder']} depois de mudar a resolução")
        confere("mf_depois.png")


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
