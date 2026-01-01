#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${SRV:?}" "${SEC:?}" "${SIM:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${APP_BUNDLE_ID:?}" "${APP_GROUP:?}"
udid=$(sim_udid)
app="$RUNNER_TEMP/app-run/Threema OnPrem.app"
bid=$APP_BUNDLE_ID
mkdir -p "$RESULTS/sim" "$RESULTS_FULL/sim"
touch "$RUNNER_TEMP/m1-start-marker"

passed() { [ "$(stage_status "$1")" = PASS ]; }

stage sim-boot
xcrun simctl boot "$udid" > /dev/null 2>&1 || true
if xcrun simctl bootstatus "$udid" -b > "$RESULTS_FULL/sim/bootstatus.txt" 2>&1; then
	xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 > /dev/null 2>&1 || true
	record sim-boot PASS "$udid"
else
	tail -n 20 "$RESULTS_FULL/sim/bootstatus.txt"
	record sim-boot FAIL "bootstatus failed"
fi
shot 00-booted

stage cert-trust
if passed sim-boot && xcrun simctl keychain "$udid" add-root-cert "$SRV/tls/ca.crt"; then
	record cert-trust PASS "simctl keychain add-root-cert"
else
	record cert-trust FAIL "add-root-cert failed"
fi

stage install
installed=false
install_note=
if passed sim-boot; then
	if xcrun simctl install "$udid" "$app"; then
		installed=true
	else
		sleep 15
		install_note="at the second try, 15 s after the first failed"
		xcrun simctl install "$udid" "$app" && installed=true
	fi
fi
if [ "$installed" = true ]; then
	record install PASS "$install_note"
else
	record install FAIL "simctl install refused the app${install_note:+ (twice)}"
fi
shot 01-installed

stage app-group
if passed install; then
	{
		echo "## get_app_container groups"
		xcrun simctl get_app_container "$udid" "$bid" groups 2>&1
		echo "## get_app_container data"
		xcrun simctl get_app_container "$udid" "$bid" data 2>&1
	} > "$RESULTS/sim/app-groups.txt"
	if grep -q "^$APP_GROUP" "$RESULTS/sim/app-groups.txt"; then
		record app-group PASS "$APP_GROUP"
	else
		record app-group FAIL "no $APP_GROUP container"
	fi
else
	record app-group SKIP "not installed"
fi

stage launch
launched=false
launch_app() {
	xcrun simctl launch --terminate-running-process \
		--stdout="$RESULTS_FULL/sim/app-stdout.log" --stderr="$RESULTS_FULL/sim/app-stderr.log" \
		"$udid" "$bid" -AppleLanguages "(en)" -AppleLocale en_US
}
if passed install; then
	if out=$(launch_app 2>&1); then
		launched=true
		record launch PASS "$out"
	else
		record launch FAIL "simctl launch: $out"
	fi
else
	record launch SKIP "not installed"
fi

stage alive
if [ "$launched" = true ]; then
	sleep 20
	xcrun simctl spawn "$udid" launchctl list > "$RESULTS_FULL/sim/launchctl.txt" 2>&1 || true
	if grep -q "UIKitApplication:$bid" "$RESULTS_FULL/sim/launchctl.txt"; then
		record alive PASS "running after 20 s"
	else
		record alive FAIL "not running 20 s after the launch"
	fi
else
	record alive SKIP "not launched"
fi
shot 02-launched

stage licence-link
if [ "$launched" = true ]; then
	if [ "${ROUTE:-link}" = mdm ]; then
		pw=$(cat "$SEC/seat-password.txt")
		container=$(xcrun simctl get_app_container "$udid" "$bid" data 2>/dev/null || true)
		xcrun simctl terminate "$udid" "$bid" > /dev/null 2>&1 || true
		ok=false
		if xcrun simctl spawn "$udid" defaults write "$bid" com.apple.configuration.managed -dict \
			th_license_username "$SEAT_USERNAME" th_license_password "$pw" th_onprem_server "$SERVER_PUBLIC_URL"; then
			ok=true
		fi
		if [ -n "$container" ]; then
			xcrun simctl spawn "$udid" defaults write "$container/Library/Preferences/$bid" com.apple.configuration.managed -dict \
				th_license_username "$SEAT_USERNAME" th_license_password "$pw" th_onprem_server "$SERVER_PUBLIC_URL" || true
		fi
		pw=
		if [ "$ok" = true ] && launch_app > /dev/null 2>&1; then
			record licence-link PASS "mdm: com.apple.configuration.managed set, app relaunched"
		else
			record licence-link FAIL "mdm: defaults write or relaunch failed"
		fi
	else
		if xcrun simctl openurl "$udid" "$(cat "$SEC/license.url")"; then
			record licence-link PASS "simctl openurl threemaonprem://license?…"
		else
			record licence-link FAIL "simctl openurl failed"
		fi
	fi
	sleep 3
else
	record licence-link SKIP "not launched"
fi
shot 03-link-opened

stage oppf-served
if passed licence-link && line=$(wait_for_log 'provisioning: served the provisioning file' 90); then
	record oppf-served PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record oppf-served FAIL "no 'provisioning: served the provisioning file' within 90 s"
fi
stage licence-valid
if passed licence-link && line=$(wait_for_log 'directory: license checked' 60 'result=valid'); then
	record licence-valid PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record licence-valid FAIL "no 'directory: license checked result=valid' within 60 s"
fi
stage work-data
if passed licence-link && line=$(wait_for_log 'work: work data fetched' 60); then
	record work-data PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record work-data FAIL "no 'work: work data fetched' within 60 s (reported, not required)"
fi
sleep 10
shot 04-after-licence
if [ -s "$RESULTS_FULL/shots/04-after-licence.png" ]; then
	record shot-04 PASS
else
	record shot-04 FAIL "no screenshot after the licence step"
fi

sleep 30
shot 05-settled

stage app-logs
xcrun simctl spawn "$udid" log show --last 20m --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema"' > "$RESULTS_FULL/sim/app-oslog.txt" 2>&1 || true
mkdir -p "$RESULTS_FULL/sim/crash"
find "$HOME/Library/Logs/DiagnosticReports" -name '*Threema*' -newer "$RUNNER_TEMP/m1-start-marker" \
	-exec cp {} "$RESULTS_FULL/sim/crash/" \; 2>/dev/null || true
crashes=$(find "$RESULTS_FULL/sim/crash" -type f | wc -l | tr -d ' ')
ls -l "$RESULTS_FULL/sim/crash" > "$RESULTS/sim/crash-reports.txt" 2>&1 || true
tls_errors=$(grep -c 'TLS handshake error' "$SRV/server.log" 2>/dev/null || true)
metric crash_reports "${crashes:-0}"
metric tls_handshake_errors "${tls_errors:-0}"
if [ "${crashes:-0}" = 0 ]; then
	record no-crash PASS "no crash report"
else
	record no-crash FAIL "$crashes crash report(s) (reported, not required)"
fi
record app-logs INFO "os_log $(wc -c < "$RESULTS_FULL/sim/app-oslog.txt" | tr -d ' ') bytes, $tls_errors TLS handshake error line(s)"

own="sim-boot cert-trust install app-group launch alive licence-link oppf-served licence-valid shot-04"
failed=$(failing_stages "$own")
if [ -n "$failed" ]; then
	echo "stage 1: stages that did not pass:"
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 1: every stage passed"
