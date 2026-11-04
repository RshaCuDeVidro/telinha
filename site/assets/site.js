// telinha — o pouco de JavaScript do site (tudo funciona sem ele, menos a busca).
(function () {
  'use strict';
  const root = document.documentElement;
  const $ = (s, el) => (el || document).querySelector(s);
  const $$ = (s, el) => Array.from((el || document).querySelectorAll(s));
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* sem armazenamento: só nesta página */ } },
  };
  const T = window.TELINHA || { lang: 'pt', base: './', t: {} };
  const t = (k) => T.t[k] || k;

  // ---------------------------------------------------- canais (os temas do app)
  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (calm) root.classList.add('calm');
  const channels = T.channels || [];
  const chIndex = () => Math.max(0, channels.findIndex((c) => c.id === root.dataset.theme));
  const chLabel = (i) => 'CH ' + String(i).padStart(2, '0');
  function paintChannel() {
    const i = chIndex();
    $$('[data-ch-now]').forEach((el) => { el.textContent = chLabel(i); });
    $$('[data-channel]').forEach((el) => { el.classList.toggle('on', el.dataset.channel === root.dataset.theme); el.setAttribute('aria-pressed', el.dataset.channel === root.dataset.theme); });
    const meta = $('meta[name="theme-color"]');
    if (meta) meta.content = getComputedStyle(root).getPropertyValue('--bg').trim() || meta.content;
  }
  // o chiado: uma tela pequena esticada, sorteada por uns poucos quadros e depois some
  let zapCv = null;
  function zap(apply) {
    if (calm) { apply(); return; }
    if (!zapCv) { zapCv = document.createElement('canvas'); zapCv.className = 'zap'; zapCv.width = 128; zapCv.height = 72; document.body.append(zapCv); }
    const g = zapCv.getContext('2d'); const img = g.createImageData(128, 72); const px = new Uint32Array(img.data.buffer);
    const t0 = performance.now(); let applied = false;
    (function frame(now) {
      const p = (now - t0) / 280;
      if (!applied && p >= 0.4) { applied = true; apply(); }
      if (p >= 1) { zapCv.style.opacity = 0; return; }
      for (let i = 0; i < px.length; i++) { const v = Math.random() * 255 | 0; px[i] = 0xff000000 | (v << 16) | (v << 8) | v; }
      g.putImageData(img, 0, 0);
      zapCv.style.opacity = p < 0.55 ? 0.94 : 0.94 * (1 - (p - 0.55) / 0.45);
      requestAnimationFrame(frame);
    })(t0);
  }
  let osd = null;
  function showOsd(i) {
    if (!osd) { osd = document.createElement('div'); osd.className = 'osd'; osd.setAttribute('aria-hidden', 'true'); document.body.append(osd); }
    osd.innerHTML = chLabel(i) + '<small></small>'; osd.lastChild.textContent = channels[i].name;
    osd.classList.remove('show'); void osd.offsetWidth; osd.classList.add('show');
  }
  function tune(i) {
    i = (i + channels.length) % channels.length;
    if (channels[i].id === root.dataset.theme) { showOsd(i); return; }
    zap(() => {
      root.dataset.theme = channels[i].id;
      store.set('telinha-theme', channels[i].id);
      paintChannel(); showOsd(i);
      dispatchEvent(new CustomEvent('telinha-channel', { detail: channels[i] }));
    });
  }
  $$('[data-ch-step]').forEach((b) => b.addEventListener('click', () => tune(chIndex() + Number(b.dataset.chStep))));
  $$('[data-channel]').forEach((b) => b.addEventListener('click', () => tune(channels.findIndex((c) => c.id === b.dataset.channel))));
  // como num controle remoto: as teclas 0 a 6 mudam de canal
  addEventListener('keydown', (e) => {
    if (e.ctrlKey || e.metaKey || e.altKey || !/^[0-9]$/.test(e.key) || /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) return;
    if (channels[Number(e.key)]) tune(Number(e.key));
  });
  paintChannel();
  // escolheu o idioma no seletor: a raiz não redireciona mais
  $$('.lang-switch').forEach((a) => a.addEventListener('click', () => store.set('telinha-lang', a.dataset.lang)));

  // ---------------------------------------------------- barra de progresso e "voltar ao topo"
  const bar = $('.scroll-progress');
  const top = $('.tk-top-btn');
  let ticking = false;
  function onScroll() {
    ticking = false;
    const h = document.documentElement.scrollHeight - innerHeight;
    if (bar) bar.style.transform = 'scaleX(' + (h > 0 ? scrollY / h : 0) + ')';
    if (top) top.classList.toggle('show', scrollY > 700);
    spy();
  }
  addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(onScroll); } }, { passive: true });
  if (top) top.addEventListener('click', () => scrollTo({ top: 0, behavior: 'smooth' }));

  // ---------------------------------------------------- índice da página acompanha a rolagem
  const tocLinks = $$('.toc-link');
  const heads = tocLinks.map((a) => document.getElementById(decodeURIComponent(a.hash.slice(1)))).filter(Boolean);
  function spy() {
    if (!heads.length) return;
    let cur = heads[0];
    for (const h of heads) { if (h.getBoundingClientRect().top < 120) cur = h; else break; }
    tocLinks.forEach((a) => a.classList.toggle('active', decodeURIComponent(a.hash.slice(1)) === cur.id));
  }

  // ---------------------------------------------------- copiar código
  function copyText(text, btn) {
    const done = () => { btn.textContent = t('copied'); btn.classList.add('copied'); setTimeout(() => { btn.textContent = t('copy'); btn.classList.remove('copied'); }, 1600); };
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, () => {});
    else {
      const ta = document.createElement('textarea'); ta.value = text; document.body.append(ta); ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { /* nada */ }
      ta.remove();
    }
  }
  $$('.markdown-body pre, .lang-panel pre').forEach((pre) => {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'code-copy-btn'; b.textContent = t('copy');
    b.addEventListener('click', () => {
      const code = $('code', pre) || pre;
      // sem o "$ " do prompt e sem os comentários de explicação
      const text = Array.from(code.childNodes).filter((n) => !(n.classList && (n.classList.contains('ps') || n.classList.contains('gp')))).map((n) => n.textContent).join('');
      copyText(text.replace(/\n+$/, ''), b);
    });
    pre.append(b);
  });

  // ---------------------------------------------------- abas do terminal (instalar)
  $$('.terminal').forEach((term) => {
    const tabs = $$('.lang-tab', term);
    tabs.forEach((tab) => tab.addEventListener('click', () => {
      tabs.forEach((x) => { x.classList.toggle('active', x === tab); x.setAttribute('aria-selected', x === tab); });
      $$('.lang-panel', term).forEach((p) => { p.hidden = p.id !== tab.getAttribute('aria-controls'); });
    }));
  });

  // ---------------------------------------------------- download certo pro sistema de quem visita
  const ua = navigator.userAgent;
  const os = /Windows/i.test(ua) ? 'windows' : /Android|iPhone|iPad/i.test(ua) ? 'mobile' : /Linux|X11/i.test(ua) ? 'linux' : 'other';
  $$('[data-os]').forEach((el) => { if (el.dataset.os === os) el.classList.add('primary'); });
  const mainTab = $('.lang-tab[data-os-tab="' + os + '"]');
  if (mainTab) mainTab.click();

  // ---------------------------------------------------- menu no celular
  const menuBtn = $('.menu-btn');
  const mnav = $('#mobile-nav');
  if (menuBtn && mnav) menuBtn.addEventListener('click', () => {
    mnav.hidden = !mnav.hidden;
    menuBtn.setAttribute('aria-expanded', String(!mnav.hidden));
  });

  // ---------------------------------------------------- gaveta no celular
  const drawerBtn = $('.tk-drawer-btn');
  const overlay = $('.tk-drawer-overlay');
  if (drawerBtn) drawerBtn.addEventListener('click', () => document.body.classList.toggle('drawer-open'));
  if (overlay) overlay.addEventListener('click', () => document.body.classList.remove('drawer-open'));
  $$('.tk-sidebar a').forEach((a) => a.addEventListener('click', () => document.body.classList.remove('drawer-open')));

  // ---------------------------------------------------- busca (Ctrl+K ou /)
  const ov = $('.search-overlay');
  if (!ov) return;
  const input = $('input', ov);
  const results = $('.search-results', ov);
  let index = null;
  let sel = 0;
  let items = [];

  function norm(s) { return s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, ''); }
  function esc(s) { return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
  function mark(text, terms) {
    // realça os termos sem mexer nos acentos do texto original
    const n = norm(text);
    const spans = [];
    for (const term of terms) {
      let i = n.indexOf(term);
      while (i >= 0 && term) { spans.push([i, i + term.length]); i = n.indexOf(term, i + term.length); }
    }
    spans.sort((a, b) => a[0] - b[0]);
    let out = ''; let at = 0;
    for (const [a, b] of spans) { if (a < at) continue; out += esc(text.slice(at, a)) + '<mark>' + esc(text.slice(a, b)) + '</mark>'; at = b; }
    return out + esc(text.slice(at));
  }
  function excerpt(text, terms) {
    const n = norm(text);
    let i = -1;
    for (const term of terms) { i = n.indexOf(term); if (i >= 0) break; }
    const from = Math.max(0, i - 50);
    const s = (from > 0 ? '…' : '') + text.slice(from, from + 170) + (from + 170 < text.length ? '…' : '');
    return mark(s, terms);
  }
  function render() {
    const q = norm(input.value.trim());
    if (!index) { results.innerHTML = '<div class="search-empty">' + esc(t('loading')) + '</div>'; return; }
    if (!q) { results.innerHTML = '<div class="search-empty">' + esc(t('searchHint')) + '</div>'; items = []; return; }
    const terms = q.split(/\s+/).filter(Boolean);
    const scored = [];
    for (const e of index) {
      const title = norm(e.title); const page = norm(e.page); const body = e._n || (e._n = norm(e.text));
      let score = 0; let ok = true;
      for (const term of terms) {
        const inT = title.includes(term); const inP = page.includes(term); const inB = body.includes(term);
        if (!inT && !inP && !inB) { ok = false; break; }
        score += (inT ? 10 : 0) + (inP ? 4 : 0) + (inB ? 1 : 0);
      }
      if (ok) scored.push([score + (e.level === 1 ? 2 : 0), e]);
    }
    scored.sort((a, b) => b[0] - a[0]);
    items = scored.slice(0, 30).map((x) => x[1]);
    sel = 0;
    if (!items.length) { results.innerHTML = '<div class="search-empty">' + esc(t('noResults')) + '</div>'; return; }
    results.innerHTML = items.map((e, i) =>
      '<a class="tk-search-result' + (i === 0 ? ' sel' : '') + '" href="' + T.base + e.url + '">' +
      '<div class="tk-search-result-cat">' + esc(e.page) + '</div>' +
      '<div class="tk-search-result-title">' + mark(e.title, terms) + '</div>' +
      '<div class="tk-search-result-excerpt">' + excerpt(e.text, terms) + '</div></a>').join('');
  }
  function select(i) {
    const links = $$('.tk-search-result', results);
    if (!links.length) return;
    sel = (i + links.length) % links.length;
    links.forEach((l, k) => l.classList.toggle('sel', k === sel));
    links[sel].scrollIntoView({ block: 'nearest' });
  }
  function open() {
    ov.classList.add('open'); document.body.classList.remove('drawer-open');
    input.value = ''; render(); input.focus();
    if (!index) fetch(T.base + 'search-' + T.lang + '.json').then((r) => r.json()).then((d) => { index = d; render(); }).catch(() => {
      results.innerHTML = '<div class="search-empty">' + esc(t('searchFail')) + '</div>';
    });
  }
  function close() { ov.classList.remove('open'); }
  $$('.search-btn').forEach((b) => b.addEventListener('click', open));
  ov.addEventListener('click', (e) => { if (e.target === ov) close(); });
  input.addEventListener('input', render);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); select(sel + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); select(sel - 1); }
    else if (e.key === 'Enter') { const l = $$('.tk-search-result', results)[sel]; if (l) location.href = l.href; }
  });
  addEventListener('keydown', (e) => {
    const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName) || document.activeElement.isContentEditable;
    if ((e.key === 'k' && (e.ctrlKey || e.metaKey)) || (e.key === '/' && !typing)) { e.preventDefault(); open(); }
    else if (e.key === 'Escape') { close(); document.body.classList.remove('drawer-open'); if (mnav) mnav.hidden = true; }
  });
})();
