#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}"
mkdir -p "$RESULTS"/server "$RESULTS"/build "$RESULTS"/sim "$RESULTS"/screenshots "$RESULTS_FULL"/server "$RESULTS_FULL"/sim
rm -f "$RESULTS/MASKED"

if [ "${L:-false}" = true ]; then
	pkill -KILL -f -- "$RUNNER_TEMP/l/bin/" 2> /dev/null || true
	rm -rf "${RUNNER_TEMP:?}/l"
fi

tail_copy() {
	local src=$1 dst=$2 max=$3 size
	[ -f "$src" ] || return 0
	size=$(wc -c < "$src" | tr -d ' ')
	if [ "$size" -le "$max" ]; then
		cp "$src" "$dst"
	else
		{
			echo "[cut: the last $max of $size bytes]"
			tail -c "$max" "$src" | sed 1d
		} > "$dst"
	fi
}

if [ -f "$SRV/server.pid" ]; then
	pid=$(cat "$SRV/server.pid")
	if kill -TERM "$pid" 2> /dev/null; then
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$pid" 2> /dev/null || break
			sleep 1
		done
	fi
fi
if [ "${L:-false}" != true ]; then
	diag_probe collect
	sim_log_quiet_end
fi
if is_macos && [ -s "${SIM:-}/udid" ]; then
	xcrun simctl terminate "$(sim_udid)" "${APP_BUNDLE_ID:-}" > /dev/null 2>&1 || true
	xcrun simctl shutdown "$(sim_udid)" > /dev/null 2>&1 || true
fi
if [ -s "$SRV/cli.path" ]; then
	pkill -f -- "$(cat "$SRV/cli.path")" 2> /dev/null || true
fi
if pkill -TERM -f -- 'load-sampler\.py sample ' 2> /dev/null; then
	for _ in 1 2 3 4 5; do
		pgrep -f -- 'load-sampler\.py sample ' > /dev/null 2>&1 || break
		sleep 1
	done
fi
if [ -f "$SRV/server.log" ]; then
	cp "$SRV/server.log" "$RESULTS_FULL/server/server.log"
	tail_copy "$SRV/server.log" "$RESULTS/server/server.log" 1800000
fi
[ -f "$SRV/fetched-oppf.json" ] && cp "$SRV/fetched-oppf.json" "$RESULTS/server/fetched-oppf.json"

for png in "$RESULTS_FULL"/shots/*.png "$RESULTS_FULL"/m2/shots/*.png "$RESULTS_FULL"/m3/shots/*.png \
	"$RESULTS_FULL"/m4/shots/*.png "$RESULTS_FULL"/m5/shots/*.png "$RESULTS_FULL"/m6/shots/*.png "$RESULTS_FULL"/m7/shots/*.png \
	"$RESULTS_FULL"/m8/shots/*.png "$RESULTS_FULL"/m9/shots/*.png \
	"$RESULTS_FULL"/m10/shots/*.png "$RESULTS_FULL"/m11/shots/*.png "$RESULTS_FULL"/m12/shots/*.png "$RESULTS_FULL"/m13/shots/*.png "$RESULTS_FULL"/m14/shots/*.png "$RESULTS_FULL"/m15/shots/*.png "$RESULTS_FULL"/m16/shots/*.png "$RESULTS_FULL"/m17/shots/*.png "$RESULTS_FULL"/m18/shots/*.png "$RESULTS_FULL"/m19/shots/*.png "$RESULTS_FULL"/m20/shots/*.png \
	"$RESULTS_FULL"/m21/shots/*.png "$RESULTS_FULL"/m22/shots/*.png "$RESULTS_FULL"/m23/shots/*.png "$RESULTS_FULL"/m24/shots/*.png "$RESULTS_FULL"/m25/shots/*.png "$RESULTS_FULL"/m26/shots/*.png \
	"$RESULTS_FULL"/m27/shots/*.png "$RESULTS_FULL"/m28/shots/*.png "$RESULTS_FULL"/m29/shots/*.png "$RESULTS_FULL"/m30/shots/*.png; do
	[ -f "$png" ] || continue
	name=$(basename "$png" .png)
	if is_macos; then
		sips -s format jpeg -s formatOptions 80 --resampleWidth 800 "$png" --out "$RESULTS/screenshots/$name.jpg" > /dev/null 2>&1 ||
			echo "::warning::could not convert $name.png"
	fi
done

tail_copy "$RESULTS_FULL/sim/app-stdout.log" "$RESULTS/sim/app-stdout.log" 900000
tail_copy "$RESULTS_FULL/sim/app-stderr.log" "$RESULTS/sim/app-stderr.log" 900000
tail_copy "$RESULTS_FULL/sim/app-oslog.txt" "$RESULTS/sim/app-oslog.txt" 1900000
mkdir -p "$RESULTS/steps" "$RESULTS_FULL/steps"
for log in "${RUNNER_TEMP:?}"/steps/*.log; do
	[ -f "$log" ] || continue
	case $(basename "$log") in collect-results.log) continue ;; esac
	cp "$log" "$RESULTS_FULL/steps/"
	tail_copy "$log" "$RESULTS/steps/$(basename "$log")" 300000
done
for log in "$RUNNER_TEMP"/steps/sim-m*.log; do
	[ -f "$log" ] || continue
	m=$(basename "$log" .log)
	m=${m#sim-m}
	case $m in '' | *[!0-9]*) continue ;; esac
	explain_unrecorded "$m" "$log" "the step of sim-m$m.sh was stopped (a timeout, or a cancelled run)"
done
mkdir -p "$RESULTS/crashes"
if [ -f "$RUNNER_TEMP/m1-start-marker" ]; then
	find "$HOME/Library/Logs/DiagnosticReports" -name '*Threema*' -newer "$RUNNER_TEMP/m1-start-marker" 2> /dev/null |
		while IFS= read -r report; do
			head -c 400000 "$report" > "$RESULTS/crashes/$(basename "$report")" 2> /dev/null || true
		done
fi
if [ "${L:-false}" != true ]; then
	record crash-reports INFO "$(find "$RESULTS/crashes" -type f | wc -l | tr -d ' ') crash report(s) of the app during the run"
fi

mask_pass() {
	if [ -f "$SEC/mask.list" ]; then
		python3 -I "$here/mask-secrets.py" "$SEC/mask.list" "$RESULTS" "$RESULTS_FULL"
	else
		echo "masking: no mask list (the server was never prepared)" | tee -a "$RESULTS/masking.txt"
	fi
}
stage masking
mask_pass
mask1=$?

disk_metric end
metric minutes_total "$((($(date +%s) - ${RUN_T0:-$(date +%s)}) / 60))"
required=$(for s in $(required_stages); do [ "$s" = masking ] || printf '%s ' "$s"; done)
failed=$(failing_stages "$required")
if [ -z "$failed" ] && [ "$mask1" = 0 ]; then verdict=PASS; else verdict=FAIL; fi
metric_value() { awk -F'\t' -v k="$1" '$1 == k { v = $2 } END { print v }' "$RESULTS/metrics.txt" 2> /dev/null; }
short_sha=$(printf '%s' "${GITHUB_SHA:-local}" | cut -c1-7)
app_source=$(stage_status app-source)
dir=$(results_dir_name)
if [ "${L:-false}" = true ]; then
	{
		echo "# Run ${GITHUB_RUN_NUMBER:-local}${GITHUB_RUN_ATTEMPT:+ (attempt $GITHUB_RUN_ATTEMPT)}: $verdict"
		echo
		echo "The Linux job (L=true): the server's Go test binaries (server/l*.bin), each entry of their list a stage."
		echo
		echo "| | |"
		echo "|---|---|"
		echo "| Trigger | ${GITHUB_EVENT_NAME:-local} on ${GITHUB_REF_NAME:-} |"
		echo "| Commit | ${GITHUB_SHA:-local} |"
		echo "| Options | L=true, every other option at its default |"
		echo "| Runner | $(metric_value os), kernel $(metric_value kernel), $(metric_value cpus) CPUs, $(metric_value memory_gb) GB RAM |"
		echo "| Minutes (job, to this step) | $(metric_value minutes_total) |"
		echo
		if [ -n "$failed" ]; then
			echo "Required stages that did not pass: $(printf '%s\n' "$failed" | awk -F'\t' '{ printf "%s%s (%s)", sep, $1, $2; sep = ", " }')"
			echo
		fi
		echo "## Stages"
		echo
		echo "| stage | result | seconds | note |"
		echo "|---|---|---|---|"
		if [ -f "$RESULTS/stages.txt" ]; then
			awk -F'\t' '{ gsub(/\|/, "\\|", $4); printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$RESULTS/stages.txt"
		fi
		echo
		echo "Each entry's output: l/<stage>.txt; the step logs: steps/."
		echo
		echo "## Masking"
		echo
		cat "$RESULTS/masking.txt" 2> /dev/null
	} > "$RESULTS/summary.md"
else
	{
		echo "# Run ${GITHUB_RUN_NUMBER:-local}${GITHUB_RUN_ATTEMPT:+ (attempt $GITHUB_RUN_ATTEMPT)}: $verdict"
		echo
		echo "| | |"
		echo "|---|---|"
		echo "| Trigger | ${GITHUB_EVENT_NAME:-local} on ${GITHUB_REF_NAME:-} |"
		echo "| Commit | ${GITHUB_SHA:-local} |"
		echo "| Options | S2=${S2:-} S3=${S3:-} S4=${S4:-} S5=${S5:-} S6=${S6:-} S7=${S7:-} S8=${S8:-} S9=${S9:-} S10=${S10:-} S11=${S11:-} S12=${S12:-} S13=${S13:-} S14=${S14:-} S15=${S15:-} S16=${S16:-} S17=${S17:-} S18=${S18:-} S19=${S19:-} S20=${S20:-} S21=${S21:-} S22=${S22:-} S23=${S23:-} S24=${S24:-} S25=${S25:-} S26=${S26:-} S27=${S27:-} S28=${S28:-} S29=${S29:-} S30=${S30:-} FORCE_BUILD=${FORCE_BUILD:-} KEY_PATCH=${KEY_PATCH:-} CERT_PROFILE=${CERT_PROFILE:-} ROUTE=${ROUTE:-} |"
		echo "| Xcode | $(metric_value xcode) |"
		echo "| Simulator | $(metric_value device), $(metric_value runtime) |"
		echo "| Runner | $(metric_value cpus) CPUs, $(metric_value memory_gb) GB RAM |"
		echo "| Upstream | ${UPSTREAM_REPO:-} @ ${UPSTREAM_SHA:-} (${UPSTREAM_VERSION:-}) |"
		echo "| Server | $(metric_value server_version) |"
		echo "| App | ${app_source:-not ready}; signing variant $(metric_value signing_variant) |"
		echo "| OPPF public key | $(metric_value oppf_public_key) |"
		echo "| Disk free (GB) | start $(metric_value disk_start_gb), before cleanup $(metric_value disk_before_cleanup_gb), after cleanup $(metric_value disk_after_cleanup_gb), after Rust $(metric_value disk_after_rust_gb), after build $(metric_value disk_after_build_gb), end $(metric_value disk_end_gb) |"
		echo "| Minutes (job, to this step) | $(metric_value minutes_total) |"
		echo "| Crash reports / TLS handshake errors | $(metric_value crash_reports) / $(metric_value tls_handshake_errors) |"
		echo
		if [ -n "$failed" ]; then
			echo "Required stages that did not pass: $(printf '%s\n' "$failed" | awk -F'\t' '{ printf "%s%s (%s)", sep, $1, $2; sep = ", " }')"
			echo
		fi
		echo "## Caches"
		echo
		echo "| cache | hit |"
		echo "|---|---|"
		for c in app:CACHE_APP libthreema:CACHE_LIBTHREEMA saltyrtc:CACHE_SALTYRTC rust-toolchains:CACHE_RUST \
			saltyrtc-target:CACHE_SALTY_TARGET libthreema-target:CACHE_LT_TARGET webrtc:CACHE_WEBRTC spm:CACHE_SPM; do
			var=${c#*:}
			hit=${!var:-}
			echo "| ${c%%:*} | ${hit:-not used} |"
		done
		echo
		echo "## Stages"
		echo
		echo "| stage | result | seconds | note |"
		echo "|---|---|---|---|"
		if [ -f "$RESULTS/stages.txt" ]; then
			awk -F'\t' '{ gsub(/\|/, "\\|", $4); printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$RESULTS/stages.txt"
		fi
		echo
		echo "## Server log: the lines that matter"
		echo
		echo '```'
		grep -E 'provisioning: |directory: (license checked|identity created|work info updated)|work: |chatserver: client connected|turn: |saltyrtc: client authenticated|SaltyRTC signalling|TLS handshake error|level=(WARN|ERROR)' \
			"$RESULTS/server/server.log" 2> /dev/null | sed 's/^time=[^ ]* //' | cut -c1-300 | head -n 80
		echo '```'
		if [ -s "$RESULTS/build/webrtc.txt" ]; then
			echo
			echo "## WebRTC"
			echo
			cat "$RESULTS/build/webrtc.txt"
		fi
		echo
		echo "## Masking"
		echo
		cat "$RESULTS/masking.txt" 2> /dev/null
	} > "$RESULTS/summary.md"
fi

{
	failed_names=$(printf '%s\n' "$failed" | awk -F'\t' 'NF { printf "%s%s", sep, $1; sep = ", " }')
	echo "| [$dir](results/$dir/summary.md) | $(date -u '+%Y-%m-%d %H:%M') | ${GITHUB_EVENT_NAME:-local} | $short_sha | $verdict | ${app_source:-} | ${failed_names:-—} |"
} > "$RESULTS/index-line.md"

mask_pass
mask2=$?
case "$mask1/$mask2" in
0/0) record masking PASS "$(grep '^masking:' "$RESULTS/masking.txt" 2> /dev/null | tail -n 1 | cut -c1-200)" ;;
[01]/[01]) record masking FAIL "a file still held a secret and was deleted (masking.txt)" ;;
*) record masking FAIL "mask-secrets.py did not finish (exit $mask1, $mask2), so nothing is uploaded" ;;
esac
if [ "$(stage_status masking)" != PASS ]; then
	sed -i.bak 's/: PASS$/: FAIL (masking)/' "$RESULTS/summary.md" 2> /dev/null && rm -f "$RESULTS/summary.md.bak"
fi
cat "$RESULTS/summary.md" 2> /dev/null | head -n 40

seal() {
	local out="${RUNNER_TEMP:?}/out" final=$verdict n
	[ "$(stage_status masking)" = PASS ] || final=FAIL
	find_openssl || return 1
	rm -rf "$out"
	mkdir -p "$out"
	(cd "$RUNNER_TEMP" && tar -czf r.tgz results && tar -czf f.tgz results-full) || return 1
	for n in r f; do
		"$OPENSSL" cms -encrypt -binary -aes256 -outform DER -in "$RUNNER_TEMP/$n.tgz" -out "$out/$n.bin" \
			-recip "$(ci_root)/ci/results.crt" -keyopt rsa_padding_mode:oaep || return 1
		rm -f "$RUNNER_TEMP/$n.tgz"
	done
	printf '%s\n' "$final" > "$out/v.txt"
}
case "$mask1/$mask2" in
[01]/[01])
	echo "both masking passes finished" > "$RESULTS/MASKED"
	if in_local; then
		record seal SKIP "local run: the results stay plain in the run directory"
		exit 0
	fi
	stage seal
	if seal; then
		if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "sealed=true" >> "$GITHUB_OUTPUT"; fi
	else
		record seal FAIL "openssl or tar failed; nothing uploaded"
		exit 1
	fi
	;;
*) echo "::error::masking did not finish; the results are not uploaded" ;;
esac
exit 0
