#pragma once
#include <stdio.h>

// Caminho do próprio executável (UTF-8). 0 = ok.
int upd_self_path(char *out, int cap);
// Dá pra criar arquivo nessa pasta? (1 = sim)
int upd_can_write(const char *dir);
// Baixa a URL pro arquivo (segue redirecionamento). 0 = ok; -2 = sem curl (Linux).
int upd_download(const char *url, const char *path);
// Põe `newfile` no lugar do executável `self`; o de agora fica em `self`.old
// (pra voltar se o novo não abrir). 0 = ok.
int upd_swap(const char *self, const char *newfile);
// Apaga sobras de uma atualização anterior (.novo e, sem keep_old, o .old).
void upd_cleanup(const char *self, int keep_old);
// Abre o executável de novo com os mesmos argumentos (quem chama sai depois).
// 0 = ok; -2 = o novo morreu logo ao abrir (biblioteca, processador): não saia.
int upd_relaunch(const char *self);
// Servidor (Linux): vira o executável de novo no mesmo processo (execve).
// Só volta se falhar (-1).
int upd_reexec(const char *self, int after_update);
// Põe o `self`.old de volta no lugar. 0 = ok.
int upd_rollback(const char *self);
// Marca "versão nova em teste" (`self`.testando): on = 1 cria, 0 apaga.
void upd_mark(const char *self, int on);
// A marca existe? (a versão nova morreu antes de passar no teste)
int upd_marked(const char *self);
// Tamanho do arquivo (-1 = não existe).
long long upd_file_size(const char *path);
// Ao abrir depois de reiniciar: espera a versão anterior fechar (até 15 s).
// 1 = abriu pelo reinício de uma atualização.
int upd_wait_previous(void);
// Abre pra leitura (caminho UTF-8, também no Windows).
FILE *upd_fopen(const char *path);
