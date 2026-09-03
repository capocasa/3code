## Reproduction: after the first submit, the volatile gap row above the
## idle prompt collapses away instead of being left blank, so the committed
## echo lands directly under the welcome hint with no empty row between
## them. (When startup still primed a `○0%` bar, this was the row it sat
## on.)
##
## Expected layout after the turn settles:
##   type a prompt. :help ...
##   <blank row>            <- the gap row, must survive as empty
##   ❯ <echo>
##   ○... footer
##   ❯ <fresh prompt>
##
## Buggy layout: the blank row is gone, echo sits directly under the hint.

import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

const VisualOutputRoot = "testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

proc writeConfiguredProvider(root: string; reasoning: bool) =
  createDir(root / "xdg" / "3code")
  # reasoning = on adds the welcome hint row, matching the real reproduction.
  let reasoningLine = if reasoning: "reasoning = on\n" else: ""
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""" & reasoningLine)

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

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

proc runCase(reasoning: bool) =
    let tag = if reasoning: "reasoning_on" else: "reasoning_off"
    let root = newFixture("first_submit_blank_row_" & tag)
    writeConfiguredProvider(root, reasoning)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "ANSWER-MARKER",
        "contentChunks": ["ANSWER-MARKER"],
        "usage": {
          "promptTokens": 12,
          "completionTokens": 8,
          "totalTokens": 20,
          "cachedTokens": 0
        }
      }
    ])
    let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"),
                            cols = 119, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "type a prompt"
    tty.expect "❯"
    tty.send "this is a test just reply"
    tty.expect "this is a test just reply"
    tty.send "\n"
    tty.expect "ANSWER-MARKER"
    tty.expect "❯"
    tty.drain(500)

    let rows = tty.rows()
    let hintIdx = tty.rowContaining("type a prompt")
    let echoIdx = tty.rowContaining("❯ this is a test just reply")
    doAssert hintIdx >= 0, "hint row missing (" & tag & ")\n" & tty.dumpFramesAround("ANSWER-MARKER")
    doAssert echoIdx >= 0, "echo row missing (" & tag & ")\n" & tty.dumpFramesAround("ANSWER-MARKER")

    # The echo must not sit directly under the hint: exactly one blank row
    # (the leftover gap row) separates them.
    doAssert echoIdx == hintIdx + 2,
      "(" & tag & ") expected echo two rows below hint (hint, blank, echo); got hint=" &
      $hintIdx & " echo=" & $echoIdx & "\n" &
      tty.dumpFramesAround("ANSWER-MARKER")
    doAssert rows[hintIdx + 1].strip.len == 0,
      "(" & tag & ") row between hint and echo must be blank, got: '" & rows[hintIdx + 1] &
      "'\n" & tty.dumpFramesAround("ANSWER-MARKER")

suite "first submit blank row":
  test "reasoning on: blank spacer row survives between hint and committed echo":
    runCase(reasoning = true)
  test "reasoning off: blank spacer row survives between hint and committed echo":
    runCase(reasoning = false)
