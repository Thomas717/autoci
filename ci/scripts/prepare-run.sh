#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
root=$(ci_root)
mode=${1:-m}
case $mode in
m | l | plan | alone) ;;
*)
	echo "usage: prepare-run.sh [l|plan]" >&2
	exit 2
	;;
esac
if [ "$mode" = plan ]; then
	job=m
	if bash "$here/prepare-run.sh" alone > /dev/null 2>&1; then job=l; fi
	printf 'job=%s\n' "$job" >> "${GITHUB_OUTPUT:?}"
	echo "job=$job"
	exit 0
fi
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"

S2=false
S3=false
S4=false
S5=false
S6=false
S7=false
S8=false
S9=false
S10=false
S11=false
S12=false
S13=false
S14=false
S15=false
S16=false
S17=false
S18=false
S19=false
S20=false
S21=false
S22=false
S23=false
S24=false
S25=false
S26=false
S27=false
S28=false
S29=false
S30=false
FORCE_BUILD=false
KEY_PATCH=bundle
CERT_PROFILE=selfsigned
ROUTE=link
L=false
options_from=defaults

set_option() {
	case "$1=$2" in
	S2=true | S2=false) S2=$2 ;;
	S3=true | S3=false) S3=$2 ;;
	S4=true | S4=false) S4=$2 ;;
	S5=true | S5=false) S5=$2 ;;
	S6=true | S6=false) S6=$2 ;;
	S7=true | S7=false) S7=$2 ;;
	S8=true | S8=false) S8=$2 ;;
	S9=true | S9=false) S9=$2 ;;
	S10=true | S10=false) S10=$2 ;;
	S11=true | S11=false) S11=$2 ;;
	S12=true | S12=false) S12=$2 ;;
	S13=true | S13=false) S13=$2 ;;
	S14=true | S14=false) S14=$2 ;;
	S15=true | S15=false) S15=$2 ;;
	S16=true | S16=false) S16=$2 ;;
	S17=true | S17=false) S17=$2 ;;
	S18=true | S18=false) S18=$2 ;;
	S19=true | S19=false) S19=$2 ;;
	S20=true | S20=false) S20=$2 ;;
	S21=true | S21=false) S21=$2 ;;
	S22=true | S22=false) S22=$2 ;;
	S23=true | S23=false) S23=$2 ;;
	S24=true | S24=false) S24=$2 ;;
	S25=true | S25=false) S25=$2 ;;
	S26=true | S26=false) S26=$2 ;;
	S27=true | S27=false) S27=$2 ;;
	S28=true | S28=false) S28=$2 ;;
	S29=true | S29=false) S29=$2 ;;
	S30=true | S30=false) S30=$2 ;;
	FORCE_BUILD=true | FORCE_BUILD=false) FORCE_BUILD=$2 ;;
	KEY_PATCH=bundle | KEY_PATCH=source) KEY_PATCH=$2 ;;
	CERT_PROFILE=selfsigned | CERT_PROFILE=ca-leaf) CERT_PROFILE=$2 ;;
	ROUTE=link | ROUTE=mdm) ROUTE=$2 ;;
	L=true | L=false) L=$2 ;;
	*) return 1 ;;
	esac
}

if [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
	options_from="dispatch inputs"
	for pair in "S2=${IN_S2:-}" "S3=${IN_S3:-}" \
		"S4=${IN_S4:-}" "S5=${IN_S5:-}" "S6=${IN_S6:-}" "S7=${IN_S7:-}" "S8=${IN_S8:-}" "S9=${IN_S9:-}" "S10=${IN_S10:-}" "S11=${IN_S11:-}" "S12=${IN_S12:-}" "S13=${IN_S13:-}" "S14=${IN_S14:-}" "S15=${IN_S15:-}" "S16=${IN_S16:-}" "S17=${IN_S17:-}" "S18=${IN_S18:-}" "S19=${IN_S19:-}" "S20=${IN_S20:-}" "FORCE_BUILD=${IN_FORCE_BUILD:-}" \
		"KEY_PATCH=${IN_KEY_PATCH:-}" "CERT_PROFILE=${IN_CERT_PROFILE:-}" "ROUTE=${IN_ROUTE:-}" "L=${IN_L:-}"; do
		key=${pair%%=*}
		value=${pair#*=}
		[ -n "$value" ] || continue
		if ! set_option "$key" "$value"; then
			echo "::error::dispatch input $key has a value this workflow does not accept"
			exit 1
		fi
	done
	more=${IN_MORE:-}
	more_re='^(2[1-9]|30)( (2[1-9]|30))*$'
	if [ -n "$more" ]; then
		if ! [[ $more =~ $more_re ]]; then
			echo "::error::dispatch input more takes stage numbers 21 to 30 separated by one space, as \"27 28 29 30\""
			exit 1
		fi
		seen=" "
		for n in $more; do
			case $seen in *" $n "*)
				echo "::error::dispatch input more names stage $n twice"
				exit 1
				;;
			esac
			seen="$seen$n "
		done
		for n in $more; do
			set_option "S$n" true || exit 1
		done
	fi
elif [ -f "$root/ci/run-options.env" ]; then
	options_from="ci/run-options.env"
	option_re='^(S2|S3|S4|S5|S6|S7|S8|S9|S10|S11|S12|S13|S14|S15|S16|S17|S18|S19|S20|S21|S22|S23|S24|S25|S26|S27|S28|S29|S30|FORCE_BUILD|KEY_PATCH|CERT_PROFILE|ROUTE|L)=[a-z-]+$'
	n=0
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line%$'\r'}
		case $line in '' | '#'*) continue ;; esac
		if ! [[ $line =~ $option_re ]] || ! set_option "${line%%=*}" "${line#*=}"; then
			echo "::error file=ci/run-options.env,line=$n::not an accepted option line (see ci/run-options.env.example)"
			exit 1
		fi
	done < "$root/ci/run-options.env"
fi

alone=false
if [ "$L" = true ] && [ "$FORCE_BUILD" = false ] && [ "$KEY_PATCH" = bundle ] &&
	[ "$CERT_PROFILE" = selfsigned ] && [ "$ROUTE" = link ]; then
	alone=true
	for n in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
		v=S$n
		[ "${!v}" = false ] || alone=false
	done
fi
case $mode in
alone)
	[ "$alone" = true ]
	exit $?
	;;
l)
	if [ "$alone" != true ]; then
		echo "::error::the Linux job runs only with L=true and every other option at its default"
		exit 1
	fi
	;;
m)
	if [ "$L" = true ]; then
		echo "::error::L=true is a run of the Linux job alone, with every other option at its default (and in Actions only)"
		exit 1
	fi
	;;
esac

if [ "$KEY_PATCH" = source ]; then FORCE_BUILD=true; fi
for n in 21 22 23 24 25 26 27 28 29 30; do
	v=S$n
	if [ "${!v}" = true ] && [ ! -f "$root/ci/scripts/sim-m$n.sh" ]; then
		echo "::error::stage $n is not in this commit yet (no ci/scripts/sim-m$n.sh)"
		exit 1
	fi
done
if [ "$S23" = true ]; then S11=true; fi
if [ "$S24" = true ]; then S7=true; fi
if [ "$S6" = true ]; then S5=true; fi
if [ "$S13" = true ]; then S11=true; fi
if [ "$S10" = true ] || [ "$S12" = true ]; then S9=true; fi
if [ "$S5" = true ] || [ "$S4" = true ] || [ "$S7" = true ] || [ "$S8" = true ] ||
	[ "$S9" = true ] || [ "$S11" = true ] || [ "$S14" = true ] || [ "$S15" = true ] ||
	[ "$S16" = true ] || [ "$S17" = true ] || [ "$S18" = true ] ||
	[ "$S19" = true ] || [ "$S20" = true ] || [ "$S21" = true ] || [ "$S22" = true ] ||
	[ "$S25" = true ] || [ "$S26" = true ] || [ "$S27" = true ] || [ "$S28" = true ] ||
	[ "$S29" = true ] || [ "$S30" = true ]; then S3=true; fi
if [ "$S3" = true ]; then S2=true; fi

load_pins() {
	local file=$1 line n=0 pin_re='^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/+=-]*$'
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line%$'\r'}
		case $line in '' | '#'*) continue ;; esac
		if ! [[ $line =~ $pin_re ]]; then
			echo "::error file=${file#"$root"/},line=$n::not a KEY=value line with a plain value"
			exit 1
		fi
		printf '%s\n' "$line" >> "$GITHUB_ENV"
		export "${line?}"
	done < "$file"
}
load_pins "$root/ci/build/pins.env"
load_pins "$root/ci/rtc.env"
load_pins "$root/ci/run.env"
if [ "$S26" = true ]; then
	host_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
	if ! [[ ${SERVER_HOST_S26:-} =~ $host_re ]]; then
		echo "::error file=ci/run.env::SERVER_HOST_S26 is not a lower-case DNS name with a dot"
		exit 1
	fi
	gh_env SERVER_HOST "$SERVER_HOST_S26"
	gh_env SERVER_PUBLIC_URL "https://$SERVER_HOST_S26:${SERVER_HTTP_PORT:?}"
fi

gh_env S2 "$S2"
gh_env S3 "$S3"
gh_env S4 "$S4"
gh_env S5 "$S5"
gh_env S6 "$S6"
gh_env S7 "$S7"
gh_env S8 "$S8"
gh_env S9 "$S9"
gh_env S10 "$S10"
gh_env S11 "$S11"
gh_env S12 "$S12"
gh_env S13 "$S13"
gh_env S14 "$S14"
gh_env S15 "$S15"
gh_env S16 "$S16"
gh_env S17 "$S17"
gh_env S18 "$S18"
gh_env S19 "$S19"
gh_env S20 "$S20"
gh_env S21 "$S21"
gh_env S22 "$S22"
gh_env S23 "$S23"
gh_env S24 "$S24"
gh_env S25 "$S25"
gh_env S26 "$S26"
gh_env S27 "$S27"
gh_env S28 "$S28"
gh_env S29 "$S29"
gh_env S30 "$S30"
gh_env FORCE_BUILD "$FORCE_BUILD"
gh_env KEY_PATCH "$KEY_PATCH"
gh_env CERT_PROFILE "$CERT_PROFILE"
gh_env ROUTE "$ROUTE"
gh_env L "$L"
if [ "$mode" = m ]; then gh_env DEVELOPER_DIR "$XCODE_APP/Contents/Developer"; fi

umask 077
gh_env RESULTS "$RUNNER_TEMP/results"
gh_env RESULTS_FULL "$RUNNER_TEMP/results-full"
gh_env SRV "$RUNNER_TEMP/server"
gh_env SEC "$RUNNER_TEMP/secrets"
gh_env SIM "$RUNNER_TEMP/sim"
mkdir -p "$RESULTS"/server "$RESULTS"/build "$RESULTS"/sim "$RESULTS"/screenshots \
	"$RESULTS_FULL"/shots "$RESULTS_FULL"/sim "$RESULTS_FULL"/server "$SRV" "$SIM"
mkdir -m 700 -p "$SEC"
: > "$SEC/mask.list"
date +%s > "$RUNNER_TEMP/t0"
gh_env RUN_T0 "$(cat "$RUNNER_TEMP/t0")"

{
	echo "run:      ${GITHUB_RUN_NUMBER:-local} (attempt ${GITHUB_RUN_ATTEMPT:-1})"
	echo "event:    ${GITHUB_EVENT_NAME:-local}"
	echo "ref:      ${GITHUB_REF:-}"
	echo "commit:   ${GITHUB_SHA:-}"
	echo "started:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "options:  S2=$S2 S3=$S3 S4=$S4 S5=$S5 S6=$S6 S7=$S7 S8=$S8 S9=$S9 S10=$S10 S11=$S11 S12=$S12 S13=$S13 S14=$S14 S15=$S15 S16=$S16 S17=$S17 S18=$S18 S19=$S19 S20=$S20" \
		"S21=$S21 S22=$S22 S23=$S23 S24=$S24 S25=$S25 S26=$S26 S27=$S27 S28=$S28 S29=$S29 S30=$S30" \
		"FORCE_BUILD=$FORCE_BUILD" \
		"KEY_PATCH=$KEY_PATCH" \
		"CERT_PROFILE=$CERT_PROFILE ROUTE=$ROUTE L=$L (from $options_from)"
} > "$RESULTS/run.txt"
cat "$RESULTS/run.txt"
record options PASS "from $options_from"
