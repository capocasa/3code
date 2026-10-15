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

# OpenSSL release-signing key. This is the SIGNING SUBKEY fingerprint
# (of primary B146647E45A7B33947AB226B2A2C87D161692D40, canonical on
# openssl.org/source) because verification runs through gpgv, which
# reports the key that made the signature, not the primary. A rotation
# is a deliberate change here.
release_fp="C46ED3F2CBEFDA1FDAADA44264ED7B1DCCE71CB2"

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

  # gpgv, not gpg --import: the import path drags in an agent/keybox,
  # and on the Windows runner both candidates are unusable that way
  # (msys2's gpg exits 2 without a word; git-bash's hangs forever under
  # msys2 bash - it sat 90 minutes in run 38713657681). gpgv is the
  # unattended verifier apt-style tools use: no agent, no keybox.
  # gpgv rejects armored keyrings, so dearmor first - in pure shell
  # (awk+base64, byte-identical to gpg --dearmor) because every gpg on
  # the Windows runner is untrusted to even start.
  awk '/-----BEGIN PGP PUBLIC KEY BLOCK-----/{inblk=1;body=0;next}
       inblk&&body==0&&/^$/{body=1;next}
       inblk&&body==1&&/^-----END/{inblk=0;next}
       inblk&&body==1&&/^=/{next}
       inblk&&body==1{print}' pubkeys.asc > pubkeys.b64
  # BSD base64 (macOS) wants -D; GNU (linux, msys2, git-bash) wants -d.
  echo aGk= | base64 -d >/dev/null 2>&1 && b64d="base64 -d" || b64d="base64 -D"
  "$b64d" < pubkeys.b64 > pubkeys.gpg
  gpgv="${GPGV:-gpgv}"
  command -v "$gpgv" >/dev/null 2>&1 \
    || { echo "$gpgv not found; cannot verify the openssl tarball" >&2; exit 1; }
  # pubkeys.asc is itself downloaded, so the pin is enforced on the key
  # gpgv reports as having made the good signature - a substituted key
  # file cannot print the pinned fingerprint.
  sig=$("$gpgv" --keyring "$PWD/pubkeys.gpg" "openssl-$ver.tar.gz.asc" \
    "openssl-$ver.tar.gz" 2>&1 || true)
  printf '%s\n' "$sig" | grep -q "Good signature" \
    || { echo "openssl tarball signature not good:" >&2
         printf '%s\n' "$sig" >&2; exit 1; }
  fp=$(printf '%s\n' "$sig" | sed -n 's/.*using [A-Z0-9]* key //p' | head -1)
  printf '%s\n' "$fp" | grep -qix "$release_fp" \
    || { echo "openssl release key fingerprint mismatch: '$fp'" >&2; exit 1; }
  echo "fetch_openssl: $ver signature verified $(date +%T)" >&2

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
  echo "fetch_openssl: Configure done, make starting $(date +%T)" >&2
  make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  echo "fetch_openssl: make done $(date +%T)" >&2
  make install_sw
  echo "fetch_openssl: install_sw done $(date +%T)" >&2
fi

echo "openssl $ver static libs: $root/$target/lib"
