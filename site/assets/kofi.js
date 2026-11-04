// O botão do Ko-fi. É script de terceiro: só entra depois da página pronta, pra não
// atrasar nada, e o build não põe nem na página de convite nem no 404 (o convite, com
// a senha, fica no # da URL, e script de fora nenhum precisa ler isso).
(function () {
  'use strict';
  function load() {
    const s = document.createElement('script');
    s.src = 'https://storage.ko-fi.com/cdn/scripts/overlay-widget.js';
    s.onload = () => window.kofiWidgetOverlay.draw('reeshasx', {
      type: 'floating-chat',
      'floating-chat.donateButton.text': 'Tip Me',
      'floating-chat.donateButton.background-color': '#00b9fe',
      'floating-chat.donateButton.text-color': '#fff',
    });
    document.body.append(s);
  }
  const later = () => { if (window.requestIdleCallback) requestIdleCallback(load, { timeout: 3000 }); else setTimeout(load, 1500); };
  if (document.readyState === 'complete') later(); else addEventListener('load', later);
})();
