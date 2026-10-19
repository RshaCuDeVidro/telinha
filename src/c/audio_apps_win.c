// Windows: quem está tocando som agora, pelas sessões de áudio da saída
// padrão (o mesmo que aparece no mixer de volume do Windows).
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <stdio.h>
#include <string.h>

#include "audio.h"

static const GUID G_CLSID_MMDeviceEnumerator = {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID G_IID_IMMDeviceEnumerator = {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID G_IID_IAudioSessionManager2 = {0x77aa99a0, 0x1bd6, 0x484f, {0x8b, 0xc7, 0x2c, 0x65, 0x4c, 0x9a, 0x9b, 0x6f}};
static const GUID G_IID_IAudioSessionControl2 = {0xbfb7ff88, 0x7239, 0x4fc9, {0x8f, 0xa2, 0x07, 0xc9, 0x50, 0xbe, 0x9c, 0x6d}};

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

int audio_list_apps(audio_app *out, int max) {
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
                        if (_stricmp(out[j].name, name) == 0) dup = 1;
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

// Processo que está tocando som com esse nome (0 = nenhum).
uint32_t audio_app_pid_by_name(const char *name) {
    audio_app apps[32];
    const int n = audio_list_apps(apps, 32);
    for (int i = 0; i < n; i++)
        if (_stricmp(apps[i].name, name) == 0) return apps[i].pid;
    return 0;
}
