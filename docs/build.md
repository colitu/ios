# Building and signing

## Identifiers

| | |
|---|---|
| Main app | `com.colitu.vpn` |
| Network Extension | `com.colitu.vpn.tun` |
| App Group | `group.com.colitu.vpn` |
| Apple Team ID | `7C74T7SHR5` |

To build for your own device, replace these with your own team, bundle IDs
and app group (Xcode project, entitlements, `ios/exportOptions.*.plist`).

Both the main app and the tunnel extension need their own provisioning
profile; the tunnel target must not reuse the app's profile. The Xcode project
uses manual signing for both targets. Do not enable automatic signing in CI:
CI installs certificates and profiles fetched through the App Store Connect
API.

## Native core

`swift/All/LibXray.xcframework` is required before any iOS build. It is built
from source and is not committed. On macOS:

```bash
scripts/build-libxray.sh
scripts/generate-ffi-bindings.sh
```

The script uses libXray's own build system (`python3 build/main.py apple go`,
falling back to `gomobile`), links hev-socks5-tunnel into every slice and
copies the result to `swift/All/LibXray.xcframework`. The pinned commits and
the one xray-core patch are described in [core-provenance.md](core-provenance.md).
Overrides: `LIBXRAY_REF`, `LIBXRAY_BUILD_DIR`, `HEV_REF` + `HEV_COMMIT`.

The repository keeps a minimal `lib/core/ffi/generated_bindings.dart` so the
Dart code compiles before the bindings are regenerated.

App icons are generated from the root `colitu-icon.png` when it changes:

```bash
python3 -m pip install --user Pillow
python3 scripts/generate-ios-icons.py
```

On Linux or Windows only `flutter analyze` and `flutter test` work; the
libXray build, `xcodebuild`, signing and archives need macOS.

## Signing files

Development profiles (the device UDID must be in both):

```bash
app-store-connect fetch-signing-files com.colitu.vpn --create \
  --type IOS_APP_DEVELOPMENT --platform IOS \
  --issuer-id "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" \
  --private-key @env:AUTH_KEY --certificate-key @env:CERTIFICATE_KEY

app-store-connect fetch-signing-files com.colitu.vpn.tun --create \
  --type IOS_APP_DEVELOPMENT --platform IOS \
  --issuer-id "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" \
  --private-key @env:AUTH_KEY --certificate-key @env:CERTIFICATE_KEY
```

For TestFlight / App Store use `--type IOS_APP_STORE` with the same commands,
and set the profile names for archive builds:

```bash
export COLITU_APP_PROFILE_SPECIFIER=ColituSecureVPNiOS
export COLITU_TUN_PROFILE_SPECIFIER=ColituSecureVPNTun
```

| | Development | TestFlight / App Store |
|---|---|---|
| Mode | Debug | Release |
| Signing type | `IOS_APP_DEVELOPMENT` | `IOS_APP_STORE` |
| Export method | `development` | `app-store` |
| Certificate | Apple Development | Apple Distribution |

## Codemagic

`codemagic.yaml` builds the release: it builds libXray, generates the FFI
bindings and icons, installs signing files from the App Store Connect API and
uploads the IPA to TestFlight. Secrets live in the `TESTER` variable group,
never in this repository:

- `CERTIFICATE_PRIVATE_KEY_B64`, `CERTIFICATE_KEY_PASSWORD`
- `COLITU_ADBLOCK_DOH` — comma-separated DNS-over-HTTPS URLs of the
  ad-blocking servers (the build fails without it)

Local fastlane lanes read their App Store Connect key from `.env` (see
`.env.example`); the `.p8` file goes to `ios/fastlane/AuthKey.p8`, which is
git-ignored.
