# 3code Testing Improvement Plan

Goal: make the test suite strong enough that a lazy, hallucination-prone agent
(deepseek-class) cannot ship a behavioral regression without seeing it fail.

## STATUS

The tty functional suite is at **14 OK / 11 FAILED** (24 total). The flicker
regression from commit 80361b8 is FIXED. The DRY unification is done. The
remaining 11 failures are pre-existing bugs unrelated to our commits.

### Commits so far

  a425974 isolate TMPDIR per fixture to stop session lock collisions
  391673e Phase 1: add assertion vocabulary to tty_expect.nim
  80361b8 refactor engine height to derive walk-up from live state; fix prompt echo erasure
  05d8bf1 fix bash tool flicker: renderFooter must not wipe live tool viewport
  36f225e unify queued-prompt transcript with emitUserSubmit (DRY)

## What was fixed

1. **Session lock collisions** (TMPDIR isolation). The failure set is now
   stable (deterministic) across runs.

2. **Engine height model** (engine.nim). Replaced the cached
   `rowsAboveCursorToFooterTop` + `footerRowsAboveEditor` fields (the
   "remember file.close" anti-pattern) with a single `paintedFooterRows`
   field. Walk-up is now derived at each paint site via `walkUp(ed)`:
   `editorRowsAboveCursor(ed) + paintedFooterRows + viewportHeight`. Killed
   the growth/shrink reconciliation math entirely.

3. **Prompt echo erasure** (fatprompt/runtime.nim emitUserSubmit). The prompt
   echo was written with `reserveFooter=false` and no trailing separator, so
   the spinner painted over it on the same row. Fix: added `\r\n\r\n` to the
   echo bytes and set `transcriptOwnsSpacing=true`. This fixed:
   - `simple one-turn prompt and reply` ✅
   - `every prompt first line survives a reasoning-ticker to content transition` ✅

4. **Bash tool flicker** (engine.nim renderFooter). Commit 80361b8 added
   `e.toolViewportRows = @[]` to `renderFooter`, which wiped the live bash-tool
   viewport during a footer repaint. A streamed line (`$ printf 'flicker-marker'`)
   got erased in one sync frame and redrawn in a later one → visible blank
   flash. Fix (05d8bf1): removed that line. `renderFooter` must PRESERVE the
   viewport; only `renderToolViewport` (replace) and `appendTranscript`
   (commit/clear) own the viewport lifecycle. `walkUp` already counts the
   viewport height, so erasing the right number of rows while rewriting the
   same viewport text is correct.
   - `bash tool output does not flicker blank on commit` ✅

5. **DRY: unified queued-prompt transcript** (36f225e). `commitUserPromptTranscript`
   (threecode.nim) was a near-duplicate of `emitUserSubmit` (runtime.nim) with
   a different (broken) spacing model. Replaced its body with a delegate call
   to `emitUserSubmit`; folded `receiptTouchesNextResponse = true` into
   `emitUserSubmit` so both submit paths share it. This is a structural fix
   (no test moved), but prevents the two paths from drifting again.

### IMPORTANT: the plan's original diagnosis was WRONG on two counts

- The **flicker** was NOT caused by the `\r\n\r\n` in emitUserSubmit. It was
  caused by `e.toolViewportRows = @[]` added to `renderFooter` in engine.nim.
  Proven by isolation: runtime.nim at 80361b8 + engine.nim at 391673e → no
  flicker. The `\r\n\r\n` is correct and must stay (it gives the prompt echo
  its separator row; with `transcriptOwnsSpacing=true` the engine trims nothing).

- **`consecutive turns never accumulate extra blank separator lines`** is a
  PRE-EXISTING bug. It fails on 391673e (pre-our-work) too. The double-blank
  is at END-OF-TURN (between the last token bar and the idle prompt), NOT at
  the prompt echo. Changing `\r\n\r\n` → `\r\n` does not affect it. The `\r\n`
  variant was reverted — keep `\r\n\r\n`.

## THEN: remaining pre-existing failures (11)

These are NOT caused by our commits (all fail on 391673e too). Investigate
each individually.

### Queued/multiline (5) — input/editing layer, NOT transcript commit

These fail BEFORE the transcript commit is reached. The failures are in live
editor visibility / queue-editing behavior during a turn. Confirmed by running
the suite before the DRY change: same failures, at the same `tty.expect` /
`expectInHistory` lines.

- `multiline prompt and queued multiline autosend` — fails at
  `expectInHistory "❯ queued line one"`: only the last editor line reaches the
  committed transcript. The queued multiline text isn't preserved (look at how
  `ieLine` events carry `ed.line.text` and how `queued` is captured in
  threecode.nim:~397 — "keep first line only").
- `queued prompt survives a second submit during one turn` — fails at
  `tty.expect "queued alpha queued beta"` (LIVE editor, line 678): after queuing
  "queued alpha" and typing more, the editor doesn't show the revised text.
  Queue-cancel-and-edit logic in fatprompt/runtime.nim (~line 1422, the
  `inputState.eventQueue` filtering).
- `editing a queued prompt keeps the text instead of wiping it` — same root.
- `interrupt during a queued mid-turn prompt sends the queue next` — fails at
  `expectInHistory "❯ queued prompt"`: queued prompt not committed after interrupt.
- `bare escape during a queued mid-turn prompt sends the queue next` — same root.

### Token / wizard (2)

- `active turn colon commands are controller handled` — fails looking for
  "no tokens used yet". The `:tokens` command during an active turn. Token-bar
  display issue.
- `idle provider add wizard is visible and masks input` — fails looking for
  masked input `********************`. Wizard masking issue.

### Golden diffs (3)

- `harness commands are transcript items` — golden diff
- `bash tool success and nonzero exit` — golden diff
- `non-bash tool transcript shapes` — golden diff

The golden diffs may resolve once the underlying bugs are fixed (the fixtures
are correct; they encode the non-buggy behavior). Investigate each individually.

### End-of-turn spacing (1)

- `consecutive turns never accumulate extra blank separator lines` — double
  blank row between the last token bar (row 16) and the idle prompt, with a
  stray `0%` token-bar fragment (row 19) in between. Inspect the `endTurn` /
  `endTurnAfterTranscriptAppend` transition in fatprompt/runtime.nim. The
  stable idle frame is what's checked.

## HOW TO RUN TESTS

```sh
# Build + run the tty functional test (the main behavioral suite):
env -u CI tools/test.sh test_tty_functional

# Run just the compiled test binary directly:
env -u CI timeout 120 ./build/tests/test_tty_functional

# After ANY source change, rebuild the stub binary before running tests:
env -u CI nim c -d:ssl -d:providerStub --threads:on \
  $(for p in unicodedb streamhttp ttty tinotify; do echo "--path:$(nimble path $p 2>/dev/null | head -1)"; done) \
  --path:src --hints:off --warnings:off -o:build/3code_stub src/threecode.nim
```

CI=1 is set in the environment which makes test.sh SKIP tty tests. Always
prefix with `env -u CI`. The PTY tests only run on Linux.

## KEY ARCHITECTURE NOTES

- The fat prompt footer (ticker + bar + editor) is volatile. Scrollback is
  append-only. The engine (engine.nim) owns cursor geometry for clearing the
  footer around transcript appends.
- `walkUp(ed)` in engine.nim derives the rows-to-move-up from live state:
  `editorRowsAboveCursor(ed) + paintedFooterRows + toolViewportRows.len`.
  Never cache it.
- `renderFooter` repaints the footer + editor and PRESERVES the live tool
  viewport. It must not clear `toolViewportRows`. (Bug 05d8bf1.)
- `renderToolViewport` REPLACES the viewport with new rows. `appendTranscript`
  COMMITS the viewport to scrollback and clears it. These three are the only
  owners of the viewport lifecycle.
- `emitUserSubmit` (runtime.nim) commits a prompt echo as scrollback and drops
  the editor. It is the normal submit path AND (now) the queued-prompt path,
  via `commitUserPromptTranscript` delegating to it.
- The fixtures in tests/fixtures/tty/*.txt are CORRECT and encode non-buggy
  behavior. Never regenerate them to match broken output.

## DECISIONS

- Fix real bugs in source; never weaken tests.
- The fixtures are the source of truth.
- Golden brittleness is deferred (will be fixed, not reduced, in a later pass).
- After all bugs are green, proceed with Phase 2 (thread assertions through
  tests) and Phase 3 (shakedown + failure messages) from the original plan.
