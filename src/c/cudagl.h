// CUDA <-> OpenGL na mesma placa (NVIDIA): copia entre textura e memória da
// placa sem passar pela CPU. Quem transmite usa pra entregar o quadro
// capturado direto pro NVENC; quem assiste, pra levar o quadro do NVDEC direto
// pra textura que aparece. libcuda é carregada em tempo de execução: sem
// NVIDIA, cudagl_open devolve NULL e tudo segue pela CPU como antes.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cudagl cudagl;

// Retém o contexto primário do CUDA no dispositivo 0. NULL = sem CUDA.
cudagl *cudagl_open(void);
void cudagl_close(cudagl *g);

// Registra uma textura 2D do OpenGL (RGBA8, R8 ou RG8). A thread tem que
// estar com o contexto GL dono da textura ativo (vale pras cópias também).
// `write` = 1 se o CUDA vai escrever nela. NULL = não deu (GL de outro
// fabricante, textura incompatível...).
void *cudagl_register(cudagl *g, unsigned tex, int write);
void cudagl_unregister(cudagl *g, void *res);

// Memória da placa com linhas alinhadas (pitch em *pitch). 0 = falhou.
uint64_t cudagl_alloc(cudagl *g, int width_bytes, int height, int *pitch);
void cudagl_free(cudagl *g, uint64_t ptr);

// Cópias (0 = ok). As duas primeiras esperam o GL terminar de desenhar na
// textura antes de copiar.
int cudagl_tex_to_dev(cudagl *g, void *res, uint64_t dst, int dst_pitch, int width_bytes, int height);
int cudagl_dev_to_tex(cudagl *g, void *res, uint64_t src, int src_pitch, int width_bytes, int height);
int cudagl_dev_to_host(cudagl *g, uint64_t src, int src_pitch, void *dst, int dst_pitch, int width_bytes, int height);

#ifdef __cplusplus
}
#endif
