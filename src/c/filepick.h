// Janela do sistema pra escolher um arquivo (imagem pro chat). Linux: portal
// (xdg-desktop-portal, pelo libportal); Windows: GetOpenFileNameW. Roda numa
// thread: a interface pergunta com filepick_poll.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Abre a janela. 0 = abriu (ou já estava aberta); -1 = não deu.
int filepick_start(const char *title_utf8);
// 0 = ainda escolhendo, 1 = escolheu (caminho em UTF-8 em `out`), -1 = desistiu/falhou.
int filepick_poll(char *out, int cap);
#ifdef __cplusplus
}
#endif
