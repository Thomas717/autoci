#!/bin/bash
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${SRV:?}" "${SEC:?}" "${SRV_BIN:?}" "${SERVER_HTTP_PORT:?}"
find_openssl
host=${SERVER_HOST:-localhost}
base="https://$host:$SERVER_HTTP_PORT"
ca="$SRV/tls/ca.crt"

stage server-start
if [ ! -f "$SRV_BIN" ]; then
	why=$(decrypt_bin srv "$SRV_BIN") || { record server-start FAIL "$why"; exit 1; }
fi
K=
unset K
nohup "$SRV_BIN" serve -config "$SRV/server.yaml" > "$SRV/server.log" 2>&1 3>&- &
echo $! > "$SRV/server.pid"
up=false
for _ in $(seq 1 60); do
	if curl_tls -fsS --max-time 5 --cacert "$ca" "$base/health" > /dev/null 2>&1; then
		up=true
		break
	fi
	kill -0 "$(cat "$SRV/server.pid")" 2> /dev/null || break
	sleep 1
done
if [ "$up" != true ]; then
	echo "the server did not answer /health; the end of its log:"
	tail -n 40 "$SRV/server.log" || true
	record server-start FAIL "no /health over HTTPS within 60 s"
	exit 1
fi
record server-start PASS "$base/health answers"

stage tls-selfcheck
v4=$(curl_tls -4 -sS --max-time 10 --cacert "$ca" -o /dev/null -w '%{http_code}' "$base/health" 2>&1 || true)
v6=$(curl_tls -6 -sS --max-time 10 --cacert "$ca" -o /dev/null -w '%{http_code}' "$base/health" 2>&1 || true)
ok_line='Verification: OK'
proto_re='^Protocol version'
if openssl_libre; then
	s_client=$("$OPENSSL" s_client -connect "$host:$SERVER_HTTP_PORT" -servername "$host" -CAfile "$ca" \
		-verify_return_error < /dev/null 2>&1 || true)
	ok_line='Verify return code: 0 (ok)'
	proto_re='^ *Protocol *:'
else
	s_client=$("$OPENSSL" s_client -connect "$host:$SERVER_HTTP_PORT" -servername "$host" -CAfile "$ca" \
		-verify_return_error -brief < /dev/null 2>&1 || true)
fi
{
	echo "## curl -4 $base/health"
	echo "$v4"
	echo "## curl -6 $base/health"
	echo "$v6"
	echo "## openssl s_client -brief (protocol, group, verification)"
	echo "$s_client"
	if is_macos; then
		echo "## security verify-cert -p ssl -s $host -L"
		security verify-cert -c "$SRV/tls/server.crt" -r "$ca" -p ssl -s "$host" -L 2>&1 || true
		echo "## security verify-cert -p ssl -s $host -L -l"
		security verify-cert -c "$SRV/tls/server.crt" -r "$ca" -p ssl -s "$host" -L -l 2>&1 || true
	fi
} > "$RESULTS/server/selfcheck.txt"
case $s_client in *"$ok_line"*) verified=true ;; *) verified=false ;; esac
if [ "$v4" = 200 ] && [ "$verified" = true ]; then
	record tls-selfcheck PASS "IPv4 200, IPv6 $v6, $(printf '%s\n' "$s_client" | awk -F': ' -v re="$proto_re" '$0 ~ re { print $2 }')"
else
	cat "$RESULTS/server/selfcheck.txt"
	record tls-selfcheck FAIL "IPv4 $v4, IPv6 $v6"
fi

stage oppf-selfcheck
anon=$(curl_tls -sS --max-time 10 --cacert "$ca" -o /dev/null -w '%{http_code}' "$base/prov/config.oppf" 2>&1 || true)
if curl_tls -fsS --max-time 10 --cacert "$ca" -K "$SEC/curl-auth.cfg" "$base/prov/config.oppf" -o "$SRV/fetched.oppf" &&
	check_oppf "$SRV/fetched.oppf" "$(cat "$SRV/oppf-public.key")" "$SRV/fetched-oppf.json" "$SRV/fetched-check"; then
	same=differs
	cmp -s "$SRV/fetched.oppf" "$SRV/config.oppf" && same="identical to the oppf command's"
	if [ "$anon" = 401 ]; then
		record oppf-selfcheck PASS "401 without credentials; served with the seat's, signed by this run's key, $same"
	else
		record oppf-selfcheck FAIL "answered $anon without credentials, not 401"
	fi
else
	record oppf-selfcheck FAIL "fetching or checking /prov/config.oppf with the seat's credentials failed"
fi

wc -c < "$SRV/server.log" | tr -d ' ' > "$SRV/log.offset"
echo "server log offset for the app's lines: $(cat "$SRV/log.offset") bytes"
for s in tls-selfcheck oppf-selfcheck; do
	[ "$(stage_status "$s")" = PASS ] || exit 1
done
