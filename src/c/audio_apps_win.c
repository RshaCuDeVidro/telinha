// Windows: quem está tocando som agora, pelas sessões de áudio da saída
// padrão (o mesmo que aparece no mixer de volume do Windows).
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <audioclient.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

#include "audio.h"

static const GUID G_CLSID_MMDeviceEnumerator = {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID G_IID_IMMDeviceEnumerator = {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID G_IID_IAudioSessionManager2 = {0x77aa99a0, 0x1bd6, 0x484f, {0x8b, 0xc7, 0x2c, 0x65, 0x4c, 0x9a, 0x9b, 0x6f}};
static const GUID G_IID_IAudioSessionControl2 = {0xbfb7ff88, 0x7239, 0x4fc9, {0x8f, 0xa2, 0x07, 0xc9, 0x50, 0xbe, 0x9c, 0x6d}};
static const GUID G_IID_IAudioClient = {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};

// Nome do executável sem pasta e sem ".exe" ("chrome", "Spotify").
static int process_name(DWORD pid, char *out, int cap) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    WCHAR path[MAX_PATH];
    DWORD n = MAX_PATH;
    BOOL ok = QueryFullProcessImageNameW(h, 0, path, &n);
    CloseHandle(h);
    if (!ok) return 0;
    WCHAR *base = path;
    for (WCHAR *p = path; *p; p++)
        if (*p == L'\\' || *p == L'/') base = p + 1;
    WCHAR *dot = NULL;
    for (WCHAR *p = base; *p; p++)
        if (*p == L'.') dot = p;
    if (dot && (_wcsicmp(dot, L".exe") == 0)) *dot = 0;
    return WideCharToMultiByte(CP_UTF8, 0, base, -1, out, cap, NULL, NULL) > 0;
}

// Sessões de áudio tocando agora (sem o telinha). dedup = um por nome.
static int list_sessions(audio_app *out, int max, int dedup) {
    int n = 0;
    const HRESULT init = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *en = NULL;
    IMMDevice *dev = NULL;
    IAudioSessionManager2 *mgr = NULL;
    IAudioSessionEnumerator *sessions = NULL;
    if (FAILED(CoCreateInstance(&G_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &G_IID_IMMDeviceEnumerator, (void **)&en))) goto done;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev))) goto done;
    if (FAILED(IMMDevice_Activate(dev, &G_IID_IAudioSessionManager2, CLSCTX_ALL, NULL, (void **)&mgr))) goto done;
    if (FAILED(IAudioSessionManager2_GetSessionEnumerator(mgr, &sessions))) goto done;
    int count = 0;
    IAudioSessionEnumerator_GetCount(sessions, &count);
    const DWORD self = GetCurrentProcessId();
    for (int i = 0; i < count && n < max; i++) {
        IAudioSessionControl *ctl = NULL;
        IAudioSessionControl2 *ctl2 = NULL;
        if (FAILED(IAudioSessionEnumerator_GetSession(sessions, i, &ctl))) continue;
        if (SUCCEEDED(IAudioSessionControl_QueryInterface(ctl, &G_IID_IAudioSessionControl2, (void **)&ctl2))) {
            DWORD pid = 0;
            AudioSessionState st = AudioSessionStateExpired;
            IAudioSessionControl2_GetProcessId(ctl2, &pid);
            IAudioSessionControl_GetState(ctl, &st);
            // 0 = sons do sistema; sessões expiradas = programa que já parou
            if (pid != 0 && pid != self && st != AudioSessionStateExpired) {
                char name[64];
                if (process_name(pid, name, sizeof name)) {
                    int dup = 0;
                    for (int j = 0; j < n; j++)
                        if (dedup ? _stricmp(out[j].name, name) == 0 : out[j].pid == pid) dup = 1;
                    if (!dup) {
                        snprintf(out[n].name, sizeof out[n].name, "%s", name);
                        out[n].pid = pid;
                        n++;
                    }
                }
            }
            IAudioSessionControl2_Release(ctl2);
        }
        IAudioSessionControl_Release(ctl);
    }
done:
    if (sessions) IAudioSessionEnumerator_Release(sessions);
    if (mgr) IAudioSessionManager2_Release(mgr);
    if (dev) IMMDevice_Release(dev);
    if (en) IMMDeviceEnumerator_Release(en);
    if (SUCCEEDED(init)) CoUninitialize();
    return n;
}

int audio_list_apps(audio_app *out, int max) {
    return list_sessions(out, max, 1);
}

// `name` está na lista (nomes separados por \n, sem diferença de maiúscula)?
static int in_list(const char *list, const char *name) {
    if (!list || !name || !*name) return 0;
    const size_t n = strlen(name);
    for (const char *p = list; *p;) {
        const char *e = strchr(p, '\n');
        const size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == n && !_strnicmp(p, name, n)) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

#define MAX_PROCS 4096

// Quais processos com som dá pra capturar um por um ("tudo menos os
// excluídos"). A captura de um processo pega a árvore dele inteira: um pai
// cuja árvore contém o telinha, um excluído ou outra sessão (o explorer, um
// launcher) não entra — senão o excluído (ou o próprio telinha, em eco)
// voltaria por ele, ou o som sairia em dobro.
int audio_mix_pids(const char *exclude, uint32_t *out, int max) {
    audio_app sess[64];
    const int ns = list_sessions(sess, 64, 0);
    // processos: pai de cada um e os excluídos (com ou sem sessão de áudio)
    static DWORD pids[MAX_PROCS], parents[MAX_PROCS];
    static unsigned char excluded[MAX_PROCS];
    int np = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W pe;
        pe.dwSize = sizeof pe;
        for (BOOL ok = Process32FirstW(snap, &pe); ok && np < MAX_PROCS; ok = Process32NextW(snap, &pe)) {
            char name[260];
            if (WideCharToMultiByte(CP_UTF8, 0, pe.szExeFile, -1, name, sizeof name, NULL, NULL) <= 0) name[0] = 0;
            char *dot = strrchr(name, '.');
            if (dot && !_stricmp(dot, ".exe")) *dot = 0;
            pids[np] = pe.th32ProcessID;
            parents[np] = pe.th32ParentProcessID;
            excluded[np] = (unsigned char)in_list(exclude, name);
            np++;
        }
        CloseHandle(snap);
    }
    const DWORD self = GetCurrentProcessId();
    int n = 0;
    for (int i = 0; i < ns && n < max; i++) {
        const DWORD cand = sess[i].pid;
        if (in_list(exclude, sess[i].name)) continue;
        // alguém "protegido" (telinha, excluído, outra sessão) descende de cand?
        int blocked = 0;
        for (int k = 0; k < np && !blocked; k++) {
            const DWORD g = pids[k];
            if (g == cand) continue;
            int guard = g == self || excluded[k];
            for (int j = 0; j < ns && !guard; j++)
                if (sess[j].pid == g) guard = 1;
            if (!guard) continue;
            // sobe a árvore de g procurando cand
            DWORD cur = g;
            for (int steps = 0; steps < 64; steps++) {
                DWORD par = 0;
                for (int m = 0; m < np; m++)
                    if (pids[m] == cur) {
                        par = parents[m];
                        break;
                    }
                if (par == 0 || par == cur) break;
                if (par == cand) {
                    blocked = 1;
                    break;
                }
                cur = par;
            }
        }
        if (!blocked) out[n++] = cand;
    }
    return n;
}

// Processo que está tocando som com esse nome (0 = nenhum).
uint32_t audio_app_pid_by_name(const char *name) {
    audio_app apps[32];
    const int n = audio_list_apps(apps, 32);
    for (int i = 0; i < n; i++)
        if (_stricmp(apps[i].name, name) == 0) return apps[i].pid;
    return 0;
}

// A captura do som não abriu: testa o loopback direto no WASAPI, passo a
// passo, e escreve no log o formato da saída e o código de cada tentativa (o
// miniaudio só diz "Invalid argument"). Só roda quando dá errado, uma vez.
void audio_loopback_probe(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    HRESULT co = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *en = NULL;
    IMMDevice *dev = NULL;
    HRESULT hr = CoCreateInstance(&G_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &G_IID_IMMDeviceEnumerator, (void **)&en);
    if (SUCCEEDED(hr)) hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev);
    if (FAILED(hr)) {
        fprintf(stderr, "[telinha] teste do som: sem saída padrão (0x%08lx)\n", (unsigned long)hr);
        goto out;
    }
    DWORD state = 0;
    IMMDevice_GetState(dev, &state);
    static const struct {
        DWORD flags;
        const char *name;
    } tries[] = {
        {AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, "loopback+evento"},
        {AUDCLNT_STREAMFLAGS_LOOPBACK, "loopback"},
        {AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, "loopback+evento+48k"},
    };
    for (int i = 0; i < 3; i++) {
        IAudioClient *ac = NULL;
        WAVEFORMATEX *mix = NULL;
        hr = IMMDevice_Activate(dev, &G_IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&ac);
        if (SUCCEEDED(hr)) hr = IAudioClient_GetMixFormat(ac, &mix);
        if (FAILED(hr)) {
            fprintf(stderr, "[telinha] teste do som: a saída não abre (estado %lu, 0x%08lx)\n", (unsigned long)state, (unsigned long)hr);
            if (ac) IAudioClient_Release(ac);
            break;
        }
        if (i == 0)
            fprintf(stderr, "[telinha] teste do som: saída padrão estado %lu, formato 0x%04x %u canais %lu Hz %u bits\n", (unsigned long)state,
                    mix->wFormatTag, mix->nChannels, (unsigned long)mix->nSamplesPerSec, mix->wBitsPerSample);
        WAVEFORMATEX want = *mix;
        if (tries[i].flags & AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM) {
            want.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
            want.nChannels = 2;
            want.nSamplesPerSec = 48000;
            want.wBitsPerSample = 32;
            want.nBlockAlign = 8;
            want.nAvgBytesPerSec = 48000 * 8;
            want.cbSize = 0;
        }
        hr = IAudioClient_Initialize(ac, AUDCLNT_SHAREMODE_SHARED, tries[i].flags, 2000000, 0, (tries[i].flags & AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM) ? &want : mix, NULL);
        fprintf(stderr, "[telinha] teste do som: %s -> 0x%08lx%s\n", tries[i].name, (unsigned long)hr, SUCCEEDED(hr) ? " (abriu)" : "");
        CoTaskMemFree(mix);
        IAudioClient_Release(ac);
    }
out:
    if (dev) IMMDevice_Release(dev);
    if (en) IMMDeviceEnumerator_Release(en);
    if (SUCCEEDED(co)) CoUninitialize();
}
