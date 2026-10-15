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

# COLITU_LIBXRAY_CHECK=1 runs every step that does not need a Mac on any
# system (Windows, Linux): fetch, patches, pins, libXray's go.mod setup, a
# darwin/arm64 build of every libXray package, libXray's go.mod revert and
# govulncheck. No framework is produced. It checks this script without a Mac.
CHECK_ONLY="${COLITU_LIBXRAY_CHECK:-}"
PYTHON="${PYTHON:-python3}"
# govulncheck on the pinned module graph after the build (reported, never
# fatal); COLITU_GOVULNCHECK=0 skips it.
GOVULNCHECK_VERSION="${GOVULNCHECK_VERSION:-v1.8.0}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_cmd git
need_cmd "$PYTHON"
if [[ -z "$CHECK_ONLY" ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || die "LibXray iOS build must run on macOS (COLITU_LIBXRAY_CHECK=1 checks the steps before the Apple ones)."
  need_cmd xcodebuild
  need_cmd nm
  need_cmd make
  need_cmd lipo
  need_cmd libtool
  need_cmd xcrun
fi

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
"$PYTHON" - "$LIBXRAY_DIR/build/template/main.gotemplate" <<'PY'
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
// Writes the goroutine profile grouped by identical stacks, largest group
// first (pprof debug=1: counts and function names), into buf, at most n
// bytes; returns the bytes written. The tunnel saves it when the memory
// runs out so a diagnostics report shows which code holds the goroutines.
//export CGoGoroutineProfile
func CGoGoroutineProfile(buf *C.char, n C.int) C.int {
	var out colitubytes.Buffer
	if colitupprof.Lookup("goroutine").WriteTo(&out, 1) != nil || n <= 0 {
		return 0
	}
	data := out.Bytes()
	if len(data) > int(n) {
		data = data[:int(n)]
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(n)), data)
	return C.int(len(data))
}

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
        'import "C"\n\nimport (\n\tcolitubytes "bytes"\n\tcolituruntime "runtime"\n\tcolitudebug "runtime/debug"\n\tcolitupprof "runtime/pprof"\n\t"unsafe"\n\n\tcolituhysteria "github.com/xtls/xray-core/transport/internet/hysteria"\n)\n',
        1,
    )
    text = text.rstrip("\n") + "\n" + memory_exports
path.write_text(text)
PY

# The pinned libXray revision was written against Xray-core 26.3; a few
# Xray APIs it uses moved by 26.10 (geo lists, the MPH cache, Shadowsocks
# UDP-over-TCP, Hysteria2 port hopping in share links). Adapt those spots;
# the C bridge the app calls is unchanged. Checked on 2026-10-13: every
# libXray package builds for darwin/arm64 against the patched core.
"$PYTHON" - "$LIBXRAY_DIR" <<'COMPAT'
# Makes the pinned libXray revision build against Xray-core 26.10.10.
from pathlib import Path
import sys

root = Path(sys.argv[1])

def patch(rel, pairs):
    path = root / rel
    text = path.read_text()
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"libXray {rel} changed; cannot apply the Xray 26.10 compatibility patch")
        text = text.replace(old, new, 1)
    path.write_text(text)

# Geo lists moved from app/router to common/geodata.
patch("geo/count.go", [
    ('"github.com/xtls/xray-core/app/router"', 'router "github.com/xtls/xray-core/common/geodata"'),
])
# The MPH matcher cache is gone from Xray-core: the path is ignored.
patch("xray/xray.go", [
    ("\tif mphCachePath != \"\" {\n\t\tos.Setenv(platform.MphCachePath, mphCachePath)\n\t}\n", "\t_ = mphCachePath // Xray-core 26.10 has no MPH cache\n"),
    ("\tif err := config.BuildMPHCache(&mphCachePath); err != nil {\n\t\tbase.Fatalf(\"failed to build MPH cache: %v\", err)\n\t\treturn err\n\t}\n\treturn nil\n",
     "\t_ = config\n\treturn errors.New(\"MPH cache is not supported by Xray-core 26.10\")\n"),
])
# Shadowsocks UDP-over-TCP left the client config.
patch("share/clash_meta.go", [
    ("\tsettings.UoT = proxy.UdpOverTcp\n", ""),
])
# Port hopping moved from quicParams.udpHop to the "udphop" UDP mask. Share
# links (not used by the Colitu app) keep bandwidth and Salamander only.
patch("share/generate_share.go", [
    ("""			if qp.UdpHop.PortList != nil {
				var portList string
				if json.Unmarshal(qp.UdpHop.PortList, &portList) == nil && len(portList) > 0 {
					query = addQuery(query, "ports", portList)
				}
			}
			if qp.UdpHop.Interval != nil {
				query = addQuery(query, "hop-interval", strconv.FormatInt(int64(qp.UdpHop.Interval.From), 10))
			}
""", ""),
])
patch("share/hysteria_mask.go", [
    ("""		if ports != "" {
			udpHop := conf.UdpHop{}
			portListJSON, err := json.Marshal(ports)
			if err != nil {
				return nil, err
			}
			udpHop.PortList = portListJSON
			if hopInterval != nil {
				i := *hopInterval
				udpHop.Interval = &conf.Int32Range{Left: i, Right: i, From: i, To: i}
			}
			quicParams.UdpHop = udpHop
		}
""", "\t\t_ = hopInterval\n"),
])

def replace_all(rel, old, new):
    path = root / rel
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"libXray {rel} changed; cannot apply the Xray 26.10 compatibility patch")
    path.write_text(text.replace(old, new))

replace_all("geo/count.go", ".CountryCode", ".Code")
patch("xray/xray.go", [('import (\n\t"os"\n', 'import (\n\t"errors"\n\t"os"\n')])
patch("share/generate_share.go", [('\t"strconv"\n', "")])
patch("share/hysteria_mask.go", [('\t"encoding/json"\n', "")])
COMPAT

# Known Go vulnerabilities reachable from the core as built (pinned graph:
# patched Xray, x/net, Go standard library), for darwin/arm64. Reported, not
# fatal: an upstream finding without a fixed version must not stop a build.
run_govulncheck() {
  if [[ "${COLITU_GOVULNCHECK:-1}" == "0" ]]; then
    return 0
  fi
  echo "build-libxray: govulncheck $GOVULNCHECK_VERSION on $(go list -m github.com/xtls/xray-core 2>/dev/null)"
  # Built for this machine, run against the darwin/arm64 build context.
  local bin="$WORK_DIR/bin"
  if ! GOBIN="$bin" go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"; then
    echo "build-libxray: WARNING: govulncheck could not be installed"
    return 0
  fi
  if ! GOOS=darwin GOARCH=arm64 "$bin/govulncheck" ./...; then
    echo "build-libxray: WARNING: govulncheck reported findings or could not run (see above)"
  fi
}

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
# The Go toolchain and the core version are pinned, so every build ships the
# same, known core (Go's standard library carries the TLS, HTTP and DNS code
# the core relies on). Xray-core v26.10.10 (2026-10-10, the version the
# Android and Windows apps ship) is tagged without a Go module version, so
# it is pinned by its commit as a pseudo-version (= tag v26.10.10, commit
# 701af60772cd). Override both only on purpose.
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.27.2}"
XRAY_MODULE="github.com/xtls/xray-core"
XRAY_VERSION="${XRAY_VERSION:-v1.260327.1-0.20261010092107-701af60772cd}"
# golang.org/x/net v0.60.0 fixes the HTTP/2 issues of 2026-10-08
# (GO-2026-6603/6610/6611/6612/6617); Xray 26.10.10 itself requires 0.59.0.
XNET_VERSION="${XNET_VERSION:-v0.60.0}"
echo "build-libxray: go toolchain $(go env GOVERSION), $XRAY_MODULE $XRAY_VERSION"
XRAY_SRC="$(go mod download -json "$XRAY_MODULE@$XRAY_VERSION" | "$PYTHON" -c 'import json, sys; print(json.load(sys.stdin).get("Dir", ""))')"
[[ -n "$XRAY_SRC" && -d "$XRAY_SRC" ]] || die "could not download $XRAY_MODULE@$XRAY_VERSION"
XRAY_PATCHED="$WORK_DIR/xray-core"
rm -rf "$XRAY_PATCHED"
cp -R "$XRAY_SRC" "$XRAY_PATCHED"
chmod -R u+w "$XRAY_PATCHED"
"$PYTHON" - "$XRAY_PATCHED/transport/internet/hysteria/dialer.go" <<'HYSTERIA'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
# Xray 26.10 keys the clients by destination and stream settings and has a
# "forced" close; ResetClients uses the dialer's own clean(force).
anchor = "var (\n\tmanager     *clientManager\n\tinitmanager sync.Once\n)\n"
if anchor not in text or "func (c *client) clean(force bool)" not in text or "func (m *clientManager) clean()" not in text:
    raise SystemExit("xray-core hysteria dialer changed; cannot add ResetClients")
reset = anchor + """
// ResetClients drops every cached QUIC client (Colitu patch). New dials
// start a fresh connection at once; the old ones are closed in the
// background, since one of them may be in the middle of a handshake.
func ResetClients() {
	initmanager.Do(func() {
		manager = &clientManager{
			m: make(map[dialerConf]*client),
		}
		go manager.clean()
	})
	manager.Lock()
	old := manager.m
	manager.m = make(map[dialerConf]*client)
	manager.Unlock()
	for _, c := range old {
		go c.clean(true)
	}
}
"""
text = text.replace(anchor, reset, 1)
path.write_text(text)
HYSTERIA
# libXray's build deletes go.mod and runs "go mod init" + "go mod tidy"
# before compiling (build/app/build.py, init_go_env), which drops any replace
# made here. Re-apply the replace and the x/net requirement right after its
# "go mod init" (its tidy then resolves against them), check the result
# after the tidy, and fail if the hook can no longer be placed.
export COLITU_XRAY_REPLACE="$XRAY_MODULE=$XRAY_PATCHED"
export COLITU_XNET_VERSION="$XNET_VERSION"
"$PYTHON" - "$LIBXRAY_DIR/build/app/build.py" <<'GOENV'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
after_init = '            raise Exception("go mod init failed")\n'
after_tidy = '            raise Exception("go mod tidy failed")\n'
pin = '''
        colitu_replace = os.environ.get("COLITU_XRAY_REPLACE")
        colitu_xnet = os.environ.get("COLITU_XNET_VERSION")
        if colitu_replace:
            if subprocess.run(["go", "mod", "edit", "-replace", colitu_replace]).returncode != 0:
                raise Exception("colitu: go mod edit -replace failed")
        if colitu_xnet:
            if subprocess.run(["go", "mod", "edit", "-require", "golang.org/x/net@" + colitu_xnet]).returncode != 0:
                raise Exception("colitu: go mod edit -require x/net failed")
'''
check = '''
        if colitu_xnet:
            got = subprocess.run(["go", "list", "-m", "-f", "{{.Version}}", "golang.org/x/net"], capture_output=True, text=True).stdout.strip()
            if got != colitu_xnet:
                raise Exception("colitu: golang.org/x/net is " + got + ", expected " + colitu_xnet)
'''
revert_marker = "    def revert_go_env(self):\n"
start_marker = "    def init_go_env(self):\n"
end_marker = "    def download_geo(self):\n"
if "COLITU_XRAY_REPLACE" not in text:
    head, sep, tail = text.partition(start_marker)
    body, sep2, rest = tail.partition(end_marker)
    if not sep or not sep2 or body.count(after_init) != 1 or body.count(after_tidy) != 1:
        raise SystemExit("libXray build.py changed; cannot re-apply the xray-core replace")
    body = body.replace(after_init, after_init + pin, 1)
    body = body.replace(after_tidy, after_tidy + check, 1)
    text = head + sep + body + sep2 + rest
    # After the framework libXray rebuilds go.mod once more ("revert"),
    # without the replace and pins: the patched sources import packages the
    # unpatched latest xray-core lacks, so that tidy fails the build. The
    # work directory is deleted before every build, so there is nothing to
    # revert: the step is skipped and go.mod keeps the pinned graph (which
    # govulncheck then reads).
    if text.count(revert_marker) != 1:
        raise SystemExit("libXray build.py changed; cannot skip revert_go_env")
    text = text.replace(
        revert_marker,
        revert_marker + "        return  # Colitu: keep the pinned go.mod (see build-libxray.sh)\n",
        1,
    )
    for needed in ("import os", "import subprocess"):
        if needed not in text:
            raise SystemExit(f"libXray build.py no longer has {needed}")
path.write_text(text)
GOENV
echo "build-libxray: $XRAY_MODULE will be replaced by $XRAY_PATCHED (resettable Hysteria2 client cache)"

if [[ -n "$CHECK_ONLY" ]]; then
  # The Apple build without the Apple toolchain: libXray's own go.mod setup
  # (with the pins above), every package for darwin/arm64 (cgo off; the C
  # bridge needs Xcode), then libXray's revert step, exactly as main.py runs
  # them around the cgo builds.
  "$PYTHON" - <<'CHECK'
import os
import subprocess
import sys

build_dir = os.path.abspath("build")
sys.path.insert(0, build_dir)
from app.apple_go import AppleGoBuilder

builder = AppleGoBuilder(build_dir)
builder.init_go_env()
env = dict(os.environ, GOOS="darwin", GOARCH="arm64", CGO_ENABLED="0")
subprocess.run(["go", "build", "./..."], env=env, check=True)
builder.revert_go_env()
print("build-libxray: check: every libXray package builds for darwin/arm64")
CHECK
  run_govulncheck
  popd >/dev/null
  echo "build-libxray: check finished (no framework is built without a Mac)"
  exit 0
fi

echo "build-libxray: running official build: $PYTHON build/main.py apple go"
"$PYTHON" build/main.py apple go
run_govulncheck

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
"$PYTHON" - "$DEST/Info.plist" > "$WORK_DIR/slices.tsv" <<'SLICES'
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
  CGoGoroutineProfile
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
