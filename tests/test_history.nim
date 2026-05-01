import std/[unicode, unittest, parseutils, deques]
import threecode/minline

# Inline ANSI grid (subset of test_minline's renderer).
type
  Grid = ref object
    rows: seq[seq[Rune]]
    row, col: int

proc newGrid(): Grid = Grid(rows: @[newSeq[Rune]()], row: 0, col: 0)
proc ensureRow(g: Grid, r: int) =
  while g.rows.len <= r: g.rows.add newSeq[Rune]()
proc padTo(row: var seq[Rune], col: int) =
  while row.len < col: row.add Rune(' ')
proc putRune(g: Grid, r: Rune) =
  ensureRow(g, g.row); padTo(g.rows[g.row], g.col)
  if g.rows[g.row].len == g.col: g.rows[g.row].add r
  else: g.rows[g.row][g.col] = r
  inc g.col
proc eraseLine(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0: (if g.rows[g.row].len > g.col: g.rows[g.row].setLen(g.col))
  of 1:
    for k in 0 ..< min(g.col, g.rows[g.row].len): g.rows[g.row][k] = Rune(' ')
  of 2: g.rows[g.row].setLen(0)
  else: discard
proc eraseDisplay(g: Grid, mode: int) =
  ensureRow(g, g.row)
  case mode
  of 0:
    if g.rows[g.row].len > g.col: g.rows[g.row].setLen(g.col)
    g.rows.setLen(g.row + 1)
  of 1:
    for r in 0 ..< g.row: g.rows[r].setLen(0)
    for k in 0 ..< min(g.col, g.rows[g.row].len): g.rows[g.row][k] = Rune(' ')
  of 2:
    for r in 0 ..< g.rows.len: g.rows[r].setLen(0)
  else: discard
proc parseN(s: string): int =
  if s.len == 0: 1
  else:
    var n = 0; discard parseInt(s, n, 0); (if n == 0: 1 else: n)
proc feed(g: Grid, bytes: string) =
  var i = 0
  while i < bytes.len:
    let b = bytes[i]
    case b
    of '\r': g.col = 0; inc i
    of '\n': inc g.row; g.col = 0; ensureRow(g, g.row); inc i
    of '\x1b':
      if i + 1 < bytes.len and bytes[i + 1] == '[':
        var j = i + 2
        var private = false
        if j < bytes.len and bytes[j] == '?': private = true; inc j
        var params = ""
        while j < bytes.len and (bytes[j] in {'0'..'9'} or bytes[j] == ';'):
          params.add bytes[j]; inc j
        if j >= bytes.len: i = j; continue
        let final = bytes[j]
        if not private:
          case final
          of 'A': g.row = max(0, g.row - parseN(params))
          of 'B': g.row += parseN(params); ensureRow(g, g.row)
          of 'C': g.col += parseN(params)
          of 'D': g.col = max(0, g.col - parseN(params))
          of 'G': g.col = max(0, parseN(params) - 1)
          of 'K':
            var mode = 0
            if params.len > 0: discard parseInt(params, mode, 0)
            eraseLine(g, mode)
          of 'J':
            var mode = 0
            if params.len > 0: discard parseInt(params, mode, 0)
            eraseDisplay(g, mode)
          of 'm', 's', 'u': discard
          else: discard
        i = j + 1
      else: inc i
    else:
      let rl = runeLenAt(bytes, i)
      let r = runeAt(bytes, i)
      putRune(g, r); i += rl
proc rowText(g: Grid, r: int): string =
  if r < 0 or r >= g.rows.len: return ""
  for ru in g.rows[r]: result.add $ru

type
  Driver = ref object
    keystrokes: seq[int]
    pos: int
    output: string
    grid: Grid
    width: int

proc newDriver(width = 80): Driver =
  Driver(keystrokes: @[], pos: 0, output: "", grid: newGrid(), width: width)
proc push(d: Driver, ks: openArray[int]) =
  for k in ks: d.keystrokes.add k
proc pushString(d: Driver, s: string) =
  for ch in s: d.keystrokes.add ch.int

const
  KEnter*    = @[13]
  KUp*       = @[27, 91, 65]
  KDown*     = @[27, 91, 66]
  KAltEnter* = @[27, 13]
  KCtrlC*    = @[3]
  KCtrlU*    = @[21]

proc run(d: Driver, ed: var LineEditor, prompt = "> "): string =
  let getCh: GetChProc = proc(): int =
    if d.pos >= d.keystrokes.len: return -1
    let k = d.keystrokes[d.pos]; inc d.pos; return k
  let write: WriteProc = proc(s: string) =
    d.output.add s; d.grid.feed s
  let widthProc: WidthProc = proc(): int = d.width
  ed.readLineWith(prompt, getCh, write, getWidth = widthProc)

proc seedHistory(ed: var LineEditor, entries: seq[string]) =
  for e in entries: ed.history.queue.addLast e
  ed.history.position = ed.history.queue.len

proc runUntilCancel(d: Driver, ed: var LineEditor, prompt = "> ") =
  d.push KCtrlC
  try: discard d.run(ed, prompt) except InputCancelled: discard

# ---------- History navigation ----------

suite "history navigation":
  test "Up→Down restores single-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "draft"
    d.push KUp; d.push KDown; d.push KEnter
    check d.run(ed, prompt = "> ") == "draft"

  test "Up→Down restores multi-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "first"
    d.push KAltEnter
    d.pushString "second"
    d.push KUp   # visualUp from row 1 to row 0
    d.push KUp   # historyPrevious — saves draft
    d.push KDown # historyNext — restore draft
    d.push KEnter
    check d.run(ed, prompt = "> ") == "first\nsecond"

  test "Up→Down→Up→Down preserves draft across repeated nav":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "draft"
    d.push KUp; d.push KDown; d.push KUp; d.push KDown; d.push KEnter
    check d.run(ed, prompt = "> ") == "draft"

  test "deep walk through history then back to draft":
    var ed = initEditor()
    seedHistory(ed, @["a", "b", "c"])
    let d = newDriver()
    d.pushString "draft"
    d.push KUp; d.push KUp; d.push KUp     # walk to oldest
    d.push KDown; d.push KDown; d.push KDown # back to draft
    d.push KEnter
    check d.run(ed, prompt = "> ") == "draft"

  test "Up→Down restores empty draft (was: silently dropped)":
    # Regression: historyNext used to early-return on empty `s`,
    # which conflated "no entry" with "next entry is empty". A
    # user pressing Up from an empty buffer would get stuck on the
    # history entry instead of returning to empty.
    var ed = initEditor()
    seedHistory(ed, @["a"])
    let d = newDriver()
    d.push KUp; d.push KDown; d.push KEnter
    check d.run(ed, prompt = "> ") == ""

  test "Ctrl+U → Up → Down restores cleared (empty) draft":
    var ed = initEditor()
    seedHistory(ed, @["foo"])
    let d = newDriver()
    d.pushString "abc"
    d.push KCtrlU         # clear -> draft = ""
    d.push KUp            # save empty draft
    d.push KDown          # should return to ""
    d.push KEnter
    check d.run(ed, prompt = "> ") == ""

  test "history entry that happens to be empty is reachable":
    # Symmetric corner: a queue entry of "" was unreachable both
    # forward and backward because previous/next returned "" as a
    # sentinel for "no movement."
    var ed = initEditor()
    seedHistory(ed, @["a", "", "c"])
    let d = newDriver()
    d.pushString "draft"
    d.push KUp; d.push KUp     # save draft, walk back through "c", land on ""
    d.push KEnter
    check d.run(ed, prompt = "> ") == ""

  test "no extra rows after Up→Down to single-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "draft"
    d.push KUp; d.push KDown
    runUntilCancel(d, ed, "> ")
    check rowText(d.grid, 0) == "> draft"
    check rowText(d.grid, 1) == ""

  test "no extra rows after Up→Down to multi-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "first"
    d.push KAltEnter
    d.pushString "second"
    d.push KUp; d.push KUp; d.push KDown
    runUntilCancel(d, ed, "> ")
    check rowText(d.grid, 0) == "> first"
    check rowText(d.grid, 1) == "  second"
    check rowText(d.grid, 2) == ""
