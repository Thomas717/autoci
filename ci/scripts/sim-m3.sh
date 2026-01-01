#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
root=$(ci_root)
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m3"
work="$RUNNER_TEMP/m2-driver"
name=cli
cli="$SRV/cli"
profile="$SEC/cli.json"
mkdir -p "$out/shots" "$RESULTS/m3"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

listen_pid=
finish() {
	if [ -n "$listen_pid" ]; then
		kill -INT "$listen_pid" 2> /dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$listen_pid" 2> /dev/null || break
			sleep 1
		done
		kill -KILL "$listen_pid" 2> /dev/null
		listen_pid=
	fi
	for f in register.txt features.txt send.txt listen.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m3/$f"
	done
}
trap finish EXIT

fail() {
	record "$1" FAIL "$2"
	exit 1
}

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

stage m3-cli
find_openssl || fail m3-cli "no OpenSSL 3"
why=$(decrypt_bin "$name" "$cli") || fail m3-cli "$why"
K=
unset K
if [ -n "${CI_CLI_BIN_OVERRIDE:-}" ]; then
	rm -f "$cli"
	cli="$SRV/$(basename "$CI_CLI_BIN_OVERRIDE")"
	cp "$CI_CLI_BIN_OVERRIDE" "$cli"
fi
chmod 700 "$cli"
printf '%s\n' "$cli" > "$SRV/cli.path"
if is_macos; then
	signature=$(codesign -dv "$cli" 2>&1 || true)
	case $signature in *Signature=adhoc*) ;; *) fail m3-cli "not ad-hoc signed" ;; esac
fi
record m3-cli PASS "$([ -n "${SRV_BIN:-}" ] && "$SRV_BIN" version 2> /dev/null || true)"

stage m3-register
line=$(wait_for_log 'directory: identity created' 5) || fail m3-register "no identity of the app in the server log"
app_id=$(printf '%s' "$line" | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[ -n "$app_id" ] || fail m3-register "no identity= in the server's line"

if ! "$cli" register -license - -signature-key "$(cat "$SRV/oppf-public.key")" -nickname "CI CLI" \
	-out "$profile" < "$SEC/license-cli.url" > "$out/register.txt" 2>&1; then
	tail -n 20 "$out/register.txt"
	fail m3-register "cli register failed (m3/register.txt)"
fi
key=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["clientKey"])' "$profile")
add_secret "$key"
key=
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
[[ $cli_id =~ ^[0-9A-Z]{8}$ ]] || fail m3-register "the CLI's profile holds no identity"
metric m3_app_id "$app_id"
metric m3_cli_id "$cli_id"
record m3-register PASS "CLI $cli_id on $CLI_SEAT_USERNAME; the app is $app_id"

if [ "${S4:-false}" = true ] || [ "${S6:-false}" = true ]; then
	stage cli-call-features
	bits=audio-calls,video-calls
	if [ "${S6:-false}" = true ]; then bits=$bits,group-calls; fi
	if "$cli" features -identity "$profile" -add "$bits" > "$out/features.txt" 2>&1; then
		record cli-call-features PASS "$(tail -n 1 "$out/features.txt" | cut -c1-160)"
	else
		tail -n 20 "$out/features.txt"
		record cli-call-features FAIL "cli features failed (m3/features.txt)"
	fi
fi

stage m3-send
nonce=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
inbound="M3 from the CLI $nonce"
reply="M3 reply from iOS $nonce"
if ! "$cli" send -identity "$profile" -to "$app_id" -text "$inbound" > "$out/send.txt" 2>&1; then
	tail -n 20 "$out/send.txt"
	fail m3-send "cli send failed (m3/send.txt)"
fi
sent_id=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id\$/\1/p" "$out/send.txt" | head -n 1)
[ -n "$sent_id" ] || fail m3-send "send did not name the message it sent"
record m3-send PASS "message $sent_id to $app_id: \"$inbound\""

"$cli" listen -identity "$profile" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!

stage m3-test
status=0
TEST_RUNNER_M3_INBOUND="$inbound" TEST_RUNNER_M3_REPLY="$reply" \
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
	-only-testing:OnboardingDriverUITests/MessagingTests \
	-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
	-resultBundlePath "$work/messaging.xcresult" -collect-test-diagnostics never \
	-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
	CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
	> "$out/xcodebuild-test.log" 2>&1 || status=$?
tail -n 150 "$out/xcodebuild-test.log" > "$RESULTS/m3/xcodebuild-test.tail.txt"
if ! export_attachments "$work/messaging.xcresult" "$out/shots" "$RESULTS/m3" m3-; then
	cp "$work/attachments-m3-.log" "$RESULTS/m3/export.log"
fi
if [ "$status" = 0 ]; then
	record m3-test PASS "the app showed the CLI's text and sent its answer"
else
	grep -E 'error:|failed|XCTAssert' "$out/xcodebuild-test.log" | head -n 20 || true
	record m3-test FAIL "xcodebuild test exit $status (m3/xcodebuild-test.tail.txt)"
fi

stage m3-reply
if wait_for_text "$out/listen.txt" "$reply" 60; then
	record m3-reply PASS "$(grep -F -- "$reply" "$out/listen.txt" | head -n 1 | cut -c1-200)"
else
	record m3-reply FAIL "the CLI did not receive \"$reply\" within 60 s (m3/listen.txt)"
fi
stage m3-receipt
receipt="delivery receipt (received) for $sent_id"
if grep -qF -- "$receipt" "$out/send.txt" || wait_for_text "$out/listen.txt" "$receipt" 30; then
	record m3-receipt PASS "$receipt"
else
	record m3-receipt FAIL "no \"$receipt\" from the app (m3/send.txt, m3/listen.txt)"
fi
if grep -qF -- "delivery receipt (read) for $sent_id" "$out/send.txt" "$out/listen.txt"; then
	record m3-read INFO "the app sent a read receipt as well"
else
	record m3-read INFO "no read receipt (the app's read receipts may be off)"
fi
shot m3-05-final

failed=$(failing_stages "$M3_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 3: every stage passed"
