// Decoder H.264 em hardware (hoje: NVIDIA NVDEC). Bibliotecas do driver
// carregadas em tempo de execução; sem NVIDIA, hwdec_open falha e o app usa o
// openh264.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct hwdec hwdec;

typedef struct hwdec_frame {
    const uint8_t *y;  // luma, largura x altura (pitch = width)
    const uint8_t *uv; // croma intercalado (NV12), largura x altura/2
    int width, height;
} hwdec_frame;

hwdec *hwdec_open(char *err, int errlen);

// Decodifica um quadro completo. 1 = imagem em *out (válida até a próxima
// chamada), 0 = nenhuma imagem ainda, <0 = erro (recomece de um IDR).
int hwdec_decode(hwdec *d, const uint8_t *data, int len, hwdec_frame *out);

void hwdec_close(hwdec *d);

#ifdef __cplusplus
}
#endif
