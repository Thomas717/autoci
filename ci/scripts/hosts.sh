#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${SERVER_HOST:?}"

stage hosts
host_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
if ! [[ $SERVER_HOST =~ $host_re ]]; then
	record hosts FAIL "SERVER_HOST is not a lower-case DNS name with a dot"
	exit 1
fi

addresses() {
	python3 -I - "$SERVER_HOST" <<'PY' 2> /dev/null || true
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None)
except OSError:
    sys.exit(0)
print(" ".join(sorted({i[4][0] for i in infos})))
PY
}

mapped() {
	awk -v a="$1" -v h="$SERVER_HOST" '
		$1 == a { for (i = 2; i <= NF; i++) { if ($i ~ /^#/) break; if ($i == h) f = 1 } }
		END { exit !f }' /etc/hosts 2> /dev/null
}

how="a local run: the Mac's /etc/hosts"
if in_actions; then
	how="/etc/hosts"
	for a in 127.0.0.1 ::1; do
		if ! mapped "$a"; then
			lf=
			[ -z "$(tail -c 1 /etc/hosts 2> /dev/null)" ] || lf=$'\n'
			printf '%s%s %s\n' "$lf" "$a" "$SERVER_HOST" | sudo tee -a /etc/hosts > /dev/null ||
				{ record hosts FAIL "sudo tee -a /etc/hosts failed"; exit 1; }
			how="/etc/hosts, added with sudo"
		fi
	done
	if is_macos; then
		sudo dscacheutil -flushcache 2> /dev/null || true
		sudo killall -HUP mDNSResponder 2> /dev/null || true
	fi
fi
got=
for _ in 1 2 3 4 5 6 7 8 9 10; do
	got=$(addresses | tr -d '\r')
	case " $got " in *" 127.0.0.1 "*) break ;; esac
	sleep 1
done
metric server_host "$SERVER_HOST"
missing=
for a in 127.0.0.1 ::1; do
	mapped "$a" || missing="$missing \"$a $SERVER_HOST\""
done
ok=false
case " $got " in *" 127.0.0.1 "*) [ -n "$missing" ] || ok=true ;; esac
if [ "$ok" = true ]; then
	record hosts PASS "$SERVER_HOST resolves to ${got}; /etc/hosts maps it to 127.0.0.1 and ::1 ($how)"
else
	if in_local; then
		record hosts FAIL "$SERVER_HOST resolves to ${got:-nothing}; /etc/hosts lacks${missing:- nothing}: the Mac's /etc/hosts needs \"127.0.0.1 $SERVER_HOST\" and \"::1 $SERVER_HOST\" (the owner adds them, sudo)"
	else
		record hosts FAIL "$SERVER_HOST resolves to ${got:-nothing} (it must give 127.0.0.1); /etc/hosts lacks${missing:- nothing} ($how)"
	fi
	exit 1
fi
