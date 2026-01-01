#!/bin/bash

M1_REQUIRED="server-binary server-keys tls-cert server-config seat licence-url server-start tls-selfcheck
oppf-selfcheck app-ready entitlements key-inject sim-boot cert-trust install app-group launch alive
licence-link oppf-served licence-valid shot-04 masking"
M2_REQUIRED="m2-test m2-identity m2-connected"
M3_REQUIRED="seat-cli m3-cli m3-register m3-send m3-test m3-reply m3-receipt"
M4_REQUIRED="cli-call-features m4-voip m4-test m4-connected"
M5_REQUIRED="m5-create m5-send m5-test-in m5-reply m5-test-create m5-app-group m5-cli-answer m5-test-see m5-relay"
M6_REQUIRED="cli-call-features m6-sfu-up m6-probe m6-test m6-start m6-sfu-app m6-cli-joined m6-sfu-peers"
M7_REQUIRED="seat-dir m7-dir-register m7-status m7-delta m7-test-sync m7-worksync m7-test-directory m7-directory"
M8_REQUIRED="m8-photos m8-cli-send m8-cli-upload m8-test-in m8-app-fetch m8-test-out m8-app-upload m8-cli-saved m8-receipt"
M9_REQUIRED="m9-password m9-mdm m9-backup m9-test m9-check"
M10_REQUIRED="m10-reinstall m10-mdm m10-restore-get m10-same-id m10-test m10-fetch-priv m10-fetch-bulk m10-cookie
m10-cookie-cleared"
M11_REQUIRED="m11-join-start m11-test-link m11-test-trust m11-cli-joined m11-mediator m11-test-send m11-reflect m11-delivered"
M13_REQUIRED="m13-listen m13-test-out m13-mirror-upload m13-recipient m13-device-out m13-test-in m13-device-in"
M14_REQUIRED="m14-cockpit m14-upload m14-test-sync m14-served m14-shown-upload m14-change m14-test-change m14-served-new
m14-shown-change m14-shown-removed"
M15_REQUIRED="m15-test-revoke m15-revoked m15-check m15-cli-send"
M16_REQUIRED="m16-cockpit m16-set m16-test-on m16-sync m16-unset m16-test-off m16-sync-off"
M17_REQUIRED="m17-cockpit m17-disable m17-test-locked m17-refused m17-offline m17-enable m17-test-back
m17-valid m17-connected"
M18_REQUIRED="m18-offline m18-queued m18-test m18-drained m18-acked"
M19_REQUIRED="m19-seat m19-register m19-send m19-test-before m19-work-fetch m19-revoke m19-check m19-test-revoked"
M20_REQUIRED="m20-initiator m20-test m20-server m20-peer"
M21_REQUIRED="m21-binaries m21-notify m21-test-phone m21-requested m21-code m21-test-verify m21-linked m21-test-email m21-email-sent
m21-email-confirm m21-cli-match m21-email-status m21-test-email-linked m21-email-checked m21-test-unlink m21-unlinked
m21-cli-phone m21-call m21-call-code m21-cli-verified"
M22_REQUIRED="m22-binaries m22-seat m22-register m22-notify m22-link m22-cli-match m22-addressbook m22-test-sync
m22-matched m22-test-unknown m22-unknown m22-sync-off m22-test-add m22-fetched"
M23_REQUIRED="m23-md-send m23-peer m23-test-mirrored m23-acked m23-test-devices m23-devices m23-test-remove m23-dropped
m23-test-md-off m23-fs-back"
M24_REQUIRED="m24-cockpit m24-categories m24-assign m24-set m24-test-sync m24-sync m24-relaunch m24-reported
m24-categorised m24-test-filter m24-directory"
M25_REQUIRED="m25-listen m25-test-typing m25-offered m25-test-offline m25-dropped m25-queued m25-drained m25-not-queued
m25-test-edit m25-edit m25-test-delete m25-delete m25-test-react m25-reaction"
M26_REQUIRED="hosts m26-pins-served m26-app-pins m26-rotate m26-fallback-refused m26-pinned m26-cli-send m26-open
m26-fallback-served m26-after m26-app-repinned m26-test-recovered m26-reply m26-fallback-file m26-close m26-closed"
M12_REQUIRED="m12-cockpit m12-enable m12-reinstall m12-mdm m12-restore-get m12-created m12-test-restored m12-fetch m12-block m12-test-locked"

ci_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); }

is_macos() { [ "$(uname -s)" = Darwin ]; }

in_actions() { [ "${GITHUB_ACTIONS:-}" = true ]; }

in_local() { [ "${CI_LOCAL:-}" = 1 ] && ! in_actions; }

gh_env() {
	case $2 in *"
"*) echo "gh_env: $1 holds a newline" >&2; return 1 ;; esac
	printf '%s=%s\n' "$1" "$2" >> "${GITHUB_ENV:?}"
	export "$1=$2"
}

mask() {
	if in_actions && [ -n "$1" ]; then
		if { : >&3; } 2> /dev/null; then
			printf '::add-mask::%s\n' "$1" >&3
		else
			printf '::add-mask::%s\n' "$1"
		fi
	fi
}

add_secret() {
	[ -n "$1" ] || return 0
	mask "$1"
	printf '%s\n' "$1" >> "${SEC:?}/mask.list"
}

stage() { date +%s > "${RUNNER_TEMP:?}/.stage-$1"; }

record() {
	local name=$1 status=$2 note secs="" start_file
	shift 2
	note=$(printf '%s' "$*" | tr '\t\n' '  ')
	start_file="${RUNNER_TEMP:?}/.stage-$name"
	if [ -f "$start_file" ]; then
		secs=$(($(date +%s) - $(cat "$start_file")))
		rm -f "$start_file"
	fi
	mkdir -p "${RESULTS:?}"
	printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$secs" "$note" >> "$RESULTS/stages.txt"
	if [ "$status" = FAIL ] && in_actions; then
		echo "::error title=$name::$name failed${note:+: $note}"
	else
		echo "[stage] $name: $status${secs:+ (${secs} s)}${note:+ - $note}"
	fi
}

stage_status() {
	[ -f "${RESULTS:?}/stages.txt" ] || return 0
	awk -F'\t' -v n="$1" '$1 == n { s = $2 } END { if (s != "") print s }' "$RESULTS/stages.txt"
}

metric() {
	mkdir -p "${RESULTS:?}"
	printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$RESULTS/metrics.txt"
}

disk_free_gb() { df -k / | awk 'NR == 2 { printf "%d", $4 / 1048576 }'; }

disk_metric() {
	local gb
	gb=$(disk_free_gb)
	metric "disk_$1_gb" "$gb"
	echo "free disk ($1): $gb GB"
}

failing_stages() {
	local stages_file="${RESULTS:?}/stages.txt" req
	[ -f "$stages_file" ] || : > "$stages_file"
	req=$(printf '%s' "$1" | tr '\n\t' '  ')
	awk -F'\t' -v req="$req" '
		BEGIN { n = split(req, r, / +/) }
		{ s[$1] = $2 }
		END {
			for (i = 1; i <= n; i++) {
				if (r[i] == "") continue
				st = (r[i] in s) ? s[r[i]] : "NOT RUN"
				if (st != "PASS") print r[i] "\t" st
			}
		}' "$stages_file" || printf '%s\t%s\n' "(failing_stages)" "awk failed, so nothing counts as passed"
}

explain_unrecorded() {
	local var req s st err note first="" failed=false
	var=M${1}_REQUIRED
	req=$(printf '%s' "${!var:-}" | tr '\n\t' '  ')
	[ -n "$req" ] || return 0
	err=$(export LC_ALL=C
		tail -n 10 "$2" 2> /dev/null | grep -E ': line [0-9]+: ' | tail -n 1 |
			sed 's|^[^ ]*/\([^/ ]*: line [0-9]*: \)|\1|' | tr -d '\r\n' | tr -c ' -~' '?' | cut -c1-160)
	note="$3 before recording it${err:+: $err} (steps/$(basename "$2"))"
	for s in $req; do
		[ "$s" = masking ] && continue
		st=$(stage_status "$s")
		if [ -z "$st" ] && [ -f "${RUNNER_TEMP:?}/.stage-$s" ]; then
			record "$s" FAIL "begun, but $note"
			st=FAIL
		fi
		case $st in
		FAIL) failed=true ;;
		'') [ -n "$first" ] || first=$s ;;
		esac
	done
	if [ "$failed" = false ] && [ -n "$first" ]; then
		record "$first" FAIL "$note"
	fi
}

required_stages() {
	printf '%s' "$M1_REQUIRED"
	if [ "${S2:-false}" = true ]; then printf ' %s' "$M2_REQUIRED"; fi
	if [ "${S3:-false}" = true ]; then printf ' %s' "$M3_REQUIRED"; fi
	if [ "${S4:-false}" = true ]; then printf ' %s' "$M4_REQUIRED"; fi
	if [ "${S5:-false}" = true ]; then printf ' %s' "$M5_REQUIRED"; fi
	if [ "${S6:-false}" = true ]; then printf ' %s' "$M6_REQUIRED"; fi
	if [ "${S7:-false}" = true ]; then printf ' %s' "$M7_REQUIRED"; fi
	if [ "${S8:-false}" = true ]; then printf ' %s' "$M8_REQUIRED"; fi
	if [ "${S9:-false}" = true ]; then printf ' %s' "$M9_REQUIRED"; fi
	if [ "${S10:-false}" = true ]; then printf ' %s' "$M10_REQUIRED"; fi
	if [ "${S11:-false}" = true ]; then printf ' %s' "$M11_REQUIRED"; fi
	if [ "${S12:-false}" = true ]; then printf ' %s' "$M12_REQUIRED"; fi
	if [ "${S13:-false}" = true ]; then printf ' %s' "$M13_REQUIRED"; fi
	if [ "${S14:-false}" = true ]; then printf ' %s' "$M14_REQUIRED"; fi
	if [ "${S15:-false}" = true ]; then printf ' %s' "$M15_REQUIRED"; fi
	if [ "${S16:-false}" = true ]; then printf ' %s' "$M16_REQUIRED"; fi
	if [ "${S17:-false}" = true ]; then printf ' %s' "$M17_REQUIRED"; fi
	if [ "${S18:-false}" = true ]; then printf ' %s' "$M18_REQUIRED"; fi
	if [ "${S19:-false}" = true ]; then printf ' %s' "$M19_REQUIRED"; fi
	if [ "${S20:-false}" = true ]; then printf ' %s' "$M20_REQUIRED"; fi
	if [ "${S21:-false}" = true ]; then printf ' %s' "$M21_REQUIRED"; fi
	if [ "${S22:-false}" = true ]; then printf ' %s' "$M22_REQUIRED"; fi
	if [ "${S23:-false}" = true ]; then printf ' %s' "$M23_REQUIRED"; fi
	if [ "${S24:-false}" = true ]; then printf ' %s' "$M24_REQUIRED"; fi
	if [ "${S25:-false}" = true ]; then printf ' %s' "$M25_REQUIRED"; fi
	if [ "${S26:-false}" = true ]; then printf ' %s' "$M26_REQUIRED"; fi
	printf '\n'
}

wait_for_log() {
	local pat=$1 secs=$2 pat2=${3:-} off=0 end line
	[ -f "${SRV:?}/log.offset" ] && off=$(cat "$SRV/log.offset")
	end=$(($(date +%s) + secs))
	while :; do
		line=$( (tail -c +"$((off + 1))" "$SRV/server.log" 2>/dev/null || true) |
			grep -F -- "$pat" | grep -F -- "${pat2:-$pat}" | head -n 1 || true)
		if [ -n "$line" ]; then
			printf '%s\n' "$line"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

sim_udid() { cat "${SIM:?}/udid"; }

export_attachments() {
	local bundle=$1 shots=$2 notes=$3 prefix=$4 tmp
	tmp="$(dirname "$bundle")/attachments-$prefix"
	rm -rf "$tmp"
	xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" > "$tmp.log" 2>&1 || return 1
	mkdir -p "$shots" "$notes"
	python3 -I - "$tmp" "$shots" "$notes" "$prefix" <<'PY'
import json, os, re, shutil, sys

src, shots, notes, prefix = sys.argv[1:5]
manifest = json.load(open(os.path.join(src, "manifest.json")))

def entries(node):
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for v in node.values():
            yield from entries(v)
    elif isinstance(node, list):
        for v in node:
            yield from entries(v)

count = 0
for e in entries(manifest):
    name = e.get("suggestedHumanReadableName") or e["exportedFileName"]
    m = re.match(re.escape(prefix) + r"[A-Za-z0-9-]+", name)
    if not m:
        continue
    path = os.path.join(src, e["exportedFileName"])
    if path.endswith(".png"):
        shutil.copy(path, os.path.join(shots, m.group(0) + ".png"))
    else:
        shutil.copy(path, os.path.join(notes, m.group(0) + ".txt"))
    count += 1
print("exported %d attachment(s)" % count)
PY
}

shot() {
	mkdir -p "${RESULTS_FULL:?}/shots"
	if xcrun simctl io "$(sim_udid)" screenshot --type=png "$RESULTS_FULL/shots/$1.png" >/dev/null 2>&1; then
		echo "[shot] $1"
	else
		echo "::warning::screenshot $1 failed"
	fi
}

find_openssl() {
	if [ -z "${OPENSSL:-}" ]; then
		if is_macos; then
			OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
		else
			OPENSSL=openssl
		fi
	fi
	case $("$OPENSSL" version 2>/dev/null) in
	"OpenSSL 3."*) ;;
	"LibreSSL 3."*) in_local || { echo "::error::$OPENSSL is not OpenSSL 3"; return 1; } ;;
	*)
		echo "::error::$OPENSSL is not OpenSSL 3"
		return 1
		;;
	esac
	export OPENSSL
}

openssl_libre() {
	in_local || return 1
	case $("${OPENSSL:?}" version 2> /dev/null) in "LibreSSL "*) return 0 ;; esac
	return 1
}

curl_tls() {
	case $(curl -V 2>/dev/null | head -n 1) in
	*Schannel*) curl --ssl-no-revoke "$@" ;;
	*) curl "$@" ;;
	esac
}

spki_sha256() {
	if [ -n "${1:-}" ]; then
		"${OPENSSL:?}" x509 -in "$1" -noout -pubkey
	else
		"${OPENSSL:?}" x509 -noout -pubkey
	fi | "$OPENSSL" pkey -pubin -outform DER | "$OPENSSL" dgst -sha256 -binary | "$OPENSSL" base64 -A
}

cockpit_sign_in() {
	local csrf
	COCKPIT_STATUS=000
	[ -s "$SEC/cockpit-password.txt" ] || return 1
	(umask 077 && : > "$SEC/cockpit.cookies" && python3 -I - "$SEC/cockpit-password.txt" "$SEC/cockpit-login.json" <<'PY'
import json, sys
password = open(sys.argv[1]).read().strip()
json.dump({"username": "ci-admin", "password": password}, open(sys.argv[2], "w"))
PY
	)
	COCKPIT_STATUS=$(curl_tls -s -o "$SEC/cockpit-session.json" -w '%{http_code}' --cacert "$SRV/tls/ca.crt" \
		-c "$SEC/cockpit.cookies" -H 'Content-Type: application/json' --data @"$SEC/cockpit-login.json" \
		"$SERVER_PUBLIC_URL/cockpit/api/login" || echo 000)
	rm -f "$SEC/cockpit-login.json"
	if [ "$COCKPIT_STATUS" = 200 ]; then
		csrf=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["csrfToken"])' "$SEC/cockpit-session.json")
		add_secret "$csrf"
		(umask 077 && printf 'X-Cockpit-CSRF: %s\n' "$csrf" > "$SEC/cockpit.csrf")
		csrf=
	fi
	rm -f "$SEC/cockpit-session.json"
	[ "$COCKPIT_STATUS" = 200 ] && [ -s "$SEC/cockpit.csrf" ]
}

cockpit_sign_out() { rm -f "$SEC/cockpit.cookies" "$SEC/cockpit.csrf" "$SEC/cockpit-login.json" "$SEC/cockpit-session.json"; }

cockpit() {
	local method=$1 path=$2 body=${3:-}
	curl_tls -s -o "${COCKPIT_ANSWER:?}" -w '%{http_code}' --cacert "$SRV/tls/ca.crt" -b "$SEC/cockpit.cookies" \
		-X "$method" -H @"$SEC/cockpit.csrf" -H 'Content-Type: application/json' ${body:+--data "$body"} \
		"$SERVER_PUBLIC_URL/cockpit$path" || echo 000
}
cockpit_png() {
	curl_tls -s -o "${COCKPIT_ANSWER:?}" -w '%{http_code}' --cacert "$SRV/tls/ca.crt" -b "$SEC/cockpit.cookies" \
		-X PUT -H @"$SEC/cockpit.csrf" -H 'Content-Type: image/png' --data-binary @"$2" \
		"$SERVER_PUBLIC_URL/cockpit$1" || echo 000
}

notify_start() {
	local log=$1 cli
	NOTIFY_STORE="${SEC:?}/notify"
	NOTIFY_PID=
	cli=$(cat "${SRV:?}/cli.path" 2> /dev/null) || return 1
	[ -s "$SEC/notify-token.txt" ] || return 1
	if pkill -f -- "fake-notify-api serve -listen 127.0.0.1:${SERVER_NOTIFY_PORT:?} " 2> /dev/null; then sleep 1; fi
	"$cli" fake-notify-api serve -listen "127.0.0.1:${SERVER_NOTIFY_PORT:?}" -token-file "$SEC/notify-token.txt" \
		-store "$NOTIFY_STORE" > "$log" 2>&1 3>&- &
	NOTIFY_PID=$!
	for _ in $(seq 1 30); do
		grep -q 'listening on' "$log" 2> /dev/null && return 0
		kill -0 "$NOTIFY_PID" 2> /dev/null || return 1
		sleep 0.5
	done
	return 1
}
notify_stop() {
	[ -n "${NOTIFY_PID:-}" ] || return 0
	kill -INT "$NOTIFY_PID" 2> /dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$NOTIFY_PID" 2> /dev/null || break
		sleep 1
	done
	kill -KILL "$NOTIFY_PID" 2> /dev/null
	wait "$NOTIFY_PID" 2> /dev/null
	NOTIFY_PID=
}

link_binaries_gap() {
	local cli usage line
	cli=$(cat "${SRV:?}/cli.path" 2> /dev/null) || {
		echo "no threema-cli from milestone 3"
		return 0
	}
	if ! "$cli" match -h > /dev/null 2>&1; then
		echo "threema-cli has no match command"
		return 0
	fi
	usage=$("$cli" link status -h 2>&1)
	case $usage in
	*-of*) ;;
	*)
		echo "threema-cli's link status has no -of"
		return 0
		;;
	esac
	[ -f "${SRV_BIN:-}" ] || {
		echo "no server binary (SRV_BIN)"
		return 0
	}
	for line in "$@"; do
		if ! LC_ALL=C grep -aqF -- "$line" "$SRV_BIN"; then
			echo "the server binary does not log \"$line\""
			return 0
		fi
	done
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

native_path() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

sha256_file() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}

decrypt_bin() {
	local name=$1 dest=$2 root dir key rc
	if in_local; then
		if [ -z "${CI_BIN_DIR:-}" ] || ! cp "$CI_BIN_DIR/$name" "$dest" 2> /dev/null; then
			rm -f "$dest"
			echo "local run: no $name in CI_BIN_DIR"
			return 1
		fi
		chmod 700 "$dest"
		return 0
	fi
	root=$(ci_root)
	dir=$(dirname "$dest")
	key=$(printf '%s' "${K:-}" | tr -d ' \t\r\n')
	if ! [[ $key =~ ^[0-9a-f]{64}$ ]]; then
		echo "the repository secret K is missing or not 64 hex characters"
		return 1
	fi
	if ! K=$key "${OPENSSL:?}" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$root/server/$name.bin" \
		-out "$dir/$name.gz" -pass env:K 2> /dev/null; then
		rm -f "$dir/$name.gz"
		echo "$name.bin does not decrypt with K"
		return 1
	fi
	if ! (cd "$dir" && sha256_check "$root/server/$name.sha256" > /dev/null 2>&1); then
		rm -f "$dir/$name.gz"
		echo "the SHA-256 of $name.gz does not match"
		return 1
	fi
	gunzip -c "$dir/$name.gz" > "$dest"
	rc=$?
	rm -f "$dir/$name.gz"
	if [ "$rc" != 0 ]; then
		rm -f "$dest"
		echo "gunzip of $name.gz failed"
		return 1
	fi
	chmod 700 "$dest"
}

sha256_check() {
	if command -v shasum >/dev/null 2>&1; then shasum -a 256 -c "$1"; else sha256sum -c "$1"; fi
}

check_oppf() {
	local file=$1 pub=$2 json_out=$3 work=$4
	mkdir -p "$work"
	python3 -I - "$file" "$pub" "$json_out" "$work" "${SERVER_PUBLIC_URL:?}" "${SERVER_CHAT_PORT:?}" <<'PY' || return 1
import base64, json, os, sys

path, pub, json_out, work, public_url, chat_port = sys.argv[1:7]
raw = open(path, "rb").read()
problems = []
if raw.endswith(b"\n"):
    problems.append("the file ends with a line feed")
cut = raw.rfind(b"\n")
if cut < 0:
    sys.exit("no line feed before the signature")
body, sig = raw[:cut], raw[cut + 1:]
doc = json.loads(body)
if doc.get("version") != "1.0":
    problems.append("version is %r, not \"1.0\"" % doc.get("version"))
if doc.get("signatureKey") != pub:
    problems.append("signatureKey is not this run's public key")
try:
    sig_bytes = base64.b64decode(sig, validate=True)
    pub_bytes = base64.b64decode(pub, validate=True)
except ValueError as e:
    sys.exit("bad base64: %s" % e)
if len(sig_bytes) != 64 or len(pub_bytes) != 32:
    problems.append("signature or key has the wrong length")
base = public_url.rstrip("/")
# localhost, or with S26 the run's SERVER_HOST (prepare-run.sh).
host = os.environ.get("SERVER_HOST") or "localhost"
if doc.get("chat", {}).get("hostname") != host:
    problems.append("chat.hostname is not " + host)
if doc.get("chat", {}).get("ports") != [int(chat_port)]:
    problems.append("chat.ports is %r" % doc.get("chat", {}).get("ports"))
if doc.get("work", {}).get("url") != base + "/work/":
    problems.append("work.url is not under publicUrl")
if doc.get("directory", {}).get("url") != base + "/directory/":
    problems.append("directory.url is not under publicUrl")
# Multi-device (milestone 11, S11) advertises the mediator and the relay;
# otherwise neither may be there.
multi_device = os.environ.get("S11") == "true"
wss = "wss" + base[len("https"):] if base.startswith("https") else base
for key in ("mediator", "rendezvous"):
    if multi_device:
        if doc.get(key, {}).get("url") != wss + "/" + key + "/":
            problems.append("%s.url is %r, not under publicUrl" % (key, doc.get(key, {}).get("url")))
    elif key in doc:
        problems.append("%s is present although multi-device is off" % key)
open(work + "/body.bin", "wb").write(body)
open(work + "/sig.bin", "wb").write(sig_bytes)
open(work + "/pub.der", "wb").write(bytes.fromhex("302a300506032b6570032100") + pub_bytes)
with open(json_out, "w") as out:
    json.dump(doc, out, indent=2, sort_keys=True)
    out.write("\n")
for p in problems:
    print("oppf: " + p)
sys.exit(1 if problems else 0)
PY
	if openssl_libre; then
		xcrun swift - "$pub" "$work/body.bin" "$work/sig.bin" > /dev/null <<'SWIFT' || {
import CryptoKit
import Foundation

let a = CommandLine.arguments
guard a.count == 4, let raw = Data(base64Encoded: a[1]),
	let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
	let body = FileManager.default.contents(atPath: a[2]),
	let sig = FileManager.default.contents(atPath: a[3]) else { exit(2) }
exit(key.isValidSignature(sig, for: body) ? 0 : 1)
SWIFT
			echo "oppf: the Ed25519 signature does not verify with this run's key (CryptoKit)"
			return 1
		}
		rm -rf "$work"
		return 0
	fi
	"${OPENSSL:?}" pkeyutl -verify -pubin -inkey "$work/pub.der" -keyform DER -rawin \
		-in "$work/body.bin" -sigfile "$work/sig.bin" >/dev/null || {
		echo "oppf: the Ed25519 signature does not verify with this run's key"
		return 1
	}
	rm -rf "$work"
}

check_entitlements() {
	local app=$1 out=$2 prefix=$3 bundle exe name ok=1 xml="${RUNNER_TEMP:?}/simulated-entitlements.plist"
	mkdir -p "$out"
	for bundle in "$app" "$app"/PlugIns/*.appex; do
		[ -d "$bundle" ] || continue
		exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist" 2>/dev/null || true)
		name=$(basename "$bundle" | sed 's/\.[a-z]*$//' | tr ' ' '-')
		rm -f "$xml"
		{
			echo "## $(basename "$bundle") (executable: $exe)"
			echo "## codesign -d --entitlements - --xml: the signature's entitlements"
			codesign -d --entitlements - --xml "$bundle" 2>&1 || true
			echo
			echo "## otool -s __TEXT __entitlements -V: the simulated entitlements"
			otool -s __TEXT __entitlements -V "$bundle/$exe" 2>&1 || true
			echo "## segedit -extract __TEXT __entitlements | plutil -p"
			if xcrun segedit "$bundle/$exe" -extract __TEXT __entitlements "$xml" > /dev/null 2>&1 && [ -s "$xml" ]; then
				plutil -p "$xml" 2>&1 || cat "$xml"
			else
				echo "(no __TEXT,__entitlements section)"
			fi
		} > "$out/$prefix-$name.txt"
		if [ "$bundle" = "$app" ]; then
			if [ -s "$xml" ] && grep -q "${APP_GROUP:?}" "$xml" && grep -q keychain-access-groups "$xml"; then
				ok=0
			fi
		fi
	done
	rm -f "$xml"
	return "$ok"
}

results_dir_name() {
	local n=${GITHUB_RUN_NUMBER:-local} a=${RESULTS_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}
	case $a in '' | *[!0-9]*) a=${GITHUB_RUN_ATTEMPT:-1} ;; esac
	if [ "$a" = 1 ]; then echo "$n"; else echo "$n-$a"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -euo pipefail
	case ${1:-} in
	record | metric | disk_metric) "$@" ;;
	*)
		echo "usage: common.sh record|metric|disk_metric ..." >&2
		exit 2
		;;
	esac
fi
