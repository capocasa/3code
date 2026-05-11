import std/[strutils, unittest]
import threecode/[api, display, types]
import ttty/grid

## Resize strategy for the footer/chrome tests.
##
## Do not multiply every footer test by every terminal size. Most tests
## should keep pinning one narrow behavior. This suite is the resize map:
## it drives the production byte emitters through the full chrome surface
## while simulating the most common resize aftermath the app can recover
## from locally: the terminal leaves the caret in a surprising column
## between frames. Every footer repaint must first normalize the column,
## keep exactly one live bar/prompt pair, and leave the cursor at the
## expected anchor for the next update.

proc perturbCaretColumn(g: Grid, col: int) =
  ## A resize can leave the visible caret column different from the app's
  ## last mental model. The byte emitters are expected to re-anchor from
  ## any column before they repaint the footer.
  g.col = col

proc findLastRow(g: Grid, needle: string): int =
  result = -1
  for r in 0 ..< g.rows.len:
    if needle in rowText(g, r):
      result = r

proc countRows(g: Grid, needle: string): int =
  for r in 0 ..< g.rows.len:
    if needle in rowText(g, r):
      inc result

proc checkFooter(g: Grid, labelNeedle: string): int =
  let barRow = findLastRow(g, labelNeedle)
  check barRow >= 0
  check countRows(g, labelNeedle) == 1
  check "❯" in rowText(g, barRow + 1)
  check g.row == barRow
  check g.col == 0
  result = barRow

proc visualRows(row: seq[Cell], width: int): int =
  if width <= 0 or row.len == 0:
    return 1
  (row.len + width - 1) div width

proc reflowToWidth(g: Grid, width: int) =
  ## Model terminal width reflow of already-painted rows. Each explicit
  ## row remains a separate logical line, but long rows become multiple
  ## visual rows. The cursor follows the same logical cell into the new
  ## visual grid.
  var rows: seq[seq[Cell]]
  var newCursorRow = 0
  var newCursorCol = g.col

  for r in 0 ..< g.rows.len:
    let old = g.rows[r]
    let base = rows.len
    if r < g.row:
      newCursorRow += visualRows(old, width)
    elif r == g.row:
      newCursorRow = base
      if width > 0:
        newCursorRow += g.col div width
        newCursorCol = g.col mod width

    if width <= 0 or old.len <= width:
      rows.add old
    elif old.len == 0:
      rows.add old
    else:
      var start = 0
      while start < old.len:
        let stop = min(start + width, old.len)
        rows.add old[start ..< stop]
        start = stop

  if rows.len == 0:
    rows.add @[]
  g.rows = rows
  g.row = min(newCursorRow, g.rows.len - 1)
  g.col = newCursorCol

suite "footer resize stress":
  let usage = Usage(
    promptTokens: 3800, completionTokens: 45,
    totalTokens: 3845, cachedTokens: 0,
  )

  test "frequent caret-column drift does not stack live stream footers":
    let g = newGrid()
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"

    for i in 0 ..< 6:
      perturbCaretColumn(g, 9 + i)
      g.feed barFooterBelowBytes("stream ↓" & $i, DimPromptColor)
      check countRows(g, "stream ↓") == 1
      check "stream ↓" & $i in rowText(g, 1)
      check "❯" in rowText(g, 2)
      check g.row == 0
      check g.col == 2

    g.feed "partial"
    perturbCaretColumn(g, 37)
    g.feed "\n"
    g.feed barFooterBytes("stream ↓6", DimPromptColor)
    let rowAfterFirstLine = checkFooter(g, "stream ↓6")
    check rowAfterFirstLine == 1
    check rowText(g, 0).startsWith("● partial")

    for i in 7 .. 12:
      perturbCaretColumn(g, 13 + i)
      g.feed ClearBarPromptBytes
      g.feed "  line " & $i & "\n"
      g.feed barFooterBytes("stream ↓" & $i, DimPromptColor)
      discard checkFooter(g, "stream ↓" & $i)
      check countRows(g, "stream ↓") == 1

  test "ticker frames recover the left edge and clear stale thinking":
    let g = newGrid()
    g.feed "\n"
    perturbCaretColumn(g, 21)
    g.feed spinnerFooterBytes("⠋", "spin ↓0", "  ... thinking", 1)
    check "thinking" in rowText(g, 0)
    check "spin ↓0" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 1
    check g.col == 0

    perturbCaretColumn(g, 44)
    g.feed spinnerFooterBytes("⠙", "spin ↓1", "", 2)
    check rowText(g, 0).strip == ""
    check "spin ↓1" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 1
    check g.col == 0

  test "submit receipt survives caret drift after prompt entry":
    let g = newGrid()
    g.feed "● answer\n"
    g.feed "\n"
    let label = tokenLineLabel(usage, 200_000, 1)
    g.feed barFooterBytes(label, BrightPromptColor)
    g.feed "\n\r\x1b[2K"
    g.feed "❯ next prompt\n"

    perturbCaretColumn(g, 31)
    g.feed submitTransitionBytes("next prompt", hadPending = true,
                                 hadGap = true, label)
    check rowText(g, 0).startsWith("● answer")
    check "3.8k" in rowText(g, 1)
    check rowText(g, 2).strip == ""
    check rowText(g, 3).startsWith("❯ next prompt")
    check g.row == 4
    check g.col == 0

  test "tool and error output repaint chrome after resize drift":
    let g = newGrid()
    g.feed barFooterBytes("tool ↓0", DimPromptColor)

    perturbCaretColumn(g, 18)
    g.feed ClearBarPromptBytes
    g.feed "  bash   nimble test\n"
    g.feed "  ok\n"
    g.feed barFooterBytes("tool ↓1", DimPromptColor)
    let toolBar = checkFooter(g, "tool ↓1")
    check "bash" in rowText(g, toolBar - 2)
    check "ok" in rowText(g, toolBar - 1)

    perturbCaretColumn(g, 27)
    g.feed ClearBarPromptBytes
    g.feed "  unknown tool 'browse_web'\n"
    g.feed "  Error: tool 'browse_web' is not available.\n"
    g.feed barFooterBytes("tool ↓2", DimPromptColor)
    let errBar = checkFooter(g, "tool ↓2")
    check "unknown tool" in rowText(g, errBar - 2)
    check "Error:" in rowText(g, errBar - 1)

  test "content row reflow above footer does not leave stale chrome":
    let g = newGrid()
    g.feed "● " & "a".repeat(70) & "\n"
    g.feed barFooterBytes("stream ↓1", DimPromptColor)

    reflowToWidth(g, 24)
    check findLastRow(g, "stream ↓1") > 1
    g.feed ClearBarPromptBytes
    g.feed "  after resize\n"
    g.feed barFooterBytes("stream ↓2", DimPromptColor)

    discard checkFooter(g, "stream ↓2")
    check countRows(g, "stream ↓") == 1
    check countRows(g, "❯") == 1
    check findLastRow(g, "after resize") == findLastRow(g, "stream ↓2") - 1

  test "reflowed wrapped token bar is fully removed on next repaint":
    let g = newGrid()
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBytes(longLabel, DimPromptColor)

    reflowToWidth(g, 24)
    check countRows(g, "555555555") == 1
    check countRows(g, "❯") == 1

    g.feed ClearBarPromptBytes
    g.feed "  next line\n"
    g.feed barFooterBytes("ctx ↓1", DimPromptColor)

    discard checkFooter(g, "ctx ↓1")
    check "555555555" notin rowText(g, findLastRow(g, "ctx ↓1") - 1)
    check countRows(g, "555555555") == 0
    check countRows(g, "❯") == 1

  test "reflowed below-cursor footer is fully removed":
    let g = newGrid()
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBelowBytes(longLabel, DimPromptColor)

    reflowToWidth(g, 24)
    check countRows(g, "555555555") == 1
    check countRows(g, "❯") == 1

    g.feed ClearBarBelowBytes
    g.feed barFooterBelowBytes("ctx ↓1", DimPromptColor)
    g.feed "partial after shrink"

    check countRows(g, "555555555") == 0
    check countRows(g, "ctx ↓1") == 1
    check countRows(g, "❯") == 1
    check g.row == 0
    check g.col == 2 + "partial after shrink".len

  test "reflowed spinner footer cleanup removes wrapped ticker and bar":
    let g = newGrid()
    g.feed "\n"
    let ticker = "  ... " & "thinking ".repeat(10)
    let label = "ctx 99%  ↑123456789  ↻987654321  ↓555555555"
    g.feed spinnerFooterBytes("⠋", label, ticker, 42)

    reflowToWidth(g, 24)
    check countRows(g, "thinking") > 1
    check countRows(g, "555555555") == 1
    check countRows(g, "❯") == 1

    g.feed spinnerCleanupBytes(g.row)

    check countRows(g, "thinking") == 0
    check countRows(g, "555555555") == 0
    check countRows(g, "❯") == 0
    check g.row == 1
    check g.col == 0

# A complementary suite exercising the *width-aware* emitter path.
# Setting ttty's `g.width` makes the grid wrap on write at a narrow
# terminal width, so we model what really happens after a SIGWINCH
# shrink — the next bar/spinner emission paints into a too-narrow row
# and naturally wraps. The byte emitters get the new width via their
# `termW` arg and must walk back over *all* wrap rows of the bar.
#
# These cases catch the regression where the `\x1b[1A` back-walk
# assumed a one-row bar: after a width shrink the bar wraps to 2+ rows,
# the cursor parks on the last wrap row, and the next clear/repaint
# stacks chrome above instead of replacing it. The "footer resize
# stress" suite above uses the hand-rolled `reflowToWidth` to simulate
# that, which mutates already-painted rows after the fact; this suite
# drives the same condition through ttty's natural wrap-on-feed.

suite "footer width-aware emission":
  test "wide bar at narrow width parks cursor at first wrap row":
    let g = newGrid()
    g.width = 24
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBytes(longLabel, DimPromptColor, 24)
    check g.row == 0
    check g.col == 0
    check countRows(g, "❯") == 1

  test "ClearBarPromptBytes after wide bar removes ALL wrap rows":
    let g = newGrid()
    g.width = 24
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBytes(longLabel, DimPromptColor, 24)
    g.feed ClearBarPromptBytes
    check countRows(g, "❯") == 0
    check countRows(g, "555555555") == 0

  test "next bar paint after wide bar leaves a single bar+prompt":
    let g = newGrid()
    g.width = 24
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBytes(longLabel, DimPromptColor, 24)
    g.feed ClearBarPromptBytes
    g.feed "  output line\n"
    g.feed barFooterBytes("short", DimPromptColor, 24)
    check countRows(g, "555555555") == 0
    check countRows(g, "❯") == 1

  test "barFooterBelow with wide label returns cursor to bullet row":
    let g = newGrid()
    g.width = 24
    g.feed "\x1b[96m\x1b[1m● \x1b[0m"  # bullet at row 0 col 2
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBelowBytes(longLabel, DimPromptColor, 24)
    check g.row == 0
    check g.col == 2
    check countRows(g, "❯") == 1

  test "spinner footer with wide label parks cursor at bar row col 0":
    let g = newGrid()
    g.width = 24
    g.feed "\n"  # scratch row callModel writes for the ticker overlay
    let longLabel = "ctx 99%  ↑123456789  ↻987654321  ↓555555555"
    g.feed spinnerFooterBytes("⠋", longLabel, "", 42, 24)
    # Bar row 1, wraps to >1 rows; cursor must land at row 1 col 0 so
    # the next frame's `\r\x1b[1A\x1b[2K` hits the ticker row.
    check g.row == 1
    check g.col == 0
    check countRows(g, "❯") == 1

  test "shrink → repaint → restore-width: chrome stays single-instanced":
    # Mimic a SIGWINCH-shrink mid-session: bar painted at width 80,
    # terminal shrunk to 24 (we model the post-shrink state by setting
    # g.width before the *next* paint), then restored to 80. The bug
    # this guards against: the post-shrink paint left a stacked extra
    # bar that the wider restore couldn't remove because its narrow
    # back-walk had already overshot.
    let g = newGrid()
    g.width = 80
    let label = "ctx 99%  ↑123456789  ↻987654321  ↓555555555  42s"
    g.feed barFooterBytes(label, DimPromptColor, 80)
    g.width = 24
    g.feed ClearBarPromptBytes
    g.feed "  tool output\n"
    g.feed barFooterBytes(label, DimPromptColor, 24)
    check countRows(g, "❯") == 1
    g.width = 80
    g.feed ClearBarPromptBytes
    g.feed "  more output\n"
    g.feed barFooterBytes(label, DimPromptColor, 80)
    check countRows(g, "❯") == 1
    check countRows(g, "tool output") == 1
    check countRows(g, "more output") == 1

  test "multibyte runes in label get correct wrap count":
    # The label uses arrow/check glyphs (multibyte UTF-8 but one cell
    # wide each); the wrap math counts runes, not bytes — otherwise a
    # 20-rune / 26-byte label would be over-counted and the back-walk
    # would overshoot, parking the cursor above the bar.
    let g = newGrid()
    g.width = 30
    let label = "↑111  ↻222  ↓333  1s"
    g.feed barFooterBytes(label, DimPromptColor, 30)
    check g.row == 0
    check g.col == 0
    check countRows(g, "❯") == 1

  test "legacy callers (termW=0) still get the single-row back-walk":
    # Default-arg behavior: emitters that don't know the width must keep
    # emitting the pre-fix `\x1b[1A` so existing callers and golden
    # captures don't shift.
    check "\x1b[1A" in barFooterBytes("LBL", DimPromptColor)
    check "\x1b[2A" in barFooterBelowBytes("LBL", DimPromptColor)
    check "\x1b[1A" in spinnerFooterBytes("⠋", "LBL", "", 1)
