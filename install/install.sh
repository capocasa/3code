#!/bin/sh
# 3code installer. Recommended (download, read, then run):
#   curl -fsSLO https://3code.capocasa.dev/install
#   less install            # see for yourself what it does
#   sh install
# Or in one line, if you don't mind piping:
#   curl -fsSL https://3code.capocasa.dev/install | sh
#   curl -fsSL https://3code.capocasa.dev/install | sh -s -- "your first prompt"
# Versioned here; the site deploy (3code.capocasa.dev, rsynced by its
# publish.nims) serves the copy at https://3code.capocasa.dev/install.
set -eu

REPO="capocasa/3code"
BIN_NAME="3code"
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
       (if you really mean it: THREECODE_ALLOW_ROOT=1 sh install)"
fi

os_name=$(uname -s 2>/dev/null || echo unknown)
arch_name=$(uname -m 2>/dev/null || echo unknown)

case "$os_name" in
  Linux)
    case "$arch_name" in
      x86_64|amd64)        asset="3code-linux-amd64.tar.gz" ;;
      aarch64|arm64)       asset="3code-linux-arm64.tar.gz" ;;
      *) die "unsupported linux architecture: $arch_name (build from source: https://github.com/$REPO)" ;;
    esac
    ;;
  Darwin)
    asset="3code-macos-universal.tar.gz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    die "windows shell install not supported. download the zip: https://github.com/$REPO/releases/latest"
    ;;
  *)
    die "unsupported OS: $os_name (build from source: https://github.com/$REPO)"
    ;;
esac

if have curl; then
  fetch() { curl -fsSL "$1" -o "$2"; }
  fetch_stdout() { curl -fsSL "$1"; }
elif have wget; then
  fetch() { wget -q -O "$2" "$1"; }
  fetch_stdout() { wget -q -O - "$1"; }
else
  die "need curl or wget to download"
fi

# THREECODE_RELEASE_BASE overrides the release download base (mirrors,
# offline installs, the test suite); it must hold the archive and
# SHASUMS256.txt side by side and skips the GitHub tag resolution.
if [ -n "${THREECODE_RELEASE_BASE:-}" ]; then
  tag="release"
  url="$THREECODE_RELEASE_BASE/$asset"
  sums_url="$THREECODE_RELEASE_BASE/SHASUMS256.txt"
else
  # resolve tag from redirect - avoids the rate-limited GitHub API
  if have curl; then
    tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      "https://github.com/$REPO/releases/latest" | sed 's|.*/tag/||')
  elif have wget; then
    tag=$(wget -q --server-response --spider \
      "https://github.com/$REPO/releases/latest" 2>&1 \
      | grep -i 'Location:' | tail -1 | sed 's|.*/tag/||' | tr -d '\r ')
  fi
  [ -n "${tag:-}" ] || die "could not determine latest release tag"
  url="https://github.com/$REPO/releases/download/$tag/$asset"
  sums_url="https://github.com/$REPO/releases/download/$tag/SHASUMS256.txt"
fi

variant=$(echo "$asset" | sed -e 's/^3code-//' -e 's/\.tar\.gz$//')
info "installing 3code $tag ($variant)"
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t 3code)
trap 'rm -rf "$tmp"' EXIT INT HUP TERM

fetch "$url" "$tmp/$asset"

# verify the archive against the SHASUMS256.txt published with the
# release, so what lands in PATH is what was built and not what a MITM
# or a compromised mirror swapped in
file_sha256() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum;    then shasum -a 256 "$1" | awk '{print $1}'
  else echo ""; fi
}
if fetch "$sums_url" "$tmp/SHASUMS256.txt"; then
  want=$(grep " $asset\$" "$tmp/SHASUMS256.txt" | awk '{print $1}')
  [ -n "$want" ] || die "no checksum line for $asset in SHASUMS256.txt"
  got=$(file_sha256 "$tmp/$asset")
  [ -n "$got" ] || die "need sha256sum or shasum to verify the download"
  [ "$got" = "$want" ] || die "checksum mismatch for $asset
       expected $want
       got      $got"
  info "checksum verified"
elif [ "${THREECODE_ALLOW_UNVERIFIED:-}" = "1" ]; then
  warn "no SHASUMS256.txt published for $tag; installing unverified (THREECODE_ALLOW_UNVERIFIED=1)"
else
  die "no SHASUMS256.txt published for $tag (the release predates published checksums).
       set THREECODE_ALLOW_UNVERIFIED=1 to install anyway"
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
