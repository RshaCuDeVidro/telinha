// Captura no Linux.
//   Wayland: xdg-desktop-portal (ScreenCast) + PipeWire. Funciona em qualquer
//            compositor com portal (Hyprland, GNOME, KDE, Sway...).
//   X11:     XShm + XFixes (cursor).
#define _GNU_SOURCE
#include "capture.h"
#include "cudagl.h"

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
// O que tem de novo (cap_ctx.fresh). Quadro da placa e quadro pela CPU têm
// sinais separados: se a captura muda de caminho no meio (a placa falhou, o
// compositor renegociou o formato), um quadro da placa não pode ser lido
// como se estivesse em `pending` (que nesse caso nem existe).
enum { FRESH_GPU = 1, FRESH_PREVIEW = 2, FRESH_CPU = 4 };
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
    struct gpu_path *gpu;  // caminho pela placa (cap_gpu_enable); NULL = pela CPU
    int gpu_on;            // sob o lock: ligado (a thread do PipeWire vê na hora)
    int waiting;           // sob o lock: quem chama está esperando quadro (senão, não vale a pena produzir)
    uint64_t last_take_us; // quando quem chama pegou um quadro pela última vez
    struct spa_source *cursor_timer; // cursor desenhado por nós: redesenha quando só o mouse mexeu

    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint8_t *pending; // último frame recebido (escrito pela thread do PipeWire)
    size_t pending_cap;
    int pending_w, pending_h, pending_fmt;
    int fresh; // FRESH_*: o que tem de novo pra quem chama
    // cursor fora do vídeo (cap_set_cursor_apart): não pinta, só diz onde está
    int cursor_apart;
    int redeliver; // reentregar o último quadro limpo (o de antes tinha o cursor pintado)
    int x11_cx, x11_cy; // última posição do cursor no X11 (pra saber se mexeu)
    int front_w, front_h, front_fmt; // tamanho/formato do que está em `front` (o `pending` pode mudar antes)
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
    out[0].pid = 0; // o portal não diz de quem é a janela
    out[0].app[0] = 0;
    if (is_wayland())
        snprintf(out[0].name, sizeof out[0].name, "Escolher tela ou janela (seletor do sistema)");
    else
        snprintf(out[0].name, sizeof out[0].name, "Tela inteira (X11)");
    return 1;
}

// O seletor do portal (Wayland) já mostra as miniaturas; no X11 é uma tela só.
int cap_thumb(int source_id, uint8_t *rgba, int max_w, int max_h, int *w, int *h) {
    (void)source_id;
    (void)rgba;
    (void)max_w;
    (void)max_h;
    (void)w;
    (void)h;
    return 0;
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
typedef unsigned int GLuint, GLenum, GLbitfield;
typedef int GLint, GLsizei;
typedef float GLfloat;
typedef unsigned char GLboolean;

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
#define GL_LINEAR 0x2601
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_BLEND 0x0BE2
#define GL_SRC_ALPHA 0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_SCISSOR_TEST 0x0C11
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_TRIANGLE_STRIP 0x0005
#define GL_FLOAT 0x1406
#define GL_TEXTURE0 0x84C0
#define GL_NO_ERROR 0

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
    EGLContext ctx_warm; // compartilha objetos com `ctx`: prepara a placa numa thread à parte
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
    // caminho pela placa (desenho do quadro de saída)
    void (*TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
    void (*TexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
    void (*Viewport)(GLint, GLint, GLsizei, GLsizei);
    void (*Enable)(GLenum);
    void (*Disable)(GLenum);
    void (*BlendFunc)(GLenum, GLenum);
    GLuint (*CreateShader)(GLenum);
    void (*ShaderSource)(GLuint, GLsizei, const char *const *, const GLint *);
    void (*CompileShader)(GLuint);
    void (*GetShaderiv)(GLuint, GLenum, GLint *);
    void (*DeleteShader)(GLuint);
    GLuint (*CreateProgram)(void);
    void (*AttachShader)(GLuint, GLuint);
    void (*LinkProgram)(GLuint);
    void (*GetProgramiv)(GLuint, GLenum, GLint *);
    void (*DeleteProgram)(GLuint);
    void (*UseProgram)(GLuint);
    GLint (*GetAttribLocation)(GLuint, const char *);
    GLint (*GetUniformLocation)(GLuint, const char *);
    void (*Uniform1i)(GLint, GLint);
    void (*Uniform4f)(GLint, GLfloat, GLfloat, GLfloat, GLfloat);
    void (*EnableVertexAttribArray)(GLuint);
    void (*VertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
    void (*DrawArrays)(GLenum, GLint, GLsizei);
    void (*ActiveTexture)(GLenum);
    GLenum (*GetError)(void);
    void (*Finish)(void);
};

// Caminho pela placa (ver capture.h): o quadro vai da textura importada do
// DMA-BUF (ou subido da memória compartilhada) pra uma textura de saída —
// recorte, escala e cursor desenhados pela GPU — e de lá, por CUDA, pra um
// buffer na placa que o NVENC lê direto. Tudo na thread que tem o contexto
// EGL (a do PipeWire; no X11, a de quem chama cap_next).
#define N_GPU_SLOTS 5
enum { SLOT_FREE = 0, SLOT_PENDING = 1, SLOT_HELD = 2, SLOT_RENDERING = 3 };
struct gpu_slot {
    uint64_t dev; // memória da placa (RGBA, pitch)
    int pitch;
    int w, h;
    int state;
    int cursor_known, cursor_px, cursor_py; // ponta do cursor nesse quadro
    int cursor_x, cursor_y; // posição usada no desenho
    int src_w, src_h; // recorte da fonte que virou esse quadro
};
struct gpu_path {
    cudagl *cg;
    cap_va_ops va; // Intel/AMD: conversor VA-API (va.ctx != NULL); aí não tem GL nem CUDA aqui
    cap_rect_fn rect_fn;
    cap_cursor_fn cursor_fn;
    int gl_ready, failed;
    GLuint prog;
    GLint loc_rect, loc_swap, loc_tex, loc_alpha;
    GLuint src_tex; // quadro subido da memória compartilhada
    int src_w, src_h;
    GLuint copy_tex, copy_fbo; // cópia da fonte inteira (recorte novo com a tela parada)
    int copy_w, copy_h, have_copy;
    int output_dirty; // recorte/altura mudaram desde o último quadro
    // preparação (shader, cursor, saída registrada no CUDA) numa thread à parte:
    // na thread do PipeWire ela levava ~80 ms, o portal ficava sem buffer,
    // desistia do DMA-BUF e a captura morria
    pthread_t warm_thread;
    int warm_started, warming, objects_ready;
    uint64_t retired[8]; // buffers de slots que mudaram de tamanho: soltos no cap_gpu_gc
    int n_retired;
    GLuint scene_tex, scene_fbo; // saída sem cursor (pra redesenhar só o cursor)
    GLuint out_tex, out_fbo;     // saída (com cursor) — registrada no CUDA
    int out_w, out_h;
    void *out_res;
    int have_scene, scene_src_w, scene_src_h, scene_swap;
    int scene_x, scene_y, scene_w, scene_h; // recorte usado na cena (pixels da fonte)
    GLuint cur_tex;
    int cur_w, cur_h;
    GLuint prev_tex, prev_fbo;
    int prev_w, prev_h;
    uint8_t *prev_back, *prev_front, *prev_out; // trás (PipeWire), frente (trocada sob o lock), saída (só de quem chama)
    size_t prev_back_cap, prev_front_cap, prev_out_cap;
    int prev_back_w, prev_back_h, prev_back_full, prev_front_w, prev_front_h, prev_front_full, prev_new;
    uint64_t prev_last_us;
    struct gpu_slot slots[N_GPU_SLOTS];
    // pedidos de quem chama (sob c->lock)
    float crop[4];
    int max_h;
    int want_preview, preview_max_w;
    uint64_t work_us, work_n; // TELINHA_DEBUG: CPU gasta por quadro
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
        if (e->ctx_warm) e->DestroyContext(e->dpy, e->ctx_warm);
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
    e->ctx_warm = e->CreateContext(e->dpy, NULL, e->ctx, ctx_attr); // pode faltar: aí prepara na hora

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
    LOAD(TexImage2D, "glTexImage2D");
    LOAD(TexSubImage2D, "glTexSubImage2D");
    LOAD(Viewport, "glViewport");
    LOAD(Enable, "glEnable");
    LOAD(Disable, "glDisable");
    LOAD(BlendFunc, "glBlendFunc");
    LOAD(CreateShader, "glCreateShader");
    LOAD(ShaderSource, "glShaderSource");
    LOAD(CompileShader, "glCompileShader");
    LOAD(GetShaderiv, "glGetShaderiv");
    LOAD(DeleteShader, "glDeleteShader");
    LOAD(CreateProgram, "glCreateProgram");
    LOAD(AttachShader, "glAttachShader");
    LOAD(LinkProgram, "glLinkProgram");
    LOAD(GetProgramiv, "glGetProgramiv");
    LOAD(DeleteProgram, "glDeleteProgram");
    LOAD(UseProgram, "glUseProgram");
    LOAD(GetAttribLocation, "glGetAttribLocation");
    LOAD(GetUniformLocation, "glGetUniformLocation");
    LOAD(Uniform1i, "glUniform1i");
    LOAD(Uniform4f, "glUniform4f");
    LOAD(EnableVertexAttribArray, "glEnableVertexAttribArray");
    LOAD(VertexAttribPointer, "glVertexAttribPointer");
    LOAD(DrawArrays, "glDrawArrays");
    LOAD(ActiveTexture, "glActiveTexture");
    LOAD(GetError, "glGetError");
    LOAD(Finish, "glFinish");
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

// Importa o DMA-BUF (uma vez por buffer) como textura. 0 = não deu.
static GLuint egl_import(struct egl_state *e, struct spa_buffer *buf, uint32_t drm_format, uint64_t modifier, int w, int h) {
    if (getenv("TELINHA_TESTE_DMABUF_FALHA")) return 0; // testa a volta pra memória compartilhada
    if (egl_make_current(e) < 0) return 0;
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
            if (d->type != SPA_DATA_DmaBuf || !d->chunk) return 0;
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
        if (!img) return 0;
        GLuint tex = 0;
        e->GenTextures(1, &tex);
        e->BindTexture(GL_TEXTURE_2D, tex);
        // linear: a escala pela placa (caminho pela placa) sai suave; a leitura
        // de volta (pela CPU) não amostra, então tanto faz pra ela
        e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        e->EGLImageTargetTexture2DOES(GL_TEXTURE_2D, img);
        e->images[free_slot].buf = buf;
        e->images[free_slot].img = img;
        e->images[free_slot].tex = tex;
        slot = free_slot;
    }
    return e->images[slot].tex;
}

// Importa (uma vez por buffer) e lê o DMA-BUF pra `dst` (w*h*4).
// Retorna o formato lido (CAP_BGRX/CAP_RGBX) ou -1.
static int egl_read(struct egl_state *e, struct spa_buffer *buf, uint32_t drm_format, uint64_t modifier,
                    int w, int h, uint8_t *dst) {
    GLuint tex = egl_import(e, buf, drm_format, modifier, w, h);
    if (!tex) return -1;
    e->BindFramebuffer(GL_FRAMEBUFFER, e->fbo);
    e->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (e->CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return -1;
    e->PixelStorei(GL_PACK_ALIGNMENT, 4);
    // o GL lê a imagem já "destrançada" (o layout da GPU vira linhas comuns)
    e->ReadPixels(0, 0, w, h, e->read_bgra ? GL_BGRA_EXT : GL_RGBA, GL_UNSIGNED_BYTE, dst);
    return e->read_bgra ? CAP_BGRX : CAP_RGBX;
}

// ===========================================================================
// Caminho pela placa

static uint64_t now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000 + (uint64_t)t.tv_nsec / 1000;
}

static GLuint gpu_shader(struct egl_state *e, GLenum kind, const char *src) {
    GLuint s = e->CreateShader(kind);
    e->ShaderSource(s, 1, &src, NULL);
    e->CompileShader(s);
    GLint ok = 0;
    e->GetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        e->DeleteShader(s);
        return 0;
    }
    return s;
}

static void gpu_tex_alloc(struct egl_state *e, GLuint *tex, int w, int h, const void *pixels) {
    if (!*tex) e->GenTextures(1, tex);
    e->BindTexture(GL_TEXTURE_2D, *tex);
    e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    e->PixelStorei(GL_UNPACK_ALIGNMENT, 4);
    e->TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}

static int gpu_fbo_for(struct egl_state *e, GLuint *fbo, GLuint tex) {
    if (!*fbo) e->GenFramebuffers(1, fbo);
    e->BindFramebuffer(GL_FRAMEBUFFER, *fbo);
    e->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    return e->CheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE ? 0 : -1;
}

// Programa e textura do cursor: objetos compartilhados entre os contextos,
// feitos uma vez (na thread de preparação ou, sem ela, na do PipeWire).
static int gpu_build_objects(struct egl_state *e, struct gpu_path *g) {
    if (g->objects_ready) return 0;
    while (e->GetError() != GL_NO_ERROR) {} // erro velho de outra etapa não é nosso
    // `rect` = pedaço da textura (fração) que cobre a área desenhada; `swap`
    // troca R e B (quadro BGRX subido da memória compartilhada)
    GLuint vs = gpu_shader(e, GL_VERTEX_SHADER,
        "attribute vec2 p; varying vec2 t; uniform vec4 rect;"
        "void main(){ t = rect.xy + (p * 0.5 + 0.5) * rect.zw; gl_Position = vec4(p, 0.0, 1.0); }");
    GLuint fs = gpu_shader(e, GL_FRAGMENT_SHADER,
        "precision mediump float; varying vec2 t; uniform sampler2D s; uniform int swap; uniform int keep_alpha;"
        "void main(){ vec4 c = texture2D(s, t); if (swap != 0) c = c.bgra; if (keep_alpha == 0) c.a = 1.0; gl_FragColor = c; }");
    if (!vs || !fs) {
        if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: shader não compilou (%s)\n", vs ? "fragmento" : "vértice");
        if (vs) e->DeleteShader(vs);
        if (fs) e->DeleteShader(fs);
        return -1;
    }
    g->prog = e->CreateProgram();
    e->AttachShader(g->prog, vs);
    e->AttachShader(g->prog, fs);
    e->LinkProgram(g->prog);
    e->DeleteShader(vs);
    e->DeleteShader(fs);
    GLint ok = 0;
    e->GetProgramiv(g->prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: programa não linkou\n");
        return -1;
    }
    g->loc_rect = e->GetUniformLocation(g->prog, "rect");
    g->loc_swap = e->GetUniformLocation(g->prog, "swap");
    g->loc_alpha = e->GetUniformLocation(g->prog, "keep_alpha");
    g->loc_tex = e->GetUniformLocation(g->prog, "s");
    e->UseProgram(g->prog);
    e->Uniform1i(g->loc_tex, 0); // estado do programa: vale em todos os contextos
    if (g->cursor_fn) {
        int cw = 0, ch = 0;
        const uint8_t *px = g->cursor_fn(&cw, &ch);
        if (px && cw > 0 && ch > 0) {
            gpu_tex_alloc(e, &g->cur_tex, cw, ch, px);
            e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            e->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            g->cur_w = cw;
            g->cur_h = ch;
        }
    }
    const GLenum err = e->GetError();
    if (err != GL_NO_ERROR && getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: erro do GL na preparação: 0x%x\n", err);
    g->objects_ready = err == GL_NO_ERROR;
    return g->objects_ready ? 0 : -1;
}

// Pronto pra desenhar na thread do contexto principal: objetos (se ninguém
// fez) + o estado que é de cada contexto (programa em uso, vértices).
static int gpu_gl_init(struct egl_state *e, struct gpu_path *g) {
    if (g->gl_ready) return 0;
    if (egl_make_current(e) < 0) {
        if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: eglMakeCurrent falhou\n");
        return -1;
    }
    if (gpu_build_objects(e, g) < 0) return -1;
    while (e->GetError() != GL_NO_ERROR) {}
    e->UseProgram(g->prog);
    GLint ap = e->GetAttribLocation(g->prog, "p");
    static const GLfloat quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    e->EnableVertexAttribArray((GLuint)ap);
    e->VertexAttribPointer((GLuint)ap, 2, GL_FLOAT, 0, 0, quad);
    g->gl_ready = e->GetError() == GL_NO_ERROR;
    return g->gl_ready ? 0 : -1;
}

// Solta tudo da placa (na thread do contexto; o cudagl continua de quem chamou).
static void gpu_gl_destroy(struct egl_state *e, struct gpu_path *g) {
    if (!g) return;
    if (g->out_res) cudagl_unregister(g->cg, g->out_res);
    g->out_res = NULL;
    for (int i = 0; i < N_GPU_SLOTS; i++) {
        if (g->slots[i].dev) cudagl_free(g->cg, g->slots[i].dev);
        g->slots[i].dev = 0;
        g->slots[i].state = SLOT_FREE;
    }
    for (int i = 0; i < g->n_retired; i++) cudagl_free(g->cg, g->retired[i]);
    g->n_retired = 0;
    if (e && e->current) {
        GLuint texs[6] = {g->src_tex, g->scene_tex, g->out_tex, g->cur_tex, g->prev_tex, g->copy_tex};
        GLuint fbos[4] = {g->scene_fbo, g->out_fbo, g->prev_fbo, g->copy_fbo};
        for (int i = 0; i < 6; i++) if (texs[i]) e->DeleteTextures(1, &texs[i]);
        for (int i = 0; i < 4; i++) if (fbos[i]) e->DeleteFramebuffers(1, &fbos[i]);
        if (g->prog) e->DeleteProgram(g->prog);
    }
    g->src_tex = g->scene_tex = g->out_tex = g->cur_tex = g->prev_tex = g->copy_tex = 0;
    g->scene_fbo = g->out_fbo = g->prev_fbo = g->copy_fbo = 0;
    g->have_copy = 0;
    g->prog = 0;
    g->gl_ready = 0;
    g->have_scene = 0;
    g->out_w = g->out_h = 0;
}

// Desenha `tex` (o pedaço `rect`, em fração) cobrindo o framebuffer `fbo` (vw x vh).
static void gpu_draw(struct egl_state *e, struct gpu_path *g, GLuint fbo, int vw, int vh, GLuint tex,
                     float rx, float ry, float rw, float rh, int swap) {
    e->BindFramebuffer(GL_FRAMEBUFFER, fbo);
    e->Viewport(0, 0, vw, vh);
    e->UseProgram(g->prog);
    e->ActiveTexture(GL_TEXTURE0);
    e->BindTexture(GL_TEXTURE_2D, tex);
    e->Uniform4f(g->loc_rect, rx, ry, rw, rh);
    e->Uniform1i(g->loc_swap, swap);
    e->Uniform1i(g->loc_alpha, 0);
    e->DrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// Texturas de saída no tamanho pedido (e o registro no CUDA).
static int gpu_ensure_output(struct egl_state *e, struct gpu_path *g, int ow, int oh) {
    if (g->out_w == ow && g->out_h == oh && g->out_res) {
        if (g->scene_fbo && g->out_fbo) return 0;
        // texturas da preparação: os FBOs não são compartilhados, nascem aqui
        if (gpu_fbo_for(e, &g->scene_fbo, g->scene_tex) < 0 || gpu_fbo_for(e, &g->out_fbo, g->out_tex) < 0) return -1;
        return 0;
    }
    if (g->out_res) cudagl_unregister(g->cg, g->out_res);
    g->out_res = NULL;
    gpu_tex_alloc(e, &g->scene_tex, ow, oh, NULL);
    gpu_tex_alloc(e, &g->out_tex, ow, oh, NULL);
    if (gpu_fbo_for(e, &g->scene_fbo, g->scene_tex) < 0 || gpu_fbo_for(e, &g->out_fbo, g->out_tex) < 0) return -1;
    g->out_res = cudagl_register(g->cg, g->out_tex, 0);
    if (!g->out_res) return -1;
    g->out_w = ow;
    g->out_h = oh;
    g->have_scene = 0;
    return 0;
}

// Cena (recorte + escala, sem cursor) -> saída com o cursor -> buffer do slot.
// O cursor vem em pixels da fonte; k = tamanho da seta em pixels lógicos.
static int gpu_compose(struct egl_state *e, struct gpu_path *g, struct gpu_slot *sl, int cursor_draw, int cx, int cy, float cursor_scale) {
    const int ow = g->out_w, oh = g->out_h;
    gpu_draw(e, g, g->out_fbo, ow, oh, g->scene_tex, 0, 0, 1, 1, 0);
    sl->cursor_x = cx;
    sl->cursor_y = cy;
    if (cursor_draw && g->cur_tex && g->scene_w > 0 && g->scene_h > 0) {
        // mesma conta do desenho pela CPU (drawCursor): seta de ~24 px lógicos
        const float sx = (float)ow / (float)g->scene_w, sy = (float)oh / (float)g->scene_h;
        float k = cursor_scale * 1.2f;
        if (k < 1) k = 1;
        const float x0 = (float)(cx - g->scene_x) * sx, y0 = (float)(cy - g->scene_y) * sy;
        const float w = (float)g->cur_w * k * sx, h = (float)g->cur_h * k * sy;
        if (x0 < ow && y0 < oh && x0 + w > 0 && y0 + h > 0) {
            // o quad cobre só o retângulo do cursor: viewport nele, textura inteira
            e->Enable(GL_BLEND);
            e->BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            e->BindFramebuffer(GL_FRAMEBUFFER, g->out_fbo);
            e->Viewport((GLint)x0, (GLint)y0, (GLsizei)(w + 0.5f), (GLsizei)(h + 0.5f));
            e->UseProgram(g->prog);
            e->ActiveTexture(GL_TEXTURE0);
            e->BindTexture(GL_TEXTURE_2D, g->cur_tex);
            e->Uniform4f(g->loc_rect, 0, 0, 1, 1);
            e->Uniform1i(g->loc_swap, 0);
            e->Uniform1i(g->loc_alpha, 1);
            e->DrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            e->Disable(GL_BLEND);
        }
    }
    if (sl->w != ow || sl->h != oh || !sl->dev) {
        if (sl->dev) {
            // o encoder (outra thread) pode ter esse ponteiro registrado: só
            // some quando ele for recriado no tamanho novo (cap_gpu_gc)
            if (g->n_retired == (int)(sizeof g->retired / sizeof g->retired[0])) {
                cudagl_free(g->cg, g->retired[0]);
                memmove(&g->retired[0], &g->retired[1], sizeof g->retired[0] * (size_t)(g->n_retired - 1));
                g->n_retired--;
            }
            g->retired[g->n_retired++] = sl->dev;
        }
        sl->dev = cudagl_alloc(g->cg, ow * 4, oh, &sl->pitch);
        if (!sl->dev) return -1;
        sl->w = ow;
        sl->h = oh;
    }
    return cudagl_tex_to_dev(g->cg, g->out_res, sl->dev, sl->pitch, ow * 4, oh);
}

// Prévia pequena lida de volta pra CPU (quem transmite olha pra ela; ≤15 q/s).
static void gpu_preview(struct egl_state *e, struct gpu_path *g, int want, int max_w, GLuint src_tex, int sw, int sh, int swap) {
    const uint64_t now = now_us();
    if (now - g->prev_last_us < 66000) return;
    g->prev_last_us = now;
    const int full = want == 2;
    const int fw = full ? sw : g->out_w, fh = full ? sh : g->out_h;
    if (fw <= 0 || fh <= 0) return;
    int pw = fw, ph = fh;
    if (max_w > 0 && pw > max_w) {
        pw = max_w;
        ph = (int)((long long)fh * pw / fw);
    }
    if (pw < 2 || ph < 2) return;
    if (g->prev_w != pw || g->prev_h != ph || !g->prev_tex) {
        gpu_tex_alloc(e, &g->prev_tex, pw, ph, NULL);
        if (gpu_fbo_for(e, &g->prev_fbo, g->prev_tex) < 0) return;
        g->prev_w = pw;
        g->prev_h = ph;
    }
    const size_t need = (size_t)pw * ph * 4;
    if (g->prev_back_cap < need) {
        free(g->prev_back);
        g->prev_back = malloc(need);
        g->prev_back_cap = g->prev_back ? need : 0;
        if (!g->prev_back) return;
    }
    gpu_draw(e, g, g->prev_fbo, pw, ph, full ? src_tex : g->scene_tex, 0, 0, 1, 1, full ? swap : 0);
    e->PixelStorei(GL_PACK_ALIGNMENT, 4);
    e->ReadPixels(0, 0, pw, ph, GL_RGBA, GL_UNSIGNED_BYTE, g->prev_back);
    g->prev_back_w = pw;
    g->prev_back_h = ph;
    g->prev_back_full = full;
    g->prev_new = 1;
}

// Escolhe um slot pra desenhar (sob o lock). NULL = todos ocupados por quem chama.
static struct gpu_slot *gpu_pick_slot(struct gpu_path *g) {
    for (int i = 0; i < N_GPU_SLOTS; i++)
        if (g->slots[i].state == SLOT_FREE) return &g->slots[i];
    for (int i = 0; i < N_GPU_SLOTS; i++)
        if (g->slots[i].state == SLOT_PENDING) return &g->slots[i]; // ninguém pegou: o novo substitui
    return NULL;
}

// Um quadro novo da fonte (`src_tex`, sw x sh): produz um slot pronto (e a
// prévia, se pedida). Na thread do contexto. Retorna 1 se produziu.
// Devolve um slot escolhido pra desenhar que acabou não sendo usado.
static void gpu_unpick(struct cap_ctx *c, struct gpu_slot *sl) {
    if (!sl) return;
    pthread_mutex_lock(&c->lock);
    sl->state = SLOT_FREE;
    pthread_mutex_unlock(&c->lock);
}

static void gpu_fail(struct gpu_path *g, const char *what) {
    if (!g->failed && getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa falhou (%s); seguindo pela CPU\n", what);
    g->failed = 1;
}

static int gpu_produce(struct cap_ctx *c, GLuint src_tex, int sw, int sh, int swap, cap_frame *cur) {
    struct gpu_path *g = c->gpu;
    struct egl_state *e = c->egl;
    if (!g || g->failed) return 0;
    const uint64_t t0 = now_us();
    if (gpu_gl_init(e, g) < 0) {
        gpu_fail(g, "GL");
        return 0;
    }
    const uint64_t t_init = now_us();
    pthread_mutex_lock(&c->lock);
    float crop[4];
    memcpy(crop, g->crop, sizeof crop);
    const int max_h = g->max_h, want_prev = g->want_preview, prev_max_w = g->preview_max_w;
    struct gpu_slot *sl = gpu_pick_slot(g);
    if (sl) sl->state = SLOT_RENDERING;
    pthread_mutex_unlock(&c->lock);
    int x = 0, y = 0, w = sw, h = sh, ow = sw, oh = sh;
    if (g->rect_fn) g->rect_fn(sw, sh, crop, max_h, &x, &y, &w, &h, &ow, &oh);
    if (ow < 2 || oh < 2 || w < 1 || h < 1) {
        gpu_unpick(c, sl);
        return 0;
    }
    if (gpu_ensure_output(e, g, ow, oh) < 0) {
        gpu_fail(g, "textura de saída/registro no CUDA");
        gpu_unpick(c, sl);
        return 0;
    }
    const uint64_t t_out = now_us();
    gpu_draw(e, g, g->scene_fbo, ow, oh, src_tex, (float)x / (float)sw, (float)y / (float)sh, (float)w / (float)sw, (float)h / (float)sh, swap);
    // cópia da fonte inteira (já com R/B certos): recorte ou altura novos com
    // a tela parada saem dela, sem esperar o compositor mandar outro quadro
    if (src_tex != g->copy_tex) {
        if (g->copy_w != sw || g->copy_h != sh || !g->copy_tex) {
            gpu_tex_alloc(e, &g->copy_tex, sw, sh, NULL);
            if (gpu_fbo_for(e, &g->copy_fbo, g->copy_tex) < 0) g->copy_tex = 0;
            g->copy_w = sw;
            g->copy_h = sh;
        } else if (!g->copy_fbo && gpu_fbo_for(e, &g->copy_fbo, g->copy_tex) < 0) {
            g->copy_tex = 0; // textura da preparação: o FBO nasce aqui
        }
        if (g->copy_tex) {
            gpu_draw(e, g, g->copy_fbo, sw, sh, src_tex, 0, 0, 1, 1, swap);
            g->have_copy = 1;
        }
    }
    g->output_dirty = 0;
    g->have_scene = 1;
    g->scene_src_w = sw;
    g->scene_src_h = sh;
    g->scene_swap = swap;
    g->scene_x = x;
    g->scene_y = y;
    g->scene_w = w;
    g->scene_h = h;
    int produced = 0;
    if (sl) {
        if (gpu_compose(e, g, sl, cur->cursor_draw, cur->cursor_x, cur->cursor_y, cur->cursor_scale) == 0) {
            sl->src_w = w;
            sl->src_h = h;
            // ponta do cursor relativa ao recorte (quem assiste dá zoom seguindo ela)
            sl->cursor_known = 0;
            if (cur->cursor_known) {
                const int px = cur->cursor_px - x, py = cur->cursor_py - y;
                if (px >= 0 && py >= 0 && px < w && py < h) {
                    // em pixels do quadro de saída
                    sl->cursor_known = 1;
                    sl->cursor_px = (int)((long long)px * ow / w);
                    sl->cursor_py = (int)((long long)py * oh / h);
                }
            }
            produced = 1;
        } else {
            gpu_fail(g, "cópia pro buffer do encoder");
        }
    }
    if (want_prev) gpu_preview(e, g, want_prev, prev_max_w, src_tex, sw, sh, swap);
    // sem cópia pro CUDA (que espera o desenho): garante que o GL acabou de
    // ler a textura antes de devolver o DMA-BUF pro compositor
    if (!produced) e->Finish();
    const GLenum gl_err = e->GetError();
    if (gl_err != GL_NO_ERROR) {
        if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] erro do GL na captura pela placa: 0x%x\n", gl_err);
        gpu_fail(g, "GL");
    }
    g->work_us += now_us() - t0;
    if (getenv("TELINHA_DEBUG") && (now_us() - t0 > 20000)) fprintf(stderr, "[telinha] quadro pela placa demorou %.1f ms (nº %llu: GL %.1f, saída %.1f)\n", (now_us() - t0) / 1000.0, (unsigned long long)g->work_n, (t_init - t0) / 1000.0, (t_out - t_init) / 1000.0);
    if (++g->work_n == 120 && getenv("TELINHA_DEBUG")) {
        fprintf(stderr, "[telinha] quadro pela placa: %.2f ms por quadro\n", (double)g->work_us / 120 / 1000.0);
        g->work_us = g->work_n = 0;
    }
    pthread_mutex_lock(&c->lock);
    if (sl) {
        if (produced && !g->failed) {
            for (int i = 0; i < N_GPU_SLOTS; i++)
                if (g->slots[i].state == SLOT_PENDING) g->slots[i].state = SLOT_FREE; // o mais novo vale
            sl->state = SLOT_PENDING;
            c->fresh |= FRESH_GPU;
            // teste: a placa "falha" logo depois de entregar o quadro N (o quadro
            // fica pendente e a captura volta pra CPU no mesmo instante)
            static int fail_after = -1, produced_n = 0;
            if (fail_after < 0) fail_after = getenv("TELINHA_TESTE_PLACA_FALHA") ? atoi(getenv("TELINHA_TESTE_PLACA_FALHA")) : 0;
            if (fail_after > 0 && ++produced_n == fail_after) gpu_fail(g, "teste");
        } else {
            sl->state = SLOT_FREE;
        }
    }
    if (g->prev_new) {
        uint8_t *tb = g->prev_front;
        size_t tc = g->prev_front_cap;
        g->prev_front = g->prev_back;
        g->prev_front_cap = g->prev_back_cap;
        g->prev_back = tb;
        g->prev_back_cap = tc;
        g->prev_front_w = g->prev_back_w;
        g->prev_front_h = g->prev_back_h;
        g->prev_front_full = g->prev_back_full;
        g->prev_new = 0;
        c->fresh |= FRESH_PREVIEW; // prévia nova (mesmo sem slot: quem chama só pega a prévia)
    }
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->lock);
    return produced;
}

// Só o cursor mexeu (tela parada): redesenha a saída a partir da cena guardada.
static int gpu_recompose(struct cap_ctx *c, cap_frame *cur) {
    struct gpu_path *g = c->gpu;
    if (!g || g->failed || !g->have_scene || !g->out_res) return 0;
    pthread_mutex_lock(&c->lock);
    struct gpu_slot *sl = gpu_pick_slot(g);
    if (sl) sl->state = SLOT_RENDERING;
    pthread_mutex_unlock(&c->lock);
    if (!sl) return 0;
    const int ok = gpu_compose(c->egl, g, sl, cur->cursor_draw, cur->cursor_x, cur->cursor_y, cur->cursor_scale) == 0;
    pthread_mutex_lock(&c->lock);
    if (ok) {
        for (int i = 0; i < N_GPU_SLOTS; i++)
            if (g->slots[i].state == SLOT_PENDING) g->slots[i].state = SLOT_FREE;
        sl->state = SLOT_PENDING;
        sl->src_w = g->scene_w;
        sl->src_h = g->scene_h;
        // ponta do cursor (a cena é a mesma, o recorte também)
        sl->cursor_known = 0;
        if (cur->cursor_known) {
            const int px = cur->cursor_px - g->scene_x, py = cur->cursor_py - g->scene_y;
            if (px >= 0 && py >= 0 && px < g->scene_w && py < g->scene_h) {
                sl->cursor_known = 1;
                sl->cursor_px = (int)((long long)px * g->out_w / g->scene_w);
                sl->cursor_py = (int)((long long)py * g->out_h / g->scene_h);
            }
        }
        c->fresh |= FRESH_GPU;
        pthread_cond_broadcast(&c->cond);
    } else {
        sl->state = SLOT_FREE;
        g->failed = 1;
    }
    pthread_mutex_unlock(&c->lock);
    return ok;
}

// Quem chama pega o slot pronto (sob o lock). 1 = tem quadro em *out.
static int gpu_take(struct cap_ctx *c, cap_frame *out) {
    struct gpu_path *g = c->gpu;
    out->preview = NULL;
    if (g->prev_front && (c->fresh & FRESH_PREVIEW)) {
        // cópia de quem chama: a thread do PipeWire pode trocar/realocar a frente a qualquer hora
        const size_t need = (size_t)g->prev_front_w * (size_t)g->prev_front_h * 4;
        if (g->prev_out_cap < need) {
            free(g->prev_out);
            g->prev_out = malloc(need);
            g->prev_out_cap = g->prev_out ? need : 0;
        }
        if (g->prev_out) {
            memcpy(g->prev_out, g->prev_front, need);
            out->preview = g->prev_out;
            out->preview_w = g->prev_front_w;
            out->preview_h = g->prev_front_h;
            out->preview_full = g->prev_front_full;
        }
    }
    struct gpu_slot *sl = NULL;
    for (int i = 0; i < N_GPU_SLOTS; i++)
        if (g->slots[i].state == SLOT_PENDING) sl = &g->slots[i];
    // tudo: um quadro pela CPU de antes de a placa ligar não vale mais, e se
    // o sinal dele ficasse, a espera em cap_next voltaria na hora (laço girando)
    c->fresh = 0;
    if (!sl) return 0;
    sl->state = SLOT_HELD;
    out->gpu = sl;
    out->gpu_dev = sl->dev;
    out->gpu_pitch = sl->pitch;
    out->gpu_src_w = sl->src_w;
    out->gpu_src_h = sl->src_h;
    out->data = NULL;
    out->width = sl->w;
    out->height = sl->h;
    out->stride = sl->pitch;
    out->format = CAP_RGBX;
    out->cursor_draw = 0; // já desenhado
    out->cursor_known = sl->cursor_known;
    out->cursor_px = sl->cursor_px;
    out->cursor_py = sl->cursor_py;
    return 1;
}

// Quem chama está parado (ninguém assistindo: pega um quadro a cada 200 ms)?
// Aí não vale a pena produzir quadro que ninguém vai pegar.
static int consumer_idle(struct cap_ctx *c) {
    return !c->waiting && now_us() - c->last_take_us > 150000;
}

static int gpu_upload_wanted(void);

// O caminho pela placa está mesmo produzindo os quadros (sob o lock)? Se o
// compositor manda memória comum (sem DMA-BUF) ou a placa falhou, o quadro
// vem pela CPU como sempre, e quem chama tem que ler ele de lá.
static int gpu_producing(struct cap_ctx *c) {
    if (!c->gpu_on || !c->gpu || c->gpu->failed) return 0;
    // conversor VA-API: o cursor nosso não dá pra pintar lá (vai pela CPU)
    if (c->gpu->va.ctx && c->soft_cursor && !c->cursor_apart) return 0;
    if (c->kind == KIND_X11) return gpu_upload_wanted();
    return c->src_kind == SRC_DMABUF || gpu_upload_wanted();
}

// TELINHA_GPU_UPLOAD=1: quadro em memória comum (X11, compositor sem DMA-BUF)
// também vai pelo caminho da placa (subido pra textura). Serve pros testes
// exercitarem o caminho da placa numa tela virtual; no uso normal, o quadro
// em memória comum segue pela CPU.
static int gpu_upload_wanted(void) {
    static int cached = -1;
    if (cached < 0) cached = getenv("TELINHA_GPU_UPLOAD") != NULL;
    return cached;
}

static int fill_cursor(struct cap_ctx *c, cap_frame *out);

// Quadro em memória comum (RGBX/BGRX, w*4 por linha) subido pra placa e
// produzido como os outros. Na thread do contexto EGL.
static int gpu_from_memory(struct cap_ctx *c, const uint8_t *pixels, int w, int h, int bgr, cap_frame *cur) {
    struct gpu_path *g = c->gpu;
    struct egl_state *e = c->egl;
    if (!g || !e || g->failed) return 0;
    if (gpu_gl_init(e, g) < 0) {
        gpu_fail(g, "GL (subida do quadro)");
        return 0;
    }
    if (g->src_w != w || g->src_h != h || !g->src_tex) {
        gpu_tex_alloc(e, &g->src_tex, w, h, pixels);
        g->src_w = w;
        g->src_h = h;
    } else {
        e->BindTexture(GL_TEXTURE_2D, g->src_tex);
        e->PixelStorei(GL_UNPACK_ALIGNMENT, 4);
        e->TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    }
    return gpu_produce(c, g->src_tex, w, h, bgr, cur);
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

    // calculado à parte e trocado de uma vez sob a trava: quem pega quadros
    // (gpu_producing) não pode ver um "SRC_32" de passagem no meio da troca
    int kind = SRC_32;
    const int dmabuf = c->egl && !c->dmabuf_off && spa_pod_find_prop(param, NULL, SPA_FORMAT_VIDEO_modifier) != NULL;
    if (c->egl) egl_forget(c->egl, NULL);
    if (c->gpu && c->gpu->va.ctx) c->gpu->va.forget(c->gpu->va.ctx, NULL);
    switch (c->info.format) {
    case SPA_VIDEO_FORMAT_RGBx:
    case SPA_VIDEO_FORMAT_RGBA: c->pw_format = CAP_RGBX; break;
    case SPA_VIDEO_FORMAT_RGB: c->pw_format = CAP_RGBX; kind = SRC_24; break;
    case SPA_VIDEO_FORMAT_BGR: c->pw_format = CAP_BGRX; kind = SRC_24; break;
    // 10 bits: palavra de 32 bits LE com o canal do byte 0 nos bits baixos
    case SPA_VIDEO_FORMAT_xRGB_210LE:
    case SPA_VIDEO_FORMAT_ARGB_210LE: c->pw_format = CAP_BGRX; kind = SRC_30; break;
    case SPA_VIDEO_FORMAT_xBGR_210LE:
    case SPA_VIDEO_FORMAT_ABGR_210LE: c->pw_format = CAP_RGBX; kind = SRC_30; break;
    default: c->pw_format = CAP_BGRX; break;
    }
    if (dmabuf) kind = SRC_DMABUF;
    pthread_mutex_lock(&c->lock);
    c->src_kind = kind;
    pthread_mutex_unlock(&c->lock);
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

// Intel/AMD: do DMA-BUF do compositor até um slot (superfície NV12 do
// conversor VA-API), sem GL nem CPU. 1 = tratou o quadro; 0 = falhou (cai pro
// caminho da CPU).
static int va_produce(struct cap_ctx *c, struct spa_buffer *buf, int sw, int sh) {
    struct gpu_path *g = c->gpu;
    cap_dmabuf src;
    memset(&src, 0, sizeof src);
    src.width = sw;
    src.height = sh;
    src.planes = buf->n_datas < 4 ? (int)buf->n_datas : 4;
    for (int i = 0; i < src.planes; i++) {
        struct spa_data *d = &buf->datas[i];
        if (d->type != SPA_DATA_DmaBuf || !d->chunk) return 0;
        src.fd[i] = (int)d->fd;
        src.offset[i] = (int)d->chunk->offset;
        src.pitch[i] = d->chunk->stride;
    }
    src.modifier = c->info.modifier;
    src.drm_fourcc = drm_format_of(c->info.format);
    pthread_mutex_lock(&c->lock);
    float crop[4];
    memcpy(crop, g->crop, sizeof crop);
    const int max_h = g->max_h, want_prev = g->want_preview, prev_max_w = g->preview_max_w;
    struct gpu_slot *sl = gpu_pick_slot(g);
    if (sl) sl->state = SLOT_RENDERING;
    pthread_mutex_unlock(&c->lock);
    int x = 0, y = 0, w = sw, h = sh, ow = sw, oh = sh;
    if (g->rect_fn) g->rect_fn(sw, sh, crop, max_h, &x, &y, &w, &h, &ow, &oh);
    if (ow < 2 || oh < 2 || w < 1 || h < 1) {
        gpu_unpick(c, sl);
        return 1;
    }
    int produced = 0;
    if (sl) {
        const int idx = (int)(sl - g->slots);
        if (g->va.convert(g->va.ctx, buf, &src, x, y, w, h, ow, oh, idx) != 0) {
            gpu_unpick(c, sl);
            gpu_fail(g, "VA-API (VPP)");
            return 0;
        }
        sl->dev = g->va.surface(g->va.ctx, idx);
        sl->pitch = 0;
        sl->w = ow;
        sl->h = oh;
        sl->src_w = w;
        sl->src_h = h;
        cap_frame cur = {0};
        cur.width = sw;
        cur.height = sh;
        fill_cursor(c, &cur);
        sl->cursor_known = 0;
        if (cur.cursor_known) {
            const int px = cur.cursor_px - x, py = cur.cursor_py - y;
            if (px >= 0 && py >= 0 && px < w && py < h) {
                sl->cursor_known = 1;
                sl->cursor_px = (int)((long long)px * ow / w);
                sl->cursor_py = (int)((long long)py * oh / h);
            }
        }
        produced = 1;
    }
    // prévia pequena (até 15 q/s)
    if (want_prev && now_us() - g->prev_last_us >= 66000) {
        g->prev_last_us = now_us();
        const int full = want_prev == 2;
        const int fw = full ? sw : w, fh = full ? sh : h;
        int pw = fw, ph = fh;
        if (prev_max_w > 0 && pw > prev_max_w) {
            pw = prev_max_w;
            ph = (int)((long long)fh * pw / fw);
        }
        pw &= ~1;
        ph &= ~1;
        const size_t need = (size_t)pw * ph * 4;
        if (pw >= 2 && ph >= 2 && g->prev_back_cap < need) {
            free(g->prev_back);
            g->prev_back = malloc(need);
            g->prev_back_cap = g->prev_back ? need : 0;
        }
        if (pw >= 2 && ph >= 2 && g->prev_back &&
            g->va.preview(g->va.ctx, buf, &src, full ? 0 : x, full ? 0 : y, fw, fh, pw, ph, g->prev_back) == 0) {
            g->prev_back_w = pw;
            g->prev_back_h = ph;
            g->prev_back_full = full;
            g->prev_new = 1;
        }
    }
    pthread_mutex_lock(&c->lock);
    if (sl && produced) {
        for (int i = 0; i < N_GPU_SLOTS; i++)
            if (g->slots[i].state == SLOT_PENDING) g->slots[i].state = SLOT_FREE;
        sl->state = SLOT_PENDING;
        c->fresh |= FRESH_GPU;
    }
    if (g->prev_new) {
        uint8_t *tb = g->prev_front;
        size_t tc = g->prev_front_cap;
        g->prev_front = g->prev_back;
        g->prev_front_cap = g->prev_back_cap;
        g->prev_back = tb;
        g->prev_back_cap = tc;
        g->prev_front_w = g->prev_back_w;
        g->prev_front_h = g->prev_back_h;
        g->prev_front_full = g->prev_back_full;
        g->prev_new = 0;
        c->fresh |= FRESH_PREVIEW;
    }
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->lock);
    return 1;
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
        pthread_mutex_lock(&c->lock);
        const int gpu_on = c->gpu_on && c->gpu && !c->gpu->failed;
        const int warming = gpu_on && c->gpu->warming;
        const int idle = consumer_idle(c) && !(gpu_on && c->gpu->want_preview);
        pthread_mutex_unlock(&c->lock);
        if (idle || warming) {
            // ninguém vai pegar: nem lê o quadro (pela CPU custava 3-5 ms cada)
            pw_stream_queue_buffer(c->stream, b);
            return;
        }
        if (gpu_on && c->gpu->va.ctx && w > 0 && hgt > 0 && !(h && (h->flags & SPA_META_HEADER_FLAG_CORRUPTED)) &&
            (!c->soft_cursor || c->cursor_apart)) {
            // Intel/AMD: o conversor VA-API faz tudo (recorte, escala, NV12)
            if (va_produce(c, buf, w, hgt)) {
                pw_stream_queue_buffer(c->stream, b);
                return;
            }
            // não deu: segue pela leitura do DMA-BUF (CPU) daqui pra frente
        } else if (gpu_on && !c->gpu->va.ctx && c->egl && w > 0 && hgt > 0 && !(h && (h->flags & SPA_META_HEADER_FLAG_CORRUPTED))) {
            // caminho pela placa: a textura importada vira a cena; nada vem pra CPU
            GLuint tex = egl_import(c->egl, buf, drm_format_of(c->info.format), c->info.modifier, w, hgt);
            if (tex) {
                cap_frame cur = {0};
                cur.width = w;
                cur.height = hgt;
                fill_cursor(c, &cur);
                gpu_produce(c, tex, w, hgt, 0, &cur);
                pw_stream_queue_buffer(c->stream, b);
                return;
            }
            // não importou: cai pro caminho de leitura abaixo (que renegocia)
        }
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
            c->fresh |= FRESH_CPU;
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
            const int gpu_on = c->gpu_on && c->gpu && !c->gpu->failed && gpu_upload_wanted();
            const int idle = consumer_idle(c) && !(gpu_on && c->gpu->want_preview);
            pthread_mutex_unlock(&c->lock);
            if (idle) {
                pw_stream_queue_buffer(c->stream, b);
                return;
            }
            if (gpu_on) {
                // memória compartilhada subida pra placa (só sob pedido: serve
                // pra testar o caminho pela placa sem compositor com DMA-BUF)
                if (c->staging_cap < need) {
                    free(c->staging);
                    c->staging = malloc(need);
                    c->staging_cap = c->staging ? need : 0;
                }
                if (c->staging) {
                    for (int y = 0; y < hgt; y++)
                        copy_row(c->staging + (size_t)y * w * 4, src + (size_t)y * stride, w, c->src_kind);
                    cap_frame cur = {0};
                    cur.width = w;
                    cur.height = hgt;
                    fill_cursor(c, &cur);
                    gpu_from_memory(c, c->staging, w, hgt, c->pw_format == CAP_BGRX, &cur);
                }
                pw_stream_queue_buffer(c->stream, b);
                return;
            }
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
                c->fresh |= FRESH_CPU;
                pthread_cond_broadcast(&c->cond);
            }
            pthread_mutex_unlock(&c->lock);
        }
    }
    pw_stream_queue_buffer(c->stream, b);
}

// Cursor desenhado por nós, no caminho pela placa: a cada 1/fps, se só o
// mouse mexeu (nenhum quadro novo), redesenha o cursor sobre a cena guardada.
static void on_cursor_timer(void *data, uint64_t expirations) {
    (void)expirations;
    struct cap_ctx *c = data;
    pthread_mutex_lock(&c->lock);
    const int gpu_on = gpu_producing(c) && c->gpu->have_scene;
    const int idle = consumer_idle(c);
    const int dirty = gpu_on && c->gpu->output_dirty && c->gpu->have_copy;
    pthread_mutex_unlock(&c->lock);
    if (!gpu_on || idle) return;
    cap_frame cur = {0};
    cur.width = c->gpu->scene_src_w;
    cur.height = c->gpu->scene_src_h;
    const int moved = fill_cursor(c, &cur);
    if (dirty) {
        // recorte/altura novos com a tela parada: refaz a partir da cópia da fonte
        gpu_produce(c, c->gpu->copy_tex, c->gpu->copy_w, c->gpu->copy_h, 0, &cur);
    } else if (moved && c->soft_cursor && !c->cursor_apart) {
        gpu_recompose(c, &cur);
    }
}

static void on_remove_buffer(void *data, struct pw_buffer *b) {
    struct cap_ctx *c = data;
    if (c->egl) egl_forget(c->egl, b->buffer);
    if (c->gpu && c->gpu->va.ctx) c->gpu->va.forget(c->gpu->va.ctx, b->buffer);
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

// Na thread do PipeWire: solta o caminho pela placa e o EGL.
static int gpu_and_egl_release(struct spa_loop *loop, bool async, uint32_t seq, const void *data, size_t size, void *user) {
    struct cap_ctx *c = user;
    gpu_gl_destroy(c->egl, c->gpu);
    return egl_release(loop, async, seq, data, size, c->egl);
}

static void gpu_free(struct cap_ctx *c) {
    if (!c->gpu) return;
    free(c->gpu->prev_back);
    free(c->gpu->prev_front);
    free(c->gpu->prev_out);
    free(c->gpu);
    c->gpu = NULL;
}

static void close_pipewire(struct cap_ctx *c) {
    if (c->gpu && c->gpu->warm_started) {
        pthread_join(c->gpu->warm_thread, NULL);
        c->gpu->warm_started = 0;
    }
    if (c->loop) pw_thread_loop_lock(c->loop);
    if (c->cursor_timer && c->loop) pw_loop_destroy_source(pw_thread_loop_get_loop(c->loop), c->cursor_timer);
    c->cursor_timer = NULL;
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->core) pw_core_disconnect(c->core);
    if (c->loop) {
        pw_thread_loop_unlock(c->loop);
        // o contexto EGL está ativo na thread do PipeWire: solta lá dentro
        if (c->egl) pw_loop_invoke(pw_thread_loop_get_loop(c->loop), gpu_and_egl_release, 0, NULL, 0, true, c);
        pw_thread_loop_stop(c->loop);
    }
    gpu_free(c);
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
    if (c->egl) {
        // caminho pela placa: redesenha o cursor (nosso) ou um recorte novo no ritmo do fps
        c->cursor_timer = pw_loop_add_timer(pw_thread_loop_get_loop(c->loop), on_cursor_timer, c);
        if (c->cursor_timer) {
            struct timespec iv = {0, (long)(1000000000L / (c->fps > 0 ? c->fps : 30))};
            pw_loop_update_timer(pw_thread_loop_get_loop(c->loop), c->cursor_timer, &iv, &iv, false);
        }
    }
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
    out->cursor_draw = !c->cursor_apart;
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
        c->waiting = 1;
        while (!c->fresh && !c->failed)
            if (pthread_cond_timedwait(&c->cond, &c->lock, &ts) == ETIMEDOUT) break;
        c->waiting = 0;
    }
    if (c->failed) {
        set_err(err, errlen, "%s", c->fail_msg);
        pthread_mutex_unlock(&c->lock);
        return -1;
    }
    if (gpu_producing(c)) {
        // caminho pela placa: o quadro é um slot (e/ou uma prévia nova)
        c->last_take_us = now_us();
        const int got = gpu_take(c, out);
        const int src_w = c->gpu->scene_src_w, src_h = c->gpu->scene_src_h;
        pthread_mutex_unlock(&c->lock);
        if (got) return 1;
        // cursor fora do vídeo: tela parada, mas o mouse mexeu (posição na fonte inteira)
        if (c->cursor_apart && c->soft_cursor && src_w > 0) {
            out->width = src_w;
            out->height = src_h;
            if (fill_cursor(c, out)) return 2;
        }
        return 0;
    }
    if (!(c->fresh & FRESH_CPU) || !c->pending) {
        c->fresh = 0;
        pthread_mutex_unlock(&c->lock);
        // tela parada, mas o cursor mexeu: reentrega o último quadro com o
        // cursor novo; com o cursor fora do vídeo, só a posição (2)
        if (c->soft_cursor && c->have_front && c->front) {
            out->data = c->front;
            out->width = c->front_w;
            out->height = c->front_h;
            out->stride = c->front_w * 4;
            out->format = c->front_fmt;
            const int moved = fill_cursor(c, out);
            if (c->redeliver) {
                c->redeliver = 0;
                return 1; // o quadro limpo (o anterior foi com o cursor pintado)
            }
            if (moved && c->cursor_apart) {
                out->data = NULL;
                return 2;
            }
            if (moved) return 1;
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
    c->last_take_us = now_us();
    c->front_w = c->pending_w;
    c->front_h = c->pending_h;
    c->front_fmt = c->pending_fmt;
    out->data = c->front;
    out->width = c->front_w;
    out->height = c->front_h;
    out->stride = c->front_w * 4;
    out->format = c->front_fmt;
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
    if (c->show_cursor && c->cursor_apart) {
        // cursor fora do vídeo: só a posição
        Window root, child;
        int rx, ry, wx, wy;
        unsigned int mask;
        if (XQueryPointer(c->dpy, c->root, &root, &child, &rx, &ry, &wx, &wy, &mask)) {
            out->cursor_known = 1;
            out->cursor_px = rx;
            out->cursor_py = ry;
        }
    } else if (c->show_cursor && c->has_xfixes) draw_x11_cursor(c, c->xbuf, out);
    out->data = c->xbuf;
    out->width = c->xw;
    out->height = c->xh;
    out->stride = c->xw * 4;
    out->format = CAP_BGRX;
    out->cursor_draw = 0;
    pthread_mutex_lock(&c->lock);
    const int gpu_on = gpu_producing(c);
    pthread_mutex_unlock(&c->lock);
    if (gpu_on) {
        // caminho pela placa (TELINHA_GPU_UPLOAD): o contexto EGL vive nesta thread
        cap_frame cur = *out;
        const int produced = gpu_from_memory(c, c->xbuf, c->xw, c->xh, 1, &cur);
        pthread_mutex_lock(&c->lock);
        c->last_take_us = now_us();
        const int got = produced ? gpu_take(c, out) : 0;
        pthread_mutex_unlock(&c->lock);
        if (!got && !c->gpu->failed) return 0;
        if (got) return 1;
        // a placa falhou: segue pela CPU (o quadro em xbuf continua válido)
    }
    return 1;
}

static void close_x11(struct cap_ctx *c) {
    // o caminho pela placa (TELINHA_GPU_UPLOAD) vive na thread de quem chama
    if (c->egl) {
        gpu_gl_destroy(c->egl, c->gpu);
        egl_release(NULL, false, 0, NULL, 0, c->egl);
        egl_destroy(c->egl);
        c->egl = NULL;
    }
    gpu_free(c);
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
    c->last_take_us = now_us(); // "parado" só depois de um tempo sem ninguém pegar quadro
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
    // nada de lixo de chamada anterior (quadro pela CPU não tem slot da placa)
    out->gpu = NULL;
    out->gpu_dev = 0;
    out->preview = NULL;
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

// ---------------------------------------------------------------------------
// Cursor fora do vídeo (ver capture.h)

int cap_set_cursor_apart(cap_ctx *c, int on) {
    if (!c || !c->show_cursor) return 0;
    // dá onde o cursor é desenhado por nós (Hyprland, X11); com o cursor
    // embutido pelo compositor (GNOME, KDE...) ele já vem pintado
    const int supported = c->kind == KIND_X11 || c->soft_cursor;
    if (!supported) return 0;
    pthread_mutex_lock(&c->lock);
    if (c->cursor_apart != (on != 0)) {
        c->cursor_apart = on != 0;
        c->redeliver = 1;
        if (c->gpu) c->gpu->output_dirty = 1; // refaz a saída sem (ou com) o cursor
    }
    pthread_mutex_unlock(&c->lock);
    return 1;
}

// ---------------------------------------------------------------------------
// Caminho pela placa (API; ver capture.h)

// Thread de preparação (contexto compartilhado): compila o shader, sobe o
// cursor e já cria e registra no CUDA as texturas de saída no tamanho que a
// tela tem agora. A thread do PipeWire pula os quadros até isso acabar.
static void *gpu_warm_thread(void *arg) {
    struct cap_ctx *c = arg;
    struct egl_state *e = c->egl;
    struct gpu_path *g = c->gpu;
    const uint64_t t0 = now_us();
    int ok = e->MakeCurrent(e->dpy, NULL, NULL, e->ctx_warm) && gpu_build_objects(e, g) == 0;
    if (ok) {
        pthread_mutex_lock(&c->lock);
        const int sw = (int)c->info.size.width, sh = (int)c->info.size.height, max_h = g->max_h;
        float crop[4];
        memcpy(crop, g->crop, sizeof crop);
        pthread_mutex_unlock(&c->lock);
        int x = 0, y = 0, w = sw, h = sh, ow = sw, oh = sh;
        if (sw > 0 && sh > 0 && g->rect_fn) g->rect_fn(sw, sh, crop, max_h, &x, &y, &w, &h, &ow, &oh);
        if (ow >= 2 && oh >= 2) {
            gpu_tex_alloc(e, &g->scene_tex, ow, oh, NULL);
            gpu_tex_alloc(e, &g->out_tex, ow, oh, NULL);
            gpu_tex_alloc(e, &g->copy_tex, sw, sh, NULL);
            g->copy_w = sw;
            g->copy_h = sh;
            e->Finish(); // objetos prontos antes de outro contexto usar
            g->out_res = cudagl_register(g->cg, g->out_tex, 0);
            if (g->out_res) {
                g->out_w = ow;
                g->out_h = oh;
                // buffers dos slots já no tamanho certo (alocar na hora custava ~30 ms
                // no primeiro uso de cada um, na thread do PipeWire)
                for (int i = 0; i < N_GPU_SLOTS; i++) {
                    struct gpu_slot *sl = &g->slots[i];
                    if (sl->dev) continue;
                    sl->dev = cudagl_alloc(g->cg, ow * 4, oh, &sl->pitch);
                    if (sl->dev) {
                        sl->w = ow;
                        sl->h = oh;
                    }
                }
            }
        }
        e->Finish();
    }
    e->MakeCurrent(e->dpy, NULL, NULL, NULL);
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: preparada em %.0f ms%s\n", (now_us() - t0) / 1000.0, ok ? "" : " (falhou: prepara na hora)");
    pthread_mutex_lock(&c->lock);
    g->warming = 0;
    pthread_mutex_unlock(&c->lock);
    return NULL;
}

int cap_gpu_enable(cap_ctx *c, void *cg, cap_rect_fn rect, cap_cursor_fn cursor) {
    if (!c || !cg || getenv("TELINHA_SEM_GPU_CAPTURA")) return 0;
    if (c->kind == KIND_X11 && !gpu_upload_wanted()) return 0;
    if (!c->egl && c->kind == KIND_X11) c->egl = egl_create(); // no X11 o EGL só existe pra isso
    if (!c->egl) return 0;
    pthread_mutex_lock(&c->lock);
    if (!c->gpu) {
        c->gpu = calloc(1, sizeof *c->gpu);
        if (!c->gpu) {
            pthread_mutex_unlock(&c->lock);
            return 0;
        }
        c->gpu->crop[2] = c->gpu->crop[3] = 1;
    }
    c->gpu->cg = cg;
    c->gpu->rect_fn = rect;
    c->gpu->cursor_fn = cursor;
    c->gpu->failed = 0;
    c->gpu_on = 1;
    // PipeWire: prepara numa thread à parte (a do PipeWire não pode parar)
    if (c->kind == KIND_PIPEWIRE && c->egl->ctx_warm && !c->gpu->warm_started) {
        c->gpu->warming = 1;
        c->gpu->warm_started = pthread_create(&c->gpu->warm_thread, NULL, gpu_warm_thread, c) == 0;
        if (!c->gpu->warm_started) c->gpu->warming = 0;
    }
    pthread_mutex_unlock(&c->lock);
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: ligada\n");
    return 1;
}

int cap_gpu_enable_d3d(cap_ctx *c, cap_rect_fn rect, char *err, int errlen) {
    (void)c;
    (void)rect;
    if (err && errlen > 0) err[0] = 0;
    return 0; // D3D11 é só no Windows
}

void *cap_d3d_device(cap_ctx *c) {
    (void)c;
    return NULL;
}

int cap_gpu_enable_va(cap_ctx *c, const cap_va_ops *ops, cap_rect_fn rect) {
    if (!c || !ops || !ops->ctx || c->kind != KIND_PIPEWIRE || !c->egl || getenv("TELINHA_SEM_GPU_CAPTURA")) return 0;
    pthread_mutex_lock(&c->lock);
    if (!c->gpu) {
        c->gpu = calloc(1, sizeof *c->gpu);
        if (!c->gpu) {
            pthread_mutex_unlock(&c->lock);
            return 0;
        }
        c->gpu->crop[2] = c->gpu->crop[3] = 1;
    }
    c->gpu->va = *ops;
    c->gpu->rect_fn = rect;
    c->gpu->failed = 0;
    c->gpu_on = 1;
    pthread_mutex_unlock(&c->lock);
    if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] captura pela placa: ligada (VA-API, VPP)\n");
    return 1;
}

void cap_gpu_disable(cap_ctx *c) {
    if (!c || !c->gpu) return;
    pthread_mutex_lock(&c->lock);
    c->gpu_on = 0;
    c->fresh = 0;
    for (int i = 0; i < N_GPU_SLOTS; i++)
        if (c->gpu->slots[i].state == SLOT_PENDING) c->gpu->slots[i].state = SLOT_FREE;
    pthread_mutex_unlock(&c->lock);
}

void cap_gpu_set_output(cap_ctx *c, const float crop[4], int max_height) {
    if (!c || !c->gpu) return;
    pthread_mutex_lock(&c->lock);
    if (memcmp(c->gpu->crop, crop, sizeof c->gpu->crop) != 0 || c->gpu->max_h != max_height) c->gpu->output_dirty = 1;
    memcpy(c->gpu->crop, crop, sizeof c->gpu->crop);
    c->gpu->max_h = max_height;
    pthread_mutex_unlock(&c->lock);
}

int cap_gpu_failed(cap_ctx *c) {
    if (!c || !c->gpu) return 0;
    pthread_mutex_lock(&c->lock);
    const int f = c->gpu->failed;
    pthread_mutex_unlock(&c->lock);
    return f;
}

void cap_gpu_gc(cap_ctx *c) {
    if (!c || !c->gpu) return;
    pthread_mutex_lock(&c->lock);
    for (int i = 0; i < c->gpu->n_retired; i++) cudagl_free(c->gpu->cg, c->gpu->retired[i]);
    c->gpu->n_retired = 0;
    pthread_mutex_unlock(&c->lock);
}

void cap_gpu_set_preview(cap_ctx *c, int want, int max_w) {
    if (!c || !c->gpu) return;
    pthread_mutex_lock(&c->lock);
    c->gpu->want_preview = want;
    c->gpu->preview_max_w = max_w;
    pthread_mutex_unlock(&c->lock);
}

void cap_gpu_release(cap_ctx *c, void *gpu) {
    if (!c || !c->gpu || !gpu) return;
    struct gpu_slot *sl = gpu;
    pthread_mutex_lock(&c->lock);
    if (sl->state == SLOT_HELD) sl->state = SLOT_FREE;
    pthread_mutex_unlock(&c->lock);
}
