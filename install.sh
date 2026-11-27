#!/usr/bin/env bash
# Install the subscription-usage overlay for oh-my-pi v19.2.1.
#
# Default: clone the upstream tag into $OMP_SUBSCRIPTION_USAGE_HOME, apply the
# patch, install workspace deps + prebuilt native bindings, and write an
# `omp-subscription-usage` launcher.
#
# Existing checkout: `./install.sh --checkout /path/to/oh-my-pi-v19.2.1`.
# The checkout is patched in place.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMP_TAG="${OMP_TAG:-v19.2.1}"
PATCH="$ROOT/patches/0001-subscription-usage-policy.patch"
INSTALL_ROOT="${OMP_SUBSCRIPTION_USAGE_HOME:-$HOME/.local/share/omp-subscription-usage}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SKIP_DEPS="${SKIP_DEPS:-0}"
CHECKOUT=""

usage() {
	cat <<'EOF'
Usage: ./install.sh [--checkout PATH] [--no-deps] [--help]

  --checkout PATH  Patch an existing oh-my-pi v19.2.1 source checkout in place.
  --no-deps        Do not run `bun install` (assumes node_modules is ready).
  --help           Show this help.

Environment:
  OMP_SUBSCRIPTION_USAGE_HOME  Install root (default: ~/.local/share/omp-subscription-usage)
  BIN_DIR                      Launcher directory (default: ~/.local/bin)
  OMP_TAG                      Upstream tag (default: v19.2.1)
  BUN                          Bun executable to use
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--checkout)
			CHECKOUT="${2:?--checkout needs a path}"
			shift 2
			;;
		--no-deps)
			SKIP_DEPS=1
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

command -v git >/dev/null 2>&1 || {
	echo "git is required" >&2
	exit 1
}

if [ -n "$CHECKOUT" ]; then
	SRC="$(cd "$CHECKOUT" && pwd)"
	if ! git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "Not a git checkout: $SRC" >&2
		exit 1
	fi
	DESCRIBED="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
	if [ "$DESCRIBED" != "$OMP_TAG" ]; then
		echo "Warning: $SRC is not exactly $OMP_TAG (found: ${DESCRIBED:-no exact tag})." >&2
		echo "         The patch targets $OMP_TAG and may not apply cleanly." >&2
	fi
else
	SRC="$INSTALL_ROOT/oh-my-pi"
	if [ ! -d "$SRC/.git" ]; then
		mkdir -p "$INSTALL_ROOT"
		echo "Cloning oh-my-pi $OMP_TAG into $SRC ..."
		git clone --depth 1 --branch "$OMP_TAG" https://github.com/can1357/oh-my-pi.git "$SRC"
	fi
fi

if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
	echo "Applying subscription-usage patch ..."
	git -C "$SRC" apply "$PATCH"
elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
	echo "Patch already applied; continuing."
else
	echo "Patch does not apply to $SRC." >&2
	echo "Use a clean $OMP_TAG checkout, or re-clone without --checkout." >&2
	exit 1
fi

BUN_BIN="${BUN:-}"
if [ -z "$BUN_BIN" ] || [ ! -x "$BUN_BIN" ]; then
	if command -v bun >/dev/null 2>&1; then
		BUN_BIN="$(command -v bun)"
	elif [ -x "$INSTALL_ROOT/.bun/bin/bun" ]; then
		BUN_BIN="$INSTALL_ROOT/.bun/bin/bun"
	else
		echo "Installing Bun into $INSTALL_ROOT/.bun ..."
		curl -fsSL https://bun.sh/install | BUN_INSTALL="$INSTALL_ROOT/.bun" bash
		BUN_BIN="$INSTALL_ROOT/.bun/bin/bun"
	fi
fi
export PATH="$(dirname "$BUN_BIN"):$PATH"

if [ "$SKIP_DEPS" != "1" ]; then
	echo "Installing workspace dependencies ..."
	(cd "$SRC" && "$BUN_BIN" install --frozen-lockfile)
fi

NATIVE_DIR="$SRC/packages/natives/native"
mkdir -p "$NATIVE_DIR"
if compgen -G "$NATIVE_DIR/*.node" >/dev/null; then
	echo "Native bindings already present."
else
	case "$(uname -s)-$(uname -m)" in
		Linux-x86_64) NATIVE_PKG="@oh-my-pi/pi-natives-linux-x64" ;;
		Linux-aarch64 | Linux-arm64) NATIVE_PKG="@oh-my-pi/pi-natives-linux-arm64" ;;
		Darwin-x86_64) NATIVE_PKG="@oh-my-pi/pi-natives-darwin-x64" ;;
		Darwin-arm64) NATIVE_PKG="@oh-my-pi/pi-natives-darwin-arm64" ;;
		MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) NATIVE_PKG="@oh-my-pi/pi-natives-win32-x64" ;;
		MINGW*-aarch64 | MSYS*-aarch64 | CYGWIN*-aarch64) NATIVE_PKG="@oh-my-pi/pi-natives-win32-arm64" ;;
		*) NATIVE_PKG="" ;;
	esac
	if [ -n "$NATIVE_PKG" ]; then
		echo "Fetching prebuilt native bindings ($NATIVE_PKG@$OMP_TAG) ..."
		TMP_NATIVE="$(mktemp -d)"
		trap 'rm -rf "$TMP_NATIVE"' EXIT
		(cd "$TMP_NATIVE" && "$BUN_BIN" add "$NATIVE_PKG@${OMP_TAG#v}" >/dev/null 2>&1)
		cp "$TMP_NATIVE"/node_modules/"$NATIVE_PKG"/*.node "$NATIVE_DIR"/
	else
		echo "No prebuilt native package for this platform." >&2
		echo "Build them with: (cd \"$SRC\" && bun --cwd=packages/natives run build)" >&2
	fi
fi

mkdir -p "$BIN_DIR"
LAUNCHER="$BIN_DIR/omp-subscription-usage"
cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$(dirname "$BUN_BIN"):\$PATH"
exec "$BUN_BIN" --cwd="$SRC/packages/coding-agent" src/cli.ts "\$@"
EOF
chmod +x "$LAUNCHER"
mkdir -p "$INSTALL_ROOT"
cp "$ROOT/examples/subscription-usage.yml" "$INSTALL_ROOT/subscription-usage.example.yml"

echo
echo "Installed patched oh-my-pi $OMP_TAG:"
echo "  source:   $SRC"
echo "  launcher: $LAUNCHER"
echo
echo "Enable it for a profile (copy once, then restart):"
echo "  cp \"$INSTALL_ROOT/subscription-usage.example.yml\" \"\$HOME/.omp/agent/subscription-usage.yml\""
echo "  $LAUNCHER"
echo
echo "Named profile example:"
echo "  cp \"$INSTALL_ROOT/subscription-usage.example.yml\" \"\$HOME/.omp/profiles/codex/agent/subscription-usage.yml\""
echo "  $LAUNCHER --profile codex"
echo
echo "Check the loaded policy inside a session with: /subscription-usage"

VERSION="$("$LAUNCHER" --version 2>/dev/null | tail -1)"
echo "Smoke check: launcher reports version ${VERSION:-unknown}"
