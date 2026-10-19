// H.264 com NVIDIA NVENC (API 11.1: drivers 470+ no Linux/Windows).
// libcuda/libnvidia-encode (ou nvcuda.dll/nvEncodeAPI64.dll) são carregadas
// pelo loader do nv-codec-headers, então nada disso é dependência de build.
//
// Entrada em BGRX/RGBX direto (o NVENC converte a cor na GPU), modo síncrono,
// preset P4 + tuning de latência ultra baixa, sem B-frames, GOP infinito (IDR
// só quando pedirem) e VBV de um quadro. Com duas camadas temporais, o tipo de
// cada quadro é decidido aqui (PTD desligado): um P sim, um não é marcado como
// não-referência — funciona em qualquer geração de NVENC, sem precisar do
// "temporal SVC" (que as placas mais antigas não têm).
#include "hwenc.h"

typedef struct nvenc nvenc;

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FFNV_LOG_FUNC(logctx, msg, ...) ((void)0)
#define FFNV_DEBUG_LOG_FUNC(logctx, msg, ...) ((void)0)
#include <ffnvcodec/dynlink_loader.h>
#include <ffnvcodec/nvEncodeAPI.h>

struct nvenc {
    CudaFunctions *cu;
    NvencFunctions *nv;
    NV_ENCODE_API_FUNCTION_LIST api;
    CUcontext ctx;
    void *enc;
    NV_ENC_INPUT_PTR input;
    NV_ENC_OUTPUT_PTR output;
    NV_ENC_INITIALIZE_PARAMS init;
    NV_ENC_CONFIG cfg;
    int width, height, fps;
    uint8_t *bits;
    size_t bits_cap;
    uint64_t frame;
    int bitrate;
    int layers;         // camadas temporais (1 ou 2)
    uint32_t since_idr; // quadros desde o último IDR (com 2 camadas)
};

static void set_err(char *err, int errlen, const char *msg, int code) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (%d)", msg, code);
}

/// VBV do IDR, em quadros: com o VBV normal (1 quadro) o IDR sai quase no QP
/// máximo e a tela fica borrada por um tempo depois de cada IDR (alguém entrou
/// na sala, um espectador recomeçou...). Com folga ele sai nítido: numa tela
/// de código em 1080p, 34 dB → 45 dB no IDR, ~60 KB a mais (zig build bench).
#define IDR_VBV_FRAMES 10

static void configure_rc(nvenc *e, int bitrate) {
    e->bitrate = bitrate;
    NV_ENC_RC_PARAMS *rc = &e->cfg.rcParams;
    // VBR com teto: tela calma gasta pouco, movimento usa até o limite
    rc->rateControlMode = NV_ENC_PARAMS_RC_VBR;
    rc->averageBitRate = (uint32_t)bitrate;
    rc->maxBitRate = (uint32_t)bitrate;
    // VBV de ~1 quadro: cada quadro sai sem esperar os próximos (latência mínima)
    rc->vbvBufferSize = (uint32_t)(bitrate / (e->fps > 0 ? e->fps : 30));
    rc->vbvInitialDelay = rc->vbvBufferSize;
}

static void reconfigure(nvenc *e) {
    NV_ENC_RECONFIGURE_PARAMS rp = {0};
    rp.version = NV_ENC_RECONFIGURE_PARAMS_VER;
    rp.reInitEncodeParams = e->init;
    rp.reInitEncodeParams.encodeConfig = &e->cfg;
    rp.resetEncoder = 0;
    rp.forceIDR = 0;
    e->api.nvEncReconfigureEncoder(e->enc, &rp);
}

void nvenc_close(nvenc *e) {
    if (!e) return;
    if (e->enc) {
        if (e->input) e->api.nvEncDestroyInputBuffer(e->enc, e->input);
        if (e->output) e->api.nvEncDestroyBitstreamBuffer(e->enc, e->output);
        e->api.nvEncDestroyEncoder(e->enc);
    }
    if (e->ctx) e->cu->cuCtxDestroy(e->ctx);
    if (e->nv) nvenc_free_functions(&e->nv);
    if (e->cu) cuda_free_functions(&e->cu);
    free(e->bits);
    free(e);
}

nvenc *nvenc_open(int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen) {
    nvenc *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->width = width;
    e->height = height;
    e->fps = fps;
    e->layers = temporal_layers > 1 ? 2 : 1;

    if (cuda_load_functions(&e->cu, NULL) < 0 || nvenc_load_functions(&e->nv, NULL) < 0) {
        set_err(err, errlen, "driver NVIDIA (CUDA/NVENC) não encontrado", 0);
        nvenc_close(e);
        return NULL;
    }
    uint32_t max_ver = 0;
    if (e->nv->NvEncodeAPIGetMaxSupportedVersion(&max_ver) != NV_ENC_SUCCESS ||
        ((max_ver >> 4) < NVENCAPI_MAJOR_VERSION ||
         ((max_ver >> 4) == NVENCAPI_MAJOR_VERSION && (max_ver & 0xf) < NVENCAPI_MINOR_VERSION))) {
        set_err(err, errlen, "driver NVIDIA antigo demais pro NVENC (precisa 470+)", (int)max_ver);
        nvenc_close(e);
        return NULL;
    }

    CUdevice dev;
    CUresult cr = e->cu->cuInit(0);
    if (cr == CUDA_SUCCESS) cr = e->cu->cuDeviceGet(&dev, 0);
    if (cr == CUDA_SUCCESS) cr = e->cu->cuCtxCreate(&e->ctx, 0, dev);
    if (cr != CUDA_SUCCESS) {
        set_err(err, errlen, "não consegui iniciar o CUDA", (int)cr);
        nvenc_close(e);
        return NULL;
    }

    e->api.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    NVENCSTATUS st = e->nv->NvEncodeAPICreateInstance(&e->api);
    if (st != NV_ENC_SUCCESS) {
        set_err(err, errlen, "NvEncodeAPICreateInstance falhou", st);
        nvenc_close(e);
        return NULL;
    }

    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS sp = {0};
    sp.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    sp.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
    sp.device = e->ctx;
    sp.apiVersion = NVENCAPI_VERSION;
    st = e->api.nvEncOpenEncodeSessionEx(&sp, &e->enc);
    if (st != NV_ENC_SUCCESS) {
        e->enc = NULL;
        set_err(err, errlen, "a placa não abriu uma sessão NVENC", st);
        nvenc_close(e);
        return NULL;
    }

    // P4 dá ~1 dB a mais que o P1 em texto pelo mesmo tempo até 1080p60 (a
    // placa sobra); acima disso, P2. TELINHA_NVENC_PRESET=1..7 força um.
    static const GUID presets[7] = {NV_ENC_PRESET_P1_GUID, NV_ENC_PRESET_P2_GUID, NV_ENC_PRESET_P3_GUID, NV_ENC_PRESET_P4_GUID,
                                    NV_ENC_PRESET_P5_GUID, NV_ENC_PRESET_P6_GUID, NV_ENC_PRESET_P7_GUID};
    int pidx = (int64_t)width * height * (fps > 0 ? fps : 30) <= 1920LL * 1080 * 60 ? 4 : 2;
    const char *penv = getenv("TELINHA_NVENC_PRESET");
    if (penv && *penv >= '1' && *penv <= '7') pidx = *penv - '0';
    const GUID preset = presets[pidx - 1];
    NV_ENC_PRESET_CONFIG pc = {0};
    pc.version = NV_ENC_PRESET_CONFIG_VER;
    pc.presetCfg.version = NV_ENC_CONFIG_VER;
    st = e->api.nvEncGetEncodePresetConfigEx(e->enc, NV_ENC_CODEC_H264_GUID, preset, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &pc);
    if (st != NV_ENC_SUCCESS) {
        set_err(err, errlen, "preset do NVENC indisponível", st);
        nvenc_close(e);
        return NULL;
    }
    e->cfg = pc.presetCfg;
    e->cfg.version = NV_ENC_CONFIG_VER;
    // High + CABAC + transformada 8x8: texto bem mais nítido pela mesma taxa
    // (+3,8 dB com 17% menos bits no bench). Sem B-frames; o decoder do
    // openh264 segura um quadro em perfis Main/High achando que pode haver
    // reordenação, e o codec.zig pede pra ele soltar na hora (FlushFrame).
    e->cfg.profileGUID = NV_ENC_H264_PROFILE_HIGH_GUID;
    e->cfg.gopLength = NVENC_INFINITE_GOPLENGTH;
    e->cfg.frameIntervalP = 1; // sem B-frames
    configure_rc(e, bitrate);
    if (screen_mode) {
        // texto: um pouco mais de qualidade nos detalhes
        e->cfg.rcParams.enableAQ = 0;
    } else {
        e->cfg.rcParams.enableAQ = 1;
    }
    NV_ENC_CONFIG_H264 *h = &e->cfg.encodeCodecConfig.h264Config;
    h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
    h->repeatSPSPPS = 1; // todo IDR leva SPS/PPS (quem entra depois consegue decodificar)
    h->outputAUD = 0;
    h->chromaFormatIDC = 1;
    // CABAC: ~20% menos bits que CAVLC pela mesma qualidade; custa ~50% a mais
    // pra decodificar em software (openh264), o NVDEC nem sente
    h->entropyCodingMode = NV_ENC_H264_ENTROPY_CODING_MODE_CABAC;
    h->adaptiveTransformMode = NV_ENC_H264_ADAPTIVE_TRANSFORM_ENABLE;

    NV_ENC_INITIALIZE_PARAMS *ip = &e->init;
    memset(ip, 0, sizeof *ip);
    ip->version = NV_ENC_INITIALIZE_PARAMS_VER;
    ip->encodeGUID = NV_ENC_CODEC_H264_GUID;
    ip->presetGUID = preset;
    ip->tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    ip->encodeWidth = (uint32_t)width;
    ip->encodeHeight = (uint32_t)height;
    ip->darWidth = (uint32_t)width;
    ip->darHeight = (uint32_t)height;
    ip->maxEncodeWidth = (uint32_t)width;
    ip->maxEncodeHeight = (uint32_t)height;
    ip->frameRateNum = (uint32_t)(fps > 0 ? fps : 30);
    ip->frameRateDen = 1;
    ip->enablePTD = e->layers == 1; // com 2 camadas, quem decide o tipo do quadro é o nvenc_encode
    ip->enableEncodeAsync = 0;
    ip->encodeConfig = &e->cfg;
    st = e->api.nvEncInitializeEncoder(e->enc, ip);
    if (st != NV_ENC_SUCCESS) {
        set_err(err, errlen, "NVENC recusou a configuração (resolução grande demais?)", st);
        nvenc_close(e);
        return NULL;
    }

    NV_ENC_CREATE_INPUT_BUFFER ib = {0};
    ib.version = NV_ENC_CREATE_INPUT_BUFFER_VER;
    ib.width = (uint32_t)width;
    ib.height = (uint32_t)height;
    ib.bufferFmt = NV_ENC_BUFFER_FORMAT_ARGB;
    st = e->api.nvEncCreateInputBuffer(e->enc, &ib);
    if (st != NV_ENC_SUCCESS) {
        set_err(err, errlen, "NVENC: falha ao criar buffer de entrada", st);
        nvenc_close(e);
        return NULL;
    }
    e->input = ib.inputBuffer;

    NV_ENC_CREATE_BITSTREAM_BUFFER bb = {0};
    bb.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    st = e->api.nvEncCreateBitstreamBuffer(e->enc, &bb);
    if (st != NV_ENC_SUCCESS) {
        set_err(err, errlen, "NVENC: falha ao criar buffer de saída", st);
        nvenc_close(e);
        return NULL;
    }
    e->output = bb.bitstreamBuffer;
    return e;
}

int nvenc_encode(nvenc *e, const uint8_t *pixels, int stride, int format, int force_idr,
                 const uint8_t **out, int *out_len, int *is_idr) {
    // copia o quadro pro buffer de entrada (memória visível pela GPU)
    NV_ENC_LOCK_INPUT_BUFFER li = {0};
    li.version = NV_ENC_LOCK_INPUT_BUFFER_VER;
    li.inputBuffer = e->input;
    NVENCSTATUS st = e->api.nvEncLockInputBuffer(e->enc, &li);
    if (st != NV_ENC_SUCCESS) return (int)st;
    const size_t row = (size_t)e->width * 4;
    uint8_t *dst = li.bufferDataPtr;
    if ((uint32_t)stride == li.pitch && li.pitch == row) {
        memcpy(dst, pixels, row * (size_t)e->height);
    } else {
        for (int y = 0; y < e->height; y++) memcpy(dst + (size_t)y * li.pitch, pixels + (size_t)y * stride, row);
    }
    e->api.nvEncUnlockInputBuffer(e->enc, e->input);

    NV_ENC_PIC_PARAMS pp = {0};
    pp.version = NV_ENC_PIC_PARAMS_VER;
    pp.inputWidth = (uint32_t)e->width;
    pp.inputHeight = (uint32_t)e->height;
    pp.inputPitch = li.pitch;
    pp.inputBuffer = e->input;
    pp.outputBitstream = e->output;
    // ARGB/ABGR do NVENC são "word-ordered": na memória ficam B,G,R,A / R,G,B,A
    pp.bufferFmt = format == HWENC_RGBX ? NV_ENC_BUFFER_FORMAT_ABGR : NV_ENC_BUFFER_FORMAT_ARGB;
    pp.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
    if (e->layers > 1) {
        const int idr = force_idr || e->frame == 0;
        if (idr) e->since_idr = 0;
        pp.pictureType = idr ? NV_ENC_PIC_TYPE_IDR : NV_ENC_PIC_TYPE_P;
        pp.codecPicParams.h264PicParams.refPicFlag = e->since_idr % 2 == 0;
        pp.codecPicParams.h264PicParams.displayPOCSyntax = 2 * e->since_idr;
        e->since_idr++;
    }
    pp.inputTimeStamp = e->frame++;
    if (force_idr) pp.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
    // IDR com folga no VBV (ver IDR_VBV_FRAMES); depois volta ao normal
    const int boost = force_idr || e->frame == 1;
    if (boost) {
        NV_ENC_RC_PARAMS *rc = &e->cfg.rcParams;
        rc->vbvBufferSize = (uint32_t)((int64_t)e->bitrate * IDR_VBV_FRAMES / (e->fps > 0 ? e->fps : 30));
        rc->vbvInitialDelay = rc->vbvBufferSize;
        reconfigure(e);
    }
    st = e->api.nvEncEncodePicture(e->enc, &pp);
    if (boost) {
        configure_rc(e, e->bitrate);
        reconfigure(e);
    }
    if (st != NV_ENC_SUCCESS) return (int)st;

    NV_ENC_LOCK_BITSTREAM lb = {0};
    lb.version = NV_ENC_LOCK_BITSTREAM_VER;
    lb.outputBitstream = e->output;
    st = e->api.nvEncLockBitstream(e->enc, &lb);
    if (st != NV_ENC_SUCCESS) return (int)st;
    size_t n = lb.bitstreamSizeInBytes;
    if (n > e->bits_cap) {
        free(e->bits);
        e->bits = malloc(n);
        e->bits_cap = e->bits ? n : 0;
    }
    if (e->bits) memcpy(e->bits, lb.bitstreamBufferPtr, n);
    *is_idr = lb.pictureType == NV_ENC_PIC_TYPE_IDR;
    e->api.nvEncUnlockBitstream(e->enc, e->output);
    if (!e->bits) return -1;
    *out = e->bits;
    *out_len = (int)n;
    return 0;
}

void nvenc_set_bitrate(nvenc *e, int bitrate) {
    configure_rc(e, bitrate);
    reconfigure(e);
}

const char *nvenc_name(nvenc *e) {
    (void)e;
    return "NVENC";
}
