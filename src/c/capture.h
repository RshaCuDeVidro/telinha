// Captura de tela multiplataforma.
//   Linux:   xdg-desktop-portal + PipeWire (Wayland: Hyprland, GNOME, KDE...), X11 (XShm) de reserva
//   Windows: DXGI Desktop Duplication, GDI de reserva
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { CAP_BGRX = 0, CAP_RGBX = 1 };

typedef struct cap_source {
    int id;
    char name[160];
    uint32_t pid;  // janela: processo dono (pro som só dele); monitor: 0
    char app[64];  // janela: nome do programa ("chrome"); monitor: ""
} cap_source;

typedef struct cap_frame {
    const uint8_t *data; // válido até a próxima chamada de cap_next/cap_close
    int width, height, stride;
    int format; // CAP_BGRX ou CAP_RGBX
    // Cursor que quem chama precisa desenhar (quando o sistema não o embute
    // no quadro sem custo, ex.: Hyprland). Coordenadas em pixels do quadro.
    int cursor_draw; // 1 = desenhar
    int cursor_x, cursor_y;
    float cursor_scale; // pixels do quadro por pixel lógico
    // Onde está a ponta do cursor no quadro (seja quem for que desenha), pra
    // quem assiste poder dar zoom seguindo o mouse. cursor_known = 0: não sabe.
    int cursor_known;
    int cursor_px, cursor_py;
    // Caminho pela placa (cap_gpu_enable): o quadro está na memória da placa
    // (gpu_dev, RGBA, linhas de gpu_pitch bytes), já no tamanho de saída
    // (width x height) com recorte e cursor; `data` é NULL. Devolver com
    // cap_gpu_release quando não precisar mais.
    void *gpu;
    uint64_t gpu_dev;
    int gpu_pitch;
    int gpu_src_w, gpu_src_h; // tamanho do pedaço da fonte que virou esse quadro (antes da escala)
    // Prévia (cap_gpu_set_preview): RGBA, quando pedida e nova; vale até a
    // próxima chamada de cap_next. NULL = nada nova.
    const uint8_t *preview;
    int preview_w, preview_h;
    int preview_full; // 1 = é a fonte inteira (sem recorte)
} cap_frame;


typedef struct cap_ctx cap_ctx;

// Lista as fontes disponíveis (monitores). Retorna quantas escreveu.
int cap_list_sources(cap_source *out, int max);

// Abre a captura. Pode bloquear (no Wayland o portal abre um seletor de tela).
// fps = ritmo máximo desejado (o compositor não precisa copiar mais que isso).
// Retorna NULL e escreve o motivo em err em caso de falha.
cap_ctx *cap_open(int source_id, int show_cursor, int fps, char *err, int errlen);

// Espera um frame novo por até timeout_ms.
// 1 = frame novo em *out, 0 = nada mudou, -1 = erro fatal (err preenchido),
// 2 = só o cursor mexeu (com cap_set_cursor_apart): sem imagem (data NULL),
// a posição em cursor_known/cursor_px/cursor_py, nas coordenadas de um
// quadro width x height da fonte inteira (sem recorte).
int cap_next(cap_ctx *ctx, cap_frame *out, int timeout_ms, char *err, int errlen);

// Cursor fora do vídeo: a captura não pinta o cursor no quadro, só diz onde
// ele está (quem assiste desenha a seta; mexer o mouse com a tela parada não
// gera quadro). 1 = dá (vale a partir do próximo quadro; o último quadro é
// reentregue limpo); 0 = esse método de captura não sabe (o cursor continua
// pintado pelo sistema: GNOME/KDE com o cursor embutido, por exemplo).
int cap_set_cursor_apart(cap_ctx *ctx, int on);

// Nome do método de captura em uso ("PipeWire", "X11", "DXGI", "GDI").
const char *cap_backend(cap_ctx *ctx);

void cap_close(cap_ctx *ctx);

// ---- Caminho pela placa (Linux + NVIDIA; ver cudagl.c). O quadro capturado
// (DMA-BUF do compositor) é recortado, escalado e ganha o cursor na própria
// placa, e vai pro NVENC sem passar pela CPU.
// `rect`: dado o tamanho da fonte, o recorte (fração) e a altura máxima,
// diz o retângulo da fonte (x, y, w, h) e o tamanho de saída (ow, oh).
// `cursor`: imagem RGBA da seta do cursor (desenhada por nós no Hyprland).
typedef void (*cap_rect_fn)(int fw, int fh, const float crop[4], int max_h, int *x, int *y, int *w, int *h, int *ow, int *oh);
typedef const uint8_t *(*cap_cursor_fn)(int *w, int *h);
// 1 = ligou (a partir do próximo quadro, cap_frame.gpu). `cg` tem que viver
// mais que a captura.
int cap_gpu_enable(cap_ctx *ctx, void *cg, cap_rect_fn rect, cap_cursor_fn cursor);
void cap_gpu_disable(cap_ctx *ctx);
// Recorte (fração 0..1 da fonte) e altura máxima (0 = sem limite).
void cap_gpu_set_output(cap_ctx *ctx, const float crop[4], int max_height);
// Prévia: 0 = não quer; 1 = do quadro de saída; 2 = da fonte inteira (escolhendo o recorte).
void cap_gpu_set_preview(cap_ctx *ctx, int want, int max_w);
void cap_gpu_release(cap_ctx *ctx, void *gpu);
// Linux Intel/AMD: o mesmo caminho, mas por um conversor VA-API (vapp,
// hwva.h; quem chama passa as funções dele): o quadro sai como superfície
// NV12 (gpu_dev = o id dela), pro encoder VA-API. Só com o cursor fora do
// vídeo (ou sem o cursor desenhado por nós). 1 = ligou.
typedef struct cap_dmabuf {
    int width, height;
    int planes;
    int fd[4];
    int offset[4], pitch[4];
    uint64_t modifier;
    uint32_t drm_fourcc; // ex.: XR24
} cap_dmabuf;
typedef struct cap_va_ops {
    void *ctx;
    int (*convert)(void *ctx, const void *key, const cap_dmabuf *src, int x, int y, int w, int h, int ow, int oh, int slot);
    uint32_t (*surface)(void *ctx, int slot);
    int (*preview)(void *ctx, const void *key, const cap_dmabuf *src, int x, int y, int w, int h, int pw, int ph, uint8_t *rgba);
    void (*forget)(void *ctx, const void *key);
} cap_va_ops;
int cap_gpu_enable_va(cap_ctx *ctx, const cap_va_ops *ops, cap_rect_fn rect);
// Windows Intel/AMD: o mesmo pelo processador de vídeo do D3D11 (d3dvp_win.c):
// o quadro sai como textura NV12 (gpu_dev = ID3D11Texture2D *) pro encoder do
// Media Foundation, que precisa do mesmo dispositivo (cap_d3d_device). 1 = ligou.
int cap_gpu_enable_d3d(cap_ctx *ctx, cap_rect_fn rect, char *err, int errlen);
void *cap_d3d_device(cap_ctx *ctx);
// A placa falhou no meio (os quadros voltaram a vir pela CPU)?
int cap_gpu_failed(cap_ctx *ctx);
// Chamar logo depois de criar um encoder novo: solta buffers de tamanho
// antigo que o encoder anterior ainda podia ter registrado.
void cap_gpu_gc(cap_ctx *ctx);

#ifdef __cplusplus
}
#endif
