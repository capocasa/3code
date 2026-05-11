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
      var v = initStreamingView(maxLines = 3)
      v.addLine("one")
      v.addLine("two")
      v.addLine("three")
      v.addLine("four")

    var g = newGrid()
    g.feed captured
    check rowText(g, 0).strip == "two"
    check rowText(g, 1).strip == "three"
    check rowText(g, 2).strip == "four"
    check "one" notin rowText(g, 0)
    check g.row == 3
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
    check rowText(g, 0).strip == "beta"
    check rowText(g, 1).strip == "gamma"
