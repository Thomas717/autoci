#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/common.sh"
root=$(ci_root)
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}"
log="$RESULTS_FULL/spm-resolve.log"

stage spm-resolve
status=0
xcodebuild -resolvePackageDependencies -project "$root/threema-ios/Threema.xcodeproj" -scheme "Threema OnPrem" \
	-clonedSourcePackagesDirPath "$RUNNER_TEMP/spm" -onlyUsePackageVersionsFromResolvedFile \
	> "$log" 2>&1 || status=$?
tail -n 60 "$log" > "$RESULTS/build/spm-resolve.tail.txt"
if [ "$status" != 0 ]; then
	tail -n 60 "$log"
	record spm-resolve FAIL "xcodebuild -resolvePackageDependencies failed"
	exit 1
fi
record spm-resolve PASS "$(du -sh "$RUNNER_TEMP/spm" 2> /dev/null | awk '{ print $1 }') in $RUNNER_TEMP/spm"
