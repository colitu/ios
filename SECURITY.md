# Security policy

## Supported versions

Only the latest release of Colitu VPN for iOS receives security fixes. It is
distributed through TestFlight (<https://testflight.apple.com/join/fnVUd6GQ>),
which installs updates automatically; the current version is in
`pubspec.yaml` and under [Tags](../../tags).

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Send the details to **security@colitu.com**. The full disclosure policy is at
<https://colitu.com/security#disclosure>. Please include:

- the affected app version and iOS / iPadOS version,
- steps to reproduce or a proof of concept,
- the impact you expect (what an attacker could do).

What to expect:

- an acknowledgement within 3 working days,
- an assessment and a planned fix date within 10 working days,
- credit in the release notes if you want it.

Please keep the details private until a fixed version is released. We will
not take legal action against research done in good faith that respects user
privacy, does not degrade the service and stays within the scope below.

## Scope

In scope: this repository's code (the Flutter app, the Swift packet tunnel
extension and the build scripts), the app's handling of tokens and VPN
profiles, and its communication with the Colitu API.

Out of scope: denial of service, social engineering, physical attacks, issues
that need a jailbroken device, and problems in third-party components (report
those to the project concerned, e.g. Xray-core, libXray or hev-socks5-tunnel).

The machine-readable contact is at
<https://colitu.com/.well-known/security.txt>. The Colitu Security Whitepaper
(architecture, threat model, logging, known limitations) is at
<https://colitu.com/security>.

## Builds

Release builds are made by Codemagic from `codemagic.yaml` and signed by
Apple's distribution process; iOS only installs builds signed through the App
Store / TestFlight. Every release version is tagged (`vX.Y.Z`) in this
repository. The native core is built from pinned commits that the build
script verifies (see [docs/core-provenance.md](docs/core-provenance.md)).

---

## Сообщить об уязвимости

Пожалуйста, не открывайте публичный issue. Напишите на **security@colitu.com**,
приложив версию, шаги воспроизведения и ожидаемое влияние. Правила раскрытия:
<https://colitu.com/ru/security#disclosure>. Мы ответим в течение 3 рабочих дней и просим не раскрывать детали
до выхода исправленной версии.
