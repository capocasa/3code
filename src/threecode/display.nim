import std/[critbits, json, os, strformat, strutils, terminal]
import types, util, prompts, session, actions, minline

template hint*(args: varargs[untyped]) =
  ## Bright cyan + bold — for labels and primary CTAs ("provider",
  ## "type a prompt."). This is the "look here" tier.
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)

template hintLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, styleBright, args, resetStyle)

template note*(args: varargs[untyped]) =
  ## Dim cyan tint — soft greyish-cyan, the harness's "talking to the
  ## user" voice. Used for help text, error messages, secondary
  ## instructions, validation hints. Noticeable (cyan hue) but soft
  ## (dim) — doesn't shout, doesn't hide. Compare:
  ##   hint = bright cyan + bold (primary)
  ##   note = dim cyan tint (action-required, secondary)
  ##   styleDim alone = greyish (FYI: thinking, tokens, tool output)
  stdout.styledWrite(fgCyan, styleDim, args, resetStyle)

template noteLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, styleDim, args, resetStyle)

template warn*(args: varargs[untyped]) =
  ## Same dim-cyan tint as `note` — error messages now share the
  ## "harness talking to you" voice rather than a separate magenta
  ## tier. Errors are action-required; the soft cyan tone keeps them
  ## visible without shouting.
  stdout.styledWrite(fgCyan, styleDim, args, resetStyle)

template warnLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, styleDim, args, resetStyle)

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
  CompactTail = 0
  ReadHead = 2
  ReadTail = 5

proc isSkillRead*(act: Action): bool =
  ## True when the action is a `cat`/`head`/`sed`-style read of a skill
  ## file (any path under a registered skills dir). The main loop
  ## suppresses banner + body output for these and prints its own dim
  ## "loaded skill: <name>" marker so the user sees a single, styled
  ## signal rather than a tool transcript.
  let dirs = skillsDirs()
  case act.kind
  of akRead:
    for d in dirs:
      if act.path.startsWith(d): return true
  of akBash:
    for d in dirs:
      if d in act.body: return true
  else: discard
  false

proc skillNameFromAct*(act: Action): string =
  ## Best-effort extraction of the skill name from a skill-read action.
  ## Returns the basename without the `.md` suffix, or "" if we can't
  ## tell. The bash form scans for the first registered skills-dir
  ## prefix in the command body, then takes the path that follows.
  var fname = ""
  case act.kind
  of akRead:
    fname = act.path.extractFilename
  of akBash:
    let dirs = skillsDirs()
    for d in dirs:
      let idx = act.body.find(d)
      if idx < 0: continue
      let after = act.body[idx + d.len .. ^1].strip(chars = {'/'}, trailing = false)
      var endIdx = 0
      while endIdx < after.len and
            after[endIdx] notin {' ', '\t', '\n', ';', '|', '&', '"', '\''}:
        inc endIdx
      fname = after[0 ..< endIdx].extractFilename
      break
  else: discard
  if fname.endsWith(".md"): fname[0 ..< fname.len - 3] else: fname

proc printSkillLoaded*(act: Action) =
  let name = skillNameFromAct(act)
  if name.len == 0: return
  stdout.styledWriteLine styleDim, "· loaded skill: ", name, resetStyle

proc trimTrailingBlank(lines: var seq[string]) =
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1

proc printLine*(l: string) =
  if l == "[exit 0]":
    discard
  else:
    stdout.styledWriteLine styleDim, "  " & l, resetStyle

proc printBashCompact*(res: string, idx: int, head = CompactHead, tail = CompactTail) =
  var lines = res.splitLines
  trimTrailingBlank(lines)
  var header = 0
  if header < lines.len and lines[header].startsWith("$ "):
    printLine(lines[header]); inc header
  var footer = lines.len
  if footer > 0 and lines[footer-1].startsWith("[exit "):
    dec footer
  let bodyLen = footer - header
  let hidden = bodyLen - head - tail
  # Only truncate when the hidden count exceeds what we'd show in
  # truncated form (head + tail + marker). Otherwise the marker is
  # heavier than the saving, so just print all of it.
  if hidden <= head + tail + 1:
    for i in header ..< footer: printLine(lines[i])
  else:
    for i in header ..< header + head: printLine(lines[i])
    stdout.styledWriteLine styleDim,
      &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
      &" hidden · :show {idx} for full …", resetStyle
    for i in footer - tail ..< footer: printLine(lines[i])
  if footer < lines.len: printLine(lines[footer])

proc printDiff*(diff: string) =
  const DiffHead = 15
  const DiffTail = 20
  var lines = diff.splitLines
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1
  if lines.len == 0: return
  proc paint(l: string) =
    let s = "  " & l
    if l.startsWith("@@"):
      stdout.styledWriteLine fgCyan, s, resetStyle
    elif l.startsWith("+++") or l.startsWith("---"):
      stdout.styledWriteLine styleDim, s, resetStyle
    elif l.len > 0 and l[0] == '+':
      stdout.styledWriteLine fgGreen, s, resetStyle
    elif l.len > 0 and l[0] == '-':
      stdout.styledWriteLine fgRed, s, resetStyle
    else:
      stdout.writeLine s
  if lines.len <= DiffHead + DiffTail + 2:
    for l in lines: paint(l)
    return
  for i in 0 ..< DiffHead: paint(lines[i])
  let hidden = lines.len - DiffHead - DiffTail
  stdout.styledWriteLine styleDim,
    &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
    " hidden · `git diff` for full …", resetStyle
  for i in lines.len - DiffTail ..< lines.len: paint(lines[i])

proc printToolResult*(kind: ActionKind, res: string, code: int, idx: int,
                     diff = "") =
  ## Body of a tool turn. bash/read fan out via `printBashCompact`
  ## (different head/tail caps); write/patch print the headline only on
  ## success, or the first error line on failure. A non-empty `diff` is
  ## colourised after the body. Banner is drawn separately by
  ## `renderToolBanner`.
  if kind == akBash:
    printBashCompact(res, idx)
  elif kind == akRead:
    printBashCompact(res, idx, ReadHead, ReadTail)
  else:
    if code == 0:
      stdout.styledWriteLine styleDim, "  " & res, resetStyle
    else:
      # Patch / write failure: only the headline goes to the user; the
      # full SEARCH body lives in `res` which the model still sees via
      # the tool result. Dumping a 30-line SEARCH block here just shouts.
      let nl = res.find('\n')
      let head = if nl < 0: res else: res[0 ..< nl]
      stdout.styledWriteLine styleDim, "  " & head, resetStyle
  if diff.len > 0:
    printDiff(diff)

proc printActionResult*(act: Action, res: string, code: int, idx: int, diff = "") =
  printToolResult(act.kind, res, code, idx, diff)

proc contextLabel*(promptTokens, window: int): string =
  ## "○ 12%" / "◔ 25%" / … / "● 92%". Empty when there's no useful
  ## number (no window, or no tokens yet). Same shape used by the live
  ## spinner and the per-turn token summary.
  if window <= 0 or promptTokens <= 0: return ""
  let pct = int(promptTokens.float / window.float * 100.0)
  let glyph =
    if pct < 20: "○"
    elif pct < 40: "◔"
    elif pct < 60: "◑"
    elif pct < 80: "◕"
    else: "●"
  &"{glyph} {pct}%"

proc renderAssistantContent*(content: string) =
  ## Bullet `● ` (bright white) + dim content; subsequent lines indent two
  ## spaces. No-op on empty/whitespace. Used by the replay path and by the
  ## live path when content was buffered (rare: streaming bypasses this).
  if content.strip.len == 0: return
  stdout.styledWrite fgWhite, styleBright, "● ", resetStyle
  let lines = content.splitLines
  for idx, l in lines:
    let prefix = if idx == 0: "" else: "  "
    stdout.styledWrite fgWhite, styleDim, prefix & l & "\n", resetStyle
  stdout.flushFile

proc renderToolPending*(banner: string) =
  ## Pre-execution banner: dim bullet + dim banner. Live only; the live
  ## caller overwrites this line with `renderToolBanner` once the action
  ## returns. Replay skips this and goes straight to the result form.
  stdout.styledWrite fgWhite, styleDim, "● ", banner, resetStyle, "\n"
  stdout.flushFile

proc renderToolBanner*(banner: string, code: int, elapsedS = -1) =
  ## Final tool banner: green bullet on success, dim white on error, dim
  ## white banner. Optional `(Ns)` suffix when `elapsedS >= 1` (live);
  ## replay passes -1 to omit it.
  if code == 0:
    stdout.styledWrite fgGreen, "● ", resetStyle
  else:
    stdout.styledWrite fgWhite, styleDim, "● ", resetStyle
  stdout.styledWrite fgWhite, styleDim, banner, resetStyle
  if elapsedS >= 1:
    stdout.styledWrite fgWhite, styleDim, &"  ({elapsedS}s)", resetStyle
  stdout.write "\n"
  stdout.flushFile

proc renderTokenLine*(usage: Usage, window: int, elapsedS = -1) =
  ## "○ N%   ↑ Nk   ↺ Nk   ↓ Nk   Ts" — context glyph, fresh, cached,
  ## generated, optional duration. Empty when usage has no totals. Live
  ## passes seconds; replay passes -1 to omit the duration.
  if usage.totalTokens <= 0: return
  let fresh = max(0, usage.promptTokens - usage.cachedTokens)
  let ctx = contextLabel(usage.promptTokens, window)
  var line = if ctx.len > 0: ctx & "   " else: ""
  line.add tokenSlot("↑", fresh)
  line.add "   " & tokenSlot("↺", usage.cachedTokens)
  line.add "   " & tokenSlot("↓", usage.completionTokens)
  if elapsedS >= 0:
    line.add "   " & $elapsedS & "s"
  stdout.styledWrite(styleDim, "  " & line, resetStyle, "\n")

proc showProfile*(p: Profile) =
  if p.name == "": return
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  stdout.styledWriteLine fgCyan, styleBright, "  provider ", resetStyle, provider
  stdout.styledWriteLine fgCyan, styleBright, "  model    ", resetStyle, p.model

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
  stdout.styledWrite fgCyan, styleBright, "   ─┤  ", resetStyle, fgWhite, styleBright, "3code ", resetStyle, fgCyan, styleBright, "v" & Version, resetStyle
  stdout.styledWriteLine fgCyan, styleDim, "   the economical coding agent", resetStyle
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  if p.name != "":
    showProfile(p)
    stdout.write "\n"
    stdout.styledWrite fgCyan, styleBright, "  type a prompt. ", resetStyle
    stdout.styledWriteLine fgCyan, styleDim, ":help for commands. :q or Ctrl-D to exit.", resetStyle
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

proc replaySessionTail*(messages: JsonNode, toolLog: seq[ToolRecord],
                       turnUsage: seq[Usage], window: int, family: string) =
  ## Show the last user turn and everything after, so a resumed session
  ## drops the user back into context without replaying the whole history.
  ## Renders via the same helpers the live path uses; `turnUsage` carries
  ## per-assistant-message usage so each assistant block gets the same
  ## token line as in live (no duration suffix).
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  var start = messages.len
  for i in countdown(messages.len - 1, 0):
    if messages[i]{"role"}.getStr == "user":
      start = i
      break
  if start >= messages.len: return
  var toolIdx = 0
  var asstIdx = 0
  for i in 0 ..< start:
    let m = messages[i]
    if m{"role"}.getStr == "assistant":
      inc asstIdx
      let tc = m{"tool_calls"}
      if tc != nil and tc.kind == JArray: toolIdx += tc.len
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let c = m{"content"}.getStr("").strip
      if c.len == 0: continue
      let shown = if c.len > 400: c[0 ..< 400] & " …" else: c
      let userLines = shown.splitLines
      stdout.write "\n"
      for idx, l in userLines:
        let prefix = if idx == 0: "❯ " else: "  "
        stdout.styledWrite fgWhite, prefix & l, resetStyle, "\n"
      stdout.write "\n"
    of "assistant":
      # Mirror callModel's leading \n in the live path: a turn that
      # follows a tool result needs the same blank-line separator. The
      # first assistant after the user message already gets one from the
      # user block's trailing \n, so skip then.
      if i > start and messages[i-1]{"role"}.getStr == "tool":
        stdout.write "\n"
      let c = m{"content"}.getStr("").strip
      renderAssistantContent(c)
      if asstIdx < turnUsage.len:
        renderTokenLine(turnUsage[asstIdx], window)
      inc asstIdx
      let tcs = m{"tool_calls"}
      let hasTools = tcs != nil and tcs.kind == JArray and tcs.len > 0
      if hasTools:
        stdout.write "\n"
        for tc in tcs:
          inc toolIdx
          var banner = ""
          var code = 0
          var output = ""
          var kind = akBash
          if toolIdx <= toolLog.len:
            let rec = toolLog[toolIdx - 1]
            banner = rec.banner
            code = rec.code
            output = rec.output
            kind = rec.kind
          else:
            let fn = tc{"function"}
            let name = if fn != nil: fn{"name"}.getStr else: "?"
            let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
            let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                       except CatchableError: newJObject()
            let act = toolCallToAction(family, name, args)
            banner = bannerFor(act)
            kind = act.kind
          renderToolBanner(banner, code)
          if output.len > 0:
            printToolResult(kind, output, code, toolIdx)
    of "tool":
      # Result already rendered alongside the assistant's tool_call via
      # toolLog; nothing to do here. Older sessions without a populated
      # toolLog will fall through to the printToolResult path above.
      discard
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
