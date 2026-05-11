import std/[unittest, strutils, json]
import threecode/[api, display, types, util, compact]
import ttty/grid

## Spinner footer tests. See test_footer_bar.nim for the overall
## layout spec this belongs to.

# ---------------- spinner footer ----------------

suite "spinner footer":
  test "ticker overlay row blank when no reasoning":
    let g = newGrid()
    g.feed "\n"  # callModel's leading \n — scratch row above bar
    g.feed spinnerFooterBytes("⠋", "lbl", "", 1)
    check rowText(g, 0).strip == ""
    check "⠋" in rowText(g, 1)
    check "1s" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    check g.row == 1
    check g.col == 0
    # Spinner bar at row 1 is bold cyan; prompt at row 2 is dim grey-244.
    check g.cellFg(1, 0) == colCyan
    check hasAttr(g.cellAttr(1, 0), saBold)
    check g.cellFg(2, 0) == col256
    check g.cellAt(2, 0).fgColorIdx == 244

  test "ticker overlay populated when reasoning":
    let g = newGrid()
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "lbl", "  … pondering", 2)
    check "pondering" in rowText(g, 0)
    check "⠋" in rowText(g, 1)
    check "❯" in rowText(g, 2)
    # Ticker at row 0 is grey-244; bar at row 1 is bold cyan.
    check g.cellFg(0, 0) == col256
    check g.cellAt(0, 0).fgColorIdx == 244
    check g.cellFg(1, 0) == colCyan
    check hasAttr(g.cellAttr(1, 0), saBold)

  test "reasoning → no-reasoning restores blank above bar":
    let g = newGrid()
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "lbl", "  … reasoning", 1)
    check "reasoning" in rowText(g, 0)
    g.feed spinnerFooterBytes("⠙", "lbl", "", 2)
    check rowText(g, 0).strip == ""
    check "⠙" in rowText(g, 1)
    # Ticker row 0 is now blank — no residual SGR from earlier reasoning.
    check g.cellFg(0, 0) == colDefault

  test "spinner cleanup wipes all three footer rows":
    let g = newGrid()
    g.feed "\n"
    g.feed spinnerFooterBytes("⠋", "lbl", "  … reasoning", 1)
    g.feed SpinnerCleanupBytes
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).strip == ""
    check g.row == 1
    check g.col == 0

