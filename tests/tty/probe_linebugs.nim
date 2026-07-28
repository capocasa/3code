## Interactive repro for two reported rendering bugs:
##
## Bug 1: after `:provider <name>` prints its multi-line profile block,
## typing into the prompt erases the last block line ("reasoning low").
##
## Bug 2: on submit, the prompt line jumps one row before scrollback
## continues.
##
## Drives the real stub binary under a PTY, captures full frames, and
## prints snapshots after each phase so the screen state is inspectable.

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
  echo "=== [", label, "] caret row=", f.cursorRow, " col=", f.cursorCol,
       " hidden=", f.cursorHidden, " ==="
  for i, row in f.rows:
    let mark = if i == f.cursorRow: " <CARET" else: ""
    echo align($i, 2), " |", row, "|", mark
  echo "=== end [", label, "] ==="

proc main() =
  let root = newFixture("repro_linebugs")
  writeConfiguredProvider(root)
  # Long streamed response with reasoning chunks, matching the scenario:
  # a reasoning-model turn the user types over.
  let chunkList = ["alpha ", "beta ", "gamma ", "delta ", "epsilon ",
                   "zeta ", "eta ", "theta ", "iota ", "kappa ",
                   "lambda ", "mu ", "nu ", "xi "]
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": chunkList.join("").strip(),
     "contentChunks": %*chunkList,
     "contentChunkDelayMs": 100,
     "reasoning": "thinking about the answer step by step",
     "reasoningChunks": %*["thinking ", "about ", "the ", "answer ",
                            "step ", "by ", "step"],
     "usage": {"promptTokens": 20, "completionTokens": 14,
               "totalTokens": 34, "cachedTokens": 0}}
  ]))
  let stub = ensureStubBinary()
  let tty = newTtySession(stub,
                          args = ["-x", "-i"],
                          cwd = root / "run",
                          env = stubEnv(root, root / "run" / "stub_responses.json"))
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()

  tty.expect "❯"

  # Phase 1: :provider <name> prints the profile block, then typing.
  tty.send ":provider stub"
  tty.expect ":provider stub"
  tty.send "\n"
  tty.expectInHistory "reasoning"
  snapshot(tty, "after :provider stub")
  let commitFrame = tty.frames.len - 1
  for ch in "typ":
    rawSend(tty, $ch)
    tty.drain(80, recordFrame = true)
  snapshot(tty, "typing after :provider")

  # Wipe check: any row non-blank at the commit snapshot that is blank in a
  # later frame while the row above it is unchanged was erased in place
  # (an over-walk by the typing repaint into committed scrollback).
  let base = tty.frames[commitFrame].rows
  var wiped = ""
  for i in commitFrame + 1 ..< tty.frames.len:
    let cur = tty.frames[i].rows
    for r in 1 ..< min(base.len, cur.len):
      if base[r].strip.len == 0: continue
      if cur[r].strip.len > 0: continue
      if base[r - 1] == cur[r - 1]:
        wiped = "frame " & $i & " row " & $r & " wiped in place: \"" &
          base[r] & "\" -> blank (row above unchanged \"" & base[r-1] & "\")"
        break
    if wiped.len > 0: break
  if wiped.len > 0:
    echo "WIPE DETECTED: ", wiped
  else:
    echo "no in-place wipe detected while typing"

  # Phase 2: clear the line, submit a prompt, watch the transition rows.
  tty.send "\x15"   # ctrl-U: kill line
  tty.drain(60)
  rawSend(tty, "go")
  tty.expect "go"
  snapshot(tty, "before submit")
  rawSend(tty, "\n")
  tty.drain(30, recordFrame = true)
  snapshot(tty, "just after submit")
  tty.expectInHistory "alpha"
  # Type while the response is streaming.
  for ch in "hel":
    rawSend(tty, $ch)
    tty.drain(80)
  snapshot(tty, "typing during stream")
  tty.drain(3000)
  snapshot(tty, "final")
  tty.expectAlive()

when isMainModule:
  main()
