// Linux: captura do som dos outros aplicativos — tudo menos o próprio
// telinha — ligando as saídas de áudio deles direto na nossa entrada, no
// grafo do PipeWire (o mesmo truque do venmic/Vesktop).
//
// Por quê: o monitor da saída padrão pega tudo que toca, inclusive o que o
// telinha toca (as vozes da sala e as transmissões assistidas). Quem assiste
// ouviria o próprio eco. Aqui cada aplicativo novo que começa a tocar é
// ligado na nossa entrada, menos os do nosso processo.
#include "audio_pw.h"

#include <stdint.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

// portas de todo o grafo (dispositivos com muitos canais somam rápido)
#define MAX_PORTS 4096
#define MAX_LINKS 1024
#define MAX_PENDING 256

enum { CH_NONE = 0, CH_LEFT = 1, CH_RIGHT = 2, CH_BOTH = 3 };

struct port {
    uint32_t id, node;
    int out;     // 1 = saída
    int channel; // CH_*
};

struct pwcap {
    struct pw_thread_loop *loop;
    struct pw_context *ctx;
    struct pw_core *core;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    uint32_t my_node; // nó da nossa captura (SPA_ID_INVALID até aparecer)
    long self_pid;
    // só um programa (vazio/0 = todos): pelo nome ou pela árvore de processos
    char only_app[64];
    long only_pid;
    char exclude[512]; // programas que ficam de fora (nomes separados por \n)

    // nós de aplicativos tocando áudio (fora o nosso processo)
    uint32_t apps[MAX_PORTS];
    int n_apps;
    // saídas de áudio ainda sendo identificadas: o anúncio do registro não traz
    // o PID; ele vem nas propriedades completas do nó (evento info)
    struct pending_node {
        struct pwcap *c;
        uint32_t id;
        struct pw_proxy *proxy;
        struct spa_hook listener;
    } pending[MAX_PENDING];
    int n_pending;
    struct port ports[MAX_PORTS];
    int n_ports;
    struct {
        uint32_t out_port, in_port;
        struct pw_proxy *proxy;
    } links[MAX_LINKS];
    int n_links;

    pwcap_fn fn;
    void *user;
};

static int channel_of(const char *ch) {
    if (!ch) return CH_BOTH;
    if (!strcmp(ch, "FL") || !strcmp(ch, "RL") || !strcmp(ch, "SL") || !strcmp(ch, "FLC") || !strcmp(ch, "FLW")) return CH_LEFT;
    if (!strcmp(ch, "FR") || !strcmp(ch, "RR") || !strcmp(ch, "SR") || !strcmp(ch, "FRC") || !strcmp(ch, "FRW")) return CH_RIGHT;
    if (!strcmp(ch, "LFE")) return CH_NONE;
    return CH_BOTH; // MONO, FC, ...
}

static int is_app(struct pwcap *c, uint32_t node) {
    for (int i = 0; i < c->n_apps; i++)
        if (c->apps[i] == node) return 1;
    return 0;
}

static int has_link(struct pwcap *c, uint32_t out_port, uint32_t in_port) {
    for (int i = 0; i < c->n_links; i++)
        if (c->links[i].out_port == out_port && c->links[i].in_port == in_port) return 1;
    return 0;
}

static void link_ports(struct pwcap *c, struct port *out, struct port *in) {
    if (has_link(c, out->id, in->id) || c->n_links == MAX_LINKS) return;
    char op[16], ip[16], on[16], in_n[16];
    snprintf(op, sizeof op, "%u", out->id);
    snprintf(ip, sizeof ip, "%u", in->id);
    snprintf(on, sizeof on, "%u", out->node);
    snprintf(in_n, sizeof in_n, "%u", in->node);
    struct pw_properties *props = pw_properties_new(PW_KEY_LINK_OUTPUT_NODE, on, PW_KEY_LINK_OUTPUT_PORT, op,
                                                    PW_KEY_LINK_INPUT_NODE, in_n, PW_KEY_LINK_INPUT_PORT, ip,
                                                    PW_KEY_OBJECT_LINGER, "false", NULL);
    struct pw_proxy *proxy = pw_core_create_object(c->core, "link-factory", PW_TYPE_INTERFACE_Link, PW_VERSION_LINK,
                                                   &props->dict, 0);
    pw_properties_free(props);
    if (!proxy) return;
    c->links[c->n_links].out_port = out->id;
    c->links[c->n_links].in_port = in->id;
    c->links[c->n_links].proxy = proxy;
    c->n_links++;
}

// Liga tudo o que dá pra ligar (chamado quando aparece nó/porta nova).
static void relink(struct pwcap *c) {
    if (c->my_node == SPA_ID_INVALID) return;
    for (int i = 0; i < c->n_ports; i++) {
        struct port *o = &c->ports[i];
        if (!o->out || o->channel == CH_NONE || !is_app(c, o->node)) continue;
        for (int j = 0; j < c->n_ports; j++) {
            struct port *in = &c->ports[j];
            if (in->out || in->node != c->my_node) continue;
            if (o->channel & in->channel) link_ports(c, o, in);
        }
    }
}

// `pid` é `root` ou descende dele? (sobe pelos pais em /proc)
static int descends_from(long pid, long root) {
    for (int depth = 0; pid > 1 && depth < 32; depth++) {
        if (pid == root) return 1;
        char path[64], buf[512];
        snprintf(path, sizeof path, "/proc/%ld/stat", pid);
        FILE *f = fopen(path, "r");
        if (!f) return 0;
        size_t n = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        buf[n] = 0;
        // "pid (nome) estado ppid ...": o nome pode ter espaço e parêntese
        char *close = strrchr(buf, ')');
        if (!close) return 0;
        char state;
        long ppid;
        if (sscanf(close + 1, " %c %ld", &state, &ppid) != 2) return 0;
        pid = ppid;
    }
    return 0;
}

// `name` está na lista (nomes separados por \n, sem diferença de maiúscula)?
static int in_list(const char *list, const char *name) {
    if (!name || !*name) return 0;
    const size_t n = strlen(name);
    for (const char *p = list; *p;) {
        const char *e = strchr(p, '\n');
        const size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == n && !strncasecmp(p, name, n)) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

// Esse nó de saída de áudio é do programa escolhido (e não de um excluído)?
static int wanted(struct pwcap *c, const struct spa_dict *props, long pid) {
    if (c->exclude[0] && !c->only_app[0] && !c->only_pid) {
        if (in_list(c->exclude, spa_dict_lookup(props, PW_KEY_APP_NAME))) return 0;
        if (in_list(c->exclude, spa_dict_lookup(props, PW_KEY_APP_PROCESS_BINARY))) return 0;
    }
    if (!c->only_app[0] && !c->only_pid) return 1;
    if (c->only_pid && pid > 0 && descends_from(pid, c->only_pid)) return 1;
    if (c->only_app[0]) {
        const char *name = spa_dict_lookup(props, PW_KEY_APP_NAME);
        const char *bin = spa_dict_lookup(props, PW_KEY_APP_PROCESS_BINARY);
        if (name && !strcasecmp(name, c->only_app)) return 1;
        if (bin && !strcasecmp(bin, c->only_app)) return 1;
    }
    return 0;
}

static void on_node_info(void *data, const struct pw_node_info *info);

static const struct pw_node_events node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = on_node_info,
};

static void forget_pending(struct pwcap *c, int i) {
    spa_hook_remove(&c->pending[i].listener);
    pw_proxy_destroy(c->pending[i].proxy);
    c->n_pending--;
    if (i != c->n_pending) {
        // move o último pro lugar (o hook aponta pra struct: refaz o listener)
        struct pending_node *last = &c->pending[c->n_pending];
        c->pending[i].id = last->id;
        c->pending[i].proxy = last->proxy;
        spa_hook_remove(&last->listener);
        pw_proxy_add_object_listener(last->proxy, &c->pending[i].listener, &node_events, &c->pending[i]);
    }
}

static void on_node_info(void *data, const struct pw_node_info *info) {
    struct pending_node *pn = data;
    struct pwcap *c = pn->c;
    if (!info->props || !(info->change_mask & PW_NODE_CHANGE_MASK_PROPS)) return;
    const char *pid = spa_dict_lookup(info->props, PW_KEY_APP_PROCESS_ID);
    const uint32_t id = pn->id;
    forget_pending(c, (int)(pn - c->pending));
    if (pid && atol(pid) == c->self_pid) return; // o próprio telinha: nunca
    if (!wanted(c, info->props, pid ? atol(pid) : 0)) return;
    if (c->n_apps < MAX_PORTS) c->apps[c->n_apps++] = id;
    relink(c);
}

static void on_global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version,
                      const struct spa_dict *props) {
    (void)permissions;
    (void)version;
    struct pwcap *c = data;
    if (!props) return;
    if (!strcmp(type, PW_TYPE_INTERFACE_Node)) {
        const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
        if (!cls || strcmp(cls, "Stream/Output/Audio") != 0 || c->n_pending == MAX_PENDING) return;
        // ainda não dá pra saber se é nosso: pede as propriedades completas
        struct pending_node *pn = &c->pending[c->n_pending];
        pn->proxy = pw_registry_bind(c->registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
        if (!pn->proxy) return;
        pn->c = c;
        pn->id = id;
        c->n_pending++;
        pw_proxy_add_object_listener(pn->proxy, &pn->listener, &node_events, pn);
    } else if (!strcmp(type, PW_TYPE_INTERFACE_Port)) {
        const char *node = spa_dict_lookup(props, PW_KEY_NODE_ID);
        const char *dir = spa_dict_lookup(props, PW_KEY_PORT_DIRECTION);
        if (!node || !dir || c->n_ports == MAX_PORTS) return;
        const char *mon = spa_dict_lookup(props, PW_KEY_PORT_MONITOR);
        if (mon && !strcmp(mon, "true")) return;
        struct port *p = &c->ports[c->n_ports++];
        p->id = id;
        p->node = (uint32_t)atol(node);
        p->out = !strcmp(dir, "out");
        p->channel = channel_of(spa_dict_lookup(props, PW_KEY_AUDIO_CHANNEL));
        relink(c);
    }
}

static void on_global_remove(void *data, uint32_t id) {
    struct pwcap *c = data;
    for (int i = 0; i < c->n_pending; i++)
        if (c->pending[i].id == id) forget_pending(c, i--);
    for (int i = 0; i < c->n_apps; i++)
        if (c->apps[i] == id) c->apps[i] = c->apps[--c->n_apps];
    for (int i = 0; i < c->n_ports; i++)
        if (c->ports[i].id == id) c->ports[i--] = c->ports[--c->n_ports];
    // links de portas que sumiram: o PipeWire já desfez; esquece o proxy
    for (int i = 0; i < c->n_links; i++) {
        int alive_out = 0, alive_in = 0;
        for (int j = 0; j < c->n_ports; j++) {
            if (c->ports[j].id == c->links[i].out_port) alive_out = 1;
            if (c->ports[j].id == c->links[i].in_port) alive_in = 1;
        }
        if (!alive_out || !alive_in) {
            pw_proxy_destroy(c->links[i].proxy);
            c->links[i--] = c->links[--c->n_links];
        }
    }
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = on_global,
    .global_remove = on_global_remove,
};

static void on_state(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old;
    (void)error;
    struct pwcap *c = data;
    if (state >= PW_STREAM_STATE_PAUSED && c->my_node == SPA_ID_INVALID) {
        c->my_node = pw_stream_get_node_id(c->stream);
        relink(c);
    }
}

static void on_process(void *data) {
    struct pwcap *c = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
    if (!b) return;
    struct spa_data *d = &b->buffer->datas[0];
    if (d->data && d->chunk && d->chunk->size > 0) {
        const float *s = (const float *)((uint8_t *)d->data + d->chunk->offset);
        c->fn(c->user, s, (int)(d->chunk->size / (sizeof(float) * 2)));
    }
    pw_stream_queue_buffer(c->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state,
    .process = on_process,
};

void pwcap_close(pwcap *c) {
    if (!c) return;
    if (c->loop) pw_thread_loop_lock(c->loop);
    while (c->n_pending > 0) forget_pending(c, c->n_pending - 1);
    for (int i = 0; i < c->n_links; i++) pw_proxy_destroy(c->links[i].proxy);
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->registry) pw_proxy_destroy((struct pw_proxy *)c->registry);
    if (c->core) pw_core_disconnect(c->core);
    if (c->loop) {
        pw_thread_loop_unlock(c->loop);
        pw_thread_loop_stop(c->loop);
    }
    if (c->ctx) pw_context_destroy(c->ctx);
    if (c->loop) pw_thread_loop_destroy(c->loop);
    free(c);
}

pwcap *pwcap_open(pwcap_fn fn, void *user, const char *app, uint32_t pid, const char *exclude, char *err, int errlen) {
    if (getenv("TELINHA_AUDIO_MONITOR")) return NULL; // força o jeito antigo (monitor)
    pw_init(NULL, NULL);
    struct pwcap *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->fn = fn;
    c->user = user;
    c->my_node = SPA_ID_INVALID;
    c->self_pid = (long)getpid();
    if (app) snprintf(c->only_app, sizeof c->only_app, "%s", app);
    c->only_pid = (long)pid;
    if (exclude) snprintf(c->exclude, sizeof c->exclude, "%s", exclude);
    c->loop = pw_thread_loop_new("telinha-audio", NULL);
    if (!c->loop) goto fail;
    c->ctx = pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0);
    if (!c->ctx || pw_thread_loop_start(c->loop) < 0) goto fail;
    pw_thread_loop_lock(c->loop);
    c->core = pw_context_connect(c->ctx, NULL, 0);
    if (!c->core) {
        pw_thread_loop_unlock(c->loop);
        if (err && errlen > 0) snprintf(err, errlen, "PipeWire indisponível");
        goto fail;
    }
    c->registry = pw_core_get_registry(c->core, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(c->registry, &c->registry_listener, &registry_events, c);

    // entrada nossa, que o gerenciador de sessão não liga em nada sozinho
    c->stream = pw_stream_new(c->core, "telinha (som dos aplicativos)",
                              pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                PW_KEY_NODE_NAME, "telinha-captura", PW_KEY_NODE_AUTOCONNECT, "false",
                                                PW_KEY_NODE_LATENCY, "480/48000", NULL));
    pw_stream_add_listener(c->stream, &c->stream_listener, &stream_events, c);
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    struct spa_audio_info_raw info = {.format = SPA_AUDIO_FORMAT_F32, .rate = 48000, .channels = 2,
                                      .position = {SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR}};
    const struct spa_pod *params[1] = {spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info)};
    int r = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                              PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, params, 1);
    pw_thread_loop_unlock(c->loop);
    if (r < 0) {
        if (err && errlen > 0) snprintf(err, errlen, "não consegui criar a captura no PipeWire");
        goto fail;
    }
    // a nossa porta ainda não é conhecida: ela marca o canal pela posição
    return c;
fail:
    pwcap_close(c);
    return NULL;
}

int pwcap_links(pwcap *c) {
    pw_thread_loop_lock(c->loop);
    int n = c->n_links;
    pw_thread_loop_unlock(c->loop);
    return n;
}

// ---------------------------------------------------------------------------
// Lista de quem está tocando som

struct lister {
    struct pw_thread_loop *loop;
    struct pw_core *core;
    struct pw_registry *registry;
    long self_pid;
    struct lnode {
        struct lister *l;
        struct pw_proxy *proxy;
        struct spa_hook listener;
    } nodes[MAX_PENDING];
    int n_nodes;
    audio_app *out;
    int max, n;
    int seq, done;
};

static void list_node_info(void *data, const struct pw_node_info *info) {
    struct lnode *ln = data;
    struct lister *l = ln->l;
    if (!info->props || l->n >= l->max) return;
    const char *pid = spa_dict_lookup(info->props, PW_KEY_APP_PROCESS_ID);
    if (pid && atol(pid) == l->self_pid) return;
    const char *name = spa_dict_lookup(info->props, PW_KEY_APP_NAME);
    if (!name || !*name) name = spa_dict_lookup(info->props, PW_KEY_APP_PROCESS_BINARY);
    if (!name || !*name) return;
    for (int i = 0; i < l->n; i++)
        if (!strcasecmp(l->out[i].name, name)) return;
    snprintf(l->out[l->n].name, sizeof l->out[l->n].name, "%s", name);
    l->out[l->n].pid = pid ? (uint32_t)atol(pid) : 0;
    l->n++;
}

static const struct pw_node_events list_node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = list_node_info,
};

static void list_global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version,
                        const struct spa_dict *props) {
    (void)permissions;
    (void)version;
    struct lister *l = data;
    if (!props || strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || l->n_nodes == MAX_PENDING) return;
    const char *cls = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (!cls || strcmp(cls, "Stream/Output/Audio") != 0) return;
    struct lnode *ln = &l->nodes[l->n_nodes];
    ln->proxy = pw_registry_bind(l->registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
    if (!ln->proxy) return;
    ln->l = l;
    l->n_nodes++;
    pw_proxy_add_object_listener(ln->proxy, &ln->listener, &list_node_events, ln);
}

static const struct pw_registry_events list_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = list_global,
};

static void list_core_done(void *data, uint32_t id, int seq) {
    struct lister *l = data;
    if (id == PW_ID_CORE && seq == l->seq) {
        l->done++;
        pw_thread_loop_signal(l->loop, false);
    }
}

static const struct pw_core_events list_core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = list_core_done,
};

int pwcap_list_apps(audio_app *out, int max) {
    if (max <= 0) return 0;
    pw_init(NULL, NULL);
    struct lister *l = calloc(1, sizeof *l);
    if (!l) return 0;
    l->out = out;
    l->max = max;
    l->self_pid = (long)getpid();
    l->loop = pw_thread_loop_new("telinha-apps", NULL);
    if (!l->loop) {
        free(l);
        return 0;
    }
    struct pw_context *ctx = pw_context_new(pw_thread_loop_get_loop(l->loop), NULL, 0);
    if (!ctx || pw_thread_loop_start(l->loop) < 0) {
        if (ctx) pw_context_destroy(ctx);
        pw_thread_loop_destroy(l->loop);
        free(l);
        return 0;
    }
    pw_thread_loop_lock(l->loop);
    l->core = pw_context_connect(ctx, NULL, 0);
    if (l->core) {
        struct spa_hook reg_listener, core_listener;
        spa_zero(reg_listener);
        spa_zero(core_listener);
        l->registry = pw_core_get_registry(l->core, PW_VERSION_REGISTRY, 0);
        pw_registry_add_listener(l->registry, &reg_listener, &list_registry_events, l);
        pw_core_add_listener(l->core, &core_listener, &list_core_events, l);
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 2;
        // 1ª volta: a lista de nós; 2ª: as propriedades de cada um (pedidas na 1ª)
        for (int round = 1; round <= 2; round++) {
            l->seq = pw_core_sync(l->core, PW_ID_CORE, 0);
            while (l->done < round)
                if (pw_thread_loop_timed_wait_full(l->loop, &ts) < 0) break;
            if (l->done < round) break;
        }
        for (int i = 0; i < l->n_nodes; i++) {
            spa_hook_remove(&l->nodes[i].listener);
            pw_proxy_destroy(l->nodes[i].proxy);
        }
        spa_hook_remove(&reg_listener);
        spa_hook_remove(&core_listener);
        pw_proxy_destroy((struct pw_proxy *)l->registry);
        pw_core_disconnect(l->core);
    }
    pw_thread_loop_unlock(l->loop);
    pw_thread_loop_stop(l->loop);
    pw_context_destroy(ctx);
    pw_thread_loop_destroy(l->loop);
    const int n = l->n;
    free(l);
    return n;
}
