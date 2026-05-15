import std/[json, os, osproc, strutils, unittest]
import tty_expect

const VisualOutputRoot = "tests" / "output" / "tty"

proc ensureStubBinary(): string =
  let pid = $getCurrentProcessId()
  result = getTempDir() / ("3code_tty_stub_" & pid)
  if fileExists(result):
    return
  let cacheDir = getTempDir() / ("3code_tty_stub_cache_" & pid)
  createDir(cacheDir)
  let cmd = "nim c -d:ssl -d:providerStub --threads:on --path:src --nimcache:" &
    cacheDir.quoteShell & " -o:" & result.quoteShell & " src/threecode.nim"
  let (outp, code) = execCmdEx(cmd)
  doAssert code == 0, outp

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
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc toolCall(id, name: string, args: JsonNode): JsonNode =
  %*{
    "id": id,
    "type": "function",
    "function": {
      "name": name,
      "arguments": $args
    }
  }

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc stubEnv(root: string): seq[EnvVar] =
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
  ]

proc startStub(root: string; args: openArray[string] = ["-x", "-i"]): TtySession =
  newTtySession(ensureStubBinary(), args = args, cwd = root / "run",
                env = stubEnv(root))

proc countOccurrences(haystack, needle: string): int =
  var pos = 0
  while true:
    let found = haystack.find(needle, pos)
    if found < 0:
      break
    inc result
    pos = found + needle.len

proc isTokenBar(row: string): bool =
  ("○" in row or "●" in row) and ("↑" in row or "↓" in row or "↻" in row)

proc isKnownTranscriptBelowFooter(row: string): bool =
  row.contains("Streaming markdown") or
    row.contains("bash-line-") or
    row.contains("second-tool") or
    row.contains("Buffered prompt answered") or
    row.startsWith("● ") or
    row.startsWith("$ ") or
    row.startsWith("r ") or
    row.startsWith("w ") or
    row.startsWith("p ")

proc assertFatPromptFrames(tty: TtySession) =
  for frame in tty.frames:
    var tokenRows: seq[int]
    var liveTokenRows: seq[int]
    var promptRows: seq[int]
    for i, row in frame.rows:
      if row.isTokenBar:
        tokenRows.add i
      if row.startsWith("❯"):
        promptRows.add i
    for rowIdx in tokenRows:
      if rowIdx + 1 < frame.rows.len and frame.rows[rowIdx + 1].startsWith("❯"):
        liveTokenRows.add rowIdx

    if liveTokenRows.len > 0:
      let liveToken = liveTokenRows[^1]
      doAssert liveToken + 1 < frame.rows.len,
        "live token bar has no reserved editor row below it:\n" &
          frame.rows.join("\n")
      doAssert frame.rows[liveToken + 1].startsWith("❯"),
        "editor prompt is not directly below live token bar:\n" &
          frame.rows.join("\n")
      for rowIdx in liveToken + 1 ..< frame.rows.len:
        doAssert not frame.rows[rowIdx].isKnownTranscriptBelowFooter,
          "transcript/tool output appeared inside reserved editor area:\n" &
            frame.rows.join("\n")
      for rowIdx in 0 ..< liveToken:
        doAssert frame.rows[rowIdx].strip != "❯",
          "stale bare prompt row escaped into scrollback:\n" &
            frame.rows.join("\n")

    if liveTokenRows.len > 0:
      let footerTop = liveTokenRows[^1]
      var prevNonEmpty = -1
      for rowIdx in countdown(footerTop - 1, 0):
        if frame.rows[rowIdx].strip.len > 0:
          prevNonEmpty = rowIdx
          break
      if prevNonEmpty >= 0:
        doAssert footerTop - prevNonEmpty <= 3,
          "fat prompt drifted away from scrollback content:\n" &
            frame.rows.join("\n")

    for j in 1 ..< liveTokenRows.len:
      doAssert liveTokenRows[j] != liveTokenRows[j - 1] + 1,
        "adjacent live token bars in frame:\n" & frame.rows.join("\n")
    doAssert frame.rows.join("\n").countOccurrences("bash-line-9") <= 1,
      "duplicated bash output in one frame:\n" & frame.rows.join("\n")
    doAssert frame.rows.join("\n").countOccurrences("\n  second-tool") <= 1,
      "duplicated bash output in one frame:\n" & frame.rows.join("\n")

suite "terminal visual contract":
  test "fat prompt remains stable through streaming, tools, and buffered input":
    let root = newFixture("visual")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "reasoning_content": "thinking about visible ticker",
        "content": "Streaming **markdown** before tools.",
        "tool_calls": [
          toolCall("call_bash1", "bash", %*{
            "command": "for i in 1 2 3 4 5 6 7 8 9; do echo bash-line-$i; sleep 0.05; done"}),
          toolCall("call_bash2", "bash", %*{
            "command": "printf second-tool"})
        ]
      },
      {
        "role": "assistant",
        "content": "Buffered prompt answered.",
        "usage": {
          "promptTokens": 120,
          "completionTokens": 8,
          "totalTokens": 128,
          "cachedTokens": 32
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "exercise visual contract\n"
    tty.expectInHistory "Streaming markdown before tools."
    tty.send "buffered"
    tty.send "\x1b[27;2;13~"
    tty.send "prompt\n"
    tty.expectInHistory "❯ buffered"
    tty.expectInHistory "  prompt"
    tty.expectInHistory "bash-line-9"
    tty.expectInHistory "second-tool"
    tty.expectInHistory "Buffered prompt answered."
    tty.expectTokenBar(["○", "↑88", "↻32", "↓8"])
    tty.send ":q\n"
    tty.expectExit 0

    tty.assertFatPromptFrames()
