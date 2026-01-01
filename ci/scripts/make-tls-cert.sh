#!/bin/bash
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"

certdir=${1:?certificate dir}
keydir=${2:?key dir}
profile=${3:-selfsigned}
mkdir -p "$certdir" "$keydir"
find_openssl
host=${SERVER_HOST:-localhost}
case $host in
localhost) san="DNS:localhost,IP:127.0.0.1" ;;
*)
	if ! [[ $host =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
		echo "make-tls-cert.sh: SERVER_HOST is not a DNS name" >&2
		exit 2
	fi
	san="DNS:$host,DNS:localhost,IP:127.0.0.1"
	;;
esac
named=
if openssl_libre; then named="-pkeyopt ec_param_enc:named_curve"; fi
cnf="$keydir/openssl-$$.cnf"
leaf_cnf="$keydir/openssl-leaf-$$.cnf"
trap 'rm -f "$cnf" "$leaf_cnf" "$keydir/leaf.csr" "$certdir/leaf.crt" "$certdir/ca.srl"' EXIT

case $profile in
selfsigned)
	cat > "$cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = server
[dn]
CN = $host
[server]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = $san
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
	"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 $named -nodes -sha256 -days 30 \
		-config "$cnf" -keyout "$keydir/server.key" -out "$certdir/server.crt"
	cp "$certdir/server.crt" "$certdir/ca.crt"
	;;
ca-leaf)
	cat > "$cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ca
[ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
	cat > "$leaf_cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $host
[leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = $san
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
	"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 $named -nodes -sha256 -days 30 \
		-config "$cnf" -extensions ca -keyout "$keydir/ca.key" -out "$certdir/ca.crt"
	"$OPENSSL" req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 $named -nodes -sha256 \
		-config "$leaf_cnf" -keyout "$keydir/server.key" -out "$keydir/leaf.csr"
	"$OPENSSL" x509 -req -in "$keydir/leaf.csr" -CA "$certdir/ca.crt" -CAkey "$keydir/ca.key" \
		-CAcreateserial -CAserial "$certdir/ca.srl" -sha256 -days 30 -extfile "$leaf_cnf" -extensions leaf \
		-out "$certdir/leaf.crt"
	cat "$certdir/leaf.crt" "$certdir/ca.crt" > "$certdir/server.crt"
	;;
*)
	echo "make-tls-cert.sh: unknown profile $profile" >&2
	exit 2
	;;
esac
chmod 600 "$keydir"/*.key

if openssl_libre; then
	"$OPENSSL" verify -CAfile "$certdir/ca.crt" -purpose sslserver -x509_strict "$certdir/server.crt" > /dev/null
	want=$(printf '%s' "$san" | sed 's/,/, /g; s/IP:/IP Address:/')
	case $("$OPENSSL" x509 -in "$certdir/server.crt" -noout -text) in
	*"$want"*) ;;
	*) echo "make-tls-cert.sh: the SAN is not $san" >&2; exit 1 ;;
	esac
	echo "TLS certificate ($profile): verifies as a TLS server certificate, SAN $san (LibreSSL)"
	exit 0
fi
"$OPENSSL" verify -CAfile "$certdir/ca.crt" -purpose sslserver -x509_strict \
	-verify_hostname "$host" "$certdir/server.crt" > /dev/null
"$OPENSSL" verify -CAfile "$certdir/ca.crt" -purpose sslserver -x509_strict \
	-verify_ip 127.0.0.1 "$certdir/server.crt" > /dev/null
echo "TLS certificate ($profile): verifies for $host and 127.0.0.1"
