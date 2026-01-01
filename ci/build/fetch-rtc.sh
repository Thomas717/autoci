#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/common.sh"
root=$(ci_root)
: "${RUNNER_TEMP:?}" "${WEBRTC_VERSION:?}" "${RESULTS:?}"
tree="$root/threema-ios"
zip="$RUNNER_TEMP/webrtc.zip"

stage webrtc
version=$(tr -d ' \r\n' < "$tree/.webrtc-version")
if [ "$version" != "$WEBRTC_VERSION" ]; then
	record webrtc FAIL ".webrtc-version is $version, ci/rtc.env says $WEBRTC_VERSION"
	exit 1
fi
curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 300 --speed-limit 50000 --speed-time 60 \
	-o "$zip" "https://oss.threema.ch/ios/webrtc/$version/WebRTC.xcframework.zip"
size=$(wc -c < "$zip" | tr -d ' ')
sha=$(sha256_file "$zip")
mkdir -p "$RESULTS/build"
if [ -n "${WEBRTC_ZIP_SIZE:-}" ] && [ "$size" != "$WEBRTC_ZIP_SIZE" ]; then
	record webrtc FAIL "the zip is $size bytes (SHA-256 $sha), expected $WEBRTC_ZIP_SIZE"
	exit 1
fi
if [ -n "${WEBRTC_ZIP_SHA256:-}" ] && [ "$sha" != "$WEBRTC_ZIP_SHA256" ]; then
	record webrtc FAIL "the zip's SHA-256 is $sha ($size bytes), ci/rtc.env says $WEBRTC_ZIP_SHA256"
	exit 1
fi
if [ -z "${WEBRTC_ZIP_SHA256:-}" ] || [ -z "${WEBRTC_ZIP_SIZE:-}" ]; then
	echo "::warning::WebRTC $version zip is not pinned yet: $size bytes, SHA-256 $sha. Commit both to ci/rtc.env."
	{
		echo "WebRTC $version zip: $size bytes, SHA-256 $sha (not pinned yet; trust on first use)."
		echo "Commit it to ci/rtc.env as (no app rebuild follows):"
		echo
		echo "    WEBRTC_ZIP_SIZE=$size"
		echo "    WEBRTC_ZIP_SHA256=$sha"
	} > "$RESULTS/build/webrtc.txt"
	metric webrtc_sha256 "$sha (unpinned)"
	metric webrtc_zip_size "$size (unpinned)"
else
	metric webrtc_sha256 "$sha (pinned)"
fi
rm -rf "$tree/WebRTC.xcframework"
mkdir "$tree/WebRTC.xcframework"
unzip -q "$zip" -d "$tree/WebRTC.xcframework"
rm -f "$zip"
test -f "$tree/WebRTC.xcframework/Info.plist"
record webrtc PASS "$version, $size bytes, SHA-256 $sha"
