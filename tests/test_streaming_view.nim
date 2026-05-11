import std/[os, strutils, unittest]
import threecode/display
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
    let captured = captureStdout("tail") do ():
      var v = initStreamingView(maxLines = 3, idx = 12)
      v.addLine("one")
      v.addLine("two")
      v.addLine("three")
      v.addLine("four")

    var g = newGrid()
    g.feed captured
    check "2 lines omitted :show 12 for full" in rowText(g, 0)
    check rowText(g, 1).strip == "three"
    check rowText(g, 2).strip == "four"
    check "one" notin rowText(g, 0)
    check g.row == 3
    check g.col == 0

  test "overflow keeps marker plus latest tail within max height":
    let captured = captureStdout("overflow") do ():
      var v = initStreamingView(maxLines = 8, idx = 1234)
      for i in 1 .. 9:
        v.addLine("line " & $i)

    var g = newGrid()
    g.feed captured
    check "2 lines omitted :show 1234 for full" in rowText(g, 0)
    for i in 3 .. 9:
      check rowText(g, i - 2).strip == "line " & $i
    check "line 1" notin rowText(g, 0)
    check "line 2" notin rowText(g, 0)
    check g.row == 8
    check g.col == 0

  test "erase clears the whole visible viewport in place":
    let captured = captureStdout("erase") do ():
      var v = initStreamingView(maxLines = 3)
      v.addLine("one")
      v.addLine("two")
      v.addLine("three")
      v.erase()

    var g = newGrid()
    g.feed captured
    check rowText(g, 0).strip == ""
    check rowText(g, 1).strip == ""
    check rowText(g, 2).strip == ""
    check g.row == 0
    check g.col == 0

  test "tracks total, visible rows, and retained buffer separately":
    var v = initStreamingView(maxLines = 2)
    let captured = captureStdout("state") do ():
      v.addLine("alpha")
      v.addLine("beta")
      v.addLine("gamma")

    check v.total == 3
    check v.onScreen == 2
    check v.buf == @["alpha", "beta", "gamma"]

    var g = newGrid()
    g.feed captured
    check "2 lines omitted" in rowText(g, 0)
    check rowText(g, 1).strip == "gamma"
