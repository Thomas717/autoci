#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m23"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
device="$SEC/cli-md.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m23"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

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
	stop_bg "$listen_pid"
	for f in md-send.txt md-send.err listen.txt md-devices.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m23/$f"
	done
	(since "${m23_start:-0}" 'mediator: ' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m23/mediator-lines.txt") 2> /dev/null || true
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
m23_start=$(offset)

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
		-only-testing:"OnboardingDriverUITests/LinkedDeviceTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m23-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m23/$1.tail.txt"
	export_attachments "$work/m23-$1.xcresult" "$out/shots" "$RESULTS/m23" m23- > /dev/null 2>&1 || true
	return "$status"
}

hex_bit() { [ $(($1 & $2)) -ne 0 ] 2> /dev/null; }

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m23-md-send "no identity of the app in the server log"
[ -s "$device" ] || fail m23-md-send "no device profile from milestone 11 ($SEC/cli-md.json)"
cli_dev=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("mediatorDeviceId", ""))' "$device" | tr -d '\r')
[[ $cli_dev =~ ^[0-9a-f]{16}$ ]] || fail m23-md-send "the device profile holds no mediator device ID"
group=$(since 0 'mediator: device connected' "device_id=$cli_dev" | sed -n 's/.* device_group=\([0-9a-f]*\) .*/\1/p' | tail -n 1)
[[ $group =~ ^[0-9a-f]{8}$ ]] || fail m23-md-send "no device group of the CLI's device in the server log"
nonce=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
text="M23 from the linked device $nonce"
label=${M23_DEVICE_LABEL:-Go client}

o=$(offset)
xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
line=$(wait_line "$o" 60 'mediator: device connected' "device_group=$group" "!device_id=$cli_dev") || line=
app_dev=$(printf '%s' "$line" | sed -n 's/.* device_id=\([0-9a-f]\{16\}\).*/\1/p')
if [ -z "$app_dev" ]; then
	app_dev=$(since 0 'mediator: device connected' "device_group=$group" | grep -vF "device_id=$cli_dev" |
		sed -n 's/.* device_id=\([0-9a-f]\{16\}\).*/\1/p' | tail -n 1)
fi
record m23-app-device INFO "group ${group}…: the app's device ${app_dev:-unknown}, the CLI's $cli_dev"
sleep 5

"$cli" listen -identity "$profile" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!
wait_for_text "$out/listen.txt" "listening as $cli_id" 60 || echo "::warning::the CLI peer's listen did not say it listens"
stage m23-md-send
o_send=$(offset)
if "$cli" md send -identity "$device" -to "$cli_id" -text "$text" -timeout 3m > "$out/md-send.txt" 2> "$out/md-send.err" 3>&-; then
	sent=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $cli_id (reflected)\$/\1/p" "$out/md-send.txt" | tail -n 1)
	backlog=$(grep -c '^\[' "$out/md-send.txt" || true)
	led=
	grep -qF "made this device the group's leader" "$out/md-send.err" && led="; the app was not connected, so the mediator made the CLI's device the leader"
	if [ -n "$sent" ]; then
		record m23-md-send PASS "message $sent to $cli_id, reflected and acknowledged; $backlog line(s) of backlog taken first$led"
	else
		record m23-md-send FAIL "md send exited 0 without \"sent <id> to $cli_id (reflected)\" (m23/md-send.txt)"
	fi
else
	sent=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $cli_id (reflected, sent state not mirrored)\$/\1/p" "$out/md-send.txt" | tail -n 1)
	tail -n 5 "$out/md-send.err"
	if [ -n "$sent" ]; then
		record m23-md-send FAIL "md send failed: message $sent acknowledged by the chat server, but its sent state was not mirrored (m23/md-send.err)"
	else
		record m23-md-send FAIL "md send failed (m23/md-send.err)"
	fi
fi

stage m23-peer
if wait_for_text "$out/listen.txt" "$text" 60; then
	line=$(grep -F -- "$text" "$out/listen.txt" | head -n 1)
	case $line in
	*"$app_id"*"id=${sent:-none}"*) record m23-peer PASS "$(printf '%s' "$line" | cut -c1-200)" ;;
	*) record m23-peer FAIL "the peer got the text, but not from $app_id with ID ${sent:-?}: $(printf '%s' "$line" | cut -c1-160)" ;;
	esac
else
	record m23-peer FAIL "the CLI peer did not receive \"$text\" within 60 s (m23/listen.txt)"
fi
stop_bg "$listen_pid"
listen_pid=

stage m23-test-mirrored
if TEST_RUNNER_M23_TEXT="$text" run_test testSeeTheMirroredMessage; then
	record m23-test-mirrored PASS "the app's chat with the CLI shows \"$text\" as its own message"
else
	record m23-test-mirrored FAIL "xcodebuild test failed (m23/testSeeTheMirroredMessage.tail.txt, m23/m23-01-label.txt)"
fi
stage m23-acked
acks=$(since "$o_send" 'mediator: reflected acked' "device_group=$group" | grep -vF "device_id=$cli_dev" | grep -F 'outcome=accepted')
if [ -n "$acks" ]; then
	record m23-acked PASS "$(printf '%s\n' "$acks" | wc -l | tr -d ' ') accepted ack(s) from the app's device; last: $(printf '%s\n' "$acks" | tail -n 1 | sed 's/^time=[^ ]* //' | cut -c1-160)"
else
	record m23-acked FAIL "no accepted reflected-ack from a device of ${group}… other than the CLI's since md send (m23/mediator-lines.txt)"
fi

stage m23-test-devices
o=$(offset)
if TEST_RUNNER_M23_DEVICE="$label" run_test testListDevices; then
	record m23-test-devices PASS "the linked devices page lists the CLI's device (\"$label\")"
else
	record m23-test-devices FAIL "xcodebuild test failed (m23/testListDevices.tail.txt)"
fi
stage m23-devices
line=$(since "$o" 'mediator: devices info sent' "device_group=$group" | grep -vF "device_id=$cli_dev" | tail -n 1)
n=$(printf '%s' "$line" | sed -n 's/.* devices=\([0-9]*\).*/\1/p')
if [ -n "$n" ] && [ "$n" -ge 2 ]; then
	record m23-devices PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m23-devices FAIL "no DevicesInfo with at least 2 devices sent to the app since the test started (got: ${line:-none})"
fi

stage m23-test-remove
o=$(offset)
if TEST_RUNNER_M23_DEVICE="$label" run_test testRemoveAll; then
	record m23-test-remove PASS "Edit, \"Remove All Linked Devices\", confirmed: no device listed any more"
else
	record m23-test-remove FAIL "xcodebuild test failed (m23/testRemoveAll.tail.txt)"
fi
stage m23-dropped
if line=$(wait_line "$o" 30 'mediator: device dropped' "device_group=$group" "device_id=$cli_dev"); then
	case $line in
	*"dropped_by=$cli_dev"*) record m23-dropped FAIL "the CLI's device dropped itself: $(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160)" ;;
	*) record m23-dropped PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)" ;;
	esac
else
	record m23-dropped FAIL "the mediator dropped no device $cli_dev of ${group}… since the removal (m23/mediator-lines.txt)"
fi

stage m23-test-md-off
if TEST_RUNNER_M23_DEVICE="$label" run_test testMultiDeviceOff; then
	record m23-test-md-off PASS "the page offers \"Add Device\" and lists no linked device"
else
	record m23-test-md-off FAIL "xcodebuild test failed (m23/testMultiDeviceOff.tail.txt)"
fi
stage m23-fs-back
masks=$(since "$o" 'directory: feature mask set' "identity=$app_id" | sed -n 's/.* feature_mask=\(0x[0-9a-f]*\).*/\1/p')
last=$(printf '%s\n' "$masks" | sed '/^$/d' | tail -n 1)
if [ -n "$last" ] && hex_bit "$last" 0x0040; then
	record m23-fs-back PASS "the app set its feature mask $last, forward security (0x0040) on again"
else
	record m23-fs-back FAIL "no feature mask of $app_id with forward security since the removal (got: $(printf '%s' "$masks" | tr '\n' ' '))"
fi

if "$cli" md devices -identity "$device" > "$out/md-devices.txt" 2>&1 3>&-; then
	record m23-cli-dropped INFO "md devices still works with the CLI's profile (m23/md-devices.txt)"
elif grep -qF 4115 "$out/md-devices.txt"; then
	record m23-cli-dropped INFO "md devices fails with the CLI's profile: 4115, the mediator holds no slot for the device"
else
	record m23-cli-dropped INFO "md devices fails with the CLI's profile, not with 4115 (m23/md-devices.txt)"
fi
if line=$(wait_line "$o" 60 'chatserver: client connected' "identity=$app_id" 'multi_device=false'); then
	record m23-direct INFO "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m23-direct INFO "no direct login of $app_id (multi_device=false) within 60 s of the removal"
fi
shot m23-09-final

failed=$(failing_stages "$M23_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 23: every stage passed"
