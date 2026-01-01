#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SEAT_USERNAME:?}" "${SERVER_PUBLIC_URL:?}"
udid=$(sim_udid)
bid=$APP_BUNDLE_ID
app="$RUNNER_TEMP/app-run/Threema OnPrem.app"
out="$RESULTS_FULL/m12"
work="$RUNNER_TEMP/m2-driver"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m12" "$out/crash"
touch "$RUNNER_TEMP/m12-start-marker"

finish() {
	cockpit_sign_out
	(since "${m12_start:-0}" 'remote secret' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m12/duallock-lines.txt") 2> /dev/null || true
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
m12_start=$(offset)

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/RemoteSecretTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m12/$1.tail.txt"
	export_attachments "$work/$1.xcresult" "$out/shots" "$RESULTS/m12" m12- > /dev/null 2>&1 || true
	return "$status"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$bid" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m12-cockpit "no identity of the app in the server log"
[ -s "$SEC/safe-password.txt" ] || fail m12-cockpit "no Threema Safe password from milestone 9"
[ -s "$SEC/cockpit-password.txt" ] || fail m12-cockpit "no cockpit password: server-prepare.sh makes one for S12 and S14"

stage m12-cockpit
cockpit_sign_in || fail m12-cockpit "the cockpit's sign-in answered $COCKPIT_STATUS"
record m12-cockpit PASS "signed in as ci-admin"

stage m12-enable
status=$(cockpit PUT "/api/users/$SEAT_USERNAME/duallock" '{"remoteSecret":"on"}')
case $status in
2??) record m12-enable PASS "DualLock on for $SEAT_USERNAME (HTTP $status)" ;;
*) cp "$out/cockpit-answer.json" "$RESULTS/m12/enable-answer.json" 2> /dev/null; fail m12-enable "the cockpit answered $status" ;;
esac

size=$(since 0 'component=safe method=PUT status=20' | tail -n 1 | sed -n 's/.* size=\([0-9]*\).*/\1/p')
[[ $size =~ ^[1-9][0-9]*$ ]] || fail m12-reinstall "no size of milestone 9's backup in the server log"

stage m12-reinstall
groups=$(xcrun simctl get_app_container "$udid" "$bid" groups 2> /dev/null | awk '{ $1 = ""; sub(/^ /, ""); print }' || true)
xcrun simctl terminate "$udid" "$bid" > /dev/null 2>&1 || true
xcrun simctl uninstall "$udid" "$bid" > /dev/null 2>&1 || fail m12-reinstall "simctl uninstall failed"
while IFS= read -r dir; do
	[ -n "$dir" ] && [ -d "$dir" ] || continue
	case $dir in
	*/CoreSimulator/Devices/"$udid"/data/Containers/Shared/AppGroup/*) rm -rf "$dir" ;;
	esac
done <<EOF
$groups
EOF
xcrun simctl keychain "$udid" reset > /dev/null 2>&1 || echo "::warning::simctl keychain reset failed"
xcrun simctl keychain "$udid" add-root-cert "$SRV/tls/ca.crt" || fail m12-reinstall "add-root-cert after the reset failed"
xcrun simctl install "$udid" "$app" || fail m12-reinstall "simctl install refused the app"
record m12-reinstall PASS "uninstalled, keychain reset, CA trusted, reinstalled"

stage m12-mdm
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
	record m12-mdm PASS "licence and Safe restore of $app_id in the company MDM; DualLock from the server's Work Sync"
else
	fail m12-mdm "defaults write or launch failed"
fi

stage m12-restore-get
if line=$(wait_since "$o" 180 'component=safe method=GET status=200' "size=$size "); then
	record m12-restore-get PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m12-restore-get FAIL "no GET of the $size byte backup within 180 s"
fi
stage m12-created
if line=$(wait_since "$o" 180 'work: remote secret created'); then
	record m12-created PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m12-created FAIL "no \"work: remote secret created\" within 180 s (m12/duallock-lines.txt)"
fi

stage m12-test-restored
if run_test testRestoredWithDualLock; then
	record m12-test-restored PASS "the restored app reached the chat list, and Settings says DualLock is active"
else
	record m12-test-restored FAIL "xcodebuild test failed (m12/testRestoredWithDualLock.tail.txt)"
fi

stage m12-fetch
o=$(offset)
relaunch
if line=$(wait_since "$o" 90 'work: remote secret fetch' 'outcome=delivered'); then
	record m12-fetch PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m12-fetch FAIL "no delivered remote secret fetch within 90 s of a relaunch"
fi

stage m12-block
status=$(cockpit POST "/api/remote-secrets/$app_id/block")
case $status in
2??) record m12-block PASS "the cockpit blocked $app_id's remote secret (HTTP $status)" ;;
*) cp "$out/cockpit-answer.json" "$RESULTS/m12/block-answer.json" 2> /dev/null; record m12-block FAIL "the cockpit answered $status" ;;
esac
stage m12-test-locked
o=$(offset)
relaunch
blocked=$(wait_since "$o" 90 'work: remote secret fetch' 'outcome=blocked' || true)
if run_test testLocked && [ -n "$blocked" ]; then
	record m12-test-locked PASS "the fetch was refused (outcome=blocked) and the app says \"App Locked\""
else
	record m12-test-locked FAIL "blocked fetch: $([ -n "$blocked" ] && echo yes || echo no); test: m12/testLocked.tail.txt"
fi

status=$(cockpit POST "/api/remote-secrets/$app_id/unblock")
o=$(offset)
relaunch
if [ "${status#2}" != "$status" ] && wait_since "$o" 90 'work: remote secret fetch' 'outcome=delivered' > /dev/null &&
	run_test testUnlocked; then
	record m12-unblocked INFO "unblocked: the fetch delivered again and the app opened"
else
	record m12-unblocked INFO "after the unblock (HTTP $status) the app did not open again (m12/testUnlocked.tail.txt)"
fi

find "$HOME/Library/Logs/DiagnosticReports" -name '*Threema*' -newer "$RUNNER_TEMP/m12-start-marker" \
	-exec cp {} "$out/crash/" \; 2> /dev/null || true
record m12-crashes INFO "$(find "$out/crash" -type f | wc -l | tr -d ' ') crash report(s) since the reinstall"
shot m12-09-final

failed=$(failing_stages "$M12_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 12: every stage passed"
