// telinha no navegador: assiste quem está transmitindo na sala e conversa no
// chat. Fala o mesmo protocolo do app (src/proto.zig), por WebSocket (o
// HTTPS na frente cifra). Decodifica com o WebCodecs (na placa de vídeo,
// quando dá) e manda a confirmação de cada quadro na hora, como o app: o
// servidor sabe quando este navegador não dá conta e se ajusta.
'use strict';

// ------------------------------------------------------------- textos
const PT = {
  join_title: 'Assistir pelo navegador', join_sub: 'Sem instalar nada. Pra transmitir e falar, use o app do telinha.',
  name: 'Seu nome', pass: 'Senha da sala', join: 'Entrar', people: 'NA SALA', chat: 'CHAT',
  connecting: 'conectando...', online: 'conectado', offline: 'desconectado, tentando de novo...',
  nobody: 'Ninguém está transmitindo agora. Quando alguém começar, aparece aqui.',
  sound_on: '🔊 Ativar som', sound_off: '🔇 Sem som', send_ph: 'Mensagem',
  wrong_pass: 'Senha errada.', nosupport: 'Este navegador não decodifica vídeo pelo WebCodecs. Use o Chrome, Edge, Firefox (130+) ou Safari (16.4+) atualizados.',
  insecure: 'A página precisa ser aberta por https:// pra mostrar o vídeo.',
  waiting_key: 'esperando o primeiro quadro...', image: '[imagem]', screen: 'tela', camera: 'câmera',
  you: '(você)', live: 'AO VIVO',
};
const EN = {
  join_title: 'Watch in your browser', join_sub: 'Nothing to install. To stream and talk, use the telinha app.',
  name: 'Your name', pass: 'Room password', join: 'Join', people: 'IN THE ROOM', chat: 'CHAT',
  connecting: 'connecting...', online: 'connected', offline: 'disconnected, retrying...',
  nobody: 'Nobody is streaming right now. When someone starts, it shows up here.',
  sound_on: '🔊 Turn on sound', sound_off: '🔇 Muted', send_ph: 'Message',
  wrong_pass: 'Wrong password.', nosupport: "This browser can't decode video with WebCodecs. Use an up-to-date Chrome, Edge, Firefox (130+) or Safari (16.4+).",
  insecure: 'The page must be opened over https:// to show the video.',
  waiting_key: 'waiting for the first frame...', image: '[image]', screen: 'screen', camera: 'camera',
  you: '(you)', live: 'LIVE',
};
const L = (navigator.language || 'pt').toLowerCase().startsWith('pt') ? PT : EN;
const $ = (id) => document.getElementById(id);

// ----------------------------------------------------------- protocolo
const T = { hello: 1, welcome: 2, denied: 3, members: 4, chat: 5, frame: 8, watch: 9, keyreq: 10, ping: 11, pong: 12,
  audio: 14, ack: 15, voice: 17, notice: 20, cursor: 25, view_size: 26, channel: 29, web_hello: 40 };
const enc = new TextEncoder();
const dec = new TextDecoder();

class W {
  constructor(type) { this.b = [type]; }
  u8(v) { this.b.push(v & 255); return this; }
  u16(v) { this.b.push(v & 255, (v >>> 8) & 255); return this; }
  u32(v) { for (let i = 0; i < 4; i++) this.b.push((v >>> (8 * i)) & 255); return this; }
  u64(v) { let x = BigInt(v); for (let i = 0; i < 8; i++) { this.b.push(Number(x & 255n)); x >>= 8n; } return this; }
  str(s) { const e = enc.encode(s).slice(0, 4000); this.u16(e.length); for (const c of e) this.b.push(c); return this; }
  done() { return new Uint8Array(this.b); }
}
class R {
  constructor(u8, off) { this.d = u8; this.p = off || 0; this.v = new DataView(u8.buffer, u8.byteOffset, u8.byteLength); }
  u8() { return this.d[this.p++]; }
  u16() { const x = this.v.getUint16(this.p, true); this.p += 2; return x; }
  u32() { const x = this.v.getUint32(this.p, true); this.p += 4; return x; }
  u64() { const lo = this.v.getUint32(this.p, true), hi = this.v.getUint32(this.p + 4, true); this.p += 8; return hi * 4294967296 + lo; }
  str() { const n = this.u16(); const s = dec.decode(this.d.subarray(this.p, this.p + n)); this.p += n; return s; }
  bytes(n) { const s = this.d.subarray(this.p, this.p + n); this.p += n; return s; }
  rest() { return this.d.subarray(this.p); }
  left() { return this.d.length - this.p; }
}

const FEAT = 1 | 2 | 4; // cursor fora do vídeo, tamanho em que assiste, call separada
const STEPS = [360, 480, 540, 720, 900, 1080, 1440, 2160];
const CODECS = [ // o que pedir ao WebCodecs pra cada codec do protocolo (0 H.264, 1 HEVC, 2 AV1)
  'avc1.640034', 'hvc1.1.6.L153.B0', 'av01.0.15M.08'];

// ------------------------------------------------------------- estado
const hash = new URLSearchParams(location.hash.slice(1));
const QA = hash.get('qa') === '1';
const st = {
  ws: null, me: 0, chan: '', members: new Map(), watching: 0, closedByUs: false, denied: false, retry: 1000,
  dec: null, decCodec: -1, waitKey: true, decoded: 0, qaSent: false, lastFrameAt: 0, fps: 0, fpsCount: 0, fpsAt: 0,
  cursor: null, frameW: 0, frameH: 0, sentH: -1,
  audio: null, node: null, gain: null, soundOn: false, adec: null, vdec: new Map(), audioPkts: 0, qaAudioSent: false,
  qaPcm: 0, qaPeak: 0, qaPcmSent: false,
};
let key = localStorage.getItem('telinha-key');
if (!key) { key = String(Math.floor(Math.random() * 2 ** 52) + 1); localStorage.setItem('telinha-key', key); }

function toast(text) {
  const t = $('toast'); t.textContent = text; t.classList.add('show');
  clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('show'), 4000);
}
function status(text, cls) { $('status-text').textContent = text; $('dot').className = 'dot ' + (cls || ''); }
function send(u8) { if (st.ws && st.ws.readyState === 1) st.ws.send(u8); }
function color(id) { const c = ['#e5484d', '#f76b15', '#ffc53d', '#30a46c', '#12a594', '#0090ff', '#6e56cf', '#d6409f']; return c[id % c.length]; }

// ---------------------------------------------------------- conexão
async function decodable() {
  let bits = 0;
  if (!('VideoDecoder' in window)) return 0;
  for (let i = 0; i < CODECS.length; i++) {
    try { const r = await VideoDecoder.isConfigSupported({ codec: CODECS[i], optimizeForLatency: true }); if (r.supported) bits |= 1 << i; } catch (e) { /* não tem */ }
  }
  return bits | 1; // H.264 o servidor sempre manda
}

async function connect(name, pass) {
  const codecs = await decodable();
  st.closedByUs = false;
  status(L.connecting);
  const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
  ws.binaryType = 'arraybuffer';
  st.ws = ws;
  ws.onopen = () => {
    send(new W(T.web_hello).str(pass).str(name).str('').u64(key).str('web').u8(codecs).u8(FEAT).str(hash.get('c') || '').done());
  };
  ws.onmessage = (e) => onMessage(new Uint8Array(e.data));
  ws.onclose = () => {
    stopVideo();
    if (st.denied || st.closedByUs) return;
    status(L.offline, 'bad');
    setTimeout(() => connect(name, pass), st.retry);
    st.retry = Math.min(st.retry * 2, 30000);
  };
}

function onMessage(u8) {
  const r = new R(u8, 1);
  switch (u8[0]) {
    case T.welcome: {
      st.me = r.u32(); $('room-name').textContent = r.str();
      st.retry = 1000;
      if (QA && !st.audio) enableSound(); // teste: o navegador do teste deixa tocar sem clique
      status(L.online, 'on');
      $('join').hidden = true; $('room').hidden = false;
      break;
    }
    case T.denied: {
      const why = r.str(); st.denied = true;
      $('join').hidden = false; $('room').hidden = true;
      $('join-err').textContent = why === 'Senha errada.' ? L.wrong_pass : why;
      $('pw-row').hidden = false;
      status('', 'bad');
      break;
    }
    case T.members: onMembers(r); break;
    case T.channel: { st.chan = r.str(); $('chan').textContent = '#' + st.chan; break; }
    case T.chat: onChat(r); break;
    case T.frame: onFrame(r); break;
    case T.audio: onAudio(r); break;
    case T.voice: onVoice(r); break;
    case T.cursor: { const s = r.u32(), x = r.u16(), y = r.u16(); if (s === st.watching) { st.cursor = x === 0xffff ? null : [x, y]; drawCursor(); } break; }
    case T.notice: { r.u8(); toast(r.str()); break; }
    default: break; // o resto o navegador não usa
  }
}

// ------------------------------------------------------- quem está na sala
function onMembers(r) {
  r.u8();
  const n = r.u16();
  const list = [];
  for (let i = 0; i < n; i++) {
    const m = { id: r.u32(), name: r.str(), flags: r.u8(), route: r.u8() };
    m.sw = r.u16(); m.sh = r.u16(); r.u8(); m.cw = r.u16(); m.ch = r.u16(); r.u8();
    const k = r.u16(); for (let j = 0; j < k; j++) r.u32();
    list.push(m);
  }
  st.members = new Map(list.map((m) => [m.id, m]));
  // transmissões que dá pra ver: de quem está na minha call
  const streams = [];
  for (const m of list) {
    if (m.id === st.me || !(m.route & 0x20)) continue;
    if (m.flags & 1) streams.push({ id: m.id, name: m.name, kind: 0 });
    if (m.flags & 64) streams.push({ id: (m.id | 0x80000000) >>> 0, name: m.name, kind: 1 });
  }
  st.streams = streams;
  renderPeople(list); renderStreams(streams);
  // a que eu assistia acabou: a próxima; nada assistindo: a primeira
  if (!streams.some((s) => s.id === st.watching)) watch(streams.length ? streams[0].id : 0);
}

function renderPeople(list) {
  const ul = $('people'); ul.textContent = '';
  for (const m of list) {
    if (!(m.route & 0x40) && !(m.route & 0x20)) continue;
    const li = document.createElement('li');
    const av = document.createElement('span'); av.className = 'av'; av.style.background = color(m.id); av.textContent = (m.name[0] || '?').toUpperCase();
    const nm = document.createElement('span'); nm.textContent = m.name + (m.id === st.me ? ' ' + L.you : '');
    li.append(av, nm);
    if (m.flags & 1) { const t = document.createElement('span'); t.className = 'tag'; t.textContent = L.live; li.append(t); }
    else if ((m.route & 0x1f) === 6) { const t = document.createElement('span'); t.className = 'web'; t.textContent = '🌐'; li.append(t); }
    ul.append(li);
  }
}

function renderStreams(streams) {
  const box = $('streams'); box.textContent = '';
  for (const s of streams) {
    const b = document.createElement('button');
    b.className = 'pill' + (s.id === st.watching ? ' sel' : '');
    const tag = document.createElement('span'); tag.className = 'live'; tag.textContent = L.live; b.append(tag);
    b.append(s.name + (s.kind ? ' · ' + L.camera : ''));
    b.onclick = () => watch(s.id);
    box.append(b);
  }
  $('empty').textContent = streams.length ? '' : L.nobody;
  $('empty').hidden = streams.length > 0 && st.decoded > 0;
}

// ------------------------------------------------------------- vídeo
function watch(id) {
  if (id === st.watching) return;
  if (st.watching) send(new W(T.watch).u32(st.watching).u8(0).u8(0).done());
  stopVideo();
  st.watching = id;
  if (!id) { clearCanvas(); renderStreams(st.streams || []); return; }
  send(new W(T.watch).u32(id).u8(1).u8(0).done());
  st.sentH = -1; sendViewSize();
  $('empty').hidden = false; $('empty').textContent = L.waiting_key;
  renderStreams(st.streams || []);
}

function stopVideo() {
  if (st.dec) { try { st.dec.close(); } catch (e) { /* já fechado */ } }
  st.dec = null; st.decCodec = -1; st.waitKey = true; st.decoded = 0; st.cursor = null;
}

function clearCanvas() {
  const c = $('video'); c.getContext('2d').clearRect(0, 0, c.width, c.height);
  drawCursor();
}

function newDecoder(codec) {
  stopVideo();
  const c = $('video');
  const ctx = c.getContext('2d', { alpha: false, desynchronized: true });
  st.dec = new VideoDecoder({
    output: (frame) => {
      if (c.width !== frame.displayWidth || c.height !== frame.displayHeight) {
        c.width = frame.displayWidth; c.height = frame.displayHeight;
        const cc = $('cursor'); cc.width = c.width; cc.height = c.height;
      }
      ctx.drawImage(frame, 0, 0);
      frame.close();
      st.decoded++;
      st.fpsCount++;
      if (st.decoded === 1) $('empty').hidden = true;
      if (QA && !st.qaSent && st.decoded >= 30) {
        st.qaSent = true;
        send(new W(T.chat).str(`[qa] ${st.decoded} quadros decodificados ${c.width}x${c.height} codec ${st.decCodec}`).done());
      }
    },
    error: () => { requestKey(); },
  });
  st.dec.configure({ codec: CODECS[codec], optimizeForLatency: true, hardwareAcceleration: 'no-preference' });
  st.decCodec = codec;
  st.waitKey = true;
}

function requestKey() {
  const id = st.watching;
  stopVideo();
  st.watching = id;
  if (id) send(new W(T.keyreq).u32(id).u8(0).done());
}

function onFrame(r) {
  const stream = r.u32();
  const seq = r.u32(), flags = r.u8(), time = r.u64(), w = r.u16(), h = r.u16(), cx = r.u16(), cy = r.u16();
  // confirma na hora (antes de decodificar): é como o servidor mede o atraso
  send(new W(T.ack).u32(stream).u32(seq).done());
  if (stream !== st.watching) return;
  st.lastFrameAt = performance.now();
  st.frameW = w; st.frameH = h;
  const key = (flags & 1) !== 0;
  const codec = (flags >> 2) & 3;
  if (flags & 0x10) { st.cursor = cx === 0xffff ? null : [cx, cy]; }
  if (!st.dec || st.decCodec !== codec) { if (!key) return; newDecoder(codec); }
  if (st.waitKey) { if (!key) return; st.waitKey = false; }
  // decoder atrasado (máquina fraca, aba em segundo plano): recomeça de um IDR
  if (st.dec.decodeQueueSize > 6) { requestKey(); return; }
  try {
    st.dec.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: time, data: r.rest() }));
  } catch (e) { requestKey(); return; }
  drawCursor();
}

// a seta de quem transmite, desenhada aqui (o vídeo vai sem ela: quem
// transmite não precisa pintar o cursor na tela, nem sair do caminho direto
// pela placa de vídeo)
function drawCursor() {
  const cc = $('cursor'); const g = cc.getContext('2d');
  g.clearRect(0, 0, cc.width, cc.height);
  if (!st.cursor || !cc.width) return;
  const x = st.cursor[0] / 65534 * cc.width, y = st.cursor[1] / 65534 * cc.height;
  const s = Math.max(1, cc.height / 720) * 1.2;
  g.save(); g.translate(x, y); g.scale(s, s);
  g.beginPath(); g.moveTo(0, 0); g.lineTo(0, 17); g.lineTo(4.5, 13); g.lineTo(7.5, 20); g.lineTo(10, 19); g.lineTo(7, 12); g.lineTo(13, 12); g.closePath();
  g.fillStyle = '#fff'; g.strokeStyle = '#000'; g.lineWidth = 1.4; g.fill(); g.stroke(); g.restore();
}

// a altura em que o vídeo aparece aqui: o servidor manda no máximo isso (economiza a banda de todo mundo)
function sendViewSize() {
  if (!st.watching) return;
  const stage = $('stage');
  const full = document.fullscreenElement != null;
  const want = full ? 0xffff : Math.round(stage.clientHeight * (window.devicePixelRatio || 1));
  const h = want === 0xffff ? want : (STEPS.find((s) => s >= want) || 0xffff);
  if (h === st.sentH) return;
  st.sentH = h;
  send(new W(T.view_size).u32(st.watching).u16(h).done());
}
new ResizeObserver(() => sendViewSize()).observe($('stage'));
document.addEventListener('fullscreenchange', () => { st.sentH = -1; sendViewSize(); });

// -------------------------------------------------------------- som
async function enableSound() {
  if (st.audio) { st.soundOn = !st.soundOn; st.gain.gain.value = st.soundOn ? $('vol').value / 100 : 0; soundButton(); return; }
  st.audio = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
  await st.audio.audioWorklet.addModule('audio-worklet.js');
  st.node = new AudioWorkletNode(st.audio, 'telinha-mix', { outputChannelCount: [2] });
  st.gain = st.audio.createGain();
  st.node.connect(st.gain).connect(st.audio.destination);
  st.soundOn = true; st.gain.gain.value = $('vol').value / 100;
  soundButton();
}
function soundButton() {
  const b = $('btn-sound');
  // sem som ainda (o navegador só deixa tocar depois de um clique): o convite pra ligar
  b.textContent = !st.audio ? L.sound_on : st.soundOn ? '🔊' : L.sound_off;
  b.classList.toggle('attn', !st.soundOn);
}

function pushPcm(id, data) {
  if (!st.node) { data.close(); return; }
  const n = data.numberOfFrames;
  const l = new Float32Array(n); data.copyTo(l, { planeIndex: 0, format: 'f32-planar' });
  if (QA && !st.qaPcmSent) {
    // teste: som decodificado de verdade (não silêncio)
    for (let i = 0; i < n; i++) st.qaPeak = Math.max(st.qaPeak || 0, Math.abs(l[i]));
    if (++st.qaPcm >= 100) { st.qaPcmSent = true; send(new W(T.chat).str(`[qa] som decodificado pico ${st.qaPeak.toFixed(2)}`).done()); }
  }
  let rr = null;
  if (data.numberOfChannels > 1) { rr = new Float32Array(n); data.copyTo(rr, { planeIndex: 1, format: 'f32-planar' }); }
  data.close();
  st.node.port.postMessage({ id, l, r: rr }, rr ? [l.buffer, rr.buffer] : [l.buffer]);
}

function onAudio(r) {
  const stream = r.u32(); const seq = r.u32(); const time = r.u64();
  if (stream !== (st.watching & 0x7fffffff)) return;
  if (QA && !st.qaAudioSent && ++st.audioPkts >= 50) { st.qaAudioSent = true; send(new W(T.chat).str('[qa] som chegando').done()); }
  if (!st.node || !('AudioDecoder' in window)) return;
  if (!st.adec || st.adec.state === 'closed') {
    st.adec = new AudioDecoder({ output: (d) => pushPcm('tela', d), error: () => { st.adec = null; } });
    st.adec.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 2 });
  }
  try { st.adec.decode(new EncodedAudioChunk({ type: 'key', timestamp: time, data: r.rest() })); } catch (e) { st.adec = null; }
  void seq;
}

function onVoice(r) {
  const from = r.u32(); const seq = r.u32();
  if (!st.node || !('AudioDecoder' in window)) return;
  let d = st.vdec.get(from);
  if (!d || d.state === 'closed') {
    d = new AudioDecoder({ output: (a) => pushPcm('voz' + from, a), error: () => st.vdec.delete(from) });
    d.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 1 });
    st.vdec.set(from, d);
  }
  try { d.decode(new EncodedAudioChunk({ type: 'key', timestamp: seq * 20000, data: r.rest() })); } catch (e) { st.vdec.delete(from); }
}

// -------------------------------------------------------------- chat
function onChat(r) {
  r.u32(); const from = r.u32(); const name = r.str(); let text = r.str();
  r.u64(); const flags = r.u8();
  const img = r.u8();
  if (img === 1) { r.u16(); r.u16(); r.bytes(r.u32()); if (!text) text = L.image; }
  void flags;
  const div = document.createElement('div');
  div.className = 'msg' + (from ? '' : ' sys');
  if (from) { const who = document.createElement('span'); who.className = 'who'; who.style.color = color(from); who.textContent = name; div.append(who); }
  div.append(text);
  const box = $('chat');
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 8;
  box.append(div);
  while (box.children.length > 300) box.firstChild.remove();
  if (atBottom) box.scrollTop = box.scrollHeight;
}

// --------------------------------------------------------------- início
function start() {
  document.documentElement.lang = L === PT ? 'pt-BR' : 'en';
  $('t-join-title').textContent = L.join_title; $('t-join-sub').textContent = L.join_sub;
  $('t-name').textContent = L.name; $('t-pass').textContent = L.pass; $('btn-join').textContent = L.join;
  $('t-people').textContent = L.people; $('t-chat').textContent = L.chat; $('chat-in').placeholder = L.send_ph;
  soundButton();
  if (!window.isSecureContext) { $('t-nosupport').textContent = L.insecure; $('t-nosupport').hidden = false; }
  else if (!('VideoDecoder' in window)) { $('t-nosupport').textContent = L.nosupport; $('t-nosupport').hidden = false; }
  const pass = hash.get('s') || '';
  $('in-name').value = hash.get('n') || localStorage.getItem('telinha-nome') || '';
  $('in-pass').value = pass;
  if (hash.has('s')) $('pw-row').hidden = true;
  $('join').hidden = false;
  $('join-form').onsubmit = (e) => {
    e.preventDefault();
    const name = $('in-name').value.trim() || 'visitante';
    localStorage.setItem('telinha-nome', name);
    $('join-err').textContent = ''; st.denied = false;
    connect(name, $('in-pass').value);
  };
  $('chat-form').onsubmit = (e) => {
    e.preventDefault();
    const t = $('chat-in').value.trim();
    if (t) send(new W(T.chat).str(t).done());
    $('chat-in').value = '';
  };
  $('btn-sound').onclick = () => enableSound();
  $('vol').oninput = () => { if (st.gain && st.soundOn) st.gain.gain.value = $('vol').value / 100; };
  $('btn-full').onclick = () => { if (document.fullscreenElement) document.exitFullscreen(); else $('stage').requestFullscreen(); };
  $('stage').ondblclick = () => $('btn-full').onclick();
  // vivo: ping a cada 5 s (o túnel fecha conexão parada) e o fps no canto
  setInterval(() => send(new W(T.ping).u64(Date.now()).done()), 5000);
  setInterval(() => {
    if (!st.watching || !st.decoded) { $('info').textContent = ''; return; }
    $('info').textContent = `${st.frameW}×${st.frameH} · ${st.fpsCount} fps`;
    st.fpsCount = 0;
  }, 1000);
  // entra direto se o link já trouxe tudo (nome salvo e senha)
  if (QA || (hash.has('s') && $('in-name').value)) $('join-form').requestSubmit();
}
start();
