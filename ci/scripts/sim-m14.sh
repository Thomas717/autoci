#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m14"
work="$RUNNER_TEMP/m2-driver"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m14"

finish() {
	cockpit_sign_out
	(since "${m14_start:-0}" 'component=branding' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m14/branding-lines.txt") 2> /dev/null || true
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
m14_start=$(offset)

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/BrandingTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m14-$1-$TEST_RUNNER_M14_TAG.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1-$TEST_RUNNER_M14_TAG.log" 2>&1 || status=$?
	tail -n 150 "$out/$1-$TEST_RUNNER_M14_TAG.log" > "$RESULTS/m14/$1-$TEST_RUNNER_M14_TAG.tail.txt"
	export_attachments "$work/m14-$1-$TEST_RUNNER_M14_TAG.xcresult" "$out/shots" "$RESULTS/m14" m14- > /dev/null 2>&1 || true
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 5
}

make_logo() {
	python3 -I - "$@" <<'PY'
import struct, sys, zlib

path, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
a = bytes(int(v) for v in a.split(",")) + bytes([255])
b = bytes(int(v) for v in b.split(",")) + bytes([255])
clear = bytes(4)
w, h = 400, 100
rows = bytearray()
for y in range(h):
    rows.append(0)
    for x in range(w):
        if y < 10 or y >= h - 10:
            rows += clear
        else:
            rows += a if (x // 40) % 2 == 0 else b


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


png = bytes.fromhex("89504e470d0a1a0a")
png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
png += chunk(b"IEND", b"")
open(path, "wb").write(png)
PY
}

upload() {
	local stage=$1 tag=$2 status variant file shas
	light_sha=
	dark_sha=
	for variant in light dark; do
		file="$out/logo-$tag-$variant.png"
		if [ "$variant" = light ]; then make_logo "$file" $3; else make_logo "$file" $4; fi || {
			record "$stage" FAIL "making the $variant logo failed"
			return 1
		}
		status=$(cockpit_png "/api/branding/logo/$variant" "$file")
		if [ "${status#2}" = "$status" ]; then
			cp "$COCKPIT_ANSWER" "$RESULTS/m14/$tag-$variant-answer.json" 2> /dev/null
			record "$stage" FAIL "the cockpit answered $status to the $variant logo (m14/$tag-$variant-answer.json)"
			return 1
		fi
	done
	shas=$(python3 -I - "$COCKPIT_ANSWER" <<'PY' | tr -d '\r'
import json, re, sys

logo = json.load(open(sys.argv[1]))["preview"]["logo"]
out = []
for variant in ("light", "dark"):
    m = re.search(r"/branding/logo-%s-([0-9a-f]{8})\.png$" % variant, logo.get(variant) or "")
    out.append(m.group(1) if m else "-")
print(" ".join(out))
PY
	)
	light_sha=${shas%% *}
	dark_sha=${shas##* }
	if ! [[ ${light_sha:-} =~ ^[0-9a-f]{8}$ && ${dark_sha:-} =~ ^[0-9a-f]{8}$ ]]; then
		cp "$COCKPIT_ANSWER" "$RESULTS/m14/$tag-answer.json" 2> /dev/null
		record "$stage" FAIL "the cockpit's preview names no uploaded logo URLs (m14/$tag-answer.json)"
		return 1
	fi
	record "$stage" PASS "light logo-light-$light_sha.png, dark logo-dark-$dark_sha.png under $SERVER_PUBLIC_URL/branding/"
}

served() {
	local end=$(($(date +%s) + 90)) line=
	while [ -z "$line" ] && [ "$(date +%s)" -lt "$end" ]; do
		line=$(since "$1" 'branding: logo served' | grep -E "asset=($light_sha|$dark_sha)( |$)" | tail -n 1)
		[ -n "$line" ] || sleep 2
	done
	if [ -n "$line" ]; then
		record "$2" PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
	else
		record "$2" FAIL "no download of logo-light-$light_sha.png or logo-dark-$dark_sha.png within 90 s"
	fi
}

shown() {
	local note="$RESULTS/m14/m14-$1-images.txt" summary
	stage "m14-shown-$1"
	if [ ! -f "$note" ]; then
		record "m14-shown-$1" FAIL "no image report from the test"
		return
	fi
	summary=$(head -n 3 "$note" | tr '\n' ';' | cut -c1-240)
	if grep -qx "uploaded logo shown: $2" "$note"; then
		record "m14-shown-$1" PASS "$summary"
	else
		record "m14-shown-$1" FAIL "want \"uploaded logo shown: $2\": $summary"
	fi
}

stage m14-cockpit
cockpit_sign_in || fail m14-cockpit "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S14)"
record m14-cockpit PASS "signed in as ci-admin"

stage m14-upload
o=$(offset)
upload m14-upload upload "0,90,170 255,140,0" "120,200,255 255,200,80" || exit 1

relaunch
stage m14-test-sync
if TEST_RUNNER_M14_TAG=upload TEST_RUNNER_M14_ASPECT=4 run_test testLogo; then
	record m14-test-sync PASS "a pull to refresh in Contacts, then the Chats tab"
else
	record m14-test-sync FAIL "xcodebuild test failed (m14/testLogo-upload.tail.txt)"
fi
stage m14-served
served "$o" m14-served
shown upload yes

stage m14-change
first_light=$light_sha
first_dark=$dark_sha
o=$(offset)
upload m14-change change "0,140,70 160,40,160" "120,230,160 230,150,230" || exit 1
if [ "$light_sha" = "$first_light" ] || [ "$dark_sha" = "$first_dark" ]; then
	record m14-change FAIL "the new logos kept a URL (light $light_sha, dark $dark_sha)"
fi
stage m14-test-change
if TEST_RUNNER_M14_TAG=change TEST_RUNNER_M14_ASPECT=4 run_test testLogo; then
	record m14-test-change PASS "a pull to refresh in Contacts, then the Chats tab"
else
	record m14-test-change FAIL "xcodebuild test failed (m14/testLogo-change.tail.txt)"
fi
stage m14-served-new
served "$o" m14-served-new
shown change yes

removed=ok
for variant in light dark; do
	status=$(cockpit DELETE "/api/branding/logo/$variant")
	[ "${status#2}" != "$status" ] || removed="HTTP $status for $variant"
done
preview=$(python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["preview"]["logo"]))' "$COCKPIT_ANSWER" 2> /dev/null || echo '?')
TEST_RUNNER_M14_TAG=removed TEST_RUNNER_M14_ASPECT=4 run_test testLogo > /dev/null 2>&1 || true
record m14-removed INFO "the logos removed: $removed; the Work Sync's logo now $preview"
shown removed no
shot m14-09-final

failed=$(failing_stages "$M14_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 14: every stage passed"
