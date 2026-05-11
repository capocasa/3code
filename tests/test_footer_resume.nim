import std/[unittest, strutils, json, os]
import threecode/[api, display, types, util, compact]
import ttty/grid

## Resume bar shape tests.
## See test_footer_bar.nim for the overall layout spec.

# ---------------- Resume bar shape ----------------
#
# On `-r`, after replaying the tail, the live token bar at the bottom
# should carry the *last response's* usage (so the user sees what the
# previous turn cost without needing the inline receipt above), and
# that response's inline receipt is suppressed. `pendingHint` is
# primed so the next user submit converts the bar into the receipt.

suite "resume bar":
  proc replayTo(s: string, messages: JsonNode): (string, Usage) =
    ## Captures `replaySessionTail` output by redirecting stdout to a
    ## temp file. The production API writes directly to stdout (no
    ## File parameter), so this is the only way to capture its output
    ## without refactoring display.nim. The redirect is scoped to this
    ## proc and restored in a `finally` block.
    let path = getTempDir() / "3code_resume_capture_" & s
    let saved = stdout
    let f = open(path, fmWrite)
    stdout = f
    var u: Usage
    try:
      u = replaySessionTail(messages, @[], 200_000, "glm")
    finally:
      stdout.flushFile
      stdout = saved
      close(f)
    let captured = readFile(path)
    try: removeFile(path) except OSError: discard
    (captured, u)

  test "replaySessionTail returns last assistant's usage":
    let messages = parseJson("""[
      {"role":"system","content":"sys"},
      {"role":"user","content":"hi"},
      {"role":"assistant","content":"first answer",
       "usage":{"promptTokens":100,"completionTokens":10,
                "totalTokens":110,"cachedTokens":0}},
      {"role":"user","content":"again"},
      {"role":"assistant","content":"second answer",
       "usage":{"promptTokens":200,"completionTokens":20,
                "totalTokens":220,"cachedTokens":50}}
    ]""")
    let (_, last) = replayTo("ret", messages)
    check last.totalTokens == 220
    check last.promptTokens == 200
    check last.completionTokens == 20
    check last.cachedTokens == 50

  test "replaySessionTail suppresses last assistant's receipt":
    # The last response's token line lives in the bottom bar (painted
    # by the resume code in `main`), not as a scrollback receipt. So
    # the last `↓20` should NOT appear in the replay output.
    let messages = parseJson("""[
      {"role":"user","content":"again"},
      {"role":"assistant","content":"second answer",
       "usage":{"promptTokens":200,"completionTokens":20,
                "totalTokens":220,"cachedTokens":50}}
    ]""")
    let (captured, _) = replayTo("suppress", messages)
    check "second answer" in captured
    check "↓20" notin captured

  test "replaySessionTail keeps non-last receipts in scrollback":
    # Only the *last* assistant in the replayed tail gets the bar
    # treatment. Earlier assistant iterations within the same user turn
    # (multi-iteration: tool call → tool result → final answer) keep
    # their inline receipts so the user sees token cost per iteration.
    let messages = parseJson("""[
      {"role":"user","content":"go"},
      {"role":"assistant","content":"answer one",
       "tool_calls":[{"id":"t1","function":{"name":"bash",
                                            "arguments":"{\"command\":\"ls\"}"}}],
       "usage":{"promptTokens":100,"completionTokens":11,
                "totalTokens":111,"cachedTokens":0}},
      {"role":"tool","tool_call_id":"t1","content":"out"},
      {"role":"assistant","content":"answer two",
       "usage":{"promptTokens":200,"completionTokens":22,
                "totalTokens":222,"cachedTokens":0}}
    ]""")
    let (captured, _) = replayTo("keep", messages)
    check "↓11" in captured
    check "↓22" notin captured

  test "post-replay bar carries last response's tokens at bottom":
    # The byte sequence main writes after replay when lastUsage > 0:
    # gap row + bar+prompt with bright cyan prompt. Pin it via the
    # grid renderer.
    let g = newGrid()
    let lastUsage = Usage(
      promptTokens: 200, completionTokens: 20,
      totalTokens: 220, cachedTokens: 50,
    )
    g.feed "● resumed abc123\n"
    g.feed "(replayed content here)\n"
    g.feed "\n"
    let label = tokenLineLabel(lastUsage, 200_000)
    g.feed barFooterBytes(label, BrightPromptColor)
    var barRow = -1
    for r in 0 ..< g.rows.len:
      if "↓20" in rowText(g, r):
        barRow = r; break
    check barRow >= 0
    check "↑150" in rowText(g, barRow)
    check "↻50" in rowText(g, barRow)
    check "❯" in rowText(g, barRow + 1)
