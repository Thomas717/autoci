#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RESULTS:?}"

selftest=$(failing_stages "verdict-selftest-a
verdict-selftest-b")
if [ "$selftest" != "$(printf 'verdict-selftest-a\tNOT RUN\nverdict-selftest-b\tNOT RUN')" ]; then
	echo "::error::the verdict's own check failed: failing_stages does not work with this awk"
	exit 1
fi

failed=$(failing_stages "$(required_stages)")
echo "required: $(required_stages | tr '\n' ' ')"
if [ -n "$failed" ]; then
	echo "required stages that did not pass:"
	printf '%s\n' "$failed" | awk -F'\t' '{ printf "  %-16s %s\n", $1, $2 }'
	if in_actions; then
		echo "::error::$(printf '%s\n' "$failed" | awk -F'\t' '{ printf "%s%s", sep, $1; sep = ", " }') did not pass; see summary.md"
	fi
	exit 1
fi
echo "every required stage passed"
