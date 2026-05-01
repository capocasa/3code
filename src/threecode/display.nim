import std/[critbits, exitprocs, json, os, strformat, strutils, terminal]
import types, util, config, prompts, session, actions, minline

# Three visible tiers, designed to read on both light + dark terminal
# backgrounds:
#   hint = bold cyan        (primary "look here": labels, CTAs)
#   note = plain cyan       (secondary: help text, validation, errors)
#   subtle = grey 244       (FYI: skill markers, tool output, receipts)
# We avoid SGR `dim` (\x1b[2m) and `fgWhite`: both render below
# readable contrast on light backgrounds.

template hint*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)

template hintLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, styleBright, args, resetStyle)

template note*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, args, resetStyle)

template noteLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, args, resetStyle)

template warn*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, args, resetStyle)

template warnLn*(args: varargs[untyped]) =
  stdout.styledWriteLine(fgCyan, args, resetStyle)

proc subtleWrite*(outFile: File, body: string) =
  ## FYI tier — grey 244, readable on both backgrounds. Replaces
  ## styledWrite(styleDim, ..., resetStyle) which is invisible on
  ## white terminals.
  outFile.write GreyFg
  outFile.write body
  outFile.write Reset

proc subtleWriteLn*(outFile: File, body: string) =
  outFile.write GreyFg
  outFile.write body
  outFile.write Reset
  outFile.write "\n"

# `withCleared` lives in `api.nim` now — it owns `currentBarLabel`,
# the cached bar payload that drives repaint after a content write.
# `display.nim`'s job here is purely formatting: receipts, banners,
# diff coloring, the welcome screen, etc.

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
  subtleWriteLn(stdout, "· loaded skill: " & name)

proc trimTrailingBlank(lines: var seq[string]) =
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1

proc printLine*(l: string) =
  if l == "[exit 0]":
    discard
  else:
    subtleWriteLn(stdout, "  " & l)

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
    subtleWriteLn(stdout,
      &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
      &" hidden · :show {idx} for full …")
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
      subtleWriteLn(stdout, s)
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
  subtleWriteLn(stdout,
    &"  … {hidden} line" & (if hidden == 1: "" else: "s") &
    " hidden · `git diff` for full …")
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
      subtleWriteLn(stdout, "  " & res)
    else:
      # Patch / write failure: only the headline goes to the user; the
      # full SEARCH body lives in `res` which the model still sees via
      # the tool result. Dumping a 30-line SEARCH block here just shouts.
      let nl = res.find('\n')
      let head = if nl < 0: res else: res[0 ..< nl]
      subtleWriteLn(stdout, "  " & head)
  if diff.len > 0:
    printDiff(diff)

proc printActionResult*(act: Action, res: string, code: int, idx: int, diff = "") =
  printToolResult(act.kind, res, code, idx, diff)

proc contextLabel*(promptTokens, window: int): string =
  ## "○ 12%" / "◔ 25%" / … / "● 92%". Empty when there's no useful
  ## number (no window). Previously also omitted when there were no tokens yet,
  ## which hid the context indicator at startup. We now always show a bullet
  ## with a percentage, defaulting to 0% when `promptTokens` is zero.
  if window <= 0: return ""
  let pct = int(promptTokens.float / window.float * 100.0)
  let glyph =
    if pct < 20: "○"
    elif pct < 40: "◔"
    elif pct < 60: "◑"
    elif pct < 80: "◕"
    else: "●"
  # Lone exception to the no-space-inside-slots rule: the half-circles
  # crowd a digit too tightly without a hair of breathing room.
  &"{glyph} {pct}%"

type MarkdownState* = ref object
  ## Per-line markdown rendering state. Shared between the streaming
  ## path (api.nim feeds chunks line by line as they arrive over SSE)
  ## and the replay path (display.nim feeds the stored full content).
  ## Both call `handleMdLine` per line and `finishMd` at end so the
  ## visible output is byte-identical regardless of who fed the lines.
  ## `ref` so nested closures inside the handlers can mutate it.
  firstEmit*: bool
  tableBuf*: seq[string]
  codeBuf*: seq[string]
  inCode*: bool

proc initMarkdownState*(firstEmit = true): MarkdownState =
  MarkdownState(firstEmit: firstEmit)

proc handleMdLine*(s: MarkdownState, l: string, outFile: File): bool {.discardable.} =
  ## Route one input line through markdown handlers (headers, fences,
  ## tables, paragraphs). Returns true if anything was written to
  ## `outFile` this call (table rows and code-block bodies buffer
  ## silently until flushed). State accumulates across calls.
  proc emitLine(l: string) =
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 2)
    let chunks = wrapAnsi(applyInlineMd(l), bodyW)
    var k = 0
    for chunk in chunks:
      let prefix = if s.firstEmit and k == 0: "" else: "  "
      outFile.write(prefix & chunk & "\n")
      inc k
    s.firstEmit = false
  proc emitHeader(text: string) =
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 2)
    let chunks = wrapAnsi(text, bodyW)
    var k = 0
    for chunk in chunks:
      let prefix = if s.firstEmit and k == 0: "" else: "  "
      outFile.styledWrite(styleBright, prefix & chunk & "\n", resetStyle)
      inc k
    s.firstEmit = false
  proc flushTable(): bool =
    if s.tableBuf.len == 0: return false
    if s.firstEmit:
      outFile.write "\n"
      s.firstEmit = false
    if s.tableBuf.len < 2:
      for r in s.tableBuf: emitLine(r)
    else:
      let termW = try: terminalWidth() except CatchableError: 80
      let rendered = renderMdTable(s.tableBuf, maxWidth = termW)
      outFile.write(rendered)
    s.tableBuf.setLen 0
    true
  if s.inCode:
    if isMdFenceLine(l):
      # close the fence: flush the buffered body, exit code mode
      var emitted = false
      for cl in s.codeBuf:
        if s.firstEmit:
          outFile.write "\n"
          s.firstEmit = false
        subtleWrite(outFile, "  ┃ ")
        outFile.write(cl & "\n")
        emitted = true
      s.codeBuf.setLen 0
      s.inCode = false
      return emitted
    s.codeBuf.add l
    return false
  if isMdFenceLine(l):
    let flushed = flushTable()
    s.inCode = true
    return flushed
  if isMdTableRow(l):
    s.tableBuf.add l
    return false
  let flushed = flushTable()
  let (isHdr, hdrText) = detectMdHeader(l)
  if isHdr:
    emitHeader(hdrText)
  else:
    emitLine(l)
  result = true or flushed

proc finishMd*(s: MarkdownState, outFile: File): bool {.discardable.} =
  ## Flush any pending code block or table buffer at end of content.
  ## Returns true if anything was written.
  result = false
  if s.codeBuf.len > 0:
    for cl in s.codeBuf:
      if s.firstEmit:
        outFile.write "\n"
        s.firstEmit = false
      subtleWrite(outFile, "  ┃ ")
      outFile.write(cl & "\n")
    s.codeBuf.setLen 0
    result = true
  if s.tableBuf.len > 0:
    if s.firstEmit:
      outFile.write "\n"
      s.firstEmit = false
    if s.tableBuf.len < 2:
      var nested = initMarkdownState(s.firstEmit)
      for r in s.tableBuf: handleMdLine(nested, r, outFile)
      s.firstEmit = nested.firstEmit
    else:
      let termW = try: terminalWidth() except CatchableError: 80
      let rendered = renderMdTable(s.tableBuf, maxWidth = termW)
      outFile.write(rendered)
    s.tableBuf.setLen 0
    result = true

proc renderAssistantContent*(content: string, outFile: File = stdout) =
  ## Bullet `● ` (bright white) + dim content with full markdown
  ## structure (headers, fences, tables, inline `**bold**`/`` `code` ``).
  ## Used by replay and by the live path when content was buffered (rare:
  ## streaming bypasses this and feeds the same handlers chunk by chunk).
  ## `outFile` lets tests capture output to a temp file; default is
  ## stdout.
  if content.strip.len == 0: return
  outFile.styledWrite fgCyan, styleBright, "● ", resetStyle
  var st = initMarkdownState()
  for line in content.splitLines:
    handleMdLine(st, line, outFile)
  finishMd(st, outFile)
  outFile.flushFile

proc renderToolPending*(banner: string) =
  ## Pre-execution banner: grey bullet + grey banner. Live only; the live
  ## caller overwrites this line with `renderToolBanner` once the action
  ## returns. Replay skips this and goes straight to the result form.
  subtleWrite(stdout, "● " & banner)
  stdout.write "\n"
  stdout.flushFile

proc renderToolBanner*(banner: string, code: int, elapsedS = -1) =
  ## Final tool banner: green bullet on success, grey on error, grey
  ## banner. Optional `(Ns)` suffix when `elapsedS >= 1` (live); replay
  ## passes -1 to omit it.
  if code == 0:
    stdout.styledWrite fgGreen, "● ", resetStyle
  else:
    subtleWrite(stdout, "● ")
  subtleWrite(stdout, banner)
  if elapsedS >= 1:
    subtleWrite(stdout, &"  ({elapsedS}s)")
  stdout.write "\n"
  stdout.flushFile

proc tokenLineLabel*(usage: Usage, window: int, elapsedS = -1): string =
  ## Pure label string for the bar / receipt: "○N%  ↑fresh  ↻cached
  ## ↓completion  Ts" (no styling, no leading spaces — caller wraps
  ## it in cyan-bright for the bar or dim for the receipt). Empty
  ## when there's no usage to report.
  if usage.totalTokens <= 0: return ""
  let fresh = max(0, usage.promptTokens - usage.cachedTokens)
  let ctx = contextLabel(usage.promptTokens, window)
  result = if ctx.len > 0: ctx & "  " else: ""
  result.add tokenSlot("↑", fresh)
  result.add "  " & tokenSlot("↻", usage.cachedTokens)
  result.add "  " & tokenSlot("↓", usage.completionTokens)
  if elapsedS >= 0:
    result.add "  " & $elapsedS & "s"

proc tokenLineBytes*(usage: Usage, window: int, elapsedS = -1): string =
  ## Pure-byte form of the **token receipt** row used by the *replay*
  ## path (saved sessions). The live path uses `submitTransitionBytes`
  ## which paints the receipt in place of the previous turn's bar.
  ## Returns "" when there's no usage. Trailing double `\x1b[0m` reset
  ## matches the byte sequence Nim's `styledWrite(... , "\n")` macro
  ## emits; pinned by `tests/test_golden.nim`.
  let label = tokenLineLabel(usage, window, elapsedS)
  if label.len == 0: return ""
  result = GreyFg & "  " & label & Reset & "\n" & Reset

proc renderTokenLine*(usage: Usage, window: int, elapsedS = -1) =
  ## "○N%  ↑Nk  ↻Nk  ↓Nk  Ts": context glyph, fresh, cached, generated,
  ## optional duration. Two-space separation, no padding inside slots.
  ## Empty when usage has no totals. Live passes seconds; replay passes
  ## -1 to omit the duration.
  let bytes = tokenLineBytes(usage, window, elapsedS)
  if bytes.len > 0:
    stdout.write bytes

proc showProfile*(p: Profile) =
  if p.name == "": return
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  stdout.styledWriteLine fgCyan, styleBright, "  provider ", resetStyle, provider
  stdout.styledWriteLine fgCyan, styleBright, "  model    ", resetStyle, shortModel(p.model)

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

proc setSteadyCursor() =
  ## DECSCUSR `\x1b[2 q`: steady block. The blink in 3code adds no
  ## information (the `❯ ` prompt already marks the input position)
  ## and competes with the spinner, which is the only animation that
  ## carries meaning here. Restored to terminal default on exit by the
  ## `\x1b[0 q` hook below; if 3code is killed abruptly the next CLI
  ## that sets a cursor style (or a `tput reset`) restores it.
  stdout.write "\x1b[2 q"
  stdout.flushFile

proc restoreCursor() {.noconv.} =
  try:
    stdout.write "\x1b[0 q"
    stdout.flushFile
  except IOError: discard

proc welcome*(p: Profile): minline.LineEditor =
  setSteadyCursor()
  addExitProc(restoreCursor)
  stdout.write "\n"
  stdout.styledWriteLine fgCyan, styleBright, "  ╭─╮"
  stdout.styledWrite fgCyan, styleBright, "   ─┤  ", resetStyle, styleBright, "3code ", resetStyle, fgCyan, styleBright, "v" & Version, resetStyle
  subtleWriteLn(stdout, "   the economical coding agent")
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  if p.name != "":
    showProfile(p)
    stdout.write "\n"
    stdout.styledWrite fgCyan, styleBright, "  type a prompt. ", resetStyle
    subtleWriteLn(stdout, ":help for commands. :q or Ctrl-D to exit.")
  stdout.flushFile
  installEditorTweaks()
  result = minline.initEditor(historyFile = historyFile())

proc printKnownGood*() =
  ## List every `(provider, variant)` combo in `KnownGoodCombos` along
  ## with its model + version tags. Powers `--good` / `3code good` so a
  ## user can survey the curated catalog without configuring anything.
  echo "known-good provider/variant combos:"
  echo ""
  var maxId = 0
  for c in KnownGoodCombos:
    let id = c[0] & "." & c[1]
    if id.len > maxId: maxId = id.len
  for c in KnownGoodCombos:
    let id = c[0] & "." & c[1]
    let v =
      if c[3].len > 0 and c[4].len > 0: c[3] & "." & c[4]
      elif c[3].len > 0: c[3]
      else: c[4]
    let tag = if v.len > 0: c[2] & " " & v else: c[2]
    echo "  ", id.alignLeft(maxId), "  ", tag
  echo ""
  echo "pass any of these to --model, e.g. 3code --model ", KnownGoodCombos[0][0],
       ".", KnownGoodCombos[0][1]
  echo "other combos require --experimental."

proc printSessionList*(paths: seq[string], currentPath: string, showCwd: bool) =
  for p in paths:
    let id = sessionIdFromPath(p)
    let preview = previewSession(p)
    let mark = if currentPath == p: "*" else: " "
    let snip =
      if preview.firstUser.len == 0: ""
      elif preview.firstUser.len > 50: "  " & preview.firstUser[0 ..< 47] & "..."
      else: "  " & preview.firstUser
    let cwdStr =
      if showCwd and preview.cwd != "": "  " & collapseHome(preview.cwd)
      else: ""
    hint &"  {mark} ", resetStyle, id, fgCyan, styleBright,
      &"   ({preview.msgCount} msg" & (if preview.msgCount == 1: "" else: "s") & ")",
      resetStyle, cwdStr, snip, "\n"

proc replaySessionTail*(messages: JsonNode, toolLog: seq[ToolRecord],
                       window: int, family: string): Usage =
  ## Show the last user turn and everything after, so a resumed session
  ## drops the user back into context without replaying the whole history.
  ## Renders via the same helpers the live path uses; usage is read from
  ## each assistant message's inline `usage` field (legacy sessions saved
  ## before the inline format simply skip the token line). The last
  ## assistant's inline receipt is suppressed and its usage is returned
  ## instead — the caller paints the live token bar with it, so the
  ## resumed shape matches the post-`endTurn` typing-ready state.
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  var start = messages.len
  for i in countdown(messages.len - 1, 0):
    if messages[i]{"role"}.getStr == "user":
      start = i
      break
  if start >= messages.len: return
  var lastAssistant = -1
  for i in countdown(messages.len - 1, start):
    if messages[i]{"role"}.getStr == "assistant":
      lastAssistant = i
      break
  var toolIdx = 0
  for i in 0 ..< start:
    let m = messages[i]
    if m{"role"}.getStr == "assistant":
      let tc = m{"tool_calls"}
      if tc != nil and tc.kind == JArray: toolIdx += tc.len
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let c = stripPreamble(m{"content"}.getStr("")).strip
      if c.len == 0: continue
      let shown = if c.len > 400: c[0 ..< 400] & " …" else: c
      let userLines = shown.splitLines
      stdout.write "\n"
      for idx, l in userLines:
        let prefix = if idx == 0: "❯ " else: "  "
        stdout.write prefix & l & "\n"
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
      let u = usageFromJson(m{"usage"})
      if i == lastAssistant:
        result = u
      elif u.totalTokens > 0:
        renderTokenLine(u, window)
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
      subtleWriteLn(stdout, rec.output)

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
