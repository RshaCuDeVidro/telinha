// Relatório de travamento: se o app cair (falha de memória, instrução
// inválida, abort, panic do Zig), escreve o que der num arquivo — o motivo e
// a pilha com módulo + deslocamento (o binário de release não tem símbolos;
// o deslocamento casa com um build sem strip do mesmo commit). Na próxima
// abertura o app oferece mandar (ver crash.zig).
//
// Linux: tratadores de sinal numa pilha alternativa (estouro de pilha também
// cai aqui), só funções seguras dentro de sinal. Windows: filtro de exceção
// não tratada, pilha desenrolada a partir do contexto da falha.
#ifndef _WIN32
#define _GNU_SOURCE // gettid
#endif
#include "crash.h"

#include <stdint.h>
#include <string.h>

static char g_path[1024];
static char g_info[1536];

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static HANDLE open_report(void) {
    WCHAR w[1024];
    if (!MultiByteToWideChar(CP_UTF8, 0, g_path, -1, w, 1024)) return INVALID_HANDLE_VALUE;
    HANDLE h = CreateFileW(w, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    return h;
}

static void put(HANDLE h, const char *s) {
    DWORD n;
    WriteFile(h, s, (DWORD)strlen(s), &n, NULL);
}

static void put_hex(HANDLE h, unsigned long long v) {
    char b[24];
    int i = 23;
    b[i] = 0;
    do {
        b[--i] = "0123456789abcdef"[v & 15];
        v >>= 4;
    } while (v && i > 2);
    b[--i] = 'x';
    b[--i] = '0';
    put(h, b + i);
}

// "módulo+0xdesloc" do endereço
static void put_addr(HANDLE h, DWORD64 addr) {
    HMODULE mod = NULL;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)(ULONG_PTR)addr, &mod) && mod) {
        WCHAR wn[MAX_PATH];
        char n[MAX_PATH * 3];
        DWORD len = GetModuleFileNameW(mod, wn, MAX_PATH);
        WCHAR *base = wn;
        for (DWORD i = 0; i < len; i++)
            if (wn[i] == L'\\' || wn[i] == L'/') base = wn + i + 1;
        if (WideCharToMultiByte(CP_UTF8, 0, base, -1, n, sizeof n, NULL, NULL) > 0) put(h, n);
        put(h, "+");
        put_hex(h, addr - (DWORD64)(ULONG_PTR)mod);
    } else
        put_hex(h, addr);
}

static const char *exc_name(DWORD code) {
    switch (code) {
    case EXCEPTION_ACCESS_VIOLATION: return "acesso inválido à memória";
    case EXCEPTION_STACK_OVERFLOW: return "estouro de pilha";
    case EXCEPTION_ILLEGAL_INSTRUCTION: return "instrução inválida";
    case EXCEPTION_INT_DIVIDE_BY_ZERO: return "divisão por zero";
    case EXCEPTION_IN_PAGE_ERROR: return "erro de página";
    case 0xC0000409: return "verificação de segurança da pilha";
    default: return "exceção";
    }
}

static LONG WINAPI on_exception(EXCEPTION_POINTERS *ep) {
    static volatile LONG once = 0;
    if (InterlockedExchange(&once, 1)) return EXCEPTION_CONTINUE_SEARCH;
    HANDLE h = open_report();
    if (h == INVALID_HANDLE_VALUE) return EXCEPTION_CONTINUE_SEARCH;
    put(h, "\r\n=== o telinha travou: ");
    put(h, exc_name(ep->ExceptionRecord->ExceptionCode));
    put(h, " (código ");
    put_hex(h, ep->ExceptionRecord->ExceptionCode);
    put(h, ") em ");
    put_addr(h, (DWORD64)(ULONG_PTR)ep->ExceptionRecord->ExceptionAddress);
    if (ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && ep->ExceptionRecord->NumberParameters >= 2) {
        put(h, ep->ExceptionRecord->ExceptionInformation[0] ? " escrevendo em " : " lendo de ");
        put_hex(h, ep->ExceptionRecord->ExceptionInformation[1]);
    }
    put(h, "\r\nthread ");
    put_hex(h, GetCurrentThreadId());
    put(h, "\r\n");
    put(h, g_info);
    put(h, "\r\npilha:\r\n");
#if defined(_M_X64) || defined(__x86_64__)
    CONTEXT ctx = *ep->ContextRecord;
    for (int i = 0; i < 48 && ctx.Rip; i++) {
        put(h, "  ");
        put_addr(h, ctx.Rip);
        put(h, "\r\n");
        DWORD64 image = 0;
        PRUNTIME_FUNCTION fn = RtlLookupFunctionEntry(ctx.Rip, &image, NULL);
        if (!fn) {
            // função folha: o endereço de volta está no topo da pilha
            if (!ctx.Rsp) break;
            ctx.Rip = *(DWORD64 *)(ULONG_PTR)ctx.Rsp;
            ctx.Rsp += 8;
            continue;
        }
        void *handler_data = NULL;
        DWORD64 frame = 0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, ctx.Rip, fn, &ctx, &handler_data, &frame, NULL);
    }
#endif
    CloseHandle(h);
    // relatório escrito: fecha sem a janela "parou de funcionar" do Windows
    // (o telinha pergunta na próxima abertura)
    return EXCEPTION_EXECUTE_HANDLER;
}

void crash_install(const char *path_utf8, const char *info) {
    strncpy(g_path, path_utf8, sizeof g_path - 1);
    strncpy(g_info, info ? info : "", sizeof g_info - 1);
    SetUnhandledExceptionFilter(on_exception);
}

void crash_note(const char *msg) {
    if (!g_path[0]) return;
    HANDLE h = open_report();
    if (h == INVALID_HANDLE_VALUE) return;
    put(h, "\r\n=== o telinha travou (panic): ");
    put(h, msg);
    put(h, "\r\n");
    put(h, g_info);
    put(h, "\r\n");
    CloseHandle(h);
}

#else // Linux
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static char g_altstack[64 * 1024];

static void put(int fd, const char *s) {
    ssize_t r = write(fd, s, strlen(s));
    (void)r;
}

static void put_num(int fd, unsigned long long v, int base) {
    char b[24];
    int i = 23;
    b[i] = 0;
    do {
        b[--i] = "0123456789abcdef"[v % (unsigned)base];
        v /= (unsigned)base;
    } while (v && i > 2);
    if (base == 16) {
        b[--i] = 'x';
        b[--i] = '0';
    }
    put(fd, b + i);
}

static const char *sig_name(int sig) {
    switch (sig) {
    case SIGSEGV: return "SIGSEGV (acesso inválido à memória)";
    case SIGBUS: return "SIGBUS (erro de barramento)";
    case SIGILL: return "SIGILL (instrução inválida)";
    case SIGFPE: return "SIGFPE (erro aritmético)";
    case SIGABRT: return "SIGABRT (abortou)";
    default: return "sinal";
    }
}

static void on_signal(int sig, siginfo_t *si, void *uc) {
    (void)uc;
    static volatile sig_atomic_t once = 0;
    if (!once) {
        once = 1;
        int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) {
            put(fd, "\n=== o telinha travou: ");
            put(fd, sig_name(sig));
            if (sig != SIGABRT && si) {
                put(fd, " no endereço ");
                put_num(fd, (unsigned long long)(uintptr_t)si->si_addr, 16);
            }
            put(fd, "\nthread ");
            put_num(fd, (unsigned long long)gettid(), 10);
            put(fd, "\n");
            put(fd, g_info);
            put(fd, "\npilha:\n");
            void *frames[64];
            int n = backtrace(frames, 64);
            backtrace_symbols_fd(frames, n, fd);
            close(fd);
        }
    }
    // SA_RESETHAND: o tratador padrão volta; o sinal de novo derruba de vez
    raise(sig);
}

void crash_install(const char *path_utf8, const char *info) {
    strncpy(g_path, path_utf8, sizeof g_path - 1);
    strncpy(g_info, info ? info : "", sizeof g_info - 1);
    // a primeira chamada do backtrace carrega a libgcc (aloca): faz agora, fora do sinal
    void *warm[2];
    backtrace(warm, 2);
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp = g_altstack;
    ss.ss_size = sizeof g_altstack;
    sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    const int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};
    for (unsigned i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
}

void crash_note(const char *msg) {
    if (!g_path[0]) return;
    int fd = open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    put(fd, "\n=== o telinha travou (panic): ");
    put(fd, msg);
    put(fd, "\n");
    put(fd, g_info);
    put(fd, "\n");
    close(fd);
}
#endif

void crash_now(int how) {
    (void)how;
    volatile int *p = (volatile int *)(uintptr_t)16;
    *p = 1; // falha de memória de propósito (teste)
}
