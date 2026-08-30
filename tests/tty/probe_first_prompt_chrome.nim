## Probe for the first-prompt chrome report: the very first prompt is
## missing the token bar and thinking ticker, and after sending the prompt
## the empty line above it collapses, scrolling the prompt up by one.
## Dumps the screen at startup and after the first turn with row numbers.

import std/[os, strutils, json]
import tty_expect, ../stub_helpers

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

proc dump(s: TtySession; label: string) =
  echo "--- " & label & " ---"
  for i, row in s.rows():
    echo align($i, 2), " |", row, "|"

when isMainModule:
  let root = newFixture("first_prompt_chrome")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $ %*[
    {"content": "REPLY_ONE", "contentChunks": ["REPLY_ONE"],
     "usage": {"promptTokens": 12, "completionTokens": 8,
               "totalTokens": 20, "cachedTokens": 0}},
    {"content": "REPLY_TWO", "contentChunks": ["REPLY_TWO"],
     "usage": {"promptTokens": 30, "completionTokens": 8,
               "totalTokens": 38, "cachedTokens": 0}}
  ])

  let stub = ensureStubBinary()
  let respPath = root / "run" / "stub_responses.json"
  let tty = newTtySession(stub, @["-x", "-i"], rows = 24, cols = 80,
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
  dump(tty, "startup (first prompt)")

  tty.send "hello\n"
  tty.expect "REPLY_ONE"
  tty.drain(400)
  dump(tty, "after first turn")

  tty.send "second\n"
  tty.expect "REPLY_ONE"
  tty.drain(400)
  dump(tty, "after second turn")

  tty.writeFrameArtifact(root / "frames.txt")
  tty.close()
