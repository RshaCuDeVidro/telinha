/* Opções do FreeType pro telinha: ele só desenha a fonte de emoji do sistema
 * (o resto do texto é stb_truetype). Parte das opções padrão + ajustes. */
#include <freetype/config/ftoption.h>

/* emoji do Linux (Noto Color Emoji, CBDT) vem em PNG */
#define FT_CONFIG_OPTION_USE_PNG
/* sem WOFF (zlib), SVG, bzip2, brotli, harfbuzz: nada disso pra emoji */
#undef FT_CONFIG_OPTION_USE_ZLIB
#undef FT_CONFIG_OPTION_SVG
#undef FT_CONFIG_OPTION_USE_BZIP2
#undef FT_CONFIG_OPTION_USE_BROTLI
#undef FT_CONFIG_OPTION_USE_HARFBUZZ
/* emoji é bitmap/camadas coloridas: sem o interpretador de hinting (menor) */
#undef TT_CONFIG_OPTION_BYTECODE_INTERPRETER
