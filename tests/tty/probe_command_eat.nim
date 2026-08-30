## Probe for the ":provider eats the previous scrollback line" report.
## Sends a user turn so the stub's reply commits into scrollback, then runs
## an idle system command, then dumps the final screen with visible row
## numbers so the eaten line is visible.

import std/[json, os, strutils]
import tty_expect, stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
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

when isMainModule:
  let root = newFixture("command_eat")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $ %*[
    {"content": "REPLY_ONE", "contentChunks": ["REPLY_ONE"]}
  ])

  let stub = ensureStubBinary()
  let respPath = root / "run" / "stub_responses.json"
  let tty = newTtySession(stub, @["-x"], rows = 30, cols = 40,
                          env = @[
                            (key: "TERM", val: "xterm-256color"),
                            (key: "PATH", val: getEnv("PATH")),
                            (key: "HOME", val: root),
                            (key: "XDG_CONFIG_HOME", val: root / "xdg"),
                            (key: "XDG_DATA_HOME", val: root / "data"),
                            (key: "THREECODE_STUB_RESPONSES", val: respPath),
                          ], cwd = root / "run")
  discard tty.waitForOutput(8000)
  tty.drain(300)

  # Turn 1: user message, stub replies REPLY_ONE, endTurn paints bar+prompt.
  tty.send "hello\n"
  tty.expectInHistory "REPLY_ONE"
  tty.drain(300)

  # Snapshot frames tightly around each command execution: type, wait
  # for the typed echo, clear the frame log, submit, capture the commit.
  proc snap(label: string) =
    echo "--- " & label & " ---"
    let last = tty.frames[^1]
    for i, line in last.rows:
      echo align($i, 2), " |", line, "|"

  # Fill the screen so commands execute at the bottom edge.
  for i in 1..3:
    tty.send ":help\n"
    tty.expectInHistory "the economical coding agent"
    tty.drain(150)
  # Multi-line editor buffer at submit: wrap the command across visual rows.
  let longCmd = ":sandbox allow " & repeat('x', 90)
  tty.send longCmd
  tty.expect "xxxx"
  tty.frames.setLen(0)
  tty.send "\n"
  tty.drain(300)
  snap "after wrapped :sandbox allow"
  for cmd in [":tokens", ":provider", ":model stub-model", ":help"]:
    tty.send cmd
    tty.expect "❯ " & cmd
    tty.frames.setLen(0)
    tty.send "\n"
    tty.drain(300)
    snap "after " & cmd
  tty.drain(300)

  tty.writeFrameArtifact(root / "frames.txt")
  echo "=== FINAL SCREEN (30x80) ==="
  for i, row in tty.rows():
    echo align($i, 2), " |", row, "|"
  echo "=== END ==="
  tty.close()
