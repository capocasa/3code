import std/[unittest, strutils, json, os]
import threecode/[api, display, types, util, compact]
import ttty/grid

## Token receipt placement and runTurns lifecycle boundary tests.
## See test_footer_bar.nim for the overall layout spec.

# ---------------- token receipt (in-place repaint) ----------------
#
# The receipt is NOT a separate content row. It's the in-place dim
# repaint of the previous bar's row at user-submit time. After
# `submitTransitionBytes` runs:
#
#   row K     dim receipt (was the cyan+bright bar)
#   row K+1   blank (separator)
#   row K+2   user echo (`❯ <input>`)
#   ...       further lines if multi-line input
#
# The bar+prompt that were on rows K, K+1 are gone — `clear-to-EOS`
# erased them; the dim receipt replaces the bar's row, the prompt is
# wiped. The next callModel will paint a fresh bar+prompt below.

suite "token receipt placement":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  test "tokenLineLabel: empty when no totals":
    check tokenLineLabel(Usage(), 200_000) == ""
    check tokenLineLabel(usage, 200_000) != ""

  test "receiptBarBytes: cyan payload, no leading clear, no \\n":
    let bytes = receiptBarBytes("○ 2%  ↑3.8k      ↓45  1s")
    check bytes.startsWith(CyanFg & " ")
    check bytes.endsWith(Reset)
    check '\n' notin bytes

  test "receiptBarBytes: empty label → empty bytes":
    check receiptBarBytes("") == ""

  test "submitTransitionBytes: no gap, no pending — receipt skipped":
    # Stage: bar at row 0 (no gap above), prompt at row 1, user types
    # "hello", Enter lands cursor at row 2.
    let g = newGrid()
    g.feed barFooterBytes("        ↓0  0s", BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ hello\n"
    g.feed submitTransitionBytes("hello", hadPending = false,
                                 hadGap = false, "")
    # Walk-back nLines+1 = 2 → row 0 (bar row). \x1b[J wipes from
    # there. No receipt. \n\n + echo.
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ hello")

  test "submitTransitionBytes: no gap + pending receipt":
    let g = newGrid()
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 1), BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ next\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("next", hadPending = true,
                                 hadGap = false, label)
    # Row 0 = receipt (carries `↑3.8k`), row 1 = blank, row 2 = echo.
    check "3.8k" in rowText(g, 0)
    check rowText(g, 1).strip == ""
    check rowText(g, 2).startsWith("❯ next")
    check CyanFg in submitTransitionBytes("next", true, false, label)
    # Receipt row 0 cells are cyan (no bold — receipt is dim repaint).
    check g.cellFg(0, 0) == colCyan
    check not hasAttr(g.cellAttr(0, 0), saBold)

  test "submitTransitionBytes: hadGap=true overwrites the gap row":
    # Stage typing-ready state: LLM line at row 0, *gap* (blank) at
    # row 1, bar at row 2, prompt at row 3. User types "next", Enter
    # lands cursor at row 4.
    let g = newGrid()
    g.feed "● Hello\n"                                     # row 0
    g.feed "\n"                                            # row 1: gap
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 1),
                          BrightPromptColor)               # bar @ 2, prompt @ 3
    g.feed "\n\r\x1b[2K"                                   # readInput
    g.feed "❯ next\n"                                      # row 3 echo + Enter
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("next", hadPending = true,
                                 hadGap = true, label)
    # Walk-back nLines+2 = 3 → row 1 (the gap row). Receipt lands
    # there, *replacing the blank* — flush against "● Hello" at row 0.
    check rowText(g, 0).startsWith("● Hello")
    check "3.8k" in rowText(g, 1)               # receipt on the old gap
    check rowText(g, 2).strip == ""             # blank separator
    check rowText(g, 3).startsWith("❯ next")    # user echo
    # Crucially: no permanent gap survives into scroll history. The
    # receipt is FLUSH against the LLM content.
    check rowText(g, 0).strip != ""
    check rowText(g, 1).strip != ""
    # Receipt row 1 cells are cyan (no bold — receipt is dim repaint).
    check g.cellFg(1, 0) == colCyan
    check not hasAttr(g.cellAttr(1, 0), saBold)

  test "submitTransitionBytes: multi-line input + hadGap walks back N+2":
    let g = newGrid()
    g.feed "● Hello\n"                # row 0
    g.feed "\n"                       # row 1: gap
    g.feed barFooterBytes("LBL", BrightPromptColor)   # bar @ 2, prompt @ 3
    g.feed "\n\r\x1b[2K"
    g.feed "❯ foo\n"                  # row 3
    g.feed "  bar\n"                  # row 4 (continuation)
    # Cursor at row 5. nLines=2, hadGap=true → walk back 4 → row 1.
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("foo\nbar", hadPending = true,
                                 hadGap = true, label)
    check rowText(g, 0).startsWith("● Hello")
    check "3.8k" in rowText(g, 1)               # receipt
    check rowText(g, 2).strip == ""             # blank separator
    check rowText(g, 3).startsWith("❯ foo")
    check rowText(g, 4).startsWith("  bar")

  test "submitTransitionBytes: cursor lands after echo, ready for callModel \\n":
    let g = newGrid()
    g.feed barFooterBytes("LBL", BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ hi\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed submitTransitionBytes("hi", hadPending = true, hadGap = false,
                                 label)
    # Receipt at 0, blank at 1, echo at 2, cursor parked at 3 col 0.
    check g.row == 3
    check g.col == 0

  test "submitTransitionBytes: hasBar=false walks back N (prompt-only)":
    # Prompt-only startup state: no bar painted, prompt at row 0,
    # user types "hello", Enter lands cursor at row 1.
    let g = newGrid()
    g.feed "\x1b[2K" & BrightPromptColor & "❯ \x1b[0m\r"
    g.feed "\r\x1b[2K"             # readInput's in-place clear
    g.feed "❯ hello\n"             # minline echo + Enter
    g.feed submitTransitionBytes("hello", hadPending = false,
                                 hadGap = false, "", hasBar = false)
    # Walk-back nLines=1 → row 0 (the prompt row). \x1b[J wipes from
    # there. No receipt, no bar — echo goes directly on the cleared row.
    check rowText(g, 0).startsWith("❯ hello")
    check g.row == 1
    check g.col == 0

  test "submitTransitionBytes: hasBar=false multi-line walks back N":
    let g = newGrid()
    g.feed "\x1b[2K" & BrightPromptColor & "❯ \x1b[0m\r"
    g.feed "\r\x1b[2K"
    g.feed "❯ foo\n"
    g.feed "  bar\n"
    # Cursor at row 2. nLines=2, hasBar=false → walk back 2 → row 0.
    g.feed submitTransitionBytes("foo\nbar", hadPending = false,
                                 hadGap = false, "", hasBar = false)
    check rowText(g, 0).startsWith("❯ foo")
    check rowText(g, 1).startsWith("  bar")

# ---------------- runTurns lifecycle ----------------
#
# The key state-flag invariant: `pendingHint.active` is set after
# `callModel` parses usage; it survives `endTurn` (typing-ready
# repaint) and is consumed by the next `emitUserSubmit`.

suite "runTurns boundaries":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  template withPendingHint(body: untyped) =
    let saved = pendingHint
    pendingHint = (active: true, usage: usage,
                   window: 200_000, elapsed: 1)
    body
    pendingHint = saved

  test "beginTurn does NOT consume pendingHint":
    # beginTurn just hides the cursor — receipt rendering moved to
    # `emitUserSubmit` at user-submit time.
    withPendingHint:
      beginTurn()
      check pendingHint.active

  test "endTurn does NOT consume pendingHint":
    # Receipt survives endTurn so the *next* emitUserSubmit can paint
    # it. If this fails, someone moved the receipt logic into endTurn.
    withPendingHint:
      let savedLabel = currentBarLabel
      let savedGap = currentBarHasGap
      currentBarLabel = "LBL"
      endTurn()
      check pendingHint.active
      check pendingHint.usage.totalTokens == 3845
      currentBarLabel = savedLabel
      currentBarHasGap = savedGap

  test "endTurn sets currentBarHasGap = true":
    # endTurn transitions to typing-ready: bar+prompt repaint with
    # bright cyan prompt, AND a one-row gap is added between the
    # bar and the row above it (breathing room while user reads).
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarLabel = "LBL"
    currentBarHasGap = false
    endTurn()
    check currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "paintBarPrompt clears currentBarHasGap":
    # Mid-stream paints (per-\n, end-of-chunk refresh, accurate
    # repaint after callModel parses usage) — none of these have
    # a gap. Gap only appears at endTurn.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarHasGap = true
    paintBarPrompt("LBL", DimPromptColor)
    check not currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "emitUserSubmit consumes pendingHint":
    withPendingHint:
      currentBarLabel = "LBL"
      emitUserSubmit("hello")
      check not pendingHint.active

  test "emitUserSubmit clears currentBarLabel and currentBarHasGap":
    # The new bar is painted by the next callModel iteration — we
    # don't carry the old label across the submit transition.
    withPendingHint:
      currentBarLabel = "LBL"
      currentBarHasGap = true
      emitUserSubmit("hello")
      check currentBarLabel == ""
      check not currentBarHasGap

  test "paintInitialBar: startup label leads with `○0%` context":
    # Bug: welcome-time paint passed an empty base to liveLabel, so
    # the bar showed `        ↓0` with no context indicator. Should
    # match the shape a populated bar carries: glyph + percent first.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    let p = Profile(model: "glm-4.7")
    paintInitialBar(p)
    check currentBarLabel.startsWith("○0%")
    check currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "paintInitialPrompt: prompt-only, no bar, no stale state":
    # Fresh-startup paint hides the token bar and shows just the
    # bright cyan prompt. `currentBarLabel` and `currentBarHasGap`
    # are the signals readInput / emitUserSubmit / the slash-command
    # repaint use to detect prompt-only mode — must end up cleared
    # even if a previous run left them populated.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarLabel = "stale"
    currentBarHasGap = true
    let p = Profile(model: "glm-4.7")
    paintInitialPrompt(p)
    check currentBarLabel == ""
    check not currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

  test "paintPromptOnly: clears state, paints in place":
    # Used by readInput's empty-Enter handler and the slash-command
    # repaint when in prompt-only mode. Resets the bar-mode signals
    # so the next readInput knows to clear in place rather than walk
    # down to a non-existent bar row.
    let savedLabel = currentBarLabel
    let savedGap = currentBarHasGap
    currentBarLabel = "stale"
    currentBarHasGap = true
    paintPromptOnly(BrightPromptColor)
    check currentBarLabel == ""
    check not currentBarHasGap
    currentBarLabel = savedLabel
    currentBarHasGap = savedGap

# ---------------- Full turn lifecycle ----------------
#
# Replay the byte stream a real turn produces and pin which row
# carries what at every checkpoint.

# Markdown body now rides the terminal's default fg (no envelope SGR);
