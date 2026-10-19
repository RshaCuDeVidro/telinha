// Imagens que você manda no chat: ler o arquivo (PNG/JPEG/GIF/BMP) e, no
// Windows, a imagem copiada (área de transferência). Só roda no PC de quem
// manda: pela rede a imagem vai como um quadro H.264 (ver chatimg.zig), então
// nenhum leitor de imagem fica exposto ao que chega da sala.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#define STBI_MAX_DIMENSIONS 16384
#include "stb_image.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "image.h"

uint8_t *img_decode(const uint8_t *data, int len, int *w, int *h) {
    int n = 0;
    return stbi_load_from_memory(data, len, w, h, &n, 4);
}

void img_free(uint8_t *rgba) {
    stbi_image_free(rgba);
}

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>

// Copia um DIB (BITMAPINFOHEADER + pixels) pra RGBA de cima pra baixo.
static uint8_t *dib_to_rgba(const uint8_t *p, size_t size, int *w, int *h) {
    if (size < sizeof(BITMAPINFOHEADER)) return NULL;
    const BITMAPINFOHEADER *bi = (const BITMAPINFOHEADER *)p;
    const int bpp = bi->biBitCount;
    if (bi->biWidth <= 0 || bi->biHeight == 0 || (bpp != 24 && bpp != 32)) return NULL;
    if (bi->biCompression != BI_RGB && bi->biCompression != BI_BITFIELDS) return NULL;
    const int width = bi->biWidth;
    const int height = bi->biHeight < 0 ? -bi->biHeight : bi->biHeight;
    if (width > 16384 || height > 16384) return NULL;
    const int bottom_up = bi->biHeight > 0;
    size_t off = bi->biSize;
    if (bi->biCompression == BI_BITFIELDS && bi->biSize == sizeof(BITMAPINFOHEADER)) off += 12; // máscaras
    const size_t stride = (((size_t)width * bpp + 31) / 32) * 4;
    if (off + stride * height > size) return NULL;
    uint8_t *out = malloc((size_t)width * height * 4);
    if (!out) return NULL;
    // 32 bits: a "transparência" do DIB costuma vir zerada; só vale se alguém usar
    int any_alpha = 0;
    if (bpp == 32)
        for (int y = 0; y < height && !any_alpha; y++)
            for (int x = 0; x < width; x++)
                if (p[off + (size_t)y * stride + (size_t)x * 4 + 3]) {
                    any_alpha = 1;
                    break;
                }
    for (int y = 0; y < height; y++) {
        const uint8_t *row = p + off + (size_t)(bottom_up ? height - 1 - y : y) * stride;
        uint8_t *o = out + (size_t)y * width * 4;
        for (int x = 0; x < width; x++) {
            const uint8_t *px = row + (size_t)x * (bpp / 8);
            o[x * 4 + 0] = px[2];
            o[x * 4 + 1] = px[1];
            o[x * 4 + 2] = px[0];
            o[x * 4 + 3] = (bpp == 32 && any_alpha) ? px[3] : 255;
        }
    }
    *w = width;
    *h = height;
    return out;
}

uint8_t *img_clipboard(int *w, int *h, wchar_t *path, int path_cap) {
    uint8_t *out = NULL;
    if (path && path_cap > 0) path[0] = 0;
    if (!OpenClipboard(NULL)) return NULL;
    if (getenv("TELINHA_DEBUG")) {
        // diagnóstico: quais formatos tem na área de transferência
        for (UINT f = EnumClipboardFormats(0); f; f = EnumClipboardFormats(f)) {
            char name[64] = "";
            GetClipboardFormatNameA(f, name, sizeof name);
            fprintf(stderr, "[telinha] área de transferência: formato %u %s\n", f, name);
        }
    }
    // "PNG" (navegador, Ferramenta de Captura, wine): melhor que o DIB, tem transparência
    const UINT png = RegisterClipboardFormatA("PNG");
    HANDLE hd = png ? GetClipboardData(png) : NULL;
    if (hd) {
        const uint8_t *p = GlobalLock(hd);
        if (p) {
            const SIZE_T n = GlobalSize(hd);
            if (n > 0 && n < 64u * 1024 * 1024) out = img_decode(p, (int)n, w, h); // stbi usa malloc: free() serve
            GlobalUnlock(hd);
        }
        if (out) {
            CloseClipboard();
            return out;
        }
    }
    hd = GetClipboardData(CF_DIB);
    if (hd) {
        const uint8_t *p = GlobalLock(hd);
        if (p) {
            out = dib_to_rgba(p, GlobalSize(hd), w, h);
            GlobalUnlock(hd);
        }
    } else if (path && (hd = GetClipboardData(CF_HDROP))) {
        // arquivo copiado no Explorer: quem chama lê o arquivo
        DragQueryFileW((HDROP)hd, 0, path, (UINT)path_cap);
    }
    CloseClipboard();
    return out;
}
#endif
