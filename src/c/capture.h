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
} cap_frame;

typedef struct cap_ctx cap_ctx;

// Lista as fontes disponíveis (monitores). Retorna quantas escreveu.
int cap_list_sources(cap_source *out, int max);

// Abre a captura. Pode bloquear (no Wayland o portal abre um seletor de tela).
// fps = ritmo máximo desejado (o compositor não precisa copiar mais que isso).
// Retorna NULL e escreve o motivo em err em caso de falha.
cap_ctx *cap_open(int source_id, int show_cursor, int fps, char *err, int errlen);

// Espera um frame novo por até timeout_ms.
// 1 = frame novo em *out, 0 = nada mudou, -1 = erro fatal (err preenchido).
int cap_next(cap_ctx *ctx, cap_frame *out, int timeout_ms, char *err, int errlen);

// Nome do método de captura em uso ("PipeWire", "X11", "DXGI", "GDI").
const char *cap_backend(cap_ctx *ctx);

void cap_close(cap_ctx *ctx);

#ifdef __cplusplus
}
#endif
