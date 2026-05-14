import std/[unicode, unittest, strutils, parseutils, json, os]
import threecode/[api, display, types, util, compact]
import ttty/grid
import ttty/terminal

## Self-eval for the streaming footer layout.
##
## CLAUDE.md "Token UI" section is the spec. Pinned invariants:
##
## - **bar always visible** (cyan + bright). 2-char prefix: column 0
##   is the spinner braille glyph during streaming, a space otherwise;
##   column 1 is always a space. Label starts at column 2.
## - **prompt `❯ ` always visible**. Dim while typing isn't possible,
##   bright cyan when readline is active. Sits one row below the bar.
## - **thinking ticker** is a transient overlay one row above the bar,
##   only painted while reasoning streams; restores to blank when
##   reasoning ends.
## - **token receipt** is *not* a separate row of content — it's the
##   in-place dim repaint of the previous bar's row at user-submit
##   time. The `submitTransitionBytes` sequence walks back to that
##   row, repaints it dim, and echoes the user's input below.
##
## Eyeballing terminal output costs more than writing a test. The
## grid renderer below feeds raw byte streams through an inline ANSI
## VT, then assertions read cell content / cursor / DECTCEM state.
## When a layout bug surfaces, the loop is: write the failing assertion
##   here first, *then* fix the byte emitters in `api.nim` /
## `display.nim`. Don't iterate by guessing at byte sequences.

# ---------------- Bar payload geometry ----------------

suite "bar payload geometry":
  test "liveBarBytes: 2-space prefix, label starts at col 2":
    let g = newGrid()
    g.feed liveBarBytes("○ 0%          ↓0  0s")
    let row = rowText(g, 0)
    # Position 0 and 1 are blank, label starts at col 2.
    check row[0] == ' '
    check row[1] == ' '
    # The context glyph and label content follow immediately.
    check row.len >= 3
    check row[2 .. ^1].startsWith("○")
    # liveBarBytes uses bold cyan for all bar cells.
    check g.cellFg(0, 2) == colCyan
    check hasAttr(g.cellAttr(0, 2), saBold)

  test "spinnerBarBytes: spinner glyph at col 0, space at col 1":
    let g = newGrid()
    g.feed spinnerBarBytes("⠋", "○ 0%          ↓0", 1)
    let row = rowText(g, 0)
    # Column 0 is the braille glyph (spinner overwrites the leading
    # space); column 1 stays a space; label content from col 2.
    check row.startsWith("⠋")
    # After the multi-byte rune, runes 1 should be a space.
    let r0len = "⠋".len
    check row[r0len] == ' '
    # Label content right after.
    check "○ 0%" in row
    # spinnerBarBytes: glyph and label are bold cyan.
    check g.cellFg(0, 0) == colCyan
    check hasAttr(g.cellAttr(0, 0), saBold)
    check g.cellFg(0, 2) == colCyan
    check hasAttr(g.cellAttr(0, 2), saBold)

  test "spinner and live bar share label column":
    # The same label rendered with/without the spinner must land at
    # the same column — the spinner replaces ONLY position 0, never
    # shifts the label. Compare by *column* (rune-indexed) not by
    # byte offset — the braille rune is multi-byte UTF-8 so a
    # `find` on the row text disagrees with the column.
    let g1 = newGrid()
    g1.feed liveBarBytes("LBL")
    let g2 = newGrid()
    g2.feed spinnerBarBytes("⠋", "LBL", 0)
    check g1.rows[0][2].rune == Rune('L')
    check g2.rows[0][2].rune == Rune('L')
    # Both live bar and spinner bar use bold cyan on the label.
    check hasAttr(g1.cellAttr(0, 2), saBold)
    check g1.cellFg(0, 2) == colCyan
    check hasAttr(g2.cellAttr(0, 2), saBold)
    check g2.cellFg(0, 2) == colCyan

# ---------------- bar+prompt footer ----------------

suite "bar+prompt footer":
  test "barFooterBytes: bar at row 0, prompt at row 1, no blank between":
    let g = newGrid()
    g.feed barFooterBytes("LBL  1s", DimPromptColor)
    check "LBL" in rowText(g, 0)
    check "❯" in rowText(g, 1)
    check g.row == 0
    check g.col == 0
    # Bar row cells are bold cyan.
    check g.cellFg(0, 0) == colCyan
    check hasAttr(g.cellAttr(0, 0), saBold)
    # Dim prompt: grey-244.
    check g.cellFg(1, 0) == col256
    check g.cellAt(1, 0).fgColorIdx == 244

  test "barFooterBytes parks cursor at bar row col 0":
    let g = newGrid()
    g.feed "preamble\n"
    g.feed barFooterBytes("LBL", DimPromptColor)
    # Bar at row 1 (after preamble row 0), prompt at row 2.
    check rowText(g, 0).startsWith("preamble")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 1
    check g.col == 0

  test "ClearBarPromptBytes erases bar+prompt rows in place":
    let g = newGrid()
    g.feed barFooterBytes("LBL", DimPromptColor)
    g.feed ClearBarPromptBytes
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check g.row == 0
    check g.col == 0

  test "live footer slides down with each emitted content line":
    let g = newGrid()
    # Bullet on bar row.
    g.feed "● "
    g.feed "Hello\n"
    # First repaint: bar at row 1, prompt at row 2.
    g.feed barFooterBytes("lbl  1s", DimPromptColor)
    # Next line: clear, write, repaint.
    g.feed ClearBarPromptBytes
    g.feed "  World\n"
    g.feed barFooterBytes("lbl  2s", DimPromptColor)
    # Final: content above, bar+prompt at the new bottom (no blank
    # between bar and prompt).
    check rowText(g, 0).startsWith("● Hello")
    check rowText(g, 1).startsWith("  World")
    check "lbl" in rowText(g, 2)
    check "❯" in rowText(g, 3)
    # No blank separator between bar (row 2) and prompt (row 3).
    check rowText(g, 2).strip != ""
    check rowText(g, 3).strip != ""
    # Bar at row 2 is bold cyan; prompt at row 3 is dim grey-244.
    check g.cellFg(2, 0) == colCyan
    check hasAttr(g.cellAttr(2, 0), saBold)
    check g.cellFg(3, 0) == col256
    check g.cellAt(3, 0).fgColorIdx == 244

  test "prompt color toggles between dim and bright cyan":
    # Same label, different prompt color: verify the visible cell state.
    block:
      let gd = newGrid()
      gd.feed barFooterBytes("LBL", DimPromptColor)
      check gd.cellFg(1, 0) == col256
      check gd.cellAt(1, 0).fgColorIdx == 244
    block:
      let gb = newGrid()
      gb.feed barFooterBytes("LBL", BrightPromptColor)
      check gb.cellFg(1, 0) == colCyan
      check hasAttr(gb.cellAttr(1, 0), saBold)

# ---------------- mid-line bar visibility ----------------
#
# The user-visible "bar disappears during streaming" symptom comes
# from the streaming loop only repainting on `\n`. When the model
# emits a long partial line (no `\n` yet), the bar would stay missing
# for the entire wait. `barFooterBelowBytes` (CSI s/u save/restore)
# paints the bar one row below the cursor without disturbing the
# content row, so the bar stays visible through pendingLine
# accumulation.

suite "mid-line bar visibility":
  test "barFooterBelowBytes paints bar+prompt below, walks cursor to col 2":
    let g = newGrid()
    # Canonical mid-line state: cursor is at the bullet row col 2
    # (right after `● ` writes). Content accumulates in memory but
    # no terminal write has advanced past col 2 yet.
    g.feed "● "
    g.feed barFooterBelowBytes("LBL  1s", DimPromptColor)
    # Bar at row 1, prompt at row 2.
    check rowText(g, 0).startsWith("● ")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # Cursor walked back to bullet row col 2 (right after `● `) —
    # uses `\x1b[2A\x1b[3G` instead of CSI s/u (SCO save/restore is
    # silently ignored on some terminals; we hit a regression where
    # each refresh stacked another bar in scroll).
    check g.row == 0
    check g.col == 2
    # Bar at row 1 is bold cyan; prompt at row 2 is dim grey-244.
    check g.cellFg(1, 0) == colCyan
    check hasAttr(g.cellAttr(1, 0), saBold)
    check g.cellFg(2, 0) == col256
    check g.cellAt(2, 0).fgColorIdx == 244

  test "barFooterBelowAtColBytes restores cursor after streamed text":
    let g = newGrid()
    g.feed "● Hello"
    g.feed barFooterBelowAtColBytes("LBL  1s", DimPromptColor, 7)
    g.feed " world"
    check rowText(g, 0).startsWith("● Hello world")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 0
    check g.col == 13

  test "stream chunk repaint clears old below-footer before appending text":
    let g = newGrid()
    g.feed "● "
    g.feed barFooterBelowBytes("OLD  0s", DimPromptColor)
    g.feed clearBarBelowAtColBytes(2)
    g.feed "Hello"
    g.feed barFooterBelowAtColBytes("MID  1s", DimPromptColor, 7)
    g.feed clearBarBelowAtColBytes(7)
    g.feed " there"
    g.feed barFooterBelowAtColBytes("NEW  2s", DimPromptColor, 13)
    check rowText(g, 0).startsWith("● Hello there")
    check "OLD" notin rowText(g, 0)
    check "MID" notin rowText(g, 0)
    check "NEW" in rowText(g, 1)
    check "❯" in rowText(g, 2)

  test "ClearBarBelowBytes wipes bar+prompt below, walks cursor to col 2":
    let g = newGrid()
    g.feed "● "
    g.feed barFooterBelowBytes("LBL", DimPromptColor)
    g.feed ClearBarBelowBytes
    check rowText(g, 0).startsWith("● ")
    check rowText(g, 1).strip == ""
    check rowText(g, 2).strip == ""
    check g.row == 0
    check g.col == 2

  test "repeated paintBarBelow does NOT stack bars in scroll":
    # Regression: CSI s/u was ignored on some terminals, so each
    # refresh advanced cursor 2 rows without restore — 30 chunks
    # stacked 30 bars in scroll history before the first `\n`. The
    # walk-up-relative emitter must keep cursor on row 0 col 2.
    let g = newGrid()
    g.feed "● "
    for i in 0 .. 30:
      g.feed barFooterBelowBytes("↓" & $i, DimPromptColor)
    # After 31 paints, only one bar+prompt visible (rows 1 + 2).
    check rowText(g, 0).startsWith("● ")
    check "↓30" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # No bar payload anywhere from row 3 onward.
    for r in 3 ..< g.rows.len:
      check "↓" notin rowText(g, r)
    check g.row == 0
    check g.col == 2

  test "first chunk no \\n: bar visible from bullet onwards":
    let g = newGrid()
    # Bullet → paintBarBelow → mid-line content. No `\n` yet; bar
    # must already be visible. Bullet at row 0, bar at row 1, prompt
    # at row 2.
    g.feed "● "
    g.feed barFooterBelowBytes("        ↓5  1s", DimPromptColor)
    # Cursor at row 0 col 2. Content writes there.
    g.feed "Hello"
    check rowText(g, 0).startsWith("● Hello")
    check "↓5" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # Bar at row 1 is bold cyan; prompt at row 2 is dim grey-244.
    check g.cellFg(1, 0) == colCyan
    check hasAttr(g.cellAttr(1, 0), saBold)
    check g.cellFg(2, 0) == col256
    check g.cellAt(2, 0).fgColorIdx == 244

  test "transition mid-line → \\n: bar replaces below-bar at-cursor":
    let g = newGrid()
    g.feed "● "
    g.feed barFooterBelowBytes("LBL  1s", DimPromptColor)
    g.feed "Hello"
    # After mid-line content, bar still below.
    check "LBL" in rowText(g, 1)
    # Now `\n` arrives. Content writes "\n" → cursor advances onto
    # row 1 (where bar was). paintBarPrompt's leading clear erases
    # old bar and writes new one in place.
    g.feed "\n"
    g.feed barFooterBytes("LBL  2s", DimPromptColor)
    # Row 0 still has "● Hello"; row 1 now NEW bar; row 2 prompt.
    check rowText(g, 0).startsWith("● Hello")
    check "LBL" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # No double bar — old bar at row 1 was overwritten cleanly.
    check rowText(g, 1).count("LBL") == 1
    # After transition, bar at row 1 is still bold cyan.
    check g.cellFg(1, 0) == colCyan
    check hasAttr(g.cellAttr(1, 0), saBold)

  test "finite terminal scrollback does not retain streamed footer receipts":
    proc countRows(g: Grid, needle: string): int =
      for r in 0 ..< g.rows.len:
        if needle in rowText(g, r):
          inc result

    proc feedLiveMarkdown(g: Grid, clearBeforeNewline: bool) =
      let lines = [
        "Here is placeholder text with a markdown table.",
        "---",
        "## Placeholder Section",
        "Praesent libero. Sed cursus ante dapibus diam.",
        "### Sample Table",
        "| Column A | Column B | Column C |",
        "|----------|----------|----------|",
        "| Row 1-A  | Row 1-B  | Row 1-C  |",
        "| Row 2-A  | Row 2-B  | Row 2-C  |",
        "| Row 3-A  | Row 3-B  | Row 3-C  |",
        "---"
      ]
      var col = 2
      var barAtCursor = false
      var step = 0

      proc label(): string =
        "STREAM ↓" & $step

      proc clearBarIfNeeded() =
        if barAtCursor:
          g.feed ClearBarPromptBytes
          barAtCursor = false

      g.feed "\x1b[1;6r\x1b[5;1H"
      g.feed "● "
      g.feed barFooterBelowAtColBytes(label(), DimPromptColor, col)
      for idx, line in lines:
        clearBarIfNeeded()
        if idx > 0:
          g.feed "  "
          col = 2
        g.feed line
        col += visibleWidth(line)
        inc step
        g.feed barFooterBelowAtColBytes(label(), DimPromptColor, col)
        if clearBeforeNewline:
          g.feed clearBarBelowAtColBytes(col)
        g.feed "\n"
        col = 0
        inc step
        g.feed barFooterBytes(label(), DimPromptColor)
        barAtCursor = true

    block:
      let term = newTerminal(width = 80, height = 6, scrollback = 80)
      feedLiveMarkdown(term.grid, clearBeforeNewline = true)
      let g = term.grid
      let barCount = countRows(g, "STREAM ↓")
      check barCount == 1
      check countRows(g, "❯") == 1
      let barRow = block:
        var found = -1
        for r in 0 ..< g.rows.len:
          if "STREAM ↓" in rowText(g, r):
            found = r
        found
      check barRow >= 0
      check "❯" in rowText(g, barRow + 1)
      for r in 0 ..< barRow:
        check "STREAM ↓" notin rowText(g, r)
