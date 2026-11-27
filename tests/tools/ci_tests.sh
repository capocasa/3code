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
# Categories run in parallel, except tty which runs last and alone:
# its PTY tests are scheduler-sensitive and starved when run against
# concurrently compiling categories on small runners (see run_testament).
# Each category is sequential inside testament.
#
# Usage: tests/tools/ci_tests.sh [global-timeout-secs] [categories...]
#   PER_TEST_SECS env overrides the per-test cap (default 720, 0=off).
#   SOAK=1 adds the four tty stress tests to the run (default: nightly only).
#   TTY_SHARD=i/n runs only tty subset i of n (duration-balanced by
#   parallel_tty.py); TTY_SHARD=none runs everything but tty. CI splits the
#   tty category across jobs this way; unset runs the whole suite here.
#   CORE_SHARD=i/n runs only balanced subset i of the non-tty units
#   (config fold, core fold groups, pooled files; shard_units.py).
set -u

# build/test-nimflags: extra nim flags for the test binary, one line.
# CI writes '-d:staticSsl' there (with OPENSSL_STATIC) on macOS/Windows
# so the test-spawned 3code needs no bundled openssl libs.
nimflags=''
[ -f build/test-nimflags ] && nimflags=$(cat build/test-nimflags)
sh tests/tools/build_binary.sh 3code src/threecode.nim $nimflags || exit $?

TIMEOUT_SECS=${1:-1500}
[ $# -gt 0 ] && shift
. "$(dirname "$0")/test_processes.sh"
WATCH_SECS=30
# 720, not 480: the caps keep pace with the slowest legitimate tests.
# 300 died to the tty stress test (~310s on 3 cores); 480 later died to
# the shakedown itself (651s local, longer on arm CI), which the cap
# killed mid-suite as an all-[OK]-then-exit-1 mystery. OSX already ran
# 720 for this class. The cap exists to catch hangs (no progress), which
# it still does.
PER_TEST_SECS=${PER_TEST_SECS:-720}

LOG=$(mktemp "${TMPDIR:-/tmp}/3code_testament.XXXXXXXX") || exit 1
SNAP=$(mktemp "${TMPDIR:-/tmp}/3code_watch.XXXXXXXX") || exit 1
FAILS=$(mktemp "${TMPDIR:-/tmp}/3code_fails.XXXXXXXX") || exit 1
cleanup() { rm -f "$LOG" "$SNAP" "$FAILS"; }
trap cleanup EXIT

snapshot() {
  for pid in $(descendants "$TID"); do
    ps -p "$pid" -o etime=,args= 2>/dev/null | sed 's/^/  /'
  done
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
        tests/*/test_*|*/tests/*/test_*) ;;
        *) continue ;;
      esac
      case " $(descendants "$TID" | tr '\n' ' ') " in
        *" $pid "*) ;;
        *) continue ;;
      esac
      secs=$(etime_secs "$et")
      if [ "$secs" -ge "$PER_TEST_SECS" ]; then
        echo "[watchdog] killed: $rest (pid $pid, ${secs}s > ${PER_TEST_SECS}s cap)" >>"$SNAP"
        kill_tree "$pid"
      fi
    done
}

echo "testament $* (timeout ${TIMEOUT_SECS}s, per-test cap ${PER_TEST_SECS:-off}s, log $LOG)"
# One testament invocation per category, run concurrently. `testament cat
# a b` does NOT select two categories: extra words are forwarded as
# per-test arguments and every test fails with "arguments can only be
# given if the '--run' option is selected".
# Every dispatch's exit code is accumulated: a function's status is its
# last command's, so an unrecovered `|| rc=1` on the non-tty batch was
# silently dropped whenever the tty batch passed (the false-green OSX
# rerun of run 38230677798).
run_testament() {
  rc_all=0
  if [ $# -eq 0 ]; then
    tty_shard=''; tty_skip=0
    case "${TTY_SHARD:-}" in
      '') ;;
      none) tty_skip=1 ;;
      */*) tty_shard="--shard $TTY_SHARD" ;;
      *) echo "ci_tests: TTY_SHARD wants i/n or none, got '$TTY_SHARD'" >&2
         return 2 ;;
    esac
    if [ -n "$tty_shard" ]; then
      soak=''
      [ "${SOAK:-0}" = 1 ] && soak='--include-soak'
      # $soak and $tty_shard are whole words. The Windows runner may
      # expose python only as `python`.
      py=python3
      command -v python3 >/dev/null 2>&1 || py=python
      # shellcheck disable=SC2086
      "$py" tests/tools/parallel_tty.py $soak $tty_shard \
        --timeout "${PER_TEST_SECS:-720}"
      return $?
    fi
    # Default selection: config and core folded, every other non-tty file
    # in one worker pool, then tty alone. Testament still owns each pooled
    # file's spec (matrix, disabled, exit codes), so coverage is unchanged;
    # folds trade per-file process isolation for one compile per group and
    # keep every assertion.
    # The tty PTY tests stay alone: they are scheduler-sensitive, and on
    # small runners (macos-15 is 3-core) concurrent compiles starve the
    # render threads, producing load-induced frame mismatches and
    # per-test-cap kills.
    files=''
    for d in tests/*/; do
      d=${d%/}
      [ "$d" = tests/tty ] && continue
      # config and core are folded below: 19 and 58 compiles -> 1 and 6.
      [ "$d" = tests/config ] && continue
      [ "$d" = tests/core ] && continue
      for f in "$d"/test_*.nim; do
        [ -f "$f" ] && files="$files $f"
      done
    done
    # Core's solo files stay per-file in the pool: the fold spec names
    # them, so the pool list cannot drift from the spec.
    for f in $(python3 tests/tools/fold_groups.py --list-solo core); do
      files="$files $f"
    done
    # The non-tty suite is a set of units: the config fold, each core
    # fold group, each pooled file. CORE_SHARD=i/n runs only balanced
    # subset i of n on this runner (shard_units.py over
    # tests/tools/core_times.txt); CI spreads the suite across jobs that
    # way. Every unit is in exactly one shard.
    units='config'
    for g in $(python3 tests/tools/fold_groups.py --list core |
              grep -v '^solo:' |
              sed -n 's/^\([a-z_][a-z_0-9]*\): .*/\1/p'); do
      units="$units core:$g"
    done
    if [ -n "${CORE_SHARD:-}" ]; then
      run_units=''
      owned=$(python3 tests/tools/shard_units.py "$CORE_SHARD" $units $files) \
        || return 2
      files=''
      for u in $owned; do
        case $u in
          config|core:*) run_units="$run_units $u" ;;
          *) files="$files $u" ;;
        esac
      done
      units="$run_units"
    fi
    # Config is proven green as one process (592 tests, 0 failures), so its
    # 19 files become one compile. Core folds into six domain groups, one
    # process each (1280 tests, 0 failures): grouping, not a single binary,
    # is what keeps cross-domain state apart.
    for u in $units; do
      case $u in
        config)
          python3 tests/tools/fold_category.py config \
            --timeout "${PER_TEST_SECS:-720}" || rc_all=1 ;;
        core:*)
          python3 tests/tools/fold_groups.py core --only "${u#core:}" \
            --timeout "${PER_TEST_SECS:-720}" || rc_all=1 ;;
      esac
    done
    if [ -n "$files" ]; then
      # Word-splitting is intentional: test paths contain no spaces.
      # Shard-owned files arrive longest first, so the pool's workers all
      # start on the heavy ones.
      python3 tests/tools/parallel_files.py \
        --timeout "${PER_TEST_SECS:-720}" $files || rc_all=1
    fi
    if [ "$tty_skip" = 0 ] && [ -n "$(ls tests/tty/t*.nim 2>/dev/null)" ]; then
      # The four stress tests are the soak tier: 287s together, a third of
      # the tty run. The per-change suite leaves them out; SOAK=1 (nightly)
      # runs them with the rest of the suite.
      soak=''
      [ "${SOAK:-0}" = 1 ] && soak='--include-soak'
      # $soak is one word or empty.
      python3 tests/tools/parallel_tty.py $soak --timeout "${PER_TEST_SECS:-720}" || rc_all=1
    fi
    return $rc_all
  else
    sh tests/tools/test_dispatch.sh categories "$@"
  fi
}
run_testament "$@" >>"$LOG" 2>&1 &
TID=$!
trap 'kill_tree "$TID"; exit 130' INT
trap 'kill_tree "$TID"; exit 143' TERM

timed_out=0
# Wall-clock deadline, not an iteration counter: each loop pass costs
# `sleep 5` PLUS the ps/pgrep watchdog work, and under runner load the
# passes stretch past 5s. A counted loop then fires the cap minutes late
# in wall time, GitHub's step timeout wins the race, and the run dies
# with no attribution (linux-amd64 bd105506: step killed at 65m12s while
# the "3600s" counter still read ~3320s).
deadline=$(($(date +%s) + TIMEOUT_SECS))
next_snap=$(($(date +%s) + WATCH_SECS))
while kill -0 "$TID" 2>/dev/null; do
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    timed_out=1
    {
      echo "[watchdog] global timeout after ${TIMEOUT_SECS}s; live test processes:"
      snapshot
    } >>"$SNAP"
    kill_tree "$TID"
    break
  fi
  kill_sluggish_tests
  if [ "$now" -ge "$next_snap" ]; then
    {
      echo "[watch $(date +%T)] live test processes:"
      snapshot
    } >>"$SNAP"
    next_snap=$((now + WATCH_SECS))
  fi
  sleep 5
done
sleep 2
wait "$TID"
rc=$?

echo "----- testament log (last 200 lines) -----"
tail -n 200 "$LOG"
echo "-----------------------------------------"
# Failure detail survives: the last-80-line tail lands mid-compile and
# cuts away every failure report. Two shapes to recover from the full
# log: single-test runs print a `Test "..." ... Output:` report right
# after the FAIL: line, while multi-test runs emit one unified diff per
# failing test (`diff --git .../diffStrings_*`) whose body carries the
# expected/gotten exitcodes and the test's whole stdout - assertion
# traces, [FAILED] blocks, frame dumps. Print both, verbatim.
print_failures() {
  # parallel_files.py's per-file report: the `FAIL path (rc=...)` line
  # plus its 40-line tail, up to the next runner line. Without this shape
  # a failing batch file's diagnosis (its own error output) never leaves
  # the runner - the arm64 sandbox failures were unactionable exactly so.
  sed 's/\x1b\[[0-9;]*m//g' "$LOG" | awk '
    /^\[[0-9]+\/[0-9]+\] FAIL / { inpar = 1 }
    /^\[[0-9]+\/[0-9]+\] PASS / { inpar = 0 }
    inpar                       { print; next }
    /^diff --git .*diffStrings_/ { indiff = 1 }
    indiff                     { print; if ($0 == "" && NR > 1) indiff = 0; next }
    /^Test "/                  { intest = 1 }
    intest                     { print; if ($0 ~ /^[ \t]*re[A-Z]/) intest = 0; next }
  ' > "$FAILS"
  [ -s "$FAILS" ] || return 0
  echo "----- failure detail -----"
  cat "$FAILS"
  echo "--------------------------"
}
echo "----- pass/fail summary -----"
sed 's/\x1b\[[0-9;]*m//g' "$LOG" |
  grep -aE 'PASS:|FAIL:|JOINED:|SKIP:|FAILURE!|Tests passed' | tail -n 250
echo "-----------------------------"
print_failures
if [ -s "$SNAP" ]; then
  echo "----- watchdog -----"
  cat "$SNAP"
  echo "--------------------"
fi

# Failure attribution as a workflow annotation: the failing tests and the
# watchdog state land in the run's check annotations, where they are
# readable from the UI and the API without downloading job logs.
emit_failure_annotation() {
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  # Head AND tail: a failing suite's diff body starts with hundreds of
  # [OK] lines, and the check failures sit at the end - a head-only cap
  # hides the very lines that name the break (the arm64 tty_functional
  # failure was all [OK] under the old 3000-char cap).
  {
    sed 's/\x1b\[[0-9;]*m//g' "$FAILS" "$SNAP" 2>/dev/null
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -aE 'FAIL:|FAILURE!|Tests passed' | tail -n 30
  } | sed 's/\x1b\[[0-9;]*m//g' > "$FAILS.txt"
  {
    head -c 2000 "$FAILS.txt"
    echo "[... snip ... every failed check: ...]"
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
      | grep -aE 'Check failed|\[FAILED\]|FAIL: ' | head -n 40
    echo "[... snip ...]"
    tail -c 1200 "$FAILS.txt"
  } | awk 'BEGIN{ORS="%0A"} {gsub(/%/, "%25"); print}' > "$FAILS.ann"
  printf '::error title=%s::%s\n' "$1" "$(cat "$FAILS.ann")"
}

if [ "$timed_out" -eq 1 ]; then
  echo "ERROR: testament timed out after ${TIMEOUT_SECS}s; attribution above."
  echo "Full log retained at $LOG"
  emit_failure_annotation "testament timed out after ${TIMEOUT_SECS}s"
  trap - EXIT
  exit 1
fi

if [ "$rc" -ne 0 ]; then
  echo "testament failed (exit $rc); full log retained at $LOG"
  emit_failure_annotation "testament failed (exit $rc)"
  trap - EXIT
  exit "$rc"
fi

exit 0
