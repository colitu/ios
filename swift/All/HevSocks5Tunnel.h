// hev-socks5-tunnel (https://github.com/heiher/hev-socks5-tunnel, MIT).
// scripts/build-libxray.sh builds it and links it into libXray.a; these are
// the entry points of its src/hev-main.h that the packet tunnel uses.

#ifndef HevSocks5Tunnel_h
#define HevSocks5Tunnel_h

#include <stddef.h>

/// Runs the tunnel on the calling thread until hev_socks5_tunnel_quit is
/// called or an error occurs. Returns 0 on success, -1 on error.
int hev_socks5_tunnel_main_from_str(const unsigned char *config_str,
                                    unsigned int config_len, int tun_fd);

/// Stops the tunnel. Safe to call from any thread.
void hev_socks5_tunnel_quit(void);

void hev_socks5_tunnel_stats(size_t *tx_packets, size_t *tx_bytes,
                             size_t *rx_packets, size_t *rx_bytes);

#endif /* HevSocks5Tunnel_h */
