#pragma once
#include <stdio.h>

// Caminho do próprio executável (UTF-8). 0 = ok.
int upd_self_path(char *out, int cap);
// Dá pra criar arquivo nessa pasta? (1 = sim)
int upd_can_write(const char *dir);
// Baixa a URL pro arquivo (segue redirecionamento). 0 = ok; -2 = sem curl (Linux).
int upd_download(const char *url, const char *path);
// Põe `newfile` no lugar do executável `self`. 0 = ok.
int upd_swap(const char *self, const char *newfile);
// Apaga sobras de uma atualização anterior (o .old no Windows, .novo).
void upd_cleanup(const char *self);
// Abre o executável de novo com os mesmos argumentos (quem chama sai depois). 0 = ok.
int upd_relaunch(const char *self);
// Tamanho do arquivo (-1 = não existe).
long long upd_file_size(const char *path);
// Ao abrir depois de reiniciar: espera a versão anterior fechar (até 15 s).
void upd_wait_previous(void);
// Abre pra leitura (caminho UTF-8, também no Windows).
FILE *upd_fopen(const char *path);
