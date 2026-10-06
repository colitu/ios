# Changelog

Notable changes to Colitu VPN for iOS. The app is distributed through
TestFlight (<https://testflight.apple.com/join/fnVUd6GQ>); release notes in
Russian, English and Turkish are also at <https://docs.colitu.com/changelog/ios>.

## 5.5.0 — next TestFlight build

- Split tunneling (Account > Split tunneling): selected sites and IP ranges
  bypass the VPN, or only they use it. iOS lets only MDM-managed VPN
  profiles choose apps, so the list holds domains and IP addresses.
- "Block internet without VPN" (strict kill switch, off by default): the VPN
  profile captures all traffic (`includeAllNetworks`, `enforceRoutes`) and
  is updated on every connect, so existing installs pick it up.
- IPv6 can no longer leak around the tunnel: with IPv6 off it is routed into
  the tunnel and dropped there, and DNS answers carry no AAAA records.
- Two-step sign-in: accounts with two-step verification (set up on the
  website) enter the authenticator code or a recovery code after the
  password.
- Trial end: a banner three days before the trial ends says which plan
  follows; a device paused because the plan allows fewer devices shows why
  and offers "Use this device instead" or Premium, and never reconnects by
  itself while paused.
- Privacy mode: Russian addresses can be sent through the VPN as well.

### Also in this build (prepared as 5.4.2)

- Account > Open source links to this repository; Account > Licences lists
  the licences of every bundled component.
- The addresses of the ad-blocking DNS servers are set at build time
  (`COLITU_ADBLOCK_DOH`) instead of in the source; without them the switch is
  hidden.

## 5.4.1 — 2026-10-05

- Firebase Analytics and Crashlytics removed: the app has no analytics,
  advertising or crash-reporting library and only talks to the Colitu API.
- Source code published under GPL-3.0.
- Security audit fixes: links (QR codes, messages, websites) can no longer add
  settings; the "Start VPN" home-screen shortcut is gone; Keychain items are
  this-device-only; sign-out removes connection settings, logs and
  diagnostics; the local proxy inbounds need per-start credentials;
  diagnostics mask credentials and e-mail addresses.
- Russian sites go through the VPN when the server is in Russia (outside the
  VPN otherwise), as on Android and Windows.
- A captive portal or error page no longer signs you out; network changes no
  longer restart the tunnel; sign-out can no longer get stuck.

## 5.4.0

- Optional ad and tracker blocking through Colitu's own DNS servers.
