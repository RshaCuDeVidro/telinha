// Carregador de fonte do ImGui só pra emoji (FreeType, colorido). Ver emoji_loader.cpp.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
struct ImFontLoader;
// O carregador (ImFontConfig.FontLoader da fonte de emoji).
const struct ImFontLoader *telinha_emoji_loader(void);
#ifdef __cplusplus
}
#endif
