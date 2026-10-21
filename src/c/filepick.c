// Ver filepick.h.
#include "filepick.h"
#include <stdatomic.h>
#include <string.h>

// 0 parado, 1 escolhendo, 2 escolheu, 3 desistiu
static atomic_int g_state = 0;
static char g_path[4096];
static char g_title[256];

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>

static DWORD WINAPI pick_thread(LPVOID arg) {
    (void)arg;
    wchar_t file[2048] = {0};
    wchar_t title[256];
    MultiByteToWideChar(CP_UTF8, 0, g_title, -1, title, 256);
    OPENFILENAMEW ofn;
    memset(&ofn, 0, sizeof(ofn));
    ofn.lStructSize = sizeof(ofn);
    ofn.lpstrFilter = L"Imagens\0*.png;*.jpg;*.jpeg;*.gif;*.bmp\0Todos os arquivos\0*.*\0";
    ofn.lpstrFile = file;
    ofn.nMaxFile = 2048;
    ofn.lpstrTitle = title;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (GetOpenFileNameW(&ofn) && WideCharToMultiByte(CP_UTF8, 0, file, -1, g_path, sizeof(g_path), NULL, NULL) > 0) {
        atomic_store(&g_state, 2);
    } else {
        atomic_store(&g_state, 3);
    }
    return 0;
}

int filepick_start(const char *title) {
    int expect = 0;
    if (!atomic_compare_exchange_strong(&g_state, &expect, 1)) return expect == 1 ? 0 : -1;
    strncpy(g_title, title ? title : "", sizeof(g_title) - 1);
    HANDLE h = CreateThread(NULL, 0, pick_thread, NULL, 0, NULL);
    if (!h) {
        atomic_store(&g_state, 0);
        return -1;
    }
    CloseHandle(h);
    return 0;
}

#else
#include <libportal/portal.h>
#include <pthread.h>

struct pick {
    int done;
    GVariant *res;
};

static void on_opened(GObject *src, GAsyncResult *res, gpointer data) {
    struct pick *p = data;
    GError *err = NULL;
    p->res = xdp_portal_open_file_finish(XDP_PORTAL(src), res, &err);
    if (err) g_error_free(err);
    p->done = 1;
}

static void *pick_thread(void *arg) {
    (void)arg;
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);
    GError *err = NULL;
    XdpPortal *portal = xdp_portal_initable_new(&err);
    int ok = 0;
    if (portal) {
        // filtro: imagens
        GVariantBuilder filters, one, pats;
        g_variant_builder_init(&pats, G_VARIANT_TYPE("a(us)"));
        g_variant_builder_add(&pats, "(us)", 1, "image/png");
        g_variant_builder_add(&pats, "(us)", 1, "image/jpeg");
        g_variant_builder_add(&pats, "(us)", 1, "image/gif");
        g_variant_builder_add(&pats, "(us)", 1, "image/bmp");
        g_variant_builder_init(&one, G_VARIANT_TYPE("(sa(us))"));
        g_variant_builder_add(&one, "s", "Imagens");
        g_variant_builder_add_value(&one, g_variant_builder_end(&pats));
        g_variant_builder_init(&filters, G_VARIANT_TYPE("a(sa(us))"));
        g_variant_builder_add_value(&filters, g_variant_builder_end(&one));
        struct pick p = {0, NULL};
        xdp_portal_open_file(portal, NULL, g_title, g_variant_builder_end(&filters), NULL, NULL, XDP_OPEN_FILE_FLAG_NONE, NULL, on_opened, &p);
        while (!p.done) g_main_context_iteration(ctx, TRUE);
        if (p.res) {
            const char **uris = NULL;
            if (g_variant_lookup(p.res, "uris", "^a&s", &uris) && uris && uris[0]) {
                char *path = g_filename_from_uri(uris[0], NULL, NULL);
                if (path) {
                    strncpy(g_path, path, sizeof(g_path) - 1);
                    g_path[sizeof(g_path) - 1] = 0;
                    g_free(path);
                    ok = 1;
                }
            }
            g_free(uris);
            g_variant_unref(p.res);
        }
        g_object_unref(portal);
    } else if (err) {
        g_error_free(err);
    }
    g_main_context_pop_thread_default(ctx);
    g_main_context_unref(ctx);
    atomic_store(&g_state, ok ? 2 : 3);
    return NULL;
}

int filepick_start(const char *title) {
    int expect = 0;
    if (!atomic_compare_exchange_strong(&g_state, &expect, 1)) return expect == 1 ? 0 : -1;
    strncpy(g_title, title ? title : "", sizeof(g_title) - 1);
    pthread_t t;
    if (pthread_create(&t, NULL, pick_thread, NULL) != 0) {
        atomic_store(&g_state, 0);
        return -1;
    }
    pthread_detach(t);
    return 0;
}
#endif

int filepick_poll(char *out, int cap) {
    const int st = atomic_load(&g_state);
    if (st == 1) return 0;
    if (st == 2) {
        strncpy(out, g_path, (size_t)cap - 1);
        out[cap - 1] = 0;
        atomic_store(&g_state, 0);
        return 1;
    }
    if (st == 3) {
        atomic_store(&g_state, 0);
        return -1;
    }
    return -1;
}
