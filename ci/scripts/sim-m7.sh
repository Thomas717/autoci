#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m7"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
dir_profile="$SEC/cli-dir.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m7"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

finish() {
	for f in register.txt status.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m7/$f"
	done
}
trap finish EXIT

fail() {
	record "$1" FAIL "$2"
	exit 1
}

since() {
	(tail -c +"$(($1 + 1))" "$SRV/server.log" 2> /dev/null || true) | grep -F -- "$2" | grep -F -- "${3:-$2}" || true
}
offset() { wc -c < "$SRV/server.log" | tr -d ' '; }

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/WorkContactsTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m7/$1.tail.txt"
	export_attachments "$work/$1.xcresult" "$out/shots" "$RESULTS/m7" m7- > /dev/null 2>&1 || true
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 5
}

cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
nonce=$(test_nonce)

stage m7-dir-register
if ! "$cli" register -license - -signature-key "$(cat "$SRV/oppf-public.key")" -nickname "CI Colleague" \
	-out "$dir_profile" < "$SEC/license-dir.url" > "$out/register.txt" 2>&1; then
	tail -n 20 "$out/register.txt"
	fail m7-dir-register "cli register failed (m7/register.txt)"
fi
key=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["clientKey"])' "$dir_profile")
add_secret "$key"
key=
dir_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$dir_profile")
[[ $dir_id =~ ^[0-9A-Z]{8}$ ]] || fail m7-dir-register "the colleague's profile holds no identity"
record m7-dir-register PASS "colleague $dir_id on ${DIR_SEAT_USERNAME:-ci-dir}"

stage m7-status
o=$(offset)
if "$cli" work-status -identity "$profile" -set busy -description "M7 $nonce" > "$out/status.txt" 2>&1 &&
	[ -n "$(since "$o" 'work: user properties request' 'outcome=applied')" ]; then
	record m7-status PASS "$(grep -F 'work status' "$out/status.txt" | head -n 1 | cut -c1-160)"
else
	tail -n 20 "$out/status.txt"
	record m7-status FAIL "the CLI's work-status was not applied (m7/status.txt)"
fi

stage m7-delta
app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
end=$(($(date +%s) + 60))
line=
while [ -z "$line" ] && [ "$(date +%s)" -lt "$end" ]; do
	line=$(since "$o" 'chatserver: message acknowledged by the receiver' "receiver=$app_id" | grep -F 'sender=*3MAW0RK' | tail -n 1)
	[ -n "$line" ] || sleep 2
done
if [ -n "$line" ]; then
	record m7-delta PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m7-delta FAIL "no Work Sync delta from *3MAW0RK acknowledged by the app within 60 s of the status change"
fi

relaunch
stage m7-test-sync
o=$(offset)
if TEST_RUNNER_M7_CLI_ID="$cli_id" run_test testWorkSync; then
	record m7-test-sync PASS "the Contacts tab lists the CLI, and the app pulled to refresh"
else
	record m7-test-sync FAIL "xcodebuild test failed (m7/testWorkSync.tail.txt)"
fi
stage m7-worksync
line=$(since "$o" 'work: work data fetched' 'seat=ci-ios' | grep -v 'contacts_returned=0' | tail -n 1)
if [ -n "$line" ]; then
	record m7-worksync PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m7-worksync FAIL "no Work Sync of the app's seat with a contact in it since the test started"
fi

stage m7-test-directory
o=$(offset)
if TEST_RUNNER_M7_QUERY="Colleague" TEST_RUNNER_M7_DIR_ID="$dir_id" run_test testDirectorySearch; then
	record m7-test-directory PASS "the directory search found the colleague, and the app showed $dir_id"
else
	record m7-test-directory FAIL "xcodebuild test failed (m7/testDirectorySearch.tail.txt)"
fi
stage m7-directory
line=$(since "$o" 'work: directory searched' 'seat=ci-ios' | grep -v 'results=0' | tail -n 1)
if [ -n "$line" ]; then
	record m7-directory PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m7-directory FAIL "no directory search of the app's seat with a hit since the test started"
fi
refusals=$(since "$o" 'work: refused a directory search')
if [ -n "$refusals" ]; then
	record m7-directory-refused INFO "$(printf '%s\n' "$refusals" | tail -n 1 | sed 's/^time=[^ ]* //' | cut -c1-200)"
fi

relaunch
if TEST_RUNNER_M7_STATUS="Busy" run_test testAvailability; then
	record m7-availability INFO "the CLI's chat-list row says \"Status: Busy\""
else
	record m7-availability INFO "the CLI's chat-list row does not say \"Status: Busy\" (m7/testAvailability.tail.txt)"
fi
info=$(since "$(cat "$SRV/log.offset")" 'directory: work info updated' 'seat=ci-ios' | wc -l | tr -d ' ')
record m7-work-info INFO "the app sent its work info $info time(s)"

xcrun simctl spawn "$udid" log show --last 15m --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema" AND subsystem != "com.apple.dt.xctest"' > "$out/app-oslog.txt" 2>&1 || true
grep -E '\[WorkDataFetcher\]|\[WorkData|batchAddWorkContacts|CompanyDirectory|WorkAvailability|\[ContactStore\]|[Dd]irectory|featureMask failed' "$out/app-oslog.txt" |
	tail -n 400 | cut -c1-400 > "$RESULTS/m7/app-work-log.txt" || true
record m7-app-log INFO "os_log $(wc -c < "$out/app-oslog.txt" | tr -d ' ') bytes, $(wc -l < "$RESULTS/m7/app-work-log.txt" | tr -d ' ') Work line(s) kept"
shot m7-09-final

failed=$(failing_stages "$M7_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 7: every stage passed"
