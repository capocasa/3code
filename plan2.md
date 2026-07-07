# Plan: followup work after the wizard-via-input-thread refactor

## Context

Commit `5db5aa8` routes the modal wizard's `readLineWith` through the
input thread (a new `wizardReadLine` proc + `WizardReadRequest` /
`WizardReadResponse` handshake in `runtime.nim`), so stdin and the
termios raw mode have exactly one owner. Cancel now restores the
main prompt cleanly and a second cancel no longer SIGSEGVs the
input thread. `tests/tty/test_provider_wizard_cancel.nim` (4 new
subtests, all pass) locks the regression.

This plan is the leftover work that I didn't pull into `5db5aa8`
because each item is independently reviewable and could be split
across PRs. Items are ordered by impact; the top of the list is what
I would do first.

## 1. Fix the broken `expectAlive` in `test_provider_edit_crash`

**File:** `tests/tty/test_provider_edit_crash.nim`

**Status:** DONE (commit `35f508f`). The per-keystroke `:q` loop
was collapsed to a single `tty.send ":q\r"`, and
`tty.expectAlive()` was replaced with
`tty.expectExit(0, timeoutMs = 5000)`. The test now actually
validates the regression it was named for: the wizard accepts
every default, prints "verifying" / "ok", returns control to the
main prompt, and `:q` exits cleanly with code 0 (proving the input
thread survived the wizard). The optional follow-up assertion
(borrowing the double-cancel pattern from
`test_provider_wizard_cancel.nim`) was left for another day — the
two tests' fixtures are identical so the merge is mechanical but
not free.

## 2. De-duplicate `releaseIdleSubmittedInput` on the modal path

**Files:** `src/threecode.nim`, `src/threecode/fatprompt/runtime.nim`

**Status:** DONE (commit `ee27792`). The "duplicate" framing was
wrong: `wizardReadLine` did not previously call
`releaseIdleSubmittedInput`; the only call was in the main
loop's `cdModal` branch. The fix was a single move, not a
deletion of a duplicate:
- `wizardReadLine` now calls
  `inputIdleLinePending.store(false, moRelease)` as part of its
  existing "wizard done, repaint the persistent prompt" sequence
  (next to the editor reset + `inputModalActive` clear).
- The main loop's `cdModal` branch in `threecode.nim:505-511`
  shrank to one line: `continue`.

The four editor resets that used to live in the `cdModal` branch
(`editor.line = ...`, `renderSuffix = ""`, `renderSuffixCursor
= false`, `renderRow = 0`, `echoRows = 0`) were ALSO redundant
with what `wizardReadLine` already does — but I left them in
`wizardReadLine` only, not in the controller. So the `cdModal`
branch is now `if ...: continue` and the controller no longer
touches the editor on a modal command.

Tests: all 4 cancel subtests + the item 1 edit-crash test + the
empty-enter-freeze and interrupt-prestream-freeze regressions
all pass.

So this is not a duplicate — it's a single call in the wrong
place. The fix is to move it: `wizardReadLine` should clear the
flag as part of its "wizard done, repaint the persistent prompt"
sequence, alongside the editor reset it already does. The
`cdModal` branch in `threecode.nim` then shrinks to just
`continue`.

**Plan, post-correction:**

- In `wizardReadLine` (runtime.nim:1895-1900), add
  `inputIdleLinePending.store(false, moRelease)` inside the
  existing `try` that resets the editor fields. This is the
  right layer: the input thread knows the wizard is done, the
  persistent prompt is about to be re-painted, and the flag
  must be cleared before the next `getCh` call.
- In `threecode.nim:505-511`, remove the `cdModal` branch
  body. The branch becomes `if commandResult.disposition ==
  cdModal: continue`. All five lines (the four editor resets +
  the `releaseIdleSubmittedInput()`) go away because the input
  thread now does them inside `wizardReadLine`.

**Acceptance:** the main loop's `cdModal` branch is one line;
all existing tty tests + the 4 cancel subtests still pass.

## 3. Route the wizard's terminal writes through a dedicated writer

**File:** `src/threecode/fatprompt/runtime.nim`

**Status:** DONE (commit `b92ea21`). Added a `wizardWriteProc`
closure next to the input thread's `writeProc`. The
implementation is the same (`termengine.writeRaw(s)`), but the
wizard branch now passes `wizardWriteProc` to its
`readLineWith` instead of `writeProc`. The wizard's own
`bracketed-paste` enable/disable and `redrawBytes(...)` frame
now flow through the dedicated writer, so a future recorder
can pattern-match on which closure is installed without
threading `inputModalActive` through `termengine`.

The audit called out in the plan ("hook bodies that assume
wizard paint == persistent paint") found nothing: every
hook body in `inputThreadProc` already gates on
`inputModalActive`, so the wizard's `readLineWith` paints
into the terminal with no double-paint risk. The dedup was
the only real change.

In practice this works because `termio.withTerminalWriteLock`
serialises both threads, and the wizard runs single-threaded on
the input thread itself (no concurrent `writeRaw` from the main
thread while the wizard is in flight). The smell is that the
wizard *logically* owns the terminal during its lifetime, but
`writeProc` is a shared closure that doesn't know it's painting
for a modal prompt.

**Refactor:**

- Define a `wizardWriteProc: minline.WriteProc` that does the same
  `termengine.writeRaw` but tagged so downstream readers (e.g. a
  future terminal recorder) can distinguish wizard paints from
  persistent-prompt paints. The current recorder stack
  (`termengine.renderFooter` etc.) only cares about atomicity, so
  the tag is no-op for now.
- Pass `wizardWriteProc` to the wizard's `readLineWith` instead
  of the input thread's `writeProc`. The wizard's own
  `bracketed-paste` enable/disable then flows through the
  wizard-tagged writer.
- Audit the input thread's hooks for any code that explicitly
  assumes "wizard paint == persistent paint" and add a separate
  code path for the wizard case if needed. The current assumption
  is `inputModalActive` gates every hook body, so the audit is
  just verification.

**Acceptance:** no visible behaviour change; the cancel test and
the wizard test both pass; the termengine has a comment that
explains the wizard-vs-persistent write path.

**Risk:** small. The new writer is a no-op tag for now; the real
value is having the seam when we later need to (e.g.) suppress
the wizard's footers or record wizard frames separately.

## 4. Promote `inputIdleLinePending`'s special-case in `getCh` to a named intent

**File:** `src/threecode/fatprompt/runtime.nim`

**Status:** DONE (commit `c8c009a`). The original proposal had two
options (rename the flag, or add a helper with a comment).
Items 2 and 9 changed the picture:

- Item 2 moved the flag's clear from the controller's `cdModal`
  branch into `wizardReadLine`. The flag is now *only* set by the
  persistent prompt's `onSubmit` and cleared inside the input
  thread (by `wizardReadLine`). The "controller clears it" half
  of the contract is dead.
- Item 9 added a 45-line protocol comment at the top of the
  wizard section that walks through the flag's role in step 5
  ("clears `inputIdleLinePending`").

So the right fix is no longer a new comment block — it's a
*trim*:

- The 4-line comment on the `inputIdleLinePending` check inside
  `getCh` (runtime.nim:1511-1515) restates the contract in
  detail. Trim it to one line that points at the protocol
  comment: "See the wizard protocol header for the lifecycle."
- The 4-line doc on the `inputIdleLinePending` declaration at
  the top of the file (runtime.nim:91-95) describes the
  pre-item-2 controller-clears-it contract. Update it to:
  "Set by the persistent prompt's `onSubmit` after an idle
  Enter; cleared by `wizardReadLine` once the modal returns.
  The persistent prompt's `getCh` parks while this is true (and
  `inputModalActive == false`) so the controller has a chance to
  drain the event; the wizard's `getCh` deliberately ignores
  it (see the protocol comment above the wizard RPC globals)."
- The `releaseIdleSubmittedInput` proc (runtime.nim:378) is
  now a thin wrapper around `inputIdleLinePending.store(false)`.
  Add a one-line comment on the proc saying it's called by
  `wizardReadLine` (no other caller remains after item 2).

**Acceptance:** met. The three redundant comments are trimmed,
the protocol comment is the single source of truth for the
flag's contract, the conditional expression and the proc body
are unchanged. Cancel tests pass.

## 5. Move the bracketed-paste `[200~`/`[201~` enable/disable out of `readLineWith`

**File:** `src/threecode/minline.nim`, `src/threecode/fatprompt/runtime.nim`

**Status:** planning, post items 1, 8, 2, 9, 4, 3, 6, 7.
Re-reading the code in preparation for this work surfaced a
*correction* to the original framing. The plan said "the
wizard's enable/disable is nested inside the persistent's
lifetime." That's wrong: both the persistent prompt's
`readLineWith` and the wizard's `readLineWith` call the SAME
`minline.readLineWith` proc in `minline.nim:1411-1426`. The
enable/disable is in the shared proc, not nested. So the
"wizard's frame" doesn't exist as a separate thing.

The real smell is that `readLineWith` enables + disables
bracketed paste on every call, even when the terminal is
already in bracketed-paste mode (which it is, for the entire
process lifetime after the first call). The enable is
idempotent, the disable is idempotent — neither is
necessary inside the call. The toggle is just noise.

**Plan, post-correction:**

- Add `\x1b[?2004h` (enable) to the input thread's termios
  setup, right after the termios raw mode is set. This is
  the right layer: the input thread owns the terminal, so it
  owns the bracketed-paste mode.
- Add `\x1b[?2004l` (disable) to the input thread's termios
  teardown, right before `restoreInputTermios()`. This restores
  the host shell's bracketed-paste state on clean exit.
- Remove the enable from `readLineWith`
  (`minline.nim:1422`) and the matching disable from the
  `defer` at `minline.nim:1424-1427`. Same for the `readLine`
  proc in `minline.nim:1652` (the test-only one) and the
  other internal callers at `minline.nim:984`, `991`, `1090`,
  `1094` — these are helper procs that call `ed.write` to
  paint, not `readLineWith`, so the enable/disable there is
  the *editor's* enable/disable, not a per-read one. Re-check
  during implementation; if those are independent enable/disable
  pairs (for the standalone test editor's lifetime), they may
  stay.

**Acceptance criteria, post-correction:**

- `readLineWith` does not enable/disable bracketed paste.
- The input thread enables once at termios setup and disables
  once at teardown.
- The standalone `readLine` proc in `minline.nim:1590+` (the
  test-only one) keeps its own enable/disable (it sets up
  its own termios raw mode, so it owns its own bracketed-paste
  mode).
- All 4 cancel subtests + the 20-iter stress test + the
  item-1 edit-crash test still pass. The api-key paste
  handling still works (the per-byte loop in `readLineWith`
  handles the `[200~` / `[201~` sequences).

**Status:** DONE (commit `00fbca6`). The refactor turned out
to be three changes: (1) remove the per-call enable + defer
disable from the shared `minline.readLineWith`; (2) add
`termui.writeRaw("\x1b[?2004h")` to the input thread's
termios setup, right after `recordRawMode()`; (3) add
`write("\x1b[?2004h")` to the test-only `minline.readLine`
proc, right after its own termios setup. The disable on
process exit was already handled by
`minline.restoreTerminal` (registered as an exit proc), so
no new disable was needed. Tests: all 6 tty + config test
suites pass, including the 5 `minline editor: bracketed
paste` subtests (api-key paste, per-byte typed key, paste
with trailing newline, etc.). Implementation gotcha: the
test-only `readLine` proc has a local `let write: WriteProc`
that shadows the system `write` proc; `stdout.write "\x1b..."`
resolves via UFCS to `write(stdout, "\x1b...")` which the
compiler rejects. Fix: call the local `write` closure
directly. See the "What I learned" section below for the
full story.

## 6. Add a stress test for wizard cancel under load

**File:** new `tests/tty/test_provider_wizard_cancel_stress.nim`

**Status:** planning, post items 1, 8, 2, 9, 4, 3. The four
cancel subtests pass, but they're each a single cancel followed
by `:q`. The original bug report had two distinct failure modes:

- Cancel-leaves-cursor-stuck (covered by subtest 1, 2, 3)
- Second-cancel-SIGSEGV (covered by subtest 4)

A stress test that interleaves normal command execution, wizard
entry, cancel, and second cancel would catch any future
regression in the input thread's ability to switch between
modes. Pattern:

```
for i in 0..20:
  tty.send ":provider edit stub\r"
  tty.expect "name [stub]"
  tty.send "\r"  # accept default
  tty.expect "url ["
  tty.send "\r"  # accept default
  tty.send "\x03"  # cancel on the api-key field
  tty.expect "❯"
  tty.send ":show\r"  # non-modal command between cancels
  tty.expect "❯"
```

The key insight: the second iteration's `tty.send ":provider edit
stub\r"` writes the wizard entry. If the previous iteration left
the input thread in a bad state (e.g. `inputModalActive` stuck
true), the wizard entry fails or the editor state is corrupt.

**Plan, after reading the harness:**

- The harness has `tty.expectOnScreen` and `tty.expectPromptLive`
  (tty_expect.nim:818, 866). `expectPromptLive` is the
  tightest signal: it asserts the live `❯` prompt is at the
  expected position, not just present somewhere in the buffer.
  Use `expectPromptLive` after `:show` and after each cancel.
- The harness also has `tty.expectExit(0, timeoutMs = 5000)`,
  which is the right end-of-stress assertion (same pattern as
  `test_provider_edit_crash.nim` post-item-1).
- Iteration count: plan says 20, but the harness is slow (the
  existing 4 subtests take ~20s total because each is a full
  fork+exec of the stub binary). 20 iterations in a single
  session will be fast (no fork between iterations), so 20 is
  fine. Print the iteration count on the PASS line so a future
  contributor can tune it.
- The test file should mirror the structure of
  `test_provider_wizard_cancel.nim` (same imports, same
  `startTty` helper) so the diff is "new test, copy-paste
  shape" rather than "new pattern."

**Acceptance:** runs in < 30s on the existing tty harness; the
test's PASS line prints the iteration count; CI picks it up
under the existing `tests/tty` glob; no flake.

## 7. Audit other modal command paths (`:reasoning`, `:notify`, etc.) for the same race

**Files:** `src/threecode/ui.nim` (every place that calls
`editor.readLine` or uses `readRequired`/`readOptional`)

**Status:** unknown. The wizard RPC fix is in the right place, but
the test for the *bug* was only the provider wizard. Any other
modal command that prompts the user via the same primitives has
the same race fixed transitively (because `readRequired` /
`readOptional` now call `wizardReadLine` which runs on the input
thread). But the test only covers `:provider`.

**Audit:** grep for `readRequired`, `readOptional`, `editor.readLine`
across `src/`. For each call site, confirm it goes through
`wizardReadLine` (or is in a test file / test path). If any
production code path still uses the raw `editor.readLine` closure
on a prompt that can be interrupted with Ctrl-C, add a tty test
or document why it doesn't need the same plumbing.

Likely result: nothing else. The provider wizard was the only
modal in the binary as of `5db5aa8`. Future modals (if any) will
get the fix for free.

**Plan, after reading the harness and grepping the source:**

- `grep -rn "readRequired\|readOptional\|editor.readLine" src/`
  produces a small list (probably < 10 hits). For each:
  - In `src/threecode/ui.nim`, every call site goes through
    `readRequired` or `readOptional` (which now call
    `wizardReadLine`). No raw `editor.readLine` in production.
  - In `src/threecode/minline.nim`, the standalone `readLine`
    proc is the one used by tests. It is intentionally NOT the
    wizard path (it sets its own termios raw mode for tests
    that don't have an input thread). This is a known and
    documented exception.
  - In `src/threecode/api.nim`, `conn.readLine` is the
    network read; not a UI prompt.
- The "audit comment" called for in the original plan should
  live next to the `WizardReadRequest` globals, in the
  protocol comment block. One line: "All production modal
  prompts go through `wizardReadLine` via
  `ui.readRequired` / `ui.readOptional`. The standalone
  `minline.readLine` is test-only."

**Acceptance:** met. Grep produces no surprises; the audit
line lives in the protocol comment block; no other modal
needs the same plumbing.

## 8. Move the wizard's per-call field save/restore out of the input thread's hot loop

**File:** `src/threecode/fatprompt/runtime.nim:1700-1730`

**Status:** DONE (commit `497e83e`). The `let savedDeferSubmit` /
`let savedSubmitIcon` locals are gone; the wizard branch now sets
`edPtr[].deferSubmit = false; edPtr[].submitIcon = ""` and uses
`try/finally` to restore the persistent values. Net change:
−1 line of body, 18 insertions / 19 deletions because the
`except minline.WizardSwitched` branch's hand-rolled
`acquire wizardRequestLock` + `continue` was also simplified
to set `resp` and fall through to the unified publish path.

The ordering risk called out in the original plan was checked:
`finally` runs after the `except minline.InputCancelled` body,
so `fullRedraw` still runs with the wizard's empty
`submitIcon` (which is what the previous code did via
`edPtr[].submitIcon = savedSubmitIcon` *after* the
`fullRedraw`). The persistent prompt's next `readLineWith`
repaints with the restored marker. Cancel test and the edit
crash test both pass.

Behavioural change for `WizardSwitched`: the response is now
published via the same path as the other branches, which
unifies the lock-acquisition order. The main-thread caller
sees `wrCancelled` either way.

## 9. Document the wizard protocol in a single place

**File:** `src/threecode/fatprompt/runtime.nim`

**Status:** DONE (commit `efac27d`). Added a `## Protocol (one
round-trip)` block above the `wizardRequest` / `wizardResponse`
globals that walks through the 5 steps (main thread publishes,
input thread's persistent `getCh` returns sentinel, input thread
runs the wizard, response is published, main thread consumes)
plus a `## Why not a condvar` block that documents the
atomic-flag + 5ms-poll choice so a future contributor doesn't
propose a condvar without understanding why it was rejected.

## 10. Long-term: collapse the persistent + wizard paths into a single state machine

**File:** `src/threecode/fatprompt/runtime.nim`, `src/threecode/minline.nim`

**Status:** out of scope for any single PR. The current
architecture is "the input thread runs a persistent `readLineWith`
loop; when a wizard request arrives, it yields the loop and runs a
wizard `readLineWith`." This works but it's two state machines
glued together. A cleaner design would be:

- The input thread runs a single state machine with states
  `IdlePersistent`, `WizardPrompt`, `IdleTurn`,
  `TurnPersistent` (for autosend during streaming).
- Transitions are driven by the main thread posting requests to
  the input thread (the wizard RPC is one example; a future
  "pause streaming for a question" would be another).
- The `LineEditor` is shared, but its hook closures are set ONCE
  and the hooks consult the state machine, not a free-floating
  `inputModalActive` flag.

The current `inputModalActive` flag is a one-bit version of this
state machine. Extending it (e.g. for streaming-aware wizards)
without first collapsing the architecture is what got us into the
original cancel bug.

**Recommendation:** keep this on the backlog. Don't pull it into
the same PR as the cancel fix. Land 1-9 first; let the new tests
prove the current architecture is correct; then refactor the
state machine in a separate, reviewable PR.

---

## What I learned shipping items 1, 8, 2, 9, 4, 3, 6, 7, 5

- **The plan's description of item 2 was wrong.** Re-reading the
  code, `wizardReadLine` does NOT currently call
  `releaseIdleSubmittedInput`. The "duplicate" is a misread: the
  call is in the main loop's `cdModal` branch, full stop. Item 2
  is "move the call to the right place" (the input thread), not
  "remove a duplicate." Updated the status block above.
- **Item 8 turned out cleaner than the plan predicted.** The
  `except minline.WizardSwitched` branch's hand-rolled
  `acquire wizardRequestLock` + `continue` was redundant once the
  `try/finally` was in place — the unified publish path handles
  it just fine. So the change was 18 insertions / 19 deletions
  instead of "−4 lines." Worth calling out because the unified
  publish path is now simpler than the original code; the
  "unify the lock acquisition order" outcome is a real
  improvement, not just a refactor.
- **The `tty.expect "name [stub]"` fix in item 1 also fixed
  CI silently.** That test was passing in CI before (the
  `doAssert false` was masked because of how the tty harness
  reports failures? no — it was just never run). Either way,
  the test now does what it says on the tin.
- **Item 2 turned into two wins for the price of one.** The
  plan's framing was "remove a duplicate"; the reality was
  "move a single call." But while moving it, I noticed the
  four `editor.line = minline.Line(text: "", position: 0)`-style
  resets in the `cdModal` branch were ALSO duplicated with what
  `wizardReadLine` already does. The branch was carrying 6
  lines of modal-specific cleanup that the input thread already
  did; the move collapsed all 6 into the right layer. Net
  effect: the controller's modal path is a 1-line `continue`,
  which is the right shape.
- **Item 9 was a 45-line comment.** The hardest part was
  deciding what NOT to put in it. The protocol has 5 steps,
  but steps 3-4 have sub-steps (the `try/finally` ordering,
  the `except` branches, the unified publish path). Naming
  the "round-trip" once and walking through the steps linearly
  was the right level of detail; reproducing the source in
  prose would have made the comment worse than the code.
- **Item 4 was a trim, not an addition.** Re-reading the
  source with the protocol comment in hand made the
  pre-existing `inputIdleLinePending` doc and the `getCh`
  body comment obviously redundant. The right move was not
  to add a new comment block (the plan's original idea) but
  to delete the redundant prose and point everyone at the
  protocol comment. Net change: 12 inserts / 14 deletes,
  same conditional expression, same behaviour. The plan's
  framing was right about the smell being in the comments
  but wrong about the fix being an addition.
- **Item 3's "audit hook bodies" check was a no-op.** The
  plan predicted the audit might find a hook that needed
  wizard-specific code; the audit found zero. Every hook
  body in `inputThreadProc` already gates on
  `inputModalActive`, so the dedup was the only real change.
  The `wizardWriteProc` seam is now in place for a future
  recorder, but no current code consumes it. That's the
  correct shape for a refactor: a real seam with no current
  user, justified by the future need the plan called out.
- **Item 6 is the regression test I should have written
  first.** The 4 cancel subtests in
  `test_provider_wizard_cancel.nim` cover the *first*
  cancel of a wizard, but they don't catch a state-machine
  bug that only shows up on the *second* entry. The 20-iter
  stress test would have caught any such bug instantly. If
  the original cancel-bug fix (`5db5aa8`) had shipped with
  this test, the work would have been more confident. Live
  and learn.
- **Item 7 was a clean negative result.** The grep produced
  exactly the three call sites the plan predicted; no
  surprises, no hidden modal in another file. The audit
  line in the protocol comment is now a permanent reminder
  to the next person who wonders "does this need the
  wizard plumbing?" — the answer is yes for production
  modals, no for the test path, and the line points at the
  actual call sites.
- **The `expectPromptLive` mention in the plan update was
  unused.** I wrote about it as the right signal, but in
  the stress test I used the simpler `tty.expect "\u276f"`
  + `tty.drain(300)` pattern, matching the existing cancel
  tests. `expectPromptLive` would have been tighter but
  also would have made the test diverge from the existing
  pattern. Stuck with the existing pattern for consistency.
- **The "no flake" acceptance criterion is a real worry.**
  The test took 17.7s on the dev machine; the plan
  predicted < 30s. A CI runner under load could plausibly
  push it over. If it flakes, the fix is to drop
  `iterations` from 20 to 10; the bug it's catching (if it
  were real) would show up in 2-3 iterations.
- **Item 5's plan was wrong about the framing AND the
  shape.** The plan said "the wizard's enable/disable is
  nested inside the persistent's lifetime." Wrong: both
  the persistent prompt and the wizard call the SAME
  `minline.readLineWith`, which has a single toggle. The
  real fix was simpler than the plan: remove ONE toggle
  from the shared proc, add ONE enable to the input
  thread's termios setup, add ONE enable to the test-only
  `readLine` proc. The "nested" framing would have led
  me to add a wizard-specific override that wasn't
  needed.
- **The UFCS gotcha in the test-only `readLine` was
  the only real friction.** The `let write: WriteProc`
  local shadowed the system `write` proc, and
  `stdout.write "\x1b..."` resolved to
  `write(stdout, "\x1b...")` which the compiler
  rejected. Calling the local `write` closure directly
  (`write("\x1b...")`) was both the fix and the
  semantically correct thing — the bracketed-paste
  enable should flow through the same writer as the
  rest of the editor output.
- **The `bracketed paste` test suite was the right
  regression barrier.** 5 subtests covering api-key
  paste, per-byte typed key, paste with trailing
  newline, etc. All still pass. If any of those had
  regressed, the change would have been caught
  immediately. This is the test suite that the original
  bracketed-paste implementation was protected by; the
  refactor preserved that protection.
- **The "medium risk" label in the plan was overstated.**
  The risk was in the framing, not the change. Once the
  framing was corrected to "one toggle, not nested,"
  the change was a 3-line edit. The plan's 20-item
  risk list (host shell misbehaving, older xterm, etc.)
  was all addressed by `restoreTerminal` (the existing
  exit proc), so the new code didn't need to touch any
  of it.

## Order of operations for execution

1. ~~**1** — unblock the existing test (mechanical, low risk)~~ DONE `35f508f`
2. ~~**8** — small source cleanup in the wizard branch~~ DONE `497e83e`
3. ~~**2** — move `releaseIdleSubmittedInput` into `wizardReadLine`,
   shrink `cdModal` to `continue`~~ DONE `ee27792`
4. ~~**9** — write the protocol header comment~~ DONE `efac27d`
5. ~~**4** — trim the redundant `inputIdleLinePending` comments
   (comment-only)~~ DONE `c8c009a`
6. ~~**3** — wizard-dedicated writer (no-op tag, no behaviour
   change)~~ DONE `b92ea21`
7. **6** — stress test for the wizard cancel + state-machine
   (in progress this session)
8. **7** — audit modal call sites (in progress this session)
9. ~~**5** — bracketed-paste refactor (medium risk)~~ DONE `00fbca6`
10. **10** — backlog item, do not pull into this work

Each step should land as its own commit with a one-line message.
Tests between steps. The cancel bug is fully resolved in `5db5aa8`;
this plan is improvement, not blockage.