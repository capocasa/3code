# Chunk 1: Extract the animation state model (`FrameModel`)

## Goal

Centralize the scattered shared state that `spinnerLoop` and `barTickLoop`
read to decide what frame to paint, into a single `FrameModel` record held
under one lock. This chunk does **not** merge the two threads — it only
makes the state they read go through one consistent source so that chunk 2
can swap the threads for a single animation thread with minimal further
plumbing.

After this chunk, both threads still exist and still call `renderFooter`
themselves, but they both build their `FooterFrame` by reading the unified
`FrameModel` instead of their private atomics/locks. The controller's
setters (`setSpinLabel`, `setSpinTicker`, `startBarTick` base, etc.) write
the `FrameModel`.

## Read first

- `plan.md` — the master plan and the race analysis. Read the "root
  problem" and "the fix" sections.
- `TICKER_RACE_HANDOFF.md` — the detailed race description and the
  `walkUp`/`paintedFooterRows` model. Read "The walk-up model" and
  "Footer height transitions at the suspect boundary".
- `src/threecode/fatprompt/rendering.nim` lines 90-120 (the `FooterFrame`
  type and `FooterFrameKind`) and lines 325-360 (the frame constructors
  `spinnerFooterFrame`, `tokenBarFrame`, `clearFooterFrame`,
  `noFooterFrame`, and `rowsAboveEditor`).
- `src/threecode/fatprompt/runtime.nim` lines 245-375 (the spinner shared
  state vars + `setSpinLabel`/`getSpinLabel`/`setSpinTicker`/
  `getSpinTicker`/`setSpinFrame`/`currentSpinnerFooterFrame`).
- `src/threecode/fatprompt/runtime.nim` lines 782-830 (`spinnerLoop`).
- `src/threecode/fatprompt/runtime.nim` lines 895-960 (`barTickLoop`,
  `startBarTick`, `stopBarTick`, `withBarTick`).
- `src/threecode/fatprompt/runtime.nim` lines 1037-1080
  (`startSpinner`/`stopSpinner`).
- `src/threecode/fatprompt/runtime.nim` lines 474-525
  (`reserveEditorFooterForRedraw` — the input thread's reader of spinner/
  barTick state; it must read the new model too).

## Background: the current scattered state

Spinner animation state (under `spinLabelLock`):
- `spinLabelShared: string` — the token-slot label (e.g. `↓ 42  ↑ 0 ↻ 0`).
- `spinTickerShared: string` — the reasoning ticker tail text.
- `spinFrameShared: string` — the current braille glyph (`⠋` etc).
- `spinElapsedShared: int` — seconds since spinner start.

Bar-tick state (under `barTickLock` + atomics):
- `barTickBase: string` — the base label, to which barTick appends ` Ns`.
- `barTickStart: float` — epoch start time.
- `commandSymbolIndex: Atomic[int]` — rotates `$ € £ ¥` in the tool
  viewport's command row.

Plus the liveness atomics `spinnerRunning`/`barTickRunning`/`spinnerStop`/
`barTickStop`.

## Instructions

### 1. Define `FrameModel` in `rendering.nim`

Add a new type near the `FooterFrame` definition (rendering.nim ~line 101):

```nim
type
  AnimationMode* = enum
    amIdle,      # nothing animating (no spinner, no bar-tick)
    amSpinner,   # spinner running (reasoning/waiting for first content)
    amBarTick    # bar-tick running (tool executing)

  FrameModel* = object
    ## The single source of truth for what the GUI animation thread paints.
    ## The controller writes it under `frameModelLock`; the animation thread
    ## reads it to build a `FooterFrame` each tick. Centralizing this state
    ## (previously scattered across `spinLabelLock` vars, `barTickLock`
    ## vars, and loose atomics) is the prerequisite to merging the two
    ## render threads into one — it removes the torn-read window where a
    ## spinner frame and a bar-tick frame disagree about footer height.
    mode*: AnimationMode
    spinner*: string      # braille glyph
    label*: string        # token-slot label (shared by spinner + bar tick)
    ticker*: string       # reasoning ticker tail text
    elapsed*: int         # seconds (spinner) or whole-second bar-tick count
    clearRows*: int       # for ffClear frames at teardown
```

### 2. Define the model + lock in `runtime.nim`

Near the existing `spinLabelLock` block (runtime.nim ~line 245), add:

```nim
var
  frameModelLock: Lock
  frameModelShared: FrameModel
frameModelLock.initLock()
```

### 3. Add accessor procs in `runtime.nim`

Add read/write procs that take the lock. These replace the scattered
`setSpinLabel`/`getSpinLabel`/etc. internals, but **keep the existing
public proc names** as thin wrappers so callers don't change in this chunk.

```nim
proc setFrameModel*(m: FrameModel) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared = m
    release frameModelLock

proc getFrameModel*(): FrameModel {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    result = frameModelShared
    release frameModelLock

proc updateFrameModel*(mode: AnimationMode = amIdle;
                      spinner = ""; label = ""; ticker = "";
                      elapsed = -1; clearRows = -1) {.gcsafe.} =
  ## Partial update: only fields whose argument differs from the sentinel
  ## are written. Lets callers set just the label or just the ticker without
  ## clobbering the rest. `elapsed = -1` and `clearRows = -1` mean "leave
  ## unchanged"; empty strings mean "set to empty".
  {.cast(gcsafe).}:
    acquire frameModelLock
    if mode != amIdle or true: frameModelShared.mode = mode
    # Note: mode defaults to amIdle but we always write it — callers that
    # want to preserve mode must read-get first. (Kept simple for chunk 1;
    # chunk 2 may refine.)
    if spinner.len > 0: frameModelShared.spinner = spinner
    if label.len > 0: frameModelShared.label = label
    if ticker.len > 0 or mode == amIdle: frameModelShared.ticker = ticker
    if elapsed >= 0: frameModelShared.elapsed = elapsed
    if clearRows >= 0: frameModelShared.clearRows = clearRows
    release frameModelLock
```

**Refinement before implementing:** the `updateFrameModel` partial-write
semantics above are fiddly (mode always written, ticker only written when
non-empty OR mode is idle). This is a common source of bugs. Consider
instead making every field explicit and having each setter read-modify-write:

```nim
proc setAnimMode*(mode: AnimationMode) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.mode = mode
    release frameModelLock

proc setAnimLabel*(label: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.label = label
    release frameModelLock

proc setAnimTicker*(ticker: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.ticker = ticker
    release frameModelLock

proc setAnimSpinner*(spinner: string; elapsed: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.spinner = spinner
    frameModelShared.elapsed = elapsed
    release frameModelLock
```

**Prefer the explicit per-field setters (second form).** They mirror the
existing `setSpinLabel`/`setSpinTicker`/`setSpinFrame` shape, are obviously
correct, and each takes the lock once. Drop `updateFrameModel` unless a
caller genuinely needs atomic multi-field update.

### 4. Repoint the existing setters to write `frameModelShared`

Rewrite `setSpinLabel`, `setSpinTicker`, `setSpinFrame`, and add the
bar-tick label setter, so they write `frameModelShared` (via the new
per-field procs) **in addition to** the legacy vars. Keep the legacy vars
(`spinLabelShared` etc.) for now — chunk 2 removes them. The goal of this
chunk is that `frameModelShared` is always consistent with the legacy
vars, so both threads can be migrated to read from it.

Actually — simpler and cleaner: **make the legacy setters write ONLY
`frameModelShared`**, and make the legacy getters read from it. Then keep
the legacy var declarations but leave them unused (chunk 2 deletes them).
This avoids dual-write bugs. Wrap the reads/writes so the existing
`emitFatPromptEvent` side effects in `setSpinTicker` (the
`clearTickerEvent`/`setTickerEvent` calls) are preserved.

Concretely, `setSpinTicker` becomes:

```nim
proc setSpinTicker(s: string) {.gcsafe.} =
  setAnimTicker(s)
  if s.len == 0:
    emitFatPromptEvent clearTickerEvent()
  else:
    emitFatPromptEvent setTickerEvent(s)
```

and `getSpinTicker` reads `getFrameModel().ticker`. Same for label,
spinner, elapsed. `currentSpinnerFooterFrame` builds from
`getFrameModel()`.

### 5. Add bar-tick label + elapsed to the model

The bar-tick loop currently computes `label = base & "  " & $elapsed & "s"`
locally each tick from `barTickBase` (under `barTickLock`) and
`barTickStart`. Move `barTickBase` into `frameModelShared.label` (the base,
without the elapsed suffix) and have `startBarTick` write it there via
`setAnimLabel`. The bar-tick loop still computes the elapsed suffix locally
each tick (it changes every 250ms) and passes the full label to
`tokenBarFrame`; that's fine — the *base* is the shared part, the suffix is
ephemeral. This is a read of `label` + local arithmetic, not a new race.

`barTickStart` and `commandSymbolIndex` stay as-is for this chunk
(`barTickStart` is write-once-at-start, read-only-after; `commandSymbolIndex`
is an atomic the loop already uses safely). Chunk 3 owns the
`commandSymbolIndex`/tool-viewport story.

### 6. Make both loops read the model

- `spinnerLoop`: replace `getSpinLabel()`/`getSpinTicker()`/`setSpinFrame`
  internals with `getFrameModel()` reads. The spinner still calls
  `setSpinFrame` (which now writes `frameModelShared.spinner` + `.elapsed`)
  before painting — that's correct, the spinner owns its own glyph
  rotation. Build the `FooterFrame` via a new helper:

```nim
proc currentFrameFromModel(): FooterFrame {.gcsafe.} =
  let m = getFrameModel()
  case m.mode
  of amSpinner:
    spinnerFooterFrame(
      if m.spinner.len > 0: m.spinner else: "○",
      m.label, m.ticker, m.elapsed)
  of amBarTick:
    tokenBarFrame(m.label, m.ticker)
  of amIdle:
    footerFrame(fatPromptState)   # static bar from fat prompt state
```

  `spinnerLoop` uses `currentFrameFromModel()` (after its own
  `setSpinFrame` updates the glyph). `barTickLoop` uses
  `currentFrameFromModel()` too, after computing its elapsed suffix into a
  local and building the full label — but note the bar-tick needs to write
  the *full* label (base + suffix) somewhere the frame builder can see it.
  Simplest: `barTickLoop` builds the `tokenBarFrame` directly from its
  local `label` var (as it does today) rather than going through the model,
  since the suffix is ephemeral. **That's acceptable for chunk 1** — the
  model holds the stable base; the loop holds the ephemeral suffix. Chunk 2
  unifies this when there's one thread.

- `reserveEditorFooterForRedraw` (runtime.nim:474): this input-thread
  callback currently reads `spinnerRunning`/`barTickRunning` +
  `spinLabelLock` to pick a frame model. Repoint it to read
  `getFrameModel()` and branch on `mode`. This is the key consistency win:
  the input thread's editor redraw now sees the same state the animation
  threads see, so it can't pick a spinner frame while the model says
  bar-tick.

### 7. Set the mode at transitions

- `startSpinner`: call `setAnimMode(amSpinner)` (in addition to existing
  logic).
- `stopSpinner`: call `setAnimMode(amIdle)` after the join (the controller
  is about to either clear the footer or start content).
- `startBarTick`: call `setAnimMode(amBarTick)`.
- `stopBarTick`: call `setAnimMode(amIdle)` after the join.

These mode transitions are writes from the controller thread, under
`frameModelLock`. The animation threads read `mode` each tick. This is the
seed of the single-thread ownership: chunk 2 makes the controller *quiesce*
the thread before transitioning, but for now the lock is enough to keep the
reads consistent.

## Verification

1. `nimble build` — must compile clean (warnings about unused imports are
   pre-existing and fine; no NEW errors).
2. `nimble test tests/tty/test_spinner_race_stress.nim` — the spinner-during-429
   stress test must still pass (it exercises the spinner + input thread
   concurrent redraw path that `reserveEditorFooterForRedraw` serves).
3. `nimble test tests/tty/test_tty_functional.nim` — the broad functional
   suite must stay green. This covers spinner start/stop, bar-tick during
   bash tools, and turn transitions.
4. Spot-check: run `./3code` locally against the stub provider with a
   reasoning-bearing turn if a quick repro is available, and confirm the
   spinner + bar still animate. (The stub exercises the test frame mode
   path; a real provider isn't required for this chunk's verification.)

If any test regresses, the likely cause is a missed setter that still
writes a legacy var without updating `frameModelShared`, or a getter that
still reads a legacy var. Grep for every read of `spinLabelShared`/
`spinTickerShared`/`spinFrameShared`/`spinElapsedShared` and confirm none
remain after migration (the legacy var declarations can stay, unused, until
chunk 2).

## Next step

When this chunk is complete and verified:

1. Update the TODO list in `plan.md`: mark impl-1 done, record learnings
   (e.g. "bar-tick elapsed suffix is ephemeral, kept local in the loop;
   `commandSymbolIndex` deferred to chunk 3; any surprises in the
   `reserveEditorFooterForRedraw` migration").
2. Commit with a one-line message, no coauthor trailer. Stage only the
   files you changed (`plan.md`, the impl-1.md if you keep it, and the
   source files). Do NOT stage `TICKER_RACE_HANDOFF.md` or
   `slurp-report.md`.
3. Call `context_clear` with:
   - summary: "Chunk 1 done: FrameModel extracted in rendering.nim,
     frameModelShared + per-field setters in runtime.nim, both animation
     loops + reserveEditorFooterForRedraw read the unified model. Legacy
     spin vars unused. Build clean, tty stress + functional tests green.
     Files changed: <list>. Committed as <sha>."
   - instructions: "Read impl-2.md and execute the instructions there.
     The working tree is at commit <sha> on branch `slurp`. Read
     `plan.md` first for the master plan and current TODO state."
