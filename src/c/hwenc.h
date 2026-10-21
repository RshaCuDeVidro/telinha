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

// Esse encoder aceita o quadro já na memória da placa (ponteiro CUDA, ver
// cudagl.c)? Só o NVENC.
int hwenc_accepts_cuda(hwenc *e);
// É o VA-API (Intel/AMD no Linux)? Aí o caminho pela placa é o conversor
// (vapp, hwva.h), e o "ponteiro" do hwenc_encode_dev é uma superfície dele.
int hwenc_is_va(hwenc *e);
// Windows: o encoder (Media Foundation) recebe a textura NV12 da captura direto.
int hwenc_accepts_d3d(hwenc *e);
// Windows: como hwenc_open, mas o encoder do Media Foundation recebe as
// texturas NV12 do dispositivo D3D11 da captura (ver d3dvp_win.c).
hwenc *hwenc_open_d3d(void *d3d_dev, int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen);
// Windows: é o encoder do Media Foundation (Intel/AMD/qualquer placa)?
int hwenc_is_mf(hwenc *e);

// Codifica um quadro RGBX/BGRX que já está na placa (hwenc_accepts_cuda).
int hwenc_encode_dev(hwenc *e, uint64_t dev, int pitch, int format, int force_idr,
                     const uint8_t **out, int *out_len, int *is_idr);

void hwenc_set_bitrate(hwenc *e, int bitrate);
const char *hwenc_name(hwenc *e);
void hwenc_close(hwenc *e);

#ifdef __cplusplus
}
#endif
