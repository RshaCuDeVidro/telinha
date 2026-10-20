// Captura no Windows.
//   Monitor: DXGI Desktop Duplication (rápido, só acorda quando a tela muda),
//            GDI BitBlt de reserva (máquinas virtuais, wine, drivers velhos)
//   Janela:  Windows.Graphics.Capture (Windows 10 1903+; a janela pode estar
//            coberta por outras), PrintWindow de reserva
#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dwmapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"

enum { KIND_DXGI = 1, KIND_GDI = 2, KIND_WGC = 3, KIND_PRINT = 4 };

// janelas da última lista (cap_list_sources): id = WINDOW_ID0 + índice
#define WINDOW_ID0 1000
#define MAX_WINDOWS 48
static HWND g_windows[MAX_WINDOWS];
static int g_n_windows;

struct wgc_state; // Windows.Graphics.Capture (mais abaixo)

typedef struct {
    RECT rc;
    int primary;
} monitor_info;

struct cap_ctx {
    int kind;
    int show_cursor;
    // cursor fora do vídeo (cap_set_cursor_apart): não pinta, só diz onde está
    int cursor_apart;
    int redeliver; // reentrega o quadro limpo (o anterior tinha o cursor pintado)
    int last_cx, last_cy, last_cshown;
    HWND hwnd;              // janela (KIND_WGC / KIND_PRINT)
    struct wgc_state *wgc;
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

typedef struct {
    cap_source *out;
    int n, max;
} win_enum;

// Janela que faz sentido compartilhar: visível, de "primeiro nível", com
// título, não escondida pelo DWM (apps UWP em segundo plano) e não nossa.
static int shareable(HWND h) {
    if (!IsWindowVisible(h) || IsIconic(h) || GetWindow(h, GW_OWNER)) return 0;
    if (GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return 0;
    if (GetWindowTextLengthW(h) == 0) return 0;
    DWORD cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(h, 14 /* DWMWA_CLOAKED */, &cloaked, sizeof cloaked)) && cloaked) return 0;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (pid == GetCurrentProcessId()) return 0;
    WCHAR cls[64];
    if (GetClassNameW(h, cls, 64) && (lstrcmpW(cls, L"Progman") == 0 || lstrcmpW(cls, L"Shell_TrayWnd") == 0)) return 0;
    RECT r;
    if (!GetWindowRect(h, &r) || r.right - r.left < 64 || r.bottom - r.top < 48) return 0;
    return 1;
}

static BOOL CALLBACK enum_window(HWND h, LPARAM lp) {
    win_enum *e = (win_enum *)lp;
    if (e->n >= e->max || g_n_windows >= MAX_WINDOWS) return FALSE;
    if (!shareable(h)) return TRUE;
    WCHAR title[120];
    GetWindowTextW(h, title, 120);
    char t8[200];
    if (WideCharToMultiByte(CP_UTF8, 0, title, -1, t8, sizeof t8, NULL, NULL) <= 0) return TRUE;
    // nome do programa (ex.: "chrome") ajuda a achar a janela certa
    char exe[64] = "";
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (proc) {
        WCHAR path[MAX_PATH];
        DWORD len = MAX_PATH;
        if (QueryFullProcessImageNameW(proc, 0, path, &len)) {
            WCHAR *base = path;
            for (WCHAR *p = path; *p; p++)
                if (*p == L'\\' || *p == L'/') base = p + 1;
            WideCharToMultiByte(CP_UTF8, 0, base, -1, exe, sizeof exe, NULL, NULL);
            char *dot = strrchr(exe, '.');
            if (dot) *dot = 0;
        }
        CloseHandle(proc);
    }
    cap_source *o = &e->out[e->n++];
    o->id = WINDOW_ID0 + g_n_windows;
    o->pid = pid;
    snprintf(o->app, sizeof o->app, "%s", exe);
    g_windows[g_n_windows++] = h;
    if (exe[0]) snprintf(o->name, sizeof o->name, "Janela: %s (%s)", t8, exe);
    else snprintf(o->name, sizeof o->name, "Janela: %s", t8);
    return TRUE;
}

int cap_list_sources(cap_source *out, int max) {
    monitor_info mons[16];
    int n = list_monitors(mons, 16);
    if (n > max) n = max;
    for (int i = 0; i < n; i++) {
        out[i].id = i;
        out[i].pid = 0;
        out[i].app[0] = 0;
        snprintf(out[i].name, sizeof out[i].name, "Monitor %d — %ldx%ld%s", i + 1,
                 mons[i].rc.right - mons[i].rc.left, mons[i].rc.bottom - mons[i].rc.top,
                 mons[i].primary ? " (principal)" : "");
    }
    // janelas (só uma janela, mesmo coberta por outras)
    g_n_windows = 0;
    win_enum e = {out, n, max};
    EnumWindows(enum_window, (LPARAM)&e);
    return e.n;
}

// ---------------------------------------------------------------------------
// Cursor: copia o pedaço da tela pra um DIB pequeno, DrawIconEx por cima e copia de volta.
// Funciona com qualquer tipo de cursor (colorido, monocromático, animado).

static void draw_cursor(struct cap_ctx *c, uint8_t *buf, cap_frame *out) {
    CURSORINFO ci = {.cbSize = sizeof ci};
    out->cursor_known = 0;
    if (!GetCursorInfo(&ci) || !(ci.flags & CURSOR_SHOWING) || !ci.hCursor) return;
    out->cursor_known = 1;
    out->cursor_px = ci.ptScreenPos.x - c->rc.left;
    out->cursor_py = ci.ptScreenPos.y - c->rc.top;
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

// Cursor fora do vídeo: só onde ele está (relativo a c->rc), sem pintar.
// Retorna 1 se mexeu (ou apareceu/sumiu) desde a última vez.
static int cursor_pos(struct cap_ctx *c, cap_frame *out) {
    CURSORINFO ci = {.cbSize = sizeof ci};
    out->cursor_known = 0;
    int shown = GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING);
    int x = shown ? ci.ptScreenPos.x - c->rc.left : 0;
    int y = shown ? ci.ptScreenPos.y - c->rc.top : 0;
    if (shown && x >= 0 && y >= 0 && x < c->w && y < c->h) {
        out->cursor_known = 1;
        out->cursor_px = x;
        out->cursor_py = y;
    } else
        shown = 0;
    const int moved = shown != c->last_cshown || (shown && (x != c->last_cx || y != c->last_cy));
    c->last_cshown = shown;
    c->last_cx = x;
    c->last_cy = y;
    return moved;
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
    if (c->cursor_apart) {
        // cursor fora do vídeo: o quadro vai limpo, sem cópia; só o mouse mexeu = 2
        if (c->redeliver) {
            c->redeliver = 0;
            changed = 1;
        }
        const int moved = cursor_pos(c, out);
        out->width = c->w;
        out->height = c->h;
        if (!changed) {
            out->data = NULL;
            return moved ? 2 : 0;
        }
        out->data = c->clean;
        out->stride = c->w * 4;
        out->format = CAP_BGRX;
        out->cursor_draw = 0;
        return 1;
    }
    if (fi.LastMouseUpdateTime.QuadPart != 0 && c->show_cursor) changed = 1;
    if (!changed) return 0;

    memcpy(c->out, c->clean, (size_t)c->w * c->h * 4);
    out->cursor_known = 0;
    if (c->show_cursor) draw_cursor(c, c->out, out);
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
    out->cursor_known = 0;
    if (c->show_cursor && c->cursor_apart) cursor_pos(c, out);
    else if (c->show_cursor) draw_cursor(c, c->out, out);
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
// Janela: Windows.Graphics.Capture (WinRT). Não tem header de C pra WinRT no
// MinGW, então as interfaces vão declaradas aqui (vtables na ordem do SDK;
// GUIDs conferidos com os IDLs). combase.dll e d3d11.dll são carregadas em
// tempo de execução: no Windows sem isso, cai pro PrintWindow.

typedef struct { INT32 Width, Height; } SizeInt32;
typedef struct HSTRING__ *HSTRG;

#define INSPECTABLE_METHODS                                              \
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **); \
    ULONG(STDMETHODCALLTYPE *AddRef)(void *);                            \
    ULONG(STDMETHODCALLTYPE *Release)(void *);                           \
    HRESULT(STDMETHODCALLTYPE *GetIids)(void *, ULONG *, IID **);        \
    HRESULT(STDMETHODCALLTYPE *GetRuntimeClassName)(void *, HSTRG *);     \
    HRESULT(STDMETHODCALLTYPE *GetTrustLevel)(void *, int *);

typedef struct { const struct { INSPECTABLE_METHODS } *v; } IInsp;
typedef struct {
    const struct {
        HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
        ULONG(STDMETHODCALLTYPE *AddRef)(void *);
        ULONG(STDMETHODCALLTYPE *Release)(void *);
        HRESULT(STDMETHODCALLTYPE *CreateForWindow)(void *, HWND, REFIID, void **);
        HRESULT(STDMETHODCALLTYPE *CreateForMonitor)(void *, HMONITOR, REFIID, void **);
    } *v;
} ItemInterop;
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *get_DisplayName)(void *, HSTRG *);
        HRESULT(STDMETHODCALLTYPE *get_Size)(void *, SizeInt32 *);
    } *v;
} CaptureItem;
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *CreateFreeThreaded)(void *, void *device, INT32 fmt, INT32 buffers, SizeInt32 size, void **pool);
    } *v;
} PoolStatics2;
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *Recreate)(void *, void *device, INT32 fmt, INT32 buffers, SizeInt32 size);
        HRESULT(STDMETHODCALLTYPE *TryGetNextFrame)(void *, void **frame);
        HRESULT(STDMETHODCALLTYPE *add_FrameArrived)(void *, void *, INT64 *);
        HRESULT(STDMETHODCALLTYPE *remove_FrameArrived)(void *, INT64);
        HRESULT(STDMETHODCALLTYPE *CreateCaptureSession)(void *, void *item, void **session);
    } *v;
} FramePool;
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *get_Surface)(void *, void **surface);
        HRESULT(STDMETHODCALLTYPE *get_SystemRelativeTime)(void *, INT64 *);
        HRESULT(STDMETHODCALLTYPE *get_ContentSize)(void *, SizeInt32 *);
    } *v;
} CaptureFrame;
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *StartCapture)(void *);
    } *v;
} CaptureSession;
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *get_Flag)(void *, unsigned char *);
        HRESULT(STDMETHODCALLTYPE *put_Flag)(void *, unsigned char);
    } *v;
} SessionFlag; // IGraphicsCaptureSession2 (cursor) e 3 (borda amarela)
typedef struct {
    const struct {
        INSPECTABLE_METHODS
        HRESULT(STDMETHODCALLTYPE *Close)(void *);
    } *v;
} Closable;
typedef struct {
    const struct {
        HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
        ULONG(STDMETHODCALLTYPE *AddRef)(void *);
        ULONG(STDMETHODCALLTYPE *Release)(void *);
        HRESULT(STDMETHODCALLTYPE *GetInterface)(void *, REFIID, void **);
    } *v;
} DxgiAccess;

static const GUID IID_ItemInterop = {0x3628e81b, 0x3cac, 0x4c60, {0xb7, 0xf4, 0x23, 0xce, 0x0e, 0x0c, 0x33, 0x56}};
static const GUID IID_CaptureItem = {0x79c3f95b, 0x31f7, 0x4ec2, {0xa4, 0x64, 0x63, 0x2e, 0xf5, 0xd3, 0x07, 0x60}};
static const GUID IID_PoolStatics2 = {0x589b103f, 0x6bbc, 0x5df5, {0xa9, 0x91, 0x02, 0xe2, 0x8b, 0x3b, 0x66, 0xd5}};
static const GUID IID_Session2 = {0x2c39ae40, 0x7d2e, 0x5044, {0x80, 0x4e, 0x8b, 0x67, 0x99, 0xd4, 0xcf, 0x9e}};
static const GUID IID_Session3 = {0xf2cdd966, 0x22ae, 0x5ea1, {0x95, 0x96, 0x3a, 0x28, 0x93, 0x44, 0xc3, 0xbe}};
static const GUID IID_Closable = {0x30d5a829, 0x7fa4, 0x4026, {0x83, 0xbb, 0xd7, 0x5b, 0xae, 0x4e, 0xa9, 0x9e}};
static const GUID IID_DxgiAccess = {0xa9b3d012, 0x3df2, 0x4ee3, {0xb8, 0xd1, 0x86, 0x95, 0xf4, 0x57, 0xd3, 0xc1}};
static const GUID IID_D3DDevice = {0xa37624ab, 0x8d5f, 0x4650, {0x9d, 0x3e, 0x9e, 0xae, 0x3d, 0x9b, 0xc6, 0x70}};

#define PIXEL_BGRA8 87 // DirectXPixelFormat_B8G8R8A8UIntNormalized

static struct {
    int tried, ok;
    HRESULT(WINAPI *GetActivationFactory)(HSTRG, REFIID, void **);
    HRESULT(WINAPI *CreateString)(const WCHAR *, UINT32, HSTRG *);
    HRESULT(WINAPI *DeleteString)(HSTRG);
    HRESULT(WINAPI *DeviceFromDXGI)(IDXGIDevice *, IInsp **);
} rt;

static int rt_load(void) {
    if (rt.tried) return rt.ok;
    rt.tried = 1;
    HMODULE combase = LoadLibraryW(L"combase.dll");
    HMODULE d3d = LoadLibraryW(L"d3d11.dll");
    if (!combase || !d3d) return 0;
    rt.GetActivationFactory = (HRESULT(WINAPI *)(HSTRG, REFIID, void **))(void *)GetProcAddress(combase, "RoGetActivationFactory");
    rt.CreateString = (HRESULT(WINAPI *)(const WCHAR *, UINT32, HSTRG *))(void *)GetProcAddress(combase, "WindowsCreateString");
    rt.DeleteString = (HRESULT(WINAPI *)(HSTRG))(void *)GetProcAddress(combase, "WindowsDeleteString");
    rt.DeviceFromDXGI = (HRESULT(WINAPI *)(IDXGIDevice *, IInsp **))(void *)GetProcAddress(d3d, "CreateDirect3D11DeviceFromDXGIDevice");
    rt.ok = rt.GetActivationFactory && rt.CreateString && rt.DeleteString && rt.DeviceFromDXGI;
    return rt.ok;
}

static HRESULT factory(const WCHAR *cls, REFIID iid, void **out) {
    HSTRG h = NULL;
    HRESULT hr = rt.CreateString(cls, (UINT32)wcslen(cls), &h);
    if (FAILED(hr)) return hr;
    hr = rt.GetActivationFactory(h, iid, out);
    rt.DeleteString(h);
    return hr;
}

#define RELEASE(p)                            \
    do {                                      \
        if (p) ((IInsp *)(p))->v->Release(p); \
        p = NULL;                             \
    } while (0)

struct wgc_state {
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IInsp *rt_device;
    CaptureItem *item;
    FramePool *pool;
    CaptureSession *session;
    SizeInt32 size; // tamanho atual do pool
    ID3D11Texture2D *staging;
    int staging_w, staging_h;
    SessionFlag *cursor_flag; // IsCursorCaptureEnabled (NULL = Windows sem isso: o cursor sempre vem)
};

static void wgc_close(struct wgc_state *g) {
    if (!g) return;
    Closable *cl = NULL;
    if (g->session && SUCCEEDED(g->session->v->QueryInterface(g->session, &IID_Closable, (void **)&cl))) {
        cl->v->Close(cl);
        RELEASE(cl);
    }
    if (g->pool && SUCCEEDED(g->pool->v->QueryInterface(g->pool, &IID_Closable, (void **)&cl))) {
        cl->v->Close(cl);
        RELEASE(cl);
    }
    RELEASE(g->session);
    RELEASE(g->pool);
    RELEASE(g->item);
    RELEASE(g->rt_device);
    RELEASE(g->cursor_flag);
    if (g->staging) ID3D11Texture2D_Release(g->staging);
    if (g->ctx) ID3D11DeviceContext_Release(g->ctx);
    if (g->dev) ID3D11Device_Release(g->dev);
    free(g);
}

static struct wgc_state *wgc_open(HWND hwnd, int show_cursor, HRESULT *hr_out) {
    HRESULT hr = E_FAIL;
    *hr_out = hr;
    if (!rt_load()) return NULL;
    CoInitializeEx(NULL, COINIT_MULTITHREADED); // essa é a thread de captura
    struct wgc_state *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    IDXGIDevice *dxgi = NULL;
    IInsp *insp = NULL;
    ItemInterop *interop = NULL;
    PoolStatics2 *ps = NULL;
    SessionFlag *f = NULL;
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &g->dev, NULL, &g->ctx);
    if (FAILED(hr)) goto fail;
    hr = ID3D11Device_QueryInterface(g->dev, &IID_IDXGIDevice, (void **)&dxgi);
    if (FAILED(hr)) goto fail;
    hr = rt.DeviceFromDXGI(dxgi, &insp);
    IDXGIDevice_Release(dxgi);
    if (FAILED(hr) || !insp) goto fail;
    hr = insp->v->QueryInterface(insp, &IID_D3DDevice, (void **)&g->rt_device);
    RELEASE(insp);
    if (FAILED(hr)) goto fail;
    hr = factory(L"Windows.Graphics.Capture.GraphicsCaptureItem", &IID_ItemInterop, (void **)&interop);
    if (FAILED(hr) || !interop) goto fail;
    hr = interop->v->CreateForWindow(interop, hwnd, &IID_CaptureItem, (void **)&g->item);
    interop->v->Release(interop);
    if (FAILED(hr) || !g->item) goto fail;
    hr = g->item->v->get_Size(g->item, &g->size);
    if (FAILED(hr) || g->size.Width <= 0 || g->size.Height <= 0) goto fail;
    hr = factory(L"Windows.Graphics.Capture.Direct3D11CaptureFramePool", &IID_PoolStatics2, (void **)&ps);
    if (FAILED(hr) || !ps) goto fail;
    hr = ps->v->CreateFreeThreaded(ps, g->rt_device, PIXEL_BGRA8, 2, g->size, (void **)&g->pool);
    ps->v->Release(ps);
    if (FAILED(hr) || !g->pool) goto fail;
    hr = g->pool->v->CreateCaptureSession(g->pool, g->item, (void **)&g->session);
    if (FAILED(hr) || !g->session) goto fail;
    // cursor desenhado pelo sistema (ou não); sem a borda amarela onde der (Windows 11)
    if (SUCCEEDED(g->session->v->QueryInterface(g->session, &IID_Session2, (void **)&g->cursor_flag)) && g->cursor_flag)
        g->cursor_flag->v->put_Flag(g->cursor_flag, show_cursor ? 1 : 0);
    if (SUCCEEDED(g->session->v->QueryInterface(g->session, &IID_Session3, (void **)&f))) {
        f->v->put_Flag(f, 0);
        RELEASE(f);
    }
    hr = g->session->v->StartCapture(g->session);
    if (FAILED(hr)) goto fail;
    *hr_out = S_OK;
    return g;
fail:
    *hr_out = hr;
    wgc_close(g);
    return NULL;
}

// Onde está a janela na tela (sem as bordas invisíveis do Windows 10/11).
static void window_bounds(HWND h, RECT *r) {
    if (FAILED(DwmGetWindowAttribute(h, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, r, sizeof *r))) GetWindowRect(h, r);
}

static int ensure_out(struct cap_ctx *c, int w, int h) {
    if (c->out && c->w == w && c->h == h) return 0;
    free(c->out);
    c->out = calloc((size_t)w * h, 4);
    c->w = w;
    c->h = h;
    return c->out ? 0 : -1;
}

// Ponta do cursor relativa à janela, na escala do quadro. 1 = mexeu.
static int wgc_cursor(struct cap_ctx *c, cap_frame *out) {
    out->cursor_known = 0;
    POINT pt;
    RECT r;
    window_bounds(c->hwnd, &r);
    CURSORINFO ci = {.cbSize = sizeof ci};
    int shown = c->show_cursor && GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING);
    pt = ci.ptScreenPos;
    int x = 0, y = 0;
    if (shown && pt.x >= r.left && pt.y >= r.top && pt.x < r.right && pt.y < r.bottom) {
        x = (int)((double)(pt.x - r.left) * c->w / (r.right - r.left > 0 ? r.right - r.left : 1));
        y = (int)((double)(pt.y - r.top) * c->h / (r.bottom - r.top > 0 ? r.bottom - r.top : 1));
        out->cursor_known = 1;
        out->cursor_px = x;
        out->cursor_py = y;
    } else
        shown = 0;
    const int moved = shown != c->last_cshown || (shown && (x != c->last_cx || y != c->last_cy));
    c->last_cshown = shown;
    c->last_cx = x;
    c->last_cy = y;
    return moved;
}

static int next_wgc(struct cap_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
    struct wgc_state *g = c->wgc;
    if (!IsWindow(c->hwnd)) {
        set_err(err, errlen, "a janela foi fechada", 0);
        return -1;
    }
    CaptureFrame *frame = NULL;
    // sem evento: confere a cada 2 ms (a janela só manda quadro quando muda)
    for (int waited = 0; waited <= timeout_ms; waited += 2) {
        if (SUCCEEDED(g->pool->v->TryGetNextFrame(g->pool, (void **)&frame)) && frame) break;
        Sleep(2);
    }
    if (!frame) {
        // cursor fora do vídeo: a janela parada, mas o mouse mexeu
        if (c->cursor_apart && c->w > 0) {
            int moved = wgc_cursor(c, out);
            out->data = NULL;
            out->width = c->w;
            out->height = c->h;
            return moved ? 2 : 0;
        }
        return 0;
    }
    SizeInt32 cs = {0, 0};
    frame->v->get_ContentSize(frame, &cs);
    int got = 0;
    void *surf = NULL;
    if (cs.Width > 0 && cs.Height > 0 && SUCCEEDED(frame->v->get_Surface(frame, &surf)) && surf) {
        DxgiAccess *acc = NULL;
        ID3D11Texture2D *tex = NULL;
        if (SUCCEEDED(((IInsp *)surf)->v->QueryInterface(surf, &IID_DxgiAccess, (void **)&acc))) {
            acc->v->GetInterface(acc, &IID_ID3D11Texture2D, (void **)&tex);
            acc->v->Release(acc);
        }
        if (tex) {
            D3D11_TEXTURE2D_DESC desc;
            ID3D11Texture2D_GetDesc(tex, &desc);
            int w = cs.Width < (int)desc.Width ? cs.Width : (int)desc.Width;
            int h = cs.Height < (int)desc.Height ? cs.Height : (int)desc.Height;
            if (!g->staging || g->staging_w != (int)desc.Width || g->staging_h != (int)desc.Height) {
                if (g->staging) ID3D11Texture2D_Release(g->staging);
                g->staging = NULL;
                desc.Usage = D3D11_USAGE_STAGING;
                desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                desc.BindFlags = 0;
                desc.MiscFlags = 0;
                desc.MipLevels = 1;
                desc.ArraySize = 1;
                desc.SampleDesc.Count = 1;
                ID3D11Device_CreateTexture2D(g->dev, &desc, NULL, &g->staging);
                g->staging_w = (int)desc.Width;
                g->staging_h = (int)desc.Height;
            }
            if (g->staging && ensure_out(c, w & ~1, h & ~1) == 0) {
                ID3D11DeviceContext_CopyResource(g->ctx, (ID3D11Resource *)g->staging, (ID3D11Resource *)tex);
                D3D11_MAPPED_SUBRESOURCE m;
                if (SUCCEEDED(ID3D11DeviceContext_Map(g->ctx, (ID3D11Resource *)g->staging, 0, D3D11_MAP_READ, 0, &m))) {
                    for (int y = 0; y < c->h; y++)
                        memcpy(c->out + (size_t)y * c->w * 4, (uint8_t *)m.pData + (size_t)y * m.RowPitch, (size_t)c->w * 4);
                    ID3D11DeviceContext_Unmap(g->ctx, (ID3D11Resource *)g->staging, 0);
                    got = 1;
                }
            }
            ID3D11Texture2D_Release(tex);
        }
        ((IInsp *)surf)->v->Release(surf);
    }
    frame->v->Release(frame);
    // janela mudou de tamanho: o pool acompanha (o próximo quadro já vem no tamanho novo)
    if (cs.Width > 0 && cs.Height > 0 && (cs.Width != g->size.Width || cs.Height != g->size.Height)) {
        g->size = cs;
        g->pool->v->Recreate(g->pool, g->rt_device, PIXEL_BGRA8, 2, cs);
    }
    if (!got) return 0;
    out->data = c->out;
    out->width = c->w;
    out->height = c->h;
    out->stride = c->w * 4;
    out->format = CAP_BGRX;
    out->cursor_draw = 0;
    // ponta do cursor relativa à janela (o zoom de quem assiste segue)
    wgc_cursor(c, out);
    return 1;
}

// Reserva: PrintWindow (pede pra janela se desenhar num bitmap; funciona com
// ela coberta, mas custa mais CPU e não acorda sozinho quando muda).
static int next_print(struct cap_ctx *c, cap_frame *out, char *err, int errlen) {
    if (!IsWindow(c->hwnd)) {
        set_err(err, errlen, "a janela foi fechada", 0);
        return -1;
    }
    if (IsIconic(c->hwnd)) return 0;
    RECT r;
    GetWindowRect(c->hwnd, &r);
    int w = (r.right - r.left) & ~1, h = (r.bottom - r.top) & ~1;
    if (w < 16 || h < 16) return 0;
    if (!c->mem_dc || w != c->w || h != c->h) {
        close_gdi(c);
        c->dib = NULL;
        c->mem_dc = NULL;
        c->screen_dc = NULL;
        if (ensure_out(c, w, h) < 0) return -1;
        free(c->clean);
        c->clean = calloc((size_t)w * h, 4);
        if (open_gdi(c) != 0) {
            set_err(err, errlen, "não consegui preparar a captura da janela", (long)GetLastError());
            return -1;
        }
    }
    if (!PrintWindow(c->hwnd, c->mem_dc, 2 /* PW_RENDERFULLCONTENT */) && !PrintWindow(c->hwnd, c->mem_dc, 0)) return 0;
    GdiFlush();
    memcpy(c->out, c->dib_bits, (size_t)c->w * c->h * 4);
    for (size_t i = 0; i < (size_t)c->w * c->h; i++) c->out[i * 4 + 3] = 255;
    out->cursor_known = 0;
    if (c->show_cursor) {
        c->rc = r; // o cursor é desenhado relativo à janela
        if (c->cursor_apart) cursor_pos(c, out);
        else draw_cursor(c, c->out, out);
    }
    out->data = c->out;
    out->width = c->w;
    out->height = c->h;
    out->stride = c->w * 4;
    out->format = CAP_BGRX;
    out->cursor_draw = 0;
    return 1;
}

static cap_ctx *open_window(HWND hwnd, int show_cursor, char *err, int errlen) {
    if (!hwnd || !IsWindow(hwnd)) {
        set_err(err, errlen, "a janela não existe mais (abre a lista de novo)", 0);
        return NULL;
    }
    struct cap_ctx *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->show_cursor = show_cursor;
    c->hwnd = hwnd;
    HRESULT hr = E_FAIL;
    c->wgc = getenv("TELINHA_SEM_WGC") ? NULL : wgc_open(hwnd, show_cursor, &hr);
    if (c->wgc) {
        c->kind = KIND_WGC;
        return c;
    }
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] Windows.Graphics.Capture indisponível (0x%08lx): usando PrintWindow\n", (unsigned long)hr);
    // sem Windows.Graphics.Capture (Windows antigo, wine): PrintWindow
    c->kind = KIND_PRINT;
    RECT r;
    GetWindowRect(hwnd, &r);
    c->w = (r.right - r.left) & ~1;
    c->h = (r.bottom - r.top) & ~1;
    if (c->w < 16 || c->h < 16) {
        set_err(err, errlen, "a janela é pequena demais (minimizada?)", 0);
        free(c);
        return NULL;
    }
    c->out = calloc((size_t)c->w * c->h, 4);
    c->clean = calloc((size_t)c->w * c->h, 4);
    if (!c->out || !c->clean || open_gdi(c) != 0) {
        set_err(err, errlen, "não consegui capturar a janela", (long)GetLastError());
        cap_close(c);
        return NULL;
    }
    return c;
}

// ---------------------------------------------------------------------------

cap_ctx *cap_open(int source_id, int show_cursor, int fps, char *err, int errlen) {
    (void)fps;
    if (source_id >= WINDOW_ID0) {
        int i = source_id - WINDOW_ID0;
        return open_window(i < g_n_windows ? g_windows[i] : NULL, show_cursor, err, errlen);
    }
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
    switch (c->kind) {
    case KIND_DXGI: return next_dxgi(c, out, timeout_ms, err, errlen);
    case KIND_WGC: return next_wgc(c, out, timeout_ms, err, errlen);
    case KIND_PRINT: return next_print(c, out, err, errlen);
    default: return next_gdi(c, out, err, errlen);
    }
}

const char *cap_backend(cap_ctx *c) {
    switch (c->kind) {
    case KIND_DXGI: return "DXGI";
    case KIND_WGC: return "WGC";
    case KIND_PRINT: return "PrintWindow";
    default: return "GDI";
    }
}

void cap_close(cap_ctx *c) {
    if (!c) return;
    wgc_close(c->wgc);
    release_dxgi(c);
    close_gdi(c);
    if (c->cur_dib) DeleteObject(c->cur_dib);
    if (c->cur_dc) DeleteDC(c->cur_dc);
    free(c->clean);
    free(c->out);
    free(c);
}

// Caminho pela placa (capture.h): só no Linux por enquanto. No Windows o
// quadro do DXGI ainda passa pela CPU até o encoder.
int cap_gpu_enable(cap_ctx *c, void *cg, cap_rect_fn rect, cap_cursor_fn cursor) {
    (void)c; (void)cg; (void)rect; (void)cursor;
    return 0;
}
void cap_gpu_disable(cap_ctx *c) { (void)c; }
void cap_gpu_set_output(cap_ctx *c, const float crop[4], int max_height) { (void)c; (void)crop; (void)max_height; }
void cap_gpu_set_preview(cap_ctx *c, int want, int max_w) { (void)c; (void)want; (void)max_w; }
void cap_gpu_release(cap_ctx *c, void *gpu) { (void)c; (void)gpu; }
int cap_gpu_failed(cap_ctx *c) { (void)c; return 0; }
void cap_gpu_gc(cap_ctx *c) { (void)c; }

int cap_set_cursor_apart(cap_ctx *c, int on) {
    if (!c || !c->show_cursor) return 0;
    if (c->kind == KIND_WGC) {
        // janela: quem pinta o cursor é o Windows; dá pra desligar a partir do Windows 10 2004
        if (!c->wgc || !c->wgc->cursor_flag) return 0;
        c->wgc->cursor_flag->v->put_Flag(c->wgc->cursor_flag, on ? 0 : 1);
    }
    if (c->cursor_apart != (on != 0)) {
        c->cursor_apart = on != 0;
        c->redeliver = 1;
    }
    return 1;
}
