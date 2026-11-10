import std/[os, strutils, times, unittest]
import threecode/display
import threecode/types
import threecode/util
import threecode/actions

suite "display: assistant rendering":
  test "assistant reply text is bright white across lines":
    let rendered = renderAssistantContentBytes("first\nsecond")
    check rendered.startsWith(AssistantTextStyle & "● " & Reset &
      AssistantTextStyle & "first")
    check AssistantTextStyle & "  second" in rendered
    check AssistantTextStyle & "  second" & Reset in rendered

  test "assistant style resumes after inline markdown resets":
    let rendered = renderAssistantContentBytes("before **bold** after")
    check "\x1b[22m" & AssistantTextStyle & " after" in rendered

import std/[json]
import threecode/[goal, session, types]

suite "display: printSessionList cap":
  # `printSessionList` is the single shared view for `-l` and `:sessions`,
  # so capping it covers both surfaces. Seeds sessions in an isolated
  # XDG_DATA_HOME so the test never touches real state, then captures
  # stdout to assert the cap and truncation hint.
  var savedXdg = ""
  var tmpRoot = ""
  var dir = ""
  var cwd = "/tmp/3code-test-cap-dir"

  setup:
    savedXdg = getEnv("XDG_DATA_HOME")
    tmpRoot = getTempDir() / ("3code-test-cap-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmpRoot)
    putEnv("XDG_DATA_HOME", tmpRoot)
    dir = sessionDir()
    createDir(dir)

  teardown:
    if savedXdg.len > 0: putEnv("XDG_DATA_HOME", savedXdg)
    else: delEnv("XDG_DATA_HOME")
    if dirExists(tmpRoot): removeDir(tmpRoot)

  proc seedSession(stamp, body: string) =
    # Minimal valid .3log: a session header (so previewSession picks up the
    # cwd) + one user line. All sessions share `cwd` so
    # listSessionPathsForCwd returns every one.
    let sess = Session(created: stamp, profileName: "stub", cwd: cwd)
    let msgs = %*[{"role": "system", "content": "sys"},
                  {"role": "user", "content": body}]
    writeFile(dir / (stamp & SessionExt), renderSession(sess, msgs))
    # Mirror saveSession: index the new file under its cwd so
    # listSessionPathsForCwd (which reads the index, not the dir) finds it.
    appendSessionIndex(cwd, stamp)

  when not defined(windows):
    proc captureList(paths: seq[string]): string =
      # Mirror the `captureStdout` helper in test_streaming_view.nim: swap
      # the `stdout` var for a temp file around the call.
      let outPath = tmpRoot / "list_out.txt"
      let saved = stdout
      let f = open(outPath, fmWrite)
      stdout = f
      try:
        printSessionList(paths, "", showCwd = false)
      finally:
        stdout.flushFile
        stdout = saved
        close(f)
      result = readFile(outPath).strip(leading = false)

  when not defined(windows):
    test "caps at SessionListCap and shows truncation hint":
      for i in 0 ..< 25:
        seedSession("2026010" & (if i < 10: "0" & $i else: $i) & "T120000",
                    "session number " & $i)
      let paths = listSessionPathsForCwd(cwd)
      check paths.len == 25
      let listing = captureList(paths)
      # 25 sessions (indices 0..24), newest-first → the 20 shown are
      # indices 24..5. Index 5 is the last shown; index 4 is the first cut.
      check "202601024T120000" in listing  # newest
      check "202601005T120000" in listing  # 20th shown (last)
      check "202601004T120000" notin listing  # 21st (capped out)
      check "202601000T120000" notin listing  # oldest
      check "20 of 25" in listing           # truncation hint
      check "more in" in listing

    test "no hint when under the cap":
      for i in 0 ..< 3:
        seedSession("2026020" & $i & "T120000", "session " & $i)
      let paths = listSessionPathsForCwd(cwd)
      check paths.len == 3
      let listing = captureList(paths)
      check "of 3" notin listing  # no truncation hint

    test "private sessions are marked in the listing":
      seedSession("20260301T120000", "plain one")
      let privDir = privateSessionDir()
      createDir(privDir)
      let sess = Session(created: "20260302T120000", profileName: "stub",
        cwd: cwd)
      writeFile(privDir / "20260302T120000.3log", renderSession(sess,
        %*[{"role": "user", "content": "private one"}]))
      appendSessionIndex(cwd, "20260302T120000")
      let listing = captureList(listSessionPathsForCwd(cwd))
      var plainLine = ""
      var privLine = ""
      for ln in listing.splitLines():
        if "20260301T120000" in ln: plainLine = ln
        if "20260302T120000" in ln: privLine = ln
      check plainLine.len > 0 and "private" notin plainLine
      check privLine.len > 0 and "private" in privLine

import threecode/[transcript, types]

suite "display: tool transcript body strips boundary blanks":
  # A tool item must not bring its own newlines into scrollback. Web
  # search/fetch output (and any other head/tail-truncated kind) can arrive
  # with leading or trailing blank lines; the formatter strips both ends so
  # only the single transcript separator owns the inter-item blank row.
  test "web_search strips leading and trailing blank lines":
    let act = Action(kind: akWebSearch, body: "query")
    let res = "\n\n1. Hit one\n\n2. Hit two\n\n\n"
    let bytes = toolTranscriptBytes(act, res, code = 0, idx = 1)
    check "1. Hit one" in bytes
    check "2. Hit two" in bytes
    # No blank-wrapped row should appear before the first real content line.
    let firstContent = bytes.find("1. Hit one")
    check firstContent > 0
    let bannerEnd = bytes.find("\x1b[0m\r\n") + "\x1b[0m\r\n".len
    check bannerEnd > 0
    let between = bytes[bannerEnd ..< firstContent]
    check between.strip().len > 0

  test "web_fetch strips leading blank lines":
    let act = Action(kind: akWebFetch, body: "https://example.test/x")
    let res = "\n\n\nPage body\nMore body\n\n"
    let bytes = toolTranscriptBytes(act, res, code = 0, idx = 1)
    check "Page body" in bytes
    check "More body" in bytes
    let firstContent = bytes.find("Page body")
    let bannerEnd = bytes.find("\x1b[0m\r\n") + "\x1b[0m\r\n".len
    let between = bytes[bannerEnd ..< firstContent]
    check between.strip().len > 0

suite "display: plan glyph rendering is unified":
  # The plan tool must render glyphs in every path (live transcript,
  # replay, :show) so a plan looks identical whether it just ran or was
  # scrolled back to. The shared renderer is `planResultBytes`; the live
  # transcript routes through it.
  test "planResultBytes emits one glyph per item, never verbal status":
    let plan = @[
      PlanItem(text: "pending item", status: "pending"),
      PlanItem(text: "ongoing item", status: "in_progress"),
      PlanItem(text: "done item", status: "completed"),
    ]
    let bytes = planResultBytes(plan)
    check "○ pending item" in bytes
    check "~ ongoing item" in bytes
    check "✓ done item" in bytes
    check "pending: " notin bytes
    check "in_progress: " notin bytes
    check "completed: " notin bytes

  test "live transcript renders plan glyphs, not the verbal res string":
    let act = Action(kind: akPlan,
      plan: @[PlanItem(text: "step one", status: "completed")])
    let res = "completed: step one"  # model-facing verbal result
    let bytes = toolTranscriptBytes(act, res, code = 0, idx = 1)
    check "✓ step one" in bytes
    check "completed: step one" notin bytes
    check "(1 item" notin bytes  # banner title dropped

when not defined(windows):
  suite "display: replay routes through the shared transcript formatters":
    # replaySessionTail must render each item through the SAME formatters
    # the live path uses (formatItem / toolItem / attachReceipt), so a
    # resumed session looks byte-identical to how it looked live, with one
    # blank row between items and no trailing blank after the last. Capture
    # stdout (temp-file swap) and compare to the live byte builders.
    proc captureReplay(messages: JsonNode; toolLog: seq[ToolRecord];
                       window = 0; family = "glm"): string =
      let outPath = getTempDir() / ("tc_replay_" & $getCurrentProcessId())
      let saved = stdout
      let f = open(outPath, fmWrite)
      stdout = f
      try:
        discard replaySessionTail(messages, toolLog, window, family)
      finally:
        stdout.flushFile
        stdout = saved
        close(f)
      result = readFile(outPath)
      removeFile(outPath)

    test "bash tool in replay matches the live byte output":
      let banner = "echo hi"
      let output = "hi\n"
      let toolLog = @[ToolRecord(banner: banner, output: output,
        code: 0, kind: akBash)]
      let msgs = %*[
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "1", "type": "function",
           "function": {"name": "bash",
             "arguments": "{\"command\": \"echo hi\"}"}}]},
        {"role": "tool", "tool_call_id": "1", "content": output}]
      let rendered = captureReplay(msgs, toolLog)
      var live = toolTranscriptBytes(banner, akBash, output, 0, 1)
      live.trimTranscriptTail()
      check live & "\n" in rendered
      check "$ echo hi" in rendered   # banner icon + command
      check "  hi" in rendered        # body line

    test "plan in replay matches the live planTranscriptBytes output":
      let plan = @[PlanItem(text: "step one", status: "completed"),
                   PlanItem(text: "step two", status: "pending")]
      let toolLog = @[ToolRecord(banner: "update plan", output: "",
        code: 0, kind: akPlan, plan: plan)]
      let msgs = %*[
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "1", "type": "function",
           "function": {"name": "update_plan",
             "arguments": "{\"items\": []}"}}]},
        {"role": "tool", "tool_call_id": "1", "content": ""}]
      let rendered = captureReplay(msgs, toolLog)
      let act = Action(kind: akPlan, plan: plan)
      var live = toolTranscriptBytes(act, "", 0, 1)
      live.trimTranscriptTail()
      check live & "\n" in rendered
      check "≡ ──────────" in rendered   # plan header matches live
      check "✓ step one" in rendered
      check "○ step two" in rendered
      check "completed: " notin rendered

    test "replay matches formatItem blocks with live spacing":
      # The exact replay byte stream must equal the live item blocks
      # joined by one blank row, with no trailing blank after the last
      # item. The first item carries the same one-blank leading separator
      # a live commit writes, so a resumed screen starts with the same
      # hint/blank/echo shape a fresh session does. Assemble the expected
      # bytes from the shared formatters so any divergence between live
      # and replay fails here. The turn's receipt caps the LAST TOOL (the
      # live `deferredReceipt` contract), not the prose above it.
      let output = "hi\n"
      let toolLog = @[ToolRecord(banner: "echo hi", output: output,
        code: 0, kind: akBash)]
      let msgs = %*[
        {"role": "user", "content": "hi there"},
        {"role": "assistant", "content": "On it.",
         "usage": {"promptTokens": 100, "completionTokens": 5,
                   "totalTokens": 105, "cachedTokens": 0},
         "tool_calls": [{"id": "1", "type": "function",
           "function": {"name": "bash",
             "arguments": "{\"command\": \"echo hi\"}"}}]},
        {"role": "tool", "tool_call_id": "1", "content": output},
        {"role": "assistant", "content": "Done.",
         "usage": {"promptTokens": 110, "completionTokens": 5,
                   "totalTokens": 115, "cachedTokens": 0}}]
      let rendered = captureReplay(msgs, toolLog, window = 1000)
      let prose1 = formatItem(assistantItem("On it."))
      let receipt = receiptBytes(tokenLineLabel(
        Usage(promptTokens: 100, completionTokens: 5,
              totalTokens: 105), 1000))
      var toolBytes = toolTranscriptBytes("echo hi", akBash, output, 0, 1)
      toolBytes.trimTranscriptTail()
      toolBytes.attachReceipt(receipt, true)
      let expected =
        "\n" &
        formatItem(userPromptItem("hi there")) & "\n" &
        "\n" & prose1 & "\n" &
        "\n" & toolBytes & "\n" &
        "\n" & formatItem(assistantItem("Done.")) & "\n"
      check rendered == expected

    test "web_search replay matches the live toolItem bytes":
      # The replay path must route a web tool through the same formatter
      # the live path uses (toolItem/toolTranscriptBytes): a banner ending
      # directly followed by the body, no extra row after the icon.
      let output = "1. Hit one\n2. Hit two\n"
      let toolLog = @[ToolRecord(banner: "nim macros", output: output,
        code: 0, kind: akWebSearch)]
      let msgs = %*[
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "1", "type": "function",
           "function": {"name": "web_search",
             "arguments": "{\"query\": \"nim macros\"}"}}]},
        {"role": "tool", "tool_call_id": "1", "content": output}]
      let rendered = captureReplay(msgs, toolLog)
      let act = Action(kind: akWebSearch, body: "nim macros")
      var live = formatItem(toolItem(act, output, 0, 1))
      live.trimTranscriptTail()
      check live & "\n" in rendered

    test "saved empty reply replays as the grey fallback, not as prose":
      # A tool-less empty reply is persisted as the marker text
      # (`EmptyReplyMsg`). Replay must map it back to the same grey
      # bullet-less fallback the live path paints, never to a `●` bullet
      # followed by the marker as white prose.
      let msgs = %*[
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": EmptyReplyMsg,
         "usage": {"promptTokens": 50, "completionTokens": 0,
                   "totalTokens": 50, "cachedTokens": 0}}]
      let rendered = captureReplay(msgs, @[], window = 1000)
      check GreyFg & EmptyReplyMsg & Reset in rendered
      check "● " notin rendered

    test "saved empty reply with finish_reason replays the explanation":
      # The live retry loop paints `empty reply: <reason>. ...`; a resumed
      # replay must show the same explanation (from the persisted
      # `finish_reason`) instead of the bare fallback.
      let msgs = %*[
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": EmptyReplyMsg,
         "finish_reason": "length",
         "usage": {"promptTokens": 50, "completionTokens": 0,
                   "totalTokens": 50, "cachedTokens": 0}}]
      let rendered = captureReplay(msgs, @[], window = 1000)
      check GreyFg & EmptyReplyMsg & Reset in rendered
      check "empty reply: length" in rendered
      check "● " notin rendered

    test "replay suppresses the empty-reply item when tools followed":
      # Live renders nothing for an empty reply paired with tool calls
      # (the empty-reply fallback is only for tool-less replies), so the
      # replay must skip that item too instead of printing the grey
      # "empty reply" line between tool batches.
      let output = "hi\n"
      let toolLog = @[ToolRecord(banner: "echo hi", output: output,
        code: 0, kind: akBash)]
      let msgs = %*[
        {"role": "assistant", "content": "",
         "usage": {"promptTokens": 50, "completionTokens": 0,
                   "totalTokens": 50, "cachedTokens": 0},
         "tool_calls": [{"id": "1", "type": "function",
           "function": {"name": "bash",
             "arguments": "{\"command\": \"echo hi\"}"}}]},
        {"role": "tool", "tool_call_id": "1", "content": output},
        {"role": "assistant", "content": "Done.",
         "usage": {"promptTokens": 60, "completionTokens": 5,
                   "totalTokens": 65, "cachedTokens": 0}}]
      let rendered = captureReplay(msgs, toolLog, window = 1000)
      check "empty reply" notin rendered
      check "$ echo hi" in rendered
      check "Done." in rendered

    proc captureShow(arg: string; toolLog: seq[ToolRecord]): string =
      let outPath = getTempDir() / ("tc_show_" & $getCurrentProcessId())
      let saved = stdout
      let f = open(outPath, fmWrite)
      stdout = f
      try:
        showTool(arg, toolLog)
      finally:
        stdout.flushFile
        stdout = saved
        close(f)
      result = readFile(outPath)
      removeFile(outPath)

    test "showTool body matches fullToolResultBytes for multi-line bash":
      # :show keeps its own `── T{n}` header but the BODY must come from
      # the shared untruncated builder; for output under the compaction
      # threshold that rendering is identical to the live compact one.
      let output = "line one\nline two\nline three\n"
      let toolLog = @[ToolRecord(banner: "echo long", output: output,
        code: 0, kind: akBash)]
      let rendered = captureShow("1", toolLog)
      check "── T1" in rendered
      check rendered.contains(fullToolResultBytes(akBash, output, 0))
      check rendered.contains(toolResultBytes(akBash, output, 0, 1))
      check "line one" in rendered
      check "line three" in rendered

    test "agent-sent steer replays as a » item, never a user echo":
      # The empty-reply steer is a harness-autosent user message (`agentSent`).
      # Replay must render the `»` agent-prompt item the live path
      # committed, not the `❯` user echo it would get from role alone. The
      # empty assistant turn it recovered painted nothing live (no grey
      # fallback, no receipt), so the replay must skip it too.
      let msgs = %*[
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": "",
         "usage": {"promptTokens": 50, "completionTokens": 0,
                   "totalTokens": 50, "cachedTokens": 0}},
        {"role": "user", "content": "Your last reply came back empty. " &
           "Answer now, or continue with a tool call.",
         "agentSent": true},
        {"role": "assistant", "content": "Here it is.",
         "usage": {"promptTokens": 60, "completionTokens": 5,
                   "totalTokens": 65, "cachedTokens": 0}}]
      let rendered = captureReplay(msgs, @[], window = 1000)
      check "» " in rendered
      check BoldOn & "» " & Reset & "Your last reply came back empty." in rendered
      check MagentaFg & "» " notin rendered  # harness voice, not the error tier
      check "❯ Your last reply came back empty." notin rendered
      check "❯ go" in rendered
      check "Here it is." in rendered
      check EmptyReplyMsg notin rendered   # the skipped empty turn leaves no fallback
      check "↑50" notin rendered          # ...and no receipt for it either

    test "harness-autosent messages replay as » items":
      # A `agentSent` user message is a steer: replay renders it with the
      # `»` agent-prompt marker, never as a user `❯` echo. A `goalSent`
      # one carries the goal flag instead.
      let msgs = %*[
        {"role": "user", "content": "Goal check: keep going.",
         "agentSent": true, "goalSent": true},
        {"role": "assistant", "content": "on it.",
         "usage": {"promptTokens": 60, "completionTokens": 5,
                   "totalTokens": 65, "cachedTokens": 0}},
        {"role": "user", "content": "Your last reply came back empty. " &
           "Answer now, or continue with a tool call.",
         "agentSent": true}]
      let rendered = captureReplay(msgs, @[], window = 1000)
      check BoldOn & "⚑ " & Reset & "Goal check: keep going." in rendered
      check BoldOn & "» " & Reset & "Your last reply came back empty." in rendered
      check "❯ Goal check" notin rendered

    test "a kickoff replays as the flag plus the goal text alone":
      # The kickoff item's body is the goal text alone - the `Goal
      # armed:` scaffold and the trailing instruction paragraph never
      # reach scrollback, live or replay. The flag comes from the
      # `Goal armed:` content lead itself, so a kickoff persisted before
      # the `+goal` marker existed still replays under it.
      let kickoff = goalKickoffMessage("fix the login bug\n\nthen ship it")
      let msgs = %*[
        kickoff,
        {"role": "assistant", "content": "on it.",
         "usage": {"promptTokens": 60, "completionTokens": 5,
                   "totalTokens": 65, "cachedTokens": 0}}]
      for strip in [false, true]:
        if strip:
          kickoff.delete("goalSent")  # a session saved before the marker
        let rendered = captureReplay(msgs, @[], window = 1000)
        check BoldOn & "⚑ " & Reset & "fix the login bug" in rendered
        check "Goal armed:" notin rendered
        check "Start working toward it now" notin rendered
        check "then ship it" in rendered   # multi-paragraph goal stays whole
        check "❯ fix the login" notin rendered

    test "flail-noted call replays as its tool item plus the » note":
      # A flail-escalated call executes: replay renders the real tool item
      # (banner + output) AND the `»` note item from `flailNote`, never the
      # note buried inside the output rows.
      let note = "Loop detected: you are repeating tool calls."
      let toolLog = @[
        ToolRecord(banner: "printf hi", output: "hi\n", code: 0,
          kind: akBash),
        ToolRecord(banner: "printf hi", output: "hi\n", code: 0,
          kind: akBash)]
      let msgs = %*[
        {"role": "assistant", "content": "",
         "usage": {"promptTokens": 50, "completionTokens": 0,
                   "totalTokens": 50, "cachedTokens": 0},
         "tool_calls": [
           {"id": "c1", "type": "function",
            "function": {"name": "bash",
              "arguments": "{\"command\": \"printf hi\"}"}},
           {"id": "c2", "type": "function",
            "function": {"name": "bash",
              "arguments": "{\"command\": \"printf hi\"}"}}]},
        {"role": "tool", "tool_call_id": "c1", "content": "hi\n"},
        {"role": "tool", "tool_call_id": "c2",
         "content": note & "\n\nhi\n", "flailNote": note},
        {"role": "assistant", "content": "Recovered.",
         "usage": {"promptTokens": 60, "completionTokens": 5,
                   "totalTokens": 65, "cachedTokens": 0}}]
      let rendered = captureReplay(msgs, toolLog, window = 1000)
      check BoldOn & "» " & Reset & note in rendered
      check rendered.count("$ printf hi") == 2  # both calls executed
      check rendered.count(note) == 1           # note once, as the » item
    test "flail abort batch collapses duplicate notes into one » item":
      # fvAbort executes the flagged call (tool item + flailNote) and pairs
      # the abort note onto every remaining call of the batch; live commits
      # one `»` item, so replay must collapse the consecutive duplicates
      # the same way.
      let note = "Turn aborted: the model is stuck in a loop."
      let toolLog = @[ToolRecord(banner: "make", output: "made\n",
        code: 0, kind: akBash)]
      let msgs = %*[
        {"role": "assistant", "content": "",
         "usage": {"promptTokens": 50, "completionTokens": 0,
                   "totalTokens": 50, "cachedTokens": 0},
         "tool_calls": [
           {"id": "c1", "type": "function",
            "function": {"name": "bash",
              "arguments": "{\"command\": \"make\"}"}},
           {"id": "c2", "type": "function",
            "function": {"name": "bash",
              "arguments": "{\"command\": \"make\"}"}},
           {"id": "c3", "type": "function",
            "function": {"name": "bash",
              "arguments": "{\"command\": \"make\"}"}}]},
        {"role": "tool", "tool_call_id": "c1",
         "content": note & "\n\nmade\n", "flailNote": note},
        {"role": "tool", "tool_call_id": "c2", "content": note,
         "agentSent": true},
        {"role": "tool", "tool_call_id": "c3", "content": note,
         "agentSent": true}]
      let rendered = captureReplay(msgs, toolLog, window = 1000)
      check rendered.count(BoldOn & "» " & Reset & note) == 1
      check "$ make" in rendered     # the aborting call executed and shows
      check "made" in rendered

suite "display: truncated tool output expansion":
  # warp (#64): too much output was trapped behind the truncation hints.
  # The hint now dumps the full output to a per-process temp file and
  # carries it as an OSC 8 `file://` hyperlink (click to open), and
  # `:show N` prints the untruncated body instead of re-rendering the
  # same compacted view with the same hint.
  proc captureShow(arg: string; toolLog: seq[ToolRecord]): string =
    let outPath = getTempDir() / ("tc_show_" & $getCurrentProcessId())
    let saved = stdout
    let f = open(outPath, fmWrite)
    stdout = f
    try:
      showTool(arg, toolLog)
    finally:
      stdout.flushFile
      stdout = saved
      close(f)
    result = readFile(outPath)
    removeFile(outPath)

  teardown:
    if dirExists(toolOutDir()): removeDir(toolOutDir())

  test ":show reveals the elided middle of a truncated bash output":
    var lines: seq[string]
    for i in 1..40: lines.add "line " & $i
    let output = lines.join("\n") & "\n"
    let toolLog = @[ToolRecord(banner: "seq 40", output: output,
      code: 0, kind: akBash)]
    let live = toolResultBytes(akBash, output, 0, 1)
    check "line20" notin live        # the middle stays elided in scrollback
    check "line 7" notin live
    check "omitted" in live
    let shown = captureShow("1", toolLog)
    check "── T1" in shown
    check "line 7" in shown
    check "line 20" in shown
    check "line 40" in shown
    check "omitted" notin shown
    check "hidden" notin shown

  test "read hint is a file:// hyperlink over a dump of the full output":
    var lines: seq[string]
    for i in 1..30: lines.add "line" & align($i, 2)
    let output = lines.join("\n")
    let bytes = toolResultBytes(akRead, output, 0, 7)
    check "… 23 lines hidden · T7.log ↗" in bytes
    check "\x1b]8;;file://" in bytes
    check "\x1b]8;;\x1b\\" in bytes   # the link span closes
    let dump = toolOutDir() / "T7.log"
    check fileExists(dump)
    check readFile(dump) == output

  test "bash omitted hint links its dump":
    var lines: seq[string]
    for i in 1..12: lines.add "out" & align($i, 2)
    let output = lines.join("\n") & "\n"
    let bytes = toolResultBytes(akBash, output, 0, 3)
    check "... 5 lines omitted · T3.log ↗" in bytes
    let dump = toolOutDir() / "T3.log"
    check fileExists(dump)
    check readFile(dump) == output

  test "diff hint links a .diff dump":
    var lines: seq[string]
    for i in 1..50: lines.add "+added line " & $i
    let diff = lines.join("\n")
    let bytes = toolResultBytes(akBash, "done", 0, 5, diff = diff)
    check "… 15 lines hidden · T5.diff ↗" in bytes
    let dump = toolOutDir() / "T5.diff"
    check fileExists(dump)
    check readFile(dump) == diff

  test "short patch diff still dumps and links T<n>.diff (#60)":
    let diff = "*** fix.nim\n+beta2\n-beta"
    let act = Action(kind: akPatch, path: "fix.nim")
    let bytes = toolTranscriptBytes(act, "ok", 0, 4, diff)
    check "T4.diff ↗" in bytes
    check "\x1b]8;;file://" in bytes
    check "\x1b]8;;\x1b\\" in bytes
    check "+beta2" in bytes          # the painted body survives
    check "*** fix.nim\n" notin bytes  # first line lives in the banner only
    let dump = toolOutDir() / "T4.diff"
    check fileExists(dump)
    check readFile(dump) == diff      # ...but the dump stays whole

  test "short outputs render without any hint or dump":
    let bytes = toolResultBytes(akRead, "one\ntwo\nthree", 0, 9)
    check "hidden" notin bytes
    check "file://" notin bytes
    check not fileExists(toolOutDir() / "T9.log")

  test "fileUrl percent-encodes non-URL bytes":
    check fileUrl("/tmp/a b/T1.log") == "file:///tmp/a%20b/T1.log"
when not defined(windows):
  import std/[json, os, sequtils]
  import threecode/[transcript, images]

  suite "display: image read replay and :show":
    proc captureReplay2(messages: JsonNode; toolLog: seq[ToolRecord]): string =
      let outPath = getTempDir() / ("tc_replay2_" & $getCurrentProcessId())
      let saved = stdout
      let f = open(outPath, fmWrite)
      stdout = f
      try:
        discard replaySessionTail(messages, toolLog, 0, "glm")
      finally:
        stdout.flushFile
        stdout = saved
        close(f)
      result = readFile(outPath)
      removeFile(outPath)

    test "replay echoes an @attach user message with the marker":
      let msgs = %*[
        {"role": "system", "content": "sys"},
        {"role": "user", "content": [
          {"type": "text", "text": "@mockup.png describe"},
          {"type": "image_url",
           "image_url": {"url": "data:image/png;base64,AAAA"}}]},
        {"role": "assistant", "content": "ok"},
      ]
      let outp = captureReplay2(msgs, @[])
      check "@mockup.png describe [image attached]" in outp
      check "base64" notin outp

    test "replay skips the harness image follow-up":
      let msgs = %*[
        {"role": "system", "content": "sys"},
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "c1", "type": "function",
           "function": {"name": "read",
                        "arguments": "{\"path\":\"tiny.png\"}"}}]},
        {"role": "user", "content": [
          {"type": "text", "text": "attached: tiny.png (image read)"},
          {"type": "image_url",
           "image_url": {"url": "data:image/png;base64,AAAA"}}]},
        {"role": "assistant", "content": "it is tiny"},
      ]
      let outp = captureReplay2(msgs, @[ToolRecord(
        banner: "tiny.png",
        output: "image tiny.png 16x12 PNG -> delivered 16x12 JPEG; attached below",
        code: 0, kind: akRead)])
      # The tool row carries the one-line `· read img` banner; the follow-up
      # user message echoed nothing live, so it echoes nothing here.
      check "· read img tiny.png 16x12 -> 16x12" in outp
      check "(image read)" notin outp
      check "base64" notin outp

    test "replay renders the screenshot banner and skips its follow-up":
      let msgs = %*[
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "[computer use on] screenshot() ..."},
        {"role": "assistant", "content": "",
         "tool_calls": [{"id": "c1", "type": "function",
           "function": {"name": "screenshot", "arguments": "{}"}}]},
        {"role": "user", "content": [
          {"type": "text",
           "text": "attached: shot 1 16x12 -> 16x12 (screenshot)"},
          {"type": "image_url",
           "image_url": {"url": "data:image/png;base64,AAAA"}}]},
        {"role": "assistant", "content": "it is tiny"},
      ]
      let outp = captureReplay2(msgs, @[ToolRecord(
        banner: "screenshot",
        output: "screenshot 16x12 -> delivered 16x12 JPEG; shot attached below",
        code: 0, kind: akScreenshot)])
      check "· shot 16x12 -> 16x12" in outp
      # Neither the activation note nor the screenshot follow-up echoed
      # anything live; replay keeps them invisible.
      check "(screenshot)" notin outp
      check "computer use on" notin outp
      check "base64" notin outp

    test "--good marks the vision-capable combos":
      # The listing is the discovery surface for "which model can see
      # images" (the manual says so); deepseek's see/no-see split is the
      # motivating case: deepseek-flash sees, the V4/V3 ids do not.
      proc captureGood(): string =
        let outPath = getTempDir() / ("tc_good_" & $getCurrentProcessId())
        let saved = stdout
        let f = open(outPath, fmWrite)
        stdout = f
        try:
          printKnownGood()
        finally:
          stdout.flushFile
          stdout = saved
          close(f)
        result = readFile(outPath)
        removeFile(outPath)
      let listing = captureGood()
      let flash = listing.splitLines.filterIt(
        it.strip.startsWith("deepseek.deepseek-flash"))
      require flash.len == 1
      check "(vision)" in flash[0]
      let pro = listing.splitLines.filterIt(
        it.strip.startsWith("deepseek.deepseek-v4-pro"))
      require pro.len == 1
      check "(vision)" notin pro[0]
      check "(vision) = can see images" in listing

    test ":show renders the whole receipt, never the base64":
      let receipt = "image tiny.png 16x12 PNG -> delivered 16x12 JPEG; " &
        "attached below"
      let s = showToolS("1", @[ToolRecord(banner: "tiny.png",
        output: receipt, code: 0, kind: akRead)])
      check "── T1" in s
      check "delivered 16x12" in s
      check "attached below" in s
      check "base64" notin s


suite "display: multiline bash command banner and :cmd":
  # A multiline bash command used to show only its first line in the `$`
  # banner, with no signal the rest existed. The banner now carries the
  # first `banner_lines` lines plus a linked `+N lines` tail (the T<idx>.cmd
  # dump holds the whole command), and `:cmd [N]` / `:cmd N edit` reveal it
  # in the transcript / $VISUAL.
  setup:
    bannerLinesSetting = 1
  teardown:
    bannerLinesSetting = 1
    if dirExists(toolOutDir()): removeDir(toolOutDir())

  const mlCmd = "echo one\necho two\necho three\necho four"

  test "default: first line plus linked +N tail and a .cmd dump":
    let body = cmdBannerBody(mlCmd, 7)
    check body.startsWith("echo one\n")
    check "+3 lines" in body
    check "\x1b]8;;file://" in body
    check "T7.cmd ↗" in body
    check readFile(toolOutDir() / "T7.cmd") == mlCmd

  test "banner_lines widens the preview":
    bannerLinesSetting = 3
    let body = cmdBannerBody(mlCmd, 7)
    check body.startsWith("echo one\necho two\necho three\n")
    check "+1 line" in body
    check "echo four" notin body

  test "command that fits carries no tail or dump":
    bannerLinesSetting = 3
    let body = cmdBannerBody("echo one\necho two", 7)
    check body == "echo one\necho two"
    check "+1 line" notin body
    check not fileExists(toolOutDir() / "T7.cmd")

  test "no tool index keeps a plain tail (:! pass)":
    let body = cmdBannerBody(mlCmd, 0)
    check "+3 lines" in body
    check "file://" notin body

  test "toolBannerBytes renders the lines as banner rows":
    bannerLinesSetting = 3
    let bytes = toolBannerBytes("echo one", akBash, 0, command = mlCmd,
                                idx = 7)
    check "$ echo one" & Reset & "\r\n" in bytes
    check "  echo two" & Reset & "\r\n" in bytes
    check "  echo three" & Reset & "\r\n" in bytes
    check "+1 line" in bytes
    check "echo four" notin bytes

  test "act form of toolTranscriptBytes routes the command through":
    # The live commit and the session replay both render through this
    # form; a multiline command must keep its banner lines on both.
    bannerLinesSetting = 2
    let act = Action(kind: akBash, body: mlCmd)
    let bytes = toolTranscriptBytes(act, "one\n", 0, 3)
    check "$ echo one" & Reset & "\r\n" in bytes
    check "  echo two" & Reset & "\r\n" in bytes
    check "+2 lines" in bytes

  test "single-line command renders exactly as before":
    let bytes = toolBannerBytes("git status", akBash, 0,
                                command = "git status", idx = 1)
    check bytes == OffWhiteFg & "$ git status" & Reset & "\r\n"

  test ":cmd resolves the last bash call and explicit N":
    let log = @[
      ToolRecord(banner: "seq 3", command: "seq 3", output: "1\n",
        code: 0, kind: akBash),
      ToolRecord(banner: "src/foo.nim", output: "body", code: 0,
        kind: akRead),
      ToolRecord(banner: "git status", command: "git status",
        output: "", code: 0, kind: akBash),
    ]
    let (last, errLast) = resolveBashCmd("", log)
    check errLast == ""
    check last == 2
    check resolveBashCmd("1", log) == (0, "")
    check resolveBashCmd("3", log) == (2, "")
    # T2 is the read between them: N names the tool-call index, not the
    # bash-ordinal.
    let (n2, errN2) = resolveBashCmd("2", log)
    check n2 == -1
    check "not a bash command" in errN2

  test ":cmd rejects non-bash and out-of-range picks":
    let log = @[
      ToolRecord(banner: "src/foo.nim", output: "body", code: 0,
        kind: akRead),
      ToolRecord(banner: "git status", command: "git status",
        output: "", code: 0, kind: akBash),
    ]
    let (badKind, errKind) = resolveBashCmd("1", log)
    check badKind == -1
    check "not a bash command" in errKind
    let (oob, errOob) = resolveBashCmd("9", log)
    check oob == -1
    check "out of range" in errOob

  test ":cmd body prints the whole command":
    let log = @[ToolRecord(banner: previewCmd(mlCmd), command: mlCmd,
      output: "one\n", code: 0, kind: akBash)]
    let body = showCmdS("", log)
    check "── T1  echo one" in body
    check "echo two" in body
    check "echo four" in body

  test ":cmd without bash commands hints":
    let log = @[ToolRecord(banner: "src/foo.nim", output: "body",
      code: 0, kind: akRead)]
    check "no bash commands" in showCmdS("1", log)

suite "display: live follow bytes":
  setup:
    if dirExists(toolOutDir()): removeDir(toolOutDir())

  teardown:
    if dirExists(toolOutDir()): removeDir(toolOutDir())

  test "follow line bytes match transcript body styling":
    let b = toolFollowLineBytes("hello")
    check "  hello" in b
    check b.contains("\r\n")

  test "follow flush bytes keep order":
    let b = toolFollowFlushBytes(@["one", "two", "three"])
    check b.find("one") < b.find("two")
    check b.find("two") < b.find("three")

  test "followed fold pins banner plus dump link, not the body":
    let act = Action(kind: akBash, body: "seq 30")
    var lines: seq[string]
    for i in 1..30: lines.add "line " & $i
    let output = lines.join("\n") & "\n"
    let item = followedToolItem(act, 0, 5, output)
    let bytes = formatItem(item)
    check "$ seq 30" in bytes      # banner survives (toolTranscriptBytes form)
    check "T5.log ↗" in bytes      # the dump link rides along
    check "\x1b]8;;file://" in bytes
    check "line 20" notin bytes    # the body never re-commits at the fold
    let dump = toolOutDir() / "T5.log"
    check fileExists(dump)
    check readFile(dump) == output
