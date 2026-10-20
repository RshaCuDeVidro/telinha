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

// Programa tocando som agora (pra escolher de quem compartilhar o áudio).
typedef struct audio_app {
    char name[64]; // nome pra mostrar e pra achar de novo ("Firefox", "spotify")
    uint32_t pid;  // um processo dele (Windows: o da sessão de áudio)
} audio_app;

// Lista os programas tocando som (sem o telinha, sem repetir). Retorna quantos.
int audio_list_apps(audio_app *out, int max);

// Som do computador (o que está tocando), sem o que o próprio telinha toca.
//   Windows: loopback do WASAPI excluindo o próprio processo.
//   Linux:   cada aplicativo ligado na nossa entrada pelo grafo do PipeWire
//            (sem PipeWire: monitor da saída padrão, que pega tudo).
// Só um programa: pid != 0 = esse processo e os filhos dele (o navegador toca
// som num processo filho); senão app = nome (como em audio_list_apps).
// Os dois vazios = tudo. Sem PipeWire no Linux, o filtro não vale (pega tudo).
audio_dev *audio_capture_open(audio_capture_fn fn, void *user, const char *app, uint32_t pid, char *err, int errlen);

// Saída padrão (caixa/fone).
audio_dev *audio_output_open(audio_play_fn fn, void *user, char *err, int errlen);

// Microfone (voz da sala): MONO a 48 kHz — o callback recebe `frames` floats.
// name = NULL ou "" usa o padrão do sistema.
audio_dev *audio_mic_open(audio_capture_fn fn, void *user, const char *name, char *err, int errlen);

// Nomes dos microfones disponíveis (até max). Retorna quantos.
int audio_list_mics(char names[][128], int max);

void audio_close(audio_dev *d);

// 1 se essa captura também pega o som que o próprio app toca (só no jeito
// antigo: monitor no Linux sem PipeWire, Windows sem loopback por processo).
// Aí quem transmite áudio precisa silenciar o que assiste, senão vira eco.
int audio_capture_hears_self(audio_dev *d);

// Para/retoma o dispositivo (sem fechar). Nunca de dentro do callback.
int audio_pause(audio_dev *d);
int audio_resume(audio_dev *d);

#ifdef __cplusplus
}
#endif
