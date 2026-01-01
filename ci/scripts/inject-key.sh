#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${SRV:?}" "${RUNNER_TEMP:?}"
pub=$(cat "$SRV/oppf-public.key")

append_key() {
	local extra=
	if in_local; then extra=${CI_APP_EXTRA_KEYS:-}; fi
	python3 -I - "$1" "$pub" "$extra" <<'PY'
import plistlib, sys

path, key, extra = sys.argv[1:4]
raw = open(path, "rb").read()
fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist00") else plistlib.FMT_XML
doc = plistlib.loads(raw)
keys = doc.get("ThreemaOnPremPublicKeys")
if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys):
    sys.exit("ThreemaOnPremPublicKeys is missing or not a list of strings")
upstream = [k for k in keys if k != key and k not in extra.split()]
if len(upstream) != 3:
    sys.exit("expected the 3 upstream keys besides this run's, found %d" % len(upstream))
if key in keys:
    print("the run's OPPF key is already in %s" % path)
    sys.exit(0)
keys.append(key)
with open(path, "wb") as f:
    plistlib.dump(doc, f, fmt=fmt, sort_keys=False)
print("appended the run's OPPF key (%s plist, now %d keys)" % ("binary" if fmt == plistlib.FMT_BINARY else "XML", len(keys)))
PY
}

has_key() {
	python3 -I -c 'import plistlib, sys
keys = plistlib.load(open(sys.argv[1], "rb")).get("ThreemaOnPremPublicKeys", [])
sys.exit(0 if keys.count(sys.argv[2]) == 1 else 1)' "$1" "$pub"
}

case ${1:-} in
source)
	plist=${2:?source plist}
	stage key-source
	if ! append_key "$plist" || ! has_key "$plist"; then
		record key-source FAIL "could not add the run's key to the source plist"
		exit 1
	fi
	record key-source PASS "the run's key is in the source plist; this build is not cached"
	;;
bundle)
	src="$RUNNER_TEMP/app/Threema OnPrem.app"
	stage app-ready
	if [ ! -d "$src" ]; then
		record app-ready FAIL "no app was built or restored"
		exit 1
	fi
	info="$RUNNER_TEMP/app/build-info.txt"
	mkdir -p "$RESULTS/build"
	cp "$info" "$RESULTS/build/build-info.txt" 2> /dev/null || true
	patches=$( (sed -n 's/^source patch: \([^ ]*\) .*/\1/p' "$info" 2> /dev/null || true) | tr '\n' ' ')
	patches=${patches% }
	record app-ready PASS "$(cat "$info" 2>/dev/null | head -n 1); source patches: ${patches:-none}"
	if [ -z "$(stage_status app-patches)" ]; then
		record app-patches INFO "the cached app's build-info.txt: ${patches:-no source patch}"
	fi

	stage key-inject
	run="$RUNNER_TEMP/app-run"
	app="$run/Threema OnPrem.app"
	fw="$app/Frameworks/ThreemaFramework.framework"
	plist="$fw/ThreemaFrameworkConfiguration.plist"
	rm -rf "$run"
	mkdir -p "$run"
	ditto "$src" "$app"
	find "$app" -name ThreemaFrameworkConfiguration.plist > "$RUNNER_TEMP/config-plists.txt"
	cat "$RUNNER_TEMP/config-plists.txt"
	if ! grep -qxF "$plist" "$RUNNER_TEMP/config-plists.txt"; then
		record key-inject FAIL "no ThreemaFrameworkConfiguration.plist in Frameworks/ThreemaFramework.framework"
		exit 1
	fi
	others=$(grep -vxcF "$plist" "$RUNNER_TEMP/config-plists.txt" || true)
	[ "$others" != 0 ] || others=
	if [ "${KEY_PATCH:-bundle}" = bundle ]; then
		if ! append_key "$plist"; then
			record key-inject FAIL "could not add the run's key to the bundle's plist"
			exit 1
		fi
		if ! codesign --force --sign - --timestamp=none --preserve-metadata=identifier,entitlements,flags "$fw" ||
			! codesign --force --sign - --timestamp=none --preserve-metadata=identifier,entitlements,flags "$app"; then
			record key-inject FAIL "ad-hoc re-signing failed"
			exit 1
		fi
		how="appended to the built bundle and re-signed ad hoc"
	else
		how="built in from the source plist"
	fi
	if ! codesign --verify --deep --strict "$app"; then
		record key-inject FAIL "codesign --verify --deep --strict fails on the patched app"
		exit 1
	fi
	if ! has_key "$plist"; then
		record key-inject FAIL "the run's key is not in the app's ThreemaOnPremPublicKeys"
		exit 1
	fi
	served=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["signatureKey"])' "$RESULTS/server/oppf.json")
	if [ "$served" != "$pub" ]; then
		record key-inject FAIL "the provisioning file is signed by another key"
		exit 1
	fi
	record key-inject PASS "$how; equals the provisioning file's signatureKey${others:+; $others other copy(ies) of the plist left alone}"

	stage entitlements
	if check_entitlements "$app" "$RESULTS/build" run; then
		record entitlements PASS "simulated entitlements carry $APP_GROUP and keychain-access-groups"
	else
		record entitlements FAIL "the app's simulated entitlements lack $APP_GROUP or keychain-access-groups"
	fi
	;;
*)
	echo "usage: inject-key.sh source <plist> | bundle" >&2
	exit 2
	;;
esac
