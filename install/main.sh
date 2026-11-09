#!/bin/sh
# 3code main-branch installer. Usage:
#   curl -fsSL https://3code.capocasa.dev/main/install | sh
#   curl -fsSL https://3code.capocasa.dev/main/install | sh -s -- "your first prompt"
# Versioned here; the site deploy (3code.capocasa.dev, rsynced by its
# publish.nims) serves the copy at https://3code.capocasa.dev/install.
set -eu

BIN_NAME="3code"
BASE_URL="https://3code.capocasa.dev/main/builds"
INSTALL_DIR="${THREECODE_INSTALL_DIR:-$HOME/.local/bin}"

c_red=""; c_green=""; c_yellow=""; c_dim=""; c_off=""
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  c_red=$(tput setaf 1); c_green=$(tput setaf 2); c_yellow=$(tput setaf 3)
  c_dim=$(tput dim 2>/dev/null || true); c_off=$(tput sgr0)
fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%swarning:%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

if [ "${THREECODE_ALLOW_ROOT:-}" = "" ] && [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  die "don't install 3code as root. Run this as your normal user.
       (if you really mean it: THREECODE_ALLOW_ROOT=1 curl https://3code.capocasa.dev/main/install | sh)"
fi

os_name=$(uname -s 2>/dev/null || echo unknown)
arch_name=$(uname -m 2>/dev/null || echo unknown)

case "$os_name" in
  Linux)
    case "$arch_name" in
      x86_64|amd64)        asset="3code-linux-amd64.tar.gz" ;;
      aarch64|arm64)       asset="3code-linux-arm64.tar.gz" ;;
      *) die "unsupported linux architecture: $arch_name (build from source: https://github.com/capocasa/3code)" ;;
    esac
    ;;
  Darwin)
    asset="3code-macos-universal.tar.gz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    die "windows shell install not supported. use PowerShell: irm https://3code.capocasa.dev/main/install.ps1 | iex"
    ;;
  *)
    die "unsupported OS: $os_name (build from source: https://github.com/capocasa/3code)"
    ;;
esac

if have curl; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif have wget; then
  fetch() { wget -q -O "$2" "$1"; }
else
  die "need curl or wget to download"
fi

variant=$(echo "$asset" | sed -e 's/^3code-//' -e 's/\.tar\.gz$//')
info "installing 3code main ($variant)"

url="$BASE_URL/$asset"
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t 3code)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM

fetch "$url" "$tmp/$asset"

# verify against the .sha256 published next to each archive when the
# build carried one (main builds publish them; old ones predate them)
if fetch "$url.sha256" "$tmp/$asset.sha256"; then
  want=$(awk '{print $1}' "$tmp/$asset.sha256")
  got=""
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$asset" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
  fi
  [ -n "$got" ] || die "need sha256sum or shasum to verify the download"
  [ "$got" = "$want" ] || die "checksum mismatch for $asset
       expected $want
       got      $got"
  info "checksum verified"
else
  warn "no checksum published for this main build; installing unverified"
fi

tar -xzf "$tmp/$asset" -C "$tmp"

src=$(find "$tmp" -type f -name "$BIN_NAME" -perm -u+x 2>/dev/null | head -n1)
[ -n "${src:-}" ] || src=$(find "$tmp" -type f -name "$BIN_NAME" 2>/dev/null | head -n1)
[ -n "${src:-}" ] || die "binary '$BIN_NAME' not found inside archive"

mkdir -p "$INSTALL_DIR"
dest="$INSTALL_DIR/$BIN_NAME"
install -m 0755 "$src" "$dest" 2>/dev/null || { cp "$src" "$dest" && chmod +x "$dest"; }

short_dest="$dest"
case "$dest" in "$HOME"/*) short_dest="~${dest#$HOME}" ;; esac
info "installed $short_dest"
say

case ":${PATH:-}:" in
  *":$INSTALL_DIR:"*) on_path=1 ;;
  *) on_path=0 ;;
esac

short_dir="$INSTALL_DIR"
case "$INSTALL_DIR" in "$HOME"/*) short_dir="~${INSTALL_DIR#$HOME}" ;; esac

if [ "$on_path" -eq 0 ]; then
  say "add $short_dir to PATH"
  say
fi

if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
  info "running: $BIN_NAME --interactive $1"
  if [ -t 0 ] || [ -e /dev/tty ]; then
    exec </dev/tty "$dest" --interactive "$@"
  else
    exec "$dest" --interactive "$@"
  fi
fi
