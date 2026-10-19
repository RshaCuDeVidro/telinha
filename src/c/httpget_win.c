// GET simples por WinHTTP (Windows): usa os certificados e o proxy do
// sistema, sem TLS próprio no .exe. Só pra checagem de versão nova.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <string.h>

// Retorna quantos bytes escreveu em out (corpo da resposta 200), ou -1.
int http_get(const char *url, char *out, int cap) {
    WCHAR wurl[512];
    if (MultiByteToWideChar(CP_UTF8, 0, url, -1, wurl, 512) == 0) return -1;
    URL_COMPONENTS uc;
    WCHAR host[256], path[512];
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 512;
    if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) return -1;
    int n = -1;
    HINTERNET s = WinHttpOpen(L"telinha", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET c = NULL, r = NULL;
    if (!s) goto done;
    WinHttpSetTimeouts(s, 10000, 10000, 10000, 15000);
    c = WinHttpConnect(s, host, uc.nPort, 0);
    if (!c) goto done;
    r = WinHttpOpenRequest(c, L"GET", path, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                           uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
    if (!r) goto done;
    if (!WinHttpSendRequest(r, L"Accept: application/vnd.github+json\r\n", (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) goto done;
    if (!WinHttpReceiveResponse(r, NULL)) goto done;
    DWORD status = 0, sz = sizeof status;
    if (!WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz, WINHTTP_NO_HEADER_INDEX) || status != 200) goto done;
    int len = 0;
    for (;;) {
        DWORD got = 0;
        if (len >= cap) break;
        if (!WinHttpReadData(r, out + len, (DWORD)(cap - len), &got)) goto done;
        if (got == 0) break;
        len += (int)got;
    }
    n = len;
done:
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    return n;
}
