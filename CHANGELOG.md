# Changelog

Notable changes to Colitu VPN for iOS. The app is distributed through
TestFlight (<https://testflight.apple.com/join/fnVUd6GQ>); release notes in
Russian, English and Turkish are also at <https://docs.colitu.com/changelog/ios>.

## 5.9.1

- **Split tunneling now applies your site list.** Sites (domains) in the
  list and the "Only selected sites use Colitu" mode were not passed to the
  VPN engine before; only IP addresses and ranges were. From this version the
  saved list works as described. If you chose "only selected sites", every
  site that is not on your list now goes outside the VPN, as that mode
  promises; check the list after updating.
- Xray engine 26.10.10 (with Go 1.27.2 and the latest HTTP/2 fixes).
- "Fast" (Hysteria2) port hopping uses the engine's new setting, so it keeps
  working with the new engine.
- Strict kill switch: the local network goes through the VPN too (printers,
  AirPlay and wireless CarPlay are unreachable while it is on), so a hostile
  Wi-Fi cannot pull traffic outside the VPN as "local".
- The app's data (including the active connection profile) is kept outside
  iCloud and computer backups; the spare server's settings are in the
  Keychain (this device only).
- The app switcher shows the Colitu screen instead of the page; recovery
  codes are hidden while typed; server and city names follow the app
  language.
- No local proxy without a password while connected or while measuring.
- Ad-blocking servers come from your account and can change without an app
  update.
- Usage statistics: the setting now says exactly what is sent (counters and
  connection events with your network's country and provider; the server
  keeps only daily totals, not linked to your account or device).
- Connection reports for support: when you write to support, the full
  connection report (tunnel stops, stability events, error logs) goes with
  the new conversation. Support can also request a connection report for
  your device; the app then sends it without asking. Before any report
  leaves the device, the names and addresses of the sites you visited are
  masked; passwords, keys and tokens are removed.
- Steadier connection (from a long iPhone test): the tunnel checks itself
  through the server's own probe first; it no longer restarts again and
  again while the phone itself has no internet (at most about 75 seconds,
  then it restarts anyway); the app no longer tears down a tunnel that is
  restarting by itself, and an automatic reconnect without network waits
  for the network instead of leaving the VPN off.
- Memory: when the tunnel gets close to iOS's memory limit it keeps fewer
  idle connections open (idle connections close after 3 minutes), so iOS
  is less likely to stop it.
- The app sends its language to Colitu, so notifications and e-mails come
  in that language.
- Clear messages for an account under review, a declined sign-up and a
  blocked account.
- Devices removed on the site or in another app no longer show in the
  device list, and removing one that is already gone no longer fails.

## 5.9.0

- Automatic mode picks the fastest measured server: a manual pick is no longer
  remembered as this network's good server, and a remembered server gives way
  to one at least 40% and 60 ms faster. Own-country servers are pushed back
  only in censoring countries.
- Invite a friend: invite screen with link, share and results; optional
  invite code at sign-up (signups labelled app:ios).
- Usage statistics (on by default, can be turned off): aggregate counters
  and connection events, no IP address or visited site (see 5.9.1 for what
  exactly is sent).
- In-app surveys (at most one in 30 days, can be turned off).

## 5.8.1

- Automatic server choice (Adaptive Connect) never picks a server in Russia:
  a Russian exit carries the same blocks the user wants to get away from.
  A server in Russia can still be chosen by hand.

## 5.8.0

- The Colitu API and its mirrors are reached only over certificates that
  chain to the Let's Encrypt (ISRG) or Google Trust Services roots, so a
  root certificate installed on the device cannot read sign-in or session
  traffic. The check ends on 31 December 2027, so an old app never locks
  itself out.
- Groundwork for Adaptive Connect 3.0 (a start order from other users'
  results on the same network, and a recovery set of servers for when the
  API cannot be reached). It is in the app but switched off in this version.

## 5.7.0

- Adaptive Connect 2.0. "Fastest server" now really is the fastest: the app
  ranks servers by measured ping, puts other countries before your own and
  remembers what worked on each network (home Wi-Fi and mobile data
  separately). Protocols that most users on your network can't use are
  tried last.
- Warm spare: while connected, a second path on another server is kept
  ready. If the main path stops working, traffic moves to it within seconds
  and the VPN stays on. The spare is checked in the background and replaced
  if it stops answering.
- The best two paths are tried at the same time when connecting, and in
  automatic mode the app moves on to the next server when one doesn't work.
  A manually chosen server that fails offers "Try the fastest server".
- The connection is watched on every protocol; the app reconnects by itself
  after an unexpected drop.
- Simple mode and Advanced mode: new installations start in Simple mode;
  one tap shows split tunnelling, protocols and the other settings.
- In-app messages for quota warnings and announcements.

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
