// Itens do Dear ImGui registrados no último quadro (modo de testes, ver qa_hooks.cpp).
#ifndef TELINHA_QA_HOOKS_H
#define TELINHA_QA_HOOKS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct qa_item {
    unsigned id;
    float x0, y0, x1, y1;     /* retângulo do item */
    float cx0, cy0, cx1, cy1; /* área visível da janela dele */
    unsigned status;          /* ImGuiItemStatusFlags (1<<23 = marcado) */
    char window[64];
    char label[96];
} qa_item;

void qa_enable(int on);
void qa_end_frame(void);
int qa_count(void);
const qa_item* qa_items(void);

#ifdef __cplusplus
}
#endif

#endif
