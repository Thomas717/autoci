#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../scripts/common.sh"
root=$(ci_root)
: "${RUST_SALTYRTC:?}" "${RESULTS:?}" "${RESULTS_FULL:?}"
log="$RESULTS_FULL/rust-saltyrtc.log"
target=aarch64-apple-ios-sim

stage rust-saltyrtc
status=0
(
	set -euo pipefail
	cd "$root/threema-ios"
	mise trust mise.toml
	mise install "rust@$RUST_SALTYRTC"
	mise exec "rust@$RUST_SALTYRTC" -- rustup target add "$target"
	cd saltyrtc-task-relayed-data-rs/ffi
	mise exec "rust@$RUST_SALTYRTC" -- cargo --version
	mise exec "rust@$RUST_SALTYRTC" -- cargo build --locked -p saltyrtc-task-relayed-data-ffi --lib --release --target "$target"
	test -f "target/$target/release/libsaltyrtc_task_relayed_data_ffi.a"
) 2>&1 | tee "$log" || status=$?
tail -n 100 "$log" > "$RESULTS/build/rust-saltyrtc.tail.txt"
if [ "$status" != 0 ]; then
	record rust-saltyrtc FAIL "cargo build failed (rust-saltyrtc.tail.txt)"
	exit 1
fi
record rust-saltyrtc PASS "Rust $RUST_SALTYRTC, $target"
