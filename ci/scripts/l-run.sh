#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RESULTS:?}" "${RUNNER_TEMP:?}"
work="$RUNNER_TEMP/l"
out="$RESULTS/l"
umask 077
rm -rf "$work"
mkdir -p -m 700 "$work"
mkdir -m 700 "$work/bin" "$work/run"
mkdir -p "$out"
trap 'rm -rf "$work"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

cleanup_record() {
	K=
	unset K
	rm -rf "$work"
	if [ -e "$work" ]; then
		record l-cleanup FAIL "the decrypted files are still on disk"
	else
		record l-cleanup PASS "the decrypted list and binaries deleted"
	fi
}
fail_decrypt() {
	record l-decrypt FAIL "$1"
	cleanup_record
	exit 1
}

stage l-decrypt
find_openssl > /dev/null || fail_decrypt "no OpenSSL 3"
why=$(decrypt_bin l0 "$work/list") || fail_decrypt "$why"
name_re='^l[1-9]$'
stage_re='^[a-z0-9][a-z0-9-]*$'
word_re='^[A-Za-z0-9_.^$|()*+?/=:,-]+$'
runs=()
need=" "
stages=" "
bins=""
n=0
while IFS= read -r line || [ -n "$line" ]; do
	n=$((n + 1))
	case $line in '' | '#'*) continue ;; esac
	read -r -a w <<< "$line"
	case ${w[0]} in
	bin)
		if [ "${#w[@]}" != 4 ] || ! [[ ${w[1]} =~ $name_re ]] || ! [[ ${w[2]} =~ ^[0-9a-f]{7,40}$ ]]; then
			fail_decrypt "line $n of the list is not 'bin lN COMMIT PACKAGE'"
		fi
		bins="$bins ${w[1]}=${w[2]}"
		;;
	run)
		if [ "${#w[@]}" -lt 5 ] || ! [[ ${w[1]} =~ $stage_re ]] || ! [[ ${w[2]} =~ ^(test|bench)$ ]] ||
			! [[ ${w[3]} =~ $name_re ]]; then
			fail_decrypt "line $n of the list is not 'run STAGE test|bench lN ARGS...'"
		fi
		case $stages in *" ${w[1]} "*) fail_decrypt "the list names stage ${w[1]} twice" ;; esac
		stages="$stages${w[1]} "
		for a in "${w[@]:4}"; do
			[[ $a =~ $word_re ]] || fail_decrypt "line $n of the list has an argument that is not a plain word"
		done
		runs+=("$line")
		case $need in *" ${w[3]} "*) ;; *) need="$need${w[3]} " ;; esac
		;;
	*) fail_decrypt "line $n of the list is neither a bin nor a run line" ;;
	esac
done < "$work/list"
rm -f "$work/list"
[ "${#runs[@]}" -gt 0 ] || fail_decrypt "the list has no run line"
for b in $need; do
	why=$(decrypt_bin "$b" "$work/bin/$b") || fail_decrypt "$why"
done
K=
unset K
record l-decrypt PASS "${#runs[@]} entries, binaries$bins"

ncpu=$(nproc 2> /dev/null || echo 1)
mem_gb=$(awk '/^MemTotal:/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo 2> /dev/null)
os=$(. /etc/os-release 2> /dev/null && printf '%s' "${PRETTY_NAME:-}")
sysctl_of() { tr -s ' \t' ' ' 2> /dev/null < "/proc/sys/net/$1" || echo "?"; }
metric cpus "$ncpu"
metric memory_gb "$mem_gb"
metric os "$os"
metric kernel "$(uname -r)"
record l-runner INFO "$ncpu CPUs, $mem_gb GB, $os, kernel $(uname -r)," \
	"tcp_notsent_lowat $(sysctl_of ipv4/tcp_notsent_lowat), tcp_wmem $(sysctl_of ipv4/tcp_wmem)," \
	"tcp_rmem $(sysctl_of ipv4/tcp_rmem), wmem_default $(sysctl_of core/wmem_default)," \
	"congestion control $(sysctl_of ipv4/tcp_congestion_control), lo mtu $(cat /sys/class/net/lo/mtu 2> /dev/null || echo ?)"

bench_lines() {
	awk -v cpu="-$ncpu" '
		/^Benchmark[^ \t]*[ \t]+[0-9]+[ \t]/ {
			name = $1
			if (length(name) > length(cpu) && substr(name, length(name) - length(cpu) + 1) == cpu)
				name = substr(name, 1, length(name) - length(cpu))
			sub("^Benchmark[^/]*/?", "", name)
			if (name == "") name = "all"
			if (!(name in seen)) { seen[name] = 1; order[++count] = name }
			for (i = 3; i + 1 <= NF; i += 2) {
				unit = $(i + 1)
				if (unit == "ns/op") continue
				key = name SUBSEP unit
				if (key in vals) vals[key] = vals[key] "," $i
				else { vals[key] = $i; units[name] = units[name] (units[name] == "" ? "" : " ") unit }
			}
		}
		END {
			for (j = 1; j <= count; j++) {
				nm = order[j]; line = ""; sep = ""
				k = split(units[nm], us, " ")
				for (x = 1; x <= k; x++) { line = line sep us[x] " " vals[nm SUBSEP us[x]]; sep = "; " }
				print nm "\t" line
			}
		}' "$1"
}

all=true
failed=""
for line in "${runs[@]}"; do
	read -r -a w <<< "$line"
	st=${w[1]}
	kind=${w[2]}
	b=${w[3]}
	args=("${w[@]:4}")
	log="$out/$st.txt"
	rm -rf "$work/run/tmp"
	mkdir -m 700 "$work/run/tmp"
	stage "$st"
	(cd "$work/run" && TMPDIR="$work/run/tmp" timeout -k 10 1200 "$work/bin/$b" "${args[@]}") > "$log" 2>&1
	rc=$?
	fails=$(grep -c -E '^[[:space:]]*--- FAIL' "$log")
	skips=$(grep -c -E '^[[:space:]]*--- SKIP' "$log")
	passes=$(grep -c -E '^[[:space:]]*--- PASS' "$log")
	benches=$(grep -c -E '^Benchmark[^[:space:]]*[[:space:]]+[0-9]+[[:space:]]' "$log")
	last=$(grep -v -E '^[[:space:]]*$' "$log" | tail -n 1)
	status=FAIL
	if [ "$rc" != 0 ]; then
		note="exit $rc"
		[ "$rc" != 124 ] || note="exit 124: stopped after 20 minutes"
	elif [ "$fails" != 0 ] || [ "$skips" != 0 ]; then
		note="$fails failed, $skips skipped"
	elif [ "$last" != PASS ]; then
		note="its output does not end in PASS"
	elif [ "$kind" = test ] && [ "$passes" = 0 ]; then
		note="no test ran"
	elif [ "$kind" = bench ] && [ "$benches" = 0 ]; then
		note="no benchmark ran"
	else
		status=PASS
		if [ "$kind" = test ]; then note="$passes test(s) passed"; else note="$benches benchmark line(s)"; fi
	fi
	record "$st" "$status" "$kind $b: $note (l/$st.txt)"
	if [ "$status" != PASS ]; then
		all=false
		failed="$failed $st"
	fi
	if [ "$kind" = bench ]; then
		while IFS=$'\t' read -r sub numbers; do
			[ -n "$sub" ] || continue
			record "$st/$sub" INFO "$numbers"
		done < <(bench_lines "$log")
	else
		result=$(grep -E '^[[:space:]]*--- (PASS|FAIL|SKIP)' "$log" | sed 's/^[[:space:]]*//' | tr '\n' ';' | cut -c1-300)
		record "$st/result" INFO "${result:-no --- line}"
	fi
done
rm -rf "$work/run"

stage l-all
if [ "$all" = true ]; then
	record l-all PASS "all ${#runs[@]} entries passed"
else
	record l-all FAIL "did not pass:$failed"
fi
cleanup_record
[ "$all" = true ]
