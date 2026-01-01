#!/bin/bash
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
root=$(ci_root)
: "${SRV:?}" "${SEC:?}" "${RESULTS:?}" "${SEAT_USERNAME:?}" "${SERVER_PUBLIC_URL:?}"
find_openssl
name=srv

fail() { record "$1" FAIL "$2"; exit 1; }

stage server-binary
SRV_BIN="$SRV/$name"
why=$(decrypt_bin "$name" "$SRV_BIN") || fail server-binary "$why"
K=
unset K
if [ -n "${CI_SERVER_BIN_OVERRIDE:-}" ]; then
	rm -f "$SRV_BIN"
	SRV_BIN="$SRV/$(basename "$CI_SERVER_BIN_OVERRIDE")"
	cp "$CI_SERVER_BIN_OVERRIDE" "$SRV_BIN"
fi
chmod 700 "$SRV_BIN"
if is_macos; then
	signature=$(codesign -dv "$SRV_BIN" 2>&1 || true)
	case $signature in *Signature=adhoc*) ;; *) fail server-binary "not ad-hoc signed" ;; esac
fi
version=$("$SRV_BIN" version)
case $version in
*+onprem_debug) ;;
*) fail server-binary "version $version is not a debug build" ;;
esac
printf '%s\n' "$version" > "$RESULTS/server/version.txt"
gh_env SRV_BIN "$SRV_BIN"
metric server_version "$version"
record server-binary PASS "$version"

stage server-keys
"$SRV_BIN" keygen > "$SEC/keygen.txt"
key_re='^[A-Za-z0-9+/]{43}=$'
for pair in oppfSigningKey:oppf-signing.key chatServerKey:chat-server.key workDeltaKey:work-delta.key; do
	field=${pair%%:*}
	file=${pair#*:}
	value=$(sed -n "s/^  $field: \"\(.*\)\"\$/\1/p" "$SEC/keygen.txt")
	[[ $value =~ $key_re ]] || fail server-keys "keygen gave no $field"
	add_secret "$value"
	printf '%s\n' "$value" > "$SEC/$file"
done
value=
pub=$(sed -n 's/^# OPPF signing public key (for the app build): //p' "$SEC/keygen.txt")
[[ $pub =~ $key_re ]] || fail server-keys "keygen gave no OPPF public key"
printf '%s\n' "$pub" > "$SRV/oppf-public.key"
rm -f "$SEC/keygen.txt"
metric oppf_public_key "$pub"
record server-keys PASS "OPPF public key $pub"

stage tls-cert
bash "$here/make-tls-cert.sh" "$SRV/tls" "$SEC/tls" "${CERT_PROFILE:-selfsigned}" || fail tls-cert "certificate generation failed"
for key in "$SEC/tls/server.key" "$SEC/tls/ca.key"; do
	[ -f "$key" ] || continue
	while IFS= read -r line; do
		case $line in -----* | '') continue ;; esac
		add_secret "$line"
	done < "$key"
done
"$OPENSSL" x509 -in "$SRV/tls/server.crt" -noout -text > "$RESULTS/server/tls-cert.txt"
cp "$SRV/tls/ca.crt" "$RESULTS/server/ca.crt.txt"
record tls-cert PASS "${CERT_PROFILE:-selfsigned}"

PW=$("$OPENSSL" rand -hex 16)
add_secret "$PW"
[[ $PW =~ ^[0-9a-f]{32}$ ]] || { echo "::error::openssl rand gave no password"; exit 1; }
printf '%s\n' "$PW" > "$SEC/seat-password.txt"
add_secret "$SEAT_USERNAME:$PW"
add_secret "$(printf '%s' "$SEAT_USERNAME:$PW" | "$OPENSSL" base64 -A)"
printf 'user = "%s:%s"\n' "$SEAT_USERNAME" "$PW" > "$SEC/curl-auth.cfg"

if [ "${S4:-false}" = true ]; then
	TURN_SECRET=$("$OPENSSL" rand -hex 32)
	add_secret "$TURN_SECRET"
	[[ $TURN_SECRET =~ ^[0-9a-f]{64}$ ]] || { echo "::error::openssl rand gave no TURN secret"; exit 1; }
	printf '%s\n' "$TURN_SECRET" > "$SEC/turn-secret.txt"
	TURN_SECRET=
fi
if [ "${S21:-false}" = true ] || [ "${S22:-false}" = true ]; then
	NOTIFY_TOKEN=$("$OPENSSL" rand -hex 32)
	add_secret "$NOTIFY_TOKEN"
	[[ $NOTIFY_TOKEN =~ ^[0-9a-f]{64}$ ]] || { echo "::error::openssl rand gave no verification API token"; exit 1; }
	printf '%s\n' "$NOTIFY_TOKEN" > "$SEC/notify-token.txt"
	NOTIFY_TOKEN=
fi
stage server-config
mkdir -p "$SRV/db"
srv_native=$(native_path "$SRV")
sec_native=$(native_path "$SEC")
for v in "$srv_native" "$sec_native" "$SERVER_PUBLIC_URL"; do
	case $v in *'|'* | *'&'* | *'\'*) fail server-config "a path holds | & or \\" ;; esac
done
TURN_IP=
if [ "${S4:-false}" = true ] || [ "${S6:-false}" = true ]; then
	TURN_IP=${CI_TURN_IP_OVERRIDE:-}
	if [ -z "$TURN_IP" ] && is_macos; then
		iface=$(route -n get default 2> /dev/null | awk '/interface:/ { print $2 }' || true)
		TURN_IP=$(ipconfig getifaddr "${iface:-en0}" 2> /dev/null || true)
	fi
	[[ $TURN_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail server-config "no IPv4 address of the runner for TURN and the SFU"
	metric turn_ip "$TURN_IP"
fi
fill() {
	sed -e "s|@SRV@|$srv_native|g" -e "s|@SEC@|$sec_native|g" -e "s|@PUBLIC_URL@|$SERVER_PUBLIC_URL|g" \
		-e "s|@HTTP_PORT@|${SERVER_HTTP_PORT:?}|g" -e "s|@CHAT_PORT@|${SERVER_CHAT_PORT:?}|g" \
		-e "s|@TURN_IP@|$TURN_IP|g" -e "s|@TURN_PORT@|${SERVER_TURN_PORT:?}|g" \
		-e "s|@SFU_PORT@|${SERVER_SFU_PORT:?}|g" -e "s|@NOTIFY_PORT@|${SERVER_NOTIFY_PORT:-}|g" "$1"
}
fill "$root/ci/server/server.yaml.tmpl" > "$SRV/server.yaml"
if [ "${S2:-false}" = true ]; then
	if [ "${S9:-false}" = true ]; then
		grep -v 'th_safe_enable' "$root/ci/server/mdm.yaml.part" >> "$SRV/server.yaml"
	else
		cat "$root/ci/server/mdm.yaml.part" >> "$SRV/server.yaml"
	fi
	if [ "${S7:-false}" = true ]; then cat "$root/ci/server/work.yaml.part" >> "$SRV/server.yaml"; fi
	if [ "${S12:-false}" = true ]; then printf '  dualLock:\n    licensed: true\n' >> "$SRV/server.yaml"; fi
fi
if [ "${S10:-false}" = true ] || [ "${S12:-false}" = true ] || [ "${S14:-false}" = true ] ||
	[ "${S16:-false}" = true ] || [ "${S17:-false}" = true ] || [ "${S19:-false}" = true ] ||
	[ "${S22:-false}" = true ] || [ "${S24:-false}" = true ] || [ "${S26:-false}" = true ]; then
	(umask 077 && "${OPENSSL:?}" rand -hex 16 > "$SEC/cockpit-password.txt") || fail server-config "openssl rand failed"
	add_secret "$(cat "$SEC/cockpit-password.txt")"
	hash=$("$SRV_BIN" hash-password -password - < "$SEC/cockpit-password.txt") || fail server-config "hash-password failed"
	add_secret "$hash"
	printf '\ncockpit:\n  enabled: true\n  adminUsername: ci-admin\n  adminPasswordHash: "%s"\n' "$hash" >> "$SRV/server.yaml"
	hash=
fi
if [ "${S11:-false}" = true ]; then
	printf '\nmultiDevice:\n  enabled: true\n' >> "$SRV/server.yaml"
fi
if [ "${S21:-false}" = true ] || [ "${S22:-false}" = true ]; then
	[[ ${SERVER_NOTIFY_PORT:-} =~ ^[0-9]+$ ]] || fail server-config "no SERVER_NOTIFY_PORT (ci/run.env) for the verification APIs"
	printf '\n' >> "$SRV/server.yaml"
	fill "$root/ci/server/verification.yaml.part" >> "$SRV/server.yaml"
fi
if [ "${S4:-false}" = true ] || [ "${S6:-false}" = true ]; then
	printf '\ncalls:\n' >> "$SRV/server.yaml"
	if [ "${S4:-false}" = true ]; then fill "$root/ci/server/turn.yaml.part" >> "$SRV/server.yaml"; fi
	if [ "${S6:-false}" = true ]; then fill "$root/ci/server/sfu.yaml.part" >> "$SRV/server.yaml"; fi
fi
if [ "${S20:-false}" = true ]; then
	: "${SERVER_SALTYRTC_PORT:?}"
	"$SRV_BIN" saltyrtc-keygen > "$SEC/saltyrtc-keygen.txt" 2> "$RESULTS/server/saltyrtc-keygen.stderr.txt" ||
		fail server-config "saltyrtc-keygen failed"
	salty_secret=$(sed -n 's/^    - "\([0-9a-f]\{64\}\)"$/\1/p' "$SEC/saltyrtc-keygen.txt")
	add_secret "$salty_secret"
	salty_public=$(sed -n 's/^# Server public key: \([0-9a-f]\{64\}\)$/\1/p' "$SEC/saltyrtc-keygen.txt")
	rm -f "$SEC/saltyrtc-keygen.txt"
	[[ $salty_secret =~ ^[0-9a-f]{64}$ ]] || fail server-config "saltyrtc-keygen gave no secret key"
	[[ $salty_public =~ ^[0-9a-f]{64}$ ]] || fail server-config "saltyrtc-keygen gave no public key"
	[ "$salty_public" != "$salty_secret" ] || fail server-config "saltyrtc-keygen's public key is its secret key"
	printf '%s\n' "$salty_public" > "$SRV/saltyrtc-public.key"
	printf '\nsaltyrtc:\n  enabled: true\n  listen: ":%s"\n  permanentKeys:\n    - "%s"\n' \
		"$SERVER_SALTYRTC_PORT" "$salty_secret" >> "$SRV/server.yaml"
	salty_secret=
	metric saltyrtc_public_key "$salty_public"
fi
if [ "${S26:-false}" = true ]; then
	[ "${SERVER_HOST:-localhost}" != localhost ] || fail server-config "S26 needs SERVER_HOST (prepare-run.sh), not localhost"
	spki=$(spki_sha256 "$SRV/tls/server.crt") || fail server-config "no SPKI hash of the TLS certificate"
	[[ $spki =~ $key_re ]] || fail server-config "the TLS certificate's SPKI hash is not 32 bytes of base64"
	printf '\npinning:\n  - fqdn: "%s"\n    matchMode: exact\n    spkis:\n      - "%s"\n' "$SERVER_HOST" "$spki" >> "$SRV/server.yaml"
	metric tls_spki "$spki"
fi
if grep -q '@[A-Z_]*@' "$SRV/server.yaml"; then fail server-config "a placeholder was left in the configuration"; fi
cp "$SRV/server.yaml" "$RESULTS/server/server.yaml"

if ! "$SRV_BIN" oppf -config "$SRV/server.yaml" -out "$SRV/config.oppf" 2> "$RESULTS/server/config-load.txt"; then
	cat "$RESULTS/server/config-load.txt"
	fail server-config "the configuration does not load"
fi
check_oppf "$SRV/config.oppf" "$pub" "$RESULTS/server/oppf.json" "$SRV/oppf-check" ||
	fail server-config "the signed provisioning file is not what iOS accepts"
record server-config PASS "loads; OPPF signed by this run's key, version 1.0, no trailing LF"

stage seat
"$SRV_BIN" user add -config "$SRV/server.yaml" -username "$SEAT_USERNAME" \
	-first-name CI -last-name iOS -password - < "$SEC/seat-password.txt" > "$RESULTS/server/user-add.txt" 2>&1 ||
	{ cat "$RESULTS/server/user-add.txt"; fail seat "user add failed"; }
"$SRV_BIN" user list -config "$SRV/server.yaml" > "$RESULTS/server/user-list.txt" 2>&1 || true
record seat PASS "$SEAT_USERNAME"

stage licence-url
if ! "$SRV_BIN" license-url -config "$SRV/server.yaml" -username "$SEAT_USERNAME" -password - \
	< "$SEC/seat-password.txt" > "$SEC/license.url" 2> "$RESULTS/server/license-url.stderr.txt"; then
	cat "$RESULTS/server/license-url.stderr.txt"
	fail licence-url "license-url failed"
fi
add_secret "$(tr -d '\r\n' < "$SEC/license.url")"
if ! python3 -I - "$SEC/license.url" "$SEC/seat-password.txt" "$SERVER_PUBLIC_URL" "$SEAT_USERNAME" <<'PY'
import sys
from urllib.parse import parse_qsl, quote, unquote, urlsplit

url = open(sys.argv[1]).read().strip()
password = open(sys.argv[2]).read().strip()
server, username = sys.argv[3], sys.argv[4]
problems = []
if not url.startswith("threemaonprem://license?"):
    problems.append("does not start with threemaonprem://license?")
if "server=" + quote(server, safe="") not in url:
    problems.append("server is not %s, percent-encoded" % server)
parts = urlsplit(url)
once = dict(parse_qsl(parts.query, keep_blank_values=True))
twice = {k: unquote(v.replace("+", " ")) for k, v in once.items()}
if twice.get("server") != server:
    problems.append("server does not survive the double decoding")
if twice.get("username") != username:
    problems.append("username does not survive the double decoding")
if twice.get("password") != password:
    problems.append("password does not survive the double decoding")
for p in problems:
    print("licence url: " + p)
sys.exit(1 if problems else 0)
PY
then
	fail licence-url "the licence link is not what iOS reads"
fi
record licence-url PASS "threemaonprem://license?… for $SEAT_USERNAME at $SERVER_PUBLIC_URL"

if [ "${S3:-false}" = true ]; then
	stage seat-cli
	: "${CLI_SEAT_USERNAME:?}"
	PW=$("$OPENSSL" rand -hex 16)
	add_secret "$PW"
	[[ $PW =~ ^[0-9a-f]{32}$ ]] || fail seat-cli "openssl rand gave no password"
	printf '%s\n' "$PW" > "$SEC/seat-cli-password.txt"
	add_secret "$CLI_SEAT_USERNAME:$PW"
	add_secret "$(printf '%s' "$CLI_SEAT_USERNAME:$PW" | "$OPENSSL" base64 -A)"
	PW=
	"$SRV_BIN" user add -config "$SRV/server.yaml" -username "$CLI_SEAT_USERNAME" \
		-first-name CI -last-name CLI -password - < "$SEC/seat-cli-password.txt" > "$RESULTS/server/user-add-cli.txt" 2>&1 ||
		{ cat "$RESULTS/server/user-add-cli.txt"; fail seat-cli "user add failed"; }
	if ! "$SRV_BIN" license-url -config "$SRV/server.yaml" -username "$CLI_SEAT_USERNAME" -password - \
		< "$SEC/seat-cli-password.txt" > "$SEC/license-cli.url" 2> "$RESULTS/server/license-url-cli.stderr.txt"; then
		cat "$RESULTS/server/license-url-cli.stderr.txt"
		fail seat-cli "license-url failed"
	fi
	add_secret "$(tr -d '\r\n' < "$SEC/license-cli.url")"
	record seat-cli PASS "$CLI_SEAT_USERNAME, licence link for the CLI"
fi

if [ "${S7:-false}" = true ]; then
	stage seat-dir
	: "${DIR_SEAT_USERNAME:?}"
	PW=$("$OPENSSL" rand -hex 16)
	add_secret "$PW"
	[[ $PW =~ ^[0-9a-f]{32}$ ]] || fail seat-dir "openssl rand gave no password"
	printf '%s\n' "$PW" > "$SEC/seat-dir-password.txt"
	add_secret "$DIR_SEAT_USERNAME:$PW"
	add_secret "$(printf '%s' "$DIR_SEAT_USERNAME:$PW" | "$OPENSSL" base64 -A)"
	PW=
	"$SRV_BIN" user add -config "$SRV/server.yaml" -username "$DIR_SEAT_USERNAME" \
		-first-name CI -last-name Colleague -password - < "$SEC/seat-dir-password.txt" > "$RESULTS/server/user-add-dir.txt" 2>&1 ||
		{ cat "$RESULTS/server/user-add-dir.txt"; fail seat-dir "user add failed"; }
	if ! "$SRV_BIN" license-url -config "$SRV/server.yaml" -username "$DIR_SEAT_USERNAME" -password - \
		< "$SEC/seat-dir-password.txt" > "$SEC/license-dir.url" 2> "$RESULTS/server/license-url-dir.stderr.txt"; then
		cat "$RESULTS/server/license-url-dir.stderr.txt"
		fail seat-dir "license-url failed"
	fi
	add_secret "$(tr -d '\r\n' < "$SEC/license-dir.url")"
	record seat-dir PASS "$DIR_SEAT_USERNAME"
fi

if [ "$SRV_BIN" = "$SRV/$name" ]; then
	rm -f "$SRV_BIN"
fi
