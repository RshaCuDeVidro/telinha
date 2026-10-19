// Câmera (webcam), entregue em quadros BGRX como a captura de tela.
//   Linux:   PipeWire (as webcams aparecem como nós Video/Source pelo
//            WirePlumber; YUYV/NV12/I420/RGB, e MJPEG com libturbojpeg)
//   Windows: Media Foundation (IMFSourceReader convertendo pra RGB32)
#pragma once
#include "capture.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cam_device {
    char id[160];   // identificador estável (nó do PipeWire / link simbólico no Windows)
    char name[160]; // nome pra mostrar
} cam_device;

typedef struct cam_ctx cam_ctx;

// Lista as câmeras. Retorna quantas escreveu (0 = nenhuma ou sem suporte).
int cam_list(cam_device *out, int max);

// Abre a câmera `id` (vazio = a primeira) pedindo esse tamanho/fps (a câmera
// escolhe o mais próximo que tiver). NULL + err em caso de falha.
cam_ctx *cam_open(const char *id, int width, int height, int fps, char *err, int errlen);

// Espera um quadro por até timeout_ms: 1 = quadro novo (BGRX) em *out,
// 0 = nada ainda, -1 = erro (err preenchido).
int cam_next(cam_ctx *ctx, cap_frame *out, int timeout_ms, char *err, int errlen);

const char *cam_backend(cam_ctx *ctx);
void cam_close(cam_ctx *ctx);

#ifdef __cplusplus
}
#endif
