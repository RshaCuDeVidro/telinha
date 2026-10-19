// Linux: som dos outros aplicativos via grafo do PipeWire (sem o próprio
// telinha). Ver audio_pw.c.
#pragma once

typedef struct pwcap pwcap;

// Recebe `frames` quadros estéreo float32 a 48 kHz.
typedef void (*pwcap_fn)(void *user, const float *samples, int frames);

// NULL = sem PipeWire (aí quem chama usa o monitor da saída padrão).
pwcap *pwcap_open(pwcap_fn fn, void *user, char *err, int errlen);
void pwcap_close(pwcap *c);

// Quantas ligações (porta de aplicativo → nossa entrada) existem agora.
int pwcap_links(pwcap *c);
