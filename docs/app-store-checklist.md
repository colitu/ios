# App Store submission

## Identity and artifact

- App bundle ID: `com.colitu.vpn`
- Packet Tunnel bundle ID: `com.colitu.vpn.tun`
- Upload only the Codemagic archive produced with the protected App Store Connect integration.
- Retain the IPA checksum, source tag, LibXray commit and framework checksum.

## Listing and review

- Use the Turkish copy in [store-listing.md](store-listing.md).
- Supply current iPhone/iPad screenshots from the release build.
- Complete App Privacy from observed archive behavior and SDK manifests.
- Explain Network Extension use and provide a reviewer account/test steps.
- Verify subscription purchase language reflects the hosted Platega flow and current App Store policy before submission.

## Release gate

TestFlight physical-device login, permission, tunnel connect, egress, DNS, reconnect and revoke tests must pass. Validate both privacy manifests in the final archive (the app has no analytics or crash reporting).
