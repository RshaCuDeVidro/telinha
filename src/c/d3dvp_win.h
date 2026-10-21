// Windows (Intel/AMD, ou qualquer placa com o processador de vídeo do D3D11):
// a imagem da tela que o DXGI entrega (BGRA, na placa) é recortada, escalada e
// convertida pra NV12 na própria placa, numa textura que o encoder do Media
// Foundation lê direto (hwenc_mf.c). Nada passa pela CPU. Ver capture_win.c.
#pragma once
#ifdef _WIN32
#include <stdint.h>
#include <d3d11.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct d3dvp d3dvp;

// Abre o processador de vídeo no dispositivo da captura (fonte src_w x src_h)
// e faz o autoteste de cor contra a conversão da CPU. NULL + motivo se não der.
d3dvp *d3dvp_open(ID3D11Device *dev, ID3D11DeviceContext *ctx, int src_w, int src_h, char *err, int errlen);
void d3dvp_close(d3dvp *p);
// Textura NV12 (w x h) que dá pra usar de saída (e de entrada do encoder).
ID3D11Texture2D *d3dvp_new_nv12(d3dvp *p, int w, int h);
// Recorta (x, y, w, h) de `src` (BGRA), escala pra ow x oh e converte pra NV12 em `dst`. 0 = ok.
int d3dvp_convert(d3dvp *p, ID3D11Texture2D *src, int x, int y, int w, int h, ID3D11Texture2D *dst, int ow, int oh);
// Prévia pequena em RGBA (pw x ph) do pedaço (x, y, w, h) de `src`. 0 = ok.
int d3dvp_preview(d3dvp *p, ID3D11Texture2D *src, int x, int y, int w, int h, int pw, int ph, uint8_t *rgba);
// Esquece o que estava guardado de uma textura (ela vai ser liberada).
void d3dvp_forget(d3dvp *p, ID3D11Texture2D *tex);

#ifdef __cplusplus
}
#endif
#endif
