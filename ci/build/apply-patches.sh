#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/common.sh"
root=$(ci_root)
: "${RUNNER_TEMP:?}" "${RESULTS:?}"
tree="$root/threema-ios"
list="$RUNNER_TEMP/app-patches.txt"
mkdir -p "$RESULTS/build"

stage app-patches
if [ ! -d "$tree/.git" ]; then
	record app-patches FAIL "no upstream checkout in threema-ios"
	exit 1
fi
head=$(git -C "$tree" rev-parse --short HEAD)
: > "$list"
names=
n=0
for patch in "$here"/patches/*.patch; do
	[ -f "$patch" ] || continue
	name=$(basename "$patch")
	report="$RESULTS/build/patch-${name%.patch}.txt"
	if ! git -C "$tree" apply --check --verbose "$patch" > "$report" 2>&1; then
		cat "$report"
		record app-patches FAIL "$name does not apply to threema-ios $head (build/$(basename "$report"))"
		exit 1
	fi
	if ! git -C "$tree" apply --verbose "$patch" >> "$report" 2>&1; then
		cat "$report"
		record app-patches FAIL "$name passed the check but did not apply (build/$(basename "$report"))"
		exit 1
	fi
	git -C "$tree" apply --numstat "$patch" >> "$report" 2>&1 || true
	printf '%s %s\n' "$name" "$(sha256_file "$patch")" >> "$list"
	names="$names${names:+, }$name"
	n=$((n + 1))
done
git -C "$tree" status --short > "$RESULTS/build/patched-files.txt" 2>&1 || true
record app-patches PASS "$n patch(es) applied to threema-ios $head${names:+: $names}"
