discard """
  disabled: "win"
  ## Flaky under ConPTY in the full testament suite: the empty-Enter
  ## responsiveness check is timing-sensitive to ConPTY output latency.
  ## Passes in isolation.
"""
## Targeted regression: empty Enter at the idle prompt must not freeze the
## input thread. Before the fix, onSubmit parked the thread on
## inputIdleSubmitted even for empty text, and the controller had nothing to
## consume, so both threads spun in sleep-loops forever.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

const Root = "testdata/output/tty/empty_enter_freeze"

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  let data = root / "data"
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

suite "idle enter freeze regression":
  test "empty Enter then a real prompt stays responsive":
    let root = newFixture("empty_enter_freeze")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "ok.", "contentChunks": ["ok."],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"),
                            keepHistory = false)
    defer:
      tty.close()

    # Idle prompt is up.
    tty.expect "\u276f"

    # Empty Enter at idle.
    tty.send "\n"
    tty.drain(200)
    tty.expect "\u276f"

    # Send a real prompt, character by character for reliability.
    for ch in "hello model":
      tty.send($ch)
      tty.drain(10)
    tty.send "\n"

    # Wait for model response.
    tty.expectInHistory "ok."

    # Prompt must be back after the turn.
    tty.drain(200)
    tty.expect "\u276f"

    # Send a command.
    for ch in ":tokens":
      tty.send($ch)
      tty.drain(10)
    tty.send "\n"
    tty.drain(200)
    tty.expectAlive()  # empty Enter + command must not exit the process

    echo "  PASS: empty Enter did not freeze the prompt"