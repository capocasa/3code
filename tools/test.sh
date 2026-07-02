#!/usr/bin/env bash
# Parallel test runner for 3code.
#
# nimble test compiles every tests/test_*.nim sequentially, each recompiling
# the full src tree from scratch. On a cold cache that is minutes; this script
# compiles all tests in parallel and runs them, cutting wall time roughly in
# proportion to core count. Per-test Nim caches under ~/.cache/nim persist
# between runs the same way nimble's do, so warm reruns stay fast too.
#
# Usage:
#   tools/test.sh            compile + run all tests
#   tools/test.sh -j 4       override parallel job count (default: nproc)
#   tools/test.sh --compile  compile only, don't run
#   tools/test.sh test_foo test_bar   run only named tests
#
# Exit code is non-zero if any test fails to compile or run.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

jobs="$(nproc 2>/dev/null || echo 4)"
compile_only=0
filters=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j) jobs="$2"; shift 2 ;;
    --compile) compile_only=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) filters+=("$1"); shift ;;
  esac
done

paths=()
for pkg in unicodedb streamhttp ttty tinotify; do
  p="$(nimble path "$pkg" 2>/dev/null | head -1)"
  [[ -n "$p" ]] && paths+=("--path:$p")
done
paths+=("--path:$root/src")

outdir="$root/build/tests"
mkdir -p "$outdir"

tests=()
if [[ ${#filters[@]} -gt 0 ]]; then
  for f in "${filters[@]}"; do
    name="${f#tests/}"; name="${name%.nim}"
    tests+=("$name")
  done
else
  for f in tests/test_*.nim; do
    tests+=("$(basename "$f" .nim)")
  done
fi

# Platform detection
os="$(uname -s)"
is_windows=0
case "$os" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) is_windows=1 ;;
esac

# Some tests are platform-specific:
#   PTY tests (test_empty_enter_freeze, test_interrupt_prestream_freeze,
#     test_tty_functional) use forkpty/openpty which are Linux-only.
#     They also hang in GitHub Actions containers (no /dev/pts).
#   test_history, test_minline use ttty simulated terminal; escape
#     sequence handling differs on Windows (KEYSEQS expects _getch()
#     format 0xE0/0x00 vs POSIX ESC [).
#   test_api has two autosend probe tests that fail on Windows
#     (child process + threading issues).
filtered=()
for t in "${tests[@]}"; do
  case "$t" in
    test_empty_enter_freeze|test_interrupt_prestream_freeze|test_tty_functional)
      if [[ "$os" == "Linux" && -z "${CI:-}" ]]; then
        filtered+=("$t")
      fi
      ;;
    test_history|test_minline|test_api|test_session|test_streamexec)
      if [[ $is_windows -eq 0 ]]; then
        filtered+=("$t")
      fi
      ;;
    *)
      filtered+=("$t")
      ;;
  esac
done
tests=("${filtered[@]}")

compile_one() {
  local name="$1"
  nim c --noNimblePath -d:NimblePkgVersion=0.4.1 \
    "${paths[@]}" \
    --hints:off --warnings:off \
    -o:"$outdir/$name" "tests/$name.nim" \
    >"$outdir/$name.compile.log" 2>&1
}

run_parallel() {
  local name
  local running=0
  for name in "$@"; do
    compile_one "$name" &
    running=$((running + 1))
    if [[ $running -ge $jobs ]]; then
      wait
      running=0
    fi
  done
  wait
}

echo "[test] building 3code binary..."
t0=$(date +%s.%N)
nim c --noNimblePath -d:NimblePkgVersion=0.4.1 \
  "${paths[@]}" --hints:off --warnings:off \
  -o:"$root/3code" src/threecode.nim >"$outdir/3code.compile.log" 2>&1 || {
  echo "[test] failed to build 3code binary (log: $outdir/3code.compile.log)" >&2
  exit 1
}

echo "[test] compiling ${#tests[@]} tests with $jobs jobs..."
run_parallel "${tests[@]}"

failed_compiles=()
for name in "${tests[@]}"; do
  if [[ ! -x "$outdir/$name" ]]; then
    failed_compiles+=("$name")
  fi
done
if [[ ${#failed_compiles[@]} -gt 0 ]]; then
  echo "[test] ${#failed_compiles[@]} compile(s) failed:" >&2
  for name in "${failed_compiles[@]}"; do
    echo "  FAILED: $name (log: $outdir/$name.compile.log)" >&2
    echo "  --- compile log for $name ---" >&2
    cat "$outdir/$name.compile.log" >&2 || true
    echo "  --- end compile log ---" >&2
  done
  exit 1
fi
t1=$(date +%s.%N)
echo "[test] compiled in $(awk "BEGIN{printf \"%.1f\", $t1-$t0}")s"

if [[ $compile_only -eq 1 ]]; then
  echo "[test] --compile set, skipping run"
  exit 0
fi

fail=0
for name in "${tests[@]}"; do
  echo "[test] running $name"
  if ! "$outdir/$name"; then
    echo "[test] FAILED: $name" >&2
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  echo "[test] FAILURES present" >&2
  exit 1
fi
echo "[test] all green"
