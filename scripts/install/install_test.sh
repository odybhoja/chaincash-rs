#!/bin/sh
# Tests for install.sh. Every test runs with a temporary $HOME so the real one is never touched.
#
#   ./scripts/install/install_test.sh              # test against the latest GitHub release
#   ./scripts/install/install_test.sh --dist DIR   # test against local release assets in DIR
#
# Set CHAINCASH_TEST_VERSION (e.g. v0.1.0) to also test installing a specific release,
# and CHAINCASH_REPO to test against releases of a fork.

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
installer="$script_dir/install.sh"

dist=""
if [ "${1:-}" = "--dist" ]; then
	dist="$(cd "$2" && pwd)"
fi

ext=""
if [ "${OS:-}" = "Windows_NT" ]; then
	ext=".exe"
fi

root="$(mktemp -d 2>/dev/null || mktemp -d -t chaincash-test)"
trap 'rm -rf "$root"' EXIT
case_no=0

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Starts a test case with a fresh, empty $HOME and a clean environment.
new_case() {
	case_no=$((case_no + 1))
	echo
	echo "=== $case_no. $1"
	HOME="$root/home$case_no"
	mkdir -p "$HOME"
	export HOME
	unset CHAINCASH_INSTALL XDG_CONFIG_HOME XDG_DATA_HOME
	if [ -n "$dist" ]; then
		export CHAINCASH_RELEASE_URL="file://$dist"
	fi
}

install() {
	sh "$installer" "$@"
}

assert_file() {
	[ -f "$1" ] || fail "expected file $1 to exist"
}

assert_contains() {
	grep -q -F -- "$2" "$1" || fail "expected $1 to contain '$2'"
}

# Paths written into config.toml, which uses Windows paths when installed from Git Bash.
native() {
	if [ -n "$ext" ] && command -v cygpath >/dev/null 2>&1; then
		cygpath -m "$1"
	else
		echo "$1"
	fi
}

# ---------------------------------------------------------------------------

new_case "installs latest release to the default locations"
install
exe="$HOME/.local/bin/chaincash$ext"
config="$HOME/.config/chaincash/config.toml"
predicate="$HOME/.config/chaincash/predicates/example.toml"
assert_file "$exe"
[ -x "$exe" ] || fail "$exe is not executable"
"$exe" --version | grep -q "^chaincash " || fail "unexpected --version output"
# requirement: config should be placed in ~/.config/chaincash/
assert_file "$config"
assert_file "$predicate"
assert_contains "$config" "$(native "$HOME/.local/share/chaincash/chaincash.sqlite")"
assert_contains "$config" "$(native "$predicate")"
[ -d "$HOME/.local/share/chaincash" ] || fail "data directory was not created"

if [ -z "$ext" ]; then
	new_case "installed binary reads its config from ~/.config/chaincash"
	install >/dev/null
	exe="$HOME/.local/bin/chaincash"
	log="$root/run$case_no.log"
	# run from an unrelated directory so ./config/ can't be picked up, bind a random free port.
	# Without an Ergo node the server exits once it tries to connect, which happens after the
	# config is loaded; TMPDIR keeps the resulting crash report inside the test directory.
	(cd "$root" && exec env 'CHAINCASH_SERVER.PORT=0' TMPDIR="$root" "$exe" run >"$log" 2>&1) &
	pid=$!
	i=0
	while [ $i -lt 50 ] && ! grep -q "loaded 1 predicates" "$log" 2>/dev/null; do
		sleep 0.2
		i=$((i + 1))
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	assert_contains "$log" "loading config from $HOME/.config/chaincash/config.toml"
	assert_contains "$log" "loaded 1 predicates"
	assert_file "$HOME/.local/share/chaincash/chaincash.sqlite"
fi

new_case "re-running keeps existing configuration and replaces the binary"
install >/dev/null
config="$HOME/.config/chaincash/config.toml"
predicate="$HOME/.config/chaincash/predicates/example.toml"
echo "# user edit" >>"$config"
echo "# user edit" >>"$predicate"
echo "stale" >"$HOME/.local/bin/chaincash$ext"
install
assert_contains "$config" "# user edit"
assert_contains "$predicate" "# user edit"
"$HOME/.local/bin/chaincash$ext" --version | grep -q "^chaincash " || fail "binary was not replaced"

new_case "installs to a custom location and honours XDG directories"
export CHAINCASH_INSTALL="$root/custom"
export XDG_CONFIG_HOME="$root/xdg-config"
export XDG_DATA_HOME="$root/xdg-data"
install >/dev/null
assert_file "$root/custom/bin/chaincash$ext"
assert_file "$root/xdg-config/chaincash/config.toml"
assert_contains "$root/xdg-config/chaincash/config.toml" "$(native "$root/xdg-data/chaincash/chaincash.sqlite")"
[ ! -e "$HOME/.local/bin/chaincash$ext" ] || fail "binary was installed to the default location"

new_case "installs to a relative custom location"
mkdir -p "$root/relative"
(cd "$root/relative" && CHAINCASH_INSTALL="." sh "$installer" >/dev/null)
assert_file "$root/relative/bin/chaincash$ext"

if [ -n "${CHAINCASH_TEST_VERSION:-}" ]; then
	new_case "installs a specific release ($CHAINCASH_TEST_VERSION)"
	unset CHAINCASH_RELEASE_URL
	install "$CHAINCASH_TEST_VERSION" >/dev/null
	"$HOME/.local/bin/chaincash$ext" --version | grep -q "${CHAINCASH_TEST_VERSION#v}" ||
		fail "installed version does not match $CHAINCASH_TEST_VERSION"
fi

if [ -n "$dist" ]; then
	new_case "refuses to install a binary that doesn't match SHA256SUMS"
	tampered="$root/tampered"
	cp -R "$dist" "$tampered"
	for f in "$tampered"/chaincash-*; do echo "tampered" >>"$f"; done
	export CHAINCASH_RELEASE_URL="file://$tampered"
	if install >"$root/tampered.log" 2>&1; then
		fail "install succeeded with a tampered binary"
	fi
	assert_contains "$root/tampered.log" "checksum mismatch"
	[ ! -e "$HOME/.local/bin/chaincash$ext" ] || fail "tampered binary was installed"
fi

echo
echo "All $case_no install tests passed"
