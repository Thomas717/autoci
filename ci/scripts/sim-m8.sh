#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m8"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
saved="$out/saved"
mkdir -p "$out/shots" "$RESULTS/m8" "$saved"
chmod 700 "$saved"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

listen_pid=
finish() {
	if [ -n "$listen_pid" ]; then
		kill -INT "$listen_pid" 2> /dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$listen_pid" 2> /dev/null || break
			sleep 1
		done
		kill -KILL "$listen_pid" 2> /dev/null
		listen_pid=
	fi
	for f in send.txt listen.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m8/$f"
	done
	(since "${m8_start:-0}" 'component=blob' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m8/blob-lines.txt") 2> /dev/null || true
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
m8_start=$(offset)

wait_since() {
	local off=$1 end=$(($(date +%s) + $2)) count=$3 lines
	shift 3
	while :; do
		lines=$(since "$off" "$@")
		if [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ge "$count" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && { [ -n "$lines" ] && printf '%s\n' "$lines"; return 1; }
		sleep 2
	done
}

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

refs_of() { sed -n 's/.* blob_ref=\([^ ]*\).*/\1/p'; }

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/MediaTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m8/$1.tail.txt"
	export_attachments "$work/$1.xcresult" "$out/shots" "$RESULTS/m8" m8- > /dev/null 2>&1 || true
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
        rows += bytes((shade, g, x * 255 // w))
    rows += b"\0" * pad
header = b"BM" + struct.pack("<IHHI", 54 + len(rows), 0, 0, 54)
info = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(rows), 2835, 2835, 0, 0)
open(path, "wb").write(header + info + rows)
PY
	sips -s format jpeg -s formatOptions 85 "$1.bmp" --out "$1" > /dev/null 2>&1 || return 1
	rm -f "$1.bmp"
	is_jpeg "$1"
}

is_jpeg() { python3 -I -c 'import sys; sys.exit(0 if open(sys.argv[1], "rb").read(3) == bytes((255, 216, 255)) else 1)' "$1"; }

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m8-photos "no identity of the app in the server log"
nonce=$(test_nonce)
inbound="M8 from the CLI $nonce"
outbound="M8 from iOS $nonce"

stage m8-photos
cli_jpg="$RUNNER_TEMP/m8-cli.jpg"
app_jpg="$RUNNER_TEMP/m8-app.jpg"
make_jpeg "$cli_jpg" 40 || fail m8-photos "could not make the CLI's JPEG (python3, sips)"
make_jpeg "$app_jpg" 200 || fail m8-photos "could not make the app's JPEG (python3, sips)"
xcrun simctl addmedia "$udid" "$app_jpg" > "$out/addmedia.txt" 2>&1 || fail m8-photos "simctl addmedia failed (m8/addmedia.txt)"
if ! xcrun simctl privacy "$udid" grant photos "$APP_BUNDLE_ID" > /dev/null 2>&1; then
	echo "::warning::simctl privacy grant photos failed; the test allows the prompt instead"
fi
xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 5
record m8-photos PASS "$(wc -c < "$cli_jpg" | tr -d ' ') and $(wc -c < "$app_jpg" | tr -d ' ') byte JPEGs; the app's in the library, full Photos access"

stage m8-cli-send
o=$(offset)
if ! "$cli" send -identity "$profile" -to "$app_id" -file "$cli_jpg" -caption "$inbound" > "$out/send.txt" 2>&1; then
	tail -n 20 "$out/send.txt"
	fail m8-cli-send "cli send -file failed (m8/send.txt)"
fi
sent_id=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id\$/\1/p" "$out/send.txt" | head -n 1)
[ -n "$sent_id" ] || fail m8-cli-send "send did not name the message it sent"
record m8-cli-send PASS "message $sent_id to $app_id: $(grep -F 'file m8-cli.jpg:' "$out/send.txt" | head -n 1 | cut -c1-160)"
stage m8-cli-upload
uploads=$(wait_since "$o" 10 2 'blob: blob uploaded' "owner=$cli_id")
cli_refs=$(printf '%s\n' "$uploads" | refs_of | head -n 2)
if [ "$(printf '%s\n' "$cli_refs" | grep -c .)" = 2 ]; then
	record m8-cli-upload PASS "the file and its thumbnail, owner=$cli_id"
else
	record m8-cli-upload FAIL "fewer than two uploads with owner=$cli_id since the send"
fi

"$cli" listen -identity "$profile" -save-files "$saved" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!

stage m8-test-in
if TEST_RUNNER_M8_INBOUND="$inbound" run_test testSeeTheCLIImage; then
	record m8-test-in PASS "the chat shows the image \"$inbound\""
else
	record m8-test-in FAIL "xcodebuild test failed (m8/testSeeTheCLIImage.tail.txt)"
fi
stage m8-app-fetch
fetched=0
for ref in $cli_refs; do
	if wait_since "$o" 60 1 'blob: done handled' "blob_ref=$ref" | grep -qF 'outcome=deleted' &&
		[ -n "$(since "$o" 'blob: blob download' "blob_ref=$ref" | grep -F 'outcome=served')" ]; then
		fetched=$((fetched + 1))
	fi
done
if [ "$fetched" = 2 ]; then
	record m8-app-fetch PASS "the app downloaded the image and its thumbnail and marked both done"
else
	record m8-app-fetch FAIL "$fetched of the CLI's 2 blobs downloaded and marked done (m8/blob-lines.txt)"
fi

stage m8-test-out
o=$(offset)
if TEST_RUNNER_M8_OUTBOUND="$outbound" run_test testSendImageToCLI; then
	record m8-test-out PASS "the app sent an image from the picker with \"$outbound\""
else
	record m8-test-out FAIL "xcodebuild test failed (m8/testSendImageToCLI.tail.txt)"
fi
stage m8-app-upload
if uploads=$(wait_since "$o" 30 1 'blob: blob uploaded' "owner=$app_id"); then
	record m8-app-upload PASS "$(printf '%s\n' "$uploads" | wc -l | tr -d ' ') upload(s) with owner=$app_id"
else
	record m8-app-upload FAIL "no upload with owner=$app_id since the test started"
fi
stage m8-cli-saved
if wait_for_text "$out/listen.txt" "caption \"$outbound\"" 60 && wait_for_text "$out/listen.txt" "file saved: " 30; then
	file=$(find "$saved" -type f | head -n 1)
	if [ -n "$file" ] && is_jpeg "$file"; then
		record m8-cli-saved PASS "$(grep -F 'file saved: ' "$out/listen.txt" | head -n 1 | sed 's|: .*[/\\]|: |' | cut -c1-200)"
	else
		record m8-cli-saved FAIL "the CLI saved no JPEG (m8/listen.txt)"
	fi
else
	grep -F 'threema-cli: file ' "$out/listen.txt" | head -n 3
	record m8-cli-saved FAIL "the CLI did not print and save the app's image (m8/listen.txt)"
fi

stage m8-receipt
receipt="delivery receipt (received) for $sent_id"
if grep -qF -- "$receipt" "$out/send.txt" || wait_for_text "$out/listen.txt" "$receipt" 30; then
	record m8-receipt PASS "$receipt"
else
	record m8-receipt FAIL "no \"$receipt\" from the app (m8/send.txt, m8/listen.txt)"
fi
record m8-blob-lines INFO "$(since "$m8_start" 'component=blob' | wc -l | tr -d ' ') blob server lines in milestone 8"
shot m8-09-final

failed=$(failing_stages "$M8_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 8: every stage passed"
