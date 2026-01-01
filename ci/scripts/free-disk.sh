#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"

stage free-disk
before=$(disk_free_gb)
disk_metric before_cleanup

if [ "$before" -lt 40 ]; then
	echo "under 40 GB free: deleting the simulator runtimes this run does not use"
	xcrun simctl runtime list -j > "$RUNNER_TEMP/runtime-list.json" 2>/dev/null || echo '{}' > "$RUNNER_TEMP/runtime-list.json"
	python3 -I - "$RUNNER_TEMP/runtime-list.json" "$SIM_IOS_VERSION" <<'PY' > "$RUNNER_TEMP/runtimes-to-delete.txt"
import json, sys

path, want = sys.argv[1:3]
for key, r in json.load(open(path)).items():
    platform = r.get("platformIdentifier", "")
    version = r.get("version", "")
    keep = platform.endswith("iphonesimulator") and (version == want or version.startswith(want + "."))
    if not keep:
        print(r.get("identifier", key), platform, version)
PY
	while read -r id platform version; do
		[ -n "$id" ] || continue
		echo "  delete $platform $version ($id)"
		xcrun simctl runtime delete "$id" >/dev/null 2>&1 || echo "  (could not delete $id)"
	done < "$RUNNER_TEMP/runtimes-to-delete.txt"
	sleep 5
fi

if [ "$(disk_free_gb)" -lt 25 ]; then
	keep=$(cd "$XCODE_APP" && pwd -P)
	linked=$(cd /Applications/Xcode.app 2>/dev/null && pwd -P || true)
	for x in /Applications/Xcode_*.app; do
		[ -d "$x" ] || continue
		real=$(cd "$x" && pwd -P)
		if [ "$real" = "$keep" ] || [ "$real" = "$linked" ]; then continue; fi
		echo "under 25 GB free: deleting $x in the background"
		nohup sudo rm -rf "$x" > /dev/null 2>&1 3>&- &
	done
	if [ -d "$HOME/Library/Android/sdk" ]; then
		echo "deleting the Android SDK in the background"
		nohup rm -rf "$HOME/Library/Android/sdk" > /dev/null 2>&1 3>&- &
	fi
fi

disk_metric after_cleanup
df -h /
record free-disk INFO "$before GB before, $(disk_free_gb) GB after"
exit 0
