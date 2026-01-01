#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SEAT_USERNAME:?}" "${SERVER_PUBLIC_URL:?}"
udid=$(sim_udid)
bid=$APP_BUNDLE_ID
app="$RUNNER_TEMP/app-run/Threema OnPrem.app"
out="$RESULTS_FULL/m10"
work="$RUNNER_TEMP/m2-driver"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m10" "$out/crash"
touch "$RUNNER_TEMP/m10-start-marker"

finish() {
	load_sampler_stop
	cockpit_sign_out
	(since "${m10_start:-0}" 'directory: ' | grep -E 'private info fetched|identities fetched in bulk' | sed 's/^time=[^ ]* //' |
		cut -c1-200 > "$RESULTS/m10/lookup-lines.txt") 2> /dev/null || true
	(since "${m10_start:-0}" 'chatserver: device cookie' | sed 's/^time=[^ ]* //' | cut -c1-200 \
		>> "$RESULTS/m10/lookup-lines.txt") 2> /dev/null || true
	(since "${m10_start:-0}" 'component=safe' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m10/safe-lines.txt") 2> /dev/null || true
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
m10_start=$(offset)

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m10-reinstall "no identity of the app in the server log"
[ -s "$SEC/safe-password.txt" ] || fail m10-reinstall "no Threema Safe password from milestone 9"
size=$(since 0 'component=safe method=PUT status=20' | tail -n 1 | sed -n 's/.* size=\([0-9]*\).*/\1/p')
[[ $size =~ ^[1-9][0-9]*$ ]] || fail m10-reinstall "no size of milestone 9's backup in the server log"

stage m10-reinstall
groups=$(xcrun simctl get_app_container "$udid" "$bid" groups 2> /dev/null | awk '{ $1 = ""; sub(/^ /, ""); print }' || true)
xcrun simctl terminate "$udid" "$bid" > /dev/null 2>&1 || true
xcrun simctl uninstall "$udid" "$bid" > "$out/uninstall.txt" 2>&1 || fail m10-reinstall "simctl uninstall failed"
left=0
while IFS= read -r dir; do
	[ -n "$dir" ] && [ -d "$dir" ] || continue
	case $dir in
	*/CoreSimulator/Devices/"$udid"/data/Containers/Shared/AppGroup/*) ;;
	*) echo "::warning::not removing $dir: not an app group container of this simulator"; continue ;;
	esac
	left=$((left + 1))
	rm -rf "$dir"
done <<EOF
$groups
EOF
xcrun simctl keychain "$udid" reset > /dev/null 2>&1 || echo "::warning::simctl keychain reset failed"
xcrun simctl keychain "$udid" add-root-cert "$SRV/tls/ca.crt" || fail m10-reinstall "add-root-cert after the reset failed"
xcrun simctl install "$udid" "$app" || fail m10-reinstall "simctl install refused the app"
record m10-reinstall PASS "uninstalled; $left group container(s) outlived it and were removed; keychain reset, CA trusted, reinstalled"

load_sampler_start m10-load "$RESULTS/m10/load.txt" 900

stage m10-mdm
pw=$(cat "$SEC/seat-password.txt")
safe_pw=$(cat "$SEC/safe-password.txt")
o=$(offset)
container=$(xcrun simctl get_app_container "$udid" "$bid" data 2> /dev/null || true)
ok=false
if xcrun simctl spawn "$udid" defaults write "$bid" com.apple.configuration.managed -dict \
	th_license_username "$SEAT_USERNAME" th_license_password "$pw" th_onprem_server "$SERVER_PUBLIC_URL" \
	th_safe_enable true th_safe_password "$safe_pw" th_safe_restore_id "$app_id" > /dev/null 2>&1; then
	ok=true
fi
if [ -n "$container" ]; then
	xcrun simctl spawn "$udid" defaults write "$container/Library/Preferences/$bid" com.apple.configuration.managed -dict \
		th_license_username "$SEAT_USERNAME" th_license_password "$pw" th_onprem_server "$SERVER_PUBLIC_URL" \
		th_safe_enable true th_safe_password "$safe_pw" th_safe_restore_id "$app_id" > /dev/null 2>&1 || true
fi
pw=
safe_pw=
if [ "$ok" = true ] && xcrun simctl launch "$udid" "$bid" -AppleLanguages "(en)" -AppleLocale en_US > /dev/null 2>&1; then
	record m10-mdm PASS "licence, th_safe_enable, th_safe_password and th_safe_restore_id $app_id; app launched"
else
	fail m10-mdm "defaults write or launch failed"
fi

stage m10-restore-get
if line=$(wait_since "$o" 180 'component=safe method=GET status=200' "size=$size "); then
	record m10-restore-get PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m10-restore-get FAIL "no GET of the ${size:-?} byte backup within 180 s (m10/safe-lines.txt)"
fi

stage m10-test
status=0
xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
	-only-testing:OnboardingDriverUITests/SafeRestoreTests/testRestoredByMDM \
	-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
	-resultBundlePath "$work/restore.xcresult" -collect-test-diagnostics never \
	-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
	CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
	> "$out/xcodebuild-test.log" 2>&1 || status=$?
tail -n 150 "$out/xcodebuild-test.log" > "$RESULTS/m10/xcodebuild-test.tail.txt"
export_attachments "$work/restore.xcresult" "$out/shots" "$RESULTS/m10" m10- > /dev/null 2>&1 || true
if [ "$status" = 0 ]; then
	record m10-test PASS "the restored app reached the chat list and lists the CLI"
else
	record m10-test FAIL "xcodebuild test exit $status (m10/xcodebuild-test.tail.txt)"
fi

stage m10-same-id
created=$(since "$o" 'directory: identity created' | wc -l | tr -d ' ')
if line=$(wait_since "$o" 60 'chatserver: client connected' "identity=$app_id") && [ "$created" = 0 ]; then
	record m10-same-id PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m10-same-id FAIL "$created new ID(s) since the reinstall; $app_id connected: $([ -n "${line:-}" ] && echo yes || echo no)"
fi
login=$(since "$o" 'chatserver: client connected' "identity=$app_id" | head -n 1 | sed -n 's/^time=\([^ ]*\) .*/\1/p')
load_sampler_stop "$login"
if line=$(wait_since "$o" 30 'component=safe method=PUT'); then
	record m10-safe-again INFO "Safe on again after the restore: $(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-120)"
else
	record m10-safe-again INFO "no backup after the restore yet"
fi

stage m10-fetch-priv
line=$(since "$o" 'directory: private info fetched' "identity=$app_id" | tail -n 1)
case $line in
*result=sent*) record m10-fetch-priv PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)" ;;
'') record m10-fetch-priv FAIL "no identity/fetch_priv for $app_id since the reinstall (m10/lookup-lines.txt)" ;;
*) record m10-fetch-priv FAIL "identity/fetch_priv was not answered: $(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-160)" ;;
esac
stage m10-fetch-bulk
bulk=$(since "$o" 'directory: identities fetched in bulk')
lookups=$(printf '%s\n' "$bulk" | grep -c 'fetched in bulk' || true)
line=$(printf '%s\n' "$bulk" | grep -E ' found=[1-9][0-9]*( |$)' | tail -n 1)
if [ -n "$line" ]; then
	record m10-fetch-bulk PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200) ($lookups bulk lookup(s) since the reinstall)"
else
	last=$(printf '%s\n' "$bulk" | sed '/^$/d' | tail -n 1 | sed 's/^time=[^ ]* //' | cut -c1-160)
	record m10-fetch-bulk FAIL "no identity/fetch_bulk with a contact found since the reinstall ($lookups lookup(s); last: ${last:-none})"
fi

stage m10-cookie
warned=$(since "$o" 'chatserver: device cookie mismatch' | tail -n 1)
told=$(since "$o" 'chatserver: device cookie change indicated' "identity=$app_id" | grep -F 'changed_now=true' | tail -n 1)
cleared=$(wait_since "$o" 30 'chatserver: device cookie change cleared' "identity=$app_id") || cleared=
if [ -n "$warned" ] && [ -n "$told" ] && [ -n "$cleared" ]; then
	record m10-cookie PASS "the mismatch noticed, the app's login told (changed_now=true), and the app cleared it"
else
	record m10-cookie FAIL "mismatch noticed: $([ -n "$warned" ] && echo yes || echo no), login told: $([ -n "$told" ] && echo yes || echo no), cleared: $([ -n "$cleared" ] && echo yes || echo no) (m10/lookup-lines.txt)"
fi
stage m10-cookie-cleared
mismatch=
if cockpit_sign_in; then
	status=$(cockpit GET "/api/identities?q=$app_id")
	mismatch=$(python3 -I -c 'import json, sys
for i in json.load(open(sys.argv[1])).get("identities", []):
    if i.get("identity") == sys.argv[2]:
        print(str(i.get("deviceCookieMismatch")).lower())' "$COCKPIT_ANSWER" "$app_id" 2> /dev/null | tr -d '\r')
	cockpit_sign_out
	if [ "$mismatch" = false ]; then
		record m10-cookie-cleared PASS "the cockpit lists $app_id with deviceCookieMismatch false"
	else
		record m10-cookie-cleared FAIL "the cockpit answered $status, deviceCookieMismatch ${mismatch:-not found} for $app_id"
	fi
else
	record m10-cookie-cleared FAIL "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S10)"
fi

find "$HOME/Library/Logs/DiagnosticReports" -name '*Threema*' -newer "$RUNNER_TEMP/m10-start-marker" \
	-exec cp {} "$out/crash/" \; 2> /dev/null || true
crashes=$(find "$out/crash" -type f | wc -l | tr -d ' ')
record m10-crashes INFO "$crashes crash report(s) since the reinstall"
xcrun simctl spawn "$udid" log show --last 10m --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema" AND subsystem != "com.apple.dt.xctest"' > "$out/app-oslog.txt" 2>&1 || true
grep -E 'ThreemaSafe Restore|Restoring ThreemaSafe|RestoreSafe|SafeManager|Restore failed' "$out/app-oslog.txt" |
	grep -v -i 'password' | tail -n 200 | cut -c1-400 > "$RESULTS/m10/app-restore-log.txt" || true
shot m10-09-final

failed=$(failing_stages "$M10_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 10: every stage passed"
