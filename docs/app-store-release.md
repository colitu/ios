# iOS App Store release

The application bundle ID is `com.colitu.vpn`; the Packet Tunnel bundle ID is `com.colitu.vpn.tun`. Codemagic builds LibXray from its pinned commit, runs Flutter and Swift tests, applies manual App Store signing profiles, produces the IPA and publishes to TestFlight only.

Before upload, complete every item in [app-store-checklist.md](app-store-checklist.md) and the shared `docs/release/production-checklist.md` in the `colitu-panel` repository. A final archive privacy-manifest audit and physical-iPhone VPN smoke test are release blockers.
