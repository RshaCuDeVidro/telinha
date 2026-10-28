// Notificação no Windows: balão do ícone da bandeja (no Windows 10/11 ele vira
// uma notificação normal) e a janela piscando na barra de tarefas até a
// pessoa voltar pro telinha. O ícone da bandeja aparece na primeira
// notificação e fica até o app fechar.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>

#include "notify.h"

#define WM_TRAY (WM_APP + 1)

static HWND msg_wnd;
static HWND app_wnd; // a janela do telinha (clicar na notificação traz ela)
static NOTIFYICONDATAW nid;
static int added;

static LRESULT CALLBACK wnd_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_TRAY && (LOWORD(l) == NIN_BALLOONUSERCLICK || LOWORD(l) == WM_LBUTTONUP) && app_wnd) {
        if (IsIconic(app_wnd)) ShowWindow(app_wnd, SW_RESTORE);
        SetForegroundWindow(app_wnd);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

// Texto maior que o campo (63 no título, 255 no corpo) é cortado com "…":
// a conversão direta falhava inteira e a notificação saía vazia.
static void utf8_to_wide(const char *s, WCHAR *out, int cap) {
    out[0] = 0;
    if (!s) return;
    const int need = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (need <= 0) return;
    if (need <= cap) {
        MultiByteToWideChar(CP_UTF8, 0, s, -1, out, cap);
        return;
    }
    WCHAR *tmp = malloc((size_t)need * sizeof(WCHAR));
    if (!tmp) return;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, tmp, need);
    int k = cap - 2;
    if (k > 0 && IS_HIGH_SURROGATE(tmp[k - 1])) k--; // não corta um emoji no meio
    memcpy(out, tmp, (size_t)k * sizeof(WCHAR));
    out[k] = 0x2026;
    out[k + 1] = 0;
    free(tmp);
}

void notify_send(const char *title, const char *body, void *window) {
    if (window) {
        app_wnd = (HWND)window;
        FLASHWINFO fi = {sizeof fi, (HWND)window, FLASHW_TRAY | FLASHW_TIMERNOFG, 0, 0};
        FlashWindowEx(&fi);
    }
    if (!msg_wnd) {
        WNDCLASSW wc = {0};
        wc.lpfnWndProc = wnd_proc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.lpszClassName = L"telinha-notify";
        RegisterClassW(&wc);
        msg_wnd = CreateWindowExW(0, L"telinha-notify", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
        if (!msg_wnd) return;
    }
    if (!added) {
        memset(&nid, 0, sizeof nid);
        nid.cbSize = sizeof nid;
        nid.hWnd = msg_wnd;
        nid.uID = 1;
        nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
        nid.uCallbackMessage = WM_TRAY;
        // ícone do próprio .exe (recurso 1 do telinha.rc), senão o padrão
        nid.hIcon = LoadIconW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(1));
        if (!nid.hIcon) nid.hIcon = LoadIconW(NULL, (LPCWSTR)IDI_APPLICATION);
        wcscpy(nid.szTip, L"telinha");
        if (!Shell_NotifyIconW(NIM_ADD, &nid)) return;
        added = 1;
    }
    nid.uFlags = NIF_INFO;
    utf8_to_wide(title, nid.szInfoTitle, (int)(sizeof nid.szInfoTitle / sizeof(WCHAR)));
    utf8_to_wide(body, nid.szInfo, (int)(sizeof nid.szInfo / sizeof(WCHAR)));
    nid.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
    Shell_NotifyIconW(NIM_MODIFY, &nid);
}
