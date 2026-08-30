import std/[unittest, os, strutils, tables, deques]
import threecode/minline
import minline_testutils
import ttty/grid

# Bind an extra cancel key so runUntilCancel can end the read without
# also clearing a non-empty line (ESC still clears by default).
minline.configuredShortcuts = {"cancel": "CtrlG"}.toTable
const CancelKey = @[7]

proc runUntilCancel(d: Driver, ed: var LineEditor, prompt = "> ") =
  d.push CancelKey
  try: discard d.run(ed, prompt) except InputCancelled: discard

# ---------- History navigation ----------

suite "history navigation":
  test "Up→Down restores single-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "draft"
    d.push Up; d.push Down; d.push Enter
    check d.run(ed, prompt = "> ") == "draft"

  test "Up→Down restores multi-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "first"
    d.push AltEnter
    d.pushString "second"
    d.push Up   # visualUp from row 1 to row 0
    d.push Up   # historyPrevious — saves draft
    d.push Down # historyNext — restore draft
    d.push Enter
    check d.run(ed, prompt = "> ") == "first\nsecond"

  test "Up→Down→Up→Down preserves draft across repeated nav":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "draft"
    d.push Up; d.push Down; d.push Up; d.push Down; d.push Enter
    check d.run(ed, prompt = "> ") == "draft"

  test "deep walk through history then back to draft":
    var ed = initEditor()
    seedHistory(ed, @["a", "b", "c"])
    let d = newDriver()
    d.pushString "draft"
    d.push Up; d.push Up; d.push Up     # walk to oldest
    d.push Down; d.push Down; d.push Down # back to draft
    d.push Enter
    check d.run(ed, prompt = "> ") == "draft"

  test "Up→Down restores empty draft (was: silently dropped)":
    # Regression: historyNext used to early-return on empty `s`,
    # which conflated "no entry" with "next entry is empty". A
    # user pressing Up from an empty buffer would get stuck on the
    # history entry instead of returning to empty.
    var ed = initEditor()
    seedHistory(ed, @["a"])
    let d = newDriver()
    d.push Up; d.push Down; d.push Enter
    check d.run(ed, prompt = "> ") == ""

  test "Ctrl+U → Up → Down restores cleared (empty) draft":
    var ed = initEditor()
    seedHistory(ed, @["foo"])
    let d = newDriver()
    d.pushString "abc"
    d.push CtrlU         # clear -> draft = ""
    d.push Up            # save empty draft
    d.push Down          # should return to ""
    d.push Enter
    check d.run(ed, prompt = "> ") == ""

  test "history entry that happens to be empty is reachable":
    # Symmetric corner: a queue entry of "" was unreachable both
    # forward and backward because previous/next returned "" as a
    # sentinel for "no movement."
    var ed = initEditor()
    seedHistory(ed, @["a", "", "c"])
    let d = newDriver()
    d.pushString "draft"
    d.push Up; d.push Up     # save draft, walk back through "c", land on ""
    d.push Enter
    check d.run(ed, prompt = "> ") == ""

  test "no extra rows after Up→Down to single-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "draft"
    d.push Up; d.push Down
    runUntilCancel(d, ed, "> ")
    check rowText(d.grid, 0) == "> draft"
    check rowText(d.grid, 1) == ""

  test "no extra rows after Up→Down to multi-line draft":
    var ed = initEditor()
    seedHistory(ed, @["short"])
    let d = newDriver()
    d.pushString "first"
    d.push AltEnter
    d.pushString "second"
    d.push Up; d.push Up; d.push Down
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
    d.push Up   # five
    d.push Up   # four
    d.push Up   # three
    d.push Up   # two
    d.push Up   # one
    d.push Up   # already at oldest, no-op
    d.push Down # two
    d.push Down # three
    d.push Down # four
    d.push Down # five
    d.push Down # draft
    d.push Down # already on draft, no-op
    d.push Enter
    check d.run(ed, prompt = "> ") == "draft"

  test "Up→Up→Down lands on the second-newest, not the newest":
    # The reported bug: a single Down after going Up twice should not
    # collapse to draft / blank. It must step exactly one entry forward.
    var ed = initEditor()
    seedHistory(ed, @["older", "newer"])
    let d = newDriver()
    d.pushString "carefully crafted prompt"
    d.push Up   # newer
    d.push Up   # older
    d.push Down # back to newer
    d.push Enter
    check d.run(ed, prompt = "> ") == "newer"

  test "Up to oldest, Down all the way, draft survives intact":
    var ed = initEditor()
    seedHistory(ed, @["a", "b", "c", "d"])
    let d = newDriver()
    d.pushString "my draft"
    for _ in 0 ..< 4: d.push Up
    for _ in 0 ..< 4: d.push Down
    d.push Enter
    check d.run(ed, prompt = "> ") == "my draft"

# ---------- Editing while navigating ----------

suite "history editing":
  test "edit a mid-history entry and submit -> new latest entry":
    var ed = initEditor()
    seedHistory(ed, @["alpha", "beta", "gamma"])
    let d = newDriver()
    # Walk back to "beta" (middle), append "!", submit.
    d.push Up   # gamma
    d.push Up   # beta
    d.pushString "!"
    d.push Enter
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
    d.push Up   # gamma
    d.push Up   # beta
    d.pushString "X"   # line is now "betaX"
    d.push Up   # alpha
    d.push Down # back to beta — should be "betaX", not "beta"
    d.push Enter
    check d.run(ed) == "betaX"

  test "draft survives walking deep into history and back":
    var ed = initEditor()
    seedHistory(ed, @["a", "b", "c"])
    let d = newDriver()
    d.pushString "carefully crafted prompt"
    d.push Up; d.push Up; d.push Up     # walk to oldest
    d.push Up                              # past-oldest no-op
    d.push Down; d.push Down; d.push Down # back to draft
    d.push Enter
    check d.run(ed) == "carefully crafted prompt"

# ---------- Add semantics ----------

suite "history add":
  test "empty submission is not appended":
    var ed = initEditor()
    seedHistory(ed, @["one"])
    let d = newDriver()
    d.push Enter
    check d.run(ed) == ""
    check ed.history.entries.len == 1
    check ed.history.entries[0] == "one"

  test "consecutive duplicate is not appended":
    var ed = initEditor()
    seedHistory(ed, @["foo"])
    let d = newDriver()
    d.pushString "foo"
    d.push Enter
    check d.run(ed) == "foo"
    check ed.history.entries.len == 1

  test "non-consecutive duplicates are kept":
    var ed = initEditor()
    seedHistory(ed, @["foo", "bar"])
    let d = newDriver()
    d.pushString "foo"
    d.push Enter
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
      d.push Enter
      check d.run(ed) == "first"
    block:
      var ed = initEditor(historyFile = path)
      let d = newDriver()
      d.pushString "second"
      d.push Enter
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
      d.push Enter
      check d.run(ed) == "real entry"
    block:
      # Simulate: open editor, type a draft, walk into history, abort.
      var ed = initEditor(historyFile = path)
      let d = newDriver()
      d.pushString "transient draft"
      d.push Up     # peek at "real entry"
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

  when defined(posix):
    test "first-created history file is only owner-readable":
      let path = getTempDir() / "threecode_test_history_create_perms"
      if fileExists(path): removeFile(path)
      var ed = initEditor(historyFile = path)
      check ed.history.entries.len == 0
      check fileExists(path)
      check getFilePermissions(path) == {fpUserRead, fpUserWrite}
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
    d.push Left
    d.push Left
    d.push Left
    d.push Up; d.push Down
    d.pushString "Z"
    d.push Enter
    check d.run(ed) == "abcZdef"
