# 3code Testing Improvement Plan

Goal: make the test suite strong enough that a lazy, hallucination-prone agent
(deepseek-class) cannot ship a behavioral regression without seeing it fail.

## STATUS

The tty functional suite is at **20 OK / 5 FAILED** (24 total). The goal is
to fix them all, one or two at a time, committing each verified fix. Next up:
the golden-diff cluster and the consecutive-turns end-of-turn spacing bug.

### Commits so far

  a425974 isolate TMPDIR per fixture to stop session lock collisions
  391673e Phase 1: add assertion vocabulary to tty_expect.nim
  80361b8 refactor engine height to derive walk-up from live state; fix prompt echo erasure
  05d8bf1 fix bash tool flicker: renderFooter must not wipe live tool viewport
  36f225e unify queued-prompt transcript with emitUserSubmit (DRY)
  8048e35 fix idle-submit input race: unpark input thread after editor clear, not at poll

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
  variant was reverted — keep `\r\n\r\n`.

## REMAINING: 5 failures (goal: fix all, one or two at a time)

All were pre-existing (fail on 391673e). The idle-submit race fix (8048e35)
cleared 6 of the original 11. These 5 remain:

### Golden diffs (3) — PICK NEXT

These pass all their `expectInHistory` / `expect` checks and fail ONLY on the
final `expectMeaningfulFrameArtifact` full-frame golden comparison. The
fixtures are correct (source of truth). To diagnose, diff the normalized
actual vs fixture (see the python normalizer snippet below — the test already
normalizes version banners, frame-separator labels, and intra-frame blank
rows, so diff the RAW files then mentally apply those normalizations, or run
the normalizer).

- `bash tool success and nonzero exit` — normalized diff is TINY: one frame
  where the expected shows the full 3-row welcome banner (`╭─╮` / `─┤ 3code...`
  / `╰─╯`) but actual shows only `╰─╯` (top two banner rows blank). A
  transient partial-redraw frame where the banner top isn't repainted. Look at
  how the banner is cleared/redrawn during turns (the welcome banner lives at
  the top of the scrollback; a `renderFooter`/`appendTranscript` walk-up that
  over-erases could blank it in a transient frame).
- `non-bash tool transcript shapes` — same class of golden diff.
- `harness commands are transcript items` — golden diff; uses a pre-written
  fixture `HarnessCommandFrames`. Inspect what differs.

Normalizer snippet (diff normalized actual vs fixture):
```
python3 -c '
import re,sys,difflib
def norm(t):
  out=[];inf=False
  for line in t.splitlines(keepends=True):
    s=line.strip()
    if s.startswith("=====") and s.endswith("====="): out.append("===== frame =====\n");inf=True;continue
    if "3code v" in line and "the economical coding agent" in line:
      line=re.sub(r"3code v\S+   the economical coding agent","3code vVERSION   the economical coding agent",line)
    if inf and s=="": continue
    out.append(line)
  return "".join(out)
for l in difflib.unified_diff(norm(open(sys.argv[2]).read()).splitlines(),norm(open(sys.argv[1]).read()).splitlines(),"expected","actual",lineterm=""):
  print(l)
' ACTUAL.txt FIXTURE.txt
```

### End-of-turn spacing (1) — PICK NEXT

- `consecutive turns never accumulate extra blank separator lines` — double
  blank row between the last token bar (row 16) and the idle prompt, with a
  stray `0%` token-bar fragment (row 19) in between. The idle frame rows
  (captured via debug, see git history) were:
  `16: ○0% ↑10 ↓5 0s` / `17: <BLANK>` / `18: <BLANK>` / `19: ○0%` / `20: ❯ `.
  The double blank + stray `0%` is the `endTurnAfterTranscriptAppend` path
  (fatprompt/runtime.nim:1654). The stray `0%` suggests the bar is repainted
  with stale/zeroed token values at turn end. Inspect `setBarEvent(label,
  hasGap = true)` there and whether the gap row + bar fragment double up.

### Multiline queued (1)

- `multiline prompt and queued multiline autosend` — now fails at line 162
  (`needle in frame.rows[frame.cursorRow]`, a cursor-row visibility check),
  NOT the old history check. The queue race is fixed; this is a separate
  MULTILINE editor display issue: a queued multiline prompt (editor newline
  via `\x1b[13;2u`) doesn't render both lines on the live footer during the
  turn. Look at `minline.totalRows` / `echoRows` for multiline queued prompts
  and how `renderToolViewport`/footer reserve the multiline height.

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
