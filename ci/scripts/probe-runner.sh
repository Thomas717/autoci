#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"

stage probe
if ! is_macos; then
	record probe SKIP ""
	exit 0
fi

if [ ! -d "$DEVELOPER_DIR" ]; then
	ls -d /Applications/Xcode*.app || true
	echo "::error::$XCODE_APP is not on this image; change XCODE_APP in ci/build/pins.env"
	record probe FAIL "Xcode $XCODE_APP missing"
	exit 1
fi

{
	echo "## sw_vers"; sw_vers
	echo "## uname -m"; uname -m
	echo "## locale (bash $BASH_VERSION)"; locale
	echo "## hw.ncpu hw.memsize"; sysctl -n hw.ncpu hw.memsize
	echo "## df -h /"; df -h /
	echo "## xcodebuild -version ($DEVELOPER_DIR)"; xcodebuild -version
	echo "## simctl list runtimes"; xcrun simctl list runtimes
	echo "## simctl list devicetypes (iPhone)"; xcrun simctl list devicetypes | grep -i iphone
	echo "## simctl runtime list"; xcrun simctl runtime list
	echo "## simctl help"; xcrun simctl help
	echo "## tools"
	for t in python3 brew xcbeautify zstd git; do printf '%s: ' "$t"; command -v "$t" || echo missing; done
	brew --prefix openssl@3 2>/dev/null && "$(brew --prefix openssl@3)/bin/openssl" version
} > "$RESULTS/env.txt" 2>&1 || true

XCODE_BUILD=$(xcodebuild -version | awk '/Build version/ { print $3 }')
if [ "$XCODE_BUILD" != "$XCODE_EXPECTED_BUILD" ]; then
	echo "::warning::$XCODE_APP is build $XCODE_BUILD, not $XCODE_EXPECTED_BUILD; the run continues"
fi
gh_env XCODE_BUILD "$XCODE_BUILD"

runtimes_json="$RUNNER_TEMP/runtimes.json"
xcrun simctl list runtimes -j > "$runtimes_json"
if ! python3 -I - "$runtimes_json" "$SIM_IOS_VERSION" "$SIM_DEVICE_TYPE" "${SIM_DEVICE_TYPE_FALLBACK:-}" \
	> "$RUNNER_TEMP/runtime-id.txt" 2> "$RUNNER_TEMP/runtime-pick.txt" <<'PY'
import json, sys

path, want, device_type, fallback = sys.argv[1:5]
prefix = "com.apple.CoreSimulator.SimDeviceType."
wanted = [device_type] + [prefix + t for t in fallback.split(":") if t]
runtimes = []
for r in json.load(open(path)).get("runtimes", []):
    ident = r.get("identifier", "")
    if not ident.startswith("com.apple.CoreSimulator.SimRuntime.iOS-") or not r.get("isAvailable"):
        continue
    version = r.get("version", "")
    types = [t.get("identifier") for t in r.get("supportedDeviceTypes", [])]
    phones = [t[len(prefix):] for t in types if t.startswith(prefix + "iPhone")]
    sys.stderr.write("runtime %s (%s, %s) supports %s\n" % (ident, version, r.get("buildversion", "?"),
                                                           " ".join(phones) or "(no list)"))
    if version != want and not version.startswith(want + "."):
        continue
    key = tuple(int(x) for x in version.split(".") if x.isdigit())
    runtimes.append((key, ident, types))
# The first wanted type that some matching runtime supports (a runtime
# without a list supports any), on the newest such runtime.
for dtype in wanted:
    best = None
    for key, ident, types in runtimes:
        if types and dtype not in types:
            continue
        if best is None or key > best[0]:
            best = (key, ident)
    if best is not None:
        print(best[1], dtype)
        sys.exit(0)
sys.exit(1)
PY
then
	cat "$RUNNER_TEMP/runtime-pick.txt"
	{ echo "## iOS runtimes and their iPhone types (wanted: $SIM_IOS_VERSION)"; cat "$RUNNER_TEMP/runtime-pick.txt"; } >> "$RESULTS/env.txt"
	xcrun simctl list runtimes
	echo "::error::no available iOS $SIM_IOS_VERSION runtime with $SIM_DEVICE_TYPE or a fallback (${SIM_DEVICE_TYPE_FALLBACK:-none}) on this image; change ci/run.env"
	record probe FAIL "iOS $SIM_IOS_VERSION runtime missing for $SIM_DEVICE_TYPE and the fallbacks"
	exit 1
fi
cat "$RUNNER_TEMP/runtime-pick.txt"
{ echo "## iOS runtimes and their iPhone types (wanted: $SIM_IOS_VERSION)"; cat "$RUNNER_TEMP/runtime-pick.txt"; } >> "$RESULTS/env.txt"
read -r SIM_RUNTIME_ID picked < "$RUNNER_TEMP/runtime-id.txt"
gh_env SIM_RUNTIME_ID "$SIM_RUNTIME_ID"
if [ "$picked" != "$SIM_DEVICE_TYPE" ]; then
	echo "::warning::no iOS $SIM_IOS_VERSION runtime supports $SIM_DEVICE_TYPE; taking the fallback $picked"
	device_note=", ${picked#com.apple.CoreSimulator.SimDeviceType.} (ci/run.env's fallback)"
fi
gh_env SIM_DEVICE_TYPE "$picked"

metric xcode "$(xcodebuild -version | head -n 1) ($XCODE_BUILD)"
metric runtime "$SIM_RUNTIME_ID"
metric cpus "$(sysctl -n hw.ncpu)"
metric memory_gb "$(($(sysctl -n hw.memsize) / 1073741824))"
disk_metric start
record probe PASS "Xcode $XCODE_BUILD, $SIM_RUNTIME_ID${device_note:-}"

diag_probe runner || true
