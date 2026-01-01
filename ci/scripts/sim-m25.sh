#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m25"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m25"
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
	for f in listen-1.txt listen-2.txt listen-3.txt send.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m25/$f"
	done
	(since "${m25_start:-0}" 'chatserver: ' | grep -E 'message (accepted|delivered|acknowledged by the receiver)|queue drained|client (dis)?connected' |
		sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m25/chat-lines.txt") 2> /dev/null || true
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
m25_start=$(offset)

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
		-only-testing:"OnboardingDriverUITests/ChatFlagsTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m25-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m25/$1.tail.txt"
	export_attachments "$work/m25-$1.xcresult" "$out/shots" "$RESULTS/m25" m25- > /dev/null 2>&1 || true
	return "$status"
}

listen_start() {
	"$cli" listen -identity "$profile" > "$out/listen-$1.txt" 2>&1 3>&- &
	listen_pid=$!
	wait_for_text "$out/listen-$1.txt" "listening as $cli_id" 60
}

accepted() {
	local want=$1 line flags
	since "$2" 'chatserver: message accepted' "sender=$app_id" | grep -F "receiver=$cli_id" | grep -F "outcome=${want#!} " |
		while IFS= read -r line; do
			flags=$(printf '%s' "$line" | sed -n 's/.* flags=\(0x[0-9a-f]*\).*/\1/p')
			[ -n "$flags" ] || continue
			if [ $((flags & 0x02)) -ne 0 ]; then
				[ "${want#!}" = "$want" ] && printf '%s\n' "$line"
			else
				[ "${want#!}" != "$want" ] && printf '%s\n' "$line"
			fi
		done
}
ids_of() { sed -n 's/.* message_id=\([0-9a-f]\{16\}\).*/\1/p'; }

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m25-listen "no identity of the app in the server log"
nonce=$(test_nonce)
typing="M25 typing $nonce"
queued_text="M25 queued $nonce"
edited_text="M25 edited $nonce"
react_text="M25 react to me $nonce"

xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 8

stage m25-listen
if listen_start 1; then
	record m25-listen PASS "the CLI peer $cli_id listens"
else
	tail -n 10 "$out/listen-1.txt"
	fail m25-listen "listen did not start (m25/listen-1.txt)"
fi

stage m25-test-typing
o=$(offset)
if TEST_RUNNER_M25_TYPING="$typing" run_test testTypeWhilePeerOnline; then
	record m25-test-typing PASS "typed in the CLI's chat without sending"
else
	record m25-test-typing FAIL "xcodebuild test failed (m25/testTypeWhilePeerOnline.tail.txt)"
fi
stage m25-offered
lines=$(accepted offered-live "$o")
seen=$(grep -E ": (typing|stopped typing) id=" "$out/listen-1.txt" | grep -F "$app_id" | head -n 1)
if [ -n "$lines" ]; then
	record m25-offered PASS "$(printf '%s\n' "$lines" | wc -l | tr -d ' ') offered live; the CLI printed: ${seen:-nothing}; $(printf '%s\n' "$lines" | head -n 1 | sed 's/^time=[^ ]* //' | cut -c1-160)"
else
	record m25-offered FAIL "no message with flag 0x02 from the app offered live to the CLI since the test started (m25/chat-lines.txt)"
fi

o=$(offset)
stop_bg "$listen_pid"
listen_pid=
wait_since "$o" 30 'chatserver: client disconnected' "identity=$cli_id" > /dev/null ||
	echo "::warning::no disconnect of the CLI logged within 30 s"
sleep 2
stage m25-test-offline
o=$(offset)
if TEST_RUNNER_M25_TYPING="$typing" TEST_RUNNER_M25_TEXT="$queued_text" run_test testTypeWhilePeerOffline; then
	record m25-test-offline PASS "typed and cleared, then sent \"$queued_text\" while the CLI was offline"
else
	record m25-test-offline FAIL "xcodebuild test failed (m25/testTypeWhilePeerOffline.tail.txt)"
fi
stage m25-dropped
sleep 3
dropped=$(accepted dropped-offline "$o")
dropped_ids=$(printf '%s\n' "$dropped" | ids_of)
if [ -n "$dropped" ]; then
	record m25-dropped PASS "$(printf '%s\n' "$dropped" | wc -l | tr -d ' ') message(s) with flag 0x02 dropped for the offline CLI: $(printf '%s' "$dropped_ids" | tr '\n' ' ')"
else
	record m25-dropped FAIL "no message with flag 0x02 from the app dropped for the offline CLI since the test started (m25/chat-lines.txt)"
fi

o_back=$(offset)
listen_start 2 || echo "::warning::listen did not say it listens"
stage m25-queued
qid=
if wait_for_text "$out/listen-2.txt" "$queued_text" 60; then
	qid=$(grep -F -- "$queued_text" "$out/listen-2.txt" | head -n 1 | sed -n 's/.* id=\([0-9a-f]\{16\}\)$/\1/p')
fi
line=
[ -n "$qid" ] && line=$(accepted '!queued' "$o" | grep -F "message_id=$qid" | tail -n 1)
if [ -n "$line" ]; then
	record m25-queued PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m25-queued FAIL "no queued message ${qid:-(the CLI printed no ID)} from the app for the CLI since the offline test (m25/chat-lines.txt)"
fi
stage m25-drained
line=
[ -n "$qid" ] && line=$(since "$o_back" 'chatserver: message delivered' "message_id=$qid" | grep -F "receiver=$cli_id" | grep -F 'queued=true' | tail -n 1)
if [ -n "$line" ]; then
	record m25-drained PASS "from the queue at the login: $(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160); listen: $(grep -F -- "$queued_text" "$out/listen-2.txt" | head -n 1 | cut -c1-120)"
else
	record m25-drained FAIL "the text ${qid:-?} was not delivered to the CLI from the queue since it listens again (m25/listen-2.txt, m25/chat-lines.txt)"
fi
stage m25-not-queued
sleep 10
typed=$(grep -E ": (typing|stopped typing) id=" "$out/listen-2.txt" | grep -F "$app_id" | head -n 1)
handed=0
for id in $dropped_ids; do
	[ -n "$(since "$o_back" 'chatserver: message delivered' "message_id=$id")" ] && handed=$((handed + 1))
done
if [ -z "$typed" ] && [ "$handed" = 0 ] && [ -n "$qid" ]; then
	record m25-not-queued PASS "the login handed over the text alone: no typing indicator printed, none of the $(printf '%s\n' "$dropped_ids" | sed '/^$/d' | wc -l | tr -d ' ') dropped delivered"
else
	record m25-not-queued FAIL "after the login: printed ${typed:-no typing}, $handed dropped message(s) delivered, text ID ${qid:-none} (m25/listen-2.txt)"
fi

stage m25-test-edit
if TEST_RUNNER_M25_TEXT="$queued_text" TEST_RUNNER_M25_EDITED="$edited_text" run_test testEdit; then
	record m25-test-edit PASS "\"$queued_text\" edited to \"$edited_text\""
else
	record m25-test-edit FAIL "xcodebuild test failed (m25/testEdit.tail.txt)"
fi
stage m25-edit
want="edit of ${qid:-none}: $edited_text"
if [ -n "$qid" ] && wait_for_text "$out/listen-2.txt" "$want" 60; then
	record m25-edit PASS "$(grep -F -- "$want" "$out/listen-2.txt" | head -n 1 | cut -c1-200)"
else
	record m25-edit FAIL "the CLI did not print \"$want\" within 60 s (m25/listen-2.txt)"
fi

stage m25-test-delete
if TEST_RUNNER_M25_EDITED="$edited_text" run_test testDeleteForEveryone; then
	record m25-test-delete PASS "\"$edited_text\" deleted for everyone"
else
	record m25-test-delete FAIL "xcodebuild test failed (m25/testDeleteForEveryone.tail.txt)"
fi
stage m25-delete
want="delete of ${qid:-none} id="
if [ -n "$qid" ] && wait_for_text "$out/listen-2.txt" "$want" 60; then
	record m25-delete PASS "$(grep -F -- "$want" "$out/listen-2.txt" | head -n 1 | cut -c1-200)"
else
	record m25-delete FAIL "the CLI did not print \"delete of ${qid:-?}\" within 60 s (m25/listen-2.txt)"
fi

stop_bg "$listen_pid"
listen_pid=
rid=
if "$cli" send -identity "$profile" -to "$app_id" -text "$react_text" > "$out/send.txt" 2>&1; then
	rid=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id\$/\1/p" "$out/send.txt" | head -n 1)
fi
listen_start 3 || echo "::warning::listen did not say it listens"
stage m25-test-react
if [ -z "$rid" ]; then
	tail -n 5 "$out/send.txt"
	record m25-test-react FAIL "the CLI's send failed (m25/send.txt)"
elif TEST_RUNNER_M25_REACT="$react_text" run_test testReact; then
	record m25-test-react PASS "a thumbs up on the CLI's \"$react_text\""
else
	record m25-test-react FAIL "xcodebuild test failed (m25/testReact.tail.txt)"
fi
stage m25-reaction
line=
if [ -n "$rid" ]; then
	end=$(($(date +%s) + 60))
	while [ -z "$line" ] && [ "$(date +%s)" -lt "$end" ]; do
		line=$(grep -F "$app_id" "$out/listen-3.txt" | grep -F ": reaction " | grep -F " to $rid id=" | head -n 1)
		[ -n "$line" ] || sleep 2
	done
fi
if [ -n "$line" ]; then
	record m25-reaction PASS "$(printf '%s' "$line" | cut -c1-200)"
else
	legacy=
	[ -n "$rid" ] && legacy=$(grep -F "delivery receipt (acknowledged) for $rid" "$out/listen-3.txt" | head -n 1)
	record m25-reaction FAIL "the CLI did not print \"reaction … to ${rid:-?}\" within 60 s${legacy:+; it got the legacy acknowledgement instead} (m25/listen-3.txt)"
fi
shot m25-09-final

failed=$(failing_stages "$M25_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 25: every stage passed"
