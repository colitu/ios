# Changelog

Notable changes to Colitu VPN for iOS. The app is distributed through
TestFlight (<https://testflight.apple.com/join/fnVUd6GQ>); release notes in
Russian, English and Turkish are also at <https://docs.colitu.com/changelog/ios>.

## 5.6.0

- Calls on the Fast connection hold up better: on servers that support it,
  the app changes its UDP port every 30 seconds, so mobile networks that
  slow down one long-lived connection never see one. If the Fast connection
  stalls while the network is fine, the app switches that server to the
  next connection method for 10 minutes.
- When colitu.com cannot be reached, the app finds the Colitu service through
  a signed list of alternative addresses.
- New installations route all traffic through the VPN (privacy mode);
  Russian sites going outside the VPN is an opt-in setting. Existing
  installations keep their current behaviour.
- Signing in from an unusual location can ask for a 6-digit code sent to
  your e-mail.
- Clearer messages when a sign-up is refused: temporary e-mail addresses,
  passwords found in known data breaches, too many sign-ups from one network.

## 5.5.1

- Locations: servers are grouped by country. A country with several servers
  shows one row with the number of locations and the best ping; tap it to
  see its cities. Searching still lists every matching server.
- A more compact server list: about twice as many servers fit on one screen
  and long country names are no longer cut off.
- Servers with YouTube without ads show an "Ad-free YouTube" tag.
- Albania is shown with its country name.

## 5.5.0

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
