#!/bin/sh
# Installs the `chaincash` binary and default configuration.
#
#   curl -fsSL https://raw.githubusercontent.com/BetterMoneyLabs/chaincash-rs/master/scripts/install/install.sh | sh
#
# Install a specific release by passing its tag:
#
#   curl -fsSL .../install.sh | sh -s v0.1.0
#
# Environment variables:
#   CHAINCASH_INSTALL      install prefix, the binary goes in "$CHAINCASH_INSTALL/bin" (default: ~/.local)
#   CHAINCASH_REPO         GitHub repository to download releases from (default: BetterMoneyLabs/chaincash-rs)
#   CHAINCASH_RELEASE_URL  base URL of release assets, overrides CHAINCASH_REPO (mainly for testing)
#   XDG_CONFIG_HOME        config is written to "$XDG_CONFIG_HOME/chaincash" (default: ~/.config/chaincash)
#   XDG_DATA_HOME          the database is stored in "$XDG_DATA_HOME/chaincash" (default: ~/.local/share/chaincash)
#
# Inspired by https://github.com/nautls/ergomatic/tree/main/scripts/install

set -eu

error() {
	echo "Error: $*" >&2
	exit 1
}

if [ -z "${HOME:-}" ]; then
	error "\$HOME is not set"
fi

# ---------------------------------------------------------------------------
# Detect target platform
# ---------------------------------------------------------------------------

ext=""
if [ "${OS:-}" = "Windows_NT" ]; then
	target="x86_64-pc-windows-msvc"
	ext=".exe"
else
	case $(uname -sm) in
	"Darwin x86_64") target="x86_64-apple-darwin" ;;
	"Darwin arm64") target="aarch64-apple-darwin" ;;
	"Linux x86_64") target="x86_64-unknown-linux-gnu" ;;
	"Linux aarch64" | "Linux arm64") target="aarch64-unknown-linux-gnu" ;;
	*) error "unsupported platform '$(uname -sm)', please build chaincash from source: https://github.com/BetterMoneyLabs/chaincash-rs" ;;
	esac

	# release binaries are linked against glibc and won't run on musl based distros (e.g. Alpine)
	if [ "$(uname -s)" = "Linux" ] && ls /lib/ld-musl-* >/dev/null 2>&1; then
		error "musl based Linux distributions are not supported by prebuilt binaries, please build chaincash from source: https://github.com/BetterMoneyLabs/chaincash-rs"
	fi
fi

# ---------------------------------------------------------------------------
# Resolve download location
# ---------------------------------------------------------------------------

version="${1:-}"
case $version in
"" | v*) ;;
*) version="v$version" ;;
esac

repo="${CHAINCASH_REPO:-BetterMoneyLabs/chaincash-rs}"
if [ -n "${CHAINCASH_RELEASE_URL:-}" ]; then
	release_url="$CHAINCASH_RELEASE_URL"
elif [ -z "$version" ]; then
	release_url="https://github.com/$repo/releases/latest/download"
else
	release_url="https://github.com/$repo/releases/download/$version"
fi

asset="chaincash-$target$ext"

# ---------------------------------------------------------------------------
# Resolve install locations
# ---------------------------------------------------------------------------

# Prints an absolute version of the given path without requiring it to exist.
absolute_path() {
	case $1 in
	/*) echo "$1" ;;
	*) echo "$(pwd)/$1" ;;
	esac
}

# Prints a path in a form the Windows binary understands when running under Git Bash/MSYS.
native_path() {
	if [ -n "$ext" ] && command -v cygpath >/dev/null 2>&1; then
		cygpath -m "$1"
	else
		echo "$1"
	fi
}

install_prefix="$(absolute_path "${CHAINCASH_INSTALL:-$HOME/.local}")"
bin_dir="$install_prefix/bin"
exe="$bin_dir/chaincash$ext"

# must match `config_dir()` in crates/chaincash_app/src/lib.rs
case ${XDG_CONFIG_HOME:-} in
/*) config_dir="$XDG_CONFIG_HOME/chaincash" ;;
*) config_dir="$HOME/.config/chaincash" ;;
esac
case ${XDG_DATA_HOME:-} in
/*) data_dir="$XDG_DATA_HOME/chaincash" ;;
*) data_dir="$HOME/.local/share/chaincash" ;;
esac

config_file="$config_dir/config.toml"
predicates_dir="$config_dir/predicates"
example_predicate="$predicates_dir/example.toml"

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

tmp_dir="$(mktemp -d 2>/dev/null || mktemp -d -t chaincash)"
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 1' INT TERM

# download <url> <output file>
download() {
	if command -v curl >/dev/null 2>&1; then
		curl --fail --silent --show-error --location --output "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget --quiet --output-document="$2" "$1"
	else
		error "either 'curl' or 'wget' is required to install chaincash"
	fi
}

# fetch <asset name>: downloads a release asset into the temporary directory
fetch() {
	download "$release_url/$1" "$tmp_dir/$1" || error "failed to download $release_url/$1"
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}

# verify <asset name>: checks a downloaded asset against the release SHA256SUMS file
verify() {
	expected="$(awk -v f="$1" '$2 == f || $2 == "*"f { print $1 }' "$tmp_dir/SHA256SUMS")"
	[ -n "$expected" ] || error "no checksum for $1 in SHA256SUMS"
	actual="$(sha256 "$tmp_dir/$1")"
	if [ -z "$actual" ]; then
		echo "Warning: neither 'sha256sum' nor 'shasum' found, skipping checksum verification of $1" >&2
	elif [ "$actual" != "$expected" ]; then
		error "checksum mismatch for $1 (expected $expected, got $actual)"
	fi
}

# ---------------------------------------------------------------------------
# Install binary
# ---------------------------------------------------------------------------

echo "Downloading chaincash ${version:-(latest)} for $target..."
fetch SHA256SUMS
fetch "$asset"
verify "$asset"

mkdir -p "$bin_dir"
# stage next to the destination, then rename: replacing the binary is atomic and also
# works while an older version is running
staged="$exe.download"
cp "$tmp_dir/$asset" "$staged"
chmod +x "$staged"
mv -f "$staged" "$exe"
echo "Installed binary to $exe"

# ---------------------------------------------------------------------------
# Install configuration, existing files are never overwritten
# ---------------------------------------------------------------------------

mkdir -p "$predicates_dir" "$data_dir"

if [ -e "$example_predicate" ]; then
	echo "Keeping existing predicate $example_predicate"
else
	fetch predicate-example.toml
	verify predicate-example.toml
	mv "$tmp_dir/predicate-example.toml" "$example_predicate"
	echo "Installed example predicate to $example_predicate"
fi

if [ -e "$config_file" ]; then
	echo "Keeping existing config $config_file"
else
	cat >"$config_file" <<EOF
# ChainCash server configuration.
#
# Values set here override the built-in defaults, see:
# https://github.com/$repo/blob/master/config/default.toml
# Environment variables override this file, e.g. CHAINCASH_NODE.API_KEY=...

[server]
url = "127.0.0.1"
port = 8080

[node]
url = "http://localhost:9053"
# API key of your Ergo node, prefer setting it with the CHAINCASH_NODE.API_KEY env var
api_key = "hello"

[store]
url = '$(native_path "$data_dir/chaincash.sqlite")'

[acceptance]
# paths to predicate configuration files
# if ANY of these evaluate to true a note will be accepted
predicates = ['$(native_path "$example_predicate")']
EOF
	echo "Installed config to $config_file"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo
echo "chaincash was installed successfully"
"$exe" --version

case ":$PATH:" in
*":$bin_dir:"*)
	echo "Run 'chaincash run' to start the server"
	;;
*)
	case ${SHELL:-} in
	*/zsh) shell_profile="\$HOME/.zshrc" ;;
	*/fish) shell_profile="\$HOME/.config/fish/config.fish" ;;
	*) shell_profile="\$HOME/.bashrc" ;;
	esac
	echo
	echo "$bin_dir is not on your PATH. Add it by adding this line to $shell_profile (or similar):"
	echo "  export PATH=\"$bin_dir:\$PATH\""
	echo "Then run 'chaincash run' to start the server"
	;;
esac

echo
echo "Edit $config_file to configure your Ergo node and acceptance predicates."
