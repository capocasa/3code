discard """
  disabled: "win"
"""
## Basic end-to-end operation with the gui thread LIVE.
##
## Every other gui-facing test runs with the deterministic frame handshake
## (`THREECODE_TEST_FRAME_FD`), which disables the free-running 80ms gui
## thread. That thread is exactly what races the submit commit and the
## streaming repaints in production, so those tests structurally cannot
## reproduce the intermittent row loss on submit. This test sets
## `THREECODE_TEST_GUI_LIVE=1` to keep the real gui cadence and exercises the
## basic flow — startup chrome, typing, first submit, streamed reply, second
## submit — asserting the committed layout stays correct:
##
##   hint row H, blank row H+1, echo row H+2
##   first echo survives the second submit, echoes in order.

import std/[json, os, strutils]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata" / "output" / "tty" / (name & "_" & $getCurrentProcessId())
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
reasoning = on
""")

proc chunks(prefix: string): JsonNode =
  result = newJArray()
  for i in 1..30:
    result.add %(prefix & " chunk" & $i & " ")

proc one(iter: int; term: string): string =
  let root = newFixture("gui_live_" & term.replace("-", "_") & "_" & $iter)
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $ %*[
    {"content": "", "contentChunks": chunks("ONE"),
     "usage": {"promptTokens": 12, "completionTokens": 8, "totalTokens": 20, "cachedTokens": 0}},
    {"content": "", "contentChunks": chunks("TWO"),
     "usage": {"promptTokens": 30, "completionTokens": 10, "totalTokens": 40, "cachedTokens": 0}}
  ])
  createDir(root / "tmp")
  let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                          cwd = root / "run",
                          env = @[
                            # term drives the DEC 2026 sync gate: xterm-256color
                            # keeps sync on, xterm-ghostty turns it off (the
                            # ghostty corruption workaround). Both must produce
                            # the same committed layout.
                            (key: "TERM", val: term),
                            (key: "PATH", val: getEnv("PATH")),
                            (key: "HOME", val: root),
                            (key: "TMPDIR", val: root / "tmp"),
                            (key: "XDG_CONFIG_HOME", val: root / "xdg"),
                            (key: "XDG_DATA_HOME", val: root / "data"),
                            (key: "THREECODE_STUB_RESPONSES", val: root / "run" / "stub_responses.json"),
                            # The whole point: real 80ms gui thread, not the
                            # deterministic handshake.
                            (key: "THREECODE_TEST_GUI_LIVE", val: "1"),
                          ], cols = 119, rows = 40)
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()
  tty.expect "type a prompt"
  tty.expect "❯"

  for ch in "first prompt here":
    tty.send $ch
    tty.drain(8)
  tty.send "\n"
  tty.expect "❯"
  tty.drain(300)
  block:
    let hintIdx = tty.rowContaining("type a prompt")
    let echoIdx = tty.rowContaining("❯ first prompt here")
    if hintIdx < 0: return "iter " & $iter & " turn1: hint missing"
    if echoIdx < 0:
      return "iter " & $iter & " turn1: echo missing\n" & tty.dumpFramesAround("ONE chunk1")
    if echoIdx != hintIdx + 2:
      return "iter " & $iter & " turn1: echo not 2 below hint (hint=" & $hintIdx &
        " echo=" & $echoIdx & ")\n" & tty.dumpFramesAround("ONE chunk1")

  for ch in "second prompt now":
    tty.send $ch
    tty.drain(8)
  tty.send "\n"
  tty.expect "❯"
  tty.drain(300)
  block:
    let echo1 = tty.rowContaining("❯ first prompt here")
    let echo2 = tty.rowContaining("❯ second prompt now")
    if echo1 < 0:
      return "iter " & $iter & " turn2: FIRST echo deleted\n" & tty.dumpFramesAround("TWO chunk1")
    if echo2 < 0:
      return "iter " & $iter & " turn2: second echo missing\n" & tty.dumpFramesAround("TWO chunk1")
    if echo2 <= echo1:
      return "iter " & $iter & " turn2: echoes out of order (echo1=" & $echo1 &
        " echo2=" & $echo2 & ")\n" & tty.dumpFramesAround("TWO chunk1")
  ""

when isMainModule:
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 20
  var failures = 0
  for i in 1..n:
    for term in ["xterm-256color", "xterm-ghostty"]:
      let f = one(i, term)
      if f.len > 0:
        inc failures
        echo "FAIL[", term, "]: ", f
  echo "ran ", n, " iterations x2 terms, ", failures, " failures"
  if failures > 0: quit(1)