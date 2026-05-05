import std/[unicode, unittest, parseutils, deques, os, strutils]
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
  for e in entries: ed.history.entries.addLast e
  ed.history.cursor = -1

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

# ---------- Stress: deep walk preserves every entry and the draft ----------

suite "history navigation, deep walk":
  test "Up/Down through 5 entries lands on the right text every step":
    var ed = initEditor()
    seedHistory(ed, @["one", "two", "three", "four", "five"])
    let d = newDriver()
    d.pushString "draft"
    # Walk all the way to the oldest, then back, and submit the draft.
    # If any step lost an entry the final line.text would be wrong.
    d.push KUp   # five
    d.push KUp   # four
    d.push KUp   # three
    d.push KUp   # two
    d.push KUp   # one
    d.push KUp   # already at oldest, no-op
    d.push KDown # two
    d.push KDown # three
    d.push KDown # four
    d.push KDown # five
    d.push KDown # draft
    d.push KDown # already on draft, no-op
    d.push KEnter
    check d.run(ed, prompt = "> ") == "draft"

  test "Up→Up→Down lands on the second-newest, not the newest":
    # The reported bug: a single Down after going Up twice should not
    # collapse to draft / blank. It must step exactly one entry forward.
    var ed = initEditor()
    seedHistory(ed, @["older", "newer"])
    let d = newDriver()
    d.pushString "carefully crafted prompt"
    d.push KUp   # newer
    d.push KUp   # older
    d.push KDown # back to newer
    d.push KEnter
    check d.run(ed, prompt = "> ") == "newer"

  test "Up to oldest, Down all the way, draft survives intact":
    var ed = initEditor()
    seedHistory(ed, @["a", "b", "c", "d"])
    let d = newDriver()
    d.pushString "my draft"
    for _ in 0 ..< 4: d.push KUp
    for _ in 0 ..< 4: d.push KDown
    d.push KEnter
    check d.run(ed, prompt = "> ") == "my draft"

# ---------- Editing while navigating ----------

suite "history editing":
  test "edit a mid-history entry and submit -> new latest entry":
    var ed = initEditor()
    seedHistory(ed, @["alpha", "beta", "gamma"])
    let d = newDriver()
    # Walk back to "beta" (middle), append "!", submit.
    d.push KUp   # gamma
    d.push KUp   # beta
    d.pushString "!"
    d.push KEnter
    check d.run(ed) == "beta!"
    # Original "beta" is untouched in entries, and "beta!" is appended.
    check ed.history.entries.len == 4
    check ed.history.entries[0] == "alpha"
    check ed.history.entries[1] == "beta"
    check ed.history.entries[2] == "gamma"
    check ed.history.entries[3] == "beta!"

  test "edits to a navigated entry are preserved across Up/Down":
    # The bug the redesign fixes: in the old code, typing while parked
    # on a history entry was lost the moment you navigated away.
    var ed = initEditor()
    seedHistory(ed, @["alpha", "beta", "gamma"])
    let d = newDriver()
    d.push KUp   # gamma
    d.push KUp   # beta
    d.pushString "X"   # line is now "betaX"
    d.push KUp   # alpha
    d.push KDown # back to beta — should be "betaX", not "beta"
    d.push KEnter
    check d.run(ed) == "betaX"

  test "draft survives walking deep into history and back":
    var ed = initEditor()
    seedHistory(ed, @["a", "b", "c"])
    let d = newDriver()
    d.pushString "carefully crafted prompt"
    d.push KUp; d.push KUp; d.push KUp     # walk to oldest
    d.push KUp                              # past-oldest no-op
    d.push KDown; d.push KDown; d.push KDown # back to draft
    d.push KEnter
    check d.run(ed) == "carefully crafted prompt"

# ---------- Add semantics ----------

suite "history add":
  test "empty submission is not appended":
    var ed = initEditor()
    seedHistory(ed, @["one"])
    let d = newDriver()
    d.push KEnter
    check d.run(ed) == ""
    check ed.history.entries.len == 1
    check ed.history.entries[0] == "one"

  test "consecutive duplicate is not appended":
    var ed = initEditor()
    seedHistory(ed, @["foo"])
    let d = newDriver()
    d.pushString "foo"
    d.push KEnter
    check d.run(ed) == "foo"
    check ed.history.entries.len == 1

  test "non-consecutive duplicates are kept":
    var ed = initEditor()
    seedHistory(ed, @["foo", "bar"])
    let d = newDriver()
    d.pushString "foo"
    d.push KEnter
    check d.run(ed) == "foo"
    check ed.history.entries.len == 3
    check ed.history.entries[2] == "foo"

# ---------- File persistence ----------

suite "history file":
  test "round-trip through disk preserves entries and skips empties":
    let path = getTempDir() / "threecode_test_history_rt"
    if fileExists(path): removeFile(path)
    block:
      var ed = initEditor(historyFile = path)
      let d = newDriver()
      d.pushString "first"
      d.push KEnter
      check d.run(ed) == "first"
    block:
      var ed = initEditor(historyFile = path)
      let d = newDriver()
      d.pushString "second"
      d.push KEnter
      check d.run(ed) == "second"
    block:
      var ed = initEditor(historyFile = path)
      check ed.history.entries.len == 2
      check ed.history.entries[0] == "first"
      check ed.history.entries[1] == "second"
      # Verify the file is human-readable: one line per entry.
      let raw = readFile(path)
      check raw.split("\n") == @["first", "second"]
    removeFile(path)

  test "drafts and pending edits never persist":
    let path = getTempDir() / "threecode_test_history_draft"
    if fileExists(path): removeFile(path)
    block:
      var ed = initEditor(historyFile = path)
      let d = newDriver()
      d.pushString "real entry"
      d.push KEnter
      check d.run(ed) == "real entry"
    block:
      # Simulate: open editor, type a draft, walk into history, abort.
      var ed = initEditor(historyFile = path)
      let d = newDriver()
      d.pushString "transient draft"
      d.push KUp     # peek at "real entry"
      runUntilCancel(d, ed)
      # File must still hold only the one persisted entry.
      let raw = readFile(path)
      check raw.split("\n") == @["real entry"]
    removeFile(path)

  test "consecutive duplicates on disk are collapsed on load":
    let path = getTempDir() / "threecode_test_history_dedup_load"
    writeFile(path, "foo\nfoo\nfoo\nbar\nbar\nfoo\n")
    var ed = initEditor(historyFile = path)
    check ed.history.entries.len == 3
    check ed.history.entries[0] == "foo"
    check ed.history.entries[1] == "bar"
    check ed.history.entries[2] == "foo"
    removeFile(path)

# ---------- Cursor preservation ----------

suite "history cursor preservation":
  test "cursor position in draft is preserved across Up/Down":
    # Type "abcdef", move cursor 3 left (between c and d), peek at history,
    # come back. Typing "Z" must land between c and d.
    var ed = initEditor()
    seedHistory(ed, @["prev"])
    let d = newDriver()
    d.pushString "abcdef"
    # Three lefts.
    d.push @[27, 91, 68]
    d.push @[27, 91, 68]
    d.push @[27, 91, 68]
    d.push KUp; d.push KDown
    d.pushString "Z"
    d.push KEnter
    check d.run(ed) == "abcZdef"
