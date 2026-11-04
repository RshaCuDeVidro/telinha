"""O husky do ícone (assets/telinha.svg) em peças, pro site animar: a cabeça fica
atrás da tela e as patinhas na frente, então ele espia de verdade por cima dela.
Sem filtro nenhum (o brilho do ícone custa caro animando) e com as cores do pelo
e do contorno vindas do canal (CSS), menos os olhos: um azul, um âmbar.
"""


def _ear(cls: str, fill: str, line: str, fur: str) -> str:
    return (f'<g class="h-ear {cls}"><path class="h-fur" d="{fill}"/>'
            f'<path class="h-line" d="{line}"/><path class="h-pale" d="{fur}"/></g>')


def head(uid: str = "h") -> str:
    eye_l = "M86.5 104.5 A13 11.6 -8 1 1 112.5 104.5 A13 11.6 -8 1 1 86.5 104.5 Z"
    eye_r = "M169.5 104.5 A13 11.6 8 1 1 143.5 104.5 A13 11.6 8 1 1 169.5 104.5 Z"
    ear_l = _ear("h-ear-l", "M58 100 L62 44 Q63 26 80 32 L118 66 L112 104 Z", "M60 92 L62 44 Q63 26 80 32 L112 62",
                 "M70 48 Q71 38 80 42 L102 63 Q88 67 72 80 Z")
    ear_r = _ear("h-ear-r", "M198 100 L194 44 Q193 26 176 32 L138 66 L144 104 Z", "M196 92 L194 44 Q193 26 176 32 L144 62",
                 "M186 48 Q185 38 176 42 L154 63 Q168 67 184 80 Z")
    return f"""<svg class="husky-head" viewBox="40 20 176 146" aria-hidden="true" focusable="false">
<defs>
<clipPath id="{uid}-l"><path d="{eye_l}"/></clipPath>
<clipPath id="{uid}-r"><path d="{eye_r}"/></clipPath>
<radialGradient id="{uid}-az" cx=".45" cy=".4" r=".6"><stop offset="0" stop-color="#a5e9ff"/><stop offset=".55" stop-color="#38bdf8"/><stop offset="1" stop-color="#0b6fa8"/></radialGradient>
<radialGradient id="{uid}-am" cx=".45" cy=".4" r=".6"><stop offset="0" stop-color="#ffd590"/><stop offset=".55" stop-color="#e8983a"/><stop offset="1" stop-color="#8a4f18"/></radialGradient>
</defs>
{ear_l}{ear_r}
<path class="h-fur" d="M58 152 C50 132 50 110 60 92 L112 62 Q128 57 144 62 L196 92 C206 110 206 132 198 152 Z"/>
<path class="h-line" d="M58 152 C50 132 50 110 60 92 M112 62 Q128 57 144 62 M196 92 C206 110 206 132 198 152"/>
<path class="h-pale" d="M56 152 L58 118 C62 98 80 84 100 84 C113 84 121 94 128 108 C135 94 143 84 156 84 C176 84 194 98 198 118 L200 152 Z"/>
<path class="h-pale" d="M58 118 L48 124 L57 128 L46 136 L56 139 L47 147 L58 150 Z M198 118 L208 124 L199 128 L210 136 L200 139 L209 147 L198 150 Z"/>
<path class="h-v" d="M118 90 Q128 96 128 108 Q128 96 138 90"/>
<g class="h-eyes">
<path class="h-sock" d="{eye_l}"/><path class="h-sock" d="{eye_r}"/>
<g clip-path="url(#{uid}-l)"><g class="h-look"><circle cx="99.5" cy="104.5" r="9.2" fill="url(#{uid}-az)"/><circle cx="99.5" cy="104.5" r="6.2" fill="#050505"/><circle cx="96.4" cy="101.2" r="2.2" fill="#fff"/></g></g>
<g clip-path="url(#{uid}-r)"><g class="h-look"><circle cx="156.5" cy="104.5" r="9.2" fill="url(#{uid}-am)"/><circle cx="156.5" cy="104.5" r="6.2" fill="#050505"/><circle cx="153.4" cy="101.2" r="2.2" fill="#fff"/></g></g>
<path class="h-rim" d="M87.2 101.4 Q83.6 99.2 80.8 97.6 Q83.6 103 87 105.8 Z M168.8 101.4 Q172.4 99.2 175.2 97.6 Q172.4 103 169 105.8 Z"/>
</g>
<path class="h-closed" d="M87 105 Q99.5 112 112.5 105 M143.5 105 Q156.5 112 169 105"/>
<path class="h-muzzle" d="M114 110 Q110 120 106 130 Q112 140 122 143 M142 110 Q146 120 150 130 Q144 140 134 143"/>
<path class="h-nose" d="M113 126 Q128 117 143 126 Q142 137 128 140 Q114 137 113 126 Z"/>
<ellipse cx="122" cy="125" rx="4" ry="2" fill="#fff" fill-opacity=".75"/>
<path class="h-mouth" d="M128 140 V145 M128 145 Q120 150 112 145 M128 145 Q136 150 144 145"/>
</svg>"""


def paws() -> str:
    return """<svg class="husky-paws" viewBox="40 20 176 146" aria-hidden="true" focusable="false">
<rect class="h-pale h-paw" x="64" y="141" width="40" height="20" rx="10"/><rect class="h-pale h-paw" x="152" y="141" width="40" height="20" rx="10"/>
<path class="h-toes" d="M77 151 V160 M90 151 V160 M165 151 V160 M178 151 V160"/>
</svg>"""


def husky(uid: str = "h", cls: str = "") -> str:
    return f'<button class="husky{(" " + cls) if cls else ""}" type="button" tabindex="-1" aria-hidden="true">{head(uid)}{paws()}</button>'
