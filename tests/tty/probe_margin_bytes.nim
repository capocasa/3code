## Byte-capture repro for the two margin bugs:
##
## 1. typing the char that fills the last column: caret and char omitted.
## 2. multiple trailing spaces: all collapsed into the wrap, not just one.
##
## Drives the real stub binary under a PTY at width 12 and dumps the exact
## bytes each keystroke paints, plus the grid state.

import std/[json, os, strutils, unicode]
import tty_expect, stub_helpers
import ttty/grid

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata" / "output" / "tty" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc startStub(root: string; cols = DefaultTtyCols; rows = DefaultTtyRows): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                cols = cols, rows = rows)

proc vis(b: string): string =
  ## escape bytes made readable
  for ch in b:
    case ch
    of '\x1b': result.add "<E>"
    of '\r': result.add "<CR>"
    of '\n': result.add "<LF>"
    of '\x7f': result.add "<DEL>"
    else: result.add ch

proc dump(s: TtySession; label: string) =
  s.drain(150, recordFrame = true)
  echo "=== [", label, "] cursor row=", s.grid.row, " col=", s.grid.col, " ==="
  for i, row in s.grid.rows:
    var line = ""
    for cell in row:
      let ch = cell.rune.toUTF8
      if cell.attrs.hasAttr(saReverse): line.add "[" & ch & "]"
      else: line.add ch
    echo align($i, 2), " |", line, "|"

proc typeSlow(s: TtySession; text: string) =
  for ch in text:
    s.send $ch
    s.drain(40)

when isMainModule:
  let root = newFixture("margin_bytes_a")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": "ok", "usage": {"promptTokens": 1, "completionTokens": 1,
                                "totalTokens": 2, "cachedTokens": 0}}
  ]))

  # Width 12: prompt "❯ " is 2 cells, 10 data cells fill the row.
  let tty = startStub(root, cols = 12, rows = 14)
  tty.expect "\u276f"
  tty.expectIdleCaret()
  discard tty.freshRaw()
  tty.advanceRawMark()
  dump(tty, "w12 idle")

  typeSlow(tty, "012345678")
  tty.expectIdleCaret()
  var raw = tty.freshRaw()
  echo "--- bytes for '012345678' ---"
  echo raw.vis
  tty.advanceRawMark()
  dump(tty, "nine chars")

  tty.send "9"
  tty.expectIdleCaret()
  raw = tty.freshRaw()
  echo "--- bytes for '9' (fills last cell) ---"
  echo raw.vis
  tty.advanceRawMark()
  dump(tty, "tenth char fills row")

  tty.send "x"
  tty.expectIdleCaret()
  raw = tty.freshRaw()
  echo "--- bytes for 'x' (wraps to next row) ---"
  echo raw.vis
  tty.advanceRawMark()
  dump(tty, "eleventh char wraps")
  tty.close()

  # Spaces: "abcdefg" + 5 spaces. abcdefg occupies cols 2..8; three spaces
  # fit (cols 9..11), the fourth is the margin break, the fifth belongs on
  # the next row.
  let root2 = newFixture("margin_bytes_b")
  writeConfiguredProvider(root2)
  writeFile(root2 / "run" / "stub_responses.json", $(%*[
    {"content": "ok", "usage": {"promptTokens": 1, "completionTokens": 1,
                                "totalTokens": 2, "cachedTokens": 0}}
  ]))
  let t2 = startStub(root2, cols = 12, rows = 14)
  t2.expect "\u276f"
  t2.expectIdleCaret()
  discard t2.freshRaw()
  t2.advanceRawMark()
  typeSlow(t2, "abcdefg")
  t2.expectIdleCaret()
  t2.advanceRawMark()
  dump(t2, "seven chars")
  for n in 1 .. 5:
    t2.send " "
    t2.expectIdleCaret()
    echo "--- bytes for space #", n, " ---"
    echo t2.freshRaw().vis
    t2.advanceRawMark()
    dump(t2, "after space #" & $n)
  t2.close()
