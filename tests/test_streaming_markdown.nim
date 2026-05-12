import std/[os, strutils, unittest]
import threecode/api
import ttty/grid

proc captureStdout(name: string, body: proc()): string =
  let path = getTempDir() / ("3code_streaming_markdown_" & name)
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

proc screenText(g: Grid, rows = 20): string =
  for i in 0 ..< rows:
    result.add rowText(g, i)
    result.add "\n"

suite "streaming markdown":
  test "live stream renders markdown table through ttty grid":
    let content = """Here is test data:

| ID | Name  |
|----|-------|
| 1  | Alice |
| 2  | Bob   |
"""
    let captured = captureStdout("table") do ():
      var live = initLiveMarkdownStream("○0%")
      var slurped = 0
      for ch in content:
        inc slurped
        live.feedContent($ch, slurped)
      live.finishContent(slurped)

    var g = newGrid()
    g.feed captured
    let screen = screenText(g)
    check "Here is test data:" in screen
    check "┌" in screen
    check "│ ID" in screen
    check "Alice" in screen
    check "└" in screen
    check "|----|-------|" notin captured
