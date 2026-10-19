// Câmera no Windows pelo Media Foundation: IMFSourceReader com o conversor de
// vídeo ligado entregando RGB32 (= BGRX). As DLLs do Media Foundation são
// carregadas em tempo de execução: no Windows "N" (sem Media Feature Pack) o
// .exe continua abrindo, só sem câmera.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "camera.h"

// GUIDs (conferidos com o SDK; definidos aqui pra não depender da mfuuid)
static const GUID G_SOURCE_TYPE = {0xc60ac5fe, 0x252a, 0x478f, {0xa0, 0xef, 0xbc, 0x8f, 0xa5, 0xf7, 0xca, 0xd3}};
static const GUID G_SOURCE_TYPE_VIDCAP = {0x8ac3587a, 0x4ae7, 0x42d8, {0x99, 0xe0, 0x0a, 0x60, 0x13, 0xee, 0xf9, 0x0f}};
static const GUID G_FRIENDLY_NAME = {0x60d0e559, 0x52f8, 0x4fa2, {0xbb, 0xce, 0xac, 0xdb, 0x34, 0xa8, 0xec, 0x01}};
static const GUID G_SYMBOLIC_LINK = {0x58f0aad8, 0x22bf, 0x4f8a, {0xbb, 0x3d, 0xd2, 0xc4, 0x97, 0x8c, 0x6e, 0x2f}};
static const GUID G_ENABLE_VIDEO_PROCESSING = {0xfb394f3d, 0xccf1, 0x42ee, {0xbb, 0xb3, 0xf9, 0xb8, 0x45, 0xd5, 0x68, 0x1d}};
static const GUID G_MT_MAJOR_TYPE = {0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}};
static const GUID G_MT_SUBTYPE = {0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}};
static const GUID G_MT_FRAME_SIZE = {0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}};
static const GUID G_MT_FRAME_RATE = {0xc459a2e8, 0x3d2c, 0x4e44, {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}};
static const GUID G_MT_DEFAULT_STRIDE = {0x644b4e48, 0x1e02, 0x4516, {0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6}};
static const GUID G_MEDIATYPE_VIDEO = {0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_FORMAT_RGB32 = {0x00000016, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_IID_MEDIA_SOURCE = {0x279a808d, 0xaec7, 0x40c8, {0x9c, 0x6b, 0xa6, 0xb4, 0x92, 0xc7, 0x8a, 0x66}};
static const GUID G_IID_2D_BUFFER = {0x7dc9d5f9, 0x9ed9, 0x44ec, {0x9b, 0xbf, 0x06, 0x00, 0xbb, 0x58, 0x9f, 0xbb}};

#define READER_VIDEO ((DWORD)0xFFFFFFFC) // MF_SOURCE_READER_FIRST_VIDEO_STREAM
#define MF_VERSION_ 0x00020070
#define NO_MORE_TYPES ((HRESULT)0xC00D36B9) // MF_E_NO_MORE_TYPES

static struct {
    int tried, ok;
    HRESULT(WINAPI *Startup)(ULONG, DWORD);
    HRESULT(WINAPI *CreateAttributes)(IMFAttributes **, UINT32);
    HRESULT(WINAPI *CreateMediaType)(IMFMediaType **);
    HRESULT(WINAPI *EnumDeviceSources)(IMFAttributes *, IMFActivate ***, UINT32 *);
    HRESULT(WINAPI *CreateSourceReaderFromMediaSource)(IMFMediaSource *, IMFAttributes *, IMFSourceReader **);
} mf;

static int mf_load(void) {
    if (mf.tried) return mf.ok;
    mf.tried = 1;
    HMODULE plat = LoadLibraryW(L"mfplat.dll"), mfd = LoadLibraryW(L"mf.dll"), rw = LoadLibraryW(L"mfreadwrite.dll");
    if (!plat || !mfd || !rw) return 0;
    mf.Startup = (HRESULT(WINAPI *)(ULONG, DWORD))(void *)GetProcAddress(plat, "MFStartup");
    mf.CreateAttributes = (HRESULT(WINAPI *)(IMFAttributes **, UINT32))(void *)GetProcAddress(plat, "MFCreateAttributes");
    mf.CreateMediaType = (HRESULT(WINAPI *)(IMFMediaType **))(void *)GetProcAddress(plat, "MFCreateMediaType");
    mf.EnumDeviceSources = (HRESULT(WINAPI *)(IMFAttributes *, IMFActivate ***, UINT32 *))(void *)GetProcAddress(mfd, "MFEnumDeviceSources");
    mf.CreateSourceReaderFromMediaSource = (HRESULT(WINAPI *)(IMFMediaSource *, IMFAttributes *, IMFSourceReader **))(void *)GetProcAddress(rw, "MFCreateSourceReaderFromMediaSource");
    if (!mf.Startup || !mf.CreateAttributes || !mf.CreateMediaType || !mf.EnumDeviceSources || !mf.CreateSourceReaderFromMediaSource) return 0;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(mf.Startup(MF_VERSION_, 1 /* MFSTARTUP_LITE */))) return 0;
    mf.ok = 1;
    return 1;
}

static void set_err(char *err, int errlen, const char *msg) {
    if (err && errlen > 0) snprintf(err, errlen, "%s", msg);
}

static void wide_to_utf8(const WCHAR *w, char *out, int cap) {
    if (!w || WideCharToMultiByte(CP_UTF8, 0, w, -1, out, cap, NULL, NULL) <= 0) out[0] = 0;
}

// Lista as câmeras (e devolve os IMFActivate se `acts` não for NULL; quem chama libera).
static int enum_devices(IMFActivate ***acts_out, UINT32 *count) {
    *acts_out = NULL;
    *count = 0;
    if (!mf_load()) return -1;
    IMFAttributes *attr = NULL;
    if (FAILED(mf.CreateAttributes(&attr, 1))) return -1;
    IMFAttributes_SetGUID(attr, &G_SOURCE_TYPE, &G_SOURCE_TYPE_VIDCAP);
    HRESULT hr = mf.EnumDeviceSources(attr, acts_out, count);
    IMFAttributes_Release(attr);
    return FAILED(hr) ? -1 : 0;
}

static void free_devices(IMFActivate **acts, UINT32 n) {
    for (UINT32 i = 0; i < n; i++) IMFActivate_Release(acts[i]);
    CoTaskMemFree(acts);
}

static void device_info(IMFActivate *a, cam_device *d) {
    WCHAR *s = NULL;
    UINT32 len = 0;
    d->id[0] = d->name[0] = 0;
    if (SUCCEEDED(IMFActivate_GetAllocatedString(a, &G_SYMBOLIC_LINK, &s, &len))) {
        wide_to_utf8(s, d->id, sizeof d->id);
        CoTaskMemFree(s);
    }
    if (SUCCEEDED(IMFActivate_GetAllocatedString(a, &G_FRIENDLY_NAME, &s, &len))) {
        wide_to_utf8(s, d->name, sizeof d->name);
        CoTaskMemFree(s);
    }
    if (!d->name[0]) snprintf(d->name, sizeof d->name, "Câmera");
}

int cam_list(cam_device *out, int max) {
    IMFActivate **acts;
    UINT32 n;
    if (enum_devices(&acts, &n) < 0) return 0;
    int k = 0;
    for (UINT32 i = 0; i < n && k < max; i++) device_info(acts[i], &out[k++]);
    free_devices(acts, n);
    return k;
}

struct cam_ctx {
    IMFSourceReader *reader;
    IMFMediaSource *source;
    HANDLE thread;
    volatile LONG stop;
    int w, h;
    LONG stride; // do tipo de saída (negativo = de baixo pra cima)

    SRWLOCK lock;
    CONDITION_VARIABLE cond;
    uint8_t *pending;
    uint8_t *front;
    int fresh;
    int failed;
    char fail_msg[160];
};

static DWORD WINAPI reader_thread(void *arg) {
    struct cam_ctx *c = arg;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    size_t need = (size_t)c->w * c->h * 4;
    while (!c->stop) {
        DWORD stream = 0, flags = 0;
        LONGLONG ts = 0;
        IMFSample *sample = NULL;
        HRESULT hr = IMFSourceReader_ReadSample(c->reader, READER_VIDEO, 0, &stream, &flags, &ts, &sample);
        if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
            AcquireSRWLockExclusive(&c->lock);
            c->failed = 1;
            snprintf(c->fail_msg, sizeof c->fail_msg, "a câmera parou (desconectada ou em uso por outro programa)");
            WakeAllConditionVariable(&c->cond);
            ReleaseSRWLockExclusive(&c->lock);
            break;
        }
        if (!sample) continue;
        IMFMediaBuffer *buf = NULL;
        if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buf))) {
            BYTE *scan0 = NULL;
            LONG pitch = 0;
            IMF2DBuffer *b2 = NULL;
            int locked2d = 0;
            BYTE *raw = NULL;
            DWORD len = 0;
            if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buf, &G_IID_2D_BUFFER, (void **)&b2)) && SUCCEEDED(IMF2DBuffer_Lock2D(b2, &scan0, &pitch))) {
                locked2d = 1;
            } else if (SUCCEEDED(IMFMediaBuffer_Lock(buf, &raw, NULL, &len))) {
                pitch = c->stride ? c->stride : c->w * 4;
                scan0 = pitch < 0 ? raw + (size_t)(-pitch) * (c->h - 1) : raw;
                if ((size_t)len < (size_t)(pitch < 0 ? -pitch : pitch) * c->h) scan0 = NULL;
            }
            if (scan0) {
                AcquireSRWLockExclusive(&c->lock);
                if (c->pending)
                    for (int y = 0; y < c->h; y++) {
                        uint8_t *d = c->pending + (size_t)y * c->w * 4;
                        memcpy(d, scan0 + (LONG_PTR)y * pitch, (size_t)c->w * 4);
                        for (int x = 0; x < c->w; x++) d[x * 4 + 3] = 255;
                    }
                c->fresh = 1;
                WakeAllConditionVariable(&c->cond);
                ReleaseSRWLockExclusive(&c->lock);
            }
            if (locked2d) IMF2DBuffer_Unlock2D(b2);
            else if (raw) IMFMediaBuffer_Unlock(buf);
            if (b2) IMF2DBuffer_Release(b2);
            IMFMediaBuffer_Release(buf);
        }
        IMFSample_Release(sample);
    }
    (void)need;
    return 0;
}

// Escolhe o formato nativo mais perto do pedido (tamanho primeiro, depois fps).
static IMFMediaType *pick_native(IMFSourceReader *r, int want_w, int want_h, int want_fps, UINT32 *ow, UINT32 *oh) {
    IMFMediaType *best = NULL;
    double best_score = 1e18;
    for (DWORD i = 0;; i++) {
        IMFMediaType *mt = NULL;
        HRESULT hr = IMFSourceReader_GetNativeMediaType(r, READER_VIDEO, i, &mt);
        if (hr == NO_MORE_TYPES || FAILED(hr)) break;
        UINT64 size = 0, rate = 0;
        IMFMediaType_GetUINT64(mt, &G_MT_FRAME_SIZE, &size);
        IMFMediaType_GetUINT64(mt, &G_MT_FRAME_RATE, &rate);
        UINT32 w = (UINT32)(size >> 32), h = (UINT32)size;
        double fps = (UINT32)rate ? (double)(UINT32)(rate >> 32) / (double)(UINT32)rate : 0;
        double dh = (double)h - want_h;
        double score = (dh < 0 ? -dh * 2 : dh) + (fps < want_fps ? (want_fps - fps) * 20 : 0) + (double)w * 0.001;
        if (w == 0 || h == 0) score = 1e17;
        if (score < best_score) {
            if (best) IMFMediaType_Release(best);
            best = mt;
            best_score = score;
            *ow = w;
            *oh = h;
        } else {
            IMFMediaType_Release(mt);
        }
    }
    return best;
}

cam_ctx *cam_open(const char *id, int width, int height, int fps, char *err, int errlen) {
    IMFActivate **acts;
    UINT32 n;
    if (enum_devices(&acts, &n) < 0) {
        set_err(err, errlen, "Esse Windows não tem Media Foundation (Windows N sem o Media Feature Pack?).");
        return NULL;
    }
    if (n == 0) {
        free_devices(acts, n);
        set_err(err, errlen, "Nenhuma câmera encontrada.");
        return NULL;
    }
    UINT32 pick = 0;
    for (UINT32 i = 0; id && *id && i < n; i++) {
        cam_device d;
        device_info(acts[i], &d);
        if (strcmp(d.id, id) == 0) pick = i;
    }
    struct cam_ctx *c = calloc(1, sizeof *c);
    InitializeSRWLock(&c->lock);
    InitializeConditionVariable(&c->cond);
    HRESULT hr = IMFActivate_ActivateObject(acts[pick], &G_IID_MEDIA_SOURCE, (void **)&c->source);
    free_devices(acts, n);
    if (FAILED(hr)) {
        free(c);
        set_err(err, errlen, "Não consegui abrir a câmera (outro programa está usando?).");
        return NULL;
    }
    IMFAttributes *attr = NULL;
    mf.CreateAttributes(&attr, 1);
    if (attr) IMFAttributes_SetUINT32(attr, &G_ENABLE_VIDEO_PROCESSING, TRUE);
    hr = mf.CreateSourceReaderFromMediaSource(c->source, attr, &c->reader);
    if (attr) IMFAttributes_Release(attr);
    if (FAILED(hr)) {
        set_err(err, errlen, "Não consegui ler a câmera.");
        cam_close(c);
        return NULL;
    }
    UINT32 w = 0, h = 0;
    IMFMediaType *native = pick_native(c->reader, width > 0 ? width : 1280, height > 0 ? height : 720, fps > 0 ? fps : 30, &w, &h);
    if (native) {
        IMFSourceReader_SetCurrentMediaType(c->reader, READER_VIDEO, NULL, native);
        IMFMediaType_Release(native);
    }
    // saída em RGB32 no mesmo tamanho (o conversor do Media Foundation faz o resto)
    IMFMediaType *out = NULL;
    mf.CreateMediaType(&out);
    IMFMediaType_SetGUID(out, &G_MT_MAJOR_TYPE, &G_MEDIATYPE_VIDEO);
    IMFMediaType_SetGUID(out, &G_MT_SUBTYPE, &G_FORMAT_RGB32);
    if (w && h) IMFMediaType_SetUINT64(out, &G_MT_FRAME_SIZE, ((UINT64)w << 32) | h);
    hr = IMFSourceReader_SetCurrentMediaType(c->reader, READER_VIDEO, NULL, out);
    IMFMediaType_Release(out);
    if (FAILED(hr)) {
        set_err(err, errlen, "A câmera não aceitou nenhum formato que o telinha entende.");
        cam_close(c);
        return NULL;
    }
    IMFMediaType *cur = NULL;
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(c->reader, READER_VIDEO, &cur))) {
        UINT64 size = 0;
        IMFMediaType_GetUINT64(cur, &G_MT_FRAME_SIZE, &size);
        w = (UINT32)(size >> 32);
        h = (UINT32)size;
        UINT32 stride = 0;
        if (SUCCEEDED(IMFMediaType_GetUINT32(cur, &G_MT_DEFAULT_STRIDE, &stride))) c->stride = (LONG)stride;
        IMFMediaType_Release(cur);
    }
    if (!w || !h || w > 8192 || h > 8192) {
        set_err(err, errlen, "A câmera informou um tamanho inválido.");
        cam_close(c);
        return NULL;
    }
    c->w = (int)w;
    c->h = (int)h;
    c->pending = malloc((size_t)w * h * 4);
    c->front = malloc((size_t)w * h * 4);
    c->thread = CreateThread(NULL, 0, reader_thread, c, 0, NULL);
    if (!c->pending || !c->front || !c->thread) {
        set_err(err, errlen, "Sem memória pra câmera.");
        cam_close(c);
        return NULL;
    }
    return c;
}

int cam_next(cam_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
    AcquireSRWLockExclusive(&c->lock);
    if (!c->fresh && !c->failed) SleepConditionVariableSRW(&c->cond, &c->lock, (DWORD)timeout_ms, 0);
    if (c->failed) {
        set_err(err, errlen, c->fail_msg);
        ReleaseSRWLockExclusive(&c->lock);
        return -1;
    }
    if (!c->fresh) {
        ReleaseSRWLockExclusive(&c->lock);
        return 0;
    }
    uint8_t *tmp = c->front;
    c->front = c->pending;
    c->pending = tmp;
    c->fresh = 0;
    ReleaseSRWLockExclusive(&c->lock);
    memset(out, 0, sizeof *out);
    out->data = c->front;
    out->width = c->w;
    out->height = c->h;
    out->stride = c->w * 4;
    out->format = CAP_BGRX;
    return 1;
}

const char *cam_backend(cam_ctx *c) {
    (void)c;
    return "Media Foundation";
}

void cam_close(cam_ctx *c) {
    if (!c) return;
    InterlockedExchange(&c->stop, 1);
    if (c->source) IMFMediaSource_Shutdown(c->source); // destrava o ReadSample
    if (c->thread) {
        WaitForSingleObject(c->thread, 3000);
        CloseHandle(c->thread);
    }
    if (c->reader) IMFSourceReader_Release(c->reader);
    if (c->source) IMFMediaSource_Release(c->source);
    free(c->pending);
    free(c->front);
    free(c);
}
