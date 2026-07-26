## Reproduction harness for scrollback spacing. Drives two consecutive bash
## tool calls with multi-line output and dumps the final screen so the blank
## lines between scrollback items are visible.

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

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc toolCall(id, name: string, args: JsonNode; stub: JsonNode = nil): JsonNode =
  result = %*{"id": id, "type": "function", "function": {"name": name, "arguments": $args}}
  if stub != nil: result["stub"] = stub

when isMainModule:
  let root = newFixture("repro_spacing")
  writeConfiguredProvider(root)
  writeStubResponses(root, %*[
    {
      "content": "Running two tools.",
      "contentChunks": ["Running two tools."],
      "tool_calls": [
        toolCall("call1", "bash", %*{"command": "echo a; echo b; echo c"},
                 %*{"output": "a\nb\nc", "code": 0}),
        toolCall("call2", "bash", %*{"command": "echo x; echo y"},
                 %*{"output": "x\ny", "code": 0})
      ]
    },
    {"content": "Done.", "contentChunks": ["Done."]}
  ])

  let stub = ensureStubBinary()
  let env = @[
    ("XDG_CONFIG_HOME", root / "xdg"),
    ("XDG_DATA_HOME", root / "data"),
    ("HOME", root),
  ]

  let respPath = root / "run" / "stub_responses.json"
  let tty = newTtySession(stub, ["-x", "-i", "do it"], rows = 30, cols = 80,
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
  tty.drain(200)
  tty.close()

  echo "=== FINAL SCREEN (30x80) ==="
  for i, row in tty.rows():
    echo align($i, 2), " |", row, "|"
  echo "=== END ==="
