// Decoder de vídeo em hardware: NVIDIA NVDEC; no Windows, se não der, o
// Media Foundation (DXVA, qualquer placa); no Linux, VA-API (Intel/AMD).
// Bibliotecas carregadas em tempo de execução; sem nenhum, hwdec_open falha e
// o app usa o openh264.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hwdec hwdec;

// Codecs (iguais aos de hwenc.h e do protocolo)
#ifndef HW_CODEC_H264
#define HW_CODEC_H264 0
#define HW_CODEC_HEVC 1
#define HW_CODEC_AV1 2
#endif

typedef struct hwdec_frame {
    const uint8_t *y;  // luma, largura x altura (pitch = width)
    const uint8_t *uv; // croma intercalado (NV12), largura x altura/2
    int width, height;
} hwdec_frame;

hwdec *hwdec_open(int codec, char *err, int errlen);

// Decodifica um quadro completo. 1 = imagem em *out (válida até a próxima
// chamada), 0 = nenhuma imagem ainda, <0 = erro (recomece de um IDR).
int hwdec_decode(hwdec *d, const uint8_t *data, int len, hwdec_frame *out);

const char *hwdec_name(hwdec *d); // "NVDEC", "Media Foundation", "VA-API"...

// Decodifica esse codec na placa? (só pergunta, sem abrir decoder)
int hwdec_supports(int codec);
void hwdec_close(hwdec *d);

#ifdef __cplusplus
}
#endif
