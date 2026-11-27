#!/usr/bin/env bash
# Subscription-usage overlay installer for oh-my-pi v19.2.1.
#
# Curl:
#   curl -fsSL https://raw.githubusercontent.com/DoctorBlackZ33/omp-subscription-usage/main/install.sh | bash
#
# Local:
#   ./install.sh [options]
#
# The installer patches a source checkout (cloned automatically when absent),
# installs workspace deps and native bindings, writes an
# `omp-subscription-usage` launcher, and copies the policy YAML into the OMP
# profiles you select. It never modifies the installed `omp` binary.
set -euo pipefail

REPO_SLUG="DoctorBlackZ33/omp-subscription-usage"
REF="${OMP_SUB_REF:-v0.2.0}"
RAW_BASE="https://raw.githubusercontent.com/$REPO_SLUG/$REF"
OMP_TAG="${OMP_TAG:-v19.2.1}"
PATCH_REL="patches/0001-subscription-usage-policy.patch"
EXAMPLE_REL="examples/subscription-usage.yml"
INSTALL_ROOT="${OMP_SUBSCRIPTION_USAGE_HOME:-$HOME/.local/share/omp-subscription-usage}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DEFAULT_OMP_DIR="${OMP_DIR:-$HOME/.omp}"
TTY=/dev/tty

OMP_DIR=""
CHECKOUT=""
PROFILE_SELECTION=""
SKIP_DEPS=0
ASSUME_YES=0
FORCE=0
NO_CONFIG=0
WITH_ALIAS=0
BUN_OVERRIDE="${BUN:-}"
INTERACTIVE=1

usage() {
	cat <<'EOF'
Usage: install.sh [options]

  --omp-dir PATH        OMP state/config root (default: ~/.omp)
  --checkout PATH       Patch an existing oh-my-pi v19.2.1 source checkout
  --profiles LIST       Profiles: "all", "none", indexes/names ("1,3", "codex")
  --yes                 Non-interactive defaults (all profiles, keep existing YAML)
  --force               Replace existing subscription-usage.yml (timestamped backup)
  --no-config           Install the patched runtime only; write no profile YAML
  --no-deps             Skip `bun install` (node_modules already prepared)
  --alias               Add an `omp` shell function for bash/zsh pointing at the launcher
  --bun PATH            Bun executable to use
  --help                Show this help

Environment:
  OMP_DIR                      Default OMP root
  OMP_SUBSCRIPTION_USAGE_HOME  Patched source + artifacts (default: ~/.local/share/omp-subscription-usage)
  BIN_DIR                      Launcher directory (default: ~/.local/bin)
  OMP_TAG                      Upstream tag (default: v19.2.1)
  OMP_SUB_REF                  GitHub ref for downloaded artifacts (default: main)
  BUN                          Bun executable

Examples:
  curl -fsSL https://raw.githubusercontent.com/DoctorBlackZ33/omp-subscription-usage/main/install.sh | bash
  ./install.sh --omp-dir ~/.omp --profiles codex,work
  ./install.sh --checkout ~/src/oh-my-pi --profiles all --yes
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--omp-dir)
			OMP_DIR="${2:?--omp-dir needs a path}"
			shift 2
			;;
		--checkout)
			CHECKOUT="${2:?--checkout needs a path}"
			shift 2
			;;
		--profiles)
			PROFILE_SELECTION="${2:?--profiles needs a list}"
			shift 2
			;;
		--yes | -y)
			ASSUME_YES=1
			shift
			;;
		--force)
			FORCE=1
			shift
			;;
		--no-config)
			NO_CONFIG=1
			shift
			;;
		--no-deps)
			SKIP_DEPS=1
			shift
			;;
		--alias)
			WITH_ALIAS=1
			shift
			;;
		--bun)
			BUN_OVERRIDE="${2:?--bun needs a path}"
			shift 2
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

say() { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ "$ASSUME_YES" = "1" ] && INTERACTIVE=0
if [ "$INTERACTIVE" = "1" ] && { [ ! -r "$TTY" ] || [ ! -w "$TTY" ]; }; then
	INTERACTIVE=0
fi

ask() {
	local prompt="$1" default="${2:-}" answer=""
	if [ "$INTERACTIVE" != "1" ]; then
		printf '%s' "$default"
		return
	fi
	printf '%s' "$prompt" >"$TTY"
	IFS= read -r answer <"$TTY" || answer=""
	[ -z "$answer" ] && answer="$default"
	printf '%s' "$answer"
}

confirm() {
	local answer
	answer="$(ask "$1 [Y/n] " "y")"
	case "$answer" in
		y | Y | yes | YES) return 0 ;;
		*) return 1 ;;
	esac
}

expand_path() {
	local value="$1"
	case "$value" in
		"~") printf '%s' "$HOME" ;;
		"~/"*) printf '%s/%s' "$HOME" "${value#\~/}" ;;
		*) printf '%s' "$value" ;;
	esac
}

looks_like_omp_root() {
	[ -d "$1/agent" ] || [ -d "$1/profiles" ] || [ -f "$1/agent/config.yml" ] || [ -f "$1/agent/agent.db" ]
}

# ---------------------------------------------------------------- artifacts --
ROOT=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	CANDIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	if [ -f "$CANDIDATE/$PATCH_REL" ] && [ -f "$CANDIDATE/$EXAMPLE_REL" ]; then
		ROOT="$CANDIDATE"
	fi
fi

need_curl() {
	command -v curl >/dev/null 2>&1 || die "curl is required to download installer artifacts"
}

fetch_artifact() {
	local rel="$1" dest="$2"
	if [ -n "$ROOT" ] && [ -f "$ROOT/$rel" ]; then
		cp "$ROOT/$rel" "$dest"
		return
	fi
	need_curl
	curl -fsSL "$RAW_BASE/$rel" -o "$dest"
}

# ------------------------------------------------------------------- locate --
say ""
say "ohm · subscription usage installer (oh-my-pi $OMP_TAG)"
say ""

if [ -z "$OMP_DIR" ] && [ "$DEFAULT_OMP_DIR" != "$HOME/.omp" ]; then
	OMP_DIR="$DEFAULT_OMP_DIR"
fi
if [ -z "$OMP_DIR" ] && [ -n "${PI_CONFIG_DIR:-}" ]; then
	case "$PI_CONFIG_DIR" in
		/*) OMP_DIR="$HOME$PI_CONFIG_DIR" ;;
		*) OMP_DIR="$HOME/$PI_CONFIG_DIR" ;;
	esac
fi
if [ -z "$OMP_DIR" ] && [ -n "${XDG_DATA_HOME:-}" ] && [ -d "$XDG_DATA_HOME/omp" ]; then
	OMP_DIR="$XDG_DATA_HOME/omp"
fi

if [ -z "$OMP_DIR" ]; then
	if [ -d "$DEFAULT_OMP_DIR" ]; then
		OMP_DIR="$DEFAULT_OMP_DIR"
		if [ "$INTERACTIVE" = "1" ]; then
			answer="$(ask "Found OMP directory: $OMP_DIR. Use it? [Y/n/custom] " "y")"
			case "$answer" in
				n | N | no | NO) OMP_DIR="" ;;
				c | C | custom | CUSTOM)
					OMP_DIR="$(expand_path "$(ask "OMP directory: " "$DEFAULT_OMP_DIR")")"
					;;
				*) : ;;
			esac
		fi
	else
		if [ "$INTERACTIVE" = "1" ]; then
			OMP_DIR="$(expand_path "$(ask "OMP directory not found at $DEFAULT_OMP_DIR. Enter path: " "$DEFAULT_OMP_DIR")")"
		else
			OMP_DIR="$DEFAULT_OMP_DIR"
		fi
	fi
else
	OMP_DIR="$(expand_path "$OMP_DIR")"
fi

[ -n "$OMP_DIR" ] || OMP_DIR="$DEFAULT_OMP_DIR"

# Convenience: a source checkout passed as the OMP directory selects the
# checkout; the state root falls back to the default.
if [ -z "$CHECKOUT" ] && [ -d "$OMP_DIR/packages/coding-agent" ]; then
	say "Detected an oh-my-pi source checkout at $OMP_DIR; using it as --checkout."
	CHECKOUT="$OMP_DIR"
	OMP_DIR="$DEFAULT_OMP_DIR"
fi

if ! looks_like_omp_root "$OMP_DIR"; then
	if [ "$INTERACTIVE" = "1" ]; then
		if confirm "$OMP_DIR does not look like an OMP directory (no agent/ or profiles/). Use it anyway?"; then
			mkdir -p "$OMP_DIR"
		else
			die "aborted"
		fi
	else
		mkdir -p "$OMP_DIR"
	fi
fi

say "OMP directory: $OMP_DIR"
if command -v omp >/dev/null 2>&1; then
	say "Installed omp binary found: $(command -v omp) (left untouched)"
fi

# ----------------------------------------------------------------- profiles --
PROFILE_NAMES=()
PROFILE_DIRS=()
add_profile() {
	PROFILE_NAMES+=("$1")
	PROFILE_DIRS+=("$2")
}
if [ -d "$OMP_DIR/agent" ]; then
	add_profile "default" "$OMP_DIR/agent"
fi
if [ -d "$OMP_DIR/profiles" ]; then
	for dir in "$OMP_DIR"/profiles/*/agent; do
		[ -d "$dir" ] || continue
		name="$(basename "$(dirname "$dir")")"
		add_profile "$name" "$dir"
	done
fi

if [ "${#PROFILE_NAMES[@]}" -eq 0 ]; then
	if [ "$INTERACTIVE" = "1" ] && [ "$NO_CONFIG" = "0" ]; then
		if confirm "No OMP profiles found. Create the default profile directory ($OMP_DIR/agent)?"; then
			mkdir -p "$OMP_DIR/agent"
			add_profile "default" "$OMP_DIR/agent"
		fi
	else
		mkdir -p "$OMP_DIR/agent"
		add_profile "default" "$OMP_DIR/agent"
	fi
fi

if [ "${#PROFILE_NAMES[@]}" -gt 0 ]; then
	say ""
	say "Profiles found:"
	for i in "${!PROFILE_NAMES[@]}"; do
		note=""
		[ -f "${PROFILE_DIRS[$i]}/config.yml" ] && note="config.yml"
		[ -f "${PROFILE_DIRS[$i]}/agent.db" ] && note="${note:+$note, }auth DB"
		say "  $((i + 1))) ${PROFILE_NAMES[$i]}  ${PROFILE_DIRS[$i]}${note:+  ($note)}"
	done
fi

selection="$PROFILE_SELECTION"
if [ "$NO_CONFIG" = "0" ] && [ "$INTERACTIVE" = "1" ]; then
	selection="$(ask "Apply the policy to which profiles? [all / none / 1,3 / names] (all): " "all")"
fi
[ -n "$selection" ] || selection="all"

SELECTED_NAMES=()
SELECTED_DIRS=()
select_index() {
	local idx="$1" dir
	[ "$idx" -ge 1 ] && [ "$idx" -le "${#PROFILE_NAMES[@]}" ] || return 1
	dir="${PROFILE_DIRS[$((idx - 1))]}"
	for existing in ${SELECTED_DIRS[@]+"${SELECTED_DIRS[@]}"}; do
		[ "$existing" = "$dir" ] && return 0
	done
	SELECTED_NAMES+=("${PROFILE_NAMES[$((idx - 1))]}")
	SELECTED_DIRS+=("$dir")
}
select_name() {
	local name="$1"
	for i in "${!PROFILE_NAMES[@]}"; do
		if [ "${PROFILE_NAMES[$i]}" = "$name" ]; then
			select_index "$((i + 1))"
			return 0
		fi
	done
	return 1
}
if [ "$NO_CONFIG" = "0" ]; then
	tokens="${selection//,/ }"
	for token in $tokens; do
		case "$token" in
			all | ALL | a)
				for i in "${!PROFILE_NAMES[@]}"; do select_index "$((i + 1))"; done
				;;
			none | NONE | n | 0) : ;;
			*-*)
				start="${token%-*}"
				end="${token#*-}"
				if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]] && [ "$start" -le "$end" ]; then
					for ((i = start; i <= end; i++)); do select_index "$i" || true; done
				else
					warn "Ignoring invalid range: $token"
				fi
				;;
			*)
				if [[ "$token" =~ ^[0-9]+$ ]]; then
					select_index "$token" || warn "No profile at index $token"
				else
					select_name "$token" || warn "Unknown profile: $token"
				fi
				;;
		esac
	done
	if [ "${#SELECTED_NAMES[@]}" -eq 0 ]; then
		if [ -n "$PROFILE_SELECTION" ] && [ "$PROFILE_SELECTION" != "none" ]; then
			die "No profile matched '$PROFILE_SELECTION'. Found: ${PROFILE_NAMES[*]:-none}"
		fi
		if [ "$INTERACTIVE" = "1" ] && confirm "No profiles selected. Install the runtime without writing any policy file?"; then
			:
		elif [ "$INTERACTIVE" = "1" ]; then
			die "aborted"
		fi
	fi
fi

# ------------------------------------------------------------ source/runtime --
mkdir -p "$INSTALL_ROOT"
PATCH="$INSTALL_ROOT/subscription-usage.patch"
EXAMPLE="$INSTALL_ROOT/subscription-usage.example.yml"
say ""
say "Preparing artifacts in $INSTALL_ROOT ..."
fetch_artifact "$PATCH_REL" "$PATCH"
fetch_artifact "$EXAMPLE_REL" "$EXAMPLE"
if [ -n "$ROOT" ]; then
	cp "$ROOT/install.sh" "$INSTALL_ROOT/install.sh" 2>/dev/null || true
elif command -v curl >/dev/null 2>&1; then
	curl -fsSL "$RAW_BASE/install.sh" -o "$INSTALL_ROOT/install.sh" 2>/dev/null || true
fi
if [ -f "$INSTALL_ROOT/install.sh" ]; then chmod +x "$INSTALL_ROOT/install.sh"; fi

if [ -n "$CHECKOUT" ]; then
	SRC="$(cd "$CHECKOUT" && pwd)"
	git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a git checkout: $SRC"
	DESCRIBED="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
	if [ "$DESCRIBED" != "$OMP_TAG" ]; then
		warn "$SRC is not exactly $OMP_TAG (found: ${DESCRIBED:-no exact tag}); the patch may not apply."
	fi
else
	SRC="$INSTALL_ROOT/oh-my-pi"
	if [ ! -d "$SRC/.git" ]; then
		command -v git >/dev/null 2>&1 || die "git is required"
		say "Cloning oh-my-pi $OMP_TAG into $SRC ..."
		git clone --depth 1 --branch "$OMP_TAG" https://github.com/can1357/oh-my-pi.git "$SRC"
	fi
fi

if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
	say "Applying subscription-usage patch ..."
	git -C "$SRC" apply "$PATCH"
elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
	say "Patch already applied; continuing."
else
	die "Patch does not apply to $SRC. Use a clean $OMP_TAG checkout."
fi

BUN_BIN="$BUN_OVERRIDE"
if [ -z "$BUN_BIN" ] || [ ! -x "$BUN_BIN" ]; then
	if command -v bun >/dev/null 2>&1; then
		BUN_BIN="$(command -v bun)"
	elif [ -x "$INSTALL_ROOT/.bun/bin/bun" ]; then
		BUN_BIN="$INSTALL_ROOT/.bun/bin/bun"
	else
		need_curl
		say "Installing Bun into $INSTALL_ROOT/.bun ..."
		curl -fsSL https://bun.sh/install | BUN_INSTALL="$INSTALL_ROOT/.bun" bash
		BUN_BIN="$INSTALL_ROOT/.bun/bin/bun"
	fi
fi
export PATH="$(dirname "$BUN_BIN"):$PATH"

if [ "$SKIP_DEPS" != "1" ]; then
	say "Installing workspace dependencies ..."
	(cd "$SRC" && "$BUN_BIN" install --frozen-lockfile)
fi

NATIVE_DIR="$SRC/packages/natives/native"
mkdir -p "$NATIVE_DIR"
NATIVE_PRESENT=0
for native_file in "$NATIVE_DIR"/*.node; do
	if [ -f "$native_file" ]; then
		NATIVE_PRESENT=1
		break
	fi
done
if [ "$NATIVE_PRESENT" = "1" ]; then
	say "Native bindings already present."
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
		say "Fetching prebuilt native bindings ($NATIVE_PKG@${OMP_TAG#v}) ..."
		TMP_NATIVE="$(mktemp -d)"
		trap 'rm -rf "$TMP_NATIVE"' EXIT
		(cd "$TMP_NATIVE" && "$BUN_BIN" add "$NATIVE_PKG@${OMP_TAG#v}" >/dev/null 2>&1)
		cp "$TMP_NATIVE"/node_modules/"$NATIVE_PKG"/*.node "$NATIVE_DIR"/
		rm -rf "$TMP_NATIVE"
		trap - EXIT
	else
		warn "No prebuilt native package for this platform."
		warn "Build them with: (cd \"$SRC\" && bun --cwd=packages/natives run build)"
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

# ------------------------------------------------------------------- config --
INSTALLED=()
SKIPPED=()
for i in "${!SELECTED_NAMES[@]}"; do
	name="${SELECTED_NAMES[$i]}"
	dir="${SELECTED_DIRS[$i]}"
	target="$dir/subscription-usage.yml"
	mkdir -p "$dir"
	if [ -f "$target" ]; then
		replace=0
		if [ "$FORCE" = "1" ]; then
			replace=1
		elif [ "$INTERACTIVE" = "1" ]; then
			answer="$(ask "Profile '$name' already has a policy. Replace it (timestamped backup kept)? [y/N] " "n")"
			case "$answer" in y | Y | yes | YES) replace=1 ;; *) replace=0 ;; esac
		fi
		if [ "$replace" != "1" ]; then
			SKIPPED+=("$name")
			continue
		fi
		cp "$target" "$target.bak.$(date +%Y%m%d%H%M%S)"
	fi
	cp "$EXAMPLE" "$target"
	INSTALLED+=("$name:$target")
done

# -------------------------------------------------------------------- alias --
install_alias() {
	shell_name="$(basename "${SHELL:-bash}")"
	case "$shell_name" in
		bash) rc="$HOME/.bashrc" ;;
		zsh) rc="$HOME/.zshrc" ;;
		*) rc="" ;;
	esac
	if [ -z "$rc" ]; then
		warn "Unsupported shell for --alias; add this manually:"
		say "  omp() { \"$LAUNCHER\" \"\$@\"; }"
		return
	fi
	if grep -q '>>> omp-subscription-usage >>>' "$rc" 2>/dev/null; then
		say "Alias already present in $rc"
		return
	fi
	{
		printf '\n# >>> omp-subscription-usage >>>\n'
		printf 'omp() { "%s" "$@"; }\n' "$LAUNCHER"
		printf '# <<< omp-subscription-usage <<<\n'
	} >>"$rc"
	say "Added an 'omp' function to $rc (open a new shell to use it)."
}
if [ "$WITH_ALIAS" = "1" ]; then
	install_alias
elif [ "$INTERACTIVE" = "1" ] && [ "$ASSUME_YES" = "0" ]; then
	answer="$(ask "Make 'omp' launch the patched runtime in new shells (shell function, stock binary untouched)? [y/N] " "n")"
	case "$answer" in y | Y | yes | YES) install_alias ;; esac
fi

# ------------------------------------------------------------------ summary --
VERSION="$("$LAUNCHER" --version 2>/dev/null | tail -1 || true)"
say ""
say "Installed patched oh-my-pi $OMP_TAG"
say "  source:   $SRC"
say "  launcher: $LAUNCHER"
say "  version:  ${VERSION:-unknown}"
if [ "${#INSTALLED[@]}" -gt 0 ]; then
	say "  policy written:"
	for entry in "${INSTALLED[@]}"; do say "    ${entry%%:*}: ${entry#*:}"; done
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
	say "  policy kept (existing): ${SKIPPED[*]}"
fi
say ""
if [ "$WITH_ALIAS" = "0" ]; then
	say "Run: $LAUNCHER"
	say "Select a profile with: $LAUNCHER --profile <name>"
	say "Then use /subscription-usage in the session."
else
	say "New shells: run 'omp' as usual. Current shell: $LAUNCHER"
fi
if [ -n "$ROOT" ]; then
	say ""
	say "Source installer: $INSTALL_ROOT/install.sh"
fi
