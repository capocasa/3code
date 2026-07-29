## Interactive repro for the resume-with-usage bar desync.
##
## On --resume with prior usage, threecode.nim paints bar+prompt via raw
## `stdout.write barFooterBytes(...)` without going through the engine, so
## `paintedFooterRows` is never registered while the frame model claims the
## bar exists. Every later walk-up under-counts by the bar height: typing
## repaints erase into committed scrollback (a scrollback line vanishes), and
## the next submit lands one row off (the prompt line jumps).
##
## Drives the real stub binary under a PTY across two sessions: phase 1 builds
## usage, phase 2 resumes and types while watching frames for in-place wipes.

import std/[json, os, posix, strutils]
import tty_expect, stub_helpers

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
reasoning = "low"
reasonings = "off, low, high"
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

proc rawSend(s: TtySession; text: string) =
  if text.len == 0: return
  discard posix.write(s.masterFd, text[0].unsafeAddr, text.len)

proc snapshot(s: TtySession; label: string) =
  s.drain(60, recordFrame = true)
  let f = s.frames[^1]
  echo "=== [", label, "] caret row=", f.cursorRow, " col=", f.cursorCol, " ==="
  for i, row in f.rows:
    let mark = if i == f.cursorRow: " <CARET" else: ""
    echo align($i, 2), " |", row, "|", mark

proc main() =
  let root = newFixture("repro_resume_bar")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": "the quick brown fox jumps",
     "contentChunks": %*["the quick brown fox jumps"],
     "usage": {"promptTokens": 40, "completionTokens": 6,
               "totalTokens": 46, "cachedTokens": 0}}
  ]))
  let stub = ensureStubBinary()

  # Phase 1: build a turn so usage lands in the session log.
  block phase1:
    let tty = newTtySession(stub, args = ["-x", "-i"], cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty.close()
    tty.expect "❯"
    tty.send "hello\n"
    tty.expectInHistory "quick brown fox"
    tty.drain(400)

  # Phase 2: resume. The bar+prompt is painted raw (no engine registration).
  block phase2:
    let tty = newTtySession(stub, args = ["-x", "-i", "-r"], cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "resume_frames.txt")
      tty.close()
    tty.expect "resumed"
    tty.drain(400)
    snapshot(tty, "after resume")
    let base = tty.frames[^1].rows
    let baseFrame = tty.frames.len - 1
    # Type a few characters; each keystroke repaints via walkUp.
    for ch in "typ":
      rawSend(tty, $ch)
      tty.drain(80, recordFrame = true)
    snapshot(tty, "typing after resume")
    # In-place wipe check against the post-resume baseline.
    var wiped = ""
    for i in baseFrame + 1 ..< tty.frames.len:
      let cur = tty.frames[i].rows
      for r in 1 ..< min(base.len, cur.len):
        if base[r].strip.len == 0: continue
        if cur[r].strip.len > 0: continue
        if base[r - 1] == cur[r - 1]:
          wiped = "frame " & $i & " row " & $r & " wiped: \"" & base[r] &
            "\" -> blank (row above unchanged \"" & base[r-1] & "\")"
          break
      if wiped.len > 0: break
    if wiped.len > 0:
      echo "WIPE DETECTED: ", wiped
    else:
      echo "no in-place wipe detected while typing after resume"
    tty.send "\x03"
    tty.drain(200)
    tty.send ":q\n"
    tty.drain(200)

when isMainModule:
  main()
