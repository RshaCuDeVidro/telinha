// Log de depuração (ver debugsys.c e debuglog.zig).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dbg_stats {
    unsigned long long proc_cpu_ms;  // CPU do processo (usuário + sistema)
    unsigned long long sys_total_ms; // tempo de CPU do sistema todo
    unsigned long long sys_idle_ms;  // ... ocioso
    unsigned long long rss_kb;       // memória em uso
    unsigned long long ram_total_kb, ram_free_kb;
} dbg_stats;

// Saída de erro do processo (fd 2 / STD_ERROR_HANDLE) vai pro arquivo
// (NULL = descarta). 0 = ok.
int dbg_redirect_stderr(const char *path_utf8);
// Volta a saída de erro pra onde estava antes do primeiro desvio.
int dbg_restore_stderr(void);
// Liga TELINHA_DEBUG pro processo (o C lê na hora). Uma vez só; desligar não
// mexe no ambiente (ver debugsys.c).
void dbg_set_env(int on);
// Windows: CPU e memória do processo e do sistema. Linux: zerado (é /proc).
int dbg_proc_stats(dbg_stats *s);
// Windows: as threads do processo, com o tempo de CPU (ms) e o nome. Linux: -1 (é /proc).
typedef struct dbg_thread {
    unsigned tid;
    unsigned long long cpu_ms;
    char name[32]; // sem nome: "t<id>@<dll onde começou>"
} dbg_thread;
int dbg_threads(dbg_thread *out, int max);
// Windows: sistema, processador, memória, placas de vídeo. Linux: vazio.
int dbg_sysinfo(char *out, int cap);
// POST multipart com o arquivo (gofile, webhook). Retorna o código HTTP ou -1;
// o corpo da resposta vai em `out`.
int dbg_http_post_file(const char *url, const char *path, const char *field, const char *filename, const char *content, char *out, int cap);

#ifdef __cplusplus
}
#endif
