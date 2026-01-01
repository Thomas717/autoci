#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/common.sh"
root=$(ci_root)
: "${RUNNER_TEMP:?}" "${RESULTS:?}" "${RESULTS_FULL:?}" "${SIM:?}"
udid=$(sim_udid)
dd="$RUNNER_TEMP/dd"
log="$RESULTS_FULL/xcodebuild.log"
product="$dd/Build/Products/Debug-iphonesimulator/Threema OnPrem.app"

pretty() {
	if command -v xcbeautify > /dev/null 2>&1; then
		xcbeautify --quiet --is-ci
	else
		grep -E 'error:|\*\* BUILD' || true
	fi
}

build() {
	local variant=$1
	shift
	echo "=== xcodebuild, signing variant $variant: $*" | tee -a "$log"
	xcodebuild build -project "$root/threema-ios/Threema.xcodeproj" -scheme "Threema OnPrem" -configuration Debug \
		-destination "platform=iOS Simulator,id=$udid" \
		-derivedDataPath "$dd" -clonedSourcePackagesDirPath "$RUNNER_TEMP/spm" \
		-disableAutomaticPackageResolution -skipMacroValidation -skipPackagePluginValidation -showBuildTimingSummary \
		COMPILER_INDEX_STORE_ENABLE=NO COMPILATION_CACHE_ENABLE_CACHING=NO \
		"$@" 2>&1 | tee -a "$log" | pretty
}

stage xcode-build
: > "$log"
variant=A
build A CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER=
status=$?
if [ "$status" != 0 ] && grep -Eq 'requires a provisioning profile|No profiles for|Signing for .* requires|No signing certificate' "$log"; then
	echo "::warning::signing variant A asked for a profile; trying variant B (Sign to Run Locally, no team)"
	variant=B
	build B CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM= PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER=
	status=$?
fi
metric signing_variant "$variant"

tail -n 200 "$log" > "$RESULTS/build/xcodebuild-tail.txt"
grep -E '(^|[^a-z])error:' "$log" | sort -u | head -n 200 > "$RESULTS/build/xcodebuild-errors.txt" || true
awk '/Build Timing Summary/ { on = 1 } on' "$log" | head -n 120 > "$RESULTS/build/xcodebuild-timing.txt" || true

if [ "$status" != 0 ] || [ ! -d "$product" ]; then
	echo "the last error lines:"
	tail -n 40 "$RESULTS/build/xcodebuild-errors.txt"
	record xcode-build FAIL "xcodebuild failed (variant $variant; xcodebuild-errors.txt)"
	exit 1
fi
record xcode-build PASS "signing variant $variant"

rm -rf "$RUNNER_TEMP/app"
mkdir -p "$RUNNER_TEMP/app"
ditto "$product" "$RUNNER_TEMP/app/Threema OnPrem.app"
{
	echo "built in run ${GITHUB_RUN_NUMBER:-local} on $(date -u +%Y-%m-%d), Xcode ${XCODE_BUILD:-?}, signing variant $variant, ${UPSTREAM_VERSION:-} ${UPSTREAM_SHA:-}"
	echo "key patch: ${KEY_PATCH:-bundle}"
	if [ -s "$RUNNER_TEMP/app-patches.txt" ]; then
		sed 's/^/source patch: /' "$RUNNER_TEMP/app-patches.txt"
	else
		echo "source patches: none"
	fi
} > "$RUNNER_TEMP/app/build-info.txt"
du -sh "$RUNNER_TEMP/app" | tee -a "$RESULTS/build/app-size.txt"

if check_entitlements "$RUNNER_TEMP/app/Threema OnPrem.app" "$RESULTS/build" built; then
	record entitlements-built PASS "simulated entitlements carry ${APP_GROUP:-} and keychain-access-groups"
else
	record entitlements-built FAIL "simulated entitlements lack ${APP_GROUP:-} or keychain-access-groups"
fi
exit 0
