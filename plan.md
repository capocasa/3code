# 3code Testing Improvement Plan

Goal: make the test suite strong enough that a lazy, hallucination-prone agent
(deepseek-class) cannot ship a behavioral regression without seeing it fail.

## STATUS

The tty functional suite is at **22 OK / 3 FAILED** (25 total). The goal is
to fix them all, one or two at a time, committing each verified fix. The
remaining 3 are NOT code regressions; they are content-overflow on the
fixed 40-row test terminal (golden brittleness). Details in the REMAINING
section below.

### Commits so far

  a425974 isolate TMPDIR per fixture to stop session lock collisions
  391673e Phase 1: add assertion vocabulary to tty_expect.nim
  80361b8 refactor engine height to derive walk-up from live state; fix prompt echo erasure
  05d8bf1 fix bash tool flicker: renderFooter must not wipe live tool viewport
  36f225e unify queued-prompt transcript with emitUserSubmit (DRY)
  8048e35 fix idle-submit input race: unpark input thread after editor clear, not at poll
  b5b05f2 fix end-of-turn double blank: final item lets footer own the gap row
  0c990f5 update stale other_tools fixture: add welcome hint line at all banners

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

6. **Idle-submit input race** (8048e35). `pollInputEvent` eagerly unparked the
   input thread the moment the controller drained an idle-submitted line —
   BEFORE the controller cleared the editor and called `beginTurn`. The thread
   resumed reading keystrokes into stale editor text, so the next prompt
   merged into the previous one (`start active command turn:tokens` instead of
   a clean `:tokens`; `queued alpha` + ` queued beta` lost). Fix: removed the
   unpark from `pollInputEvent`; the consuming path now explicitly calls
   `releaseIdleSubmittedInput` (idle) or `beginTurn` (turn) AFTER clearing the
   editor. Added `releaseIdleSubmittedInput` to the no-provider path
   (threecode.nim) and the whitespace-only-empty path (ui.nim readInput).
   This fixed SIX tests at once:
   - `active turn colon commands are controller handled` ✅
   - `queued prompt survives a second submit during one turn` ✅
   - `editing a queued prompt keeps the text instead of wiping it` ✅
   - `interrupt during a queued mid-turn prompt sends the queue next` ✅
   - `bare escape during a queued mid-turn prompt sends the queue next` ✅
   - (`idle provider add wizard` was NOT fixed by this — see below)

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
  variant was reverted — keep `\r\n\r\n`.  **NOW FIXED** in b5b05f2 (see below).

## FIXED THIS ROUND (2 tests)

7. **End-of-turn double blank** (b5b05f2, turns.nim). The final assistant
   item before idle ended its transcript bytes with `\r\n\r\n`, and the
   engine ALSO added its separator row when reserving the footer, doubling
   the gap. Fix: `commitAssistantItem` gained a `finalBeforeIdle` flag; when
   set, it calls `finishFinalTranscriptItem` (ends bytes with `\r\n` only)
   and passes `transcriptOwnsSpacing = true` so the engine skips its own
   separator. The footer's own gap/ticker row is the visible separator.
   - `consecutive turns never accumulate extra blank separator lines` ✅

8. **Stale other_tools fixture** (0c990f5). `other_tools_visual_test.txt`
   lacked the `type a prompt. :help for commands. :q or Ctrl-D to exit.`
   welcome-hint line that `welcome()` emits whenever the profile has a name
   (display.nim:784). All OTHER fixtures (simple, bash_tool, multiline,
   harness) already had it; this one was generated before the hint existed.
   Added the hint line at all 4 banners. Legitimately stale fixture (correct
   program behavior, not a regression).
   - `non-bash tool transcript shapes` ✅

## REMAINING: 3 failures — all content-overflow, NOT code bugs

All three pass their `expectInHistory` / `expect` checks and fail ONLY on the
final `expectMeaningfulFrameArtifact` full-frame golden comparison. Root cause
for ALL three is identical: the test terminal is a fixed 40 rows, and the
fixture's content sits at or over that boundary. Any single extra row scrolls
the top of scrollback (the `╭─╮` banner, or a content header like `# Git`)
off the grid, where ttty DELETES it (scrollback=0). `stripFrameBlanks` can
remove intra-frame blank rows but cannot restore a row that was scrolled off
and deleted. None of these are render bugs; all are golden brittleness.

### bash tool success and nonzero exit — prompt-echo separator overflow

The fixture's final frame is EXACTLY 40 rows with `╭─╮` at row 0. The actual
emits 41 rows: `emitUserSubmit` (runtime.nim:1664) ends the prompt-echo bytes
with `\r\n\r\n` and `transcriptOwnsSpacing = true`. That double-newline is
INTENTIONAL and correct (gives the prompt echo its separator row; confirmed
by the flicker diagnosis — the `\r\n` variant was reverted). The same blank
appears in the PASSING `simple one-turn prompt and reply` test, where
`stripFrameBlanks` removes it harmlessly. Here the content is at the exact
40-row boundary, so the one separator blank overflows and scrolls `╭─╮` off.

Diff: expected frame row 0 = `╭─╮`, actual row 0 = blank; actual has an extra
blank at row 9 (between `❯ run bash checks` and `● Running bash checks.`).
Otherwise byte-identical (only the version string differs).

### harness commands are transcript items — skill-path line wraps at 120 cols

The system-prompt skills list (prompts.nim `discoverSkills`) emits full paths
like `- <data-root>/data/3code/skills/task-chunked-implementation.md`. After
`normalizeTtyRunRoots` redaction this is 62 chars (fits), but the REAL
rendered path on this checkout is 121 chars
(`/home/carlo/p/3code/testimp/tests/output/tty/<pid>/data/...`), which
exceeds the 120-col terminal and hard-wraps (`...implementation.m` + `d`).
The redaction collapses the prefix post-capture but cannot UN-wrap a line
the terminal already broke. Each wrapped skill line adds a row; with several
skill lines wrapping, the content overflows 40 rows and `# Git` (and the
banner) scroll off. Frame 33: expected 40 rows with `# Git`, actual 40 rows
without it. The fixture was generated on a checkout whose path fit in 120.

### multiline prompt and queued multiline autosend — spinner phases

Fails only on the golden comparison. The diff is large but the real issues
are (a) spinner glyph phases: fixture has `⠋`/`⠙`/`⠹` (animated), actual has
`⣿` (normalized); `normalizeSpinnerGlyphs` only fires when `0s` is present,
and several spinner rows in this test lack the elapsed token; (b) caret `█`
markers in different positions.

NOTE: the `needle was hello` / `row was ❯ hello` check failure that prints is
a non-fatal `check` inside the PASSING `queued prompt typed during a turn`
test (line 162), NOT the multiline test — the multiline test itself fails
purely on the golden assert.

## HOW TO PROCEED (next round)

These three are golden brittleness. Options, in order of preference:

1. **Multiline**: fix `normalizeSpinnerGlyphs` to normalize spinner phases
   regardless of the `0s` token presence (the `⠋`→`⣿` collapse should not
   depend on a trailing elapsed value). Legitimate test-harness robustness
   fix, not a fixture weakening. Re-diff after; if only caret positions
   remain, assess those separately.

2. **bash_tool**: either (a) raise the test terminal to 41+ rows so the
   intentional separator blank doesn't overflow the exact boundary, or (b)
   accept as deferred golden brittleness. Do NOT change the `\r\n\r\n` in
   emitUserSubmit — it is correct.

3. **harness**: the skill-path wrap is path-length-dependent. Cleanest fix is
   to make `normalizeTtyRunRoots` collapse a wrapped path tail back onto its
   line (rejoin `...implementation.m` + `d`), OR shorten the test data root so
   paths always fit 120 cols. Deferred per the brittleness policy unless
tackled explicitly.

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
