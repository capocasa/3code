# Chunk 3: Route tool-call viewport animation through the GUI thread

## Goal

The last remaining two-writer race: `guiLoop`'s `amBarTick` branch calls
`termengine.updateToolViewportSymbol` (mutates `engine.toolViewportRows[0]`)
while the controller thread (`turns.nim:runBashWithViewport`) appends rows
via `renderToolViewport` and re-renders the viewport. Both touch
`toolViewportRows` and both paint the viewport region, but on different
threads with no composite-level coordination.

Chunk 3 makes **`guiLoop` the sole owner of the viewport+footer composite
during `amBarTick`**. The controller pushes the streaming-view rows into
`FrameModel`; the GUI thread reads them, applies the rotating command
symbol to its own local copy, and paints the whole composite
(viewport + footer) via `renderToolViewport`. The controller never calls
`renderToolViewport` / `updateToolViewportSymbol` / `clearToolViewport`
directly during a bar tick.

Key invariant after this chunk: **during `amBarTick`, only `guiLoop` calls
`renderToolViewport`.** The controller's `runBashWithViewport.renderView()`
becomes a pure state update (`setAnimViewport`) + (in test mode) a
paint-request handshake.

## Read first

- `plan.md` — master plan; "The fix" + impl-2 learnings (the open chunk-3
  item: `guiLoop`'s `amBarTick` branch still calls
  `updateToolViewportSymbol` directly).
- `impl-2.md` — the `guiLoop` structure, the `startBarTick`/`stopBarTick`
  lifecycle, the `commandStatusActive`/`commandSymbolIndex`/
  `nextCommandSymbol` machinery (these stay; the GUI thread owns them).
- `src/threecode/fatprompt/rendering.nim` lines 105-131 (`FrameModel`,
  `AnimationMode`, `FooterFrame`).
- `src/threecode/fatprompt/runtime.nim` lines 257-320 (`frameModelShared`
  + setters + `currentFrameFromModel`).
- `src/threecode/fatprompt/runtime.nim` lines 816-870 (`guiLoop`,
  esp. the `amBarTick` branch).
- `src/threecode/fatprompt/runtime.nim` lines 1065-1067
  (`setCommandStatusActive`), lines 67-76 (`commandSymbolIndex`/
  `nextCommandSymbol`).
- `src/threecode/turns.nim` lines 85-145 (`runBashWithViewport`,
  `renderView`, the exception `clearToolViewport`).
- `src/threecode/engine.nim` lines 110-160 (`walkUp`, `writeToolViewportRows`,
  `updateToolViewportSymbol`), lines 250-315 (`renderToolViewport`/
  `clearToolViewport`).
- `src/threecode/toolstream.nim` lines 35-100 (`StreamingView`,
  `viewportRows`, `commandIcon`, `setSymbol`).
- `tests/tty_expect.nim` lines 210-250 (`pollOnce` — how the frame-event
  `'f'` byte drives `flushFrame`), lines 130-175 (`feedGridChunk` — frames
  commit on `SyncEnd`).

## Background: the test-sync contract (do not break it)

The tty harness captures deterministic frames two ways:
1. **SyncEnd-driven**: every `renderFooter`/`renderToolViewport` is wrapped
   in `SyncBegin`..`SyncEnd`; the harness feeds each sync burst to the grid
   and commits a frame on `SyncEnd` (when not paused).
2. **Frame-event-driven**: the controller calls `emitTestFrameEvent()`
   (writes `'f'` to `THREECODE_TEST_FRAME_FD`, blocks for `'a'` ack). The
   harness, on reading `'f'`, drains the PTY and forces a `flushFrame`.

`runBashWithViewport` calls `emitTestFrameEvent()` after each `renderView()`
so the harness sees each streamed line as a discrete frame. **If the
viewport render moves to the GUI thread's 80ms loop, the controller's
`emitTestFrameEvent()` can fire before the GUI thread has painted the new
rows → the harness commits a stale frame.** This is why a **viewport paint
handshake** is required in test mode: the controller requests a paint and
waits for the GUI thread to acknowledge before emitting the frame event.

In **normal (non-test) mode**, no handshake is needed: the controller sets
the rows and lets the next 80ms tick paint them (80ms is imperceptible for
streaming bash output). The `guiDirty` flag is set so the GUI thread paints
on its very next iteration without waiting a full tick — but since the loop
already sleeps 80ms at the bottom and re-reads the model each iteration,
this is automatic.

## Instructions

### 1. Add `viewportRows` to `FrameModel` + setter

In `rendering.nim`, add a field to `FrameModel`:

```nim
FrameModel* = object
  mode*: AnimationMode
  spinner*: string
  label*: string
  ticker*: string
  elapsed*: int
  clearRows*: int
  viewportRows*: seq[string]   # bash tool viewport rows (owned by GUI thread during amBarTick)
```

In `runtime.nim`, add a setter near the other `setAnim*` procs (~line 300):

```nim
proc setAnimViewport*(rows: openArray[string]) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.viewportRows = @rows
    release frameModelLock
```

Also add a helper to read+clear them (used by `stopBarTick` to clear the
composite on teardown):

```nim
proc animViewportRows*(): seq[string] {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    result = frameModelShared.viewportRows
    release frameModelLock
```

### 2. Add the viewport paint handshake (test-mode determinism)

Near the `testSpinnerRequested`/`testSpinnerPainted` atomics (~line 255),
add:

```nim
var
  viewportPaintRequested: Atomic[int]
  viewportPainted: Atomic[int]
```

Add a controller-side request proc (mirrors `requestTestSpinnerFrame`'s
shape but for the viewport composite):

```nim
proc requestViewportPaint() =
  ## In test mode, request one viewport composite paint from the GUI thread
  ## and block until it acknowledges. Lets `runBashWithViewport.renderView`
  ## guarantee the rows are on screen before emitting a frame event, so the
  ## harness captures each streamed line as a discrete frame. A no-op
  ## outside test mode (the GUI thread's 80ms cadence handles it).
  if not testFrameMode() or not guiRunning:
    return
  let requested = viewportPaintRequested.fetchAdd(1, moRelease) + 1
  while guiRunning and viewportPainted.load(moAcquire) < requested:
    sleep 1
```

### 3. Rewrite the `guiLoop` `amBarTick` branch

The branch currently does:
```nim
of amBarTick:
  let secs = (epochTime() - barTickStart).int
  let label = if m.label.hasElapsedSuffix: m.label else: m.label & "  " & $secs & "s"
  if commandStatusActive.load(moRelaxed):
    discard commandSymbolIndex.fetchAdd(1, moRelease)
    termengine.updateToolViewportSymbol(nextCommandSymbol())   # ← the race
  termengine.renderFooter(tokenBarFrame(label), ...)
```

Replace with: read viewport rows from the model, apply the rotating symbol
to a **local** copy (never touch `engine.toolViewportRows[0]` directly),
paint the viewport+footer composite via `renderToolViewport`. When
`commandStatusActive` is false (tool done, about to tear down) or the model
has no viewport rows, just paint the footer.

```nim
of amBarTick:
  let secs = (epochTime() - barTickStart).int
  let label =
    if m.label.hasElapsedSuffix: m.label
    else: m.label & "  " & $secs & "s"
  let frame = tokenBarFrame(label)
  let vpRows = m.viewportRows
  if vpRows.len > 0:
    var rows = vpRows
    # Apply the rotating command symbol to our local copy's row 0. This is
    # the live "currency ticker" effect during bash execution. We own this
    # composite now — no `updateToolViewportSymbol` mutation of shared
    # engine state, so no race with the controller's row appends.
    if commandStatusActive.load(moRelaxed) and rows[0].len > 0:
      let sym = nextCommandSymbol()
      let firstLen = runeLenAt(rows[0], 0)
      if firstLen > 0:
        rows[0] = sym & rows[0].substr(firstLen)
    termengine.renderToolViewport(rows, frame,
                                  inputThreadRunning, inputEditor,
                                  currentTermW())
  else:
    termengine.renderFooter(frame, inputThreadRunning, inputEditor,
                            currentTermW())
  if testFrameMode():
    viewportPainted.store(observedTestTick, moRelease)
```

Wait — `observedTestTick` is the spinner handshake's counter; the viewport
ack must use `viewportPaintRequested`. Fix: track a local
`observedViewportTick = viewportPainted.load(moAcquire)` at the top of the
loop, and in the `amBarTick` branch store
`viewportPainted.store(observedViewportTick, moRelease)`. But the
`amBarTick` branch runs on the **same iteration** as the
`testSpinnerRequested` block-wait at the top — in test mode the loop blocks
on the spinner handshake. The viewport handshake is a *separate* signal.

**Resolution:** the top-of-loop test-mode block currently only waits on
`testSpinnerRequested`. For `amBarTick` test mode, the loop must ALSO wake
on `viewportPaintRequested`. Restructure the top-of-loop wait so that in
test mode it waits for EITHER signal:

```nim
let elapsed =
  if testFrameMode():
    # Wait for either a spinner frame request or a viewport paint request.
    # Both are controller-driven deterministic paint triggers.
    while not guiStop.load(moRelaxed):
      if testSpinnerRequested.load(moAcquire) > observedTestTick: break
      if viewportPaintRequested.load(moAcquire) > observedViewportTick: break
      sleep 1
    if guiStop.load(moRelaxed): break
    observedTestTick = testSpinnerRequested.load(moAcquire)
    observedViewportTick = viewportPaintRequested.load(moAcquire)
    0.0
  else:
    epochTime() - start
```

And initialize `var observedViewportTick = viewportPainted.load(moAcquire)`
alongside `observedTestTick`. Then in the `amBarTick` branch, after
painting, `viewportPainted.store(observedViewportTick, moRelease)`. In the
`amSpinner` branch, after painting,
`testSpinnerPainted.store(observedTestTick, moRelease)` (unchanged).

**Note on cadence in non-test mode:** the loop sleeps 80ms at the bottom
regardless of mode. In non-test `amBarTick`, the controller sets rows and
the next iteration (≤80ms later) paints them. That is responsive enough for
streaming bash output (human reading speed >> 80ms). No dirty-signal
wakeup needed in non-test mode.

### 4. Rewrite `runBashWithViewport.renderView()`

In `turns.nim`, the local `renderView()` proc currently:
```nim
proc renderView() =
  view.setSymbol(nextCommandSymbol())
  termengine.renderToolViewport(view.viewportRows(),
                                footerFrame(fatPromptState),
                                inputThreadRunning, inputEditor)
```

Becomes a pure state update + (test mode) a paint request:
```nim
proc renderView() =
  view.setSymbol(nextCommandSymbol())
  setAnimViewport(view.viewportRows())
  requestViewportPaint()
```

The `view.setSymbol(nextCommandSymbol())` stays — it bakes the current
symbol into the rows the GUI thread will read. The GUI thread *also*
rotates the symbol each tick (step 3), but since the controller overwrites
the rows on every `renderView()`, the two don't fight: the controller sets
the baseline symbol, the GUI thread rotates it forward each 80ms until the
next `renderView()` resets the baseline. `commandStatusActive` gates the
rotation in the GUI thread (false after tool done → no rotation, exit-code
icon `Ø` takes over via `commandIcon`).

**Import the new procs.** `turns.nim` already imports
`fatprompt` (which re-exports runtime). Verify `setAnimViewport` and
`requestViewportPaint` are exported/accessible. If `requestViewportPaint`
is module-private in runtime.nim, mark it `*` OR make it accessible. Since
`turns.nim` calls it, it must be exported. Make `requestViewportPaint*()`
and `setAnimViewport*`.

### 5. Handle the exception-path `clearToolViewport`

`runBashWithViewport`'s `finally` block calls `clearToolViewport` on
exception (turns.nim:145). Under the new model, the controller must not
call `renderToolViewport` during a bar tick. Replace it with: clear the
model's viewport rows and request a paint (so the GUI thread paints an
empty composite), OR stop the bar tick first (which stops the GUI thread)
and then the controller can clear directly.

The cleanest: **`stopBarTick` clears the model viewport rows** before
stopping the GUI thread, so after `stopBarTick` the composite is gone. But
the exception path needs an immediate clear. Since the exception happens
inside `withBarTick`, the `finally` of `withBarTick` calls `stopBarTick`
which stops the GUI thread — but `runBashWithViewport`'s own `finally`
runs BEFORE `withBarTick`'s `finally`. So at the point of the
`clearToolViewport` call, the GUI thread is still running.

**Resolution:** Replace the exception-path `clearToolViewport` with:
```nim
if getCurrentException() != nil:
  setAnimViewport(@[])
  requestViewportPaint()
```
This asks the GUI thread to paint an empty composite (viewport gone,
footer remains). The subsequent `stopBarTick` (from `withBarTick`'s
`finally`) then stops the GUI thread. Since `requestViewportPaint` is a
no-op when `guiRunning` is false, and it returns once the paint acks,
this is safe. The controller's `appendItem`/transcript commit then runs
with the viewport already cleared.

**Verify** that `clearToolViewport`'s no-rows path (`renderToolViewport([])`)
matches what the GUI thread now paints with empty `viewportRows` — i.e.
the `renderFooter`-only path. In the new `amBarTick` branch, empty
`viewportRows` → `renderFooter(frame)` which paints the token bar. That
matches the old `clearToolViewport` behavior (which renders `[]` rows =
no viewport + footer). Good.

### 6. Delete now-dead engine code (optional, verify with grep)

After this chunk, `updateToolViewportSymbol` has NO callers (the GUI thread
no longer calls it). Grep to confirm:
```
grep -rn updateToolViewportSymbol src/
```
If zero callers remain, **delete** `updateToolViewportSymbol` from
`engine.nim` (lines ~146-157). Its doc comment about "serialize with the
render threads" is now moot — there are no render threads mutating
`toolViewportRows[0]`; the GUI thread operates on a local copy.

**Keep** `renderToolViewport` and `clearToolViewport` — the GUI thread
calls `renderToolViewport`; `clearToolViewport` may still be called from
non-bar-tick paths (verify; if it's only called from
`runBashWithViewport`'s exception path which is now rewritten, check
other callers). Grep `clearToolViewport` callers.

### 7. Confirm `stopBarTick` clears the viewport composite

`stopBarTick` stops the GUI thread and sets `amIdle`. After it returns,
`frameModelShared.viewportRows` may still hold stale rows. Clear them so
the next `amBarTick` (next tool call) doesn't flash the previous tool's
rows for one frame before the controller's first `setAnimViewport`. Add
to `stopBarTick` (before `stopGui`):
```nim
setAnimViewport(@[])
```
This is belt-and-suspenders: `startBarTick` → first `renderView()` sets
fresh rows before the first paint anyway. But clearing on stop prevents
a one-frame stale flash if the GUI thread paints once between
`startBarTick` and the first `renderView()`. Since `startBarTick` calls
`ensureGuiStarted()` which may start the thread, and the thread's first
iteration reads the model before the controller's `renderView()` runs,
clearing on stop is correct.

## Verification

1. `nimble build` — clean.
2. `nimble test tests/tty/test_spinner_race_stress.nim` — MUST pass
   (~65s). This stress-tests concurrent GUI + input-thread access.
3. `nimble test tests/tty/test_tty_functional.nim` — MUST pass (~64s).
   The "main visual test" exercises the bash tool viewport heavily:
   `ls -R` (2 streamed lines), `printf 'bash-line-1..12'` (12 lines,
   triggers the omitted-line cutoff), `printf second-tool`. The viewport
   must render every streamed line as a frame and the command symbol must
   rotate. **This is the test that will catch a broken viewport composite
   or a stale-frame bug from the handshake.**
4. `nimble test tests/tty/test_resize_ticker.nim` — MUST pass (~13s).
5. Grep: confirm `updateToolViewportSymbol` has no callers (and is
   deleted) and that during `amBarTick` only `guiLoop` calls
   `renderToolViewport`.

## Pitfalls / what to watch

- **The `view.setSymbol(nextCommandSymbol())` in `renderView()`** and the
  GUI thread's rotation can both touch the symbol. They don't race because
  the controller writes to the `FrameModel` (under lock) and the GUI thread
  reads it; the rotation is applied to the GUI thread's LOCAL copy. Verify
  the rotation doesn't double-advance `commandSymbolIndex` — only the GUI
  thread advances it now (the controller's `setSymbol` reads the current
  value without advancing). **Do NOT call `commandSymbolIndex.fetchAdd` in
  the controller.**
- **`runeLenAt` / `substr`**: the GUI thread's local symbol swap must use
  the same `runeLenAt(row, 0)` + `substr(firstLen)` logic as the old
  `updateToolViewportSymbol`. Import `unicode` (for `runeLenAt`) if not
  already imported in runtime.nim — check.
- **`observedViewportTick` init**: must be loaded at loop start alongside
  `observedTestTick`, else the first viewport paint acks the wrong counter.
- **Empty viewport rows + footer paint**: when `viewportRows.len == 0` in
  `amBarTick`, paint footer only (not `renderToolViewport([])`) — calling
  `renderToolViewport([])` would still set `engine.toolViewportRows = @[]`
  which is fine but `renderFooter` is the lighter path. Match whichever the
  tests expect; if a blank viewport row appears, switch to
  `renderToolViewport([], ...)`.

## Next step

When complete and verified:
1. Update `plan.md` TODO: mark impl-3 done, record learnings (did the
   handshake work first try? did `updateToolViewportSymbol` delete cleanly?
   did the exception-path clear work? any stale-frame flakiness?).
2. Commit, one-line message, no coauthor. Stage only changed files.
3. Call `context_clear` with:
   - summary: viewport composite now owned by guiLoop during amBarTick;
     FrameModel carries viewportRows; controller pushes rows via
     setAnimViewport + requestViewportPaint handshake; updateToolViewportSymbol
     deleted. Build clean, tests green. Committed <sha>.
   - instructions: read impl-4.md (final integration + stress + reproduce-or-close).
