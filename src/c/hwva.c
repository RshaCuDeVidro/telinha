// VA-API (Linux: Intel/AMD): encoder e decoder. AINDA NÃO FEITO.
#include <stdio.h>
#include <stdint.h>

#include "hwdec.h"
#include "hwenc.h"

typedef struct vadec vadec;
typedef struct vaenc vaenc;

vadec *vadec_open(int codec, char *err, int errlen) {
    (void)codec;
    if (err && errlen > 0) snprintf(err, errlen, "ainda não implementado");
    return NULL;
}

int vadec_decode(vadec *d, const uint8_t *data, int len, hwdec_frame *out) {
    (void)d, (void)data, (void)len, (void)out;
    return -1;
}

void vadec_close(vadec *d) {
    (void)d;
}

vaenc *vaenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen) {
    (void)codec, (void)width, (void)height, (void)fps, (void)bitrate, (void)screen_mode, (void)temporal_layers;
    if (err && errlen > 0) snprintf(err, errlen, "ainda não implementado");
    return NULL;
}

int vaenc_encode(vaenc *e, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr) {
    (void)e, (void)pixels, (void)stride, (void)format, (void)force_idr, (void)out, (void)out_len, (void)is_idr;
    return -1;
}

void vaenc_set_bitrate(vaenc *e, int bitrate) {
    (void)e, (void)bitrate;
}

const char *vaenc_name(vaenc *e) {
    (void)e;
    return "VA-API";
}

void vaenc_close(vaenc *e) {
    (void)e;
}
