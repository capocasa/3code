import std/[os, strutils, terminal, unittest]
import threecode/toolstream
import ttty/grid

proc captureStdout(name: string, body: proc()): string =
  let path = getTempDir() / ("3code_streaming_view_" & name)
  let saved = stdout
  let f = open(path, fmWrite)
  stdout = f
  try:
    body()
  finally:
    stdout.flushFile
    stdout = saved
    close(f)
  result = readFile(path)
  try: removeFile(path) except OSError: discard

suite "streaming view scroll area":
  test "keeps only the latest maxLines visible after scrolling":
    var v = initStreamingView(maxLines = 3, idx = 12, banner = "cmd")
    v.addLine("one")
    v.addLine("two")
    v.addLine("three")
    v.addLine("four")

    let rows = v.viewportRows()
    check rows[0] == "$ cmd"
    check "2 lines omitted :show 12 for full" in rows[1]
    check rows[2].strip == "three"
    check rows[3].strip == "four"
    check "one" notin rows.join("\n")

  test "overflow keeps marker plus latest tail within max height":
    var v = initStreamingView(maxLines = 8, idx = 1234, banner = "cmd")
    for i in 1 .. 9:
      v.addLine("line " & $i)

    let rows = v.viewportRows()
    check rows[0] == "$ cmd"
    check "2 lines omitted :show 1234 for full" in rows[1]
    for i in 3 .. 9:
      check rows[i - 1].strip == "line " & $i
    check "line 1" notin rows.join("\n")
    check "line 2" notin rows.join("\n")
    check rows.len == 9

  test "tracks total, visible rows, and retained buffer separately":
    var v = initStreamingView(maxLines = 2, banner = "cmd")
    v.addLine("alpha")
    v.addLine("beta")
    v.addLine("gamma")

    check v.total == 3
    check v.buf == @["alpha", "beta", "gamma"]
    let rows = v.viewportRows()
    check "2 lines omitted" in rows[1]
    check rows[2].strip == "gamma"

  test "wrapped long line expands semantic viewport rows":
    # Each input line is wider than the soft-wrap budget (term - 3),
    # so `printLine` splits it into two visual rows. The viewport
    # must track those rows or eraseRows leaves stale residue when
    # the buffer overflows (the bug behind duplicated output during
    # `ls -la` streams).
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 3)
    let long = repeat('x', bodyW + 5)
    var v = initStreamingView(maxLines = 2, idx = 7, banner = "cmd")
    v.addLine(long)
    v.addLine(long)
    v.addLine(long)
    let rows = v.viewportRows()
    check "2 lines omitted :show 7 for full" in rows[1]
    # The wrapped tail occupies rows 1 and 2.
    check rows[2].strip.startsWith("xxx")
    check rows.len == 4

  test "printBashScroll prints all lines when under cap":
    let captured = captureStdout("scroll-short") do ():
      printBashScroll("one\ntwo\nthree\n", idx = 4, maxLines = 8)
    var g = newGrid()
    g.feed captured
    check rowText(g, 0).strip == "one"
    check rowText(g, 1).strip == "two"
    check rowText(g, 2).strip == "three"
    check g.row == 3
    check g.col == 0
    check "omitted" notin captured

  test "printBashScroll caps at maxLines with omission marker plus tail":
    var body = ""
    for i in 1 .. 12:
      body.add "line " & $i & "\n"
    let captured = captureStdout("scroll-long") do ():
      printBashScroll(body, idx = 9, maxLines = 4)
    var g = newGrid()
    g.feed captured
    # maxLines=4 → marker + last 3 lines (10, 11, 12); hidden = 9.
    check "9 lines omitted :show 9 for full" in rowText(g, 0)
    check rowText(g, 1).strip == "line 10"
    check rowText(g, 2).strip == "line 11"
    check rowText(g, 3).strip == "line 12"
    check "line 9" notin captured.split('\n')[2 .. ^1].join("\n") or
          "line 9 lines omitted" in rowText(g, 0)
    check g.row == 4

  test "printBashScroll honors default 8-line cap":
    var body = ""
    for i in 1 .. 20:
      body.add "row " & $i & "\n"
    let captured = captureStdout("scroll-default") do ():
      printBashScroll(body, idx = 1)
    var g = newGrid()
    g.feed captured
    # default StreamMaxLines = 8 → marker + 7 tail lines, hidden=13.
    check "13 lines omitted :show 1 for full" in rowText(g, 0)
    for i in 1 .. 7:
      check rowText(g, i).strip == "row " & $(13 + i)
    check g.row == 8
