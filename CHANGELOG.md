# Changelog

Notable changes to Colitu VPN for iOS. The app is distributed through
TestFlight (<https://testflight.apple.com/join/fnVUd6GQ>); release notes in
Russian, English and Turkish are also at <https://colitu.com/download/ios>.

## 5.4.2 — next TestFlight build

- Account > Open source links to this repository; Account > Licences lists
  the licences of every bundled component.
- The addresses of the ad-blocking DNS servers are set at build time
  (`COLITU_ADBLOCK_DOH`) instead of in the source; without them the switch is
  hidden.

## 5.4.1 — 2026-10-05

- Firebase Analytics and Crashlytics removed: the app has no analytics,
  advertising or crash-reporting library.
- Security audit fixes.
- Source code published under GPL-3.0.

## 5.4.0

- Optional ad and tracker blocking through Colitu's own DNS servers.
