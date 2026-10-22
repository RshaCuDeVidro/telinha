// H.264 ou HEVC com NVIDIA NVENC (API 11.1: drivers 470+ no Linux/Windows).
// libcuda/libnvidia-encode (ou nvcuda.dll/nvEncodeAPI64.dll) são carregadas
// pelo loader do nv-codec-headers, então nada disso é dependência de build.
//
// Entrada em BGRX/RGBX direto (o NVENC converte a cor na GPU), modo síncrono,
// preset P4 + tuning de latência ultra baixa, sem B-frames, GOP infinito (IDR
// só quando pedirem) e VBV de um quadro. Com duas camadas temporais, o tipo de
// cada quadro é decidido aqui (PTD desligado): um P sim, um não é marcado como
// não-referência — funciona em qualquer geração de NVENC, sem precisar do
// "temporal SVC" (que as placas mais antigas não têm).
//
// AV1 (experimental, NVIDIA RTX 40 em diante): este mesmo arquivo é compilado
// de novo com NVENC_AV1 e os cabeçalhos da API 12 (build.zig: nvenc_av1), com
// nomes próprios (nvenc_av1_*). Driver antigo demais pra API 12 não abre esse,
// e o H.264/HEVC (API 11.1, este) segue igual.
#ifdef NVENC_AV1
#define nvenc nvenc_av1
#define nvenc_open nvenc_av1_open
#define nvenc_close nvenc_av1_close
#define nvenc_encode nvenc_av1_encode
#define nvenc_encode_dev nvenc_av1_encode_dev
#define nvenc_set_bitrate nvenc_av1_set_bitrate
#define nvenc_name nvenc_av1_name
#endif
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
    int hevc;
    CUdevice dev;
    int retained, pushed; // contexto primário retido / empurrado nessa thread
    int layers;         // camadas temporais (1 ou 2)
    uint32_t since_idr; // quadros desde o último IDR (com 2 camadas)
    // quadros que já estão na placa (cudagl.c): registrados uma vez por buffer
    struct { uint64_t ptr; NV_ENC_REGISTERED_PTR reg; } regs[8];
    int n_regs;
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
        for (int i = 0; i < e->n_regs; i++) e->api.nvEncUnregisterResource(e->enc, e->regs[i].reg);
        if (e->input) e->api.nvEncDestroyInputBuffer(e->enc, e->input);
        if (e->output) e->api.nvEncDestroyBitstreamBuffer(e->enc, e->output);
        e->api.nvEncDestroyEncoder(e->enc);
    }
    if (e->pushed) {
        CUcontext dummy;
        e->cu->cuCtxPopCurrent(&dummy);
    }
    if (e->retained) e->cu->cuDevicePrimaryCtxRelease(e->dev);
    if (e->nv) nvenc_free_functions(&e->nv);
    if (e->cu) cuda_free_functions(&e->cu);
    free(e->bits);
    free(e);
}

int hwenc_effort(void); // hwenc.c

nvenc *nvenc_open(int codec, int width, int height, int fps, int bitrate, int screen_mode, int temporal_layers, char *err, int errlen) {
#ifdef NVENC_AV1
    if (codec != HW_CODEC_AV1) {
        set_err(err, errlen, "NVENC (AV1): codec não suportado", codec);
        return NULL;
    }
    const int hevc = 0;
    const GUID codec_guid = NV_ENC_CODEC_AV1_GUID;
#else
    if (codec != HW_CODEC_H264 && codec != HW_CODEC_HEVC) {
        set_err(err, errlen, "NVENC: codec não suportado", codec);
        return NULL;
    }
    const int hevc = codec == HW_CODEC_HEVC;
    const GUID codec_guid = hevc ? NV_ENC_CODEC_HEVC_GUID : NV_ENC_CODEC_H264_GUID;
#endif
    // camadas alternadas só no H.264 (o truque dos quadros pares é dele)
    const int single_layer = codec != HW_CODEC_H264;
    nvenc *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->width = width;
    e->height = height;
    e->fps = fps;
    // HEVC/AV1: uma camada só (o truque dos quadros alternados é do H.264)
    e->layers = temporal_layers > 1 && !single_layer ? 2 : 1;
    e->hevc = hevc;

    if (cuda_load_functions(&e->cu, NULL) < 0 || nvenc_load_functions(&e->nv, NULL) < 0) {
        set_err(err, errlen, "driver NVIDIA (CUDA/NVENC) não encontrado", 0);
        nvenc_close(e);
        return NULL;
    }
    uint32_t max_ver = 0;
    if (e->nv->NvEncodeAPIGetMaxSupportedVersion(&max_ver) != NV_ENC_SUCCESS ||
        ((max_ver >> 4) < NVENCAPI_MAJOR_VERSION ||
         ((max_ver >> 4) == NVENCAPI_MAJOR_VERSION && (max_ver & 0xf) < NVENCAPI_MINOR_VERSION))) {
#ifdef NVENC_AV1
        set_err(err, errlen, "driver NVIDIA antigo demais pro AV1 (precisa 550+)", (int)max_ver);
#else
        set_err(err, errlen, "driver NVIDIA antigo demais pro NVENC (precisa 470+)", (int)max_ver);
#endif
        nvenc_close(e);
        return NULL;
    }

    CUdevice dev;
    CUresult cr = e->cu->cuInit(0);
    if (cr == CUDA_SUCCESS) cr = e->cu->cuDeviceGet(&dev, 0);
    // contexto primário (um por placa, compartilhado com os decoders): criar
    // um contexto próprio custava ~30 MB e um monte de memória a cada abertura
    if (cr == CUDA_SUCCESS) cr = e->cu->cuDevicePrimaryCtxRetain(&e->ctx, dev);
    if (cr == CUDA_SUCCESS) {
        e->dev = dev;
        e->retained = 1;
        cr = e->cu->cuCtxPushCurrent(e->ctx);
        if (cr == CUDA_SUCCESS) e->pushed = 1;
    }
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

    // Preset pelo peso escolhido (Configurações → Desempenho). Qualidade: P4
    // dá ~1 dB a mais que o P1 em texto até 1080p60; equilibrado: P3; leve:
    // P1 (e sem AQ, que roda nos núcleos CUDA — os mesmos do jogo). Acima de
    // 1080p60, um degrau a menos. TELINHA_NVENC_PRESET=1..7 força um.
    static const GUID presets[7] = {NV_ENC_PRESET_P1_GUID, NV_ENC_PRESET_P2_GUID, NV_ENC_PRESET_P3_GUID, NV_ENC_PRESET_P4_GUID,
                                    NV_ENC_PRESET_P5_GUID, NV_ENC_PRESET_P6_GUID, NV_ENC_PRESET_P7_GUID};
    const int effort = hwenc_effort();
    const int big = (int64_t)width * height * (fps > 0 ? fps : 30) > 1920LL * 1080 * 60;
    int pidx = effort == 0 ? 1 : effort == 1 ? (big ? 2 : 3) : (big ? 2 : 4);
    const char *penv = getenv("TELINHA_NVENC_PRESET");
    if (penv && *penv >= '1' && *penv <= '7') pidx = *penv - '0';
    const GUID preset = presets[pidx - 1];
    NV_ENC_PRESET_CONFIG pc = {0};
    pc.version = NV_ENC_PRESET_CONFIG_VER;
    pc.presetCfg.version = NV_ENC_CONFIG_VER;
    if (codec != HW_CODEC_H264) {
        // a placa codifica HEVC (Maxwell 2ª geração em diante) / AV1 (RTX 40 em diante)?
        GUID guids[16];
        uint32_t n = 0;
        int found = 0;
        if (e->api.nvEncGetEncodeGUIDs(e->enc, guids, 16, &n) == NV_ENC_SUCCESS)
            for (uint32_t i = 0; i < n; i++)
                if (!memcmp(&guids[i], &codec_guid, sizeof(GUID))) found = 1;
        if (!found) {
            set_err(err, errlen, codec == HW_CODEC_AV1 ? "a placa não codifica AV1" : "a placa não codifica HEVC", 0);
            nvenc_close(e);
            return NULL;
        }
    }
    st = e->api.nvEncGetEncodePresetConfigEx(e->enc, codec_guid, preset, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &pc);
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
#ifdef NVENC_AV1
    e->cfg.profileGUID = NV_ENC_AV1_PROFILE_MAIN_GUID;
#else
    e->cfg.profileGUID = hevc ? NV_ENC_HEVC_PROFILE_MAIN_GUID : NV_ENC_H264_PROFILE_HIGH_GUID;
#endif
    e->cfg.gopLength = NVENC_INFINITE_GOPLENGTH;
    e->cfg.frameIntervalP = 1; // sem B-frames
    configure_rc(e, bitrate);
    if (screen_mode) {
        // texto: um pouco mais de qualidade nos detalhes
        e->cfg.rcParams.enableAQ = 0;
    } else {
        e->cfg.rcParams.enableAQ = hwenc_effort() > 0; // AQ usa CUDA: o leve fica sem
    }
#ifdef NVENC_AV1
    {
        // OBUs "low overhead" (o que o NVDEC e o WebCodecs esperam), cabeçalho de
        // sequência em todo quadro-chave (quem entra depois consegue decodificar)
        NV_ENC_CONFIG_AV1 *a = &e->cfg.encodeCodecConfig.av1Config;
        a->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        a->repeatSeqHdr = 1;
        a->disableSeqHdr = 0;
        a->outputAnnexBFormat = 0;
        a->chromaFormatIDC = 1;
        a->inputBitDepth = NV_ENC_BIT_DEPTH_8;
        a->outputBitDepth = NV_ENC_BIT_DEPTH_8;
    }
#else
    if (hevc) {
        NV_ENC_CONFIG_HEVC *h = &e->cfg.encodeCodecConfig.hevcConfig;
        h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h->repeatSPSPPS = 1; // todo IDR leva VPS/SPS/PPS
        h->outputAUD = 0;
        h->chromaFormatIDC = 1;
        h->pixelBitDepthMinus8 = 0;
    } else {
        NV_ENC_CONFIG_H264 *h = &e->cfg.encodeCodecConfig.h264Config;
        h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h->repeatSPSPPS = 1; // todo IDR leva SPS/PPS (quem entra depois consegue decodificar)
        h->outputAUD = 0;
        h->chromaFormatIDC = 1;
        // CABAC: ~20% menos bits que CAVLC pela mesma qualidade; custa ~50% a mais
        // pra decodificar em software (openh264), o NVDEC nem sente
        h->entropyCodingMode = NV_ENC_H264_ENTROPY_CODING_MODE_CABAC;
        h->adaptiveTransformMode = NV_ENC_H264_ADAPTIVE_TRANSFORM_ENABLE;
    }
#endif

    NV_ENC_INITIALIZE_PARAMS *ip = &e->init;
    memset(ip, 0, sizeof *ip);
    ip->version = NV_ENC_INITIALIZE_PARAMS_VER;
    ip->encodeGUID = codec_guid;
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

// Codifica o quadro que já está em `input` (buffer do NVENC ou recurso mapeado).
static int encode_input(nvenc *e, NV_ENC_INPUT_PTR input, uint32_t pitch, NV_ENC_BUFFER_FORMAT fmt, int force_idr,
                        const uint8_t **out, int *out_len, int *is_idr) {
    NVENCSTATUS st;
    NV_ENC_PIC_PARAMS pp = {0};
    pp.version = NV_ENC_PIC_PARAMS_VER;
    pp.inputWidth = (uint32_t)e->width;
    pp.inputHeight = (uint32_t)e->height;
    pp.inputPitch = pitch;
    pp.inputBuffer = input;
    pp.outputBitstream = e->output;
    pp.bufferFmt = fmt;
    pp.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
#ifndef NVENC_AV1
    if (e->layers > 1) {
        const int idr = force_idr || e->frame == 0;
        if (idr) e->since_idr = 0;
        pp.pictureType = idr ? NV_ENC_PIC_TYPE_IDR : NV_ENC_PIC_TYPE_P;
        pp.codecPicParams.h264PicParams.refPicFlag = e->since_idr % 2 == 0;
        pp.codecPicParams.h264PicParams.displayPOCSyntax = 2 * e->since_idr;
        e->since_idr++;
    }
#endif
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
    // ARGB/ABGR do NVENC são "word-ordered": na memória ficam B,G,R,A / R,G,B,A
    const NV_ENC_BUFFER_FORMAT fmt = format == HWENC_RGBX ? NV_ENC_BUFFER_FORMAT_ABGR : NV_ENC_BUFFER_FORMAT_ARGB;
    return encode_input(e, e->input, li.pitch, fmt, force_idr, out, out_len, is_idr);
}

// Quadro que já está na memória da placa (ponteiro CUDA do mesmo contexto
// primário; ver cudagl.c): nada é copiado pela CPU. O buffer é registrado no
// NVENC na primeira vez e fica registrado (quem chama usa poucos buffers, em
// rodízio).
int nvenc_encode_dev(nvenc *e, uint64_t dev, int pitch, int format, int force_idr,
                     const uint8_t **out, int *out_len, int *is_idr) {
    NV_ENC_REGISTERED_PTR reg = NULL;
    for (int i = 0; i < e->n_regs; i++)
        if (e->regs[i].ptr == dev) reg = e->regs[i].reg;
    if (!reg) {
        if (e->n_regs == (int)(sizeof e->regs / sizeof e->regs[0])) {
            // mais buffers que o esperado: esquece o mais antigo
            e->api.nvEncUnregisterResource(e->enc, e->regs[0].reg);
            memmove(&e->regs[0], &e->regs[1], sizeof e->regs[0] * (size_t)(e->n_regs - 1));
            e->n_regs--;
        }
        NV_ENC_REGISTER_RESOURCE rr = {0};
        rr.version = NV_ENC_REGISTER_RESOURCE_VER;
        rr.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_CUDADEVICEPTR;
        rr.width = (uint32_t)e->width;
        rr.height = (uint32_t)e->height;
        rr.pitch = (uint32_t)pitch;
        rr.resourceToRegister = (void *)(uintptr_t)dev;
        rr.bufferFormat = format == HWENC_RGBX ? NV_ENC_BUFFER_FORMAT_ABGR : NV_ENC_BUFFER_FORMAT_ARGB;
        rr.bufferUsage = NV_ENC_INPUT_IMAGE;
        NVENCSTATUS st = e->api.nvEncRegisterResource(e->enc, &rr);
        if (st != NV_ENC_SUCCESS) return (int)st;
        e->regs[e->n_regs].ptr = dev;
        e->regs[e->n_regs].reg = rr.registeredResource;
        e->n_regs++;
        reg = rr.registeredResource;
    }
    NV_ENC_MAP_INPUT_RESOURCE mp = {0};
    mp.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
    mp.registeredResource = reg;
    NVENCSTATUS st = e->api.nvEncMapInputResource(e->enc, &mp);
    if (st != NV_ENC_SUCCESS) return (int)st;
    const int rc = encode_input(e, mp.mappedResource, (uint32_t)pitch, mp.mappedBufferFmt, force_idr, out, out_len, is_idr);
    e->api.nvEncUnmapInputResource(e->enc, mp.mappedResource);
    return rc;
}

void nvenc_set_bitrate(nvenc *e, int bitrate) {
    configure_rc(e, bitrate);
    reconfigure(e);
}

const char *nvenc_name(nvenc *e) {
#ifdef NVENC_AV1
    (void)e;
    return "NVENC (AV1)";
#else
    return e->hevc ? "NVENC (HEVC)" : "NVENC";
#endif
}
