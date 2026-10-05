#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "fetch-libxray.sh is deprecated; building LibXray.xcframework from source."
exec "$ROOT_DIR/scripts/build-libxray.sh" "$@"
