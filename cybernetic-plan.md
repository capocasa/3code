# Cybernetic plan: fix missing blank row after first submit

## Context

Bug: after the FIRST prompt submit, the row that held the `○0%` token bar
collapses away instead of surviving as an empty line. The committed echo
`❯ <prompt>` lands flush under the welcome hint instead of one blank row
below it. Later turns in the same session separate correctly. Full repro
detail in `reproduction.md`.

Root cause (confirmed at the byte level via ttty replay of a real-xterm
capture, `/tmp/probe2`): the welcome banner + hint are painted RAW in
`display.welcome()` (src/threecode/display.nim:705) before the input thread
and engine frame model are up, so the engine's `hasScrollback` flag stays
false even though the hint occupies a real row. `writeTranscriptItem`
(src/threecode/engine.nim:674) only prepends the inter-item `\r\n`
separator `if e.hasScrollback`, so the first commit skips it and the echo
lands flush. The erase/walk-up geometry was always correct (this is why
five prior geometry patches failed and the DSR probe reported the model
internally consistent); the missing piece was the separator gate.

## Fix

- Added `termengine.noteScrollbackExists()` (src/threecode/engine.nim) —
  registers `hasScrollback = true` without writing bytes.
- Call it in src/threecode.nim right after `welcome(prof)`, so the first
  transcript commit prepends the blank-row separator.

## Current state

- Reproduction committed: `reproduction.md` +
  `tests/tty/test_first_submit_blank_row.nim` (reasoning on + off). Both
  FAILED before the fix (echo flush under hint), both PASS after.
- Fix implemented in src/threecode/{engine.nim,threecode.nim}.
- Verified on the REAL-XTERM byte stream (ground-truth surface) via
  `/tmp/hintcheck/fifo_5s.sh` + `/tmp/probe2`: hint row 9, BLANK row 10,
  echo row 11, stable 3/3 runs. Screenshot OCR confirms hint/blank/echo.
- Related geometry tests still green: test_first_prompt_overwrite,
  test_repro_spacing.
- `nimble test` running in background (pid was 1599713, log
  /tmp/nimble_test.log). tty category was passing when last checked.

## Steps

- [x] Write reproduction.md (real-xterm harness + OCR + expected vs actual)
- [x] Reproduce in ttty (test_first_submit_blank_row.nim, reasoning on+off)
- [x] Diagnose root cause (hasScrollback never set for raw welcome paint)
- [x] Implement fix (noteScrollbackExists + call after welcome)
- [x] Verify ttty test passes both reasoning states
- [x] Verify real-xterm byte stream + screenshot (3/3 stable)
- [ ] nimble test to completion (73 PASS/0 FAIL baseline)
- [ ] Commit fix + test
