# Plan: single-threaded GUI renderer (kill the ticker-line race)

Supersedes the per-symptom hunt in `TICKER_RACE_HANDOFF.md`. The handoff
documents the race in detail; this plan replaces the racy architecture
instead of patching its bookkeeping.

## The root problem

Two background threads repaint the same screen region (the volatile footer
+ editor area) on their own schedules, with no coordination with the
controller's footer-height transitions:

- `spinnerLoop` (runtime.nim:782, 80ms) calls `renderFooter`.
- `barTickLoop` (runtime.nim:896, 250ms) calls `renderFooter` and mutates
  `toolViewportRows[0]` via `updateToolViewportSymbol`.

The controller thread also calls `renderFooter` / `renderToolViewport` /
`renderLiveContent` / `appendTranscript` at turn boundaries.

`terminalWriteLock` (terminal.nim) serializes the *bytes*, but the race is
not interleaved bytes — it is **stale view state read mid-frame**. A spinner
frame sets `paintedFooterRows`; the controller then tears the footer down in
`prepareAssistantContentStart`; a spinner frame already in flight leaves
`paintedFooterRows` tall; the next `walkUp` (engine.nim:112) over-erases
into committed scrollback. "One line per background frame" = each stale
repaint eats one more row. The `paintedFooterRows` / `noteNoFooter`
bookkeeping narrows this window but cannot close it: two writers of the
same region can never be made race-free by bookkeeping alone.

A second, analogous race exists in the tool viewport: `barTickLoop` rotates
the command symbol in `toolViewportRows[0]` while `turns.nim:runBashWithViewport`
appends streamed output lines and re-renders the viewport from the
controller thread.

## The fix: one animation thread owns all volatile rendering

Collapse `spinnerLoop` and `barTickLoop` into a single **GUI animation
thread** that is the *only* writer of `renderFooter` /
`renderToolViewport` / `renderLiveContent`. The controller sets desired
frame state under a lock and signals the GUI thread (dirty flag); the GUI
thread composites and paints on a fixed cadence (spinner 80ms, bar-tick
250ms, or on-demand for test frame mode). Height transitions
(`startContent`, `endTurn`) happen with the controller holding the floor:
it stops the GUI thread, performs the atomic transition, restarts it.

The input thread's editor redraw (`reserveEditorFooterForRedraw`) already
reads shared spinner/barTick flags to pick a frame model — that stays, but
it reads the *single* source of truth the GUI thread owns, so it can no
longer see a torn spinner-vs-barTick state.

## Why this kills the ticker race

With one writer, `paintedFooterRows` is set only by the GUI thread's own
`renderFooter`. The controller's height-transition paths
(`prepareAssistantContentStart`, `endTurn`) stop the GUI thread *before*
reading `paintedFooterRows` / calling `walkUp`, so the value is guaranteed
current at the moment of the erase. No stale value can survive a
transition because the only writer is quiesced.

## Stages (see impl-N.md for each)

1. **impl-1.md — Extract the animation state model.** Introduce a
   `FrameModel` (the union of spinner / bar-tick / live-content / clear
   frames) held under one lock, with setter procs the controller calls.
   The existing `spinnerLoop`/`barTickLoop` read from it instead of their
   scattered atomics. No thread change yet — this just centralizes the
   state the GUI thread will own. Build + tty tests green.

2. **impl-2.md — Single GUI animation thread.** Replace `spinnerLoop` and
   `barTickLoop` with one `guiLoop` that paints whatever the `FrameModel`
   says, on a merged cadence. `startSpinner`/`stopSpinner`/`startBarTick`/
   `stopBarTick` become state setters + a dirty signal, not thread
   create/join. `startContent`/`endTurn` quiesce the single thread for the
   transition. Build + tty tests green.

3. **impl-3.md — Route tool-call animation through the GUI thread.**
   `turns.nim:runBashWithViewport`'s `renderToolViewport` and
   `updateToolViewportSymbol` move to the GUI thread: the controller pushes
   viewport rows into the `FrameModel`, the GUI thread composites +
   paints. Removes the `toolViewportRows[0]` mutation race. Build + tty
   tests green; the `test_spinner_race_stress` path still passes.

4. **impl-4.md — Integrate, stress, reproduce-or-close.** Run the full tty
   suite, the spinner-race stress test, and the hy3 reproduction harness
   from `TICKER_RACE_HANDOFF.md` step 1 (reasoning-heavy prompts under
   tmux). If the race is gone, close it. Remove the now-dead
   `barTickStart`/`commandSymbolIndex` atomics and the
   `testTickerControl` two-thread dance if it collapses. (impl-2 already
   removed `barTickLock`/`barTickBase`.)

## Notes for the chunked execution

- Each `impl-N.md` is self-contained: a fresh-context agent reads it +
  the "Read first" files and executes. After verifying (build + tests),
  it updates the todo list in this file with state + learnings, commits,
  then calls `context_clear` with a handoff summary pointing at
  `impl-<N+1>.md`.
- The branch is `slurp` (not `main`). Build with `nimble build` in the
  slurp cwd; run the local `./3code` for repros (the `~/.local/bin/3code`
  symlink points at `~/p/3code/3code` on main, NOT slurp's binary).
- `~/.local/bin/3code` must NOT be repointed — repros use `./3code`.
- Leave untracked `TICKER_RACE_HANDOFF.md` and `slurp-report.md` alone.
- Do not auto-install or auto-push. Commit with short one-line messages,
  no coauthor trailer.
- tty test command: `nimble test tests/tty/test_spinner_race_stress.nim`
  for the stress test; `nimble test` for the full suite (slow).

## TODO

- [x] **impl-1: Extract the animation state model (`FrameModel`).**
      Status: DONE. Committed.
      Learnings:
      - The `else:` branch of the original `let frameModel = if/elif/else`
        in `reserveEditorFooterForRedraw` sat at col 2 (sibling of `let`),
        not col 4 — Nim's formatter quirk for multi-line if-expr. The
        `case` rewrite puts `of amIdle` at col 4, which is cleaner.
      - `currentFrameFromModel` and `setSpinTicker` access `fatPromptState`
        (GC'd global), so they need `{.cast(gcsafe).}` around the body —
        the original procs had it; the migration must preserve it.
      - The bar-tick elapsed suffix (`  Ns`) is ephemeral and recomputed
        locally each tick from the base label. The model stores only the
        base. Chunk 2 (single thread) can keep this local computation.
      - `commandSymbolIndex` and `barTickStart` left as-is; chunk 3 owns
        the tool-viewport symbol story.
      - Legacy spin vars (`spinLabelShared` etc.) are now write-only
        mirrors in the setters; all reads go through `getFrameModel()`.
        Chunk 2 can delete them.
- [x] **impl-2: Single GUI animation thread (merge spinnerLoop +
      barTickLoop).** Status: DONE. Committed.
      Learnings:
      - The merge was mechanical once impl-1 had centralized state: the
        two loops already shared the same `renderFooter` call shape, so
        `guiLoop` is just `spinnerLoop`'s cadence (80ms) wrapping a
        `case m.mode` that dispatches to each loop's old paint body.
        No new locks, no dirty-signal complexity needed — polling
        `frameModelShared.mode` at 80ms is cheaper than a condvar and
        the test-frame handshake was already poll-based.
      - `commandSymbolIndex` (a `var`) and `nextCommandSymbol` (a proc)
        had to be hoisted above `guiLoop` — they used to live just above
        `barTickLoop`, which was the only caller. Nim has no forward decl
        for module-level vars, so the var moved up to the GUI-thread
        block; the proc moved with it (a single duplicate left behind
        had to be cleaned up — patch-tool's sequential edits need care
        when the same text appears twice).
      - The test-frame handshake needed zero changes beyond the guard:
        `requestTestSpinnerFrame`'s `if not spinnerRunning` became
        `if not guiRunning`, and the `while spinnerRunning` poll loop
        became `while guiRunning`. After `startContent`'s `stopSpinner`+
        `stopBarTick`, `guiRunning == false`, so the
        `requestTestSpinnerFrame` calls in `apiReasoningDelta`/
        `apiContentDelta` early-return — no deadlock, no stale frame.
      - `spinnerCleanupBytes` exit-cleanup stayed in `guiLoop`'s
        post-loop block (the `if not inputThreadRunning` teardown).
        `stopSpinner`'s explicit `clearFooterFrame(2)` render covers the
        normal controller-driven teardown; the cleanup bytes are the
        thread-exit-without-controller path. Both coexist; tests pass
        with both. No regression observed.
      - `barTickBase`/`barTickLock` deleted cleanly — nothing read
        `barTickBase` after `setAnimLabel(base)` wrote the base into
        `frameModelShared.label`. `barTickStart` stays (guiLoop +
        `reserveEditorFooterForRedraw` both compute the elapsed suffix
        from it).
      - `stopBarTick` now stops the *entire* GUI thread, not just bar-
        tick. This is correct because spinner and bar-tick are mutually
        exclusive in practice (startContent stops both idempotently),
        and `startSpinner`/`startBarTick` both `ensureGuiStarted()` to
        restart. The `withBarTick` RAII template still works because
        `stopBarTick`'s `if m.mode != amBarTick: return 0` guard makes
        it a no-op when the spinner path already stopped the thread.
      - All three required tests pass: stress (64.75s), functional
        (64.24s), resize_ticker (12.59s). Build clean.
      - Open for chunk 3: `guiLoop`'s `amBarTick` branch still calls
        `termengine.updateToolViewportSymbol` directly — that's the
        chunk-3 race (controller appends viewport rows + re-renders
        while the GUI thread rotates the symbol). The chunk-3 work is
        to push the viewport rows into `FrameModel` so the GUI thread
        owns the whole composite.
- [x] **impl-3: Route tool-call animation through the GUI thread.**
      Status: DONE. Committed.
      Learnings:
      - Added `viewportRows: seq[string]` to `FrameModel` + `setAnimViewport*`
        setter. The controller's `runBashWithViewport.renderView()` now
        pushes rows into the model instead of calling `renderToolViewport`
        directly; the GUI thread's `amBarTick` branch owns the whole
        viewport+footer composite (reads rows from the model, applies the
        rotating command symbol to a LOCAL copy, paints via
        `renderToolViewport`). This removes the two-writer race on
        `engine.toolViewportRows`.
      - The tty harness captures frames via `emitTestFrameEvent()` ('f'
        byte) which fires AFTER `renderView()`. Since the viewport render
        moved to the GUI thread's 80ms loop, a **viewport paint handshake**
        (`viewportPaintRequested`/`viewportPainted` atomics +
        `requestViewportPaint*()`) was needed: `renderView()` requests a
        paint and blocks for the ack in test mode so the harness captures
        each streamed line as a discrete frame (no stale frame before the
        paint). The `guiLoop` top-of-loop test-mode wait now watches BOTH
        the spinner handshake and the viewport handshake.
      - The command-symbol rotation (`$`/`€`/`£`/`¥`) had two subtleties:
        (1) the index must NOT advance in test mode — the old `barTickLoop`
        gated `fetchAdd` behind `if advance:` which in test mode only fired
        on a spinner-tick (`advanceTicker`), so the bash stream path (which
        never calls `advanceTicker`) kept the index at 0 → every captured
        frame shows `$`. Replicate this with `if not testFrameMode():
        fetchAdd`. (2) the exit-failure icon `Ø` (baked by `commandIcon`
        once `exitCode > 0`) must not be overwritten by the rotation — the
        GUI thread skips the swap when `rows[0].startsWith("Ø")`. Without
        this, the nonzero-exit frame showed `$` instead of `Ø`.
      - `updateToolViewportSymbol` deleted from engine.nim (zero callers
        after the GUI thread operates on a local copy). `clearToolViewport`
        kept (clean public API, no external callers now but harmless);
        `unicode` import dropped from engine.nim (was only used by the
        deleted proc).
      - The exception-path `clearToolViewport` in `runBashWithViewport`
        became `setAnimViewport(@[])` + `requestViewportPaint()` — clears
        the composite via the model + a paint request rather than the
        controller rendering directly. `stopBarTick` also clears the model
        viewport rows before stopping the GUI thread (prevents a one-frame
        stale flash on the next tool call).
      - All three required tests pass: stress (~64s), functional (~time),
        resize_ticker (~13s). Build clean.
- [x] **impl-4: Integrate, stress, reproduce-or-close.**
      Status: DONE. Committed.
      Learnings:
      - All three tty tests green: stress (40.74s), functional (47.06s),
        resize_ticker (6.01s). Build clean. No source changes needed —
        impl-3 left the architecture in its final intended state.
      - **Dead-code audit: nothing collapsed.** Every symbol the task
        flagged as a candidate for removal is still actively used:
        `commandSymbolIndex` (advanced by `guiLoop`'s `amBarTick`
        branch line 916, reset by `setCommandStatusActive` line 1133,
        read by `nextCommandSymbol` line 76); `nextCommandSymbol`
        (called by `guiLoop` line 914 + `turns.nim` line 92);
        `commandStatusActive` (set by `turns.nim`/`setCommandStatusActive`,
        read by `guiLoop` line 901); `barTickStart` (elapsed-suffix in
        `guiLoop` line 888 + `reserveEditorFooterForRedraw` line 565).
        The `testTickerControl*` machinery is the **test harness's**
        ticker driver (`advanceTicker()` in `tty_expect.nim` sends 't'
        bytes that `testTickerControlLoop` reads →
        `requestTestSpinnerFrame`); it has NOT collapsed and must stay.
      - **Reproduction: not reproduced; user took over further repro.**
        The hy3 reproduction harness (`/tmp/repro_ticker_hy3.sh`,
        novita.tencent/hy3 confirmed live + streaming reasoning) ran
        reasoning-heavy prompts under tmux across multiple turns;
        content accumulated monotonically (7→11→153→155 content lines),
        no missing lines. At 40 cols the scrollback overflowed the
        200-line capture cap (each turn ~80 wrapped lines → old content
        scrolls off the top), which the naive diff flagged as "missing";
        this is normal terminal scroll-off, not the race. The race's
        signature (recent lines above the prompt vanishing one-by-one)
        did not appear; settled committed scrollback was complete and
        correct. The single-GUI-thread fix stands.
