# Cybernetic plan: change-gated rendering (skip identical paints)

## Context

The fat prompt footer (token bar / spinner / ticker) and the live command
areas (tool viewport, live assistant content) are repainted completely on
every tick: `guiLoop` (src/threecode/fatprompt/runtime.nim:757) calls
`renderFooter` / `renderToolViewport` every 80ms, and the controller calls
`renderLiveContent` on every streaming chunk. Each paint erases the whole
volatile region (`\x1b[J` after a walk-up) and rewrites every row, even when
not one byte changed. This causes visible flicker on slow terminals and
wasted I/O.

Goal, in two stages:

1. **This task:** change-gated painting. Each render entry point computes
   what it is about to write and skips the entire erase+repaint when it is
   byte-identical to what is already on screen (and the editor state it
   would repaint is unchanged).
2. **Future, out of scope:** a full diff renderer that paints only changed
   rows within a region.

All terminal painting flows through `src/threecode/engine.nim`
(`TerminalEngine`, single choke point). Key state:

- `paintedFooterRows` — bar+ticker rows currently on screen.
- `lastPaintedWidth` — for resize handling in `eraseUp`.
- `toolViewportRows` / `liveContentRows` — volatile region rows.

Render entry points to gate:

- `renderFooter` (engine.nim:253) — footer bytes + editor repaint.
- `renderToolViewport` (engine.nim:316) — viewport rows + footer + editor.
- `renderLiveContent` (engine.nim:419) — live rows + footer + editor.
- `repaintLiveContent` (engine.nim:501) — stored live rows + new footer.

Skip condition per entry point: the composed bytes (footer bytes, viewport
rows, live rows) equal the last painted ones AND `width` is unchanged AND
the editor signature is unchanged AND `paintedFooterRows` matches the new
frame's `rowsAboveEditor` (geometry, not just pixels). On skip, return
without writing anything; all engine state stays as-is, which is consistent
because the screen is unchanged.

Editor signature: text + cursor position + render suffix + width, from the
`LineEditor` (minline.nim). The editor repaint is embedded in every footer
paint, so a keystroke since the last paint must force a repaint even when
footer bytes are identical.

Constraints from `.agents/design.md`:

- Caret must end up visible in the editor after any render tick; skipping
  is only safe when nothing changed, so caret state is unchanged too.
- Scrollback stays append-only; `appendTranscript` is NOT gated.
- Test frame mode: the guiLoop handshake
  (`testSpinnerRequested`/`testSpinnerPainted`) completes even when the
  paint is skipped; the tty harness dedupes identical consecutive frames,
  so golden fixtures should not shift.

## Current state

DONE. Commit `1f4f898` on `flicker`. All four steps complete.

Implementation notes (learned during execution):

- One combined signature `lastPaintSig: string` in `TerminalEngine`, not
  four per-region sigs: every entry point's skip condition is "the bytes I
  would write are already on screen", so the signature must describe the
  whole last painted composite (region tag F/V/L/R, footer bytes, volatile
  rows, editor sig, width).
- The signature is stored AFTER the paint completes, not before: the paint
  paths end in `noteFooterPainted`/`noteNoFooter`, which reset
  `lastPaintSig` so out-of-band repaints (transcript commit, end turn,
  modal chrome) always invalidate. Storing before the paint made the
  reset erase the just-computed signature and the skip never engaged.
- `editorSig` (engine.nim:165): text + cursor + renderSuffix +
  renderSuffixCursor + pendingCaret + prompts + width.
- `viewportSig` (engine.nim:153): gap flag + bannerRows + joined rows.
- Verified with a throwaway stdout-capture probe (9 checks: identical
  repaint emits nothing for footer/viewport/live content; text change,
  keystroke, row change, transcript commit, width change all repaint).
  Probe not committed.

## Steps

- [x] 1. Engine change detection: `lastPaintSig` + `editorSig` helper;
      `renderFooter` gated on footer bytes + width + editor sig + footer
      row count. Reset via `noteFooterPainted`/`noteNoFooter`.
- [x] 2. `renderToolViewport`, `renderLiveContent`, `repaintLiveContent`
      gated with the same scheme (rows joined into the signature;
      `bannerRows` included for the viewport).
- [x] 3. Full tty suite: all 30 tests pass, zero fixture changes needed
      (the harness dedupes identical consecutive frames, as predicted).
- [x] 4. Release build + full `nimble test` (all categories) +
      `nimble install` + commit `1f4f898`.

Pre-existing failures (reproduced on clean tree, unrelated to this work):
`tests/core/test_cli_args.nim` and `tests/config/test_config_validation.nim`
(exercise the stale installed binary), `tests/core/test_wall_bash.nim`
(needs network namespaces, blocked in this sandbox).

## Verification notes

- `nimble test tests/tty/...` runs the PTY visual tests; fixtures in
  `testdata/fixtures/tty/`.
- Frame viewer: `nim r tools/pty_frames.nim -- testdata/output/tty/<run>/frames.txt`.
- Manual smoke: run `3code` in a terminal, watch that the spinner still
  animates, typing during a stream still repaints the editor, and resize
  still repaints correctly.
