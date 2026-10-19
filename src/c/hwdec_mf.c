// Decoder H.264 do Media Foundation (DXVA: qualquer placa). AINDA NÃO FEITO.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

#include "hwdec.h"

typedef struct mfdec mfdec;

mfdec *mfdec_open(int codec, char *err, int errlen) {
    (void)codec;
    if (err && errlen > 0) snprintf(err, errlen, "ainda não implementado");
    return NULL;
}

int mfdec_decode(mfdec *d, const uint8_t *data, int len, hwdec_frame *out) {
    (void)d, (void)data, (void)len, (void)out;
    return -1;
}

void mfdec_close(mfdec *d) {
    (void)d;
}
