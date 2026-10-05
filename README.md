# Colitu VPN for iOS

[![Build](https://img.shields.io/github/actions/workflow/status/Colitu-VPN/colitu-ios/ci.yml?branch=main&style=flat-square&label=build&labelColor=101014)](https://github.com/Colitu-VPN/colitu-ios/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/tag/Colitu-VPN/colitu-ios?style=flat-square&label=release&labelColor=101014&color=7c6cff)](https://github.com/Colitu-VPN/colitu-ios/tags)
[![License](https://img.shields.io/badge/license-GPL--3.0-7c6cff?style=flat-square&labelColor=101014)](LICENSE)
[![Colitu Network](https://img.shields.io/endpoint?url=https://status.colitu.com/api/github-badge/network&style=flat-square)](https://status.colitu.com)

**English** · [Русский](README.ru.md)

The open-source iPhone and iPad client of [Colitu VPN](https://colitu.com). A
Flutter interface drives a Swift Network Extension (packet tunnel) that runs
[Xray-core](https://github.com/XTLS/Xray-core) through
[libXray](https://github.com/XTLS/libXray), and every account, plan and server
detail comes from the Colitu API.

| | |
|---|---|
| Bundle IDs | `com.colitu.vpn` (app), `com.colitu.vpn.tun` (packet tunnel) |
| Minimum iOS | 15.0 |
| Languages | Russian, English, Turkish (switch instantly in the app) |
| Install | [TestFlight](https://testflight.apple.com/join/fnVUd6GQ) (public beta) |
| Website | <https://colitu.com> |
| License | [GPL-3.0](LICENSE) |

> A Colitu account is required to connect. The app has no hard-coded servers:
> the server list and connection profiles are issued per device by the Colitu API.

## Features

- **Automatic protocol selection.** Hysteria2, VLESS Reality / XHTTP, Trojan
  and Shadowsocks endpoints are tried in order, the tunnel is verified with a
  real request, and the app moves to the next candidate if one fails.
- **Full account flow in the app.** Onboarding, sign-in and registration,
  password reset, approving a TV sign-in by QR code, plan status, devices,
  usage and a support inbox. Nothing is sold inside the app: plans are bought
  and renewed in the customer account on app.colitu.com.
- **Server locations** with on-device latency and a remembered location.
- **Always-on VPN** through iOS on-demand rules, and auto-connect.
- **Optional ad and tracker blocking** through Colitu's own DNS servers
  (DNS-over-HTTPS inside the tunnel; the servers keep no query log).
- **Secure storage.** Session tokens live in the iOS Keychain; the tunnel
  configuration is only shared with the extension through the app group.
- **No tracking.** No Firebase, analytics, advertising or crash-reporting SDK.
  Diagnostics stay on the device until you share a report yourself, with
  credentials and e-mail addresses masked.

## How it connects

1. `POST /auth/login` (or `/auth/register`) returns an access/refresh token pair.
2. `POST /devices/register` binds the install to a device slot.
3. `GET /client/bootstrap`, `/me`, `/me/usage` and `/servers` fill the UI.
4. Picking a location calls `PUT /me/preferences`, then `GET /config` returns a
   device-bound configuration envelope with a primary profile and alternatives.
5. The app turns the envelope into an Xray configuration and starts the packet
   tunnel. The extension runs Xray with a local SOCKS inbound, and
   [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) turns the
   tunnel's packets into connections to it (see
   [docs/core-provenance.md](docs/core-provenance.md)).

The app never computes prices, eligibility or device limits itself; the server
decides. The endpoints are listed in `lib/colitu/api/api_endpoint.dart` and
summarised in [COLITU_API_CONTRACT.md](COLITU_API_CONTRACT.md).

## Repository layout

| Path | Contents |
|---|---|
| `lib/colitu/` | Colitu API client, account and connection logic, theme, translations |
| `lib/pages/colitu/` | Colitu screens (onboarding, sign-in, home, locations, account, support) |
| `lib/service/` | Xray configuration builder, VPN service and native bridge |
| `swift/App`, `swift/Tunnel`, `swift/All` | VPN manager, packet tunnel provider and shared Swift code |
| `ios/` | Xcode project, app and tunnel targets, entitlements, privacy manifests |
| `c/include/libXray.h` | C header of libXray; Dart FFI bindings are generated from it |
| `scripts/` | libXray build, FFI binding generation, icon generation |
| `test/` | Unit tests and golden screenshots of the Colitu screens |

## Building

You need macOS with Xcode, Flutter (stable), Go and Python 3.

```bash
flutter pub get
scripts/build-libxray.sh          # builds swift/All/LibXray.xcframework from source
scripts/generate-ffi-bindings.sh  # regenerates the Dart FFI bindings
flutter analyze --no-fatal-infos
flutter test
flutter build ios --simulator --no-codesign
```

`scripts/build-libxray.sh` fetches libXray, Xray-core and hev-socks5-tunnel at
pinned commits and fails if they do not match; see
[docs/core-provenance.md](docs/core-provenance.md).

Optional build-time settings (`--dart-define`):

| Name | Purpose |
|---|---|
| `COLITU_API_BASE_URL` | API base URL, default `https://api.colitu.com/api/v1` |
| `COLITU_ADBLOCK_DOH` | Comma-separated DNS-over-HTTPS URLs of the ad-blocking servers. Without it the ad-blocking switch is hidden. |

Running on a device needs your own Apple developer team, bundle IDs, app group
and provisioning profiles for both targets. Release builds are made by
Codemagic (`codemagic.yaml`) and uploaded to TestFlight; details are in
[docs/build.md](docs/build.md) and [docs/release.md](docs/release.md).

## Security

Please report vulnerabilities privately to **security@colitu.com**, not in a
public issue. See [SECURITY.md](SECURITY.md) and the
[Colitu Security Whitepaper](https://colitu.com/security).

## Contributing

Bug reports, translation fixes and focused pull requests are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md). Account, payment and connection problems
are handled by support at <https://colitu.com/support>.

## License

Colitu VPN for iOS is free software under the [GNU GPL v3.0](LICENSE). Third-party
components and their licences are listed in [NOTICE](NOTICE). The Colitu name
and logo are not covered by the GPL: if you publish your own build, use your
own name and logo.
