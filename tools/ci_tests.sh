#!/bin/sh
# CI test runner. Wraps `testament all` so the run keeps its native
# parallelism (one child process per tests/ category, launched together
# by execProcesses) but a single hung test can no longer mask the suite:
#
# - Output goes straight to a log file, never through a reader pipe.
#   A pipe's 64KiB buffer is what turns a hang into silence: PASS lines
#   stop mid-stream and everything after the hung test is invisible.
#   Writing to a file keeps every finished test visible.
# - A per-test watchdog kills any single test binary that exceeds
#   PER_TEST_SECS: testament reports it failed and moves on, so one
#   hang costs minutes, not the whole run. Snapshots name the culprit.
# - A global watchdog bounds the run (no GNU timeout needed; macOS and
#   git-bash have none) and a pass/fail summary is always printed, so
#   failures cannot fall outside a tail window.
#
# Categories run in parallel but each category is sequential inside
# testament: the tty PTY tests are scheduler-sensitive and starve when
# run against concurrently compiling categories on small runners.
#
# Usage: tools/ci_tests.sh [global-timeout-secs] [categories...]
#   PER_TEST_SECS env overrides the per-test cap (default 300, 0=off).
set -u

TIMEOUT_SECS=${1:-1500}
[ $# -gt 0 ] && shift
CATEGORIES=${*:-}
WATCH_SECS=30
PER_TEST_SECS=${PER_TEST_SECS:-300}

LOG=$(mktemp "${TMPDIR:-/tmp}/3code_testament.XXXXXXXX") || exit 1
SNAP=$(mktemp "${TMPDIR:-/tmp}/3code_watch.XXXXXXXX") || exit 1
cleanup() { rm -f "$LOG" "$SNAP"; }
trap cleanup EXIT

snapshot() {
  ps -eo etime,args 2>/dev/null |
    grep -E 'tests/[a-z]+/test_|build/3code_stub' |
    grep -v grep | sed 's/^/  /'
}

# ps etime comes as MM:SS, HH:MM:SS or D-HH:MM:SS. Each field goes through
# 10#N to strip zero padding: bare $((...)) reads 08/09 as invalid octal,
# aborts the arithmetic ("value too great for base") and leaves the
# watchdog comparing against an empty string instead of a number.
etime_secs() {
  t=$1; d=0
  case $t in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  case $t in
    *:*:*) h=${t%%:*}; r=${t#*:}; m=${r%%:*}; s=${r##*:} ;;
    *:*)  h=0; m=${t%%:*}; s=${t##*:} ;;
    *)    h=0; m=0; s=$t ;;
  esac
  printf '%s\n' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# Kill test binaries that exceed the per-test cap. The match is anchored
# to argv[0]: testament execs test binaries as "tests/<cat>/test_*", while
# compilers and other testament invocations only carry the path mid-args and
# must not be touched. Needs ps/pgrep; silently off on shells without them
# (git-bash), where the global timeout still applies.
kill_sluggish_tests() {
  command -v ps >/dev/null 2>&1 || return 0
  command -v pgrep >/dev/null 2>&1 || return 0
  [ "${PER_TEST_SECS:-0}" -gt 0 ] || return 0
  ps -eo etime=,pid=,args= 2>/dev/null |
    while read -r et pid rest; do
      case $rest in
        tests/*/test_*) ;;
        *) continue ;;
      esac
      secs=$(etime_secs "$et")
      if [ "$secs" -ge "$PER_TEST_SECS" ]; then
        echo "[watchdog] killed: $rest (pid $pid, ${secs}s > ${PER_TEST_SECS}s cap)" >>"$SNAP"
        kill -TERM "$pid" 2>/dev/null
        for c in $(pgrep -P "$pid" 2>/dev/null); do
          kill -KILL "$c" 2>/dev/null
        done
        ( sleep 5; kill -KILL "$pid" 2>/dev/null ) &
      fi
    done
}

echo "testament ${CATEGORIES:-all} (timeout ${TIMEOUT_SECS}s, per-test cap ${PER_TEST_SECS:-off}s, log $LOG)"
# One testament invocation per category, run concurrently. `testament cat
# a b` does NOT select two categories: extra words are forwarded as
# per-test arguments and every test fails with "arguments can only be
# given if the '--run' option is selected".
run_testament() {
  if [ -z "$CATEGORIES" ]; then
    testament --print --megatest:off all >>"$LOG" 2>&1
    return $?
  fi
  pids=""
  rc=0
  for cat_ in $CATEGORIES; do
    testament --print --megatest:off cat "$cat_" >>"$LOG" 2>&1 &
    pids="$pids $!"
  done
  for p in $pids; do
    wait "$p" || rc=1
  done
  return $rc
}
run_testament &
TID=$!

timed_out=0
elapsed=0
while kill -0 "$TID" 2>/dev/null; do
  if [ "$elapsed" -ge "$TIMEOUT_SECS" ]; then
    timed_out=1
    {
      echo "[watchdog] global timeout after ${TIMEOUT_SECS}s; live test processes:"
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
  kill_sluggish_tests
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
echo "----- pass/fail summary -----"
sed 's/\x1b\[[0-9;]*m//g' "$LOG" |
  grep -aE 'PASS:|FAIL:|JOINED:|SKIP:|FAILURE!|Tests passed' | tail -n 250
echo "-----------------------------"
if [ -s "$SNAP" ]; then
  echo "----- watchdog -----"
  cat "$SNAP"
  echo "--------------------"
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
