#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}" "${SEC:?}" "${APP_BUNDLE_ID:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m27"
work="$RUNNER_TEMP/m2-driver"
profile="$SEC/cli.json"
cli=$(cat "$SRV/cli.path")
pictures="$out/pictures"
mkdir -p "$out/shots" "$RESULTS/m27" "$pictures"
chmod 700 "$pictures"
export THREEMA_CA_FILE="$SRV/tls/ca.crt"

listen_pid=
listens=0
stop_bg() {
	local pid=$1
	[ -n "$pid" ] || return 0
	kill -INT "$pid" 2> /dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$pid" 2> /dev/null || break
		sleep 1
	done
	kill -KILL "$pid" 2> /dev/null
	wait "$pid" 2> /dev/null
	sleep 1
}
finish() {
	stop_bg "$listen_pid"
	listen_pid=
	for f in "$out"/listen-*.txt "$out"/send-*.txt "$out"/addmedia.txt; do
		[ -f "$f" ] && cp "$f" "$RESULTS/m27/"
	done
	(since "${m27_start:-0}" 'component=blob' | sed 's/^time=[^ ]* //' | cut -c1-300 > "$RESULTS/m27/blob-lines.txt") 2> /dev/null || true
	(since "${m27_start:-0}" 'chatserver: ' | grep -E 'message (accepted|delivered|acknowledged by the receiver)' |
		sed 's/^time=[^ ]* //' | cut -c1-260 > "$RESULTS/m27/chat-lines.txt") 2> /dev/null || true
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
wait_since() {
	local off=$1 end=$(($(date +%s) + $2)) count=$3 lines
	shift 3
	while :; do
		lines=$(since "$off" "$@")
		if [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ge "$count" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && { [ -n "$lines" ] && printf '%s\n' "$lines"; return 1; }
		sleep 2
	done
}
m27_start=$(offset)

wait_for_text() {
	local end=$(($(date +%s) + $3))
	while :; do
		grep -qF -- "$2" "$1" 2> /dev/null && return 0
		[ "$(date +%s)" -ge "$end" ] && return 1
		sleep 2
	done
}

cli_lines() { cat "$out"/listen-*.txt "$out"/send-*.txt 2> /dev/null || true; }
app_lines() { cli_lines | grep -F "] $app_id" | grep -F -- "$1" || true; }
wait_app_lines() {
	local end=$(($(date +%s) + $3)) lines
	while :; do
		lines=$(app_lines "$1")
		if [ -n "$lines" ] && [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -ge "$2" ]; then
			printf '%s\n' "$lines"
			return 0
		fi
		[ "$(date +%s)" -ge "$end" ] && { [ -n "$lines" ] && printf '%s\n' "$lines"; return 1; }
		sleep 2
	done
}
ids_of() { sed -n 's/.* id=\([0-9a-f]\{16\}\)$/\1/p'; }
sizes_of() { sed -n 's/.*profile picture set, a \([0-9]*\)-byte blob.*/\1/p'; }
refs_of() { sed -n 's/.* blob_ref=\([^ ]*\).*/\1/p'; }
short() { printf '%s' "$1" | sed 's/^time=[^ ]* //' | cut -c1-200; }

run_test() {
	local status=0
	rm -rf "$work/m27-$1.xcresult"
	xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
		-only-testing:"OnboardingDriverUITests/ProfilePictureTests/$1" \
		-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
		-resultBundlePath "$work/m27-$1.xcresult" -collect-test-diagnostics never \
		-test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
		CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
		> "$out/$1.log" 2>&1 || status=$?
	tail -n 150 "$out/$1.log" > "$RESULTS/m27/$1.tail.txt"
	export_attachments "$work/m27-$1.xcresult" "$out/shots" "$RESULTS/m27" m27- > /dev/null 2>&1 || true
	[ "$status" = 0 ] || relaunch
	return "$status"
}

listen_start() {
	listens=$((listens + 1))
	"$cli" listen -identity "$profile" -save-pictures "$pictures" > "$out/listen-$listens.txt" 2>&1 3>&- &
	listen_pid=$!
	wait_for_text "$out/listen-$listens.txt" "listening as $cli_id" 60
}
listen_stop() {
	stop_bg "$listen_pid"
	listen_pid=
}

cli_send() {
	local name=$1
	shift
	SENT=
	"$cli" send -identity "$profile" -to "$app_id" -save-pictures "$pictures" "$@" > "$out/send-$name.txt" 2>&1 || return 1
	SENT=$(sed -n "s/^sent \([0-9a-f]\{16\}\) to $app_id: .*/\1/p" "$out/send-$name.txt" | head -n 1)
	[ -n "$SENT" ]
}

relaunch() {
	xcrun simctl launch --terminate-running-process "$udid" "$APP_BUNDLE_ID" -AppleLanguages "(en)" -AppleLocale en_US \
		> /dev/null 2>&1 || true
	sleep 5
}

app_id=$(wait_for_log 'directory: identity created' 5 | sed -n 's/.* identity=\([0-9A-Z]\{8\}\).*/\1/p')
cli_id=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["identity"])' "$profile" | tr -d '\r')
[[ $app_id =~ ^[0-9A-Z]{8}$ ]] || fail m27-binaries "no identity of the app in the server log"
nonce=$(test_nonce)
after_set="M27 after picture $nonce"
control="M27 control $nonce"
after_request="M27 after request $nonce"
after_delete="M27 after delete $nonce"
cli_sent=""

stage m27-binaries
gap=$(cli_flags_gap send -- -profile-picture -delete-profile-picture -request-profile-picture -save-pictures)
[ -n "$gap" ] || gap=$(cli_flags_gap listen -- -save-pictures)
[ -z "$gap" ] || fail m27-binaries "$gap: the binaries predate the CLI of the server repository's 5498363; rebuild server/ (tools/update-server-binary.sh; docs/HOW-IT-WORKS.md, milestones 27 to 30)"
record m27-binaries PASS "threema-cli sends, requests and deletes profile pictures, and listen saves them"

stage m27-photos
app_jpg="$RUNNER_TEMP/m27-app.jpg"
cli_jpg="$RUNNER_TEMP/m27-cli.jpg"
make_solid_jpeg "$app_jpg" 255 255 0 || fail m27-photos "could not make the yellow JPEG (python3, sips)"
make_solid_jpeg "$cli_jpg" 255 0 255 || fail m27-photos "could not make the CLI's magenta JPEG (python3, sips)"
xcrun simctl addmedia "$udid" "$app_jpg" > "$out/addmedia.txt" 2>&1 || fail m27-photos "simctl addmedia failed (m27/addmedia.txt)"
if ! xcrun simctl privacy "$udid" grant photos "$APP_BUNDLE_ID" > /dev/null 2>&1; then
	echo "::warning::simctl privacy grant photos failed; the test allows the prompt instead"
fi
relaunch
record m27-photos PASS "a yellow JPEG ($(wc -c < "$app_jpg" | tr -d ' ') bytes) in the library, a magenta one ($(wc -c < "$cli_jpg" | tr -d ' ') bytes) for the CLI; the app launched again"

stage m27-listen
if listen_start; then
	record m27-listen PASS "the CLI peer $cli_id listens and saves profile pictures"
else
	tail -n 10 "$out/listen-$listens.txt"
	fail m27-listen "listen did not start (m27/listen-$listens.txt)"
fi

stage m27-test-set
o_set=$(offset)
if run_test testSetOwnPicture; then
	record m27-test-set PASS "Profile > Edit > Edit picture > the newest photo > Choose > Done"
else
	record m27-test-set FAIL "xcodebuild test failed (m27/testSetOwnPicture.tail.txt)"
fi
quiescence_note m27
stage m27-test-write
if TEST_RUNNER_M27_TEXT="$after_set" TEST_RUNNER_M27_TAG=set run_test testWriteToCLI; then
	record m27-test-write PASS "\"$after_set\" to the CLI"
else
	record m27-test-write FAIL "xcodebuild test failed (m27/testWriteToCLI.tail.txt)"
fi
stage m27-app-upload
app_ref=
app_size=
if uploads=$(wait_since "$o_set" 60 1 'blob: blob uploaded' "owner=$app_id"); then
	first=$(printf '%s\n' "$uploads" | head -n 1)
	app_ref=$(printf '%s' "$first" | refs_of)
	app_size=$(printf '%s' "$first" | sed -n 's/.* size=\([0-9]*\).*/\1/p')
	persist=$(printf '%s' "$first" | sed -n 's/.* persist=\([a-z]*\).*/\1/p')
	mount=$(printf '%s' "$first" | sed -n 's/.* mount=\([a-z]*\).*/\1/p')
	if [ -n "$app_ref" ] && [ -n "$app_size" ] && [ "$mount" = blob ]; then
		record m27-app-upload PASS "$(short "$first")"
	else
		record m27-app-upload FAIL "an upload without blob_ref, size or mount=blob: $(short "$first")"
	fi
	record m27-persist INFO "persist=${persist:-?}: iOS asks for persist through a {persistBlob} placeholder in the upload URL, which this provisioning file does not have"
else
	record m27-app-upload FAIL "no upload with owner=$app_id within 60 s of the picture's save (m27/blob-lines.txt)"
fi
stage m27-cli-set
set_id=
if line=$(wait_app_lines ': profile picture set, a ' 1 60); then
	line=$(printf '%s\n' "$line" | head -n 1)
	set_id=$(printf '%s' "$line" | ids_of)
	size=$(printf '%s' "$line" | sizes_of)
	if [ -n "$app_size" ] && [ "$size" = "$app_size" ]; then
		record m27-cli-set PASS "$(printf '%s' "$line" | cut -c1-200); the size of the upload"
	else
		record m27-cli-set FAIL "the 0x18 names ${size:-no size}, the upload ${app_size:-none}: $(printf '%s' "$line" | cut -c1-160)"
	fi
else
	record m27-cli-set FAIL "the CLI printed no \"profile picture set\" from the app within 60 s (m27/listen-1.txt)"
fi
stage m27-cli-saved
saved=
end=$(($(date +%s) + 30))
while [ -z "$saved" ] && [ "$(date +%s)" -lt "$end" ]; do
	saved=$(cli_lines | grep -F 'profile picture saved: ' | grep -F -- "-$app_id.jpg" | head -n 1)
	[ -n "$saved" ] || sleep 2
done
centre=$(printf '%s' "$saved" | sed -n 's/.* centre #\([0-9a-f]\{6\}\).*/\1/p')
if [ -n "$centre" ] && colour_near "$centre" 255 255 0; then
	record m27-cli-saved PASS "$(printf '%s' "$saved" | sed 's|: .*[/\\]|: |' | cut -c1-200): yellow"
elif [ -n "$saved" ]; then
	record m27-cli-saved FAIL "the saved picture's centre is #${centre:-?}, not yellow: the test picked another photo? ($(printf '%s' "$saved" | sed 's|: .*[/\\]|: |' | cut -c1-160))"
else
	cli_lines | grep -F 'threema-cli: profile picture' | head -n 3
	record m27-cli-saved FAIL "the CLI saved no picture of the app's (m27/listen-1.txt)"
fi
stage m27-cli-fetch
served=0
[ -n "$app_ref" ] && served=$(wait_since "$o_set" 30 1 'blob: blob download' "blob_ref=$app_ref" | grep -c 'outcome=served')
if [ "$served" -ge 1 ]; then
	record m27-cli-fetch PASS "the CLI's download of $app_ref served"
else
	record m27-cli-fetch FAIL "no served download of the app's blob ${app_ref:-?} (m27/blob-lines.txt)"
fi

stage m27-test-now
sets_before=$(app_lines ': profile picture set, a ' | grep -c .)
o_now=$(offset)
if TEST_RUNNER_M27_CLI_ID="$cli_id" run_test testSendPictureNow; then
	record m27-test-now PASS "the CLI's details > Send Profile Picture Now"
else
	record m27-test-now FAIL "xcodebuild test failed (m27/testSendPictureNow.tail.txt)"
fi
stage m27-now
sets=$(wait_app_lines ': profile picture set, a ' $((sets_before + 1)) 60)
n_sets=$(printf '%s\n' "$sets" | sed '/^$/d' | wc -l | tr -d ' ')
other=$(printf '%s\n' "$sets" | sizes_of | grep -vx "${app_size:-none}" | head -n 1)
served=0
[ -n "$app_ref" ] && served=$(wait_since "$o_now" 30 1 'blob: blob download' "blob_ref=$app_ref" | grep -c 'outcome=served')
if [ "$n_sets" -gt "$sets_before" ] && [ -z "$other" ] && [ "$served" -ge 1 ]; then
	record m27-now PASS "$((n_sets - sets_before)) more profile picture(s) set from the app, each of $app_size bytes, and $served more served download(s) of $app_ref"
else
	record m27-now FAIL "$((n_sets - sets_before)) more profile picture(s) set from the app${other:+, one of $other bytes}, $served more served download(s) of ${app_ref:-?} (want 1 of $app_size bytes, 1 download)"
fi
stage m27-reused
n_up=$(since "$o_set" 'blob: blob uploaded' "owner=$app_id" | grep -c .)
if [ "$n_up" = 1 ]; then
	record m27-reused PASS "one upload by the app for both sends: the blob reused"
else
	record m27-reused FAIL "$n_up uploads by the app since the picture's save, want 1 (m27/blob-lines.txt)"
fi

listen_stop
stage m27-cli-send
o_cli=$(offset)
if cli_send picture -profile-picture "$cli_jpg"; then
	cli_sent="$cli_sent $SENT"
	record m27-cli-send PASS "$(grep -F "sent $SENT" "$out/send-picture.txt" | cut -c1-160); $(grep -F 'profile picture m27-cli.jpg:' "$out/send-picture.txt" | cut -c1-80)"
else
	tail -n 5 "$out/send-picture.txt"
	record m27-cli-send FAIL "the CLI's send -profile-picture failed (m27/send-picture.txt)"
fi
listen_start || echo "::warning::listen did not say it listens"
stage m27-cli-upload
cli_ref=
if line=$(wait_since "$o_cli" 20 1 'blob: blob uploaded' "owner=$cli_id"); then
	cli_ref=$(printf '%s\n' "$line" | head -n 1 | refs_of)
	record m27-cli-upload PASS "$(short "$(printf '%s\n' "$line" | head -n 1)")"
else
	record m27-cli-upload FAIL "no upload with owner=$cli_id since the CLI's send"
fi
stage m27-app-fetch
if [ -n "$cli_ref" ] && line=$(wait_since "$o_cli" 60 1 'blob: blob download' "blob_ref=$cli_ref") &&
	[ -n "$(printf '%s\n' "$line" | grep -F 'outcome=served')" ]; then
	record m27-app-fetch PASS "the app's download of $cli_ref: $(short "$(printf '%s\n' "$line" | grep -F 'outcome=served' | head -n 1)")"
else
	record m27-app-fetch FAIL "no served download of the CLI's blob ${cli_ref:-?} within 60 s (m27/blob-lines.txt)"
fi
stage m27-test-shown
if TEST_RUNNER_M27_CLI_ID="$cli_id" run_test testSeeCLIPicture; then
	record m27-test-shown PASS "the CLI's details, photographed (m27-10-cli-picture)"
else
	record m27-test-shown FAIL "xcodebuild test failed (m27/testSeeCLIPicture.tail.txt)"
fi
stage m27-shown
pixels=$(colour_pixels "$out/shots/m27-10-cli-picture.png" 255 0 255)
if [ "${pixels:-0}" -ge 20000 ]; then
	record m27-shown PASS "$pixels magenta pixels on the CLI's details: its picture"
else
	record m27-shown FAIL "${pixels:-0} magenta pixels on m27-10-cli-picture, want 20000 (the 120 pt picture is about 100000 at 3x)"
fi

stage m27-test-control
sets_before=$(app_lines ': profile picture set, a ' | grep -c .)
if TEST_RUNNER_M27_TEXT="$control" TEST_RUNNER_M27_TAG=control run_test testWriteToCLI; then
	record m27-test-control PASS "\"$control\" to the CLI"
else
	record m27-test-control FAIL "xcodebuild test failed (m27/testWriteToCLI.tail.txt)"
fi
stage m27-control
if wait_app_lines ": $control id=" 1 60 > /dev/null; then
	sleep 20
	n_sets=$(app_lines ': profile picture set, a ' | grep -c .)
	if [ "$n_sets" = "$sets_before" ]; then
		record m27-control PASS "listen printed \"$control\" and, 20 s on, no more profile picture set from the app ($n_sets in all)"
	else
		record m27-control FAIL "$((n_sets - sets_before)) more profile picture(s) set from the app with the control text: a text alone brings one, so m27-requested proves nothing"
	fi
else
	record m27-control FAIL "listen printed no \"$control\" from the app within 60 s"
fi

listen_stop
stage m27-request
sets_before=$(app_lines ': profile picture set, a ' | grep -c .)
o_req=$(offset)
if cli_send request -request-profile-picture; then
	cli_sent="$cli_sent $SENT"
	record m27-request PASS "$(grep -F "sent $SENT" "$out/send-request.txt" | cut -c1-160)"
else
	tail -n 5 "$out/send-request.txt"
	record m27-request FAIL "the CLI's send -request-profile-picture failed (m27/send-request.txt)"
fi
listen_start || echo "::warning::listen did not say it listens"
stage m27-test-request
if TEST_RUNNER_M27_TEXT="$after_request" TEST_RUNNER_M27_TAG=request run_test testWriteToCLI; then
	record m27-test-request PASS "\"$after_request\" to the CLI"
else
	record m27-test-request FAIL "xcodebuild test failed (m27/testWriteToCLI.tail.txt)"
fi
stage m27-requested
sets=$(wait_app_lines ': profile picture set, a ' $((sets_before + 1)) 60)
n_sets=$(printf '%s\n' "$sets" | sed '/^$/d' | wc -l | tr -d ' ')
other=$(printf '%s\n' "$sets" | sizes_of | grep -vx "${app_size:-none}" | head -n 1)
served=0
[ -n "$app_ref" ] && served=$(wait_since "$o_req" 30 1 'blob: blob download' "blob_ref=$app_ref" | grep -c 'outcome=served')
n_up=$(since "$o_set" 'blob: blob uploaded' "owner=$app_id" | grep -c .)
if [ "$n_sets" -gt "$sets_before" ] && [ -z "$other" ] && [ "$served" -ge 1 ] && [ "$n_up" = 1 ]; then
	record m27-requested PASS "after the request: $((n_sets - sets_before)) more profile picture(s) set from the app, of $app_size bytes, $served more served download(s) of $app_ref, still one upload"
else
	record m27-requested FAIL "after the request: $((n_sets - sets_before)) more profile picture(s) set${other:+, one of $other bytes}, $served more served download(s) of ${app_ref:-?}, $n_up upload(s) in all (want 1, 1 and 1)"
fi

stage m27-test-delete
deleted=false
how_deleted=
for try in 1 2; do
	retry=
	[ "$try" = 2 ] && retry=1
	if TEST_RUNNER_M27_RETRY="$retry" run_test testDeleteOwnPicture; then
		deleted=true
		how_deleted="try $try"
		[ -f "$RESULTS/m27/m27-12-none.txt" ] && how_deleted="try 2 found no picture left: try 1's deletion"
		break
	fi
	cp "$RESULTS/m27/testDeleteOwnPicture.tail.txt" "$RESULTS/m27/testDeleteOwnPicture-try$try.tail.txt" 2> /dev/null
done
written=false
TEST_RUNNER_M27_TEXT="$after_delete" TEST_RUNNER_M27_TAG=delete run_test testWriteToCLI && written=true
if [ "$deleted" = true ] && [ "$written" = true ]; then
	record m27-test-delete PASS "Profile > Edit > the delete badge > Done ($how_deleted), then \"$after_delete\""
else
	record m27-test-delete FAIL "deleted: $deleted (two tries), text written: $written (m27/testDeleteOwnPicture-try1.tail.txt, -try2, testWriteToCLI.tail.txt): later milestones may carry the picture"
fi
stage m27-deleted
if line=$(wait_app_lines ': profile picture deleted id=' 1 60); then
	record m27-deleted PASS "$(printf '%s\n' "$line" | head -n 1 | cut -c1-200)"
else
	record m27-deleted FAIL "the CLI printed no \"profile picture deleted\" from the app within 60 s"
fi

listen_stop
stage m27-cli-deleted
if cli_send delete -delete-profile-picture; then
	cli_sent="$cli_sent $SENT"
	record m27-cli-deleted PASS "$(grep -F "sent $SENT" "$out/send-delete.txt" | cut -c1-160)"
else
	tail -n 5 "$out/send-delete.txt"
	record m27-cli-deleted FAIL "the CLI's send -delete-profile-picture failed (m27/send-delete.txt): the app keeps the CLI's picture for later milestones"
fi

stage m27-not-done
dones=""
for ref in $app_ref $cli_ref; do
	dones="$dones$(since "$m27_start" 'blob: done handled' "blob_ref=$ref")"
done
if [ -z "$app_ref" ] || [ -z "$cli_ref" ]; then
	record m27-not-done FAIL "not both pictures' blobs are known (app ${app_ref:-?}, CLI ${cli_ref:-?})"
elif [ -z "$dones" ]; then
	record m27-not-done PASS "no done for $app_ref or $cli_ref: $(since "$m27_start" 'blob: blob download' "blob_ref=$app_ref" | grep -c 'outcome=served') and $(since "$m27_start" 'blob: blob download' "blob_ref=$cli_ref" | grep -c 'outcome=served') served downloads"
else
	first=$(printf '%s\n' "$dones" | sed '/^$/d' | head -n 1)
	record m27-not-done FAIL "a done for a profile picture, outcome=$(printf '%s' "$first" | sed -n 's/.* outcome=\([^ ]*\).*/\1/p'): $(short "$first")"
fi
stage m27-relay
app_ids=$( (app_lines ': profile picture set, a '; app_lines ': profile picture deleted id=') | ids_of | sort -u | tr '\n' ' ')
if [ -z "$app_ids" ] || [ -z "$cli_sent" ]; then
	record m27-relay FAIL "no IDs to check (app: ${app_ids:-none}, CLI: ${cli_sent:-none})"
elif out_app=$(relayed_count "$m27_start" 30 "$app_id" "$cli_id" $app_ids) &&
	out_cli=$(relayed_count "$m27_start" 30 "$cli_id" "$app_id" $cli_sent); then
	record m27-relay PASS "the app's 0x18 and 0x19: $out_app accepted and acknowledged by the CLI; the CLI's: $out_cli delivered and acknowledged by the app"
else
	record m27-relay FAIL "the app's: ${out_app:-?}; the CLI's: ${out_cli:-not checked} (m27/chat-lines.txt)"
fi
record m27-flags INFO "the app's: $(accepted_flags "$m27_start" "$app_id" "$cli_id" $app_ids); the CLI's: $(accepted_flags "$m27_start" "$cli_id" "$app_id" $cli_sent)"
own=$(colour_pixels "$out/shots/m27-06-profile.png" 255 255 0)
record m27-own-shown INFO "${own:-0} yellow pixels on the Profile tab after the save (m27-06-profile)"
record m27-blob-lines INFO "$(since "$m27_start" 'component=blob' | wc -l | tr -d ' ') blob server lines in milestone 27"
shot m27-19-final

failed=$(failing_stages "$M27_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 27: every stage passed"
