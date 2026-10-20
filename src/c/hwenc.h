// Encoder de vídeo em hardware: NVIDIA NVENC; no Windows, se não der, o
// Media Foundation (Intel/AMD/NVIDIA); no Linux, VA-API (Intel/AMD). As
// bibliotecas são carregadas em tempo de execução: sem nenhum, hwenc_open
// falha e o app usa o encoder em software (openh264, só H.264).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hwenc hwenc;

enum { HWENC_BGRX = 0, HWENC_RGBX = 1 };

// Codecs (iguais aos de hwdec.h e do protocolo)
#ifndef HW_CODEC_H264
#define HW_CODEC_H264 0
#define HW_CODEC_HEVC 1
#define HW_CODEC_AV1 2
#endif

// Abre o encoder. screen_mode = 1 pra tela/texto, 0 pra jogo/vídeo.
// temporal_layers = 2: um quadro sim, um não, ninguém usa de referência
// (dá pra pular pra quem não dá conta).
hwenc *hwenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen);

// Peso do encoder da placa (vale no próximo hwenc_open): 0 = leve (menos
// trabalho na placa), 1 = equilibrado, 2 = qualidade.
void hwenc_set_effort(int effort);

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
