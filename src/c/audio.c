// Áudio com miniaudio (backends carregados em runtime: WASAPI no Windows,
// PulseAudio/PipeWire no Linux).
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include "audio.h"
#ifndef _WIN32
#include "audio_pw.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#endif

struct audio_dev {
    ma_context ctx;
    ma_device dev;
    int ctx_ok, dev_ok;
    int hears_self; // a captura pega também o que o próprio app toca
#ifndef _WIN32
    pwcap *pw; // captura dos aplicativos pelo grafo do PipeWire (sem o telinha)
#endif
    audio_capture_fn capture;
    audio_play_fn play;
    void *user;
};

static void set_err(char *err, int errlen, const char *msg, int code) {
    if (err && errlen > 0) snprintf(err, errlen, "%s (%d)", msg, code);
}

static void on_data(ma_device *dev, void *out, const void *in, ma_uint32 frames) {
    struct audio_dev *d = dev->pUserData;
    if (d->capture && in) d->capture(d->user, (const float *)in, (int)frames);
    if (d->play && out) d->play(d->user, (float *)out, (int)frames);
}

void audio_close(audio_dev *d) {
    if (!d) return;
#ifndef _WIN32
    if (d->pw) pwcap_close(d->pw);
#endif
    if (d->dev_ok) ma_device_uninit(&d->dev);
    if (d->ctx_ok) ma_context_uninit(&d->ctx);
    free(d);
}

static audio_dev *open_dev(ma_device_type type, const ma_backend *backends, int nbackends, char *err, int errlen) {
    struct audio_dev *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    ma_context_config cc = ma_context_config_init();
    cc.pulse.pApplicationName = "telinha";
    ma_result r = ma_context_init(backends, (ma_uint32)nbackends, &cc, &d->ctx);
    if (r != MA_SUCCESS) {
        set_err(err, errlen, "sistema de áudio indisponível", r);
        free(d);
        return NULL;
    }
    d->ctx_ok = 1;
    (void)type;
    return d;
}

static int start(struct audio_dev *d, ma_device_config *cfg, char *err, int errlen) {
    cfg->sampleRate = AUDIO_RATE;
    cfg->dataCallback = on_data;
    cfg->pUserData = d;
    cfg->performanceProfile = ma_performance_profile_low_latency;
    ma_result r = ma_device_init(&d->ctx, cfg, &d->dev);
    if (r != MA_SUCCESS) {
        set_err(err, errlen, "não consegui abrir o dispositivo de áudio", r);
        return -1;
    }
    d->dev_ok = 1;
    r = ma_device_start(&d->dev);
    if (r != MA_SUCCESS) {
        set_err(err, errlen, "não consegui iniciar o áudio", r);
        return -1;
    }
    return 0;
}

audio_dev *audio_capture_open(audio_capture_fn fn, void *user, char *err, int errlen) {
#ifdef _WIN32
    const ma_backend backends[] = {ma_backend_wasapi};
    audio_dev *d = open_dev(ma_device_type_loopback, backends, 1, err, errlen);
    if (!d) return NULL;
    d->capture = fn;
    d->user = user;
    ma_device_config cfg = ma_device_config_init(ma_device_type_loopback);
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = AUDIO_CHANNELS;
    // tudo menos o próprio telinha (o som das transmissões assistidas não volta em eco)
    cfg.wasapi.loopbackProcessID = (ma_uint32)GetCurrentProcessId();
    cfg.wasapi.loopbackProcessExclude = MA_TRUE;
    if (start(d, &cfg, err, errlen) < 0) {
        // Windows antigo (sem loopback por processo): captura tudo
        if (d->dev_ok) ma_device_uninit(&d->dev);
        d->dev_ok = 0;
        cfg.wasapi.loopbackProcessID = 0;
        cfg.wasapi.loopbackProcessExclude = MA_FALSE;
        d->hears_self = 1;
        if (start(d, &cfg, err, errlen) < 0) {
            audio_close(d);
            return NULL;
        }
    }
    return d;
#else
    // PipeWire: os aplicativos ligados direto na nossa entrada, menos o telinha
    {
        audio_dev *d = calloc(1, sizeof *d);
        if (!d) return NULL;
        d->pw = pwcap_open(fn, user, NULL, 0);
        if (d->pw) return d;
        free(d);
    }
    // sem PipeWire: monitor da saída padrão (pega também o que o telinha toca)
    const ma_backend backends[] = {ma_backend_pulseaudio};
    audio_dev *d = open_dev(ma_device_type_capture, backends, 1, err, errlen);
    if (!d) {
        if (err && errlen > 0) snprintf(err, errlen, "pra capturar o áudio precisa do PulseAudio ou pipewire-pulse");
        return NULL;
    }
    d->capture = fn;
    d->user = user;
    d->hears_self = 1;
    // nome especial do PulseAudio/PipeWire: monitor da saída padrão
    ma_device_id id;
    memset(&id, 0, sizeof id);
    snprintf(id.pulse, sizeof id.pulse, "@DEFAULT_MONITOR@");
    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.pDeviceID = &id;
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = AUDIO_CHANNELS;
    if (start(d, &cfg, err, errlen) < 0) {
        audio_close(d);
        return NULL;
    }
    return d;
#endif
}

audio_dev *audio_output_open(audio_play_fn fn, void *user, char *err, int errlen) {
    audio_dev *d = open_dev(ma_device_type_playback, NULL, 0, err, errlen);
    if (!d) return NULL;
    d->play = fn;
    d->user = user;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = AUDIO_CHANNELS;
    if (start(d, &cfg, err, errlen) < 0) {
        audio_close(d);
        return NULL;
    }
    return d;
}

// Acha o id de um dispositivo de captura pelo nome.
static int find_capture(ma_context *ctx, const char *name, ma_device_id *out) {
    if (!name || !*name) return 0;
    ma_device_info *infos;
    ma_uint32 n;
    if (ma_context_get_devices(ctx, NULL, NULL, &infos, &n) != MA_SUCCESS) return 0;
    for (ma_uint32 i = 0; i < n; i++) {
        if (strcmp(infos[i].name, name) == 0) {
            *out = infos[i].id;
            return 1;
        }
    }
    return 0;
}

audio_dev *audio_mic_open(audio_capture_fn fn, void *user, const char *name, char *err, int errlen) {
    audio_dev *d = open_dev(ma_device_type_capture, NULL, 0, err, errlen);
    if (!d) return NULL;
    d->capture = fn;
    d->user = user;
    ma_device_id id;
    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    if (find_capture(&d->ctx, name, &id)) cfg.capture.pDeviceID = &id; // senão, o padrão
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = 1;
    if (start(d, &cfg, err, errlen) < 0) {
        audio_close(d);
        return NULL;
    }
    return d;
}

int audio_list_mics(char names[][128], int max) {
    ma_context ctx;
    if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) return 0;
    ma_device_info *infos;
    ma_uint32 n = 0;
    int out = 0;
    if (ma_context_get_devices(&ctx, NULL, NULL, &infos, &n) == MA_SUCCESS) {
        for (ma_uint32 i = 0; i < n && out < max; i++) {
            // monitores de saída do PulseAudio/PipeWire não são microfone
            if (strstr(infos[i].name, "Monitor of") || strstr(infos[i].name, "Monitor de")) continue;
            snprintf(names[out++], 128, "%s", infos[i].name);
        }
    }
    ma_context_uninit(&ctx);
    return out;
}

int audio_capture_hears_self(audio_dev *d) {
    return d ? d->hears_self : 0;
}
