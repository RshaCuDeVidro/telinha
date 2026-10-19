// Áudio: captura do som do computador e saída pra caixa/fone (miniaudio).
// Sempre float32 estéreo intercalado a 48 kHz.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AUDIO_RATE 48000
#define AUDIO_CHANNELS 2

typedef struct audio_dev audio_dev;

// Recebe `frames` quadros (cada quadro = 2 floats) capturados.
typedef void (*audio_capture_fn)(void *user, const float *samples, int frames);
// Preenche `frames` quadros pra tocar.
typedef void (*audio_play_fn)(void *user, float *samples, int frames);

// Som do computador (o que está tocando), sem o que o próprio telinha toca.
//   Windows: loopback do WASAPI excluindo o próprio processo.
//   Linux:   cada aplicativo ligado na nossa entrada pelo grafo do PipeWire
//            (sem PipeWire: monitor da saída padrão, que pega tudo).
audio_dev *audio_capture_open(audio_capture_fn fn, void *user, char *err, int errlen);

// Saída padrão (caixa/fone).
audio_dev *audio_output_open(audio_play_fn fn, void *user, char *err, int errlen);

void audio_close(audio_dev *d);

// 1 se essa captura também pega o som que o próprio app toca (só no jeito
// antigo: monitor no Linux sem PipeWire, Windows sem loopback por processo).
// Aí quem transmite áudio precisa silenciar o que assiste, senão vira eco.
int audio_capture_hears_self(audio_dev *d);

#ifdef __cplusplus
}
#endif
