// Endereços IPv6 globais desta máquina no Windows (pro convite com vários
// caminhos). Pula temporários (privacidade) quando tem um estável.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <stdlib.h>
#include <string.h>

int local_ip6(unsigned char out[][16], int max) {
    ULONG size = 16 * 1024;
    IP_ADAPTER_ADDRESSES *list = NULL;
    ULONG r = ERROR_BUFFER_OVERFLOW;
    for (int tries = 0; tries < 3 && r == ERROR_BUFFER_OVERFLOW; tries++) {
        free(list);
        list = (IP_ADAPTER_ADDRESSES *)malloc(size);
        if (!list) return 0;
        r = GetAdaptersAddresses(AF_INET6, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, NULL, list, &size);
    }
    int n = 0, temp_n = 0;
    unsigned char temps[8][16];
    if (r == NO_ERROR) {
        for (IP_ADAPTER_ADDRESSES *a = list; a; a = a->Next) {
            if (a->OperStatus != IfOperStatusUp) continue;
            for (IP_ADAPTER_UNICAST_ADDRESS *u = a->FirstUnicastAddress; u; u = u->Next) {
                if (u->Address.lpSockaddr->sa_family != AF_INET6 || u->DadState != IpDadStatePreferred) continue;
                const unsigned char *b = ((struct sockaddr_in6 *)u->Address.lpSockaddr)->sin6_addr.s6_addr;
                if ((b[0] & 0xE0) != 0x20) continue; // só 2000::/3 (global)
                if (u->SuffixOrigin == IpSuffixOriginRandom) {
                    if (temp_n < 8) memcpy(temps[temp_n++], b, 16);
                    continue;
                }
                if (n < max) memcpy(out[n++], b, 16);
            }
        }
    }
    free(list);
    // sem estável: usa um temporário (vale por dias, dá pra uma sessão)
    for (int i = 0; n == 0 && i < temp_n && n < max; i++) memcpy(out[n++], temps[i], 16);
    return n;
}
