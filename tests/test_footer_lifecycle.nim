import std/[unittest, strutils, json, os]
import threecode/[api, display, types, util, compact]
import ttty/grid

## Full turn lifecycle: end-to-end byte replay of complete turns.
## See test_footer_bar.nim for the overall layout spec.

proc styledLineBytes(text: string): string =
  text & "\n"

proc countRows(g: Grid, needle: string): int =
  for r in 0 ..< g.rows.len:
    if needle in rowText(g, r):
      inc result

suite "full turn lifecycle":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  test "single turn: bar visible during streaming, finalised at end":
    let g = newGrid()
    # ---- welcome paints initial bar+prompt at zeros ----
    g.feed "  ╭─╮\n   ─┤  3code v0.0\n  ╰─╯\n"
    g.feed barFooterBytes("        ↓0", BrightPromptColor)
    # Bar at row 3, prompt at row 4, cursor at row 3 col 0.
    check "  " in rowText(g, 3)
    check "❯" in rowText(g, 4)
    # ---- readInput: walk down to prompt row, clear, type, Enter ----
    g.feed "\n\r\x1b[2K"          # readInput's advance + clear
    g.feed "❯ test prompt\n"      # minline echo + Enter
    # Cursor at row 5 col 0.
    # ---- emitUserSubmit (first turn — pending NOT active) ----
    g.feed submitTransitionBytes("test prompt", hadPending = false,
                                 hadGap = false, "")
    # Walk back 2 rows to bar row 3, \x1b[J wipes from row 3 down.
    # Row 3 stays blank (no receipt — first turn). Row 4 blank,
    # row 5 user echo.
    check rowText(g, 3).strip == ""
    check rowText(g, 4).strip == ""
    check rowText(g, 5).startsWith("❯ test prompt")
    check g.row == 6 and g.col == 0
    # ---- runTurns → beginTurn (hide cursor) ----
    g.feed "\x1b[?25l"
    check g.cursorHidden
    # ---- callModel: leading \n + spinner ----
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "        ↓0", "", 0)
    # Bar at row 7 (cursor advance), prompt at row 8, scratch at row 6.
    check "⠋" in rowText(g, 7)
    check "❯" in rowText(g, 8)
    # Spinner bar row is bold cyan, prompt row is dim grey.
    check g.cellFg(7, 0) == colCyan
    check hasAttr(g.cellAttr(7, 0), saBold)
    check g.cellFg(8, 0) == col256
    check g.cellAt(8, 0).fgColorIdx == 244
    # ---- content arrives ----
    g.feed SpinnerCleanupBytes
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("Hello")
    g.feed barFooterBytes("        ↓5  1s", DimPromptColor)
    # Bullet cell is bright cyan + bold.
    check g.cellFg(7, 0) == colBrightCyan
    check hasAttr(g.cellAttr(7, 0), saBold)
    # Bar visible during streaming.
    let barRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓5" in rowText(g, r): found = r; break
      found
    check barRow >= 0
    check "❯" in rowText(g, barRow + 1)
    # Bar is bold cyan, prompt is dim (grey-244).
    check hasAttr(g.cellAttr(barRow, 0), saBold)
    check g.cellFg(barRow, 0) == colCyan
    check g.cellAt(barRow + 1, 0).fgColor == col256
    check g.cellAt(barRow + 1, 0).fgColorIdx == 244
    # Second content line.
    g.feed ClearBarPromptBytes
    g.feed styledLineBytes("  World")
    g.feed barFooterBytes("        ↓11  2s", DimPromptColor)
    let barRow2 = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓11" in rowText(g, r): found = r; break
      found
    check barRow2 == barRow + 1
    check "❯" in rowText(g, barRow2 + 1)
    # ---- streamHttp finishContent + final paintBarPrompt ----
    g.feed ClearBarPromptBytes
    g.feed barFooterBytes("        ↓11  2s", DimPromptColor)
    # ---- callModel post-stream: repaint with accurate values ----
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 2), DimPromptColor)
    let finalBarRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "3.8k" in rowText(g, r) and "↓45" in rowText(g, r):
          found = r; break
      found
    check finalBarRow == barRow2
    # No blank between bar and prompt.
    check "❯" in rowText(g, finalBarRow + 1)
    # ---- endTurn: bright cyan prompt + show cursor ----
    g.feed barFooterBytes(tokenLineLabel(usage, 200_000, 2), BrightPromptColor)
    g.feed "\x1b[?25h"
    check not g.cursorHidden
    # Bright prompt: bold cyan.
    check g.cellFg(finalBarRow + 1, 0) == colCyan
    check hasAttr(g.cellAttr(finalBarRow + 1, 0), saBold)

  test "retry-backoff interrupt clears footer before feedback":
    let g = newGrid()
    let label = "ctx 1%  ↑0  ↻0  ↓0"
    g.feed barFooterBytes(label, DimPromptColor)

    g.feed endTurnBytes(label, BrightPromptColor, repaintPrompt = false)
    g.feed "interrupted by user during retry backoff\n"

    check countRows(g, "❯") == 0
    check rowText(g, 0).startsWith("interrupted by user during retry backoff")
    check not rowText(g, 0).startsWith("  interrupted")

  test "turn 2: receipt overwrites the gap, lands flush below LLM":
    # Stage turn 1 typing-ready state: LLM line at row 0, gap at
    # row 1, bar at row 2, prompt at row 3.
    let g = newGrid()
    g.feed "● Hello\n"                      # row 0
    g.feed "\n"                             # row 1: gap
    let iter1Label = tokenLineLabel(usage, 200_000, 1)
    g.feed barFooterBytes(iter1Label, BrightPromptColor)
    # ---- readInput (turn 2): walk to prompt row, type, Enter ----
    g.feed "\n\r\x1b[2K"
    g.feed "❯ elaborate\n"
    # ---- emitUserSubmit: hadGap=true ----
    g.feed submitTransitionBytes("elaborate", hadPending = true,
                                 hadGap = true, iter1Label)
    # Receipt lands on the GAP row (row 1), flush below LLM.
    check rowText(g, 0).startsWith("● Hello")
    check "3.8k" in rowText(g, 1)               # receipt on old gap
    check rowText(g, 2).strip == ""             # blank separator
    check rowText(g, 3).startsWith("❯ elaborate")
    # Receipt is cyan.
    check CyanFg in submitTransitionBytes("elaborate", true, true,
                                          iter1Label)
    # Grid-level: receipt row has cyan cells (no bold — receipt is dim).
    check g.cellFg(1, 0) == colCyan

  test "tool exec under withCleared: bar+prompt slide down":
    # Bar at row 0, prompt at row 1. Tool exec writes content above
    # via clearBarPrompt + body + repaintBarPrompt-like sequence.
    let g = newGrid()
    g.feed barFooterBytes("LBL", DimPromptColor)
    # withCleared body: clear → write → repaint.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls\n"
    g.feed "  total 16\n"
    g.feed barFooterBytes("LBL", DimPromptColor)
    # Tool output rows 0-1, bar slid down to row 2, prompt row 3.
    check "bash" in rowText(g, 0)
    check "total 16" in rowText(g, 1)
    check "LBL" in rowText(g, 2)
    check "❯" in rowText(g, 3)
    # No blank between bar and prompt.
    check rowText(g, 2).strip != ""
    check rowText(g, 3).strip != ""
    # Bar row cells are bold cyan, dim prompt is grey-244.
    check hasAttr(g.cellAttr(2, 0), saBold)
    check g.cellFg(2, 0) == colCyan
    check g.cellAt(3, 0).fgColor == col256
    check g.cellAt(3, 0).fgColorIdx == 244

  test "tool exec: bar+prompt visible during runAction (bar tick)":
    # Production sequence: paintBarPrompt → withCleared(\n + content)
    # → startBarTick → runAction (no writes, bar ticks) → stopBarTick
    # → withCleared(renderToolBanner + printToolResult + repaint).
    # The KEY property: during runAction the bar stays visible and ticks
    # elapsed seconds — runAction can take seconds and the user sees a
    # live counter instead of a frozen screen.
    let g = newGrid()
    # Initial: bar at row 0, prompt at row 1.
    g.feed barFooterBytes("LBL  0s", DimPromptColor)
    check "LBL" in rowText(g, 0)
    check "❯" in rowText(g, 1)
    # withCleared writes \n + assistant content, repaints bar.
    g.feed ClearBarPromptBytes
    g.feed "\n"
    g.feed barFooterBytes("LBL  0s", DimPromptColor)
    # Bar tick: bar label updates with elapsed (simulated as one frame).
    g.feed barFooterBytes("LBL  1s", DimPromptColor)
    # CHECKPOINT: this is the moment during runAction. Bar+prompt MUST
    # be visible with ticking counter.
    let barRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "LBL  1s" in rowText(g, r): found = r; break
      found
    check barRow >= 0
    check "❯" in rowText(g, barRow + 1)
    check rowText(g, barRow).strip != ""
    check rowText(g, barRow + 1).strip != ""
    # During runAction: bar is bold cyan, prompt is dim grey-244.
    check hasAttr(g.cellAttr(barRow, 0), saBold)
    check g.cellFg(barRow, 0) == colCyan
    check g.cellAt(barRow + 1, 0).fgColor == col256
    check g.cellAt(barRow + 1, 0).fgColorIdx == 244
    # runAction completes, stopBarTick. Result phase:
    # withCleared clears bar, writes result, repaints.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls  (1s)\n"
    g.feed "  total 16\n"
    g.feed "  [exit 0]\n"
    g.feed barFooterBytes("LBL  2s", DimPromptColor)
    # FINAL: bar+prompt at the bottom, output above.
    let finalBarRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "LBL" in rowText(g, r): found = r
      found
    check finalBarRow >= 0
    check "❯" in rowText(g, finalBarRow + 1)
    check rowText(g, finalBarRow).strip != ""
    check rowText(g, finalBarRow + 1).strip != ""
    var foundFinal = false
    for r in 0 ..< g.rows.len:
      if "(1s)" in rowText(g, r): foundFinal = true
    check foundFinal

  test "iter 2 stream end: bar at new bottom with no blank above prompt":
    let g = newGrid()
    # Iter 1 stream end.
    g.feed "● iter 1 content\n"
    g.feed barFooterBytes("        ↓18  1s", DimPromptColor)
    # Tool exec under withCleared.
    g.feed ClearBarPromptBytes
    g.feed "  bash   ls\n"
    g.feed "  total 16\n"
    g.feed barFooterBytes("        ↓18  1s", DimPromptColor)
    # Iter 2: callModel \n + spinner + content + finalise.
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "ctx 5%          ↓0", "", 0)
    g.feed SpinnerCleanupBytes
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("iter 2 content")
    g.feed barFooterBytes("ctx 5%          ↓14  1s", DimPromptColor)
    g.feed ClearBarPromptBytes
    g.feed barFooterBytes("ctx 5%          ↓14  1s", DimPromptColor)
    # Final state: iter 2 bar visible with prompt directly below.
    let bar2Row = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓14" in rowText(g, r): found = r; break
      found
    check bar2Row >= 0
    check "❯" in rowText(g, bar2Row + 1)

  test "DECTCEM hide on beginTurn, show on endTurn":
    let g = newGrid()
    check not g.cursorHidden
    g.feed "\x1b[?25l"
    check g.cursorHidden
    g.feed "\x1b[?25h"
    check not g.cursorHidden

  test "fresh startup: prompt-only → first turn paints bar, no stale row":
    # Welcome paints banner, paintInitialPrompt drops one blank gap
    # row + the bright cyan prompt — no token bar above. User types,
    # emitUserSubmit walks back N (hasBar=false) so the prompt's row
    # is wiped, NOT some non-existent bar row. With no bar and no
    # pending receipt, only one \n is emitted (the cleared prompt row
    # itself becomes the separator), so the echo lands directly below
    # the gap. After the first turn's callModel paints the bar, the
    # layout is back to normal.
    let g = newGrid()
    g.feed "  type a prompt.\n"
    # paintInitialPrompt: blank gap + prompt, cursor at col 0 of prompt row.
    g.feed "\n"
    g.feed "\x1b[2K" & BrightPromptColor & "❯ \x1b[0m\r"
    let promptRow = g.row
    check rowText(g, promptRow).startsWith("❯")
    check rowText(g, promptRow - 1).strip == ""
    # No bar row above the prompt: the row above is just the gap.
    check "↑" notin rowText(g, promptRow - 1)
    # readInput in prompt-only mode: clear in place (no walk-down).
    g.feed "\r\x1b[2K"
    g.feed "❯ hello\n"           # minline echo
    # Cursor at promptRow + 1.
    # emitUserSubmit with hasBar=false walks back N=1 to promptRow,
    # clears, echo goes directly on the cleared row (no newline needed
    # when there's no bar and no receipt — the gap row above persists).
    g.feed submitTransitionBytes("hello", hadPending = false,
                                 hadGap = false, "", hasBar = false)
    check rowText(g, promptRow).startsWith("❯ hello")          # echo on cleared row
    # Now callModel's leading \n + content + paintBarPrompt paints
    # the bar; from here the normal lifecycle resumes.
    g.feed "\n"                                            # scratch
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("hi back")
    g.feed barFooterBytes("ctx 1%  ↑10      ↓7  1s", DimPromptColor)
    let barRow = block:
      var found = -1
      for r in 0 ..< g.rows.len:
        if "↓7" in rowText(g, r): found = r; break
      found
    check barRow >= 0
    check "❯" in rowText(g, barRow + 1)

  test "multi-line content in one chunk: bar painted after every \\n":
    # Per-line repaint pattern: bar visible at every checkpoint.
    let g = newGrid()
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"
    g.feed styledLineBytes("Line 1")
    g.feed barFooterBytes("lbl  1s", DimPromptColor)
    check "Line 1" in rowText(g, 0)
    check "lbl" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    g.feed ClearBarPromptBytes
    g.feed styledLineBytes("  Line 2")
    g.feed barFooterBytes("lbl  2s", DimPromptColor)
    check "Line 2" in rowText(g, 1)
    check "lbl" in rowText(g, 2)
    check "❯" in rowText(g, 3)
    g.feed ClearBarPromptBytes
    g.feed styledLineBytes("  Line 3")
    g.feed barFooterBytes("lbl  3s", DimPromptColor)
    check "Line 3" in rowText(g, 2)
    check "lbl" in rowText(g, 3)
    check "❯" in rowText(g, 4)

  test "long repaint sequence keeps only the latest footer":
    let g = newGrid()
    for i in 0 ..< 8:
      if i > 0:
        g.feed ClearBarPromptBytes
      g.feed "line " & $i & "\n"
      g.feed barFooterBytes("LBL " & $i, DimPromptColor)

    var barRow = -1
    var labelCount = 0
    for r in 0 ..< g.rows.len:
      if "LBL" in rowText(g, r):
        inc labelCount
      if "LBL 7" in rowText(g, r):
        barRow = r
    check labelCount == 1
    check barRow >= 0
    check "line 7" in rowText(g, barRow - 1)
    check "❯" in rowText(g, barRow + 1)
    check g.cellFg(barRow, 0) == colCyan
    check hasAttr(g.cellAttr(barRow, 0), saBold)
    check g.cellFg(barRow + 1, 0) == col256
    check g.cellAt(barRow + 1, 0).fgColorIdx == 244
