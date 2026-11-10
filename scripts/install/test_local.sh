#!/bin/sh
# Builds chaincash from source and runs the install.sh tests against that build, so the
# installer can be tested on macOS or Linux without a GitHub release.
#
#   ./scripts/install/test_local.sh             # build, then test
#   ./scripts/install/test_local.sh --no-build  # reuse the existing target/release/chaincash
#
# All output is also written to install-test-<os>-<arch>-<timestamp>.log in the repository root,
# ready to be shared. Set CHAINCASH_TEST_LOG to choose a different file.
#
# Requirements: git, a Rust toolchain (https://rustup.rs) and a C compiler
# (on macOS: `xcode-select --install`; Linux builds also need perl and make for OpenSSL).
# Your real $HOME is not touched, every test runs with a temporary one.

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
log="${CHAINCASH_TEST_LOG:-$repo_root/install-test-$os-$arch-$(date +%Y%m%d-%H%M%S).log}"

print_environment() {
	echo "chaincash install test report"
	echo "date:     $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
	echo "system:   $(uname -srm)"
	if command -v sw_vers >/dev/null 2>&1; then
		echo "macOS:    $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
	elif [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		echo "distro:   $(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
	fi
	echo "shell:    $(readlink /bin/sh 2>/dev/null || echo /bin/sh)"
	echo "commit:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown) ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown))"
	echo "rustc:    $(rustc --version 2>/dev/null || echo 'not found')"
	echo "cargo:    $(cargo --version 2>/dev/null || echo 'not found')"
	echo "curl:     $(curl --version 2>/dev/null | head -n 1 || echo 'not found')"
	echo
}

run() {
	case $(uname -sm) in
	"Darwin x86_64") target="x86_64-apple-darwin" features="bundled-sqlite" ;;
	"Darwin arm64") target="aarch64-apple-darwin" features="bundled-sqlite" ;;
	"Linux x86_64") target="x86_64-unknown-linux-gnu" features="bundled-sqlite,vendored-openssl" ;;
	"Linux aarch64" | "Linux arm64") target="aarch64-unknown-linux-gnu" features="bundled-sqlite,vendored-openssl" ;;
	*)
		echo "Error: unsupported platform '$(uname -sm)'" >&2
		return 1
		;;
	esac

	if [ "${1:-}" != "--no-build" ]; then
		echo "Building chaincash for $target (features: $features)..."
		git submodule update --init
		cargo build --release --locked -p chaincash_cli --features "$features"
	fi

	binary="target/release/chaincash"
	if [ ! -f "$binary" ]; then
		echo "Error: $binary not found, run without --no-build" >&2
		return 1
	fi

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

	echo
	echo "Testing install.sh against local assets in $dist"
	sh scripts/install/install_test.sh --dist "$dist"
}

# POSIX sh has no pipefail, so the exit status of the run is passed back through a file
status_file="$(mktemp 2>/dev/null || mktemp -t chaincash-status)"
trap 'rm -f "$status_file"' EXIT
{
	print_environment
	set +e
	(
		set -e
		run "$@"
	)
	status=$?
	set -e
	echo
	if [ $status -eq 0 ]; then
		echo "RESULT: PASSED"
	else
		echo "RESULT: FAILED (exit code $status)"
	fi
	echo $status >"$status_file"
} 2>&1 | tee "$log"

status="$(cat "$status_file")"
echo
echo "Test report written to $log"
exit "$status"
