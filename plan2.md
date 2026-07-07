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

**Status:** working but smelly. The flag is now set/cleared twice
on every modal command:

1. `wizardReadLine` (in `runtime.nim:1885-1895`) clears it as part
   of "wizard done, repaint the persistent prompt" — necessary
   because the wizard's own `getCh` deliberately ignores
   `inputIdleLinePending` while `inputModalActive == true` (the
   fix that broke the original deadlock), so the controller has to
   clear it on the way out.
2. The main loop's `cdModal` branch in `threecode.nim:505-511`
   also calls `releaseIdleSubmittedInput()` after the command
   returns — this is the original call site from before the
   refactor.

The second call is a no-op (both write `false`) but the
duplication is a smell that hints at a wrong layering: the
modal's "we're done" protocol now lives partly in the input
thread and partly in the controller.

**Two options, in order of preference:**

**(a) Make the input thread own the full lifecycle.** Move the
"clear the persistent prompt's input state" logic out of the
`cdModal` branch in `threecode.nim`. The input thread already
resets `editor.line`, `editor.renderSuffix`, etc. inside
`wizardReadLine` after the response is consumed, so by the time
the controller sees the `cdModal` return the editor is already
clean. The `cdModal` branch should just `continue` the main loop
(no `releaseIdleSubmittedInput`, no editor reset, no nothing
modal-specific — those happen inside the input thread's wizard
branch now).

Risk: the persistent prompt's next `readLineWith` happens on the
*next* outer-loop iteration, after `continue`. If the input
thread's "wizard is done, repaint the persistent prompt" hook
fires synchronously (it does — `wizardReadLine` resets the editor
synchronously before returning), the next `readLineWith` will see a
clean state. So this is safe.

**(b) Document the duplication and add an assertion** in
`releaseIdleSubmittedInput` that it is idempotent (which it is,
via the atomic store). Cheaper but leaves the smell.

**Recommendation:** (a). The input thread is the right layer; the
controller shouldn't need to know about modal-specific cleanup
anymore.

**Acceptance:** the controller's `cdModal` branch shrinks to
`continue`; all existing tty tests + the new cancel tests still
pass.

## 3. Route the wizard's terminal writes through a dedicated writer

**File:** `src/threecode/fatprompt/runtime.nim`

**Status:** functional but architecturally off. The wizard's
`readLineWith` reuses the input thread's `writeProc =
termengine.writeRaw` closure. The input thread's `postRedraw` hook
calls `termengine.finishEditorRedraw` which paints the footer +
sets `inputEditorReady`. The wizard has `inputModalActive == true`
so the hook returns early — good, no double-paint. But the
wizard's `bracketed-paste` enable bytes (`\x1b[?2004h` / `\x1b[?2004l`)
and the `redrawBytes(...)` frame still go through
`termengine.writeRaw` on the same path the persistent prompt
uses.

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

**Status:** works, but the condition is a head-scratcher on
re-read:

```nim
if inputIdleLinePending.load(moAcquire) and
   not inputModalActive.load(moAcquire):
  sleep(5)
  continue
```

The intent is: "park the persistent prompt while the controller
drains its just-submitted line; the wizard doesn't have an
idle-submit to park on, so it ignores the flag." The comment in
the source explains it, but a future reader is going to spend a
cycle going "but what about a wizard prompt submitted in flight?"

**Refactor:**

- Either rename the flag to something that reflects the
  persistent-prompt-only intent
  (`persistentPromptSubmittedPending`? `editorIdleEntered`? — both
  are bad, but a rename is better than nothing), OR
- Add a `parkedForController` helper that encapsulates the
  `and not inputModalActive` check, with a comment that explains
  the contract.

**Recommendation:** the second option, lighter touch. Add a
comment block at the top of `inputThreadProc` describing the
flag's contract: "Set by the persistent prompt's onSubmit after
an idle Enter; the controller is expected to clear it via
`releaseIdleSubmittedInput` once the `ieLine` event is drained.
The wizard's `readLineWith` does not set or honour this flag —
its lifecycle is short and it doesn't push events."

**Acceptance:** the source reads cleanly; the conditional
expression is unchanged. No tests need to move.

## 5. Move the bracketed-paste `[200~`/`[201~` sentinel out of the wizard's frame

**File:** `src/threecode/minline.nim`

**Status:** the wizard enables bracketed paste (`\x1b[?2004h`) at
the start of its `readLineWith` and disables it (`\x1b[?2004l`)
at the end via `defer`. The persistent prompt also enables and
disables it on every read. The wizard's enable/disable is nested
inside the persistent's lifetime, so we get a sequence like
`persistent-enable → wizard-enable → ... → wizard-disable →
persistent-disable` which is technically redundant. The disable
is idempotent (the terminal just stops looking for the sequence),
so this is correctness-safe but not clean.

**Refactor:** the wizard's `readLineWith` shouldn't toggle
bracketed paste if the persistent prompt already enabled it. The
cleanest fix is to lift the bracketed-paste enable to the input
thread's termios-raw-mode setup (it sets raw mode once on
`inputThreadProc` startup) and never disable it for the
process's lifetime. The hidden-input use case for the wizard
(api-key paste) still works because the per-byte loop in
`readLineWith` already handles the `[200~` / `[201~` sequence.

Risk: hosts that don't have bracketed-paste support (older
`xterm`s, some `screen` configs) get a stray `[?2004h` byte that
they ignore silently, so no behaviour change. The current code's
"disable in defer" exists to keep the host shell from misbehaving
on the next paste after the editor exits; that risk stays
mitigated because the persistent prompt still disables on its
own `defer`.

**Acceptance:** the persistent prompt's first read enables
bracketed paste once; the wizard's read doesn't toggle; the
process-lifetime terminal mode is correct. The hidden-input paste
test in `test_minline.nim` (if any) still passes; the API-key
wizard field still masks paste bursts as `*`s.

## 6. Add a stress test for wizard cancel under load

**File:** new `tests/tty/test_provider_wizard_cancel_stress.nim`

**Status:** the four cancel subtests pass, but they're each a
single cancel followed by `:q`. The original bug report had two
distinct failure modes:

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

**Acceptance:** runs in < 30s on the existing tty harness; the
test's PASS line prints the iteration count; CI picks it up
under the existing `tests/tty` glob.

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

**Acceptance:** a one-line audit comment in `runtime.nim` near
`wizardReadLine` stating which call sites are covered. No code
change if the grep comes up clean.

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

**Status:** the wizard RPC is split across three places: the
handshake globals near the top of the file, the `wizardReadLine`
proc in the middle, and the input thread's wizard branch in
`inputThreadProc`. A new reader has to scroll through ~250
lines to assemble the full picture.

**Refactor:** add a single header comment block at the top of the
file (or just above `wizardReadLine`) that describes the full
protocol in one place:

- Roles (main thread, input thread)
- State machine (request states: none → posted → in-flight →
  responded → consumed)
- Sync primitives (the lock is for the request/response struct,
  NOT for the flags; the flags are atomic)
- Sentinel mechanics (the `-2` returned by `getCh` and how it
  becomes `WizardSwitched`)
- Cancellation and timeout semantics
- Why a condvar wasn't used (we match the existing
  `releaseIdleSubmittedInput` style of atomic + 5ms sleep)

**Acceptance:** the file's top-of-file comment block reads as a
specification; a new contributor can read the protocol in one
place instead of cross-referencing three regions.

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

## Order of operations for execution

1. ~~**1** — unblock the existing test (mechanical, low risk)~~ DONE `35f508f`
2. ~~**8** — small source cleanup in the wizard branch~~ DONE `497e83e`
3. **2** — single-source the modal cleanup (small but touches the
   main loop)
4. **9** — write the protocol header comment (no code change)
5. **4** — clarify `inputIdleLinePending`'s contract (comment-only)
6. **3** — wizard-dedicated writer (no-op tag, no behaviour change)
7. **6** — stress test (catches any of the above's mistakes)
8. **7** — audit (likely no-op)
9. **5** — bracketed-paste refactor (medium risk)
10. **10** — backlog item, do not pull into this work

Each step should land as its own commit with a one-line message.
Tests between steps. The cancel bug is fully resolved in `5db5aa8`;
this plan is improvement, not blockage.