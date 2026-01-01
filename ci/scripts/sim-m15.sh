#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SEAT_USERNAME:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m15"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m15"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

finish() {
	rm -f "$SEC/m15-curl.conf"
	for f in send.txt check.json; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m15/$f"
	done
	(since "${m15_start:-0}" 'revoked' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m15/revoke-lines.txt") 2> /dev/null || true
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
m15_start=$(offset)

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/RevocationTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m15-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m15/$1.tail.txt"
	export_attachments "$work/m15-$1.xcresult" "$out/shots" "$RESULTS/m15" m15- > /dev/null 2>&1 || true
	return "$status"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m15-test-revoke "no identity of the app in the server log"

xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 5

stage m15-test-revoke
o=$(offset)
if TEST_RUNNER_M15_ID="$app_id" run_test testRevoke; then
	record m15-test-revoke PASS "the app says its ID $app_id has been revoked"
else
	record m15-test-revoke FAIL "xcodebuild test failed (m15/testRevoke.tail.txt)"
fi

stage m15-revoked
line=$(since "$o" 'directory: identity revoked' | grep -vF 'revocation key' | tail -n 1)
if [ -n "$line" ]; then
	record m15-revoked PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m15-revoked FAIL "no \"directory: identity revoked\" since the test started"
fi

stage m15-check
(umask 077 && printf 'user = "%s:%s"\n' "$SEAT_USERNAME" "$(cat "$SEC/seat-password.txt")" > "$SEC/m15-curl.conf")
state=$(curl_tls -s -K "$SEC/m15-curl.conf" --cacert "$SRV/tls/ca.crt" -H 'Content-Type: application/json' \
	--data "{\"identities\":[\"$app_id\"]}" "$SERVER_PUBLIC_URL/directory/identity/check" -o "$out/check.json" -w '%{http_code}' || echo 000)
states=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["states"])' "$out/check.json" 2> /dev/null | tr -d '\r')
lookup=$(curl_tls -s -K "$SEC/m15-curl.conf" -o /dev/null -w '%{http_code}' --cacert "$SRV/tls/ca.crt" \
	"$SERVER_PUBLIC_URL/directory/identity/$app_id" || echo 000)
rm -f "$SEC/m15-curl.conf"
if [ "$state" = 200 ] && [ "$states" = "[2]" ] && [ "$lookup" = 404 ]; then
	record m15-check PASS "identity/check: state 2 (invalid); GET identity/$app_id: 404"
else
	record m15-check FAIL "identity/check answered $state with states $states; GET identity/$app_id answered $lookup"
fi

stage m15-cli-send
if "$cli" send -identity "$profile" -to "$app_id" -text "M15 to a revoked ID" > "$out/send.txt" 2>&1; then
	record m15-cli-send FAIL "the CLI's message to the revoked $app_id was taken (m15/send.txt)"
elif grep -qF 'not found' "$out/send.txt"; then
	record m15-cli-send PASS "refused, the directory no longer knows $app_id: $(grep -F 'not found' "$out/send.txt" | tail -n 1 | cut -c1-140)"
else
	record m15-cli-send FAIL "the send failed, but not for an unknown ID (m15/send.txt)"
fi

deleted=$(since "$m15_start" 'component=safe method=DELETE' | tail -n 1 | sed 's/^time=[^ ]* //' | cut -c1-200)
record m15-safe INFO "${deleted:-no DELETE of a Safe backup}"
xcrun simctl launch "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US > /dev/null 2>&1 || true
sleep 10
shot m15-09-relaunched
record m15-relaunch INFO "the app relaunched after the revocation (screenshot m15-09-relaunched)"

failed=$(failing_stages "$M15_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 15: every stage passed"
