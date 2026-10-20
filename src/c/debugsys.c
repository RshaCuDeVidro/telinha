// Log de depuração: desvia a saída de erro do processo pro arquivo (pega o
// que o app, os drivers e as bibliotecas já imprimem), lê CPU/memória do
// processo e do sistema, e manda o arquivo por HTTP (gofile, webhook).
#include "debugsys.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi.h>
#include <fcntl.h>
#include <io.h>
#include <winhttp.h>
#include <psapi.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
#endif

static int saved_fd = -1; // a saída de erro de antes (devolvida ao desligar)

int dbg_restore_stderr(void) {
    if (saved_fd < 0) return 0;
    fflush(stderr);
#ifdef _WIN32
    _dup2(saved_fd, 2);
    SetStdHandle(STD_ERROR_HANDLE, (HANDLE)_get_osfhandle(2));
#else
    dup2(saved_fd, 2);
#endif
    return 0;
}

int dbg_redirect_stderr(const char *path) {
#ifdef _WIN32
    if (saved_fd < 0) saved_fd = _dup(2);
    WCHAR w[1024];
    if (!MultiByteToWideChar(CP_UTF8, 0, path ? path : "NUL", -1, w, 1024)) return -1;
    int fd = _wopen(w, _O_WRONLY | _O_CREAT | _O_APPEND | _O_BINARY, 0600);
    if (fd < 0) return -1;
    fflush(stderr);
    if (_dup2(fd, 2) != 0) {
        _close(fd);
        return -1;
    }
    _close(fd);
    // o que não passa pelo C (std.debug.print do Zig, Win32) usa o handle do processo
    SetStdHandle(STD_ERROR_HANDLE, (HANDLE)_get_osfhandle(2));
    setvbuf(stderr, NULL, _IONBF, 0);
    return 0;
#else
    if (saved_fd < 0) saved_fd = fcntl(2, F_DUPFD_CLOEXEC, 3);
    int fd = open(path ? path : "/dev/null", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    fflush(stderr);
    int r = dup2(fd, 2);
    close(fd);
    return r < 0 ? -1 : 0;
#endif
}

// Mexer no ambiente com outras threads lendo (getenv no encoder, no
// PipeWire...) não é seguro: liga uma vez só na vida do processo e nunca
// desliga (desligado o log, o que o C imprime volta pra saída de erro de
// antes, sem fazer mal).
void dbg_set_env(int on) {
    static int done = 0;
    if (!on || done || getenv("TELINHA_DEBUG")) return;
    done = 1;
#ifdef _WIN32
    _putenv_s("TELINHA_DEBUG", "1");
#else
    setenv("TELINHA_DEBUG", "1", 1);
#endif
}

#ifdef _WIN32
static unsigned long long ft(FILETIME f) {
    return ((unsigned long long)f.dwHighDateTime << 32) | f.dwLowDateTime;
}

int dbg_proc_stats(dbg_stats *s) {
    memset(s, 0, sizeof *s);
    FILETIME c, e, k, u, idle, sk, su;
    if (GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) {
        s->proc_cpu_ms = (ft(k) + ft(u)) / 10000;
    }
    if (GetSystemTimes(&idle, &sk, &su)) {
        // tempo do sistema todo (kernel inclui o ocioso)
        s->sys_total_ms = (ft(sk) + ft(su)) / 10000;
        s->sys_idle_ms = ft(idle) / 10000;
    }
    PROCESS_MEMORY_COUNTERS pmc;
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) s->rss_kb = pmc.WorkingSetSize / 1024;
    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof ms;
    if (GlobalMemoryStatusEx(&ms)) {
        s->ram_total_kb = ms.ullTotalPhys / 1024;
        s->ram_free_kb = ms.ullAvailPhys / 1024;
    }
    return 0;
}

// Windows: versão, processador, memória e as placas (DXGI).
int dbg_sysinfo(char *out, int cap) {
    int n = 0;
    typedef LONG(WINAPI * RtlGetVersionFn)(OSVERSIONINFOW *);
    OSVERSIONINFOW v;
    memset(&v, 0, sizeof v);
    v.dwOSVersionInfoSize = sizeof v;
    RtlGetVersionFn rgv = (RtlGetVersionFn)(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "RtlGetVersion");
    if (rgv) rgv(&v);
    const char *wine = GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version") ? " (wine)" : "";
    n += snprintf(out + n, cap - n, "sistema: Windows %lu.%lu build %lu%s\n", v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber, wine);
    char cpu[128] = "";
    DWORD sz = sizeof cpu;
    RegGetValueA(HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "ProcessorNameString", RRF_RT_REG_SZ, NULL, cpu, &sz);
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    const char *cpu_name = cpu;
    while (*cpu_name == ' ') cpu_name++; // o registro às vezes vem com espaços na frente
    n += snprintf(out + n, cap - n, "processador: %s (%lu núcleos lógicos)\n", cpu_name, si.dwNumberOfProcessors);
    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof ms;
    if (GlobalMemoryStatusEx(&ms)) n += snprintf(out + n, cap - n, "memória: %llu MB (%llu MB livres)\n", ms.ullTotalPhys >> 20, ms.ullAvailPhys >> 20);
    // placas de vídeo
    HMODULE dxgi = LoadLibraryA("dxgi.dll");
    typedef HRESULT(WINAPI * CreateFactory)(REFIID, void **);
    CreateFactory cf = dxgi ? (CreateFactory)(void *)GetProcAddress(dxgi, "CreateDXGIFactory1") : NULL;
    static const GUID iid_factory1 = {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
    IDXGIFactory1 *f = NULL;
    if (cf && SUCCEEDED(cf(&iid_factory1, (void **)&f)) && f) {
        IDXGIAdapter1 *a = NULL;
        for (UINT i = 0; f->lpVtbl->EnumAdapters1(f, i, &a) == S_OK; i++) {
            DXGI_ADAPTER_DESC1 d;
            if (SUCCEEDED(a->lpVtbl->GetDesc1(a, &d))) {
                char name[128];
                WideCharToMultiByte(CP_UTF8, 0, d.Description, -1, name, sizeof name, NULL, NULL);
                n += snprintf(out + n, cap - n, "placa %u: %s (vendor %04x, %llu MB de vídeo)%s\n", i, name, d.VendorId,
                              (unsigned long long)d.DedicatedVideoMemory >> 20, (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? " [software]" : "");
            }
            a->lpVtbl->Release(a);
            if (n >= cap - 1) break;
        }
        f->lpVtbl->Release(f);
    }
    return n;
}

// Manda `path` num POST multipart (campo `field`; `content` vai junto como
// texto, pro Discord). Resposta em `out`. Retorna o código HTTP, ou -1.
int dbg_http_post_file(const char *url, const char *path, const char *field, const char *filename, const char *content, char *out, int cap) {
    if (cap > 0) out[0] = 0;
    // arquivo inteiro na memória (o log é limitado por quem chama)
    WCHAR wpath[1024];
    if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 1024)) return -1;
    HANDLE fh = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (fh == INVALID_HANDLE_VALUE) return -1;
    LARGE_INTEGER fsz;
    GetFileSizeEx(fh, &fsz);
    if (fsz.QuadPart > 200ll * 1024 * 1024) {
        CloseHandle(fh);
        return -1;
    }
    const char *boundary = "----telinhaDebugBoundary7MA4YWxk";
    char head[1024], mid[512];
    int hl = 0;
    if (content && content[0])
        hl += snprintf(head + hl, sizeof head - hl, "--%s\r\nContent-Disposition: form-data; name=\"content\"\r\n\r\n%s\r\n", boundary, content);
    hl += snprintf(head + hl, sizeof head - hl, "--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: text/plain\r\n\r\n", boundary, field, filename);
    int ml = snprintf(mid, sizeof mid, "\r\n--%s--\r\n", boundary);
    size_t total = (size_t)hl + (size_t)fsz.QuadPart + (size_t)ml;
    char *body = malloc(total);
    if (!body) {
        CloseHandle(fh);
        return -1;
    }
    memcpy(body, head, hl);
    DWORD got = 0;
    ReadFile(fh, body + hl, (DWORD)fsz.QuadPart, &got, NULL);
    CloseHandle(fh);
    memcpy(body + hl + got, mid, ml);
    total = (size_t)hl + got + ml;

    WCHAR wurl[1024];
    MultiByteToWideChar(CP_UTF8, 0, url, -1, wurl, 1024);
    URL_COMPONENTS uc;
    WCHAR host[256], upath[1024];
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    uc.lpszUrlPath = upath;
    uc.dwUrlPathLength = 1024;
    int code = -1;
    HINTERNET s = NULL, c = NULL, r = NULL;
    if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) goto done;
    s = WinHttpOpen(L"telinha", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s) goto done;
    WinHttpSetTimeouts(s, 15000, 15000, 300000, 300000);
    c = WinHttpConnect(s, host, uc.nPort, 0);
    if (!c) goto done;
    r = WinHttpOpenRequest(c, L"POST", upath, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
    if (!r) goto done;
    WCHAR hdr[160];
    swprintf(hdr, 160, L"Content-Type: multipart/form-data; boundary=%hs\r\n", boundary);
    if (!WinHttpSendRequest(r, hdr, (DWORD)-1L, body, (DWORD)total, (DWORD)total, 0)) goto done;
    if (!WinHttpReceiveResponse(r, NULL)) goto done;
    DWORD st = 0, sz = sizeof st;
    WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &st, &sz, WINHTTP_NO_HEADER_INDEX);
    code = (int)st;
    int len = 0;
    for (;;) {
        DWORD rd = 0;
        if (len >= cap - 1 || !WinHttpReadData(r, out + len, (DWORD)(cap - 1 - len), &rd) || rd == 0) break;
        len += (int)rd;
    }
    if (cap > 0) out[len] = 0;
done:
    free(body);
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    return code;
}
#else
int dbg_proc_stats(dbg_stats *s) {
    memset(s, 0, sizeof *s);
    return 0; // Linux: lido em Zig (/proc)
}

int dbg_sysinfo(char *out, int cap) {
    if (cap > 0) out[0] = 0;
    return 0; // Linux: lido em Zig (/proc, /etc/os-release)
}

// Linux: o curl do sistema (sem shell: os argumentos vão direto).
int dbg_http_post_file(const char *url, const char *path, const char *field, const char *filename, const char *content, char *out, int cap) {
    if (cap > 0) out[0] = 0;
    char form[1400], cont[1200];
    snprintf(form, sizeof form, "%s=@%s;filename=%s;type=text/plain", field, path, filename);
    snprintf(cont, sizeof cont, "content=%s", content ? content : "");
    const char *argv[16];
    int a = 0;
    argv[a++] = "curl";
    argv[a++] = "-sS";
    argv[a++] = "--max-time";
    argv[a++] = "300";
    argv[a++] = "-w";
    argv[a++] = "\n%{http_code}";
    argv[a++] = "-F";
    argv[a++] = form;
    if (content && content[0]) {
        argv[a++] = "--form-string"; // texto puro (sem @arquivo nem ;type=)
        argv[a++] = cont;
    }
    argv[a++] = url;
    argv[a] = NULL;
    int pfd[2];
    // fecha no exec: um processo que outra thread abrir agora não herda a
    // ponta de escrita (senão a leitura daqui nunca veria o fim)
    if (pipe(pfd) != 0) return -1;
    fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pfd[1], F_SETFD, FD_CLOEXEC); // o adddup2 do spawn tira isso no stdout do curl
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    pid_t pid;
    int rc = posix_spawnp(&pid, "curl", &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pfd[1]);
    if (rc != 0) {
        close(pfd[0]);
        return -1;
    }
    // lê tudo (o curl trava se ninguém ler); o que não cabe em `out` só
    // guarda o fim, que é onde vem o código HTTP
    int len = 0, over = 0;
    char tail[64];
    int tl = 0;
    for (;;) {
        char tmp[4096];
        char *dst = len < cap - 1 ? out + len : tmp;
        int room = len < cap - 1 ? cap - 1 - len : (int)sizeof tmp;
        ssize_t rd = read(pfd[0], dst, room);
        if (rd < 0 && errno == EINTR) continue;
        if (rd <= 0) break;
        if (dst == tmp) {
            over = 1;
            int k = rd > (ssize_t)sizeof tail - 1 ? (int)sizeof tail - 1 : (int)rd;
            if (tl + k > (int)sizeof tail - 1) {
                int drop = tl + k - ((int)sizeof tail - 1);
                memmove(tail, tail + drop, tl - drop);
                tl -= drop;
            }
            memcpy(tail + tl, tmp + rd - k, k);
            tl += k;
        } else
            len += (int)rd;
    }
    close(pfd[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (cap > 0) out[len] = 0;
    tail[tl] = 0;
    // última linha = código HTTP (-w)
    char *nl = strrchr(over ? tail : out, '\n');
    if (!nl) return -1;
    int code = atoi(nl + 1);
    if (!over) *nl = 0;
    return code > 0 ? code : -1;
}
#endif
