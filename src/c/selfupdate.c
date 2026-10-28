// Atualização do próprio app: onde está o executável, baixar a versão nova
// pra um arquivo, trocar o executável e abrir de novo. Quem confere a
// assinatura e o sha256 é o update.zig, antes de trocar.
//
// Windows: o .exe em uso não pode ser apagado nem sobrescrito, mas pode ser
// renomeado: vira telinha.exe.old (apagado na próxima vez que abrir) e o novo
// entra no lugar. Linux: rename() por cima é atômico e o processo que está
// rodando continua com o arquivo antigo até sair.
#include "selfupdate.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// teto do que se baixa (o mesmo de update.max_bin_bytes)
#define UPD_MAX_BYTES (256ull * 1024 * 1024)
#define UPD_MAX_BYTES_STR "268435456"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

static int to_wide(const char *s, WCHAR *out, int cap) {
    return MultiByteToWideChar(CP_UTF8, 0, s, -1, out, cap) > 0;
}

int upd_self_path(char *out, int cap) {
    WCHAR w[1024];
    DWORD n = GetModuleFileNameW(NULL, w, 1024);
    if (n == 0 || n >= 1024) return -1;
    return WideCharToMultiByte(CP_UTF8, 0, w, -1, out, cap, NULL, NULL) > 0 ? 0 : -1;
}

int upd_can_write(const char *dir) {
    // Arquivos de Programas sem ser administrador: o único jeito certo de
    // saber é tentar criar um arquivo
    char p[1100];
    snprintf(p, sizeof p, "%s\\.telinha-teste-escrita", dir);
    WCHAR w[1100];
    if (!to_wide(p, w, 1100)) return 0;
    HANDLE h = CreateFileW(w, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    CloseHandle(h);
    return 1;
}

int upd_download(const char *url, const char *path) {
    WCHAR wurl[1024], wpath[1100];
    if (!to_wide(url, wurl, 1024) || !to_wide(path, wpath, 1100)) return -1;
    URL_COMPONENTS uc;
    WCHAR host[256], upath[900];
    memset(&uc, 0, sizeof uc);
    uc.dwStructSize = sizeof uc;
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    uc.lpszUrlPath = upath;
    uc.dwUrlPathLength = 900;
    if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) return -1;
    int rc = -1;
    HANDLE f = INVALID_HANDLE_VALUE;
    HINTERNET s = WinHttpOpen(L"telinha", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET c = NULL, r = NULL;
    if (!s) goto done;
    WinHttpSetTimeouts(s, 15000, 15000, 30000, 60000);
    c = WinHttpConnect(s, host, uc.nPort, 0);
    if (!c) goto done;
    // o GitHub manda pro servidor de arquivos (redirecionamento): o WinHTTP segue
    r = WinHttpOpenRequest(c, L"GET", upath, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                           uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
    if (!r) goto done;
    if (!WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) goto done;
    if (!WinHttpReceiveResponse(r, NULL)) goto done;
    DWORD status = 0, sz = sizeof status;
    if (!WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz, WINHTTP_NO_HEADER_INDEX) || status != 200) goto done;
    f = CreateFileW(wpath, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) goto done;
    static char buf[64 * 1024];
    unsigned long long total = 0;
    for (;;) {
        DWORD got = 0, wrote = 0;
        if (!WinHttpReadData(r, buf, sizeof buf, &got)) goto done;
        if (got == 0) break;
        total += got;
        if (total > UPD_MAX_BYTES) goto done; // nenhum executável nosso chega perto
        if (!WriteFile(f, buf, got, &wrote, NULL) || wrote != got) goto done;
    }
    rc = 0;
done:
    if (f != INVALID_HANDLE_VALUE) CloseHandle(f);
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    if (rc != 0) DeleteFileW(wpath);
    return rc;
}

int upd_swap(const char *self, const char *newfile) {
    WCHAR wself[1100], wold[1110], wnew[1100];
    char old[1110];
    snprintf(old, sizeof old, "%s.old", self);
    if (!to_wide(self, wself, 1100) || !to_wide(old, wold, 1110) || !to_wide(newfile, wnew, 1100)) return -1;
    DeleteFileW(wold); // sobra de uma atualização anterior
    if (!MoveFileExW(wself, wold, MOVEFILE_REPLACE_EXISTING)) return -1;
    if (!MoveFileExW(wnew, wself, MOVEFILE_REPLACE_EXISTING)) {
        MoveFileExW(wold, wself, MOVEFILE_REPLACE_EXISTING); // desfaz
        return -1;
    }
    return 0;
}

void upd_cleanup(const char *self, int keep_old) {
    char p[1110];
    WCHAR w[1110];
    if (!keep_old) {
        snprintf(p, sizeof p, "%s.old", self);
        if (to_wide(p, w, 1110)) DeleteFileW(w);
    }
    snprintf(p, sizeof p, "%s.novo", self);
    if (to_wide(p, w, 1110)) DeleteFileW(w);
}

int upd_rollback(const char *self) {
    WCHAR wself[1100], wold[1110];
    char old[1110];
    snprintf(old, sizeof old, "%s.old", self);
    if (!to_wide(self, wself, 1100) || !to_wide(old, wold, 1110)) return -1;
    if (GetFileAttributesW(wold) == INVALID_FILE_ATTRIBUTES) return -1;
    // o novo pode ser o que está rodando: renomeia ele pra fora antes
    char bad[1110];
    WCHAR wbad[1110];
    snprintf(bad, sizeof bad, "%s.ruim", self);
    if (!to_wide(bad, wbad, 1110)) return -1;
    DeleteFileW(wbad);
    if (!MoveFileExW(wself, wbad, MOVEFILE_REPLACE_EXISTING)) return -1;
    if (!MoveFileExW(wold, wself, MOVEFILE_REPLACE_EXISTING)) {
        MoveFileExW(wbad, wself, MOVEFILE_REPLACE_EXISTING);
        return -1;
    }
    return 0;
}

void upd_mark(const char *self, int on) {
    char p[1110];
    WCHAR w[1110];
    snprintf(p, sizeof p, "%s.testando", self);
    if (!to_wide(p, w, 1110)) return;
    if (!on) {
        DeleteFileW(w);
        return;
    }
    HANDLE h = CreateFileW(w, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
}

int upd_marked(const char *self) {
    char p[1110];
    WCHAR w[1110];
    snprintf(p, sizeof p, "%s.testando", self);
    return to_wide(p, w, 1110) && GetFileAttributesW(w) != INVALID_FILE_ATTRIBUTES;
}

int upd_relaunch(const char *self) {
    WCHAR wself[1100];
    if (!to_wide(self, wself, 1100)) return -1;
    // os mesmos argumentos (a linha de comando inteira, com o programa na frente)
    const WCHAR *cl = GetCommandLineW();
    size_t n = wcslen(cl) + 1;
    WCHAR *line = malloc(n * sizeof(WCHAR));
    if (!line) return -1;
    memcpy(line, cl, n * sizeof(WCHAR));
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    // o novo espera este fechar (sala hospedada: a porta ainda está com este)
    WCHAR pidw[32];
    swprintf(pidw, 32, L"%lu", (unsigned long)GetCurrentProcessId());
    SetEnvironmentVariableW(L"TELINHA_ESPERAR_PID", pidw);
    BOOL ok = CreateProcessW(wself, line, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi);
    SetEnvironmentVariableW(L"TELINHA_ESPERAR_PID", NULL);
    free(line);
    if (!ok) return -1;
    CloseHandle(pi.hThread);
    // o novo fica esperando este fechar: se ele morreu antes disso, nem abriu
    // (DLL que falta, instrução que o processador não tem)
    const DWORD w = WaitForSingleObject(pi.hProcess, 1000);
    CloseHandle(pi.hProcess);
    return w == WAIT_OBJECT_0 ? -2 : 0;
}

int upd_wait_previous(void) {
    WCHAR v[32];
    if (GetEnvironmentVariableW(L"TELINHA_ESPERAR_PID", v, 32) == 0) return 0;
    SetEnvironmentVariableW(L"TELINHA_ESPERAR_PID", NULL);
    DWORD pid = (DWORD)wcstoul(v, NULL, 10);
    HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (!h) return 1;
    WaitForSingleObject(h, 15000);
    CloseHandle(h);
    return 1;
}

FILE *upd_fopen(const char *path) {
    WCHAR w[1100];
    if (!to_wide(path, w, 1100)) return NULL;
    return _wfopen(w, L"rb");
}

long long upd_file_size(const char *path) {
    WCHAR w[1100];
    WIN32_FILE_ATTRIBUTE_DATA a;
    if (!to_wide(path, w, 1100) || !GetFileAttributesExW(w, GetFileExInfoStandard, &a)) return -1;
    return ((long long)a.nFileSizeHigh << 32) | a.nFileSizeLow;
}

#else
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

int upd_self_path(char *out, int cap) {
    ssize_t n = readlink("/proc/self/exe", out, (size_t)cap - 1);
    if (n <= 0) return -1;
    out[n] = 0;
    // o executável foi trocado enquanto rodava: o kernel põe " (deleted)"
    const char *tag = " (deleted)";
    size_t tl = strlen(tag);
    if ((size_t)n > tl && strcmp(out + n - tl, tag) == 0) out[n - tl] = 0;
    return 0;
}

int upd_can_write(const char *dir) {
    return access(dir, W_OK) == 0;
}

int upd_download(const char *url, const char *path) {
    // curl (quase todo Linux tem): sem shell no meio, o endereço vai como argumento
    const char *argv[] = {"curl", "-fsSL", "--max-time", "900", "--retry", "2", "--max-filesize", UPD_MAX_BYTES_STR, "-A", "telinha", "-o", path, url, NULL};
    pid_t pid;
    if (posix_spawnp(&pid, "curl", NULL, NULL, (char *const *)argv, environ) != 0) return -2;
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
    }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        unlink(path);
        return -1;
    }
    return 0;
}

int upd_swap(const char *self, const char *newfile) {
    if (chmod(newfile, 0755) != 0) return -1;
    // o de agora fica como .old (outro nome pro mesmo arquivo; o rename abaixo
    // é atômico): se o novo não abrir, volta
    char old[1110];
    snprintf(old, sizeof old, "%s.old", self);
    unlink(old);
    if (link(self, old) != 0) old[0] = 0;
    if (rename(newfile, self) != 0) {
        if (old[0]) unlink(old);
        return -1;
    }
    return 0;
}

void upd_cleanup(const char *self, int keep_old) {
    char p[1110];
    snprintf(p, sizeof p, "%s.novo", self);
    unlink(p);
    if (!keep_old) {
        snprintf(p, sizeof p, "%s.old", self);
        unlink(p);
    }
}

int upd_rollback(const char *self) {
    char old[1110];
    snprintf(old, sizeof old, "%s.old", self);
    if (access(old, F_OK) != 0) return -1;
    return rename(old, self) == 0 ? 0 : -1;
}

void upd_mark(const char *self, int on) {
    char p[1110];
    snprintf(p, sizeof p, "%s.testando", self);
    if (!on) {
        unlink(p);
        return;
    }
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) close(fd);
}

int upd_marked(const char *self) {
    char p[1110];
    snprintf(p, sizeof p, "%s.testando", self);
    return access(p, F_OK) == 0;
}

int upd_relaunch(const char *self) {
    // os mesmos argumentos de agora (/proc/self/cmdline: separados por \0)
    static char cmd[8192];
    int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, cmd, sizeof cmd - 1);
    close(fd);
    if (n <= 0) return -1;
    cmd[n] = 0;
    char *argv[128];
    int argc = 0;
    argv[argc++] = (char *)self;
    for (char *p = cmd + strlen(cmd) + 1; p < cmd + n && argc < 127; p += strlen(p) + 1) argv[argc++] = p;
    argv[argc] = NULL;
    // o ambiente de agora + quem esperar fechar (sala hospedada: a porta)
    static char pidvar[48];
    snprintf(pidvar, sizeof pidvar, "TELINHA_ESPERAR_PID=%d", (int)getpid());
    static char *envp[1024];
    int ne = 0;
    for (char **e = environ; *e && ne < 1022; e++)
        if (strncmp(*e, "TELINHA_ESPERAR_PID=", 20) != 0) envp[ne++] = *e;
    envp[ne++] = pidvar;
    envp[ne] = NULL;
    // fork + exec em vez de posix_spawn: o filho fecha tudo que herdaria (a
    // conexão com a sala ficaria aberta nele e a pessoa "não sairia")
    long maxfd = sysconf(_SC_OPEN_MAX);
    if (maxfd < 0 || maxfd > 65536) maxfd = 65536;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        for (int fd = 3; fd < maxfd; fd++) close(fd);
        execve(self, argv, envp);
        _exit(127);
    }
    // o novo fica esperando este fechar: se ele morreu antes disso, nem abriu
    // (glibc mais nova que a do sistema, instrução que o processador não tem)
    for (int i = 0; i < 20; i++) {
        int st = 0;
        if (waitpid(pid, &st, WNOHANG) == pid) return -2;
        usleep(50000);
    }
    return 0;
}

int upd_wait_previous(void) {
    const char *v = getenv("TELINHA_ESPERAR_PID");
    if (!v) return 0;
    pid_t pid = (pid_t)atoi(v);
    // "0" em vez de unsetenv: o Zig guarda a lista do ambiente do começo do
    // processo, e o unsetenv encurta essa lista no lugar (a última entrada
    // virava nulo e o primeiro std.debug.print caía nela: o app travava toda
    // vez que reiniciava depois de atualizar)
    setenv("TELINHA_ESPERAR_PID", "0", 1);
    if (pid <= 1) return 0;
    // até 15 s (kill 0 só pergunta se o processo ainda existe)
    for (int i = 0; i < 300 && kill(pid, 0) == 0; i++) usleep(50000);
    return 1;
}

FILE *upd_fopen(const char *path) {
    return fopen(path, "rb");
}

long long upd_file_size(const char *path) {
    struct stat s;
    return stat(path, &s) == 0 ? (long long)s.st_size : -1;
}
#endif
