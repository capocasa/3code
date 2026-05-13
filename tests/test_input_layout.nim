import std/[unittest, strutils]
import ttty/grid
import threecode/[api, types, minline]
import harness

## Functional tests for input-thread prompt layout during turns.
##
## These tests exercise real code paths through a PTY+pipe harness:
## production code writes to stdout (captured by pipe -> grid),
## reads from stdin (fed by PTY master with synthetic keystrokes).
## The grid is then asserted on for correct row/column placement.

suite "input thread layout during turns":

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
