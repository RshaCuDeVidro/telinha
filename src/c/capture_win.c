// Captura no Windows.
//   DXGI Desktop Duplication (rápido, só acorda quando a tela muda)
//   GDI BitBlt de reserva (máquinas virtuais, wine, drivers velhos)
#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"

enum { KIND_DXGI = 1, KIND_GDI = 2 };

typedef struct {
    RECT rc;
    int primary;
} monitor_info;

struct cap_ctx {
    int kind;
    int show_cursor;
    RECT rc;
    int w, h;
    uint8_t *clean; // tela sem cursor
    uint8_t *out;   // tela com cursor (entregue)

    // DXGI
    IDXGIOutput1 *output;
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGIOutputDuplication *dupl;
    ID3D11Texture2D *staging;
    int staging_w, staging_h;
    int have_frame;

    // GDI
    HDC screen_dc, mem_dc;
    HBITMAP dib;
    uint8_t *dib_bits;

    // cursor
    HDC cur_dc;
    HBITMAP cur_dib;
    uint8_t *cur_bits;
    int cur_size;
};

static void set_err(char *err, int errlen, const char *msg, long code) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (0x%08lx)", msg, (unsigned long)code);
}

typedef struct {
    monitor_info *list;
    int n, max;
} enum_ctx;

static BOOL CALLBACK enum_monitor(HMONITOR hm, HDC dc, LPRECT r, LPARAM lp) {
    (void)dc;
    (void)r;
    enum_ctx *e = (enum_ctx *)lp;
    if (e->n >= e->max) return FALSE;
    MONITORINFO mi = {.cbSize = sizeof mi};
    if (!GetMonitorInfoW(hm, &mi)) return TRUE;
    e->list[e->n].rc = mi.rcMonitor;
    e->list[e->n].primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
    e->n++;
    return TRUE;
}

static int list_monitors(monitor_info *list, int max) {
    enum_ctx e = {list, 0, max};
    EnumDisplayMonitors(NULL, NULL, enum_monitor, (LPARAM)&e);
    // principal primeiro
    for (int i = 1; i < e.n; i++)
        if (list[i].primary) {
            monitor_info t = list[0];
            list[0] = list[i];
            list[i] = t;
        }
    return e.n;
}

int cap_list_sources(cap_source *out, int max) {
    monitor_info mons[16];
    int n = list_monitors(mons, 16);
    if (n > max) n = max;
    for (int i = 0; i < n; i++) {
        out[i].id = i;
        snprintf(out[i].name, sizeof out[i].name, "Monitor %d — %ldx%ld%s", i + 1,
                 mons[i].rc.right - mons[i].rc.left, mons[i].rc.bottom - mons[i].rc.top,
                 mons[i].primary ? " (principal)" : "");
    }
    return n;
}

// ---------------------------------------------------------------------------
// Cursor: copia o pedaço da tela pra um DIB pequeno, DrawIconEx por cima e copia de volta.
// Funciona com qualquer tipo de cursor (colorido, monocromático, animado).

static void draw_cursor(struct cap_ctx *c, uint8_t *buf) {
    CURSORINFO ci = {.cbSize = sizeof ci};
    if (!GetCursorInfo(&ci) || !(ci.flags & CURSOR_SHOWING) || !ci.hCursor) return;
    ICONINFO ii;
    if (!GetIconInfo(ci.hCursor, &ii)) return;
    int hx = (int)ii.xHotspot, hy = (int)ii.yHotspot;
    if (ii.hbmMask) DeleteObject(ii.hbmMask);
    if (ii.hbmColor) DeleteObject(ii.hbmColor);

    if (!c->cur_dc) {
        c->cur_size = GetSystemMetrics(SM_CXCURSOR) * 2;
        if (c->cur_size < 64) c->cur_size = 64;
        BITMAPINFO bi = {0};
        bi.bmiHeader.biSize = sizeof bi.bmiHeader;
        bi.bmiHeader.biWidth = c->cur_size;
        bi.bmiHeader.biHeight = -c->cur_size;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        c->cur_dc = CreateCompatibleDC(NULL);
        c->cur_dib = CreateDIBSection(c->cur_dc, &bi, DIB_RGB_COLORS, (void **)&c->cur_bits, NULL, 0);
        if (!c->cur_dib) return;
        SelectObject(c->cur_dc, c->cur_dib);
    }
    int s = c->cur_size;
    int x0 = ci.ptScreenPos.x - c->rc.left - hx;
    int y0 = ci.ptScreenPos.y - c->rc.top - hy;
    if (x0 >= c->w || y0 >= c->h || x0 + s <= 0 || y0 + s <= 0) return;

    for (int y = 0; y < s; y++) {
        int sy = y0 + y;
        for (int x = 0; x < s; x++) {
            int sx = x0 + x;
            uint32_t v = 0;
            if (sx >= 0 && sy >= 0 && sx < c->w && sy < c->h) memcpy(&v, buf + ((size_t)sy * c->w + sx) * 4, 4);
            memcpy(c->cur_bits + ((size_t)y * s + x) * 4, &v, 4);
        }
    }
    GdiFlush();
    DrawIconEx(c->cur_dc, 0, 0, ci.hCursor, 0, 0, 0, NULL, DI_NORMAL);
    GdiFlush();
    for (int y = 0; y < s; y++) {
        int sy = y0 + y;
        if (sy < 0 || sy >= c->h) continue;
        for (int x = 0; x < s; x++) {
            int sx = x0 + x;
            if (sx < 0 || sx >= c->w) continue;
            memcpy(buf + ((size_t)sy * c->w + sx) * 4, c->cur_bits + ((size_t)y * s + x) * 4, 4);
        }
    }
}

// ---------------------------------------------------------------------------
// DXGI

static void release_dxgi(struct cap_ctx *c) {
    if (c->have_frame && c->dupl) IDXGIOutputDuplication_ReleaseFrame(c->dupl);
    c->have_frame = 0;
    if (c->staging) ID3D11Texture2D_Release(c->staging);
    if (c->dupl) IDXGIOutputDuplication_Release(c->dupl);
    if (c->ctx) ID3D11DeviceContext_Release(c->ctx);
    if (c->dev) ID3D11Device_Release(c->dev);
    if (c->output) IDXGIOutput1_Release(c->output);
    c->staging = NULL;
    c->dupl = NULL;
    c->ctx = NULL;
    c->dev = NULL;
    c->output = NULL;
}

static HRESULT open_dxgi(struct cap_ctx *c) {
    IDXGIFactory1 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    if (FAILED(hr)) return hr;

    IDXGIAdapter1 *adapter = NULL, *found_adapter = NULL;
    for (UINT ai = 0; !found_adapter && IDXGIFactory1_EnumAdapters1(factory, ai, &adapter) == S_OK; ai++) {
        IDXGIOutput *out = NULL;
        for (UINT oi = 0; IDXGIAdapter1_EnumOutputs(adapter, oi, &out) == S_OK; oi++) {
            DXGI_OUTPUT_DESC d;
            IDXGIOutput_GetDesc(out, &d);
            if (d.DesktopCoordinates.left == c->rc.left && d.DesktopCoordinates.top == c->rc.top &&
                d.DesktopCoordinates.right == c->rc.right && d.DesktopCoordinates.bottom == c->rc.bottom) {
                IDXGIOutput_QueryInterface(out, &IID_IDXGIOutput1, (void **)&c->output);
                found_adapter = adapter;
                IDXGIOutput_Release(out);
                break;
            }
            IDXGIOutput_Release(out);
        }
        if (!found_adapter) IDXGIAdapter1_Release(adapter);
    }
    IDXGIFactory1_Release(factory);
    if (!found_adapter || !c->output) {
        if (found_adapter) IDXGIAdapter1_Release(found_adapter);
        return E_FAIL;
    }

    hr = D3D11CreateDevice((IDXGIAdapter *)found_adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, 0, NULL, 0,
                           D3D11_SDK_VERSION, &c->dev, NULL, &c->ctx);
    IDXGIAdapter1_Release(found_adapter);
    if (FAILED(hr)) return hr;
    return IDXGIOutput1_DuplicateOutput(c->output, (IUnknown *)c->dev, &c->dupl);
}

static int next_dxgi(struct cap_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
    if (c->have_frame) {
        IDXGIOutputDuplication_ReleaseFrame(c->dupl);
        c->have_frame = 0;
    }
    DXGI_OUTDUPL_FRAME_INFO fi;
    IDXGIResource *res = NULL;
    HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(c->dupl, (UINT)timeout_ms, &fi, &res);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return 0;
    if (hr == DXGI_ERROR_ACCESS_LOST) {
        // mudou resolução, UAC, tela de bloqueio... recria
        release_dxgi(c);
        hr = open_dxgi(c);
        if (FAILED(hr)) {
            Sleep(200);
            hr = open_dxgi(c);
        }
        if (FAILED(hr)) {
            set_err(err, errlen, "perdi o acesso à tela (DXGI)", hr);
            return -1;
        }
        return 0;
    }
    if (FAILED(hr)) {
        set_err(err, errlen, "AcquireNextFrame falhou", hr);
        return -1;
    }
    c->have_frame = 1;

    int changed = 0;
    if (fi.LastPresentTime.QuadPart != 0) {
        ID3D11Texture2D *tex = NULL;
        IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void **)&tex);
        if (tex) {
            D3D11_TEXTURE2D_DESC desc;
            ID3D11Texture2D_GetDesc(tex, &desc);
            if (!c->staging || c->staging_w != (int)desc.Width || c->staging_h != (int)desc.Height) {
                if (c->staging) ID3D11Texture2D_Release(c->staging);
                c->staging = NULL;
                desc.Usage = D3D11_USAGE_STAGING;
                desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                desc.BindFlags = 0;
                desc.MiscFlags = 0;
                desc.MipLevels = 1;
                desc.ArraySize = 1;
                desc.SampleDesc.Count = 1;
                ID3D11Device_CreateTexture2D(c->dev, &desc, NULL, &c->staging);
                c->staging_w = (int)desc.Width;
                c->staging_h = (int)desc.Height;
            }
            if (c->staging) {
                ID3D11DeviceContext_CopyResource(c->ctx, (ID3D11Resource *)c->staging, (ID3D11Resource *)tex);
                D3D11_MAPPED_SUBRESOURCE m;
                if (SUCCEEDED(ID3D11DeviceContext_Map(c->ctx, (ID3D11Resource *)c->staging, 0, D3D11_MAP_READ, 0, &m))) {
                    int w = c->staging_w < c->w ? c->staging_w : c->w;
                    int h = c->staging_h < c->h ? c->staging_h : c->h;
                    for (int y = 0; y < h; y++)
                        memcpy(c->clean + (size_t)y * c->w * 4, (uint8_t *)m.pData + (size_t)y * m.RowPitch, (size_t)w * 4);
                    ID3D11DeviceContext_Unmap(c->ctx, (ID3D11Resource *)c->staging, 0);
                    changed = 1;
                }
            }
            ID3D11Texture2D_Release(tex);
        }
    }
    if (res) IDXGIResource_Release(res);
    // devolve o frame pro DWM o quanto antes (menos latência)
    IDXGIOutputDuplication_ReleaseFrame(c->dupl);
    c->have_frame = 0;
    if (fi.LastMouseUpdateTime.QuadPart != 0 && c->show_cursor) changed = 1;
    if (!changed) return 0;

    memcpy(c->out, c->clean, (size_t)c->w * c->h * 4);
    if (c->show_cursor) draw_cursor(c, c->out);
    out->data = c->out;
    out->width = c->w;
    out->height = c->h;
    out->stride = c->w * 4;
    out->format = CAP_BGRX;
    out->cursor_draw = 0;
    return 1;
}

// ---------------------------------------------------------------------------
// GDI

static int open_gdi(struct cap_ctx *c) {
    c->screen_dc = GetDC(NULL);
    c->mem_dc = CreateCompatibleDC(c->screen_dc);
    BITMAPINFO bi = {0};
    bi.bmiHeader.biSize = sizeof bi.bmiHeader;
    bi.bmiHeader.biWidth = c->w;
    bi.bmiHeader.biHeight = -c->h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    c->dib = CreateDIBSection(c->mem_dc, &bi, DIB_RGB_COLORS, (void **)&c->dib_bits, NULL, 0);
    if (!c->dib) return -1;
    SelectObject(c->mem_dc, c->dib);
    return 0;
}

static int next_gdi(struct cap_ctx *c, cap_frame *out, char *err, int errlen) {
    if (!BitBlt(c->mem_dc, 0, 0, c->w, c->h, c->screen_dc, c->rc.left, c->rc.top, SRCCOPY)) {
        set_err(err, errlen, "BitBlt falhou", (long)GetLastError());
        return -1;
    }
    GdiFlush();
    memcpy(c->out, c->dib_bits, (size_t)c->w * c->h * 4);
    if (c->show_cursor) draw_cursor(c, c->out);
    out->data = c->out;
    out->width = c->w;
    out->height = c->h;
    out->stride = c->w * 4;
    out->format = CAP_BGRX;
    out->cursor_draw = 0;
    return 1;
}

static void close_gdi(struct cap_ctx *c) {
    if (c->dib) DeleteObject(c->dib);
    if (c->mem_dc) DeleteDC(c->mem_dc);
    if (c->screen_dc) ReleaseDC(NULL, c->screen_dc);
}

// ---------------------------------------------------------------------------

cap_ctx *cap_open(int source_id, int show_cursor, int fps, char *err, int errlen) {
    (void)fps;
    monitor_info mons[16];
    int n = list_monitors(mons, 16);
    if (n == 0) {
        set_err(err, errlen, "nenhum monitor encontrado", 0);
        return NULL;
    }
    if (source_id < 0 || source_id >= n) source_id = 0;

    struct cap_ctx *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->show_cursor = show_cursor;
    c->rc = mons[source_id].rc;
    c->w = c->rc.right - c->rc.left;
    c->h = c->rc.bottom - c->rc.top;
    c->clean = calloc((size_t)c->w * c->h, 4);
    c->out = calloc((size_t)c->w * c->h, 4);
    if (!c->clean || !c->out) {
        set_err(err, errlen, "sem memória", 0);
        cap_close(c);
        return NULL;
    }

    if (SUCCEEDED(open_dxgi(c))) {
        c->kind = KIND_DXGI;
        return c;
    }
    release_dxgi(c);
    if (open_gdi(c) == 0) {
        c->kind = KIND_GDI;
        return c;
    }
    set_err(err, errlen, "não consegui capturar a tela (nem DXGI nem GDI)", (long)GetLastError());
    cap_close(c);
    return NULL;
}

int cap_next(cap_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
    if (c->kind == KIND_DXGI) return next_dxgi(c, out, timeout_ms, err, errlen);
    return next_gdi(c, out, err, errlen);
}

const char *cap_backend(cap_ctx *c) {
    return c->kind == KIND_DXGI ? "DXGI" : "GDI";
}

void cap_close(cap_ctx *c) {
    if (!c) return;
    release_dxgi(c);
    close_gdi(c);
    if (c->cur_dib) DeleteObject(c->cur_dib);
    if (c->cur_dc) DeleteDC(c->cur_dc);
    free(c->clean);
    free(c->out);
    free(c);
}
