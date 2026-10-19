// VA-API (Linux: Intel/AMD): decoder e encoder H.264. Normalmente usado
// pelos despachantes (hwdec.c/hwenc.c); declarado aqui pros testes.
#pragma once
#include <stdint.h>

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

// Teste sem placa: gera SPS/PPS do encoder (vários tamanhos/perfis), lê de
// volta com o parser do decoder e confere com os parâmetros que iriam pro
// driver. 0 = ok; senão o motivo em err.
int hwva_test_headers(char *err, int errlen);

#ifdef __cplusplus
}
#endif
