// Página de convite: o convite vem depois do # (#i=telinha%3A%2F%2F...), que o
// navegador nunca manda pro servidor. Abre o app pelo telinha://, copia o
// convite e mostra como instalar no sistema de quem abriu. Sem rede nenhuma.
(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const m = /(?:^#|&)i=([^&]*)/.exec(location.hash);
  let inv = '';
  try { inv = m ? decodeURIComponent(m[1]) : ''; } catch (e) { inv = ''; }
  const ok = /^telinha:\/\/[^\s<>"']+$/.test(inv);
  $('inv-ok').hidden = !ok;
  $('inv-bad').hidden = ok || !location.hash;
  if (ok) {
    $('inv-open').href = inv;
    const addrs = inv.slice('telinha://'.length).split(/[/!#]/)[0];
    const pt = document.documentElement.lang.startsWith('pt');
    $('inv-where').textContent = (pt ? 'Sala: ' : 'Room: ') + addrs.split(',').join(pt ? ' ou ' : ' or ');
    $('inv-copy').onclick = () => {
      const done = () => { $('inv-copy').classList.add('primary'); };
      if (navigator.clipboard) navigator.clipboard.writeText(inv).then(done, () => {});
    };
  }
  // o sistema de quem abriu: mostra só o jeito de instalar dele
  const ua = navigator.userAgent;
  const os = /Windows/i.test(ua) ? 'windows' : /Android|iPhone|iPad/i.test(ua) ? 'mobile' : /Linux|X11/i.test(ua) ? 'linux' : 'other';
  document.querySelectorAll('[data-os-box]').forEach((el) => { el.hidden = el.dataset.osBox !== os; });
  // trocar de idioma não perde o convite
  document.querySelectorAll('.lang-switch').forEach((a) => { a.href = a.getAttribute('href').split('#')[0] + location.hash; });
})();
