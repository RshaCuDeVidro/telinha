// Apertar pra falar: a tecla vale mesmo com outro programa em foco (o jogo).
//   Windows: GetAsyncKeyState (teclado e botões laterais do mouse).
//   Linux X11: XQueryKeymap numa conexão própria com o servidor X (uma por
//   thread: a do microfone e a do atalho de clipe). Wayland nativo: o compositor não deixa ler
//   o teclado de fora; aí só vale com o telinha em foco (ver ptt.zig).
#include "ptt.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

int ptt_global_down(int scancode, int mouse_button) {
    if (mouse_button == 3) return (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) != 0;
    if (mouse_button == 4) return (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) != 0;
    if (mouse_button == 2) return (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0;
    if (scancode <= 0) return 0;
    // scancode do GLFW no Windows: o do teclado, com 0x100 nas teclas estendidas
    const UINT sc = (UINT)(scancode & 0xFF) | ((scancode & 0x100) ? 0xE000 : 0);
    const UINT vk = MapVirtualKeyW(sc, MAPVK_VSC_TO_VK_EX);
    if (!vk) return 0;
    return (GetAsyncKeyState((int)vk) & 0x8000) != 0;
}

int ptt_global_supported(void) {
    return 1;
}
#else
#include <X11/Xlib.h>
#include <stdlib.h>

// uma conexão por thread (o Xlib não pode ser usado de duas threads na mesma)
static _Thread_local Display *dpy;
static _Thread_local int tried;

int ptt_global_down(int x11_keycode, int mouse_button) {
    (void)mouse_button; // botões laterais (8/9) não aparecem na máscara do X
    if (!tried) {
        tried = 1;
        if (getenv("DISPLAY")) dpy = XOpenDisplay(NULL);
    }
    if (!dpy || x11_keycode < 8 || x11_keycode > 255) return 0;
    char keys[32];
    XQueryKeymap(dpy, keys);
    return (keys[x11_keycode / 8] & (1 << (x11_keycode % 8))) != 0;
}

int ptt_global_supported(void) {
    return getenv("DISPLAY") != NULL;
}
#endif
