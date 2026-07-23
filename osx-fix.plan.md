# Plan: re-enable tty tests on macOS and verify via OSX CI

## Context

The tty PTY tests are currently `disabled: "osx"` in 18 test files
(`grep -rln 'disabled: "osx"' tests/`). The skip comment on
`tests/tty/test_tty_functional.nim` says:

> On macOS the harness compiles but hangs deterministically: the expect*
> procs poll on wall-clock deadlines (plan-flakiness.md) and starve under
> the OSX runner's scheduler, so a subtest never returns. Re-enable after
> the frame-event sync rewrite lands.

**Key finding from the prior task** (commit 7b2a903): the plan's premise
that the failures were harness timing fragility was **partly wrong**. The
three tests that were red (`test_tty_functional.nim` x2, and
`test_slurp_resize_reasoning.nim`) were catching a **real, deterministic
rendering bug**: `eraseUp` in `src/threecode/engine.nim` did not count
`liveContentGapRows`, so a GUI repaint stranded a double blank row between
scrollback items. That is fixed; all 18 tty tests now pass deterministically
on Linux.

What remains UNVERIFIED is the OSX-specific claim: that `expect*` "polls on
wall-clock deadlines and starves under the OSX runner's scheduler." Reading
`tests/tty_expect.nim` now shows this comment is **stale**: `expect*`
already calls `waitForOutput` (line ~278), which is the signal-driven
primitive that blocks on `poll()` of the PTY fd + frame-event pipe rather
than busy-spinning. The wall-clock deadlines that remain are safety
timeouts (runaway guards), which is the correct design. So the harness may
already be OSX-safe; the skip was never re-evaluated after the
`waitForOutput` rewrite.

The OSX workflow (`.github/workflows/osx.yml`) runs on `macos-latest`,
builds a universal binary, and runs `testament --print --megatest:off all`.
It is triggered by `workflow_dispatch` (manual), push to `main`, and tags.
The OSX runs on `main` have been green recently, but only because every tty
test is skipped there.

## Goal

Re-enable the tty tests on macOS, push to a branch, manually trigger the
OSX workflow on that branch, watch it with `gh`, and fix whatever fails.
The branch must not be merged to main until OSX is confirmed green, since
re-enabling the tests on main would make main's OSX runs go red if they
fail.

## Steps

- [ ] **1. Push the timing branch to GitHub.**
  `git push -u origin timing`. (The double-blank fix from the prior task is
  already committed on this branch at 7b2a903.)

- [ ] **2. Remove `disabled: "osx"` from the 18 tty test files.**
  These are the files matched by `grep -rln 'disabled: "osx"' tests/`. For
  each file, delete the `disabled: "osx"` line AND its preceding
  explanation comment ONLY if the comment is specific to that directive
  (e.g. the multi-line block on `test_tty_functional.nim`). Leave the
  `disabled: "win"` line and its comment (Windows skip is a separate,
  real concern: the harness uses openpty/fork/execv which is POSIX-only;
  see `docs/windows-testing.md`). Commit as a single one-liner.

- [ ] **3. Push the branch and manually trigger the OSX workflow on it.**
  `git push`; then
  `gh workflow run osx.yml --ref timing` (the workflow has
  `workflow_dispatch`, so it accepts a branch ref). Confirm the run started
  with `gh run list --workflow=osx.yml --limit 1`.

- [ ] **4. Watch the OSX run to completion via `gh run watch`.**
  `gh run watch <run-id>`. OSX runs take roughly 3-6 minutes based on the
  recent history. If a step fails, capture the log:
  `gh run view <run-id> --log-failed`.

- [ ] **5. If OSX fails: read the failure, fix root cause, push, re-trigger.**
  Most likely failure modes and their fixes:
    - A tty test hangs (the original "starves under scheduler" symptom):
      this would mean `waitForOutput` is not enough on OSX and the harness
      needs the deeper signal-driven rewrite from `plan-flakiness.md` step
      1. In that case, follow that plan's step 1 (make `expect*` block on
      the frame-event pipe first, fall back to wall-clock only as a safety
      net). Do NOT just raise timeouts (the existing plan explicitly forbids
      this; it masks the race).
    - A tty test fails an assertion (real OSX rendering difference): fix
      the rendering in `src/`, do not loosen the test or change fixtures
      unless the fixture genuinely encodes platform-specific wrong
      behavior.
    - A compile error (OSX header/import difference): the harness already
      uses platform-conditional imports (`when defined(macosx)` for
      `<util.h>` vs `<pty.h>`); follow that pattern.
  Re-trigger after each fix: `gh workflow run osx.yml --ref timing`, watch
  again. Repeat until green. If a tty test hangs AND the signal-driven
  rewrite is too large for one iteration, fall back to re-disabling ONLY
  that one test on osx with a precise comment, but prefer the fix.

- [ ] **6. Once OSX is green: verify the run actually executed the tty
  tests** (not silently skipped).**
  Check the "Run tests" step log contains `[Suite]` / tty test names and
  `Tests passed or allowed to fail: N / N` with N including the tty files.
  A green run that skipped everything is not a success.

- [ ] **7. Final review.**
  `git diff main..timing` should show: the one-line engine fix (7b2a903),
  the `disabled: "osx"` removal across 18 files, and any OSX fixes from
  step 5. Confirm no `disabled: "osx"` remains anywhere in `tests/`
  (`grep -rn 'disabled: "osx"' tests/` returns nothing). Commit state
  should be clean. Report results; leave merging to main to the user
  (merging is a release-level action per ~/p/3CODE.md).

## Notes

- The OSX workflow is the ONLY way to verify macOS here; there is no local
  macOS box. The stefani VM referenced in AGENTS.md / `.agents/osx-testing.md`
  is not available in this environment. Do not guess about OSX behavior,
  verify via CI.
- `gh run watch` polls until the run finishes; use it rather than
  re-checking manually.
- If `workflow_dispatch` on a non-main branch is rejected by the workflow
  config, the fallback is to temporarily edit the workflow's `on:` to allow
  `workflow_dispatch` on the branch, but the current config
  (`workflow_dispatch:` with no `branches:` filter) already allows any
  branch.
- Do not touch the Windows (`disabled: "win"`) skips or the Linux/Windows
  workflows.
- The Linux CI workflows (`linux-amd64.yml`, `linux-arm64.yml`) should keep
  passing too; they already ran green locally (all 18 tty tests pass). If a
  push triggers them, confirm they stay green, but the OSX run is the gate
  for this task.
