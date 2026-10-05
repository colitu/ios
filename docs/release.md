# iOS release

The App Store identity is `com.colitu.vpn`; the packet tunnel extension is `com.colitu.vpn.tun`. The current release line is `5.4.1+48` (see `pubspec.yaml`); Codemagic may replace only the build number, which must always increase.

Codemagic builds LibXray from source, generates FFI bindings and archives the app; `flutter analyze` and `flutter test` run in GitHub Actions (`.github/workflows/ci.yml`) and locally. App Store certificates and profiles remain in the CI secret store. The app contains no Firebase, analytics or crash reporting (removed in 5.4.1): App Privacy in App Store Connect is "Data Not Collected" apart from the account e-mail and support messages used for app functionality.

Before TestFlight submission, validate the Runner and tunnel entitlements, inspect the generated privacy report and signed archive, then run login, registration, device registration, VPN connect/disconnect, background reconnect, entitlement expiry and logout on a physical device.
