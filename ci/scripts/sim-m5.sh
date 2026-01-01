#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m5"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m5"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

listen_pid=
start_listen() {
	"$cli" listen -identity "$profile" >> "$out/listen.txt" 2>&1 3>&- &
	listen_pid=$!
	sleep 3
}
stop_listen() {
	[ -n "$listen_pid" ] || return 0
	kill -INT "$listen_pid" 2> /dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$listen_pid" 2> /dev/null || break
		sleep 1
	done
	kill -KILL "$listen_pid" 2> /dev/null
	wait "$listen_pid" 2> /dev/null
	listen_pid=
}
finish() {
	stop_listen
	for f in create.txt send-a.txt send-b.txt listen.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m5/$f"
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

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/GroupTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/$2.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$2.log" 2>&1 || status=$?
	tail -n 150 "$out/$2.log" > "$RESULTS/m5/$2.tail.txt"
	export_attachments "$work/$2.xcresult" "$out/shots" "$RESULTS/m5" m5- > /dev/null 2>&1 || true
	return "$status"
}

line=$(wait_for_log 'directory: identity created' 5) || fail m5-create "no identity of the app in the server log"
app_id=$(printf '%s' "$line" | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
nonce=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
group_name="CI group $nonce"
inbound="M5 from the CLI $nonce"
reply="M5 reply from iOS $nonce"
app_group_name="iOS group $nonce"
app_text="M5 from iOS $nonce"
cli_reply="M5 answer from the CLI $nonce"
mids=""
log_start=$(date '+%Y-%m-%d %H:%M:%S')

stage m5-create
if ! "$cli" group create -identity "$profile" -members "$app_id" -name "$group_name" > "$out/create.txt" 2>&1; then
	tail -n 20 "$out/create.txt"
	fail m5-create "cli group create failed (m5/create.txt)"
fi
group=$(sed -n 's/^created group \([0-9A-Z]\{8\}\/[0-9a-f]\{16\}\) .*/\1/p' "$out/create.txt" | head -n 1)
[ -n "$group" ] || fail m5-create "group create named no group"
for m in $(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id in group .*/\1/p" "$out/create.txt"); do mids="$mids $m"; done
[ "$(printf '%s\n' $mids | grep -c .)" = 3 ] || fail m5-create "not three group state messages (m5/create.txt)"
printf '%s\n%s\n' "$group" "$group_name" > "$SRV/m5-group"
record m5-create PASS "group $group \"$group_name\", member $app_id"

stage m5-send
if ! "$cli" send -identity "$profile" -group "$group" -text "$inbound" > "$out/send-a.txt" 2>&1; then
	tail -n 20 "$out/send-a.txt"
	fail m5-send "cli send -group failed (m5/send-a.txt)"
fi
m=$(grep -F -- " to $app_id in group $group" "$out/send-a.txt" | sed -n 's/^sent \([0-9a-f]\{16\}\) .*/\1/p' | head -n 1)
[ -n "$m" ] || fail m5-send "send named no message to $app_id in group $group"
mids="$mids $m"
record m5-send PASS "message $m: \"$inbound\""

start_listen

stage m5-test-in
if TEST_RUNNER_M5_GROUP_NAME="$group_name" TEST_RUNNER_M5_INBOUND="$inbound" TEST_RUNNER_M5_REPLY="$reply" \
	run_test testAnswerInTheCLIGroup group-a; then
	record m5-test-in PASS "the app showed the group's text and answered in it"
else
	record m5-test-in FAIL "xcodebuild test failed (m5/group-a.tail.txt)"
fi

stage m5-reply
if wait_for_text "$out/listen.txt" "in group $group: $reply" 60; then
	record m5-reply PASS "$(grep -F -- "$reply" "$out/listen.txt" | head -n 1 | cut -c1-200)"
else
	record m5-reply FAIL "the CLI did not receive \"$reply\" in group $group (m5/listen.txt)"
fi

stage m5-test-create
if TEST_RUNNER_M5_APP_GROUP_NAME="$app_group_name" TEST_RUNNER_M5_APP_TEXT="$app_text" \
	run_test testCreateGroupWithTheCLI group-b; then
	record m5-test-create PASS "the app created \"$app_group_name\" with the CLI and wrote in it"
else
	record m5-test-create FAIL "xcodebuild test failed (m5/group-b.tail.txt)"
fi

stage m5-app-group
group2=
if wait_for_text "$out/listen.txt" "$app_text" 60; then
	group2=$(grep -F -- "$app_text" "$out/listen.txt" | sed -n "s/.* in group \($app_id\/[0-9a-f]\{16\}\): .*/\1/p" | head -n 1)
fi
if [ -n "$group2" ] && grep -F -- "in group $group2: group setup, members $cli_id" "$out/listen.txt" > /dev/null &&
	grep -F -- "in group $group2: group name \"$app_group_name\"" "$out/listen.txt" > /dev/null; then
	record m5-app-group PASS "group $group2: setup, name and \"$app_text\" at the CLI"
else
	record m5-app-group FAIL "the CLI did not get the app's group's setup, name and text (m5/listen.txt)"
fi

stop_listen

stage m5-cli-answer
if [ -n "$group2" ] && "$cli" send -identity "$profile" -group "$group2" -text "$cli_reply" > "$out/send-b.txt" 2>&1; then
	m=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id in group .*/\1/p" "$out/send-b.txt" | head -n 1)
	if [ -n "$m" ]; then
		mids="$mids $m"
		record m5-cli-answer PASS "message $m in group $group2"
	else
		record m5-cli-answer FAIL "send named no message to $app_id (m5/send-b.txt)"
	fi
else
	record m5-cli-answer FAIL "no group of the app to answer in, or cli send failed (m5/send-b.txt)"
fi

stage m5-test-see
if TEST_RUNNER_M5_APP_GROUP_NAME="$app_group_name" TEST_RUNNER_M5_CLI_REPLY="$cli_reply" \
	run_test testSeeTheCLIAnswer group-c; then
	record m5-test-see PASS "the app showed the CLI's answer in its group"
else
	record m5-test-see FAIL "xcodebuild test failed (m5/group-c.tail.txt)"
fi

stage m5-relay
total=0
done_count=0
for m in $mids; do
	total=$((total + 1))
	if wait_for_log 'chatserver: message delivered' 20 "message_id=$m" > /dev/null &&
		wait_for_log 'chatserver: message acknowledged by the receiver' 20 "message_id=$m" > /dev/null; then
		done_count=$((done_count + 1))
	fi
done
if [ "$total" = 5 ] && [ "$done_count" = 5 ]; then
	record m5-relay PASS "5 of the CLI's group messages delivered to and acknowledged by the app"
else
	record m5-relay FAIL "$done_count of $total of the CLI's group messages delivered and acknowledged (want 5 of 5)"
fi
flags=$( (tail -c +"$(($(cat "$SRV/log.offset") + 1))" "$SRV/server.log" 2> /dev/null || true) |
	grep -F 'chatserver: message accepted' | grep -F "sender=$app_id" | grep -F "receiver=$cli_id" |
	sed -n 's/.* flags=\(0x[0-9a-f]*\).*/\1/p' | sort | uniq -c | tr -s ' \n' ' ')
record m5-app-flags INFO "the app's messages to the CLI, by flags:${flags:- none}"

xcrun simctl spawn "$udid" log show --start "$log_start" --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema"' > "$out/app-oslog.txt" 2>&1 || true
grep -E 'ForwardSecurity|group(Setup|Name|Text)|GroupManager|Group' "$out/app-oslog.txt" | tail -n 600 | cut -c1-400 \
	> "$RESULTS/m5/app-group-log.txt" || true
shot m5-09-final

failed=$(failing_stages "$M5_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 5: every stage passed"
