// Câmera no Linux pelo PipeWire: as webcams aparecem como nós Video/Source
// (o WirePlumber cria pelo v4l2/libcamera). O quadro chega em YUYV, NV12,
// I420, RGB ou MJPEG e sai em BGRX. MJPEG (o que a maioria das webcams usa
// em 720p/30) é decodificado com a libturbojpeg, carregada em tempo de
// execução: sem ela, ficam só os formatos crus.
#define _GNU_SOURCE
#include "camera.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

static void set_err(char *err, int errlen, const char *msg) {
    if (err && errlen > 0) snprintf(err, errlen, "%s", msg);
}

// ---------------------------------------------------------------------------
// libturbojpeg (opcional)

typedef void *tjhandle;
enum { TJPF_BGRX = 3, TJFLAG_FASTDCT = 2048 };
static struct {
    int tried;
    tjhandle (*init)(void);
    int (*header)(tjhandle, const unsigned char *, unsigned long, int *, int *, int *, int *);
    int (*decompress)(tjhandle, const unsigned char *, unsigned long, unsigned char *, int, int, int, int, int);
    int (*destroy)(tjhandle);
} tj;
static pthread_mutex_t tj_lock = PTHREAD_MUTEX_INITIALIZER;

static int tj_load(void) {
    pthread_mutex_lock(&tj_lock);
    if (!tj.tried) {
        tj.tried = 1;
        void *lib = dlopen("libturbojpeg.so.0", RTLD_NOW | RTLD_LOCAL);
        if (lib) {
            tj.init = (tjhandle(*)(void))dlsym(lib, "tjInitDecompress");
            tj.header = (int (*)(tjhandle, const unsigned char *, unsigned long, int *, int *, int *, int *))dlsym(lib, "tjDecompressHeader3");
            tj.decompress = (int (*)(tjhandle, const unsigned char *, unsigned long, unsigned char *, int, int, int, int, int))dlsym(lib, "tjDecompress2");
            tj.destroy = (int (*)(tjhandle))dlsym(lib, "tjDestroy");
            if (!tj.init || !tj.header || !tj.decompress || !tj.destroy) tj.init = NULL;
        }
    }
    pthread_mutex_unlock(&tj_lock);
    return tj.init != NULL;
}

// ---------------------------------------------------------------------------
// Lista de câmeras: os nós Video/Source que são câmera (não captura de tela)

typedef struct {
    struct pw_thread_loop *loop;
    cam_device *out;
    int max, n;
    int done, seq;
} list_ctx;

static int is_camera(const struct spa_dict *props) {
    const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (!cls || strcmp(cls, "Video/Source") != 0) return 0;
    const char *role = spa_dict_lookup(props, PW_KEY_MEDIA_ROLE);
    if (role && strcmp(role, "Camera") == 0) return 1;
    const char *api = spa_dict_lookup(props, PW_KEY_DEVICE_API);
    if (api && (strcmp(api, "v4l2") == 0 || strcmp(api, "libcamera") == 0)) return 1;
    return 0;
}

static void on_global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version, const struct spa_dict *props) {
    (void)id;
    (void)permissions;
    (void)version;
    list_ctx *l = data;
    if (!props || strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || !is_camera(props) || l->n >= l->max) return;
    const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (!name) return;
    const char *desc = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
    if (!desc) desc = spa_dict_lookup(props, PW_KEY_NODE_NICK);
    if (!desc) desc = name;
    snprintf(l->out[l->n].id, sizeof l->out[l->n].id, "%s", name);
    snprintf(l->out[l->n].name, sizeof l->out[l->n].name, "%s", desc);
    l->n++;
}

static const struct pw_registry_events registry_events = {PW_VERSION_REGISTRY_EVENTS, .global = on_global};

static void on_core_done(void *data, uint32_t id, int seq) {
    list_ctx *l = data;
    if (id == PW_ID_CORE && seq == l->seq) {
        l->done = 1;
        pw_thread_loop_signal(l->loop, false);
    }
}

static const struct pw_core_events core_events = {PW_VERSION_CORE_EVENTS, .done = on_core_done};

int cam_list(cam_device *out, int max) {
    if (max <= 0) return 0;
    pw_init(NULL, NULL);
    list_ctx l = {.out = out, .max = max};
    l.loop = pw_thread_loop_new("telinha-cameras", NULL);
    if (!l.loop) return 0;
    struct pw_context *ctx = pw_context_new(pw_thread_loop_get_loop(l.loop), NULL, 0);
    if (!ctx || pw_thread_loop_start(l.loop) < 0) {
        if (ctx) pw_context_destroy(ctx);
        pw_thread_loop_destroy(l.loop);
        return 0;
    }
    pw_thread_loop_lock(l.loop);
    struct pw_core *core = pw_context_connect(ctx, NULL, 0);
    if (core) {
        struct pw_registry *reg = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
        struct spa_hook reg_listener, core_listener;
        spa_zero(reg_listener);
        spa_zero(core_listener);
        pw_registry_add_listener(reg, &reg_listener, &registry_events, &l);
        pw_core_add_listener(core, &core_listener, &core_events, &l);
        l.seq = pw_core_sync(core, PW_ID_CORE, 0);
        // a lista inteira chega antes do "done" do sync
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 2;
        while (!l.done)
            if (pw_thread_loop_timed_wait_full(l.loop, &ts) < 0) break;
        spa_hook_remove(&reg_listener);
        spa_hook_remove(&core_listener);
        pw_proxy_destroy((struct pw_proxy *)reg);
        pw_core_disconnect(core);
    }
    pw_thread_loop_unlock(l.loop);
    pw_thread_loop_stop(l.loop);
    pw_context_destroy(ctx);
    pw_thread_loop_destroy(l.loop);
    return l.n;
}

// ---------------------------------------------------------------------------
// Captura

struct cam_ctx {
    struct pw_thread_loop *loop;
    struct pw_context *pw_ctx;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    int want_w, want_h, want_fps;
    int mjpeg;
    struct spa_video_info_raw info; // formato cru combinado (se não for MJPEG)
    int mjpeg_w, mjpeg_h;
    tjhandle tj;

    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint8_t *pending; // último quadro (BGRX), escrito pela thread do PipeWire
    size_t pending_cap;
    int pending_w, pending_h;
    int fresh;
    int failed;
    char fail_msg[160];
    uint8_t *front;
    size_t front_cap;
};

static inline uint8_t clamp8(int v) {
    return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

// YUV (BT.601, faixa limitada, que é o que as webcams mandam) → BGRX
static inline void yuv_px(uint8_t *d, int y, int u, int v) {
    int c = (y - 16) * 298, dd = u - 128, e = v - 128;
    d[0] = clamp8((c + 516 * dd + 128) >> 8);
    d[1] = clamp8((c - 100 * dd - 208 * e + 128) >> 8);
    d[2] = clamp8((c + 409 * e + 128) >> 8);
    d[3] = 255;
}

static void convert_raw(struct cam_ctx *c, const uint8_t *src, int stride, uint8_t *dst, int w, int h) {
    switch (c->info.format) {
    case SPA_VIDEO_FORMAT_YUY2:
        for (int y = 0; y < h; y++) {
            const uint8_t *s = src + (size_t)y * stride;
            uint8_t *d = dst + (size_t)y * w * 4;
            for (int x = 0; x + 1 < w; x += 2, s += 4, d += 8) {
                yuv_px(d, s[0], s[1], s[3]);
                yuv_px(d + 4, s[2], s[1], s[3]);
            }
        }
        break;
    case SPA_VIDEO_FORMAT_NV12: {
        const uint8_t *uv = src + (size_t)stride * h;
        for (int y = 0; y < h; y++) {
            const uint8_t *sy = src + (size_t)y * stride;
            const uint8_t *suv = uv + (size_t)(y / 2) * stride;
            uint8_t *d = dst + (size_t)y * w * 4;
            for (int x = 0; x < w; x++) yuv_px(d + x * 4, sy[x], suv[x & ~1], suv[(x & ~1) + 1]);
        }
        break;
    }
    case SPA_VIDEO_FORMAT_I420: {
        const uint8_t *pu = src + (size_t)stride * h;
        const uint8_t *pv = pu + (size_t)(stride / 2) * (h / 2);
        for (int y = 0; y < h; y++) {
            const uint8_t *sy = src + (size_t)y * stride;
            const uint8_t *su = pu + (size_t)(y / 2) * (stride / 2);
            const uint8_t *sv = pv + (size_t)(y / 2) * (stride / 2);
            uint8_t *d = dst + (size_t)y * w * 4;
            for (int x = 0; x < w; x++) yuv_px(d + x * 4, sy[x], su[x / 2], sv[x / 2]);
        }
        break;
    }
    case SPA_VIDEO_FORMAT_RGBx:
    case SPA_VIDEO_FORMAT_RGBA:
        for (int y = 0; y < h; y++) {
            const uint8_t *s = src + (size_t)y * stride;
            uint8_t *d = dst + (size_t)y * w * 4;
            for (int x = 0; x < w; x++) {
                d[x * 4 + 0] = s[x * 4 + 2];
                d[x * 4 + 1] = s[x * 4 + 1];
                d[x * 4 + 2] = s[x * 4 + 0];
                d[x * 4 + 3] = 255;
            }
        }
        break;
    case SPA_VIDEO_FORMAT_RGB:
        for (int y = 0; y < h; y++) {
            const uint8_t *s = src + (size_t)y * stride;
            uint8_t *d = dst + (size_t)y * w * 4;
            for (int x = 0; x < w; x++) {
                d[x * 4 + 0] = s[x * 3 + 2];
                d[x * 4 + 1] = s[x * 3 + 1];
                d[x * 4 + 2] = s[x * 3 + 0];
                d[x * 4 + 3] = 255;
            }
        }
        break;
    default: // BGRx/BGRA
        for (int y = 0; y < h; y++) memcpy(dst + (size_t)y * w * 4, src + (size_t)y * stride, (size_t)w * 4);
        break;
    }
}

// Bytes que um quadro cru ocupa no buffer (pra não ler além do fim).
static size_t raw_size(uint32_t fmt, int stride, int h) {
    switch (fmt) {
    case SPA_VIDEO_FORMAT_NV12:
    case SPA_VIDEO_FORMAT_I420: return (size_t)stride * h * 3 / 2;
    default: return (size_t)stride * h;
    }
}

static int raw_bpp(uint32_t fmt) {
    switch (fmt) {
    case SPA_VIDEO_FORMAT_YUY2: return 2;
    case SPA_VIDEO_FORMAT_NV12:
    case SPA_VIDEO_FORMAT_I420: return 1;
    case SPA_VIDEO_FORMAT_RGB: return 3;
    default: return 4;
    }
}

static void fail(struct cam_ctx *c, const char *msg) {
    pthread_mutex_lock(&c->lock);
    c->failed = 1;
    snprintf(c->fail_msg, sizeof c->fail_msg, "%s", msg);
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->lock);
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    struct cam_ctx *c = data;
    if (!param || id != SPA_PARAM_Format) return;
    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0 || media_type != SPA_MEDIA_TYPE_video) return;
    if (media_subtype == SPA_MEDIA_SUBTYPE_mjpg) {
        struct spa_video_info_mjpg mj;
        if (spa_format_video_mjpg_parse(param, &mj) < 0) return;
        c->mjpeg = 1;
        c->mjpeg_w = (int)mj.size.width;
        c->mjpeg_h = (int)mj.size.height;
    } else if (media_subtype == SPA_MEDIA_SUBTYPE_raw) {
        if (spa_format_video_raw_parse(param, &c->info) < 0) return;
        c->mjpeg = 0;
    } else {
        return;
    }
    if (getenv("TELINHA_DEBUG"))
        fprintf(stderr, "[telinha] câmera: %dx%d %s\n", c->mjpeg ? c->mjpeg_w : (int)c->info.size.width,
                c->mjpeg ? c->mjpeg_h : (int)c->info.size.height, c->mjpeg ? "MJPEG" : "cru");
    uint8_t buffer[512];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b,
        SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 16),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    pw_stream_update_params(c->stream, params, 1);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    struct cam_ctx *c = data;
    if (state == PW_STREAM_STATE_ERROR) {
        char msg[160];
        snprintf(msg, sizeof msg, "câmera: %s", error ? error : "erro no PipeWire");
        fail(c, msg);
    }
}

static void on_process(void *data) {
    struct cam_ctx *c = data;
    struct pw_buffer *b = NULL, *nb;
    while ((nb = pw_stream_dequeue_buffer(c->stream)) != NULL) {
        if (b) pw_stream_queue_buffer(c->stream, b);
        b = nb;
    }
    if (!b) return;
    struct spa_data *d = &b->buffer->datas[0];
    if (!d->data || !d->chunk || d->chunk->size == 0 || (d->chunk->flags & SPA_CHUNK_FLAG_CORRUPTED)) {
        pw_stream_queue_buffer(c->stream, b);
        return;
    }
    const uint8_t *src = (const uint8_t *)d->data + d->chunk->offset;
    size_t avail = d->maxsize > d->chunk->offset ? d->maxsize - d->chunk->offset : 0;
    if (d->chunk->size < avail) avail = d->chunk->size;
    int w, h;
    if (c->mjpeg) {
        w = c->mjpeg_w;
        h = c->mjpeg_h;
        int jw = 0, jh = 0, sub = 0, cs = 0;
        if (!c->tj || tj.header(c->tj, src, (unsigned long)avail, &jw, &jh, &sub, &cs) != 0 || jw <= 0 || jh <= 0) {
            pw_stream_queue_buffer(c->stream, b);
            return;
        }
        w = jw;
        h = jh;
    } else {
        w = (int)c->info.size.width;
        h = (int)c->info.size.height;
    }
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) {
        pw_stream_queue_buffer(c->stream, b);
        return;
    }
    size_t need = (size_t)w * h * 4;
    pthread_mutex_lock(&c->lock);
    if (c->pending_cap < need) {
        free(c->pending);
        c->pending = malloc(need);
        c->pending_cap = c->pending ? need : 0;
    }
    int ok = 0;
    if (c->pending) {
        if (c->mjpeg) {
            ok = tj.decompress(c->tj, src, (unsigned long)avail, c->pending, w, w * 4, h, TJPF_BGRX, TJFLAG_FASTDCT) == 0;
        } else {
            int stride = d->chunk->stride > 0 ? d->chunk->stride : w * raw_bpp(c->info.format);
            if (raw_size(c->info.format, stride, h) <= avail) {
                convert_raw(c, src, stride, c->pending, w, h);
                ok = 1;
            }
        }
    }
    if (ok) {
        c->pending_w = w;
        c->pending_h = h;
        c->fresh = 1;
        pthread_cond_broadcast(&c->cond);
    }
    pthread_mutex_unlock(&c->lock);
    pw_stream_queue_buffer(c->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

static int build_formats(struct cam_ctx *c, struct spa_pod_builder *b, const struct spa_pod **params) {
    int n = 0;
    const struct spa_rectangle want = SPA_RECTANGLE((uint32_t)c->want_w, (uint32_t)c->want_h);
    const struct spa_fraction fps = SPA_FRACTION((uint32_t)c->want_fps, 1);
    // MJPEG primeiro (é como a webcam entrega 720p a 30 q/s; cru costuma
    // ser só 640x480 ou 720p a 10 q/s), se der pra decodificar
    if (c->tj) {
        params[n++] = spa_pod_builder_add_object(b,
            SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
            SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
            SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_mjpg),
            SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&want, &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(4096, 4096)),
            SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&fps, &SPA_FRACTION(0, 1), &SPA_FRACTION(120, 1)));
    }
    params[n++] = spa_pod_builder_add_object(b,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(9, SPA_VIDEO_FORMAT_YUY2, SPA_VIDEO_FORMAT_YUY2, SPA_VIDEO_FORMAT_NV12,
                                                        SPA_VIDEO_FORMAT_I420, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA,
                                                        SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_RGB),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&want, &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(4096, 4096)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&fps, &SPA_FRACTION(0, 1), &SPA_FRACTION(120, 1)));
    return n;
}

cam_ctx *cam_open(const char *id, int width, int height, int fps, char *err, int errlen) {
    cam_device devs[16];
    char target[160] = "";
    if (id && *id) {
        snprintf(target, sizeof target, "%s", id);
    } else {
        if (cam_list(devs, 16) <= 0) {
            set_err(err, errlen, "Nenhuma câmera encontrada.");
            return NULL;
        }
        snprintf(target, sizeof target, "%s", devs[0].id);
    }
    struct cam_ctx *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->want_w = width > 0 ? width : 1280;
    c->want_h = height > 0 ? height : 720;
    c->want_fps = fps > 0 ? fps : 30;
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->cond, NULL);
    if (tj_load()) c->tj = tj.init();

    pw_init(NULL, NULL);
    c->loop = pw_thread_loop_new("telinha-camera", NULL);
    c->pw_ctx = c->loop ? pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0) : NULL;
    if (!c->pw_ctx || pw_thread_loop_start(c->loop) < 0) {
        set_err(err, errlen, "Não consegui iniciar o PipeWire pra câmera.");
        cam_close(c);
        return NULL;
    }
    pw_thread_loop_lock(c->loop);
    c->core = pw_context_connect(c->pw_ctx, NULL, 0);
    if (!c->core) {
        pw_thread_loop_unlock(c->loop);
        set_err(err, errlen, "Não consegui conectar no PipeWire (ele está rodando?).");
        cam_close(c);
        return NULL;
    }
    c->stream = pw_stream_new(c->core, "telinha-camera",
                              pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                PW_KEY_MEDIA_ROLE, "Camera", PW_KEY_TARGET_OBJECT, target, NULL));
    pw_stream_add_listener(c->stream, &c->stream_listener, &stream_events, c);
    uint8_t buffer[2048];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[2];
    int n = build_formats(c, &b, params);
    int r = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                              PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, (uint32_t)n);
    pw_thread_loop_unlock(c->loop);
    if (r < 0) {
        set_err(err, errlen, "Não consegui abrir a câmera.");
        cam_close(c);
        return NULL;
    }
    return c;
}

int cam_next(cam_ctx *c, cap_frame *out, int timeout_ms, char *err, int errlen) {
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
        set_err(err, errlen, c->fail_msg);
        pthread_mutex_unlock(&c->lock);
        return -1;
    }
    if (!c->fresh) {
        pthread_mutex_unlock(&c->lock);
        return 0;
    }
    uint8_t *tmp = c->front;
    size_t tmp_cap = c->front_cap;
    c->front = c->pending;
    c->front_cap = c->pending_cap;
    c->pending = tmp;
    c->pending_cap = tmp_cap;
    c->fresh = 0;
    memset(out, 0, sizeof *out);
    out->data = c->front;
    out->width = c->pending_w;
    out->height = c->pending_h;
    out->stride = c->pending_w * 4;
    out->format = CAP_BGRX;
    pthread_mutex_unlock(&c->lock);
    return 1;
}

const char *cam_backend(cam_ctx *c) {
    return c->mjpeg ? "PipeWire (MJPEG)" : "PipeWire";
}

void cam_close(cam_ctx *c) {
    if (!c) return;
    if (c->loop) pw_thread_loop_stop(c->loop);
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->core) pw_core_disconnect(c->core);
    if (c->pw_ctx) pw_context_destroy(c->pw_ctx);
    if (c->loop) pw_thread_loop_destroy(c->loop);
    if (c->tj) tj.destroy(c->tj);
    free(c->pending);
    free(c->front);
    pthread_mutex_destroy(&c->lock);
    pthread_cond_destroy(&c->cond);
    free(c);
}
