# Plan: get CI green (Linux first, then OSX, then Windows)

## Starting state (end of testament-migration session)

The testament migration is merged to main and works: tests run, parallelize
across category subdirs, and self-disable on Windows via `disabled: "win"`
specs. All three platforms were **already red before this work** (verified in
run history); the remaining failures are pre-existing test bugs now surfaced
cleanly by testament instead of being filtered by the deleted `tools/test.sh`.

Uncommitted on the worktree: `tests/tty_expect.nim` has the pty.h→util.h fix
(macOS `<util.h>` vs Linux `<pty.h>` for openpty/login_tty). Commit this.

## Linux failures (2 test files)

CI run 28655827236, job 84984528270. 32 of 33 pass; 2 files fail:

### 1. test_streamexec — "suppresses streaming callback after NUL byte"

**The symptom:** `lines was @["before", "\x00binary\x00garbage", "after"]`.
The test expects that after a NUL byte, no further lines reach the callback
(`"after" notin lines`). On CI, "after" leaked through.

**The code path:** `runStreamingBash` (src/threecode/streamexec.nim:293) calls
`readAvailableOutput` once. That proc holds a single `suppress` var across all
pipe chunks in the call. `feedOutputChunk` (line 61) sets `suppress = true`
on `'\x00'`. So in a single-call model, suppress should persist.

**The puzzle:** if suppress persists, "after" can't leak. The CI output proves
it did. Two hypotheses remain open:
  (a) **Chunk boundary + a second code path.** There may be a drain-after-exit
      path or a partial-line flush that re-enters emission with suppress
      already true but hits a branch that doesn't check it. Re-read
      `emitPartialLine` (line 73) and the post-exit drain loop (line 126) for
      any emission that bypasses the suppress guard.
  (b) **The CI shell's printf differs.** Unlikely (the repr shows real NULs)
      but worth a one-line probe: have the test log `rawOut.len` and whether
      any `'\x00'` was seen.

**Reproduces locally?** No — passes 3x isolated and under parallel load on this
machine. The CI runner is slower / differently scheduled. This is a real
correctness gap, not pure timing.

**Do NOT:** loosen the assertion, add a retry, or disable the test. It guards
binary-output suppression (a Windows pipe-layer false-positive fix).

### 2. test_tty_functional — intermittent subtest flakes

Already documented in `plan-flakiness.md` (frame-event sync fix). Different
subtest each run. This is the known harness timing defect, not a code bug.

## OSX failures (pre-existing; main was red before this work)

CI run 28655827170, job 84984528003. Failing files:
- `tests/tty/*` — `'pty.h' file not found`. **FIXED** by the uncommitted
  tty_expect.nim patch (util.h on macOS). Needs commit + verify the link step
  finds openpty (may need `-lutil`).
- `test_session`, `test_display` — XDG/path isolation: `draftPathFor` resolves
  to `/Users/runner/.config/3code/...` instead of the isolated tmpdir;
  `paths.len was 28` (real runner state leaks in). The setup blocks set
  `XDG_DATA_HOME` but `draftPathFor`/`getConfigDir` may read `XDG_CONFIG_HOME`
  or the real home. Root cause: incomplete XDG isolation in these tests' setup.
- `test_cli_args` — `3code -l` returns "no saved sessions" because the spawned
  binary uses the real config dir. Same isolation class.

## Windows failures (pre-existing; old script skipped them)

CI run 28655827253, job 84984528217. 18 of ~30 pass (tty correctly skipped via
spec). Failing files: test_api, test_cli_args, test_history, test_streamexec.
The old `tools/test.sh` skipped exactly these on Windows. **Restore the
equivalent coverage via `disabled: "win"` specs** on these 4 files — that
matches prior behavior without the bash filter. Document each in
docs/windows-testing.md.

## Execution order

1. **Commit the tty_expect.nim util.h fix** (uncommitted now).
2. **Linux: root-cause test_streamexec NUL** (hypothesis a above). This is the
   one real bug; fixing it likely fixes the Windows streamexec failure too.
3. **Windows: add `disabled: "win"` specs** to test_api, test_cli_args,
   test_history (test_streamexec addressed in step 2, re-check).
4. **OSX: fix XDG isolation** in test_session/test_display/test_cli_args setup
   blocks (set both XDG_DATA_HOME and XDG_CONFIG_HOME to the tmpdir; ensure
   the spawned `3code` binary inherits the isolated env).
5. Push, watch CI, iterate. tty flakes are expected until plan-flakiness.md
   lands; do not chase them per-run.

## Longcat-suitable tasks (bounded, mechanical, low reasoning risk)

- Add `disabled: "win"` specs to the 4 Windows tests (exact files known).
- Commit the util.h fix and verify OSX link.
These are explicitly: no assertion changes, no retries, no new skips beyond
the documented set.