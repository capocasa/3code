# Cybernetic Plan: Option B — unify the bash viewport and transcript byte paths

## Context

The bash tool has two independent code paths that paint the *same*
command output at different lifecycle stages, and they diverge. This is
the root cause behind the "volatile output is replaced by a rendered
output" observation (issue 1): when a bash tool commits, the live
volatile viewport is erased and the output is repainted from the
transcript path, and the two paths disagree on five details. Option A
(the already-shipped fix) patched the worst symptom (the missing
inter-item separator). This plan eliminates the repaint entirely by
making the two paths produce identical bytes, so the commit becomes a
"silent append" of internal state with no visual change.

### The five divergences (confirmed by raw byte trace, see git history)

These are why the painted pixels cannot today be frozen and declared
scrollback:

1. **Banner icon.**
   - Live viewport: rotating currency symbol via `commandSymbolIndex`
     (`$`/`€`/`£`/`¥`, runtime.nim:75) or `Ø` on failure, set in
     `commandIcon` (toolstream.nim:41).
   - Transcript: static `toolIcon` per `ActionKind` (`$`, display.nim:478)
     via `toolBannerBytes` (display.nim:490).

2. **Output wrapping algorithm.**
   - Live viewport: `charWrapAnsi` (hard char break at width),
     util.nim:592, via `wrappedRowsAt` (toolstream.nim:56).
   - Transcript: `wrapAnsi` (greedy word-wrap on spaces), util.nim:561,
     via `wrappedSubtleBytes` (display.nim:196).

3. **Banner wrapping.** Both call `bannerWrapRows` (util.nim:631), but
   the viewport feeds it `commandIcon & " "` while the transcript feeds
   it `toolIcon(kind) & " "`. When the icons differ (divergence 1), the
   first-line width budget differs, so continuation rows can break at
   different points.

4. **Truncation marker.**
   - Live viewport: `omittedLine()` (toolstream.nim) recomputed each
     stream line, shows live hidden count.
   - Transcript: `toolResultBytes` (display.nim:502) re-derives from
     full `res`, same `StreamMaxLines` cap, regenerated text.

5. **Color placement.**
   - Live viewport: SGR applied per-row at write boundary in
     `writeToolViewportRows` (engine.nim:107): `OffWhiteFg` for banner
     rows, `GreyFg` for output.
   - Transcript: SGR baked into bytes per chunk in `wrappedSubtleBytes`
     (`GreyFg` per output chunk) and `toolBannerBytes` (`OffWhiteFg`).

### The target shape

One function builds the rendered rows for a bash tool given (banner,
output-lines, exit-code, idx, terminal-width). Both the live viewport
paint and the transcript commit call it. The bytes are then identical;
committing is a state-only append (mark the rows as scrollback, stop
erasing them). The repaint vanishes.

### Key code locations

- `src/threecode/toolstream.nim` — `StreamingView`, `viewportRowsAt`,
  `bannerRowCountAt`, `visibleOutputLines`, `omittedLine`,
  `commandIcon`, `wrappedRowsAt`. The viewport row builder.
- `src/threecode/display.nim` — `toolBannerBytes` (490),
  `toolResultBytes` (502), `toolTranscriptBytes` (520, 531),
  `wrappedSubtleBytes` (196), `trimBoundaryBlank` (184). The transcript
  byte builder.
- `src/threecode/engine.nim` — `renderToolViewport` (203),
  `writeToolViewportRows` (107), `appendTranscript` (448),
  `toolViewportRows`/`toolViewportBannerRows`/`toolViewportHasGap`
  fields. The two paint paths.
- `src/threecode/fatprompt/runtime.nim` — `guiLoop` amBarTick branch
  (911), `setAnimViewport` (306), `requestViewportPaint` (357),
  `commandSymbolIndex`/`nextCommandSymbol` (71-77). The GUI-thread
  viewport ownership.
- `src/threecode/turns.nim` — `runBashWithViewport` (84),
  `renderView` (90), `appendItem` call site (505). The controller.
- Golden fixtures: `testdata/fixtures/tty/bash_tool_visual_test.txt`,
  `bash_tool.txt`. Several frames will change shape (icon unification,
  wrap unification) and must be re-captured.

## Current state

Not begun. The inter-item separator jump is now fixed for BOTH live
paint paths (shipped, see below):

- The live bash **viewport** carries a gap row matching committed
  scrollback spacing, and `walkUp` accounts for it via
  `viewportGapRows`/`toolViewportHasGap`.
- The live **assistant content** path (`renderLiveContent` /
  `repaintLiveContent`, the `liveContentRows` mechanism) now carries the
  same gap via `liveContentHasGap`/`liveContentGapRows`, also counted by
  `walkUp` and by the reflow branch in `renderToolViewport`.

This closed the user's actual complaint: assistant prose streaming
immediately below a committed bash tool output (or below the user
prompt) was flush against the line above during the live phase, then
jumped down one row at commit when the separator was inserted. The
prose now sits one blank row below the prior item from the first
streaming chunk, and stays on that row through commit. Verified by a
row-position probe (prose row stable live == committed) and the
observation that the golden fixtures encoded the old flush-then-jump
behavior, which the fix removes.

The remaining work (this plan) is the deeper unification that makes
the commit a no-op repaint, eliminating the four byte-level
divergences (icon, wrap, truncation, color) that still cause a subtle
repaint at commit.

## Decision log

- **Do NOT attempt to freeze the painted volatile bytes and call them
  scrollback without unifying the byte builders.** The divergences make
  that produce permanently-wrong scrollback (wrong icon, wrong wrap).
  This was the conclusion of the investigation that produced Option A.
- **Pick ONE wrapping algorithm as the single source of truth.**
  Candidate: `charWrapAnsi` (the viewport's), because it is
  deterministic across terminal widths and matches what a terminal
  itself would do. `wrapAnsi` (word-wrap) is nicer to read but
  re-wraps non-trivially on resize. Unifying on `charWrapAnsi` means
  the golden fixtures shift to char-wrap; unifying on `wrapAnsi` means
  the viewport gains word-wrap. Decide in step 1; default to
  `charWrapAnsi` to keep the live behavior stable.
- **The rotating currency symbol (`commandSymbolIndex`) is a live-only
  flourish.** The transcript never had it. To unify, the live viewport
  must drop it (paint the final icon always) OR the transcript must
  gain a way to render "the icon that was live." Simplest: drop the
  rotation, always paint the final icon. This loses the ticker effect
  but removes a whole divergence for free. If the ticker is wanted,
  the unified builder takes the symbol as a parameter and the
  transcript commit passes the final symbol the viewport used.
- **`toolViewportHasGap` (Option A's field) becomes redundant once the
  paths are unified**, because the commit stops repainting. Remove it
  as part of this work (it was always a band-aid).

## Steps

- [ ] 1. **Decide and lock the wrapping algorithm.** Write a 10-line
      throwaway comparison of `charWrapAnsi` vs `wrapAnsi` for the
      existing golden fixture inputs. Record the choice and its
      rationale in this plan's decision log. Default: `charWrapAnsi`.
      (Decision step, no production code.)

- [ ] 2. **Write the unified row builder.** In `toolstream.nim`, add a
      proc that takes `(banner, outputLines: seq[string], exitCode,
      idx, termW)` and returns `(rows: seq[string], bannerRowCount:
      int)`, using the chosen wrap algorithm and a single
      icon-resolution rule. Both `StreamingView.viewportRowsAt` and
      the transcript path will delegate to it. Keep
      `commandSymbolIndex` as a parameter (caller-supplied symbol) so
      the live path can still rotate while the commit passes the final
      symbol; OR drop rotation entirely per the decision.

- [ ] 3. **Route the transcript path through the unified builder.**
      `toolResultBytes` (display.nim:502) and `toolBannerBytes`
      (display.nim:490) for `akBash` must produce byte-identical
      output to the unified builder. This is the step that makes the
      repaint a no-op. Verify with a unit test that feeds identical
      inputs to both and asserts equality.

- [ ] 4. **Make the bash commit a silent append.** In
      `appendTranscript` (engine.nim:448) and/or a new
      `commitToolViewport` path, when the incoming transcript bytes
      match what the viewport currently paints, skip the erase+repaint
      and instead just promote `toolViewportRows` to scrollback state
      (set `hasScrollback`, clear the viewport tracking). The GUI
      thread must be told the viewport is no longer volatile so its
      next tick does not erase it. This is the delicate concurrency
      step; the GUI-thread ownership model in `runtime.nim:911` is the
      thing to coordinate with.

- [ ] 5. **Reconcile `toolViewportHasGap`** with the silent append.
      The field currently makes the live viewport carry the
      inter-item gap row so the commit doesn't push the item down
      (the jump fix). Once the commit stops repainting (step 4),
      the gap must still be painted during the live phase and then
      become committed scrollback without an erase — decide whether
      the field stays, becomes a scrollback-row promotion, or folds
      into the unified builder's output.

- [ ] 6. **Re-capture the golden fixtures.**
      `bash_tool_visual_test.txt` and `bash_tool.txt` will change
      (icon unification, wrap unification). Run the tty test, let it
      write the `_actual.txt`, diff against the golden, sanity-check
      the diff matches the expected divergences, then accept. Watch
      for the "scrollback wipe" guard test (`streaming bash viewport
      never wipes scrollback lines above it`) — the silent append
      changes the erase geometry and could regress it.

- [ ] 7. **Add a regression test: commit is visually a no-op.** Assert
      on the raw sync-frame stream (like the existing flicker test in
      test_tty_functional.nim) that the frame which commits a bash
      tool contains NO erase (`ESC[J`) of the viewport region. This is
      the direct, durable assertion that the repaint is gone. Without
      it, `stripFrameBlanks` in the golden comparison will hide a
      regression (this is exactly why the original separator bug
      escaped the suite).

- [ ] 8. **Full suite + review.** `nimble test`, release build, diff
      review. Confirm `toolViewportHasGap` is gone, the unified
      builder has exactly one caller for each path, and no dead
      viewport-only wrapping code remains.

## Notes

- The flicker regression test (`bash tool output does not flicker
  blank on commit`) already asserts an erase-then-redraw pair does not
  exist. Step 7 strengthens this from "no blank flash" to "no repaint
  at all." Keep both; they guard different invariants.
- The GUI thread re-wraps at the live width each tick
  (runtime.nim:926). The unified builder must remain width-parametric
  for this to keep working after unification.
- macOS (stefani VM) has different terminal-width assumptions; the
  wrap-algorithm choice in step 1 should be checked there before
  locking. See `.agents/osx-testing.md`.
