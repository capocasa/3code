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

root=openssl-static
mkdir -p "$root/src"
cd "$root"

if [ ! -f version ]; then
  ver=$(curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
      https://www.openssl.org/source/ \
    | grep -oE "openssl-${series}\.[0-9]+\.tar\.gz" | sort -V | tail -1 \
    | sed -e 's/^openssl-//' -e 's/\.tar\.gz$//')
  [ -n "$ver" ] || { echo "no openssl $series.* release listed" >&2; exit 1; }
  echo "$ver" > version

  cd src
  for f in "openssl-$ver.tar.gz" "openssl-$ver.tar.gz.asc" pubkeys.asc; do
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "$f" \
      "https://www.openssl.org/source/$f"
  done

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
  # no-shared is the point; no-tests/no-docs keep the build short.
  ../../src/openssl-$ver/Configure "$conf" no-shared no-tests no-docs \
    --prefix="../../$target" --libdir=lib
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  make install_sw
fi

echo "openssl $ver static libs: $root/$target/lib"
