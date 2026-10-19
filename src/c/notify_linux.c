// Notificação no Linux: Notify do org.freedesktop.Notifications pelo GDBus.
// A chamada vai sem esperar resposta (o app não roda o loop do GLib): a
// interface não trava nem se o serviço de notificação não existir.
#include "notify.h"

#include <gio/gio.h>

static GDBusConnection *bus;
static int tried;

void notify_send(const char *title, const char *body, void *window) {
    (void)window;
    if (!tried) {
        tried = 1;
        bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    }
    if (!bus) return;
    GVariantBuilder actions, hints;
    g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
    g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&hints, "{sv}", "desktop-entry", g_variant_new_string("telinha"));
    g_variant_builder_add(&hints, "{sv}", "category", g_variant_new_string("im.received"));
    g_dbus_connection_call(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                           "org.freedesktop.Notifications", "Notify",
                           g_variant_new("(susssasa{sv}i)", "telinha", 0u, "video-display", title, body, &actions, &hints, 6000),
                           NULL, G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL, NULL);
}
