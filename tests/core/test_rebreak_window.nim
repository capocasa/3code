import std/[json, sequtils, strutils, unittest]
import threecode/[transcript, engine, types]

proc plain(rows: seq[string]): seq[string] =
  ## Strip ANSI and blank separator rows: assertions key on text order only.
  for r in rows:
    var s = ""
    var i = 0
    while i < r.len:
      if r[i] == '\x1b':
        while i < r.len and r[i] != 'm': inc i
      else:
        s.add r[i]
      inc i
    if s.strip.len > 0: result.add s.strip

suite "transcript: rebreak window order":
  # The window paints top-to-bottom on a width change, so rows must come
  # back oldest-first with the newest (the turn's final answer) last,
  # directly above the volatile block. The budget scan walks the tail
  # backwards; emission used to skip the reversal and paint the final
  # answer at the top of the re-rendered tail.
  let messages = %*[
    {"role": "user", "content": "run the checks"},
    {"role": "assistant", "content": "first prose", "tool_calls": [
      {"id": "t1", "function": {"name": "bash",
                                "arguments": "{\"body\": \"echo one\"}"}}]},
    {"role": "tool", "tool_call_id": "t1", "content": "one"},
    {"role": "assistant", "content": "final answer prose"},
  ]
  var toolLog: seq[ToolRecord]
  toolLog.add ToolRecord(banner: "$ echo one", output: "one", code: 0,
                         kind: akBash)

  test "oldest first, final answer last":
    let rows = plain(renderTailRows(messages, toolLog, 40000, "glm",
                                    newSeq[TailJournalRecord](), 80, 200))
    check rows.len == 5
    check rows[0].contains("run the checks")
    check rows[2] == "$"
    check rows[^1].contains("final answer prose")

  test "journal notice paints in commit order between message items":
    # A harness notice anchored at messages.len == 3 sits between the
    # tool item (message 2) and the final prose (message 3).
    var jr: TailJournalRecord
    jr.atMessagesLen = 3
    jr.rows = @["· auto: goal rollover - plan at .3code/goal.md"]
    let rows = plain(renderTailRows(messages, toolLog, 40000, "glm",
                                    @[jr], 80, 200))
    let notice = rows.findIt(it.startsWith("· auto: goal"))
    check notice > rows.findIt(it.contains("echo one"))
    check notice < rows.findIt(it.contains("final answer prose"))

  test "budget cut head-truncates the oldest unit, newest stays last":
    let rows = plain(renderTailRows(messages, toolLog, 40000, "glm",
                                    newSeq[TailJournalRecord](), 80, 5))
    check rows.len <= 5
    check rows[0] == "$"
    check rows[^1].contains("final answer prose")
