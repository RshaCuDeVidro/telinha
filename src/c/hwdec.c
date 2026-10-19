// Escolhe o decoder em hardware: NVDEC (NVIDIA) primeiro; se não der, no
// Windows o Media Foundation (DXVA: Intel/AMD/NVIDIA) e no Linux o VA-API
// (Intel/AMD). Sem nenhum, hwdec_open falha e o app usa o openh264.
#include "hwdec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct nvdec nvdec;
nvdec *nvdec_open(int codec, char *err, int errlen);
int nvdec_decode(nvdec *d, const uint8_t *data, int len, hwdec_frame *out);
void nvdec_close(nvdec *d);

#ifdef _WIN32
typedef struct mfdec mfdec;
mfdec *mfdec_open(int codec, char *err, int errlen);
int mfdec_decode(mfdec *d, const uint8_t *data, int len, hwdec_frame *out);
void mfdec_close(mfdec *d);
#define ALT_NAME "Media Foundation"
#define alt_open mfdec_open
#define alt_decode mfdec_decode
#define alt_close mfdec_close
#else
typedef struct vadec vadec;
vadec *vadec_open(int codec, char *err, int errlen);
int vadec_decode(vadec *d, const uint8_t *data, int len, hwdec_frame *out);
void vadec_close(vadec *d);
#define ALT_NAME "VA-API"
#define alt_open vadec_open
#define alt_decode vadec_decode
#define alt_close vadec_close
#endif

enum { KIND_NV = 1, KIND_ALT = 2 };

struct hwdec {
    int kind;
    void *impl;
};

hwdec *hwdec_open(int codec, char *err, int errlen) {
    hwdec *h = calloc(1, sizeof *h);
    if (!h) return NULL;
    char nv_err[256] = "", alt_err[256] = "";
    if (!getenv("TELINHA_SEM_NVDEC")) {
        h->impl = nvdec_open(codec, nv_err, sizeof nv_err);
        if (h->impl) {
            h->kind = KIND_NV;
            return h;
        }
    } else snprintf(nv_err, sizeof nv_err, "desligado (TELINHA_SEM_NVDEC)");
    if (!getenv("TELINHA_SEM_HWDEC_ALT")) {
        h->impl = alt_open(codec, alt_err, sizeof alt_err);
        if (h->impl) {
            h->kind = KIND_ALT;
            if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] decoder: %s (NVDEC: %s)\n", ALT_NAME, nv_err);
            return h;
        }
    } else snprintf(alt_err, sizeof alt_err, "desligado");
    if (err && errlen > 0) snprintf(err, errlen, "NVDEC: %s; %s: %s", nv_err, ALT_NAME, alt_err);
    free(h);
    return NULL;
}

int hwdec_decode(hwdec *h, const uint8_t *data, int len, hwdec_frame *out) {
    if (h->kind == KIND_ALT) return alt_decode(h->impl, data, len, out);
    return nvdec_decode(h->impl, data, len, out);
}

const char *hwdec_name(hwdec *h) {
    return h->kind == KIND_ALT ? ALT_NAME : "NVDEC";
}

void hwdec_close(hwdec *h) {
    if (!h) return;
    if (h->kind == KIND_ALT) alt_close(h->impl);
    else nvdec_close(h->impl);
    free(h);
}
