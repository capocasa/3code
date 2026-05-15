import std/[json, os, osproc, strutils, unittest]
import tty_expect

const VisualOutputRoot = "tests" / "output" / "tty"

proc ensureStubBinary(): string =
  let pid = $getCurrentProcessId()
  result = getTempDir() / ("3code_tty_stub_" & pid)
  if fileExists(result):
    removeFile(result)
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

proc assertHistoryNavigationDuringLiveBar(tty: TtySession) =
  var sawHistoryRecall = false
  var sawDraftRestore = false
  for frame in tty.frames:
    let liveRows = frame.liveTokenRows()
    if liveRows.len == 0:
      continue
    let promptRow = liveRows[^1] + 1
    if promptRow >= frame.rows.len:
      continue
    if frame.rows[promptRow].startsWith("❯ start live history"):
      sawHistoryRecall = true
    if sawHistoryRecall and frame.rows[promptRow].startsWith("❯ draft live"):
      sawDraftRestore = true
  doAssert sawHistoryRecall,
    "visual test never captured active-turn Up history recall"
  doAssert sawDraftRestore,
    "visual test never captured active-turn Down draft restore"

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

proc assertReceiptTouchesAssistantResponse(tty: TtySession;
                                           responseMarker: string) =
  for frame in tty.frames:
    for rowIdx in 0 ..< frame.rows.len - 1:
      if frame.rows[rowIdx].isTokenBar and
          frame.rows[rowIdx + 1].startsWith("● ") and
          responseMarker in frame.rows[rowIdx + 1]:
        return
  doAssert false,
    "no frame showed token receipt directly adjacent to assistant response: " &
      responseMarker

proc rowWith(frame: TtyFrame; marker: string): int =
  for rowIdx, row in frame.rows:
    if marker in row:
      return rowIdx
  -1

proc assertOneBlankBetween(tty: TtySession; upperMarker, lowerMarker: string) =
  var sawPair = false
  for frame in tty.frames:
    let upper = frame.rowWith(upperMarker)
    let lower = frame.rowWith(lowerMarker)
    if upper < 0 or lower < 0 or lower <= upper:
      continue
    sawPair = true
    doAssert lower - upper == 2 and frame.rows[upper + 1].strip.len == 0,
      "expected exactly one blank row between `" & upperMarker & "` and `" &
        lowerMarker & "`:\n" & frame.rows.join("\n")
  doAssert sawPair,
    "visual test never captured both `" & upperMarker & "` and `" &
      lowerMarker & "` in one frame"

proc assertNoBlankBetween(tty: TtySession; upperMarker, lowerMarker: string) =
  for frame in tty.frames:
    let upper = frame.rowWith(upperMarker)
    let lower = frame.rowWith(lowerMarker)
    if upper < 0 or lower < 0 or lower <= upper:
      continue
    doAssert lower - upper == 1,
      "expected no blank row between `" & upperMarker & "` and `" &
        lowerMarker & "`:\n" & frame.rows.join("\n")
    return
  doAssert false,
    "visual test never captured adjacent pair `" & upperMarker & "` and `" &
      lowerMarker & "`"

proc assertOrderedRows(tty: TtySession; markers: openArray[string]) =
  for frame in tty.frames:
    var next = 0
    for row in frame.rows:
      if next < markers.len and markers[next] in row:
        inc next
    if next == markers.len:
      return
  doAssert false,
    "visual test never captured ordered markers: " & markers.join(" -> ")

proc assertInitialPromptOnly(tty: TtySession) =
  for frame in tty.frames:
    let promptRow = frame.rowWith("❯")
    let helpRow = frame.rowWith("type a prompt.")
    if promptRow < 0 or helpRow < 0:
      continue
    if frame.rows[promptRow].startsWith("❯") and
        "exercise visual contract" notin frame.rows[promptRow]:
      for row in frame.rows:
        doAssert not row.isTokenBar,
          "initial first prompt should not show a token bar:\n" &
            frame.rows.join("\n")
      doAssert promptRow - helpRow == 2,
        "initial prompt should have one blank row after the help line:\n" &
          frame.rows.join("\n")
      return
  doAssert false, "visual test never captured prompt-only initial screen"

proc nearestPromptRow(frame: TtyFrame; rowIdx: int): int =
  for i in countdown(min(rowIdx, frame.rows.high), 0):
    if frame.rows[i].startsWith("❯ "):
      return i
    if frame.rows[i].strip.len > 0 and not frame.rows[i].startsWith("  "):
      return -1
  -1

proc assertLiveTypingKeepsTokenBar(tty: TtySession;
                                   promptMarkers: openArray[string]) =
  ## Reproduce the "typing while the token bar updates makes it blink" report:
  ## whenever the visible caret is inside one of the live editor prompts, the
  ## token bar must be present directly above the editor top in that same frame.
  var sawLiveTyping = false
  for frame in tty.frames:
    if frame.cursorHidden or frame.cursorRow < 0 or
        frame.cursorRow >= frame.rows.len:
      continue
    let cursorRow = frame.rows[frame.cursorRow]
    if not cursorRow.startsWith("❯ ") and not cursorRow.startsWith("  "):
      continue
    let promptRow = frame.nearestPromptRow(frame.cursorRow)
    if promptRow <= 0:
      continue
    var tracked = false
    for marker in promptMarkers:
      if marker in frame.rows[promptRow]:
        tracked = true
        break
    if not tracked:
      continue
    sawLiveTyping = true
    doAssert frame.rows[promptRow - 1].isTokenBar,
      "token bar blinked or separated while typing in live editor:\n" &
        frame.rows.join("\n")
  doAssert sawLiveTyping,
    "visual test never captured live typing with a token bar for markers: " &
      @promptMarkers.join(", ")

proc assertAutosendMarkerBehavior(tty: TtySession) =
  var sawMarker = false
  var sawMarkerRemoved = false
  var sawFinalWithoutMarker = false
  for frame in tty.frames:
    var hasPromptMarker = false
    var hasAnotherMarker = false
    for rowIdx, row in frame.rows:
      if "prompt" in row and "⧖" in row:
        hasPromptMarker = true
        sawMarker = true
        doAssert row.contains(" ⧖"),
          "autosend marker should be separated from text by one space:\n" &
            frame.rows.join("\n")
        doAssert rowIdx + 1 < frame.rows.len,
          "autosend marker should reserve a following editor row:\n" &
            frame.rows.join("\n")
        if not frame.cursorHidden:
          doAssert frame.cursorRow == rowIdx + 1,
            "autosend marker caret should sit on following editor row:\n" &
              frame.rows.join("\n")
      if "another" in row and "⧖" in row:
        hasAnotherMarker = true
    if "Buffered prompt answered." in frame.rows.join("\n"):
      doAssert not hasPromptMarker,
        "autosend marker remained after queued prompt was sent:\n" &
          frame.rows.join("\n")
      sawMarkerRemoved = true
    if "Sure is. Let me know when you have a real task." in frame.rows.join("\n"):
      doAssert not hasAnotherMarker,
        "autosend marker remained after final queued prompt was sent:\n" &
          frame.rows.join("\n")
      sawFinalWithoutMarker = true
  doAssert sawMarker, "visual test never captured autosend marker"
  doAssert sawMarkerRemoved, "visual test never captured autosend marker removal"
  doAssert sawFinalWithoutMarker,
    "visual test never captured final queued prompt after marker removal"

proc assertBashViewportBounded(tty: TtySession) =
  var sawCutoff = false
  for frame in tty.frames:
    var bashRows = 0
    for row in frame.rows:
      if "lines omitted" in row:
        sawCutoff = true
      if row.startsWith("  bash-line-"):
        inc bashRows
    doAssert bashRows <= 7,
      "live bash viewport showed more than the bottom seven output lines:\n" &
        frame.rows.join("\n")
  doAssert sawCutoff, "visual test never captured bash viewport cutoff hint"

proc assertNoPromptOnlyClearAfter(tty: TtySession; marker: string) =
  ## Once transcript content exists, no later visual frame should collapse to a
  ## nearly blank prompt/token-only screen. This catches the old random-clear /
  ## jump-to-bottom failure mode without pinning raw terminal bytes.
  var armed = false
  for frame in tty.frames:
    for row in frame.rows:
      if marker in row:
        armed = true
        break
    if not armed:
      continue
    var transcriptRows = 0
    var liveRows = 0
    for row in frame.rows:
      if row.startsWith("❯ ") or row.startsWith("● ") or
          row.startsWith("$ ") or row.startsWith("r ") or
          row.startsWith("w ") or row.startsWith("p "):
        inc transcriptRows
      elif row.isTokenBar:
        inc liveRows
    doAssert transcriptRows > 0 or liveRows == 0,
      "screen collapsed to prompt/token chrome after transcript appeared:\n" &
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
      },
      {
        "role": "assistant",
        "preStreamDelayMs": 900,
        "content": "yes it is",
        "usage": {
          "promptTokens": 16,
          "completionTokens": 36,
          "totalTokens": 52,
          "cachedTokens": 3200
        }
      },
      {
        "role": "assistant",
        "content": "Sure is. Let me know when you have a real task.",
        "usage": {
          "promptTokens": 31,
          "completionTokens": 31,
          "totalTokens": 62,
          "cachedTokens": 3200
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.assertInitialPromptOnly()
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
    tty.expectTokenBar(["○", "↑120", "↻32", "↓8"])
    tty.send "this is..."
    tty.send "\x1b[13;2u"
    tty.send "a test!!!\n"
    tty.expectTokenBar(["○"])
    tty.send "and"
    tty.send "\x1b[13;2u"
    tty.send "another\n"
    tty.expectInHistory "yes it is"
    tty.expectInHistory "Sure is. Let me know when you have a real task."
    tty.expectFrameSeries([
      """
...
● Streaming markdown before tools.

  ○0%  ↑100  ↓9  <elapsed>
❯ buffered
  prompt ⧖
...
""",
      """
...
$ for i in 1 2 3 4 5 6 7 8 9; do echo bash-line-$i; sleep 0.05; d…
  ... 2 lines omitted :show 1 for full
  bash-line-3
  bash-line-4
  bash-line-5
  bash-line-6
  bash-line-7
  bash-line-8
  bash-line-9

  ○0%  ↑100  ↓9  <elapsed>
❯ buffered
  prompt ⧖
...
""",
      """
...
❯ buffered
  prompt

● Buffered prompt answered.

  ○0%  ↑120  ↻32  ↓8  <elapsed>
❯ this is...
  a test!!!
""",
      """
...
❯ this is...
  a test!!!

● yes it is

  ○0%  ↑16  ↻3.2k  ↓36  <elapsed>

❯ and
  another

● Sure is. Let me know when you have a real task.

  ○0%  ↑31  ↻3.2k  ↓31  <elapsed>
...
"""
    ])
    tty.assertFatPromptFrames()
    tty.assertLiveTypingKeepsTokenBar(["❯ buffered", "❯ this is"])
    tty.assertAutosendMarkerBehavior()
    tty.assertBashViewportBounded()
    tty.assertNoPromptOnlyClearAfter("Streaming markdown before tools.")
    tty.assertOrderedRows([
      "❯ this is...",
      "  a test!!!",
      "● yes it is",
      "↻3.2k  ↓36",
      "❯ and",
      "  another",
      "● Sure is. Let me know when you have a real task.",
      "↻3.2k  ↓31"
    ])
    tty.assertOneBlankBetween("  a test!!!", "● yes it is")
    tty.assertOneBlankBetween("  another", "● Sure is.")
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

  test "history navigation works inside the live reserved editor":
    let root = newFixture("history_live")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "History seed done.",
        "usage": {
          "promptTokens": 30,
          "completionTokens": 4,
          "totalTokens": 34,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "preStreamDelayMs": 900,
        "content": "Live history wait done.",
        "usage": {
          "promptTokens": 64,
          "completionTokens": 5,
          "totalTokens": 69,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "History buffered answered.",
        "usage": {
          "promptTokens": 72,
          "completionTokens": 5,
          "totalTokens": 77,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "history seed\n"
    tty.expectInHistory "History seed done."
    tty.send "start live history\n"
    tty.expectTokenBar(["○"])
    tty.send "draft live"
    tty.drain(80)
    tty.send "\x1b[A"
    tty.drain(80)
    tty.send "\x1b[B"
    tty.drain(80)
    tty.send " ok\n"
    tty.expectInHistory "Live history wait done."
    tty.expectInHistory "❯ draft live ok"
    tty.expectInHistory "History buffered answered."
    tty.expectTokenBar(["○", "↑72", "↓5"])
    tty.assertFatPromptFrames()
    tty.assertHistoryNavigationDuringLiveBar()
    tty.send ":q\n"
    tty.expectExit 0

  test "tool follow-up response touches its token receipt":
    let root = newFixture("receipt_followup")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Running directory listing.",
        "tool_calls": [
          toolCall("call_ls", "bash", %*{"command": "printf 'listed-file\\n'"})
        ],
        "usage": {
          "promptTokens": 90,
          "completionTokens": 7,
          "totalTokens": 97,
          "cachedTokens": 16
        }
      },
      {
        "role": "assistant",
        "content": "Follow-up answer after tool.",
        "usage": {
          "promptTokens": 110,
          "completionTokens": 6,
          "totalTokens": 116,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "run tool followup\n"
    tty.expectInHistory "listed-file"
    tty.expectInHistory "Follow-up answer after tool."
    tty.assertFatPromptFrames()
    tty.assertOneBlankBetween("❯ run tool followup",
                              "● Running directory listing.")
    tty.assertOneBlankBetween("  listed-file", "↑90")
    tty.assertReceiptTouchesAssistantResponse("Follow-up answer after tool.")
    tty.assertNoBlankBetween("↑90", "● Follow-up answer after tool.")
    tty.assertOneBlankBetween("● Follow-up answer after tool.", "↑110")
    tty.send ":q\n"
    tty.expectExit 0
