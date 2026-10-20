// Apertar pra falar: tecla apertada em qualquer programa (ver ptt.c).
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// 1 se a tecla (ou o botão do mouse, 2 = meio, 3/4 = laterais) está apertada.
// Windows: `key` é o scancode do GLFW; Linux: o keycode do X11.
int ptt_global_down(int key, int mouse_button);
// 0 = não dá pra ler o teclado de fora (sem servidor X no Linux).
int ptt_global_supported(void);
// Esse botão do mouse dá pra ler de fora? (Linux/X11: só o do meio)
int ptt_global_button_supported(int mouse_button);
// Modificadores apertados agora (lidos de fora): 1 = Ctrl, 2 = Shift, 4 = Alt.
int ptt_global_mods(void);

#ifdef __cplusplus
}
#endif
