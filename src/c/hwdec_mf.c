// Decoder H.264 do Media Foundation no Windows: DXVA de qualquer placa
// (Intel, AMD, NVIDIA), quando o NVDEC não está disponível.
//
// O decoder H.264 da Microsoft é um MFT síncrono que decodifica na placa
// quando recebe um IMFDXGIDeviceManager (MFT_MESSAGE_SET_D3D_MANAGER): a
// saída vira textura NV12, copiada pra uma textura de leitura (staging) e
// compactada num NV12 na memória. Sem a placa ele decodificaria em software,
// e aí não vale a pena (o app já tem o openh264): falha. Com
// TELINHA_MF_SOFTWARE=1 (diagnóstico; é o que funciona no wine) é só software.
// Modo de baixa latência: a imagem de cada quadro sai na mesma chamada (os
// streams não têm B-frames). As DLLs do Media Foundation são carregadas em
// tempo de execução.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3d10.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <icodecapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hwdec.h"

// GUIDs (conferidos com o SDK; definidos aqui pra não depender da mfuuid)
static const GUID G_CAT_VIDEO_DECODER = {0xd6c02d4b, 0x6833, 0x45b4, {0x97, 0x1a, 0x05, 0xa4, 0xb0, 0x4b, 0xab, 0x91}};
static const GUID G_MEDIATYPE_VIDEO = {0x73646976, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_FORMAT_NV12 = {0x3231564e, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_FORMAT_H264 = {0x34363248, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const GUID G_MT_MAJOR_TYPE = {0x48eba18e, 0xf8c9, 0x4687, {0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f}};
static const GUID G_MT_SUBTYPE = {0xf7e34c9a, 0x42e8, 0x4714, {0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5}};
static const GUID G_MT_FRAME_SIZE = {0x1652c33d, 0xd6b2, 0x4012, {0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d}};
static const GUID G_MT_INTERLACE_MODE = {0xe2724bb8, 0xe676, 0x4806, {0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd}};
static const GUID G_MT_MIN_APERTURE = {0xd7388766, 0x18fe, 0x48c6, {0xa1, 0x77, 0xee, 0x89, 0x48, 0x67, 0xc8, 0xc4}};
static const GUID G_MT_DEFAULT_STRIDE = {0x644b4e48, 0x1e02, 0x4516, {0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6}};
static const GUID G_LOW_LATENCY = {0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};
static const GUID G_D3D11_AWARE = {0x206b4fc8, 0xfcf9, 0x4c51, {0xaf, 0xe3, 0x97, 0x64, 0x36, 0x9e, 0x33, 0xa0}};
static const GUID G_CLSID_MS_H264_DEC = {0x62ce7e72, 0x4c71, 0x4d20, {0xb1, 0x5d, 0x45, 0x28, 0x31, 0xa8, 0x7d, 0x9d}};
static const GUID G_IID_TRANSFORM = {0xbf94c121, 0x5b05, 0x4e6f, {0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d}};
static const GUID G_IID_CODECAPI = {0x901db4c7, 0x31ce, 0x41a2, {0x85, 0xdc, 0x8f, 0xa0, 0xbf, 0x41, 0xb8, 0xda}};
static const GUID G_IID_DXGI_BUFFER = {0xe7174cfa, 0x1c9e, 0x48b1, {0x88, 0x66, 0x62, 0x62, 0x26, 0xbf, 0xc2, 0x58}};
static const GUID G_IID_2D_BUFFER = {0x7dc9d5f9, 0x9ed9, 0x44ec, {0x9b, 0xbf, 0x06, 0x00, 0xbb, 0x58, 0x9f, 0xbb}};
static const GUID G_IID_TEXTURE2D = {0x6f15aaf2, 0xd208, 0x4e89, {0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c}};
static const GUID G_IID_MULTITHREAD = {0x9b7e4e00, 0x342c, 0x4106, {0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0}};

#define E_NOT_ACCEPTING ((HRESULT)0xC00D36B5)
#define E_NEED_MORE_INPUT ((HRESULT)0xC00D6D72)
#define E_STREAM_CHANGE ((HRESULT)0xC00D6D61)

static struct {
    int tried, ok;
    HRESULT(WINAPI *Startup)(ULONG, DWORD);
    HRESULT(WINAPI *TEnumEx)(GUID, UINT32, const MFT_REGISTER_TYPE_INFO *, const MFT_REGISTER_TYPE_INFO *, IMFActivate ***, UINT32 *);
    HRESULT(WINAPI *CreateMediaType)(IMFMediaType **);
    HRESULT(WINAPI *CreateSample)(IMFSample **);
    HRESULT(WINAPI *CreateMemoryBuffer)(DWORD, IMFMediaBuffer **);
    HRESULT(WINAPI *CreateDXGIDeviceManager)(UINT *, IMFDXGIDeviceManager **); // Windows 8+
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
    mf.CreateDXGIDeviceManager = (HRESULT(WINAPI *)(UINT *, IMFDXGIDeviceManager **))(void *)GetProcAddress(plat, "MFCreateDXGIDeviceManager");
    if (!mf.Startup || !mf.TEnumEx || !mf.CreateMediaType || !mf.CreateSample || !mf.CreateMemoryBuffer) return 0;
    if (FAILED(mf.Startup(0x00020070, 1 /* MFSTARTUP_LITE */))) return 0;
    mf.ok = 1;
    return 1;
}

typedef struct mfdec {
    IMFTransform *mft;
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IMFDXGIDeviceManager *mgr;
    ID3D11Texture2D *staging; // cópia da saída que a CPU consegue ler
    D3D11_TEXTURE2D_DESC st;
    int gpu; // o decoder aceitou a placa (saída em textura)
    int allow_sw;
    // quadros desde o último SPS ([u32 tamanho][dados]...), pra recomeçar
    // com um decoder novo sem esperar outro IDR; n = -1: passou do limite
    uint8_t *keep;
    size_t keep_len, keep_cap;
    int keep_n;
    int provides_samples;
    DWORD out_size;
    int fw, fh;   // quadro decodificado (alinhado a 16)
    int stride;   // pitch da saída em memória, quando não tem IMF2DBuffer
    int cx, cy;   // recorte: onde começa a imagem de verdade
    int w, h;     // ...e o tamanho dela
    LONGLONG ts;  // 100 ns
    uint8_t *buf; // NV12 compacto entregue
    size_t cap;
} mfdec;

static void set_err(char *err, int errlen, const char *msg, HRESULT hr) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (0x%08lx)", msg, (unsigned long)hr);
}

// Com TELINHA_DEBUG: por que um quadro não saiu (o app só vê o -1).
static void dbg(const char *msg, HRESULT hr) {
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] Media Foundation: %s (0x%08lx)\n", msg, (unsigned long)hr);
}

static void release_mft(mfdec *d);

void mfdec_close(mfdec *d) {
    if (!d) return;
    release_mft(d);
    if (d->staging) ID3D11Texture2D_Release(d->staging);
    if (d->mgr) IMFDXGIDeviceManager_Release(d->mgr);
    if (d->ctx) ID3D11DeviceContext_Release(d->ctx);
    if (d->dev) ID3D11Device_Release(d->dev);
    free(d->buf);
    free(d->keep);
    free(d);
}

// Dispositivo D3D11 com vídeo + gerenciador pro decoder usar a placa.
static HRESULT make_device(mfdec *d) {
    if (!mf.CreateDXGIDeviceManager) return E_NOTIMPL;
    static const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    const UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags, levels, 4, D3D11_SDK_VERSION, &d->dev, NULL, &d->ctx);
    if (hr == E_INVALIDARG) // Direct3D 11.0 sem o nível 11_1
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags, levels + 1, 3, D3D11_SDK_VERSION, &d->dev, NULL, &d->ctx);
    if (FAILED(hr)) return hr;
    // o decoder usa o mesmo contexto em outra thread dele
    ID3D10Multithread *mt = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(d->dev, &G_IID_MULTITHREAD, (void **)&mt)) && mt) {
        ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
        ID3D10Multithread_Release(mt);
    }
    UINT token = 0;
    hr = mf.CreateDXGIDeviceManager(&token, &d->mgr);
    if (FAILED(hr)) return hr;
    return IMFDXGIDeviceManager_ResetDevice(d->mgr, (IUnknown *)d->dev, token);
}

// Lê tamanho e recorte do tipo de saída atual.
static void read_output_type(mfdec *d) {
    IMFMediaType *t = NULL;
    if (FAILED(IMFTransform_GetOutputCurrentType(d->mft, 0, &t)) || !t) return;
    UINT64 fs = 0;
    if (SUCCEEDED(IMFMediaType_GetUINT64(t, &G_MT_FRAME_SIZE, &fs))) {
        d->fw = (int)(fs >> 32);
        d->fh = (int)(fs & 0xFFFFFFFF);
    }
    d->cx = d->cy = 0;
    d->w = d->fw;
    d->h = d->fh;
    // o quadro vem alinhado a 16 (1080 → 1088): a abertura diz o que é imagem
    MFVideoArea a;
    UINT32 sz = 0;
    if (SUCCEEDED(IMFMediaType_GetBlob(t, &G_MT_MIN_APERTURE, (UINT8 *)&a, sizeof a, &sz)) && sz >= sizeof a && a.Area.cx > 0 && a.Area.cy > 0) {
        d->cx = a.OffsetX.value > 0 ? a.OffsetX.value : 0;
        d->cy = a.OffsetY.value > 0 ? a.OffsetY.value : 0;
        d->w = a.Area.cx;
        d->h = a.Area.cy;
    }
    if (d->cx + d->w > d->fw) d->w = d->fw - d->cx;
    if (d->cy + d->h > d->fh) d->h = d->fh - d->cy;
    // NV12: croma em pares de pixels
    d->cx &= ~1;
    d->cy &= ~1;
    d->w &= ~1;
    d->h &= ~1;
    UINT32 stride = 0;
    d->stride = SUCCEEDED(IMFMediaType_GetUINT32(t, &G_MT_DEFAULT_STRIDE, &stride)) && (INT32)stride > 0 ? (int)stride : d->fw;
    IMFMediaType_Release(t);
}

// Escolhe a saída NV12 entre as que o decoder oferece agora.
static HRESULT set_nv12_output(mfdec *d) {
    HRESULT hr = E_FAIL;
    for (DWORD i = 0;; i++) {
        IMFMediaType *t = NULL;
        if (FAILED(IMFTransform_GetOutputAvailableType(d->mft, 0, i, &t)) || !t) break;
        GUID sub;
        if (SUCCEEDED(IMFMediaType_GetGUID(t, &G_MT_SUBTYPE, &sub)) && IsEqualGUID(&sub, &G_FORMAT_NV12)) {
            hr = IMFTransform_SetOutputType(d->mft, 0, t, 0);
            IMFMediaType_Release(t);
            break;
        }
        IMFMediaType_Release(t);
    }
    if (FAILED(hr)) return hr;
    read_output_type(d);
    MFT_OUTPUT_STREAM_INFO si;
    memset(&si, 0, sizeof si);
    IMFTransform_GetOutputStreamInfo(d->mft, 0, &si);
    d->provides_samples = (si.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
    d->out_size = si.cbSize ? si.cbSize : (DWORD)(d->stride * d->fh * 3 / 2);
    return S_OK;
}

// Configura um decoder já ativado. allow_sw: sem a placa (d->mgr NULL) vale.
static HRESULT configure(mfdec *d, int allow_sw, const char **why) {
    IMFAttributes *attr = NULL;
    UINT32 aware = 0;
    if (SUCCEEDED(IMFTransform_GetAttributes(d->mft, &attr)) && attr) {
        IMFAttributes_SetUINT32(attr, &G_LOW_LATENCY, TRUE);
        IMFAttributes_GetUINT32(attr, &G_D3D11_AWARE, &aware);
        IMFAttributes_Release(attr);
    }
    ICodecAPI *codec = NULL;
    if (SUCCEEDED(IMFTransform_QueryInterface(d->mft, &G_IID_CODECAPI, (void **)&codec)) && codec) {
        VARIANT v;
        memset(&v, 0, sizeof v);
        // o mesmo pedido pela ICodecAPI (CODECAPI_AVLowLatencyMode é VT_BOOL)
        v.vt = VT_BOOL;
        v.boolVal = VARIANT_TRUE;
        ICodecAPI_SetValue(codec, &G_LOW_LATENCY, &v);
        ICodecAPI_Release(codec);
    }
    HRESULT hr = S_OK;
    if (d->mgr && aware) {
        // a placa entra antes dos tipos (o decoder escolhe a saída por ela)
        hr = IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)d->mgr);
        d->gpu = SUCCEEDED(hr);
    }
    if (!d->gpu && !allow_sw) {
        *why = !d->mgr ? "sem Direct3D 11 com vídeo" : !aware ? "o decoder não usa Direct3D 11" : "o decoder recusou a placa (seria só software)";
        return FAILED(hr) ? hr : E_FAIL;
    }
    IMFMediaType *t = NULL;
    hr = mf.CreateMediaType(&t);
    if (FAILED(hr)) return hr;
    IMFMediaType_SetGUID(t, &G_MT_MAJOR_TYPE, &G_MEDIATYPE_VIDEO);
    IMFMediaType_SetGUID(t, &G_MT_SUBTYPE, &G_FORMAT_H264);
    IMFMediaType_SetUINT32(t, &G_MT_INTERLACE_MODE, 2 /* progressivo */);
    hr = IMFTransform_SetInputType(d->mft, 0, t, 0);
    IMFMediaType_Release(t);
    if (FAILED(hr)) {
        *why = "o decoder não aceitou H.264";
        return hr;
    }
    // o tamanho de verdade só chega com o SPS (MF_E_TRANSFORM_STREAM_CHANGE)
    hr = set_nv12_output(d);
    if (FAILED(hr)) {
        *why = "o decoder não oferece saída NV12";
        return hr;
    }
    IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return S_OK;
}

// Solta o decoder (o dispositivo fica).
static void release_mft(mfdec *d) {
    if (!d->mft) return;
    IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    // solta o gerenciador antes de destruir o dispositivo
    if (d->gpu) IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_SET_D3D_MANAGER, 0);
    IMFTransform_Release(d->mft);
    d->mft = NULL;
    d->gpu = 0;
}

// Acha e configura um decoder H.264 (o dispositivo já existe).
static HRESULT create_mft(mfdec *d, const char **why) {
    MFT_REGISTER_TYPE_INFO in = {G_MEDIATYPE_VIDEO, G_FORMAT_H264};
    MFT_REGISTER_TYPE_INFO out = {G_MEDIATYPE_VIDEO, G_FORMAT_NV12};
    IMFActivate **acts = NULL;
    UINT32 n = 0;
    // decoders de vídeo são MFTs síncronos (o DXVA vem do gerenciador D3D)
    HRESULT hr = mf.TEnumEx(G_CAT_VIDEO_DECODER, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, &in, &out, &acts, &n);
    if (FAILED(hr)) n = 0;
    *why = "nenhum decoder H.264 no Media Foundation";
    for (UINT32 i = 0; i <= n; i++) {
        if (i < n) {
            hr = IMFActivate_ActivateObject(acts[i], &G_IID_TRANSFORM, (void **)&d->mft);
        } else if (n == 0) {
            // enumeração vazia: tenta o da Microsoft direto
            hr = CoCreateInstance(&G_CLSID_MS_H264_DEC, NULL, CLSCTX_INPROC_SERVER, &G_IID_TRANSFORM, (void **)&d->mft);
        } else break;
        if (SUCCEEDED(hr) && d->mft && SUCCEEDED(hr = configure(d, d->allow_sw, why))) break;
        release_mft(d);
        if (SUCCEEDED(hr)) hr = E_FAIL;
    }
    for (UINT32 i = 0; i < n; i++) IMFActivate_Release(acts[i]);
    if (acts) CoTaskMemFree(acts);
    return d->mft ? S_OK : hr;
}

static int under_wine(void) {
    HMODULE nt = GetModuleHandleW(L"ntdll.dll");
    return nt && GetProcAddress(nt, "wine_get_version") != NULL;
}

mfdec *mfdec_open(int codec, char *err, int errlen) {
    if (codec != HW_CODEC_H264) {
        set_err(err, errlen, "codec ainda não suportado no Media Foundation", 0);
        return NULL;
    }
    if (!mf_load()) {
        set_err(err, errlen, "sem Media Foundation", 0);
        return NULL;
    }
    // TELINHA_MF_SOFTWARE=1 (diagnóstico): decodifica em software, sem a placa
    const int allow_sw = getenv("TELINHA_MF_SOFTWARE") != NULL;
    if (!allow_sw && under_wine()) {
        // lá o decoder aceita o Direct3D, mas o wined3d não sabe ler textura
        // NV12: a imagem sairia zerada (verde). Fica o openh264
        set_err(err, errlen, "no wine a saída na placa vem vazia", 0);
        return NULL;
    }
    CoInitializeEx(NULL, COINIT_MULTITHREADED); // essa é a thread do decoder
    mfdec *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->allow_sw = allow_sw;
    d->keep_n = -1; // nada guardado até o primeiro SPS
    HRESULT hr = S_OK;
    if (!d->allow_sw && FAILED(hr = make_device(d))) {
        set_err(err, errlen, "sem Direct3D 11 com vídeo", hr);
        mfdec_close(d);
        return NULL;
    }
    const char *why = "";
    hr = create_mft(d, &why);
    if (FAILED(hr)) {
        set_err(err, errlen, why, hr);
        mfdec_close(d);
        return NULL;
    }
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] Media Foundation: decodificando %s\n", d->gpu ? "na placa (DXVA)" : "em software");
    return d;
}

// Copia o recorte (planos com pitch qualquer) pro NV12 compacto.
static void pack(mfdec *d, const uint8_t *y, int ypitch, const uint8_t *uv, int uvpitch) {
    const int w = d->w, h = d->h;
    uint8_t *dy = d->buf, *duv = d->buf + (size_t)w * h;
    for (int r = 0; r < h; r++) memcpy(dy + (size_t)r * w, y + (ptrdiff_t)(d->cy + r) * ypitch + d->cx, w);
    for (int r = 0; r < h / 2; r++) memcpy(duv + (size_t)r * w, uv + (ptrdiff_t)(d->cy / 2 + r) * uvpitch + d->cx, w);
}

// Textura da placa → staging → memória. 0 = ok.
static int copy_texture(mfdec *d, IMFDXGIBuffer *db) {
    ID3D11Texture2D *tex = NULL;
    UINT sub = 0;
    if (FAILED(IMFDXGIBuffer_GetResource(db, &G_IID_TEXTURE2D, (void **)&tex)) || !tex) return -1;
    IMFDXGIBuffer_GetSubresourceIndex(db, &sub);
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(tex, &td);
    int rc = -1;
    if (td.Format != DXGI_FORMAT_NV12 || (int)td.Width < d->cx + d->w || (int)td.Height < d->cy + d->h) {
        if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] Media Foundation: textura %ux%u formato %d, imagem %dx%d\n", td.Width, td.Height, (int)td.Format, d->w, d->h);
        goto done;
    }
    if (!d->staging || d->st.Width != td.Width || d->st.Height != td.Height) {
        if (d->staging) ID3D11Texture2D_Release(d->staging);
        d->staging = NULL;
        D3D11_TEXTURE2D_DESC sd;
        memset(&sd, 0, sizeof sd);
        sd.Width = td.Width;
        sd.Height = td.Height;
        sd.MipLevels = 1;
        sd.ArraySize = 1;
        sd.Format = DXGI_FORMAT_NV12;
        sd.SampleDesc.Count = 1;
        sd.Usage = D3D11_USAGE_STAGING;
        sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(ID3D11Device_CreateTexture2D(d->dev, &sd, NULL, &d->staging))) goto done;
        d->st = sd;
    }
    // o decoder entrega uma fatia de um array de texturas
    ID3D11DeviceContext_CopySubresourceRegion(d->ctx, (ID3D11Resource *)d->staging, 0, 0, 0, 0, (ID3D11Resource *)tex, sub, NULL);
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(d->ctx, (ID3D11Resource *)d->staging, 0, D3D11_MAP_READ, 0, &m))) goto done;
    const uint8_t *p = m.pData;
    pack(d, p, (int)m.RowPitch, p + (size_t)m.RowPitch * td.Height, (int)m.RowPitch);
    ID3D11DeviceContext_Unmap(d->ctx, (ID3D11Resource *)d->staging, 0);
    rc = 0;
done:
    ID3D11Texture2D_Release(tex);
    return rc;
}

// Uma imagem decodificada → d->buf. 0 = ok.
static int take_picture(mfdec *d, IMFSample *s) {
    if (d->w <= 0 || d->h <= 0) return -1;
    const size_t need = (size_t)d->w * d->h * 3 / 2;
    if (need > d->cap) {
        uint8_t *nb = realloc(d->buf, need);
        if (!nb) return -1;
        d->buf = nb;
        d->cap = need;
    }
    IMFMediaBuffer *b = NULL;
    if (FAILED(IMFSample_GetBufferByIndex(s, 0, &b)) || !b) return -1;
    int rc = -1;
    IMFDXGIBuffer *db = NULL;
    IMF2DBuffer *b2 = NULL;
    if (d->gpu && SUCCEEDED(IMFMediaBuffer_QueryInterface(b, &G_IID_DXGI_BUFFER, (void **)&db)) && db) {
        rc = copy_texture(d, db);
        IMFDXGIBuffer_Release(db);
    }
    if (rc != 0 && SUCCEEDED(IMFMediaBuffer_QueryInterface(b, &G_IID_2D_BUFFER, (void **)&b2)) && b2) {
        // memória (ou a cópia que o próprio MF faz da textura): pitch de verdade
        BYTE *scan0 = NULL;
        LONG pitch = 0;
        if (SUCCEEDED(IMF2DBuffer_Lock2D(b2, &scan0, &pitch))) {
            if (pitch > 0 && pitch >= d->cx + d->w) {
                pack(d, scan0, pitch, scan0 + (size_t)pitch * d->fh, pitch);
                rc = 0;
            }
            IMF2DBuffer_Unlock2D(b2);
        }
        IMF2DBuffer_Release(b2);
    }
    if (rc != 0) {
        BYTE *p = NULL;
        DWORD len = 0;
        if (SUCCEEDED(IMFMediaBuffer_Lock(b, &p, NULL, &len))) {
            // o croma começa depois das linhas de luma que o buffer tem de
            // fato: o do wine, ao diminuir a resolução, mantém o enchimento
            // antigo (480 linhas + 8) e o tamanho do tipo não bate
            int rows = d->fh;
            if (d->stride > 0 && (size_t)len / ((size_t)d->stride * 3 / 2) > (size_t)rows) rows = (int)((size_t)len / ((size_t)d->stride * 3 / 2));
            if ((size_t)len >= (size_t)d->stride * rows * 3 / 2 && d->stride >= d->cx + d->w) {
                pack(d, p, d->stride, p + (size_t)d->stride * rows, d->stride);
                rc = 0;
            }
            IMFMediaBuffer_Unlock(b);
        }
    }
    IMFMediaBuffer_Release(b);
    return rc;
}

// Tira tudo o que o decoder tem pronto. 1 = tem imagem nova, 0 = não, -1 = erro.
static int drain(mfdec *d) {
    int got = 0;
    for (int guard = 0; guard < 16; guard++) {
        MFT_OUTPUT_DATA_BUFFER odb;
        memset(&odb, 0, sizeof odb);
        if (!d->provides_samples) {
            IMFSample *own = NULL;
            IMFMediaBuffer *b = NULL;
            if (FAILED(mf.CreateSample(&own)) || FAILED(mf.CreateMemoryBuffer(d->out_size, &b))) {
                if (own) IMFSample_Release(own);
                return -1;
            }
            IMFSample_AddBuffer(own, b);
            IMFMediaBuffer_Release(b);
            odb.pSample = own;
        }
        DWORD status = 0;
        HRESULT hr = IMFTransform_ProcessOutput(d->mft, 0, 1, &odb, &status);
        if (odb.pEvents) IMFCollection_Release(odb.pEvents);
        IMFSample *s = odb.pSample;
        if (hr == E_STREAM_CHANGE) {
            // SPS novo (começo ou mudança de resolução): renegocia a saída
            if (s) IMFSample_Release(s);
            HRESULT h2 = set_nv12_output(d);
            if (FAILED(h2)) {
                dbg("não renegociou a saída", h2);
                return -1;
            }
            if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] Media Foundation: saída %dx%d (imagem %dx%d em %d,%d)\n", d->fw, d->fh, d->w, d->h, d->cx, d->cy);
            continue;
        }
        if (FAILED(hr)) {
            if (s) IMFSample_Release(s);
            if (hr == E_NEED_MORE_INPUT) return got;
            dbg("ProcessOutput falhou", hr);
            return -1;
        }
        // com várias prontas (não devia, sem B-frames), fica a mais nova
        if (s && take_picture(d, s) == 0) got = 1;
        else if (s) dbg("não consegui copiar a imagem", 0);
        if (s) IMFSample_Release(s);
    }
    return got;
}

// Tem NAL desse tipo no Annex B? (7 = SPS)
static int has_nal(const uint8_t *p, int n, int type) {
    for (int i = 0; i + 3 < n; i++) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            if ((p[i + 3] & 0x1F) == type) return 1;
            i += 2;
        }
    }
    return 0;
}

// Entrega um quadro e tira a imagem. 1 = imagem em d->buf, 0 = não, -1 = erro.
static int feed(mfdec *d, const uint8_t *data, int len) {
    IMFMediaBuffer *b = NULL;
    IMFSample *s = NULL;
    if (FAILED(mf.CreateMemoryBuffer((DWORD)len, &b))) return -1;
    BYTE *p = NULL;
    if (FAILED(IMFMediaBuffer_Lock(b, &p, NULL, NULL))) {
        IMFMediaBuffer_Release(b);
        return -1;
    }
    memcpy(p, data, (size_t)len);
    IMFMediaBuffer_Unlock(b);
    IMFMediaBuffer_SetCurrentLength(b, (DWORD)len);
    if (FAILED(mf.CreateSample(&s))) {
        IMFMediaBuffer_Release(b);
        return -1;
    }
    IMFSample_AddBuffer(s, b);
    IMFMediaBuffer_Release(b);
    // tempo só pra ordem (o app mostra na hora que sai)
    IMFSample_SetSampleTime(s, d->ts);
    IMFSample_SetSampleDuration(s, 166667);
    d->ts += 166667;

    int got = 0;
    HRESULT hr = IMFTransform_ProcessInput(d->mft, 0, s, 0);
    if (hr == E_NOT_ACCEPTING) {
        // ainda tinha saída presa: tira e entrega de novo
        int r = drain(d);
        if (r > 0) got = 1;
        hr = r < 0 ? E_FAIL : IMFTransform_ProcessInput(d->mft, 0, s, 0);
    }
    IMFSample_Release(s);
    if (FAILED(hr)) {
        dbg("ProcessInput falhou", hr);
        return -1;
    }
    int r = drain(d);
    if (r < 0) return -1;
    return got || r > 0;
}

// Guarda o quadro pra um recomeço (só os poucos desde o último SPS).
static void keep_frame(mfdec *d, const uint8_t *data, int len) {
    if (has_nal(data, len, 7)) {
        d->keep_len = 0;
        d->keep_n = 0;
    }
    if (d->keep_n < 0) return;
    const size_t need = d->keep_len + 4 + (size_t)len;
    if (d->keep_n >= 8 || need > (8u << 20)) {
        d->keep_n = -1;
        return;
    }
    if (need > d->keep_cap) {
        uint8_t *nb = realloc(d->keep, need * 2);
        if (!nb) {
            d->keep_n = -1;
            return;
        }
        d->keep = nb;
        d->keep_cap = need * 2;
    }
    const uint32_t n = (uint32_t)len;
    memcpy(d->keep + d->keep_len, &n, 4);
    memcpy(d->keep + d->keep_len + 4, data, (size_t)len);
    d->keep_len = need;
    d->keep_n++;
}

// Decoder novo, reentregando os quadros desde o SPS. 1 = imagem, 0 = não, -1 = erro.
static int restart(mfdec *d) {
    release_mft(d);
    const char *why = "";
    HRESULT hr = create_mft(d, &why);
    if (FAILED(hr)) {
        dbg(why, hr);
        return -1;
    }
    int got = 0;
    for (size_t off = 0; off < d->keep_len;) {
        uint32_t n;
        memcpy(&n, d->keep + off, 4);
        const int r = feed(d, d->keep + off + 4, (int)n);
        if (r < 0) return -1;
        if (r > 0) got = 1;
        off += 4 + n;
    }
    return got;
}

int mfdec_decode(mfdec *d, const uint8_t *data, int len, hwdec_frame *out) {
    if (len <= 0) return 0;
    keep_frame(d, data, len);
    int r = d->mft ? feed(d, data, len) : -1;
    if (r < 0 && d->keep_n > 0) {
        // decoder perdido (já visto no do wine, na placa, ao diminuir a
        // resolução): recomeça com um novo a partir do último SPS, uma vez
        dbg("recriando o decoder a partir do último IDR", 0);
        r = restart(d);
    }
    if (r <= 0) return r;
    out->y = d->buf;
    out->uv = d->buf + (size_t)d->w * d->h;
    out->width = d->w;
    out->height = d->h;
    return 1;
}
