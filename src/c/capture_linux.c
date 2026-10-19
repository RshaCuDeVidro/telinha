// Captura no Linux.
//   Wayland: xdg-desktop-portal (ScreenCast) + PipeWire. Funciona em qualquer
//            compositor com portal (Hyprland, GNOME, KDE, Sway...).
//   X11:     XShm + XFixes (cursor).
#define _GNU_SOURCE
#include "capture.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <libportal/portal.h>
#include <pipewire/pipewire.h>
#include <spa/debug/types.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xfixes.h>

enum { KIND_PIPEWIRE = 1, KIND_X11 = 2 };
// Pixels que o compositor entrega: 32 bits (copia direto), 24 bits (BGR/RGB,
// ganha o byte X), 10 bits por canal (monitor HDR/10 bits, vira 8 bits) ou
// DMA-BUF (buffer da GPU, lido com EGL).
enum { SRC_32 = 0, SRC_24 = 1, SRC_30 = 2, SRC_DMABUF = 3 };

struct egl_state; // DMA-BUF (mais abaixo)

struct cap_ctx {
    int kind;
    int show_cursor;
    int fps;

    // Cursor desenhado por nós (Hyprland): pedir o cursor embutido faz o
    // compositor trocar pro cursor em software enquanto captura, e o mouse
    // fica "preso" à renderização. Então capturamos sem cursor e pegamos a
    // posição pelo IPC do Hyprland.
    int soft_cursor;
    int stream_x, stream_y, stream_w, stream_h; // área capturada (coordenadas lógicas)
    int cursor_gx, cursor_gy; // última posição global enviada
    int have_front;

    // ---- PipeWire
    XdpPortal *portal;
    XdpSession *session;
    GMainContext *gctx;
    struct pw_thread_loop *loop;
    struct pw_context *pw_ctx;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_video_info_raw info;
    int pw_format; // CAP_BGRX / CAP_RGBX (formato depois da conversão)
    int src_kind;  // SRC_32 / SRC_24 / SRC_30 / SRC_DMABUF: como o compositor entrega os pixels
    struct egl_state *egl; // NULL = sem DMA-BUF
    uint64_t read_us, read_n, read_report; // TELINHA_DEBUG: custo da leitura do DMA-BUF
    int dmabuf_off;        // a importação falhou: renegociou pra memória compartilhada
    uint8_t *staging;      // leitura do DMA-BUF (fora do lock)
    size_t staging_cap;

    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint8_t *pending; // último frame recebido (escrito pela thread do PipeWire)
    size_t pending_cap;
    int pending_w, pending_h, pending_fmt;
    int fresh;
    int failed;
    char fail_msg[160];
    uint8_t *front; // frame entregue pro chamador
    size_t front_cap;

    // ---- X11
    Display *dpy;
    Window root;
    XImage *img;
    XShmSegmentInfo shm;
    int xw, xh;
    int has_xfixes;
    uint8_t *xbuf;
};

static void set_err(char *err, int errlen, const char *fmt, const char *arg) {
    if (err && errlen > 0) snprintf(err, errlen, fmt, arg ? arg : "");
}

static int is_wayland(void) {
    const char *wd = getenv("WAYLAND_DISPLAY");
    const char *st = getenv("XDG_SESSION_TYPE");
    return (wd && *wd) || (st && strcmp(st, "wayland") == 0);
}

int cap_list_sources(cap_source *out, int max) {
    if (max < 1) return 0;
    out[0].id = 0;
    if (is_wayland())
        snprintf(out[0].name, sizeof out[0].name, "Escolher tela ou janela (seletor do sistema)");
    else
        snprintf(out[0].name, sizeof out[0].name, "Tela inteira (X11)");
    return 1;
}

// ===========================================================================
// DMA-BUF: o compositor copia a tela pra um buffer da GPU — sem travar o
// próprio loop de renderização lendo a imagem de volta pra RAM, que é o que a
// memória compartilhada obriga ele a fazer a cada quadro — e nós importamos
// com EGL e lemos aqui, na nossa thread. libEGL é carregada em tempo de
// execução: sem ela (ou sem suporte), fica só a memória compartilhada.

typedef void *EGLDisplay, *EGLContext, *EGLImageKHR, *EGLDeviceEXT, *EGLConfig, *EGLSurface;
typedef int EGLint;
typedef unsigned int EGLBoolean, EGLenum;
typedef unsigned int GLuint, GLenum;
typedef int GLint, GLsizei;

#define EGL_NONE 0x3038
#define EGL_EXTENSIONS 0x3055
#define EGL_HEIGHT 0x3056
#define EGL_WIDTH 0x3057
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_IMAGE_PRESERVED_KHR 0x30D2
#define EGL_PLATFORM_DEVICE_EXT 0x313F
#define EGL_DRM_DEVICE_FILE_EXT 0x3233
#define EGL_LINUX_DMA_BUF_EXT 0x3270
#define EGL_LINUX_DRM_FOURCC_EXT 0x3271
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3377

#define GL_TEXTURE_2D 0x0DE1
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_UNSIGNED_BYTE 0x1401
#define GL_RGBA 0x1908
#define GL_EXTENSIONS 0x1F03
#define GL_NEAREST 0x2600
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_BGRA_EXT 0x80E1
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER 0x8D40

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define MOD_INVALID 0x00ffffffffffffffULL

// planos 0-3: fd, offset, pitch, modifier lo, modifier hi
static const EGLint plane_attr[4][5] = {
    {0x3272, 0x3273, 0x3274, 0x3443, 0x3444},
    {0x3275, 0x3276, 0x3277, 0x3445, 0x3446},
    {0x3278, 0x3279, 0x327A, 0x3447, 0x3448},
    {0x3440, 0x3441, 0x3442, 0x3449, 0x344A},
};

// formatos que dá pra importar: SPA ↔ DRM
static const struct { uint32_t spa, drm; } dma_formats[] = {
    {SPA_VIDEO_FORMAT_BGRx, FOURCC('X', 'R', '2', '4')},
    {SPA_VIDEO_FORMAT_BGRA, FOURCC('A', 'R', '2', '4')},
    {SPA_VIDEO_FORMAT_RGBx, FOURCC('X', 'B', '2', '4')},
    {SPA_VIDEO_FORMAT_RGBA, FOURCC('A', 'B', '2', '4')},
};
#define N_DMA_FORMATS 4
#define MAX_MODS 64
#define MAX_IMAGES 16

struct egl_state {
    void *lib;
    EGLDisplay dpy;
    EGLContext ctx;
    int current; // contexto já ativado na thread do PipeWire
    int read_bgra;
    GLuint fbo;
    uint64_t mods[N_DMA_FORMATS][MAX_MODS];
    int n_mods[N_DMA_FORMATS];
    struct { struct spa_buffer *buf; EGLImageKHR img; GLuint tex; } images[MAX_IMAGES];

    void *(*GetProcAddress)(const char *);
    EGLBoolean (*QueryDevicesEXT)(EGLint, EGLDeviceEXT *, EGLint *);
    const char *(*QueryDeviceStringEXT)(EGLDeviceEXT, EGLint);
    EGLDisplay (*GetPlatformDisplayEXT)(EGLenum, void *, const EGLint *);
    EGLBoolean (*Initialize)(EGLDisplay, EGLint *, EGLint *);
    EGLBoolean (*Terminate)(EGLDisplay);
    const char *(*QueryString)(EGLDisplay, EGLint);
    EGLBoolean (*BindAPI)(EGLenum);
    EGLContext (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
    EGLBoolean (*DestroyContext)(EGLDisplay, EGLContext);
    EGLBoolean (*MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
    EGLImageKHR (*CreateImageKHR)(EGLDisplay, EGLContext, EGLenum, void *, const EGLint *);
    EGLBoolean (*DestroyImageKHR)(EGLDisplay, EGLImageKHR);
    EGLBoolean (*QueryDmaBufModifiersEXT)(EGLDisplay, EGLint, EGLint, uint64_t *, EGLBoolean *, EGLint *);

    void (*GenTextures)(GLsizei, GLuint *);
    void (*DeleteTextures)(GLsizei, const GLuint *);
    void (*BindTexture)(GLenum, GLuint);
    void (*TexParameteri)(GLenum, GLenum, GLint);
    void (*GenFramebuffers)(GLsizei, GLuint *);
    void (*DeleteFramebuffers)(GLsizei, const GLuint *);
    void (*BindFramebuffer)(GLenum, GLuint);
    void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
    GLenum (*CheckFramebufferStatus)(GLenum);
    void (*ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
    void (*PixelStorei)(GLenum, GLint);
    const unsigned char *(*GetString)(GLenum);
    void (*EGLImageTargetTexture2DOES)(GLenum, void *);
};

static int has_ext(const char *list, const char *name) {
    if (!list) return 0;
    size_t n = strlen(name);
    for (const char *p = list; (p = strstr(p, name)) != NULL; p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) return 1;
    return 0;
}

// Chamado sem o contexto ativo em nenhuma thread (ver egl_release).
// A libEGL fica carregada: alguns drivers não gostam de ser descarregados.
static void egl_destroy(struct egl_state *e) {
    if (!e) return;
    if (e->dpy) {
        if (e->ctx) e->DestroyContext(e->dpy, e->ctx);
        e->Terminate(e->dpy);
    }
    free(e);
}

// Abre o EGL num dispositivo com render node e descobre quais DMA-BUFs dá pra
// importar. NULL = sem suporte (fica só a memória compartilhada).
static struct egl_state *egl_create(void) {
    if (getenv("TELINHA_SEM_DMABUF")) return NULL;
    struct egl_state *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->lib = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!e->lib) goto fail;
    e->GetProcAddress = (void *(*)(const char *))dlsym(e->lib, "eglGetProcAddress");
    if (!e->GetProcAddress) goto fail;
#define LOAD(field, name) if (!(*(void **)&e->field = e->GetProcAddress(name))) goto fail
    LOAD(QueryDevicesEXT, "eglQueryDevicesEXT");
    LOAD(QueryDeviceStringEXT, "eglQueryDeviceStringEXT");
    LOAD(GetPlatformDisplayEXT, "eglGetPlatformDisplayEXT");
    LOAD(Initialize, "eglInitialize");
    LOAD(Terminate, "eglTerminate");
    LOAD(QueryString, "eglQueryString");
    LOAD(BindAPI, "eglBindAPI");
    LOAD(CreateContext, "eglCreateContext");
    LOAD(DestroyContext, "eglDestroyContext");
    LOAD(MakeCurrent, "eglMakeCurrent");
    LOAD(CreateImageKHR, "eglCreateImageKHR");
    LOAD(DestroyImageKHR, "eglDestroyImageKHR");
    LOAD(QueryDmaBufModifiersEXT, "eglQueryDmaBufModifiersEXT");

    // primeiro dispositivo de verdade (com render node; pula renderização por software)
    EGLDeviceEXT devs[8];
    EGLint ndev = 0;
    if (!e->QueryDevicesEXT(8, devs, &ndev)) goto fail;
    for (EGLint i = 0; i < ndev && !e->dpy; i++) {
        const char *node = e->QueryDeviceStringEXT(devs[i], EGL_DRM_RENDER_NODE_FILE_EXT);
        if (!node) node = e->QueryDeviceStringEXT(devs[i], EGL_DRM_DEVICE_FILE_EXT);
        if (!node) continue;
        EGLDisplay d = e->GetPlatformDisplayEXT(EGL_PLATFORM_DEVICE_EXT, devs[i], NULL);
        if (!d || !e->Initialize(d, NULL, NULL)) continue;
        const char *ext = e->QueryString(d, EGL_EXTENSIONS);
        if (has_ext(ext, "EGL_EXT_image_dma_buf_import_modifiers") && has_ext(ext, "EGL_KHR_surfaceless_context") &&
            has_ext(ext, "EGL_KHR_no_config_context"))
            e->dpy = d;
        else
            e->Terminate(d);
    }
    if (!e->dpy) goto fail;
    if (!e->BindAPI(EGL_OPENGL_ES_API)) goto fail;
    static const EGLint ctx_attr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    e->ctx = e->CreateContext(e->dpy, NULL, NULL, ctx_attr);
    if (!e->ctx) goto fail;

    LOAD(GenTextures, "glGenTextures");
    LOAD(DeleteTextures, "glDeleteTextures");
    LOAD(BindTexture, "glBindTexture");
    LOAD(TexParameteri, "glTexParameteri");
    LOAD(GenFramebuffers, "glGenFramebuffers");
    LOAD(DeleteFramebuffers, "glDeleteFramebuffers");
    LOAD(BindFramebuffer, "glBindFramebuffer");
    LOAD(FramebufferTexture2D, "glFramebufferTexture2D");
    LOAD(CheckFramebufferStatus, "glCheckFramebufferStatus");
    LOAD(ReadPixels, "glReadPixels");
    LOAD(PixelStorei, "glPixelStorei");
    LOAD(GetString, "glGetString");
    LOAD(EGLImageTargetTexture2DOES, "glEGLImageTargetTexture2DOES");
#undef LOAD

    // modificadores (layout na GPU) que dá pra ler de volta; "external only"
    // não serve (só dá pra amostrar num shader, não ler de um framebuffer)
    int total = 0;
    for (int f = 0; f < N_DMA_FORMATS; f++) {
        uint64_t mods[MAX_MODS];
        EGLBoolean ext_only[MAX_MODS];
        EGLint n = 0;
        if (!e->QueryDmaBufModifiersEXT(e->dpy, (EGLint)dma_formats[f].drm, MAX_MODS - 1, mods, ext_only, &n)) n = 0;
        for (EGLint i = 0; i < n; i++)
            if (!ext_only[i]) e->mods[f][e->n_mods[f]++] = mods[i];
        // sem lista: o driver escolhe o layout (modificador implícito)
        e->mods[f][e->n_mods[f]++] = MOD_INVALID;
        total += e->n_mods[f];
    }
    if (total == 0) goto fail;
    return e;
fail:
    egl_destroy(e);
    return NULL;
}

// Ativa o contexto na thread do PipeWire (na primeira vez).
static int egl_make_current(struct egl_state *e) {
    if (e->current) return 0;
    if (!e->MakeCurrent(e->dpy, NULL, NULL, e->ctx)) return -1;
    e->GenFramebuffers(1, &e->fbo);
    const char *ext = (const char *)e->GetString(GL_EXTENSIONS);
    e->read_bgra = has_ext(ext, "GL_EXT_read_format_bgra");
    e->current = 1;
    return 0;
}

static void egl_forget(struct egl_state *e, struct spa_buffer *buf);

// Na thread do PipeWire: solta texturas/imagens e desativa o contexto.
static int egl_release(struct spa_loop *loop, bool async, uint32_t seq, const void *data, size_t size, void *user) {
    (void)loop; (void)async; (void)seq; (void)data; (void)size;
    struct egl_state *e = user;
    egl_forget(e, NULL);
    if (e->current) {
        e->DeleteFramebuffers(1, &e->fbo);
        e->MakeCurrent(e->dpy, NULL, NULL, NULL);
        e->current = 0;
    }
    return 0;
}

static void egl_forget(struct egl_state *e, struct spa_buffer *buf) {
    for (int i = 0; i < MAX_IMAGES; i++) {
        if (!e->images[i].buf || (buf && e->images[i].buf != buf)) continue;
        if (e->current) e->DeleteTextures(1, &e->images[i].tex);
        e->DestroyImageKHR(e->dpy, e->images[i].img);
        e->images[i].buf = NULL;
    }
}

// Importa (uma vez por buffer) e lê o DMA-BUF pra `dst` (w*h*4).
// Retorna o formato lido (CAP_BGRX/CAP_RGBX) ou -1.
static int egl_read(struct egl_state *e, struct spa_buffer *buf, uint32_t drm_format, uint64_t modifier,
                    int w, int h, uint8_t *dst) {
    if (getenv("TELINHA_TESTE_DMABUF_FALHA")) return -1; // testa a volta pra memória compartilhada
    if (egl_make_current(e) < 0) return -1;
    int slot = -1, free_slot = -1;
    for (int i = 0; i < MAX_IMAGES; i++) {
        if (e->images[i].buf == buf) slot = i;
        else if (!e->images[i].buf && free_slot < 0) free_slot = i;
    }
    if (slot < 0) {
        if (free_slot < 0) {
            egl_forget(e, NULL);
            free_slot = 0;
        }
        EGLint attr[6 + 4 * 10 + 1];
        int n = 0;
        attr[n++] = EGL_WIDTH;
        attr[n++] = w;
        attr[n++] = EGL_HEIGHT;
        attr[n++] = h;
        attr[n++] = EGL_LINUX_DRM_FOURCC_EXT;
        attr[n++] = (EGLint)drm_format;
        uint32_t planes = buf->n_datas < 4 ? buf->n_datas : 4;
        for (uint32_t p = 0; p < planes; p++) {
            struct spa_data *d = &buf->datas[p];
            if (d->type != SPA_DATA_DmaBuf || !d->chunk) return -1;
            attr[n++] = plane_attr[p][0];
            attr[n++] = (EGLint)d->fd;
            attr[n++] = plane_attr[p][1];
            attr[n++] = (EGLint)d->chunk->offset;
            attr[n++] = plane_attr[p][2];
            attr[n++] = (EGLint)d->chunk->stride;
            if (modifier != MOD_INVALID) {
                attr[n++] = plane_attr[p][3];
                attr[n++] = (EGLint)(modifier & 0xffffffff);
                attr[n++] = plane_attr[p][4];
                attr[n++] = (EGLint)(modifier >> 32);
            }
        }
        attr[n++] = EGL_NONE;
        EGLImageKHR img = e->CreateImageKHR(e->dpy, NULL, EGL_LINUX_DMA_BUF_EXT, NULL, attr);
        if (!img) return -1;
        GLuint tex = 0;
        e->GenTextures(1, &tex);
        e->BindTexture(GL_TEXTURE_2D, tex);
        e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        e->EGLImageTargetTexture2DOES(GL_TEXTURE_2D, img);
        e->images[free_slot].buf = buf;
        e->images[free_slot].img = img;
        e->images[free_slot].tex = tex;
        slot = free_slot;
    }
    e->BindFramebuffer(GL_FRAMEBUFFER, e->fbo);
    e->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, e->images[slot].tex, 0);
    if (e->CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return -1;
    e->PixelStorei(GL_PACK_ALIGNMENT, 4);
    // o GL lê a imagem já "destrançada" (o layout da GPU vira linhas comuns)
    e->ReadPixels(0, 0, w, h, e->read_bgra ? GL_BGRA_EXT : GL_RGBA, GL_UNSIGNED_BYTE, dst);
    return e->read_bgra ? CAP_BGRX : CAP_RGBX;
}

// ===========================================================================
// PipeWire

// Formatos que aceitamos: DMA-BUF primeiro (com os modificadores que o EGL
// importa), depois memória compartilhada (32 bits, e 24/10 bits convertidos).
// O ritmo máximo vai em `maxFramerate`, que é o que o portal usa pra decidir
// quantas vezes por segundo copiar a tela.
static int build_formats(struct cap_ctx *c, struct spa_pod_builder *b, const struct spa_pod **params, int max) {
    int n = 0;
    for (int f = 0; c->egl && !c->dmabuf_off && f < N_DMA_FORMATS && n < max - 1; f++) {
        struct spa_pod_frame fr[2];
        spa_pod_builder_push_object(b, &fr[0], SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
        spa_pod_builder_add(b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), 0);
        spa_pod_builder_add(b, SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), 0);
        spa_pod_builder_add(b, SPA_FORMAT_VIDEO_format, SPA_POD_Id(dma_formats[f].spa), 0);
        spa_pod_builder_prop(b, SPA_FORMAT_VIDEO_modifier, SPA_POD_PROP_FLAG_MANDATORY | SPA_POD_PROP_FLAG_DONT_FIXATE);
        spa_pod_builder_push_choice(b, &fr[1], SPA_CHOICE_Enum, 0);
        spa_pod_builder_long(b, (int64_t)c->egl->mods[f][0]); // padrão
        for (int i = 0; i < c->egl->n_mods[f]; i++) spa_pod_builder_long(b, (int64_t)c->egl->mods[f][i]);
        spa_pod_builder_pop(b, &fr[1]);
        spa_pod_builder_add(b,
            SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)),
            SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(c->fps, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(c->fps, 1)),
            SPA_FORMAT_VIDEO_maxFramerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(c->fps, 1), &SPA_FRACTION(1, 1), &SPA_FRACTION(c->fps, 1)),
            0);
        params[n++] = spa_pod_builder_pop(b, &fr[0]);
    }
    params[n++] = spa_pod_builder_add_object(b,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        // 32 bits primeiro (cópia direta); 24 e 10 bits pra compositor/monitor que só tem isso
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(11, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
                                                        SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx,
                                                        SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_BGR,
                                                        SPA_VIDEO_FORMAT_RGB, SPA_VIDEO_FORMAT_xRGB_210LE,
                                                        SPA_VIDEO_FORMAT_xBGR_210LE, SPA_VIDEO_FORMAT_ARGB_210LE,
                                                        SPA_VIDEO_FORMAT_ABGR_210LE),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(c->fps, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(c->fps, 1)),
        SPA_FORMAT_VIDEO_maxFramerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(c->fps, 1), &SPA_FRACTION(1, 1), &SPA_FRACTION(c->fps, 1)));
    return n;
}

static uint32_t drm_format_of(uint32_t spa) {
    for (int f = 0; f < N_DMA_FORMATS; f++)
        if (dma_formats[f].spa == spa) return dma_formats[f].drm;
    return 0;
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    struct cap_ctx *c = data;
    if (!param || id != SPA_PARAM_Format) return;
    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0) return;
    if (media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw) return;
    if (spa_format_video_raw_parse(param, &c->info) < 0) return;

    c->src_kind = SRC_32;
    const int dmabuf = c->egl && !c->dmabuf_off && spa_pod_find_prop(param, NULL, SPA_FORMAT_VIDEO_modifier) != NULL;
    if (c->egl) egl_forget(c->egl, NULL);
    switch (c->info.format) {
    case SPA_VIDEO_FORMAT_RGBx:
    case SPA_VIDEO_FORMAT_RGBA: c->pw_format = CAP_RGBX; break;
    case SPA_VIDEO_FORMAT_RGB: c->pw_format = CAP_RGBX; c->src_kind = SRC_24; break;
    case SPA_VIDEO_FORMAT_BGR: c->pw_format = CAP_BGRX; c->src_kind = SRC_24; break;
    // 10 bits: palavra de 32 bits LE com o canal do byte 0 nos bits baixos
    case SPA_VIDEO_FORMAT_xRGB_210LE:
    case SPA_VIDEO_FORMAT_ARGB_210LE: c->pw_format = CAP_BGRX; c->src_kind = SRC_30; break;
    case SPA_VIDEO_FORMAT_xBGR_210LE:
    case SPA_VIDEO_FORMAT_ABGR_210LE: c->pw_format = CAP_RGBX; c->src_kind = SRC_30; break;
    default: c->pw_format = CAP_BGRX; break;
    }
    if (dmabuf) c->src_kind = SRC_DMABUF;
    if (getenv("TELINHA_DEBUG"))
        fprintf(stderr, "[telinha] PipeWire: %ux%u, formato %s, %s\n", c->info.size.width, c->info.size.height,
                spa_debug_type_find_short_name(spa_type_video_format, c->info.format),
                dmabuf ? "DMA-BUF (GPU)" : "memória compartilhada");

    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[2];
    params[0] = spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 16),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_Int(dmabuf ? (1 << SPA_DATA_DmaBuf) : (1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    params[1] = spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
    pw_stream_update_params(c->stream, params, 2);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    struct cap_ctx *c = data;
    if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
        pthread_mutex_lock(&c->lock);
        c->failed = 1;
        snprintf(c->fail_msg, sizeof c->fail_msg, "PipeWire: %s", error ? error : "a transmissão foi encerrada");
        pthread_cond_broadcast(&c->cond);
        pthread_mutex_unlock(&c->lock);
    }
}

// Uma linha do formato do compositor pra 32 bits (BGRX/RGBX na mesma ordem).
static void copy_row(uint8_t *dst, const uint8_t *src, int w, int kind) {
    switch (kind) {
    case SRC_24:
        for (int x = 0; x < w; x++) {
            dst[x * 4 + 0] = src[x * 3 + 0];
            dst[x * 4 + 1] = src[x * 3 + 1];
            dst[x * 4 + 2] = src[x * 3 + 2];
            dst[x * 4 + 3] = 255;
        }
        break;
    case SRC_30:
        for (int x = 0; x < w; x++) {
            uint32_t v;
            memcpy(&v, src + x * 4, 4);
            dst[x * 4 + 0] = (uint8_t)(v >> 2);
            dst[x * 4 + 1] = (uint8_t)(v >> 12);
            dst[x * 4 + 2] = (uint8_t)(v >> 22);
            dst[x * 4 + 3] = 255;
        }
        break;
    default: memcpy(dst, src, (size_t)w * 4); break;
    }
}

static void on_process(void *data) {
    struct cap_ctx *c = data;
    struct pw_buffer *b = NULL, *nb;
    // fica só com o buffer mais recente
    while ((nb = pw_stream_dequeue_buffer(c->stream)) != NULL) {
        if (b) pw_stream_queue_buffer(c->stream, b);
        b = nb;
    }
    if (!b) return;

    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];
    struct spa_meta_header *h = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof(*h));
    int w = (int)c->info.size.width, hgt = (int)c->info.size.height;

    if (d->type == SPA_DATA_DmaBuf) {
        if (c->egl && w > 0 && hgt > 0 && !(h && (h->flags & SPA_META_HEADER_FLAG_CORRUPTED))) {
            size_t need = (size_t)w * hgt * 4;
            if (c->staging_cap < need) {
                free(c->staging);
                c->staging = malloc(need);
                c->staging_cap = c->staging ? need : 0;
            }
            struct timespec t0, t1;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            int fmt = c->staging ? egl_read(c->egl, buf, drm_format_of(c->info.format), c->info.modifier, w, hgt, c->staging) : -1;
            clock_gettime(CLOCK_MONOTONIC, &t1);
            c->read_us += (uint64_t)((int64_t)(t1.tv_sec - t0.tv_sec) * 1000000 + ((int64_t)t1.tv_nsec - (int64_t)t0.tv_nsec) / 1000);
            if (++c->read_n == 60) {
                if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] leitura do DMA-BUF: %.2f ms por quadro\n", c->read_us / 60 / 1000.0);
                c->read_us = c->read_n = 0;
            }
            if (fmt < 0) {
                // não deu pra importar: volta pra memória compartilhada
                if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] DMA-BUF não importou; usando memória compartilhada\n");
                c->dmabuf_off = 1;
                pw_stream_queue_buffer(c->stream, b);
                uint8_t pb[4096];
                struct spa_pod_builder pbb = SPA_POD_BUILDER_INIT(pb, sizeof(pb));
                const struct spa_pod *params[8];
                int n = build_formats(c, &pbb, params, 8);
                pw_stream_update_params(c->stream, params, n);
                return;
            }
            pthread_mutex_lock(&c->lock);
            uint8_t *tmp = c->pending;
            size_t tmp_cap = c->pending_cap;
            c->pending = c->staging;
            c->pending_cap = c->staging_cap;
            c->staging = tmp;
            c->staging_cap = tmp_cap;
            c->pending_w = w;
            c->pending_h = hgt;
            c->pending_fmt = fmt;
            c->fresh = 1;
            pthread_cond_broadcast(&c->cond);
            pthread_mutex_unlock(&c->lock);
        }
        pw_stream_queue_buffer(c->stream, b);
        return;
    }

    if (d->data && d->chunk && d->chunk->size > 0 && w > 0 && hgt > 0 &&
        !(h && (h->flags & SPA_META_HEADER_FLAG_CORRUPTED)) &&
        !(d->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED)) {
        const int bpp = c->src_kind == SRC_24 ? 3 : 4;
        int stride = d->chunk->stride > 0 ? d->chunk->stride : w * bpp;
        const uint8_t *src = (const uint8_t *)d->data + d->chunk->offset;
        size_t need = (size_t)w * hgt * 4;
        if ((size_t)stride * (hgt - 1) + (size_t)w * bpp <= d->maxsize - d->chunk->offset) {
            pthread_mutex_lock(&c->lock);
            if (c->pending_cap < need) {
                free(c->pending);
                c->pending = malloc(need);
                c->pending_cap = c->pending ? need : 0;
            }
            if (c->pending) {
                for (int y = 0; y < hgt; y++)
                    copy_row(c->pending + (size_t)y * w * 4, src + (size_t)y * stride, w, c->src_kind);
                c->pending_w = w;
                c->pending_h = hgt;
                c->pending_fmt = c->pw_format;
                c->fresh = 1;
                pthread_cond_broadcast(&c->cond);
            }
            pthread_mutex_unlock(&c->lock);
        }
    }
    pw_stream_queue_buffer(c->stream, b);
}

static void on_remove_buffer(void *data, struct pw_buffer *b) {
    struct cap_ctx *c = data;
    if (c->egl) egl_forget(c->egl, b->buffer);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .remove_buffer = on_remove_buffer,
    .process = on_process,
};

typedef struct {
    int done;
    GError *error;
    XdpSession *session;
    gboolean started;
} portal_wait;

static void on_session_created(GObject *src, GAsyncResult *res, gpointer data) {
    portal_wait *w = data;
    w->session = xdp_portal_create_screencast_session_finish(XDP_PORTAL(src), res, &w->error);
    w->done = 1;
}

static void on_session_started(GObject *src, GAsyncResult *res, gpointer data) {
    portal_wait *w = data;
    w->started = xdp_session_start_finish(XDP_SESSION(src), res, &w->error);
    w->done = 1;
}

static void token_path(char *out, size_t n) {
    const char *xdg = getenv("XDG_CONFIG_HOME");
    const char *home = getenv("HOME");
    if (xdg && *xdg) snprintf(out, n, "%s/telinha", xdg);
    else snprintf(out, n, "%s/.config/telinha", home ? home : "/tmp");
    mkdir(out, 0700);
    strncat(out, "/portal-token", n - strlen(out) - 1);
}

static char *load_token(void) {
    char path[512];
    token_path(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    char buf[256] = {0};
    if (!fgets(buf, sizeof buf, f)) buf[0] = 0;
    fclose(f);
    buf[strcspn(buf, "\r\n")] = 0;
    return buf[0] ? strdup(buf) : NULL;
}

static void save_token(const char *tok) {
    char path[512];
    token_path(path, sizeof path);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fputs(tok ? tok : "", f);
    fclose(f);
}

static void close_pipewire(struct cap_ctx *c) {
    if (c->loop) pw_thread_loop_lock(c->loop);
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->core) pw_core_disconnect(c->core);
    if (c->loop) {
        pw_thread_loop_unlock(c->loop);
        // o contexto EGL está ativo na thread do PipeWire: solta lá dentro
        if (c->egl) pw_loop_invoke(pw_thread_loop_get_loop(c->loop), egl_release, 0, NULL, 0, true, c->egl);
        pw_thread_loop_stop(c->loop);
    }
    egl_destroy(c->egl);
    c->egl = NULL;
    free(c->staging);
    c->staging = NULL;
    if (c->pw_ctx) pw_context_destroy(c->pw_ctx);
    if (c->loop) pw_thread_loop_destroy(c->loop);
    if (c->session) {
        xdp_session_close(c->session);
        g_object_unref(c->session);
    }
    if (c->portal) g_object_unref(c->portal);
    if (c->gctx) {
        g_main_context_pop_thread_default(c->gctx);
        g_main_context_unref(c->gctx);
    }
}

static int open_pipewire(struct cap_ctx *c, char *err, int errlen) {
    c->gctx = g_main_context_new();
    g_main_context_push_thread_default(c->gctx);

    GError *gerr = NULL;
    c->portal = xdp_portal_initable_new(&gerr);
    if (!c->portal) {
        set_err(err, errlen, "não consegui falar com o xdg-desktop-portal: %s", gerr ? gerr->message : "?");
        if (gerr) g_error_free(gerr);
        return -1;
    }

    char *token = load_token();
    for (int attempt = 0; attempt < 2; attempt++) {
        portal_wait w = {0};
        xdp_portal_create_screencast_session(c->portal, XDP_OUTPUT_MONITOR | XDP_OUTPUT_WINDOW,
                                             XDP_SCREENCAST_FLAG_NONE,
                                             (c->show_cursor && !c->soft_cursor) ? XDP_CURSOR_MODE_EMBEDDED : XDP_CURSOR_MODE_HIDDEN,
                                             XDP_PERSIST_MODE_PERSISTENT, token, NULL, on_session_created, &w);
        while (!w.done) g_main_context_iteration(c->gctx, TRUE);
        if (!w.session) {
            set_err(err, errlen, "o portal recusou a captura: %s", w.error ? w.error->message : "?");
            if (w.error) g_error_free(w.error);
            free(token);
            return -1;
        }
        c->session = w.session;

        portal_wait s = {0};
        xdp_session_start(c->session, NULL, NULL, on_session_started, &s);
        while (!s.done) g_main_context_iteration(c->gctx, TRUE);
        if (s.started) {
            if (s.error) g_error_free(s.error);
            break;
        }
        // token velho pode ter estragado; tenta de novo sem ele
        g_object_unref(c->session);
        c->session = NULL;
        if (token && attempt == 0) {
            if (s.error) g_error_free(s.error);
            free(token);
            token = NULL;
            continue;
        }
        set_err(err, errlen, "captura cancelada%s", "");
        if (s.error) {
            set_err(err, errlen, "captura cancelada ou negada: %s", s.error->message);
            g_error_free(s.error);
        }
        free(token);
        return -1;
    }
    free(token);
    if (!c->session) return -1;

    char *new_token = xdp_session_get_restore_token(c->session);
    if (new_token) {
        save_token(new_token);
        g_free(new_token);
    }

    GVariant *streams = xdp_session_get_streams(c->session);
    if (!streams || g_variant_n_children(streams) < 1) {
        set_err(err, errlen, "o portal não devolveu nenhuma tela%s", "");
        if (streams) g_variant_unref(streams);
        return -1;
    }
    uint32_t node = 0;
    GVariant *props = NULL;
    g_variant_get_child(streams, 0, "(u@a{sv})", &node, &props);
    if (props) {
        // monitor: onde ele fica no layout (pra posicionar o cursor desenhado por nós)
        g_variant_lookup(props, "position", "(ii)", &c->stream_x, &c->stream_y);
        g_variant_lookup(props, "size", "(ii)", &c->stream_w, &c->stream_h);
        g_variant_unref(props);
    }
    g_variant_unref(streams);

    int fd = xdp_session_open_pipewire_remote(c->session);
    if (fd < 0) {
        set_err(err, errlen, "não consegui abrir o PipeWire%s", "");
        return -1;
    }

    c->egl = egl_create();
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] DMA-BUF: %s\n", c->egl ? "disponível" : "indisponível");
    pw_init(NULL, NULL);
    c->loop = pw_thread_loop_new("telinha-captura", NULL);
    c->pw_ctx = pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0);
    if (!c->loop || !c->pw_ctx || pw_thread_loop_start(c->loop) < 0) {
        close(fd);
        set_err(err, errlen, "falha ao iniciar o PipeWire%s", "");
        return -1;
    }

    pw_thread_loop_lock(c->loop);
    c->core = pw_context_connect_fd(c->pw_ctx, fd, NULL, 0);
    if (!c->core) {
        pw_thread_loop_unlock(c->loop);
        set_err(err, errlen, "não consegui conectar no PipeWire%s", "");
        return -1;
    }
    c->stream = pw_stream_new(c->core, "telinha",
                              pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                PW_KEY_MEDIA_ROLE, "Screen", NULL));
    pw_stream_add_listener(c->stream, &c->stream_listener, &stream_events, c);

    uint8_t buffer[4096];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[8];
    int n_params = build_formats(c, &b, params, 8);
    int r = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, node,
                              PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, (uint32_t)n_params);
    pw_thread_loop_unlock(c->loop);
    if (r < 0) {
        set_err(err, errlen, "não consegui receber a tela do PipeWire%s", "");
        return -1;
    }
    return 0;
}

// Pergunta a posição global do cursor pro Hyprland (socket de IPC, ~0,1 ms).
static int hyprland_cursor(int *x, int *y) {
    const char *sig = getenv("HYPRLAND_INSTANCE_SIGNATURE");
    const char *rt = getenv("XDG_RUNTIME_DIR");
    if (!sig) return -1;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    for (int attempt = 0; attempt < 2; attempt++) {
        if (attempt == 0 && rt) snprintf(addr.sun_path, sizeof addr.sun_path, "%s/hypr/%s/.socket.sock", rt, sig);
        else snprintf(addr.sun_path, sizeof addr.sun_path, "/tmp/hypr/%s/.socket.sock", sig);
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0) return -1;
        if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
            const char req[] = "cursorpos";
            char buf[64] = {0};
            int ok = -1;
            if (write(fd, req, sizeof req - 1) == (ssize_t)(sizeof req - 1)) {
                ssize_t n = read(fd, buf, sizeof buf - 1);
                if (n > 0 && sscanf(buf, "%d, %d", x, y) == 2) ok = 0;
            }
            close(fd);
            return ok;
        }
        close(fd);
    }
    return -1;
}

// Preenche os campos de cursor do quadro (cursor desenhado por quem chama).
static int fill_cursor(struct cap_ctx *c, cap_frame *out) {
    out->cursor_draw = 0;
    out->cursor_known = 0;
    if (!c->soft_cursor) return 0;
    int gx, gy;
    if (hyprland_cursor(&gx, &gy) < 0) return 0;
    float scale = 1.0f;
    if (c->stream_w > 0 && out->width > 0) scale = (float)out->width / (float)c->stream_w;
    out->cursor_draw = 1;
    out->cursor_x = (int)((float)(gx - c->stream_x) * scale);
    out->cursor_y = (int)((float)(gy - c->stream_y) * scale);
    out->cursor_scale = scale;
    out->cursor_known = 1;
    out->cursor_px = out->cursor_x;
    out->cursor_py = out->cursor_y;
    int moved = gx != c->cursor_gx || gy != c->cursor_gy;
    c->cursor_gx = gx;
    c->cursor_gy = gy;
    return moved;
}

static int next_pipewire(struct cap_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
    // deixa o GLib processar sinais do portal (ex.: usuário parou o compartilhamento)
    while (g_main_context_iteration(c->gctx, FALSE)) {}
    // com cursor nosso, não dá pra esperar muito: o mouse pode mexer sem a tela mudar
    if (c->soft_cursor && c->fps > 0 && timeout_ms > 1000 / c->fps) timeout_ms = 1000 / c->fps;

    pthread_mutex_lock(&c->lock);
    if (!c->fresh && !c->failed) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += timeout_ms / 1000;
        ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000L;
        }
        while (!c->fresh && !c->failed)
            if (pthread_cond_timedwait(&c->cond, &c->lock, &ts) == ETIMEDOUT) break;
    }
    if (c->failed) {
        set_err(err, errlen, "%s", c->fail_msg);
        pthread_mutex_unlock(&c->lock);
        return -1;
    }
    if (!c->fresh) {
        pthread_mutex_unlock(&c->lock);
        // tela parada, mas o cursor mexeu: reentrega o último quadro com o cursor novo
        if (c->soft_cursor && c->have_front) {
            out->data = c->front;
            out->width = c->pending_w;
            out->height = c->pending_h;
            out->stride = c->pending_w * 4;
            out->format = c->pending_fmt;
            if (fill_cursor(c, out)) return 1;
        }
        return 0;
    }
    // troca pending <-> front
    uint8_t *tmp = c->front;
    size_t tmp_cap = c->front_cap;
    c->front = c->pending;
    c->front_cap = c->pending_cap;
    c->pending = tmp;
    c->pending_cap = tmp_cap;
    c->fresh = 0;
    out->data = c->front;
    out->width = c->pending_w;
    out->height = c->pending_h;
    out->stride = c->pending_w * 4;
    out->format = c->pending_fmt;
    c->have_front = 1;
    pthread_mutex_unlock(&c->lock);
    fill_cursor(c, out);
    return 1;
}

// ===========================================================================
// X11

static int x_error_flag;
static int x_error_handler(Display *d, XErrorEvent *e) {
    (void)d;
    (void)e;
    x_error_flag = 1;
    return 0;
}

static int open_x11(struct cap_ctx *c, char *err, int errlen) {
    c->dpy = XOpenDisplay(NULL);
    if (!c->dpy) {
        set_err(err, errlen, "não consegui abrir o display X11%s", "");
        return -1;
    }
    if (!XShmQueryExtension(c->dpy)) {
        set_err(err, errlen, "o servidor X não tem a extensão MIT-SHM%s", "");
        return -1;
    }
    int scr = DefaultScreen(c->dpy);
    c->root = RootWindow(c->dpy, scr);
    c->xw = DisplayWidth(c->dpy, scr);
    c->xh = DisplayHeight(c->dpy, scr);
    c->img = XShmCreateImage(c->dpy, DefaultVisual(c->dpy, scr), DefaultDepth(c->dpy, scr), ZPixmap, NULL,
                             &c->shm, c->xw, c->xh);
    if (!c->img || c->img->bits_per_pixel != 32) {
        set_err(err, errlen, "formato de tela X11 não suportado (precisa ser 32 bits)%s", "");
        return -1;
    }
    c->shm.shmid = shmget(IPC_PRIVATE, (size_t)c->img->bytes_per_line * c->img->height, IPC_CREAT | 0600);
    if (c->shm.shmid < 0) {
        set_err(err, errlen, "shmget falhou%s", "");
        return -1;
    }
    c->shm.shmaddr = c->img->data = shmat(c->shm.shmid, NULL, 0);
    c->shm.readOnly = False;
    XShmAttach(c->dpy, &c->shm);
    XSync(c->dpy, False);
    shmctl(c->shm.shmid, IPC_RMID, NULL);
    int ev, er;
    c->has_xfixes = XFixesQueryExtension(c->dpy, &ev, &er);
    c->xbuf = malloc((size_t)c->xw * c->xh * 4);
    return c->xbuf ? 0 : -1;
}

static void draw_x11_cursor(struct cap_ctx *c, uint8_t *buf, cap_frame *out) {
    XFixesCursorImage *ci = XFixesGetCursorImage(c->dpy);
    if (!ci) return;
    out->cursor_known = 1;
    out->cursor_px = ci->x;
    out->cursor_py = ci->y;
    int x0 = ci->x - ci->xhot, y0 = ci->y - ci->yhot;
    for (int y = 0; y < ci->height; y++) {
        int sy = y0 + y;
        if (sy < 0 || sy >= c->xh) continue;
        for (int x = 0; x < ci->width; x++) {
            int sx = x0 + x;
            if (sx < 0 || sx >= c->xw) continue;
            unsigned long p = ci->pixels[y * ci->width + x]; // ARGB pré-multiplicado
            unsigned a = (p >> 24) & 0xff;
            if (!a) continue;
            uint8_t *d = buf + ((size_t)sy * c->xw + sx) * 4;
            unsigned r = (p >> 16) & 0xff, g = (p >> 8) & 0xff, bl = p & 0xff;
            d[0] = (uint8_t)(bl + d[0] * (255 - a) / 255);
            d[1] = (uint8_t)(g + d[1] * (255 - a) / 255);
            d[2] = (uint8_t)(r + d[2] * (255 - a) / 255);
        }
    }
    XFree(ci);
}

static int next_x11(struct cap_ctx *c, cap_frame *out, char *err, int errlen) {
    x_error_flag = 0;
    XErrorHandler old = XSetErrorHandler(x_error_handler);
    Bool ok = XShmGetImage(c->dpy, c->root, c->img, 0, 0, AllPlanes);
    XSync(c->dpy, False);
    XSetErrorHandler(old);
    if (!ok || x_error_flag) {
        set_err(err, errlen, "XShmGetImage falhou (a resolução mudou?)%s", "");
        return -1;
    }
    for (int y = 0; y < c->xh; y++)
        memcpy(c->xbuf + (size_t)y * c->xw * 4, c->img->data + (size_t)y * c->img->bytes_per_line, (size_t)c->xw * 4);
    out->cursor_known = 0;
    if (c->show_cursor && c->has_xfixes) draw_x11_cursor(c, c->xbuf, out);
    out->data = c->xbuf;
    out->width = c->xw;
    out->height = c->xh;
    out->stride = c->xw * 4;
    out->format = CAP_BGRX;
    out->cursor_draw = 0;
    return 1;
}

static void close_x11(struct cap_ctx *c) {
    if (c->dpy && c->img) {
        XShmDetach(c->dpy, &c->shm);
        XDestroyImage(c->img);
        shmdt(c->shm.shmaddr);
    }
    if (c->dpy) XCloseDisplay(c->dpy);
    free(c->xbuf);
}

// ===========================================================================

cap_ctx *cap_open(int source_id, int show_cursor, int fps, char *err, int errlen) {
    (void)source_id;
    struct cap_ctx *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->show_cursor = show_cursor;
    c->fps = fps > 0 ? fps : 30;
    c->cursor_gx = c->cursor_gy = -100000;
    // Hyprland: cursor embutido força cursor em software (mouse com lag); desenhamos nós mesmos
    c->soft_cursor = show_cursor && getenv("HYPRLAND_INSTANCE_SIGNATURE") != NULL && getenv("TELINHA_CURSOR_EMBUTIDO") == NULL;
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->cond, NULL);
    if (is_wayland()) {
        c->kind = KIND_PIPEWIRE;
        if (open_pipewire(c, err, errlen) < 0) {
            cap_close(c);
            return NULL;
        }
    } else {
        c->kind = KIND_X11;
        if (open_x11(c, err, errlen) < 0) {
            cap_close(c);
            return NULL;
        }
    }
    return c;
}

int cap_next(cap_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
    if (c->kind == KIND_PIPEWIRE) return next_pipewire(c, out, timeout_ms, err, errlen);
    return next_x11(c, out, err, errlen);
}

const char *cap_backend(cap_ctx *c) {
    return c->kind == KIND_PIPEWIRE ? "PipeWire" : "X11";
}

void cap_close(cap_ctx *c) {
    if (!c) return;
    if (c->kind == KIND_PIPEWIRE) close_pipewire(c);
    else close_x11(c);
    free(c->pending);
    free(c->front);
    pthread_mutex_destroy(&c->lock);
    pthread_cond_destroy(&c->cond);
    free(c);
}
