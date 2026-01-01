#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_SALTYRTC_PORT:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m20"
work="$RUNNER_TEMP/m2-driver"
cli=$(cat "$SRV/cli.path")
web_out="$SEC/m20-web.out"
srv_host=${SERVER_HOST:-localhost}
signalling="wss://$srv_host:$SERVER_SALTYRTC_PORT"
marker="$RUNNER_TEMP/m20-start-marker"
mkdir -p "$out/shots" "$RESULTS/m20"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"
: > "$marker"
log_start=$(date '+%Y-%m-%d %H:%M:%S')
raw_log="$SEC/m20-xcodebuild.log"

blank_log() {
	sed -E -e "s/(Typ[a-z]* )'[^']*'/\1'***'/g" -e 's/(Typ[a-z]* )"[^"]*"/\1"***"/g' "$1" > "$2" || true
	rm -f "$1"
}

web_pid=
stop_web() {
	[ -n "$web_pid" ] || return 0
	kill -INT "$web_pid" 2> /dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$web_pid" 2> /dev/null || break
		sleep 1
	done
	kill -KILL "$web_pid" 2> /dev/null
	wait "$web_pid" 2> /dev/null
	web_pid=
}
finish() {
	stop_web
	[ -f "$raw_log" ] && blank_log "$raw_log" "$out/testConnect.log"
	if [ -f "$web_out" ]; then
		grep -v -e '^qr payload:' -e ' -qr ' "$web_out" | sed -E 's/pushToken:[^] ]*/pushToken:(left out)/g' \
			> "$out/initiator.txt" 2> /dev/null
		cp "$out/initiator.txt" "$RESULTS/m20/initiator.txt"
	fi
	rm -f "$web_out"
	[ -f "$out/initiator.stderr.txt" ] && cp "$out/initiator.stderr.txt" "$RESULTS/m20/initiator.stderr.txt"
	(since "${m20_start:-0}" 'saltyrtc: ' | sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m20/saltyrtc-lines.txt") 2> /dev/null || true
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
m20_start=$(offset)

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 1
	done
}

run_test() {
	local status=0
	rm -f "$raw_log"
	(umask 077 && : > "$raw_log")
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/ThreemaWebTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m20-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		>> "$raw_log" 2>&1 || status=$?
	blank_log "$raw_log" "$out/$1.log"
	tail -n 150 "$out/$1.log" > "$RESULTS/m20/$1.tail.txt"
	export_attachments "$work/m20-$1.xcresult" "$out/shots" "$RESULTS/m20" m20- > /dev/null 2>&1 || true
	return "$status"
}

pub=$(tr -d '\r\n' < "$SRV/saltyrtc-public.key" 2> /dev/null)

patch0001=0001-simulator-threema-web-qr.patch
if ! grep -q "^source patch: $patch0001 " "$RUNNER_TEMP/app/build-info.txt" 2> /dev/null; then
	stage m20-test
	fail m20-test "the app under test was built without ci/build/patches/$patch0001 (build/build-info.txt), so it has no \"Web QR payload\" field"
fi

stage m20-tls
tls12() {
	if openssl_libre; then
		local a=${1#\[}
		a=${a/\]:/:}
		"${OPENSSL:?}" s_client -connect "$a" -servername "$srv_host" -CAfile "$SRV/tls/ca.crt" \
			-tls1_2 -verify_return_error < /dev/null 2>&1 || true
		return
	fi
	"${OPENSSL:?}" s_client -connect "$1" -servername "$srv_host" -verify_hostname "$srv_host" -CAfile "$SRV/tls/ca.crt" \
		-tls1_2 -verify_return_error -brief < /dev/null 2>&1 || true
}
tls_verdict() {
	if printf '%s\n' "$1" | grep -Eq '^(Protocol version: | +Protocol +: )TLSv1\.2' &&
		printf '%s\n' "$1" | grep -Eq '^(Verification: OK| +Verify return code: 0 \(ok\))'; then
		echo "TLS 1.2, verified ($(printf '%s\n' "$1" | awk -F': ' '/^Ciphersuite|^ +Cipher +:/ { print $2; exit }'))"
	else
		echo "no verified TLS 1.2"
	fi
}
if find_openssl > /dev/null 2>&1; then
	v4=$(tls12 "127.0.0.1:$SERVER_SALTYRTC_PORT")
	v6=$(tls12 "[::1]:$SERVER_SALTYRTC_PORT")
	printf '## 127.0.0.1:%s, -tls1_2\n%s\n## [::1]:%s, -tls1_2\n%s\n' "$SERVER_SALTYRTC_PORT" "$v4" \
		"$SERVER_SALTYRTC_PORT" "$v6" > "$RESULTS/m20/tls.txt"
	record m20-tls INFO "port $SERVER_SALTYRTC_PORT: IPv4 $(tls_verdict "$v4"); IPv6 $(tls_verdict "$v6")"
else
	record m20-tls INFO "no OpenSSL 3 to check with"
fi

stage m20-initiator
[[ $pub =~ ^[0-9a-f]{64}$ ]] || fail m20-initiator "no SaltyRTC public key of this run (server-prepare.sh makes one for S20)"
configured=$(grep -F 'SaltyRTC signalling server configured' "$SRV/server.log" | tail -n 1)
case $configured in
*"publicKey=$pub"*) ;;
*) fail m20-initiator "the server did not start its signalling server with this run's key" ;;
esac
rm -f "$web_out"
(umask 077 && : > "$web_out")
"$cli" web -role initiator -server "$signalling" -server-key "$pub" -duration 15m \
	>> "$web_out" 2> "$out/initiator.stderr.txt" 3>&- &
web_pid=$!
payload=
for _ in $(seq 1 30); do
	payload=$(sed -n 's|^qr payload: \([A-Za-z0-9+/=]*\)$|\1|p' "$web_out" 2> /dev/null | head -n 1)
	[ -n "$payload" ] && break
	kill -0 "$web_pid" 2> /dev/null || break
	sleep 1
done
add_secret "$payload"
if ! [[ $payload =~ ^[A-Za-z0-9+/]{100,}={0,2}$ ]]; then
	tail -n 20 "$out/initiator.stderr.txt"
	fail m20-initiator "web -role initiator printed no QR payload (m20/initiator.stderr.txt)"
fi
if ! wait_for_text "$web_out" 'connected as 0x' 30; then
	tail -n 20 "$out/initiator.stderr.txt"
	fail m20-initiator "the CLI did not get onto its path in 30 s (m20/initiator.stderr.txt)"
fi
line=$(grep -F 'connected as 0x' "$web_out" | head -n 1)
case $line in
"connected as 0x01, signed_keys verified: true")
	record m20-initiator PASS "on $signalling: $line; QR payload masked" ;;
*) fail m20-initiator "$line (want 0x01, with the server's signed_keys verified)" ;;
esac

xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
	> /dev/null 2>&1 || true
sleep 5

stage m20-test
tested=false
TEST_RUNNER_M20_PAYLOAD="$payload" run_test testConnect && tested=true
payload=
handshake=$(grep -E '^peer connection id: [0-9a-f]+ \(resumable: (true|false)\)$' "$web_out" 2> /dev/null | head -n 1)
if [ "$tested" = true ] && [ -n "$handshake" ]; then
	record m20-test PASS "the payload typed into the Desktop/Web screen's field, Connect: the app completed the ARP handshake with the CLI, and the session showed active (\"Stop Session\") with the app still running 15 s later"
elif [ "$tested" = true ]; then
	record m20-test FAIL "the session showed active (\"Stop Session\"), but the CLI saw no ARP handshake from the app (m20/initiator.txt): the app only started connecting"
else
	record m20-test FAIL "xcodebuild test failed (m20/testConnect.tail.txt, m20/m20-session.txt)"
fi
shot m20-09-final
wait_for_text "$web_out" 'clientInfo:' 10 > /dev/null || true
for _ in $(seq 1 15); do
	kill -0 "$web_pid" 2> /dev/null || break
	sleep 1
done
stop_web

stage m20-server
pair=$(since "$m20_start" 'saltyrtc: client authenticated' | awk '
	{
		p = ""; a = ""; i = ""
		for (k = 1; k <= NF; k++) {
			if ($k ~ /^path=/) p = substr($k, 6)
			else if ($k ~ /^address=/) a = substr($k, 9)
			else if ($k ~ /^initiator=/) i = substr($k, 11)
		}
		if (p == "") next
		if ((a == "1" || a == "0x01") && i == "true") init[p] = 1
		else if (a != "" && a != "0" && a != "1" && a != "0x01" && i == "false") resp[p] = a
	}
	END { for (p in init) if (p in resp) { print p " " resp[p]; exit } }')
if [ -n "$pair" ]; then
	record m20-server PASS "path ${pair% *}: the initiator (address 1) and a responder (address ${pair#* }) authenticated"
else
	n=$(since "$m20_start" 'saltyrtc: client authenticated' | wc -l | tr -d ' ')
	record m20-server FAIL "no initiator and responder authenticated on one path ($n client(s) authenticated; m20/saltyrtc-lines.txt)"
fi

stage m20-peer
task=$(sed -n 's/^task: *//p' "$web_out" 2> /dev/null | head -n 1)
peer=$(sed -n 's/^peer: *//p' "$web_out" 2> /dev/null | head -n 1)
handshake=$(grep -E '^peer connection id: [0-9a-f]+ \(resumable: (true|false)\)$' "$web_out" 2> /dev/null | head -n 1)
info=$(grep -E '^clientInfo: +device ' "$web_out" 2> /dev/null | head -n 1)
problems=
[ "$task" = v0.relayed-data.tasks.saltyrtc.org ] || problems="$problems; task ${task:-none}"
[ -n "$handshake" ] || problems="$problems; no ARP handshake (peer connection id)"
case $info in
*'", ios '*) ;;
*) problems="$problems; no response/clientInfo from the app" ;;
esac
if [ -z "$problems" ]; then
	record m20-peer PASS "task $task, peer $peer, ${handshake#peer connection id: }; response/clientInfo: ${info#clientInfo:*device }"
else
	record m20-peer FAIL "${problems#; } (m20/initiator.txt)"
fi

session=$(tr '\n' ' ' < "$RESULTS/m20/m20-session.txt" 2> /dev/null | cut -c1-300)
record m20-session INFO "${session:-no report from the test}"
disconnect=$(grep -F -A 1 '<- update/connectionDisconnect' "$web_out" 2> /dev/null | sed -n 's/^   data: //p' | head -n 1)
if grep -qF '<- update/connectionDisconnect' "$web_out" 2> /dev/null; then
	record m20-stop INFO "the app's update/connectionDisconnect reached the CLI${disconnect:+: $disconnect}"
else
	record m20-stop INFO "no update/connectionDisconnect from the app"
fi
crashes=$(find "$HOME/Library/Logs/DiagnosticReports" -name '*Threema*' -newer "$marker" 2> /dev/null | wc -l | tr -d ' ')
record m20-crash INFO "$crashes crash report(s) of the app during milestone 20 (crashes/)"
xcrun simctl spawn "$udid" log show --start "$log_start" --info --debug --style compact \
	--predicate 'process BEGINSWITH "Threema"' > "$out/app-oslog.txt" 2>&1 || true
grep -E 'Threema Web|[Ss]alty' "$out/app-oslog.txt" | tail -n 400 | cut -c1-400 > "$RESULTS/m20/app-web-log.txt" || true

failed=$(failing_stages "$M20_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 20: every stage passed"
