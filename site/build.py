#!/usr/bin/env python3
"""Gera o site do telinha (GitHub Pages) a partir dos .md do repositório.

Os .md continuam sendo a fonte: aqui só vira HTML com a cara do site, nos dois
idiomas (pt na raiz, en em /en/), com barra lateral, índice da página, busca e
links entre os docs apontando pras páginas do site. No fim confere cada link
interno (página e âncora): link quebrado faz o build falhar.

    python3 site/build.py              # gera em _site/
    python3 site/build.py --out DIR

Precisa de: markdown (Python-Markdown) e pygments.
"""
import argparse
import html
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import unicodedata
from datetime import date
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, unquote

import markdown
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

REPO = "RshaCuDeVidro/telinha"
GH = f"https://github.com/{REPO}"
GH_BLOB = f"{GH}/blob/main/"
SITE_URL = f"https://{REPO.split('/')[0].lower()}.github.io/{REPO.split('/')[1]}/"
SITE_PATH = urlsplit(SITE_URL).path  # "/telinha/" (pro 404, que é servido em qualquer caminho)
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from icons import icon, sprite  # noqa: E402
TOP = os.path.dirname(HERE)
LANGS = ("pt", "en")

# ------------------------------------------------------------------ páginas
# (slug, fonte em inglês, fonte em português, trecho do README ou None)
SECTIONS = [
    ("start", {"pt": "Começar", "en": "Getting started", "icon": "play"}, [
        ("guide", "docs/GUIDE.md", "docs/GUIDE.pt.md", None),
        ("connecting", "docs/CONNECTING.md", "docs/CONNECTING.pt.md", None),
        ("faq", "docs/FAQ.md", "docs/FAQ.pt.md", None),
    ]),
    ("server", {"pt": "Servidor", "en": "Server", "icon": "server"}, [
        ("deploy", "docs/DEPLOY.md", "docs/DEPLOY.pt.md", None),
    ]),
    ("bots", {"pt": "Bots", "en": "Bots", "icon": "bot"}, [
        ("bots", "docs/BOTS.md", "docs/BOTS.pt.md", None),
        ("bots-music", "docs/BOTS_MUSIC.md", "docs/BOTS_MUSIC.pt.md", None),
        ("bots-screen", "docs/BOTS_SCREEN.md", "docs/BOTS_SCREEN.pt.md", None),
        ("bots-tutorial", "docs/BOTS_TUTORIAL.md", "docs/BOTS_TUTORIAL.pt.md", None),
        ("bots-api", "docs/BOTS_API.md", "docs/BOTS_API.pt.md", None),
    ]),
    ("dev", {"pt": "Desenvolvimento", "en": "Development", "icon": "code"}, [
        ("building", "README.md", "README.pt.md", {"en": "Building from source", "pt": "Compilar"}),
        ("architecture", "docs/ARCHITECTURE.md", "docs/ARCHITECTURE.pt.md", None),
        ("protocol", "docs/PROTOCOL.md", "docs/PROTOCOL.pt.md", None),
        ("contributing", "CONTRIBUTING.md", "CONTRIBUTING.pt.md", None),
    ]),
    ("news", {"pt": "Novidades", "en": "What's new", "icon": "spark"}, [
        ("changelog", "CHANGELOG.md", "CHANGELOG.pt.md", None),
    ]),
]

# nome curto na barra lateral (o título da página continua o do .md)
NAV = {
    "connecting": {"pt": "Conectar de fora", "en": "Connecting from outside"},
    "protocol": {"pt": "Protocolo", "en": "Protocol"},
    "contributing": {"pt": "Contribuir", "en": "Contributing"},
    "bots": {"pt": "Visão geral", "en": "Overview"},
    "bots-music": {"pt": "Bot de música", "en": "Music bot"},
    "bots-screen": {"pt": "Bot de tela", "en": "Big-screen bot"},
    "bots-tutorial": {"pt": "Criar um bot", "en": "Make a bot"},
    "bots-api": {"pt": "Referência da API", "en": "API reference"},
}

UI = {
    "pt": {
        "home": "Início", "docs": "Docs", "server": "Servidor", "news": "Novidades", "bots": "Bots", "menu_btn": "Menu",
        "search": "buscar", "searchTitle": "Buscar na documentação", "theme": "Tema claro/escuro",
        "crt": "Efeito CRT", "other_lang": "English", "other_lang_short": "EN",
        "menu": "páginas", "top": "Voltar ao topo", "on_page": "nesta página",
        "edit": "editar esta página", "source": "ver o .md no GitHub", "updated": "atualizado",
        "read": "min de leitura", "prev": "anterior", "next": "próxima",
        "copy": "copiar", "copied": "copiado!", "loading": "carregando o índice…",
        "searchHint": "digite pra buscar em todas as páginas",
        "noResults": "nada encontrado. tenta outra palavra?", "searchFail": "não deu pra carregar o índice da busca",
        "nav_keys": "↑↓ escolher · enter abrir · esc fechar",
        "footer": "telinha · licença MIT · feito com Zig",
        "notfound_title": "404 — sinal perdido", "notfound": "Essa página não existe (ou mudou de lugar).",
        "notfound_back": "voltar pro início", "skip": "pular pro conteúdo",
        "callout": {"NOTE": "nota", "TIP": "dica", "IMPORTANT": "importante", "WARNING": "atenção", "CAUTION": "cuidado"},
        "desc": "Compartilhar a tela em grupo, com atraso baixo, no Linux e no Windows. Uma sala estilo Discord onde qualquer um transmite e todo mundo assiste, fala e conversa.",
    },
    "en": {
        "home": "Home", "docs": "Docs", "server": "Server", "news": "What's new", "bots": "Bots", "menu_btn": "Menu",
        "search": "search", "searchTitle": "Search the docs", "theme": "Light/dark theme",
        "crt": "CRT effect", "other_lang": "Português", "other_lang_short": "PT",
        "menu": "pages", "top": "Back to top", "on_page": "on this page",
        "edit": "edit this page", "source": "view the .md on GitHub", "updated": "updated",
        "read": "min read", "prev": "previous", "next": "next",
        "copy": "copy", "copied": "copied!", "loading": "loading the index…",
        "searchHint": "type to search every page",
        "noResults": "nothing found. try another word?", "searchFail": "couldn't load the search index",
        "nav_keys": "↑↓ choose · enter open · esc close",
        "footer": "telinha · MIT license · made with Zig",
        "notfound_title": "404 — signal lost", "notfound": "This page doesn't exist (or it moved).",
        "notfound_back": "back to the home page", "skip": "skip to content",
        "callout": {"NOTE": "note", "TIP": "tip", "IMPORTANT": "important", "WARNING": "warning", "CAUTION": "caution"},
        "desc": "Low-latency group screen sharing for Linux and Windows. A Discord-style room where anyone can go live and everyone can watch, talk and chat.",
    },
}



# ------------------------------------------------------------------ utilidades
def read(path):
    with open(os.path.join(TOP, path), encoding="utf-8") as f:
        return f.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def gh_slug(value, separator="-"):
    """Âncora do jeito do GitHub: minúsculas, acentos mantidos, pontuação fora."""
    value = unicodedata.normalize("NFC", html.unescape(re.sub(r"<[^>]+>", "", value))).strip().lower()
    value = "".join(ch for ch in value if ch.isalnum() or ch in " -_")
    return value.replace(" ", separator)


def plain(html_text):
    t = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html_text, flags=re.S)
    # fim de bloco separa palavras; tag de texto (strong, code, a) não
    t = re.sub(r"</?(p|li|ul|ol|h\d|td|th|tr|table|pre|div|blockquote|br|hr|details|summary)\b[^>]*>", " ", t)
    t = re.sub(r"<[^>]+>", "", t)
    return re.sub(r"\s+", " ", html.unescape(t)).strip()


def app_version():
    m = re.search(r'app_version = "([^"]+)"', read("src/proto.zig"))
    return m.group(1) if m else "?"


def last_updated(src):
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cs", "--", src], cwd=TOP, capture_output=True, text=True, timeout=10).stdout.strip()
        return out or None
    except (OSError, subprocess.SubprocessError):
        return None


def readme_section(text, heading):
    """O trecho do README de '## heading' até o próximo '## ', virando página."""
    m = re.search(rf"^## {re.escape(heading)}\s*$", text, re.M)
    if not m:
        raise SystemExit(f"README sem a seção '{heading}'")
    rest = text[m.end():]
    end = re.search(r"^## ", rest, re.M)
    body = rest[: end.start()] if end else rest
    return f"# {heading}\n{body}"


# ------------------------------------------------------------------ markdown
FENCE = re.compile(r"^(?P<ind>[ \t]*)(?P<fence>`{3,}|~{3,})[ \t]*(?P<lang>[\w+-]*)[^\n]*$")


def pull_code(src):
    """Tira os blocos ``` antes do markdown (e devolve já realçados), pra não
    depender de como o markdown trata código dentro de lista."""
    lines = src.split("\n")
    out, blocks = [], []
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        ind, fence, lang = m.group("ind"), m.group("fence"), m.group("lang")
        body = []
        i += 1
        while i < len(lines) and not re.match(rf"^[ \t]*{re.escape(fence[0])}{{{len(fence)},}}\s*$", lines[i]):
            ln = lines[i]
            body.append(ln[len(ind):] if ln.startswith(ind) else ln.lstrip())
            i += 1
        i += 1  # a cerca de fechar
        code = "\n".join(body)
        try:
            lexer = get_lexer_by_name(lang) if lang else None
        except ClassNotFound:
            lexer = None
        if lexer:
            inner = highlight(code, lexer, HtmlFormatter(nowrap=True))
        else:
            inner = html.escape(code) + "\n"
        label = f' data-lang="{html.escape(lang)}"' if lang else ""
        blocks.append(f'<pre class="hl"{label}><code>{inner.rstrip()}</code></pre>')
        out.append(f"{ind}TELINHACODE{len(blocks) - 1}X")
    return "\n".join(out), blocks


def put_code(h, blocks):
    def rep(m):
        return blocks[int(m.group(1))]
    h = re.sub(r"<p>TELINHACODE(\d+)X</p>", rep, h)
    return re.sub(r"TELINHACODE(\d+)X", rep, h)


def callouts(h, lang):
    """> [!NOTE] do GitHub vira um aviso com cara de terminal."""
    names = UI[lang]["callout"]
    out, pos = [], 0
    pat = re.compile(r"<blockquote>\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(?:<br\s*/?>)?\s*")
    while True:
        m = pat.search(h, pos)
        if not m:
            out.append(h[pos:])
            break
        end = h.find("</blockquote>", m.end())
        kind = m.group(1)
        inner = "<p>" + h[m.end():end]
        inner = inner.replace("<p></p>", "")
        out.append(h[pos:m.start()])
        out.append(f'<div class="callout {kind.lower()}"><div class="callout-title">{names[kind]}</div>{inner}</div>')
        pos = end + len("</blockquote>")
    return "".join(out)


EMOJI = re.compile("[\U0001F000-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\u2300-\u23FF\u21A9\u21AA\u2194-\u2199\u2934\u2935\uFE0F\u200D\u20E3]")


def strip_emoji(h):
    """O site não usa emoji (o app e o changelog dele usam): tira, menos dentro de código."""
    parts = re.split(r"(<pre.*?</pre>|<code.*?</code>)", h, flags=re.S)
    for i in range(0, len(parts), 2):
        t = EMOJI.sub("", parts[i])
        parts[i] = re.sub(r"(<li>|<p>|<h[1-6][^>]*>)\s+", r"\1", t)
    return "".join(parts)


def anchors(h):
    return re.sub(r'<h([234]) id="([^"]+)">(.*?)</h\1>',
                  lambda m: f'<h{m.group(1)} id="{m.group(2)}">{m.group(3)}<a class="anchor" href="#{m.group(2)}" aria-hidden="true" tabindex="-1">#</a></h{m.group(1)}>', h)


def kbd(h):
    # **Ctrl+M**, **F11**, **Esc** nos docs viram teclas
    return re.sub(r"<strong>((?:Ctrl|Shift|Alt|Super)\+[^<]{1,20}|F\d{1,2}|Esc|Enter)</strong>", r"<kbd>\1</kbd>", h)


def render_md(src_text):
    src_text = re.sub(r"^<sub>\[🇺🇸 English\].*?</sub>\s*$", "", src_text, flags=re.M)
    # markdown dentro de <details> (tabelas, listas) também vira HTML
    src_text = re.sub(r"^<details>", '<details markdown="1">', src_text, flags=re.M)
    text, blocks = pull_code(src_text)
    md = markdown.Markdown(extensions=["tables", "toc", "attr_list", "md_in_html", "sane_lists"],
                           extension_configs={"toc": {"slugify": gh_slug, "toc_depth": "2-3"}})
    body = md.convert(text)
    # "\|" numa tabela do GitHub é uma barra; dentro de `código` o markdown deixa a contrabarra
    body = re.sub(r"<td>(.*?)</td>", lambda m: "<td>" + m.group(1).replace("\\|", "|") + "</td>", body, flags=re.S)
    # o título (h1) vai no cartão de cima
    m = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
    title = plain(m.group(1)) if m else ""
    if m:
        body = body[:m.start()] + body[m.end():]
    toc = [(t["level"], t["id"], plain(t["name"])) for t in _flat(md.toc_tokens) if t["level"] in (2, 3)]
    return title, put_code(body, blocks), toc


def _flat(tokens):
    for t in tokens:
        yield t
        yield from _flat(t.get("children", []))


# ------------------------------------------------------------------ links
class Site:
    def __init__(self, out):
        self.out = out
        self.pages = []  # dicts com slug, lang, src, ...
        self.src_to_slug = {}
        self.images = set()

    def page_path(self, lang, slug=None):
        """Caminho (a partir da raiz do site) da página."""
        prefix = "" if lang == "pt" else "en/"
        return prefix + ("" if slug is None else f"docs/{slug}/")

    def fix_links(self, h, src, lang, base):
        srcdir = posixpath.dirname(src)

        def resolve(url, is_img):
            if not url or url.startswith(("#", "mailto:", "data:")) or re.match(r"^[a-z]+://", url):
                return url
            path, _, frag = url.partition("#")
            repo_path = posixpath.normpath(posixpath.join(srcdir, unquote(path))) if path else src
            if repo_path.startswith("docs/img/") or repo_path.startswith("assets/"):
                self.images.add(repo_path)
                return base + "img/" + repo_path.split("/", 1)[1] if repo_path.startswith("docs/") else base + repo_path
            key = re.sub(r"\.pt\.md$", ".md", repo_path)
            if key in self.src_to_slug:
                return base + self.page_path(lang, self.src_to_slug[key]) + (f"#{frag}" if frag else "")
            # o resto (código, licença, Releases) fica no GitHub
            return urljoin(GH_BLOB + src, url)

        h = re.sub(r'(<a\s[^>]*?href=")([^"]*)(")', lambda m: m.group(1) + html.escape(resolve(html.unescape(m.group(2)), False)) + m.group(3), h)
        h = re.sub(r'(<img\s[^>]*?src=")([^"]*)(")', lambda m: m.group(1) + html.escape(resolve(html.unescape(m.group(2)), True)) + m.group(3), h)
        # link pra fora abre em outra aba
        return re.sub(r'<a\s(href="https?://(?!' + re.escape(urlsplit(SITE_URL).netloc) + r')[^"]*")', r'<a target="_blank" rel="noopener" \1', h)


# ------------------------------------------------------------------ moldura
def head(lang, title, desc, base, path, extra=""):
    t = UI[lang]
    other = "en" if lang == "pt" else "pt"
    alt_path = path[3:] if path.startswith("en/") else "en/" + path
    js = {"lang": lang, "base": base, "t": {k: t[k] for k in ("copy", "copied", "loading", "searchHint", "noResults", "searchFail")}}
    full = f"{title} · telinha" if title != "telinha" else "telinha"
    return f"""<!doctype html>
<html lang="{'pt-BR' if lang == 'pt' else 'en'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(full)}</title>
<meta name="description" content="{html.escape(desc)}">
<meta name="theme-color" content="#050505">
<link rel="canonical" href="{SITE_URL}{path}">
<link rel="alternate" hreflang="{'pt-BR' if lang == 'pt' else 'en'}" href="{SITE_URL}{path}">
<link rel="alternate" hreflang="{'en' if other == 'en' else 'pt-BR'}" href="{SITE_URL}{alt_path}">
<meta property="og:type" content="website">
<meta property="og:title" content="{html.escape(full)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:image" content="{SITE_URL}img/{lang}/room.jpg">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="{base}assets/telinha.svg" type="image/svg+xml">
<link rel="icon" href="{base}assets/icon.png" type="image/png">
<link rel="preload" href="{base}assets/fonts/fira-code-latin.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="{base}assets/style.css">
<script>
(function(){{var r=document.documentElement,s=null,c=null;try{{s=localStorage.getItem('telinha-theme');c=localStorage.getItem('telinha-crt')}}catch(e){{}}
r.dataset.theme=s||'dark';if(c==='off')r.dataset.crt='off';}})();
window.TELINHA={json.dumps(js, ensure_ascii=False)};
</script>{extra}
</head>"""


def header(lang, base, active, path, page_class=""):
    t = UI[lang]
    lp = "" if lang == "pt" else "en/"
    other = "en" if lang == "pt" else "pt"
    alt_path = path[3:] if path.startswith("en/") else "en/" + path

    def nav(key, href):
        cls = ' class="active" aria-current="page"' if active == key else ""
        return f'<a href="{base}{href}"{cls}>{t[key]}</a>'
    links = "".join(nav(k, h) for k, h in (("home", lp), ("docs", lp + "docs/guide/"), ("server", lp + "docs/deploy/"),
                                           ("bots", lp + "docs/bots/"), ("news", lp + "docs/changelog/")))
    return f"""<body class="bg-grid{(' page-' + page_class) if page_class else ''}">
{sprite()}
<a class="sr-only" href="#conteudo">{t['skip']}</a>
<div class="scroll-progress" aria-hidden="true"></div>
<header class="site-header">
  <div class="header-inner">
    <a class="logo glitch-hover" href="{base}{lp}"><img src="{base}assets/icon.png" alt="" width="26" height="26">telinha<span class="logo-path">~/wiki</span></a>
    <nav class="main-nav" aria-label="principal">{links}</nav>
    <div class="header-tools">
      <button class="search-btn" type="button" title="{t['searchTitle']}">{icon("search")}<span class="label">{t['search']}</span><kbd>Ctrl K</kbd></button>
      <a class="icon-btn lang-switch" data-lang="{other}" href="{base}{alt_path}" hreflang="{other}" title="{t['other_lang']}">{t['other_lang_short']}</a>
      <button class="icon-btn crt-toggle" type="button" title="{t['crt']}" aria-label="{t['crt']}">{icon("crt")}</button>
      <button class="icon-btn theme-toggle" type="button" title="{t['theme']}" aria-label="{t['theme']}">{icon("sun", "sun")}{icon("moon", "moon")}</button>
      <a class="icon-btn gh-btn" href="{GH}" target="_blank" rel="noopener" title="GitHub" aria-label="GitHub">{icon("github")}</a>
      <button class="icon-btn menu-btn" type="button" aria-expanded="false" aria-controls="mobile-nav" title="{t['menu_btn']}" aria-label="{t['menu_btn']}">{icon("menu", "open")}{icon("close", "shut")}</button>
    </div>
  </div>
  <nav class="mobile-nav" id="mobile-nav" aria-label="principal" hidden>{links}<a href="{GH}" target="_blank" rel="noopener">GitHub {icon("external")}</a></nav>
</header>"""


def footer(lang, base):
    t = UI[lang]
    lp = "" if lang == "pt" else "en/"
    return f"""<footer class="site-footer">
  <div class="footer-inner">
    <span>{t['footer']} · v{app_version()}</span>
    <span class="footer-links">
      <a href="{base}{lp}docs/guide/">{t['docs']}</a>
      <a href="{base}{lp}docs/changelog/">{t['news']}</a>
      <a href="{GH}/releases/latest" target="_blank" rel="noopener">releases</a>
      <a href="{GH}/issues" target="_blank" rel="noopener">issues</a>
      <a href="{GH}" target="_blank" rel="noopener">github</a>
    </span>
  </div>
</footer>
<div class="search-overlay" role="dialog" aria-modal="true" aria-label="{t['searchTitle']}">
  <div class="search-box">
    <div class="search-input-row"><span class="prompt">grep -i</span><input type="search" placeholder="{t['search']}…" aria-label="{t['searchTitle']}" autocomplete="off" spellcheck="false"></div>
    <div class="search-results"></div>
    <div class="search-foot">{t['nav_keys']}</div>
  </div>
</div>
<button class="tk-top-btn" type="button" aria-label="{t['top']}" title="{t['top']}">{icon("arrow-up")}</button>
<script src="{base}assets/site.js" defer></script>
</body>
</html>
"""


def sidebar(site, lang, base, current):
    t = UI[lang]
    parts = [f'<aside class="tk-sidebar" aria-label="docs"><div class="tk-sidebar-header"><div class="prompt"><b>$</b> ls ~/telinha/docs</div><h2>docs</h2></div><ul class="tk-tree">']
    for _, names, pages in SECTIONS:
        parts.append(f'<li><div class="tk-tree-cat-name">{icon(names["icon"])}{names[lang]}</div><ul class="tk-tree-pages">')
        for slug, *_ in pages:
            p = site.by_slug[(lang, slug)]
            cls = " active" if slug == current else ""
            cur = ' aria-current="page"' if slug == current else ""
            parts.append(f'<li><a class="tk-tree-link{cls}"{cur} href="{base}{site.page_path(lang, slug)}">{html.escape(p["nav"])}</a></li>')
        parts.append("</ul></li>")
    parts.append("</ul></aside>")
    return "".join(parts)


# ------------------------------------------------------------------ build
def build(out):
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    site = Site(out)
    site.by_slug = {}
    order = []
    for sec_key, names, pages in SECTIONS:
        for slug, en, pt, readme in pages:
            site.src_to_slug[en] = slug
            order.append((sec_key, names, slug, en, pt, readme))
    version = app_version()
    search = {lang: [] for lang in LANGS}

    # 1) tudo vira HTML
    for lang in LANGS:
        for sec_key, names, slug, en, pt, readme in order:
            src = pt if lang == "pt" else en
            text = read(src)
            if readme:
                text = readme_section(text, readme[lang])
            title, body, toc = render_md(text)
            nav = NAV[slug][lang] if slug in NAV else readme[lang] if readme else title
            p = {"slug": slug, "lang": lang, "src": src, "title": title, "nav": nav, "body": body, "toc": toc,
                 "section": names[lang], "updated": last_updated(src)}
            site.pages.append(p)
            site.by_slug[(lang, slug)] = p

    # 2) cada página no lugar, com links arrumados
    for lang in LANGS:
        pages = [p for p in site.pages if p["lang"] == lang]
        for i, p in enumerate(pages):
            path = site.page_path(lang, p["slug"])
            base = "../" * path.count("/")
            body = p["body"]
            body = strip_emoji(callouts(body, lang))
            body = anchors(kbd(body))
            body = site.fix_links(body, p["src"], lang, base)
            words = len(plain(body).split())
            desc = plain(body)[:180]
            t = UI[lang]
            meta = []
            if p["updated"]:
                meta.append(f'<span class="meta-item">{t["updated"]} <b>{p["updated"]}</b></span>')
            meta.append(f'<span class="meta-item"><b>{max(1, round(words / 200))}</b> {t["read"]}</span>')
            meta.append(f'<span class="meta-item"><a href="{GH}/edit/main/{p["src"]}" target="_blank" rel="noopener">{icon("edit")} {t["edit"]}</a></span>')
            prev_html = next_html = ""
            if i > 0:
                q = pages[i - 1]
                prev_html = f'<a class="mini-card prev" href="{base}{site.page_path(lang, q["slug"])}"><span>← {t["prev"]}</span><b>{html.escape(q["nav"])}</b></a>'
            if i + 1 < len(pages):
                q = pages[i + 1]
                next_html = f'<a class="mini-card next" href="{base}{site.page_path(lang, q["slug"])}"><span>{t["next"]} →</span><b>{html.escape(q["nav"])}</b></a>'
            toc_html = ""
            if len(p["toc"]) >= 2:
                items = "".join(f'<li class="lvl{lvl}"><a class="toc-link" href="#{hid}">{html.escape(name)}</a></li>' for lvl, hid, name in p["toc"])
                toc_html = f'<nav class="toc" aria-label="{t["on_page"]}"><div class="toc-title">{t["on_page"]}</div><ul>{items}</ul><div class="toc-actions"><a href="{GH_BLOB}{p["src"]}" target="_blank" rel="noopener">{icon("file")} {t["source"]}</a></div></nav>'
            page = head(lang, p["title"], desc, base, path) + header(lang, base, "news" if p["slug"] == "changelog" else "server" if p["slug"] == "deploy" else "bots" if p["slug"].startswith("bots") else "docs", path, p["slug"])
            page += f"""
<div class="docs-shell{'' if toc_html else ' no-toc'}">
  {sidebar(site, lang, base, p['slug'])}
  <main class="doc-main" id="conteudo">
    <div class="tk-breadcrumb"><a href="{base}{site.page_path(lang)}">~</a><span class="sep">/</span>docs<span class="sep">/</span>{html.escape(p['section'].lower())}</div>
    <div class="article-header-card fade-in">
      <span class="category-badge">{html.escape(p['section'])}</span>
      <h1>{html.escape(p['title'])}</h1>
      <div class="meta-row">{''.join(meta)}</div>
    </div>
    <article class="article-body-card markdown-body">
{body}
    </article>
    <nav class="page-nav">{prev_html}{next_html}</nav>
  </main>
  {toc_html}
</div>
<button class="tk-drawer-btn" type="button">{icon("menu")} {t['menu']}</button>
<div class="tk-drawer-overlay"></div>
""" + footer(lang, base)
            write(os.path.join(out, path, "index.html"), page)
            # busca: uma entrada por seção (h2/h3) da página
            index_sections(search[lang], p, body, path)

    # 3) página inicial
    for lang in LANGS:
        path = site.page_path(lang)
        base = "../" * path.count("/")
        content = read(f"site/home.{lang}.html")
        for m in re.finditer(r"\{\{img\}\}([^\"']+)", content):
            site.images.add("docs/img/" + m.group(1))
        content = content.replace("{{img}}", base + "img/")
        content = re.sub(r"\{\{icon:([a-z-]+)\}\}", lambda m: icon(m.group(1)), content)
        content = content.replace("{{base}}", base).replace("{{lp}}", "" if lang == "pt" else "en/")
        content = content.replace("{{version}}", version).replace("{{gh}}", GH)
        content = content.replace("{{news}}", news_html(lang, base))
        redirect = ""
        if lang == "pt":
            # primeira visita, navegador em outra língua: vai pro inglês (escolher no seletor vale pra sempre)
            redirect = "\n<script>(function(){try{if(localStorage.getItem('telinha-lang'))return}catch(e){}var l=(navigator.languages||[navigator.language||''])" \
                       ".join(',').toLowerCase();if(l&&l.indexOf('pt')<0)location.replace('en/')})();</script>"
        page = head(lang, "telinha", UI[lang]["desc"], base, path, redirect) + header(lang, base, "home", path)
        page += f'\n<main class="home" id="conteudo">\n{content}\n</main>\n' + footer(lang, base)
        write(os.path.join(out, path, "index.html"), page)

    # 4) arquivos: estilo, fontes, imagens, busca, 404, sitemap
    shutil.copytree(os.path.join(HERE, "assets"), os.path.join(out, "assets"))
    for f in ("icon.png", "telinha.svg"):
        shutil.copy(os.path.join(TOP, "assets", f), os.path.join(out, "assets", f))
    for img in sorted(site.images):
        if img.startswith("docs/img/"):
            dst = os.path.join(out, "img", img[len("docs/img/"):])
        else:
            dst = os.path.join(out, img)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(TOP, img), dst)
    for lang in LANGS:
        write(os.path.join(out, f"search-{lang}.json"), json.dumps(search[lang], ensure_ascii=False, separators=(",", ":")))
    t = UI["pt"]
    nf = head("pt", "404", t["desc"], SITE_PATH, "404.html") + header("pt", SITE_PATH, "", "")
    nf += f"""
<main class="home" id="conteudo"><section class="hero wrap">
  <div class="hero-kicker">error: 404</div>
  <h1 class="hero-title"><span class="hero-glitch" data-text="404">404</span></h1>
  <p class="hero-sub cursor-blink">{t['notfound']} / {UI['en']['notfound']}</p>
  <div class="dl-row"><a class="btn primary" href="{SITE_PATH}">{t['notfound_back']}</a><a class="btn" href="{SITE_PATH}en/">{UI['en']['notfound_back']}</a></div>
</section></main>
""" + footer("pt", SITE_PATH)
    write(os.path.join(out, "404.html"), nf)
    urls = [site.page_path(l) for l in LANGS] + [site.page_path(p["lang"], p["slug"]) for p in site.pages]
    write(os.path.join(out, "sitemap.xml"), '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
          + "".join(f"  <url><loc>{SITE_URL}{u}</loc><lastmod>{date.today().isoformat()}</lastmod></url>\n" for u in urls) + "</urlset>\n")
    write(os.path.join(out, "robots.txt"), f"User-agent: *\nAllow: /\nSitemap: {SITE_URL}sitemap.xml\n")
    write(os.path.join(out, ".nojekyll"), "")
    return site


def news_html(lang, base):
    """Os destaques da seção mais nova do CHANGELOG (a página inicial mostra sozinha)."""
    text = read("CHANGELOG.pt.md" if lang == "pt" else "CHANGELOG.md")
    m = re.search(r"^## (.+)$", text, re.M)
    if not m:
        return ""
    title = m.group(1).strip()
    rest = text[m.end():]
    end = re.search(r"^## ", rest, re.M)
    sec = rest[: end.start()] if end else rest
    hl = re.search(r"^### (?:Destaques|Highlights)\s*$(.*?)(?=^### |^<!--|\Z)", sec, re.M | re.S)
    if not hl:
        return ""
    md = markdown.Markdown(extensions=["sane_lists"])
    body = strip_emoji(md.convert(hl.group(1)))
    lp = "" if lang == "pt" else "en/"
    label = ("v" + title) if title[:1].isdigit() else title
    anchor = gh_slug(title)
    href = f"{base}{lp}docs/changelog/#{anchor}"
    more = "o changelog inteiro →" if lang == "pt" else "the full changelog →"
    return (f'<div class="news-head"><span class="tag-badge">{html.escape(label)}</span>'
            f'<a href="{href}">{more}</a></div><div class="news-body markdown-body">{body}</div>')


def index_sections(entries, p, body, path):
    parts = re.split(r'(<h[23] id="[^"]+">.*?</h[23]>)', body, flags=re.S)
    entries.append({"page": p["section"], "title": p["title"], "url": path, "text": plain(parts[0])[:600], "level": 1})
    for i in range(1, len(parts) - 1, 2):
        m = re.match(r'<h([23]) id="([^"]+)">(.*?)</h[23]>', parts[i], re.S)
        title = plain(re.sub(r'<a class="anchor".*?</a>', "", m.group(3)))
        entries.append({"page": p["title"], "title": title, "url": f"{path}#{m.group(2)}", "text": plain(parts[i + 1])[:1200], "level": int(m.group(1))})


# ------------------------------------------------------------------ conferência dos links
class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        for k in ("href", "src"):
            if k in a and a[k]:
                self.refs.append(a[k])


def check(out):
    pages = {}
    for d, _, files in os.walk(out):
        for f in files:
            if f.endswith(".html"):
                path = os.path.join(d, f)
                lp = Links()
                with open(path, encoding="utf-8") as fh:
                    lp.feed(fh.read())
                pages[os.path.normpath(path)] = lp
    bad = []
    for path, lp in pages.items():
        if path.endswith("404.html"):
            continue  # caminhos absolutos do Pages
        for ref in lp.refs:
            if re.match(r"^[a-z]+:", ref) or ref.startswith("//"):
                continue
            target, _, frag = ref.partition("#")
            tpath = os.path.normpath(os.path.join(os.path.dirname(path), unquote(target))) if target else path
            if os.path.isdir(tpath):
                tpath = os.path.join(tpath, "index.html")
            if not os.path.exists(tpath):
                bad.append(f"{os.path.relpath(path, out)}: {ref} (não existe)")
            elif frag and tpath.endswith(".html") and unquote(frag) not in pages[os.path.normpath(tpath)].ids:
                bad.append(f"{os.path.relpath(path, out)}: {ref} (âncora não existe)")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(TOP, "_site"))
    args = ap.parse_args()
    site = build(args.out)
    bad = check(args.out)
    n = sum(1 for _ in site.pages) + len(LANGS)
    if bad:
        print(f"{len(bad)} link(s) quebrado(s):", *bad, sep="\n  ", file=sys.stderr)
        sys.exit(1)
    print(f"ok: {n} páginas em {args.out}")


if __name__ == "__main__":
    main()
