#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m29"
work="$RUNNER_TEMP/m2-driver"
cli=$(cat "$SRV/cli.path")
profile="$SEC/cli.json"
lat=46.948
lon=7.4474
mkdir -p "$out/shots" "$RESULTS/m29"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

listen_pid=
geo_set=false
geo_reset_done=false
geo_reset() {
	[ "$geo_set" = true ] && [ "$geo_reset_done" = false ] || return 0
	geo_reset_done=true
	{
		echo "## simctl location clear"
		xcrun simctl location "$udid" clear 2>&1
		echo "exit $?"
		echo "## simctl privacy reset location"
		xcrun simctl privacy "$udid" reset location "$APP_BUNDLE_ID" 2>&1
		echo "exit $?"
	} >> "$out/geo.txt"
}
stop_bg() {
	local pid=$1
	[ -n "$pid" ] || return 0
	kill -INT "$pid" 2> /dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$pid" 2> /dev/null || break
		sleep 1
	done
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	sleep 1
}
finish() {
	load_sampler_stop
	stop_bg "$listen_pid"
	listen_pid=
	geo_reset
	for f in cli.txt geo.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m29/$f"
	done
	(since "${m29_start:-0}" 'chatserver: ' | grep -E 'message (accepted|delivered|acknowledged by the receiver)' |
		sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m29/chat-lines.txt") 2> /dev/null || true
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
m29_start=$(offset)
ids_of() { sed -n 's/.* id=\([0-9a-f]\{16\}\)$/\1/p'; }

mark() {
	local n
	n=$(wc -l 2> /dev/null < "$out/cli.txt" | tr -d ' ')
	echo "${n:-0}"
}
wait_after() {
	local m=$1 end=$(($(date +%s) + $2)) lines text
	shift 2
	while :; do
		lines=$(tail -n +"$((m + 1))" "$out/cli.txt" 2> /dev/null || true)
		for text in "$@"; do
			lines=$(printf '%s\n' "$lines" | grep -F -- "$text" || true)
		done
		lines=$(printf '%s\n' "$lines" | sed '/^$/d' | head -n 1)
		if [ -n "$lines" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

listen_start() {
	local before now
	before=$(grep -c 'listening as' "$out/cli.txt" 2> /dev/null)
	"$cli" listen -identity "$profile" >> "$out/cli.txt" 2>&1 3>&- &
	listen_pid=$!
	for _ in $(seq 1 30); do
		now=$(grep -c 'listening as' "$out/cli.txt" 2> /dev/null)
		[ "${now:-0}" -gt "${before:-0}" ] && return 0
		sleep 2
	done
	return 1
}
listen_stop() {
	stop_bg "$listen_pid"
	listen_pid=
}

cli_send() {
	local m
	SENT=
	SENT_LINE=
	listen_stop
	m=$(mark)
	"$cli" send -identity "$profile" -to "$app_id" "$@" >> "$out/cli.txt" 2>&1
	SENT_LINE=$(tail -n +"$((m + 1))" "$out/cli.txt" | grep -E "^sent [0-9a-f]{16} to $app_id: " | head -n 1)
	SENT=$(printf '%s' "$SENT_LINE" | sed -n 's/^sent \([0-9a-f]\{16\}\) .*/\1/p')
	listen_start || echo "::warning::listen did not say it listens"
	[ -n "$SENT" ]
}

run_test() {
	local status=0
	rm -rf "$work/m29-$1.xcresult"
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/PollLocationTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m29-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m29/$1.tail.txt"
	export_attachments "$work/m29-$1.xcresult" "$out/shots" "$RESULTS/m29" m29- > /dev/null 2>&1 || true
	[ "$status" = 0 ] || relaunch
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 5
}

choice_id() { printf '%s' "$1" | sed -n "s/.* \(-\{0,1\}[0-9][0-9]*\) \"$2\".*/\1/p"; }

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m29-binaries "no identity of the app in the server log"
nonce=$(test_nonce)
poll_title="M29 poll $nonce"
choice_a="Red $nonce"
choice_b="Blue $nonce"
cli_title="M29 CLI poll $nonce"
cli_yes="Yes $nonce"
cli_no="No $nonce"
place="M29 place $nonce"
app_ids=""
cli_sent=""

relaunch

stage m29-binaries
gap=$(cli_flags_gap send -- -location -location-name -location-address -poll-title -poll-choice -poll-vote -poll-choices -poll-close)
[ -n "$gap" ] || gap=$(cli_negative_choices_gap)
[ -z "$gap" ] || fail m29-binaries "$gap: the binaries predate the CLI of the server repository's 5498363; rebuild server/ (tools/update-server-binary.sh; docs/HOW-IT-WORKS.md, milestones 27 to 30)"
record m29-binaries PASS "threema-cli sends locations, polls, votes and a poll's close"

stage m29-listen
if listen_start; then
	record m29-listen PASS "the CLI peer $cli_id listens"
else
	tail -n 10 "$out/cli.txt"
	fail m29-listen "listen did not start (m29/cli.txt)"
fi

load_sampler_start m29-load "$RESULTS/m29/load.txt" 900

stage m29-test-poll
m=$(mark)
if TEST_RUNNER_M29_POLL="$poll_title" TEST_RUNNER_M29_CHOICE_A="$choice_a" TEST_RUNNER_M29_CHOICE_B="$choice_b" \
	run_test testCreatePoll; then
	record m29-test-poll PASS "Create Poll: \"$poll_title\", \"$choice_a\", \"$choice_b\" sent"
else
	record m29-test-poll FAIL "xcodebuild test failed (m29/testCreatePoll.tail.txt)"
fi
quiescence_note m29
stage m29-cli-poll
poll=
id_a=
id_b=
if line=$(wait_after "$m" 60 "] $app_id" ": poll " "\"$poll_title\" open"); then
	poll=$(printf '%s' "$line" | sed -n 's/.*: poll \([0-9a-f]\{16\}\) ".*/\1/p')
	id_a=$(choice_id "$line" "$choice_a")
	id_b=$(choice_id "$line" "$choice_b")
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
fi
if [ -n "$poll" ] && [ -n "$id_a" ] && [ -n "$id_b" ]; then
	record m29-cli-poll PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-220)"
else
	record m29-cli-poll FAIL "the CLI printed no open poll \"$poll_title\" with both choices from the app within 60 s (m29/cli.txt)"
fi

stage m29-cli-vote
if [ -n "$poll" ] && cli_send -poll-vote "$app_id/$poll" -poll-choices "$id_a=1,$id_b=0"; then
	cli_sent="$cli_sent $SENT"
	record m29-cli-vote PASS "$(printf '%s' "$SENT_LINE" | cut -c1-200)"
else
	record m29-cli-vote FAIL "no poll to vote on, or the CLI's send -poll-vote failed (m29/cli.txt)"
fi
stage m29-test-close
m=$(mark)
if TEST_RUNNER_M29_POLL="$poll_title" TEST_RUNNER_M29_CHOICE_A="$choice_a" run_test testCloseAfterVote; then
	record m29-test-close PASS "\"1 of 2 Participants.\", then Close Poll > OK; the row says Closed, most votes for \"$choice_a\""
else
	record m29-test-close FAIL "xcodebuild test failed (m29/testCloseAfterVote.tail.txt)"
fi
stage m29-cli-closed
if [ -n "$poll" ] && line=$(wait_after "$m" 60 "] $app_id" ": poll $poll " " closed, " "\"$choice_a\" (1 vote: $cli_id)"); then
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
	record m29-cli-closed PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-220)"
else
	last=$(tail -n +"$((m + 1))" "$out/cli.txt" | grep -F ": poll ${poll:-?} " | tail -n 1 | cut -c1-160)
	record m29-cli-closed FAIL "the CLI printed no closed poll ${poll:-?} with the vote of $cli_id for \"$choice_a\"${last:+; last: $last}"
fi

stage m29-cli-create
cli_poll=
cli_yes_id=
cli_no_id=
if cli_send -poll-title "$cli_title" -poll-choice "$cli_yes" -poll-choice "$cli_no"; then
	cli_sent="$cli_sent $SENT"
	cli_poll=$(printf '%s' "$SENT_LINE" | sed -n 's/.*: poll \([0-9a-f]\{16\}\) ".*/\1/p')
	cli_yes_id=$(choice_id "$SENT_LINE" "$cli_yes")
	cli_no_id=$(choice_id "$SENT_LINE" "$cli_no")
fi
if [ -n "$cli_poll" ] && [ -n "$cli_no_id" ]; then
	record m29-cli-create PASS "$(printf '%s' "$SENT_LINE" | cut -c1-220)"
else
	record m29-cli-create FAIL "the CLI's send -poll-title failed or named no poll (m29/cli.txt)"
fi
stage m29-test-vote
m=$(mark)
if TEST_RUNNER_M29_CLI_POLL="$cli_title" TEST_RUNNER_M29_CLI_CHOICE="$cli_no" run_test testVoteOnCLIPoll; then
	record m29-test-vote PASS "the CLI's poll > \"$cli_no\" > the confirmation: \"You voted for $cli_no.\""
else
	record m29-test-vote FAIL "xcodebuild test failed (m29/testVoteOnCLIPoll.tail.txt)"
fi
stage m29-app-vote
if [ -n "$cli_poll" ] && line=$(wait_after "$m" 60 "] $app_id" ": poll vote for $cli_id/$cli_poll: ") &&
	[ -n "$(printf '%s' "$line" | grep -E "[:,] $cli_no_id=1(,| )")" ] &&
	wait_after "$m" 20 "poll $cli_poll: vote of $app_id recorded" > /dev/null; then
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
	record m29-app-vote PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-200); recorded"
else
	refused=$(tail -n +"$((m + 1))" "$out/cli.txt" | grep -F "threema-cli: poll ${cli_poll:-?}" | tail -n 1 | cut -c1-160)
	record m29-app-vote FAIL "the CLI printed no recorded vote of the app for \"$cli_no\" (${cli_no_id:-?}=1)${refused:+; $refused} (m29/cli.txt)"
fi
stage m29-cli-close
if [ -n "$cli_poll" ] && cli_send -poll-close "$cli_poll" &&
	[ -n "$(printf '%s' "$SENT_LINE" | grep -F " closed, " | grep -F "\"$cli_no\" (1 vote: $app_id)")" ]; then
	cli_sent="$cli_sent $SENT"
	record m29-cli-close PASS "$(printf '%s' "$SENT_LINE" | cut -c1-220)"
else
	[ -n "${SENT:-}" ] && cli_sent="$cli_sent $SENT"
	record m29-cli-close FAIL "the CLI's close of ${cli_poll:-its poll} failed or carries no vote of the app for \"$cli_no\": ${SENT_LINE:-nothing sent}"
fi
stage m29-test-closed
if TEST_RUNNER_M29_CLI_POLL="$cli_title" TEST_RUNNER_M29_CLI_CHOICE="$cli_no" run_test testSeeClosedCLIPoll; then
	record m29-test-closed PASS "the CLI's poll: Closed, most votes for \"$cli_no\""
else
	record m29-test-closed FAIL "xcodebuild test failed (m29/testSeeClosedCLIPoll.tail.txt)"
fi
load_sampler_stop -

stage m29-geo
geo_set=true
{
	echo "## simctl privacy grant location"
	xcrun simctl privacy "$udid" grant location "$APP_BUNDLE_ID" 2>&1
	granted=$?
	echo "exit $granted"
	echo "## simctl location set $lat,$lon"
	xcrun simctl location "$udid" set "$lat,$lon" 2>&1
	located=$?
	echo "exit $located"
} > "$out/geo.txt"
relaunch
if [ "$granted" = 0 ] && [ "$located" = 0 ]; then
	record m29-geo PASS "the app may use the location, the simulator is at $lat,$lon; the app launched again"
else
	record m29-geo FAIL "simctl privacy grant location exit $granted, simctl location set exit $located (m29/geo.txt)"
fi
stage m29-test-location
m=$(mark)
if run_test testSendLocation; then
	record m29-test-location PASS "Add Attachments > Send Location > Send ($(head -n 1 "$RESULTS/m29/m29-11-how.txt" 2> /dev/null))"
else
	record m29-test-location FAIL "xcodebuild test failed (m29/testSendLocation.tail.txt)"
fi
stage m29-cli-location
loc=
if line=$(wait_after "$m" 60 "] $app_id" ": location "); then
	loc=$(printf '%s' "$line" | sed -n 's/.*: location \(-\{0,1\}[0-9.]*,-\{0,1\}[0-9.]*\).*/\1/p')
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
	record m29-cli-location PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-200)"
else
	record m29-cli-location FAIL "the CLI printed no location from the app within 60 s (m29/cli.txt)"
fi
stage m29-coords
how=$(head -n 1 "$RESULTS/m29/m29-11-how.txt" 2> /dev/null)
if [ -n "$loc" ] && awk -v p="$loc" -v la="$lat" -v lo="$lon" 'BEGIN {
	split(p, c, ","); d1 = c[1] - la; d2 = c[2] - lo
	if (d1 < 0) d1 = -d1
	if (d2 < 0) d2 = -d2
	exit !(d1 <= 0.0005 && d2 <= 0.0005) }'; then
	record m29-coords PASS "$loc, within 0.0005 degrees of the simulator's $lat,$lon${how:+ ($how)}"
else
	record m29-coords FAIL "the app sent ${loc:-no location}, not within 0.0005 degrees of $lat,$lon${how:+ ($how; a dropped pin is where the map was pressed)}"
fi

stage m29-cli-send-location
if cli_send -location "$lat,$lon" -location-name "$place" -location-address "Bundesplatz 3"; then
	cli_sent="$cli_sent $SENT"
	record m29-cli-send-location PASS "$(printf '%s' "$SENT_LINE" | cut -c1-200)"
else
	record m29-cli-send-location FAIL "the CLI's send -location failed (m29/cli.txt)"
fi
stage m29-test-see-location
if TEST_RUNNER_M29_PLACE="$place" run_test testSeeCLILocation; then
	record m29-test-see-location PASS "the chat shows \"$place\", which opens the location"
else
	record m29-test-see-location FAIL "xcodebuild test failed (m29/testSeeCLILocation.tail.txt)"
fi

stage m29-relay
app_ids=$(printf '%s\n' $app_ids | sed '/^$/d' | sort -u | tr '\n' ' ')
if [ -n "$app_ids" ] && [ -n "$cli_sent" ] && to_cli=$(relayed_count "$m29_start" 30 "$app_id" "$cli_id" $app_ids) &&
	to_app=$(relayed_count "$m29_start" 30 "$cli_id" "$app_id" $cli_sent); then
	record m29-relay PASS "the app's poll, close, vote and location: $to_cli accepted and acknowledged by the CLI; the CLI's: $to_app delivered and acknowledged by the app"
else
	record m29-relay FAIL "the app's: ${to_cli:-${app_ids:-no IDs}}; the CLI's: ${to_app:-${cli_sent:-no IDs}} (m29/chat-lines.txt)"
fi
record m29-flags INFO "the app's: $(accepted_flags "$m29_start" "$app_id" "$cli_id" $app_ids); the CLI's: $(accepted_flags "$m29_start" "$cli_id" "$app_id" $cli_sent)"
record m29-vote-message INFO "$(head -n 1 "$RESULTS/m29/m29-04-vote-message.txt" 2> /dev/null || echo "no note from testCloseAfterVote")"
geo_reset
relaunch
record m29-geo-reset INFO "$(grep -c '^exit 0$' "$out/geo.txt") of 4 simctl location and privacy commands exited 0 (m29/geo.txt); the app launched again"
shot m29-19-final

failed=$(failing_stages "$M29_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 29: every stage passed"
