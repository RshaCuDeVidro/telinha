// Relatório de travamento (ver crash.c e o crash.zig).
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Liga os tratadores: se o app cair, escreve em `path` (UTF-8) o motivo, a
// pilha (módulo + deslocamento) e `info` (versão, sistema).
void crash_install(const char *path_utf8, const char *info);
// Mais uma linha fixa no relatório (placa, driver, sessão: o que só se sabe depois de abrir).
void crash_add_info(const char *line);
// O que o app está fazendo agora (vai no relatório; troque só quando mudar).
void crash_set_context(const char *ctx);
// Anota uma linha no relatório (panic do Zig, antes de fechar).
void crash_note(const char *msg);
// Teste: derruba o app de propósito (1 = falha de memória).
void crash_now(int how);

#ifdef __cplusplus
}
#endif
