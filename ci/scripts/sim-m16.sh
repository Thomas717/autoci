#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SEAT_USERNAME:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m16"
work="$RUNNER_TEMP/m2-driver"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m16"

finish() {
	cockpit_sign_out
	(since "${m16_start:-0}" 'work: work data fetched' "seat=$SEAT_USERNAME" | sed 's/^time=[^ ]* //' | cut -c1-300 \
		> "$RESULTS/m16/worksync-lines.txt") 2> /dev/null || true
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
wait_line() {
	local off=$1 end=$(($(date +%s) + $2)) lines filter
	shift 2
	while :; do
		lines=$(tail -c +"$((off + 1))" "$SRV/server.log" 2> /dev/null || true)
		for filter in "$@"; do
			case $filter in
			!*) lines=$(printf '%s\n' "$lines" | grep -vF -- "${filter#!}" || true) ;;
			*) lines=$(printf '%s\n' "$lines" | grep -F -- "$filter" || true) ;;
			esac
		done
		lines=$(printf '%s\n' "$lines" | sed '/^$/d' | tail -n 1)
		if [ -n "$lines" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}
m16_start=$(offset)

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/AppConfigTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m16-$1-$TEST_RUNNER_M16_TAG.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1-$TEST_RUNNER_M16_TAG.log" 2>&1 || status=$?
	tail -n 150 "$out/$1-$TEST_RUNNER_M16_TAG.log" > "$RESULTS/m16/$1-$TEST_RUNNER_M16_TAG.tail.txt"
	export_attachments "$work/m16-$1-$TEST_RUNNER_M16_TAG.xcresult" "$out/shots" "$RESULTS/m16" m16- > /dev/null 2>&1 || true
	return "$status"
}

patch() {
	local status queued
	status=$(cockpit PATCH "/api/users/$SEAT_USERNAME/app-configuration" "$2")
	if [ "${status#2}" = "$status" ]; then
		cp "$COCKPIT_ANSWER" "$RESULTS/m16/$1-answer.json" 2> /dev/null
		record "$1" FAIL "the cockpit answered $status (m16/$1-answer.json)"
		return 1
	fi
	queued=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("pushResult", {}).get("queued", "?"))' \
		"$COCKPIT_ANSWER" 2> /dev/null | tr -d '\r')
	record "$1" PASS "$2 (HTTP $status, $queued device(s) asked to sync)"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m16-cockpit "no identity of the app in the server log"

xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 8

stage m16-cockpit
cockpit_sign_in || fail m16-cockpit "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S16)"
record m16-cockpit PASS "signed in as ci-admin"

stage m16-set
o=$(offset)
patch m16-set '{"set":{"th_disable_add_contact":true,"th_block_unknown":true},"pushNow":true}' || exit 1

if line=$(wait_line "$o" 30 'chatserver: message acknowledged by the receiver' "receiver=$app_id" 'sender=*3MAW0RK'); then
	record m16-push INFO "delivered, and discarded by iOS OnPrem: $(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160)"
else
	record m16-push INFO "no Work Sync delta from *3MAW0RK acknowledged by the app within 30 s"
fi

stage m16-test-on
if TEST_RUNNER_M16_EXPECT=on TEST_RUNNER_M16_TAG=on run_test testApplied; then
	record m16-test-on PASS "the compose sheet says features are disabled; Block Unknown is on and locked"
else
	record m16-test-on FAIL "xcodebuild test failed (m16/testApplied-on.tail.txt, m16/m16-on-report.txt)"
fi
stage m16-sync
if line=$(wait_line "$o" 5 'work: work data fetched' "seat=$SEAT_USERNAME" 'th_block_unknown' 'th_disable_add_contact'); then
	record m16-sync PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-260)"
else
	record m16-sync FAIL "no Work Sync of $SEAT_USERNAME naming both keys since the cockpit's change"
fi

stage m16-unset
o=$(offset)
patch m16-unset '{"set":{"th_block_unknown":false},"inherit":["th_disable_add_contact"],"pushNow":true}' || exit 1
stage m16-test-off
if TEST_RUNNER_M16_EXPECT=off TEST_RUNNER_M16_TAG=off run_test testApplied; then
	record m16-test-off PASS "the compose sheet no longer says features are disabled; Block Unknown is off"
else
	record m16-test-off FAIL "xcodebuild test failed (m16/testApplied-off.tail.txt, m16/m16-off-report.txt)"
fi
stage m16-sync-off
if line=$(wait_line "$o" 5 'work: work data fetched' "seat=$SEAT_USERNAME" 'th_block_unknown' '!th_disable_add_contact'); then
	record m16-sync-off PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-260)"
else
	record m16-sync-off FAIL "no Work Sync of $SEAT_USERNAME without th_disable_add_contact since the change"
fi

status=$(cockpit PATCH "/api/users/$SEAT_USERNAME/app-configuration" '{"inherit":["th_block_unknown"]}')
record m16-cleared INFO "th_block_unknown taken back too: HTTP $status"
shot m16-09-final

failed=$(failing_stages "$M16_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 16: every stage passed"
