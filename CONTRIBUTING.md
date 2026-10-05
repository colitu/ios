# Contributing to Colitu VPN for iOS

Thanks for helping. Bug reports, translation fixes and focused pull requests
are welcome.

## Before you start

- **Security problems:** do not open an issue; follow [SECURITY.md](SECURITY.md).
- **Account, payment or connection problems:** these are handled by support at
  <https://colitu.com/support>, not in this repository.
- For larger changes, open an issue first so we can agree on the approach.

## Building

```
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

`flutter analyze` and `flutter test` also work on Linux and Windows. Building
the app itself needs macOS (Xcode, Go, Python 3) and the native core from
`scripts/build-libxray.sh`; see the README and [docs/build.md](docs/build.md).

The Colitu screens have golden screenshot tests. After an intended visual
change, update them with
`flutter test test/colitu_screens_test.dart --update-goldens` and include the
new images in the pull request.

## Pull requests

- Keep each pull request to one change, and describe what it fixes and how you
  tested it (simulator or device, iOS version).
- Follow the style of the surrounding code; do not reformat unrelated files.
- Add or update tests for behaviour changes.
- Do not commit secrets, signing material (`*.p8`, `*.p12`, provisioning
  profiles), `.env` files or personal configuration.
- The app speaks Russian, English and Turkish; a new user-facing string needs
  all three (`lib/colitu/l10n/colitu_loc.dart`).
- CI (analysis, simulator build and tests) must pass.

## Licence and trademarks

The code is licensed under GPL-3.0; by contributing you agree that your
contribution is published under the same licence. The Colitu name and logo
are not covered by the GPL: if you publish your own build, use your own name
and logo.

## Code of conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
