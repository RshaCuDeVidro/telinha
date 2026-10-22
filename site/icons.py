"""Ícones do site: traço fino, 24×24, desenhados aqui (sem biblioteca de
terceiros). Vão uma vez por página num <svg> escondido (sprite) e cada uso
é um <use href="#i-nome">; a cor vem do texto (currentColor).
"""

PATHS = {
    "search": '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
    "sun": '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4"/>',
    "moon": '<path d="M20 14.2A8.2 8.2 0 1 1 9.8 4a6.6 6.6 0 0 0 10.2 10.2z"/>',
    "crt": '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M6.5 8h11M6.5 10.5h11M6.5 13h11M9 21h6M12 17v4"/>',
    "menu": '<path d="M4 7h16M4 12h16M4 17h16"/>',
    "close": '<path d="M6 6l12 12M18 6L6 18"/>',
    "arrow-up": '<path d="M12 19V5M6 11l6-6 6 6"/>',
    "arrow-right": '<path d="M5 12h14M13 6l6 6-6 6"/>',
    "edit": '<path d="M4 20h4.2L19 9.2 14.8 5 4 15.8V20z"/><path d="M13.3 6.5l4.2 4.2"/>',
    "file": '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5z"/><path d="M14 3v5h5M10 12.5l-2 2 2 2M14 12.5l2 2-2 2"/>',
    "external": '<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
    "zap": '<path d="M13 2.5L4.5 13.5H11l-1 8 8.5-11H12l1-8z"/>',
    "link": '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    "lock": '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7.5a4 4 0 0 1 8 0V11M12 15v2"/>',
    "feather": '<path d="M20 4c-7 0-12 4.5-12.5 11.5L5 20"/><path d="M20 4c0 7-4.5 11.5-12 11.5M9.5 14.5h5"/>',
    "box": '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
    "refresh": '<path d="M20 11a8 8 0 0 0-14.5-4.5L4 8"/><path d="M4 3.5V8h4.5"/><path d="M4 13a8 8 0 0 0 14.5 4.5L20 16"/><path d="M20 20.5V16h-4.5"/>',
    "monitor": '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
    "eye": '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
    "mic": '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    "message": '<path d="M4 5h16v11H10l-6 4.5V5z"/><path d="M8 9.5h8M8 12.5h5"/>',
    "hash": '<path d="M4 9h16M4 15h16M10 3.5L8 20.5M16 3.5l-2 17"/>',
    "globe": '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9c-2.6-2.6-3.8-5.6-3.8-9S9.4 5.6 12 3z"/>',
    "cpu": '<rect x="6" y="6" width="12" height="12" rx="1.5"/><rect x="9.5" y="9.5" width="5" height="5"/><path d="M9 2.5V6M15 2.5V6M9 18v3.5M15 18v3.5M2.5 9H6M2.5 15H6M18 9h3.5M18 15h3.5"/>',
    "crown": '<path d="M3 8l4.5 4L12 5l4.5 7L21 8l-2 11H5L3 8z"/><path d="M5 15.5h14"/>',
    "bot": '<rect x="4" y="8" width="16" height="11" rx="3"/><path d="M12 8V4.5"/><circle cx="12" cy="3.5" r="1"/><circle cx="9" cy="13" r="1.2"/><circle cx="15" cy="13" r="1.2"/><path d="M9.5 16.5h5M2 12.5v3M22 12.5v3"/>',
    "music": '<path d="M9 18V5.5l11-2V16"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
    "terminal": '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M12.5 15H17"/>',
    "download": '<path d="M12 3.5v12M7 10.5l5 5 5-5M5 20.5h14"/>',
    "server": '<rect x="3.5" y="4" width="17" height="7" rx="1.5"/><rect x="3.5" y="13" width="17" height="7" rx="1.5"/><path d="M7 7.5h.01M7 16.5h.01M11 7.5h6M11 16.5h6"/>',
    "book": '<path d="M4 4.5A1.5 1.5 0 0 1 5.5 3H20v15H5.5A1.5 1.5 0 0 0 4 19.5v-15z"/><path d="M4 19.5A1.5 1.5 0 0 0 5.5 21H20M8 7.5h8M8 11h6"/>',
    "code": '<path d="M8 7l-5 5 5 5M16 7l5 5-5 5M13.5 4.5l-3 15"/>',
    "spark": '<path d="M12 3l1.8 5.4L19 10l-5.2 1.6L12 17l-1.8-5.4L5 10l5.2-1.6L12 3z"/><path d="M19 16.5l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7.7-2z"/>',
    "play": '<path d="M7 4.5v15l12-7.5-12-7.5z"/>',
    "check": '<path d="M5 12.5l4.5 4.5L19 7"/>',
    "copy": '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16H8"/>',
    "signal": '<path d="M4 20v-3M9 20v-7M14 20V9M19 20V4"/>',
    "radio": '<circle cx="12" cy="12" r="2"/><path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8"/>',
}

# marcas (preenchidas, não traço)
FILLED = {
    "github": ('0 0 16 16', '<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/>'),
    "windows": ('0 0 16 16', '<path d="M0 2.3 6.5 1.4v6.2H0zM7.3 1.3 16 0v7.6H7.3zM0 8.4h6.5v6.2L0 13.7zM7.3 8.4H16V16l-8.7-1.2z"/>'),
    "linux": ('0 0 16 16', '<path d="M8 0C6.3 0 5.4 1.5 5.4 3.4c0 1 .2 1.7-.3 2.6C4.4 7.2 3 8.7 3 11c0 .6.1 1.1.3 1.6-.5.3-1.3.5-1.3 1.2 0 .9 1.4.8 2.3 1.3.9.5 1.6 1 2.4.6.4-.2.7-.5.9-.5h1.6c.2 0 .5.3.9.5.8.4 1.5-.1 2.4-.6.9-.5 2.3-.4 2.3-1.3 0-.7-.8-.9-1.3-1.2.2-.5.3-1 .3-1.6 0-2.3-1.4-3.8-2.1-5-.5-.9-.3-1.6-.3-2.6C10.6 1.5 9.7 0 8 0zm-1.3 3c.4 0 .6.4.6.9s-.2.9-.6.9-.6-.4-.6-.9.2-.9.6-.9zm2.6 0c.4 0 .6.4.6.9s-.2.9-.6.9-.6-.4-.6-.9.2-.9.6-.9zM8 5.6c.7 0 1.6.4 1.6.8S8.7 7.3 8 7.3s-1.6-.5-1.6-.9.9-.8 1.6-.8z"/>'),
}


def sprite() -> str:
    syms = [f'<symbol id="i-{n}" viewBox="0 0 24 24">{p}</symbol>' for n, p in PATHS.items()]
    syms += [f'<symbol id="i-{n}" viewBox="{vb}">{p}</symbol>' for n, (vb, p) in FILLED.items()]
    return '<svg class="sprite" aria-hidden="true" focusable="false">' + "".join(syms) + "</svg>"


def icon(name: str, cls: str = "") -> str:
    kind = "i-fill" if name in FILLED else "i"
    if name not in PATHS and name not in FILLED:
        raise KeyError(f"ícone desconhecido: {name}")
    return f'<svg class="{kind}{(" " + cls) if cls else ""}" aria-hidden="true" focusable="false"><use href="#i-{name}"/></svg>'
