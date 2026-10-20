// H.264 ou HEVC com NVIDIA NVDEC (via nvcuvid, carregado em runtime).
// Parser com ulMaxDisplayDelay = 0 e cada pacote marcado como quadro
// completo: o quadro decodificado sai na mesma chamada (latência mínima).
#include "hwdec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FFNV_LOG_FUNC(logctx, msg, ...) ((void)0)
#define FFNV_DEBUG_LOG_FUNC(logctx, msg, ...) ((void)0)
#include <ffnvcodec/dynlink_loader.h>

typedef struct nvdec nvdec;

struct nvdec {
    CudaFunctions *cu;
    CuvidFunctions *cv;
    CUcontext ctx;
    CUvideoparser parser;
    CUvideodecoder dec;
    unsigned coded_w, coded_h;
    int w, h;
    uint8_t *host; // NV12 na memória da CPU
    size_t host_cap;
    int have, err;
    // saída na placa (nvdec_decode_to): destino do quadro atual (0 = CPU)
    CUdeviceptr dst_y, dst_uv;
    int dst_pitch, dst_w, dst_h;
    int on_device;
    cudaVideoCodec codec;
    CUdevice dev;
    int retained; // contexto primário retido (solta no close)
};

static void set_err(char *err, int errlen, const char *msg, int code) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (%d)", msg, code);
}

static int CUDAAPI on_sequence(void *ud, CUVIDEOFORMAT *f) {
    struct nvdec *d = ud;
    int w = f->display_area.right - f->display_area.left;
    int h = f->display_area.bottom - f->display_area.top;
    int surfaces = f->min_num_decode_surfaces > 0 ? f->min_num_decode_surfaces + 2 : 8;
    if (d->dec && d->coded_w == f->coded_width && d->coded_h == f->coded_height && d->w == w && d->h == h) return surfaces;
    if (d->dec) {
        d->cv->cuvidDestroyDecoder(d->dec);
        d->dec = NULL;
    }
    if (f->codec != d->codec || f->chroma_format != cudaVideoChromaFormat_420 || f->bit_depth_luma_minus8 != 0) {
        d->err = 1;
        return 0;
    }
    CUVIDDECODECREATEINFO ci;
    memset(&ci, 0, sizeof ci);
    ci.ulWidth = f->coded_width;
    ci.ulHeight = f->coded_height;
    ci.ulMaxWidth = f->coded_width;
    ci.ulMaxHeight = f->coded_height;
    ci.ulNumDecodeSurfaces = (tcu_ulong)surfaces;
    ci.CodecType = f->codec;
    ci.ChromaFormat = f->chroma_format;
    ci.ulCreationFlags = cudaVideoCreate_PreferCUVID;
    ci.bitDepthMinus8 = 0;
    ci.display_area.left = f->display_area.left;
    ci.display_area.top = f->display_area.top;
    ci.display_area.right = f->display_area.right;
    ci.display_area.bottom = f->display_area.bottom;
    ci.OutputFormat = cudaVideoSurfaceFormat_NV12;
    ci.DeinterlaceMode = cudaVideoDeinterlaceMode_Weave;
    ci.ulTargetWidth = (tcu_ulong)w;
    ci.ulTargetHeight = (tcu_ulong)h;
    ci.ulNumOutputSurfaces = 2;
    if (d->cv->cuvidCreateDecoder(&d->dec, &ci) != CUDA_SUCCESS) {
        d->dec = NULL;
        d->err = 1;
        return 0;
    }
    d->coded_w = f->coded_width;
    d->coded_h = f->coded_height;
    d->w = w;
    d->h = h;
    size_t need = (size_t)w * h * 3 / 2;
    if (need > d->host_cap) {
        free(d->host);
        d->host = malloc(need);
        d->host_cap = d->host ? need : 0;
        if (!d->host) d->err = 1;
    }
    return surfaces;
}

static int CUDAAPI on_decode(void *ud, CUVIDPICPARAMS *pp) {
    struct nvdec *d = ud;
    if (!d->dec || d->cv->cuvidDecodePicture(d->dec, pp) != CUDA_SUCCESS) d->err = 1;
    return 1;
}

static int CUDAAPI on_display(void *ud, CUVIDPARSERDISPINFO *di) {
    struct nvdec *d = ud;
    if (!d->dec || !d->host) return 1;
    d->on_device = 0;
    CUVIDPROCPARAMS vp;
    memset(&vp, 0, sizeof vp);
    vp.progressive_frame = di->progressive_frame;
    vp.top_field_first = di->top_field_first;
    vp.second_field = di->repeat_first_field + 1;
    vp.unpaired_field = di->repeat_first_field < 0;
    CUdeviceptr src = 0;
    unsigned int pitch = 0;
    if (d->cv->cuvidMapVideoFrame(d->dec, di->picture_index, &src, &pitch, &vp) != CUDA_SUCCESS) {
        d->err = 1;
        return 1;
    }
    CUDA_MEMCPY2D m;
    memset(&m, 0, sizeof m);
    m.srcMemoryType = CU_MEMORYTYPE_DEVICE;
    m.srcDevice = src;
    m.srcPitch = pitch;
    m.WidthInBytes = (size_t)d->w;
    m.Height = (size_t)d->h;
    const int to_dev = d->dst_y && d->dst_w == d->w && d->dst_h == d->h;
    if (to_dev) {
        // placa -> placa: nenhuma cópia pela CPU
        m.dstMemoryType = CU_MEMORYTYPE_DEVICE;
        m.dstDevice = d->dst_y;
        m.dstPitch = (size_t)d->dst_pitch;
    } else {
        m.dstMemoryType = CU_MEMORYTYPE_HOST;
        m.dstHost = d->host;
        m.dstPitch = (size_t)d->w;
    }
    CUresult r = d->cu->cuMemcpy2D(&m);
    if (r == CUDA_SUCCESS) {
        // croma logo depois da luma (altura alinhada em 2)
        m.srcDevice = src + (CUdeviceptr)pitch * (CUdeviceptr)((d->h + 1) & ~1);
        if (to_dev) m.dstDevice = d->dst_uv;
        else m.dstHost = d->host + (size_t)d->w * d->h;
        m.Height = (size_t)d->h / 2;
        r = d->cu->cuMemcpy2D(&m);
    }
    d->cv->cuvidUnmapVideoFrame(d->dec, src);
    if (r != CUDA_SUCCESS) d->err = 1;
    else {
        d->have = 1;
        d->on_device = to_dev;
    }
    return 1;
}

// Só pergunta à placa se ela decodifica esse codec (sem criar decoder nem
// parser: abrir um de verdade só pra testar custava ~26 MB e uma thread).
int nvdec_probe(int codec) {
    CudaFunctions *cu = NULL;
    CuvidFunctions *cv = NULL;
    int ok = 0;
    if (cuda_load_functions(&cu, NULL) < 0 || cuvid_load_functions(&cv, NULL) < 0) goto done;
    CUdevice dev;
    CUcontext ctx;
    if (cu->cuInit(0) != CUDA_SUCCESS || cu->cuDeviceGet(&dev, 0) != CUDA_SUCCESS) goto done;
    if (cu->cuDevicePrimaryCtxRetain(&ctx, dev) != CUDA_SUCCESS) goto done;
    if (cu->cuCtxPushCurrent(ctx) == CUDA_SUCCESS) {
        CUVIDDECODECAPS caps;
        memset(&caps, 0, sizeof caps);
        caps.eCodecType = codec == HW_CODEC_HEVC ? cudaVideoCodec_HEVC : cudaVideoCodec_H264;
        caps.eChromaFormat = cudaVideoChromaFormat_420;
        caps.nBitDepthMinus8 = 0;
        ok = cv->cuvidGetDecoderCaps && cv->cuvidGetDecoderCaps(&caps) == CUDA_SUCCESS && caps.bIsSupported;
        CUcontext dummy;
        cu->cuCtxPopCurrent(&dummy);
    }
    cu->cuDevicePrimaryCtxRelease(dev);
done:
    if (cv) cuvid_free_functions(&cv);
    if (cu) cuda_free_functions(&cu);
    return ok;
}

void nvdec_close(nvdec *d) {
    if (!d) return;
    if (d->ctx) d->cu->cuCtxPushCurrent(d->ctx);
    if (d->parser) d->cv->cuvidDestroyVideoParser(d->parser);
    if (d->dec) d->cv->cuvidDestroyDecoder(d->dec);
    if (d->ctx) {
        CUcontext dummy;
        d->cu->cuCtxPopCurrent(&dummy);
    }
    if (d->retained) {
        d->cu->cuDevicePrimaryCtxRelease(d->dev);
    }
    if (d->cv) cuvid_free_functions(&d->cv);
    if (d->cu) cuda_free_functions(&d->cu);
    free(d->host);
    free(d);
}

nvdec *nvdec_open(int codec, char *err, int errlen) {
    if (codec != HW_CODEC_H264 && codec != HW_CODEC_HEVC) {
        set_err(err, errlen, "NVDEC: codec não suportado", codec);
        return NULL;
    }
    struct nvdec *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->codec = codec == HW_CODEC_HEVC ? cudaVideoCodec_HEVC : cudaVideoCodec_H264;
    if (cuda_load_functions(&d->cu, NULL) < 0 || cuvid_load_functions(&d->cv, NULL) < 0) {
        set_err(err, errlen, "driver NVIDIA (CUDA/NVDEC) não encontrado", 0);
        nvdec_close(d);
        return NULL;
    }
    CUdevice dev;
    CUresult r = d->cu->cuInit(0);
    if (r == CUDA_SUCCESS) r = d->cu->cuDeviceGet(&dev, 0);
    // contexto primário (um por placa, compartilhado): um contexto próprio por
    // transmissão assistida custava ~37 MB
    if (r == CUDA_SUCCESS) r = d->cu->cuDevicePrimaryCtxRetain(&d->ctx, dev);
    if (r == CUDA_SUCCESS) {
        d->dev = dev;
        d->retained = 1;
        r = d->cu->cuCtxPushCurrent(d->ctx);
    }
    if (r != CUDA_SUCCESS) {
        if (!d->retained) d->ctx = NULL;
        set_err(err, errlen, "não consegui iniciar o CUDA", (int)r);
        nvdec_close(d);
        return NULL;
    }
    // a placa decodifica H.264 nesse tamanho?
    if (d->cv->cuvidGetDecoderCaps) {
        CUVIDDECODECAPS caps;
        memset(&caps, 0, sizeof caps);
        caps.eCodecType = d->codec;
        caps.eChromaFormat = cudaVideoChromaFormat_420;
        caps.nBitDepthMinus8 = 0;
        if (d->cv->cuvidGetDecoderCaps(&caps) != CUDA_SUCCESS || !caps.bIsSupported) {
            CUcontext dummy;
            d->cu->cuCtxPopCurrent(&dummy);
            set_err(err, errlen, d->codec == cudaVideoCodec_HEVC ? "a placa não decodifica HEVC" : "a placa não decodifica H.264", 0);
            nvdec_close(d);
            return NULL;
        }
    }
    CUVIDPARSERPARAMS pp;
    memset(&pp, 0, sizeof pp);
    pp.CodecType = d->codec;
    pp.ulMaxNumDecodeSurfaces = 8;
    pp.ulMaxDisplayDelay = 0; // sai na hora
    pp.pUserData = d;
    pp.pfnSequenceCallback = on_sequence;
    pp.pfnDecodePicture = on_decode;
    pp.pfnDisplayPicture = on_display;
    r = d->cv->cuvidCreateVideoParser(&d->parser, &pp);
    CUcontext dummy;
    d->cu->cuCtxPopCurrent(&dummy);
    if (r != CUDA_SUCCESS) {
        d->parser = NULL;
        set_err(err, errlen, "não consegui criar o parser NVDEC", (int)r);
        nvdec_close(d);
        return NULL;
    }
    return d;
}

int nvdec_decode_to(nvdec *d, const uint8_t *data, int len, hwdec_frame *out,
                    uint64_t dst_y, uint64_t dst_uv, int dst_pitch, int dst_w, int dst_h) {
    d->dst_y = (CUdeviceptr)dst_y;
    d->dst_uv = (CUdeviceptr)dst_uv;
    d->dst_pitch = dst_pitch;
    d->dst_w = dst_w;
    d->dst_h = dst_h;
    const int r = nvdec_decode(d, data, len, out);
    d->dst_y = d->dst_uv = 0;
    if (r == 1 && d->on_device) {
        out->on_device = 1;
        out->y = NULL;
        out->uv = NULL;
    }
    return r;
}

int nvdec_decode(nvdec *d, const uint8_t *data, int len, hwdec_frame *out) {
    d->have = 0;
    d->err = 0;
    out->on_device = 0;
    d->cu->cuCtxPushCurrent(d->ctx);
    CUVIDSOURCEDATAPACKET pkt;
    memset(&pkt, 0, sizeof pkt);
    pkt.flags = CUVID_PKT_ENDOFPICTURE;
    pkt.payload_size = (unsigned long)len;
    pkt.payload = data;
    CUresult r = d->cv->cuvidParseVideoData(d->parser, &pkt);
    CUcontext dummy;
    d->cu->cuCtxPopCurrent(&dummy);
    if (r != CUDA_SUCCESS || d->err) return -1;
    if (!d->have) return 0;
    out->y = d->host;
    out->uv = d->host + (size_t)d->w * d->h;
    out->width = d->w;
    out->height = d->h;
    return 1;
}
