# iOS VPN core provenance

`scripts/build-libxray.sh` fetches `https://github.com/XTLS/libXray.git` at commit:

```text
9a86646da8d800208188864a820c333f9b6bbe76
```

This revision is pinned because it still exposes the legacy C ABI consumed by
`c/include/libXray.h` and the generated Dart FFI bindings; the script fails when a
required symbol is missing. Override with `LIBXRAY_REF` only together with a
matching header and regenerated bindings. Release evidence must retain the
resolved commit (printed by the script), the build log and the SHA-256 of the
produced `swift/All/LibXray.xcframework` archive.

## tun2socks

The same script links `https://github.com/heiher/hev-socks5-tunnel.git` (MIT)
into every slice of `libXray.a`, at tag `2.17.1`, commit:

```text
9a06bc6e7989da54e3d32ff701ef7a7ce4995d3a
```

The packet tunnel does not start Xray's TUN inbound (its gVisor TCP stack
lets each connection buffer megabytes, too much for the extension's ~50 MB
cap). It rewrites that inbound into a local SOCKS5 inbound with the same tag
and sniffing, and hev-socks5-tunnel (lwIP) turns the tunnel's packets into
SOCKS5 connections to it, as on Android. The script fails when the tag no
longer resolves to the pinned commit; override `HEV_REF` together with
`HEV_COMMIT`. The entry points the tunnel calls are declared in
`swift/All/HevSocks5Tunnel.h`.

## xray-core patch

libXray is built against a copy of its pinned xray-core with one addition,
`ResetClients()` in `transport/internet/hysteria/dialer.go`, exported to the
tunnel as `CGoResetHysteria`. Xray caches Hysteria2 QUIC clients in a
package-level map that outlives the core instance, so a restarted core would
reuse the previous core's connection; after a device sleep that connection is
dead on the server but still looks active in the client (Go's monotonic clock
stops while iOS sleeps). The tunnel resets the cache on every core stop and
after every sleep of 10 s or more. The script fails if the dialer no longer
has the code the patch relies on.

