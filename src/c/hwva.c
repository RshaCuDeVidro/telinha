// VA-API (Linux: Intel/AMD): decoder e encoder H.264.
//
// libva.so.2 e libva-drm.so.2 são carregadas em tempo de execução (o app tem
// que rodar em máquina sem libva); dos headers do libva só vêm os tipos. Cada
// decoder/encoder abre o primeiro /dev/dri/renderD* cujo driver faz o que
// precisa (num notebook com Intel + NVIDIA, cada placa é um renderD).
//
// Decoder: no VA-API o driver só faz a parte pesada (entropia, reconstrução);
// o resto do H.264 é daqui: SPS/PPS (com matrizes de quantização), cabeçalho
// das fatias, POC (tipos 0, 1 e 2), marcação das referências (janela
// deslizante e MMCO, inclusive longo prazo) e a lista de referências de cada
// fatia P (com as reordenações). Um quadro completo (Annex B) por chamada e a
// imagem sai na mesma chamada, em NV12 na memória da CPU: os fluxos não têm
// B-frames (openh264, NVENC e Media Foundation configurados por nós). Só
// quadros progressivos, 4:2:0 de 8 bits, sem FMO/ASO, fatias I e P; buraco no
// frame_num (quadro de referência perdido) é erro: quem chama pede um IDR.
//
// Encoder: I e P (cada P referencia só o anterior), GOP infinito (IDR só no
// começo e quando pedirem), CBR (ou VBR) com HRD curto e sem preencher bits,
// um quadro por vez (sem fila). SPS/PPS gerados aqui (cabeçalhos "packed")
// antes de cada IDR quando o driver aceita; senão o driver gera. Uma camada
// temporal só (temporal_layers = 2 é ignorado, como no Media Foundation:
// cada fabricante faz de um jeito). Não dá pra testar em toda placa: o
// vaenc_open codifica 3 quadros sintéticos e decodifica com o openh264; se a
// imagem não bater (PSNR < 30 dB) ele falha e o app fica com o openh264 em vez
// de mandar lixo pra quem assiste.
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <va/va.h>
#include <wels/codec_api.h>

#include "hwdec.h"
#include "hwenc.h"
#include "hwva.h"

#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#endif

static void set_err(char *err, int errlen, const char *fmt, const char *a) {
    if (err && errlen > 0) snprintf(err, errlen, fmt, a);
}

// ---------------------------------------------------------------- libva

typedef VADisplay (*get_display_drm_fn)(int fd);

#define VA_FUNCS(X)                                                                                                          \
    X(Initialize) X(Terminate) X(QueryVendorString) X(ErrorStr) X(MaxNumProfiles) X(MaxNumEntrypoints) X(QueryConfigProfiles) \
    X(QueryConfigEntrypoints) X(GetConfigAttributes) X(CreateConfig) X(DestroyConfig) X(CreateSurfaces) X(DestroySurfaces)  \
    X(CreateContext) X(DestroyContext) X(CreateBuffer) X(DestroyBuffer) X(MapBuffer) X(UnmapBuffer) X(BeginPicture)         \
    X(RenderPicture) X(EndPicture) X(SyncSurface) X(DeriveImage) X(CreateImage) X(DestroyImage) X(GetImage) X(PutImage)     \
    X(SetErrorCallback) X(SetInfoCallback)

static struct {
    pthread_once_t once;
    int ok;
    char err[160];
    get_display_drm_fn GetDisplayDRM;
#define DECL(n) __typeof__(va##n) *n;
    VA_FUNCS(DECL)
#undef DECL
} va = {PTHREAD_ONCE_INIT};

static void va_load(void) {
    // nunca descarrega: drivers de vídeo não gostam de dlclose
    void *h = dlopen("libva.so.2", RTLD_NOW | RTLD_LOCAL);
    void *hd = h ? dlopen("libva-drm.so.2", RTLD_NOW | RTLD_LOCAL) : NULL;
    if (!h || !hd) {
        snprintf(va.err, sizeof va.err, "libva não encontrada (pacote libva2/libva-drm2)");
        return;
    }
#define LOAD(n)                                                                     \
    if (!(va.n = (__typeof__(va.n))dlsym(h, "va" #n))) {                            \
        snprintf(va.err, sizeof va.err, "libva antiga demais (sem va%s)", #n);      \
        return;                                                                     \
    }
    VA_FUNCS(LOAD)
#undef LOAD
    va.GetDisplayDRM = (get_display_drm_fn)dlsym(hd, "vaGetDisplayDRM");
    if (!va.GetDisplayDRM) {
        snprintf(va.err, sizeof va.err, "libva-drm sem vaGetDisplayDRM");
        return;
    }
    va.ok = 1;
}

typedef struct {
    int fd;
    VADisplay dpy;
} va_dev;

// Confere se o driver aberto serve; 1 = serve (senão o motivo em why).
typedef int (*dev_check_fn)(VADisplay dpy, char *why, int whylen);

static void va_close_dev(va_dev *dev) {
    if (dev->dpy) va.Terminate(dev->dpy);
    if (dev->fd >= 0) close(dev->fd);
    dev->dpy = NULL;
    dev->fd = -1;
}

static int va_open_dev(va_dev *dev, dev_check_fn check, char *err, int errlen) {
    dev->fd = -1;
    dev->dpy = NULL;
    pthread_once(&va.once, va_load);
    if (!va.ok) {
        set_err(err, errlen, "%s", va.err);
        return -1;
    }
    char why[200] = "nenhuma placa de vídeo (/dev/dri/renderD*)";
    for (int i = 128; i < 136; i++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/dri/renderD%d", i);
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        VADisplay dpy = va.GetDisplayDRM(fd);
        if (!dpy) {
            close(fd);
            continue;
        }
        // o libva escreve "libva info: ..." no stderr a cada vaInitialize
        if (!getenv("TELINHA_DEBUG")) {
            va.SetErrorCallback(dpy, NULL, NULL);
            va.SetInfoCallback(dpy, NULL, NULL);
        }
        int major = 0, minor = 0;
        if (va.Initialize(dpy, &major, &minor) != VA_STATUS_SUCCESS) {
            snprintf(why, sizeof why, "%s: driver VA-API não carregou", path);
            va.Terminate(dpy);
            close(fd);
            continue;
        }
        char w[160] = "";
        if (!check(dpy, w, sizeof w)) {
            const char *vendor = va.QueryVendorString(dpy);
            snprintf(why, sizeof why, "%s (%.60s): %s", path, vendor ? vendor : "?", w);
            va.Terminate(dpy);
            close(fd);
            continue;
        }
        dev->fd = fd;
        dev->dpy = dpy;
        return 0;
    }
    set_err(err, errlen, "%s", why);
    return -1;
}

// Entrypoints do perfil (0 se não suportado)
static int va_entrypoints(VADisplay dpy, VAProfile prof, VAEntrypoint *eps, int max) {
    int n = va.MaxNumEntrypoints(dpy);
    if (n <= 0) return 0;
    VAEntrypoint *tmp = calloc((size_t)n, sizeof *tmp);
    if (!tmp) return 0;
    int got = 0;
    if (va.QueryConfigEntrypoints(dpy, prof, tmp, &got) != VA_STATUS_SUCCESS) got = 0;
    if (got > max) got = max;
    memcpy(eps, tmp, (size_t)got * sizeof *tmp);
    free(tmp);
    return got;
}

static int va_has(VADisplay dpy, VAProfile prof, VAEntrypoint ep) {
    VAEntrypoint eps[32];
    int n = va_entrypoints(dpy, prof, eps, 32);
    for (int i = 0; i < n; i++)
        if (eps[i] == ep) return 1;
    return 0;
}

// "Intel iHD driver ...", "Mesa Gallium driver ... for AMD Radeon ..." -> fabricante
static const char *vendor_short(const char *v) {
    if (!v) return "?";
    if (strstr(v, "Intel")) return "Intel";
    if (strstr(v, "AMD") || strstr(v, "Radeon") || strstr(v, "radeonsi")) return "AMD";
    if (strstr(v, "NVIDIA") || strstr(v, "NVDEC") || strstr(v, "nouveau")) return "NVIDIA";
    return NULL;
}

// ------------------------------------------------- cópia da memória do vídeo

// Imagens mapeadas do vídeo costumam ser memória sem cache (write-combining):
// ler com memcpy normal é ~10x mais lento. MOVNTDQA (SSE4.1) lê de 16 em 16
// bytes direto pra um buffer pequeno (no cache) e de lá vai pro destino.
#if defined(__x86_64__)
static int cpu_sse41(void) {
    static int v = -1;
    if (v < 0) {
        unsigned a, b, c, d;
        v = __get_cpuid(1, &a, &b, &c, &d) && (c & bit_SSE4_1) ? 1 : 0;
    }
    return v;
}

__attribute__((target("sse4.1"))) static void copy_row_stream(uint8_t *dst, const uint8_t *src, size_t n, uint8_t *bounce) {
    // alinha pra baixo: os bytes lidos a mais ficam na mesma página (nunca falham)
    const uintptr_t mis = (uintptr_t)src & 15;
    const uint8_t *s = src - mis;
    const size_t chunks = (n + mis + 15) / 16;
    __m128i *b = (__m128i *)bounce;
    for (size_t i = 0; i < chunks; i++) b[i] = _mm_stream_load_si128((__m128i *)(s + i * 16));
    memcpy(dst, bounce + mis, n);
}
#endif

// bounce: alinhado em 16 bytes, com pelo menos w + 32 bytes
static void copy_plane(uint8_t *dst, size_t dpitch, const uint8_t *src, size_t spitch, size_t w, size_t h, uint8_t *bounce) {
#if defined(__x86_64__)
    if (bounce && cpu_sse41()) {
        for (size_t y = 0; y < h; y++) copy_row_stream(dst + y * dpitch, src + y * spitch, w, bounce);
        return;
    }
#endif
    for (size_t y = 0; y < h; y++) memcpy(dst + y * dpitch, src + y * spitch, w);
}

// ----------------------------------------------------- leitura de bits (RBSP)

typedef struct {
    const uint8_t *p;
    int len; // bytes
    int pos; // bits
    int err;
} br;

static uint32_t br_u(br *b, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        if (b->pos >= b->len * 8) {
            b->err = 1;
            return 0;
        }
        v = (v << 1) | ((b->p[b->pos >> 3] >> (7 - (b->pos & 7))) & 1u);
        b->pos++;
    }
    return v;
}

static uint32_t br_ue(br *b) {
    int zeros = 0;
    while (!br_u(b, 1)) {
        if (b->err || ++zeros > 31) {
            b->err = 1;
            return 0;
        }
    }
    if (!zeros) return 0;
    return ((1u << zeros) - 1) + br_u(b, zeros);
}

static int32_t br_se(br *b) {
    uint32_t k = br_ue(b);
    return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

// more_rbsp_data(): ainda tem algo antes do bit de parada?
static int br_more(br *b) {
    int last = b->len * 8 - 1;
    while (last >= 0 && !((b->p[last >> 3] >> (7 - (last & 7))) & 1)) last--;
    return b->pos < last;
}

// Tira os bytes de prevenção (00 00 03 -> 00 00). Retorna o tamanho.
static int unescape(const uint8_t *src, int n, uint8_t *dst) {
    int o = 0, zeros = 0;
    for (int i = 0; i < n; i++) {
        if (zeros >= 2 && src[i] == 3) {
            zeros = 0;
            continue;
        }
        dst[o++] = src[i];
        zeros = src[i] == 0 ? zeros + 1 : 0;
    }
    return o;
}

static const uint8_t *find_sc(const uint8_t *p, const uint8_t *end) {
    for (; p + 3 <= end; p++)
        if (p[0] == 0 && p[1] == 0 && p[2] == 1) return p;
    return end;
}

// --------------------------------------------------------------- SPS / PPS

static const uint8_t zz4[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
static const uint8_t zz8[64] = {0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
                                41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
                                30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};
// Tabelas 7-3 e 7-4 (na ordem zigue-zague)
static const uint8_t def4_intra[16] = {6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42};
static const uint8_t def4_inter[16] = {10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34};
static const uint8_t def8_intra[64] = {6,  10, 10, 13, 11, 13, 16, 16, 16, 16, 18, 18, 18, 18, 18, 23, 23, 23, 23, 23, 23, 25,
                                       25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 31,
                                       31, 31, 31, 31, 31, 33, 33, 33, 33, 33, 36, 36, 36, 36, 38, 38, 38, 40, 40, 42};
static const uint8_t def8_inter[64] = {9,  13, 13, 15, 13, 15, 17, 17, 17, 17, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 22,
                                       22, 22, 22, 22, 22, 22, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 27,
                                       27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 30, 30, 30, 30, 32, 32, 32, 33, 33, 35};

// as listas ficam em ordem raster (é o que o VAIQMatrixBufferH264 espera)
static void default4(uint8_t *out, int intra) {
    for (int j = 0; j < 16; j++) out[zz4[j]] = intra ? def4_intra[j] : def4_inter[j];
}
static void default8(uint8_t *out, int intra) {
    for (int j = 0; j < 64; j++) out[zz8[j]] = intra ? def8_intra[j] : def8_inter[j];
}

// scaling_list(); 1 = "use a lista padrão" (useDefaultScalingMatrixFlag)
static int scaling_list(br *b, uint8_t *out, int size) {
    const uint8_t *scan = size == 16 ? zz4 : zz8;
    int last = 8, next = 8;
    for (int j = 0; j < size; j++) {
        if (next) {
            const int delta = br_se(b);
            next = ((last + delta) % 256 + 256) % 256;
            if (j == 0 && next == 0) return 1;
        }
        out[scan[j]] = (uint8_t)(next ? next : last);
        last = out[scan[j]];
    }
    return 0;
}

typedef struct {
    int profile_idc, constraint, level_idc, id;
    int chroma_format_idc, separate_colour_plane, bit_depth_luma, bit_depth_chroma;
    int scaling_present;
    uint8_t sl4[6][16], sl8[6][64]; // já com a regra A aplicada (ou planas)
    int log2_max_frame_num, poc_type, log2_max_poc_lsb, delta_pic_order_always_zero;
    int offset_for_non_ref_pic, offset_for_top_to_bottom_field, num_ref_frames_in_poc_cycle;
    int offset_for_ref_frame[256];
    int max_num_ref_frames, gaps_allowed;
    int mb_w, map_h, frame_mbs_only, mbaff, direct_8x8;
    int crop_l, crop_r, crop_t, crop_b; // em pixels
    // VUI (só pra conferir o que o encoder gera; -1 = ausente)
    int vui, vui_full_range, vui_primaries, vui_transfer, vui_matrix;
    uint32_t vui_num_units, vui_time_scale;
    int vui_mv_over_bounds, vui_reorder, vui_max_dec;
} h264_sps;

typedef struct {
    int id, sps_id, cabac, bottom_field_pic_order, num_ref_idx_default[2];
    int weighted_pred, weighted_bipred_idc, pic_init_qp, pic_init_qs, chroma_qp_index_offset, second_chroma_qp_index_offset;
    int deblocking_filter_control_present, constrained_intra_pred, redundant_pic_cnt_present;
    int transform_8x8, scaling_present;
    int sl_present[12], sl_default[12];
    uint8_t sl4[6][16], sl8[6][64];
} h264_pps;

static void skip_hrd(br *b) {
    const uint32_t n = br_ue(b) + 1;
    br_u(b, 8); // bit_rate_scale, cpb_size_scale
    for (uint32_t i = 0; i < n && i < 32 && !b->err; i++) {
        br_ue(b);
        br_ue(b);
        br_u(b, 1);
    }
    br_u(b, 20); // 4 campos de 5 bits
}

static void parse_vui(br *b, h264_sps *s) {
    s->vui = 1;
    if (br_u(b, 1) && br_u(b, 8) == 255) br_u(b, 32); // aspect_ratio_idc, sar
    if (br_u(b, 1)) br_u(b, 1);                       // overscan
    if (br_u(b, 1)) {
        br_u(b, 3); // video_format
        s->vui_full_range = (int)br_u(b, 1);
        if (br_u(b, 1)) {
            s->vui_primaries = (int)br_u(b, 8);
            s->vui_transfer = (int)br_u(b, 8);
            s->vui_matrix = (int)br_u(b, 8);
        }
    }
    if (br_u(b, 1)) {
        br_ue(b);
        br_ue(b);
    }
    if (br_u(b, 1)) {
        s->vui_num_units = br_u(b, 32);
        s->vui_time_scale = br_u(b, 32);
        br_u(b, 1);
    }
    const int nal_hrd = (int)br_u(b, 1);
    if (nal_hrd) skip_hrd(b);
    const int vcl_hrd = (int)br_u(b, 1);
    if (vcl_hrd) skip_hrd(b);
    if (nal_hrd || vcl_hrd) br_u(b, 1);
    br_u(b, 1); // pic_struct_present_flag
    if (br_u(b, 1)) {
        s->vui_mv_over_bounds = (int)br_u(b, 1);
        br_ue(b);
        br_ue(b);
        br_ue(b);
        br_ue(b);
        s->vui_reorder = (int)br_ue(b);
        s->vui_max_dec = (int)br_ue(b);
    }
}

// b posicionado depois do byte do NAL. 0 = ok.
static int parse_sps(br *b, h264_sps *s) {
    memset(s, 0, sizeof *s);
    s->vui_full_range = s->vui_primaries = s->vui_transfer = s->vui_matrix = -1;
    s->vui_mv_over_bounds = s->vui_reorder = s->vui_max_dec = -1;
    s->profile_idc = (int)br_u(b, 8);
    s->constraint = (int)br_u(b, 8);
    s->level_idc = (int)br_u(b, 8);
    s->id = (int)br_ue(b);
    if (s->id > 31) return -1;
    s->chroma_format_idc = 1;
    s->bit_depth_luma = s->bit_depth_chroma = 8;
    for (int i = 0; i < 6; i++) memset(s->sl4[i], 16, 16), memset(s->sl8[i], 16, 64);
    const int p = s->profile_idc;
    if (p == 100 || p == 110 || p == 122 || p == 244 || p == 44 || p == 83 || p == 86 || p == 118 || p == 128 || p == 138 ||
        p == 139 || p == 134 || p == 135) {
        s->chroma_format_idc = (int)br_ue(b);
        if (s->chroma_format_idc > 3) return -1;
        if (s->chroma_format_idc == 3) s->separate_colour_plane = (int)br_u(b, 1);
        s->bit_depth_luma = 8 + (int)br_ue(b);
        s->bit_depth_chroma = 8 + (int)br_ue(b);
        br_u(b, 1); // qpprime_y_zero_transform_bypass_flag
        s->scaling_present = (int)br_u(b, 1);
        if (s->scaling_present) {
            const int n = s->chroma_format_idc != 3 ? 8 : 12;
            for (int i = 0; i < n; i++) {
                const int present = (int)br_u(b, 1);
                if (i < 6) {
                    // regra A: 0 e 3 caem na padrão, as outras repetem a anterior
                    if (present) {
                        if (scaling_list(b, s->sl4[i], 16)) default4(s->sl4[i], i < 3);
                    } else if (i == 0 || i == 3)
                        default4(s->sl4[i], i == 0);
                    else
                        memcpy(s->sl4[i], s->sl4[i - 1], 16);
                } else {
                    const int k = i - 6;
                    if (present) {
                        if (scaling_list(b, s->sl8[k], 64)) default8(s->sl8[k], k % 2 == 0);
                    } else if (k < 2)
                        default8(s->sl8[k], k == 0);
                    else
                        memcpy(s->sl8[k], s->sl8[k - 2], 64);
                }
            }
            for (int k = n - 6; k < 6; k++) memcpy(s->sl8[k], s->sl8[k - 2], 64);
        }
    }
    s->log2_max_frame_num = 4 + (int)br_ue(b);
    if (s->log2_max_frame_num > 16) return -1;
    s->poc_type = (int)br_ue(b);
    if (s->poc_type == 0) {
        s->log2_max_poc_lsb = 4 + (int)br_ue(b);
        if (s->log2_max_poc_lsb > 16) return -1;
    } else if (s->poc_type == 1) {
        s->delta_pic_order_always_zero = (int)br_u(b, 1);
        s->offset_for_non_ref_pic = br_se(b);
        s->offset_for_top_to_bottom_field = br_se(b);
        s->num_ref_frames_in_poc_cycle = (int)br_ue(b);
        if (s->num_ref_frames_in_poc_cycle > 255) return -1;
        for (int i = 0; i < s->num_ref_frames_in_poc_cycle; i++) s->offset_for_ref_frame[i] = br_se(b);
    } else if (s->poc_type != 2)
        return -1;
    s->max_num_ref_frames = (int)br_ue(b);
    if (s->max_num_ref_frames > 16) return -1;
    s->gaps_allowed = (int)br_u(b, 1);
    s->mb_w = 1 + (int)br_ue(b);
    s->map_h = 1 + (int)br_ue(b);
    if (s->mb_w > 1024 || s->map_h > 1024) return -1;
    s->frame_mbs_only = (int)br_u(b, 1);
    if (!s->frame_mbs_only) s->mbaff = (int)br_u(b, 1);
    s->direct_8x8 = (int)br_u(b, 1);
    if (br_u(b, 1)) {
        // unidades de corte: 2 pixels na horizontal, 2 (ou 4 com campos) na vertical (4:2:0)
        const int cx = 2, cy = 2 * (2 - s->frame_mbs_only);
        s->crop_l = cx * (int)br_ue(b);
        s->crop_r = cx * (int)br_ue(b);
        s->crop_t = cy * (int)br_ue(b);
        s->crop_b = cy * (int)br_ue(b);
        if (s->crop_l + s->crop_r >= s->mb_w * 16 || s->crop_t + s->crop_b >= s->map_h * 16 * (2 - s->frame_mbs_only)) return -1;
    }
    if (b->err) return -1;
    if (br_u(b, 1)) {
        // a VUI não faz falta pra decodificar: erro nela não invalida o SPS
        parse_vui(b, s);
        b->err = 0;
    }
    return 0;
}

static int parse_pps(br *b, h264_pps *p, h264_sps *const *sps_tab) {
    memset(p, 0, sizeof *p);
    p->id = (int)br_ue(b);
    p->sps_id = (int)br_ue(b);
    if (p->id > 255 || p->sps_id > 31) return -1;
    p->cabac = (int)br_u(b, 1);
    p->bottom_field_pic_order = (int)br_u(b, 1);
    if (br_ue(b) != 0) return -1; // grupos de fatias (FMO): nenhum encoder nosso usa e o VA-API não suporta
    p->num_ref_idx_default[0] = 1 + (int)br_ue(b);
    p->num_ref_idx_default[1] = 1 + (int)br_ue(b);
    if (p->num_ref_idx_default[0] > 32 || p->num_ref_idx_default[1] > 32) return -1;
    p->weighted_pred = (int)br_u(b, 1);
    p->weighted_bipred_idc = (int)br_u(b, 2);
    p->pic_init_qp = 26 + br_se(b);
    p->pic_init_qs = 26 + br_se(b);
    p->chroma_qp_index_offset = br_se(b);
    p->deblocking_filter_control_present = (int)br_u(b, 1);
    p->constrained_intra_pred = (int)br_u(b, 1);
    p->redundant_pic_cnt_present = (int)br_u(b, 1);
    p->second_chroma_qp_index_offset = p->chroma_qp_index_offset;
    if (b->err) return -1;
    if (br_more(b)) {
        p->transform_8x8 = (int)br_u(b, 1);
        p->scaling_present = (int)br_u(b, 1);
        if (p->scaling_present) {
            const h264_sps *s = sps_tab[p->sps_id];
            const int chroma = s ? s->chroma_format_idc : 1;
            const int n = 6 + (chroma != 3 ? 2 : 6) * p->transform_8x8;
            for (int i = 0; i < n; i++) {
                p->sl_present[i] = (int)br_u(b, 1);
                if (p->sl_present[i])
                    p->sl_default[i] = i < 6 ? scaling_list(b, p->sl4[i], 16) : scaling_list(b, p->sl8[i - 6], 64);
            }
        }
        p->second_chroma_qp_index_offset = br_se(b);
    }
    return b->err ? -1 : 0;
}

// Matrizes do quadro (8.5.6): as do PPS com as regras de reserva A/B.
static void resolve_scaling(const h264_sps *s, const h264_pps *p, uint8_t sl4[6][16], uint8_t sl8[2][64]) {
    if (!p->scaling_present) {
        memcpy(sl4, s->sl4, 6 * 16);
        memcpy(sl8[0], s->sl8[0], 64);
        memcpy(sl8[1], s->sl8[1], 64);
        return;
    }
    // regra A (SPS sem matriz): listas ausentes viram a padrão; regra B: viram as do SPS
    const int rule_a = !s->scaling_present;
    for (int i = 0; i < 6; i++) {
        if (p->sl_present[i]) {
            if (p->sl_default[i]) default4(sl4[i], i < 3);
            else memcpy(sl4[i], p->sl4[i], 16);
        } else if (i == 0 || i == 3) {
            if (rule_a) default4(sl4[i], i == 0);
            else memcpy(sl4[i], s->sl4[i], 16);
        } else
            memcpy(sl4[i], sl4[i - 1], 16);
    }
    for (int k = 0; k < 2; k++) {
        if (p->sl_present[6 + k]) {
            if (p->sl_default[6 + k]) default8(sl8[k], k == 0);
            else memcpy(sl8[k], p->sl8[k], 64);
        } else if (rule_a)
            default8(sl8[k], k == 0);
        else
            memcpy(sl8[k], s->sl8[k], 64);
    }
}

// ----------------------------------------------------------- cabeçalho da fatia

enum { SL_P = 0, SL_B = 1, SL_I = 2, SL_SP = 3, SL_SI = 4 };

typedef struct {
    int nal_type, nal_ref_idc, idr;
    int first_mb, slice_type, pps_id, frame_num, idr_pic_id, poc_lsb, delta_poc_bottom, delta_poc[2];
    int num_ref_idx[2];
    int nmod;
    struct {
        int idc, val;
    } mod[40];
    int luma_denom, chroma_denom;
    int lw_flag[32], lw[32], lo[32], cw_flag[32], cw[32][2], co[32][2];
    int long_term_reference_flag, adaptive, nmmco;
    struct {
        int op, a, b;
    } mmco[72];
    int cabac_init_idc, slice_qp_delta, disable_deblocking, alpha, beta;
    int header_bits; // do começo do NAL (com o byte do cabeçalho) até o fim do cabeçalho da fatia, sem os bytes de prevenção
} h264_slice;

// b começa no byte do cabeçalho do NAL. 0 = ok.
static int parse_slice(br *b, h264_slice *sh, h264_pps *const *pps_tab, h264_sps *const *sps_tab) {
    memset(sh, 0, sizeof *sh);
    br_u(b, 1);
    sh->nal_ref_idc = (int)br_u(b, 2);
    sh->nal_type = (int)br_u(b, 5);
    sh->idr = sh->nal_type == 5;
    sh->first_mb = (int)br_ue(b);
    sh->slice_type = (int)(br_ue(b) % 5);
    sh->pps_id = (int)br_ue(b);
    if (b->err || sh->pps_id > 255 || !pps_tab[sh->pps_id]) return -1;
    const h264_pps *p = pps_tab[sh->pps_id];
    const h264_sps *s = sps_tab[p->sps_id];
    if (!s) return -1;
    if (s->separate_colour_plane) br_u(b, 2);
    sh->frame_num = (int)br_u(b, s->log2_max_frame_num);
    if (!s->frame_mbs_only && br_u(b, 1)) return -1; // field_pic_flag: campos não são suportados
    if (sh->idr) sh->idr_pic_id = (int)br_ue(b);
    if (s->poc_type == 0) {
        sh->poc_lsb = (int)br_u(b, s->log2_max_poc_lsb);
        if (p->bottom_field_pic_order) sh->delta_poc_bottom = br_se(b);
    }
    if (s->poc_type == 1 && !s->delta_pic_order_always_zero) {
        sh->delta_poc[0] = br_se(b);
        if (p->bottom_field_pic_order) sh->delta_poc[1] = br_se(b);
    }
    if (p->redundant_pic_cnt_present && br_ue(b) != 0) return -1; // fatia redundante: ignora
    const int st = sh->slice_type;
    if (st == SL_B) br_u(b, 1); // direct_spatial_mv_pred_flag
    sh->num_ref_idx[0] = p->num_ref_idx_default[0];
    sh->num_ref_idx[1] = p->num_ref_idx_default[1];
    if (st == SL_P || st == SL_SP || st == SL_B) {
        if (br_u(b, 1)) {
            sh->num_ref_idx[0] = 1 + (int)br_ue(b);
            if (st == SL_B) sh->num_ref_idx[1] = 1 + (int)br_ue(b);
        }
        if (sh->num_ref_idx[0] > 32 || sh->num_ref_idx[1] > 32) return -1;
    }
    if (st != SL_I && st != SL_SI) {
        // ref_pic_list_modification() (só a lista 0: fatias B não são suportadas)
        if (st == SL_B) return -2;
        if (br_u(b, 1)) {
            for (;;) {
                const int idc = (int)br_ue(b);
                if (b->err || idc > 3) return -1;
                if (idc == 3) break;
                if (sh->nmod >= (int)(sizeof sh->mod / sizeof sh->mod[0])) return -1;
                sh->mod[sh->nmod].idc = idc;
                sh->mod[sh->nmod].val = (int)br_ue(b);
                sh->nmod++;
            }
        }
    }
    if (p->weighted_pred && (st == SL_P || st == SL_SP)) {
        // pred_weight_table() da lista 0; ausentes ficam no padrão (2^denom, 0)
        sh->luma_denom = (int)br_ue(b);
        sh->chroma_denom = s->chroma_format_idc ? (int)br_ue(b) : 0;
        if (sh->luma_denom > 7 || sh->chroma_denom > 7) return -1;
        for (int i = 0; i < sh->num_ref_idx[0]; i++) {
            sh->lw[i] = 1 << sh->luma_denom;
            sh->cw[i][0] = sh->cw[i][1] = 1 << sh->chroma_denom;
            if ((sh->lw_flag[i] = (int)br_u(b, 1))) {
                sh->lw[i] = br_se(b);
                sh->lo[i] = br_se(b);
            }
            if (s->chroma_format_idc && (sh->cw_flag[i] = (int)br_u(b, 1))) {
                for (int j = 0; j < 2; j++) {
                    sh->cw[i][j] = br_se(b);
                    sh->co[i][j] = br_se(b);
                }
            }
        }
    }
    if (sh->nal_ref_idc) {
        // dec_ref_pic_marking()
        if (sh->idr) {
            br_u(b, 1); // no_output_of_prior_pics_flag
            sh->long_term_reference_flag = (int)br_u(b, 1);
        } else if ((sh->adaptive = (int)br_u(b, 1))) {
            for (;;) {
                const int op = (int)br_ue(b);
                if (b->err || op > 6) return -1;
                if (op == 0) break;
                if (sh->nmmco >= (int)(sizeof sh->mmco / sizeof sh->mmco[0])) return -1;
                int a = 0, bb = 0;
                if (op == 1 || op == 3) a = (int)br_ue(b); // difference_of_pic_nums_minus1
                if (op == 2) a = (int)br_ue(b);            // long_term_pic_num
                if (op == 3 || op == 6) {
                    if (op == 6) a = (int)br_ue(b); // long_term_frame_idx
                    else bb = (int)br_ue(b);
                }
                if (op == 4) a = (int)br_ue(b); // max_long_term_frame_idx_plus1
                sh->mmco[sh->nmmco].op = op;
                sh->mmco[sh->nmmco].a = a;
                sh->mmco[sh->nmmco].b = bb;
                sh->nmmco++;
            }
        }
    }
    if (p->cabac && st != SL_I && st != SL_SI) sh->cabac_init_idc = (int)br_ue(b);
    sh->slice_qp_delta = br_se(b);
    if (st == SL_SP || st == SL_SI) return -2;
    if (p->deblocking_filter_control_present) {
        sh->disable_deblocking = (int)br_ue(b);
        if (sh->disable_deblocking != 1) {
            sh->alpha = br_se(b);
            sh->beta = br_se(b);
        }
    }
    sh->header_bits = b->pos;
    return b->err ? -1 : 0;
}

// ------------------------------------------------------------------ decoder

enum { REF_NONE = 0, REF_SHORT = 1, REF_LONG = 2 };

typedef struct {
    VASurfaceID surf;
    int ref;
    int frame_num, lt_idx;
    int top, bot; // POC
} dpb_pic;

#define MAX_SURF 20

struct vadec {
    va_dev dev;
    char vendor[128];
    int has_cb, has_main, has_high;
    VAConfigID cfg;
    VAContextID ctx;
    VAProfile profile;
    VASurfaceID surf[MAX_SURF];
    int nsurf, coded_w, coded_h;
    h264_sps *sps[32];
    h264_pps *pps[256];
    h264_sps active; // SPS do IDR atual (só muda num IDR)
    int ready;       // já teve um IDR e não houve erro desde então
    dpb_pic dpb[16];
    int ndpb;
    int max_lt_idx; // -1 = nenhum índice de longo prazo
    // estado do POC e do frame_num
    int prev_poc_msb, prev_poc_lsb, prev_frame_num_offset, prev_frame_num, prev_ref_frame_num;
    int cur_poc_msb, cur_frame_num_offset;
    // quadro em montagem
    int in_pic, pic_err;
    h264_slice first;
    dpb_pic cur;
    VAPictureParameterBufferH264 pp;
    VAIQMatrixBufferH264 iq;
    VASliceParameterBufferH264 *sp;
    const uint8_t **sdata;
    int *slen;
    int nslices, slices_cap;
    h264_slice sh; // rascunho (grande demais pra pilha à toa)
    uint8_t rbsp[4096];
    // saída
    uint8_t *host;
    size_t host_cap;
    int out_w, out_h, have;
    VAImage img;
    int no_derive;
    uint8_t *bounce;
    vadec_stats st;
};

static int dec_check(VADisplay dpy, char *why, int whylen) {
    if (va_has(dpy, VAProfileH264High, VAEntrypointVLD) || va_has(dpy, VAProfileH264Main, VAEntrypointVLD)) return 1;
    snprintf(why, whylen, "o driver não decodifica H.264");
    return 0;
}

static void dec_destroy_ctx(vadec *d) {
    if (d->img.image_id != VA_INVALID_ID) va.DestroyImage(d->dev.dpy, d->img.image_id);
    d->img.image_id = VA_INVALID_ID;
    if (d->ctx != VA_INVALID_ID) va.DestroyContext(d->dev.dpy, d->ctx);
    d->ctx = VA_INVALID_ID;
    if (d->nsurf) va.DestroySurfaces(d->dev.dpy, d->surf, d->nsurf);
    d->nsurf = 0;
    if (d->cfg != VA_INVALID_ID) va.DestroyConfig(d->dev.dpy, d->cfg);
    d->cfg = VA_INVALID_ID;
    d->ndpb = 0;
    d->ready = 0;
}

void vadec_close(vadec *d) {
    if (!d) return;
    if (d->dev.dpy) dec_destroy_ctx(d);
    va_close_dev(&d->dev);
    for (int i = 0; i < 32; i++) free(d->sps[i]);
    for (int i = 0; i < 256; i++) free(d->pps[i]);
    free(d->sp);
    free(d->sdata);
    free(d->slen);
    free(d->host);
    free(d->bounce);
    free(d);
}

vadec *vadec_open(int codec, char *err, int errlen) {
    if (codec != HW_CODEC_H264) {
        set_err(err, errlen, "VA-API: codec ainda não suportado%s", "");
        return NULL;
    }
    vadec *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->cfg = VA_INVALID_ID;
    d->ctx = VA_INVALID_ID;
    d->img.image_id = VA_INVALID_ID;
    d->max_lt_idx = -1;
    if (va_open_dev(&d->dev, dec_check, err, errlen) < 0) {
        vadec_close(d);
        return NULL;
    }
    const char *v = va.QueryVendorString(d->dev.dpy);
    snprintf(d->vendor, sizeof d->vendor, "%s", v ? v : "?");
    d->has_cb = va_has(d->dev.dpy, VAProfileH264ConstrainedBaseline, VAEntrypointVLD);
    d->has_main = va_has(d->dev.dpy, VAProfileH264Main, VAEntrypointVLD);
    d->has_high = va_has(d->dev.dpy, VAProfileH264High, VAEntrypointVLD);
    return d;
}

const char *vadec_driver(vadec *d) {
    return d->vendor;
}

void vadec_get_stats(vadec *d, vadec_stats *s) {
    *s = d->st;
}

// Cria (ou recria, se o tamanho/perfil mudou) a configuração, as superfícies e o contexto.
static int dec_setup(vadec *d, const h264_sps *s) {
    if (s->chroma_format_idc != 1 || s->bit_depth_luma != 8 || s->bit_depth_chroma != 8 || !s->frame_mbs_only) return -1;
    // perfil do VA-API: o exato se tiver; senão um que contenha esse (CB ⊂ Main ⊂ High)
    VAProfile prof;
    const int p = s->profile_idc;
    if (p == 66 && d->has_cb) prof = VAProfileH264ConstrainedBaseline;
    else if ((p == 66 || p == 77) && d->has_main) prof = VAProfileH264Main;
    else if ((p == 66 || p == 77 || p == 100) && d->has_high) prof = VAProfileH264High;
    else return -1;
    const int w = s->mb_w * 16, h = s->map_h * 16;
    int n = (s->max_num_ref_frames > 0 ? s->max_num_ref_frames : 1) + 2;
    if (n > MAX_SURF) n = MAX_SURF;
    if (d->ctx != VA_INVALID_ID && prof == d->profile && w == d->coded_w && h == d->coded_h && n <= d->nsurf) return 0;
    dec_destroy_ctx(d);
    VAConfigAttrib a = {VAConfigAttribRTFormat, VA_RT_FORMAT_YUV420};
    if (va.CreateConfig(d->dev.dpy, prof, VAEntrypointVLD, &a, 1, &d->cfg) != VA_STATUS_SUCCESS) {
        d->cfg = VA_INVALID_ID;
        return -1;
    }
    if (va.CreateSurfaces(d->dev.dpy, VA_RT_FORMAT_YUV420, (unsigned)w, (unsigned)h, d->surf, (unsigned)n, NULL, 0) != VA_STATUS_SUCCESS) {
        dec_destroy_ctx(d);
        return -1;
    }
    d->nsurf = n;
    if (va.CreateContext(d->dev.dpy, d->cfg, w, h, VA_PROGRESSIVE, d->surf, n, &d->ctx) != VA_STATUS_SUCCESS) {
        d->ctx = VA_INVALID_ID;
        dec_destroy_ctx(d);
        return -1;
    }
    d->profile = prof;
    d->coded_w = w;
    d->coded_h = h;
    free(d->bounce);
    d->bounce = aligned_alloc(64, ((size_t)w + 128 + 63) & ~(size_t)63);
    return 0;
}

static void va_pic(VAPictureH264 *v, const dpb_pic *p) {
    memset(v, 0, sizeof *v);
    v->picture_id = p->surf;
    v->frame_idx = (uint32_t)(p->ref == REF_LONG ? p->lt_idx : p->frame_num);
    v->flags = p->ref == REF_LONG ? VA_PICTURE_H264_LONG_TERM_REFERENCE : p->ref == REF_SHORT ? VA_PICTURE_H264_SHORT_TERM_REFERENCE : 0;
    v->TopFieldOrderCnt = p->top;
    v->BottomFieldOrderCnt = p->bot;
}

static void va_pic_invalid(VAPictureH264 *v) {
    memset(v, 0, sizeof *v);
    v->picture_id = VA_INVALID_SURFACE;
    v->flags = VA_PICTURE_H264_INVALID;
}

// PicNum de um quadro de curto prazo (FrameNumWrap, 8.2.4.1)
static int pic_num(const dpb_pic *p, int cur_frame_num, int max_frame_num) {
    return p->frame_num > cur_frame_num ? p->frame_num - max_frame_num : p->frame_num;
}

// POC do quadro (8.2.1); só quadros, não campos
static void compute_poc(vadec *d, const h264_slice *sh, const h264_sps *s, int *top, int *bot) {
    const int max_fn = 1 << s->log2_max_frame_num;
    if (s->poc_type == 0) {
        const int prev_msb = sh->idr ? 0 : d->prev_poc_msb, prev_lsb = sh->idr ? 0 : d->prev_poc_lsb;
        const int max_lsb = 1 << s->log2_max_poc_lsb;
        int msb = prev_msb;
        if (sh->poc_lsb < prev_lsb && prev_lsb - sh->poc_lsb >= max_lsb / 2) msb = prev_msb + max_lsb;
        else if (sh->poc_lsb > prev_lsb && sh->poc_lsb - prev_lsb > max_lsb / 2) msb = prev_msb - max_lsb;
        d->cur_poc_msb = msb;
        *top = msb + sh->poc_lsb;
        *bot = *top + sh->delta_poc_bottom;
        return;
    }
    int offset = 0;
    if (!sh->idr) offset = d->prev_frame_num > sh->frame_num ? d->prev_frame_num_offset + max_fn : d->prev_frame_num_offset;
    d->cur_frame_num_offset = offset;
    if (s->poc_type == 2) {
        const int t = sh->idr ? 0 : sh->nal_ref_idc ? 2 * (offset + sh->frame_num) : 2 * (offset + sh->frame_num) - 1;
        *top = *bot = t;
        return;
    }
    // tipo 1
    const int n = s->num_ref_frames_in_poc_cycle;
    int abs_fn = n ? offset + sh->frame_num : 0;
    if (!sh->nal_ref_idc && abs_fn > 0) abs_fn--;
    int expected = 0;
    if (abs_fn > 0) {
        int delta_cycle = 0;
        for (int i = 0; i < n; i++) delta_cycle += s->offset_for_ref_frame[i];
        const int cycle = (abs_fn - 1) / n, in_cycle = (abs_fn - 1) % n;
        expected = cycle * delta_cycle;
        for (int i = 0; i <= in_cycle; i++) expected += s->offset_for_ref_frame[i];
    }
    if (!sh->nal_ref_idc) expected += s->offset_for_non_ref_pic;
    *top = expected + sh->delta_poc[0];
    *bot = *top + s->offset_for_top_to_bottom_field + sh->delta_poc[1];
}

// Começa um quadro: ativa o SPS (num IDR), confere o frame_num, calcula o POC
// e monta os parâmetros do quadro.
static int pic_start(vadec *d, const h264_slice *sh) {
    const h264_pps *p = d->pps[sh->pps_id];
    const h264_sps *s = d->sps[p->sps_id];
    if (sh->idr) {
        if (!sh->nal_ref_idc || dec_setup(d, s) < 0) return -1;
        d->active = *s;
        d->ready = 1;
    } else {
        if (!d->ready) return -1;
        // SPS trocado sem IDR: tamanho/estrutura diferentes do que está em uso
        if (s->mb_w != d->active.mb_w || s->map_h != d->active.map_h || s->log2_max_frame_num != d->active.log2_max_frame_num ||
            s->poc_type != d->active.poc_type || s->max_num_ref_frames > d->active.max_num_ref_frames)
            return -1;
        // buraco no frame_num = perdeu quadro de referência (gaps_in_frame_num não é suportado)
        const int max_fn = 1 << d->active.log2_max_frame_num;
        if (sh->frame_num != (d->prev_ref_frame_num + 1) % max_fn) return -1;
    }
    const h264_sps *as = &d->active;
    // superfície livre (nenhuma referência usando)
    VASurfaceID surf = VA_INVALID_SURFACE;
    for (int i = 0; i < d->nsurf && surf == VA_INVALID_SURFACE; i++) {
        int used = 0;
        for (int j = 0; j < d->ndpb; j++)
            if (!sh->idr && d->dpb[j].surf == d->surf[i]) used = 1;
        if (!used) surf = d->surf[i];
    }
    if (surf == VA_INVALID_SURFACE) return -1;
    if (sh->idr) d->ndpb = 0; // num IDR todas as referências caem (8.2.5.1)

    memset(&d->cur, 0, sizeof d->cur);
    d->cur.surf = surf;
    d->cur.frame_num = sh->frame_num;
    d->cur.ref = sh->nal_ref_idc ? REF_SHORT : REF_NONE;
    compute_poc(d, sh, as, &d->cur.top, &d->cur.bot);

    VAPictureParameterBufferH264 *pp = &d->pp;
    memset(pp, 0, sizeof *pp);
    va_pic(&pp->CurrPic, &d->cur);
    pp->CurrPic.frame_idx = (uint32_t)sh->frame_num;
    pp->CurrPic.flags = 0; // como o ffmpeg: o quadro atual vai sem marca de referência (o reference_pic_flag diz)
    // referências: curto prazo (mais recente primeiro) e depois longo prazo
    const int max_fn = 1 << as->log2_max_frame_num;
    int k = 0;
    for (int pass = 0; pass < 2; pass++) {
        int order[16], n = 0;
        for (int i = 0; i < d->ndpb; i++)
            if (d->dpb[i].ref == (pass ? REF_LONG : REF_SHORT)) order[n++] = i;
        for (int i = 1; i < n; i++) // inserção: curto por PicNum decrescente, longo por índice crescente
            for (int j = i; j > 0; j--) {
                const dpb_pic *a = &d->dpb[order[j - 1]], *b = &d->dpb[order[j]];
                const int swap = pass ? a->lt_idx > b->lt_idx : pic_num(a, sh->frame_num, max_fn) < pic_num(b, sh->frame_num, max_fn);
                if (!swap) break;
                const int t = order[j];
                order[j] = order[j - 1];
                order[j - 1] = t;
            }
        for (int i = 0; i < n && k < 16; i++) va_pic(&pp->ReferenceFrames[k++], &d->dpb[order[i]]);
    }
    for (; k < 16; k++) va_pic_invalid(&pp->ReferenceFrames[k]);
    pp->picture_width_in_mbs_minus1 = (uint16_t)(as->mb_w - 1);
    pp->picture_height_in_mbs_minus1 = (uint16_t)(as->map_h - 1);
    pp->bit_depth_luma_minus8 = 0;
    pp->bit_depth_chroma_minus8 = 0;
    pp->num_ref_frames = (uint8_t)as->max_num_ref_frames;
    pp->seq_fields.bits.chroma_format_idc = (uint32_t)as->chroma_format_idc;
    pp->seq_fields.bits.residual_colour_transform_flag = (uint32_t)as->separate_colour_plane;
    pp->seq_fields.bits.gaps_in_frame_num_value_allowed_flag = (uint32_t)as->gaps_allowed;
    pp->seq_fields.bits.frame_mbs_only_flag = (uint32_t)as->frame_mbs_only;
    pp->seq_fields.bits.mb_adaptive_frame_field_flag = (uint32_t)as->mbaff;
    pp->seq_fields.bits.direct_8x8_inference_flag = (uint32_t)as->direct_8x8;
    pp->seq_fields.bits.MinLumaBiPredSize8x8 = as->level_idc >= 31;
    pp->seq_fields.bits.log2_max_frame_num_minus4 = (uint32_t)(as->log2_max_frame_num - 4);
    pp->seq_fields.bits.pic_order_cnt_type = (uint32_t)as->poc_type;
    pp->seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 = as->poc_type == 0 ? (uint32_t)(as->log2_max_poc_lsb - 4) : 0;
    pp->seq_fields.bits.delta_pic_order_always_zero_flag = (uint32_t)as->delta_pic_order_always_zero;
    pp->pic_init_qp_minus26 = (int8_t)(p->pic_init_qp - 26);
    pp->pic_init_qs_minus26 = (int8_t)(p->pic_init_qs - 26);
    pp->chroma_qp_index_offset = (int8_t)p->chroma_qp_index_offset;
    pp->second_chroma_qp_index_offset = (int8_t)p->second_chroma_qp_index_offset;
    pp->pic_fields.bits.entropy_coding_mode_flag = (uint32_t)p->cabac;
    pp->pic_fields.bits.weighted_pred_flag = (uint32_t)p->weighted_pred;
    pp->pic_fields.bits.weighted_bipred_idc = (uint32_t)p->weighted_bipred_idc;
    pp->pic_fields.bits.transform_8x8_mode_flag = (uint32_t)p->transform_8x8;
    pp->pic_fields.bits.field_pic_flag = 0;
    pp->pic_fields.bits.constrained_intra_pred_flag = (uint32_t)p->constrained_intra_pred;
    pp->pic_fields.bits.pic_order_present_flag = (uint32_t)p->bottom_field_pic_order;
    pp->pic_fields.bits.deblocking_filter_control_present_flag = (uint32_t)p->deblocking_filter_control_present;
    pp->pic_fields.bits.redundant_pic_cnt_present_flag = (uint32_t)p->redundant_pic_cnt_present;
    pp->pic_fields.bits.reference_pic_flag = sh->nal_ref_idc != 0;
    pp->frame_num = (uint16_t)sh->frame_num;

    resolve_scaling(as, p, d->iq.ScalingList4x4, d->iq.ScalingList8x8);
    d->first = *sh;
    d->in_pic = 1;
    d->pic_err = 0;
    d->nslices = 0;
    return 0;
}

// Lista de referências 0 da fatia P (8.2.4.2.1 e 8.2.4.3); list tem 33 posições.
static int build_list0(vadec *d, const h264_slice *sh, dpb_pic **list) {
    const int n = sh->num_ref_idx[0];
    const int max_fn = 1 << d->active.log2_max_frame_num, cur_fn = sh->frame_num;
    dpb_pic *st[16], *lt[16];
    int ns = 0, nl = 0;
    for (int i = 0; i < d->ndpb; i++) {
        if (d->dpb[i].ref == REF_SHORT) st[ns++] = &d->dpb[i];
        else if (d->dpb[i].ref == REF_LONG) lt[nl++] = &d->dpb[i];
    }
    for (int i = 1; i < ns; i++)
        for (int j = i; j > 0 && pic_num(st[j - 1], cur_fn, max_fn) < pic_num(st[j], cur_fn, max_fn); j--) {
            dpb_pic *t = st[j];
            st[j] = st[j - 1];
            st[j - 1] = t;
        }
    for (int i = 1; i < nl; i++)
        for (int j = i; j > 0 && lt[j - 1]->lt_idx > lt[j]->lt_idx; j--) {
            dpb_pic *t = lt[j];
            lt[j] = lt[j - 1];
            lt[j - 1] = t;
        }
    for (int i = 0; i < 33; i++) list[i] = NULL;
    int k = 0;
    for (int i = 0; i < ns && k < n; i++) list[k++] = st[i];
    for (int i = 0; i < nl && k < n; i++) list[k++] = lt[i];

    int pred = cur_fn, idx = 0;
    for (int m = 0; m < sh->nmod; m++) {
        dpb_pic *pic = NULL;
        if (sh->mod[m].idc < 2) {
            const int abs_diff = sh->mod[m].val + 1;
            int nowrap;
            if (sh->mod[m].idc == 0) {
                nowrap = pred - abs_diff;
                if (nowrap < 0) nowrap += max_fn;
            } else {
                nowrap = pred + abs_diff;
                if (nowrap >= max_fn) nowrap -= max_fn;
            }
            pred = nowrap;
            const int num = nowrap > cur_fn ? nowrap - max_fn : nowrap;
            for (int i = 0; i < ns; i++)
                if (pic_num(st[i], cur_fn, max_fn) == num) pic = st[i];
        } else {
            for (int i = 0; i < nl; i++)
                if (lt[i]->lt_idx == sh->mod[m].val) pic = lt[i];
        }
        if (!pic || idx >= n) return -1; // referência perdida
        for (int c = n; c > idx; c--) list[c] = list[c - 1];
        list[idx++] = pic;
        int o = idx;
        for (int c = idx; c <= n; c++)
            if (list[c] != pic) list[o++] = list[c];
    }
    return list[0] ? 0 : -1;
}

static int add_slice(vadec *d, const h264_slice *sh, const uint8_t *nal, int len) {
    if (d->nslices == d->slices_cap) {
        const int cap = d->slices_cap ? d->slices_cap * 2 : 16;
        VASliceParameterBufferH264 *sp = realloc(d->sp, (size_t)cap * sizeof *sp);
        if (!sp) return -1;
        d->sp = sp;
        const uint8_t **sd = realloc(d->sdata, (size_t)cap * sizeof *sd);
        if (!sd) return -1;
        d->sdata = sd;
        int *sl = realloc(d->slen, (size_t)cap * sizeof *sl);
        if (!sl) return -1;
        d->slen = sl;
        d->slices_cap = cap;
    }
    const h264_pps *p = d->pps[d->first.pps_id];
    VASliceParameterBufferH264 *s = &d->sp[d->nslices];
    memset(s, 0, sizeof *s);
    s->slice_data_size = (uint32_t)len;
    s->slice_data_offset = 0;
    s->slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
    s->slice_data_bit_offset = (uint16_t)sh->header_bits;
    s->first_mb_in_slice = (uint16_t)sh->first_mb;
    s->slice_type = (uint8_t)sh->slice_type;
    s->direct_spatial_mv_pred_flag = 0;
    s->num_ref_idx_l0_active_minus1 = sh->slice_type == SL_P ? (uint8_t)(sh->num_ref_idx[0] - 1) : 0;
    s->num_ref_idx_l1_active_minus1 = 0;
    s->cabac_init_idc = (uint8_t)sh->cabac_init_idc;
    s->slice_qp_delta = (int8_t)sh->slice_qp_delta;
    s->disable_deblocking_filter_idc = (uint8_t)sh->disable_deblocking;
    s->slice_alpha_c0_offset_div2 = (int8_t)sh->alpha;
    s->slice_beta_offset_div2 = (int8_t)sh->beta;
    for (int i = 0; i < 32; i++) {
        va_pic_invalid(&s->RefPicList0[i]);
        va_pic_invalid(&s->RefPicList1[i]);
    }
    if (sh->slice_type == SL_P) {
        dpb_pic *list[33];
        if (build_list0(d, sh, list) < 0) return -1;
        for (int i = 0; i < sh->num_ref_idx[0]; i++)
            if (list[i]) va_pic(&s->RefPicList0[i], list[i]);
        if (p->weighted_pred) {
            s->luma_log2_weight_denom = (uint8_t)sh->luma_denom;
            s->chroma_log2_weight_denom = (uint8_t)sh->chroma_denom;
            for (int i = 0; i < sh->num_ref_idx[0]; i++) {
                s->luma_weight_l0_flag |= (uint8_t)sh->lw_flag[i];
                s->chroma_weight_l0_flag |= (uint8_t)sh->cw_flag[i];
                s->luma_weight_l0[i] = (int16_t)sh->lw[i];
                s->luma_offset_l0[i] = (int16_t)sh->lo[i];
                for (int j = 0; j < 2; j++) {
                    s->chroma_weight_l0[i][j] = (int16_t)sh->cw[i][j];
                    s->chroma_offset_l0[i][j] = (int16_t)sh->co[i][j];
                }
            }
        }
    }
    d->sdata[d->nslices] = nal;
    d->slen[d->nslices] = len;
    d->nslices++;
    return 0;
}

// Marcação das referências depois de decodificar o quadro (8.2.5).
static void mark_refs(vadec *d) {
    const h264_slice *sh = &d->first;
    const h264_sps *s = &d->active;
    const int max_fn = 1 << s->log2_max_frame_num;
    dpb_pic *cur = &d->cur;
    int mmco5 = 0;
    if (sh->nal_ref_idc) {
        if (sh->idr) {
            d->ndpb = 0;
            if (sh->long_term_reference_flag) {
                cur->ref = REF_LONG;
                cur->lt_idx = 0;
                d->max_lt_idx = 0;
            } else {
                cur->ref = REF_SHORT;
                d->max_lt_idx = -1;
            }
        } else {
            int cur_long = 0;
            if (sh->adaptive) {
                for (int m = 0; m < sh->nmmco; m++) {
                    const int op = sh->mmco[m].op, a = sh->mmco[m].a, b = sh->mmco[m].b;
                    const int pnx = sh->frame_num - (a + 1); // picNumX (operações 1 e 3)
                    for (int i = 0; i < d->ndpb; i++) {
                        dpb_pic *r = &d->dpb[i];
                        switch (op) {
                        case 1:
                            if (r->ref == REF_SHORT && pic_num(r, sh->frame_num, max_fn) == pnx) r->ref = REF_NONE;
                            break;
                        case 2:
                            if (r->ref == REF_LONG && r->lt_idx == a) r->ref = REF_NONE;
                            break;
                        case 3:
                            if (r->ref == REF_LONG && r->lt_idx == b) r->ref = REF_NONE;
                            break;
                        case 4:
                            if (r->ref == REF_LONG && r->lt_idx > a - 1) r->ref = REF_NONE;
                            break;
                        case 5:
                            r->ref = REF_NONE;
                            break;
                        case 6:
                            if (r->ref == REF_LONG && r->lt_idx == a) r->ref = REF_NONE;
                            break;
                        }
                    }
                    if (op == 3) {
                        for (int i = 0; i < d->ndpb; i++) {
                            dpb_pic *r = &d->dpb[i];
                            if (r->ref == REF_SHORT && pic_num(r, sh->frame_num, max_fn) == pnx) {
                                r->ref = REF_LONG;
                                r->lt_idx = b;
                            }
                        }
                    } else if (op == 4)
                        d->max_lt_idx = a - 1;
                    else if (op == 5) {
                        d->max_lt_idx = -1;
                        mmco5 = 1;
                    } else if (op == 6) {
                        cur->ref = REF_LONG;
                        cur->lt_idx = a;
                        cur_long = 1;
                    }
                }
            } else {
                // janela deslizante: cheio -> sai o de curto prazo mais antigo
                int nshort = 0, nlong = 0, oldest = -1;
                for (int i = 0; i < d->ndpb; i++) {
                    if (d->dpb[i].ref == REF_SHORT) {
                        nshort++;
                        if (oldest < 0 || pic_num(&d->dpb[i], sh->frame_num, max_fn) < pic_num(&d->dpb[oldest], sh->frame_num, max_fn)) oldest = i;
                    } else if (d->dpb[i].ref == REF_LONG)
                        nlong++;
                }
                if (nshort + nlong >= (s->max_num_ref_frames > 0 ? s->max_num_ref_frames : 1) && nshort > 0) d->dpb[oldest].ref = REF_NONE;
            }
            if (!cur_long) cur->ref = REF_SHORT;
        }
    }
    // tira da lista quem não é mais referência
    int o = 0;
    for (int i = 0; i < d->ndpb; i++)
        if (d->dpb[i].ref != REF_NONE) d->dpb[o++] = d->dpb[i];
    d->ndpb = o;
    if (mmco5) {
        // o quadro passa a valer como frame_num 0 e POC relativo a ele mesmo (8.2.1)
        const int t = cur->top < cur->bot ? cur->top : cur->bot;
        cur->top -= t;
        cur->bot -= t;
        cur->frame_num = 0;
    }
    if (cur->ref != REF_NONE) {
        // fluxo fora do padrão (mais referências que o SPS permite): sai a mais antiga
        const int max_refs = s->max_num_ref_frames > 0 ? s->max_num_ref_frames : 1;
        while (d->ndpb >= max_refs || d->ndpb >= 16) {
            int oldest = 0;
            for (int i = 1; i < d->ndpb; i++)
                if (d->dpb[i].ref == REF_SHORT &&
                    (d->dpb[oldest].ref != REF_SHORT || pic_num(&d->dpb[i], cur->frame_num, max_fn) < pic_num(&d->dpb[oldest], cur->frame_num, max_fn)))
                    oldest = i;
            memmove(&d->dpb[oldest], &d->dpb[oldest + 1], (size_t)(d->ndpb - oldest - 1) * sizeof d->dpb[0]);
            d->ndpb--;
        }
        d->dpb[d->ndpb++] = *cur;
    }
    // estado pro próximo quadro (POC e frame_num)
    if (s->poc_type == 0) {
        if (sh->nal_ref_idc) {
            d->prev_poc_msb = mmco5 ? 0 : d->cur_poc_msb;
            d->prev_poc_lsb = mmco5 ? cur->top : sh->poc_lsb;
        }
    } else {
        d->prev_frame_num_offset = mmco5 ? 0 : d->cur_frame_num_offset;
    }
    d->prev_frame_num = mmco5 ? 0 : sh->frame_num;
    if (sh->nal_ref_idc) d->prev_ref_frame_num = mmco5 ? 0 : sh->frame_num;
}

// Copia a imagem decodificada (recortada) pra memória da CPU.
static int copy_out(vadec *d, VASurfaceID surf) {
    const h264_sps *s = &d->active;
    const int w = s->mb_w * 16 - s->crop_l - s->crop_r, h = s->map_h * 16 - s->crop_t - s->crop_b;
    const size_t need = (size_t)w * h * 3 / 2;
    if (need > d->host_cap) {
        free(d->host);
        d->host = malloc(need);
        d->host_cap = d->host ? need : 0;
        if (!d->host) return -1;
    }
    VAImage img;
    int derived = 0;
    if (!d->no_derive) {
        if (va.DeriveImage(d->dev.dpy, surf, &img) == VA_STATUS_SUCCESS) {
            if (img.format.fourcc == VA_FOURCC_NV12) derived = 1;
            else va.DestroyImage(d->dev.dpy, img.image_id);
        }
        if (!derived) d->no_derive = 1; // não adianta tentar de novo
    }
    if (!derived) {
        if (d->img.image_id == VA_INVALID_ID) {
            VAImageFormat f;
            memset(&f, 0, sizeof f);
            f.fourcc = VA_FOURCC_NV12;
            f.byte_order = VA_LSB_FIRST;
            f.bits_per_pixel = 12;
            if (va.CreateImage(d->dev.dpy, &f, d->coded_w, d->coded_h, &d->img) != VA_STATUS_SUCCESS) {
                d->img.image_id = VA_INVALID_ID;
                return -1;
            }
        }
        if (va.GetImage(d->dev.dpy, surf, 0, 0, (unsigned)d->coded_w, (unsigned)d->coded_h, d->img.image_id) != VA_STATUS_SUCCESS) return -1;
        img = d->img;
    }
    void *ptr = NULL;
    int rc = -1;
    if (va.MapBuffer(d->dev.dpy, img.buf, &ptr) == VA_STATUS_SUCCESS) {
        const uint8_t *base = ptr;
        const uint8_t *y = base + img.offsets[0] + (size_t)s->crop_t * img.pitches[0] + (size_t)s->crop_l;
        const uint8_t *uv = base + img.offsets[1] + (size_t)(s->crop_t / 2) * img.pitches[1] + (size_t)s->crop_l;
        copy_plane(d->host, (size_t)w, y, img.pitches[0], (size_t)w, (size_t)h, d->bounce);
        copy_plane(d->host + (size_t)w * h, (size_t)w, uv, img.pitches[1], (size_t)w, (size_t)h / 2, d->bounce);
        va.UnmapBuffer(d->dev.dpy, img.buf);
        rc = 0;
    }
    if (derived) va.DestroyImage(d->dev.dpy, img.image_id);
    if (rc == 0) {
        d->out_w = w;
        d->out_h = h;
    }
    return rc;
}

// Manda o quadro montado pro driver, marca as referências e copia a imagem.
static int pic_finish(vadec *d) {
    d->in_pic = 0;
    if (d->pic_err || !d->nslices) return -1;
    VADisplay dpy = d->dev.dpy;
    VABufferID bufs[2 + 2 * 64], *dyn = NULL, *ids = bufs;
    const int total = 2 + 2 * d->nslices;
    if (total > (int)(sizeof bufs / sizeof bufs[0])) {
        dyn = malloc((size_t)total * sizeof *dyn);
        if (!dyn) return -1;
        ids = dyn;
    }
    int n = 0, ok = 1;
    ok = ok && va.CreateBuffer(dpy, d->ctx, VAPictureParameterBufferType, sizeof d->pp, 1, &d->pp, &ids[n]) == VA_STATUS_SUCCESS && ++n;
    ok = ok && va.CreateBuffer(dpy, d->ctx, VAIQMatrixBufferType, sizeof d->iq, 1, &d->iq, &ids[n]) == VA_STATUS_SUCCESS && ++n;
    ok = ok && va.BeginPicture(dpy, d->ctx, d->cur.surf) == VA_STATUS_SUCCESS;
    const int begun = ok;
    ok = ok && va.RenderPicture(dpy, d->ctx, ids, 2) == VA_STATUS_SUCCESS;
    for (int i = 0; i < d->nslices && ok; i++) {
        VABufferID *pair = &ids[n];
        ok = va.CreateBuffer(dpy, d->ctx, VASliceParameterBufferType, sizeof d->sp[i], 1, &d->sp[i], &pair[0]) == VA_STATUS_SUCCESS && ++n;
        ok = ok && va.CreateBuffer(dpy, d->ctx, VASliceDataBufferType, (unsigned)d->slen[i], 1, (void *)d->sdata[i], &pair[1]) == VA_STATUS_SUCCESS && ++n;
        ok = ok && va.RenderPicture(dpy, d->ctx, pair, 2) == VA_STATUS_SUCCESS;
    }
    if (begun) ok = va.EndPicture(dpy, d->ctx) == VA_STATUS_SUCCESS && ok;
    for (int i = 0; i < n; i++) va.DestroyBuffer(dpy, ids[i]);
    free(dyn);
    if (!ok) return -1;
    const h264_pps *p = d->pps[d->first.pps_id];
    d->st.pictures++;
    d->st.idr += d->first.idr;
    d->st.mmco += d->first.adaptive && d->first.nmmco > 0;
    d->st.multi_slice += d->nslices > 1;
    d->st.scaling += d->active.scaling_present || p->scaling_present;
    d->st.cabac += p->cabac;
    d->st.weighted += p->weighted_pred && d->first.slice_type == SL_P;
    d->st.poc_types |= 1 << d->active.poc_type;
    for (int i = 0; i < d->ndpb; i++) d->st.long_term += d->dpb[i].ref == REF_LONG;
    mark_refs(d);
    if (va.SyncSurface(dpy, d->cur.surf) != VA_STATUS_SUCCESS) return -1;
    if (copy_out(d, d->cur.surf) < 0) return -1;
    d->have = 1;
    return 0;
}

static void handle_nal(vadec *d, const uint8_t *nal, int len, int *err) {
    if (len < 1) return;
    const int type = nal[0] & 0x1f;
    if (type == 7 || type == 8) {
        // SPS/PPS: guardados por id; valem a partir do próximo quadro que os usar
        const int n = unescape(nal, len < (int)sizeof d->rbsp ? len : (int)sizeof d->rbsp, d->rbsp);
        br b = {d->rbsp, n, 8, 0};
        if (type == 7) {
            h264_sps s;
            if (parse_sps(&b, &s) < 0) return;
            if (!d->sps[s.id] && !(d->sps[s.id] = malloc(sizeof s))) return;
            *d->sps[s.id] = s;
        } else {
            h264_pps p;
            if (parse_pps(&b, &p, d->sps) < 0) return;
            if (!d->pps[p.id] && !(d->pps[p.id] = malloc(sizeof p))) return;
            *d->pps[p.id] = p;
        }
        return;
    }
    if (type == 2 || type == 3 || type == 4) {
        *err = 1; // partição de dados (perfil Extended): não suportado
        return;
    }
    if (type != 1 && type != 5) return; // SEI, AUD, prefixo SVC...
    // só o começo do NAL precisa de bytes de prevenção removidos: é onde está o cabeçalho
    const int n = unescape(nal, len < (int)sizeof d->rbsp ? len : (int)sizeof d->rbsp, d->rbsp);
    br b = {d->rbsp, n, 0, 0};
    h264_slice *sh = &d->sh;
    if (parse_slice(&b, sh, d->pps, d->sps) < 0) {
        if (d->in_pic) d->pic_err = 1;
        *err = 1;
        return;
    }
    if (d->in_pic && sh->first_mb == 0) {
        // quadro novo no mesmo pacote: termina o anterior
        if (pic_finish(d) < 0) {
            *err = 1;
            d->ready = 0;
        }
    }
    if (!d->in_pic) {
        if (pic_start(d, sh) < 0) {
            *err = 1;
            d->ready = 0; // sem referência confiável até o próximo IDR
            return;
        }
    } else if (sh->pps_id != d->first.pps_id) {
        d->pic_err = 1;
        return;
    }
    d->st.reorder += sh->nmod > 0;
    if (add_slice(d, sh, nal, len) < 0) d->pic_err = 1;
}

int vadec_decode(vadec *d, const uint8_t *data, int len, hwdec_frame *out) {
    d->have = 0;
    int err = 0;
    const uint8_t *end = data + len;
    const uint8_t *p = find_sc(data, end);
    while (p < end) {
        const uint8_t *nal = p + 3;
        const uint8_t *q = find_sc(nal, end);
        const uint8_t *e = q;
        while (e > nal && e[-1] == 0) e--; // zeros antes do próximo start code não são do NAL
        handle_nal(d, nal, (int)(e - nal), &err);
        p = q;
    }
    if (d->in_pic && pic_finish(d) < 0) {
        err = 1;
        d->ready = 0;
    }
    if (err) return -1;
    if (!d->have) return 0;
    out->y = d->host;
    out->uv = d->host + (size_t)d->out_w * d->out_h;
    out->width = d->out_w;
    out->height = d->out_h;
    return 1;
}

// ---------------------------------------------------------- escrita de bits

typedef struct {
    uint8_t buf[256];
    int bits;
} bw;

static void bw_u(bw *w, int n, uint32_t v) {
    for (int i = n - 1; i >= 0; i--) {
        if (w->bits < (int)sizeof w->buf * 8 && ((v >> i) & 1)) w->buf[w->bits >> 3] |= (uint8_t)(0x80 >> (w->bits & 7));
        w->bits++;
    }
}

static void bw_ue(bw *w, uint32_t v) {
    const uint64_t x = (uint64_t)v + 1;
    int len = 0;
    while ((x >> (len + 1)) != 0) len++;
    bw_u(w, len, 0);
    bw_u(w, len + 1, (uint32_t)x); // len <= 31 pros valores daqui
}

static void bw_se(bw *w, int32_t v) {
    bw_ue(w, v > 0 ? (uint32_t)(2 * v - 1) : (uint32_t)(-2 * (int64_t)v));
}

static void bw_trailing(bw *w) {
    bw_u(w, 1, 1);
    while (w->bits & 7) bw_u(w, 1, 0);
}

// NAL completo (start code + cabeçalho + RBSP com bytes de prevenção). Retorna o tamanho.
static int nal_wrap(uint8_t *dst, int cap, int header, const bw *w) {
    if (w->bits > (int)sizeof w->buf * 8 || cap < 5) return -1;
    int o = 0;
    dst[o++] = 0, dst[o++] = 0, dst[o++] = 0, dst[o++] = 1;
    dst[o++] = (uint8_t)header;
    int zeros = 0;
    for (int i = 0; i < w->bits / 8; i++) {
        const uint8_t c = w->buf[i];
        if (o + 2 > cap) return -1;
        if (zeros >= 2 && c <= 3) {
            dst[o++] = 3;
            zeros = 0;
        }
        dst[o++] = c;
        zeros = c == 0 ? zeros + 1 : 0;
    }
    return o;
}

// ------------------------------------------------------------------ encoder

// Configuração dos cabeçalhos: o mesmo struct gera o SPS/PPS e os parâmetros
// que vão pro driver (que escreve o cabeçalho das fatias): não podem divergir.
typedef struct {
    int profile_idc, constraint, level_idc;
    int w, h, mb_w, mb_h, fps;
    int cabac;
} enc_hdr;

#define LOG2_MAX_FRAME_NUM 16
#define LOG2_MAX_POC_LSB 16

static void write_sps(bw *w, const enc_hdr *c) {
    memset(w, 0, sizeof *w);
    bw_u(w, 8, (uint32_t)c->profile_idc);
    bw_u(w, 8, (uint32_t)c->constraint);
    bw_u(w, 8, (uint32_t)c->level_idc);
    bw_ue(w, 0); // seq_parameter_set_id
    bw_ue(w, LOG2_MAX_FRAME_NUM - 4);
    bw_ue(w, 0); // pic_order_cnt_type 0: o que todo driver aceita
    bw_ue(w, LOG2_MAX_POC_LSB - 4);
    bw_ue(w, 1); // max_num_ref_frames
    bw_u(w, 1, 0);
    bw_ue(w, (uint32_t)c->mb_w - 1);
    bw_ue(w, (uint32_t)c->mb_h - 1);
    bw_u(w, 1, 1); // frame_mbs_only_flag
    bw_u(w, 1, 1); // direct_8x8_inference_flag
    const int crop_r = c->mb_w * 16 - c->w, crop_b = c->mb_h * 16 - c->h;
    bw_u(w, 1, crop_r || crop_b);
    if (crop_r || crop_b) {
        bw_ue(w, 0);
        bw_ue(w, (uint32_t)crop_r / 2);
        bw_ue(w, 0);
        bw_ue(w, (uint32_t)crop_b / 2);
    }
    // VUI: matriz BT.601 de faixa limitada (a conta da nossa conversão),
    // timing pro controle de taxa e "sem reordenação" pra quem decodifica
    // soltar cada quadro na hora
    bw_u(w, 1, 1);
    bw_u(w, 1, 0); // aspect_ratio_info_present_flag
    bw_u(w, 1, 0); // overscan_info_present_flag
    bw_u(w, 1, 1); // video_signal_type_present_flag
    bw_u(w, 3, 5); // video_format: não especificado
    bw_u(w, 1, 0); // video_full_range_flag
    bw_u(w, 1, 1); // colour_description_present_flag
    bw_u(w, 8, 2); // colour_primaries: não especificado
    bw_u(w, 8, 2); // transfer_characteristics: não especificado
    bw_u(w, 8, 6); // matrix_coefficients: BT.601
    bw_u(w, 1, 0); // chroma_loc_info_present_flag
    bw_u(w, 1, 1); // timing_info_present_flag
    bw_u(w, 32, 1);
    bw_u(w, 32, (uint32_t)c->fps * 2);
    bw_u(w, 1, 0); // fixed_frame_rate_flag
    bw_u(w, 1, 0); // nal_hrd_parameters_present_flag
    bw_u(w, 1, 0); // vcl_hrd_parameters_present_flag
    bw_u(w, 1, 0); // pic_struct_present_flag
    bw_u(w, 1, 1); // bitstream_restriction_flag
    bw_u(w, 1, 1); // motion_vectors_over_pic_boundaries_flag
    bw_ue(w, 0);   // max_bytes_per_pic_denom
    bw_ue(w, 0);   // max_bits_per_mb_denom
    bw_ue(w, 15);  // log2_max_mv_length_horizontal
    bw_ue(w, 15);  // log2_max_mv_length_vertical
    bw_ue(w, 0);   // max_num_reorder_frames
    bw_ue(w, 1);   // max_dec_frame_buffering
    bw_trailing(w);
}

static void write_pps(bw *w, const enc_hdr *c) {
    memset(w, 0, sizeof *w);
    bw_ue(w, 0); // pic_parameter_set_id
    bw_ue(w, 0); // seq_parameter_set_id
    bw_u(w, 1, (uint32_t)c->cabac);
    bw_u(w, 1, 0); // bottom_field_pic_order_in_frame_present_flag
    bw_ue(w, 0);   // num_slice_groups_minus1
    bw_ue(w, 0);   // num_ref_idx_l0_default_active_minus1
    bw_ue(w, 0);   // num_ref_idx_l1_default_active_minus1
    bw_u(w, 1, 0); // weighted_pred_flag
    bw_u(w, 2, 0); // weighted_bipred_idc
    bw_se(w, 0);   // pic_init_qp_minus26
    bw_se(w, 0);   // pic_init_qs_minus26
    bw_se(w, 0);   // chroma_qp_index_offset
    bw_u(w, 1, 1); // deblocking_filter_control_present_flag
    bw_u(w, 1, 0); // constrained_intra_pred_flag
    bw_u(w, 1, 0); // redundant_pic_cnt_present_flag
    bw_trailing(w);
}

static void fill_seq(VAEncSequenceParameterBufferH264 *sq, const enc_hdr *c, int bitrate) {
    memset(sq, 0, sizeof *sq);
    sq->seq_parameter_set_id = 0;
    sq->level_idc = (uint8_t)c->level_idc;
    // GOP "infinito": quem decide o IDR somos nós (idr_pic_flag); o driver só
    // usa isso pra planejar a taxa
    sq->intra_period = 32767;
    sq->intra_idr_period = 32767;
    sq->ip_period = 1; // sem B-frames
    sq->bits_per_second = (uint32_t)bitrate;
    sq->max_num_ref_frames = 1;
    sq->picture_width_in_mbs = (uint16_t)c->mb_w;
    sq->picture_height_in_mbs = (uint16_t)c->mb_h;
    sq->seq_fields.bits.chroma_format_idc = 1;
    sq->seq_fields.bits.frame_mbs_only_flag = 1;
    sq->seq_fields.bits.direct_8x8_inference_flag = 1;
    sq->seq_fields.bits.log2_max_frame_num_minus4 = LOG2_MAX_FRAME_NUM - 4;
    sq->seq_fields.bits.pic_order_cnt_type = 0;
    sq->seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 = LOG2_MAX_POC_LSB - 4;
    const int crop_r = c->mb_w * 16 - c->w, crop_b = c->mb_h * 16 - c->h;
    sq->frame_cropping_flag = crop_r || crop_b;
    sq->frame_crop_right_offset = (uint32_t)crop_r / 2;
    sq->frame_crop_bottom_offset = (uint32_t)crop_b / 2;
    sq->vui_parameters_present_flag = 1;
    sq->vui_fields.bits.timing_info_present_flag = 1;
    sq->vui_fields.bits.bitstream_restriction_flag = 1;
    sq->vui_fields.bits.motion_vectors_over_pic_boundaries_flag = 1;
    sq->vui_fields.bits.log2_max_mv_length_horizontal = 15;
    sq->vui_fields.bits.log2_max_mv_length_vertical = 15;
    sq->num_units_in_tick = 1;
    sq->time_scale = (uint32_t)c->fps * 2;
}

static void fill_pic_fields(VAEncPictureParameterBufferH264 *pp, const enc_hdr *c) {
    pp->pic_parameter_set_id = 0;
    pp->seq_parameter_set_id = 0;
    pp->pic_init_qp = 26;
    pp->num_ref_idx_l0_active_minus1 = 0;
    pp->num_ref_idx_l1_active_minus1 = 0;
    pp->pic_fields.bits.entropy_coding_mode_flag = (uint32_t)c->cabac;
    pp->pic_fields.bits.deblocking_filter_control_present_flag = 1;
}

// Menor nível que comporta o tamanho, a taxa de quadros e o bitrate (tabela A-1)
static int pick_level(int mb_w, int mb_h, int fps, int bitrate) {
    static const struct {
        int level, mbps, fs, kbps;
    } t[] = {{30, 40500, 1620, 10000},     {31, 108000, 3600, 14000},    {32, 216000, 5120, 20000},    {40, 245760, 8192, 20000},
             {41, 245760, 8192, 50000},    {42, 522240, 8704, 50000},    {50, 589824, 22080, 135000},  {51, 983040, 36864, 240000},
             {52, 2073600, 36864, 240000}, {60, 4177920, 139264, 240000}, {61, 8355840, 139264, 480000}, {62, 16711680, 139264, 800000}};
    const long fs = (long)mb_w * mb_h, mbps = fs * fps, kbps = bitrate / 1000;
    for (size_t i = 0; i < sizeof t / sizeof t[0]; i++)
        if (fs <= t[i].fs && mbps <= t[i].mbps && kbps <= t[i].kbps && (long)mb_w * mb_w <= 8L * t[i].fs && (long)mb_h * mb_h <= 8L * t[i].fs) return t[i].level;
    return 62;
}

static void enc_hdr_init(enc_hdr *c, int w, int h, int fps, int bitrate, int main_profile) {
    memset(c, 0, sizeof *c);
    c->w = w;
    c->h = h;
    c->mb_w = (w + 15) / 16;
    c->mb_h = (h + 15) / 16;
    c->fps = fps;
    c->cabac = main_profile;
    // Main com CABAC (~10-20% menos bits) ou Constrained Baseline
    c->profile_idc = main_profile ? 77 : 66;
    c->constraint = main_profile ? 0 : 0xC0; // CB: constraint_set0 e set1
    c->level_idc = pick_level(c->mb_w, c->mb_h, fps, bitrate);
}

// HRD de alguns quadros: o IDR (bem maior que um P) ainda sai nítido, e um
// quadro sozinho não segura a rede por muito tempo.
#define HRD_FRAMES 6

struct vaenc {
    va_dev dev;
    char name[48];
    VAProfile profile;
    VAEntrypoint ep;
    VAConfigID cfg;
    VAContextID ctx;
    VASurfaceID surf[3]; // entrada + 2 reconstruídos (atual e referência)
    int nsurf;
    VABufferID coded;
    int w, h, aw, ah, fps, bitrate, rc_mode, packed, no_packed, rc_dirty;
    enc_hdr hdr;
    uint32_t frames, since_idr;
    int idr_id, cur;
    uint8_t *nv12; // quadro convertido (aw x ah), também a referência do autoteste
    uint8_t *out;
    size_t out_cap;
    VAImage up;
    int no_derive;
};

static void enc_teardown(vaenc *e) {
    VADisplay dpy = e->dev.dpy;
    if (e->up.image_id != VA_INVALID_ID) va.DestroyImage(dpy, e->up.image_id);
    e->up.image_id = VA_INVALID_ID;
    if (e->coded != VA_INVALID_ID) va.DestroyBuffer(dpy, e->coded);
    e->coded = VA_INVALID_ID;
    if (e->ctx != VA_INVALID_ID) va.DestroyContext(dpy, e->ctx);
    e->ctx = VA_INVALID_ID;
    if (e->nsurf) va.DestroySurfaces(dpy, e->surf, e->nsurf);
    e->nsurf = 0;
    if (e->cfg != VA_INVALID_ID) va.DestroyConfig(dpy, e->cfg);
    e->cfg = VA_INVALID_ID;
    e->no_derive = 0;
}

void vaenc_close(vaenc *e) {
    if (!e) return;
    if (e->dev.dpy) enc_teardown(e);
    va_close_dev(&e->dev);
    free(e->nv12);
    free(e->out);
    free(e);
}

static int enc_check(VADisplay dpy, char *why, int whylen) {
    const VAProfile profs[] = {VAProfileH264Main, VAProfileH264ConstrainedBaseline};
    for (int i = 0; i < 2; i++)
        if (va_has(dpy, profs[i], VAEntrypointEncSlice) || va_has(dpy, profs[i], VAEntrypointEncSliceLP)) return 1;
    snprintf(why, whylen, "o driver não codifica H.264");
    return 0;
}

static const char *va_err_str(VAStatus st) {
    return va.ErrorStr ? va.ErrorStr(st) : "?";
}

// Configuração + superfícies + contexto pra um perfil/entrypoint. 0 = ok.
static int enc_setup(vaenc *e, VAProfile prof, VAEntrypoint ep, char *why, int whylen) {
    VADisplay dpy = e->dev.dpy;
    VAConfigAttrib q[5] = {{VAConfigAttribRTFormat, 0}, {VAConfigAttribRateControl, 0}, {VAConfigAttribEncPackedHeaders, 0},
                           {VAConfigAttribMaxPictureWidth, 0}, {VAConfigAttribMaxPictureHeight, 0}};
    if (va.GetConfigAttributes(dpy, prof, ep, q, 5) != VA_STATUS_SUCCESS) {
        snprintf(why, whylen, "atributos do encoder indisponíveis");
        return -1;
    }
    if (q[0].value == VA_ATTRIB_NOT_SUPPORTED || !(q[0].value & VA_RT_FORMAT_YUV420)) {
        snprintf(why, whylen, "encoder sem YUV 4:2:0");
        return -1;
    }
    // CBR primeiro (o mais testado em todo driver; sem bits de enchimento,
    // tela parada continua barata), VBR se não tiver
    const uint32_t rc = q[1].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : q[1].value;
    e->rc_mode = rc & VA_RC_CBR ? VA_RC_CBR : rc & VA_RC_VBR ? VA_RC_VBR : 0;
    if (!e->rc_mode) {
        snprintf(why, whylen, "encoder sem controle de taxa CBR/VBR");
        return -1;
    }
    const uint32_t ph = q[2].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : q[2].value;
    e->packed = ph & VA_ENC_PACKED_HEADER_SEQUENCE ? ph & (VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE) : 0;
    if (e->no_packed || getenv("TELINHA_VAAPI_SEM_PACKED")) e->packed = 0;
    if ((q[3].value != VA_ATTRIB_NOT_SUPPORTED && q[3].value && (uint32_t)e->w > q[3].value) ||
        (q[4].value != VA_ATTRIB_NOT_SUPPORTED && q[4].value && (uint32_t)e->h > q[4].value)) {
        snprintf(why, whylen, "resolução %dx%d acima do máximo do encoder (%ux%u)", e->w, e->h, q[3].value, q[4].value);
        return -1;
    }
    VAConfigAttrib a[3];
    int na = 0;
    a[na].type = VAConfigAttribRTFormat, a[na++].value = VA_RT_FORMAT_YUV420;
    a[na].type = VAConfigAttribRateControl, a[na++].value = (uint32_t)e->rc_mode;
    if (q[2].value != VA_ATTRIB_NOT_SUPPORTED) a[na].type = VAConfigAttribEncPackedHeaders, a[na++].value = (uint32_t)e->packed;
    VAStatus st = va.CreateConfig(dpy, prof, ep, a, na, &e->cfg);
    if (st != VA_STATUS_SUCCESS) {
        e->cfg = VA_INVALID_ID;
        snprintf(why, whylen, "vaCreateConfig: %s", va_err_str(st));
        return -1;
    }
    st = va.CreateSurfaces(dpy, VA_RT_FORMAT_YUV420, (unsigned)e->aw, (unsigned)e->ah, e->surf, 3, NULL, 0);
    if (st != VA_STATUS_SUCCESS) {
        snprintf(why, whylen, "vaCreateSurfaces: %s", va_err_str(st));
        return -1;
    }
    e->nsurf = 3;
    st = va.CreateContext(dpy, e->cfg, e->aw, e->ah, VA_PROGRESSIVE, e->surf, 3, &e->ctx);
    if (st != VA_STATUS_SUCCESS) {
        e->ctx = VA_INVALID_ID;
        snprintf(why, whylen, "vaCreateContext: %s", va_err_str(st));
        return -1;
    }
    // saída: no pior caso um IDR do tamanho do quadro cru
    const unsigned coded_size = (unsigned)((size_t)e->aw * e->ah * 3 / 2 + 256 * 1024);
    st = va.CreateBuffer(dpy, e->ctx, VAEncCodedBufferType, coded_size, 1, NULL, &e->coded);
    if (st != VA_STATUS_SUCCESS) {
        e->coded = VA_INVALID_ID;
        snprintf(why, whylen, "buffer de saída: %s", va_err_str(st));
        return -1;
    }
    e->profile = prof;
    e->ep = ep;
    enc_hdr_init(&e->hdr, e->w, e->h, e->fps, e->bitrate, prof != VAProfileH264ConstrainedBaseline);
    e->frames = 0;
    e->since_idr = 0;
    e->cur = 0;
    e->rc_dirty = 1;
    return 0;
}

// BGRX/RGBX -> NV12 (BT.601 faixa limitada, a mesma conta do openh264/hwenc_mf),
// com as bordas até o múltiplo de 16 repetindo o último pixel.
static void to_nv12(const uint8_t *src, int stride, int w, int h, int format, uint8_t *dst, int aw, int ah) {
    const int ri = format == HWENC_RGBX ? 0 : 2, bi = format == HWENC_RGBX ? 2 : 0;
    uint8_t *uv = dst + (size_t)aw * ah;
    for (int y = 0; y < h; y += 2) {
        const uint8_t *r0 = src + (size_t)y * stride, *r1 = r0 + stride;
        uint8_t *y0 = dst + (size_t)y * aw, *y1 = y0 + aw;
        uint8_t *uvr = uv + (size_t)(y / 2) * aw;
        for (int x = 0; x < w; x += 2) {
            int R = 0, G = 0, B = 0;
            for (int k = 0; k < 4; k++) {
                const uint8_t *p = (k < 2 ? r0 : r1) + (size_t)(x + (k & 1)) * 4;
                const int r = p[ri], g = p[1], b = p[bi];
                const int yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                (k < 2 ? y0 : y1)[x + (k & 1)] = (uint8_t)(yy > 255 ? 255 : yy);
                R += r;
                G += g;
                B += b;
            }
            R = (R + 2) / 4;
            G = (G + 2) / 4;
            B = (B + 2) / 4;
            const int u = ((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128;
            const int v = ((112 * R - 94 * G - 18 * B + 128) >> 8) + 128;
            uvr[x] = (uint8_t)(u < 0 ? 0 : u > 255 ? 255 : u);
            uvr[x + 1] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
        for (int x = w; x < aw; x += 2) {
            y0[x] = y0[x + 1] = y0[w - 1];
            y1[x] = y1[x + 1] = y1[w - 1];
            uvr[x] = uvr[w - 2];
            uvr[x + 1] = uvr[w - 1];
        }
    }
    for (int y = h; y < ah; y++) memcpy(dst + (size_t)y * aw, dst + (size_t)(h - 1) * aw, (size_t)aw);
    for (int y = h / 2; y < ah / 2; y++) memcpy(uv + (size_t)y * aw, uv + (size_t)(h / 2 - 1) * aw, (size_t)aw);
}

static int upload(vaenc *e) {
    VADisplay dpy = e->dev.dpy;
    const VASurfaceID surf = e->surf[0];
    VAImage img;
    int derived = 0;
    if (!e->no_derive) {
        if (va.DeriveImage(dpy, surf, &img) == VA_STATUS_SUCCESS) {
            if (img.format.fourcc == VA_FOURCC_NV12 && img.width >= (unsigned)e->aw && img.height >= (unsigned)e->ah) derived = 1;
            else va.DestroyImage(dpy, img.image_id);
        }
        if (!derived) e->no_derive = 1;
    }
    if (!derived) {
        if (e->up.image_id == VA_INVALID_ID) {
            VAImageFormat f;
            memset(&f, 0, sizeof f);
            f.fourcc = VA_FOURCC_NV12;
            f.byte_order = VA_LSB_FIRST;
            f.bits_per_pixel = 12;
            if (va.CreateImage(dpy, &f, e->aw, e->ah, &e->up) != VA_STATUS_SUCCESS) {
                e->up.image_id = VA_INVALID_ID;
                return -1;
            }
        }
        img = e->up;
    }
    void *ptr = NULL;
    int rc = -1;
    if (va.MapBuffer(dpy, img.buf, &ptr) == VA_STATUS_SUCCESS) {
        uint8_t *base = ptr;
        const uint8_t *uv = e->nv12 + (size_t)e->aw * e->ah;
        for (int y = 0; y < e->ah; y++) memcpy(base + img.offsets[0] + (size_t)y * img.pitches[0], e->nv12 + (size_t)y * e->aw, (size_t)e->aw);
        for (int y = 0; y < e->ah / 2; y++) memcpy(base + img.offsets[1] + (size_t)y * img.pitches[1], uv + (size_t)y * e->aw, (size_t)e->aw);
        va.UnmapBuffer(dpy, img.buf);
        rc = 0;
    }
    if (derived) va.DestroyImage(dpy, img.image_id);
    else if (rc == 0 && va.PutImage(dpy, surf, img.image_id, 0, 0, (unsigned)e->aw, (unsigned)e->ah, 0, 0, (unsigned)e->aw, (unsigned)e->ah) != VA_STATUS_SUCCESS)
        rc = -1;
    return rc;
}

static int misc_buffer(vaenc *e, VAEncMiscParameterType type, const void *data, size_t size, VABufferID *id) {
    uint8_t buf[sizeof(VAEncMiscParameterBuffer) + 128];
    if (size > 128) return -1;
    memset(buf, 0, sizeof buf);
    VAEncMiscParameterBuffer *m = (VAEncMiscParameterBuffer *)buf;
    m->type = type;
    memcpy(m->data, data, size);
    return va.CreateBuffer(e->dev.dpy, e->ctx, VAEncMiscParameterBufferType, (unsigned)(sizeof *m + size), 1, buf, id) == VA_STATUS_SUCCESS ? 0 : -1;
}

static int packed_buffers(vaenc *e, int type, const uint8_t *data, int bytes, VABufferID *ids) {
    VAEncPackedHeaderParameterBuffer ph;
    memset(&ph, 0, sizeof ph);
    ph.type = (uint32_t)type;
    ph.bit_length = (uint32_t)bytes * 8;
    ph.has_emulation_bytes = 1;
    if (va.CreateBuffer(e->dev.dpy, e->ctx, VAEncPackedHeaderParameterBufferType, sizeof ph, 1, &ph, &ids[0]) != VA_STATUS_SUCCESS) return -1;
    if (va.CreateBuffer(e->dev.dpy, e->ctx, VAEncPackedHeaderDataBufferType, (unsigned)bytes, 1, (void *)data, &ids[1]) != VA_STATUS_SUCCESS) {
        va.DestroyBuffer(e->dev.dpy, ids[0]);
        return -1;
    }
    return 0;
}

int vaenc_encode(vaenc *e, const uint8_t *pixels, int stride, int format, int force_idr, const uint8_t **out, int *out_len, int *is_idr) {
    VADisplay dpy = e->dev.dpy;
    const int idr = force_idr || e->frames == 0;
    to_nv12(pixels, stride, e->w, e->h, format, e->nv12, e->aw, e->ah);
    if (upload(e) < 0) return -1;
    if (idr) {
        e->since_idr = 0;
        e->idr_id = (e->idr_id + 1) & 0xffff; // dois IDRs seguidos não podem ter o mesmo idr_pic_id
    }
    const VASurfaceID rec = e->surf[1 + e->cur], ref = e->surf[1 + (e->cur ^ 1)];
    const int frame_num = (int)(e->since_idr % (1u << LOG2_MAX_FRAME_NUM));
    const int poc = (int)(2 * e->since_idr);
    VAPictureH264 refpic; // o quadro anterior (só nos P)
    memset(&refpic, 0, sizeof refpic);
    refpic.picture_id = ref;
    refpic.frame_idx = (uint32_t)((e->since_idr - 1) % (1u << LOG2_MAX_FRAME_NUM));
    refpic.flags = VA_PICTURE_H264_SHORT_TERM_REFERENCE;
    refpic.TopFieldOrderCnt = poc - 2;
    refpic.BottomFieldOrderCnt = poc - 2;

    VABufferID ids[16];
    int n = 0, ok = 1;
    if (idr) {
        VAEncSequenceParameterBufferH264 sq;
        fill_seq(&sq, &e->hdr, e->bitrate);
        ok = va.CreateBuffer(dpy, e->ctx, VAEncSequenceParameterBufferType, sizeof sq, 1, &sq, &ids[n]) == VA_STATUS_SUCCESS && ++n;
        if (ok && e->packed) {
            // SPS e PPS nossos; se o driver só aceita o de sequência, os dois vão nele
            uint8_t hb[512];
            bw w;
            write_sps(&w, &e->hdr);
            int len = nal_wrap(hb, sizeof hb, 0x67, &w);
            write_pps(&w, &e->hdr);
            int plen = len > 0 ? nal_wrap(hb + len, (int)sizeof hb - len, 0x68, &w) : -1;
            if (len < 0 || plen < 0) ok = 0;
            else if (e->packed & VA_ENC_PACKED_HEADER_PICTURE) {
                ok = packed_buffers(e, VAEncPackedHeaderSequence, hb, len, &ids[n]) == 0 && (n += 2);
                ok = ok && packed_buffers(e, VAEncPackedHeaderPicture, hb + len, plen, &ids[n]) == 0 && (n += 2);
            } else
                ok = packed_buffers(e, VAEncPackedHeaderSequence, hb, len + plen, &ids[n]) == 0 && (n += 2);
        }
    }
    if (ok && (idr || e->rc_dirty)) {
        VAEncMiscParameterRateControl rc;
        memset(&rc, 0, sizeof rc);
        rc.bits_per_second = (uint32_t)e->bitrate;
        rc.target_percentage = 100;
        rc.window_size = 1000;
        rc.rc_flags.bits.disable_frame_skip = 1;   // pular quadro é decisão do sharer
        rc.rc_flags.bits.disable_bit_stuffing = 1; // tela parada não vira enchimento
        VAEncMiscParameterHRD hrd;
        memset(&hrd, 0, sizeof hrd);
        hrd.buffer_size = (uint32_t)((int64_t)e->bitrate * HRD_FRAMES / e->fps);
        hrd.initial_buffer_fullness = hrd.buffer_size;
        VAEncMiscParameterFrameRate fr;
        memset(&fr, 0, sizeof fr);
        fr.framerate = (1u << 16) | (uint32_t)e->fps;
        ok = misc_buffer(e, VAEncMiscParameterTypeRateControl, &rc, sizeof rc, &ids[n]) == 0 && ++n;
        ok = ok && misc_buffer(e, VAEncMiscParameterTypeHRD, &hrd, sizeof hrd, &ids[n]) == 0 && ++n;
        ok = ok && misc_buffer(e, VAEncMiscParameterTypeFrameRate, &fr, sizeof fr, &ids[n]) == 0 && ++n;
        if (ok) e->rc_dirty = 0;
    }
    if (ok) {
        VAEncPictureParameterBufferH264 pp;
        memset(&pp, 0, sizeof pp);
        pp.CurrPic.picture_id = rec;
        pp.CurrPic.frame_idx = (uint32_t)frame_num;
        pp.CurrPic.TopFieldOrderCnt = poc;
        pp.CurrPic.BottomFieldOrderCnt = poc;
        for (int i = 0; i < 16; i++) va_pic_invalid(&pp.ReferenceFrames[i]);
        if (!idr) pp.ReferenceFrames[0] = refpic;
        pp.coded_buf = e->coded;
        pp.frame_num = (uint16_t)frame_num;
        fill_pic_fields(&pp, &e->hdr);
        pp.pic_fields.bits.idr_pic_flag = (uint32_t)idr;
        pp.pic_fields.bits.reference_pic_flag = 1;
        ok = va.CreateBuffer(dpy, e->ctx, VAEncPictureParameterBufferType, sizeof pp, 1, &pp, &ids[n]) == VA_STATUS_SUCCESS && ++n;
    }
    if (ok) {
        VAEncSliceParameterBufferH264 sp;
        memset(&sp, 0, sizeof sp);
        sp.macroblock_address = 0;
        sp.num_macroblocks = (uint32_t)(e->hdr.mb_w * e->hdr.mb_h);
        sp.macroblock_info = VA_INVALID_ID;
        sp.slice_type = idr ? SL_I : SL_P;
        sp.pic_parameter_set_id = 0;
        sp.idr_pic_id = (uint16_t)e->idr_id;
        sp.pic_order_cnt_lsb = (uint16_t)(poc % (1 << LOG2_MAX_POC_LSB));
        sp.num_ref_idx_active_override_flag = 0;
        sp.num_ref_idx_l0_active_minus1 = 0;
        for (int i = 0; i < 32; i++) {
            va_pic_invalid(&sp.RefPicList0[i]);
            va_pic_invalid(&sp.RefPicList1[i]);
        }
        if (!idr) sp.RefPicList0[0] = refpic;
        sp.cabac_init_idc = 0;
        sp.slice_qp_delta = 0;
        sp.disable_deblocking_filter_idc = 0;
        ok = va.CreateBuffer(dpy, e->ctx, VAEncSliceParameterBufferType, sizeof sp, 1, &sp, &ids[n]) == VA_STATUS_SUCCESS && ++n;
    }
    int rc = -1;
    if (ok && va.BeginPicture(dpy, e->ctx, e->surf[0]) == VA_STATUS_SUCCESS) {
        ok = va.RenderPicture(dpy, e->ctx, ids, n) == VA_STATUS_SUCCESS;
        ok = va.EndPicture(dpy, e->ctx) == VA_STATUS_SUCCESS && ok;
        if (ok && va.SyncSurface(dpy, e->surf[0]) == VA_STATUS_SUCCESS) {
            VACodedBufferSegment *seg = NULL;
            if (va.MapBuffer(dpy, e->coded, (void **)&seg) == VA_STATUS_SUCCESS) {
                size_t total = 0;
                int overflow = 0;
                for (VACodedBufferSegment *s = seg; s; s = s->next) {
                    total += s->size;
                    if (s->status & VA_CODED_BUF_STATUS_SLICE_OVERFLOW_MASK) overflow = 1;
                }
                if (total > e->out_cap) {
                    free(e->out);
                    e->out = malloc(total);
                    e->out_cap = e->out ? total : 0;
                }
                if (e->out && !overflow && total > 0) {
                    size_t o = 0;
                    for (VACodedBufferSegment *s = seg; s; s = s->next) {
                        memcpy(e->out + o, s->buf, s->size);
                        o += s->size;
                    }
                    *out = e->out;
                    *out_len = (int)total;
                    *is_idr = idr;
                    rc = 0;
                }
                va.UnmapBuffer(dpy, e->coded);
            }
        }
    }
    for (int i = 0; i < n; i++) va.DestroyBuffer(dpy, ids[i]);
    if (rc < 0) {
        e->frames = 0; // a referência pode ter ficado ruim: o próximo é IDR
        return -1;
    }
    e->cur ^= 1;
    e->since_idr++;
    e->frames++;
    return 0;
}

void vaenc_set_bitrate(vaenc *e, int bitrate) {
    if (bitrate <= 0 || bitrate == e->bitrate) return;
    e->bitrate = bitrate;
    e->rc_dirty = 1; // vai junto com o próximo quadro
}

const char *vaenc_name(vaenc *e) {
    return e->name;
}

// ---------------------------------------------------------------- autoteste

// Degradê + "texto" (traços finos e contrastados) andando 6 pixels por quadro:
// pega erro de cor, de referência (P) e de borda/corte.
static void synth_frame(uint8_t *img, int w, int h, int f) {
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint8_t *p = img + ((size_t)y * w + x) * 4;
            int r = x * 255 / w, g = y * 255 / h, b = 255 - (x + y) * 255 / (w + h);
            if (x >= w / 8 && x < w - w / 8 && y >= h / 4 && y < h - h / 4) {
                const int xx = x + 6 * f, cx = xx % 8, cy = y % 16;
                const int glyph = ((xx / 8) * 7 + (y / 16) * 13) % 3 != 0;
                const int stroke = cy >= 2 && cy < 14 && (cx == 1 || cy == 3 || (cx == cy / 2 && cy < 12));
                r = g = b = glyph && stroke ? 30 : 235;
                if (glyph && stroke && (xx / 8) % 5 == 0) r = 220, g = 40, b = 40; // umas letras vermelhas
            }
            p[0] = (uint8_t)b, p[1] = (uint8_t)g, p[2] = (uint8_t)r, p[3] = 255;
        }
    }
}

static double psnr_of(double sse, double n) {
    return sse <= 0 ? 99.0 : 10.0 * log10(255.0 * 255.0 * n / sse);
}

// Tipos de NAL presentes no Annex B (bit t = tipo t)
static uint32_t nal_types(const uint8_t *d, int n) {
    uint32_t m = 0;
    for (int i = 0; i + 3 < n; i++)
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            m |= 1u << (d[i + 3] & 0x1f);
            i += 2;
        }
    return m;
}

static int selftest(vaenc *e, char *why, int whylen) {
    ISVCDecoder *dec = NULL;
    if (WelsCreateDecoder(&dec) != 0 || !dec) {
        snprintf(why, whylen, "autoteste: sem o decoder openh264");
        return -1;
    }
    int trace = WELS_LOG_QUIET;
    (*dec)->SetOption(dec, DECODER_OPTION_TRACE_LEVEL, &trace);
    SDecodingParam dp;
    memset(&dp, 0, sizeof dp);
    dp.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
    dp.eEcActiveIdc = ERROR_CON_DISABLE;
    dp.uiTargetDqLayer = 0xff;
    uint8_t *img = malloc((size_t)e->w * e->h * 4);
    int rc = img && (*dec)->Initialize(dec, &dp) == 0 ? 0 : -1;
    if (rc < 0) snprintf(why, whylen, "autoteste: openh264 não iniciou");
    for (int f = 0; f < 3 && rc == 0; f++) {
        synth_frame(img, e->w, e->h, f);
        const uint8_t *bits = NULL;
        int len = 0, idr = 0;
        if (vaenc_encode(e, img, e->w * 4, HWENC_BGRX, f == 0, &bits, &len, &idr) < 0) {
            snprintf(why, whylen, "autoteste falhou: o driver não codificou o quadro %d", f);
            rc = -1;
            break;
        }
        const uint32_t types = nal_types(bits, len);
        const uint32_t want = f == 0 ? (1u << 7 | 1u << 8 | 1u << 5) : 1u << 1;
        if (idr != (f == 0) || (types & want) != want || (f > 0 && (types & (1u << 5)))) {
            snprintf(why, whylen, "autoteste falhou: quadro %d com NALs inesperados (0x%x)", f, types);
            rc = -1;
            break;
        }
        uint8_t *planes[3] = {NULL, NULL, NULL};
        SBufferInfo info;
        memset(&info, 0, sizeof info);
        const DECODING_STATE st = (*dec)->DecodeFrameNoDelay(dec, bits, len, planes, &info);
        // Main: o openh264 segura o quadro achando que pode haver reordenação
        if (st == dsErrorFree && info.iBufferStatus != 1) (*dec)->FlushFrame(dec, planes, &info);
        if (st != dsErrorFree || info.iBufferStatus != 1 || !planes[0]) {
            snprintf(why, whylen, "autoteste falhou: o openh264 não decodificou o quadro %d (0x%x)", f, (unsigned)st);
            rc = -1;
            break;
        }
        const SSysMEMBuffer *sb = &info.UsrData.sSystemBuffer;
        if (sb->iWidth != e->w || sb->iHeight != e->h) {
            snprintf(why, whylen, "autoteste falhou: saiu %dx%d em vez de %dx%d", sb->iWidth, sb->iHeight, e->w, e->h);
            rc = -1;
            break;
        }
        double sy = 0, sc = 0;
        const uint8_t *uv = e->nv12 + (size_t)e->aw * e->ah;
        for (int y = 0; y < e->h; y++)
            for (int x = 0; x < e->w; x++) {
                const double dd = (double)planes[0][(size_t)y * sb->iStride[0] + x] - e->nv12[(size_t)y * e->aw + x];
                sy += dd * dd;
            }
        for (int y = 0; y < e->h / 2; y++)
            for (int x = 0; x < e->w / 2; x++) {
                const double du = (double)planes[1][(size_t)y * sb->iStride[1] + x] - uv[(size_t)y * e->aw + 2 * x];
                const double dv = (double)planes[2][(size_t)y * sb->iStride[1] + x] - uv[(size_t)y * e->aw + 2 * x + 1];
                sc += du * du + dv * dv;
            }
        const double py = psnr_of(sy, (double)e->w * e->h), pc = psnr_of(sc, (double)e->w * e->h / 2);
        if (getenv("TELINHA_DEBUG")) fprintf(stderr, "[telinha] VA-API autoteste: quadro %d, %d bytes, Y %.1f dB, UV %.1f dB\n", f, len, py, pc);
        if (py < 30 || pc < 30) {
            snprintf(why, whylen, "autoteste falhou: quadro %d com Y %.1f dB / UV %.1f dB (mínimo 30)", f, py, pc);
            rc = -1;
        }
    }
    free(img);
    (*dec)->Uninitialize(dec);
    WelsDestroyDecoder(dec);
    return rc;
}

vaenc *vaenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen) {
    (void)screen_mode;     // o VA-API não tem um ajuste genérico pra "conteúdo de tela"
    (void)temporal_layers; // uma camada só (ver o começo do arquivo)
    if (codec != HW_CODEC_H264) {
        set_err(err, errlen, "VA-API: codec ainda não suportado%s", "");
        return NULL;
    }
    if (width < 16 || height < 16 || width % 2 || height % 2 || width > 8192 || height > 8192) {
        set_err(err, errlen, "VA-API: tamanho inválido%s", "");
        return NULL;
    }
    vaenc *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->cfg = VA_INVALID_ID;
    e->ctx = VA_INVALID_ID;
    e->coded = VA_INVALID_ID;
    e->up.image_id = VA_INVALID_ID;
    e->w = width;
    e->h = height;
    e->aw = (width + 15) & ~15;
    e->ah = (height + 15) & ~15;
    e->fps = fps < 1 ? 30 : fps > 240 ? 240 : fps;
    e->nv12 = malloc((size_t)e->aw * e->ah * 3 / 2);
    if (!e->nv12) {
        vaenc_close(e);
        return NULL;
    }
    char why[200] = "";
    if (va_open_dev(&e->dev, enc_check, why, sizeof why) < 0) {
        set_err(err, errlen, "VA-API: %s", why);
        vaenc_close(e);
        return NULL;
    }
    const char *vendor = va.QueryVendorString(e->dev.dpy);
    const char *vs = vendor_short(vendor);
    if (vs) snprintf(e->name, sizeof e->name, "VA-API (%s)", vs);
    else snprintf(e->name, sizeof e->name, "VA-API (%.30s)", vendor ? vendor : "?");

    // autoteste com folga de bitrate: o que interessa é se a imagem sai certa
    const int real = bitrate > 0 ? bitrate : 2000000;
    int64_t generous = (int64_t)width * height * e->fps / 3;
    if (generous > 50000000) generous = 50000000;
    const int test_rate = real > generous ? real : (int)generous;
    const struct {
        VAProfile prof;
        VAEntrypoint ep;
    } cands[] = {{VAProfileH264Main, VAEntrypointEncSlice},
                 {VAProfileH264Main, VAEntrypointEncSliceLP},
                 {VAProfileH264ConstrainedBaseline, VAEntrypointEncSlice},
                 {VAProfileH264ConstrainedBaseline, VAEntrypointEncSliceLP}};
    snprintf(why, sizeof why, "nenhum perfil H.264 Main/Constrained Baseline com encoder");
    for (size_t i = 0; i < sizeof cands / sizeof cands[0]; i++) {
        if (!va_has(e->dev.dpy, cands[i].prof, cands[i].ep)) continue;
        // com os nossos SPS/PPS e, se não passar no autoteste, com os do driver
        for (int attempt = 0; attempt < 2; attempt++) {
            e->no_packed = attempt;
            e->bitrate = test_rate;
            if (enc_setup(e, cands[i].prof, cands[i].ep, why, sizeof why) == 0 && selftest(e, why, sizeof why) == 0) {
                e->bitrate = real;
                e->rc_dirty = 1;
                e->frames = 0; // o primeiro quadro de verdade é IDR
                if (getenv("TELINHA_DEBUG"))
                    fprintf(stderr, "[telinha] %s: %s, %s, %s, cabeçalhos %s\n", e->name, vendor ? vendor : "?",
                            cands[i].prof == VAProfileH264Main ? "Main" : "Constrained Baseline", cands[i].ep == VAEntrypointEncSliceLP ? "LP" : "normal",
                            e->packed ? "nossos" : "do driver");
                return e;
            }
            const int had_packed = e->packed;
            enc_teardown(e);
            if (!had_packed) break; // sem cabeçalhos nossos não há o que variar
        }
    }
    set_err(err, errlen, "VA-API: %s", why);
    vaenc_close(e);
    return NULL;
}

// ------------------------------------------------- teste dos cabeçalhos

#define T_CHECK(cond, ...)                                             \
    do {                                                               \
        if (!(cond)) {                                                 \
            if (err && errlen > 0) snprintf(err, errlen, __VA_ARGS__); \
            return -1;                                                 \
        }                                                              \
    } while (0)

// Acha o primeiro NAL em buf e devolve o RBSP (sem start code nem prevenção)
static int first_nal_rbsp(const uint8_t *buf, int len, uint8_t *rbsp) {
    const uint8_t *end = buf + len, *p = find_sc(buf, end);
    if (p >= end) return -1;
    const uint8_t *nal = p + 3, *q = find_sc(nal, end);
    return unescape(nal, (int)(q - nal), rbsp);
}

int hwva_test_headers(char *err, int errlen) {
    // Exp-Golomb ida e volta
    {
        bw w;
        memset(&w, 0, sizeof w);
        static const uint32_t ues[] = {0, 1, 2, 3, 7, 8, 254, 255, 256, 1000, 65535, 65536, 1u << 20};
        static const int32_t ses[] = {0, 1, -1, 2, -2, 63, -64, 1000, -1000, 32767, -32768};
        for (size_t i = 0; i < sizeof ues / sizeof ues[0]; i++) bw_ue(&w, ues[i]);
        for (size_t i = 0; i < sizeof ses / sizeof ses[0]; i++) bw_se(&w, ses[i]);
        bw_u(&w, 32, 0xdeadbeef);
        br b = {w.buf, (w.bits + 7) / 8, 0, 0};
        for (size_t i = 0; i < sizeof ues / sizeof ues[0]; i++) T_CHECK(br_ue(&b) == ues[i], "ue(%u) não voltou igual", ues[i]);
        for (size_t i = 0; i < sizeof ses / sizeof ses[0]; i++) T_CHECK(br_se(&b) == ses[i], "se(%d) não voltou igual", ses[i]);
        T_CHECK(br_u(&b, 32) == 0xdeadbeef && !b.err, "u(32) não voltou igual");
    }
    // bytes de prevenção: 00 00 0x (x <= 3) no payload ganha um 03; unescape desfaz
    {
        static const uint8_t payload[] = {0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x03, 0xff, 0x00, 0x00, 0x04, 0x80};
        bw w;
        memset(&w, 0, sizeof w);
        for (size_t i = 0; i < sizeof payload; i++) bw_u(&w, 8, payload[i]);
        uint8_t nal[64], back[64];
        const int n = nal_wrap(nal, sizeof nal, 0x06, &w);
        T_CHECK(n > 0, "nal_wrap falhou");
        for (int i = 4; i + 2 < n; i++) T_CHECK(!(nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] <= 2), "sequência proibida 00 00 0%d no NAL", nal[i + 2]);
        const int m = first_nal_rbsp(nal, n, back);
        T_CHECK(m == (int)sizeof payload + 1 && !memcmp(back + 1, payload, sizeof payload), "prevenção de emulação não voltou igual");
    }
    // SPS/PPS do encoder lidos pelo parser do decoder, conferidos com os parâmetros do driver
    static const struct {
        int w, h, fps, bitrate, main;
    } cfgs[] = {{1920, 1080, 30, 4000000, 1}, {1366, 768, 60, 2500000, 0}, {64, 48, 5, 100000, 1}, {3840, 2160, 60, 20000000, 1},
                {1280, 720, 30, 2000000, 0}, {2560, 1440, 144, 30000000, 1}, {1024, 768, 30, 1500000, 1}};
    for (size_t i = 0; i < sizeof cfgs / sizeof cfgs[0]; i++) {
        enc_hdr c;
        enc_hdr_init(&c, cfgs[i].w, cfgs[i].h, cfgs[i].fps, cfgs[i].bitrate, cfgs[i].main);
        uint8_t nal[512], rbsp[512];
        bw w;
        write_sps(&w, &c);
        int n = nal_wrap(nal, sizeof nal, 0x67, &w);
        T_CHECK(n > 0, "SPS não coube");
        int m = first_nal_rbsp(nal, n, rbsp);
        T_CHECK(m > 1 && rbsp[0] == 0x67, "SPS: cabeçalho do NAL");
        br b = {rbsp, m, 8, 0};
        h264_sps s;
        T_CHECK(parse_sps(&b, &s) == 0, "SPS %dx%d não passou no parser", c.w, c.h);
        T_CHECK(s.profile_idc == (cfgs[i].main ? 77 : 66) && s.constraint == (cfgs[i].main ? 0 : 0xC0), "SPS: perfil %d/%x", s.profile_idc, s.constraint);
        T_CHECK(s.level_idc == c.level_idc && s.level_idc >= 30, "SPS: nível %d", s.level_idc);
        T_CHECK(s.mb_w * 16 - s.crop_l - s.crop_r == c.w && s.map_h * 16 - s.crop_t - s.crop_b == c.h && s.crop_l == 0 && s.crop_t == 0,
                "SPS: tamanho %dx%d virou %dx%d", c.w, c.h, s.mb_w * 16 - s.crop_r, s.map_h * 16 - s.crop_b);
        T_CHECK(s.frame_mbs_only && s.chroma_format_idc == 1 && s.max_num_ref_frames == 1 && !s.gaps_allowed && s.direct_8x8, "SPS: estrutura");
        T_CHECK(s.poc_type == 0 && s.log2_max_poc_lsb == LOG2_MAX_POC_LSB && s.log2_max_frame_num == LOG2_MAX_FRAME_NUM, "SPS: POC/frame_num");
        T_CHECK(s.vui && s.vui_matrix == 6 && s.vui_full_range == 0 && s.vui_reorder == 0 && s.vui_max_dec == 1 && s.vui_mv_over_bounds == 1,
                "SPS: VUI (matriz %d, faixa %d, reordenação %d, dpb %d)", s.vui_matrix, s.vui_full_range, s.vui_reorder, s.vui_max_dec);
        T_CHECK(s.vui_num_units == 1 && s.vui_time_scale == (uint32_t)c.fps * 2, "SPS: timing %u/%u", s.vui_num_units, s.vui_time_scale);
        // os mesmos valores nos parâmetros de sequência do VA-API (o driver escreve as fatias com eles)
        VAEncSequenceParameterBufferH264 sq;
        fill_seq(&sq, &c, cfgs[i].bitrate);
        T_CHECK(sq.picture_width_in_mbs == s.mb_w && sq.picture_height_in_mbs == s.map_h && sq.level_idc == s.level_idc, "seq: tamanho/nível");
        T_CHECK(sq.seq_fields.bits.log2_max_frame_num_minus4 + 4 == (uint32_t)s.log2_max_frame_num &&
                    sq.seq_fields.bits.log2_max_pic_order_cnt_lsb_minus4 + 4 == (uint32_t)s.log2_max_poc_lsb &&
                    sq.seq_fields.bits.pic_order_cnt_type == (uint32_t)s.poc_type && sq.max_num_ref_frames == (uint32_t)s.max_num_ref_frames &&
                    sq.seq_fields.bits.frame_mbs_only_flag == (uint32_t)s.frame_mbs_only &&
                    sq.seq_fields.bits.direct_8x8_inference_flag == (uint32_t)s.direct_8x8 && sq.seq_fields.bits.chroma_format_idc == 1,
                "seq: campos diferentes do SPS");
        T_CHECK(sq.frame_cropping_flag == (s.crop_r || s.crop_b) && sq.frame_crop_right_offset * 2 == (uint32_t)s.crop_r &&
                    sq.frame_crop_bottom_offset * 2 == (uint32_t)s.crop_b && sq.frame_crop_left_offset == 0 && sq.frame_crop_top_offset == 0,
                "seq: corte diferente do SPS");
        T_CHECK(sq.num_units_in_tick == s.vui_num_units && sq.time_scale == s.vui_time_scale && sq.vui_parameters_present_flag, "seq: timing");

        write_pps(&w, &c);
        n = nal_wrap(nal, sizeof nal, 0x68, &w);
        m = first_nal_rbsp(nal, n, rbsp);
        T_CHECK(m > 1 && rbsp[0] == 0x68, "PPS: cabeçalho do NAL");
        h264_sps *tab[32] = {0};
        tab[0] = &s;
        b = (br){rbsp, m, 8, 0};
        h264_pps p;
        T_CHECK(parse_pps(&b, &p, tab) == 0, "PPS não passou no parser");
        VAEncPictureParameterBufferH264 pp;
        memset(&pp, 0, sizeof pp);
        fill_pic_fields(&pp, &c);
        T_CHECK(p.id == pp.pic_parameter_set_id && p.sps_id == pp.seq_parameter_set_id && p.cabac == (int)pp.pic_fields.bits.entropy_coding_mode_flag &&
                    p.cabac == cfgs[i].main,
                "PPS: ids/entropia");
        T_CHECK(p.pic_init_qp == pp.pic_init_qp && p.num_ref_idx_default[0] == pp.num_ref_idx_l0_active_minus1 + 1 &&
                    p.deblocking_filter_control_present == (int)pp.pic_fields.bits.deblocking_filter_control_present_flag &&
                    p.chroma_qp_index_offset == pp.chroma_qp_index_offset && !p.weighted_pred && !p.transform_8x8 && !p.bottom_field_pic_order &&
                    !p.redundant_pic_cnt_present && !p.constrained_intra_pred,
                "PPS: campos diferentes dos parâmetros do quadro");
    }
    // nível: 1080p30 -> 4.0, 1080p60 -> 4.2, 4K60 -> 5.2, 720p30 -> 3.1
    T_CHECK(pick_level(120, 68, 30, 4000000) == 40 && pick_level(120, 68, 60, 8000000) == 42 && pick_level(240, 135, 60, 20000000) == 52 &&
                pick_level(80, 45, 30, 2000000) == 31,
            "nível escolhido errado");
    // matrizes padrão em ordem raster
    {
        uint8_t l4[16], l8[64];
        default4(l4, 1);
        default8(l8, 0);
        T_CHECK(l4[0] == 6 && l4[1] == 13 && l4[4] == 13 && l4[15] == 42 && l8[0] == 9 && l8[63] == 35 && l8[8] == 13, "matriz padrão");
    }
    return 0;
}
