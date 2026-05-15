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

proc liveTokenRows(frame: TtyFrame): seq[int] =
  for i, row in frame.rows:
    if row.isTokenBar and i + 1 < frame.rows.len and frame.rows[i + 1].startsWith("❯"):
      result.add i

proc liveEditorRows(frame: TtyFrame; liveToken: int): int =
  var lastOwned = liveToken
  for rowIdx in liveToken + 1 ..< frame.rows.len:
    if frame.rows[rowIdx].strip.len > 0:
      lastOwned = rowIdx
  max(1, lastOwned - liveToken)

proc isKnownTranscriptBelowFooter(row: string): bool =
  row.contains("Streaming markdown") or
    row.contains("bash-line-") or
    row.contains("second-tool") or
    row.contains("Buffered prompt answered") or
    row.contains("Short response done") or
    row.contains("Height change done") or
    row.contains("Ticker disabled response") or
    row.startsWith("● ") or
    row.startsWith("$ ") or
    row.startsWith("r ") or
    row.startsWith("w ") or
    row.startsWith("p ")

proc assertFatPromptFrames(tty: TtySession) =
  ## Assert the full fat-prompt visual contract over every captured frame.
  for frame in tty.frames:
    var tokenRows: seq[int]
    let liveRows = frame.liveTokenRows()
    var promptRows: seq[int]
    for i, row in frame.rows:
      if row.isTokenBar:
        tokenRows.add i
      if row.startsWith("❯"):
        promptRows.add i

    if liveRows.len > 0:
      let liveToken = liveRows[^1]
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

      if not frame.cursorHidden:
        doAssert frame.cursorRow > liveToken,
          "visible caret escaped above the editor area:\n" &
            frame.rows.join("\n")
        doAssert frame.cursorRow < frame.rows.len,
          "visible caret row is outside the terminal frame:\n" &
            frame.rows.join("\n")

    if liveRows.len > 0:
      let footerTop = liveRows[^1]
      var prevNonEmpty = -1
      for rowIdx in countdown(footerTop - 1, 0):
        if frame.rows[rowIdx].strip.len > 0:
          prevNonEmpty = rowIdx
          break
      if prevNonEmpty >= 0:
        doAssert footerTop - prevNonEmpty == 2,
          "fat prompt must have exactly one blank row below scrollback content:\n" &
            frame.rows.join("\n")

    for j in 1 ..< liveRows.len:
      doAssert liveRows[j] != liveRows[j - 1] + 1,
        "adjacent live token bars in frame:\n" & frame.rows.join("\n")
    doAssert frame.rows.join("\n").countOccurrences("bash-line-9") <= 1,
      "duplicated bash output in one frame:\n" & frame.rows.join("\n")
    doAssert frame.rows.join("\n").countOccurrences("\n  second-tool") <= 1,
      "duplicated bash output in one frame:\n" & frame.rows.join("\n")

proc assertEditorHeightChangedDuringLiveBar(tty: TtySession) =
  var sawMulti = false
  var sawSingleAfterMulti = false
  for frame in tty.frames:
    let liveRows = frame.liveTokenRows()
    if liveRows.len == 0:
      continue
    let rows = frame.liveEditorRows(liveRows[^1])
    if rows > 1:
      sawMulti = true
    elif sawMulti and rows == 1:
      sawSingleAfterMulti = true
  doAssert sawMulti, "visual test never captured a multiline/wrapped editor"
  doAssert sawSingleAfterMulti,
    "visual test never captured the editor shrinking after it grew"

proc assertNoCacheLiveReceipt(tty: TtySession; marker: string) =
  var sawMarker = false
  for frame in tty.frames:
    for row in frame.rows:
      if marker in row:
        sawMarker = true
    if sawMarker:
      for row in frame.rows:
        if row.isTokenBar and "❯" notin row:
          doAssert "↻" notin row,
            "cache slot shown for a no-cache usage receipt:\n" &
              frame.rows.join("\n")

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
    tty.assertFatPromptFrames()
    tty.send ":q\n"
    tty.expectExit 0

  test "short response keeps prompt attached to scrollback":
    let root = newFixture("short")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Short response done.",
        "usage": {
          "promptTokens": 44,
          "completionTokens": 4,
          "totalTokens": 48,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "short gap check\n"
    tty.expectInHistory "Short response done."
    tty.expectTokenBar(["○", "↑44", "↓4"])
    tty.assertFatPromptFrames()
    tty.assertNoCacheLiveReceipt("Short response done.")
    tty.send ":q\n"
    tty.expectExit 0

  test "live editor reserved height grows and shrinks during api wait":
    let root = newFixture("height")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "preStreamDelayMs": 900,
        "content": "Height change done.",
        "usage": {
          "promptTokens": 80,
          "completionTokens": 5,
          "totalTokens": 85,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Shrink prompt answered.",
        "usage": {
          "promptTokens": 92,
          "completionTokens": 5,
          "totalTokens": 97,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start height change\n"
    tty.expectTokenBar(["○"])
    tty.send repeat("wrap-", 35)
    tty.drain(120)
    tty.send "\x15"
    tty.drain(80)
    tty.send "short buffered\n"
    tty.expectInHistory "Height change done."
    tty.expectInHistory "❯ short buffered"
    tty.expectInHistory "Shrink prompt answered."
    tty.assertFatPromptFrames()
    tty.assertEditorHeightChangedDuringLiveBar()
    tty.send ":q\n"
    tty.expectExit 0

  test "thinking off hides ticker and no-cache bar omits cache slot":
    let root = newFixture("ticker_off")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "reasoning_content": "this reasoning must not appear as a ticker",
        "content": "Ticker disabled response.",
        "usage": {
          "promptTokens": 70,
          "completionTokens": 6,
          "totalTokens": 76,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send ":think off\n"
    tty.expectInHistory "thinking ticker off"
    tty.send "ticker off check\n"
    tty.expectInHistory "Ticker disabled response."
    tty.expectTokenBar(["○", "↑70", "↓6"])
    tty.assertFatPromptFrames()
    tty.expectNoReasoningTickerRows()
    tty.assertNoCacheLiveReceipt("Ticker disabled response.")
    tty.send ":q\n"
    tty.expectExit 0
