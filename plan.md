# Plan: route modal wizard through the input thread

## Result

Implemented option A from the previous plan (stashed in `stash@{0}` /
committed in the dbg-print-only commit before this one). The modal
wizard's `editor.readLine` now runs on the input thread via a new
`wizardReadLine` proc, so stdin and the termios raw mode have exactly
one owner. Cancel restores the main prompt without leaving the cursor
on the wizard's first field, and a second cancel no longer SIGSEGVs the
input thread.

## What changed

- `src/threecode/types.nim` — `WizardReadRequest`,
  `WizardReadResultKind`, `WizardReadResponse`. The wizard RPC envelope
  is plain data so the main thread can publish a request without
  touching the input thread's `LineEditor` or its hook closures.
- `src/threecode/minline.nim` — new `wizardSentinel = -2` and
  `WizardSwitched` exception. `readLineWith` raises `WizardSwitched`
  when `getCh` returns the sentinel; the input thread catches it in
  its outer loop and starts the wizard's `readLineWith`.
- `src/threecode/fatprompt/runtime.nim`:
  - new globals: `wizardRequest`, `wizardResponse`,
    `wizardRequestPosted`, `wizardResponsePosted`, `wizardRequestLock`.
    The handshake is: main thread sets request, input thread clears
    request + sets response, main thread clears response.
  - new proc `wizardReadLine(editor, prompt, hidechars, noHistory)`:
    publishes a `WizardReadRequest`, parks the main thread on
    `wizardResponsePosted`, and either returns the submitted line or
    raises `minline.InputCancelled` / `EOFError`.
  - input thread's `getCh` returns the wizard sentinel while
    `wizardRequestPosted` is true, so the persistent `readLineWith`
    yields the editor to the modal wizard instead of competing for
    stdin. The persistent `getCh` does NOT honour the sentinel while
    the wizard's own `getCh` is in flight (it would cancel the
    wizard before the user typed a thing).
  - input thread's outer loop runs the wizard's `readLineWith` when
    `wizardRequestPosted` is set, publishes the response, and loops
    back. The wizard branch sets/clears `inputModalActive` around the
    wizard call; the existing hook bodies (`reserveEditorFooterForRedraw`,
    `finishEditorRedraw`, `onSubmit`) already gate on that flag.
  - `inputIdleLinePending` is ignored while a wizard is in flight
    (`inputModalActive == true`). The flag exists to park the
    *persistent* prompt while the controller drains its `ieLine`
    event; the wizard owns the editor instead, so the parking would
    deadlock the wizard's `getCh`.
- `src/threecode/ui.nim`:
  - `readRequired` / `readOptional` now call `wizardReadLine` (from
    `fatprompt`) instead of `editor.readLine`. The
    `wizardReadLineHook` test path is unchanged.
  - `handleCommandResult` for `ckModal` no longer saves/restores the
    editor's data fields or toggles `inputModalActive` — the input
    thread owns that flag and the input thread's wizard branch
    handles the field dance. Cancel propagates as
    `minline.InputCancelled` through `wizardReadLine` →
    `promptNewProvider` / `promptEditProvider` →
    `cmdProviderAdd` / `cmdProviderEdit`. `handleCommandResult`
    catches it and returns an empty `cdModal` (no message, no
    provider change). The prompt caret is repainted by the input
    thread's existing `except InputCancelled` handler.
  - `cmdProviderAdd` and `cmdProviderEdit` no longer need their own
    `try / except InputCancelled` blocks. The silent-cancel contract
    from the bug report comes "for free" because the controller
    catches and returns empty, and the input thread repaints.

## Why the existing test failed to catch this

`tests/tty/test_provider_edit_crash.nim` was the regression test
added in commit `1f9b712` for the previous segfault fix. Its
`expect "name \\[stub\\]"` patterns (and friends) have Nim string
escapes that turn into literal `name \[stub\]` (with a backslash
before each `[`). The screen text contains `name [stub]` (no
backslash), so every `expect` in that test was an unconditional
`doAssert false` that never actually validated anything. Fixed the
literal vs. escape confusion in that file as a drive-by; the test
now fails on its real assertion (`expectAlive` after `:q`, which is
also wrong — `:q` exits, the test should `expectExit(0)`). Left the
`expectAlive` part alone; it is out of scope for this fix.

## What the new test covers

`tests/tty/test_provider_wizard_cancel.nim` has four subtests:

1. `:provider edit` + Ctrl-C restores the main prompt; `:q` then
   exits with code 0.
2. `:provider edit` + ESC same.
3. `:provider add` + Ctrl-C same.
4. Two consecutive Ctrl-C (the original segfault trigger) is a
   no-op; the process stays alive and `:q` exits cleanly.

All four pass. Existing tests that exercise the same surface
(`test_provider_wizard`, `test_minline`, `test_empty_enter_freeze`,
`test_interrupt_prestream_freeze`) also pass.

## Known follow-ups (not done here)

- The `test_provider_edit_crash` regression test still ends with
  `expectAlive` after `:q`. That assertion is wrong (the process is
  supposed to exit on `:q`). It is not exercised by CI today, but
  should be fixed before this branch is merged.
- `releaseIdleSubmittedInput` is now called twice on the modal
  path: once by `wizardReadLine` (so the next `getCh` doesn't park
  on the stale flag) and once by the main loop's `cdModal` branch
  (the existing call site). Both calls store the same `false`, so
  it is a no-op, but the duplicate is a smell.
- The input thread still paints the wizard's `bracketed-paste`
  enable and the prompt's `fullRedraw` while the wizard is in
  flight. This works (the hooks check `inputModalActive`) but the
  wizard technically owns the terminal during its prompts, so
  ideally `ed.write` would route to a wizard-specific writer.
  Leaving for a follow-up; the cancel path is the user-visible bug
  and is now correct.
