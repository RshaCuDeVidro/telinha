"""Testes de interface do telinha clicando nos botões de verdade.

Cada app roda numa tela escondida (Xvfb) com o modo de testes ligado
(TELINHA_QA): ele escreve onde está cada botão (items.tsv) e o próprio estado
(state.json). Aqui a gente move o mouse e clica com XTest, como uma pessoa, e
confere o estado depois. Nada aparece na tela de verdade, nada toca som
(TELINHA_SEM_SOM=1) e, com áudio, PipeWire/D-Bus/WirePlumber são privados
(saída muda, sem dispositivos de verdade).

Uso: ver run_qa.py. Precisa de Xvfb e python-xlib.
"""
import json
import math
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import wave

from Xlib import X, XK
from Xlib import display as xdisplay
from Xlib.ext import xtest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.join(ROOT, "zig-out", "bin", "telinha")
EXE = os.path.join(ROOT, "zig-out", "bin", "telinha.exe")
# prefixo do wine só dos testes (nunca o de outro programa)
WINEPREFIX = os.environ.get("QA_WINEPREFIX", os.path.join(tempfile.gettempdir(), "telinha-qa-wineprefix"))


def winpath(p):
    """Caminho do Linux como o wine vê (unidade Z:)."""
    return "Z:" + p.replace("/", "\\")
SERVER = os.path.join(ROOT, "zig-out", "bin", "telinha-server-x86_64")


class QAError(Exception):
    pass


def log(msg):
    print(f"[qa {time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Session:
    """Processos de um teste (telas, áudio isolado, apps). Tudo para no fim."""

    def __init__(self, name="qa", audio=False):
        self.name = name
        self.base = tempfile.mkdtemp(prefix=f"telinha-{name}-")
        self.procs = []  # (nome, Popen)
        self.displays = {}  # número -> Xlib Display
        self.audio = audio
        self.runtime = None
        self.apps = []

    def __enter__(self):
        if self.audio:
            self.start_audio()
        return self

    def __exit__(self, *exc):
        self.stop()
        return False

    # ---------------------------------------------------------------- processos
    def spawn(self, name, cmd, env, cwd=None):
        logf = open(os.path.join(self.base, f"{name}.log"), "wb")
        p = subprocess.Popen(cmd, env=env, stdout=logf, stderr=subprocess.STDOUT, cwd=cwd, start_new_session=True)
        self.procs.append((name, p))
        return p

    def stop_proc(self, p, timeout=3.0):
        if p.poll() is not None:
            return
        p.terminate()
        try:
            p.wait(timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(2)

    def stop(self):
        for app in reversed(self.apps):
            app.stop()
        if any(getattr(a, "wine", False) for a in self.apps):
            # só o wineserver do NOSSO prefixo
            subprocess.run(["wineserver", "-k"], env=dict(os.environ, WINEPREFIX=WINEPREFIX), timeout=20, check=False)
        for name, p in reversed(self.procs):
            self.stop_proc(p)
        for d in self.displays.values():
            try:
                d.close()
            except Exception:
                pass
        self.displays.clear()
        if self.runtime:
            # serviços que o D-Bus privado ativou sozinho (só os desse diretório)
            for pid in os.listdir("/proc"):
                if not pid.isdigit():
                    continue
                try:
                    env = open(f"/proc/{pid}/environ", "rb").read().split(b"\0")
                except OSError:
                    continue
                if f"XDG_RUNTIME_DIR={self.runtime}".encode() in env:
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except OSError:
                        pass
            time.sleep(0.3)
            shutil.rmtree(self.runtime, ignore_errors=True)
            self.runtime = None

    # ------------------------------------------------------------------- telas
    def display(self, num, size="1600x900"):
        if num in self.displays:
            return self.displays[num]
        if os.path.exists(f"/tmp/.X11-unix/X{num}"):
            raise QAError(f"a tela :{num} já existe (outro teste rodando?)")
        self.spawn(f"xvfb{num}", ["Xvfb", f":{num}", "-screen", "0", f"{size}x24", "-noreset", "-nolisten", "tcp"], dict(os.environ))
        for _ in range(100):
            if os.path.exists(f"/tmp/.X11-unix/X{num}"):
                try:
                    d = xdisplay.Display(f":{num}")
                    self.displays[num] = d
                    return d
                except Exception:
                    pass
            time.sleep(0.05)
        raise QAError(f"Xvfb :{num} não subiu")

    # ------------------------------------------------------------ áudio isolado
    def start_audio(self):
        """D-Bus, PipeWire, WirePlumber e pulse privados, só com uma saída muda."""
        self.runtime = f"/run/user/{os.getuid()}/tq{os.getpid() % 10000}"
        os.makedirs(self.runtime, mode=0o700, exist_ok=False)
        cfg = os.path.join(self.base, "audiocfg")
        wp = os.path.join(cfg, "wireplumber", "wireplumber.conf.d")
        os.makedirs(wp)
        with open(os.path.join(wp, "90-isolado.conf"), "w") as f:
            f.write("wireplumber.profiles = {\n  main = {\n")
            for m in ["alsa", "alsa-midi", "bluez", "bluez.seat-monitoring", "bluez-midi", "v4l2", "libcamera"]:
                f.write(f"    monitor.{m} = disabled\n")
            f.write("  }\n}\n")
        # gerador de vídeo de teste (vira uma "câmera" de mentira nos testes)
        pw = os.path.join(cfg, "pipewire", "pipewire.conf.d")
        os.makedirs(pw)
        with open(os.path.join(pw, "90-teste.conf"), "w") as f:
            f.write("context.spa-libs = {\n    videotestsrc = videotestsrc/libspa-videotestsrc\n}\n")
        self.audio_cfg = cfg
        env = self.audio_env({})
        self.spawn("dbus", ["dbus-daemon", "--session", f"--address=unix:path={self.runtime}/bus", "--nofork", "--nopidfile"], env)
        self._wait_file(f"{self.runtime}/bus")
        self.spawn("pipewire", ["pipewire"], env)
        self._wait_file(f"{self.runtime}/pipewire-0")
        self.spawn("wireplumber", ["wireplumber"], env)
        time.sleep(0.6)
        subprocess.run(["pw-cli", "create-node", "adapter",
                        "{ factory.name=support.null-audio-sink node.name=saida-muda node.description=\"saida muda\" "
                        "media.class=Audio/Sink object.linger=true audio.position=[FL FR] }"],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        self.spawn("pulse", ["pipewire-pulse"], env)
        self._wait_file(f"{self.runtime}/pulse/native")
        time.sleep(0.4)

    def audio_env(self, extra):
        """Ambiente limpo apontando só pro áudio privado (nunca o PipeWire de verdade)."""
        r = self.runtime
        env = {
            "HOME": os.environ.get("HOME", "/tmp"), "PATH": "/usr/bin:/bin", "USER": os.environ.get("USER", "qa"),
            "LANG": "C.UTF-8", "XDG_RUNTIME_DIR": r, "PIPEWIRE_RUNTIME_DIR": r,
            "PULSE_SERVER": f"unix:{r}/pulse/native", "DBUS_SESSION_BUS_ADDRESS": f"unix:path={r}/bus",
            "XDG_CONFIG_HOME": self.audio_cfg,
        }
        env.update(extra)
        return env

    def play_tone(self, name="tom", seconds=120, freq=440.0):
        """Um aplicativo tocando som no áudio privado (vai pra saída muda)."""
        if not self.runtime:
            raise QAError("play_tone precisa de Session(audio=True)")
        path = os.path.join(self.base, f"{name}.wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(48000)
            frames = bytearray()
            for i in range(48000 * seconds):
                v = int(9000 * math.sin(2 * math.pi * freq * i / 48000))
                frames += struct.pack("<hh", v, v)
            w.writeframes(bytes(frames))
        return self.spawn(name, ["pw-play", path], self.audio_env({}))

    def fake_mic(self, name="mic-mudo"):
        """Um microfone de mentira (fonte virtual silenciosa) no áudio privado."""
        subprocess.run(["pw-cli", "create-node", "adapter",
                        f"{{ factory.name=support.null-audio-sink node.name={name} node.description=\"Microfone de teste\" "
                        "media.class=Audio/Source/Virtual object.linger=true audio.position=[MONO] }"],
                       env=self.audio_env({}), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        time.sleep(0.5)

    def fake_camera(self, name="camfake", desc="Camera de teste"):
        """Uma câmera de mentira (padrão de teste do PipeWire) no áudio privado."""
        r = subprocess.run(["pw-cli", "create-node", "adapter",
                            f"{{ factory.name=videotestsrc node.name={name} node.description=\"{desc}\" "
                            "media.class=Video/Source media.role=Camera object.linger=true }"],
                           env=self.audio_env({}), capture_output=True, text=True, timeout=10)
        if "error" in r.stdout + r.stderr:
            raise QAError(f"não consegui criar a câmera de teste: {r.stdout} {r.stderr}")
        time.sleep(0.3)

    def _wait_file(self, path, timeout=5.0):
        t = time.time()
        while time.time() - t < timeout:
            if os.path.exists(path):
                return
            time.sleep(0.05)
        raise QAError(f"não apareceu: {path}")

    # -------------------------------------------------------------------- apps
    def wine_app(self, name, display, args, size=(1280, 760), extra_env=None):
        """O telinha.exe no wine (tela escondida, prefixo próprio, sem som)."""
        a = App(self, name, display, args, size, extra_env or {}, False)
        a.wine = True
        a.wrap = []
        self.apps.append(a)
        a.start()
        return a

    def app(self, name, display, args, size=(1280, 760), extra_env=None, audio=None, wrap=None, config=None):
        a = App(self, name, display, args, size, extra_env or {}, self.runtime is not None if audio is None else audio)
        a.wrap = wrap or []
        if config:
            os.makedirs(os.path.join(a.cfg, "telinha"), exist_ok=True)
            with open(os.path.join(a.cfg, "telinha", "config.ini"), "w") as f:
                for k, v in config.items():
                    f.write(f"{k}={v}\n")
        self.apps.append(a)
        a.start()
        return a


class App:
    def __init__(self, session, name, display, args, size, extra_env, audio):
        self.s = session
        self.name = name
        # QA_TELAS=N soma N aos números das telas (duas baterias rodando juntas)
        self.num = display + int(os.environ.get("QA_TELAS", "0"))
        self.args = args
        self.size = size
        self.extra_env = extra_env
        self.audio = audio
        self.dir = os.path.join(session.base, name)
        self.qa_dir = os.path.join(self.dir, "qa")
        self.cfg = os.path.join(self.dir, "cfg")
        os.makedirs(self.qa_dir, exist_ok=True)
        os.makedirs(self.cfg, exist_ok=True)
        self.proc = None
        self.d = None

    def env(self):
        if self.audio:
            base = self.s.audio_env({})
        else:
            base = {k: os.environ[k] for k in ("HOME", "PATH", "USER", "LANG") if k in os.environ}
        # ALSA sem dispositivo de verdade: se algum caminho cair pro ALSA
        # direto (sem PulseAudio), ele acha um "default" nulo, nunca o
        # microfone ou a caixa de som da máquina
        alsa = os.path.join(self.dir, "alsa.conf")
        with open(alsa, "w") as f:
            f.write("pcm.!default { type null }\nctl.!default { type hw card 999 }\n")
        base.update({
            "DISPLAY": f":{self.num}", "XDG_SESSION_TYPE": "x11", "TELINHA_QA": self.qa_dir,
            "XDG_CONFIG_HOME": self.cfg, "TELINHA_SEM_SOM": "1", "ALSA_CONFIG_PATH": alsa,
            # clipes e gravações na pasta do teste (nunca nos Vídeos de verdade)
            "TELINHA_PASTA_CLIPES": os.path.join(self.dir, "clipes"),
        })
        if not self.audio:
            # sem áudio isolado: o app não pode achar o PipeWire de verdade
            base["XDG_RUNTIME_DIR"] = os.path.join(self.dir, "run")
            base["PIPEWIRE_RUNTIME_DIR"] = os.path.join(self.dir, "run")
            base["PULSE_SERVER"] = "unix:/nonexistent"
            base["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/nonexistent"
            os.makedirs(base["XDG_RUNTIME_DIR"], mode=0o700, exist_ok=True)
        if getattr(self, "wine", False):
            # o .exe vê caminhos do Windows; configuração (APPDATA) e clipes na pasta do teste
            appdata = os.path.join(self.dir, "appdata")
            os.makedirs(appdata, exist_ok=True)
            base.update({
                "WINEPREFIX": WINEPREFIX, "WINEDEBUG": "-all", "TELINHA_QA": winpath(self.qa_dir),
                # o wine ignora APPDATA vindo de fora (pega do registro do prefixo)
                "TELINHA_PASTA_CONFIG": winpath(appdata), "TELINHA_PASTA_CLIPES": winpath(os.path.join(self.dir, "clipes")),
            })
        base.update(self.extra_env)
        return base

    def start(self):
        self.d = self.s.display(self.num, f"{max(self.size[0], 1280)}x{max(self.size[1], 760)}")
        w, h = self.size
        prog = ["wine", EXE] if getattr(self, "wine", False) else [APP]
        cmd = getattr(self, "wrap", []) + prog + ["--janela", f"0,0,{w},{h}"] + self.args
        self.proc = self.s.spawn(self.name, cmd, self.env())
        self.wait(lambda st: st.get("screen") is not None, 60 if getattr(self, "wine", False) else 15, "o app abrir")

    def stop(self):
        if self.proc:
            self.s.stop_proc(self.proc)
            self.proc = None

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    # ---------------------------------------------------------------- leitura
    def state(self):
        for _ in range(20):
            try:
                with open(os.path.join(self.qa_dir, "state.json")) as f:
                    return json.load(f)
            except (OSError, ValueError):
                time.sleep(0.05)
        return {}

    def items(self):
        try:
            lines = open(os.path.join(self.qa_dir, "items.tsv"), encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            return (0, 0), []
        win = (0, 0)
        out = []
        for ln in lines:
            p = ln.split("\t")
            if p[0] == "#janela":
                win = (int(p[1]), int(p[2]))
                continue
            if len(p) < 12:
                continue
            out.append({
                "label": p[0], "window": p[1], "id": int(p[2]),
                "x0": float(p[3]), "y0": float(p[4]), "x1": float(p[5]), "y1": float(p[6]),
                "cx0": float(p[7]), "cy0": float(p[8]), "cx1": float(p[9]), "cy1": float(p[10]),
                "status": int(p[11]),
            })
        return win, out

    def find(self, label=None, contains=None, window=None, within=None, timeout=5.0, need=True):
        """Item visível com esse rótulo (ou contendo o texto), dentro de `within` (x0,y0,x1,y1)."""
        t0 = time.time()
        last_key = None
        while True:
            win, items = self.items()
            hits = []
            for it in items:
                if label is not None:
                    lb = it["label"]
                    # "##id" acha também "<ícone>##id"; "Texto" acha "Texto##id"
                    ok = lb == label or lb.split("##")[0] == label or (label.startswith("##") and lb.endswith(label))
                    if not ok:
                        continue
                if contains is not None and contains not in it["label"]:
                    continue
                if window is not None and window not in it["window"]:
                    continue
                # parte visível (dentro da janela/recorte dela)
                x0, y0 = max(it["x0"], it["cx0"]), max(it["y0"], it["cy0"])
                x1, y1 = min(it["x1"], it["cx1"]), min(it["y1"], it["cy1"])
                if x1 - x0 < 2 or y1 - y0 < 2:
                    continue
                if within is not None:
                    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                    if not (within[0] <= cx <= within[2] and within[1] <= cy <= within[3]):
                        continue
                hits.append(dict(it, vx0=x0, vy0=y0, vx1=x1, vy1=y1, wx=win[0], wy=win[1]))
            if hits:
                # o menor ganha (a janela inteira também é um "item" com o nome dela)
                best = min(hits, key=lambda h: (h["vx1"] - h["vx0"]) * (h["vy1"] - h["vy0"]))
                # só confia numa posição que se repetiu (sem layout mudando no meio)
                key = (best["label"], best["window"], best["vx0"], best["vy0"], best["vx1"], best["vy1"])
                if key == last_key:
                    return best
                last_key = key
                time.sleep(0.09)
                continue
            if time.time() - t0 > timeout:
                if need:
                    raise QAError(f"[{self.name}] não achei o item {label or contains!r}" + (f" em {within}" if within else ""))
                return None
            time.sleep(0.05)

    def wait(self, cond, timeout=10.0, what="condição"):
        t0 = time.time()
        last = {}
        while time.time() - t0 < timeout:
            st = self.state()
            if st:
                last = st
                try:
                    if cond(st):
                        return st
                except (KeyError, TypeError, IndexError):
                    pass
            if self.proc is not None and self.proc.poll() is not None:
                raise QAError(f"[{self.name}] o app fechou (código {self.proc.returncode}) esperando {what}")
            time.sleep(0.08)
        brief = {k: last.get(k) for k in ("screen", "status", "error", "toasts", "home_error", "views", "members", "sharer")}
        raise QAError(f"[{self.name}] passou {timeout:.0f} s esperando {what}. Estado: {json.dumps(brief, ensure_ascii=False)[:1500]}")

    def tile(self, owner, timeout=10.0):
        st = self.wait(lambda s: any(t["stream"] == owner for t in s["tiles"]), timeout, f"o quadro de {owner}")
        t = next(t for t in st["tiles"] if t["stream"] == owner)
        return (t["x0"], t["y0"], t["x1"], t["y1"])

    def member_row(self, mid, timeout=10.0):
        st = self.wait(lambda s: any(r["id"] == mid for r in s["member_rows"]), timeout, f"a linha do membro {mid}")
        r = next(r for r in st["member_rows"] if r["id"] == mid)
        return (r["x0"], r["y0"], r["x1"], r["y1"])

    def live_row(self, stream, timeout=10.0):
        st = self.wait(lambda s: any(r["stream"] == stream for r in s["live_rows"]), timeout, f"a linha ao vivo de {stream}")
        r = next(r for r in st["live_rows"] if r["stream"] == stream)
        return (r["x0"], r["y0"], r["x1"], r["y1"])

    def click_rect(self, r, button=1):
        """Clica no meio de um retângulo (coordenadas da janela)."""
        win, _ = self.items()
        self.click_at(win[0] + (r[0] + r[2]) / 2, win[1] + (r[1] + r[3]) / 2, button)

    def member_id(self, name):
        st = self.wait(lambda s: any(m["name"] == name for m in s["members"]), 10, f"{name} na lista")
        return next(m["id"] for m in st["members"] if m["name"] == name)

    # ------------------------------------------------------------------ input
    def _abs(self, it, fx=0.5, fy=0.5):
        x = it["vx0"] + (it["vx1"] - it["vx0"]) * fx
        y = it["vy0"] + (it["vy1"] - it["vy0"]) * fy
        return int(it["wx"] + x), int(it["wy"] + y)

    def move(self, x, y):
        xtest.fake_input(self.d, X.MotionNotify, x=int(x), y=int(y))
        self.d.sync()
        time.sleep(0.12)

    def press(self, button=1):
        xtest.fake_input(self.d, X.ButtonPress, button)
        self.d.sync()
        time.sleep(0.1)

    def release(self, button=1):
        xtest.fake_input(self.d, X.ButtonRelease, button)
        self.d.sync()
        time.sleep(0.12)

    def click_at(self, x, y, button=1, double=False):
        self.move(x, y)
        for _ in range(2 if double else 1):
            self.press(button)
            self.release(button)
            if double:
                time.sleep(0.03)

    def click(self, label=None, contains=None, button=1, double=False, within=None, window=None, fx=0.5, fy=0.5, hover_first=None):
        """Clica no item. `hover_first` = ponto (x,y relativos à janela) pra passar o mouse antes (botões que só aparecem com o mouse em cima)."""
        if hover_first is not None:
            self.move(hover_first[0], hover_first[1])
            time.sleep(0.15)
        it = self.find(label, contains, window, within)
        x, y = self._abs(it, fx, fy)
        self.click_at(x, y, button, double)
        return it

    def drag(self, label, fx0, fx1, within=None, hover_first=None, steps=8):
        if hover_first is not None:
            self.move(*hover_first)
            time.sleep(0.15)
        it = self.find(label, within=within)
        x0, y = self._abs(it, fx0, 0.5)
        x1, _ = self._abs(it, fx1, 0.5)
        self.move(x0, y)
        self.press()
        for i in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * i / steps, y)
        self.release()

    def scroll(self, x, y, clicks):
        self.move(x, y)
        b = 4 if clicks > 0 else 5
        for _ in range(abs(clicks)):
            self.press(b)
            self.release(b)

    def key(self, name, ctrl=False, shift=False):
        kc = self.d.keysym_to_keycode(XK.string_to_keysym(name))
        mods = []
        if ctrl:
            mods.append(self.d.keysym_to_keycode(XK.XK_Control_L))
        if shift:
            mods.append(self.d.keysym_to_keycode(XK.XK_Shift_L))
        for m in mods:
            xtest.fake_input(self.d, X.KeyPress, m)
        xtest.fake_input(self.d, X.KeyPress, kc)
        self.d.sync()
        time.sleep(0.06)
        xtest.fake_input(self.d, X.KeyRelease, kc)
        for m in reversed(mods):
            xtest.fake_input(self.d, X.KeyRelease, m)
        self.d.sync()
        time.sleep(0.1)

    def type(self, text):
        for ch in text:
            if ch == " ":
                sym, shift = XK.XK_space, False
            elif ch == "\n":
                sym, shift = XK.XK_Return, False
            else:
                sym = XK.string_to_keysym(ch)
                shift = ch.isupper()
                if sym == 0:
                    names = {".": "period", ":": "colon", "/": "slash", "-": "minus", "_": "underscore", "#": "numbersign", "@": "at", ",": "comma", "!": "exclam", "?": "question"}
                    sym = XK.string_to_keysym(names.get(ch, ch))
                    shift = ch in ":_#@!?"
            kc = self.d.keysym_to_keycode(sym)
            if kc == 0:
                raise QAError(f"não sei digitar {ch!r}")
            if shift:
                xtest.fake_input(self.d, X.KeyPress, self.d.keysym_to_keycode(XK.XK_Shift_L))
            xtest.fake_input(self.d, X.KeyPress, kc)
            xtest.fake_input(self.d, X.KeyRelease, kc)
            if shift:
                xtest.fake_input(self.d, X.KeyRelease, self.d.keysym_to_keycode(XK.XK_Shift_L))
            self.d.sync()
            time.sleep(0.03)
        time.sleep(0.1)

    def click_unlabeled(self, window, index=0):
        """Clica no n-ésimo item sem rótulo de uma janela (o combo do ImGui não registra o rótulo)."""
        t0 = time.time()
        while True:
            win, items = self.items()
            hits = [it for it in items if it["label"] == "" and window in it["window"] and it["y1"] - it["y0"] < 80]
            if len(hits) > index:
                break
            if time.time() - t0 > 5:
                raise QAError(f"[{self.name}] não achei item sem rótulo #{index} em {window}")
            time.sleep(0.1)
        it = hits[index]
        self.click_at(win[0] + (it["x0"] + it["x1"]) / 2, win[1] + (it["y0"] + it["y1"]) / 2)

    def x_windows(self):
        """Nomes das janelas na tela dessa instância."""
        out = []
        for w in self.d.screen().root.query_tree().children:
            try:
                n = w.get_wm_name()
            except Exception:
                n = None
            if n:
                out.append((n, w))
        return out

    def move_x_window(self, name, x, y, w, h, timeout=20.0):
        """Põe uma janela (de outro programa) num lugar fixo da tela."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            for n, win in self.x_windows():
                if n == name:
                    win.configure(x=x, y=y, width=w, height=h)
                    self.d.sync()
                    return True
            time.sleep(0.2)
        return False

    def close_x_window(self, name):
        """Fecha uma janela como o X do gerenciador de janelas faria (WM_DELETE_WINDOW)."""
        from Xlib import protocol
        wm_protocols = self.d.intern_atom("WM_PROTOCOLS")
        wm_delete = self.d.intern_atom("WM_DELETE_WINDOW")
        for n, w in self.x_windows():
            if n == name:
                ev = protocol.event.ClientMessage(window=w, client_type=wm_protocols, data=(32, [wm_delete, X.CurrentTime, 0, 0, 0]))
                w.send_event(ev, event_mask=X.NoEventMask)
                self.d.flush()
                return True
        return False

    def unfocus(self):
        """Tira o foco do teclado da janela (como se a pessoa fosse pra outro app)."""
        self.d.set_input_focus(self.d.screen().root, X.RevertToPointerRoot, X.CurrentTime)
        self.d.sync()
        time.sleep(0.2)

    def fill(self, label, text):
        """Clica num campo de texto, apaga o que tinha e digita."""
        self.click(label)
        self.key("a", ctrl=True)
        self.key("BackSpace")
        if text:
            self.type(text)

    def toasted(self, text, timeout=5.0):
        return self.wait(lambda st: any(text in t for t in st["toasts"]), timeout, f"o aviso '{text}'")

    def screenshot(self, path):
        env = dict(os.environ, DISPLAY=f":{self.num}")
        subprocess.run(["import", "-window", "root", path], env=env, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return path

    def log_tail(self, n=40):
        try:
            return "".join(open(os.path.join(self.s.base, f"{self.name}.log"), errors="replace").readlines()[-n:])
        except OSError:
            return ""
