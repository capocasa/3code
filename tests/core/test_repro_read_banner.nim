import std/[strutils, unittest]
import threecode/[display, types]

suite "repro: read banner keeps path under truncation":
  test "toolTranscriptBytes banner row contains act.path for >15-line read":
    let act = Action(kind: akRead, path: "bigfile.txt")
    var lines: seq[string] = @[]
    for i in 1 .. 30:
      lines.add "line " & $i
    let body = lines.join("\n") &
      "\n... [file is 30 lines, 600 bytes; showed 30 lines from line 1. Use read(path, offset, limit) for a specific range.] ..."
    let bytes = toolTranscriptBytes(act, body, code = 0, idx = 1)
    check "bigfile.txt" in bytes
    let firstLine = bytes.split("\r\n")[0]
    check "bigfile.txt" in firstLine

  test "empty-path read banner surfaces (no path) instead of a bare 'r '":
    # The user-reported symptom: a read banner rendered as `r ` with no
    # filename. bannerFor must surface a missing/blank path visibly so the
    # banner row is never a bare icon with nothing after it.
    let act = Action(kind: akRead, path: "")
    let bytes = toolTranscriptBytes(act, "error:  does not exist", code = 1, idx = 1)
    check "(no path)" in bytes
    let firstLine = bytes.split("\r\n")[0]
    check "(no path)" in firstLine

  test "empty-path write and patch banners also surface (no path)":
    let wAct = Action(kind: akWrite, path: "")
    check "(no path)" in toolTranscriptBytes(wAct, "error", 1, 1).split("\r\n")[0]
    let pAct = Action(kind: akPatch, path: "")
    check "(no path)" in toolTranscriptBytes(pAct, "error", 1, 1).split("\r\n")[0]
