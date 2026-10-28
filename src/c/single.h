// Uma janela só pros convites (ver single.c).
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Entrega o convite pra janela do telinha que já está aberta (com essas
// configurações). 1 = entregue (este processo pode fechar).
int single_handoff(const char *name, const char *invite);
// Esta janela passa a receber convites (thread própria; cb roda nela).
// 1 = ouvindo, 0 = outra janela já é a principal, -1 = erro.
int single_listen(const char *name, void (*cb)(const char *invite));

#ifdef __cplusplus
}
#endif
