// Conversor da captura no Windows: processador de vídeo do D3D11 (ver
// d3dvp_win.h). BGRA da tela → NV12 (BT.601, faixa limitada, igual à conversão
// da CPU em codec.zig), recortado e escalado, numa textura que o encoder do
// Media Foundation lê direto.
#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "d3dvp_win.h"
#include "hwenc.h" // HWENC_BGRX

// BGRX/RGBX → NV12 da CPU (codec.zig): a referência do autoteste
void telinha_to_nv12(const uint8_t *src, int stride, int w, int h, int format, uint8_t *y, int ys, uint8_t *uv, int uvs);

#define N_VIEWS 8

struct d3dvp {
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    ID3D11VideoDevice *vdev;
    ID3D11VideoContext *vctx;
    ID3D11VideoProcessorEnumerator *en;
    ID3D11VideoProcessor *vp;
    // views guardadas por textura (criar uma a cada quadro custa)
    struct {
        ID3D11Texture2D *tex;
        ID3D11VideoProcessorInputView *view;
    } in[N_VIEWS];
    struct {
        ID3D11Texture2D *tex;
        ID3D11VideoProcessorOutputView *view;
    } out[N_VIEWS];
    // prévia: BGRA na placa + cópia pra CPU
    ID3D11Texture2D *prev, *prev_staging;
    int prev_w, prev_h;
};

static void set_err(char *err, int errlen, const char *msg, HRESULT hr) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (0x%08lx)", msg, (unsigned long)hr);
}

static ID3D11VideoProcessorInputView *in_view(d3dvp *p, ID3D11Texture2D *tex) {
    for (int i = 0; i < N_VIEWS; i++)
        if (p->in[i].tex == tex) return p->in[i].view;
    int slot = -1;
    for (int i = 0; i < N_VIEWS && slot < 0; i++)
        if (!p->in[i].tex) slot = i;
    if (slot < 0) {
        slot = 0;
        ID3D11VideoProcessorInputView_Release(p->in[0].view);
    }
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC d;
    memset(&d, 0, sizeof d);
    d.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ID3D11VideoProcessorInputView *v = NULL;
    if (FAILED(ID3D11VideoDevice_CreateVideoProcessorInputView(p->vdev, (ID3D11Resource *)tex, p->en, &d, &v)) || !v) {
        p->in[slot].tex = NULL;
        p->in[slot].view = NULL;
        return NULL;
    }
    p->in[slot].tex = tex;
    p->in[slot].view = v;
    return v;
}

static ID3D11VideoProcessorOutputView *out_view(d3dvp *p, ID3D11Texture2D *tex) {
    for (int i = 0; i < N_VIEWS; i++)
        if (p->out[i].tex == tex) return p->out[i].view;
    int slot = -1;
    for (int i = 0; i < N_VIEWS && slot < 0; i++)
        if (!p->out[i].tex) slot = i;
    if (slot < 0) {
        slot = 0;
        ID3D11VideoProcessorOutputView_Release(p->out[0].view);
    }
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC d;
    memset(&d, 0, sizeof d);
    d.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    ID3D11VideoProcessorOutputView *v = NULL;
    if (FAILED(ID3D11VideoDevice_CreateVideoProcessorOutputView(p->vdev, (ID3D11Resource *)tex, p->en, &d, &v)) || !v) {
        p->out[slot].tex = NULL;
        p->out[slot].view = NULL;
        return NULL;
    }
    p->out[slot].tex = tex;
    p->out[slot].view = v;
    return v;
}

void d3dvp_forget(d3dvp *p, ID3D11Texture2D *tex) {
    if (!p) return;
    for (int i = 0; i < N_VIEWS; i++) {
        if (p->in[i].tex && (!tex || p->in[i].tex == tex)) {
            ID3D11VideoProcessorInputView_Release(p->in[i].view);
            p->in[i].tex = NULL;
            p->in[i].view = NULL;
        }
        if (p->out[i].tex && (!tex || p->out[i].tex == tex)) {
            ID3D11VideoProcessorOutputView_Release(p->out[i].view);
            p->out[i].tex = NULL;
            p->out[i].view = NULL;
        }
    }
}

// Um "blit" do processador de vídeo: recorte (x, y, w, h) → saída inteira (ow x oh).
static int blit(d3dvp *p, ID3D11Texture2D *src, int x, int y, int w, int h, ID3D11Texture2D *dst, int ow, int oh) {
    ID3D11VideoProcessorInputView *iv = in_view(p, src);
    ID3D11VideoProcessorOutputView *ov = out_view(p, dst);
    if (!iv || !ov) return -1;
    RECT sr = {x, y, x + w, y + h};
    RECT dr = {0, 0, ow, oh};
    ID3D11VideoContext_VideoProcessorSetStreamSourceRect(p->vctx, p->vp, 0, TRUE, &sr);
    ID3D11VideoContext_VideoProcessorSetStreamDestRect(p->vctx, p->vp, 0, TRUE, &dr);
    ID3D11VideoContext_VideoProcessorSetOutputTargetRect(p->vctx, p->vp, TRUE, &dr);
    D3D11_VIDEO_PROCESSOR_STREAM st;
    memset(&st, 0, sizeof st);
    st.Enable = TRUE;
    st.pInputSurface = iv;
    return SUCCEEDED(ID3D11VideoContext_VideoProcessorBlt(p->vctx, p->vp, ov, 0, 1, &st)) ? 0 : -1;
}

ID3D11Texture2D *d3dvp_new_nv12(d3dvp *p, int w, int h) {
    D3D11_TEXTURE2D_DESC d;
    memset(&d, 0, sizeof d);
    d.Width = (UINT)(w & ~1);
    d.Height = (UINT)(h & ~1);
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_NV12;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *t = NULL;
    if (FAILED(ID3D11Device_CreateTexture2D(p->dev, &d, NULL, &t))) return NULL;
    return t;
}

int d3dvp_convert(d3dvp *p, ID3D11Texture2D *src, int x, int y, int w, int h, ID3D11Texture2D *dst, int ow, int oh) {
    if (!p || !src || !dst || w < 1 || h < 1 || ow < 2 || oh < 2) return -1;
    return blit(p, src, x, y, w, h, dst, ow, oh);
}

int d3dvp_preview(d3dvp *p, ID3D11Texture2D *src, int x, int y, int w, int h, int pw, int ph, uint8_t *rgba) {
    if (!p || !src || pw < 2 || ph < 2) return -1;
    if (!p->prev || p->prev_w != pw || p->prev_h != ph) {
        d3dvp_forget(p, p->prev);
        if (p->prev) ID3D11Texture2D_Release(p->prev);
        if (p->prev_staging) ID3D11Texture2D_Release(p->prev_staging);
        p->prev = p->prev_staging = NULL;
        D3D11_TEXTURE2D_DESC d;
        memset(&d, 0, sizeof d);
        d.Width = (UINT)pw;
        d.Height = (UINT)ph;
        d.MipLevels = 1;
        d.ArraySize = 1;
        d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        d.SampleDesc.Count = 1;
        d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_RENDER_TARGET;
        if (FAILED(ID3D11Device_CreateTexture2D(p->dev, &d, NULL, &p->prev))) return -1;
        d.Usage = D3D11_USAGE_STAGING;
        d.BindFlags = 0;
        d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(ID3D11Device_CreateTexture2D(p->dev, &d, NULL, &p->prev_staging))) return -1;
        p->prev_w = pw;
        p->prev_h = ph;
    }
    if (blit(p, src, x, y, w, h, p->prev, pw, ph) != 0) return -1;
    ID3D11DeviceContext_CopyResource(p->ctx, (ID3D11Resource *)p->prev_staging, (ID3D11Resource *)p->prev);
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(p->ctx, (ID3D11Resource *)p->prev_staging, 0, D3D11_MAP_READ, 0, &m))) return -1;
    for (int r = 0; r < ph; r++) {
        const uint8_t *s = (const uint8_t *)m.pData + (size_t)r * m.RowPitch;
        uint8_t *o = rgba + (size_t)r * pw * 4;
        for (int i = 0; i < pw; i++) {
            o[i * 4 + 0] = s[i * 4 + 2];
            o[i * 4 + 1] = s[i * 4 + 1];
            o[i * 4 + 2] = s[i * 4 + 0];
            o[i * 4 + 3] = 255;
        }
    }
    ID3D11DeviceContext_Unmap(p->ctx, (ID3D11Resource *)p->prev_staging, 0);
    return 0;
}

// Autoteste: uma imagem conhecida pela placa e pela CPU; a cor tem que bater
// (driver que converte com outra matriz ou faixa deixaria tudo desbotado).
static int selftest(d3dvp *p, char *err, int errlen) {
    enum { W = 64, H = 32 };
    static uint8_t px[W * H * 4];
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint8_t *o = &px[(y * W + x) * 4];
            // faixas de cor em cima, degradê embaixo
            const int bar = x / 8;
            if (y < H / 2) {
                static const uint8_t bars[8][3] = {{255, 255, 255}, {0, 255, 255}, {255, 255, 0}, {0, 255, 0}, {255, 0, 255}, {0, 0, 255}, {255, 0, 0}, {16, 16, 16}};
                o[0] = bars[bar][0];
                o[1] = bars[bar][1];
                o[2] = bars[bar][2];
            } else {
                o[0] = (uint8_t)(x * 4);
                o[1] = (uint8_t)(y * 8);
                o[2] = (uint8_t)(255 - x * 4);
            }
            o[3] = 255;
        }
    D3D11_TEXTURE2D_DESC d;
    memset(&d, 0, sizeof d);
    d.Width = W;
    d.Height = H;
    d.MipLevels = 1;
    d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    D3D11_SUBRESOURCE_DATA init = {px, W * 4, 0};
    ID3D11Texture2D *src = NULL, *nv = NULL, *st = NULL;
    int rc = -1;
    if (FAILED(ID3D11Device_CreateTexture2D(p->dev, &d, &init, &src))) {
        set_err(err, errlen, "autoteste: textura de entrada", 0);
        goto done;
    }
    nv = d3dvp_new_nv12(p, W, H);
    d.Format = DXGI_FORMAT_NV12;
    d.Usage = D3D11_USAGE_STAGING;
    d.BindFlags = 0;
    d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (!nv || FAILED(ID3D11Device_CreateTexture2D(p->dev, &d, NULL, &st))) {
        set_err(err, errlen, "autoteste: textura NV12", 0);
        goto done;
    }
    if (blit(p, src, 0, 0, W, H, nv, W, H) != 0) {
        set_err(err, errlen, "autoteste: o processador de vídeo não converteu", 0);
        goto done;
    }
    ID3D11DeviceContext_CopyResource(p->ctx, (ID3D11Resource *)st, (ID3D11Resource *)nv);
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(p->ctx, (ID3D11Resource *)st, 0, D3D11_MAP_READ, 0, &m))) {
        set_err(err, errlen, "autoteste: não deu pra ler o NV12", 0);
        goto done;
    }
    static uint8_t cy[W * H], cuv[W * H / 2];
    telinha_to_nv12(px, W * 4, W, H, HWENC_BGRX, cy, W, cuv, W);
    double dy = 0, duv = 0;
    int worst = 0;
    const uint8_t *gy = (const uint8_t *)m.pData;
    const uint8_t *guv = gy + (size_t)m.RowPitch * H;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            const int dd = abs((int)gy[(size_t)y * m.RowPitch + x] - (int)cy[y * W + x]);
            dy += dd;
            if (dd > worst) worst = dd;
        }
    for (int y = 0; y < H / 2; y++)
        for (int x = 0; x < W; x++) duv += abs((int)guv[(size_t)y * m.RowPitch + x] - (int)cuv[y * W + x]);
    ID3D11DeviceContext_Unmap(p->ctx, (ID3D11Resource *)st, 0);
    dy /= W * H;
    duv /= W * H / 2;
    fprintf(stderr, "[telinha] processador de vídeo do D3D11, autoteste: diferença média Y %.2f, UV %.2f, pior Y %d\n", dy, duv, worst);
    if (dy <= 2.5 && duv <= 3.5 && worst <= 16) rc = 0;
    else if (err && errlen > 0) snprintf(err, errlen, "autoteste: cor diferente da CPU (Y %.1f, UV %.1f)", dy, duv);
done:
    d3dvp_forget(p, src);
    d3dvp_forget(p, nv);
    if (st) ID3D11Texture2D_Release(st);
    if (nv) ID3D11Texture2D_Release(nv);
    if (src) ID3D11Texture2D_Release(src);
    return rc;
}

d3dvp *d3dvp_open(ID3D11Device *dev, ID3D11DeviceContext *ctx, int src_w, int src_h, char *err, int errlen) {
    if (getenv("TELINHA_SEM_D3DVP")) {
        set_err(err, errlen, "desligado (TELINHA_SEM_D3DVP)", 0);
        return NULL;
    }
    d3dvp *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->dev = dev;
    p->ctx = ctx;
    ID3D11Device_AddRef(dev);
    ID3D11DeviceContext_AddRef(ctx);
    HRESULT hr = ID3D11Device_QueryInterface(dev, &IID_ID3D11VideoDevice, (void **)&p->vdev);
    if (FAILED(hr) || !p->vdev) {
        set_err(err, errlen, "a placa não tem o processador de vídeo do D3D11", hr);
        d3dvp_close(p);
        return NULL;
    }
    hr = ID3D11DeviceContext_QueryInterface(ctx, &IID_ID3D11VideoContext, (void **)&p->vctx);
    if (FAILED(hr) || !p->vctx) {
        set_err(err, errlen, "sem contexto de vídeo do D3D11", hr);
        d3dvp_close(p);
        return NULL;
    }
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd;
    memset(&cd, 0, sizeof cd);
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = (UINT)src_w;
    cd.InputHeight = (UINT)src_h;
    cd.OutputWidth = (UINT)src_w;
    cd.OutputHeight = (UINT)src_h;
    cd.InputFrameRate.Numerator = 60;
    cd.InputFrameRate.Denominator = 1;
    cd.OutputFrameRate = cd.InputFrameRate;
    cd.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
    hr = ID3D11VideoDevice_CreateVideoProcessorEnumerator(p->vdev, &cd, &p->en);
    if (FAILED(hr) || !p->en) {
        set_err(err, errlen, "processador de vídeo (enumerador)", hr);
        d3dvp_close(p);
        return NULL;
    }
    UINT f_in = 0, f_out = 0;
    ID3D11VideoProcessorEnumerator_CheckVideoProcessorFormat(p->en, DXGI_FORMAT_B8G8R8A8_UNORM, &f_in);
    ID3D11VideoProcessorEnumerator_CheckVideoProcessorFormat(p->en, DXGI_FORMAT_NV12, &f_out);
    if (!(f_in & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_INPUT) || !(f_out & D3D11_VIDEO_PROCESSOR_FORMAT_SUPPORT_OUTPUT)) {
        set_err(err, errlen, "o processador de vídeo não faz BGRA → NV12", 0);
        d3dvp_close(p);
        return NULL;
    }
    hr = ID3D11VideoDevice_CreateVideoProcessor(p->vdev, p->en, 0, &p->vp);
    if (FAILED(hr) || !p->vp) {
        set_err(err, errlen, "processador de vídeo", hr);
        d3dvp_close(p);
        return NULL;
    }
    // entrada: RGB 0-255; saída: BT.601, Y em 16-235 (igual à CPU)
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs, out_cs;
    memset(&in_cs, 0, sizeof in_cs);
    memset(&out_cs, 0, sizeof out_cs);
    in_cs.RGB_Range = 0;
    out_cs.YCbCr_Matrix = 0;
    out_cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    ID3D11VideoContext_VideoProcessorSetStreamColorSpace(p->vctx, p->vp, 0, &in_cs);
    ID3D11VideoContext_VideoProcessorSetOutputColorSpace(p->vctx, p->vp, &out_cs);
    ID3D11VideoContext_VideoProcessorSetStreamAutoProcessingMode(p->vctx, p->vp, 0, FALSE);
    ID3D11VideoContext_VideoProcessorSetStreamFrameFormat(p->vctx, p->vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    if (selftest(p, err, errlen) != 0) {
        d3dvp_close(p);
        return NULL;
    }
    return p;
}

void d3dvp_close(d3dvp *p) {
    if (!p) return;
    d3dvp_forget(p, NULL);
    if (p->prev) ID3D11Texture2D_Release(p->prev);
    if (p->prev_staging) ID3D11Texture2D_Release(p->prev_staging);
    if (p->vp) ID3D11VideoProcessor_Release(p->vp);
    if (p->en) ID3D11VideoProcessorEnumerator_Release(p->en);
    if (p->vctx) ID3D11VideoContext_Release(p->vctx);
    if (p->vdev) ID3D11VideoDevice_Release(p->vdev);
    if (p->ctx) ID3D11DeviceContext_Release(p->ctx);
    if (p->dev) ID3D11Device_Release(p->dev);
    free(p);
}
