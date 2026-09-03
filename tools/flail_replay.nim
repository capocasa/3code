## Replay a .3log session log through the real FlailDetector to verify
## when each signal fires on the recorded mergepdf session.
import std/[os, strutils, json]
import threecode/turns except fingerprint

type Call = object
  name, args: string
  code: int

proc parse(path: string): seq[Call] =
  type Mode = enum mNone, mUse, mUseArgs, mResult
  var
    cur: Call
    mode: Mode = mNone
  for line in lines(path):
    if line.startsWith("tool_use "):
      if cur.name != "": result.add cur
      let parts = line.splitWhitespace(maxsplit = 3)
      cur = Call(name: parts[2])
      mode = mUse
    elif line.startsWith("tool_result "):
      mode = mResult
      for p in line.splitWhitespace:
        if p.startsWith("exit="):
          cur.code = parseInt(p[5..^1])
    elif mode in {mUse, mUseArgs} and
        (line.startsWith("  ") or line.strip == ""):
      # Arg blocks (write/patch bodies, bash commands) keep indented lines
      # and interior blank lines; the block ends at the first non-indented
      # non-blank line (tokens/tool_result/next section header).
      if line.startsWith("  "):
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
  let argsJson = "{\"command\":" & escapeJson(c.args) & "}"
  let v = det.observeCall(c.name, argsJson)
  det.noteResult(c.name, argsJson, madeChange = c.code == 0)
  if v != fvOk:
    echo "call #", i + 1, " (", c.name, "): ",
      if v == fvEscalate: "ESCALATE " & $det.escalations else: "ABORT"
