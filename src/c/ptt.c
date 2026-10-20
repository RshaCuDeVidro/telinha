// Apertar pra falar: a tecla vale mesmo com outro programa em foco (o jogo).
//   Windows: GetAsyncKeyState (teclado e botões laterais do mouse).
//   Linux X11: XQueryKeymap numa conexão própria com o servidor X (uma só,
//   com trava: a thread do microfone e a do atalho de clipe usam). Wayland
//   nativo: o compositor não deixa ler o teclado de fora; aí só vale com o
//   telinha em foco (ver ptt.zig).
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

int ptt_global_button_supported(int mouse_button) {
    (void)mouse_button;
    return 1;
}

int ptt_global_mods(void) {
    int m = 0;
    if (GetAsyncKeyState(VK_CONTROL) & 0x8000) m |= 1;
    if (GetAsyncKeyState(VK_SHIFT) & 0x8000) m |= 2;
    if (GetAsyncKeyState(VK_MENU) & 0x8000) m |= 4;
    return m;
}
#else
#include <X11/Xlib.h>
#include <pthread.h>
#include <stdlib.h>

// Uma conexão só com o servidor X, usada por mais de uma thread (microfone,
// atalho de clipe): a trava garante uma de cada vez (o Xlib não aguenta duas
// juntas sem XInitThreads), e a conexão não se multiplica a cada thread nova.
static Display *dpy;
static int tried;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

int ptt_global_down(int x11_keycode, int mouse_button) {
    // botão do meio: na máscara do ponteiro; os laterais (8/9) o X não conta
    if (mouse_button >= 0 && mouse_button != 2) return 0;
    if (mouse_button < 0 && (x11_keycode < 8 || x11_keycode > 255)) return 0;
    pthread_mutex_lock(&lock);
    if (!tried) {
        tried = 1;
        if (getenv("DISPLAY")) dpy = XOpenDisplay(NULL);
    }
    int down = 0;
    if (dpy && mouse_button == 2) {
        Window root, child;
        int rx, ry, wx, wy;
        unsigned int mask = 0;
        if (XQueryPointer(dpy, DefaultRootWindow(dpy), &root, &child, &rx, &ry, &wx, &wy, &mask)) down = (mask & Button2Mask) != 0;
    } else if (dpy) {
        char keys[32];
        XQueryKeymap(dpy, keys);
        down = (keys[x11_keycode / 8] & (1 << (x11_keycode % 8))) != 0;
    }
    pthread_mutex_unlock(&lock);
    return down;
}

int ptt_global_button_supported(int mouse_button) {
    return mouse_button == 2;
}

int ptt_global_supported(void) {
    return getenv("DISPLAY") != NULL;
}

#include <X11/keysym.h>

int ptt_global_mods(void) {
    // keycodes dos modificadores (uma vez; dependem do mapa de teclado)
    static KeyCode kc[6];
    static int have;
    pthread_mutex_lock(&lock);
    if (!tried) {
        tried = 1;
        if (getenv("DISPLAY")) dpy = XOpenDisplay(NULL);
    }
    int m = 0;
    if (dpy) {
        if (!have) {
            const KeySym syms[6] = {XK_Control_L, XK_Control_R, XK_Shift_L, XK_Shift_R, XK_Alt_L, XK_Alt_R};
            for (int i = 0; i < 6; i++) kc[i] = XKeysymToKeycode(dpy, syms[i]);
            have = 1;
        }
        char keys[32];
        XQueryKeymap(dpy, keys);
        for (int i = 0; i < 6; i++) {
            if (!kc[i]) continue;
            if (keys[kc[i] / 8] & (1 << (kc[i] % 8))) m |= 1 << (i / 2);
        }
    }
    pthread_mutex_unlock(&lock);
    return m;
}
#endif
