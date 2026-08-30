## Repro probe: resume replay of a web_search tool item.
## Phase 1: run a turn with a web_search tool call, quit.
## Phase 2: resume and capture the replayed scrollback frames.

import std/[json, os, strutils]
import tty_expect
import stub_helpers

let root = getCurrentDir() / "testdata" / "output" / "tty" /
  ("repro_resume_tool_" & $getCurrentProcessId())
createDir(root / "run")
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

proc toolCall(id, name: string, args: JsonNode; stub: JsonNode = nil): JsonNode =
  result = %*{
    "id": id,
    "type": "function",
    "function": {
      "name": name,
      "arguments": $args
    }
  }
  if stub != nil:
    result["stub"] = stub

writeFile(root / "run" / "stub_responses.json", $ %*[
  {
    "role": "assistant",
    "content": "Searching now.",
    "contentChunks": ["Searching now."],
    "tool_calls": [
      toolCall("call_search", "web_search", %*{
        "query": "terminal rendering"
      }, %*{
        "output": "1. Terminal Rendering Guide\nhttps://example.test/rendering\nUseful result snippet.\n",
        "code": 0
      })
    ],
    "usage": {
      "promptTokens": 300,
      "completionTokens": 44,
      "totalTokens": 344,
      "cachedTokens": 0
    }
  },
  {
    "role": "assistant",
    "content": "Search done.",
    "contentChunks": ["Search done."],
    "usage": {
      "promptTokens": 310,
      "completionTokens": 10,
      "totalTokens": 320,
      "cachedTokens": 0
    }
  }
])

proc stubEnv(): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: root / "run" / "stub_responses.json"),
  ]

proc start(args: openArray[string]): TtySession =
  newTtySession(ensureStubBinary(), args = args, cwd = root / "run",
                env = stubEnv(), cols = 80, rows = 40)

block phase1:
  let tty = start(["-x", "-i"])
  defer: tty.close()
  tty.expect "❯"
  tty.send "go search\n"
  tty.expectInHistory "Search done."
  tty.drain(400)

block phase2:
  let tty = start(["-x", "-r"])
  defer:
    tty.writeFrameArtifact(root / "resume_frames.txt")
    tty.writeMeaningfulFrameArtifact(root / "resume_meaningful_frames.txt")
    tty.close()
  tty.expect "resumed"
  tty.drain(600)
  echo "=== phase 2 done, frames written ==="
