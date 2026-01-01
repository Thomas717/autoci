#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m30"
work="$RUNNER_TEMP/m2-driver"
cli=$(cat "$SRV/cli.path")
profile="$SEC/cli.json"
pictures="$out/pictures"
lat=46.948
lon=7.4474
mkdir -p "$out/shots" "$RESULTS/m30" "$pictures"
chmod 700 "$pictures"
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
	stop_bg "$listen_pid"
	listen_pid=
	geo_reset
	for f in cli.txt geo.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m30/$f"
	done
	(since "${m30_start:-0}" 'component=blob' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m30/blob-lines.txt") 2> /dev/null || true
	(since "${m30_start:-0}" 'chatserver: ' | grep -E 'message (accepted|delivered|acknowledged by the receiver)' |
		sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m30/chat-lines.txt") 2> /dev/null || true
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
	local off=$1 end=$(($(date +%s) + $2)) count=$3 lines
	shift 3
	while :; do
		lines=$(since "$off" "$@")
		if [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ge "$count" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && { [ -n "$lines" ] && printf '%s\n' "$lines"; return 1; }
		sleep 2
	done
}
m30_start=$(offset)
short() { printf '%s' "$1" | sed 's/^time=[^ ]* //' | cut -c1-200; }
ids_of() { sed -n 's/.* id=\([0-9a-f]\{16\}\)$/\1/p'; }
refs_of() { sed -n 's/.* blob_ref=\([^ ]*\).*/\1/p'; }

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
	"$cli" listen -identity "$profile" -save-pictures "$pictures" >> "$out/cli.txt" 2>&1 3>&- &
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

cli_run() {
	local m
	SENT=
	SENT_LINE=
	listen_stop
	m=$(mark)
	"$cli" "$@" >> "$out/cli.txt" 2>&1
	SENT_LINE=$(tail -n +"$((m + 1))" "$out/cli.txt" | grep -E "^sent [0-9a-f]{16} to $app_id in group $group: " | tail -n 1)
	SENT=$(tail -n +"$((m + 1))" "$out/cli.txt" | grep -E "^sent [0-9a-f]{16} to $app_id in group $group: " |
		sed -n 's/^sent \([0-9a-f]\{16\}\) .*/\1/p' | tr '\n' ' ')
	listen_start || echo "::warning::listen did not say it listens"
	[ -n "$SENT" ]
}

run_test() {
	local status=0
	rm -rf "$work/m30-$1.xcresult"
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/MemberGroupTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m30-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m30/$1.tail.txt"
	export_attachments "$work/m30-$1.xcresult" "$out/shots" "$RESULTS/m30" m30- > /dev/null 2>&1 || true
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
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m30-binaries "no identity of the app in the server log"
nonce=$(test_nonce)
name="M30 group $nonce"
renamed="M30 renamed $nonce"
poll_title="M30 poll $nonce"
choice_a="Left $nonce"
choice_b="Right $nonce"
group=
cli_sent=""
app_ids=""

relaunch

stage m30-binaries
gap=$(cli_flags_gap group rename -- -group -name)
[ -n "$gap" ] || gap=$(cli_flags_gap group picture -- -group -file -delete)
[ -n "$gap" ] || gap=$(cli_flags_gap send -- -location -poll-vote -poll-choices)
[ -n "$gap" ] || gap=$(cli_flags_gap listen -- -save-pictures)
[ -n "$gap" ] || gap=$(cli_negative_choices_gap)
[ -z "$gap" ] || fail m30-binaries "$gap: the binaries predate the CLI of the server repository's 5498363; rebuild server/ (tools/update-server-binary.sh; docs/HOW-IT-WORKS.md, milestones 27 to 30)"
record m30-binaries PASS "threema-cli renames a group and sets its picture, votes and sends locations in a group, and saves pictures"

stage m30-create
if ! "$cli" group create -identity "$profile" -members "$app_id" -name "$name" >> "$out/cli.txt" 2>&1; then
	tail -n 10 "$out/cli.txt"
	fail m30-create "cli group create failed (m30/cli.txt)"
fi
group=$(sed -n 's/^created group \([0-9A-Z]\{8\}\/[0-9a-f]\{16\}\) .*/\1/p' "$out/cli.txt" | tail -n 1)
[ -n "$group" ] || fail m30-create "group create named no group"
for m in $(grep -E "^sent [0-9a-f]{16} to $app_id in group $group: " "$out/cli.txt" | sed -n 's/^sent \([0-9a-f]\{16\}\) .*/\1/p'); do
	cli_sent="$cli_sent $m"
done
record m30-create PASS "group $group \"$name\", the app $app_id its member ($(printf '%s\n' $cli_sent | grep -c .) messages)"
stage m30-listen
if listen_start; then
	record m30-listen PASS "the CLI $cli_id listens and saves pictures"
else
	fail m30-listen "listen did not start (m30/cli.txt)"
fi

stage m30-test-see
if TEST_RUNNER_M30_GROUP="$name" run_test testSeeGroup; then
	record m30-test-see PASS "the chat \"$name\" opens"
else
	record m30-test-see FAIL "xcodebuild test failed (m30/testSeeGroup.tail.txt)"
fi
quiescence_note m30

stage m30-rename
if cli_run group rename -identity "$profile" -group "$group" -name "$renamed" &&
	[ -n "$(printf '%s' "$SENT_LINE" | grep -F "group name \"$renamed\"")" ]; then
	cli_sent="$cli_sent $SENT"
	record m30-rename PASS "$(printf '%s' "$SENT_LINE" | cut -c1-200)"
else
	record m30-rename FAIL "group rename failed or sent no name (m30/cli.txt)"
fi
stage m30-test-rename
if TEST_RUNNER_M30_GROUP="$name" TEST_RUNNER_M30_RENAMED="$renamed" run_test testSeeRename; then
	record m30-test-rename PASS "the chat says it was renamed to \"$renamed\""
else
	record m30-test-rename FAIL "xcodebuild test failed (m30/testSeeRename.tail.txt)"
fi

stage m30-picture
jpg="$RUNNER_TEMP/m30-group.jpg"
make_solid_jpeg "$jpg" 0 255 0 || fail m30-picture "could not make the green JPEG (python3, sips)"
o_pic=$(offset)
if cli_run group picture -identity "$profile" -group "$group" -file "$jpg" &&
	[ -n "$(printf '%s' "$SENT_LINE" | grep -F 'profile picture set, a ')" ]; then
	cli_sent="$cli_sent $SENT"
	record m30-picture PASS "$(printf '%s' "$SENT_LINE" | cut -c1-200)"
else
	record m30-picture FAIL "group picture failed or sent no picture (m30/cli.txt)"
fi
stage m30-cli-upload
pic_ref=
if line=$(wait_since "$o_pic" 20 1 'blob: blob uploaded' "owner=$cli_id"); then
	pic_ref=$(printf '%s\n' "$line" | head -n 1 | refs_of)
	record m30-cli-upload PASS "$(short "$(printf '%s\n' "$line" | head -n 1)")"
else
	record m30-cli-upload FAIL "no upload with owner=$cli_id since group picture"
fi
stage m30-test-picture
if TEST_RUNNER_M30_RENAMED="$renamed" run_test testSeeGroupPicture; then
	record m30-test-picture PASS "\"Group picture changed\" in the chat; the details photographed (m30-05-details)"
else
	record m30-test-picture FAIL "xcodebuild test failed (m30/testSeeGroupPicture.tail.txt)"
fi
stage m30-app-fetch
if [ -n "$pic_ref" ] && line=$(wait_since "$o_pic" 60 1 'blob: blob download' "blob_ref=$pic_ref") &&
	[ -n "$(printf '%s\n' "$line" | grep -F 'outcome=served')" ]; then
	record m30-app-fetch PASS "the app's download of $pic_ref: $(short "$(printf '%s\n' "$line" | grep -F 'outcome=served' | head -n 1)")"
else
	record m30-app-fetch FAIL "no served download of the group picture's blob ${pic_ref:-?} within 60 s (m30/blob-lines.txt)"
fi
stage m30-not-done
dones=
[ -n "$pic_ref" ] && dones=$(since "$o_pic" 'blob: done handled' "blob_ref=$pic_ref" | sed '/^$/d' | head -n 1)
if [ -n "$pic_ref" ] && [ -z "$dones" ]; then
	record m30-not-done PASS "no done for the group picture's blob $pic_ref"
elif [ -n "$pic_ref" ]; then
	record m30-not-done FAIL "a done for $pic_ref, outcome=$(printf '%s' "$dones" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p'): $(short "$dones")"
else
	record m30-not-done FAIL "no blob of the group picture to check"
fi
stage m30-shown
pixels=$(colour_pixels "$out/shots/m30-05-details.png" 0 255 0)
if [ "${pixels:-0}" -ge 20000 ]; then
	record m30-shown PASS "$pixels green pixels on the group's details: its picture"
else
	record m30-shown FAIL "${pixels:-0} green pixels on m30-05-details, want 20000 (the 120 pt picture is about 100000 at 3x)"
fi

stage m30-test-poll
m=$(mark)
if TEST_RUNNER_M30_RENAMED="$renamed" TEST_RUNNER_M30_POLL="$poll_title" TEST_RUNNER_M30_CHOICE_A="$choice_a" \
	TEST_RUNNER_M30_CHOICE_B="$choice_b" run_test testGroupPoll; then
	record m30-test-poll PASS "Create Poll in the group: \"$poll_title\", \"$choice_a\", \"$choice_b\""
else
	record m30-test-poll FAIL "xcodebuild test failed (m30/testGroupPoll.tail.txt)"
fi
stage m30-cli-poll
poll=
id_a=
id_b=
if line=$(wait_after "$m" 60 "] $app_id" " in group $group: poll " "\"$poll_title\" open"); then
	poll=$(printf '%s' "$line" | sed -n 's/.*: poll \([0-9a-f]\{16\}\) ".*/\1/p')
	id_a=$(choice_id "$line" "$choice_a")
	id_b=$(choice_id "$line" "$choice_b")
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
fi
if [ -n "$poll" ] && [ -n "$id_a" ] && [ -n "$id_b" ]; then
	record m30-cli-poll PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-220)"
else
	record m30-cli-poll FAIL "the CLI printed no open poll \"$poll_title\" in $group from the app within 60 s (m30/cli.txt)"
fi
stage m30-cli-vote
if [ -n "$poll" ] && cli_run send -identity "$profile" -group "$group" -poll-vote "$app_id/$poll" -poll-choices "$id_a=1,$id_b=0"; then
	cli_sent="$cli_sent $SENT"
	record m30-cli-vote PASS "$(printf '%s' "$SENT_LINE" | cut -c1-200)"
else
	record m30-cli-vote FAIL "no poll to vote on, or send -group -poll-vote failed (m30/cli.txt)"
fi
stage m30-test-voted
m=$(mark)
if TEST_RUNNER_M30_RENAMED="$renamed" TEST_RUNNER_M30_POLL="$poll_title" TEST_RUNNER_M30_CHOICE_A="$choice_a" \
	run_test testCloseGroupPoll; then
	record m30-test-voted PASS "\"1 of 2 Participants.\", then Close Poll > OK"
else
	record m30-test-voted FAIL "xcodebuild test failed (m30/testCloseGroupPoll.tail.txt)"
fi
stage m30-cli-closed
if [ -n "$poll" ] && line=$(wait_after "$m" 60 "] $app_id" " in group $group: poll $poll " " closed, " "\"$choice_a\" (1 vote: $cli_id)"); then
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
	record m30-cli-closed PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-220)"
else
	record m30-cli-closed FAIL "the CLI printed no closed poll ${poll:-?} in $group with its vote for \"$choice_a\" (m30/cli.txt)"
fi

stage m30-geo
geo_set=true
{
	echo "## simctl privacy grant location"
	xcrun simctl privacy "$udid" grant location "$APP_BUNDLE_ID" 2>&1
	echo "exit $?"
	echo "## simctl location set $lat,$lon"
	xcrun simctl location "$udid" set "$lat,$lon" 2>&1
	echo "exit $?"
} > "$out/geo.txt"
relaunch
record m30-geo INFO "$(grep -c '^exit 0$' "$out/geo.txt") of 2 simctl commands exited 0 (m30/geo.txt); the app launched again"
stage m30-test-location
m=$(mark)
if TEST_RUNNER_M30_RENAMED="$renamed" run_test testGroupLocation; then
	record m30-test-location PASS "Add Attachments > Send Location > Send, in the group ($(head -n 1 "$RESULTS/m30/m30-10-how.txt" 2> /dev/null))"
else
	record m30-test-location FAIL "xcodebuild test failed (m30/testGroupLocation.tail.txt)"
fi
stage m30-cli-location
if line=$(wait_after "$m" 60 "] $app_id" " in group $group: location "); then
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
	record m30-cli-location PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-200)"
else
	record m30-cli-location FAIL "the CLI printed no location in $group from the app within 60 s (m30/cli.txt)"
fi

stage m30-test-leave
m=$(mark)
if TEST_RUNNER_M30_RENAMED="$renamed" run_test testLeave; then
	record m30-test-leave PASS "Leave Group > Leave Group: \"You have left the group.\""
else
	record m30-test-leave FAIL "xcodebuild test failed (m30/testLeave.tail.txt)"
fi
stage m30-left
if line=$(wait_after "$m" 60 "] $app_id" " in group $group: left the group") &&
	wait_after "$m" 20 "group $group: $app_id left, members now none" > /dev/null; then
	app_ids="$app_ids $(printf '%s' "$line" | ids_of)"
	record m30-left PASS "$(printf '%s' "$line" | sed 's/^\[[^]]*\] //' | cut -c1-160); \"$app_id left, members now none\""
else
	record m30-left FAIL "the CLI printed no leave of the app in $group, or did not take it off the members (m30/cli.txt)"
fi

stage m30-relay
app_ids=$(printf '%s\n' $app_ids | sed '/^$/d' | sort -u | tr '\n' ' ')
cli_sent=$(printf '%s\n' $cli_sent | sed '/^$/d' | sort -u | tr '\n' ' ')
if [ -n "$app_ids" ] && [ -n "$cli_sent" ] && to_cli=$(relayed_count "$m30_start" 30 "$app_id" "$cli_id" $app_ids) &&
	to_app=$(relayed_count "$m30_start" 30 "$cli_id" "$app_id" $cli_sent); then
	record m30-relay PASS "the creator's setup, name, pictures and vote: $to_app delivered and acknowledged by the app; the app's poll, close, location and leave: $to_cli accepted and acknowledged by the CLI"
else
	record m30-relay FAIL "the CLI's: ${to_app:-${cli_sent:-no IDs}}; the app's: ${to_cli:-${app_ids:-no IDs}} (m30/chat-lines.txt)"
fi
record m30-flags INFO "the app's: $(accepted_flags "$m30_start" "$app_id" "$cli_id" $app_ids); the CLI's: $(accepted_flags "$m30_start" "$cli_id" "$app_id" $cli_sent)"
geo_reset
relaunch
record m30-geo-reset INFO "$(grep -c '^exit 0$' "$out/geo.txt") of 4 simctl location and privacy commands exited 0 (m30/geo.txt); the app launched again"
shot m30-19-final

failed=$(failing_stages "$M30_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 30: every stage passed"
