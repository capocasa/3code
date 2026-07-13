# Chunk 2: Single GUI animation thread (merge spinnerLoop + barTickLoop)

## Goal

Replace the two background render threads (`spinnerLoop` 80ms,
`barTickLoop` 250ms) with **one** `guiLoop` thread that is the sole painter
of `renderFooter`. This closes the ticker-line race: with one writer,
`paintedFooterRows` can never be left stale by a competing frame, because
the controller quiesces the single thread before any height transition
(`startContent`, `endTurn`).

Key invariant after this chunk: **only `guiLoop` calls `renderFooter`.**
The controller sets desired state in `frameModelShared`, signals the GUI
thread (dirty flag), and the GUI thread paints. At transitions the
controller stops the GUI thread, performs the atomic transition, and
restarts it.

## Read first

- `plan.md` — the master plan; re-read "The fix" and the impl-1 learnings.
- `impl-1.md` — what the `FrameModel` is and how the setters work (already
  implemented; this chunk builds on it).
- `src/threecode/fatprompt/runtime.nim` lines 245-315 (the `frameModelShared`
  block + `setAnimMode`/`getFrameModel`/`currentFrameFromModel`).
- `src/threecode/fatprompt/runtime.nim` lines 836-870 (`spinnerLoop`).
- `src/threecode/fatprompt/runtime.nim` lines 946-985 (`barTickLoop`).
- `src/threecode/fatprompt/runtime.nim` lines 970-1020 (`startBarTick`/
  `stopBarTick`/`withBarTick`).
- `src/threecode/fatprompt/runtime.nim` lines 1088-1135 (`startSpinner`/
  `stopSpinner`).
- `src/threecode/fatprompt/runtime.nim` lines 1198-1225 (`startContent` —
  the transition that must quiesce the GUI thread).
- `src/threecode/fatprompt/runtime.nim` lines 2228-2260 (`endTurn`).
- `src/threecode/api.nim` lines 95-170 (the `ApiStreamHooks` that wire
  `startSpinner`/`stopSpinner` into the streaming loop).
- `src/threecode/terminal.nim` lines 40-90 (`withTerminalLockDroppedForJoin`
  — the join-dance the GUI thread must still respect).

## Background: why the two threads can merge cleanly

The spinner and bar-tick are **mutually exclusive in practice**:
- Spinner runs during reasoning / waiting-for-first-content / retry backoff.
- Bar-tick runs during bash tool execution.
They never animate the footer at the same time. The current code even has
explicit "pause the other thread" logic in `startContent` (runtime.nim:1218
`discard stopBarTick()`). So a single thread that paints "whatever
`frameModelShared.mode` says" on a merged cadence loses nothing.

## Instructions

### 1. Add a dirty signal + single thread var

Near the `frameModelShared` block (runtime.nim ~line 257), add:

```nim
var
  guiStop: Atomic[bool]
  guiDirty: Atomic[bool]      # controller signals "paint now"
  guiRunning: bool
  guiThread: Thread[void]
```

### 2. Write `guiLoop`

One thread. Cadence: in normal mode, poll-sleep at the faster of the two
intervals (80ms covers both spinner animation and bar-tick visibility; the
bar-tick's seconds counter visibly updating at 80ms vs 250ms is a non-issue
— it shows whole seconds). In test frame mode, block on the existing
`testSpinnerRequested`/`testSpinnerPainted` handshake so deterministic
frame capture still works.

```nim
proc guiLoop(unused: string) {.thread.} =
  const frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
  let start = epochTime()
  var i = 0
  var observedTestTick = testSpinnerPainted.load(moAcquire)
  while not guiStop.load(moRelaxed):
    let elapsed =
      if testFrameMode():
        while not guiStop.load(moRelaxed) and
            testSpinnerRequested.load(moAcquire) <= observedTestTick:
          sleep 1
        if guiStop.load(moRelaxed): break
        observedTestTick = testSpinnerRequested.load(moAcquire)
        0.0
      else:
        epochTime() - start
    let m = getFrameModel()
    try:
      case m.mode
      of amSpinner:
        # Advance the spinner glyph ourselves (we own it now).
        let glyph = frames[i mod frames.len]
        setAnimSpinner(glyph, elapsed.int)
        termengine.renderFooter(currentFrameFromModel(),
                                inputThreadRunning, inputEditor,
                                currentTermW())
        spinnerFramePainted.store(true, moRelaxed)
      of amBarTick:
        # Compute the ephemeral elapsed suffix here (was local to barTickLoop).
        let secs = (epochTime() - barTickStart).int
        let label =
          if m.label.hasElapsedSuffix: m.label
          else: m.label & "  " & $secs & "s"
        if commandStatusActive.load(moRelaxed):
          discard commandSymbolIndex.fetchAdd(1, moRelease)
          termengine.updateToolViewportSymbol(nextCommandSymbol())
        termengine.renderFooter(tokenBarFrame(label),
                                inputThreadRunning, inputEditor,
                                currentTermW())
        # barTick never sets spinnerFramePainted; the test handshake keys
        # on spinner frames, and bar-tick is not driven through it.
      of amIdle:
        discard  # nothing to animate; the controller paints idle frames
                 # directly (they're not periodic)
      if testFrameMode():
        testSpinnerPainted.store(observedTestTick, moRelease)
    except CatchableError: discard
    if not testFrameMode():
      sleep 80
    inc i
```

**Note on cadence:** the original bar-tick slept 250ms and re-asserted
hide-cursor each tick. At 80ms the hide-cursor re-assert happens more
often — that's harmless (it's idempotent). If you observe flicker, gate the
hide-cursor re-assert to every Nth iteration, but try 80ms first.

**Note on the test handshake:** `testSpinnerRequested`/`testSpinnerPainted`
is the mechanism the tty test harness uses to request and acknowledge a
single deterministic spinner frame. The guiLoop must honor it exactly as
`spinnerLoop` did: block until requested, paint one frame, store the ack.
`requestTestSpinnerFrame` (runtime.nim ~line 322) checks `spinnerRunning`;
**repoint that check to `guiRunning`** (see step 5) so the handshake still
fires.

### 3. Replace `startSpinner`/`stopSpinner`/`startBarTick`/`stopBarTick`

These become state setters + lifecycle for the single thread, not
per-thread create/join.

```nim
proc ensureGuiStarted() =
  if guiRunning: return
  ensureTestTickerControlStarted()
  guiStop.store(false, moRelaxed)
  testSpinnerRequested.store(0, moRelease)
  testSpinnerPainted.store(0, moRelease)
  createThread(guiThread, guiLoop, "")
  guiRunning = true

proc stopGui() =
  if not guiRunning: return
  guiStop.store(true, moRelaxed)
  termui.withTerminalLockDroppedForJoin:
    joinThread(guiThread)
  guiRunning = false

proc startSpinner*(label: string) =
  debugOut "startSpinner"
  if label.len > 0: setSpinLabel(label)
  setSpinFrame("⠋", 0)
  setAnimMode(amSpinner)
  spinnerFramePainted.store(false, moRelaxed)
  ensureGuiStarted()
  # Paint one immediate frame so the spinner appears instantly (matches the
  # old startSpinner which rendered before createThread).
  termengine.renderFooter(currentFrameFromModel(),
                          inputThreadRunning, inputEditor, currentTermW())
  spinnerFramePainted.store(true, moRelaxed)

proc stopSpinner*(clearLiveFooter = true) =
  debugOut "stopSpinner"
  if not guiRunning:
    setAnimMode(amIdle)
    return
  stopGui()
  setAnimMode(amIdle)
  if clearLiveFooter and inputThreadRunning and inputEditor != nil and
      spinnerFramePainted.load(moRelaxed):
    termengine.renderFooter(clearFooterFrame(2),
                            inputThreadRunning, inputEditor, currentTermW())
```

For `startBarTick`/`stopBarTick`/`withBarTick`: keep their public signatures
(`startBarTick*(base: string): bool`, `stopBarTick*(): int`,
`withBarTick` template) because `turns.nim` and the tool execution path
call them. Repoint them to set `amBarTick` and drive the single thread:

```nim
proc startBarTick*(base: string): bool =
  debugOut "startBarTick"
  if getFrameModel().mode == amBarTick: return false  # idempotent
  setAnimLabel(base)
  setAnimMode(amBarTick)
  barTickStart = epochTime()
  ensureGuiStarted()
  return true

proc stopBarTick*(): int =
  debugOut "stopBarTick"
  let m = getFrameModel()
  if m.mode != amBarTick: return 0
  let elapsed = (epochTime() - barTickStart).int
  stopGui()
  setAnimMode(amIdle)
  commandStatusActive.store(false, moRelaxed)
  return elapsed
```

**Careful with `withBarTick`:** it's an RAII template that calls
`startBarTick` before `body` and `stopBarTick` after. Since `stopBarTick`
now stops the *entire* GUI thread, and a spinner might want to run right
after a tool call (`apiAfterLiveContent` calls `startSpinner`), this is
fine — `startSpinner` will `ensureGuiStarted()` again. But verify the
join/stop doesn't deadlock: `stopGui` joins with the terminal lock dropped
(same as before). The `commandStatusActive` reset stays in `stopBarTick`.

### 4. Delete the old thread vars + loops

Remove:
- `spinnerStop`, `spinnerRunning`, `spinnerThread` (the `createThread(spinnerThread, spinnerLoop)` is gone).
- `barTickStop`, `barTickRunning`, `barTickThread`.
- `spinnerLoop`, `barTickLoop` proc bodies (replaced by `guiLoop`).
- The legacy spin vars (`spinLabelShared`, `spinTickerShared`,
  `spinFrameShared`, `spinElapsedShared`) and their mirror-writes in the
  setters — all reads now go through `getFrameModel()`. **Remove the
  `spinLabelLock` acquisition from `setSpinLabel`/`setSpinTicker`/
  `setSpinFrame`** since those vars are gone; keep only the
  `setAnimLabel`/`setAnimTicker`/`setAnimSpinner` calls.

Keep:
- `barTickLock`/`barTickBase` — `barTickBase` is now redundant with
  `frameModelShared.label`, but `withBarTick`/callers may still reference
  it. If after repointing nothing reads `barTickBase`, delete it too.
  Grep to confirm.
- `commandSymbolIndex`, `nextCommandSymbol`, `setCommandStatusActive` —
  chunk 3 owns these; leave them.
- `barTickStart` — still used by `guiLoop` to compute the elapsed suffix.

### 5. Repoint the test-frame handshake + liveness checks

Search for every read of `spinnerRunning` and `barTickRunning` and decide:
- `requestTestSpinnerFrame` (runtime.nim ~line 322): change the guard
  `if not spinnerRunning` → `if not guiRunning`.
- `reserveEditorFooterForRedraw` (runtime.nim ~line 530): it now reads
  `getFrameModel().mode` directly (done in impl-1); confirm it no longer
  references `spinnerRunning`/`barTickRunning`. The `amSpinner`/`amBarTick`
  branches are the replacement.
- Any test helper that polls `spinnerRunning` to know when a frame painted:
  repoint to `guiRunning` or to `spinnerFramePainted`.

### 6. The transition paths must quiesce the single thread

`startContent` (runtime.nim ~line 1198) currently calls `stopSpinner` then
`stopBarTick`. With the merged thread, `stopSpinner` already stops the GUI
thread and sets `amIdle`; the subsequent `stopBarTick` is a no-op (mode is
no longer `amBarTick`). **Keep both calls** — they're idempotent and the
call sites are numerous; removing the `stopBarTick` from `startContent` is
optional cleanup. The important thing: after `startContent`'s
`stopSpinner`+`stopBarTick`, `guiRunning == false`, so
`prepareAssistantContentStart`'s `walkUp` reads a `paintedFooterRows` that
no background thread can mutate. That's the race closure.

`endTurn` (runtime.nim ~line 2228) calls `stopBarTick` then `stopSpinner`.
Same story: both stop the GUI thread idempotently. Keep both.

### 7. Verify the `spinnerCleanupBytes` exit path

`spinnerLoop` had an exit-cleanup `syncWrite(spinnerCleanupBytes(1))` when
`not inputThreadRunning` (runtime.nim ~line 866). Decide where this moves:
- If it's the "spinner exiting while no input thread" teardown, it belongs
  in `stopGui` or `stopSpinner`'s post-join path. Check whether
  `clearLiveFooter` already covers it (the `clearFooterFrame(2)` render).
  Likely the exit-cleanup is now redundant with `stopSpinner`'s explicit
  `clearFooterFrame(2)` render — but verify by running the tests; if a
  blank row appears or disappears regressively, restore the cleanup bytes
  in `stopSpinner` after the clear-footer render.

## Verification

1. `nimble build` — clean.
2. `nimble test tests/tty/test_spinner_race_stress.nim` — MUST pass. This
   is the test that caught the original spinner/input-thread heap race; if
   the GUI thread merge reintroduces any unsynchronized access it will
   crash here.
3. `nimble test tests/tty/test_tty_functional.nim` — MUST pass. Covers
   spinner start/stop, bar-tick during bash tools, turn transitions, and
   the test-frame deterministic-capture path.
4. `nimble test tests/tty/test_resize_ticker.nim` — resize during spinner;
   the merged thread must still handle it.
5. Grep: confirm `renderFooter` is now called from exactly one thread
   context (the GUI thread) plus the controller's transition paths
   (`startSpinner`'s immediate paint, `stopSpinner`'s clear,
   `startContent`/`endTurn`/`apiFinalUsage`). There should be NO remaining
   `renderFooter` call inside a `while ... loop` proc that runs on its own
   thread.

If the stress test crashes with a SIGSEGV in the allocator, the likely
cause is the GUI thread and the input thread's editor redraw both touching
the `LineEditor` without coordination — but that was already the case with
`spinnerLoop`, so if impl-1 passed, the merge shouldn't introduce a new
access. If it does, check whether `guiLoop`'s `amBarTick` branch's
`updateToolViewportSymbol` call races the controller's tool-viewport render
(that's the chunk-3 race; if it manifests now, defer it but note it).

## Next step

When this chunk is complete and verified:

1. Update the TODO list in `plan.md`: mark impl-2 done, record learnings
   (especially: did the test-frame handshake need changes? did
   `spinnerCleanupBytes` stay or go? any deadlock in `stopGui` during
   `endTurn`?).
2. Commit, one-line message, no coauthor. Stage only changed files.
3. Call `context_clear` with:
   - summary: "Chunk 2 done: spinnerLoop + barTickLoop merged into single
     guiLoop; startSpinner/stopSpinner/startBarTick/stopBarTick repointed
     to drive the one thread via frameModelShared.mode; legacy spin vars +
     per-thread stop/running flags deleted. renderFooter now called only
     from guiLoop + controller transitions. Build clean, tty stress +
     functional + resize tests green. Files changed: <list>. Committed
     <sha>."
   - instructions: "Read impl-3.md and execute the instructions there.
     Working tree at commit <sha> on branch `slurp`. Read `plan.md` first
     for master plan + current TODO state."
