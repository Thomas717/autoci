#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m11"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
device="$SEC/cli-md.json"
uri_file="$SEC/join.uri"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m11"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

join_pid=
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
	stop_bg "$join_pid"
	stop_bg "$listen_pid"
	rm -f "$uri_file"
	for f in md-join.txt listen.txt send.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m11/$f"
	done
	(since "${m11_start:-0}" 'mediator: ' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m11/mediator-lines.txt") 2> /dev/null || true
	(since "${m11_start:-0}" 'rendezvous: ' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m11/relay-lines.txt") 2> /dev/null || true
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
m11_start=$(offset)

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
		-only-testing:"OnboardingDriverUITests/MultiDeviceTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m11/$1.tail.txt"
	export_attachments "$work/$1.xcresult" "$out/shots" "$RESULTS/m11" m11- > /dev/null 2>&1 || true
	return "$status"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m11-join-start "no identity of the app in the server log"
nonce=$(test_nonce)
outbound="M11 from iOS $nonce"
inbound="M11 from the CLI $nonce"

stage m11-join-start
rm -f "$device" "$uri_file"
"$cli" md join -license - -signature-key "$(cat "$SRV/oppf-public.key")" -out "$device" -uri "$uri_file" -stay \
	< "$SEC/license.url" > "$out/md-join.txt" 2>&1 3>&- &
join_pid=$!
for _ in $(seq 1 30); do
	[ -s "$uri_file" ] && break
	sleep 1
done
[ -s "$uri_file" ] || { tail -n 20 "$out/md-join.txt"; fail m11-join-start "md join wrote no join link (m11/md-join.txt)"; }
uri=$(head -n 1 "$uri_file" | tr -d '\r\n')
add_secret "$uri"
fragment=${uri#*#}
add_secret "$fragment"
case $uri in
threema://device-group/join#?*) record m11-join-start PASS "md join waits on the relay with its join link" ;;
*) fail m11-join-start "md join's link is not threema://device-group/join#…" ;;
esac

stage m11-test-link
o=$(offset)
if TEST_RUNNER_M11_JOIN="$fragment" run_test testStartLinking; then
	record m11-test-link PASS "the app connected to the relay and shows the emoji to compare"
else
	record m11-test-link FAIL "xcodebuild test failed (m11/testStartLinking.tail.txt)"
fi
fragment=
uri=
stage m11-test-trust
emoji=
for _ in $(seq 1 30); do
	emoji=$(sed -n 's/^  [123]\. .*(\([0-9A-Fa-f_]*\))$/\1/p' "$out/md-join.txt" | head -n 3 | tr '\n' ' ' | sed 's/ $//')
	[ "$(printf '%s' "$emoji" | wc -w | tr -d ' ')" = 3 ] && break
	sleep 2
done
if [ "$(printf '%s' "$emoji" | wc -w | tr -d ' ')" != 3 ]; then
	record m11-test-trust FAIL "md join printed no three emoji (m11/md-join.txt)"
elif labels=$(sed -n 's/^  [123]\. [^ ]*  *\(.*\) ([0-9A-Fa-f_]*)$/\1/p' "$out/md-join.txt" | head -n 3 |
	tr '\n' '|' | sed 's/|$//') &&
	TEST_RUNNER_M11_EMOJI="$emoji" TEST_RUNNER_M11_EMOJI_LABELS="$labels" run_test testTrustTheCLI; then
	record m11-test-trust PASS "the app's row $emoji tapped, the data sent, \"Device Linked Successfully\""
else
	record m11-test-trust FAIL "xcodebuild test failed (m11/testTrustTheCLI.tail.txt)"
fi

stage m11-cli-joined
if wait_for_text "$out/md-join.txt" "joined the device group of $app_id" 120; then
	record m11-cli-joined PASS "$(grep -F 'joined the device group' "$out/md-join.txt" | head -n 1 | sed 's/; saved to .*//' | cut -c1-200)"
else
	tail -n 20 "$out/md-join.txt"
	record m11-cli-joined FAIL "md join did not join the app's device group (m11/md-join.txt)"
fi

stage m11-mediator
groups=$(since "$o" 'mediator: device connected' | sed -n 's/.* device_group=\([0-9a-f]*\) device_id=\([0-9a-f]*\).*/\1 \2/p' | sort -u)
best=$(printf '%s\n' "$groups" | awk 'NF == 2 { n[$1]++ } END { for (g in n) if (n[g] > m) { m = n[g]; b = g } ; if (m) print b, m }')
if [ -n "$best" ] && [ "${best#* }" -ge 2 ]; then
	record m11-mediator PASS "device group ${best% *}…: ${best#* } devices connected"
else
	record m11-mediator FAIL "no device group with two connected devices at the mediator (m11/mediator-lines.txt)"
fi
line=$(since "$o" 'chatserver: client connected' "identity=$app_id" | grep -F 'multi_device=true' | tail -n 1)
if [ -n "$line" ]; then
	record m11-app-md INFO "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
fi

stage m11-test-send
if TEST_RUNNER_M11_TEXT="$outbound" run_test testSendWhileLinked; then
	record m11-test-send PASS "the app sent \"$outbound\" to the CLI while linked"
else
	record m11-test-send FAIL "xcodebuild test failed (m11/testSendWhileLinked.tail.txt)"
fi
stage m11-reflect
if wait_for_text "$out/md-join.txt" "$outbound" 60; then
	line=$(grep -F -- "$outbound" "$out/md-join.txt" | head -n 1)
	case $line in
	*reflected-outgoing*) record m11-reflect PASS "$(printf '%s' "$line" | cut -c1-200)" ;;
	*) record m11-reflect FAIL "the CLI's device printed the app's text, but not as reflected-outgoing: $(printf '%s' "$line" | cut -c1-160)" ;;
	esac
else
	record m11-reflect FAIL "the CLI's device did not print the app's text within 60 s (m11/md-join.txt)"
fi
stage m11-delivered
"$cli" listen -identity "$profile" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!
if wait_for_text "$out/listen.txt" "$outbound" 60; then
	record m11-delivered PASS "$(grep -F -- "$outbound" "$out/listen.txt" | head -n 1 | cut -c1-200)"
else
	record m11-delivered FAIL "the CLI's identity did not receive \"$outbound\" within 60 s (m11/listen.txt)"
fi
stop_bg "$listen_pid"
listen_pid=

if "$cli" send -identity "$profile" -to "$app_id" -text "$inbound" > "$out/send.txt" 2>&1 &&
	wait_for_text "$out/md-join.txt" "$inbound" 60; then
	record m11-incoming INFO "$(grep -F -- "$inbound" "$out/md-join.txt" | head -n 1 | cut -c1-200)"
else
	record m11-incoming INFO "the CLI's device did not print \"$inbound\" within 60 s"
fi
shot m11-09-final

failed=$(failing_stages "$M11_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 11: every stage passed"
