// H.264 em hardware de qualquer placa no Windows (Intel Quick Sync, AMD AMF,
// NVIDIA...) pelo Media Foundation, quando o NVENC não está disponível.
//
// Acha o encoder de hardware registrado (MFTEnumEx), liga o modo de baixa
// latência, taxa constante (CBR), sem B-frames e GOP enorme (IDR só quando
// pedirem). Encoders de hardware são assíncronos: esperam o pedido de entrada
// (METransformNeedInput) e avisam quando tem saída (METransformHaveOutput).
// Entrada em NV12 (convertida aqui, com a mesma conta BT.601 do openh264).
// As DLLs do Media Foundation são carregadas em tempo de execução.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <icodecapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hwenc.h"

// GUIDs (conferidos com o SDK; definidos aqui pra não depender da mfuuid)
static const GUID G_CAT_VIDEO_ENCODER = {0xf79eac7d, 0xe545, 0x4387, {0xbd, 0xee, 0xd6, 0x47, 0xd7, 0xbd, 0xe4, 0x2a}};
static const GUID G_MEDIATYPE_VIDEO = {0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_FORMAT_NV12 = {0x3231564e, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_FORMAT_H264 = {0x34363248, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_MT_MAJOR_TYPE = {0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}};
static const GUID G_MT_SUBTYPE = {0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}};
static const GUID G_MT_FRAME_SIZE = {0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}};
static const GUID G_MT_FRAME_RATE = {0xc459a2e8, 0x3d2c, 0x4e44, {0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0}};
static const GUID G_MT_AVG_BITRATE = {0x20332624, 0xfb0d, 0x4d9e, {0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e}};
static const GUID G_MT_INTERLACE_MODE = {0xe2724bb8, 0xe676, 0x4806, {0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd}};
static const GUID G_MT_MPEG2_PROFILE = {0xad76a80b, 0x2d5c, 0x4e0b, {0xb3, 0x75, 0x64, 0xe5, 0x20, 0x13, 0x70, 0x36}};
static const GUID G_MT_PIXEL_ASPECT = {0xc6376a1e, 0x8d0a, 0x4027, {0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6}};
static const GUID G_TRANSFORM_ASYNC = {0xf81a699a, 0x649a, 0x497d, {0x8c, 0x73, 0x29, 0xf8, 0xfe, 0xd6, 0xad, 0x7a}};
static const GUID G_TRANSFORM_ASYNC_UNLOCK = {0xe5666d6b, 0x3422, 0x4eb6, {0xa4, 0x21, 0xda, 0x7d, 0xb1, 0xf8, 0xe2, 0x07}};
static const GUID G_FRIENDLY_NAME = {0x314ffbae, 0x5b41, 0x4c95, {0x9c, 0x19, 0x4e, 0x7d, 0x58, 0x6f, 0xac, 0xe3}};
static const GUID G_CLEAN_POINT = {0x9cdf01d8, 0xa0f0, 0x43ba, {0xb0, 0x77, 0xea, 0xa0, 0x6c, 0xbd, 0x72, 0x8a}};
static const GUID G_IID_TRANSFORM = {0xbf94c121, 0x5b05, 0x4e6f, {0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d}};
static const GUID G_IID_EVENT_GEN = {0x2cd0bd52, 0xbcd5, 0x4b89, {0xb6, 0x2c, 0xea, 0xdc, 0x0c, 0x03, 0x1e, 0x7d}};
static const GUID G_IID_CODECAPI = {0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}};
static const GUID G_LOW_LATENCY = {0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};
static const GUID G_RATE_CONTROL = {0x1c0608e9, 0x370c, 0x4710, {0x8a, 0x58, 0xcb, 0x61, 0x81, 0xc4, 0x24, 0x23}};
static const GUID G_MEAN_BITRATE = {0xf7222374, 0x2144, 0x4815, {0xb5, 0x50, 0xa3, 0x7f, 0x8e, 0x12, 0xee, 0x52}};
static const GUID G_GOP_SIZE = {0x95f31b26, 0x95a4, 0x41aa, {0x93, 0x03, 0x24, 0x6a, 0x7f, 0xc6, 0xee, 0xf1}};
static const GUID G_B_FRAMES = {0x8d390aac, 0xdc5c, 0x4200, {0xb5, 0x7f, 0x81, 0x4d, 0x04, 0xba, 0xba, 0xb2}};
static const GUID G_FORCE_KEY = {0x398c1b98, 0x8353, 0x475a, {0x9e, 0xf2, 0x8f, 0x26, 0x5d, 0x26, 0x03, 0x45}};
static const GUID G_QUALITY_SPEED = {0x98332df8, 0x03cd, 0x476b, {0x89, 0xfa, 0x3f, 0x9e, 0x44, 0x2d, 0xec, 0x9f}};

#define EVENT_NEED_INPUT 601
#define EVENT_HAVE_OUTPUT 602
#define E_NO_EVENTS ((HRESULT)0xC00D3E80)
#define E_NEED_MORE_INPUT ((HRESULT)0xC00D6D72)
#define E_STREAM_CHANGE ((HRESULT)0xC00D6D61)

static struct {
    int tried, ok;
    HRESULT(WINAPI *Startup)(ULONG, DWORD);
    HRESULT(WINAPI *TEnumEx)(GUID, UINT32, const MFT_REGISTER_TYPE_INFO *, const MFT_REGISTER_TYPE_INFO *, IMFActivate ***, UINT32 *);
    HRESULT(WINAPI *CreateMediaType)(IMFMediaType **);
    HRESULT(WINAPI *CreateSample)(IMFSample **);
    HRESULT(WINAPI *CreateMemoryBuffer)(DWORD, IMFMediaBuffer **);
} mf;

static int mf_load(void) {
    if (mf.tried) return mf.ok;
    mf.tried = 1;
    HMODULE plat = LoadLibraryW(L"mfplat.dll");
    if (!plat) return 0;
    mf.Startup = (HRESULT(WINAPI *)(ULONG, DWORD))(void *)GetProcAddress(plat, "MFStartup");
    mf.TEnumEx = (HRESULT(WINAPI *)(GUID, UINT32, const MFT_REGISTER_TYPE_INFO *, const MFT_REGISTER_TYPE_INFO *, IMFActivate ***, UINT32 *))(void *)GetProcAddress(plat, "MFTEnumEx");
    mf.CreateMediaType = (HRESULT(WINAPI *)(IMFMediaType **))(void *)GetProcAddress(plat, "MFCreateMediaType");
    mf.CreateSample = (HRESULT(WINAPI *)(IMFSample **))(void *)GetProcAddress(plat, "MFCreateSample");
    mf.CreateMemoryBuffer = (HRESULT(WINAPI *)(DWORD, IMFMediaBuffer **))(void *)GetProcAddress(plat, "MFCreateMemoryBuffer");
    if (!mf.Startup || !mf.TEnumEx || !mf.CreateMediaType || !mf.CreateSample || !mf.CreateMemoryBuffer) return 0;
    if (FAILED(mf.Startup(0x00020070, 1 /* MFSTARTUP_LITE */))) return 0;
    mf.ok = 1;
    return 1;
}

struct mfenc {
    IMFTransform *mft;
    IMFMediaEventGenerator *events; // NULL = encoder síncrono
    ICodecAPI *codec;
    int w, h, fps;
    int need_input; // pedidos de entrada ainda não atendidos
    int provides_samples;
    DWORD out_size;
    LONGLONG ts; // 100 ns
    uint8_t *out;
    size_t out_cap, out_len;
    int out_key;
    char name[96];
};

static void set_err(char *err, int errlen, const char *msg, HRESULT hr) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (0x%08lx)", msg, (unsigned long)hr);
}

static void codec_u32(ICodecAPI *c, const GUID *g, UINT32 v) {
    VARIANT var;
    memset(&var, 0, sizeof var);
    var.vt = VT_UI4;
    var.ulVal = v;
    ICodecAPI_SetValue(c, g, &var);
}

static void codec_bool(ICodecAPI *c, const GUID *g, int v) {
    VARIANT var;
    memset(&var, 0, sizeof var);
    var.vt = VT_BOOL;
    var.boolVal = v ? VARIANT_TRUE : VARIANT_FALSE;
    ICodecAPI_SetValue(c, g, &var);
}

static void set_video_type(IMFMediaType *t, const GUID *subtype, int w, int h, int fps) {
    IMFMediaType_SetGUID(t, &G_MT_MAJOR_TYPE, &G_MEDIATYPE_VIDEO);
    IMFMediaType_SetGUID(t, &G_MT_SUBTYPE, subtype);
    IMFMediaType_SetUINT64(t, &G_MT_FRAME_SIZE, ((UINT64)w << 32) | (UINT32)h);
    IMFMediaType_SetUINT64(t, &G_MT_FRAME_RATE, ((UINT64)fps << 32) | 1);
    IMFMediaType_SetUINT64(t, &G_MT_PIXEL_ASPECT, ((UINT64)1 << 32) | 1);
    IMFMediaType_SetUINT32(t, &G_MT_INTERLACE_MODE, 2 /* progressivo */);
}

static void short_name(const WCHAR *friendly, char *out, int cap) {
    char n8[160] = "";
    if (friendly) WideCharToMultiByte(CP_UTF8, 0, friendly, -1, n8, sizeof n8, NULL, NULL);
    if (strstr(n8, "Intel")) snprintf(out, cap, "Intel Quick Sync");
    else if (strstr(n8, "AMD")) snprintf(out, cap, "AMD (AMF)");
    else if (strstr(n8, "NVIDIA")) snprintf(out, cap, "NVIDIA (Media Foundation)");
    else if (n8[0]) snprintf(out, cap, "%.40s", n8);
    else snprintf(out, cap, "Media Foundation");
}

void mfenc_close(struct mfenc *e) {
    if (!e) return;
    if (e->mft) {
        IMFTransform_ProcessMessage(e->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        IMFTransform_Release(e->mft);
    }
    if (e->events) IMFMediaEventGenerator_Release(e->events);
    if (e->codec) ICodecAPI_Release(e->codec);
    free(e->out);
    free(e);
}

// Configura um encoder já ativado. 0 = pronto.
static HRESULT configure(struct mfenc *e, int bitrate, int screen_mode) {
    IMFAttributes *attr = NULL;
    if (SUCCEEDED(IMFTransform_GetAttributes(e->mft, &attr)) && attr) {
        UINT32 async = 0;
        if (SUCCEEDED(IMFAttributes_GetUINT32(attr, &G_TRANSFORM_ASYNC, &async)) && async) {
            IMFAttributes_SetUINT32(attr, &G_TRANSFORM_ASYNC_UNLOCK, TRUE);
            IMFTransform_QueryInterface(e->mft, &G_IID_EVENT_GEN, (void **)&e->events);
        }
        IMFAttributes_Release(attr);
    }
    if (SUCCEEDED(IMFTransform_QueryInterface(e->mft, &G_IID_CODECAPI, (void **)&e->codec)) && e->codec) {
        codec_bool(e->codec, &G_LOW_LATENCY, 1);
        codec_u32(e->codec, &G_RATE_CONTROL, 0 /* CBR */);
        codec_u32(e->codec, &G_MEAN_BITRATE, (UINT32)bitrate);
        codec_u32(e->codec, &G_GOP_SIZE, 0xFFFF);
        codec_u32(e->codec, &G_B_FRAMES, 0);
        // tela/texto: mais qualidade por bit; jogo: mais velocidade
        codec_u32(e->codec, &G_QUALITY_SPEED, screen_mode ? 70 : 40);
    }
    // saída antes da entrada (é o que os encoders pedem)
    IMFMediaType *t = NULL;
    HRESULT hr = mf.CreateMediaType(&t);
    if (FAILED(hr)) return hr;
    set_video_type(t, &G_FORMAT_H264, e->w, e->h, e->fps);
    IMFMediaType_SetUINT32(t, &G_MT_AVG_BITRATE, (UINT32)bitrate);
    IMFMediaType_SetUINT32(t, &G_MT_MPEG2_PROFILE, 100 /* High */);
    hr = IMFTransform_SetOutputType(e->mft, 0, t, 0);
    if (FAILED(hr)) {
        // nem todo encoder aceita High: tenta Main
        IMFMediaType_SetUINT32(t, &G_MT_MPEG2_PROFILE, 77);
        hr = IMFTransform_SetOutputType(e->mft, 0, t, 0);
    }
    IMFMediaType_Release(t);
    if (FAILED(hr)) return hr;
    hr = mf.CreateMediaType(&t);
    if (FAILED(hr)) return hr;
    set_video_type(t, &G_FORMAT_NV12, e->w, e->h, e->fps);
    hr = IMFTransform_SetInputType(e->mft, 0, t, 0);
    IMFMediaType_Release(t);
    if (FAILED(hr)) return hr;
    MFT_OUTPUT_STREAM_INFO si;
    memset(&si, 0, sizeof si);
    IMFTransform_GetOutputStreamInfo(e->mft, 0, &si);
    e->provides_samples = (si.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
    e->out_size = si.cbSize ? si.cbSize : (DWORD)(e->w * e->h * 3 / 2);
    IMFTransform_ProcessMessage(e->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    IMFTransform_ProcessMessage(e->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return S_OK;
}

struct mfenc *mfenc_open(int width, int height, int fps, int bitrate, int screen_mode, char *err, int errlen) {
    if (!mf_load()) {
        set_err(err, errlen, "sem Media Foundation", 0);
        return NULL;
    }
    CoInitializeEx(NULL, COINIT_MULTITHREADED); // essa é a thread do encoder
    MFT_REGISTER_TYPE_INFO in = {G_MEDIATYPE_VIDEO, G_FORMAT_NV12};
    MFT_REGISTER_TYPE_INFO out = {G_MEDIATYPE_VIDEO, G_FORMAT_H264};
    IMFActivate **acts = NULL;
    UINT32 n = 0;
    // TELINHA_MF_SOFTWARE=1 (diagnóstico): aceita encoder de software também
    const UINT32 kinds = getenv("TELINHA_MF_SOFTWARE") ? (MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE) : MFT_ENUM_FLAG_HARDWARE;
    HRESULT hr = mf.TEnumEx(G_CAT_VIDEO_ENCODER, kinds | MFT_ENUM_FLAG_SORTANDFILTER, &in, &out, &acts, &n);
    if (FAILED(hr) || n == 0) {
        if (acts) CoTaskMemFree(acts);
        set_err(err, errlen, "nenhum encoder H.264 de hardware no Media Foundation", hr);
        return NULL;
    }
    struct mfenc *e = NULL;
    for (UINT32 i = 0; i < n && !e; i++) {
        struct mfenc *t = calloc(1, sizeof *t);
        if (!t) break;
        t->w = width & ~1;
        t->h = height & ~1;
        t->fps = fps > 0 ? fps : 30;
        WCHAR *friendly = NULL;
        UINT32 len = 0;
        IMFActivate_GetAllocatedString(acts[i], &G_FRIENDLY_NAME, &friendly, &len);
        short_name(friendly, t->name, sizeof t->name);
        if (friendly) CoTaskMemFree(friendly);
        hr = IMFActivate_ActivateObject(acts[i], &G_IID_TRANSFORM, (void **)&t->mft);
        if (SUCCEEDED(hr) && t->mft && SUCCEEDED(hr = configure(t, bitrate, screen_mode))) {
            e = t;
        } else {
            set_err(err, errlen, "o encoder de hardware não aceitou a configuração", hr);
            mfenc_close(t);
        }
    }
    for (UINT32 i = 0; i < n; i++) IMFActivate_Release(acts[i]);
    CoTaskMemFree(acts);
    return e;
}

// BGRX/RGBX → NV12 (BT.601 faixa limitada, igual ao openh264 do app).
static void to_nv12(const uint8_t *src, int stride, int w, int h, int format, uint8_t *dst) {
    const int ri = format == HWENC_RGBX ? 0 : 2, bi = format == HWENC_RGBX ? 2 : 0;
    uint8_t *uv = dst + (size_t)w * h;
    for (int y = 0; y < h; y += 2) {
        const uint8_t *r0 = src + (size_t)y * stride, *r1 = r0 + stride;
        uint8_t *y0 = dst + (size_t)y * w, *y1 = y0 + w;
        uint8_t *uvr = uv + (size_t)(y / 2) * w;
        for (int x = 0; x < w; x += 2) {
            int R = 0, G = 0, B = 0;
            for (int k = 0; k < 4; k++) {
                const uint8_t *p = (k < 2 ? r0 : r1) + (size_t)(x + (k & 1)) * 4;
                const int r = p[ri], g = p[1], b = p[bi];
                const int yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                (k < 2 ? y0 : y1)[x + (k & 1)] = (uint8_t)(yy > 255 ? 255 : yy);
                R += r;
                G += g;
                B += b;
            }
            R = (R + 2) / 4;
            G = (G + 2) / 4;
            B = (B + 2) / 4;
            const int u = ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
            const int v = ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;
            uvr[x] = (uint8_t)(u < 0 ? 0 : u > 255 ? 255 : u);
            uvr[x + 1] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
    }
}

// Tem fatia IDR (NAL tipo 5) no Annex B? Nem todo encoder marca a amostra.
static int has_idr(const uint8_t *d, size_t n) {
    for (size_t i = 0; i + 3 < n; i++) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            if ((d[i + 3] & 0x1F) == 5) return 1;
            i += 2;
        }
    }
    return 0;
}

// Tira uma saída do encoder (junta em e->out). 1 = tirou, 0 = não tinha, -1 = erro.
static int pull_output(struct mfenc *e) {
    MFT_OUTPUT_DATA_BUFFER odb;
    memset(&odb, 0, sizeof odb);
    IMFSample *own = NULL;
    if (!e->provides_samples) {
        IMFMediaBuffer *b = NULL;
        if (FAILED(mf.CreateSample(&own)) || FAILED(mf.CreateMemoryBuffer(e->out_size, &b))) {
            if (own) IMFSample_Release(own);
            return -1;
        }
        IMFSample_AddBuffer(own, b);
        IMFMediaBuffer_Release(b);
        odb.pSample = own;
    }
    DWORD status = 0;
    HRESULT hr = IMFTransform_ProcessOutput(e->mft, 0, 1, &odb, &status);
    if (hr == E_STREAM_CHANGE) {
        // o encoder mudou o formato de saída: aceita o que ele oferece
        IMFMediaType *t = NULL;
        if (SUCCEEDED(IMFTransform_GetOutputAvailableType(e->mft, 0, 0, &t))) {
            IMFTransform_SetOutputType(e->mft, 0, t, 0);
            IMFMediaType_Release(t);
        }
        if (own) IMFSample_Release(own);
        if (odb.pEvents) IMFCollection_Release(odb.pEvents);
        return 0;
    }
    if (hr == E_NEED_MORE_INPUT || FAILED(hr)) {
        if (own) IMFSample_Release(own);
        if (odb.pEvents) IMFCollection_Release(odb.pEvents);
        return hr == E_NEED_MORE_INPUT ? 0 : -1;
    }
    IMFSample *s = odb.pSample;
    int ok = 0;
    if (s) {
        UINT32 clean = 0;
        if (SUCCEEDED(IMFSample_GetUINT32(s, &G_CLEAN_POINT, &clean)) && clean) e->out_key = 1;
        IMFMediaBuffer *b = NULL;
        if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(s, &b))) {
            BYTE *data = NULL;
            DWORD len = 0;
            if (SUCCEEDED(IMFMediaBuffer_Lock(b, &data, NULL, &len))) {
                if (e->out_len + len > e->out_cap) {
                    size_t cap = (e->out_len + len) * 2;
                    uint8_t *nb = realloc(e->out, cap);
                    if (nb) {
                        e->out = nb;
                        e->out_cap = cap;
                    }
                }
                if (e->out_len + len <= e->out_cap) {
                    memcpy(e->out + e->out_len, data, len);
                    e->out_len += len;
                    ok = 1;
                }
                IMFMediaBuffer_Unlock(b);
            }
            IMFMediaBuffer_Release(b);
        }
        IMFSample_Release(s);
    }
    if (odb.pEvents) IMFCollection_Release(odb.pEvents);
    return ok;
}

// Encoder assíncrono: processa eventos por até `ms`. Para quando `until` acontecer.
static int pump(struct mfenc *e, int until, int ms) {
    for (int waited = 0; waited <= ms;) {
        IMFMediaEvent *ev = NULL;
        HRESULT hr = IMFMediaEventGenerator_GetEvent(e->events, 1 /* MF_EVENT_FLAG_NO_WAIT */, &ev);
        if (hr == E_NO_EVENTS) {
            Sleep(1);
            waited += 1;
            continue;
        }
        if (FAILED(hr) || !ev) return -1;
        MediaEventType type = 0;
        IMFMediaEvent_GetType(ev, &type);
        IMFMediaEvent_Release(ev);
        if (type == EVENT_NEED_INPUT) e->need_input++;
        else if (type == EVENT_HAVE_OUTPUT) {
            if (pull_output(e) < 0) return -1;
        }
        if ((int)type == until) return 1;
    }
    return 0;
}

int mfenc_encode(struct mfenc *e, const uint8_t *pixels, int stride, int format, int force_idr,
                 const uint8_t **out, int *out_len, int *is_idr) {
    e->out_len = 0;
    e->out_key = 0;
    const DWORD size = (DWORD)(e->w * e->h * 3 / 2);
    IMFMediaBuffer *buf = NULL;
    IMFSample *sample = NULL;
    if (FAILED(mf.CreateMemoryBuffer(size, &buf))) return -1;
    BYTE *p = NULL;
    if (FAILED(IMFMediaBuffer_Lock(buf, &p, NULL, NULL))) {
        IMFMediaBuffer_Release(buf);
        return -1;
    }
    to_nv12(pixels, stride, e->w, e->h, format, p);
    IMFMediaBuffer_Unlock(buf);
    IMFMediaBuffer_SetCurrentLength(buf, size);
    if (FAILED(mf.CreateSample(&sample))) {
        IMFMediaBuffer_Release(buf);
        return -1;
    }
    IMFSample_AddBuffer(sample, buf);
    IMFMediaBuffer_Release(buf);
    const LONGLONG dur = 10000000LL / e->fps;
    IMFSample_SetSampleTime(sample, e->ts);
    IMFSample_SetSampleDuration(sample, dur);
    e->ts += dur;
    if (force_idr && e->codec) codec_u32(e->codec, &G_FORCE_KEY, 1);

    int rc = 0;
    if (e->events) {
        // assíncrono: espera o pedido de entrada, entrega, espera a saída
        if (e->need_input == 0 && pump(e, EVENT_NEED_INPUT, 500) <= 0 && e->need_input == 0) rc = -1;
        if (rc == 0) {
            e->need_input--;
            if (FAILED(IMFTransform_ProcessInput(e->mft, 0, sample, 0))) rc = -1;
        }
        if (rc == 0 && e->out_len == 0 && pump(e, EVENT_HAVE_OUTPUT, 1000) < 0) rc = -1;
    } else {
        // síncrono: entrega e tira tudo o que sair
        if (FAILED(IMFTransform_ProcessInput(e->mft, 0, sample, 0))) rc = -1;
        while (rc == 0) {
            int r = pull_output(e);
            if (r < 0) rc = -1;
            if (r <= 0) break;
        }
    }
    IMFSample_Release(sample);
    if (rc < 0) return -1;
    *out = e->out;
    *out_len = (int)e->out_len;
    *is_idr = e->out_key || has_idr(e->out, e->out_len);
    return 0;
}

void mfenc_set_bitrate(struct mfenc *e, int bitrate) {
    if (e->codec) codec_u32(e->codec, &G_MEAN_BITRATE, (UINT32)bitrate);
}

const char *mfenc_name(struct mfenc *e) {
    return e->name;
}
