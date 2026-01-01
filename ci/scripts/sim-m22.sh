#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SERVER_NOTIFY_PORT:?}" "${SRV_BIN:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m22"
work="$RUNNER_TEMP/m2-driver"
cli=$(cat "$SRV/cli.path")
profile="$SEC/cli.json"
match_seat=ci-match
match_profile="$SEC/cli-match.json"
add_profile="$SEC/cli-add.json"
match_number=+12025550122
code_file="$SEC/m22-code.txt"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m22"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

finish() {
	notify_stop
	cockpit_sign_out
	rm -f "$SEC/ci-match-seat.json" "$SEC/ci-match-license.url" "$SEC/m22-curl.conf" "$code_file"
	for f in notify.txt latest.txt register-match.txt register-add.txt link-phone.txt link-verify.txt link-unlink.txt \
		match.txt addressbook.txt unknown-check.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m22/$f"
	done
	[ -f "$SRV/m22.vcf" ] && cp "$SRV/m22.vcf" "$RESULTS/m22/m22-vcard.txt"
	(since "${m22_start:-0}" 'directory: ' | grep -E 'directory: (phone link|contacts matched|match token|identity fetched)' |
		sed 's/^time=[^ ]* //' | cut -c1-220 > "$RESULTS/m22/match-lines.txt") 2> /dev/null || true
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
			lines=$(printf '%s\n' "$lines" | grep -F -- "$filter" || true)
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
short() { printf '%s' "$1" | sed 's/^time=[^ ]* //' | cut -c1-200; }
m22_start=$(offset)

run_test() {
	local status=0
	rm -rf "$work/m22-$2.xcresult"
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/$1/$2" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m22-$2.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$2.log" 2>&1 || status=$?
	tail -n 150 "$out/$2.log" > "$RESULTS/m22/$2.tail.txt"
	export_attachments "$work/m22-$2.xcresult" "$out/shots" "$RESULTS/m22" m22- > /dev/null 2>&1 || true
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 5
}

register() {
	local key
	REGISTERED=
	"$cli" register -license - -signature-key "$(cat "$SRV/oppf-public.key")" -nickname "$1" -out "$2" \
		< "$SEC/ci-match-license.url" > "$out/$3" 2>&1 || return 1
	key=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["clientKey"])' "$2" | tr -d '\r')
	add_secret "$key"
	key=
	REGISTERED=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$2" | tr -d '\r')
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m22-seat "no identity of the app in the server log"
[ -s "$profile" ] || fail m22-seat "no CLI peer profile from milestone 3 ($profile)"

stage m22-binaries
gap=$(link_binaries_gap 'directory: phone link code checked' 'directory: phone link removed' \
	'directory: match token issued' 'directory: contacts matched' 'directory: identity fetched')
[ -z "$gap" ] || fail m22-binaries "$gap: the binaries predate the server's b0aa48a; rebuild server/ (tools/update-server-binary.sh; docs/HOW-IT-WORKS.md, milestones 21 and 22)"
record m22-binaries PASS "threema-cli has match; the server binary has the directory's debug lines of matching"

stage m22-seat
cockpit_sign_in || fail m22-seat "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S22)"
find_openssl > /dev/null 2>&1 || fail m22-seat "no OpenSSL 3"
(umask 077 && "$OPENSSL" rand -hex 16 > "$SEC/ci-match-password.txt") || fail m22-seat "openssl rand failed"
add_secret "$(cat "$SEC/ci-match-password.txt")"
(umask 077 && python3 -I - "$SEC/ci-match-password.txt" "$SEC/ci-match-seat.json" "$match_seat" <<'PY'
import json, sys
password = open(sys.argv[1]).read().strip()
json.dump({"username": sys.argv[3], "password": password,
           "profile": {"firstName": "CI", "lastName": "Match"}}, open(sys.argv[2], "w"))
PY
)
status=$(curl_tls -s -o "$COCKPIT_ANSWER" -w '%{http_code}' --cacert "$SRV/tls/ca.crt" -b "$SEC/cockpit.cookies" \
	-X POST -H @"$SEC/cockpit.csrf" -H 'Content-Type: application/json' --data @"$SEC/ci-match-seat.json" \
	"$SERVER_PUBLIC_URL/cockpit/api/users" || echo 000)
rm -f "$SEC/ci-match-seat.json"
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m22/seat-answer.json" 2> /dev/null
	fail m22-seat "the cockpit answered $status to the new seat (m22/seat-answer.json)"
fi
record m22-seat PASS "seat $match_seat (CI Match) made in the cockpit (HTTP $status)"

stage m22-register
(umask 077 && python3 -I - "$SEC/ci-match-password.txt" "$SEC/ci-match-license.url" "$SERVER_PUBLIC_URL" "$match_seat" <<'PY'
import sys
from urllib.parse import quote, urlencode
password = open(sys.argv[1]).read().strip()
query = urlencode({"server": sys.argv[3], "username": sys.argv[4], "password": password},
                  quote_via=lambda value, *_: quote(value, safe=""))
open(sys.argv[2], "w").write("threemaonprem://license?" + query + "\n")
PY
)
add_secret "$(tr -d '\r\n' < "$SEC/ci-match-license.url")"
register "CI Match" "$match_profile" register-match.txt || {
	tail -n 20 "$out/register-match.txt"
	fail m22-register "cli register \"CI Match\" on $match_seat failed (m22/register-match.txt)"
}
match_id=$REGISTERED
register "CI AddById" "$add_profile" register-add.txt || {
	tail -n 20 "$out/register-add.txt"
	fail m22-register "cli register \"CI AddById\" on $match_seat failed (m22/register-add.txt)"
}
add_id=$REGISTERED
rm -f "$SEC/ci-match-license.url"
[[ $match_id =~ ^[0-9A-Z]{8}$ ]] && [[ $add_id =~ ^[0-9A-Z]{8}$ ]] || fail m22-register "a profile holds no identity"
metric m22_match_id "$match_id"
metric m22_add_id "$add_id"
record m22-register PASS "CI Match $match_id and CI AddById $add_id on $match_seat"

stage m22-notify
notify_start "$out/notify.txt" ||
	fail m22-notify "fake-notify-api does not listen on 127.0.0.1:$SERVER_NOTIFY_PORT (m22/notify.txt; server-prepare.sh makes its token for S22)"
record m22-notify PASS "fake-notify-api (test-only) listens on 127.0.0.1:$SERVER_NOTIFY_PORT"
stage m22-link
o=$(offset)
t=$(utc_now)
code=
if "$cli" link phone -identity "$match_profile" -number "$match_number" > "$out/link-phone.txt" 2>&1 &&
	grep -qF "$match_id: verification SMS requested" "$out/link-phone.txt"; then
	if "$cli" fake-notify-api latest -store "$NOTIFY_STORE" -channel sms -to "$match_number" -since "$t" -field code \
		-wait 60s -out "$code_file" >> "$out/latest.txt" 2>&1; then
		code=$(head -n 1 "$code_file" | tr -d '\r\n ')
		add_secret "$code"
	fi
fi
if ! [[ $code =~ ^[0-9]{8}$ ]]; then
	fail m22-link "no SMS code for $match_number ($(tail -n 1 "$out/link-phone.txt" | cut -c1-120); m22/latest.txt)"
fi
code=
if "$cli" link verify -identity "$match_profile" -code-file "$code_file" > "$out/link-verify.txt" 2>&1 &&
	grep -qF "$match_id: phone number linked" "$out/link-verify.txt" &&
	line=$(wait_line "$o" 20 'directory: phone link code checked' "identity=$match_id" 'result=linked'); then
	record m22-link PASS "link phone, the SMS's code (masked), link verify: $(short "$line")"
else
	record m22-link FAIL "$(tail -n 1 "$out/link-verify.txt" | cut -c1-160) (m22/link-verify.txt)"
fi
rm -f "$code_file"
stage m22-cli-match
if "$cli" match -identity "$profile" -phone "$match_number" -expect "$match_id" > "$out/match.txt" 2>&1; then
	record m22-cli-match PASS "the CLI's own hash of $match_number finds $match_id: $(grep -F "match $match_id" "$out/match.txt")"
else
	record m22-cli-match FAIL "$(tail -n 1 "$out/match.txt" | cut -c1-160) (m22/match.txt)"
fi

stage m22-addressbook
printf 'BEGIN:VCARD\r\nVERSION:3.0\r\nN:Match;CI;;;\r\nFN:CI Match\r\nTEL;TYPE=CELL:+1 202-555-0122\r\nEND:VCARD\r\n' \
	> "$SRV/m22.vcf"
granted=
added=
{
	echo "## simctl privacy grant contacts"
	xcrun simctl privacy "$udid" grant contacts "$APP_BUNDLE_ID" 2>&1
	granted=$?
	echo "exit $granted"
	echo "## simctl addmedia m22.vcf"
	xcrun simctl addmedia "$udid" "$SRV/m22.vcf" 2>&1
	added=$?
	echo "exit $added"
} > "$out/addressbook.txt"
relaunch
if [ "$added" = 0 ] && [ "$granted" = 0 ]; then
	record m22-addressbook PASS "contacts access granted, vCard \"CI Match\" (+1 202-555-0122) added; the app launched again"
else
	record m22-addressbook FAIL "simctl privacy grant exit ${granted:-?}, addmedia exit ${added:-?} (m22/addressbook.txt)"
fi

stage m22-test-sync
o=$(offset)
if TEST_RUNNER_M22_NAME="CI Match" run_test ContactSyncTests testSyncFindsTheMatch; then
	record m22-test-sync PASS "Settings > Privacy > Sync Contacts on; a pull on Contacts lists \"CI Match\""
else
	record m22-test-sync FAIL "xcodebuild test failed (m22/testSyncFindsTheMatch.tail.txt)"
fi
stage m22-matched
if line=$(wait_line "$o" 10 'directory: contacts matched' "identity=$app_id" 'result=answered'); then
	phones=$(printf '%s' "$line" | sed -n 's/.* phone_hashes=\([0-9]*\).*/\1/p')
	matches=$(printf '%s' "$line" | sed -n 's/.* matches=\([0-9]*\).*/\1/p')
	if [ "${phones:-0}" -ge 1 ] && [ "${matches:-0}" -ge 1 ]; then
		record m22-matched PASS "$(short "$line")"
	else
		record m22-matched FAIL "$(short "$line"): no phone hash or no match"
	fi
else
	last=$(since "$o" 'directory: contacts matched' | tail -n 1)
	record m22-matched FAIL "no \"directory: contacts matched\" for $app_id during the test${last:+; last: $(short "$last")}"
fi
token=$(since "$m22_start" 'directory: match token issued' "identity=$app_id" | tail -n 1)
record m22-token INFO "$(short "${token:-no match token issued to the app in this milestone (iOS keeps one per install)}")"

stage m22-test-unknown
unknown=
(umask 077 && cp "$SEC/curl-auth.cfg" "$SEC/m22-curl.conf")
for _ in 1 2 3 4 5; do
	candidate=Q$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 7)
	answer=$(curl_tls -s -o /dev/null -w '%{http_code}' -K "$SEC/m22-curl.conf" --cacert "$SRV/tls/ca.crt" \
		"$SERVER_PUBLIC_URL/directory/identity/$candidate" || echo 000)
	printf '%s: HTTP %s\n' "$candidate" "$answer" >> "$out/unknown-check.txt"
	if [ "$answer" = 404 ]; then
		unknown=$candidate
		break
	fi
done
rm -f "$SEC/m22-curl.conf"
o=$(offset)
if [ -z "$unknown" ]; then
	record m22-test-unknown FAIL "no ID the server answers 404 for (m22/unknown-check.txt)"
elif TEST_RUNNER_M22_ID="$unknown" run_test AddContactTests testUnknownID; then
	record m22-test-unknown PASS "Contacts > Add > New Contact, $unknown (404 for curl), Add: \"Unknown ID\""
else
	record m22-test-unknown FAIL "xcodebuild test failed (m22/testUnknownID.tail.txt)"
fi
stage m22-unknown
if line=$(wait_line "$o" 10 'directory: identity fetched' 'result=not-found'); then
	record m22-unknown PASS "$(short "$line")"
else
	record m22-unknown FAIL "no \"directory: identity fetched\" result=not-found during the test"
fi

stage m22-sync-off
sync_off=false
for try in 1 2; do
	if run_test ContactSyncTests testSyncOff; then
		sync_off=true
		break
	fi
	cp "$RESULTS/m22/testSyncOff.tail.txt" "$RESULTS/m22/testSyncOff-try$try.tail.txt" 2> /dev/null
done
if [ "$sync_off" = true ]; then
	record m22-sync-off PASS "Settings > Privacy > Sync Contacts off again (try $try)"
else
	record m22-sync-off FAIL "Sync Contacts may still be on after two tries (m22/testSyncOff-try1.tail.txt, -try2): no contact is added, as its Safe backup would carry the sync on"
fi

stage m22-test-add
o=$(offset)
if [ "$sync_off" != true ]; then
	record m22-test-add FAIL "skipped: Sync Contacts may still be on (m22-sync-off)"
elif TEST_RUNNER_M22_ID="$add_id" run_test AddContactTests testAddByID; then
	record m22-test-add PASS "Contacts > Add > New Contact, $add_id (CI AddById), Add: its details show the ID"
else
	record m22-test-add FAIL "xcodebuild test failed (m22/testAddByID.tail.txt)"
fi
stage m22-fetched
if [ "$sync_off" != true ]; then
	record m22-fetched FAIL "skipped with testAddByID (m22-sync-off)"
elif line=$(wait_line "$o" 10 'directory: identity fetched' 'result=found'); then
	record m22-fetched PASS "$(short "$line")"
else
	last=$(since "$o" 'directory: identity fetched' | tail -n 1)
	record m22-fetched FAIL "no \"directory: identity fetched\" result=found during the test${last:+; last: $(short "$last")}"
fi

stage m22-cli-unlink
o=$(offset)
if "$cli" link unlink -identity "$match_profile" phone > "$out/link-unlink.txt" 2>&1 &&
	line=$(wait_line "$o" 20 'directory: phone link removed' "identity=$match_id"); then
	record m22-cli-unlink INFO "$(short "$line")"
else
	record m22-cli-unlink INFO "CI Match's number may still be linked: $(tail -n 1 "$out/link-unlink.txt" | cut -c1-160)"
fi
stage m22-addressbook-reset
{
	echo "## simctl privacy reset contacts"
	xcrun simctl privacy "$udid" reset contacts "$APP_BUNDLE_ID" 2>&1
	reset_status=$?
	echo "exit $reset_status"
} >> "$out/addressbook.txt"
relaunch
if [ "$reset_status" = 0 ]; then
	record m22-addressbook-reset INFO "the app's contacts access reset to undecided; the app launched again"
else
	record m22-addressbook-reset INFO "simctl privacy reset contacts exit $reset_status (m22/addressbook.txt): the app may keep its access"
fi
shot m22-09-final

failed=$(failing_stages "$M22_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 22: every stage passed"
