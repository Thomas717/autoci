#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" "${SERVER_PUBLIC_URL:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m28"
work="$RUNNER_TEMP/m2-driver"
cli=$(cat "$SRV/cli.path")
profile="$SEC/cli.json"
member_seat=ci-member
member_profile="$SEC/cli-member.json"
pictures="$out/pictures"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m28" "$pictures"
chmod 700 "$pictures"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

cli_pid=
member_pid=
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
	stop_bg "$cli_pid"
	stop_bg "$member_pid"
	cli_pid=
	member_pid=
	cockpit_sign_out
	rm -f "$SEC/ci-member-seat.json" "$SEC/ci-member-license.url"
	for f in cli.txt member.txt register.txt addmedia.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m28/$f"
	done
	(since "${m28_start:-0}" 'component=blob' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m28/blob-lines.txt") 2> /dev/null || true
	(since "${m28_start:-0}" 'chatserver: ' | grep -E 'message (accepted|delivered|acknowledged by the receiver)' |
		sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m28/chat-lines.txt") 2> /dev/null || true
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
m28_start=$(offset)
short() { printf '%s' "$1" | sed 's/^time=[^ ]* //' | cut -c1-200; }
ids_of() { sed -n 's/.* id=\([0-9a-f]\{16\}\)$/\1/p'; }
sizes_of() { sed -n 's/.*profile picture set, a \([0-9]*\)-byte blob.*/\1/p'; }
refs_of() { sed -n 's/.* blob_ref=\([^ ]*\).*/\1/p'; }

mark() {
	local n
	n=$(wc -l 2> /dev/null < "$out/$1.txt" | tr -d ' ')
	echo "${n:-0}"
}
after() { tail -n +"$(($2 + 1))" "$out/$1.txt" 2> /dev/null || true; }
wait_after() {
	local who=$1 m=$2 end=$(($(date +%s) + $3)) lines text
	shift 3
	while :; do
		lines=$(after "$who" "$m")
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
	local who=$1 file="$out/$1.txt" prof before now pid
	prof=$profile
	[ "$who" = member ] && prof=$member_profile
	before=$(grep -c 'listening as' "$file" 2> /dev/null)
	"$cli" listen -identity "$prof" -save-pictures "$pictures" >> "$file" 2>&1 3>&- &
	pid=$!
	if [ "$who" = member ]; then member_pid=$pid; else cli_pid=$pid; fi
	for _ in $(seq 1 30); do
		now=$(grep -c 'listening as' "$file" 2> /dev/null)
		[ "${now:-0}" -gt "${before:-0}" ] && return 0
		sleep 2
	done
	return 1
}
listen_stop() {
	if [ "$1" = member ]; then
		stop_bg "$member_pid"
		member_pid=
	else
		stop_bg "$cli_pid"
		cli_pid=
	fi
}

run_test() {
	local status=0
	rm -rf "$work/m28-$1.xcresult"
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/GroupAdminTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m28-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m28/$1.tail.txt"
	export_attachments "$work/m28-$1.xcresult" "$out/shots" "$RESULTS/m28" m28- > /dev/null 2>&1 || true
	[ "$status" = 0 ] || relaunch
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 5
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m28-binaries "no identity of the app in the server log"
nonce=$(test_nonce)
name="M28 group $nonce"
renamed="M28 renamed $nonce"
text="M28 first $nonce"
member_text="M28 hello from CI Member $nonce"
member_id=
group=

stage m28-binaries
gap=$(cli_flags_gap group leave -- -group -members)
[ -n "$gap" ] || gap=$(cli_flags_gap listen -- -save-pictures)
[ -z "$gap" ] || fail m28-binaries "$gap: the binaries predate the CLI of the server repository's 5498363; rebuild server/ (tools/update-server-binary.sh; docs/HOW-IT-WORKS.md, milestones 27 to 30)"
record m28-binaries PASS "threema-cli leaves a group as a member, and listen saves pictures"

stage m28-photos
jpg="$RUNNER_TEMP/m28-group.jpg"
make_solid_jpeg "$jpg" 0 255 255 || fail m28-photos "could not make the cyan JPEG (python3, sips)"
xcrun simctl addmedia "$udid" "$jpg" > "$out/addmedia.txt" 2>&1 || fail m28-photos "simctl addmedia failed (m28/addmedia.txt)"
xcrun simctl privacy "$udid" grant photos "$APP_BUNDLE_ID" > /dev/null 2>&1 || echo "::warning::simctl privacy grant photos failed"
relaunch
record m28-photos PASS "a cyan JPEG ($(wc -c < "$jpg" | tr -d ' ') bytes) in the library; the app launched again"

stage m28-member
cockpit_sign_in || fail m28-member "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S28)"
find_openssl > /dev/null 2>&1 || fail m28-member "no OpenSSL 3"
(umask 077 && "$OPENSSL" rand -hex 16 > "$SEC/ci-member-password.txt") || fail m28-member "openssl rand failed"
add_secret "$(cat "$SEC/ci-member-password.txt")"
(umask 077 && python3 -I - "$SEC/ci-member-password.txt" "$SEC/ci-member-seat.json" "$member_seat" <<'PY'
import json, sys
password = open(sys.argv[1]).read().strip()
json.dump({"username": sys.argv[3], "password": password,
           "profile": {"firstName": "CI", "lastName": "Member"}}, open(sys.argv[2], "w"))
PY
)
status=$(curl_tls -s -o "$COCKPIT_ANSWER" -w '%{http_code}' --cacert "$SRV/tls/ca.crt" -b "$SEC/cockpit.cookies" \
	-X POST -H @"$SEC/cockpit.csrf" -H 'Content-Type: application/json' --data @"$SEC/ci-member-seat.json" \
	"$SERVER_PUBLIC_URL/cockpit/api/users" || echo 000)
rm -f "$SEC/ci-member-seat.json"
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m28/seat-answer.json" 2> /dev/null
	fail m28-member "the cockpit answered $status to the new seat (m28/seat-answer.json)"
fi
stage m28-seat-hash
cheap_seat_hashes m28-seat-hash "$cli" "$member_seat" "$SEC/ci-member-password.txt" || true
(umask 077 && python3 -I - "$SEC/ci-member-password.txt" "$SEC/ci-member-license.url" "$SERVER_PUBLIC_URL" "$member_seat" <<'PY'
import sys
from urllib.parse import quote, urlencode
password = open(sys.argv[1]).read().strip()
query = urlencode({"server": sys.argv[3], "username": sys.argv[4], "password": password},
                  quote_via=lambda value, *_: quote(value, safe=""))
open(sys.argv[2], "w").write("threemaonprem://license?" + query + "\n")
PY
)
add_secret "$(tr -d '\r\n' < "$SEC/ci-member-license.url")"
if ! "$cli" register -license - -signature-key "$(cat "$SRV/oppf-public.key")" -nickname "CI Member" \
	-out "$member_profile" < "$SEC/ci-member-license.url" > "$out/register.txt" 2>&1; then
	tail -n 20 "$out/register.txt"
	fail m28-member "cli register on $member_seat failed (m28/register.txt)"
fi
rm -f "$SEC/ci-member-license.url"
key=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["clientKey"])' "$member_profile" | tr -d '\r')
add_secret "$key"
key=
member_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$member_profile" | tr -d '\r')
[[ $member_id =~ ^[0-9A-Z]{8}$ ]] || fail m28-member "CI Member's profile holds no identity"
metric m28_member_id "$member_id"
record m28-member PASS "CI Member $member_id on the seat $member_seat (made in the cockpit, HTTP $status)"
stage m28-member-text
if "$cli" send -identity "$member_profile" -to "$app_id" -text "$member_text" >> "$out/member.txt" 2>&1; then
	record m28-member-text PASS "$(grep -F "sent " "$out/member.txt" | tail -n 1 | cut -c1-120): \"$member_text\""
else
	tail -n 5 "$out/member.txt"
	fail m28-member-text "CI Member's send failed (m28/member.txt)"
fi

stage m28-listen
if listen_start cli && listen_start member; then
	record m28-listen PASS "the CLI $cli_id and CI Member $member_id listen and save pictures"
else
	fail m28-listen "a listen did not start (m28/cli.txt, m28/member.txt)"
fi

member_resend() {
	local said sent= how
	listen_stop member
	if said=$("$cli" send -identity "$member_profile" -to "$app_id" -text "$member_text" 2>&1); then
		sent=$(printf '%s\n' "$said" | tr -d '\r' | sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id\$/\1/p" | head -n 1)
	fi
	printf '%s\n' "$said" >> "$out/member.txt"
	listen_start member || echo "::warning::CI Member's listen did not say it listens"
	if [ -n "$sent" ]; then
		how="CI Member sent its text again, as message $sent"
	else
		how="CI Member's second send failed (m28/member.txt)"
	fi
	record m28-resend INFO "forward security: session-terminated: session $1 with $app_id (m28/member.txt) before the app showed CI Member's text: $how"
}

stage m28-test-create
m_cli=$(mark cli)
m_member=$(mark member)
TEST_RUNNER_M28_GROUP="$name" TEST_RUNNER_M28_TEXT="$text" TEST_RUNNER_M28_MEMBER_TEXT="$member_text" \
	run_test testCreateGroup &
if fs_resend_watch $! "$out/member.txt" "$app_id" "$out/testCreateGroup.log" m28-01-list member_resend; then
	record m28-test-create PASS "\"$name\" with CI CLI and CI Member, and \"$text\" in it"
else
	record m28-test-create FAIL "xcodebuild test failed (m28/testCreateGroup.tail.txt)"
fi
quiescence_note m28
stage m28-created
if line=$(wait_after cli "$m_cli" 60 "] $app_id" "$text"); then
	group=$(printf '%s' "$line" | sed -n "s/.* in group \($app_id\/[0-9a-f]\{16\}\): .*/\1/p")
fi
ok=0
if [ -n "$group" ]; then
	for who in cli member; do
		m=$m_cli
		[ "$who" = member ] && m=$m_member
		setup=$(wait_after "$who" "$m" 30 "in group $group: group setup, members ")
		if [ -n "$(printf '%s' "$setup" | grep -F "$cli_id" | grep -F "$member_id")" ] &&
			wait_after "$who" "$m" 10 "in group $group: group name \"$name\"" > /dev/null &&
			wait_after "$who" "$m" 30 "in group $group: $text" > /dev/null; then
			ok=$((ok + 1))
		fi
	done
fi
if [ "$ok" = 2 ]; then
	record m28-created PASS "group $group: the setup with $cli_id and $member_id, the name and the text at both"
else
	record m28-created FAIL "${group:-no group}: $ok of the two CLIs printed the setup with both members, the name and the text (m28/cli.txt, m28/member.txt)"
fi

stage m28-test-rename
m_cli=$(mark cli)
m_member=$(mark member)
if TEST_RUNNER_M28_GROUP="$name" TEST_RUNNER_M28_RENAMED="$renamed" run_test testRename; then
	record m28-test-rename PASS "Edit Group: \"$name\" renamed to \"$renamed\""
else
	record m28-test-rename FAIL "xcodebuild test failed (m28/testRename.tail.txt)"
fi
stage m28-renamed
if [ -n "$group" ] && wait_after cli "$m_cli" 60 "in group $group: group name \"$renamed\"" > /dev/null &&
	wait_after member "$m_member" 30 "in group $group: group name \"$renamed\"" > /dev/null; then
	record m28-renamed PASS "both CLIs printed group name \"$renamed\" in $group"
else
	record m28-renamed FAIL "not both CLIs printed group name \"$renamed\" in ${group:-the group}"
fi

stage m28-test-picture
m_cli=$(mark cli)
m_member=$(mark member)
o_pic=$(offset)
if TEST_RUNNER_M28_RENAMED="$renamed" run_test testGroupPicture; then
	record m28-test-picture PASS "Edit Group: the newest photo as the group's picture"
else
	record m28-test-picture FAIL "xcodebuild test failed (m28/testGroupPicture.tail.txt)"
fi
stage m28-app-upload
pic_ref=
pic_size=
if line=$(wait_since "$o_pic" 60 1 'blob: blob uploaded' "owner=$app_id"); then
	line=$(printf '%s\n' "$line" | head -n 1)
	pic_ref=$(printf '%s' "$line" | refs_of)
	pic_size=$(printf '%s' "$line" | sed -n 's/.* size=\([0-9]*\).*/\1/p')
	persist=$(printf '%s' "$line" | sed -n 's/.* persist=\([a-z]*\).*/\1/p')
	record m28-app-upload PASS "$(short "$line")"
	record m28-persist INFO "persist=${persist:-?} for the group picture"
else
	record m28-app-upload FAIL "no upload with owner=$app_id within 60 s of the picture's save (m28/blob-lines.txt)"
fi
stage m28-cli-picture
ok=0
note=""
for who in cli member; do
	m=$m_cli
	[ "$who" = member ] && m=$m_member
	n=$(wait_after "$who" "$m" 60 "] $app_id" "in group ${group:-?}: profile picture set, a " | sizes_of)
	note="$note $who:${n:-none}"
	if [ -n "$n" ] && [ -n "$pic_size" ] && [ "$((n + 16))" = "$pic_size" ]; then ok=$((ok + 1)); fi
done
saved=$(wait_after cli "$m_cli" 30 'profile picture saved: ' "-$app_id-")
centre=$(printf '%s' "$saved" | sed -n 's/.* centre #\([0-9a-f]\{6\}\).*/\1/p')
if [ "$ok" = 2 ] && [ -n "$centre" ] && colour_near "$centre" 0 255 255; then
	record m28-cli-picture PASS "both CLIs: the picture's 0x50 names $((pic_size - 16)) bytes, the upload $pic_size; the CLI saved it, its centre #$centre (cyan)"
else
	record m28-cli-picture FAIL "sizes printed:$note, the upload ${pic_size:-none} (want it 16 more), the CLI's saved centre #${centre:-none} (want cyan)"
fi
stage m28-fetched
served=0
[ -n "$pic_ref" ] && served=$(wait_since "$o_pic" 30 2 'blob: blob download' "blob_ref=$pic_ref" | grep -c 'outcome=served')
msaved=$(wait_after member "$m_member" 30 'profile picture saved: ' "-$app_id-")
mcentre=$(printf '%s' "$msaved" | sed -n 's/.* centre #\([0-9a-f]\{6\}\).*/\1/p')
if [ "$served" -ge 2 ] && [ -n "$mcentre" ] && colour_near "$mcentre" 0 255 255; then
	record m28-fetched PASS "$served served downloads of the group picture's blob $pic_ref; CI Member saved it too, its centre #$mcentre (cyan)"
else
	record m28-fetched FAIL "$served served download(s) of ${pic_ref:-?} (want 2), CI Member's saved centre #${mcentre:-none} (want cyan; m28/member.txt, m28/blob-lines.txt)"
fi
stage m28-not-done
sleep 5
dones=
[ -n "$pic_ref" ] && dones=$(since "$o_pic" 'blob: done handled' "blob_ref=$pic_ref" | sed '/^$/d' | head -n 1)
if [ -n "$pic_ref" ] && [ -z "$dones" ]; then
	record m28-not-done PASS "no done for the group picture's blob $pic_ref"
elif [ -n "$pic_ref" ]; then
	record m28-not-done FAIL "a done for $pic_ref, outcome=$(printf '%s' "$dones" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p'): $(short "$dones")"
else
	record m28-not-done FAIL "no blob of the group picture to check"
fi

stage m28-test-remove
m_cli=$(mark cli)
m_member=$(mark member)
if TEST_RUNNER_M28_RENAMED="$renamed" run_test testRemoveMember; then
	record m28-test-remove PASS "Edit Group: CI Member's clear badge, Done"
else
	record m28-test-remove FAIL "xcodebuild test failed (m28/testRemoveMember.tail.txt)"
fi
stage m28-removed
gone=$(wait_after member "$m_member" 60 "] $app_id" "in group ${group:-?}: group setup")
kept=$(wait_after cli "$m_cli" 30 "] $app_id" "in group ${group:-?}: group setup, members ")
if [ -n "$gone" ] && [ -z "$(printf '%s' "$gone" | grep -F "$member_id")" ] &&
	[ -n "$(printf '%s' "$kept" | grep -F "$cli_id")" ] && [ -z "$(printf '%s' "$kept" | grep -F "$member_id")" ]; then
	record m28-removed PASS "CI Member: $(printf '%s' "$gone" | sed 's/.*: group setup/group setup/; s/ id=.*//'); the CLI: $(printf '%s' "$kept" | sed 's/.*: group setup/group setup/; s/ id=.*//')"
else
	record m28-removed FAIL "CI Member printed: ${gone:-no setup}; the CLI: ${kept:-no setup} (want CI Member's without itself, the CLI's with itself alone)"
fi

stage m28-test-add
m_cli=$(mark cli)
m_member=$(mark member)
o_add=$(offset)
if TEST_RUNNER_M28_RENAMED="$renamed" run_test testAddMember; then
	record m28-test-add PASS "Edit Group: Add Contact > CI Member > Next, Done"
else
	record m28-test-add FAIL "xcodebuild test failed (m28/testAddMember.tail.txt)"
fi
stage m28-added
setup=$(wait_after member "$m_member" 60 "] $app_id" "in group ${group:-?}: group setup, members ")
named=$(wait_after member "$m_member" 30 "in group ${group:-?}: group name \"$renamed\"")
pictured=$(wait_after member "$m_member" 60 "] $app_id" "in group ${group:-?}: profile picture set, a ")
add_ref=$(wait_since "$o_add" 30 1 'blob: blob uploaded' "owner=$app_id" | head -n 1 | refs_of)
add_served=
[ -n "$add_ref" ] && add_served=$(wait_since "$o_add" 30 1 'blob: blob download' "blob_ref=$add_ref" | grep -F 'outcome=served' | head -n 1)
if [ -n "$(printf '%s' "$setup" | grep -F "$cli_id" | grep -F "$member_id")" ] && [ -n "$named" ] && [ -n "$pictured" ] &&
	[ -n "$add_served" ]; then
	record m28-added PASS "CI Member: the setup with both, the name, the picture (blob $add_ref, uploaded again and served)"
else
	record m28-added FAIL "CI Member printed setup: ${setup:+yes}${setup:-no}, name: ${named:+yes}${named:-no}, picture: ${pictured:+yes}${pictured:-no}; a new upload ${add_ref:-none}, served: ${add_served:+yes}${add_served:-no}"
fi
record m28-resync-upload INFO "the re-add's upload: ${add_ref:-none} (the first was ${pic_ref:-none}); $(since "$o_add" 'blob: blob uploaded' "owner=$app_id" | grep -c .) upload(s) by the app since the test started"

listen_stop member
stage m28-leave
o_leave=$(offset)
leave_id=
if [ -n "$group" ] && "$cli" group leave -identity "$member_profile" -group "$group" -members "$cli_id" >> "$out/member.txt" 2>&1; then
	leave_id=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id in group .*: left the group$/\1/p" "$out/member.txt" | tail -n 1)
fi
listen_start member || echo "::warning::CI Member's listen did not say it listens"
if [ -n "$leave_id" ] && how=$(relayed_count "$o_leave" 30 "$member_id" "$app_id" "$leave_id"); then
	record m28-leave PASS "CI Member's leave $leave_id: $how delivered to and acknowledged by the app"
else
	record m28-leave FAIL "CI Member's leave ${leave_id:-was not sent} (m28/member.txt): ${how:-not delivered}"
fi
stage m28-test-left
if TEST_RUNNER_M28_RENAMED="$renamed" run_test testMemberLeft; then
	record m28-test-left PASS "the chat says CI Member left the group"
else
	record m28-test-left FAIL "xcodebuild test failed (m28/testMemberLeft.tail.txt)"
fi
stage m28-sync
m_cli=$(mark cli)
o_sync=$(offset)
if TEST_RUNNER_M28_RENAMED="$renamed" run_test testSynchronize; then
	sync_setup=$(wait_after cli "$m_cli" 30 "] $app_id" "in group ${group:-?}: group setup")
	record m28-sync INFO "Synchronize Group: the CLI printed ${sync_setup:+a setup}${sync_setup:-no setup}; $(since "$o_sync" 'blob: blob uploaded' "owner=$app_id" | grep -c .) upload(s) by the app"
else
	record m28-sync INFO "Synchronize Group failed (m28/testSynchronize.tail.txt); reported only"
fi

stage m28-test-dissolve
m_cli=$(mark cli)
if TEST_RUNNER_M28_RENAMED="$renamed" run_test testDissolve; then
	record m28-test-dissolve PASS "Dissolve Group > Dissolve Group: \"You have left the group.\""
else
	record m28-test-dissolve FAIL "xcodebuild test failed (m28/testDissolve.tail.txt)"
fi
stage m28-dissolved
if line=$(wait_after cli "$m_cli" 60 "] $app_id" "in group ${group:-?}: group setup, no members"); then
	record m28-dissolved PASS "$(printf '%s' "$line" | cut -c1-200)"
else
	record m28-dissolved FAIL "the CLI printed no empty setup in ${group:-the group} within 60 s"
fi

stage m28-relay
cli_ids=$(grep -F "] $app_id" "$out/cli.txt" 2> /dev/null | grep -F " in group ${group:-?}: " | ids_of | sort -u | tr '\n' ' ')
member_ids=$(grep -F "] $app_id" "$out/member.txt" 2> /dev/null | grep -F " in group ${group:-?}: " | ids_of | sort -u | tr '\n' ' ')
if [ -n "$group" ] && [ -n "$cli_ids" ] && [ -n "$member_ids" ] &&
	to_cli=$(relayed_count "$m28_start" 30 "$app_id" "$cli_id" $cli_ids) &&
	to_member=$(relayed_count "$m28_start" 30 "$app_id" "$member_id" $member_ids); then
	record m28-relay PASS "the app's group messages: $to_cli to the CLI, $to_member to CI Member, each accepted and acknowledged"
else
	record m28-relay FAIL "to the CLI: ${to_cli:-${cli_ids:-no IDs}}; to CI Member: ${to_member:-${member_ids:-no IDs}} (m28/chat-lines.txt)"
fi
record m28-flags INFO "to the CLI: $(accepted_flags "$m28_start" "$app_id" "$cli_id" $cli_ids); to CI Member: $(accepted_flags "$m28_start" "$app_id" "$member_id" $member_ids)"
record m28-blob-lines INFO "$(since "$m28_start" 'component=blob' | wc -l | tr -d ' ') blob server lines; $(since "$m28_start" 'blob: done handled' | grep -c 'outcome=deleted') done(s) that deleted"
shot m28-19-final

failed=$(failing_stages "$M28_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 28: every stage passed"
