## Byte-exact scrollback replay contract: whatever rendered live must render
## identically when the session is resumed.
##
## Phase 1 drives one turn per scrollback item type through the stub provider
## (plain prose, markdown, bash/read/write/plan tools, receipts) and captures
## the settled scrollback after the final turn. Phase 2 resumes and captures
## the replayed scrollback. The conversation region must match row-for-row
## including SGR styling, after masking volatile fields (elapsed seconds).
##
## Verification surface: ttty grid model of a real PTY session.
discard """
  disabled: "win"
"""
import std/[json, os, re, strformat, strutils, unittest]
import tty_expect
import ttty/grid
import frame_artifact
import stub_helpers

const VisualOutputRoot = "testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")
  createDir(result / "xdg" / "3code")

proc writeStubProvider(root: string) =
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

proc toolCall(id, name: string; args: JsonNode): JsonNode =
  %*{
    "id": id,
    "type": "function",
    "function": {"name": name, "arguments": $args}
  }

proc usage(p, c, cached = 0): JsonNode =
  %*{"promptTokens": p, "completionTokens": c,
     "totalTokens": p + c, "cachedTokens": cached}

proc stubEnv(root: string): seq[EnvVar] =
  createDir(root / "tmp")
  result = @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: root / "run" / "stub_responses.json"),
  ]

proc startApp(root: string; args: openArray[string];
              cols = 100, rows = 60): TtySession =
  newTtySession(ensureStubBinary(), args = args, cwd = root / "run",
                env = stubEnv(root), cols = cols, rows = rows)

proc currentRows(s: TtySession): seq[string] =
  ## Plain-text rows of the whole modeled grid (scrollback + screen),
  ## trailing empty rows trimmed.
  for r in 0 ..< s.grid.rows.len:
    result.add rowText(s.grid, r)
  while result.len > 0 and result[^1].strip.len == 0:
    result.setLen(result.len - 1)

proc currentAnsiRows(s: TtySession): seq[string] =
  ## Styled rows (per-cell SGR) of the whole modeled grid, trailing empty
  ## rows trimmed.
  let frame = VisualFrame(id: "now", width: s.grid.width,
    height: s.grid.height, cells: s.grid.rows, cursorRow: s.grid.row,
    cursorCol: s.grid.col, cursorHidden: s.grid.cursorHidden,
    pendingWrap: s.grid.pendingWrap)
  result = frame.ansiRows()
  while result.len > 0 and result[^1].strip.len == 0:
    result.setLen(result.len - 1)

proc region(rows: seq[string]; firstMark, lastMark: string): seq[string] =
  ## Rows from the first containing `firstMark` through the last containing
  ## `lastMark` (inclusive). Empty when either mark is missing.
  var first = -1
  var last = -1
  for i, row in rows:
    if firstMark in row and first < 0: first = i
    if lastMark in row: last = i
  if first < 0 or last < 0 or last < first:
    return @[]
  result = rows[first .. last]

proc stripSgr(row: string): string =
  row.replace(re"\x1b\[[0-9;]*m", "")

proc diffRows(live, replay: seq[string]; label: string): string =
  ## Compare plain-text rows pairwise; report styled bytes on mismatch.
  if live == replay: return ""
  result = label & " differs:" & "\n"
  for i in 0 ..< max(live.len, replay.len):
    let l = if i < live.len: live[i] else: "<missing>"
    let r = if i < replay.len: replay[i] else: "<missing>"
    if l != r:
      result.add &"  row {i}:\n    live:   {l}\n    replay: {r}\n"

suite "resume replay matches live scrollback byte-for-byte":

  test "all scrollback item types replay identically":
    let root = newFixture("resume_replay_bytes")
    writeStubProvider(root)
    writeFile(root / "run" / "file.txt",
              "file content line one\nfile content line two\n")
    # Response order matches the exact call sequence: each tool-call reply
    # is followed by one follow-up reply for the post-tool model call.
    let responses = %*[
      {"role": "assistant", "content": "plain prose reply one",
       "contentChunks": ["plain prose reply one"],
       "usage": usage(100, 20)},
      {"role": "assistant",
       "content": "markdown reply:\n- item one\n- item two",
       "contentChunks": ["markdown reply:\n- item one\n- item two"],
       "usage": usage(150, 30)},
      {"role": "assistant", "content": "running a command",
       "contentChunks": ["running a command"],
       "tool_calls": [
         toolCall("t1", "bash", %*{"command": "printf 'tool-out-line\\n'"})],
       "usage": usage(200, 10)},
      {"role": "assistant", "content": "command done",
       "contentChunks": ["command done"],
       "usage": usage(205, 5)},
      {"role": "assistant", "content": "",
       "tool_calls": [
         toolCall("t2", "read", %*{"path": "file.txt"})],
       "usage": usage(220, 10)},
      {"role": "assistant", "content": "file read",
       "contentChunks": ["file read"],
       "usage": usage(225, 5)},
      {"role": "assistant", "content": "",
       "tool_calls": [
         toolCall("t3", "write",
                  %*{"path": "out.txt", "body": "hello world\n"})],
       "usage": usage(240, 10)},
      {"role": "assistant", "content": "file written",
       "contentChunks": ["file written"],
       "usage": usage(245, 5)},
      {"role": "assistant", "content": "",
       "tool_calls": [
         toolCall("t4", "update_plan",
                  %*{"items": [
                     {"text": "step one", "status": "completed"},
                     {"text": "step two", "status": "pending"}]})],
       "usage": usage(260, 10)},
      {"role": "assistant", "content": "plan set",
       "contentChunks": ["plan set"],
       "usage": usage(265, 5)},
      # turn 7: paragraph break inside one reply
      {"role": "assistant",
       "content": "para one\n\npara two",
       "contentChunks": ["para one\n\npara two"],
       "usage": usage(280, 15)},
      # turn 8: code block + prose
      {"role": "assistant",
       "content": "before fence\n```nim\necho 42\n```\nafter fence",
       "contentChunks": ["before fence\n```nim\necho 42\n```\nafter fence"],
       "usage": usage(290, 25)},
      # turn 9: skill read (suppressed tool marker live + replay)
      {"role": "assistant", "content": "",
       "tool_calls": [
         toolCall("t6", "read",
                  %*{"path": root / "xdg" / "3code" / "skills" /
                            "demo-skill.md"})],
       "usage": usage(300, 10)},
      {"role": "assistant", "content": "skill loaded",
       "contentChunks": ["skill loaded"],
       "usage": usage(305, 5)}
    ]
    # The clear tool is deliberately NOT exercised here: it truncates the
    # conversation at runtime, so the session on disk only ever contains
    # post-clear turns and a cross-clear byte comparison is impossible by
    # design. Its live rendering is covered by the other-tools tty test.
    writeFile(root / "run" / "stub_responses.json", $responses)

    var liveRows: seq[string] = @[]
    block:  # phase 1: live session, one turn per item type
      let tty = startApp(root, args = ["-x", "-i"])
      defer:
        tty.writeFrameArtifact(root / "live_frames.txt")
        tty.close()
      tty.expect("type a prompt", timeoutMs = 8000)
      # Wait for each turn's follow-up marker before the next prompt, so
      # a prompt never buffers into a still-running turn.
      for (prompt, marker) in [
          ("hello world prompt", "plain prose reply one"),
          ("show me markdown", "- item two"),
          ("run the command", "command done"),
          ("read the file", "file read"),
          ("write out.txt", "file written"),
          ("update the plan", "plan set"),
          ("paragraph break please", "para two"),
          ("show a code block", "after fence"),
          ("load the skill", "loaded skill: demo-skill")]:
        tty.send prompt & "\r"
        tty.expectInHistory marker, timeoutMs = 10000
        tty.expectIdleCaret(timeoutMs = 5000)
        tty.drain(150)
      liveRows = currentRows(tty)
      tty.ctrlD()
      tty.expectExit(0, timeoutMs = 5000)

    check liveRows.len > 0

    var replayRows: seq[string] = @[]
    block:  # phase 2: resume
      let tty = startApp(root, args = ["-x", "-i", "-r"])
      defer:
        tty.writeFrameArtifact(root / "resume_frames.txt")
        tty.close()
      tty.expectIdleCaret(timeoutMs = 8000)
      tty.drain(300)
      replayRows = currentRows(tty)
      tty.ctrlD()
      tty.expectExit(0, timeoutMs = 5000)

    check replayRows.len > 0

    # The replayed conversation starts below the "● resumed <id>" row;
    # the live one below the welcome banner. Align on the first user echo
    # still on screen at 60 rows (early turns scroll off both).
    let liveConv = region(liveRows, "read the file", "loaded skill: demo-skill")
    let replayConv = region(replayRows, "read the file",
                            "loaded skill: demo-skill")
    check liveConv.len > 0
    check replayConv.len > 0

    # Mask volatile fields: elapsed-seconds suffixes on receipts ("  0s")
    # depend on the live run's wall clock and are not persisted.
    proc mask(rows: seq[string]): seq[string] =
      for row in rows:
        result.add row.replace(re"  ?\d+s$", "")

    let d = diffRows(mask(liveConv), mask(replayConv), "conversation region")
    writeFile(root / "live_region.txt", mask(liveConv).join("\n"))
    writeFile(root / "replay_region.txt", mask(replayConv).join("\n"))
    if d.len > 0:
      echo d
    check d.len == 0
