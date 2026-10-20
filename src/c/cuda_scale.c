// Kernel CUDA de recorte + escala (bilinear) de BGRA/RGBA 8 bits, usado pelo
// caminho pela placa no Windows (DXGI → CUDA → NVENC; ver cudagl.c).
//
// Não é compilado junto com o app: vira PTX (texto) que o driver da NVIDIA
// compila na hora (cuModuleLoadData). Pra regerar src/c/cuda_scale_ptx.h:
//
//   clang --target=nvptx64-nvidia-cuda -march=sm_50 -O3 -S -o - src/c/cuda_scale.c \
//     | python3 tools/ptx_header.py > src/c/cuda_scale_ptx.h
//
// sm_50 = Maxwell (GTX 750 / 900) pra cima; o driver recompila pra placa que tiver.

#ifdef __NVPTX__ // só pro PTX (o editor que abre como C comum não reclama)

typedef unsigned char u8;
typedef unsigned int u32;

#define KERNEL __attribute__((nvptx_kernel))

static inline int tid_x(void) { return __nvvm_read_ptx_sreg_tid_x(); }
static inline int tid_y(void) { return __nvvm_read_ptx_sreg_tid_y(); }
static inline int bid_x(void) { return __nvvm_read_ptx_sreg_ctaid_x(); }
static inline int bid_y(void) { return __nvvm_read_ptx_sreg_ctaid_y(); }
static inline int bdim_x(void) { return __nvvm_read_ptx_sreg_ntid_x(); }
static inline int bdim_y(void) { return __nvvm_read_ptx_sreg_ntid_y(); }

// src: imagem inteira (pitch sp bytes); o pedaço (cx, cy, cw, ch) dela vira
// dst (ow x oh, pitch dp). Alfa sai 255. Mesmo tamanho: cópia direta.
KERNEL void telinha_scale(const u8 *src, int sp, int cx, int cy, int cw, int ch, u8 *dst, int dp, int ow, int oh) {
    const int x = bid_x() * bdim_x() + tid_x();
    const int y = bid_y() * bdim_y() + tid_y();
    if (x >= ow || y >= oh) return;
    u8 *d = dst + (long)y * dp + (long)x * 4;
    if (cw == ow && ch == oh) {
        const u8 *s = src + (long)(cy + y) * sp + (long)(cx + x) * 4;
        d[0] = s[0];
        d[1] = s[1];
        d[2] = s[2];
        d[3] = 255;
        return;
    }
    // centro do pixel de saída na fonte (ponto fixo 8.8 pros pesos)
    float fx = ((float)x + 0.5f) * (float)cw / (float)ow - 0.5f;
    float fy = ((float)y + 0.5f) * (float)ch / (float)oh - 0.5f;
    if (fx < 0) fx = 0;
    if (fy < 0) fy = 0;
    int x0 = (int)fx, y0 = (int)fy;
    if (x0 > cw - 1) x0 = cw - 1;
    if (y0 > ch - 1) y0 = ch - 1;
    const int x1 = x0 + 1 < cw ? x0 + 1 : cw - 1;
    const int y1 = y0 + 1 < ch ? y0 + 1 : ch - 1;
    const u32 wx = (u32)((fx - (float)x0) * 256.0f);
    const u32 wy = (u32)((fy - (float)y0) * 256.0f);
    const u8 *r0 = src + (long)(cy + y0) * sp + (long)cx * 4;
    const u8 *r1 = src + (long)(cy + y1) * sp + (long)cx * 4;
    for (int c = 0; c < 3; c++) {
        const u32 a = r0[x0 * 4 + c], b = r0[x1 * 4 + c];
        const u32 e = r1[x0 * 4 + c], f = r1[x1 * 4 + c];
        const u32 top = a * (256 - wx) + b * wx;
        const u32 bot = e * (256 - wx) + f * wx;
        d[c] = (u8)((top * (256 - wy) + bot * wy + 32768) >> 16);
    }
    d[3] = 255;
}

#endif
