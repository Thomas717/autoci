#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SEAT_USERNAME:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m17"
work="$RUNNER_TEMP/m2-driver"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m17"
enabled=true

finish() {
	if [ "$enabled" != true ] && [ -s "$SEC/cockpit.csrf" ]; then
		cockpit POST "/api/users/$SEAT_USERNAME/enable" '{}' > /dev/null || true
	fi
	cockpit_sign_out
	(since "${m17_start:-0}" 'license checked' | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200 \
		> "$RESULTS/m17/licence-lines.txt") 2> /dev/null || true
	(since "${m17_start:-0}" 'refused the provisioning file' | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200 \
		>> "$RESULTS/m17/licence-lines.txt") 2> /dev/null || true
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
m17_start=$(offset)

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/LicenseTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m17-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m17/$1.tail.txt"
	export_attachments "$work/m17-$1.xcresult" "$out/shots" "$RESULTS/m17" m17- > /dev/null 2>&1 || true
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m17-cockpit "no identity of the app in the server log"

stage m17-cockpit
cockpit_sign_in || fail m17-cockpit "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S17)"
record m17-cockpit PASS "signed in as ci-admin"

stage m17-disable
status=$(cockpit POST "/api/users/$SEAT_USERNAME/disable" '{"dualLock":"keep"}')
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m17/disable-answer.json" 2> /dev/null
	fail m17-disable "the cockpit answered $status (m17/disable-answer.json)"
fi
enabled=false
record m17-disable PASS "$SEAT_USERNAME disabled (HTTP $status)"

o=$(offset)
relaunch
stage m17-test-locked
if run_test testLocked; then
	record m17-test-locked PASS "after a relaunch the licence screen asks for the credentials"
else
	record m17-test-locked FAIL "xcodebuild test failed (m17/testLocked.tail.txt)"
fi
stage m17-refused
line=$( (since "$o" 'provisioning: refused the provisioning file' 'reason="invalid credentials"'
	since "$o" 'directory: license checked' 'result=invalid') | tail -n 1)
if [ -n "$line" ]; then
	record m17-refused PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200)"
else
	record m17-refused FAIL "the server refused no credentials since the relaunch (m17/licence-lines.txt)"
fi
stage m17-offline
if [ -z "$(since "$o" 'chatserver: client connected' "identity=$app_id")" ]; then
	record m17-offline PASS "the app did not connect to the chat server with its seat disabled"
else
	record m17-offline FAIL "the app connected to the chat server with its seat disabled"
fi

stage m17-enable
status=$(cockpit POST "/api/users/$SEAT_USERNAME/enable" '{}')
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m17/enable-answer.json" 2> /dev/null
	fail m17-enable "the cockpit answered $status (m17/enable-answer.json)"
fi
enabled=true
record m17-enable PASS "$SEAT_USERNAME enabled again (HTTP $status)"

o=$(offset)
relaunch
stage m17-test-back
if run_test testBack; then
	record m17-test-back PASS "after a relaunch the chat list is back, without the licence screen"
else
	record m17-test-back FAIL "xcodebuild test failed (m17/testBack.tail.txt)"
fi
stage m17-valid
line=$(since "$o" 'directory: license checked' 'result=valid' | grep -F "seat=$SEAT_USERNAME" | tail -n 1)
if [ -n "$line" ]; then
	record m17-valid PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200)"
else
	record m17-valid FAIL "no valid licence check of $SEAT_USERNAME since the relaunch"
fi
stage m17-connected
line=$(since "$o" 'chatserver: client connected' "identity=$app_id" | tail -n 1)
if [ -n "$line" ]; then
	record m17-connected PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m17-connected FAIL "the app did not connect to the chat server after the seat was enabled again"
fi
shot m17-09-final

failed=$(failing_stages "$M17_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 17: every stage passed"
