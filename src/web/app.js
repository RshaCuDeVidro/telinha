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
const TOUCH = matchMedia('(pointer: coarse)').matches;

// ----------------------------------------------------------- protocolo
const T = { hello: 1, welcome: 2, denied: 3, members: 4, chat: 5, frame: 8, watch: 9, keyreq: 10, ping: 11, pong: 12,
  audio: 14, ack: 15, voice: 17, notice: 20, cursor: 25, view_size: 26, channel: 29, web_hello: 40,
  chat_edit: 42, embed_action: 43 };
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

const FEAT = 1 | 2 | 4 | 32; // cursor fora do vídeo, tamanho em que assiste, call separada, cartões
const STEPS = [360, 480, 540, 720, 900, 1080, 1440, 2160];
const CODECS = [ // o que pedir ao WebCodecs pra cada codec do protocolo (0 H.264, 1 HEVC, 2 AV1)
  'avc1.640034', 'hvc1.1.6.L153.B0', 'av01.0.15M.08'];

// --------------------------------------------- vídeo sem WebCodecs (MSE)
// Navegador sem VideoDecoder (Firefox do Android, por exemplo): o H.264
// vira MP4 fragmentado, um pedaço por quadro, e toca num <video> comum. Atraso
// um pouco maior, e o som da transmissão só onde tiver AudioDecoder.
const MS = window.ManagedMediaSource || window.MediaSource;
const USE_MSE = !!MS && (!('VideoDecoder' in window) || new URLSearchParams(location.hash.slice(1)).get('mse') === '1');

function box(type, ...parts) {
  let n = 8;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  new DataView(out.buffer).setUint32(0, n);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  let o = 8;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
function bytes(...vals) { // [bits, valor]: 8/16/32 bits, big-endian
  const out = [];
  for (const [b, v] of vals) for (let s = b - 8; s >= 0; s -= 8) out.push(Math.floor(v / 2 ** s) & 255);
  return new Uint8Array(out);
}
const MATRIX = bytes([32, 0x10000], [32, 0], [32, 0], [32, 0], [32, 0x10000], [32, 0], [32, 0], [32, 0], [32, 0x40000000]);

// NALs de um quadro Annex-B (00 00 01 / 00 00 00 01)
function nals(d) {
  const out = [];
  let i = 0, start = -1;
  while (i + 2 < d.length) {
    if (d[i] === 0 && d[i + 1] === 0 && d[i + 2] === 1) {
      if (start >= 0) out.push(d.subarray(start, i > 0 && d[i - 1] === 0 ? i - 1 : i));
      i += 3; start = i;
    } else i++;
  }
  if (start >= 0) out.push(d.subarray(start));
  return out.filter((n) => n.length);
}

class Mp4Feed {
  constructor(video) {
    this.video = video; this.ms = null; this.sb = null; this.queue = []; this.seq = 1; this.t0 = -1; this.last = -1;
    this.dur = 16667; this.sps = null; this.pps = null; this.w = 0; this.h = 0; this.trimAt = 0;
  }
  close() {
    this.queue = []; this.sb = null; this.sps = null;
    if (this.ms && this.ms.readyState === 'open') { try { this.ms.endOfStream(); } catch (e) { /* já fechado */ } }
    this.ms = null;
    if (this.video.src) { URL.revokeObjectURL(this.video.src); this.video.removeAttribute('src'); this.video.load(); }
  }
  // um quadro: true se entrou (false = espera um IDR)
  push(key, time, data, w, h) {
    const list = nals(data);
    let sps = null, pps = null;
    const keep = [];
    for (const n of list) {
      const t = n[0] & 31;
      if (t === 7) sps = n; else if (t === 8) pps = n; else if (t !== 9) keep.push(n);
    }
    if (key && sps && pps && (!this.sps || w !== this.w || h !== this.h || !same(sps, this.sps))) this.open(sps, pps, w, h);
    if (!this.ms) return false;
    if (this.t0 < 0) { if (!key) return false; this.t0 = time; }
    if (this.last >= 0 && time > this.last) this.dur = Math.min(200000, time - this.last);
    this.last = time;
    let size = 0;
    for (const n of keep) size += 4 + n.length;
    const mdat = new Uint8Array(size);
    let o = 0;
    for (const n of keep) { new DataView(mdat.buffer).setUint32(o, n.length); mdat.set(n, o + 4); o += 4 + n.length; }
    this.append(this.fragment(Math.max(0, time - this.t0), this.dur, mdat, key));
    return true;
  }
  open(sps, pps, w, h) {
    this.close();
    this.sps = sps; this.pps = pps; this.w = w; this.h = h; this.t0 = -1; this.last = -1; this.seq = 1;
    const hex = (b) => b.toString(16).padStart(2, '0');
    const mime = `video/mp4; codecs="avc1.${hex(sps[1])}${hex(sps[2])}${hex(sps[3])}"`;
    if (!MS.isTypeSupported(mime)) { toast(L.nosupport); return; }
    const ms = new MS();
    this.ms = ms;
    this.video.disableRemotePlayback = true;
    this.video.src = URL.createObjectURL(ms);
    ms.addEventListener('sourceopen', () => {
      if (this.ms !== ms) return;
      this.sb = ms.addSourceBuffer(mime);
      this.sb.mode = 'segments';
      this.sb.addEventListener('updateend', () => this.flush());
      this.queue.unshift(this.init());
      this.flush();
    }, { once: true });
  }
  init() {
    const { sps, pps, w, h } = this;
    const avcc = box('avcC', bytes([8, 1], [8, sps[1]], [8, sps[2]], [8, sps[3]], [8, 0xff], [8, 0xe1], [16, sps.length]), sps, bytes([8, 1], [16, pps.length]), pps);
    const avc1 = box('avc1', bytes([32, 0], [16, 0], [16, 1], [32, 0], [32, 0], [32, 0], [32, 0], [16, w], [16, h], [32, 0x480000], [32, 0x480000], [32, 0], [16, 1]),
      new Uint8Array(32), bytes([16, 0x18], [16, 0xffff]), avcc);
    const stbl = box('stbl', box('stsd', bytes([32, 0], [32, 1]), avc1), box('stts', bytes([32, 0], [32, 0])), box('stsc', bytes([32, 0], [32, 0])),
      box('stsz', bytes([32, 0], [32, 0], [32, 0])), box('stco', bytes([32, 0], [32, 0])));
    const minf = box('minf', box('vmhd', bytes([32, 1], [32, 0], [32, 0])), box('dinf', box('dref', bytes([32, 0], [32, 1]), box('url ', bytes([32, 1])))), stbl);
    const mdia = box('mdia', box('mdhd', bytes([32, 0], [32, 0], [32, 0], [32, 1000000], [32, 0], [16, 0x55c4], [16, 0])),
      box('hdlr', bytes([32, 0], [32, 0]), new TextEncoder().encode('vide'), new Uint8Array(12), new TextEncoder().encode('telinha\0')), minf);
    const tkhd = box('tkhd', bytes([32, 3], [32, 0], [32, 0], [32, 1], [32, 0], [32, 0], [32, 0], [32, 0], [16, 0], [16, 0], [16, 0], [16, 0]), MATRIX, bytes([32, w * 65536], [32, h * 65536]));
    const mvhd = box('mvhd', bytes([32, 0], [32, 0], [32, 0], [32, 1000000], [32, 0], [32, 0x10000], [16, 0x100], [16, 0], [32, 0], [32, 0]), MATRIX, new Uint8Array(24), bytes([32, 2]));
    const mvex = box('mvex', box('trex', bytes([32, 0], [32, 1], [32, 1], [32, 0], [32, 0], [32, 0x10001])));
    const ftyp = box('ftyp', new TextEncoder().encode('isom'), bytes([32, 0]), new TextEncoder().encode('isomiso2avc1mp41'));
    const moov = box('moov', mvhd, box('trak', tkhd, mdia), mvex);
    const out = new Uint8Array(ftyp.length + moov.length); out.set(ftyp); out.set(moov, ftyp.length);
    return out;
  }
  fragment(t, dur, mdat, key) {
    const trunLen = 8 + 4 + 4 + 4 + 3 * 4; // caixa, versão/flags, quantas, data_offset, 1 amostra (duração, tamanho, flags)
    const tfdt = box('tfdt', bytes([32, 0x01000000], [32, Math.floor(t / 2 ** 32)], [32, t % 2 ** 32]));
    const tfhd = box('tfhd', bytes([32, 0x020000], [32, 1]));
    const mfhd = box('mfhd', bytes([32, 0], [32, this.seq++]));
    const moofLen = 8 + mfhd.length + 8 + tfhd.length + tfdt.length + trunLen;
    const trun = box('trun', bytes([32, 0x000701], [32, 1], [32, moofLen + 8], [32, dur], [32, mdat.length], [32, key ? 0x02000000 : 0x01010000]));
    const moof = box('moof', mfhd, box('traf', tfhd, tfdt, trun));
    const md = box('mdat', mdat);
    const out = new Uint8Array(moof.length + md.length); out.set(moof); out.set(md, moof.length);
    return out;
  }
  append(seg) { this.queue.push(seg); this.flush(); }
  flush() {
    const sb = this.sb;
    if (!sb || sb.updating || !this.queue.length) return;
    // junta o que acumulou num append só
    let n = 0;
    for (const q of this.queue) n += q.length;
    const all = new Uint8Array(n);
    let o = 0;
    for (const q of this.queue) { all.set(q, o); o += q.length; }
    this.queue = [];
    try { sb.appendBuffer(all); } catch (e) { requestKey(); return; }
    const v = this.video;
    if (v.paused) v.play().catch(() => {});
    // ao vivo: sempre perto do fim do que chegou (atrasou, pula pra frente)
    const b = v.buffered;
    if (b.length) {
      const end = b.end(b.length - 1);
      if (end - v.currentTime > 0.5) v.currentTime = Math.max(b.start(b.length - 1), end - 0.08);
      // o que já passou sai do buffer (a memória do celular agradece)
      const now = performance.now();
      if (now > this.trimAt && v.currentTime > 15) {
        this.trimAt = now + 10000;
        this.queue.length === 0 && setTimeout(() => { try { if (!sb.updating) sb.remove(0, v.currentTime - 10); } catch (e) { /* tanto faz */ } }, 0);
      }
    }
  }
}
function same(a, b) { if (a.length !== b.length) return false; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; }

// ------------------------------------------------------------- estado
const hash = new URLSearchParams(location.hash.slice(1));
const QA = hash.get('qa') === '1';
const st = {
  ws: null, me: 0, chan: '', members: new Map(), watching: 0, closedByUs: false, denied: false, retry: 1000,
  dec: null, decCodec: -1, waitKey: true, decoded: 0, qaSent: false, lastFrameAt: 0, fps: 0, fpsCount: 0, fpsAt: 0,
  cursor: null, frameW: 0, frameH: 0, sentH: -1,
  audio: null, node: null, gain: null, soundOn: false, adec: null, vdec: new Map(), audioPkts: 0, qaAudioSent: false,
  qaPcm: 0, qaPeak: 0, qaPcmSent: false, pending: [], mp4: null,
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
  if (USE_MSE || !('VideoDecoder' in window)) return 1; // MP4 pelo <video>: só H.264
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
    case T.chat_edit: onChatEdit(r); break;
    case T.frame: onFrame(r); break;
    case T.audio: onAudio(r); break;
    case T.voice: onVoice(r); break;
    case T.cursor: { const s = r.u32(), x = r.u16(), y = r.u16(); if (s === st.watching) { st.cursor = x === 0xffff ? null : [x, y]; drawCursor(); } break; }
    case T.notice: {
      const kind = r.u8(); toast(r.str());
      if (kind === 12) { $('chat').textContent = ''; msgEls.clear(); } // um admin limpou o chat da sala
      break;
    }
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
  // depois: a versão do app de cada um e o que cada um é (1 = bot); servidor antigo não manda
  try { for (const m of list) r.str(); for (const m of list) m.bot = (r.u8() & 1) !== 0; } catch (e) { /* sem */ }
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
    if (m.bot) { const t = document.createElement('span'); t.className = 'bot'; t.textContent = 'BOT'; li.append(t); }
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
  if (st.mp4) st.mp4.close();
  st.dec = null; st.decCodec = -1; st.waitKey = true; st.decoded = 0; st.cursor = null; st.pending = [];
}

function clearCanvas() {
  const c = $('video'); c.getContext('2d').clearRect(0, 0, c.width, c.height);
  drawCursor();
}

function newDecoder(codec) {
  stopVideo();
  const c = $('video');
  // "desynchronized" (menos atraso) pisca no Chrome do Android: só no PC
  const ctx = c.getContext('2d', { alpha: false, desynchronized: !TOUCH });
  st.dec = new VideoDecoder({
    output: (frame) => {
      st.pending.shift();
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
  if (USE_MSE) {
    if (codec !== 0) return; // só H.264 (o servidor sabe: a página disse)
    if (!st.mp4) st.mp4 = new Mp4Feed($('mvideo'));
    if (st.mp4.push(key, time, r.rest(), w, h)) {
      if (++st.decoded === 1) { $('empty').hidden = true; sizeCursor(w, h); }
      st.fpsCount++;
      // teste: o <video> tocando de verdade (imagem com tamanho, o tempo andando)
      const v = $('mvideo');
      if (QA && !st.qaSent && v.videoWidth > 0 && v.currentTime > 1) {
        st.qaSent = true;
        const late = v.buffered.length ? v.buffered.end(v.buffered.length - 1) - v.currentTime : -1;
        send(new W(T.chat).str(`[qa] ${st.decoded} quadros tocando pelo MSE ${v.videoWidth}x${v.videoHeight} atraso ${late.toFixed(2)}`).done());
      }
    } else if (key) requestKey();
    drawCursor();
    return;
  }
  if (!st.dec || st.decCodec !== codec) { if (!key) return; newDecoder(codec); }
  if (st.waitKey) { if (!key) return; st.waitKey = false; }
  // decoder atrasado (máquina fraca, aba em segundo plano): recomeça de um IDR.
  // Pelo tempo, não pela fila: o decoder da placa do celular segura vários
  // quadros de propósito, e "fila > 6" pedia IDR sem parar (o vídeo engasgava)
  const now = performance.now();
  if (st.dec.decodeQueueSize > 60 || (st.pending.length > 2 && now - st.pending[0] > 700)) { requestKey(); return; }
  try {
    st.dec.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: time, data: r.rest() }));
    st.pending.push(now);
  } catch (e) { requestKey(); return; }
  drawCursor();
}

function sizeCursor(w, h) {
  const cc = $('cursor');
  if (cc.width !== w || cc.height !== h) { cc.width = w; cc.height = h; }
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
// ---------------------------------------------------------------- chat
// A mensagem inteira (docs/PROTOCOL.md): o que a página mostra é o texto, a
// imagem (decodificada pelo WebCodecs, como o vídeo) e o cartão dos bots.
function readChat(r) {
  const m = { id: r.u32(), from: r.u32(), name: r.str(), text: r.str() };
  r.u64(); r.u8();
  const img = r.u8();
  if (img === 1) { m.img = { w: r.u16(), h: r.u16() }; m.img.data = r.bytes(r.u32()).slice(); }
  const nr = r.left() ? r.u8() : 0;
  for (let i = 0; i < nr; i++) { r.u8(); r.u32(); }
  if (r.left() >= 4) { const rep = r.u32(); if (rep) { r.u32(); m.quoteName = r.str(); m.quote = r.str(); } }
  if (r.left() >= 4) { const to = r.u32(); if (to) r.str(); }
  if (r.left() >= 4) { const f = r.u32(); if (f) { m.file = r.str(); r.u64(); } }
  if (r.left() >= 4) { const n = r.u32(); if (n) m.embed = readEmbed(r.bytes(n)); }
  return m;
}

function readEmbed(b) {
  try {
    if (b[0] !== 1) return null;
    const r = new R(b, 1);
    const e = { color: r.u32(), flags: r.u8(), kicker: r.str(), title: r.str(), url: r.str(), desc: r.str(), footer: r.str(), fields: [], buttons: [] };
    if (e.flags & 2) { e.elapsed = r.u32(); e.total = r.u32(); e.paused = r.u8() !== 0; e.at = performance.now(); }
    for (let i = r.u8(); i > 0; i--) e.fields.push({ name: r.str(), value: r.str(), inline: r.u8() !== 0 });
    for (let i = r.u8(); i > 0; i--) { const bt = { style: r.u8(), icon: r.u8(), label: r.str() }; bt.disabled = r.left() ? (r.u8() & 1) !== 0 : false; e.buttons.push(bt); }
    if (!/^https?:\/\//.test(e.url)) e.url = '';
    e.fields = e.fields.slice(0, 12); e.buttons = e.buttons.slice(0, 5);
    return e;
  } catch (err) { return null; }
}

// markdown pequeno e seguro: escapa tudo e só então põe negrito, itálico, código e link
function md(text) {
  const esc = text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  return esc
    .replace(/`([^`\n]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<i>$2</i>')
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
    .replace(/\n/g, '<br>');
}

const ICON = { // os mesmos números do embed.zig; traço fino como no resto
  1: 'M7 4.5v15l12-7.5z', 2: 'M7 5h3.5v14H7zM13.5 5H17v14h-3.5z', 3: 'M6 5l9 7-9 7zM17 5v14', 4: 'M18 5l-9 7 9 7zM7 5v14',
  5: 'M6 6h12v12H6z', 6: 'M3 7h3.5c4 0 6 10 10 10H21M17.5 14l3.5 3-3.5 3M3 17h3.5c1.4 0 2.6-1.2 3.6-2.8M21 7h-4.5c-1.4 0-2.6 1.2-3.6 2.8M17.5 4l3.5 3-3.5 3',
  7: 'M17 2.5l3 3-3 3M4 11V9a3.5 3.5 0 0 1 3.5-3.5H20M7 21.5l-3-3 3-3M20 13v2a3.5 3.5 0 0 1-3.5 3.5H4', 8: 'M4 9.5h3.5L12 5v14l-4.5-4.5H4zM15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11',
  9: 'M4 9.5h3.5L12 5v14l-4.5-4.5H4zM15.5 9a4 4 0 0 1 0 6', 10: 'M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01',
  11: 'M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.3 4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z', 12: 'M9 18V5.5l11-2V16M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM17 19a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  13: 'M12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8',
  14: 'M11 17.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM16 16l4.5 4.5', 15: 'M12 5v14M5 12h14', 16: 'M5 12.5l4.5 4.5L19 7', 17: 'M6 6l12 12M18 6L6 18',
  18: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  19: 'M4 14v-2a8 8 0 0 1 16 0v2M4 14h3v6H5.5A1.5 1.5 0 0 1 4 18.5zM20 14h-3v6h1.5a1.5 1.5 0 0 0 1.5-1.5z', 20: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
  21: 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1-5.4-2.9-5.4 2.9 1-6.1L3.2 9.5l6.1-.9z', 22: 'M5 3.5h14A1.5 1.5 0 0 1 20.5 5v14a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V5A1.5 1.5 0 0 1 5 3.5zM8.5 8.5h.01M15.5 15.5h.01M12 12h.01',
};
function icon(n) {
  if (!ICON[n]) return null;
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path'); p.setAttribute('d', ICON[n]); svg.append(p);
  return svg;
}
const dur = (ms) => { const s = Math.floor(ms / 1000); return s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };

// imagem do chat: um quadro H.264, decodificado como o vídeo
function chatImage(img, cls) {
  const cv = document.createElement('canvas'); cv.className = cls; cv.width = img.w; cv.height = img.h;
  if (!('VideoDecoder' in window)) return cv;
  try {
    const d = new VideoDecoder({ output: (f) => { cv.getContext('2d').drawImage(f, 0, 0, cv.width, cv.height); f.close(); d.close(); }, error: () => {} });
    d.configure({ codec: 'avc1.42E01F', optimizeForLatency: true });
    d.decode(new EncodedVideoChunk({ type: 'key', timestamp: 0, data: img.data }));
    d.flush().catch(() => {});
  } catch (err) { /* sem imagem */ }
  return cv;
}

function renderCard(m) {
  const e = m.embed;
  const card = document.createElement('div'); card.className = 'card-embed';
  const accent = e.color ? '#' + (e.color & 0xffffff).toString(16).padStart(6, '0') : 'var(--accent)';
  card.style.setProperty('--c', accent);
  const body = document.createElement('div'); body.className = 'ce-body';
  if (e.kicker) { const k = document.createElement('div'); k.className = 'ce-kicker'; k.textContent = e.kicker; body.append(k); }
  if (e.title) {
    const t = document.createElement(e.url ? 'a' : 'div'); t.className = 'ce-title'; t.textContent = e.title;
    if (e.url) { t.href = e.url; t.target = '_blank'; t.rel = 'noopener noreferrer'; }
    body.append(t);
  }
  if (e.desc) { const dd = document.createElement('div'); dd.className = 'ce-desc'; dd.innerHTML = md(e.desc); body.append(dd); }
  const top = document.createElement('div'); top.className = 'ce-top'; top.append(body);
  if (m.img && (e.flags & 1)) top.append(chatImage(m.img, 'ce-thumb'));
  card.append(top);
  if (e.fields.length) {
    const g = document.createElement('div'); g.className = 'ce-fields';
    for (const f of e.fields) {
      const fd = document.createElement('div'); fd.className = 'ce-field' + (f.inline ? '' : ' wide');
      const n = document.createElement('div'); n.className = 'ce-fname'; n.textContent = f.name;
      const v = document.createElement('div'); v.className = 'ce-fval'; v.innerHTML = md(f.value);
      fd.append(n, v); g.append(fd);
    }
    card.append(g);
  }
  if (m.img && (e.flags & 4) && !(e.flags & 1)) card.append(chatImage(m.img, 'ce-big'));
  if (e.flags & 2) {
    const pr = document.createElement('div'); pr.className = 'ce-progress';
    pr.innerHTML = '<span class="ce-t0"></span><div class="ce-bar"><i></i></div><span class="ce-t1"></span>';
    card.append(pr);
    let shown = false; // o primeiro tick roda antes do cartão entrar na página
    const tick = () => {
      if (pr.isConnected) shown = true;
      else if (shown) return; // a mensagem saiu (ou foi redesenhada): para
      const pos = e.paused ? e.elapsed : Math.min(e.total || Infinity, e.elapsed + (performance.now() - e.at));
      pr.querySelector('.ce-t0').textContent = dur(pos);
      pr.querySelector('.ce-t1').textContent = e.total ? dur(e.total) : L.live;
      pr.querySelector('i').style.width = e.total ? (100 * pos / e.total).toFixed(2) + '%' : '100%';
      pr.classList.toggle('live', !e.total); pr.classList.toggle('paused', e.paused);
      if (!e.paused && (!e.total || pos < e.total)) setTimeout(tick, 500);
    };
    tick();
  }
  if (e.buttons.length) {
    const row = document.createElement('div'); row.className = 'ce-buttons';
    e.buttons.forEach((bt, i) => {
      const b = document.createElement('button'); b.type = 'button';
      b.className = 'ce-btn ' + (['', 'primary', 'danger', 'success'][bt.style] || '');
      const ic = icon(bt.icon); if (ic) b.append(ic);
      if (bt.label) b.append(bt.label);
      b.disabled = bt.disabled;
      b.onclick = () => send(new W(T.embed_action).u32(m.id).u8(i).done());
      row.append(b);
    });
    card.append(row);
  }
  if (e.footer) { const f = document.createElement('div'); f.className = 'ce-footer'; f.textContent = e.footer; card.append(f); }
  return card;
}

const msgEls = new Map(); // id → a mensagem (pra quando ela for editada)

function renderMsg(m) {
  const div = document.createElement('div');
  div.className = 'msg' + (m.from ? '' : ' sys');
  if (m.from) {
    const who = document.createElement('span'); who.className = 'who'; who.style.color = color(m.from); who.textContent = m.name; div.append(who);
    const mem = st.members.get(m.from);
    if (mem && mem.bot) { const t = document.createElement('span'); t.className = 'bot-tag'; t.textContent = 'BOT'; div.append(t); }
  }
  if (m.quote !== undefined) { const q = document.createElement('div'); q.className = 'quote'; q.textContent = `${m.quoteName}: ${m.quote}`; div.append(q); }
  if (m.embed) div.append(renderCard(m));
  else {
    const t = document.createElement('span'); t.innerHTML = md(m.file ? `📎 ${m.file}` : m.text); div.append(t);
    if (m.img) div.append(chatImage(m.img, 'chat-img'));
  }
  return div;
}

function onChat(r) {
  const m = readChat(r);
  const div = renderMsg(m);
  msgEls.set(m.id, { el: div, m });
  const box = $('chat');
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 8;
  box.append(div);
  while (box.children.length > 300) { const first = box.firstChild; for (const [k, v] of msgEls) if (v.el === first) msgEls.delete(k); first.remove(); }
  if (atBottom) box.scrollTop = box.scrollHeight;
}

function onChatEdit(r) {
  const id = r.u32(); const text = r.str();
  const n = r.left() >= 4 ? r.u32() : 0;
  const cur = msgEls.get(id); if (!cur) return;
  cur.m.text = text; cur.m.embed = n ? readEmbed(r.bytes(n)) : null;
  const div = renderMsg(cur.m);
  cur.el.replaceWith(div); cur.el = div;
}

// --------------------------------------------------------------- início
function start() {
  document.documentElement.lang = L === PT ? 'pt-BR' : 'en';
  $('t-join-title').textContent = L.join_title; $('t-join-sub').textContent = L.join_sub;
  $('t-name').textContent = L.name; $('t-pass').textContent = L.pass; $('btn-join').textContent = L.join;
  $('t-people').textContent = L.people; $('t-chat').textContent = L.chat; $('chat-in').placeholder = L.send_ph;
  soundButton();
  if (!window.isSecureContext) { $('t-nosupport').textContent = L.insecure; $('t-nosupport').hidden = false; }
  else if (!('VideoDecoder' in window) && !USE_MSE) { $('t-nosupport').textContent = L.nosupport; $('t-nosupport').hidden = false; }
  if (USE_MSE) { $('video').hidden = true; $('mvideo').hidden = false; }
  if (TOUCH) document.body.classList.add('touch');
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
  $('btn-full').onclick = () => {
    if (document.fullscreenElement) { document.exitFullscreen(); return; }
    const stage = $('stage');
    if (stage.requestFullscreen) stage.requestFullscreen().then(() => { try { screen.orientation.lock('landscape'); } catch (e) { /* sem */ } }).catch(() => {});
    else if (stage.webkitRequestFullscreen) stage.webkitRequestFullscreen();
  };
  // celular: um toque mostra/esconde os controles (não tem "mouse em cima")
  $('stage').addEventListener('click', (e) => { if (TOUCH && e.target.closest('.controls') == null) $('stage').classList.toggle('show-ctl'); });
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
// teste: se o vídeo não andou, conta no chat onde parou (o navegador headless não tem console à mão)
if (QA) {
  window.addEventListener('error', (e) => send(new W(T.chat).str(`[qa-dbg] erro ${e.message}`).done()));
  setTimeout(() => {
    if (st.qaSent) return;
    const v = $('mvideo'); const f = st.mp4;
    const b = v.buffered.length ? `${v.buffered.start(0).toFixed(2)}-${v.buffered.end(v.buffered.length - 1).toFixed(2)}` : 'vazio';
    send(new W(T.chat).str(`[qa-dbg] mse=${USE_MSE} decoded=${st.decoded} ms=${f && f.ms ? f.ms.readyState : '-'} sb=${!!(f && f.sb)} fila=${f ? f.queue.length : '-'} ` +
      `ready=${v.readyState} paused=${v.paused} t=${v.currentTime.toFixed(2)} buf=${b} err=${v.error ? v.error.code + ' ' + v.error.message : '-'} w=${v.videoWidth}`).done());
  }, 15000);
}
