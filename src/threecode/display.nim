import std/[critbits, json, strformat, strutils, terminal]
import types, util, prompts, session, actions, minline

template hint*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)

template hintLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, styleBright, args, resetStyle)

template warn*(args: varargs[untyped]) =
  ## Magenta highlight for the "user has to fix something" tier: API
  ## errors, wizard input validation, unknown command/model, mode gates.
  ## Pairs cleanly with cyan (`hint`) and avoids the red-means-server-down
  ## reflex. Anything for the LLM to handle (SEARCH/REPLACE failures,
  ## parser hiccups, repeat-guard halts, interrupted state) goes through
  ## `styleDim` instead — those don't need to grab the user's eye.
  stdout.styledWrite(fgMagenta, args, resetStyle)

template warnLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgMagenta, args, resetStyle)

proc previewCmd*(body: string, width = 64): string =
  let first = body.strip.splitLines[0]
  if first.len > width: first[0 ..< width-1] & "…" else: first

proc bannerFor*(act: Action): string =
  case act.kind
  of akBash:
    "bash   " & previewCmd(act.body)
  of akRead:
    if act.offset > 0 or act.limit > 0:
      let endHint = if act.limit > 0: $(act.offset + act.limit - 1) else: "end"
      &"read   {act.path}  [lines {max(1, act.offset)}-{endHint}]"
    else:
      &"read   {act.path}"
  of akWrite:
    &"write  {act.path}  ({humanBytes(act.body.len)})"
  of akPatch:
    &"patch  {act.path}  ({act.edits.len} edit" & (if act.edits.len == 1: "" else: "s") & ")"
  of akApplyPatch:
    let nl = act.body.count('\n')
    &"apply_patch  ({nl} line" & (if nl == 1: "" else: "s") & ")"

const
  CompactHead = 3
  CompactTail = 10
  CompactThreshold = CompactHead + CompactTail + 2  # below this, show everything

proc trimTrailingBlank(lines: var seq[string]) =
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1

proc printLine*(l: string) =
  if l == "[exit 0]":
    discard
  elif l.startsWith("[exit "):
    stdout.styledWriteLine styleDim, l, resetStyle
  else:
    stdout.styledWriteLine styleDim, l, resetStyle

proc printBashCompact*(res: string, idx: int) =
  var lines = res.splitLines
  trimTrailingBlank(lines)
  if lines.len <= CompactThreshold:
    for l in lines: printLine(l)
    return
  # keep "$ cmd" line + head body + hidden marker + tail body + "[exit N]"
  var header = 0
  if header < lines.len and lines[header].startsWith("$ "):
    printLine(lines[header]); inc header
  var footer = lines.len
  if footer > 0 and lines[footer-1].startsWith("[exit "):
    dec footer
  let bodyLen = footer - header
  if bodyLen <= CompactThreshold:
    for i in header ..< footer: printLine(lines[i])
  else:
    for i in header ..< header + CompactHead: printLine(lines[i])
    let hidden = bodyLen - CompactHead - CompactTail
    hintLn &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
      &" hidden · :show {idx} for full …", resetStyle
    for i in footer - CompactTail ..< footer: printLine(lines[i])
  if footer < lines.len: printLine(lines[footer])

proc printDiff*(diff: string) =
  const DiffHead = 15
  const DiffTail = 20
  var lines = diff.splitLines
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1
  if lines.len == 0: return
  proc paint(l: string) =
    if l.startsWith("@@"):
      stdout.styledWriteLine fgCyan, l, resetStyle
    elif l.startsWith("+++") or l.startsWith("---"):
      stdout.styledWriteLine styleDim, l, resetStyle
    elif l.len > 0 and l[0] == '+':
      stdout.styledWriteLine fgGreen, l, resetStyle
    elif l.len > 0 and l[0] == '-':
      stdout.styledWriteLine fgRed, l, resetStyle
    else:
      stdout.writeLine l
  if lines.len <= DiffHead + DiffTail + 2:
    for l in lines: paint(l)
    return
  for i in 0 ..< DiffHead: paint(lines[i])
  let hidden = lines.len - DiffHead - DiffTail
  hintLn &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
    " hidden · `git diff` for full …", resetStyle
  for i in lines.len - DiffTail ..< lines.len: paint(lines[i])

proc printActionResult*(act: Action, res: string, code: int, idx: int, diff = "") =
  if act.kind == akBash:
    # The body no longer carries the "$ cmd" echo — reconstitute it for
    # display from the action, then print the real output.
    printLine("$ " & act.body.strip)
    printBashCompact(res, idx)
  elif act.kind == akRead:
    printBashCompact(res, idx)
  else:
    if code == 0:
      stdout.styledWriteLine styleDim, res, resetStyle
    else:
      # Patch / write failure: only the headline goes to the user — the
      # full SEARCH body and any nearest-match hint are for the model
      # (it's already in `res` going back via the tool result). Dumping
      # a 30-line SEARCH block here just makes the screen shout.
      let nl = res.find('\n')
      let head = if nl < 0: res else: res[0 ..< nl]
      stdout.styledWriteLine styleDim, head, resetStyle
  if diff.len > 0:
    printDiff(diff)

proc showProfile*(p: Profile) =
  if p.name == "": return
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  stdout.styledWriteLine fgCyan, styleBright, "  provider ", resetStyle, provider
  stdout.styledWriteLine fgCyan, styleBright, "  variant  ", resetStyle, p.variant
  let mdl = if p.model != "": p.model else: "glm"
  stdout.styledWriteLine fgCyan, styleBright, "  model    ", resetStyle, mdl

# Track up-navigation so "down past last" can return to blank line.
var navigatedUp*: bool = false
var origDown, origUp: proc(ed: var LineEditor) {.closure.}

proc installEditorTweaks*() =
  origUp = KEYMAP["up"]
  origDown = KEYMAP["down"]
  KEYMAP["up"] = proc(ed: var LineEditor) =
    origUp(ed)
    navigatedUp = true
  KEYMAP["down"] = proc(ed: var LineEditor) =
    let before = ed.lineText
    origDown(ed)
    if navigatedUp and ed.lineText == before:
      ed.changeLine("")
      navigatedUp = false
  # also reset the flag when the line is cleared via ctrl+u
  let origClear = KEYMAP["ctrl+u"]
  KEYMAP["ctrl+u"] = proc(ed: var LineEditor) =
    origClear(ed)
    navigatedUp = false

proc welcome*(p: Profile): minline.LineEditor =
  stdout.write "\n"
  stdout.styledWriteLine fgCyan, styleBright, "  ╭─╮"
  stdout.styledWriteLine fgCyan, styleBright, "   ─┤  ", resetStyle, fgWhite, styleBright, "3code ", resetStyle, fgCyan, styleBright, "v" & Version,
    resetStyle, styleDim, "   the economical coding agent"
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  if p.name != "":
    showProfile(p)
    stdout.write "\n"
    stdout.styledWriteLine fgCyan, styleBright, "  type a prompt. :help for commands. :q or Ctrl-D to exit.", resetStyle
    stdout.write "\n"
  stdout.flushFile
  installEditorTweaks()
  result = minline.initEditor(historyFile = historyFile())

proc printSessionList*(paths: seq[string], currentPath: string, showCwd: bool) =
  for p in paths:
    let id = sessionIdFromPath(p)
    var count = 0
    var first = ""
    var cwd = ""
    try:
      let j = parseJson(readFile(p))
      let msgs = j{"messages"}
      if msgs != nil and msgs.kind == JArray: count = msgs.len
      first = firstUserMessage(msgs)
      cwd = j{"cwd"}.getStr("")
    except CatchableError: discard
    let mark = if currentPath == p: "*" else: " "
    let snip =
      if first.len == 0: ""
      elif first.len > 50: "  " & first[0 ..< 47] & "..."
      else: "  " & first
    let cwdStr =
      if showCwd and cwd != "": "  " & collapseHome(cwd)
      else: ""
    hint &"  {mark} ", resetStyle, id, fgCyan, styleBright,
      &"   ({count} msg" & (if count == 1: "" else: "s") & ")",
      resetStyle, cwdStr, snip, "\n"

proc replaySessionTail*(messages: JsonNode, toolLog: seq[ToolRecord], model: string) =
  ## Show the last user turn and everything after, so a resumed session
  ## drops the user back into context without replaying the whole history.
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  var start = messages.len
  for i in countdown(messages.len - 1, 0):
    if messages[i]{"role"}.getStr == "user":
      start = i
      break
  if start >= messages.len: return
  var toolIdx = 0
  for i in 0 ..< start:
    let tc = messages[i]{"tool_calls"}
    if tc != nil and tc.kind == JArray: toolIdx += tc.len
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let c = m{"content"}.getStr("").strip
      if c.len == 0: continue
      let shown = if c.len > 400: c[0 ..< 400] & " …" else: c
      stdout.styledWrite fgWhite, styleBright, "» you  ", resetStyle
      stdout.write shown, "\n"
    of "assistant":
      let c = m{"content"}.getStr("").strip
      if c.len > 0:
        stdout.styledWriteLine fgCyan, c, resetStyle
      let tcs = m{"tool_calls"}
      if tcs != nil and tcs.kind == JArray:
        for tc in tcs:
          inc toolIdx
          let banner =
            if toolIdx <= toolLog.len: toolLog[toolIdx - 1].banner
            else:
              let fn = tc{"function"}
              let name = if fn != nil: fn{"name"}.getStr else: "?"
              let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
              let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                         except CatchableError: newJObject()
              bannerFor(toolCallToAction(model, name, args))
          stdout.styledWrite styleDim, "• ", banner, resetStyle, "\n"
    of "tool":
      let r = m{"content"}.getStr("")
      if r.len > 0:
        printBashCompact(r, toolIdx)
    else: discard
  stdout.flushFile

proc showTool*(arg: string, toolLog: seq[ToolRecord]) =
  if toolLog.len == 0:
    hintLn "  no tool calls yet", resetStyle
    return
  var n = toolLog.len
  if arg != "":
    try: n = parseInt(arg)
    except ValueError:
      stdout.styledWriteLine fgMagenta, "show: not a number: ", arg, resetStyle
      return
  if n < 1 or n > toolLog.len:
    stdout.styledWriteLine fgMagenta,
      &"show: T{n} out of range (1..{toolLog.len})", resetStyle
    return
  let rec = toolLog[n-1]
  stdout.styledWriteLine fgCyan, styleBright, &"── T{n}  ", rec.banner, resetStyle
  if rec.kind in {akBash, akRead}:
    for l in rec.output.splitLines: printLine(l)
  else:
    if rec.code == 0:
      stdout.styledWriteLine fgGreen, rec.output, resetStyle
    else:
      stdout.styledWriteLine styleDim, rec.output, resetStyle

proc listTools*(toolLog: seq[ToolRecord]) =
  if toolLog.len == 0:
    hintLn "  no tool calls yet", resetStyle
    return
  for i, rec in toolLog:
    let tag = &"T{i+1}"
    let lines = rec.output.splitLines.len
    let mark = if rec.code == 0: "✓" else: "✗"
    let color = if rec.code == 0: fgGreen else: fgDefault
    hint &"  {tag:>4}  ", resetStyle,
      color, mark, resetStyle, " ",
      rec.banner,
      fgCyan, styleBright, &"   ({lines} line" & (if lines == 1: "" else: "s") & ")",
      resetStyle, "\n"
