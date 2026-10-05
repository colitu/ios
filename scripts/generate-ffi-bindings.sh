#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f c/include/libXray.h ]]; then
  echo "generate-ffi-bindings: missing c/include/libXray.h" >&2
  exit 1
fi

if command -v dart >/dev/null 2>&1; then
  dart run ffigen
elif command -v flutter >/dev/null 2>&1; then
  flutter pub run ffigen
else
  echo "generate-ffi-bindings: dart/flutter not found; checked-in generated_bindings.dart will be used" >&2
  exit 0
fi

if [[ ! -f lib/core/ffi/generated_bindings.dart ]]; then
  echo "generate-ffi-bindings: ffigen did not create lib/core/ffi/generated_bindings.dart" >&2
  exit 1
fi

for symbol in CGoInvoke CGoFree; do
  if ! grep -q "$symbol" lib/core/ffi/generated_bindings.dart; then
    echo "generate-ffi-bindings: required desktop ABI symbol $symbol is missing" >&2
    exit 1
  fi
done
