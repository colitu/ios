# macOS release (direct download)

The macOS app is the same Flutter app as on iOS, shipped like the Windows
installer: a Developer ID signed, notarized DMG from colitu.com, not the Mac
App Store. The packet tunnel runs as a **system extension** (an app
extension only works for App Store apps).

| | |
|---|---|
| App | `com.colitu.vpn.se` (`Colitu.app`) |
| System extension | `com.colitu.vpn.se.tun` (`Contents/Library/SystemExtensions/com.colitu.vpn.se.tun.systemextension`) |
| App Group | `group.com.colitu.vpn.se` (also the extension's `NEMachServiceName`) |
| Apple Team ID | `7C74T7SHR5` |
| Minimum macOS | 13 (Ventura), Apple silicon and Intel |

Code: Xcode project `macos/`, native code `swift/macOS` (app delegate,
window, system extension manager), `swift/macOSSE/AppStart.swift`
(`Constants.useSystemExtension = true`), shared `swift/All`, `swift/App`,
`swift/Tunnel`. `swift/macOSStore` is the unused App Store variant.

The extension runs as root and keeps its files in root's group container.
The app hands it what it needs over provider messages (`swift/All/Model.swift`,
`TunnelRequest`): the dat files and start signal, the rewritten core config of
a warm-spare swap (`writeCoreConfig`), and it copies the extension's run files
(`traffic.json`, `drops.jsonl`, stability log, stderr) into its own container
once a second while connected (`readRunFiles`), where the Flutter side reads
them as on iOS.

## One-time Apple Developer setup (Account Holder)

1. **Identifiers → App Groups**: register `group.com.colitu.vpn.se`.
2. **Identifiers → App IDs**:
   - `com.colitu.vpn.se`: App Groups (`group.com.colitu.vpn.se`),
     Network Extensions, System Extension.
   - `com.colitu.vpn.se.tun`: App Groups (`group.com.colitu.vpn.se`),
     Network Extensions.
3. **Certificates → Developer ID Application** (G2 Sub-CA). Only the Account
   Holder can create it, and the App Store Connect API cannot. Make the CSR
   from the same private key Codemagic signs with (the one in
   `CERTIFICATE_PRIVATE_KEY_B64`), so CI finds the certificate by its key:

   ```bash
   openssl req -new -key certificate_private_key.pem -out colitu-developer-id.csr -subj "/emailAddress=hello@colitu.com/CN=COLITU LIMITED/C=GB"
   ```

   Upload the CSR; nothing needs to be downloaded.
4. Profiles: none by hand. The workflow creates the two Developer ID
   profiles (`fetch-signing-files --type MAC_APP_DIRECT --create`). After a
   capability change, delete the old macOS Developer ID profiles of these two
   IDs so new ones are made.

The workflow stops early with a clear message when a profile lacks the system
extension, network extension or app group entitlement.

## Codemagic

Workflow `colitu-macos-direct` in `codemagic.yaml` (started by hand). It uses
the same `TESTER` group as iOS (`CERTIFICATE_PRIVATE_KEY_B64`,
`CERTIFICATE_KEY_PASSWORD`, `COLITU_ADBLOCK_DOH`, `COLITU_MIRRORS`) and the
`codemagic` App Store Connect key, which also notarizes. Steps:

1. `build-libxray.sh` (all Apple slices; the macOS slice is checked for the
   tunnel's C ABI), FFI bindings, `generate-macos-icons.py`.
2. Developer ID certificate and profiles; the profile UUIDs replace the
   placeholders `"Colitu macOS Direct App"` / `"Colitu macOS Direct Tunnel"`
   in the project; export options for `developer-id`.
3. `flutter build macos --release` (dart defines as on iOS), then
   `xcodebuild archive` + `-exportArchive`, which signs every binary with a
   secure timestamp. Checks: signature, entitlements, the extension's version
   equals the app's (`macos/tunnel/Version.xcconfig`).
4. Notarize and staple the app, zip it; build the DMG (app + Applications
   link), sign, notarize and staple it.

Artifacts: `ColituVPN-<version>-macos.dmg`, `ColituVPN-<version>-macos.zip`,
`SHA256SUMS.txt`. The version is the pubspec version; set
`COLITU_MACOS_VERSION` when starting the build to give the Mac its own line.

## First run on a Mac

1. Open the DMG, drag Colitu to Applications, open it from there (the app
   warns when it runs from anywhere else: macOS installs system extensions
   only for apps in /Applications).
2. First connect: macOS reports the blocked system extension. **System
   Settings → Privacy & Security → Allow** (for "Colitu"), then allow the VPN
   configuration. Connect again.
3. Updates replace the extension automatically when its version changes
   (`SystemExtensionManager`); macOS may ask to allow it again.

## Publishing

Upload the DMG to `colitu.com/downloads/macos/`, add `platforms.macos` to the
portal release manifest (`web/portal/lib/release/release-manifest.json`) with the SHA-256 from `SHA256SUMS.txt`, and link it from the apps
page. The macOS app has no in-app update check yet (the Windows app reads
`/downloads/windows/latest.json`).
