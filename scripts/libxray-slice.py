#!/usr/bin/env python3
"""Print the static library path of one LibXray.xcframework slice.

Usage: libxray-slice.py macos|ios [simulator]
"""

import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "swift" / "All" / "LibXray.xcframework"


def main() -> int:
    platform = sys.argv[1] if len(sys.argv) > 1 else "macos"
    variant = sys.argv[2] if len(sys.argv) > 2 else None
    info = plistlib.loads((ROOT / "Info.plist").read_bytes())
    for library in info["AvailableLibraries"]:
        if library["SupportedPlatform"] == platform and library.get("SupportedPlatformVariant") == variant:
            print(ROOT / library["LibraryIdentifier"] / library["LibraryPath"])
            return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
