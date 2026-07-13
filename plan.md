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
   `barTickLock`/`barTickBase`/`barTickStart`/`commandSymbolIndex`
   atomics and the `testTickerControl` two-thread dance if it collapses.

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
- [ ] **impl-2: Single GUI animation thread (merge spinnerLoop +
      barTickLoop).** Status: not started. Depends on impl-1.
      Learnings: (none yet)
- [ ] **impl-3: Route tool-call animation through the GUI thread.**
      Status: not started. Depends on impl-2.
      Learnings: (none yet)
- [ ] **impl-4: Integrate, stress, reproduce-or-close.**
      Status: not started. Depends on impl-3.
      Learnings: (none yet)
