import std/[os, unittest, strutils]
import ttty/grid
import threecode/[api, types, minline]
import harness

## Functional tests for input-thread prompt layout during turns.
##
## These tests exercise real code paths through a PTY+pipe harness:
## production code writes to stdout (captured by pipe -> grid),
## reads from stdin (fed by PTY master with synthetic keystrokes).
## The grid is then asserted on for correct row/column placement.

proc lastRow(g: Grid, needle: string): int =
  result = -1
  for r in 0..<g.rows.len:
    if needle in rowText(g, r):
      result = r

proc captureUntil(ft: FakeTerm, needle: string): int =
  result = -1
  for _ in 0..<20:
    sleep 20
    ft.capture()
    result = lastRow(ft.grid, needle)
    if result >= 0:
      return

suite "input thread layout during turns":
  test "beginTurn input thread echoes typed text on prompt row":
    ## Exercise the production path, not just a hand-built escape
    ## sequence. This catches the real regression where the buffered
    ## prompt was rendered one row too high and overwrote the token bar.
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    defer:
      inputEditor = nil
      inputState = InputState()
      currentBarLabel = ""
      currentBarHasGap = false

    paintBarPrompt("LBL  3s", DimPromptColor)
    beginTurn()

    let promptRow = captureUntil(ft, "❯")
    let barRow = promptRow - 1
    ft.feedKeys("h")
    let typedPromptRow = captureUntil(ft, "❯ h")
    let typedOnPromptRow =
      typedPromptRow == promptRow and "❯ h" in rowText(ft.grid, promptRow)
    let typedOnBarRow =
      barRow >= 0 and "h" in rowText(ft.grid, barRow)
    let cursorOnPromptRow = ft.grid.row == promptRow

    ft.feedKeys("\r")
    sleep 100
    endTurn()

    ft.drain()
    check inputState.queuedText == "h"
    check promptRow >= 1
    check barRow >= 0
    check "LBL" in rowText(ft.grid, barRow)
    check "❯" in rowText(ft.grid, promptRow)
    check typedOnPromptRow
    check not typedOnBarRow
    check cursorOnPromptRow

  test "beginTurn input thread keeps prompt below token bar after submit":
    ## This final-grid check covers the submitted state. It is not a
    ## substitute for the half-typed assertion above, which catches the
    ## visible flicker.
    var ft = newFakeTerm()
    defer: ft.close()

    var ed = minline.initEditor()
    inputEditor = addr(ed)
    defer:
      inputEditor = nil
      inputState = InputState()
      currentBarLabel = ""
      currentBarHasGap = false

    paintBarPrompt("LBL  3s", DimPromptColor)
    ft.feedKeys("hi\r")
    beginTurn()
    sleep 200
    endTurn()

    ft.drain()
    check inputState.queuedText == "hi"
    check "LBL" in rowText(ft.grid, 0)
    check "❯" notin rowText(ft.grid, 0)
    check "hi" notin rowText(ft.grid, 0)
    check "❯" in rowText(ft.grid, 1)

  test "typing during turn: prompt and text on caret row":
    ## Real-world scenario: the model is streaming a response. The bar
    ## is visible. The input thread starts and paints a bright-white
    ## prompt below the bar. The user types "hi" and hits Enter.
    ## The typed text must appear on the prompt row (row 1), not on
    ## the bar row (row 0).
    var ft = newFakeTerm()
    defer: ft.close()

    # Main thread painted the bar before the turn
    paintBarPrompt("LBL  3s", DimPromptColor)

    # Input thread starts: clears, repaints bar+prompt with fix
    clearBarPrompt()
    currentBarLabel = "LBL  3s"
    stdout.write barFooterBytes("LBL  3s", TurnPromptColor)
    stdout.write "\x1b[1B"  # cursor down: bar row -> prompt row
    stdout.flushFile()

    # readLineWith runs: user types "hi" and Enter
    var ed = minline.initEditor()
    ed.width = 80
    ft.feedKeys("hi\r")

    let getCh: minline.GetChProc = proc(): int =
      try: stdin.readChar().ord
      except: -1
    let writeProc: minline.WriteProc = proc(s: string) =
      stdout.write s
      stdout.flushFile
    let text = minline.readLineWith(ed, "\xe2\x9d\xaf ", getCh, writeProc,
                                     hidechars = false)

    ft.drain()
    check text == "hi"
    check "LBL" in rowText(ft.grid, 0)     # bar on row 0
    check "❯" in rowText(ft.grid, 1)       # prompt on row 1
    check "hi" in rowText(ft.grid, 1)       # typed text on row 1
    check "❯" notin rowText(ft.grid, 0)    # prompt NOT on bar row
    check "hi" notin rowText(ft.grid, 0)    # typed text NOT on bar row

  test "BUG REPRO: without cursor-down, typed text lands on bar row":
    ## Same scenario but skip the \x1b[1B. The prompt and typed text
    ## overwrite the bar row — the bug.
    var ft = newFakeTerm()
    defer: ft.close()

    paintBarPrompt("LBL  3s", DimPromptColor)
    clearBarPrompt()
    currentBarLabel = "LBL  3s"
    stdout.write barFooterBytes("LBL  3s", TurnPromptColor)
    stdout.flushFile()
    # Deliberately skip: stdout.write "\x1b[1B"

    var ed = minline.initEditor()
    ed.width = 80
    ft.feedKeys("h\r")

    let getCh: minline.GetChProc = proc(): int =
      try: stdin.readChar().ord
      except: -1
    let writeProc: minline.WriteProc = proc(s: string) =
      stdout.write s
      stdout.flushFile
    discard minline.readLineWith(ed, "\xe2\x9d\xaf ", getCh, writeProc,
                                  hidechars = false)

    ft.drain()
    # BUG: prompt and typed char overwrite bar row
    check "❯" in rowText(ft.grid, 0)   # prompt on bar row
    check "h" in rowText(ft.grid, 0)   # typed char on bar row
