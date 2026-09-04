import std/[strutils, unittest]
import tty_expect
import ttty/grid

suite "harness escape reassembly":
  test "feedGridChunk completes a split CSI erase across chunks":
    let s = TtySession(grid: newGrid(), keepHistory: false)
    s.grid.width = 40
    s.grid.height = 10
    s.feedGridChunk "hello"
    s.feedGridChunk "\x1b[2"          # chunk boundary inside EL 2
    s.feedGridChunk "Kworld"          # tail in the next read()
    check rowText(s.grid, 0).strip == "world"

  test "feedGridChunk completes split SGR params across chunks":
    let s = TtySession(grid: newGrid(), keepHistory: false)
    s.grid.width = 40
    s.grid.height = 10
    s.feedGridChunk "ab\x1b[38;5"
    s.feedGridChunk ";244mcd"
    check rowText(s.grid, 0) == "abcd"

  test "feedGridChunk holds a lone trailing ESC for its bracket":
    let s = TtySession(grid: newGrid(), keepHistory: false)
    s.grid.width = 40
    s.grid.height = 10
    s.feedGridChunk "x\x1b"
    s.feedGridChunk "[2Ky"
    # EL 2 blanks the whole row but leaves the cursor at col 1, so "y"
    # prints one cell in (matches the whole-feed control below).
    check rowText(s.grid, 0).strip == "y"
    let ctl = TtySession(grid: newGrid(), keepHistory: false)
    ctl.grid.width = 40; ctl.grid.height = 10
    ctl.feedGridChunk "x\x1b[2Ky"
    check rowText(s.grid, 0) == rowText(ctl.grid, 0)

  test "feedGridChunk sync-splitting still works with a pending tail":
    # A SyncEnd whose sequence straddles the chunk boundary must still
    # commit its frame, and the held tail must not corrupt the next burst.
    let s = TtySession(grid: newGrid(), keepHistory: true)
    s.grid.width = 40
    s.grid.height = 10
    s.feedGridChunk "\x1b[?2026hrow-one\r\n\x1b[?2026"
    check s.pendingEsc == "\x1b[?2026"
    s.feedGridChunk "l"
    check s.frames.len == 1
    check rowText(s.grid, 0).strip == "row-one"

  test "splitIncompleteEscape splits at incomplete tail only":
    let (c, p) = splitIncompleteEscape("abc\x1b[2")
    check c == "abc"
    check p == "\x1b[2"
    let (c2, p2) = splitIncompleteEscape("\x1b[2Kdef\x1b[38;5;244")
    check c2 == "\x1b[2Kdef"
    check p2 == "\x1b[38;5;244"
    let (c3, p3) = splitIncompleteEscape("plain")
    check c3 == "plain"
    check p3 == ""
    let (c4, p4) = splitIncompleteEscape("end\x1b")
    check c4 == "end"
    check p4 == "\x1b"
    let (c5, p5) = splitIncompleteEscape("")
    check c5 == ""
    check p5 == ""
