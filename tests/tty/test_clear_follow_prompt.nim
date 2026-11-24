## `:clear <text>` arms a follow prompt: the clear commits its divider
## first and the text continues as an ordinary `❯` prompt on the fresh
## context. The typed `:clear` line itself is never echoed — the ❯ item
## the text becomes is the announcement (same discipline as a mode-verb
## arm write).
import std/[json, os, strutils, times, unittest]
import tty_expect, stub_helpers


proc newFixture(name: string): string =
  result = getTempDir() / "3code_tty_fixture" / (name & "_" & $getCurrentProcessId())
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

proc stubReply(content: string): JsonNode =
  %*{
    "content": content,
    "contentChunks": [content],
    "usage": {
      "promptTokens": 20, "completionTokens": 5,
      "totalTokens": 25, "cachedTokens": 0
    }
  }

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "test.stub_responses", val: responsesPath),
  ]

proc startStub(root: string; cols = DefaultTtyCols; rows = DefaultTtyRows): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                cols = cols, rows = rows)

suite "clear follow prompt":
  test ":clear <text> clears, then runs the text as an ordinary prompt":
    let root = newFixture("clear_follow_prompt")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[stubReply("fresh answer")])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send ":clear and summarize the repo"
    tty.send "\n"
    # The clear's divider commits first, the follow prompt echoes as an
    # ordinary ❯ item below it, and the turn answers on the fresh context.
    tty.expectInHistory "══════════"
    tty.expectInHistory "❯ and summarize the repo"
    tty.expectInHistory "fresh answer"
    tty.drain(400)
    # The typed command line never lands in the committed transcript: the
    # rotated fresh session's .3log carries the follow prompt as the user
    # message, no `:clear` line (frames still hold the transient editor
    # echo of the typing, so the check reads the .3log only).
    var log = ""
    let logDeadline = epochTime() + 10.0
    while epochTime() < logDeadline:
      for p in walkFiles(root / "data" / "3code" / "sessions" / "*.3log"):
        let c = readFile(p)
        if "fresh answer" in c: log = c
      if log != "": break
      tty.drain(100)
    check log != ""
    check "and summarize the repo" in log
    check ":clear" notin log
    # Order on the live screen: divider above the ❯ prompt item.
    let screen = tty.screenText()
    let divider = screen.find("══════════")
    let prompt = screen.find("❯ and summarize")
    doAssert divider >= 0 and prompt > divider,
      "expected the clear divider above the follow prompt item\n" &
      "--- screen ---\n" & screen & tty.dumpFramesAround("❯")

    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 5000)

  test "mid-turn :clear <text> queues, then drains clear + prompt":
    let root = newFixture("clear_follow_queued")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {"role": "assistant", "preStreamDelayMs": 1500,
       "content": "slow reply", "contentChunks": ["slow reply"],
       "usage": {"promptTokens": 10, "completionTokens": 2,
                 "totalTokens": 12, "cachedTokens": 0}},
      stubReply("queued answer")])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start a turn\n"
    tty.drain(100)
    # Submit the arm mid-turn: it queues behind the running turn.
    tty.send ":clear and summarize"
    tty.send "\n"
    tty.expectInHistory "slow reply"
    tty.drain(200)
    # The drain runs the clear (echo dropped, receipt committed), then the
    # follow prompt as an ordinary ❯ item on the fresh context.
    tty.expectInHistory "══════════"
    tty.expectInHistory "❯ and summarize"
    tty.expectInHistory "queued answer"
    tty.drain(400)
    var log = ""
    let logDeadline = epochTime() + 10.0
    while epochTime() < logDeadline:
      for p in walkFiles(root / "data" / "3code" / "sessions" / "*.3log"):
        let c = readFile(p)
        if "queued answer" in c: log = c
      if log != "": break
      tty.drain(100)
    check log != ""
    check "and summarize" in log

    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 5000)

  test "bare :clear still echoes the typed command line":
    let root = newFixture("clear_bare_echo")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send ":clear\n"
    tty.expectInHistory "❯ :clear"
    tty.expectInHistory "══════════"

    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 5000)
