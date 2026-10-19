/* config.h do SpeexDSP pro build do telinha (o original sai do ./configure):
 * ponto flutuante, FFT própria (smallft), sem SIMD manual. */
#define FLOATING_POINT 1
#define USE_SMALLFT 1
#define EXPORT
#define VAR_ARRAYS 1
