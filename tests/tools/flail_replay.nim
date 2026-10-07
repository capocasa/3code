## Replay a .3log session log through the real FlailDetector to verify
## when each signal fires on a recorded session.
import std/[os, strutils, json]
import threecode/turns except fingerprint

type Call = object
  name, args, output: string
  newBatch: bool  # this call opens a new model response
  code: int
  agent: bool     # +agent: result replaced by a harness note, never ran

proc parse(path: string): seq[Call] =
  type Mode = enum mNone, mUse, mUseArgs, mResult
  var
    cur: Call
    mode: Mode = mNone
    newBatch = false
  for line in lines(path):
    if line == "assistant":
      # tool_use blocks after this line belong to one response batch.
      newBatch = true
    elif line.startsWith("tool_use "):
      if cur.name != "": result.add cur
      let parts = line.splitWhitespace(maxsplit = 3)
      cur = Call(name: parts[2], newBatch: newBatch)
      newBatch = false
      mode = mUse
    elif line.startsWith("tool_result "):
      mode = mResult
      cur.agent = "+agent" in line
      for p in line.splitWhitespace:
        if p.startsWith("exit="):
          cur.code = parseInt(p[5..^1])
    elif mode == mResult:
      # Result body: indented lines until the ~~ terminator. Results the
      # harness replaced (an abort batch's note-only remainder) carry
      # +agent on the header; their body is the note, not a tool output.
      if line.startsWith("  "):
        cur.output.add line.substr(2) & "\n"
      elif line.strip == "~~":
        mode = mNone
    elif mode in {mUse, mUseArgs} and
        (line.startsWith("  ") or line.strip == ""):
      # Arg blocks (write/patch bodies, bash commands) keep indented lines
      # and interior blank lines; the block ends at the first non-indented
      # non-blank line (tokens/tool_result/next section header).
      if line.strip.startsWith("{\"id\":"):
        # The wire line is what the app actually executed; use its
        # arguments verbatim instead of the displayed block, which
        # duplicates the command and would double-count its tokens.
        try:
          cur.args = parseJson(line.strip){"function"}{"arguments"}.getStr
        except CatchableError:
          discard
        mode = mNone
      elif line.startsWith("  "):
        cur.args.add "\n" & line.substr(2)
      elif cur.args.len > 0:
        cur.args.add "\n"
      mode = mUseArgs
    elif line.strip != "" and not line.startsWith(" ") and not line.startsWith("\t"):
      mode = mNone
  if cur.name != "": result.add cur

var det: FlailDetector
let calls = parse(paramStr(1))
echo "calls: ", calls.len
for i, c in calls:
  # c.args is the raw wire arguments JSON the app executed; pass it through
  # untouched so fingerprints and tokens match what the app saw. Batch
  # boundaries reset the one-rung-per-batch guard, like runTurns does.
  if c.newBatch:
    det.flaggedInBatch = false
  let v = det.observeCall(c.name, c.args)
  # Loop verdicts execute the call too (the +flail results carry the real
  # output); only +agent notes (an abort batch's unexecuted remainder)
  # never ran, so only those skip the result signal.
  if not c.agent:
    det.noteResult(c.name, c.args, madeChange = c.code == 0, output = c.output)
  if v != fvOk:
    echo "call #", i + 1, " (", c.name, "): ",
      if v == fvEscalate: "ESCALATE " & $det.escalations else: "ABORT"
