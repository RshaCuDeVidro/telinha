// Imagens do chat (ver image.c): só lê arquivos/área de transferência locais.
#pragma once
#include <stdint.h>
#ifdef _WIN32
#include <wchar.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// PNG/JPEG/GIF/BMP em memória → RGBA (liberar com img_free). NULL se não der.
uint8_t *img_decode(const uint8_t *data, int len, int *w, int *h);
void img_free(uint8_t *rgba);

#ifdef _WIN32
// Imagem copiada (CF_DIB) → RGBA (liberar com free()). Se o que foi copiado é
// um arquivo, devolve NULL e o caminho em `path`.
uint8_t *img_clipboard(int *w, int *h, wchar_t *path, int path_cap);
#endif

#ifdef __cplusplus
}
#endif
