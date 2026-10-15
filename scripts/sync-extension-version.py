#!/usr/bin/env python3
"""Gives the packet-tunnel extension the app's version.

The app reads its version from Flutter's build settings (FLUTTER_BUILD_NAME /
FLUTTER_BUILD_NUMBER in Info.plist), which the extension target does not
include; its MARKETING_VERSION and CURRENT_PROJECT_VERSION were fixed
numbers. App Store Connect expects an extension to carry the same version
and build as its app (ITMS-90473), and crash reports name the extension by
it. Codemagic runs this right before `flutter build ipa` with the same
version and build number.

Usage: sync-extension-version.py <version> <build> [project.pbxproj]
"""

import re
import sys
from pathlib import Path

EXTENSION_BUNDLE_ID = "com.colitu.vpn.tun"
EXPECTED_CONFIGURATIONS = 3  # Debug, Release, Profile


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    version, build = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"\d+(\.\d+){1,2}", version) or not re.fullmatch(r"\d+", build):
        print(f"sync-extension-version: invalid version {version!r} or build {build!r}")
        return 2
    path = Path(sys.argv[3] if len(sys.argv) > 3 else "ios/Runner.xcodeproj/project.pbxproj")
    with path.open(encoding="utf-8", newline="") as f:
        text = f.read()

    # Each build configuration is one "{ isa = XCBuildConfiguration; ... };"
    # block; only the extension's blocks are changed.
    block = re.compile(
        r"(isa = XCBuildConfiguration;\s*buildSettings = \{)(.*?)(\n\t\t\t\};)",
        re.S,
    )
    changed = 0

    def rewrite(match: re.Match) -> str:
        nonlocal changed
        settings = match.group(2)
        if f"PRODUCT_BUNDLE_IDENTIFIER = {EXTENSION_BUNDLE_ID};" not in settings:
            return match.group(0)
        new, n1 = re.subn(r"MARKETING_VERSION = [^;]*;", f"MARKETING_VERSION = {version};", settings)
        new, n2 = re.subn(r"CURRENT_PROJECT_VERSION = [^;]*;", f"CURRENT_PROJECT_VERSION = {build};", new)
        if n1 != 1 or n2 != 1:
            raise SystemExit("sync-extension-version: extension build settings changed; update this script")
        changed += 1
        return match.group(1) + new + match.group(3)

    text = block.sub(rewrite, text)
    if changed != EXPECTED_CONFIGURATIONS:
        print(f"sync-extension-version: found {changed} extension configurations, expected {EXPECTED_CONFIGURATIONS}")
        return 1
    with path.open("w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"sync-extension-version: {EXTENSION_BUNDLE_ID} is {version} ({build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
