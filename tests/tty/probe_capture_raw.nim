## Capture FAITHFUL raw PTY-master bytes (ONLCR-intact, `\r\r\n` preserved)
## for the ttty xterm-conformance corpus. Drives the hint-loss scenario:
## fresh startup (welcome + bar + prompt), type a prompt, submit, first turn.
## The whole point: `cleanRaw` strips `\r`, hiding the line-discipline
## doubling; this capture keeps every byte so replaying the stream into a
## real terminal reproduces the model-vs-physical desync.

import std/[os, strutils, json]
import tty_expect
import stub_helpers

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

when isMainModule:
  let outDir = getEnv("RAW_OUT_DIR", "testdata/output/tty")
  createDir(outDir)
  let root = newFixture("capture_raw")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $ %*[
    {"content": "REPLY_ONE", "contentChunks": ["REPLY_ONE"],
     "usage": {"promptTokens": 12, "completionTokens": 8,
               "totalTokens": 20, "cachedTokens": 0}}
  ])
  let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                          cwd = root / "run",
                          env = stubEnv(root, root / "run" / "stub_responses.json"),
                          cols = 120, rows = 40)

  # Startup: welcome + bar + idle prompt fully painted.
  tty.expect "❯"
  tty.drain(300)
  tty.writeRawArtifact(outDir / "capture_startup_raw.raw")

  # Type a prompt (real keystrokes), then submit.
  tty.send "hello first turn"
  tty.expect "hello first turn"
  tty.drain(200)
  tty.writeRawArtifact(outDir / "capture_typed_raw.raw")
  tty.send "\n"
  tty.expect "REPLY_ONE"
  tty.drain(400)
  tty.writeRawArtifact(outDir / "capture_submit_turn_raw.raw")

  # Sanity: the faithful capture must contain the ONLCR doubling that
  # cleanRaw would have destroyed. If it does not, the capture path is
  # cooked and the corpus is blind again.
  let raw = readFile(outDir / "capture_submit_turn_raw.raw")
  echo "capture bytes: ", raw.len
  echo "contains \\r\\r\\n (ONLCR doubling): ", raw.contains("\r\r\n")
  echo "contains \\r\\n: ", raw.contains("\r\n")
  echo "hint text present: ", raw.contains("type a prompt")
  tty.close()
