#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
root=$(ci_root)
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SRV:?}"
udid=$(sim_udid)
out="$RESULTS_FULL/m2"
work="$RUNNER_TEMP/m2-driver"
mkdir -p "$out/shots" "$RESULTS/m2"

login=
diag_probe m2-before
load_sampler_start m2-load "$RESULTS/m2/load.txt"
trap load_sampler_stop EXIT

stage m2-test
xcodegen=${XCODEGEN:-xcodegen}
if ! command -v "$xcodegen" > /dev/null 2>&1; then
	brew install xcodegen > "$out/brew-xcodegen.log" 2>&1 || {
		record m2-test FAIL "brew install xcodegen failed"
		exit 1
	}
fi
rm -rf "$work"
cp -R "$root/ci/uitests" "$work"
if ! (cd "$work" && "$xcodegen" generate --spec project.yml) > "$out/xcodegen.log" 2>&1; then
	cp "$out/xcodegen.log" "$RESULTS/m2/xcodegen.log"
	record m2-test FAIL "xcodegen generate failed"
	exit 1
fi

status=0
xcodebuild test -project "$work/OnboardingDriver.xcodeproj" -scheme OnboardingDriver \
	-only-testing:OnboardingDriverUITests/OnboardingTests \
	-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$RUNNER_TEMP/dd-m2" \
	-resultBundlePath "$work/onboarding.xcresult" -collect-test-diagnostics never \
	-test-timeouts-enabled YES -maximum-test-execution-time-allowance 900 \
	CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= COMPILER_INDEX_STORE_ENABLE=NO \
	> "$out/xcodebuild-test.log" 2>&1 || status=$?
tail -n 150 "$out/xcodebuild-test.log" > "$RESULTS/m2/xcodebuild-test.tail.txt"

if ! export_attachments "$work/onboarding.xcresult" "$out/shots" "$RESULTS/m2" m2-; then
	cp "$work/attachments-m2-.log" "$RESULTS/m2/export.log"
fi

if [ "$status" = 0 ]; then
	record m2-test PASS "the onboarding reached the chat list"
else
	grep -E 'error:|failed|XCTAssert' "$out/xcodebuild-test.log" | head -n 20 || true
	record m2-test FAIL "xcodebuild test exit $status (m2/xcodebuild-test.tail.txt)"
fi

stage m2-identity
if line=$(wait_for_log 'directory: identity created' 60); then
	record m2-identity PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
else
	record m2-identity FAIL "no 'directory: identity created' in the server log"
fi
stage m2-connected
if line=$(wait_for_log 'chatserver: client connected' 120); then
	record m2-connected PASS "$(printf '%s' "$line" | sed 's/^time=[^ ]* //' | cut -c1-200)"
	login=$(printf '%s' "$line" | sed -n 's/^time=\([^ ]*\) .*/\1/p')
else
	record m2-connected FAIL "no 'chatserver: client connected' in the server log"
fi
sleep 5
shot m2-05-final
load_sampler_stop "$login"
diag_probe m2-after

failed=$(failing_stages "$M2_REQUIRED")
if [ -n "$failed" ]; then
	printf '%s\n' "$failed"
	exit 1
fi
echo "stage 2: every stage passed"
