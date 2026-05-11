## Terminal rendering: markdown, token bar, tool banners, and session replay.
##
## All terminal output except user-input lines goes through this module.
##
## - **Markdown rendering**: headers, fences, tables, bold/italic/code pass
##   through `printLine` which calls `applyInlineMd` and wraps at terminal
##   width. Tables buffer rows and render aligned box-drawing via `renderMdTable`.
## - **Token bar**: the live bar during streaming (`paintBarBelow`/`paintBarPrompt`)
##   and the dim receipt in scroll history after each turn (`renderTokenLine`).
## - **Tool banners**: per-kind glyph and path header for each tool call result.
## - **Session replay**: `replaySession` reprints a loaded session in the same
##   visual style as a live session, reusing the same render helpers.
##
## The three-tier colour palette (bold cyan for hints, plain cyan for notes,
## grey-244 for subtle FYI output) avoids SGR `dim` and `fgWhite` which render
## below readable contrast on light terminal backgrounds.

import std/[critbits, exitprocs, json, os, strformat, strutils, terminal, times]
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
  stdout.styledWrite(fgCyan, styleBright, args, resetStyle)
  stdout.write "\r\n"

template note*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, args, resetStyle)

template noteLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, args, resetStyle)
  stdout.write "\r\n"

template warn*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, args, resetStyle)

template warnLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgCyan, args, resetStyle)
  stdout.write "\r\n"

template err*(args: varargs[untyped]) =
  stdout.styledWrite(fgMagenta, args, resetStyle)

template errLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgMagenta, args, resetStyle)
  stdout.write "\r\n"

proc debugOut*(msg: string) =
  if not debugEnabled: return
  let t = epochTime().formatFloat(ffDecimal, 3)
  stderr.styledWriteLine(fgBlue, "[dbg ", t, "] ", msg, resetStyle)

proc debugOut*(msg, tag: string) =
  if not debugEnabled: return
  let t = epochTime().formatFloat(ffDecimal, 3)
  stderr.styledWriteLine(fgBlue, "[dbg ", t, "] ", styleBright, tag, resetStyle, fgBlue, " ", msg, resetStyle)

proc cmdResponse*(body: string) =
  ## System-command response. One blank line above and below, no
  ## indentation, default terminal color (matching LLM output).
  ## Distinguishes system feedback from model replies.
  stdout.write "\n"
  stdout.write body
  if not body.endsWith("\n"): stdout.write "\n"
  stdout.write "\n"
  stdout.flushFile

proc cmdError*(body: string) =
  ## Actionable error from a system command — non-bold magenta, no
  ## indent, blank lines above and below.
  stdout.write "\n"
  stdout.styledWrite(fgMagenta, body, resetStyle)
  if not body.endsWith("\n"): stdout.write "\n"
  stdout.write "\n"
  stdout.flushFile

proc renderHelp*() =
  ## :help body in default terminal color. `3code` highlighted bright
  ## bold cyan; `:command` tokens highlighted bright white.
  stdout.write "\n"
  for line in HelpText.splitLines:
    var i = 0
    while i < line.len:
      if i + 5 <= line.len and line[i ..< i + 5] == "3code":
        stdout.styledWrite(fgCyan, styleBright, "3code", resetStyle)
        i += 5
      elif line[i] == ':' and i + 1 < line.len and
           line[i + 1] in {'a'..'z', 'A'..'Z', '?'}:
        var j = i + 1
        while j < line.len and line[j] in {'a'..'z', 'A'..'Z', '?'}:
          inc j
        stdout.styledWrite(fgWhite, line[i ..< j], resetStyle)
        i = j
      else:
        stdout.write line[i]
        inc i
    stdout.write "\n"
  stdout.write "\n"
  stdout.flushFile

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
  outFile.write "\r\n"

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

const StreamMaxLines* = 8
  ## Maximum lines shown in the bash scroll area, both during live
  ## streaming (`StreamingView`) and in the static post-stream
  ## rendering (`printBashScroll`). Configurable so tests can shrink
  ## the viewport.

proc eraseRows(n: int) =
  ## Erase n rows above the cursor: move up, clear line, repeat.
  for _ in 0..<n:
    stdout.write "\x1b[1A\x1b[2K"

proc printStreamingLine*(line: string) =
  ## Print a single line of streaming bash output. Legacy path used
  ## by non-viewport callers.
  subtleWriteLn(stdout, "  " & line)

proc indentedRowCount(l: string): int =
  ## Number of visual terminal rows a single `printLine(l)` call
  ## occupies, accounting for soft-wrap at the terminal width. The
  ## streaming viewport needs this to erase the correct number of
  ## rows when long lines wrap (the prior implementation counted
  ## logical lines and undercounted when output wrapped).
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - 3)
  result = max(1, charWrapAnsi(l, bodyW).len)

type
  StreamingView* = object
    ## Fixed-height viewport for streaming bash output. Lines append
    ## normally until `maxLines` is reached, then the oldest line is
    ## pushed off the top to make room at the bottom.
    maxLines*: int
    idx*: int         ## tool call index for the :show hint
    total*: int       ## total lines received (not just visible)
    onScreen*: int    ## visual rows currently on screen (post-wrap)
    buf*: seq[string] ## ring buffer of last maxLines lines

proc initStreamingView*(maxLines = StreamMaxLines, idx = 0): StreamingView =
  result = StreamingView(maxLines: maxLines, idx: idx, buf: @[])

proc trimTrailingBlank(lines: var seq[string]) =
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1

proc printLine*(l: string) =
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - 3)
  let chunks = charWrapAnsi(l, bodyW)
  for i, chunk in chunks:
    subtleWriteLn(stdout, "  " & chunk)

proc omittedLine(v: StreamingView): string =
  let hidden = max(0, v.total - (v.maxLines - 1))
  let show =
    if v.idx > 0: " :show " & $v.idx & " for full"
    else: ""
  &"... {hidden} line" & (if hidden == 1: "" else: "s") &
    " omitted" & show

proc addLine*(v: var StreamingView, line: string) =
  ## Add one line to the viewport. For the first `maxLines` lines, appends
  ## normally. After that, erases the entire viewport and reprints an
  ## omission marker plus the latest tail, giving the illusion of a
  ## bounded scroll area. Visual rows are tracked separately so that
  ## wrapped long lines erase cleanly.
  inc v.total
  v.buf.add line
  if v.total <= v.maxLines:
    printLine(line)
    v.onScreen += indentedRowCount(line)
  else:
    eraseRows(v.onScreen)
    v.onScreen = 0
    let mark = omittedLine(v)
    printLine(mark)
    v.onScreen += indentedRowCount(mark)
    let tailLines = max(0, v.maxLines - 1)
    let start = max(0, v.buf.len - tailLines)
    for i in start..<v.buf.len:
      printLine(v.buf[i])
      v.onScreen += indentedRowCount(v.buf[i])
    stdout.flushFile()

proc erase*(v: var StreamingView) =
  ## Remove all on-screen rows, leaving cursor where the viewport started.
  eraseRows(v.onScreen)
  v.onScreen = 0

proc printBashScroll*(res: string, idx: int, maxLines = StreamMaxLines) =
  ## Static scroll-area render for completed bash output. Mirrors the
  ## shape of the live `StreamingView`: up to `maxLines` lines verbatim,
  ## or an "... N lines omitted" marker plus the latest (maxLines - 1)
  ## lines when the body overflows. Terminal output is uniquely
  ## understood as streaming, so this matches the live view rather than
  ## the head/tail compact used by other tool kinds.
  var lines = res.splitLines
  trimTrailingBlank(lines)
  if lines.len <= maxLines:
    for l in lines: printLine(l)
    return
  let tailLen = max(0, maxLines - 1)
  let hidden = lines.len - tailLen
  let show = if idx > 0: " :show " & $idx & " for full" else: ""
  subtleWriteLn(stdout,
    &"  ... {hidden} line" & (if hidden == 1: "" else: "s") &
    " omitted" & show)
  for i in lines.len - tailLen ..< lines.len:
    printLine(lines[i])

proc printCompactHeadTail*(res: string, idx: int,
                           head = CompactHead, tail = CompactTail) =
  ## Head/tail truncation for non-bash tool kinds that don't have the
  ## streaming-terminal semantics (read, web search, web fetch). Keeps
  ## the first `head` and last `tail` lines with an "N lines hidden"
  ## marker in the middle. Bash uses `printBashScroll` instead.
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
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 2)
    let chunks = wrapAnsi(l, bodyW)
    for chunk in chunks:
      if l.len > 0 and l[0] == '+':
        stdout.styledWriteLine fgGreen, "  " & chunk, resetStyle
      elif l.len > 0 and l[0] == '-':
        stdout.styledWriteLine fgRed, "  " & chunk, resetStyle
      else:
        subtleWriteLn(stdout, "  " & chunk)
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
  ## Body of a tool turn. bash uses the scroll-area shape via
  ## `printBashScroll` (streaming-style: marker + tail), read/web use
  ## the head/tail compact via `printCompactHeadTail`; write/patch
  ## print the headline only on success, or the first error line on
  ## failure. A non-empty `diff` is colourised after the body. Banner
  ## is drawn separately by `renderToolBanner`.
  if kind == akBash:
    printBashScroll(res, idx)
  elif kind == akRead:
    # Strip the trailing "... [N lines hidden, use offset/limit] ..."
    # markers that runAction appends for the model. The display already
    # shows the requested line range in the tool-call banner, so
    # repeating it in the body is just noise to the user.
    var lines = res.splitLines
    while lines.len > 0 and lines[^1].startsWith("... [") and
          lines[^1].endsWith("] ..."):
      lines.setLen(lines.len - 1)
    printCompactHeadTail(lines.join("\n"), idx, ReadHead, ReadTail)
  elif kind in {akWebSearch, akWebFetch}:
    printCompactHeadTail(res, idx)
  elif kind == akPlan:
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 3)
    for line in res.splitLines:
      for chunk in wrapAnsi(line, bodyW):
        subtleWriteLn(stdout, "  " & chunk)
  else:
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 3)
    if code == 0:
      for line in res.splitLines:
        for chunk in wrapAnsi(line, bodyW):
          subtleWriteLn(stdout, "  " & chunk)
    else:
      let nl = res.find('\n')
      let head = if nl < 0: res else: res[0 ..< nl]
      for chunk in wrapAnsi(head, bodyW):
        subtleWriteLn(stdout, "  " & chunk)
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
  &"{glyph}{pct}%"

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
  ## structure (headers, fences, tables, inline bold and backtick-code).
  ## Used by replay and by the live path when content was buffered (rare:
  ## streaming bypasses this and feeds the same handlers chunk by chunk).
  ## `outFile` lets tests capture output to a temp file; default is
  ## stdout.
  if content.strip.len == 0: return
  outFile.styledWrite styleBright, "● ", resetStyle
  var st = initMarkdownState()
  for line in content.splitLines:
    handleMdLine(st, line, outFile)
  finishMd(st, outFile)
  outFile.flushFile

proc toolIcon*(kind: ActionKind): string =
  case kind
  of akBash: "$"
  of akRead: "r"
  of akWrite: "w"
  of akPatch, akApplyPatch: "p"
  of akPlan: "▸"
  of akWebSearch: "⌕"
  of akWebFetch: "⇊"
  of akClear: "⟳"
  of akError: "✕"

proc renderToolPending*(banner: string, kind: ActionKind) =
  ## Pre-execution banner: grey bullet + grey banner. Live only; the live
  ## caller overwrites this line with `renderToolBanner` once the action
  ## returns. Replay skips this and goes straight to the result form.
  let icon = toolIcon(kind)
  subtleWrite(stdout, icon & " " & banner)
  stdout.write "\n"
  stdout.flushFile

proc renderToolBanner*(banner: string, kind: ActionKind, code: int, elapsedS = -1) =
  ## Final tool banner. Icons render in default text color regardless of
  ## exit code. Optional `(Ns)` suffix when `elapsedS >= 1`
  ## (live); replay passes -1 to omit it.
  let icon = if kind == akBash and code > 0: "¤" else: toolIcon(kind)
  stdout.write icon & " "
  stdout.write banner
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
  var parts: seq[string]
  if ctx.len > 0: parts.add ctx
  let ts1 = tokenSlot("↑", fresh)
  if ts1.len > 0: parts.add ts1
  let ts2 = tokenSlot("↻", usage.cachedTokens)
  if ts2.len > 0: parts.add ts2
  let ts3 = tokenSlot("↓", usage.completionTokens)
  if ts3.len > 0: parts.add ts3
  if elapsedS >= 0: parts.add $elapsedS & "s"
  result = parts.join("  ")

proc tokenLineBytes*(usage: Usage, window: int, elapsedS = -1): string =
  ## Pure-byte form of the **token receipt** row used by the *replay*
  ## path (saved sessions). The live path uses `submitTransitionBytes`
  ## which paints the receipt in place of the previous turn's bar.
  ## Returns "" when there's no usage. Trailing double `\x1b[0m` reset
  ## matches the byte sequence Nim's `styledWrite(... , "\n")` macro
  ## emits; pinned by `tests/test_golden.nim`.
  let label = tokenLineLabel(usage, window, elapsedS)
  if label.len == 0: return ""
  result = CyanFg & "  " & label & Reset & "\n" & Reset

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
  stdout.styledWriteLine fgCyan, styleBright, "  provider  ", resetStyle, provider
  stdout.styledWriteLine fgCyan, styleBright, "  model     ", resetStyle, shortModel(p.model)
  if p.reasoning != "":
    stdout.styledWriteLine fgCyan, styleBright, "  reasoning ", resetStyle, p.reasoning

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
    origDown(ed)
    if navigatedUp:
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

proc restoreCursorStyle() {.noconv.} =
  try:
    stdout.write "\x1b[0 q"
    stdout.flushFile
  except IOError: discard

proc welcome*(p: Profile): minline.LineEditor =
  setSteadyCursor()
  addExitProc(restoreCursorStyle)
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
          renderToolBanner(banner, kind, code)
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
  if rec.kind in {akBash, akRead, akWebSearch, akWebFetch}:
    for l in rec.output.splitLines: printLine(l)
  else:
    let termW = try: terminalWidth() except CatchableError: 80
    let bodyW = max(20, termW - 3)
    for line in rec.output.splitLines:
      for chunk in wrapAnsi(line, bodyW):
        if rec.code == 0:
          stdout.styledWriteLine fgGreen, "  " & chunk, resetStyle
        else:
          subtleWriteLn(stdout, "  " & chunk)

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
