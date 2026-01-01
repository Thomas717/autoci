#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SEAT_USERNAME:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m19"
work="$RUNNER_TEMP/m2-driver"
cli=$(cat "$SRV/cli.path")
rev_seat=ci-rev
rev_profile="$SEC/cli-rev.json"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m19"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

finish() {
	cockpit_sign_out
	rm -f "$SEC/ci-rev-seat.json" "$SEC/ci-rev-license.url" "$SEC/m19-curl.conf"
	for f in register.txt send.txt check.json; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m19/$f"
	done
	(since "${m19_start:-0}" 'work: ' | grep -E 'work contacts fetched|refused a work contacts fetch' | sed 's/^time=[^ ]* //' |
		cut -c1-200 > "$RESULTS/m19/lookup-lines.txt") 2> /dev/null || true
	(since "${m19_start:-0}" 'directory: feature masks checked' | sed 's/^time=[^ ]* //' | cut -c1-200 \
		>> "$RESULTS/m19/lookup-lines.txt") 2> /dev/null || true
}
trap finish EXIT

offset() { wc -c < "$SRV/server.log" | tr -d ' '; }
since() {
	(tail -c +"$(($1 + 1))" "$SRV/server.log" 2> /dev/null || true) | grep -F -- "$2" | grep -F -- "${3:-$2}" || true
}
m19_start=$(offset)

fail() {
	record "$1" FAIL "$2"
	exit 1
}

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/RevokedContactTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m19-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m19/$1.tail.txt"
	export_attachments "$work/m19-$1.xcresult" "$out/shots" "$RESULTS/m19" m19- > /dev/null 2>&1 || true
	return "$status"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m19-seat "no identity of the app in the server log"
nonce=$(test_nonce)
text="M19 from a colleague $nonce"

xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 5

stage m19-seat
cockpit_sign_in || fail m19-seat "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S19)"
find_openssl > /dev/null 2>&1 || fail m19-seat "no OpenSSL 3"
(umask 077 && "$OPENSSL" rand -hex 16 > "$SEC/ci-rev-password.txt") || fail m19-seat "openssl rand failed"
add_secret "$(cat "$SEC/ci-rev-password.txt")"
(umask 077 && python3 -I - "$SEC/ci-rev-password.txt" "$SEC/ci-rev-seat.json" "$rev_seat" <<'PY'
import json, sys
password = open(sys.argv[1]).read().strip()
json.dump({"username": sys.argv[3], "password": password,
           "profile": {"firstName": "CI", "lastName": "Revoked"}}, open(sys.argv[2], "w"))
PY
)
status=$(curl_tls -s -o "$COCKPIT_ANSWER" -w '%{http_code}' --cacert "$SRV/tls/ca.crt" -b "$SEC/cockpit.cookies" \
	-X POST -H @"$SEC/cockpit.csrf" -H 'Content-Type: application/json' --data @"$SEC/ci-rev-seat.json" \
	"$SERVER_PUBLIC_URL/cockpit/api/users" || echo 000)
rm -f "$SEC/ci-rev-seat.json"
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m19/seat-answer.json" 2> /dev/null
	fail m19-seat "the cockpit answered $status to the new seat (m19/seat-answer.json)"
fi
record m19-seat PASS "seat $rev_seat (CI Revoked) made in the cockpit (HTTP $status)"
stage m19-seat-hash
cheap_seat_hashes m19-seat-hash "$cli" "$rev_seat" "$SEC/ci-rev-password.txt" || true

stage m19-register
(umask 077 && python3 -I - "$SEC/ci-rev-password.txt" "$SEC/ci-rev-license.url" "$SERVER_PUBLIC_URL" "$rev_seat" <<'PY'
import sys
from urllib.parse import quote, urlencode
password = open(sys.argv[1]).read().strip()
query = urlencode({"server": sys.argv[3], "username": sys.argv[4], "password": password},
                  quote_via=lambda value, *_: quote(value, safe=""))
open(sys.argv[2], "w").write("threemaonprem://license?" + query + "\n")
PY
)
add_secret "$(tr -d '\r\n' < "$SEC/ci-rev-license.url")"
if ! "$cli" register -license - -signature-key "$(cat "$SRV/oppf-public.key")" -nickname "CI Revoked" \
	-out "$rev_profile" < "$SEC/ci-rev-license.url" > "$out/register.txt" 2>&1; then
	tail -n 20 "$out/register.txt"
	fail m19-register "cli register on $rev_seat failed (m19/register.txt)"
fi
rm -f "$SEC/ci-rev-license.url"
key=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["clientKey"])' "$rev_profile" | tr -d '\r')
add_secret "$key"
key=
rev_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$rev_profile" | tr -d '\r')
[[ $rev_id =~ ^[0-9A-Z]{8}$ ]] || fail m19-register "the colleague's profile holds no identity"
record m19-register PASS "the colleague $rev_id on $rev_seat"
stage m19-send
o_send=$(offset)
if "$cli" send -identity "$rev_profile" -to "$app_id" -text "$text" > "$out/send.txt" 2>&1; then
	record m19-send PASS "$(grep -F 'sent ' "$out/send.txt" | tail -n 1 | cut -c1-120)"
else
	tail -n 5 "$out/send.txt"
	fail m19-send "the colleague's send failed (m19/send.txt)"
fi

stage m19-test-before
if TEST_RUNNER_M19_TEXT="$text" TEST_RUNNER_M19_ID="$rev_id" run_test testSeeTheColleague; then
	record m19-test-before PASS "the colleague's text in its chat, not marked invalid"
else
	record m19-test-before FAIL "xcodebuild test failed (m19/testSeeTheColleague.tail.txt)"
fi
stage m19-work-fetch
line=$(since "$o_send" 'work: work contacts fetched' "seat=$SEAT_USERNAME" | tail -n 1)
requested=$(printf '%s' "$line" | sed -n 's/.* requested=\([0-9]*\).*/\1/p')
if [ -n "$requested" ] && [ "$requested" -ge 1 ]; then
	record m19-work-fetch PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	refused=$(since "$o_send" 'work: refused a work contacts fetch' | tail -n 1 | sed 's/^time=[^ ]* //' | cut -c1-120)
	record m19-work-fetch FAIL "no Work contacts lookup of $SEAT_USERNAME since the colleague wrote${refused:+; refused: $refused} (m19/lookup-lines.txt)"
fi
checks=$(since "$m19_start" 'directory: feature masks checked' | sed 's/^time=[^ ]* //' | cut -c1-120)
last=$(printf '%s\n' "$checks" | sed '/^$/d' | tail -n 1)
record m19-featuremask INFO "$(printf '%s\n' "$checks" | grep -c . || true) feature mask check(s)${last:+; last: $last}"

stage m19-revoke
status=$(cockpit POST "/api/identities/$rev_id/revoke" "{\"confirm\":\"$rev_id\"}")
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m19/revoke-answer.json" 2> /dev/null
	fail m19-revoke "the cockpit answered $status to the revocation (m19/revoke-answer.json)"
fi
record m19-revoke PASS "the cockpit revoked $rev_id (HTTP $status)"
stage m19-check
(umask 077 && printf 'user = "%s:%s"\n' "$SEAT_USERNAME" "$(cat "$SEC/seat-password.txt")" > "$SEC/m19-curl.conf")
state=$(curl_tls -s -K "$SEC/m19-curl.conf" --cacert "$SRV/tls/ca.crt" -H 'Content-Type: application/json' \
	--data "{\"identities\":[\"$rev_id\"]}" "$SERVER_PUBLIC_URL/directory/identity/check" -o "$out/check.json" -w '%{http_code}' || echo 000)
rm -f "$SEC/m19-curl.conf"
states=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["states"])' "$out/check.json" 2> /dev/null | tr -d '\r')
if [ "$state" = 200 ] && [ "$states" = "[2]" ]; then
	record m19-check PASS "identity/check: state 2 (invalid) for $rev_id"
else
	record m19-check FAIL "identity/check answered $state with states $states for $rev_id"
fi

stage m19-test-revoked
if TEST_RUNNER_M19_TEXT="$text" TEST_RUNNER_M19_ID="$rev_id" run_test testRevoked; then
	record m19-test-revoked PASS "after a pull the chat says the colleague is invalid, and the composer refuses to send"
else
	record m19-test-revoked FAIL "xcodebuild test failed (m19/testRevoked.tail.txt, m19/m19-after-header.txt)"
fi
shot m19-09-final

failed=$(failing_stages "$M19_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 19: every stage passed"
