#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m4"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m4"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

voip_pid=
finish() {
	if [ -n "$voip_pid" ]; then
		kill -INT "$voip_pid" 2> /dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$voip_pid" 2> /dev/null || break
			sleep 1
		done
		kill -KILL "$voip_pid" 2> /dev/null
		voip_pid=
	fi
	[ -f "$out/voip.txt" ] && cp "$out/voip.txt" "$RESULTS/m4/voip.txt"
}
trap finish EXIT

patch0003=0003-simulator-callkit-1to1.patch
patch_line=$(grep "^source patch: $patch0003 " "$RUNNER_TEMP/app/build-info.txt" 2> /dev/null | head -n 1)
if [ -z "$patch_line" ] || [[ $patch_line == *"NOT applied"* ]]; then
	stage m4-test
	record m4-test FAIL "the app under test was built without ci/build/patches/$patch0003 (build/build-info.txt), so CallKit would end its call at once"
	exit 1
fi

for service in microphone camera; do
	xcrun simctl privacy "$udid" grant "$service" "$APP_BUNDLE_ID" > /dev/null 2>&1 ||
		echo "::warning::simctl privacy grant $service failed; the test allows the prompt instead"
done

stage m4-voip
"$cli" voip -identity "$profile" -answer auto -duration 20s -calls 1 -expect connected > "$out/voip.txt" 2>&1 3>&- &
voip_pid=$!
sleep 5
if kill -0 "$voip_pid" 2> /dev/null; then
	record m4-voip PASS "voip waits for the app's call"
else
	tail -n 20 "$out/voip.txt"
	record m4-voip FAIL "voip exited before any call (m4/voip.txt)"
	exit 1
fi

stage m4-test
status=0
log_start=$(date '+%Y-%m-%d %H:%M:%S')
xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
	-only-testing:OnboardingDriverUITests/CallTests \
	-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
	-resultBundlePath "$work/calls.xcresult" -collect-test-diagnostics never \
	-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
	CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
	> "$out/xcodebuild-test.log" 2>&1 || status=$?
tail -n 150 "$out/xcodebuild-test.log" > "$RESULTS/m4/xcodebuild-test.tail.txt"
if ! export_attachments "$work/calls.xcresult" "$out/shots" "$RESULTS/m4" m4-; then
	cp "$work/attachments-m4-.log" "$RESULTS/m4/export.log"
fi
xcrun simctl spawn "$udid" log show --start "$log_start" --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema" AND subsystem != "com.apple.dt.xctest"' > "$out/app-oslog.txt" 2>&1 || true
grep -E '\[Call|CallKit|VoIP|AVAudioSession|RTC|ICE|TURN' "$out/app-oslog.txt" | tail -n 600 | cut -c1-400 \
	> "$RESULTS/m4/app-call-log.txt" || true
metric m4_app_call_log_lines "$(wc -l < "$RESULTS/m4/app-call-log.txt" | tr -d ' ')"
if [ "$status" = 0 ]; then
	record m4-test PASS "the app placed the call from the chat's call button"
else
	grep -E 'error:|failed|XCTAssert' "$out/xcodebuild-test.log" | head -n 20 || true
	record m4-test FAIL "xcodebuild test exit $status (m4/xcodebuild-test.tail.txt)"
fi

stage m4-connected
for _ in $(seq 1 45); do
	kill -0 "$voip_pid" 2> /dev/null || break
	sleep 2
done
summary=
if kill -0 "$voip_pid" 2> /dev/null; then
	record m4-connected FAIL "voip still waits 90 s after the test: no call ended (m4/voip.txt)"
else
	voip_status=0
	wait "$voip_pid" || voip_status=$?
	voip_pid=
	summary=$(grep -E 'call=[0-9]+ peer=' "$out/voip.txt" | tail -n 1)
	if [ "$voip_status" = 0 ]; then
		record m4-connected PASS "$(printf '%s' "$summary" | cut -c1-240)"
	else
		record m4-connected FAIL "voip exit $voip_status: ${summary:-no call summary} (m4/voip.txt)"
	fi
fi
audio_in=$(printf '%s' "$summary" | sed -n 's/.* audio_in=\([0-9]*\)\/.*/\1/p')
if [ "${audio_in:-0}" -gt 0 ] 2> /dev/null; then
	record m4-audio INFO "the app's audio reached the CLI: $audio_in packets"
else
	record m4-audio INFO "no audio packets from the app (the runner may have no audio input)"
fi
shot m4-06-final

failed=$(failing_stages "$M4_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 4: every stage passed"
