// Encoder H.264 em hardware (hoje: NVIDIA NVENC). As bibliotecas do driver
// são carregadas em tempo de execução: sem placa/driver, hwenc_open falha e o
// app usa o encoder em software (openh264).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hwenc hwenc;

enum { HWENC_BGRX = 0, HWENC_RGBX = 1 };

// Abre o encoder. screen_mode = 1 pra tela/texto, 0 pra jogo/vídeo.
hwenc *hwenc_open(int width, int height, int fps, int bitrate, int screen_mode, char *err, int errlen);

// Codifica um quadro BGRX/RGBX. *out aponta pra um buffer interno válido até a
// próxima chamada. Retorna 0 em sucesso.
int hwenc_encode(hwenc *e, const uint8_t *pixels, int stride, int format, int force_idr,
                 const uint8_t **out, int *out_len, int *is_idr);

void hwenc_set_bitrate(hwenc *e, int bitrate);
const char *hwenc_name(hwenc *e);
void hwenc_close(hwenc *e);

#ifdef __cplusplus
}
#endif
