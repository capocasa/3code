#!/bin/sh
# CI test runner. Wraps `testament all` so the run keeps its native
# parallelism (one child process per tests/ category, launched together
# by execProcesses) but a single hung test can no longer mask the suite:
#
# - Output goes straight to a log file, never through a reader pipe.
#   A pipe's 64KiB buffer is what turns a hang into silence: PASS lines
#   stop mid-stream and everything after the hung test is invisible.
#   Writing to a file keeps every finished test visible.
# - A shell watchdog (no GNU timeout dependency; macOS has none) bounds
#   the run. Snapshots of live test binaries go to a side file: the log
#   fd is shared with testament's children without O_APPEND, so writes
#   racing into the same file clobber each other. The side file is
#   merged only after the process tree is dead, which attributes a hang
#   to the exact test binary.
#
# Categories run in parallel but each category is sequential inside
# testament: the tty PTY tests are scheduler-sensitive and starve when
# run against concurrently compiling categories on small runners.
#
# Usage:
#   tools/ci_tests.sh [timeout-seconds] [categories...]
# With categories given, runs those categories (single testament child,
# sequential within the category); otherwise `testament all` (parallel).
set -u

TIMEOUT_SECS=${1:-1500}
[ $# -gt 0 ] && shift
CATEGORIES=${*:-}
WATCH_SECS=30

LOG=$(mktemp "${TMPDIR:-/tmp}/3code_testament.XXXXXXXX") || exit 1
SNAP=$(mktemp "${TMPDIR:-/tmp}/3code_watch.XXXXXXXX") || exit 1
cleanup() { rm -f "$LOG" "$SNAP"; }
trap cleanup EXIT

snapshot() {
  ps -eo etime,args 2>/dev/null |
    grep -E 'tests/[a-z]+/test_|tests/megatest|build/3code_stub' |
    grep -v grep | sed 's/^/  /'
}

echo "testament ${CATEGORIES:-all} (timeout ${TIMEOUT_SECS}s, log $LOG)"
if [ -n "$CATEGORIES" ]; then
  # shellcheck disable=SC2086
  testament --print --megatest:off cat $CATEGORIES >"$LOG" 2>&1 &
else
  testament --print --megatest:off all >"$LOG" 2>&1 &
fi
TID=$!

timed_out=0
elapsed=0
while kill -0 "$TID" 2>/dev/null; do
  if [ "$elapsed" -ge "$TIMEOUT_SECS" ]; then
    timed_out=1
    {
      echo "[watchdog] timeout after ${TIMEOUT_SECS}s; live test processes:"
      snapshot
    } >>"$SNAP"
    kill -TERM "$TID" 2>/dev/null
    sleep 5
    if command -v pkill >/dev/null 2>&1; then
      pkill -KILL -f 'tests/[a-z]+/test_' 2>/dev/null
      pkill -KILL -f 'build/3code_stub' 2>/dev/null
    fi
    kill -KILL "$TID" 2>/dev/null
    break
  fi
  if [ "$elapsed" -gt 0 ] && [ $((elapsed % WATCH_SECS)) -eq 0 ]; then
    {
      echo "[watch $(date +%T)] live test processes:"
      snapshot
    } >>"$SNAP"
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
sleep 2
wait "$TID"
rc=$?

echo "----- testament log (last 80 lines) -----"
tail -n 80 "$LOG"
echo "-----------------------------------------"
if [ -s "$SNAP" ]; then
  echo "----- process snapshots -----"
  cat "$SNAP"
  echo "-----------------------------"
fi

if [ "$timed_out" -eq 1 ]; then
  echo "ERROR: testament timed out after ${TIMEOUT_SECS}s; attribution above."
  echo "Full log retained at $LOG"
  trap - EXIT
  exit 1
fi

if [ "$rc" -ne 0 ]; then
  echo "testament failed (exit $rc); full log retained at $LOG"
  trap - EXIT
  exit "$rc"
fi

exit 0
