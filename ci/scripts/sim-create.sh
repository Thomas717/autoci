#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${SIM:?}" "${SIM_DEVICE_TYPE:?}" "${SIM_RUNTIME_ID:?}"

stage sim-create
if ! udid=$(xcrun simctl create "ci-${GITHUB_RUN_NUMBER:-local}" "$SIM_DEVICE_TYPE" "$SIM_RUNTIME_ID"); then
	record sim-create FAIL "simctl create $SIM_DEVICE_TYPE on $SIM_RUNTIME_ID"
	exit 1
fi
printf '%s\n' "$udid" > "$SIM/udid"
gh_env SIM_UDID "$udid"
metric device "$SIM_DEVICE_TYPE ($udid)"
record sim-create PASS "$udid"
