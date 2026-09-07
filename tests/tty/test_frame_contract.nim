discard """
  action: run
  disabled: "win"
"""

import std/[unittest, osproc]
include ../tty_expect

proc capture(s: TtySession; bytes: string) =
  s.grid.feed(bytes)
  s.rememberFrame()

suite "lossless frame contracts (ttty model)":
  test "semantic checkpoints do not suppress diagnostic capture":
    let s = TtySession(grid: newGrid(), keepHistory: true, started: epochTime())
    s.frameRecordingPaused = true
    s.feedGridChunk("\e[?2026hfirst\e[?2026l")
    check s.frames.len == 1
    let first = s.checkpoint("prompt-ready")
    s.feedGridChunk("\e[?2026h\e[1Gsecond\e[?2026l")
    check s.frames.len == 2
    check s.checkpoints.len == 1
    check first.id == "prompt-ready"
    check s.checkpoints[0].cells[0][0].rune == Rune('f')
    expect AssertionDefect:
      discard s.checkpoint("prompt-ready")

  test "cursor movement visibility and style are visual changes":
    let s = TtySession(grid: newGrid(), keepHistory: true, started: epochTime())
    s.capture("abc")
    s.capture("\e[1G")
    check s.frames.len == 2
    s.capture("\e[?25l")
    check s.frames.len == 3
    s.capture("\e[31ma")
    check s.frames.len == 4
    s.capture("\e[1G\e[32ma")
    check s.frames.len == 5

  test "overlay uses physical cells not rune indices":
    let s = TtySession(grid: newGrid(), keepHistory: true, started: epochTime())
    s.capture("界xy\e[1;3H")
    check s.frames[0].frameRowsWithCursor()[0] == "界█y"
    s.capture("\e[1G\e[Kéxy\e[1;2H")
    check s.frames[^1].frameRowsWithCursor()[0] == "é█y"

  test "normalization retains cursor and physical row boundaries":
    check normalizeFrameRows(["abc█"])[0] == "abc█"
    check normalizeWrappedPathTail("path.m\nd\n") == "path.m\nd\n"
    check normalizeFrameRows(["  123s text"])[0].len == "  123s text".len

  test "frame labels are repeatable":
    let s = TtySession(grid: newGrid(), keepHistory: true, started: epochTime())
    s.capture("abc")
    check s.meaningfulFrameText() == s.meaningfulFrameText()

  test "structured roundtrip style coordinates redaction and CLI":
    let s = TtySession(grid: newGrid(), keepHistory: true, started: epochTime())
    s.capture("\e[31m界abc")
    let original = s.frames[0].visual
    let encoded = $original.frameJson()
    check firstDifference(original, parseVisualFrame(encoded)) == ""
    var edited = original
    edited.cells[0][2].attrs = SgrAttr(1)
    check "row=0 col=2" in firstDifference(original, edited)
    edited = original
    edited.redactCells(0, 0, 2)
    check edited.cells[0].len == original.cells[0].len
    check edited.cells[0][0].width == 2
    check edited.cursorCol == original.cursorCol
    let root = getTempDir() / ("astra-frames-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    s.writeFrameArtifact(root / "frames.txt")
    discard s.checkpoint("styled-ready")
    s.writeCheckpoints(root / "expected.jsonl")
    s.expectCheckpoints(root / "expected.jsonl", root / "actual.jsonl")
    s.checkpoints[0].cursorHidden = not s.checkpoints[0].cursorHidden
    expect AssertionDefect:
      s.expectCheckpoints(root / "expected.jsonl", root / "actual.jsonl")
    let viewer = root / "viewer"
    check execCmd("nim c --hints:off --out:" & quoteShell(viewer) & " tools/pty_frames.nim") == 0
    let artifact = quoteShell(root / "frames.txt.jsonl")
    check execCmd(quoteShell(viewer) & " --diff " & artifact & " " & artifact) == 0
    let dump = execCmdEx(quoteShell(viewer) & " --dump " & artifact)
    check dump.exitCode == 0
    check "cursor=" in dump.output
    writeFile(root / "changed.jsonl", $edited.frameJson() & "\n")
    check execCmdEx(quoteShell(viewer) & " --diff " & artifact & " " & quoteShell(root / "changed.jsonl")).exitCode == 1
    writeFile(root / "legacy.txt", "===== 123 =====\nlegacy\n")
    check "legacy" in execCmdEx(quoteShell(viewer) & " --dump " & quoteShell(root / "legacy.txt")).output
