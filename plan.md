# Plan: One Blank Line Between Every Scrollback Item

## Context

The rule is simple: every scrollback item (prompt, assistant response, tool
call, error message) is separated from the next by exactly one blank row.
Historically there were many exceptions:

1. `emitUserSubmit` ended the prompt with `\r\n` (no separator), relying on
   the volatile footer gap.
2. `finishFinalTranscriptItem` collapsed the last item before idle to `\r\n`,
   relying on `endTurn`'s volatile gap.
3. `prefixBoundary` prepended `\r\n` to the first tool as a workaround for #1.
4. Harness messages (interrupt, retry, error) manually bracketed with `\r\n`.

These have been axed. The current uncommitted change (across
`engine.nim`, `fatprompt/runtime.nim`, `transcript.nim`, `turns.nim`) removes
all four exception classes. Every item now ends with `\r\n\r\n`.

The `endTurn` volatile gap (`endTurnBytes` `gapAlready` parameter) has been
forced to `true` (never add a gap), since the committed separator owns it.

The engine's `gapIsSeparator` flag (in `appendTranscript`) was widened from
`transcriptOwnsSpacing and ...` to just `transcript.len > 0 and reserveFooter
and footerBytes.len > 0` so the footer frame's reserved gap row is treated as
the separator whenever content was just written.

## What's Done (in current working tree)

- [x] `emitUserSubmit` (runtime.nim:~2375): prompt ends `\r\n\r\n`
- [x] `endTurn` (runtime.nim:~2328): always `gapAlready = true`
- [x] Removed `finishFinalTranscriptItem`, `collapseGap`, `finalBeforeIdle`
      from turns.nim
- [x] Removed `prefixBoundary` from turns.nim and transcript.nim
- [x] Removed manual `\r\n` bracketing from all harness messages
      (onTurnInterrupted, apiRetryNotice, 6 error/retry messages in turns.nim)
- [x] `gapIsSeparator` widened in engine.nim (both `appendTranscript` branches)

## Remaining Work (2 failing tests)

### Item 1: `consecutive turns never accumulate extra blank separator lines`

**Status: completed**

### REVISED DESIGN (flag-toggling does not work — the architecture must change)

The previous approach (toggle `hasGap` / widen `gapIsSeparator`) was verified
broken by direct tracing. The root cause is architectural: **two emitters
stack**, and no flag can suppress an emitter that fires *within the same
append* it is supposed to guard.

**The two stacking emitters of a blank row between content and bar:**

1. The committed item's trailing `\r\n\r\n` — written by
   `finishTranscriptItem`/`finishItem` (turns/transcript) and/or re-emitted
   by `appendTranscript` itself (engine.nim:454/491, the `not
   transcriptOwnsSpacing` branch).
2. The footer frame's leading gap/ticker row — `footerFrameBytes` ffTokenBar
   (rendering.nim:488) always reserves one row (blank when no ticker is
   active, filled when reasoning is streaming). This row is **structural**:
   it gives the footer a height invariant to the ticker appearing/clearing,
   and it is the volatile "breathing room" below the last item, above the bar.

When a transcript commit writes `content + \r\n\r\n` and THEN paints the
footer frame, both #1 and #2 land: one blank from the separator, one blank
from the footer's reserved ticker row (empty when idle) = **double blank**.
`gapIsSeparator` only governs *subsequent* repaints; it cannot suppress #2
within the same `appendTranscript` call because the footer bytes are already
baked before the flag is evaluated at the end.

`setBarEvent(hasGap=...)` is DEAD state: `footer.hasGap` is written by
`apply()` but never read anywhere. Toggling it does nothing.

**CONSTRAINTS (non-negotiable):**
- Scrollback is strictly append-only once written to terminal bytes. In-memory
  trimming *before* the write is allowed; editing committed rows is not.
- The footer's ticker/gap row stays structural — it is the reasoning ticker's
  reserved slot and is not "there all the time" as a gap; it is blank only
  when idle.

### CHOSEN FIX: Design C — the gap precedes each item except the first

The separator is emitted ONCE, by `appendTranscript`, PREPENDED before the
content of every item after the first. No item carries a trailing separator.
The footer's ticker row remains volatile breathing room below the last item,
entirely separate from inter-item spacing — so the two never stack.

  item 1: `content`                  (no leading gap — first in scrollback)
  item 2: `\r\n\r\n` + `content`
  item 3: `\r\n\r\n` + `content`

**Single emission point:** `appendTranscript`. It prepends `\r\n\r\n` iff
scrollback already exists. A new `hasScrollback: bool` field on
`TerminalEngine` (set true after the first content write, never reset) gates
the prepend.

**Engine changes (`src/threecode/engine.nim`):**
- Add `hasScrollback: bool` to `TerminalEngine`.
- In `appendTranscript` (both liveAnchored and non-liveAnchored branches):
  remove the trailing `content + \r\n\r\n` write, the `trimTrailingNewlines`
  call, and the `transcriptOwnsSpacing`/`not transcriptOwnsSpacing` branch.
  Instead: if `hasScrollback and transcript.len > 0`, write `\r\n\r\n` BEFORE
  the content. Set `hasScrollback = true` after writing non-empty content.
  Remove `gapIsSeparator` entirely (the walk-up gap logic, `noteFooterPainted`
  reset, and the `footerBarOnlyBytes` selection all collapse — the footer
  always paints `footerFrameBytes` with its ticker row).
- Drop the `transcriptOwnsSpacing` parameter from `appendTranscript`.

**Caller changes — stop emitting trailing separators:**
- `turns.nim` `finishTranscriptItem` (line ~158): delete the `bytes.add
  "\r\n\r\n"`; items are bare content now. (Keep the `trimTranscriptTail`
  pre-write trim — append-only allows pre-write trimming.)
- `transcript.nim` `finishItem` (line ~45): same — drop the `\r\n\r\n`.
- `fatprompt/runtime.nim` `emitUserSubmit` (line ~2366-2374): drop the two
  `bytes.add "\r\n\r\n"` (receipt block + prompt block).
- `fatprompt/runtime.nim` `commitTranscriptBytes` (line ~776): drop the
  `transcriptOwnsSpacing` parameter and its forwarding to `appendTranscript`.
  Update all call sites.

**After the change, verify:** every adjacent pair of scrollback items has
exactly one blank between them; the footer ticker row (blank when idle) sits
below the last item with no double-blank; the `consecutive turns` test's
`maxRun <= 1` passes.

### Item 2: `multiline prompt and queued multiline autosend`

**Status: completed** — golden regenerated (multiline.txt). The visual
recording is timing-sensitive (which streaming-partial frames get captured
varies run to run); content is always correct, only the captured frame set
differs.

This test compares against a golden frame artifact
(`testdata/fixtures/tty/multiline.txt`). The frame shapes changed because the
prompt now carries its own `\r\n\r\n` separator (previously it relied on the
volatile gap). The fix is to regenerate the golden artifact.

Steps:
1. Run the test to get the actual output path from the failure message.
2. Inspect the actual frames vs the golden to confirm the ONLY differences are
   the new single-blank separators between items (no double-blanks, no missing
   content).
3. If the actual output is correct, copy it over the golden:
   `cp testdata/output/tty/multiline_*/multiline_visual_test_actual.txt testdata/fixtures/tty/multiline.txt`
4. Re-run the test to confirm it passes.

File: `testdata/fixtures/tty/multiline.txt`

### Item 3: Verify all other golden frame artifacts

**Status: completed** — harness_commands.txt regenerated (old spacing
truncated help/command output; now shows full content). simple.txt,
bash_tool_visual_test.txt, other_tools_visual_test.txt, resize_stream_frames.txt
all pass unchanged.

Other tests with golden artifacts may also need regeneration:
- `testdata/fixtures/tty/simple.txt` (simple_visual_test)
- `testdata/fixtures/tty/other_tools_visual_test.txt` (other_tools_visual_test)
- `testdata/fixtures/tty/bash_tool_visual_test.txt` (bash tool test)
- `testdata/fixtures/tty/harness_commands.txt` (harness commands test)
- `testdata/fixtures/tty/resize_stream_frames.txt` (resize test)

For each:
1. Run the specific test.
2. If it fails on artifact comparison, inspect the actual vs expected.
3. Confirm differences are ONLY the corrected separator spacing (one blank
   between every item, including after the prompt).
4. If correct, regenerate the golden artifact.
5. Re-run to confirm.

### Item 4: Run the full test suite

**Status: completed** — tty functional, core/display, core/history,
api/fatprompt all pass.

After items 1-3:
```
nimble build && nim c -r --path:src --path:tests tests/tty/test_tty_functional.nim
nim c -r --path:src --path:tests tests/core/test_display.nim
nim c -r --path:src --path:tests tests/core/test_history.nim
nim c -r --path:src --path:tests tests/api/test_fatprompt.nim
```

All must pass. Then commit with message like:
`enforce one blank line between every scrollback item`

### Item 5: Manual verification

**Status: pending**

Run `3code` with the stub or a real provider and verify visually:
- Prompt followed by assistant reply: exactly one blank between
- Prompt followed by tool call (no assistant content): exactly one blank
- Tool call followed by tool call: exactly one blank
- Interrupted turn: exactly one blank above the interrupt message
- Multiple turns: no accumulating blank rows

## Key Files

- `src/threecode/turns.nim` - turn controller, item commit
- `src/threecode/transcript.nim` - item formatting and append
- `src/threecode/fatprompt/runtime.nim` - prompt echo, endTurn, footer state
- `src/threecode/fatprompt/rendering.nim` - footer frame byte construction
- `src/threecode/engine.nim` - terminal geometry, appendTranscript, walkUp
- `tests/tty/test_tty_functional.nim` - visual test suite
- `testdata/fixtures/tty/*.txt` - golden frame artifacts
