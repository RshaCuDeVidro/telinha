// Windows: som de um processo só (ou de tudo menos ele) pelo loopback por
// processo do WASAPI (Windows 10 2004+). O miniaudio 0.11.25 não abre isso no
// desktop: procura o dispositivo virtual "VAD\Process_Loopback" na lista
// normal (IMMDeviceEnumerator::GetDevice), que nunca tem, e falha com "Failed
// to retrieve IMMDevice" em qualquer Windows. Aqui é o caminho da Microsoft:
// ActivateAudioInterfaceAsync no dispositivo virtual, com o formato escolhido
// por nós (GetMixFormat não funciona nele) e uma thread lendo os pacotes.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <propidl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "audio.h"
#include "audio_proc_win.h"

static const GUID P_IID_IUnknown = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID P_IID_IAgileObject = {0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};
static const GUID P_IID_IActivateAudioInterfaceCompletionHandler = {0x41d949ab, 0x9862, 0x444a, {0x80, 0xf6, 0xc2, 0x61, 0x33, 0x4d, 0xa5, 0xeb}};
static const GUID P_IID_IAudioClient = {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID P_IID_IAudioCaptureClient = {0xc8adbd64, 0xe71e, 0x48a0, {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}};

// audioclientactivationparams.h (não vem no mingw)
enum { ACTIVATION_TYPE_PROCESS_LOOPBACK = 1 };
enum { LOOPBACK_INCLUDE_TREE = 0, LOOPBACK_EXCLUDE_TREE = 1 };
typedef struct {
    DWORD activation_type;
    DWORD target_pid;
    DWORD mode;
} activation_params;

typedef HRESULT(WINAPI *activate_fn)(LPCWSTR, REFIID, PROPVARIANT *, IActivateAudioInterfaceCompletionHandler *, IActivateAudioInterfaceAsyncOperation **);

// O "completion handler": só avisa que a ativação terminou. Agile (o Windows
// chama de outra thread) e contado de verdade: a operação pode soltar depois.
typedef struct {
    IActivateAudioInterfaceCompletionHandler iface;
    LONG refs;
    HANDLE done;
} handler;

static HRESULT STDMETHODCALLTYPE h_qi(IActivateAudioInterfaceCompletionHandler *self, REFIID riid, void **out) {
    if (IsEqualIID(riid, &P_IID_IUnknown) || IsEqualIID(riid, &P_IID_IActivateAudioInterfaceCompletionHandler) || IsEqualIID(riid, &P_IID_IAgileObject)) {
        *out = self;
        InterlockedIncrement(&((handler *)self)->refs);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE h_addref(IActivateAudioInterfaceCompletionHandler *self) {
    return (ULONG)InterlockedIncrement(&((handler *)self)->refs);
}

static ULONG STDMETHODCALLTYPE h_release(IActivateAudioInterfaceCompletionHandler *self) {
    handler *h = (handler *)self;
    const LONG n = InterlockedDecrement(&h->refs);
    if (n == 0) {
        CloseHandle(h->done);
        free(h);
    }
    return (ULONG)n;
}

static HRESULT STDMETHODCALLTYPE h_completed(IActivateAudioInterfaceCompletionHandler *self, IActivateAudioInterfaceAsyncOperation *op) {
    (void)op;
    SetEvent(((handler *)self)->done);
    return S_OK;
}

static IActivateAudioInterfaceCompletionHandlerVtbl h_vtbl = {h_qi, h_addref, h_release, h_completed};

struct proc_loop {
    HANDLE thread, ready, stop_ev;
    volatile LONG stop;
    uint32_t pid;
    int exclude;
    audio_capture_fn fn;
    void *user;
    HRESULT result; // da abertura (a thread preenche antes de `ready`)
    const char *step; // em qual passo falhou
    float conv[4800 * AUDIO_CHANNELS]; // PCM 16 bits → float, ou silêncio
};

static IAudioClient *activate(proc_loop *p, HRESULT *hr) {
    static activate_fn act = NULL;
    if (!act) {
        HMODULE m = LoadLibraryW(L"mmdevapi.dll");
        if (m) act = (activate_fn)(void *)GetProcAddress(m, "ActivateAudioInterfaceAsync");
    }
    if (!act) {
        *hr = E_NOTIMPL;
        p->step = "sem ActivateAudioInterfaceAsync";
        return NULL;
    }
    handler *h = calloc(1, sizeof *h);
    if (!h) {
        *hr = E_OUTOFMEMORY;
        return NULL;
    }
    h->iface.lpVtbl = &h_vtbl;
    h->refs = 1;
    h->done = CreateEventW(NULL, TRUE, FALSE, NULL);
    activation_params ap = {ACTIVATION_TYPE_PROCESS_LOOPBACK, p->pid, p->exclude ? LOOPBACK_EXCLUDE_TREE : LOOPBACK_INCLUDE_TREE};
    PROPVARIANT pv;
    memset(&pv, 0, sizeof pv);
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof ap;
    pv.blob.pBlobData = (BYTE *)&ap;
    IActivateAudioInterfaceAsyncOperation *op = NULL;
    IAudioClient *ac = NULL;
    *hr = act(L"VAD\\Process_Loopback", &P_IID_IAudioClient, &pv, &h->iface, &op);
    if (FAILED(*hr)) {
        p->step = "ActivateAudioInterfaceAsync";
    } else if (WaitForSingleObject(h->done, 5000) != WAIT_OBJECT_0) {
        *hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        p->step = "esperando a ativação";
    } else {
        HRESULT res = E_FAIL;
        IUnknown *unk = NULL;
        *hr = IActivateAudioInterfaceAsyncOperation_GetActivateResult(op, &res, &unk);
        if (SUCCEEDED(*hr)) *hr = res;
        if (SUCCEEDED(*hr) && unk) *hr = IUnknown_QueryInterface(unk, &P_IID_IAudioClient, (void **)&ac);
        if (unk) IUnknown_Release(unk);
        if (FAILED(*hr)) p->step = "ativação";
    }
    if (op) IActivateAudioInterfaceAsyncOperation_Release(op);
    h_release(&h->iface);
    return ac;
}

static DWORD WINAPI run(LPVOID arg) {
    proc_loop *p = arg;
    const HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    HRESULT hr = S_OK;
    IAudioCaptureClient *cc = NULL;
    HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    int pcm16 = 0;
    IAudioClient *ac = activate(p, &hr);
    if (ac) {
        // float 48 kHz estéreo; se recusar, PCM 16 bits (o exemplo da Microsoft)
        // e a gente converte. AUTOCONVERTPCM: o Windows reamostra da saída.
        const DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        for (int t = 0; t < 2; t++) {
            WAVEFORMATEX wf;
            memset(&wf, 0, sizeof wf);
            wf.wFormatTag = t == 0 ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
            wf.nChannels = AUDIO_CHANNELS;
            wf.nSamplesPerSec = AUDIO_RATE;
            wf.wBitsPerSample = t == 0 ? 32 : 16;
            wf.nBlockAlign = (WORD)(wf.nChannels * wf.wBitsPerSample / 8);
            wf.nAvgBytesPerSec = wf.nSamplesPerSec * wf.nBlockAlign;
            if (t == 1) {
                // um IAudioClient que recusou o Initialize não aceita outro: ativa de novo
                IAudioClient_Release(ac);
                ac = activate(p, &hr);
                if (!ac) break;
            }
            hr = IAudioClient_Initialize(ac, AUDCLNT_SHAREMODE_SHARED, flags, 200000 /* 20 ms */, 0, &wf, NULL);
            if (SUCCEEDED(hr)) {
                pcm16 = t == 1;
                break;
            }
            p->step = "Initialize";
        }
    }
    if (ac && SUCCEEDED(hr)) {
        hr = IAudioClient_SetEventHandle(ac, ev);
        if (SUCCEEDED(hr)) hr = IAudioClient_GetService(ac, &P_IID_IAudioCaptureClient, (void **)&cc);
        if (SUCCEEDED(hr)) hr = IAudioClient_Start(ac);
        if (FAILED(hr)) p->step = "Start";
    }
    p->result = hr;
    SetEvent(p->ready);
    if (SUCCEEDED(hr)) {
        HANDLE waits[2] = {ev, p->stop_ev};
        while (!p->stop) {
            // sem nada tocando o Windows não manda pacote nenhum: espera o evento
            if (WaitForMultipleObjects(2, waits, FALSE, 200) == WAIT_OBJECT_0 + 1) break;
            UINT32 n = 0;
            while (!p->stop && SUCCEEDED(IAudioCaptureClient_GetNextPacketSize(cc, &n)) && n > 0) {
                BYTE *data = NULL;
                UINT32 frames = 0;
                DWORD bf = 0;
                if (FAILED(IAudioCaptureClient_GetBuffer(cc, &data, &frames, &bf, NULL, NULL))) break;
                for (UINT32 off = 0; off < frames;) {
                    const UINT32 k = frames - off < 4800 ? frames - off : 4800;
                    const float *out;
                    if (bf & AUDCLNT_BUFFERFLAGS_SILENT) {
                        memset(p->conv, 0, (size_t)k * AUDIO_CHANNELS * sizeof(float));
                        out = p->conv;
                    } else if (pcm16) {
                        const int16_t *s = (const int16_t *)data + (size_t)off * AUDIO_CHANNELS;
                        for (UINT32 i = 0; i < k * AUDIO_CHANNELS; i++) p->conv[i] = (float)s[i] * (1.0f / 32768.0f);
                        out = p->conv;
                    } else {
                        out = (const float *)data + (size_t)off * AUDIO_CHANNELS;
                    }
                    p->fn(p->user, out, (int)k);
                    off += k;
                }
                IAudioCaptureClient_ReleaseBuffer(cc, frames);
            }
        }
        IAudioClient_Stop(ac);
    }
    if (cc) IAudioCaptureClient_Release(cc);
    if (ac) IAudioClient_Release(ac);
    CloseHandle(ev);
    if (SUCCEEDED(co)) CoUninitialize();
    return 0;
}

proc_loop *proc_loop_open(uint32_t pid, int exclude, audio_capture_fn fn, void *user, char *err, int errlen) {
    proc_loop *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->pid = pid;
    p->exclude = exclude;
    p->fn = fn;
    p->user = user;
    p->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    p->stop_ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    p->thread = CreateThread(NULL, 0, run, p, 0, NULL);
    if (!p->thread) {
        if (err && errlen > 0) snprintf(err, errlen, "não consegui criar a thread do som");
        proc_loop_close(p);
        return NULL;
    }
    WaitForSingleObject(p->ready, INFINITE);
    if (FAILED(p->result)) {
        fprintf(stderr, "[telinha] som por processo (%s pid %u): %s falhou (0x%08lx)\n", exclude ? "menos" : "só", (unsigned)pid,
                p->step ? p->step : "?", (unsigned long)p->result);
        if (err && errlen > 0) snprintf(err, errlen, "o Windows recusou o som por programa (0x%08lx)", (unsigned long)p->result);
        proc_loop_close(p);
        return NULL;
    }
    SetThreadPriority(p->thread, THREAD_PRIORITY_TIME_CRITICAL);
    return p;
}

void proc_loop_close(proc_loop *p) {
    if (!p) return;
    if (p->thread) {
        InterlockedExchange(&p->stop, 1);
        SetEvent(p->stop_ev);
        WaitForSingleObject(p->thread, INFINITE);
        CloseHandle(p->thread);
    }
    if (p->ready) CloseHandle(p->ready);
    if (p->stop_ev) CloseHandle(p->stop_ev);
    free(p);
}
