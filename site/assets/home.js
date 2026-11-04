// telinha — a sala de controle da página inicial. Sem nada disso a página continua
// inteira (o texto, os botões e a captura de tela já estão no HTML).
// Regra da casa: o que não está na tela não custa nada. Um laço só, que dorme quando
// a parede sai de vista; o resto é transform e opacity.
(function () {
  'use strict';
  const root = document.documentElement;
  const $ = (s, el) => (el || document).querySelector(s);
  const $$ = (s, el) => Array.from((el || document).querySelectorAll(s));
  const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const css = (name) => getComputedStyle(root).getPropertyValue(name).trim();
  const rand = (a, b) => a + Math.random() * (b - a);
  const lite = () => root.classList.contains('lite');

  // ---------------------------------------------------- o que entra na tela liga, o que sai para
  const seen = new IntersectionObserver((list) => {
    list.forEach((e) => {
      if (!e.isIntersecting) return;
      const group = e.target.parentElement ? $$(':scope > .rv, :scope > .power', e.target.parentElement) : [];
      const order = Math.max(0, group.indexOf(e.target));
      e.target.style.setProperty('--d', Math.min(order, 7) * 0.06 + 's');
      e.target.classList.add('on');
      seen.unobserve(e.target);
    });
  }, { rootMargin: '0px 0px -8% 0px' });
  $$('.rv, .power, .sec-head').forEach((el) => seen.observe(el));

  const pausing = new IntersectionObserver((list) => {
    list.forEach((e) => { if (e.isIntersecting) delete e.target.dataset.off; else e.target.dataset.off = ''; });
  }, { rootMargin: '80px' });
  $$('[data-hero], [data-ticker], [data-wire]').forEach((el) => pausing.observe(el));

  // ---------------------------------------------------- a faixa do topo: o relógio do programa
  const tc = $('[data-tc]');
  const hero = $('[data-hero]');
  const pad = (n) => String(n).padStart(2, '0');
  const t0 = performance.now();
  function tickTc() {
    if (hero.dataset.off !== undefined || document.hidden) return;
    const ms = performance.now() - t0; const s = ms / 1000;
    tc.textContent = pad(s / 3600 | 0) + ':' + pad((s / 60 | 0) % 60) + ':' + pad((s | 0) % 60) + ':' + pad((ms / (1000 / 30) | 0) % 30);
  }
  if (tc && !calm) setInterval(tickTc, 100);

  // o nome dá um tranco de sinal de vez em quando (duas cópias, só transform e opacity)
  const mega = $('[data-mega]');
  if (mega && !calm) {
    const ghosts = [0, 1].map((i) => {
      const g = document.createElement('span');
      g.className = 'mega-ghost' + (i ? ' two' : ''); g.textContent = 'telınha'; g.setAttribute('aria-hidden', 'true');
      mega.parentElement.append(g); return g;
    });
    const jolt = () => {
      if (hero.dataset.off === undefined && !document.hidden && !lite()) {
        ghosts.forEach((g, i) => {
          const d = i ? 1 : -1;
          g.animate([
            { opacity: 0.75, transform: `translate3d(${d * 9}px,0,0)` },
            { opacity: 0.55, transform: `translate3d(${d * -5}px,2px,0)` },
            { opacity: 0.8, transform: `translate3d(${d * 3}px,-1px,0)` },
            { opacity: 0, transform: 'translate3d(0,0,0)' },
          ], { duration: 240, easing: 'steps(4)' });
        });
      }
      setTimeout(jolt, rand(7000, 13000));
    };
    setTimeout(jolt, 3500);
  }

  // ---------------------------------------------------- a parede de telas
  const stage = $('[data-stage]');
  const scenes = $$('[data-scene]', stage);
  const ink = $('[data-ink]');
  const hud = $('[data-hud]');
  const hudWho = $('[data-hud-who]');
  const hudWhat = $('[data-hud-what]');
  const hint = $('[data-hint]');
  const penChip = $('[data-pen]');
  const flash = document.createElement('i'); flash.className = 'cut-flash'; stage.append(flash);
  let order = scenes.slice();
  let wallW = 0; let pgmH = 0; let lastCut = 0; let touched = false;
  const GAP = 8;

  function slotOf(i) {
    if (i === 0) return { x: 0, y: 0, s: wallW / 960 };
    const w = (wallW - GAP * 3) / 4;
    return { x: (i - 1) * (w + GAP), y: pgmH + GAP, s: w / 960 };
  }
  function place(animate) {
    order.forEach((sc, i) => {
      const { x, y, s } = slotOf(i);
      const to = `translate3d(${x}px,${y}px,0) scale(${s})`;
      if (animate && !calm && sc.dataset.at) {
        const a = sc.animate([{ transform: sc.dataset.at }, { transform: to }], { duration: 520, easing: 'cubic-bezier(.3,1.25,.45,1)' });
        a.onfinish = () => { sc.style.zIndex = ''; };
      }
      sc.dataset.at = to;
      sc.style.transform = to;
      sc.classList.toggle('pgm', i === 0);
      sc.setAttribute('aria-pressed', i === 0);
    });
  }
  function layout() {
    wallW = stage.clientWidth;
    pgmH = wallW * 9 / 16;
    const pre = ((wallW - GAP * 3) / 4) * 9 / 16;
    stage.style.height = pgmH + GAP + pre + 'px';
    stage.style.aspectRatio = 'auto';
    place(false);
    const dpr = Math.min(devicePixelRatio || 1, 2);
    ink.width = wallW * dpr; ink.height = pgmH * dpr;
    ink.style.width = wallW + 'px'; ink.style.height = pgmH + 'px';
    inkG.setTransform(dpr, 0, 0, dpr, 0, 0);
    hint.style.top = pgmH - 58 + 'px';
    flash.style.width = wallW + 'px'; flash.style.height = pgmH + 'px';
    dirty = true;
  }
  function cut(sc, byHand) {
    const i = order.indexOf(sc);
    if (i <= 0) return;
    if (byHand) touched = true;
    lastCut = performance.now();
    sc.style.zIndex = 5;
    [order[0], order[i]] = [order[i], order[0]];
    place(true);
    hudWho.textContent = sc.dataset.who;
    hudWhat.textContent = sc.dataset.what;
    strokes.length = 0; dirty = true;
    look(sc);
    if (!calm) flash.animate([{ opacity: 0.5 }, { opacity: 0 }], { duration: 200, easing: 'ease-out' });
  }
  scenes.forEach((sc) => {
    sc.setAttribute('aria-label', sc.dataset.who + ' · ' + sc.dataset.what);
    sc.addEventListener('click', () => cut(sc, true));
    sc.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); cut(sc, true); } });
  });

  // ---------------------------------------------------- riscar a transmissão
  const inkG = ink.getContext('2d');
  const strokes = [];
  let drawing = null; let dirty = false; let inkColor = css('--accent-2');
  const INK_MS = 2600;
  function inkAt(e) { const r = ink.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; }
  ink.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'touch') return; // no celular o dedo rola a página
    drawing = { pts: [inkAt(e)], born: performance.now(), hand: true };
    strokes.push(drawing); ink.setPointerCapture(e.pointerId);
    hint.classList.remove('show'); touched = true; game.jump();
  });
  ink.addEventListener('pointermove', (e) => { if (drawing) { drawing.pts.push(inkAt(e)); drawing.born = performance.now(); } });
  const stopDraw = () => { drawing = null; };
  ink.addEventListener('pointerup', stopDraw);
  ink.addEventListener('pointercancel', stopDraw);
  function drawInk(now) {
    if (!strokes.length && !dirty) return;
    dirty = false;
    inkG.clearRect(0, 0, wallW, pgmH);
    inkG.lineCap = inkG.lineJoin = 'round'; inkG.lineWidth = 4; inkG.strokeStyle = inkColor;
    for (let i = strokes.length - 1; i >= 0; i--) {
      const st = strokes[i]; const age = now - st.born;
      if (age > INK_MS && st !== drawing) { strokes.splice(i, 1); dirty = true; continue; }
      inkG.globalAlpha = age < INK_MS - 700 ? 1 : Math.max(0, (INK_MS - age) / 700);
      inkG.beginPath(); st.pts.forEach((p, k) => (k ? inkG.lineTo(p[0], p[1]) : inkG.moveTo(p[0], p[1]))); inkG.stroke();
    }
    inkG.globalAlpha = 1;
  }
  // a Bia passa a caneta sozinha de vez em quando, como no app
  let pen = null;
  function penPass() {
    const cx = wallW * rand(0.45, 0.62); const cy = pgmH * rand(0.35, 0.62);
    pen = { st: { pts: [], born: performance.now() }, cx, cy, rx: wallW * 0.13, ry: pgmH * 0.075, t0: performance.now() };
    strokes.push(pen.st); penChip.style.opacity = 1;
  }
  function drawPen(now) {
    if (!pen) return;
    const p = (now - pen.t0) / 1250;
    const a = -2.3 + Math.min(p, 1) * Math.PI * 2.15;
    const x = pen.cx + Math.cos(a) * pen.rx; const y = pen.cy + Math.sin(a) * pen.ry;
    pen.st.pts.push([x, y]); pen.st.born = now;
    penChip.style.transform = `translate3d(${x + 6}px,${y + 8}px,0)`;
    if (p >= 1) { pen = null; penChip.style.opacity = 0; }
  }

  // ---------------------------------------------------- a tela do Bruno: um joguinho de husky
  const game = (function () {
    const cv = $('[data-game]'); const g = cv.getContext('2d', { alpha: false });
    const W = 480; const H = 270; const GROUND = 226;
    const layer = (draw) => { const c = document.createElement('canvas'); c.width = W; c.height = H; draw(c.getContext('2d')); return c; };
    const hills = (x, base, amp, color, seed) => {
      x.fillStyle = color; x.beginPath(); x.moveTo(0, H);
      for (let i = 0; i <= W; i += 6) {
        const t = (i / W) * Math.PI * 2;
        x.lineTo(i, base - Math.round(Math.abs(Math.sin(t * 3 + seed)) * amp + Math.abs(Math.sin(t * 7 + seed * 2)) * amp * 0.34));
      }
      x.lineTo(W, H); x.fill();
    };
    const sky = layer((x) => {
      const grad = x.createLinearGradient(0, 0, 0, GROUND);
      grad.addColorStop(0, '#040a16'); grad.addColorStop(0.6, '#0a2036'); grad.addColorStop(1, '#154a5a');
      x.fillStyle = grad; x.fillRect(0, 0, W, H);
      for (let i = 0; i < 70; i++) { x.fillStyle = i % 7 ? '#8fb0c8' : '#fff'; x.fillRect((i * 97) % W, (i * 53) % 130, 1, 1); }
      for (let b = 0; b < 3; b++) {
        x.fillStyle = ['rgba(52,211,153,.2)', 'rgba(111,211,255,.15)', 'rgba(167,139,250,.12)'][b];
        for (let i = 0; i < W; i += 4) { const y = 28 + b * 15 + Math.sin(i / 42 + b) * 16; x.fillRect(i, y, 4, 26 + Math.sin(i / 20 + b) * 10); }
      }
      x.fillStyle = '#e8f2f8'; x.beginPath(); x.arc(392, 44, 15, 0, 7); x.fill();
      x.fillStyle = '#071425'; x.beginPath(); x.arc(385, 40, 13, 0, 7); x.fill();
    });
    const far = layer((x) => hills(x, 188, 46, '#10293c', 1.1));
    const near = layer((x) => hills(x, 214, 28, '#1a3d50', 2.6));
    const PAL = { d: '#39485c', w: '#eaf2f7', k: '#0a0d12', b: '#38bdf8', a: '#e8983a', r: '#ff5a6e' };
    const BODY = ['.............d...d..', '.............dd.dd..', '.............ddddd..', 'dd...........dbwawdk', '.dd..dddddddddwwwww.', '..ddddddddddddwwwr..', '...dddddddddddww....', '...dwwwwwwwwwwww....', '...dwwwwwwwwwwww....'];
    const LEGS = [['...dd.w.....dd.w....', '...d..w.....d..w....'], ['....dd.w...dd.w.....', '.....d.w....d.w.....'], ['...dd...w..dd...w...', '..d......w.d.....w..']];
    const sprite = (legs) => layer((x) => {
      BODY.concat(legs).forEach((row, y) => { for (let i = 0; i < row.length; i++) if (PAL[row[i]]) { x.fillStyle = PAL[row[i]]; x.fillRect(i * 3, y * 3, 3, 3); } });
    });
    const runA = sprite(LEGS[0]); const runB = sprite(LEGS[1]); const air = sprite(LEGS[2]);
    let dist = 0; let y = 0; let vy = 0; let score = 0; let rocks = [{ x: 500, w: 12, h: 14 }];
    const flakes = Array.from({ length: 34 }, (_, i) => ({ x: (i * 53) % W, y: (i * 31) % H, s: 0.5 + (i % 3) * 0.45 }));
    const jump = () => { if (y === 0) vy = -7.4; };
    const tile = (img, off) => { const o = -(off % W); g.drawImage(img, o, 0); g.drawImage(img, o + W, 0); };
    function step() {
      dist += 3.1; score += 1;
      vy += 0.5; y = Math.min(0, y + vy); if (y === 0) vy = 0;
      rocks.forEach((r) => { r.x -= 3.1; });
      if (rocks[0].x < -30) rocks.shift();
      const last = rocks[rocks.length - 1];
      if (last.x < W - 60 - Math.random() * 180) rocks.push({ x: W + 20, w: 9 + (Math.random() * 11 | 0), h: 10 + (Math.random() * 12 | 0) });
      if (rocks.some((r) => r.x > 124 && r.x < 158)) jump();
      g.drawImage(sky, 0, 0);
      tile(far, dist * 0.14); tile(near, dist * 0.32);
      g.fillStyle = '#d7e8f1'; g.fillRect(0, GROUND, W, H - GROUND);
      g.fillStyle = '#a9c4d3';
      for (let i = 0; i < 12; i++) g.fillRect(W - (((dist * 1) + i * 67) % (W + 30)), GROUND + 7 + (i * 13) % 34, 14 + (i % 4) * 6, 2);
      g.fillStyle = '#2a3546';
      rocks.forEach((r) => { g.fillRect(r.x, GROUND - r.h, r.w, r.h); g.fillStyle = '#eaf2f7'; g.fillRect(r.x, GROUND - r.h, r.w, 3); g.fillStyle = '#2a3546'; });
      g.drawImage(y < 0 ? air : (dist / 14 | 0) % 2 ? runA : runB, 68, GROUND - 33 + Math.round(y));
      g.fillStyle = '#fff';
      flakes.forEach((f) => { f.x -= f.s * 2.4; f.y += f.s; if (f.x < 0) f.x += W; if (f.y > H) f.y -= H; g.fillRect(f.x | 0, f.y | 0, 1 + (f.s > 1 ? 1 : 0), 1 + (f.s > 1 ? 1 : 0)); });
      g.fillStyle = '#0a0d12'; g.fillRect(12, 12, 92, 15);
      g.fillStyle = '#7ef0b3'; g.font = '500 11px "Fira Code", monospace'; g.fillText(String(score).padStart(6, '0') + ' m', 20, 23);
    }
    step();
    return { step, jump };
  })();

  // ---------------------------------------------------- telas que mudam devagar
  const data = JSON.parse($('#wall-data').textContent);
  const code = $('[data-scroll]');
  const lineH = 27; const codeLines = $$('.ln', code).length;
  let codeAt = 0;
  function stepCode() {
    codeAt = (codeAt + 1) % Math.max(1, codeLines - 15);
    code.style.transform = `translate3d(0,${-codeAt * lineH}px,0)`;
  }
  const chat = $('[data-chat]');
  let chatAt = 0;
  function stepChat() {
    const [who, color, text, react] = data.chat[chatAt++ % data.chat.length];
    const m = document.createElement('div'); m.className = 'rm-msg';
    const b = document.createElement('b'); b.textContent = who; b.style.color = color; m.append(b, text);
    if (react) { const u = document.createElement('u'); u.textContent = react; m.append(u); }
    chat.append(m);
    if (!calm) m.animate([{ opacity: 0, transform: 'translateY(10px)' }, { opacity: 1, transform: 'none' }], { duration: 240 });
    while (chat.children.length > 5) chat.firstChild.remove();
  }
  const term = $('[data-term]');
  let termLine = 0; let termChar = 0; let termCur = null;
  function stepTerm() {
    if (termLine >= data.term.length) { if (termChar++ > 14) { term.textContent = ''; termLine = 0; termChar = 0; termCur = null; } return; }
    const [cls, text] = data.term[termLine];
    if (!termCur) { termCur = document.createElement('span'); termCur.className = cls; term.append(termCur); termChar = 0; }
    if (cls === 't-cmd') {
      termChar = Math.min(text.length, termChar + 2);
      termCur.textContent = text.slice(0, termChar);
      if (termChar < text.length) return;
    } else termCur.textContent = text;
    termCur = null; termLine++;
  }

  // ---------------------------------------------------- o husky
  const husky = $('.husky.on-wall');
  const huskyHead = $('.husky-head', husky);
  const looks = $$('.h-look', huskyHead);
  const eyes = $('.h-eyes', huskyHead);
  const ears = $$('.h-ear', huskyHead);
  function look(el) {
    if (calm || lite()) return;
    const h = husky.getBoundingClientRect(); const r = el.getBoundingClientRect();
    aimEyes(r.left + r.width / 2 - (h.left + h.width / 2), r.top + r.height / 2 - (h.top + h.height / 2));
  }
  function aimEyes(dx, dy) {
    const d = Math.hypot(dx, dy) || 1; const m = Math.min(1, d / 180);
    const x = (dx / d) * 3.4 * m; const y = (dy / d) * 2.6 * m;
    looks.forEach((l) => l.setAttribute('transform', `translate(${x.toFixed(2)} ${y.toFixed(2)})`));
    huskyHead.style.transform = peeking ? `rotate(${(Math.max(-1, Math.min(1, dx / 500)) * 5).toFixed(2)}deg)` : huskyHead.style.transform;
  }
  let peeking = false;
  let pointer = null; let pointerQueued = false;
  addEventListener('pointermove', (e) => {
    if (calm || e.pointerType === 'touch') return;
    pointer = e;
    if (pointerQueued) return;
    pointerQueued = true;
    requestAnimationFrame(() => {
      pointerQueued = false;
      if (hero.dataset.off !== undefined || lite()) return;
      const r = husky.getBoundingClientRect();
      aimEyes(pointer.clientX - (r.left + r.width / 2), pointer.clientY - (r.top + r.height * 0.5));
    });
  }, { passive: true });
  function blink() {
    if (hero.dataset.off === undefined && !document.hidden) {
      eyes.animate([{ transform: 'scaleY(1)' }, { transform: 'scaleY(.06)' }, { transform: 'scaleY(1)' }], { duration: 170, easing: 'ease-in-out' });
    }
    setTimeout(blink, rand(2400, 6200));
  }
  function twitch() {
    if (hero.dataset.off === undefined && !document.hidden) {
      const ear = ears[Math.random() * 2 | 0]; const d = ear.classList.contains('h-ear-l') ? -1 : 1;
      ear.animate([{ transform: 'rotate(0)' }, { transform: `rotate(${d * 11}deg)` }, { transform: `rotate(${d * -3}deg)` }, { transform: 'rotate(0)' }], { duration: 320, easing: 'ease-out' });
    }
    setTimeout(twitch, rand(3200, 8000));
  }
  function peekIn() {
    huskyHead.style.transform = 'translateY(75%)';
    $('.husky-paws', husky).style.opacity = 0;
    setTimeout(() => {
      huskyHead.style.transform = 'translateY(0)';
      $('.husky-paws', husky).style.transition = 'opacity .2s';
      $('.husky-paws', husky).style.opacity = 1;
      setTimeout(() => { peeking = true; }, 500);
    }, 750);
  }
  function hearts(host, n) {
    for (let i = 0; i < n; i++) {
      const h = document.createElement('span'); h.className = 'heart'; h.textContent = '❤'; h.setAttribute('aria-hidden', 'true');
      h.style.left = rand(24, 66) + '%'; h.style.top = '12%'; host.append(h);
      const dx = rand(-34, 34);
      h.animate([{ opacity: 0, transform: 'translate(0,10px) scale(.5)' }, { opacity: 1, transform: `translate(${dx * 0.4}px,-30px) scale(1.1)`, offset: 0.25 }, { opacity: 0, transform: `translate(${dx}px,-110px) scale(.8)` }], { duration: 950 + i * 130, easing: 'ease-out', delay: i * 70, fill: 'backwards' }).onfinish = () => h.remove();
    }
  }
  husky.addEventListener('click', () => {
    if (calm) return;
    hearts(husky, 4);
    peeking = false;
    huskyHead.style.transform = 'translateY(26%) rotate(-3deg)';
    setTimeout(() => { huskyHead.style.transform = 'none'; peeking = true; }, 260);
    ears.forEach((ear, i) => ear.animate([{ transform: 'rotate(0)' }, { transform: `rotate(${i ? 12 : -12}deg)` }, { transform: 'rotate(0)' }], { duration: 300, iterations: 2 }));
  });

  // ---------------------------------------------------- o laço (só com a parede na tela)
  let wallOn = true; let lastGame = 0; let lastSlow = 0; let lastPen = performance.now() + 4000; let slowN = 0;
  function loop(now) {
    if (!wallOn || document.hidden) { running = false; return; }
    requestAnimationFrame(loop);
    if (now - lastGame >= 50 && !lite()) { lastGame = now; game.step(); }
    drawPen(now); drawInk(now);
    if (now - lastSlow >= 340) {
      lastSlow = now; slowN++;
      stepTerm();
      if (slowN % 3 === 0) stepCode();
      if (slowN % 9 === 0) stepChat();
    }
    if (!touched && now - lastCut > 7200) cut(order[1 + (Math.random() * 4 | 0)], false);
    if (!lite() && !pen && now - lastPen > 12500) { lastPen = now; penPass(); }
  }
  let running = false;
  function wake() { if (!running && wallOn && !document.hidden) { running = true; requestAnimationFrame(loop); } }
  new IntersectionObserver((l) => { wallOn = l[0].isIntersecting; wake(); }, { rootMargin: '60px' }).observe(stage);
  document.addEventListener('visibilitychange', wake);
  new ResizeObserver(layout).observe(stage);
  addEventListener('telinha-channel', () => { inkColor = css('--accent-2'); labColors(); });

  layout();
  stepChat(); stepChat(); stepChat(); stepTerm(); stepTerm();
  if (calm) {
    data.term.forEach(() => stepTerm());
  } else {
    lastCut = performance.now();
    peekIn(); setTimeout(blink, 2000); setTimeout(twitch, 2600);
    if (matchMedia('(hover: hover)').matches) setTimeout(() => { if (!touched) { hint.classList.add('show'); setTimeout(() => hint.classList.remove('show'), 4200); } }, 2200);
    wake();
  }

  // ---------------------------------------------------- sinta o atraso: duas telas, um risco só
  const lab = $('[data-lab]');
  let labColors = () => {};
  if (lab) {
    const A = $('[data-lab-a]', lab); const B = $('[data-lab-b]', lab);
    const ga = A.getContext('2d'); const gb = B.getContext('2d');
    const val = $('[data-lab-val]', lab);
    let delay = 17; let pts = []; let W2 = 0; let H2 = 0; let onScreen = false; let handUntil = 0; let color = css('--accent-text');
    let down = false;
    labColors = () => { color = css('--accent-text'); };
    const size = () => {
      // clientWidth, não getBoundingClientRect: a tela ainda pode estar "ligando" (achatada pelo transform)
      const dpr = Math.min(devicePixelRatio || 1, 2);
      W2 = A.clientWidth; H2 = A.clientHeight;
      [A, B].forEach((c) => { c.width = W2 * dpr; c.height = H2 * dpr; c.getContext('2d').setTransform(dpr, 0, 0, dpr, 0, 0); });
    };
    const LIFE = 2400;
    function paint(g, now, lag) {
      g.clearRect(0, 0, W2, H2);
      g.lineCap = g.lineJoin = 'round'; g.lineWidth = 3; g.strokeStyle = color; g.fillStyle = color;
      let prev = null; let head = null;
      for (const p of pts) {
        const shown = p.t + lag;
        if (shown > now) break;
        head = p;
        const age = now - shown;
        if (prev && !p.pen && age < LIFE) {
          g.globalAlpha = 1 - age / LIFE;
          g.beginPath(); g.moveTo(prev.x * W2, prev.y * H2); g.lineTo(p.x * W2, p.y * H2); g.stroke();
        }
        prev = p;
      }
      g.globalAlpha = 1;
      if (head) { g.beginPath(); g.arc(head.x * W2, head.y * H2, 6, 0, 7); g.fill(); }
    }
    function pathAuto(now) {
      if (now < handUntil) return;
      const t = now / 1000;
      pts.push({ x: 0.5 + Math.sin(t * 1.9) * 0.36, y: 0.5 + Math.sin(t * 3.1 + 0.7) * 0.32, t: now });
    }
    function labLoop(now) {
      if (!onScreen || document.hidden) { labRun = false; return; }
      requestAnimationFrame(labLoop);
      if (!calm) pathAuto(now);
      const cut0 = now - LIFE - delay - 100;
      while (pts.length && pts[0].t < cut0) pts.shift();
      paint(ga, now, 0); paint(gb, now, delay);
    }
    let labRun = false;
    const labWake = () => { if (!labRun && onScreen && !document.hidden) { labRun = true; requestAnimationFrame(labLoop); } };
    function hand(e, pen) {
      pts.push({ x: e.offsetX / A.clientWidth, y: e.offsetY / A.clientHeight, t: performance.now(), pen });
      handUntil = performance.now() + 1600;
      lab.classList.add('touched');
    }
    A.addEventListener('pointerenter', (e) => { if (e.pointerType !== 'touch') hand(e, true); });
    A.addEventListener('pointermove', (e) => { if (e.pointerType !== 'touch' || down) hand(e, false); });
    A.addEventListener('pointerdown', (e) => { down = true; hand(e, true); });
    addEventListener('pointerup', () => { down = false; });
    A.addEventListener('pointerleave', () => { handUntil = performance.now() + 400; });
    $$('[data-ms]', lab).forEach((b) => b.addEventListener('click', () => {
      delay = Number(b.dataset.ms);
      val.textContent = delay >= 1000 ? delay / 1000 + ' s' : delay + ' ms';
      $$('[data-ms]', lab).forEach((x) => x.classList.toggle('on', x === b));
    }));
    new IntersectionObserver((l) => { onScreen = l[0].isIntersecting; if (onScreen) size(); labWake(); }).observe(lab);
    new ResizeObserver(size).observe(A);
    document.addEventListener('visibilitychange', labWake);
  }

  // ---------------------------------------------------- o caminho do quadro, em câmera lenta
  const wire = $('[data-wire]');
  if (wire && !calm) {
    const steps = $$('li', wire);
    let hot = 0;
    setInterval(() => {
      if (wire.dataset.off !== undefined || document.hidden) return;
      steps.forEach((s, i) => s.classList.toggle('hot', i === hot));
      hot = (hot + 1) % (steps.length + 1);
    }, 420);
  }

  // ---------------------------------------------------- a corrida do convite
  const race = $('[data-race]');
  if (race) {
    // ms até responder (só pra ver a corrida: câmera lenta); null = não responde nunca
    const CASES = {
      home: { lan: 420, port: 1500, ipv6: 1250, pub: 2300 },
      far: { lan: null, port: 900, ipv6: null, pub: 1900 },
      cgnat: { lan: null, port: null, ipv6: null, pub: 1500 },
    };
    const rows = $$('[data-route]', race);
    const out = $('[data-race-out]', race);
    const tabs = $$('[data-case]', race);
    const parts = $$('[data-part]', race);
    let anims = []; let timer = 0; let auto = true; let visible = false; let current = 'home';
    function run(name) {
      clearTimeout(timer); anims.forEach((a) => a.cancel()); anims = [];
      current = name;
      tabs.forEach((t) => t.classList.toggle('on', t.dataset.case === name));
      rows.forEach((r) => { r.className = ''; $('em', r).textContent = '…'; });
      parts.forEach((p) => { p.className = 'lit'; });
      out.textContent = '';
      const times = CASES[name];
      const win = Object.keys(times).filter((k) => times[k] !== null).sort((a, b) => times[a] - times[b])[0];
      const T = times[win];
      rows.forEach((r) => {
        const key = r.dataset.route; const t = times[key];
        const bar = $('i', r);
        const end = t === null ? 0.32 : Math.min(1, T / t);
        if (calm) { bar.style.transform = `scaleX(${end})`; return; }
        const a = bar.animate([{ transform: 'scaleX(0)' }, { transform: `scaleX(${end})` }], { duration: t === null ? T * 0.95 : T, easing: 'linear', fill: 'forwards' });
        anims.push(a);
      });
      timer = setTimeout(() => {
        rows.forEach((r) => {
          const key = r.dataset.route; const em = $('em', r);
          if (key === win) { r.className = 'won'; em.textContent = em.dataset.note; }
          else if (times[key] === null) { r.className = 'lost'; em.textContent = out.dataset.lost; }
          else { r.className = 'stop'; em.textContent = out.dataset.stop; }
        });
        parts.forEach((p) => { p.className = p.dataset.part === win ? 'won' : ''; });
        out.textContent = '→ ' + out.dataset.win + ' ' + $('b', rows.find((r) => r.dataset.route === win)).textContent;
        const next = Object.keys(CASES)[(Object.keys(CASES).indexOf(name) + 1) % 3];
        if (auto && !calm) timer = setTimeout(() => { if (visible && !document.hidden) run(next); else { pendingRace = next; } }, 2600);
      }, calm ? 0 : T);
    }
    let pendingRace = null;
    tabs.forEach((t) => t.addEventListener('click', () => { auto = false; run(t.dataset.case); }));
    new IntersectionObserver((l) => {
      const was = visible; visible = l[0].isIntersecting;
      if (visible && !was) { const n = pendingRace || current; pendingRace = null; run(n); }
    }, { threshold: 0.25 }).observe(race);
  }

  // ---------------------------------------------------- ver a captura em tamanho grande
  const box = $('[data-zoom-box]');
  if (box && box.showModal) {
    const img = $('img', box);
    $$('[data-zoom]').forEach((b) => b.addEventListener('click', () => {
      const src = $('img', b); img.src = src.currentSrc || src.src; img.alt = src.alt; box.showModal();
    }));
    box.addEventListener('click', (e) => { if (e.target === box) box.close(); });
  }

  // ---------------------------------------------------- o outro husky, dormindo no fim da página
  const sleeper = $('.husky.asleep');
  if (sleeper) sleeper.addEventListener('click', () => { if (!calm) hearts(sleeper, 3); });

  // ---------------------------------------------------- navegador sem fôlego: menos efeitos
  if (!calm && !/[?&]fx=full/.test(location.search)) {
    let slow = 0; let rounds = 0;
    const sample = () => {
      if (lite() || rounds++ > 4 || document.hidden) return;
      let n = 0; const start = performance.now();
      (function f(now) {
        n++;
        if (now - start < 1000) { requestAnimationFrame(f); return; }
        slow = n < 28 ? slow + 1 : 0;
        if (slow >= 2) root.classList.add('lite'); else setTimeout(sample, 3000);
      })(start);
    };
    setTimeout(sample, 1800);
  }
})();
