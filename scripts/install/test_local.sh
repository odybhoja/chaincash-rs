#!/bin/sh
# Builds chaincash from source and runs the install.sh tests against that build, so the
# installer can be tested on macOS or Linux without a GitHub release.
#
#   ./scripts/install/test_local.sh             # build, then test
#   ./scripts/install/test_local.sh --no-build  # reuse the existing target/release/chaincash
#
# Requirements: git, a Rust toolchain (https://rustup.rs) and a C compiler
# (on macOS: `xcode-select --install`; Linux builds also need perl and make for OpenSSL).
# Your real $HOME is not touched, every test runs with a temporary one.

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

case $(uname -sm) in
"Darwin x86_64") target="x86_64-apple-darwin" features="bundled-sqlite" ;;
"Darwin arm64") target="aarch64-apple-darwin" features="bundled-sqlite" ;;
"Linux x86_64") target="x86_64-unknown-linux-gnu" features="bundled-sqlite,vendored-openssl" ;;
"Linux aarch64" | "Linux arm64") target="aarch64-unknown-linux-gnu" features="bundled-sqlite,vendored-openssl" ;;
*)
	echo "Error: unsupported platform '$(uname -sm)'" >&2
	exit 1
	;;
esac

if [ "${1:-}" != "--no-build" ]; then
	echo "Building chaincash for $target (features: $features)..."
	git submodule update --init
	cargo build --release --locked -p chaincash_cli --features "$features"
fi

binary="target/release/chaincash"
[ -f "$binary" ] || {
	echo "Error: $binary not found, run without --no-build" >&2
	exit 1
}

# lay out the same assets a GitHub release has (see .github/workflows/release.yaml)
dist="$(mktemp -d 2>/dev/null || mktemp -d -t chaincash-dist)"
trap 'rm -rf "$dist"' EXIT
cp "$binary" "$dist/chaincash-$target"
cp config/predicates/example.toml "$dist/predicate-example.toml"
(
	cd "$dist"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -- * >SHA256SUMS
	else
		shasum -a 256 -- * >SHA256SUMS
	fi
)

echo "Testing install.sh against local assets in $dist"
sh scripts/install/install_test.sh --dist "$dist"
