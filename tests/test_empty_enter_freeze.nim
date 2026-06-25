## Targeted regression: empty Enter at the idle prompt must not freeze the
## input thread. Before the fix, onSubmit parked the thread on
## inputIdleSubmitted even for empty text, and the controller had nothing to
## consume, so both threads spun in sleep-loops forever.
import std/[json, os, strutils, unittest]
import tty_expect

const Root = "tests/output/tty/empty_enter_freeze"

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/output/tty" / (name & "_" & $getCurrentProcessId())
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
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
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
    let tty = newTtySession("/tmp/3code_tty_stub",
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    # Idle prompt is up.
    tty.expect "\u276f"

    # Empty Enter at idle -- the exact trigger that used to wedge the
    # input thread. expect() has a 5s timeout, so a hang fails the test
    # rather than blocking the suite.
    tty.send "\n"

    # Process must still be responsive: send a real prompt.
    tty.drain(200)
    tty.expect "\u276f"
    tty.send "hello model"
    tty.expect "hello model"
    tty.send "\n"
    tty.expectInHistory "ok."

    # And a command after the turn.
    tty.drain(200)
    tty.expect "\u276f"
    tty.send ":tokens"
    tty.expect ":tokens"
    tty.send "\n"

    echo "  PASS: empty Enter did not freeze the prompt"
