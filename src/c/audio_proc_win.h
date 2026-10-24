// Windows: loopback por processo do WASAPI (audio_proc_win.c).
#pragma once
#include <stdint.h>
#include "audio.h"

typedef struct proc_loop proc_loop;

// exclude = 0: só o processo `pid` e os filhos; 1: tudo menos ele e os filhos.
// Bloqueia até abrir (ou falhar); o callback roda numa thread própria.
proc_loop *proc_loop_open(uint32_t pid, int exclude, audio_capture_fn fn, void *user, char *err, int errlen);
void proc_loop_close(proc_loop *p);
