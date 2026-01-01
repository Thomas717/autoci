#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}" \
	"${SERVER_PUBLIC_URL:?}" "${SEAT_USERNAME:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m24"
work="$RUNNER_TEMP/m2-driver"
dir_seat=${DIR_SEAT_USERNAME:-ci-dir}
COCKPIT_ANSWER="$out/cockpit-answer.json"
mkdir -p "$out/shots" "$RESULTS/m24"
cleaned=false
ops_id=
me_id=
empty_id=

cleanup() {
	local s1 s2 id label sd="" pair
	s1=$(cockpit PATCH "/api/users/$SEAT_USERNAME" \
		'{"profile":{"firstName":"CI","lastName":"iOS","csi":"","jobTitle":"","department":""},"categories":[]}')
	s2=$(cockpit PATCH "/api/users/$dir_seat" '{"categories":[]}')
	for pair in "ci-ops:CI Ops" "ci-me:CI Me" "ci-empty:CI Empty"; do
		id=${pair%%:*}
		label=${pair#*:}
		sd="$sd $(cockpit DELETE "/api/directory/categories/$id" "{\"confirm\":\"$label\"}")"
	done
	printf 'seat profile HTTP %s, %s categories HTTP %s, categories %s deleted HTTP%s' "$s1" "$dir_seat" "$s2" \
		"ci-ops ci-me ci-empty" "$sd"
}

seat_now() {
	local status
	status=$(cockpit GET "/api/users/$SEAT_USERNAME")
	[ "${status#2}" != "$status" ] || return 0
	answer '"|".join((a["user"]["profile"].get("effective") or {}).get(k) or "" for k in ("firstName", "lastName", "csi", "jobTitle", "department")) + "|" + ",".join(c.get("id", "") for c in (a["user"].get("effectiveCategories") or []))'
}

finish() {
	if [ "$cleaned" != true ] && [ -s "$SEC/cockpit.csrf" ]; then
		cleanup > /dev/null 2>&1 || true
	fi
	cockpit_sign_out
	(since "${m24_start:-0}" 'work: ' | grep -E 'work data fetched|directory searched|refused' | grep -F "seat=$SEAT_USERNAME" |
		sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-300 > "$RESULTS/m24/work-lines.txt") 2> /dev/null || true
	(since "${m24_start:-0}" 'directory: work info updated' | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200 \
		>> "$RESULTS/m24/work-lines.txt") 2> /dev/null || true
}
trap finish EXIT

fail() {
	record "$1" FAIL "$2"
	exit 1
}

offset() { wc -c < "$SRV/server.log" | tr -d ' '; }
since() {
	(tail -c +"$(($1 + 1))" "$SRV/server.log" 2> /dev/null || true) | grep -F -- "$2" | grep -F -- "${3:-$2}" || true
}
wait_line() {
	local off=$1 end=$(($(date +%s) + $2)) lines filter
	shift 2
	while :; do
		lines=$(tail -c +"$((off + 1))" "$SRV/server.log" 2> /dev/null || true)
		for filter in "$@"; do
			case $filter in
			!*) lines=$(printf '%s\n' "$lines" | grep -vF -- "${filter#!}" || true) ;;
			*) lines=$(printf '%s\n' "$lines" | grep -F -- "$filter" || true) ;;
			esac
		done
		lines=$(printf '%s\n' "$lines" | sed '/^$/d' | tail -n 1)
		if [ -n "$lines" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}
m24_start=$(offset)

run_test() {
	local status=0 name=$1${2:+-$2}
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/WorkProfileTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m24-$name.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$name.log" 2>&1 || status=$?
	tail -n 150 "$out/$name.log" > "$RESULTS/m24/$name.tail.txt"
	export_attachments "$work/m24-$name.xcresult" "$out/shots" "$RESULTS/m24" m24- > /dev/null 2>&1 || true
	return "$status"
}

synced_note() {
	local note
	note=$(tr -d '\r' 2> /dev/null < "$RESULTS/m24/$1.txt" | head -n 1 | cut -c1-80)
	printf '%s' "${note:-no note on the toast}"
}

fields() {
	printf '%s' "$1" | awk -F'|' -v OFS=', ' '{ $1 = $1; for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print }'
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 8
}

answer() {
	python3 -I -c 'import json, sys
try:
    a = json.load(open(sys.argv[1]))
    v = eval(sys.argv[2], {"a": a})
except Exception:
    v = ""
print("" if v is None else v)' "$COCKPIT_ANSWER" "$1" 2> /dev/null | tr -d '\r'
}

category() {
	local status
	status=$(cockpit POST /api/directory/categories "{\"id\":\"$2\",\"label\":\"$1\"}")
	if [ "${status#2}" = "$status" ]; then
		cp "$COCKPIT_ANSWER" "$RESULTS/m24/category-$2-answer.json" 2> /dev/null
		return 1
	fi
	answer 'a["category"]["id"]'
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m24-cockpit "no identity of the app in the server log"

relaunch

stage m24-cockpit
cockpit_sign_in || fail m24-cockpit "the cockpit's sign-in answered $COCKPIT_STATUS (server-prepare.sh makes a password for S24)"
record m24-cockpit PASS "signed in as ci-admin"
before=$(seat_now)
cp "$COCKPIT_ANSWER" "$out/seat-before.json" 2> /dev/null

stage m24-categories
ops_id=$(category "CI Ops" ci-ops) || fail m24-categories "the cockpit refused the category CI Ops (m24/category-ci-ops-answer.json)"
me_id=$(category "CI Me" ci-me) || fail m24-categories "the cockpit refused the category CI Me (m24/category-ci-me-answer.json)"
empty_id=$(category "CI Empty" ci-empty) || fail m24-categories "the cockpit refused the category CI Empty (m24/category-ci-empty-answer.json)"
[ -n "$ops_id" ] && [ -n "$me_id" ] && [ -n "$empty_id" ] || fail m24-categories "a category answer named no ID"
record m24-categories PASS "categories $ops_id (CI Ops), $me_id (CI Me), $empty_id (CI Empty)"

stage m24-assign
status=$(cockpit PATCH "/api/users/$dir_seat" "{\"categories\":[\"$ops_id\"]}")
got=$(answer '",".join(a["user"]["categories"])')
if [ "${status#2}" = "$status" ] || [ "$got" != "$ops_id" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m24/assign-answer.json" 2> /dev/null
	fail m24-assign "the cockpit answered $status, categories \"$got\" (m24/assign-answer.json)"
fi
record m24-assign PASS "$dir_seat in $ops_id (HTTP $status)"

stage m24-set
o=$(offset)
status=$(cockpit PATCH "/api/users/$SEAT_USERNAME" \
	"{\"profile\":{\"firstName\":\"Ada\",\"lastName\":\"CI\",\"csi\":\"CI-24\",\"jobTitle\":\"Tester\",\"department\":\"QA\"},\"categories\":[\"$me_id\"]}")
changed=$(answer '" ".join(a["changed"])')
if [ "${status#2}" = "$status" ]; then
	cp "$COCKPIT_ANSWER" "$RESULTS/m24/set-answer.json" 2> /dev/null
	fail m24-set "the cockpit answered $status (m24/set-answer.json)"
fi
record m24-set PASS "$SEAT_USERNAME: Ada CI, CSI CI-24, Tester, QA, category $me_id (HTTP $status; changed: $changed)"

stage m24-test-sync
if run_test testSyncProfile; then
	record m24-test-sync PASS "the Contacts list pulled, which forces a Work Sync ($(synced_note m24-02-synced))"
else
	record m24-test-sync FAIL "xcodebuild test failed (m24/testSyncProfile.tail.txt)"
fi
stage m24-sync
if line=$(wait_line "$o" 60 'work: work data fetched' "seat=$SEAT_USERNAME" 'th_firstname' 'th_lastname' 'th_csi' \
	'th_job_title' 'th_department' 'th_category' 'categories=3 '); then
	record m24-sync PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-300)"
else
	record m24-sync FAIL "no Work Sync of $SEAT_USERNAME naming the six work-profile keys and 3 categories since the change (m24/work-lines.txt)"
fi

o_relaunch=$(offset)
relaunch
stage m24-relaunch
if line=$(wait_line "$o" 90 'directory: work info updated' "identity=$app_id" "seat=$SEAT_USERNAME"); then
	when="after the relaunch"
	[ -n "$(since "$o_relaunch" 'directory: work info updated' "identity=$app_id")" ] || when="before the relaunch, after the Work Sync"
	record m24-relaunch PASS "$when: $(printf '%s' "$line" | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200)"
else
	record m24-relaunch FAIL "the app sent no work info within 90 s of the change (m24/work-lines.txt)"
fi

stage m24-reported
want="Ada|CI|CI-24|Tester|QA"
got=
for _ in $(seq 1 10); do
	status=$(cockpit GET "/api/users/$SEAT_USERNAME")
	got=$(answer '"|".join(a["user"]["profile"]["reported"][k] for k in ("firstName", "lastName", "csi", "jobTitle", "department"))')
	[ "$got" = "$want" ] && break
	sleep 3
done
cp "$COCKPIT_ANSWER" "$out/seat-answer.json" 2> /dev/null
python3 -I - "$COCKPIT_ANSWER" "$RESULTS/m24/seat-profile.json" <<'PY' 2> /dev/null || true
import json, sys
u = json.load(open(sys.argv[1]))["user"]
keep = {k: u.get(k) for k in ("username", "categories", "categoryLabels", "profile", "effectiveCategories",
                             "reportedCategories", "assignedCategories")}
json.dump(keep, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
if [ "$got" = "$want" ]; then
	record m24-reported PASS "the seat's reported profile: ${got//|/, }"
else
	record m24-reported FAIL "the seat's reported profile is \"${got//|/, }\", not \"${want//|/, }\" (m24/seat-profile.json)"
fi
stage m24-categorised
reported=$(answer '",".join(str(c.get("categoryId")) + ":" + c.get("label", "") for c in a["user"]["reportedCategories"])')
effective=$(answer '",".join(c["id"] for c in a["user"]["effectiveCategories"])')
if [ "$reported" = "$me_id:CI Me" ] && [ "$effective" = "$me_id" ]; then
	record m24-categorised PASS "reported \"CI Me\", which is category $me_id, the seat's effective category"
else
	record m24-categorised FAIL "reported categories \"$reported\", effective \"$effective\", not $me_id (m24/seat-profile.json)"
fi

stage m24-test-filter
o=$(offset)
if TEST_RUNNER_M24_HIT="CI Ops" TEST_RUNNER_M24_EMPTY="CI Empty" TEST_RUNNER_M24_NAME="CI Colleague" run_test testCategoryFilter; then
	record m24-test-filter PASS "\"CI Ops\" finds CI Colleague in the directory, \"CI Empty\" nobody"
else
	record m24-test-filter FAIL "xcodebuild test failed (m24/testCategoryFilter.tail.txt)"
fi
stage m24-directory
searches=$(since "$o" 'work: directory searched' "seat=$SEAT_USERNAME" | grep -F 'categories=1 ')
hit=$(printf '%s\n' "$searches" | grep -nF 'results=1 ' | head -n 1 | cut -d: -f1)
none=$(printf '%s\n' "$searches" | grep -nF 'results=0 ' | tail -n 1 | cut -d: -f1)
if [ -n "$hit" ] && [ -n "$none" ] && [ "$none" -gt "$hit" ]; then
	record m24-directory PASS "by one category: results=1, then results=0 ($(printf '%s\n' "$searches" | sed '/^$/d' | wc -l | tr -d ' ') search(es))"
else
	record m24-directory FAIL "no search by one category with one result followed by one with none since the test started (m24/work-lines.txt)"
fi
refusals=$(since "$o" 'work: refused a directory search')
if [ -n "$refusals" ]; then
	record m24-directory-refused INFO "$(printf '%s\n' "$refusals" | tail -n 1 | sed 's/^time=[^ ]* //; s/ remote=.*//' | cut -c1-200)"
fi
shot m24-09-final

o_clean=$(offset)
note=$(cleanup)
cleaned=true
if TEST_RUNNER_M24_SHOTS=m24-1 run_test testSyncProfile restore; then
	pulled="pulled again ($(synced_note m24-12-synced))"
else
	pulled="the second pull's test failed (m24/testSyncProfile-restore.tail.txt)"
fi
if ! line=$(wait_line "$o_clean" 60 'directory: work info updated' "identity=$app_id"); then
	relaunch
	line=$(wait_line "$o_clean" 60 'directory: work info updated' "identity=$app_id") || line=
fi
after=$(seat_now)
cp "$COCKPIT_ANSWER" "$out/seat-after.json" 2> /dev/null
reported_again=$([ -n "$line" ] && echo "the app reported its work info again" || echo "no new work info from the app")
if [ -n "$before" ] && [ "$after" = "$before" ]; then
	restored="the effective profile and categories as before the milestone ($(fields "$after"))"
else
	restored="the effective profile and categories differ from before the milestone: $(fields "$after") (before: $(fields "$before"); empty: no answer; results-full/m24/seat-before.json, seat-after.json)"
fi
record m24-cleanup INFO "$note; $pulled, $reported_again; $restored"

stage m24-cleared
cleared=
for _ in $(seq 1 10); do
	status=$(cockpit GET "/api/users/$SEAT_USERNAME")
	cleared=$(answer '(lambda p: "|".join([p["reported"].get(k) or "" for k in ("csi", "jobTitle", "department", "category")] + [p["effective"].get("csi") or ""]))(a["user"]["profile"])')
	[ "$cleared" = "||||" ] && break
	sleep 3
done
python3 -I - "$COCKPIT_ANSWER" "$RESULTS/m24/seat-cleared.json" <<'PY' 2> /dev/null || true
import json, sys
u = json.load(open(sys.argv[1]))["user"]
keep = {k: u.get(k) for k in ("username", "profile", "effectiveCategories", "reportedCategories")}
json.dump(keep, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
if [ -z "$line" ]; then
	record m24-cleared FAIL "the app sent no work info after the cleanup (m24/work-lines.txt)"
elif [ "$cleared" = "||||" ]; then
	record m24-cleared PASS "the app's report cleared the reported CSI, job title, department and category, and the effective CSI"
else
	record m24-cleared FAIL "reported CSI, job title, department, category and effective CSI are \"$(fields "$cleared")\", not all empty (a server without LC-20 keeps the CSI and the category the app leaves out; m24/seat-cleared.json)"
fi

failed=$(failing_stages "$M24_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 24: every stage passed"
