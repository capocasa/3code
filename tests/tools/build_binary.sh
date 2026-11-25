#!/bin/sh
# One writer per output/cache. Nim validates dependencies on every invocation.
# A killed -9 builder leaves a lock: bounded waiting reports it, never steals it.
set -eu
[ "$#" -ge 2 ] || { echo 'usage: build_binary.sh OUTPUT SOURCE [nim flags...]' >&2; exit 2; }
out=$1; source=$2; shift 2
# --lock-timeout=N: seconds to wait for a foreign build lock (default 180).
lock_timeout=180
for arg in "$@"; do
  case $arg in
    --lock-timeout=*) lock_timeout=${arg#--lock-timeout=} ;;
  esac
done
set -- $(printf '%s\n' "$@" | grep -v '^--lock-timeout=')
# Git-bash callers pass Windows paths (`D:\a\...\out`). dirname/mv/nim want
# `/` separators, and a `D:` drive must not be mistaken for a relative path
# (that doubled it into `$PWD/D:\...`).
out=$(printf '%s' "$out" | tr '\\' '/')
case $out in
  /*) ;;
  [A-Za-z]:/*) ;;
  *) out="$PWD/$out" ;;
esac
mkdir -p "$(dirname "$out")"
# Up-to-date fast path, before taking the lock: a published binary is only
# rebuilt when an input is newer. Nim's nimcache makes the recompile cheap
# but still pays a full frontend+link pass; ensureStubBinary runs this per
# tty session (70 in test_tty_functional), which dwarfed the tests themselves.
# git checkout/pull set source mtimes to the change time, so newer-than-output
# is a sound staleness signal; a touched-but-unchanged file only costs a rebuild.
case " $* " in
  *--forceBuild*) ;;
  *)
    if [ -f "$out" ]; then
      inputs='src config.nims nimble.paths nimble.lock'
      [ -d tests/testdata/stub ] && inputs="$inputs tests/testdata/stub"
      if ! find $inputs -newer "$out" -print -quit 2>/dev/null | grep -q .; then
        exit 0
      fi
    fi
    ;;
esac
lock="$out.build-lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  waited=$((waited + 1))
  if [ "$waited" -ge "$lock_timeout" ]; then
    echo "Timed out waiting for $lock; check its owner before removing a stale lock" >&2
    exit 1
  fi
  sleep 1
done
printf '%s\n' "$$" > "$lock/owner"
staged="$out.pending"
cleanup() { rm -f "$staged"; rm -f "$lock/owner"; rmdir "$lock"; }
trap cleanup EXIT
compiler=''
stop() {
  if [ -n "$compiler" ]; then
    # Do not release ownership while the compiler is still writing.
    wait "$compiler" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'stop 130' INT
trap 'stop 143' TERM
# Keep the staging name stable: Nim's link cache includes its output path.
# The published inode is never linked into or truncated by the compiler.
nim c "$@" "--nimcache:$out.nimcache" "--out:$staged" "$source" &
compiler=$!
wait "$compiler"
compiler=''
mv -f "$staged" "$out"
