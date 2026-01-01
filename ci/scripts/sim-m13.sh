#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m13"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
device="$SEC/cli-md.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m13" "$out/device-files" "$out/cli-files"
chmod 700 "$out/device-files" "$out/cli-files"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

device_pid=
listen_pid=
stop_bg() {
	local pid=$1
	[ -n "$pid" ] || return 0
	kill -INT "$pid" 2> /dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$pid" 2> /dev/null || return 0
		sleep 1
	done
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	sleep 1
}
finish() {
	load_sampler_stop
	stop_bg "$device_pid"
	stop_bg "$listen_pid"
	for f in md-listen.txt listen.txt send.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m13/$f"
	done
	(since "${m13_start:-0}" 'component=blob' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m13/blob-lines.txt") 2> /dev/null || true
}
trap finish EXIT

fail() {
	record "$1" FAIL "$2"
	exit 1
}

offset() { wc -c < "$SRV/server.log" | tr -d ' '; }
since() {
	(tail -c +"$(($1 + 1))" "$SRV/server.log" 2> /dev/null || true) | grep -F -- "$2" | grep -F -- "${3:-$2}" || true
}
m13_start=$(offset)

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

saved_line() {
	awk -v text="$2" 'index($0, text) { found = 1; next } found && /^file saved: / { print; exit }' "$1" 2> /dev/null
}

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/MediaTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m13-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m13/$1.tail.txt"
	export_attachments "$work/m13-$1.xcresult" "$out/shots" "$RESULTS/m13" m8- > /dev/null 2>&1 || true
	local f
	for f in "$out"/shots/m8-* "$RESULTS"/m13/m8-*; do
		[ -e "$f" ] && mv "$f" "$(dirname "$f")/m13-$(basename "$f" | cut -c4-)"
	done
	return "$status"
}

make_jpeg() {
	python3 -I - "$1.bmp" "$2" <<'PY' || return 1
import struct, sys

path, shade = sys.argv[1], int(sys.argv[2]) & 255
w, h = 640, 480
pad = (4 - w * 3 % 4) % 4
rows = bytearray()
for y in range(h):
    g = y * 255 // h
    for x in range(w):
        rows += bytes((g, shade, x * 255 // w))
    rows += b"\0" * pad
header = b"BM" + struct.pack("<IHHI", 54 + len(rows), 0, 0, 54)
info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(rows), 2835, 2835, 0, 0)
open(path, "wb").write(header + info + rows)
PY
	sips -s format jpeg -s formatOptions 85 "$1.bmp" --out "$1" > /dev/null 2>&1 || return 1
	rm -f "$1.bmp"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m13-listen "no identity of the app in the server log"
[ -s "$device" ] || fail m13-listen "no device profile from milestone 11 ($SEC/cli-md.json)"
nonce=$(test_nonce)
outbound="M13 from iOS $nonce"
inbound="M13 from the CLI $nonce"

stage m13-listen
"$cli" md listen -identity "$device" -save-files "$out/device-files" > "$out/md-listen.txt" 2>&1 3>&- &
device_pid=$!
"$cli" listen -identity "$profile" -save-files "$out/cli-files" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!
if wait_for_text "$out/md-listen.txt" "listening as $app_id" 60 && wait_for_text "$out/listen.txt" "listening as $cli_id" 60; then
	record m13-listen PASS "the CLI's device of $app_id's group and the CLI's identity $cli_id listen"
else
	tail -n 10 "$out/md-listen.txt" "$out/listen.txt"
	fail m13-listen "md listen or listen did not start (m13/md-listen.txt, m13/listen.txt)"
fi

jpg="$RUNNER_TEMP/m13-app.jpg"
if make_jpeg "$jpg" 90; then
	xcrun simctl addmedia "$udid" "$jpg" > /dev/null 2>&1 || true
fi
xcrun simctl privacy "$udid" grant photos "$APP_BUNDLE_ID" > /dev/null 2>&1 || true
load_sampler_start m13-load "$RESULTS/m13/load.txt" 900
stage m13-test-out
o=$(offset)
if TEST_RUNNER_M8_OUTBOUND="$outbound" run_test testSendImageToCLI; then
	record m13-test-out PASS "the app, in its device group, sent a photo with \"$outbound\""
else
	record m13-test-out FAIL "xcodebuild test failed (m13/testSendImageToCLI.tail.txt)"
fi
login=$(since "$o" 'chatserver: client connected' "identity=$app_id" | grep -F 'platform=I' | head -n 1 |
	sed -n 's/^time=\([^ ]*\) .*/\1/p')
load_sampler_stop "$login"
stage m13-mirror-upload
uploads=$(since "$o" 'blob: blob uploaded' "owner=$app_id")
if printf '%s\n' "$uploads" | grep -qF 'mount=mirror'; then
	record m13-mirror-upload PASS "$(printf '%s\n' "$uploads" | grep -F 'mount=mirror' | head -n 1 | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m13-mirror-upload FAIL "no upload of the app's through the blob mirror (m13/blob-lines.txt)"
fi
stage m13-recipient
if wait_for_text "$out/listen.txt" "caption \"$outbound\"" 60 && sleep 5 && line=$(saved_line "$out/listen.txt" "$outbound") && [ -n "$line" ]; then
	record m13-recipient PASS "the CLI's identity: $(printf '%s' "$line" | sed 's|: .*[/\\]|: |' | cut -c1-160)"
else
	record m13-recipient FAIL "the CLI's identity did not save the app's photo (m13/listen.txt)"
fi
stage m13-device-out
if wait_for_text "$out/md-listen.txt" "caption \"$outbound\"" 60 && sleep 5 && line=$(saved_line "$out/md-listen.txt" "$outbound") && [ -n "$line" ]; then
	record m13-device-out PASS "the CLI's device, its own outgoing photo through the mirror: $(printf '%s' "$line" | sed 's|: .*[/\\]|: |' | cut -c1-140)"
else
	grep -F 'threema-cli: file ' "$out/md-listen.txt" | head -n 3
	record m13-device-out FAIL "the CLI's device did not save the app's outgoing photo (m13/md-listen.txt)"
fi
record m13-dones-out INFO "$(since "$o" 'blob: done handled' | sed -n 's/.* path=\([a-z]*\) outcome=\([a-z-]*\).*/\1:\2/p' | sort | uniq -c | tr '\n' ' ')"

stop_bg "$listen_pid"
listen_pid=
stage m13-test-in
o=$(offset)
cli_jpg="$RUNNER_TEMP/m13-cli.jpg"
make_jpeg "$cli_jpg" 30 || cp "$jpg" "$cli_jpg"
if "$cli" send -identity "$profile" -to "$app_id" -file "$cli_jpg" -caption "$inbound" > "$out/send.txt" 2>&1 &&
	TEST_RUNNER_M8_INBOUND="$inbound" run_test testSeeTheCLIImage; then
	record m13-test-in PASS "the app, in its device group, shows the CLI's photo \"$inbound\""
else
	record m13-test-in FAIL "send -file or the test failed (m13/send.txt, m13/testSeeTheCLIImage.tail.txt)"
fi
stage m13-device-in
if wait_for_text "$out/md-listen.txt" "caption \"$inbound\"" 60 && sleep 5 && line=$(saved_line "$out/md-listen.txt" "$inbound") && [ -n "$line" ]; then
	record m13-device-in PASS "the CLI's device, the group's incoming photo through the mirror: $(printf '%s' "$line" | sed 's|: .*[/\\]|: |' | cut -c1-140)"
else
	grep -F 'threema-cli: file ' "$out/md-listen.txt" | head -n 3
	record m13-device-in FAIL "the CLI's device did not save the CLI's photo (m13/md-listen.txt)"
fi
record m13-dones-in INFO "$(since "$o" 'blob: done handled' | sed -n 's/.* path=\([a-z]*\) outcome=\([a-z-]*\).*/\1:\2/p' | sort | uniq -c | tr '\n' ' ')"
shot m13-09-final

failed=$(failing_stages "$M13_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 13: every stage passed"
