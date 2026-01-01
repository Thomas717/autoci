#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m18"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m18"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

finish() {
	[ -f "$out/send.txt" ] && cp "$out/send.txt" "$RESULTS/m18/send.txt"
	(since "${m18_start:-0}" 'chatserver: ' | grep -E 'message (accepted|delivered|acknowledged by the receiver)|queue drained|client (dis)?connected' |
		sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m18/chat-lines.txt") 2> /dev/null || true
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
wait_since() {
	local off=$1 end=$(($(date +%s) + $2)) line
	shift 2
	while :; do
		line=$(since "$off" "$@" | tail -n 1)
		if [ -n "$line" ]; then
			printf '%s\n' "$line"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}
m18_start=$(offset)

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/QueueTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m18-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m18/$1.tail.txt"
	export_attachments "$work/m18-$1.xcresult" "$out/shots" "$RESULTS/m18" m18- > /dev/null 2>&1 || true
	return "$status"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m18-offline "no identity of the app in the server log"
nonce=$(test_nonce)

stage m18-offline
o=$(offset)
xcrun simctl terminate "$udid" "$APP_BUNDLE_ID" > /dev/null 2>&1 || true
if line=$(wait_since "$o" 60 'chatserver: client disconnected' "identity=$app_id"); then
	record m18-offline PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160)"
else
	fail m18-offline "no disconnect of $app_id within 60 s of ending the app"
fi
sleep 3

stage m18-queued
o=$(offset)
texts=()
ids=()
for n in 1 2 3; do
	text="M18 queued $n of 3 $nonce"
	if ! "$cli" send -identity "$profile" -to "$app_id" -text "$text" >> "$out/send.txt" 2>&1; then
		tail -n 5 "$out/send.txt"
		fail m18-queued "send $n failed (m18/send.txt)"
	fi
	texts+=("$text")
	ids+=("$(grep -F 'sent ' "$out/send.txt" | tail -n 1 | awk '{print $2}')")
	sleep 1
done
queued=0
for id in "${ids[@]}"; do
	line=$(since "$o" 'chatserver: message accepted' "message_id=$id" | grep -F "receiver=$app_id" | tail -n 1)
	case $line in
	*receiver_connections=0*) queued=$((queued + 1)) ;;
	esac
done
delivered=$(since "$o" 'chatserver: message delivered' "receiver=$app_id" | grep -cF "sender=$cli_id" || true)
if [ "$queued" = 3 ] && [ "${delivered:-0}" = 0 ]; then
	record m18-queued PASS "3 texts accepted for $app_id with no connection of its own, none delivered: ${ids[*]}"
else
	record m18-queued FAIL "$queued of 3 accepted with no connection of the app's, $delivered delivered (m18/chat-lines.txt)"
fi

o=$(offset)
xcrun simctl launch "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US > /dev/null 2>&1 || true
stage m18-test
joined=$(printf '%s|' "${texts[@]}")
if TEST_RUNNER_M18_TEXTS="${joined%|}" run_test testSeeTheQueuedTexts; then
	record m18-test PASS "after the relaunch the CLI's chat shows the 3 queued texts, in order"
else
	record m18-test FAIL "xcodebuild test failed (m18/testSeeTheQueuedTexts.tail.txt, m18/m18-02-order.txt)"
fi
stage m18-drained
line=$(since "$o" 'chatserver: queue drained' "identity=$app_id" | awk '{
	n = 0; if (match($0, / sent=[0-9]+/)) n = substr($0, RSTART + 6, RLENGTH - 6) + 0
	if (best == "" || n > max) { best = $0; max = n }
} END { if (best != "") print best }')
sent=$(printf '%s' "$line" | sed -n 's/.* sent=\([0-9]*\).*/\1/p')
if [ -n "$sent" ] && [ "$sent" -ge 3 ]; then
	record m18-drained PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160)"
else
	record m18-drained FAIL "no \"queue drained\" of $app_id with sent >= 3 since the relaunch (got: ${line:-none})"
fi
stage m18-acked
acked=0
for id in "${ids[@]}"; do
	[ -n "$(since "$o" 'chatserver: message acknowledged by the receiver' "message_id=$id" | grep -F "receiver=$app_id")" ] &&
		acked=$((acked + 1))
done
if [ "$acked" = 3 ]; then
	record m18-acked PASS "the app acknowledged the 3 queued texts"
else
	record m18-acked FAIL "the app acknowledged $acked of the 3 queued texts (m18/chat-lines.txt)"
fi
shot m18-09-final

failed=$(failing_stages "$M18_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 18: every stage passed"
