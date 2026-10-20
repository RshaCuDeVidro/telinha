// VA-API (Linux: Intel/AMD): decoder e encoder H.264. Normalmente usado
// pelos despachantes (hwdec.c/hwenc.c); declarado aqui pros testes.
#pragma once
#include <stdint.h>

#include "capture.h"
#include "hwdec.h"
#include "hwenc.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vadec vadec;
typedef struct vaenc vaenc;

vadec *vadec_open(int codec, char *err, int errlen);
int vadec_decode(vadec *d, const uint8_t *data, int len, hwdec_frame *out);
const char *vadec_driver(vadec *d); // nome do driver (vaQueryVendorString)
void vadec_close(vadec *d);

// Contadores pros testes: o que os fluxos decodificados até agora usaram.
typedef struct {
    int pictures, idr, mmco, long_term, reorder, weighted, multi_slice, scaling, cabac, poc_types; // poc_types: bit t = tipo t
} vadec_stats;
void vadec_get_stats(vadec *d, vadec_stats *s);

vaenc *vaenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen);
int vaenc_encode(vaenc *e, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr);
void vaenc_set_bitrate(vaenc *e, int bitrate);
const char *vaenc_name(vaenc *e);
void vaenc_close(vaenc *e);

// Encoder no dispositivo compartilhado com o conversor (aceita as superfícies dele)?
int vaenc_is_shared(vaenc *e);
// Codifica uma superfície NV12 do conversor (vapp_slot_surface). 0 = ok.
int vaenc_encode_surface(vaenc *e, uint32_t surface, int force_idr, const uint8_t **out, int *out_len, int *is_idr);

// ---- Conversor da captura (Intel/AMD, VPP): DMA-BUF RGB do compositor →
// NV12 na placa, recortado e escalado, numa superfície que o encoder lê direto.
typedef struct vapp vapp;
// Um quadro DMA-BUF do compositor (o mesmo da captura).
typedef cap_dmabuf vapp_src;
// Abre (VPP + encoder H.264 no mesmo driver) e faz o autoteste de cor.
vapp *vapp_open(char *err, int errlen);
void vapp_close(vapp *p);
// Recorta (x, y, w, h), escala pra ow x oh e converte pra NV12 no slot.
// `key` identifica o buffer (a importação fica guardada). 0 = ok.
int vapp_convert(vapp *p, const void *key, const vapp_src *src, int x, int y, int w, int h, int ow, int oh, int slot);
uint32_t vapp_slot_surface(vapp *p, int slot);
// Prévia pequena em RGBA (pw x ph). 0 = ok.
int vapp_preview(vapp *p, const void *key, const vapp_src *src, int x, int y, int w, int h, int pw, int ph, uint8_t *rgba);
// Esquece a importação do buffer `key` (NULL = todas).
void vapp_forget(vapp *p, const void *key);

// Teste sem placa: gera SPS/PPS do encoder (vários tamanhos/perfis), lê de
// volta com o parser do decoder e confere com os parâmetros que iriam pro
// driver. 0 = ok; senão o motivo em err.
int hwva_test_headers(char *err, int errlen);

#ifdef __cplusplus
}
#endif
