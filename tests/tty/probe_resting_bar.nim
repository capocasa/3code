## Interactive repro: the resting context bar above the idle prompt after a
## completed turn. Report: after running a prompt the token bar is deleted
## (prompt-only footer); it reappears on the next update. Expected: the bar
## stays with the latest numbers (the resting context label).
##
## Drives the real stub binary under a PTY across turn shapes: plain reply,
## tool-call turn, second plain turn, and a keystroke repaint.

import std/[json, os, posix, strutils]
import tty_expect, stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata" / "output" / "tty" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeHarnessProviders(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model stub-large"
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

proc snapshot(s: TtySession; label: string) =
  let f = s.frames[^1]
  echo "=== [", label, "] caret row=", f.cursorRow, " col=", f.cursorCol, " ==="
  for i, row in f.rows:
    let mark = if i == f.cursorRow: " <CARET" else: ""
    echo align($i, 2), " |", row, "|", mark

proc toolCall(id, name: string; args: JsonNode): JsonNode =
  %*{"id": id, "type": "function",
     "function": {"name": name, "arguments": $args}}

proc main() =
  let root = newFixture("probe_resting_bar")
  writeHarnessProviders(root)
  writeFile(root / "run" / "stub_responses.json", $ %*[
    # Turn 1: plain reply.
    {"role": "assistant", "preStreamDelayMs": 50,
     "content": "turn one reply", "contentChunks": ["turn one reply"],
     "usage": {"promptTokens": 6000, "completionTokens": 3,
                "totalTokens": 6003, "cachedTokens": 0}},
    # Turn 2: tool call, then final reply.
    {"role": "assistant", "preStreamDelayMs": 50,
     "content": "checking", "contentChunks": ["checking"],
     "tool_calls": [toolCall("c1", "bash", %*{"command": "echo tool-ran"})],
     "usage": {"promptTokens": 6500, "completionTokens": 5,
                "totalTokens": 6505, "cachedTokens": 0}},
    {"role": "assistant", "preStreamDelayMs": 50,
     "content": "turn two reply", "contentChunks": ["turn two reply"],
     "usage": {"promptTokens": 7000, "completionTokens": 4,
                "totalTokens": 7004, "cachedTokens": 0}},
    # Turn 3: reply with NO usage (no-usage turn end).
    {"role": "assistant", "preStreamDelayMs": 50, "noUsage": true,
     "content": "turn three reply", "contentChunks": ["turn three reply"]},
    # Turn 4: plain reply (does the bar come back?).
    {"role": "assistant", "preStreamDelayMs": 50,
     "content": "turn four reply", "contentChunks": ["turn four reply"],
     "usage": {"promptTokens": 8000, "completionTokens": 4,
                "totalTokens": 8004, "cachedTokens": 0}}
  ])
  let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                          cwd = root / "run",
                          env = stubEnv(root, root / "run" / "stub_responses.json"))
  defer: tty.close()
  tty.expect "❯"

  tty.send "turn one"
  tty.send "\n"
  tty.expectTokenBar(["◑", "↑6.0k", "↓3"])
  tty.drain(500)
  snapshot(tty, "after turn 1 (plain) settles")

  tty.send "turn two"
  tty.send "\n"
  tty.expectInHistory "tool-ran"
  tty.expectTokenBar(["◑", "↑7.0k", "↓4"])
  tty.drain(500)
  snapshot(tty, "after turn 2 (tool call) settles")

  tty.send "turn three"
  tty.send "\n"
  tty.expectInHistory "turn three reply"
  tty.drain(500)
  snapshot(tty, "after turn 3 (NO USAGE) settles")

  tty.send "x"
  tty.drain(300)
  snapshot(tty, "after turn 3, one keystroke")

  tty.send "\x15"   # kill line
  tty.send "turn four"
  tty.send "\n"
  tty.expectTokenBar(["◕", "↑8.0k", "↓4"])
  tty.drain(500)
  snapshot(tty, "after turn 4 (plain) settles")
  tty.send "\x04"

main()
