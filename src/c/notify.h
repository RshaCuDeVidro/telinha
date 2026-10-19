// Notificação do sistema (o telinha em segundo plano).
//   Linux:   org.freedesktop.Notifications pelo D-Bus (GDBus), sem bloquear
//   Windows: balão da bandeja (o Windows 10/11 mostra como notificação) e a
//            janela piscando na barra de tarefas
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// `window`: HWND da janela principal no Windows (pra piscar), NULL no Linux.
void notify_send(const char *title, const char *body, void *window);

#ifdef __cplusplus
}
#endif
