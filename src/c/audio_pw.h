// Linux: som dos outros aplicativos via grafo do PipeWire (sem o próprio
// telinha). Ver audio_pw.c.
#pragma once

#include <stdint.h>

#include "audio.h"

typedef struct pwcap pwcap;

// Recebe `frames` quadros estéreo float32 a 48 kHz.
typedef void (*pwcap_fn)(void *user, const float *samples, int frames);

// NULL = sem PipeWire (aí quem chama usa o monitor da saída padrão).
// app/pid: só esse programa (ver audio_capture_open); vazios = todos.
// exclude: nomes (separados por \n) que ficam de fora; NULL = nenhum.
pwcap *pwcap_open(pwcap_fn fn, void *user, const char *app, uint32_t pid, const char *exclude, char *err, int errlen);

// Programas tocando som agora (nome = application.name), sem o telinha.
int pwcap_list_apps(audio_app *out, int max);
void pwcap_close(pwcap *c);

// Quantas ligações (porta de aplicativo → nossa entrada) existem agora.
int pwcap_links(pwcap *c);
