// Uma janela só pros convites: o link telinha:// clicado com o telinha já
// aberto entregava o convite pra uma SEGUNDA janela (duas salas, dois
// microfones). Agora o processo novo entrega o convite pro que está aberto e
// fecha. Linux: socket Unix no espaço abstrato (some sozinho quando o app
// fecha); Windows: pipe com nome. O nome vem da pasta de configurações (dois
// telinhas com configurações separadas, como nos testes, não se misturam).
#ifndef _WIN32
#define _GNU_SOURCE // accept4
#endif
#include "single.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define MAX_INVITE 1024

int single_errno; // o motivo da última falha (log de depuração)

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static void (*g_cb)(const char *);
static wchar_t g_pipe[128];

static void pipe_name(const char *name, wchar_t *out, int cap) {
    wchar_t w[96];
    MultiByteToWideChar(CP_UTF8, 0, name, -1, w, 96);
    _snwprintf(out, cap, L"\\\\.\\pipe\\%ls", w);
    out[cap - 1] = 0;
}

int single_handoff(const char *name, const char *invite) {
    wchar_t p[128];
    pipe_name(name, p, 128);
    HANDLE h = CreateFileW(p, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        // ocupado com outro convite: espera um pouco
        if (GetLastError() != ERROR_PIPE_BUSY || !WaitNamedPipeW(p, 1000)) return 0;
        h = CreateFileW(p, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (h == INVALID_HANDLE_VALUE) return 0;
    }
    DWORD n = 0;
    const DWORD len = (DWORD)strlen(invite);
    char ack = 0;
    const int ok = WriteFile(h, invite, len > MAX_INVITE ? MAX_INVITE : len, &n, NULL) && ReadFile(h, &ack, 1, &n, NULL) && n == 1 && ack == 1;
    CloseHandle(h);
    return ok;
}

static DWORD WINAPI serve(LPVOID first_h) {
    HANDLE h = (HANDLE)first_h;
    for (;;) {
        if (ConnectNamedPipe(h, NULL) || GetLastError() == ERROR_PIPE_CONNECTED) {
            char buf[MAX_INVITE + 1];
            DWORD n = 0;
            if (ReadFile(h, buf, MAX_INVITE, &n, NULL) && n > 0) {
                buf[n] = 0;
                char ack = 1;
                DWORD w = 0;
                WriteFile(h, &ack, 1, &w, NULL);
                FlushFileBuffers(h);
                g_cb(buf);
            }
        }
        DisconnectNamedPipe(h);
    }
    return 0;
}

int single_listen(const char *name, void (*cb)(const char *)) {
    g_cb = cb;
    pipe_name(name, g_pipe, 128);
    // a primeira instância do pipe é desta janela; outra já tendo: não é a principal
    HANDLE h = CreateNamedPipeW(g_pipe, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1,
                                MAX_INVITE, MAX_INVITE, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        single_errno = (int)GetLastError();
        return GetLastError() == ERROR_ACCESS_DENIED ? 0 : -1; // a primeira instância é de outra janela
    }
    HANDLE t = CreateThread(NULL, 0, serve, h, 0, NULL);
    if (!t) {
        CloseHandle(h);
        return -1;
    }
    CloseHandle(t);
    return 1;
}

#else
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static void (*g_cb)(const char *);
static int g_fd = -1;

static socklen_t addr_of(const char *name, struct sockaddr_un *a) {
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    // espaço abstrato: sun_path[0] = 0 (nada no disco, some quando o app fecha)
    const size_t n = strlen(name) < sizeof a->sun_path - 2 ? strlen(name) : sizeof a->sun_path - 2;
    memcpy(a->sun_path + 1, name, n);
    return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
}

static void timeouts(int fd) {
    struct timeval tv = {1, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

int single_handoff(const char *name, const char *invite) {
    struct sockaddr_un a;
    const socklen_t len = addr_of(name, &a);
    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return 0;
    timeouts(fd);
    int ok = 0;
    if (connect(fd, (struct sockaddr *)&a, len) == 0) {
        size_t n = strlen(invite);
        if (n > MAX_INVITE) n = MAX_INVITE;
        char ack = 0;
        ok = write(fd, invite, n) == (ssize_t)n && shutdown(fd, SHUT_WR) == 0 && read(fd, &ack, 1) == 1 && ack == 1;
    }
    close(fd);
    return ok;
}

static void *serve(void *arg) {
    (void)arg;
    for (;;) {
        const int c = accept4(g_fd, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) {
            if (errno == EINTR) continue;
            return NULL;
        }
        timeouts(c);
        char buf[MAX_INVITE + 1];
        size_t n = 0;
        for (;;) {
            const ssize_t r = read(c, buf + n, MAX_INVITE - n);
            if (r <= 0) break;
            n += (size_t)r;
            if (n == MAX_INVITE) break;
        }
        if (n > 0) {
            buf[n] = 0;
            const char ack = 1;
            if (write(c, &ack, 1) != 1) {
            }
            g_cb(buf);
        }
        close(c);
    }
}

int single_listen(const char *name, void (*cb)(const char *)) {
    g_cb = cb;
    struct sockaddr_un a;
    const socklen_t len = addr_of(name, &a);
    const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        single_errno = errno;
        return -1;
    }
    if (bind(fd, (struct sockaddr *)&a, len) != 0) {
        single_errno = errno;
        close(fd);
        return errno == EADDRINUSE ? 0 : -1; // outra janela já é a principal
    }
    if (listen(fd, 4) != 0) {
        single_errno = 1000 + errno;
        close(fd);
        return -1;
    }
    g_fd = fd;
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    const int r = pthread_create(&t, &at, serve, NULL);
    pthread_attr_destroy(&at);
    if (r != 0) {
        single_errno = 2000 + r;
        close(fd);
        g_fd = -1;
        return -1;
    }
    return 1;
}
#endif
