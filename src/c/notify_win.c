// Notificação no Windows: balão do ícone da bandeja (no Windows 10/11 ele vira
// uma notificação normal) e a janela piscando na barra de tarefas até a
// pessoa voltar pro telinha. O ícone da bandeja aparece na primeira
// notificação e fica até o app fechar.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <string.h>

#include "notify.h"

static HWND msg_wnd;
static NOTIFYICONDATAW nid;
static int added;

static LRESULT CALLBACK wnd_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    return DefWindowProcW(h, m, w, l);
}

static void utf8_to_wide(const char *s, WCHAR *out, int cap) {
    if (!s || MultiByteToWideChar(CP_UTF8, 0, s, -1, out, cap) <= 0) out[0] = 0;
    out[cap - 1] = 0;
}

void notify_send(const char *title, const char *body, void *window) {
    if (window) {
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
        nid.uFlags = NIF_ICON | NIF_TIP;
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
