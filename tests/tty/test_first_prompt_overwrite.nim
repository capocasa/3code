import std/[json, os, strutils, times, unittest]
import tty_expect
import stub_helpers

const VisualOutputRoot = "testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

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

proc startStub(root: string; cols = 80; rows = 24): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                cols = cols, rows = rows)

suite "first prompt overwrite math":
  test "first turn response is not overwritten by prompt-only footer math":
    # At startup the fat prompt is prompt-only: no token bar, no thinking
    # ticker. Walk-up / erase math must not reserve bar+ticker rows that are
    # not on screen, or the first assistant response gets eaten when the
    # footer is painted/repainted.
    let root = newFixture("first_prompt_overwrite")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "UNIQUE-FIRST-ANSWER-MARKER visible forever",
        "contentChunks": ["UNIQUE-FIRST-ANSWER-MARKER visible forever"],
        "usage": {
          "promptTokens": 12,
          "completionTokens": 8,
          "totalTokens": 20,
          "cachedTokens": 0
        }
      }
    ])
    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()
    tty.expect "❯"
    tty.send "hello first turn"
    tty.expect "hello first turn"
    tty.send "\n"
    tty.expect "UNIQUE-FIRST-ANSWER-MARKER visible forever"
    tty.expect "❯"
    tty.drain(300)
    # Must remain visible after the turn settles (token bar now present).
    tty.expectRowAppearsOnce("● UNIQUE-FIRST-ANSWER-MARKER visible forever")
    tty.expectRowAppearsOnce("❯ hello first turn")
    # No multi-blank-run from over-erase / under-count gap math.
    let rows = tty.frames[^1].rows
    var maxRun = 0
    var cur = 0
    for r in rows:
      if r.strip.len == 0:
        inc cur
        if cur > maxRun: maxRun = cur
      else:
        cur = 0
    doAssert maxRun <= 1, "extra blank rows after first turn: maxRun=" &
      $maxRun & "\n" & tty.dumpFramesAround("UNIQUE-FIRST-ANSWER-MARKER")
