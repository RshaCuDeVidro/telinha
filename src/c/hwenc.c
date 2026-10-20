// Escolhe o encoder em hardware: NVENC (NVIDIA) primeiro; se não der, no
// Windows o encoder do Media Foundation da placa que tiver (Intel Quick Sync,
// AMD, ...) e no Linux o VA-API (Intel/AMD). Sem nenhum, hwenc_open falha e o
// app usa o openh264.
#include "hwenc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct nvenc nvenc;
nvenc *nvenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen);
int nvenc_encode(nvenc *e, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr);
int nvenc_encode_dev(nvenc *e, uint64_t dev, int pitch, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr);
void nvenc_set_bitrate(nvenc *e, int bitrate);
const char *nvenc_name(nvenc *e);
void nvenc_close(nvenc *e);

#ifdef _WIN32
typedef struct mfenc mfenc;
mfenc *mfenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, char *err, int errlen);
int mfenc_encode(mfenc *e, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr);
void mfenc_set_bitrate(mfenc *e, int bitrate);
const char *mfenc_name(mfenc *e);
void mfenc_close(mfenc *e);
#else
typedef struct vaenc vaenc;
vaenc *vaenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen);
int vaenc_encode(vaenc *e, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr);
void vaenc_set_bitrate(vaenc *e, int bitrate);
const char *vaenc_name(vaenc *e);
void vaenc_close(vaenc *e);
#endif

enum { KIND_NV = 1, KIND_MF = 2, KIND_VA = 3 };

struct hwenc {
    int kind;
    void *impl;
};

static volatile int g_effort = 1;

void hwenc_set_effort(int effort) {
    g_effort = effort < 0 ? 0 : effort > 2 ? 2 : effort;
}

int hwenc_effort(void) {
    return g_effort;
}

hwenc *hwenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen) {
    hwenc *h = calloc(1, sizeof *h);
    if (!h) return NULL;
    char nv_err[256] = "";
    if (!getenv("TELINHA_SEM_NVENC")) {
        h->impl = nvenc_open(codec, width, height, fps, bitrate, screen_mode, temporal_layers, nv_err, sizeof nv_err);
        if (h->impl) {
            h->kind = KIND_NV;
            return h;
        }
    }
#ifdef _WIN32
    // qualquer placa (Intel/AMD/NVIDIA) pelo Media Foundation; uma camada só
    // (camadas temporais variam demais entre fabricantes)
    if (!getenv("TELINHA_SEM_MF")) {
        char mf_err[256] = "";
        h->impl = mfenc_open(codec, width, height, fps, bitrate, screen_mode, mf_err, sizeof mf_err);
        if (h->impl) {
            h->kind = KIND_MF;
            if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] encoder: %s (Media Foundation; NVENC: %s)\n", mfenc_name(h->impl), nv_err);
            return h;
        }
        if (err && errlen > 0) snprintf(err, errlen, "NVENC: %s; Media Foundation: %s", nv_err, mf_err);
        free(h);
        return NULL;
    }
#else
    if (!getenv("TELINHA_SEM_VAAPI")) {
        char va_err[256] = "";
        h->impl = vaenc_open(codec, width, height, fps, bitrate, screen_mode, temporal_layers, va_err, sizeof va_err);
        if (h->impl) {
            h->kind = KIND_VA;
            if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] encoder: %s (NVENC: %s)\n", vaenc_name(h->impl), nv_err);
            return h;
        }
        if (err && errlen > 0) snprintf(err, errlen, "NVENC: %s; VA-API: %s", nv_err, va_err);
        free(h);
        return NULL;
    }
#endif
    if (err && errlen > 0) snprintf(err, errlen, "%s", nv_err);
    free(h);
    return NULL;
}

int hwenc_encode(hwenc *h, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr) {
#ifdef _WIN32
    if (h->kind == KIND_MF) return mfenc_encode(h->impl, pixels, stride, format, force_idr, out, out_len, is_idr);
#else
    if (h->kind == KIND_VA) return vaenc_encode(h->impl, pixels, stride, format, force_idr, out, out_len, is_idr);
#endif
    return nvenc_encode(h->impl, pixels, stride, format, force_idr, out, out_len, is_idr);
}

int hwenc_accepts_cuda(hwenc *h) {
    return h->kind == KIND_NV;
}

int hwenc_is_va(hwenc *h) {
#ifdef _WIN32
    (void)h;
    return 0;
#else
    return h->kind == KIND_VA;
#endif
}

#ifndef _WIN32
int vaenc_encode_surface(vaenc *e, uint32_t surface, int force_idr, const uint8_t **out, int *out_len, int *is_idr);
#endif

int hwenc_encode_dev(hwenc *h, uint64_t dev, int pitch, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr) {
#ifndef _WIN32
    // VA-API: `dev` é a superfície NV12 do conversor (mesmo dispositivo)
    if (h->kind == KIND_VA) return vaenc_encode_surface(h->impl, (uint32_t)dev, force_idr, out, out_len, is_idr);
#endif
    if (h->kind != KIND_NV) return -1;
    return nvenc_encode_dev(h->impl, dev, pitch, format, force_idr, out, out_len, is_idr);
}

void hwenc_set_bitrate(hwenc *h, int bitrate) {
#ifdef _WIN32
    if (h->kind == KIND_MF) {
        mfenc_set_bitrate(h->impl, bitrate);
        return;
    }
#else
    if (h->kind == KIND_VA) {
        vaenc_set_bitrate(h->impl, bitrate);
        return;
    }
#endif
    nvenc_set_bitrate(h->impl, bitrate);
}

const char *hwenc_name(hwenc *h) {
#ifdef _WIN32
    if (h->kind == KIND_MF) return mfenc_name(h->impl);
#else
    if (h->kind == KIND_VA) return vaenc_name(h->impl);
#endif
    return nvenc_name(h->impl);
}

void hwenc_close(hwenc *h) {
    if (!h) return;
#ifdef _WIN32
    if (h->kind == KIND_MF) mfenc_close(h->impl);
    else
#else
    if (h->kind == KIND_VA) vaenc_close(h->impl);
    else
#endif
        nvenc_close(h->impl);
    free(h);
}
