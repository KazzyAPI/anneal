#!/usr/bin/env bash
#
# harness installer.
#
# Global (default):
#   curl -fsSL https://raw.githubusercontent.com/KazzyAPI/anneal/main/install.sh | sh
#
# Project-local (plug and play in a repo):
#   curl -fsSL .../install.sh | sh -s -- --project
#   # or from a local checkout:
#   HARNESS_REMOTE=file:///path/to/anneal/harness.sh ./install.sh --project
#
# Env overrides:
#   HARNESS_REMOTE   raw URL of harness.sh (default: latest GitHub release)
#   HARNESS_BIN      global install dir     (default: $HOME/.local/bin)
#   HARNESS_PROJECT  project install dir      (default: current directory)
#
set -eu

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

MODE="global"
PROJECT_DIR="${HARNESS_PROJECT:-$PWD}"

while [ $# -gt 0 ]; do
  case "$1" in
    --project|-p) MODE="project"; shift;;
    --global|-g)  MODE="global"; shift;;
    -h|--help)
      cat <<'EOF'
harness installer

Usage:
  install.sh              Install `harness` to ~/.local/bin (global)
  install.sh --project    Install harness.sh into a repo + run init (plug and play)

Env:
  HARNESS_REMOTE   Source URL for harness.sh (file:// for local dev)
  HARNESS_BIN      Global install directory
  HARNESS_PROJECT  Project directory (default: current directory)
EOF
      exit 0;;
    *) die "unknown option: $1 (try: install.sh --help)";;
  esac
done

REMOTE="${HARNESS_REMOTE:-https://github.com/KazzyAPI/anneal/releases/latest/download/harness.sh}"

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else die "need curl or wget"; fi
}

validate_script() {
  head -n1 "$1" | grep -q '^#!' || die "downloaded file is not a script"
  grep -q 'HARNESS_VERSION=' "$1" || die "downloaded file is not harness.sh"
}

install_payload() {
  local dest="$1"
  local tmp; tmp="$(mktemp)"
  say "Fetching harness from $REMOTE ..."
  fetch "$REMOTE" "$tmp" || die "download failed"
  validate_script "$tmp"
  cat "$tmp" > "$dest"
  chmod +x "$dest"
  rm -f "$tmp"
}

if [ "$MODE" = "project" ]; then
  TARGET="$PROJECT_DIR/harness.sh"
  [ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
  install_payload "$TARGET"
  ver="$("$TARGET" version 2>/dev/null || echo "harness")"
  ok_msg="Installed $ver -> $TARGET"
  say "$ok_msg"
  say "Initializing harness in $PROJECT_DIR ..."
  ( cd "$PROJECT_DIR" && "$TARGET" init )
  ( cd "$PROJECT_DIR" && "$TARGET" wire )
  ( cd "$PROJECT_DIR" && "$TARGET" doctor )
  say ""
  say "Ready. Run:  npm run harness:start   (or ./harness.sh start)"
else
  BIN_DIR="${HARNESS_BIN:-$HOME/.local/bin}"
  TARGET="$BIN_DIR/harness"
  mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
  install_payload "$TARGET"
  ver="$("$TARGET" version 2>/dev/null || echo "harness")"
  say "Installed $ver -> $TARGET"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say ""
       say "NOTE: $BIN_DIR is not on your PATH. Add this to your shell profile:"
       say "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
  say ""
  say "Next: cd into a repo and run:  harness init"
fi
