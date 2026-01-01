#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
bid=$APP_BUNDLE_ID
out="$RESULTS_FULL/m9"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
password_file="$SEC/safe-password.txt"
cli=$(cat "$SRV/cli.path")
mkdir -p "$out/shots" "$RESULTS/m9"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

finish() {
	[ -f "$out/check.txt" ] && cp "$out/check.txt" "$RESULTS/m9/check.txt"
	(since "${m9_start:-0}" 'component=safe' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m9/safe-lines.txt") 2> /dev/null || true
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
m9_start=$(offset)

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

launch_app() {
	xcrun simctl launch --terminate-running-process "$udid" "$bid" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile")
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m9-password "no identity of the app in the server log"

stage m9-password
find_openssl || fail m9-password "no OpenSSL 3"
(umask 077 && "$OPENSSL" rand -hex 16 > "$password_file") || fail m9-password "openssl rand failed"
pw=$(cat "$password_file")
add_secret "$pw"
[[ $pw =~ ^[0-9a-f]{32}$ ]] || fail m9-password "the password is not 32 hex digits"
record m9-password PASS "32 hex digits in an owner-only file, masked"

stage m9-mdm
container=$(xcrun simctl get_app_container "$udid" "$bid" data 2> /dev/null || true)
xcrun simctl terminate "$udid" "$bid" > /dev/null 2>&1 || true
ok=false
if xcrun simctl spawn "$udid" defaults write "$bid" com.apple.configuration.managed -dict-add \
	th_safe_enable true th_safe_password "$pw" > /dev/null 2>&1; then
	ok=true
fi
if [ -n "$container" ]; then
	xcrun simctl spawn "$udid" defaults write "$container/Library/Preferences/$bid" com.apple.configuration.managed \
		-dict-add th_safe_enable true th_safe_password "$pw" > /dev/null 2>&1 || true
fi
pw=
o=$(offset)
if [ "$ok" = true ] && launch_app; then
	record m9-mdm PASS "th_safe_enable and th_safe_password in the company MDM, app relaunched"
else
	fail m9-mdm "defaults write or relaunch failed"
fi

stage m9-backup
if ! line=$(wait_since "$o" 90 'component=safe method=PUT status=201'); then
	launch_app || true
	record m9-relaunch INFO "no backup within 90 s; relaunched once"
	line=$(wait_since "$o" 90 'component=safe method=PUT status=201') || line=
fi
if [ -n "$line" ]; then
	record m9-backup PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m9-backup FAIL "no \"safe: request handled method=PUT status=201\" since the relaunch (m9/safe-lines.txt)"
fi

stage m9-test
o=$(offset)
status=0
xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
	-only-testing:OnboardingDriverUITests/SafeTests/testSafeDashboard \
	-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
	-resultBundlePath "$work/safe.xcresult" -collect-test-diagnostics never \
	-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
	CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
	> "$out/xcodebuild-test.log" 2>&1 || status=$?
tail -n 150 "$out/xcodebuild-test.log" > "$RESULTS/m9/xcodebuild-test.tail.txt"
export_attachments "$work/safe.xcresult" "$out/shots" "$RESULTS/m9" m9- > /dev/null 2>&1 || true
if [ "$status" = 0 ]; then
	record m9-test PASS "the Threema Safe dashboard says \"Successful\""
else
	record m9-test FAIL "xcodebuild test exit $status (m9/xcodebuild-test.tail.txt)"
fi
if line=$(wait_since "$o" 20 'component=safe method=PUT status=204'); then
	record m9-overwrite INFO "Create Backup: $(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160)"
else
	record m9-overwrite INFO "no overwrite (PUT 204) after Create Backup"
fi
deletes=$(since "$m9_start" 'component=safe method=DELETE' | wc -l | tr -d ' ')
[ "$deletes" = 0 ] || record m9-delete INFO "$deletes DELETE(s): the app deactivated Safe in between"

stage m9-check
if "$cli" safe-check -identity "$profile" -of "$app_id" -password-file "$password_file" \
	-expect-contact "$cli_id" > "$out/check.txt" 2>&1; then
	record m9-check PASS "$(grep -F 'safe backup of' "$out/check.txt" | head -n 1 | cut -c1-200)"
else
	tail -n 5 "$out/check.txt"
	record m9-check FAIL "safe-check failed (m9/check.txt)"
fi

xcrun simctl spawn "$udid" log show --last 10m --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema"' > "$out/app-oslog.txt" 2>&1 || true
grep -E 'Safe backup|ThreemaSafe|Threema Safe|SafeManager|SafeStore' "$out/app-oslog.txt" |
	grep -v -i 'password' | tail -n 200 | cut -c1-400 > "$RESULTS/m9/app-safe-log.txt" || true
shot m9-09-final

failed=$(failing_stages "$M9_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 9: every stage passed"
