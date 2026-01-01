#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/common.sh"
root=$(ci_root)
: "${RESULTS:?}" "${RESULTS_FULL:?}"
log="$RESULTS_FULL/rust-libthreema.log"
target=aarch64-apple-ios-sim

stage rust-libthreema
status=0
(
	set -euo pipefail
	cd "$root/threema-ios"
	mise trust mise.toml
	if ! mise install; then
		echo "mise install failed; installing rust alone"
		mise install rust
		export MISE_EXEC_AUTO_INSTALL=false
	fi
	(cd libthreema && mise exec -- rustup target add "$target" && mise exec -- cargo --version)
	PROTOC="$(command -v protoc)"
	export PROTOC
	xcrun --sdk macosx ./scripts/BuildRustLibrary/Sources/BuildRustLibraryScript/main.swift libthreema \
		--library-path libthreema \
		--framework-out-file-path libthreemaSwift/libthreema.xcframework \
		--swift-out-file-path libthreemaSwift/Sources/libthreemaSwift/Generated/libthreema.swift \
		--targets "$target" --force
	test -d libthreemaSwift/libthreema.xcframework
	test -s libthreemaSwift/Sources/libthreemaSwift/Generated/libthreema.swift
	plutil -p libthreemaSwift/libthreema.xcframework/Info.plist
) 2>&1 | tee "$log" || status=$?
tail -n 100 "$log" > "$RESULTS/build/rust-libthreema.tail.txt"
if [ "$status" != 0 ]; then
	record rust-libthreema FAIL "BuildRustLibrary failed (rust-libthreema.tail.txt)"
	exit 1
fi
record rust-libthreema PASS "Rust ${RUST_LIBTHREEMA:-}, $target"
