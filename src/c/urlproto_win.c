// Links telinha:// abrindo no telinha (Windows): registra o protocolo na conta
// do usuário (HKCU\Software\Classes\telinha, sem pedir administrador), apontando
// pro executável de agora. Só escreve quando o valor muda (o app foi movido,
// atualizado pra outra pasta): abrir o app normalmente não mexe no registro.
// Sem isso, o convite clicado no Discord ou no navegador não abria nada.
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

static int set_str(HKEY root, const wchar_t *sub, const wchar_t *name, const wchar_t *val) {
    HKEY k;
    if (RegCreateKeyExW(root, sub, 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS) return -1;
    const LONG r = RegSetValueExW(k, name, 0, REG_SZ, (const BYTE *)val, (DWORD)((wcslen(val) + 1) * sizeof(wchar_t)));
    RegCloseKey(k);
    return r == ERROR_SUCCESS ? 0 : -1;
}

// 1 = registrou (ou atualizou), 0 = já estava certo, -1 = erro.
int urlproto_register(void) {
    wchar_t exe[1024];
    const DWORD n = GetModuleFileNameW(NULL, exe, 1024);
    if (n == 0 || n >= 1024) return -1;
    wchar_t cmd[1100];
    _snwprintf(cmd, 1100, L"\"%ls\" \"%%1\"", exe);
    cmd[1099] = 0;
    // já aponta pra cá?
    wchar_t cur[1100];
    DWORD sz = sizeof cur;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Classes\\telinha\\shell\\open\\command", NULL, RRF_RT_REG_SZ, NULL, cur, &sz) == ERROR_SUCCESS &&
        wcscmp(cur, cmd) == 0)
        return 0;
    wchar_t icon[1100];
    _snwprintf(icon, 1100, L"\"%ls\",0", exe);
    icon[1099] = 0;
    if (set_str(HKEY_CURRENT_USER, L"Software\\Classes\\telinha", NULL, L"URL:telinha") < 0) return -1;
    if (set_str(HKEY_CURRENT_USER, L"Software\\Classes\\telinha", L"URL Protocol", L"") < 0) return -1;
    if (set_str(HKEY_CURRENT_USER, L"Software\\Classes\\telinha\\DefaultIcon", NULL, icon) < 0) return -1;
    if (set_str(HKEY_CURRENT_USER, L"Software\\Classes\\telinha\\shell\\open\\command", NULL, cmd) < 0) return -1;
    return 1;
}

// Tira o registro (a opção desligada).
void urlproto_unregister(void) {
    RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Classes\\telinha");
}
#endif
