## Regression: the rebreak window painted the committed transcript tail
## newest-first after a width change, so the turn's final answer landed at
## the top of the re-rendered tail, above the older items it answers.
## Two turns commit two answer items; the resize must keep them in
## conversation order (older above, newer below).
import std/[json, os, strutils, unittest]
import tty_expect, stub_helpers

const VisualOutputRoot = "tests/testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
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

proc writeStubResponses(root: string; responses: JsonNode) =
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

proc startStub(root: string; cols = DefaultTtyCols; rows = DefaultTtyRows): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                cols = cols, rows = rows)

proc stubReply(content: string): JsonNode =
  %*{
    "content": content,
    "contentChunks": [content],
    "usage": {
      "promptTokens": 20, "completionTokens": 5,
      "totalTokens": 25, "cachedTokens": 0
    }
  }

suite "rebreak window across items":
  test "resize keeps conversation order across two answers":
    const First = "able bravo charlie delta echo foxtrot golf hotel"
    const Second = "india juliet kilo lima mike november oscar papa"
    let root = newFixture("rebreak_item_order")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[stubReply(First), stubReply(Second)])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "one\n"
    tty.expectInHistory "able"
    tty.drain(400)
    tty.send "two\n"
    tty.expectInHistory "oscar"
    tty.drain(400)

    for w in [100, 60, 44]:
      tty.resize(w, 24)
      tty.drain(400)
      let screen = tty.screenText()
      let first = screen.find("able")
      let second = screen.find("oscar")
      if first < 0 or second < 0:
        doAssert false, "width " & $w & ": an answer vanished from the " &
          "screen after rebreak.\n--- screen ---\n" & screen &
          tty.dumpFramesAround("❯")
      if first > second:
        doAssert false, "width " & $w & ": answers paint newest-first " &
          "after rebreak (final answer above the item it follows).\n" &
          "--- screen ---\n" & screen & tty.dumpFramesAround("❯")

    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 5000)
