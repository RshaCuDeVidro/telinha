// CUDA <-> OpenGL (ver cudagl.h). O contexto primário do dispositivo é o
// mesmo que o NVENC (hwenc_nvenc.c) e o NVDEC (hwdec_nvdec.c) usam, então um
// ponteiro de memória da placa vale pros três. Cada chamada empurra o contexto
// na thread atual e tira ao sair (barato; nenhuma thread fica com ele preso).
#include "cudagl.h"
#include "cuda_scale_ptx.h"

#include <stdlib.h>
#include <string.h>

#define FFNV_LOG_FUNC(logctx, msg, ...) ((void)0)
#define FFNV_DEBUG_LOG_FUNC(logctx, msg, ...) ((void)0)
#include <ffnvcodec/dynlink_loader.h>

#define GL_TEXTURE_2D 0x0DE1

struct cudagl {
    CudaFunctions *cu;
    CUdevice dev;
    CUcontext ctx;
    CUmodule mod; // cuda_scale.c (carregado no primeiro uso)
    CUfunction fn_scale;
    int mod_failed;
};

cudagl *cudagl_open(void) {
    if (getenv("TELINHA_SEM_CUDAGL")) return NULL;
    cudagl *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    if (cuda_load_functions(&g->cu, NULL) < 0 || g->cu->cuInit(0) != CUDA_SUCCESS ||
        g->cu->cuDeviceGet(&g->dev, 0) != CUDA_SUCCESS || g->cu->cuDevicePrimaryCtxRetain(&g->ctx, g->dev) != CUDA_SUCCESS) {
        if (g->cu) cuda_free_functions(&g->cu);
        free(g);
        return NULL;
    }
    return g;
}

void cudagl_close(cudagl *g) {
    if (!g) return;
    if (g->mod && g->cu->cuCtxPushCurrent(g->ctx) == CUDA_SUCCESS) {
        CUcontext dummy;
        g->cu->cuModuleUnload(g->mod);
        g->cu->cuCtxPopCurrent(&dummy);
    }
    g->cu->cuDevicePrimaryCtxRelease(g->dev);
    cuda_free_functions(&g->cu);
    free(g);
}

static int push(cudagl *g) {
    return g->cu->cuCtxPushCurrent(g->ctx) == CUDA_SUCCESS ? 0 : -1;
}

static void pop(cudagl *g) {
    CUcontext dummy;
    g->cu->cuCtxPopCurrent(&dummy);
}

void *cudagl_register(cudagl *g, unsigned tex, int write) {
    if (!g || push(g) < 0) return NULL;
    CUgraphicsResource res = NULL;
    const unsigned flags = write ? CU_GRAPHICS_REGISTER_FLAGS_WRITE_DISCARD : CU_GRAPHICS_REGISTER_FLAGS_READ_ONLY;
    if (g->cu->cuGraphicsGLRegisterImage(&res, tex, GL_TEXTURE_2D, flags) != CUDA_SUCCESS) res = NULL;
    pop(g);
    return res;
}

void cudagl_unregister(cudagl *g, void *res) {
    if (!g || !res || push(g) < 0) return;
    g->cu->cuGraphicsUnregisterResource((CUgraphicsResource)res);
    pop(g);
}

uint64_t cudagl_alloc(cudagl *g, int width_bytes, int height, int *pitch) {
    if (!g || width_bytes <= 0 || height <= 0 || push(g) < 0) return 0;
    CUdeviceptr p = 0;
    size_t pt = 0;
    if (g->cu->cuMemAllocPitch(&p, &pt, (size_t)width_bytes, (size_t)height, 16) != CUDA_SUCCESS) p = 0;
    pop(g);
    if (pitch) *pitch = (int)pt;
    return (uint64_t)p;
}

void cudagl_free(cudagl *g, uint64_t ptr) {
    if (!g || !ptr || push(g) < 0) return;
    g->cu->cuMemFree((CUdeviceptr)ptr);
    pop(g);
}

// textura <-> memória: mapeia a textura (o CUDA espera o GL terminar com
// ela), copia e desmapeia (o GL volta a poder usar)
static int copy_tex(cudagl *g, void *res, int to_tex, uint64_t mem, int mem_pitch, int width_bytes, int height) {
    if (!g || !res || !mem || push(g) < 0) return -1;
    CUgraphicsResource r = res;
    int rc = -1;
    if (g->cu->cuGraphicsMapResources(1, &r, 0) == CUDA_SUCCESS) {
        CUarray arr = NULL;
        if (g->cu->cuGraphicsSubResourceGetMappedArray(&arr, r, 0, 0) == CUDA_SUCCESS) {
            CUDA_MEMCPY2D m;
            memset(&m, 0, sizeof m);
            if (to_tex) {
                m.srcMemoryType = CU_MEMORYTYPE_DEVICE;
                m.srcDevice = (CUdeviceptr)mem;
                m.srcPitch = (size_t)mem_pitch;
                m.dstMemoryType = CU_MEMORYTYPE_ARRAY;
                m.dstArray = arr;
            } else {
                m.srcMemoryType = CU_MEMORYTYPE_ARRAY;
                m.srcArray = arr;
                m.dstMemoryType = CU_MEMORYTYPE_DEVICE;
                m.dstDevice = (CUdeviceptr)mem;
                m.dstPitch = (size_t)mem_pitch;
            }
            m.WidthInBytes = (size_t)width_bytes;
            m.Height = (size_t)height;
            if (g->cu->cuMemcpy2D(&m) == CUDA_SUCCESS) rc = 0;
        }
        g->cu->cuGraphicsUnmapResources(1, &r, 0);
    }
    pop(g);
    return rc;
}

int cudagl_tex_to_dev(cudagl *g, void *res, uint64_t dst, int dst_pitch, int width_bytes, int height) {
    return copy_tex(g, res, 0, dst, dst_pitch, width_bytes, height);
}

int cudagl_dev_to_tex(cudagl *g, void *res, uint64_t src, int src_pitch, int width_bytes, int height) {
    return copy_tex(g, res, 1, src, src_pitch, width_bytes, height);
}

int cudagl_dev_to_host(cudagl *g, uint64_t src, int src_pitch, void *dst, int dst_pitch, int width_bytes, int height) {
    if (!g || !src || !dst || push(g) < 0) return -1;
    CUDA_MEMCPY2D m;
    memset(&m, 0, sizeof m);
    m.srcMemoryType = CU_MEMORYTYPE_DEVICE;
    m.srcDevice = (CUdeviceptr)src;
    m.srcPitch = (size_t)src_pitch;
    m.dstMemoryType = CU_MEMORYTYPE_HOST;
    m.dstHost = dst;
    m.dstPitch = (size_t)dst_pitch;
    m.WidthInBytes = (size_t)width_bytes;
    m.Height = (size_t)height;
    const int rc = g->cu->cuMemcpy2D(&m) == CUDA_SUCCESS ? 0 : -1;
    pop(g);
    return rc;
}

int cudagl_host_to_dev(cudagl *g, const void *src, int src_pitch, uint64_t dst, int dst_pitch, int width_bytes, int height) {
    if (!g || !src || !dst || push(g) < 0) return -1;
    CUDA_MEMCPY2D m;
    memset(&m, 0, sizeof m);
    m.srcMemoryType = CU_MEMORYTYPE_HOST;
    m.srcHost = src;
    m.srcPitch = (size_t)src_pitch;
    m.dstMemoryType = CU_MEMORYTYPE_DEVICE;
    m.dstDevice = (CUdeviceptr)dst;
    m.dstPitch = (size_t)dst_pitch;
    m.WidthInBytes = (size_t)width_bytes;
    m.Height = (size_t)height;
    const int rc = g->cu->cuMemcpy2D(&m) == CUDA_SUCCESS ? 0 : -1;
    pop(g);
    return rc;
}

int cudagl_scale(cudagl *g, uint64_t src, int src_pitch, int cx, int cy, int cw, int ch,
                 uint64_t dst, int dst_pitch, int ow, int oh) {
    if (!g || !src || !dst || cw < 1 || ch < 1 || ow < 1 || oh < 1 || g->mod_failed || push(g) < 0) return -1;
    if (!g->mod) {
        if (g->cu->cuModuleLoadData(&g->mod, telinha_scale_ptx) != CUDA_SUCCESS ||
            g->cu->cuModuleGetFunction(&g->fn_scale, g->mod, "telinha_scale") != CUDA_SUCCESS) {
            g->mod = NULL;
            g->mod_failed = 1;
            pop(g);
            return -1;
        }
    }
    CUdeviceptr s_ = (CUdeviceptr)src, d_ = (CUdeviceptr)dst;
    void *args[] = {&s_, &src_pitch, &cx, &cy, &cw, &ch, &d_, &dst_pitch, &ow, &oh};
    const unsigned bx = 16, by = 16;
    int rc = g->cu->cuLaunchKernel(g->fn_scale, ((unsigned)ow + bx - 1) / bx, ((unsigned)oh + by - 1) / by, 1, bx, by, 1, 0, NULL, args, NULL) == CUDA_SUCCESS ? 0 : -1;
    // o NVENC lê logo em seguida (outra fila): espera o kernel acabar
    if (rc == 0 && g->cu->cuStreamSynchronize(NULL) != CUDA_SUCCESS) rc = -1;
    pop(g);
    return rc;
}

void *cudagl_register_d3d11(cudagl *g, void *d3d11_texture) {
#if defined(_WIN32)
    if (!g || !d3d11_texture || push(g) < 0) return NULL;
    CUgraphicsResource res = NULL;
    if (g->cu->cuGraphicsD3D11RegisterResource(&res, d3d11_texture, CU_GRAPHICS_REGISTER_FLAGS_NONE) != CUDA_SUCCESS) res = NULL;
    pop(g);
    return res;
#else
    (void)g;
    (void)d3d11_texture;
    return NULL;
#endif
}
