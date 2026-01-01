#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m6"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m6"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"
hold=75

listen_pid=
joiner_pid=
finish() {
	for pid in "$joiner_pid" "$listen_pid"; do
		[ -n "$pid" ] || continue
		kill -INT "$pid" 2> /dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$pid" 2> /dev/null || break
			sleep 1
		done
		kill -KILL "$pid" 2> /dev/null
	done
	if [ -s "$SRV/cli.path" ]; then pkill -f -- "$(cat "$SRV/cli.path") call" 2> /dev/null || true; fi
	for f in probe.txt listen.txt call.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m6/$f"
	done
}
trap finish EXIT

fail() {
	record "$1" FAIL "$2"
	exit 1
}

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

since() {
	(tail -c +"$(($1 + 1))" "$SRV/server.log" 2> /dev/null || true) | grep -F -- "$2" | grep -F -- "${3:-$2}" || true
}

[ -s "$SRV/m5-group" ] || fail m6-test "no group from milestone 5"
group=$(sed -n 1p "$SRV/m5-group")
group_name=$(sed -n 2p "$SRV/m5-group")
log_start=$(date '+%Y-%m-%d %H:%M:%S')

stage m6-sfu-up
if line=$(grep -F 'sfu: media transport listening' "$SRV/server.log" | head -n 1) && [ -n "$line" ]; then
	record m6-sfu-up PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	fail m6-sfu-up "no 'sfu: media transport listening' in the server log"
fi

stage m6-probe
call_id=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
"$cli" call -identity "$profile" -call-id "$call_id" -duration 5s -alone-timeout -1s > "$out/probe.txt" 2>&1 3>&- || true
if grep -q -E '^joined +as participant' "$out/probe.txt"; then
	record m6-probe PASS "$(grep -E '^joined +as participant' "$out/probe.txt" | head -n 1 | tr -s ' ' | cut -c1-160)"
else
	tail -n 20 "$out/probe.txt"
	record m6-probe FAIL "the CLI could not join a call of its own (m6/probe.txt)"
fi

offset=$(wc -c < "$SRV/server.log" | tr -d ' ')
rm -f "$SEC/gcks.json"
"$cli" listen -identity "$profile" -group-calls "$SEC/gcks.json" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!
(
	if wait_for_text "$out/listen.txt" "key saved to" $((hold + 60)); then
		"$cli" call -identity "$profile" -gck-file "$SEC/gcks.json" -duration 60s -stats 10s > "$out/call.txt" 2>&1
	fi
) 3>&- &
joiner_pid=$!
sleep 3

xcrun simctl privacy "$udid" grant microphone "$APP_BUNDLE_ID" > /dev/null 2>&1 || true
stage m6-test
status=0
TEST_RUNNER_M6_GROUP_NAME="$group_name" TEST_RUNNER_M6_HOLD="$hold" \
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
	-only-testing:OnboardingDriverUITests/GroupCallTests/testStartGroupCall \
	-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
	-resultBundlePath "$work/groupcall.xcresult" -collect-test-diagnostics never \
	-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
	CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
	> "$out/xcodebuild-test.log" 2>&1 || status=$?
tail -n 150 "$out/xcodebuild-test.log" > "$RESULTS/m6/xcodebuild-test.tail.txt"
export_attachments "$work/groupcall.xcresult" "$out/shots" "$RESULTS/m6" m6- > /dev/null 2>&1 || true
if [ "$status" = 0 ]; then
	record m6-test PASS "the app opened the group and started its group call"
else
	record m6-test FAIL "xcodebuild test exit $status (m6/xcodebuild-test.tail.txt)"
fi

stage m6-start
if grep -F -- "in group $group: group call start: protocol" "$out/listen.txt" > /dev/null; then
	record m6-start PASS "$(grep -F -- 'group call start' "$out/listen.txt" | head -n 1 | cut -c1-200)"
else
	record m6-start FAIL "no GroupCallStart from the app in group $group (m6/listen.txt)"
fi

for _ in $(seq 1 45); do
	kill -0 "$joiner_pid" 2> /dev/null || break
	sleep 2
done

stage m6-cli-joined
if grep -q -E '^joined +as participant' "$out/call.txt" 2> /dev/null && grep -q -E '^others +\[[0-9]' "$out/call.txt"; then
	record m6-cli-joined PASS "$(grep -E '^(joined +as|others)' "$out/call.txt" | tr -s ' ' | tr '\n' ';' | cut -c1-200)"
else
	record m6-cli-joined FAIL "the CLI did not join the app's call with the app in it (m6/call.txt)"
fi

stage m6-sfu-app
if [ -n "$(since "$offset" 'sfu: participant connected' 'others=0')" ]; then
	record m6-sfu-app PASS "the app's media connection to the SFU is up (participant connected, others=0)"
else
	record m6-sfu-app FAIL "no 'sfu: participant connected' for the app"
fi
stage m6-sfu-peers
if [ -n "$(since "$offset" 'sfu: participant connected' 'others=1')" ]; then
	record m6-sfu-peers PASS "two participants in one call at the SFU (participant connected, others=1)"
else
	record m6-sfu-peers FAIL "never two participants at once at the SFU"
fi

packets=$(sed -n 's/.*from participant [0-9]* microphone: \([0-9]*\) packets.*/\1/p' "$out/call.txt" 2> /dev/null | sort -n | tail -n 1)
if [ "${packets:-0}" -gt 0 ] 2> /dev/null; then
	record m6-audio INFO "the SFU forwarded the app's audio to the CLI: $packets packets"
else
	record m6-audio INFO "no audio from the app (the runner may have no audio input)"
fi
warns=$(since "$offset" 'level=WARN' | grep -F 'sfu' | cut -c1-200 | head -n 5 | tr '\n' ';')
[ -z "$warns" ] || record m6-sfu-warn INFO "$warns"

xcrun simctl spawn "$udid" log show --start "$log_start" --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema"' > "$out/app-oslog.txt" 2>&1 || true
grep -E '\[GroupCall\]|\[Group Call\]|\[Call:GroupCall|\[Call:Launcher\]|RTCAudioSession|AudioSession' "$out/app-oslog.txt" |
	tail -n 600 | cut -c1-400 > "$RESULTS/m6/app-groupcall-log.txt" || true
shot m6-09-final

failed=$(failing_stages "$M6_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 6: every stage passed"
