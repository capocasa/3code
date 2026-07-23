# Plan: fix tty-test timing fragility on the Linux CI runner

## Context

Three tty/PTY visual tests fail **consistently** on the GitHub Actions
Linux amd64/arm64 runners (Ubuntu 22.04, kernel `6.8.0-1062-azure`) while
passing on dev machines and being `disabled: "osx"` on macOS. They are
the wall-clock-deadline PTY harness tests, and they are red only since
the sandbox feature landed (which linked nimbox into the binary, growing
it and shifting startup/scheduler timing on the Linux runner). The
sandbox code itself is correct and unrelated; the failures are purely
the tty harness's timing sensitivity surfacing against a slightly
different binary on the Linux runner's scheduler.

The three failing assertions:

1. `tests/tty/test_tty_functional.nim:2051` - `consecutive turns never
   accumulate extra blank separator lines` - asserts `maxRun <= 1` (no
   two adjacent blank rows in idle scrollback). Fails with "2 consecutive
   blank rows at rows 11..12 (the extra-line bug)". This is the
   bar-tick-thread repaints-between-turns regression the test guards.
2. `tests/tty/test_tty_functional.nim:1652` - `bash tool success and
   nonzero exit` - `expectMeaningfulFrameArtifact` full-frame recording
   differs from the `bash_tool_visual_test.txt` fixture (linked to #1:
   the extra blank row desyncs the captured frames).
3. `tests/tty/test_slurp_resize_reasoning.nim` - `repeated SIGWINCH
   during spinner never wipes committed scrollback` - a resize/signal
   timing assertion that polls on wall-clock deadlines.

All three use the same underlying sync model: `tty_expect.nim`'s `expect*`
procs loop `while epochTime() < deadline`, polling the PTY master fd and
the frame-event pipe, committing frames on a sync boundary. The Linux
runner's scheduler slices this differently, so a render that lands "just
in time" locally lands "too late" on the runner, stranding a gap row or
missing a frame.

Key code locations:

- `tests/tty_expect.nim`
  - `expect*` loop: line ~278 (`while epochTime() < deadline`)
  - `pollOnce`: line ~210 (polls PTY fd + frame-event pipe)
  - `drain`: line ~291 (settle window, `settleMs` default 20ms)
  - frame commit gating: lines ~267-305 (SyncEnd-driven commits)
- `tests/tty/test_tty_functional.nim:1983` - the consecutive-turns test
  (the `maxRun <= 1` idle-frame scan)
- `tests/tty/test_tty_functional.nim:1545` - the bash-tool visual test
- `tests/tty/test_slurp_resize_reasoning.nim` - the SIGWINCH test
- Background on the model: `plan-flakiness.md` (the frame-event sync
  rewrite rationale) and the `disabled: "osx"` comments on these files.

The goal is NOT to make the tests pass by loosening assertions to the
point of uselessness. It is to make the harness **deterministic**: the
tests should assert real regressions (an extra blank row IS a bug) but
only fail when the bug is present, not when the runner's scheduler is
slow. The root fix is to replace wall-clock polling with explicit
synchronization so a frame is "done" when the child signals completion,
not when a timer happens to expire.

## Current state

Not begun. No steps attempted. The failing tests reproduce on every
Linux CI run; they pass locally and are skipped on macOS.

## Steps

- [ ] **1. Audit the sync model in `tty_expect.nim`.** Read the full
  `expect*` / `pollOnce` / `drain` / frame-commit path. Identify every
  wall-clock deadline (`epochTime() + timeoutMs`) and every place a
  frame is committed or sampled on a timer rather than on an explicit
  "frame done" signal. Record the list in this step's notes. This is a
  read-and-decide step: it scopes which deadlines can be made
  signal-driven and which are genuinely wall-clock (e.g. a runaway-child
  safety timeout that should stay).

- [ ] **2. Decide the synchronization contract.** Based on the audit,
  decide what "the child has finished rendering frame N" means: is there
  already a SyncEnd marker on the frame-event pipe (the comments at
  tty_expect.nim:267-305 suggest there is)? If so, the fix is to make
  `expect*` wait for the next SyncEnd rather than for a wall-clock
  settle. If SyncEnd only fires on some paths, design the minimal
  addition. Write the decision and its rationale here so it isn't
  relitigated. (Decision-only step.)

- [ ] **3. Make `expect*` and the idle-frame waiter signal-driven.**
  Rework the polling loop so screen-state `expect*` procs wait for a
  frame-event (SyncEnd) that carries the expected content, with a long
  safety deadline only as a runaway guard (not the primary sync). The
  consecutive-turns test's idle waiter (`test_tty_functional.nim:2036`
  block, `while epochTime() < idleDeadline`) must wait for the idle
  frame the same way. Verify locally that the three tests still pass on a
  fast machine and that deliberately introducing the extra-blank-row bug
  still fails them.

- [ ] **4. Fix or replace the `drain` settle window.** `drain(settleMs)`
  currently waits a fixed wall-clock window then samples. On a slow
  runner a render arriving just after the window is missed or split.
  Make `drain` wait for frame quiescence (no new frame events for N ms
  after the last one) rather than a flat window, so "settled" means the
  child stopped rendering, not "we ran out the clock". Keep the default
  settle short so fast machines aren't slowed.

- [ ] **5. Re-capture any fixture that becomes stale.** If the
  signal-driven harness changes which exact frames get committed for the
  bash-tool visual test, re-capture
  `testdata/fixtures/tty/bash_tool_visual_test.txt` from a known-good
  run. Confirm the fixture reflects correct rendering (no extra blank
  rows), not the broken timing. The consecutive-blank-row test must
  still catch the regression against the new fixture.

- [ ] **6. Add a CI-only flake-guard check (optional).** If, after the
  sync rewrite, residual non-determinism remains in the SIGWINCH test
  (signals are inherently racy), add a bounded retry or mark it
  `disabled: "linux"` with a comment matching the osx one, rather than
  leaving it intermittently red. Prefer the signal-driven fix first;
  only fall back to disable if signals genuinely can't be made
  deterministic.

- [ ] **7. Verify across platforms.** Run the full tty suite locally
  (Linux dev). Push to a branch and confirm the Linux + macOS CI runs
  go green. macOS currently skips these tests (`disabled: "osx"`); if
  the signal-driven fix makes them deterministic, consider re-enabling
  them on macOS too (remove the `disabled: "osx"` line) as a bonus, but
  only if CI confirms it.

- [ ] **8. Final review.** Re-read the full diff. Confirm no wall-clock
  deadline was silently kept where a signal exists, and no safety
  deadline was removed. Confirm each of the three tests now fails when
  its bug is reintroduced (inject the extra-blank-row path, the
  scrollback-wipe, the frame desync) and passes when correct. Commit
  clean.

## Notes

- The sandbox feature is NOT the cause of the bugs these tests guard; it
  is the trigger that exposed pre-existing harness timing fragility. Do
  not "fix" by reverting sandbox code or disabling the sandbox in the
  stub beyond what's already done.
- These tests already `disabled: "osx"` because of the same scheduler
  starvation. A real fix (signal-driven sync) would let them run
  everywhere; a give-up fix (disable on linux) is the fallback.
- The `backendWorks` probe fork (`sandbox.nim:backendWorks`) runs at
  startup in the non-stub binary; the stub skips it. Keep that
  separation - the stub is for rendering tests, not enforcement.
