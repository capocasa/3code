import std/[strutils, terminal, unittest]
import threecode/toolstream
import ttty/grid

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
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 3)
    let long = repeat('x', bodyW + 5)
    var v = initStreamingView(maxLines = 2, idx = 7, banner = "cmd")
    v.addLine(long)
    v.addLine(long)
    v.addLine(long)
    let rows = v.viewportRows()
    check "2 lines omitted :show 7 for full" in rows[1]
    check rows[2].strip.startsWith("xxx")
    check rows.len == 4
