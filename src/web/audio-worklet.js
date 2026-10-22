// Mistura o som da transmissão e as vozes da call (cada uma com o seu
// buffer). Buffer curto (alvo ~60 ms): atraso baixo; se acumular demais
// (aba em segundo plano, rede soluçando), joga o excesso fora.
const TARGET = 48000 * 0.06;
const MAX = 48000 * 0.25;

class Source {
  constructor() { this.l = new Float32Array(MAX * 2); this.r = new Float32Array(MAX * 2); this.read = 0; this.len = 0; this.started = false; }
  push(l, r) {
    if (this.len + l.length > this.l.length) { // cheio: descarta o mais velho
      const drop = this.len + l.length - this.l.length;
      this.read = (this.read + drop) % this.l.length; this.len -= drop;
    }
    let w = (this.read + this.len) % this.l.length;
    for (let i = 0; i < l.length; i++) { this.l[w] = l[i]; this.r[w] = r[i]; w = (w + 1) % this.l.length; }
    this.len += l.length;
    if (this.len > MAX) { const drop = this.len - TARGET; this.read = (this.read + drop) % this.l.length; this.len -= drop; }
  }
}

class Mix extends AudioWorkletProcessor {
  constructor() {
    super();
    this.src = new Map();
    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.clear) { this.src.clear(); return; }
      let s = this.src.get(m.id);
      if (!s) { s = new Source(); this.src.set(m.id, s); }
      s.push(m.l, m.r || m.l);
    };
  }
  process(_in, outs) {
    const out = outs[0];
    const L = out[0], R = out[1] || out[0];
    L.fill(0); if (R !== L) R.fill(0);
    for (const [id, s] of this.src) {
      // começa a tocar só com o buffer no alvo (sem picotar no começo)
      if (!s.started) { if (s.len < TARGET) continue; s.started = true; }
      const n = Math.min(L.length, s.len);
      for (let i = 0; i < n; i++) { L[i] += s.l[s.read]; R[i] += s.r[s.read]; s.read = (s.read + 1) % s.l.length; }
      s.len -= n;
      if (s.len === 0) { s.started = false; if (n === 0) this.src.delete(id); }
    }
    for (let i = 0; i < L.length; i++) { L[i] = Math.max(-1, Math.min(1, L[i])); if (R !== L) R[i] = Math.max(-1, Math.min(1, R[i])); }
    return true;
  }
}
registerProcessor('telinha-mix', Mix);
