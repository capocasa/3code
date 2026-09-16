## Interactive repro for the "last char of the row" caret bug:
##
## When a typed char fills the last cell of the prompt row, the drawn
## caret parks on that char (reverse video over it) instead of the char
## printing normally and the caret moving to the next row.
##
## Drives the real stub binary under a PTY at narrow widths, types per
## keystroke, and prints grid snapshots (with reverse-attr caret cells
## marked) after every phase.

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

proc snapshot(s: TtySession; label: string) =
  s.drain(120, recordFrame = true)
  echo "=== [", label, "] physical cursor row=", s.grid.row,
       " col=", s.grid.col, " hidden=", s.grid.cursorHidden, " ==="
  for i, row in s.grid.rows:
    var line = ""
    for c, cell in row:
      let ch = cell.rune.toUTF8
      if cell.attrs.hasAttr(saReverse):
        line.add "[" & ch & "]"
      else:
        line.add ch
    echo align($i, 2), " |", line, "|"
  echo "=== end [", label, "] ==="

proc typeSlow(s: TtySession; text: string) =
  for ch in text:
    s.send $ch
    s.drain(40)

proc main() =
  let root = newFixture("repro_lastchar")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": "ok", "usage": {"promptTokens": 1, "completionTokens": 1,
                                "totalTokens": 2, "cachedTokens": 0}}
  ]))

  # ---- Width 12: prompt "❯ " is 2 cells, 10 data cells fill the row.
  let tty = startStub(root, cols = 12, rows = 14)
  tty.expect "\u276f"
  tty.expectIdleCaret()
  snapshot(tty, "w12 idle")

  echo "--- type 0..8 (9 chars, cols 2..10) ---"
  typeSlow(tty, "012345678")
  tty.expectIdleCaret()
  snapshot(tty, "w12 nine chars")

  echo "--- type 9: char fills the last cell of the row ---"
  typeSlow(tty, "9")
  tty.expectIdleCaret()
  snapshot(tty, "w12 tenth char fills row")

  echo "--- type x: first char of the next row ---"
  typeSlow(tty, "x")
  tty.expectIdleCaret()
  snapshot(tty, "w12 eleventh char wraps")

  echo "--- clear draft, reach margin via trailing spaces ---"
  tty.send "\x1b"
  tty.drain(250)
  snapshot(tty, "w12 cleared")
  typeSlow(tty, "abcdefg")
  tty.expectIdleCaret()
  snapshot(tty, "w12 seven chars")
  typeSlow(tty, "   ")
  tty.expectIdleCaret()
  snapshot(tty, "w12 spaces reach margin")
  typeSlow(tty, "xy")
  tty.expectIdleCaret()
  snapshot(tty, "w12 xy after margin spaces")

  echo "--- submit a margin-filled row: check echo/blank rows ---"
  tty.send "\x1b"
  tty.drain(250)
  typeSlow(tty, "0123456789")
  tty.expectIdleCaret()
  snapshot(tty, "w12 refilled before submit")
  tty.send "\r"
  tty.expectIdleCaret()
  snapshot(tty, "w12 after submit")
  tty.send "\r"
  tty.expectIdleCaret()
  snapshot(tty, "w12 after second submit")
  tty.close()

  # ---- Width 7: prompt 2 cells, 5 data cells. Word-wrap territory.
  let tty7 = startStub(root, cols = 7, rows = 14)
  tty7.expect "\u276f"
  tty7.expectIdleCaret()
  echo "--- w7: type 'alpha' (fills row exactly) ---"
  typeSlow(tty7, "alpha")
  tty7.expectIdleCaret()
  snapshot(tty7, "w7 alpha fills row")
  echo "--- w7: type the break space ---"
  typeSlow(tty7, " ")
  tty7.expectIdleCaret()
  snapshot(tty7, "w7 space at margin")
  echo "--- w7: type 'beta' ---"
  typeSlow(tty7, "beta")
  tty7.expectIdleCaret()
  snapshot(tty7, "w7 beta wraps")
  echo "--- w7: arrow left twice from the margin caret ---"
  tty7.send "\x1b[D"
  tty7.drain(120)
  tty7.send "\x1b[D"
  tty7.expectIdleCaret()
  snapshot(tty7, "w7 caret left twice")
  tty7.send "\x1b[C"
  tty7.drain(120)
  tty7.send "\x1b[C"
  tty7.expectIdleCaret()
  snapshot(tty7, "w7 caret right twice")
  echo "--- w7: backspace the space, caret returns to margin ---"
  tty7.send "\x7f"
  tty7.expectIdleCaret()
  snapshot(tty7, "w7 backspace at wrap boundary")
  tty7.close()

main()
