#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_NOTIFY_PORT:?}" "${SERVER_PUBLIC_URL:?}" "${SRV_BIN:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m21"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
app_national=2025550121
app_number=+12025550121
app_last4=0121
cli_number=+12025550123
app_email=ci-app@example.com
code_file="$SEC/m21-code.txt"
call_code_file="$SEC/m21-call-code.txt"
link_file="$SEC/m21-link.txt"
raw_log="$SEC/m21-xcodebuild.log"
mkdir -p "$out/shots" "$RESULTS/m21"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

blank_log() {
	sed -E -e "s/(Typ[a-z]* )'[^']*'/\1'***'/g" -e 's/(Typ[a-z]* )"[^"]*"/\1"***"/g' "$1" > "$2" || true
	rm -f "$1"
}

finish() {
	notify_stop
	[ -f "$raw_log" ] && blank_log "$raw_log" "$out/testVerifyCode.log"
	rm -f "$code_file" "$call_code_file" "$link_file"
	for f in notify.txt latest.txt confirm.txt match-linked.txt match-unlinked.txt status.txt link-phone.txt \
		link-call.txt link-verify.txt link-unlink.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m21/$f"
	done
	(since "${m21_start:-0}" 'directory: ' | grep -E 'directory: (phone link|email link|link request|contacts matched|match token)' |
		sed 's/^time=[^ ]* //' | cut -c1-220 > "$RESULTS/m21/link-lines.txt") 2> /dev/null || true
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
m21_start=$(offset)

notify_count() { grep -c "received $1 #" "$out/notify.txt" 2> /dev/null || true; }

latest() {
	rm -f "$5"
	"$cli" fake-notify-api latest -store "$NOTIFY_STORE" -channel "$1" -to "$2" -since "$3" -field "$4" \
		-wait 60s -out "$5" >> "$out/latest.txt" 2>&1
}

run_test() {
	local status=0 log="$out/$1.log"
	if [ "${2:-}" = secret ]; then
		rm -f "$raw_log"
		(umask 077 && : > "$raw_log")
		log=$raw_log
	fi
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/LinkTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m21-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		>> "$log" 2>&1 || status=$?
	[ "${2:-}" = secret ] && blank_log "$raw_log" "$out/$1.log"
	tail -n 150 "$out/$1.log" > "$RESULTS/m21/$1.tail.txt"
	export_attachments "$work/m21-$1.xcresult" "$out/shots" "$RESULTS/m21" m21- > /dev/null 2>&1 || true
	return "$status"
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m21-notify "no identity of the app in the server log"
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $cli_id =~ ^[0-9A-Z]{8}$ ]] || fail m21-notify "no CLI peer profile from milestone 3 ($profile)"

stage m21-binaries
gap=$(link_binaries_gap 'directory: phone link requested' 'directory: phone link code checked' \
	'directory: phone link call requested' 'directory: phone link removed' 'directory: email link requested' \
	'directory: email link checked' 'directory: email link removed')
[ -z "$gap" ] || fail m21-binaries "$gap: the binaries predate the server's b0aa48a; rebuild server/ (tools/update-server-binary.sh; docs/HOW-IT-WORKS.md, milestones 21 and 22)"
record m21-binaries PASS "threema-cli has match and link status -of; the server binary has the directory's debug lines of linking"

stage m21-notify
notify_start "$out/notify.txt" ||
	fail m21-notify "fake-notify-api does not listen on 127.0.0.1:$SERVER_NOTIFY_PORT (m21/notify.txt; server-prepare.sh makes its token for S21)"
record m21-notify PASS "fake-notify-api (test-only) listens on 127.0.0.1:$SERVER_NOTIFY_PORT; the server's verification APIs point there"

xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 5

stage m21-test-phone
o=$(offset)
t=$(utc_now)
if TEST_RUNNER_M21_PHONE="$app_national" run_test testRequestPhoneLink; then
	record m21-test-phone PASS "Profile > Linked Phone Number: $app_national typed, Verify, \"Confirm number\" > Verify: the Code page shows"
else
	record m21-test-phone FAIL "xcodebuild test failed (m21/testRequestPhoneLink.tail.txt, m21/m21-01-confirm-text.txt)"
fi
stage m21-requested
if line=$(wait_line "$o" 30 'directory: phone link requested' "identity=$app_id" 'result=sent'); then
	sms=$(notify_count sms)
	if [ "${sms:-0}" -ge 1 ]; then
		record m21-requested PASS "$(short "$line"); the stand-in received $sms SMS"
	else
		record m21-requested FAIL "$(short "$line"), but the stand-in received no SMS (m21/notify.txt)"
	fi
else
	last=$(since "$o" 'directory: phone link requested' "identity=$app_id" | tail -n 1)
	refused=$(since "$o" 'directory: link request' | tail -n 1)
	record m21-requested FAIL "no \"directory: phone link requested\" result=sent for $app_id within 30 s${last:+; last: $(short "$last")}${refused:+; $(short "$refused")}"
fi

stage m21-code
code=
if latest sms "$app_number" "$t" code "$code_file"; then
	code=$(head -n 1 "$code_file" | tr -d '\r\n ')
	add_secret "$code"
fi
if [[ $code =~ ^[0-9]{8}$ ]]; then
	record m21-code PASS "the SMS to $app_number carried an 8-digit code (masked; in an owner-only file)"
else
	record m21-code FAIL "no 8-digit code in an SMS to $app_number since $t (m21/latest.txt)"
fi
stage m21-test-verify
o=$(offset)
if [ -z "$code" ]; then
	record m21-test-verify FAIL "no code to type"
elif TEST_RUNNER_M21_CODE="$code" TEST_RUNNER_M21_LAST4="$app_last4" run_test testVerifyCode secret; then
	record m21-test-verify PASS "the code typed, Verify: the page shows the number and \"Unlink Number\""
else
	record m21-test-verify FAIL "xcodebuild test failed (m21/testVerifyCode.tail.txt)"
fi
code=
rm -f "$code_file"
stage m21-linked
if line=$(wait_line "$o" 30 'directory: phone link code checked' "identity=$app_id" 'result=linked'); then
	record m21-linked PASS "$(short "$line")"
else
	last=$(since "$o" 'directory: phone link code checked' | tail -n 1)
	record m21-linked FAIL "no \"directory: phone link code checked\" result=linked for $app_id within 30 s${last:+; last: $(short "$last")}"
fi

stage m21-test-email
o=$(offset)
t=$(utc_now)
if TEST_RUNNER_M21_EMAIL="$app_email" run_test testRequestEmailLink; then
	record m21-test-email PASS "Profile > Linked Email: $app_email, Verify, \"Confirm Email\" > Verify: \"Stop Verification\" shows"
else
	record m21-test-email FAIL "xcodebuild test failed (m21/testRequestEmailLink.tail.txt)"
fi
stage m21-email-sent
if line=$(wait_line "$o" 30 'directory: email link requested' "identity=$app_id" 'result=sent'); then
	mails=$(notify_count email)
	if [ "${mails:-0}" -ge 1 ]; then
		record m21-email-sent PASS "$(short "$line"); the stand-in received $mails e-mail(s)"
	else
		record m21-email-sent FAIL "$(short "$line"), but the stand-in received no e-mail (m21/notify.txt)"
	fi
else
	last=$(since "$o" 'directory: email link requested' "identity=$app_id" | tail -n 1)
	refused=$(since "$o" 'directory: link request' | tail -n 1)
	record m21-email-sent FAIL "no \"directory: email link requested\" result=sent for $app_id within 30 s${last:+; last: $(short "$last")}${refused:+; $(short "$refused")}"
fi

stage m21-email-confirm
o=$(offset)
link=
if latest email "$app_email" "$t" link "$link_file"; then
	link=$(head -n 1 "$link_file" | tr -d '\r\n')
	add_secret "$link"
	add_secret "$(printf '%s' "$link" | sed -n 's/.*[?&]t=\([^&]*\).*/\1/p')"
fi
case $link in
"$SERVER_PUBLIC_URL/verify/email?t="?*)
	scanned=$("$cli" confirm-email-link -link-file "$link_file" -get-only 2> "$out/confirm.txt")
	confirmed=$("$cli" confirm-email-link -link-file "$link_file" 2>> "$out/confirm.txt")
	printf 'get-only: %s\nconfirm: %s\n' "$scanned" "$confirmed" >> "$out/confirm.txt"
	get_line=$(wait_line "$o" 10 'directory: email link confirmation' 'method=GET' || true)
	post_line=$(wait_line "$o" 10 'directory: email link confirmation' 'method=POST' || true)
	if [ "$scanned" = ready ] && [ "$confirmed" = confirmed ] && [[ $get_line == *result=ready* ]] &&
		[[ $post_line == *result=confirmed* ]]; then
		record m21-email-confirm PASS "the link (masked) opened: GET only \"ready\", then Confirm \"confirmed\"; $(short "$post_line")"
	else
		record m21-email-confirm FAIL "GET only: ${scanned:-nothing} (${get_line:+$(short "$get_line")}), Confirm: ${confirmed:-nothing} (${post_line:+$(short "$post_line")}); m21/confirm.txt"
	fi
	;;
*) record m21-email-confirm FAIL "no confirmation link under $SERVER_PUBLIC_URL/verify/email in an e-mail to $app_email (m21/latest.txt)" ;;
esac
link=
rm -f "$link_file"

stage m21-cli-match
if "$cli" match -identity "$profile" -phone "$app_number" -email "$app_email" -expect "$app_id" > "$out/match-linked.txt" 2>&1 &&
	grep -qxF "match $app_id (email, phone)" "$out/match-linked.txt"; then
	record m21-cli-match PASS "the CLI's own hashes find $app_id by the number and the address: $(grep -F "match $app_id" "$out/match-linked.txt")"
else
	record m21-cli-match FAIL "$(tail -n 2 "$out/match-linked.txt" | tr '\n' ' ' | cut -c1-200) (m21/match-linked.txt)"
fi
stage m21-email-status
if "$cli" link status -identity "$profile" -of "$app_id" -email "$app_email" > "$out/status.txt" 2>&1 &&
	grep -qxF "$app_id: e-mail linked" "$out/status.txt"; then
	record m21-email-status PASS "link status -of $app_id: e-mail linked"
else
	record m21-email-status FAIL "$(tail -n 1 "$out/status.txt" | cut -c1-200) (m21/status.txt)"
fi

stage m21-test-email-linked
o=$(offset)
if TEST_RUNNER_M21_EMAIL="$app_email" run_test testEmailLinked; then
	record m21-test-email-linked PASS "Linked Email opened again: the address, linked, and \"Unlink Email\""
else
	record m21-test-email-linked FAIL "xcodebuild test failed (m21/testEmailLinked.tail.txt)"
fi
stage m21-email-checked
if line=$(wait_line "$o" 10 'directory: email link checked' "identity=$app_id" 'linked=true'); then
	record m21-email-checked PASS "$(short "$line")"
else
	last=$(since "$o" 'directory: email link checked' "identity=$app_id" | tail -n 1)
	record m21-email-checked FAIL "no \"directory: email link checked\" linked=true for $app_id from the app${last:+; last: $(short "$last")}"
fi

stage m21-test-unlink
o=$(offset)
unlinked_phone=false
unlinked_email=false
run_test testUnlinkPhone && unlinked_phone=true
TEST_RUNNER_M21_EMAIL="$app_email" run_test testUnlinkEmail && unlinked_email=true
if [ "$unlinked_phone" = true ] && [ "$unlinked_email" = true ]; then
	record m21-test-unlink PASS "\"Unlink Number\" and \"Unlink Email\": both pages offer linking again"
else
	record m21-test-unlink FAIL "testUnlinkPhone passed: $unlinked_phone, testUnlinkEmail passed: $unlinked_email (m21/testUnlinkPhone.tail.txt, m21/testUnlinkEmail.tail.txt)"
fi
stage m21-unlinked
phone_line=$(wait_line "$o" 20 'directory: phone link removed' "identity=$app_id" 'result=removed' 'was_linked=true' ||
	since "$o" 'directory: phone link removed' "identity=$app_id" | tail -n 1)
email_line=$(wait_line "$o" 20 'directory: email link removed' "identity=$app_id" 'result=removed' 'was_linked=true' ||
	since "$o" 'directory: email link removed' "identity=$app_id" | tail -n 1)
"$cli" match -identity "$profile" -phone "$app_number" -email "$app_email" -expect none > "$out/match-unlinked.txt" 2>&1
matched=$?
if [[ $phone_line == *result=removed*was_linked=true* ]] && [[ $email_line == *result=removed*was_linked=true* ]] &&
	[ "$matched" = 0 ]; then
	record m21-unlinked PASS "$(short "$phone_line"); $(short "$email_line"); match: $(tail -n 1 "$out/match-unlinked.txt")"
else
	record m21-unlinked FAIL "phone: $(short "${phone_line:-no line}"); e-mail: $(short "${email_line:-no line}"); match: $(tail -n 1 "$out/match-unlinked.txt" | cut -c1-120)"
fi

stage m21-cli-phone
o=$(offset)
t=$(utc_now)
if "$cli" link phone -identity "$profile" -number "$cli_number" > "$out/link-phone.txt" 2>&1 &&
	grep -qF "$cli_id: verification SMS requested" "$out/link-phone.txt" &&
	line=$(wait_line "$o" 20 'directory: phone link requested' "identity=$cli_id" 'result=sent'); then
	record m21-cli-phone PASS "link phone $cli_number for $cli_id: $(short "$line")"
else
	record m21-cli-phone FAIL "$(tail -n 1 "$out/link-phone.txt" | cut -c1-160) (m21/link-phone.txt)"
fi
stage m21-call
o=$(offset)
t=$(utc_now)
calls_before=$(notify_count call)
calls_new() {
	local n end=$(($(date +%s) + 10))
	while :; do
		n=$(($(notify_count call) - ${calls_before:-0}))
		if [ "$n" -ge 1 ] || [ "$(date +%s)" -ge "$end" ]; then
			echo "$n"
			return
		fi
		sleep 1
	done
}
if "$cli" link call -identity "$profile" > "$out/link-call.txt" 2>&1 &&
	grep -qF "$cli_id: verification call requested" "$out/link-call.txt" &&
	line=$(wait_line "$o" 20 'directory: phone link call requested' "identity=$cli_id" 'result=placed'); then
	calls=$(calls_new)
	if [ "$calls" -ge 1 ]; then
		record m21-call PASS "link call: $(short "$line"); the stand-in received $calls call(s)"
	else
		record m21-call FAIL "link call: $(short "$line"), but the stand-in received no call (m21/notify.txt)"
	fi
else
	last=$(since "$o" 'directory: phone link call requested' | tail -n 1)
	record m21-call FAIL "$(tail -n 1 "$out/link-call.txt" | cut -c1-160)${last:+; $(short "$last")} (m21/link-call.txt)"
fi
stage m21-call-code
code=
if latest call "$cli_number" "$t" code "$call_code_file"; then
	code=$(head -n 1 "$call_code_file" | tr -d '\r\n ')
	add_secret "$code"
fi
if [[ $code =~ ^[0-9]{8}$ ]]; then
	record m21-call-code PASS "the call to $cli_number read out an 8-digit code (masked)"
else
	record m21-call-code FAIL "no 8-digit code in a call to $cli_number since $t (m21/latest.txt)"
fi
code=
stage m21-cli-verified
o=$(offset)
if [ -s "$call_code_file" ] && "$cli" link verify -identity "$profile" -code-file "$call_code_file" > "$out/link-verify.txt" 2>&1 &&
	grep -qF "$cli_id: phone number linked" "$out/link-verify.txt" &&
	line=$(wait_line "$o" 20 'directory: phone link code checked' "identity=$cli_id" 'result=linked'); then
	record m21-cli-verified PASS "link verify with the call's code: $(short "$line")"
else
	record m21-cli-verified FAIL "$(tail -n 1 "$out/link-verify.txt" 2> /dev/null | cut -c1-160) (m21/link-verify.txt)"
fi
rm -f "$call_code_file"
stage m21-cli-unlink
o=$(offset)
if "$cli" link unlink -identity "$profile" phone > "$out/link-unlink.txt" 2>&1 &&
	line=$(wait_line "$o" 20 'directory: phone link removed' "identity=$cli_id"); then
	record m21-cli-unlink INFO "$(short "$line")"
else
	record m21-cli-unlink INFO "the CLI's number may still be linked: $(tail -n 1 "$out/link-unlink.txt" | cut -c1-160)"
fi
record m21-notify-count INFO "the stand-in received $(notify_count sms) SMS, $(notify_count email) e-mail(s), $(notify_count call) call(s) in this milestone"
shot m21-09-final

failed=$(failing_stages "$M21_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 21: every stage passed"
