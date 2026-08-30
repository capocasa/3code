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

Step 1 in progress: adding signature state + skip logic to engine.nim.

## Steps

- [ ] 1. Engine change detection: add `lastFooterBytes`, `lastViewportSig`,
      `lastLiveSig`, `lastEditorSig` (or one combined signature) to
      `TerminalEngine`; add an `editorSig` helper. Gate `renderFooter`:
      skip when footer bytes + width + editor sig + footer row count are
      unchanged. Reset signatures wherever the screen is invalidated
      (resize path already forces repaint via width change; verify).
- [ ] 2. Gate `renderToolViewport`, `renderLiveContent`,
      `repaintLiveContent` with the same scheme (rows joined into the
      signature; `bannerRows` included for the viewport).
- [ ] 3. Run the tty test suite (`nimble test` tty category). Review every
      fixture failure in the frame viewer; fix regressions, deliberately
      update fixtures only if the new frames encode the intended behavior.
- [ ] 4. Full build + `nimble test` (all categories), `nimble install`,
      commit.

## Verification notes

- `nimble test tests/tty/...` runs the PTY visual tests; fixtures in
  `testdata/fixtures/tty/`.
- Frame viewer: `nim r tools/pty_frames.nim -- testdata/output/tty/<run>/frames.txt`.
- Manual smoke: run `3code` in a terminal, watch that the spinner still
  animates, typing during a stream still repaints the editor, and resize
  still repaints correctly.
