#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${LIBXRAY_BUILD_DIR:-$ROOT_DIR/.build/libxray-ios}"
LIBXRAY_REPO_URL="${LIBXRAY_REPO_URL:-https://github.com/XTLS/libXray.git}"
# Keep this pinned to a libXray revision that exposes the complete legacy C ABI
# consumed by c/include/libXray.h and the generated Dart FFI bindings. Upstream
# main switched to the CGoInvoke/CGoFree API, which is not ABI-compatible.
LIBXRAY_REF="${LIBXRAY_REF:-9a86646da8d800208188864a820c333f9b6bbe76}"
LIBXRAY_DIR="$WORK_DIR/libXray"
# The packet tunnel turns IP packets into SOCKS5 connections to Xray with
# hev-socks5-tunnel (C, lwIP) instead of Xray's own gVisor TUN stack, which is
# too memory-hungry for the iOS extension. It is linked into libXray.a, so the
# Xcode project needs no extra framework.
HEV_REPO_URL="${HEV_REPO_URL:-https://github.com/heiher/hev-socks5-tunnel.git}"
HEV_REF="${HEV_REF:-2.17.1}"
HEV_COMMIT="${HEV_COMMIT:-9a06bc6e7989da54e3d32ff701ef7a7ce4995d3a}"
HEV_DIR="$WORK_DIR/hev-socks5-tunnel"
HEV_OUT="$WORK_DIR/hev-out"
DEST="$ROOT_DIR/swift/All/LibXray.xcframework"

die() {
  echo "build-libxray: $*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  echo "build-libxray: failed in directory: $(pwd)" >&2
  echo "build-libxray: exit code: $exit_code" >&2
  exit "$exit_code"
}

trap on_error ERR

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

[[ "$(uname -s)" == "Darwin" ]] || die "LibXray iOS build must run on macOS. Do not run this script on Linux."
need_cmd git
need_cmd python3
need_cmd xcodebuild
need_cmd nm
need_cmd make
need_cmd lipo
need_cmd libtool
need_cmd xcrun

echo "build-libxray: cleaning $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "build-libxray: fetching $LIBXRAY_REPO_URL ($LIBXRAY_REF)"
git init -q "$LIBXRAY_DIR"
git -C "$LIBXRAY_DIR" remote add origin "$LIBXRAY_REPO_URL"
git -C "$LIBXRAY_DIR" fetch --depth 1 origin "$LIBXRAY_REF"
git -C "$LIBXRAY_DIR" checkout -q --detach FETCH_HEAD
echo "build-libxray: resolved revision $(git -C "$LIBXRAY_DIR" rev-parse HEAD)"

# The pinned libXray revision exposes GetXrayState to Go callers but omits it
# from the generated C bridge. The packet-tunnel extension needs the real core
# state; treating RunXray's successful (and immediate) return as a process exit
# causes false disconnect and recovery decisions.
python3 - "$LIBXRAY_DIR/build/template/main.gotemplate" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = "//export CGoSetTunFd\nfunc CGoSetTunFd(fd C.int) {\n\tSetTunFd(int32(fd))\n}\n"
addition = needle + "\n//export CGoGetXrayState\nfunc CGoGetXrayState() C.int {\n\tif GetXrayState() {\n\t\treturn 1\n\t}\n\treturn 0\n}\n"
if "func CGoGetXrayState()" not in text:
    if needle not in text:
        raise SystemExit("libXray C bridge template changed; cannot add CGoGetXrayState")
    text = text.replace(needle, addition)

# The packet-tunnel extension has a hard memory cap (about 50 MB on iOS); iOS
# kills it without notice when the Go heap grows past it. Expose a soft limit
# and a way to hand freed pages back to the OS.
memory_exports = """
//export CGoSetMemoryLimit
func CGoSetMemoryLimit(limitBytes C.longlong, gcPercent C.int) {
	if gcPercent > 0 {
		colitudebug.SetGCPercent(int(gcPercent))
	}
	if limitBytes > 0 {
		colitudebug.SetMemoryLimit(int64(limitBytes))
	}
}

//export CGoFreeOSMemory
func CGoFreeOSMemory() {
	colitudebug.FreeOSMemory()
}

//export CGoSetMaxProcs
func CGoSetMaxProcs(n C.int) {
	if n > 0 {
		colituruntime.GOMAXPROCS(int(n))
	}
}

//export CGoResetHysteria
func CGoResetHysteria() {
	colituhysteria.ResetClients()
}

//export CGoGoSysBytes
func CGoGoSysBytes() C.longlong {
	var stats colituruntime.MemStats
	colituruntime.ReadMemStats(&stats)
	return C.longlong(stats.Sys - stats.HeapReleased)
}

// Fills out[0..8) with HeapAlloc, HeapInuse, HeapIdle, HeapReleased,
// StackInuse, Sys, NumGC and the goroutine count so the tunnel can log
// where the Go memory is and roughly how many connections are open.
//export CGoGoMemStats
func CGoGoMemStats(out *C.longlong) {
	var stats colituruntime.MemStats
	colituruntime.ReadMemStats(&stats)
	values := [8]uint64{stats.HeapAlloc, stats.HeapInuse, stats.HeapIdle, stats.HeapReleased, stats.StackInuse, stats.Sys, uint64(stats.NumGC), uint64(colituruntime.NumGoroutine())}
	slice := (*[8]C.longlong)(unsafe.Pointer(out))
	for i, v := range values {
		slice[i] = C.longlong(v)
	}
}
"""
if "func CGoSetMemoryLimit(" not in text:
    if 'import "C"\n' not in text:
        raise SystemExit("libXray C bridge template changed; cannot add memory exports")
    text = text.replace(
        'import "C"\n',
        'import "C"\n\nimport (\n\tcolituruntime "runtime"\n\tcolitudebug "runtime/debug"\n\t"unsafe"\n\n\tcolituhysteria "github.com/xtls/xray-core/transport/internet/hysteria"\n)\n',
        1,
    )
    text = text.rstrip("\n") + "\n" + memory_exports
path.write_text(text)
PY

pushd "$LIBXRAY_DIR" >/dev/null

# Xray's Hysteria2 dialer caches its QUIC clients in a package-level map
# that outlives the core instance: libXray starts every new core in the same
# process, so a restarted core reused the previous core's QUIC connection.
# After a device sleep that connection is dead but still looks active (Go's
# monotonic clock stops while iOS sleeps, so quic-go's idle timeout has not
# run while the server's has), and every new stream waited on it for about
# 30 s. Build against a copy of the pinned xray-core with ResetClients(),
# which the packet tunnel calls on every core stop and after a sleep.
need_cmd go
XRAY_MODULE="github.com/xtls/xray-core"
go mod download "$XRAY_MODULE"
XRAY_SRC="$(go list -m -f '{{.Dir}}' "$XRAY_MODULE")"
[[ -n "$XRAY_SRC" && -d "$XRAY_SRC" ]] || die "could not locate $XRAY_MODULE in the module cache"
XRAY_PATCHED="$WORK_DIR/xray-core"
rm -rf "$XRAY_PATCHED"
cp -R "$XRAY_SRC" "$XRAY_PATCHED"
chmod -R u+w "$XRAY_PATCHED"
python3 - "$XRAY_PATCHED/transport/internet/hysteria/dialer.go" <<'HYSTERIA'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
anchor = "var manger *clientManager\n"
if anchor not in text or "func (c *client) close()" not in text or "closeErrCodeOK" not in text:
    raise SystemExit("xray-core hysteria dialer changed; cannot add ResetClients")
reset = anchor + """
// ResetClients drops every cached QUIC client (Colitu patch). New dials
// start a fresh connection at once; the old ones are closed in the
// background, since one of them may be in the middle of a handshake.
func ResetClients() {
	manger.mutex.Lock()
	old := manger.m
	manger.m = make(map[string]*client)
	manger.mutex.Unlock()
	for _, c := range old {
		go func(c *client) {
			c.mutex.Lock()
			defer c.mutex.Unlock()
			if c.conn != nil {
				_ = c.conn.CloseWithError(closeErrCodeOK, "")
			}
			if c.pktConn != nil {
				_ = c.pktConn.Close()
			}
			c.conn = nil
			c.pktConn = nil
			c.udpSM = nil
		}(c)
	}
}
"""
text = text.replace(anchor, reset, 1)
path.write_text(text)
HYSTERIA
# libXray's build deletes go.mod and runs "go mod init" + "go mod tidy"
# before compiling (build/app/build.py, init_go_env), which drops any replace
# made here and resolves xray-core afresh. Re-apply the replace inside that
# step, right after its tidy, and fail if the hook can no longer be placed.
export COLITU_XRAY_REPLACE="$XRAY_MODULE=$XRAY_PATCHED"
python3 - "$LIBXRAY_DIR/build/app/build.py" <<'GOENV'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
start_marker = "    def init_go_env(self):\n"
end_marker = "    def download_geo(self):\n"
hook = (
    "        colitu_replace = os.environ.get(\"COLITU_XRAY_REPLACE\")\n"
    "        if colitu_replace:\n"
    "            if subprocess.run([\"go\", \"mod\", \"edit\", \"-replace\", colitu_replace]).returncode != 0:\n"
    "                raise Exception(\"colitu: go mod edit -replace failed\")\n"
    "            if subprocess.run([\"go\", \"mod\", \"tidy\"]).returncode != 0:\n"
    "                raise Exception(\"colitu: go mod tidy after replace failed\")\n"
    "\n"
)
if "COLITU_XRAY_REPLACE" not in text:
    head, sep, tail = text.partition(start_marker)
    if not sep or end_marker not in tail:
        raise SystemExit("libXray build.py changed; cannot re-apply the xray-core replace")
    body, sep2, rest = tail.partition(end_marker)
    text = head + sep + body.rstrip("\n") + "\n\n" + hook + sep2 + rest
    for needed in ("import os", "import subprocess"):
        if needed not in text:
            raise SystemExit(f"libXray build.py no longer has {needed}")
path.write_text(text)
GOENV
echo "build-libxray: $XRAY_MODULE will be replaced by $XRAY_PATCHED (resettable Hysteria2 client cache)"

echo "build-libxray: running official build: python3 build/main.py apple go"
python3 build/main.py apple go

popd >/dev/null

FOUND_FRAMEWORK="$(find "$LIBXRAY_DIR" -name "LibXray.xcframework" -type d -print -quit)"
if [[ -z "$FOUND_FRAMEWORK" ]]; then
  die "official libXray build completed but LibXray.xcframework was not found"
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$FOUND_FRAMEWORK" "$DEST"

if [[ ! -d "$DEST" ]]; then
  die "failed to copy LibXray.xcframework to $DEST"
fi

echo "build-libxray: fetching $HEV_REPO_URL ($HEV_REF)"
git clone -q --depth 1 --branch "$HEV_REF" --recursive --shallow-submodules "$HEV_REPO_URL" "$HEV_DIR"
HEV_RESOLVED="$(git -C "$HEV_DIR" rev-parse HEAD)"
[[ "$HEV_RESOLVED" == "$HEV_COMMIT" ]] || die "hev-socks5-tunnel $HEV_REF resolved to $HEV_RESOLVED, expected $HEV_COMMIT"
echo "build-libxray: hev-socks5-tunnel revision $HEV_RESOLVED"

# Builds hev-socks5-tunnel and its bundled libraries for one SDK/arch into a
# single static archive (the same steps as upstream build-apple.sh).
build_hev() {
  local sdk="$1" arch="$2" min_version="$3"
  local out="$HEV_OUT/$sdk-$arch/libhev-socks5-tunnel.a"
  [[ -f "$out" ]] && return 0
  echo "build-libxray: building hev-socks5-tunnel for $sdk $arch"
  local flags="-arch $arch -m$sdk-version-min=$min_version"
  make -C "$HEV_DIR" clean >/dev/null
  make -C "$HEV_DIR" \
    PP="xcrun --sdk $sdk --toolchain $sdk clang" \
    CC="xcrun --sdk $sdk --toolchain $sdk clang" \
    CFLAGS="$flags" \
    LFLAGS="$flags -Wl,-Bsymbolic-functions" \
    static
  mkdir -p "$(dirname "$out")"
  libtool -static -o "$out" \
    "$HEV_DIR/bin/libhev-socks5-tunnel.a" \
    "$HEV_DIR/third-part/lwip/bin/liblwip.a" \
    "$HEV_DIR/third-part/yaml/bin/libyaml.a" \
    "$HEV_DIR/third-part/hev-task-system/bin/libhev-task-system.a"
}

# Every slice of the xcframework gets hev linked into its libXray.a, one
# architecture at a time, so all platforms keep resolving the same symbols.
python3 - "$DEST/Info.plist" > "$WORK_DIR/slices.tsv" <<'SLICES'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
for library in info["AvailableLibraries"]:
    print("\t".join([
        library["LibraryIdentifier"],
        library["LibraryPath"],
        library["SupportedPlatform"],
        # Never an empty field: tab is IFS whitespace, so read would merge
        # two tabs and shift the architectures into the variant.
        library.get("SupportedPlatformVariant") or "device",
        " ".join(library["SupportedArchitectures"]),
    ]))
SLICES

while IFS=$'\t' read -r identifier library_path platform variant archs; do
  case "$platform/$variant" in
    ios/device) sdk=iphoneos; min_version=15.0 ;;
    ios/simulator) sdk=iphonesimulator; min_version=15.0 ;;
    macos/device) sdk=macosx; min_version=10.14 ;;
    tvos/device) sdk=appletvos; min_version=17.0 ;;
    tvos/simulator) sdk=appletvsimulator; min_version=17.0 ;;
    *) die "unexpected LibXray slice $identifier ($platform/$variant)" ;;
  esac
  slice_library="$DEST/$identifier/$library_path"
  [[ -f "$slice_library" ]] || die "missing $slice_library"
  merge_dir="$WORK_DIR/merge/$identifier"
  rm -rf "$merge_dir"
  mkdir -p "$merge_dir"
  merged=()
  for arch in $archs; do
    build_hev "$sdk" "$arch" "$min_version"
    if [[ "$(lipo -archs "$slice_library")" == "$arch" ]]; then
      cp "$slice_library" "$merge_dir/xray-$arch.a"
    else
      lipo "$slice_library" -thin "$arch" -output "$merge_dir/xray-$arch.a"
    fi
    libtool -static -o "$merge_dir/merged-$arch.a" \
      "$merge_dir/xray-$arch.a" \
      "$HEV_OUT/$sdk-$arch/libhev-socks5-tunnel.a"
    merged+=("$merge_dir/merged-$arch.a")
  done
  if [[ ${#merged[@]} -eq 1 ]]; then
    cp "${merged[0]}" "$slice_library"
  else
    lipo -create "${merged[@]}" -output "$slice_library"
  fi
  echo "build-libxray: linked hev-socks5-tunnel into $identifier ($archs)"
done < "$WORK_DIR/slices.tsv"

DEVICE_LIBRARY="$(find "$DEST" -type f -path '*ios-arm64*' -name 'libXray.a' -print -quit)"
if [[ -z "$DEVICE_LIBRARY" ]]; then
  die "iOS arm64 static library was not found in $DEST"
fi

EXPECTED_SYMBOLS=(
  hev_socks5_tunnel_main_from_str
  hev_socks5_tunnel_quit
  hev_socks5_tunnel_stats
  CGoSetTunFd
  CGoGetXrayState
  CGoSetMemoryLimit
  CGoFreeOSMemory
  CGoSetMaxProcs
  CGoGoSysBytes
  CGoResetHysteria
  CGoGoMemStats
  CGoInitDns
  CGoResetDns
  CGoRunXrayFromJSON
  CGoGetFreePorts
  CGoConvertShareLinksToXrayJson
  CGOConvertXrayJsonToShareLinks
  CGoCountGeoData
  CGoReadGeoFiles
  CGoPing
  CGoQueryStats
  CGoTestXray
  CGoRunXray
  CGoStopXray
  CGoXrayVersion
)

SYMBOL_TABLE="$(nm -g "$DEVICE_LIBRARY")"
for symbol in "${EXPECTED_SYMBOLS[@]}"; do
  if ! grep -Eq "[[:space:]]_?${symbol}$" <<<"$SYMBOL_TABLE"; then
    die "required C ABI symbol $symbol is missing from $DEVICE_LIBRARY (ref $LIBXRAY_REF)"
  fi
done

echo "build-libxray: verified ${#EXPECTED_SYMBOLS[@]} required C ABI symbols"
echo "build-libxray: copied $FOUND_FRAMEWORK to $DEST (with hev-socks5-tunnel $HEV_REF)"
