# 3code Testing Improvement Plan

Goal: make the test suite strong enough that a lazy, hallucination-prone agent
(deepseek-class) cannot ship a behavioral regression without seeing it fail.

## CRITICAL CONTEXT (established by investigation)

The tty functional suite is **13/24 red on the current `testimp` branch, and
this is correct**. The 13 failures are real, live behavioral bugs:

  - **Scrollback overwrite bug**: committed scrollback rows (prompt echoes,
    replies) get erased by footer repaints as a turn progresses. The fixture
    `simple.txt` expects `❯ This is a test prompt` in 4 frames; the actual
    output keeps it in only ~1 of ~25 frames. Same root cause as the
    bug-hall-of-fame "first line dropped when footer shrinks".
  - **Queued/multiline concatenation**: echoes lose their newline separators
    (`second linequeued line one`).
  - **Queued prompt not reaching history** under various race windows.

**The fixtures are the source of truth and they are correct.** The 6
"golden drift" failures are NOT drift - they are the same bugs captured by the
golden files. Do not regenerate fixtures to match broken output. Do not treat
red tests as "flaky" - they are catching real bugs.

The task here is NOT to fix those bugs. It is to make the suite catch this
class of bug more loudly and more cheaply for a weak agent, so when deepseek
re-introduces one, the test fails with a focused, actionable message instead
of a wall-of-frames golden diff.

## What is already done

  [x] 0a. Isolate TMPDIR per fixture in all three spawned-process env builders
       (test_tty_functional.nim:133, test_empty_enter_freeze.nim:31,
       test_interrupt_prestream_freeze.nim:31). This STABILIZED the failure
       set: it was 13-14 nondeterministic, now it is a stable 13 across runs.
       Session lock files live in TMPDIR/3code/lock keyed by a
       second-resolution timestamp; without per-fixture TMPDIR isolation,
       back-to-back fixtures collided. Committed (unstaged) in working tree.

## Remaining work

### Phase 1: Assertion vocabulary (tests/tty_expect.nim only)

No source changes. All helpers added next to expectExit (line ~725).

  [x] 1a. expectAlive(s, msg="process exited unexpectedly") + expectPromptLive
  [x] 1b. countIn(s, text, where) + expectCount(s, text, n, where)
  [x] 1c. expectOnScreen(s, text, timeout) - grid-only match, no cleanRaw
  [x] 1d. promote framePresenceRuns (test_tty_functional.nim:150) into
       tty_expect.nim as expectRowAppearsOnce

### Phase 2: Thread assertions through tests

  [ ] 2a. expectAlive() after expect "..." in interrupt/command/model-edit tests
  [ ] 2b. expectCount(_, 1) on prompt echoes and replies
  [ ] 2c. expectNeverInHistory on half-typed text that must not commit

### Phase 3: Shakedown + failure messages

  [ ] 3a. consolidated shakedown test (prompt/reply, interrupt+resend,
       :model edit, multiline, :q exit)
  [ ] 3b. bug-class names in assertion failure messages

## Verification gate

A chunk is done when:
  - it compiles (`env -u CI tools/test.sh --compile` or building the one test)
  - the pre-existing 13 failures are unchanged (we are not fixing source bugs)
  - any NEW assertions added are demonstrably exercised

Do NOT regenerate golden fixtures. Do NOT weaken tests. Do NOT fix the source
bugs as part of this work (separate effort). The TMPDIR fix is the only
test-infra change; commit it first.

## Decisions

- No chunked plan files. Context clears decided ongoing.
- Golden brittleness: deferred, will be FIXED (not reduced) later. Current
  golden failures are real bugs, not brittleness.
- The 13 red tests stay red until the underlying source bugs are fixed in a
  separate effort. This plan only adds detection strength.
