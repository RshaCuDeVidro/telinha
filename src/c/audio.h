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

// Som do computador (o que está tocando).
//   Windows: loopback do WASAPI excluindo o próprio processo (sem eco).
//   Linux:   monitor da saída padrão via PulseAudio/PipeWire.
audio_dev *audio_capture_open(audio_capture_fn fn, void *user, char *err, int errlen);

// Saída padrão (caixa/fone).
audio_dev *audio_output_open(audio_play_fn fn, void *user, char *err, int errlen);

void audio_close(audio_dev *d);

// 1 se a captura do Linux também pega o som que o próprio app toca (aí quem
// transmite áudio precisa silenciar o que assiste, senão vira eco).
int audio_capture_hears_self(void);

#ifdef __cplusplus
}
#endif
