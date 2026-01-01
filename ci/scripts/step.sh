#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
script=${1:?usage: step.sh SCRIPT [ARGS...]}
shift
name=$(basename "$script" .sh)
logs="${RUNNER_TEMP:?}/steps"
stages="${RESULTS:-$RUNNER_TEMP/results}/stages.txt"
mkdir -p "$logs"
before=0
[ -f "$stages" ] && before=$(wc -l < "$stages" | tr -d ' ')

status=0
stopped=
trap 'stopped=SIGTERM' TERM
trap 'stopped=SIGINT' INT
bash "$root/$script" "$@" 3>&1 >> "$logs/$name.log" 2>&1 || status=$?

case $name in
sim-m[0-9] | sim-m[0-9][0-9])
	if [ -n "${RESULTS:-}" ] && . "$here/common.sh"; then
		how="$name.sh exited $status"
		[ -z "$stopped" ] || how="$name.sh was stopped ($stopped: the step's timeout, or a cancelled run)"
		explain_unrecorded "${name#sim-m}" "$logs/$name.log" "$how" >> "$logs/$name.log" 2>&1
	fi
	;;
esac

if [ -f "$stages" ]; then
	awk -F'\t' -v n="$before" 'NR > n { c[$2]++; k++ } END { for (s in c) { printf "%s%s %d", sep, s, c[s]; sep = " " } if (k) print "" }' "$stages"
fi
if [ "$status" != 0 ]; then
	echo "$name: exit $status"
fi
exit "$status"
