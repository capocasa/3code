#!/bin/sh
# Resolve, PGP-verify, and static-build the newest OpenSSL release of a
# pinned series. Used by the macOS and Windows packaging builds so the TLS
# stack is baked into the binary instead of shipped as dylibs/DLLs (issues
# #50, #53, #56; the Windows bundle had been EOL OpenSSL 1.1).
#
# Why latest-of-series instead of a pinned version: a static OpenSSL is
# frozen at build time, so the mechanism that keeps it fresh is resolving
# the newest patch release on every CI run. The series and the release-key
# fingerprint below are the conscious-bump pins; patch releases flow
# automatically. The tarball signature is verified so "latest" cannot
# silently become "whatever the CDN serves".
#
# usage: fetch_openssl.sh SERIES TARGET
#   SERIES  e.g. 3.5 (LTS; openssl.org/source lists one latest per series)
#   TARGET  darwin64-arm64 | darwin64-x86_64 | mingw64
# Leaves libssl.a/libcrypto.a in openssl-static/TARGET/lib and the resolved
# version in openssl-static/version. The source download is shared across
# targets (macOS builds two slices from one tarball).

set -eu

series=${1:?usage: fetch_openssl.sh SERIES TARGET}
target=${2:?targets: darwin64-arm64 darwin64-x86_64 mingw64}

# Current OpenSSL release-signing key (canonical fingerprint published on
# openssl.org/source; a rotation is a deliberate change here).
release_fp="B146647E45A7B33947AB226B2A2C87D161692D40"

here=$(pwd)  # Configure demands an absolute --prefix
root=openssl-static
mkdir -p "$root/src"
cd "$root"

if [ ! -f version ]; then
  # Resolve via the git tag list, not the website: openssl.org redirects
  # through openssl-library.org to GitHub assets and 404s some networks
  # (GitHub runner IPs included), while git transport and github.com
  # release downloads are reachable everywhere this runs. Anchored to a
  # plain X.Y.Z so prerelease tags (openssl-4.1.0-beta2) never match.
  ver=$(git ls-remote --tags https://github.com/openssl/openssl.git \
    | grep -oE "openssl-${series}\.[0-9]+$" | sort -V | tail -1 \
    | sed -e 's/^openssl-//')
  [ -n "$ver" ] || { echo "no openssl $series.* tag found" >&2; exit 1; }
  echo "$ver" > version

  cd src
  for f in "openssl-$ver.tar.gz" "openssl-$ver.tar.gz.asc"; do
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$f" \
      "https://github.com/openssl/openssl/releases/download/openssl-$ver/$f"
  done
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o pubkeys.asc \
    https://openssl-library.org/source/pubkeys.asc \
    || curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o pubkeys.asc \
      https://www.openssl.org/source/pubkeys.asc

  command -v gpg >/dev/null 2>&1 \
    || { echo "gpg not found; cannot verify the openssl tarball" >&2; exit 1; }
  gpg --import pubkeys.asc 2>/dev/null
  have=$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10}')
  printf '%s\n' "$have" | grep -qix "$release_fp" \
    || { echo "openssl release key fingerprint mismatch" >&2; exit 1; }
  gpg --verify "openssl-$ver.tar.gz.asc" "openssl-$ver.tar.gz"

  tar -xzf "openssl-$ver.tar.gz"
  cd ..
fi
ver=$(cat version)

case $target in
  darwin64-arm64)  conf=darwin64-arm64-cc;  export ZERO_AR_DATE=1 ;;
  darwin64-x86_64) conf=darwin64-x86_64-cc; export ZERO_AR_DATE=1 ;;
  # ZERO_AR_DATE: macOS ar stamps members with wall-clock mtimes unless
  # told otherwise; the flag keeps the archives deterministic.
  mingw64)         conf=mingw64 ;;
  *) echo "unknown target: $target" >&2; exit 1 ;;
esac

if [ ! -f "$target/lib/libssl.a" ]; then
  rm -rf "build/$target"
  mkdir -p "build/$target"
  cd "build/$target"
  # git-bash (Windows runners) ships a minimal perl without the core
  # modules Configure needs; prefer a complete one if the default is
  # gutted. No-op where the system perl is fine (macOS, Linux).
  if ! perl -MLocale::Maketext::Simple -e 1 >/dev/null 2>&1; then
    # msys2's perl, not Strawberry: a native-Windows perl would receive
    # msys-style paths (/d/a/...) it cannot resolve. The image ships
    # C:\msys64; git-bash shares its path conventions.
    for cand in /c/msys64/usr/bin; do
      if [ -x "$cand/perl" ] \
          && "$cand/perl" -MLocale::Maketext::Simple -e 1 >/dev/null 2>&1; then
        PATH="$cand:$PATH"; export PATH
        break
      fi
    done
  fi
  # no-shared is the point; no-tests/no-docs keep the build short.
  # Invoked through `perl` (not the shebang) so the PATH fix above holds.
  perl ../../src/openssl-$ver/Configure "$conf" no-shared no-tests no-docs \
    --prefix="$here/$root/$target" --libdir=lib
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  make install_sw
fi

echo "openssl $ver static libs: $root/$target/lib"
