#!/bin/bash
set -euo pipefail
incoming=${1:?usage: publish-results.sh <downloaded artifact dir>}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${GITHUB_RUN_NUMBER:?}"
run=$(results_dir_name)
pub="$RUNNER_TEMP/pub"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

checkout_branch() {
	rm -rf "$pub"
	git worktree prune
	if git fetch --depth=1 origin out 2> /dev/null; then
		git worktree add -B out "$pub" FETCH_HEAD
	else
		git worktree add --detach "$pub"
		git branch -D out > /dev/null 2>&1 || true
		git -C "$pub" switch --orphan out
	fi
}

apply_results() {
	local verdict
	mkdir -p "$pub/runs"
	if [ -s "$incoming/r.bin" ]; then
		cp "$incoming/r.bin" "$pub/runs/$run.bin"
		verdict=$(head -n 1 "$incoming/v.txt" 2> /dev/null || true)
		case $verdict in PASS | FAIL) ;; *) verdict=unknown ;; esac
	else
		verdict="none (${SIM_RESULT:-unknown})"
	fi
	printf '%s %s %s\n' "$run" "$(date -u '+%Y-%m-%dT%H:%MZ')" "$verdict" >> "$pub/runs/INDEX"
	git -C "$pub" add -A
	git -C "$pub" commit -q -m "r$run"
}

checkout_branch
apply_results
for attempt in 1 2 3; do
	if git -C "$pub" push -q origin out 2> /dev/null; then
		echo "published r$run"
		exit 0
	fi
	sleep $((attempt * 5))
	checkout_branch
	apply_results
done
echo "::error::could not push to out"
exit 1
