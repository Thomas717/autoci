#!/bin/bash
set -uo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" "${APP_GROUP:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SERVER_HTTP_PORT:?}" "${SEAT_USERNAME:?}" "${SRV_BIN:?}"
host=${SERVER_HOST:-localhost}
udid=$(sim_udid)
out="$RESULTS_FULL/m26"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
marker="$RUNNER_TEMP/m26-start-marker"
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m26"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"
: > "$marker"
spki_re='^[A-Za-z0-9+/]{43}=$'
listen_pid=
opened=false

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
	if [ "$opened" = true ] && { [ -s "$SEC/cockpit.csrf" ] || cockpit_sign_in; }; then
		cockpit POST /api/provisioning/fallback/close '{}' > /dev/null 2>&1 || true
	fi
	cockpit_sign_out
	for f in send.txt listen.txt; do
		[ -f "$out/$f" ] && cp "$out/$f" "$RESULTS/m26/$f"
	done
	(since "${m26_start:-0}" '' | grep -E 'provisioning: |server: (fallback provisioning|the fallback|the unauthenticated)|directory: license checked|work: work data fetched|chatserver: client (dis)?connected|TLS handshake error|level=(WARN|ERROR)' |
		sed 's/^time=[^ ]* //; s/ remote=[^ ]*//' | cut -c1-260 > "$RESULTS/m26/server-lines.txt") 2> /dev/null || true
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
short() { printf '%s' "$1" | sed 's/^time=[^ ]* //; s/ remote=[^ ]*//' | cut -c1-200; }
brief() { printf '%s…' "$(printf '%s' "$1" | cut -c1-12)"; }

answer() {
	python3 -I -c 'import json, sys
try:
    a = json.load(open(sys.argv[1]))
    v = eval(sys.argv[2], {"a": a})
except Exception:
    v = ""
print("" if v is None else v)' "$COCKPIT_ANSWER" "$1" 2> /dev/null | tr -d '\r'
}

oppf_pins() {
	python3 -I - "$1" "$host" <<'PY' 2> /dev/null | tr -d '\r' || true
import json, sys
raw = open(sys.argv[1], "rb").read()
cut = raw.rfind(b"\n")
doc = json.loads(raw[:cut] if cut >= 0 else raw)
pins = []
for rule in (doc.get("domains") or {}).get("rules") or []:
    if rule.get("fqdn") == sys.argv[2] and rule.get("matchMode") == "exact":
        pins += [s.get("value", "") for s in rule.get("spkis") or [] if s.get("algorithm") == "sha256"]
print(" ".join(pins))
PY
}

app_pins() {
	local dir
	dir=$(xcrun simctl get_app_container "$udid" "$APP_BUNDLE_ID" "$APP_GROUP" 2> /dev/null | tr -d '\r') || return 0
	[ -s "$dir/config.oppf" ] || return 0
	cp "$dir/config.oppf" "$out/app-config-$1.oppf" 2> /dev/null
	oppf_pins "$dir/config.oppf"
}

served_spki() {
	"$OPENSSL" s_client -connect "$host:$SERVER_HTTP_PORT" -servername "$host" < /dev/null 2> /dev/null |
		spki_sha256 2> /dev/null || true
}

health() {
	curl_tls -sS --max-time 10 --cacert "$1" -o /dev/null -w '%{http_code}' "$SERVER_PUBLIC_URL/health" 2> /dev/null || true
}

set_pin() {
	[ "$(grep -cF -- "\"$1\"" "$SRV/server.yaml")" = 1 ] || return 1
	awk -v old="\"$1\"" -v new="\"$2\"" '{
		i = index($0, old)
		if (i) $0 = substr($0, 1, i - 1) new substr($0, i + length(old))
		print
	}' "$SRV/server.yaml" > "$SRV/server.yaml.new" && mv "$SRV/server.yaml.new" "$SRV/server.yaml"
}

stop_server() {
	local pid
	pid=$(cat "$SRV/server.pid" 2> /dev/null) || return 1
	kill -TERM "$pid" 2> /dev/null || return 0
	for _ in $(seq 1 30); do
		kill -0 "$pid" 2> /dev/null || return 0
		sleep 1
	done
	kill -KILL "$pid" 2> /dev/null
	sleep 2
	! kill -0 "$pid" 2> /dev/null
}

start_server() {
	local pid
	(
		nohup python3 -I -c 'import os, sys
try:
    os.setsid()
except Exception:
    pass
os.execv(sys.argv[1], sys.argv[1:])' "$SRV_BIN" serve -config "$SRV/server.yaml" < /dev/null >> "$SRV/server.log" 2>&1 3>&- &
		echo "$!" > "$SRV/server.pid"
	)
	pid=$(cat "$SRV/server.pid")
	for _ in $(seq 1 60); do
		if curl_tls -fsS --max-time 5 --cacert "$SRV/tls/ca.crt" "$SERVER_PUBLIC_URL/health" > /dev/null 2>&1; then
			return 0
		fi
		kill -0 "$pid" 2> /dev/null || return 1
		sleep 1
	done
	return 1
}

restore_a() {
	local back=no
	stop_server > /dev/null 2>&1
	if [ -s "$SRV/tls-a/server.crt" ] && [ -s "$SRV/tls-a/ca.crt" ]; then
		cp "$SRV/tls-a/server.crt" "$SRV/tls-a/ca.crt" "$SRV/tls/" 2> /dev/null
		cp "$SEC/tls-a/"*.key "$SEC/tls/" 2> /dev/null
	fi
	[ "$(grep -cF -- "\"$spki_a\"" "$SRV/server.yaml")" = 1 ] || set_pin "$spki_b" "$spki_a"
	start_server && back=yes
	fail m26-rotate "$1; the server is back on certificate A: $back"
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
}

run_test() {
	local status=0
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/RecoveryTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m26-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m26/$1.tail.txt"
	export_attachments "$work/m26-$1.xcresult" "$out/shots" "$RESULTS/m26" m26- > /dev/null 2>&1 || true
	return "$status"
}

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

m26_start=$(offset)
app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m26-pins-served "no identity of the app in the server log"
find_openssl > /dev/null || fail m26-pins-served "no OpenSSL 3"
[ "$host" != localhost ] || fail m26-pins-served "SERVER_HOST is localhost, which TrustKit cannot pin (prepare-run.sh sets it for S26)"
[ -x "$SRV_BIN" ] || fail m26-pins-served "no server binary at SRV_BIN to restart the server with"

stage m26-pins-served
spki_a=$(spki_sha256 "$SRV/tls/server.crt" 2> /dev/null)
[[ $spki_a =~ $spki_re ]] || fail m26-pins-served "no SPKI hash of the run's certificate"
if ! curl_tls -fsS --max-time 10 --cacert "$SRV/tls/ca.crt" -K "$SEC/curl-auth.cfg" "$SERVER_PUBLIC_URL/prov/config.oppf" \
	-o "$out/served-a.oppf" 2> "$out/served-a.err"; then
	fail m26-pins-served "fetching the provisioning file with the seat's credentials failed"
fi
pins=$(oppf_pins "$out/served-a.oppf")
served=$(served_spki)
if [ "$pins" = "$spki_a" ] && [ "$served" = "$spki_a" ]; then
	record m26-pins-served PASS "$host pinned (exact) to key A $(brief "$spki_a"), the key the server presents"
else
	record m26-pins-served FAIL "pins for $host: ${pins:-none}; key A $spki_a; the server presents ${served:-nothing}"
fi
stage m26-app-pins
pins=$(app_pins a)
case " $pins " in
*" $spki_a "*) record m26-app-pins PASS "the app's cached provisioning file pins $host to $(brief "$spki_a")" ;;
*) record m26-app-pins FAIL "the app's cached provisioning file pins $host to: ${pins:-nothing}" ;;
esac

stage m26-rotate
rm -rf "$SRV/tls-b" "$SEC/tls-b"
bash "$here/make-tls-cert.sh" "$SRV/tls-b" "$SEC/tls-b" "${CERT_PROFILE:-selfsigned}" > "$out/make-tls-cert-b.txt" 2>&1 ||
	fail m26-rotate "make-tls-cert.sh failed for certificate B (m26/make-tls-cert-b.txt)"
cp "$out/make-tls-cert-b.txt" "$RESULTS/m26/make-tls-cert-b.txt"
for key in "$SEC/tls-b/server.key" "$SEC/tls-b/ca.key"; do
	[ -f "$key" ] || continue
	while IFS= read -r line; do
		case $line in -----* | '') continue ;; esac
		add_secret "$line"
	done < "$key"
done
spki_b=$(spki_sha256 "$SRV/tls-b/server.crt" 2> /dev/null)
[[ $spki_b =~ $spki_re ]] || fail m26-rotate "no SPKI hash of certificate B"
[ "$spki_b" != "$spki_a" ] || fail m26-rotate "certificate B has key A"
"$OPENSSL" x509 -in "$SRV/tls-b/server.crt" -noout -text > "$RESULTS/m26/tls-cert-b.txt" 2>&1
xcrun simctl keychain "$udid" add-root-cert "$SRV/tls-b/ca.crt" > "$out/add-root-cert.txt" 2>&1 ||
	fail m26-rotate "simctl keychain add-root-cert failed for certificate B"
xcrun simctl terminate "$udid" "$APP_BUNDLE_ID" > /dev/null 2>&1 || true
stop_server || fail m26-rotate "the server did not stop"
rm -rf "$SRV/tls-a" "$SEC/tls-a"
mkdir -p "$SRV/tls-a" "$SEC/tls-a"
cp "$SRV/tls/server.crt" "$SRV/tls/ca.crt" "$SRV/tls-a/" && cp "$SEC/tls/"*.key "$SEC/tls-a/" ||
	restore_a "keeping certificate A failed"
cp "$SRV/tls-b/server.crt" "$SRV/tls-b/ca.crt" "$SRV/tls/" && cp "$SEC/tls-b/"*.key "$SEC/tls/" ||
	restore_a "putting certificate B in place failed"
set_pin "$spki_a" "$spki_b" || restore_a "pin A is not in the configuration once"
grep -A 4 '^pinning:' "$SRV/server.yaml" > "$RESULTS/m26/pinning-b.txt" 2> /dev/null
if ! "$SRV_BIN" oppf -config "$SRV/server.yaml" -out "$out/config-b.oppf" 2> "$RESULTS/m26/config-load.txt"; then
	restore_a "the configuration with pin B does not load (m26/config-load.txt)"
fi
[ "$(oppf_pins "$out/config-b.oppf")" = "$spki_b" ] || restore_a "the provisioning file of the configuration does not pin $host to B"
o_restart=$(offset)
start_server || restore_a "the server did not answer /health with certificate B within 60 s"
served=$(served_spki)
with_b=$(health "$SRV/tls/ca.crt")
with_a=$(health "$SRV/tls-a/ca.crt")
if [ "$served" = "$spki_b" ] && [ "$with_b" = 200 ] && [ "$with_a" != 200 ]; then
	record m26-rotate PASS "key B $(brief "$spki_b") in place of A, pinned, trusted in the simulator; the server restarted (pid $(cat "$SRV/server.pid")): /health $with_b with B's CA, ${with_a:-000} with A's"
else
	fail m26-rotate "after the restart the server presents ${served:-nothing} (B is $spki_b); /health ${with_b:-000} with B's CA, ${with_a:-000} with A's"
fi

o_broken=$(offset)
relaunch
stage m26-fallback-refused
if line=$(wait_line "$o_broken" 120 'provisioning: refused the fallback provisioning file' 'reason="not activated"'); then
	record m26-fallback-refused PASS "$(short "$line")"
else
	record m26-fallback-refused FAIL "no request of the app's for the fallback file within 120 s of the relaunch: pin A was not refused, or iOS's recovery did not start (m26/server-lines.txt)"
fi
sleep 20
shot m26-03-broken
stage m26-pinned
reached=$( {
	since "$o_restart" 'provisioning: served the provisioning file' "seat=$SEAT_USERNAME"
	since "$o_restart" 'provisioning: refused the provisioning file'
	since "$o_restart" 'directory: license checked' "seat=$SEAT_USERNAME"
	since "$o_restart" 'work: work data fetched' "seat=$SEAT_USERNAME"
	since "$o_restart" 'chatserver: client connected' "identity=$app_id"
} | sed '/^$/d' | head -n 1)
if [ -z "$reached" ]; then
	record m26-pinned PASS "since the restart on B: no request for the provisioning file, no licence check or Work data for $SEAT_USERNAME, no chat server login of $app_id"
else
	record m26-pinned FAIL "the app reached the server on pin A: $(short "$reached")"
fi
record m26-handshakes INFO "$(since "$o_restart" 'TLS handshake error' | grep -c . || true) TLS handshake error line(s) since the restart"

xcrun simctl terminate "$udid" "$APP_BUNDLE_ID" > /dev/null 2>&1 || true
sleep 2
nonce=$(test_nonce)
inbound="M26 from the CLI $nonce"
reply="M26 reply from iOS $nonce"
stage m26-cli-send
if "$cli" send -identity "$profile" -to "$app_id" -text "$inbound" > "$out/send.txt" 2>&1; then
	sent_id=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id\$/\1/p" "$out/send.txt" | tr -d '\r' | head -n 1)
	record m26-cli-send PASS "message ${sent_id:-?} to $app_id, which is not running: \"$inbound\""
else
	tail -n 5 "$out/send.txt"
	record m26-cli-send FAIL "cli send failed (m26/send.txt)"
fi
"$cli" listen -identity "$profile" > "$out/listen.txt" 2>&1 3>&- &
listen_pid=$!
stage m26-open
cockpit_sign_in || fail m26-open "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S26)"
o_open=$(offset)
status=$(cockpit POST /api/provisioning/fallback '{"durationMinutes":10,"confirm":"OPEN"}')
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m26/open-answer.json" 2> /dev/null
	fail m26-open "the cockpit answered $status (m26/open-answer.json)"
fi
opened=true
active=$(answer 'a["active"]')
until=$(answer 'a["activeUntil"]')
if [ "$active" = True ] && line=$(wait_line "$o_open" 10 'server: fallback provisioning endpoint activation changed'); then
	record m26-open PASS "open until $until (HTTP $status); $(short "$line")"
else
	record m26-open FAIL "HTTP $status, active ${active:-?}, and no activation line in the server log"
fi

relaunch
stage m26-fallback-served
if line=$(wait_line "$o_open" 120 'provisioning: served the fallback provisioning file' 'method=GET'); then
	record m26-fallback-served PASS "$(short "$line")"
else
	record m26-fallback-served FAIL "the app fetched no fallback file within 120 s of the relaunch (m26/server-lines.txt)"
fi
stage m26-after
lic=$(wait_line "$o_open" 120 'directory: license checked' 'result=valid' "seat=$SEAT_USERNAME")
con=$(wait_line "$o_open" 60 'chatserver: client connected' "identity=$app_id")
if [ -n "$lic" ] && [ -n "$con" ]; then
	record m26-after PASS "$(short "$lic"); $(short "$con")"
else
	record m26-after FAIL "since the fallback opened: valid licence check of $SEAT_USERNAME: $([ -n "$lic" ] && echo yes || echo none), chat server login of $app_id: $([ -n "$con" ] && echo yes || echo none)"
fi
stage m26-app-repinned
pins=$(app_pins b)
if [ "$pins" = "$spki_b" ]; then
	record m26-app-repinned PASS "the app's cached provisioning file pins $host to $(brief "$spki_b") alone"
else
	record m26-app-repinned FAIL "the app's cached provisioning file pins $host to: ${pins:-nothing} (B is $spki_b)"
fi
stage m26-test-recovered
if TEST_RUNNER_M26_INBOUND="$inbound" TEST_RUNNER_M26_REPLY="$reply" run_test testRecovered; then
	record m26-test-recovered PASS "the chat list, the CLI's text in its chat, the answer sent"
else
	record m26-test-recovered FAIL "xcodebuild test failed (m26/testRecovered.tail.txt)"
fi
if [ -f "$RESULTS/m26/m26-01-licence.txt" ]; then
	record m26-licence-screen INFO "$(tr -d '\r\n' < "$RESULTS/m26/m26-01-licence.txt" | cut -c1-120)"
fi
stage m26-reply
if wait_for_text "$out/listen.txt" "$reply" 60; then
	record m26-reply PASS "$(grep -F -- "$reply" "$out/listen.txt" | head -n 1 | tr -d '\r' | cut -c1-200)"
else
	record m26-reply FAIL "the CLI did not receive \"$reply\" within 60 s (m26/listen.txt)"
fi

stage m26-fallback-file
code=$(curl_tls -sS --max-time 10 --cacert "$SRV/tls/ca.crt" -o "$out/fallback.oppf" -w '%{http_code}' \
	"$SERVER_PUBLIC_URL/prov/config.fallback.oppf" 2> /dev/null || true)
if [ "$code" = 200 ] && check_oppf "$out/fallback.oppf" "$(cat "$SRV/oppf-public.key")" "$out/fallback-oppf.json" \
	"$out/fallback-check" > "$out/fallback-check.txt" 2>&1; then
	pins=$(oppf_pins "$out/fallback.oppf")
	if [ "$pins" = "$spki_b" ]; then
		record m26-fallback-file PASS "200 without credentials, signed by the run's key, pins $host to $(brief "$spki_b")"
	else
		record m26-fallback-file FAIL "it pins $host to ${pins:-nothing}, not to B"
	fi
else
	cp "$out/fallback-check.txt" "$RESULTS/m26/fallback-check.txt" 2> /dev/null
	record m26-fallback-file FAIL "HTTP ${code:-000}, or not what iOS accepts (m26/fallback-check.txt)"
fi
stage m26-close
[ -s "$SEC/cockpit.csrf" ] || cockpit_sign_in || fail m26-close "the cockpit's sign-in answered $COCKPIT_STATUS"
o_close=$(offset)
status=$(cockpit POST /api/provisioning/fallback/close '{}')
active=$(answer 'a["active"]')
if [ "${status#2}" != "$status" ] && [ "$active" = False ]; then
	opened=false
	line=$(wait_line "$o_close" 10 'server: fallback provisioning endpoint activation changed' || true)
	record m26-close PASS "closed (HTTP $status)${line:+; $(short "$line")}"
else
	cp "$COCKPIT_ANSWER" "$RESULTS/m26/close-answer.json" 2> /dev/null
	record m26-close FAIL "the cockpit answered $status, active ${active:-?} (m26/close-answer.json)"
fi
stage m26-closed
code=$(curl_tls -sS --max-time 10 --cacert "$SRV/tls/ca.crt" -o /dev/null -w '%{http_code}' \
	"$SERVER_PUBLIC_URL/prov/config.fallback.oppf" 2> /dev/null || true)
line=$(wait_line "$o_close" 10 'provisioning: refused the fallback provisioning file' 'reason="not activated"' || true)
if [ "$code" = 404 ] && [ -n "$line" ]; then
	record m26-closed PASS "404; $(short "$line")"
else
	record m26-closed FAIL "the fallback file answered ${code:-000} after the close"
fi
status=$(cockpit POST /api/provisioning/fallback/reset '{}')
record m26-reset INFO "HTTP $status: active $(answer 'a["active"]'), the window from $(answer 'a["setting"]["source"]')"
if is_macos; then
	record m26-crashes INFO "$(find "$HOME/Library/Logs/DiagnosticReports" -name '*Threema*' -newer "$marker" 2> /dev/null | wc -l | tr -d ' ') crash report(s) of the app during the milestone"
fi
shot m26-09-final

failed=$(failing_stages "$M26_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 26: every stage passed"
