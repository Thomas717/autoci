#!/bin/bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
: "${RESULTS:?}" "${RUNNER_TEMP:?}"
exec 3>&-
out="$RESULTS/x27"
work="$RUNNER_TEMP/x27"
mkdir -p "$out" "$work/src" "$work/mc"

capped() {
	local secs=$1 pid killer rc
	shift
	"$@" &
	pid=$!
	(sleep "$secs" && kill -TERM "$pid") > /dev/null 2>&1 &
	killer=$!
	wait "$pid"
	rc=$?
	pkill -TERM -P "$killer" > /dev/null 2>&1
	wait "$killer" 2> /dev/null
	return "$rc"
}

stage x27-openssl
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
is_openssl3() { case $("$1" version 2> /dev/null) in "OpenSSL 3."*) return 0 ;; esac; return 1; }
pick=""
how=found
brew_prefix=$(brew --prefix openssl@3 2> /dev/null) || brew_prefix=""
for c in ${brew_prefix:+"$brew_prefix/bin/openssl"} /opt/homebrew/opt/openssl@3/bin/openssl \
	/usr/local/opt/openssl@3/bin/openssl $(type -a -p openssl 2> /dev/null) /opt/homebrew/bin/openssl; do
	[ -x "$c" ] || continue
	if is_openssl3 "$c"; then
		pick=$c
		break
	fi
done
if [ -z "$pick" ] && command -v brew > /dev/null 2>&1; then
	how="installed (brew install openssl@3)"
	capped 600 brew install openssl@3 > "$out/brew-openssl.txt" 2>&1
	c="$(brew --prefix openssl@3 2> /dev/null)/bin/openssl"
	if [ -x "$c" ] && is_openssl3 "$c"; then pick=$c; fi
fi
if [ -n "$pick" ]; then
	gh_env OPENSSL "$pick"
	record x27-openssl INFO "for the seal, $how: $pick ($("$pick" version 2> /dev/null | head -n 1))"
else
	record x27-openssl INFO "no OpenSSL 3 found or installed: the seal will fail"
fi

stage x27-runner
os_ver=$(sw_vers -productVersion 2> /dev/null)
os_build=$(sw_vers -buildVersion 2> /dev/null)
arch=$(uname -m)
ncpu=$(sysctl -n hw.ncpu 2> /dev/null || echo "?")
mem_gb=$(sysctl -n hw.memsize 2> /dev/null | awk '{ printf "%.1f", $1 / 1073741824 }')
image="${ImageOS:-?} ${ImageVersion:-?}"
{
	echo "== sw_vers"
	sw_vers
	echo "== uname -a"
	uname -a
	echo "== uname -m"
	uname -m
	echo "== sysctl"
	sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize
	echo "== image"
	echo "ImageOS=${ImageOS:-} ImageVersion=${ImageVersion:-}"
	echo "== xcode-select -p"
	xcode-select -p
	echo "== ls -ld /Applications/Xcode*"
	ls -ld /Applications/Xcode*
	echo "== df -h /"
	df -h /
	echo "== brew --version"
	brew --version
	echo "== type -a openssl, swift, python3"
	type -a openssl swift python3
	for c in $(type -a -p openssl); do printf '%s: ' "$c"; "$c" version; done
	echo "== python3 --version"
	python3 --version
} > "$out/system.txt" 2>&1
metric os "macOS $os_ver ($os_build)"
metric arch "$arch"
metric cpus "$ncpu"
metric memory_gb "$mem_gb"
metric image "$image"
record x27-runner INFO "macOS $os_ver ($os_build), $arch, $ncpu CPUs, $mem_gb GB, image $image, default $(xcode-select -p 2> /dev/null)"

stage x27-xcodes
apps=""
: > "$out/xcodes.txt"
for a in /Applications/Xcode*.app; do
	[ -e "$a" ] || continue
	r=$(cd -P "$a" 2> /dev/null && pwd) || continue
	if [ -L "$a" ]; then
		echo "$a -> $r" >> "$out/xcodes.txt"
	else
		echo "$a" >> "$out/xcodes.txt"
	fi
	case "
$apps
" in *"
$r
"*) ;; *) apps="$apps${apps:+
}$r" ;; esac
done
n_apps=$(printf '%s' "$apps" | grep -c .)
if [ "$n_apps" = 0 ]; then
	record x27-xcodes FAIL "no /Applications/Xcode*.app"
else
	record x27-xcodes PASS "$n_apps Xcode app(s): $(printf '%s\n' "$apps" | sed 's|^/Applications/||' | tr '\n' ' ')(links in x27/xcodes.txt)"
fi

cat > "$work/src/control.swift" << 'EOF'
import UIKit

@available(iOS 26.0, *)
func controlProbe(_ view: UIView) -> UILayoutGuide {
    view.layoutGuide(for: .safeArea(cornerAdaptation: nil))
}
EOF
cat > "$work/src/bar.swift" << 'EOF'
import UIKit

@available(iOS 27.1, *)
func barProbe(_ view: UIView) -> Bool {
    let guide = view.layoutGuide(for: .bar(onEdge: UIRectEdge.bottom, extent: 44))
    _ = guide.centerYAnchor
    return view.traitCollection.verticalBarEdge != .unspecified
}
EOF

lines_in() {
	local pat=$1
	shift
	[ "$#" -gt 0 ] || { echo 0; return 0; }
	grep -r -F -c -- "$pat" "$@" 2> /dev/null | awk -F: '{ s += $NF } END { print s + 0 }'
}

typecheck() {
	local dev=$1 sdk=$2 triple=$3 file=$4 rc log
	log="$work/tc.txt"
	DEVELOPER_DIR="$dev" capped 600 xcrun swiftc -typecheck -sdk "$sdk" -target "$triple" \
		-module-cache-path "$work/mc/$name-$(basename "$sdk")" "$file" > "$log" 2>&1
	rc=$?
	{
		echo "-- swiftc -typecheck -target $triple $(basename "$file"): exit $rc"
		grep -E 'error:|warning:' "$log" | cut -c1-400 | head -n 20
	} >> "$xfile"
	if [ "$rc" = 0 ]; then echo pass; else echo "fail (exit $rc)"; fi
}

{
	echo "| Xcode | build | SDK | version | verticalBarEdge: swiftinterface / UIKit | \`case bar(onEdge\`: swiftinterface | \`bar(onEdge\`: UIKit | control \`safeArea(cornerAdaptation\`: UIKit | typecheck control / bar |"
	echo "|---|---|---|---|---|---|---|---|---|"
} > "$out/sdks.txt"
: > "$out/runtimes.txt"
inventory=true
sdks_scanned=0
api_yes=""
xcode_note=""
while IFS= read -r app <&4; do
	[ -n "$app" ] || continue
	name=$(basename "$app" .app)
	dev="$app/Contents/Developer"
	xfile="$out/xcode-$name.txt"
	stage "x27-xcode-$name"
	ver_out=$(DEVELOPER_DIR="$dev" capped 180 xcodebuild -version 2>&1)
	ver_rc=$?
	xv=$(printf '%s\n' "$ver_out" | sed -n 's/^Xcode //p' | head -n 1)
	xb=$(printf '%s\n' "$ver_out" | sed -n 's/^Build version //p' | head -n 1)
	sdks_out=$(DEVELOPER_DIR="$dev" capped 180 xcodebuild -showsdks 2>&1)
	sdks_rc=$?
	{
		echo "== $app"
		echo "== xcodebuild -version (exit $ver_rc)"
		printf '%s\n' "$ver_out"
		echo "== xcodebuild -showsdks (exit $sdks_rc)"
		printf '%s\n' "$sdks_out"
	} > "$xfile"
	if [ "$ver_rc" != 0 ] || [ -z "$xv" ] || [ "$sdks_rc" != 0 ]; then inventory=false; fi
	{
		echo "== $name (Xcode ${xv:-?} ${xb:-?}): xcrun simctl list runtimes"
		DEVELOPER_DIR="$dev" capped 180 xcrun simctl list runtimes 2>&1
		echo
	} >> "$out/runtimes.txt"
	all_yes=true
	n_sdk=0
	notes=""
	for plat in iPhoneSimulator iPhoneOS; do
		seen=""
		for s in "$dev/Platforms/$plat.platform/Developer/SDKs/"*.sdk; do
			[ -e "$s" ] || continue
			sdk=$(cd -P "$s" 2> /dev/null && pwd) || continue
			case " $seen " in *" $sdk "*) continue ;; esac
			seen="$seen $sdk"
			n_sdk=$((n_sdk + 1))
			sdks_scanned=$((sdks_scanned + 1))
			sv=$(plutil -extract Version raw -o - "$sdk/SDKSettings.plist" 2> /dev/null ||
				/usr/libexec/PlistBuddy -c 'Print :Version' "$sdk/SDKSettings.plist" 2> /dev/null)
			cn=$(plutil -extract CanonicalName raw -o - "$sdk/SDKSettings.plist" 2> /dev/null ||
				/usr/libexec/PlistBuddy -c 'Print :CanonicalName' "$sdk/SDKSettings.plist" 2> /dev/null)
			[ -n "$cn" ] || cn=$(basename "$sdk" .sdk)
			u="$sdk/System/Library/Frameworks/UIKit.framework"
			ifaces=$(find "$u/Modules" -name '*.swiftinterface' 2> /dev/null | sort)
			{
				echo
				echo "== SDK $cn (version ${sv:-?}): ${sdk#"$dev"/}"
				echo "-- UIKit swiftinterface files and their lines: verticalBarEdge, 'case bar(onEdge', 'bar(onEdge', 'safeArea(cornerAdaptation'"
			} >> "$xfile"
			vbe_if=0
			case_if=0
			for f in $ifaces; do
				a1=$(lines_in verticalBarEdge "$f")
				a2=$(lines_in 'case bar(onEdge' "$f")
				a3=$(lines_in 'bar(onEdge' "$f")
				a4=$(lines_in 'safeArea(cornerAdaptation' "$f")
				vbe_if=$((vbe_if + a1))
				case_if=$((case_if + a2))
				echo "   $(basename "$f"): $a1, $a2, $a3, $a4" >> "$xfile"
			done
			[ -n "$ifaces" ] || echo "   (none under ${u#"$dev"/}/Modules)" >> "$xfile"
			vbe_all=$(lines_in verticalBarEdge "$u")
			bar_all=$(lines_in 'bar(onEdge' "$u")
			ctl_all=$(lines_in 'safeArea(cornerAdaptation' "$u")
			{
				echo "-- anywhere in UIKit.framework: verticalBarEdge $vbe_all, 'bar(onEdge' $bar_all, 'safeArea(cornerAdaptation' $ctl_all; the lines (3 before each):"
				grep -r -n -F -B 3 -e verticalBarEdge -e 'bar(onEdge' "$u" 2> /dev/null | sed "s|^$u/||" | cut -c1-300 | head -n 200
			} >> "$xfile"
			case $plat in
			iPhoneSimulator) triple="$arch-apple-ios17.0-simulator" ;;
			*) triple=arm64-apple-ios17.0 ;;
			esac
			tc_ctl=$(typecheck "$dev" "$sdk" "$triple" "$work/src/control.swift")
			tc_bar=$(typecheck "$dev" "$sdk" "$triple" "$work/src/bar.swift")
			yes_vbe=no
			yes_bar=no
			[ "$vbe_all" -gt 0 ] && yes_vbe=yes
			[ "$bar_all" -gt 0 ] && yes_bar=yes
			if [ "$yes_vbe" = yes ] && [ "$yes_bar" = yes ] && [ "$tc_bar" = pass ]; then
				api_yes="$api_yes${api_yes:+, }$name (${xv:-?} ${xb:-?}) $cn"
			else
				all_yes=false
			fi
			notes="$notes${notes:+; }SDK $cn (${sv:-?}): verticalBarEdge $yes_vbe, bar(onEdge $yes_bar, typecheck $tc_bar (control $tc_ctl)"
			echo "| $name (${xv:-?}) | ${xb:-?} | $cn | ${sv:-?} | $vbe_if / $vbe_all | $case_if | $bar_all | $ctl_all | $tc_ctl / $tc_bar |" >> "$out/sdks.txt"
		done
	done
	if [ "$n_sdk" = 0 ]; then
		all_yes=false
		notes="no iPhoneSimulator or iPhoneOS SDK"
	fi
	if [ "$all_yes" = true ]; then st=PASS; else st=INFO; fi
	record "x27-xcode-$name" "$st" "Xcode ${xv:-?} (${xb:-?}): $notes (x27/xcode-$name.txt)"
	xcode_note="$xcode_note${xcode_note:+, }$name ${xv:-?} ${xb:-?}"
done 4<< EOF
$apps
EOF

stage x27-runtimes
{
	echo "== default ($(xcode-select -p 2> /dev/null)): xcrun simctl runtime list"
	capped 180 xcrun simctl runtime list 2>&1
} >> "$out/runtimes.txt"
ios_rt=$(capped 180 xcrun simctl list runtimes 2> /dev/null | grep -E '^iOS ' | sed 's/ - com\.apple\.CoreSimulator\.SimRuntime\.[^ ]*//' | tr '\n' ';' | cut -c1-600)
record x27-runtimes INFO "default Xcode's iOS runtimes: ${ios_rt:-none} (x27/runtimes.txt)"

stage x27-api
if [ -n "$api_yes" ]; then
	record x27-api INFO "verticalBarEdge and bar(onEdge:extent:) declared, and their use typechecks, in: $api_yes"
else
	record x27-api INFO "no Xcode here has an iOS SDK that declares verticalBarEdge and bar(onEdge:extent:) with a passing typecheck"
fi
stage x27-inventory
if [ "$n_apps" != 0 ] && [ "$inventory" = true ] && [ "$sdks_scanned" -gt 0 ]; then
	record x27-inventory PASS "$n_apps Xcode app(s), $sdks_scanned iOS SDK(s) scanned: $xcode_note"
else
	record x27-inventory FAIL "an Xcode did not answer xcodebuild -version or -showsdks, or no iOS SDK was found ($n_apps app(s), $sdks_scanned SDK(s))"
fi
rm -rf "$work"
[ "$(stage_status x27-inventory)" = PASS ]
