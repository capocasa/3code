## Transcript formatting: markdown, receipts, tool banners, and session replay.
##
## This module formats append-only scrollback content. It may write ordinary
## transcript text, usually while `api.writeTranscriptWithFatPrompt` has temporarily
## captured stdout or while terminal locking is already active, but it does not
## own volatile cursor movement or prompt repainting.
##
## - **Markdown rendering**: headers, fences, tables, bold/italic/code pass
##   through `handleMdLine` which calls `applyInlineMd` and wraps at terminal
##   width. Tables buffer rows and render aligned box-drawing via `renderMdTable`.
## - **Token receipt**: the cyan receipt in scroll history after each turn
##   (`renderTokenLine`). All receipts route through `receiptBytes`. Live
##   token-bar policy lives in `fatprompt.nim`.
## - **Tool banners**: per-kind glyph and path header for each tool call result.
## - **Session replay**: `replaySession` reprints a loaded session in the same
##   visual style as a live session, reusing the same render helpers.
##
## The three-tier colour palette (bold cyan for hints, plain cyan for notes,
## a dim-white for subtle FYI output) is mode-aware: the white family is
## resolved per `ColorMode` at startup (see `util.applyPalette`), so it reads
## on both light and dark backgrounds. SGR `dim` (`\x1b[2m`) is still avoided,
## since it drops below readable contrast on light backgrounds and has no
## clean mode switch.

import std/[critbits, exitprocs, json, os, strformat, strutils, terminal]
import types, util, config, prompts, session, actions, minline, toolstream
import terminal as termui

# Three visible tiers, designed to read on both light + dark terminal
# backgrounds:
#   hint/note/warn = regular white   (status, help, validation — not brand)
#   err            = non-bold magenta (never indented)
#   subtle         = dim white        (FYI: skill markers, tool output)
# Bold cyan stays on the startup screen and the live token bar only. The
# white family (`BrightWhiteFg`, `OffWhiteFg`, `GreyFg`) is resolved per
# `ColorMode` in `util.applyPalette`.

template hint*(args: varargs[untyped]) =
  stdout.styledWrite(fgDefault, args, resetStyle)

template hintLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgDefault, args, resetStyle)
  stdout.write "\r\n"

template note*(args: varargs[untyped]) =
  stdout.styledWrite(fgDefault, args, resetStyle)

template noteLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgDefault, args, resetStyle)
  stdout.write "\r\n"

template warn*(args: varargs[untyped]) =
  stdout.styledWrite(fgDefault, args, resetStyle)

template warnLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgDefault, args, resetStyle)
  stdout.write "\r\n"

template err*(args: varargs[untyped]) =
  stdout.styledWrite(fgMagenta, args, resetStyle)

template errLn*(args: varargs[untyped]) =
  stdout.styledWrite(fgMagenta, args, resetStyle)
  stdout.write "\r\n"

## String-returning counterparts of the write templates above. Command
## emitters build their transcript body with these and return it; the
## controller commits the body via the single history path. `styledWrite`
## resolves the same globals (`BrightWhiteFg` and friends) at expansion
## time, so a string built here carries the mode-resolved palette exactly
## like a direct write.
proc styleText*(args: varargs[string, `$`]): string =
  for a in args: result.add a

proc hintS*(args: varargs[string, `$`]): string =
  styleText(args)

proc hintLnS*(args: varargs[string, `$`]): string =
  styleText(args) & "\r\n"

proc noteLnS*(args: varargs[string, `$`]): string =
  styleText(args) & "\r\n"

proc errS*(args: varargs[string, `$`]): string =
  "\x1b[35m" & styleText(args) & ansiResetCode

proc errLnS*(args: varargs[string, `$`]): string =
  errS(args) & "\r\n"

func cmdResponseS*(body: string): string =
  ## String form of `cmdResponse`: blank line above and below, default
  ## color, flush left.
  result = "\n" & body
  if not body.endsWith("\n"): result.add "\n"
  result.add "\n"

func cmdErrorS*(body: string): string =
  ## String form of `cmdError`: non-bold magenta, blank lines above/below.
  result = "\n\x1b[35m" & body & ansiResetCode
  if not body.endsWith("\n"): result.add "\n"
  result.add "\n"

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

proc renderHelpS*(): string =
  ## :help body in default terminal color. `3code` highlighted bright
  ## white; `:command` tokens highlighted bright white.
  result = "\n"
  for line in HelpText.splitLines:
    var i = 0
    while i < line.len:
      if i + 5 <= line.len and line[i ..< i + 5] == "3code":
        result.add BrightWhiteFg & "3code" & ansiResetCode
        i += 5
      elif line[i] == ':' and i + 1 < line.len and
           line[i + 1] in {'a'..'z', 'A'..'Z', '?'}:
        var j = i + 1
        while j < line.len and line[j] in {'a'..'z', 'A'..'Z', '?'}:
          inc j
        # `:command` tokens in the white family: `BrightWhiteFg` so they
        # participate in light/dark mode switching (plain white is
        # invisible on a light background).
        result.add BrightWhiteFg & line[i ..< j] & Reset
        i = j
      else:
        result.add line[i]
        inc i
    result.add "\n"
  result.add "\n"

proc renderHelp*() =
  stdout.write renderHelpS()
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

# `writeTranscriptWithFatPrompt` lives in `api.nim` now — it owns
# `currentBarLabel`, the cached bar payload that drives repaint after a
# content write.
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

proc trimBoundaryBlank(lines: var seq[string]) =
  ## Strip blank rows from both ends of a tool-output line list so an item
  ## never brings its own newlines into scrollback. Only the transcript
  ## separator (one place) is allowed to insert the inter-item blank.
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1
  var start = 0
  while start < lines.len and lines[start].strip == "":
    inc start
  if start > 0:
    lines = lines[start ..< lines.len]

proc wrappedSubtleBytes(body: string; widthPad = 3): string =
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - widthPad)
  for line in body.splitLines:
    for chunk in wrapAnsi(line, bodyW):
      result.add GreyFg & "  " & chunk & Reset & "\r\n"

proc compactHeadTailBytes(res: string; idx: int;
                          head = CompactHead; tail = CompactTail): string =
  var lines = res.splitLines
  trimBoundaryBlank(lines)
  var header = 0
  if header < lines.len and lines[header].startsWith("$ "):
    result.add wrappedSubtleBytes(lines[header])
    inc header
  var footer = lines.len
  if footer > 0 and lines[footer-1].startsWith("[exit "):
    dec footer
  let bodyLen = footer - header
  let hidden = bodyLen - head - tail
  if hidden <= head + tail + 1:
    for i in header ..< footer:
      result.add wrappedSubtleBytes(lines[i])
  else:
    for i in header ..< header + head:
      result.add wrappedSubtleBytes(lines[i])
    result.add GreyFg & "  … " & $hidden & " line" &
      (if hidden == 1: "" else: "s") &
      " hidden · :show " & $idx & " for full …" & Reset & "\r\n"
    for i in footer - tail ..< footer:
      result.add wrappedSubtleBytes(lines[i])
  if footer < lines.len:
    result.add wrappedSubtleBytes(lines[footer])

proc addDiffPainted(outBytes: var string; l: string) =
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - 2)
  for chunk in wrapAnsi(l, bodyW):
    if l.len > 0 and l[0] == '+':
      outBytes.add ansiForegroundColorCode(fgGreen) & "  " & chunk &
        ansiResetCode & "\r\n"
    elif l.len > 0 and l[0] == '-':
      outBytes.add ansiForegroundColorCode(fgRed) & "  " & chunk &
        ansiResetCode & "\r\n"
    else:
      outBytes.add GreyFg & "  " & chunk & Reset & "\r\n"

proc diffBytes(diff: string): string =
  const DiffHead = 15
  const DiffTail = 20
  var lines = diff.splitLines
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1
  if lines.len == 0:
    return ""
  if lines.len <= DiffHead + DiffTail + 2:
    for l in lines:
      result.addDiffPainted(l)
    return
  for i in 0 ..< DiffHead:
    result.addDiffPainted(lines[i])
  result.add GreyFg & "  … " & $(lines.len - DiffHead - DiffTail) &
    " line" & (if lines.len - DiffHead - DiffTail == 1: "" else: "s") &
    " hidden · `git diff` for full …" & Reset & "\r\n"
  for i in lines.len - DiffTail ..< lines.len:
    result.addDiffPainted(lines[i])

proc firstDiffLine(diff: string): string =
  for line in diff.splitLines:
    if line.strip.len > 0:
      return line
  ""

proc diffBytesSkippingFirst(diff: string): string =
  var skipped = false
  var rest: seq[string]
  for line in diff.splitLines:
    if not skipped and line.strip.len > 0:
      skipped = true
      continue
    if skipped:
      rest.add line
  diffBytes(rest.join("\n"))

proc planStatusGlyph(status: string): string =
  case status
  of "completed": "✓"
  of "in_progress": "~"
  else: "○"

proc planResultBytes*(plan: seq[PlanItem]): string =
  ## One item per line, glyph-prefixed. The single renderer for plan
  ## output - used by `planTranscriptBytes` (live transcript) and `showTool`
  ## so a plan looks identical whether it just ran or was scrolled back to.
  for item in plan:
    result.add GreyFg & "  " & planStatusGlyph(item.status) & " " &
      item.text & Reset & "\r\n"

proc planTranscriptBytes(act: Action): string =
  result.add "≡ ──────────\r\n"
  result.add planResultBytes(act.plan)

proc clearTranscriptBytes(act: Action): string =
  result.add "═════════════════════════════════════════\r\n"
  result.add "↻ " & act.body.strip & "\r\n"

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

template AssistantTextStyle*: string = BrightWhiteFg
  ## Active assistant-text SGR (the white-family color for LLM output).
  ## A template so it re-reads the mode-resolved `BrightWhiteFg` var at
  ## each use instead of snapshotting it at compile time.

proc assistantTextBytes*(bytes: string): string =
  if bytes.len == 0:
    return ""
  var body = bytes
  var tail = ""
  while body.len > 0 and body[^1] in {'\r', '\n'}:
    tail.insert($body[^1], 0)
    body.setLen(body.len - 1)
  let styled = body
    .replace(Reset, Reset & AssistantTextStyle)
    .replace("\x1b[22m", "\x1b[22m" & AssistantTextStyle)
  AssistantTextStyle & styled & Reset & tail

proc captureMarkdownBytes(s: MarkdownState; line = ""; finish = false): string =
  let path = getTempDir() / "3code_assistant_md_" & $getCurrentProcessId()
  let f = open(path, fmWrite)
  defer: close(f)
  if finish:
    discard finishMd(s, f)
  else:
    discard handleMdLine(s, line, f)
  f.flushFile
  defer:
    try: removeFile(path) except OSError: discard
  result = readFile(path)

proc writeAssistantBullet*(outFile: File = stdout) =
  outFile.write AssistantTextStyle & "● " & Reset

proc renderAssistantContent*(content: string, outFile: File = stdout) =
  ## Bullet `● ` + bright-white content with full markdown
  ## structure (headers, fences, tables, inline bold and backtick-code).
  ## Used by replay and by the live path when content was buffered (rare:
  ## streaming bypasses this and feeds the same handlers chunk by chunk).
  ## `outFile` lets tests capture output to a temp file; default is
  ## stdout.
  if content.strip.len == 0: return
  writeAssistantBullet(outFile)
  var st = initMarkdownState()
  for line in content.splitLines:
    outFile.write assistantTextBytes(captureMarkdownBytes(st, line))
  outFile.write assistantTextBytes(captureMarkdownBytes(st, finish = true))
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

proc toolBannerBytes*(banner: string; kind: ActionKind; code: int;
                      elapsedS = -1): string =
  let icon = if kind == akBash and code > 0: "Ø" else: toolIcon(kind)
  let suffix = if elapsedS >= 1: GreyFg & &"  ({elapsedS}s)" & Reset else: ""
  let termW = try: terminalWidth() except CatchableError: 80
  let rows = bannerWrapRows(icon & " ", banner, termW)
  for i, row in rows:
    result.add OffWhiteFg & row & Reset
    if i == rows.high:
      result.add suffix
    result.add "\r\n"

proc toolResultBytes*(kind: ActionKind; res: string; code: int; idx: int;
                      diff = ""): string =
  if kind == akBash:
    var lines = res.splitLines
    trimBoundaryBlank(lines)
    if lines.len <= StreamMaxLines:
      for l in lines:
        result.add wrappedSubtleBytes(l)
    else:
      let tailLen = max(0, StreamMaxLines - 1)
      let hidden = lines.len - tailLen
      result.add GreyFg & "  ... " & $hidden & " line" &
        (if hidden == 1: "" else: "s") & " omitted" &
        (if idx > 0: " :show " & $idx & " for full" else: "") &
        Reset & "\r\n"
      for i in lines.len - tailLen ..< lines.len:
        result.add wrappedSubtleBytes(lines[i])
  elif kind == akRead:
    var lines = res.splitLines
    while lines.len > 0 and lines[^1].startsWith("... [") and
          lines[^1].endsWith("] ..."):
      lines.setLen(lines.len - 1)
    result.add compactHeadTailBytes(lines.join("\n"), idx, ReadHead, ReadTail)
  elif kind == akWrite:
    result.add compactHeadTailBytes(diff, idx, ReadHead, ReadTail)
  elif kind in {akWebSearch, akWebFetch}:
    result.add compactHeadTailBytes(res, idx)
  else:
    if code == 0:
      result.add wrappedSubtleBytes(res)
    else:
      let nl = res.find('\n')
      let head = if nl < 0: res else: res[0 ..< nl]
      result.add wrappedSubtleBytes(head)
  if diff.len > 0 and kind notin {akWrite, akRead}:
    result.add diffBytes(diff)

proc toolTranscriptBytes*(banner: string; kind: ActionKind; res: string;
                          code: int; idx: int; diff = "";
                          elapsedS = -1): string =
  result.add toolBannerBytes(banner, kind, code, elapsedS)
  result.add toolResultBytes(kind, res, code, idx, diff)

proc toolTranscriptBytes*(act: Action; res: string; code: int; idx: int;
                          diff = ""; elapsedS = -1): string =
  case act.kind
  of akWrite:
    result.add toolBannerBytes(bannerFor(act), act.kind, code, elapsedS)
    if code == 0 and diff.len > 0:
      result.add compactHeadTailBytes(diff, idx, ReadHead, ReadTail)
    else:
      result.add toolResultBytes(act.kind, res, code, idx, diff = "")
  of akPatch, akApplyPatch:
    let first = firstDiffLine(diff)
    let banner = if first.len > 0: first else: bannerFor(act)
    result.add toolBannerBytes(banner, act.kind, code, elapsedS)
    if code != 0:
      result.add toolResultBytes(act.kind, res, code, idx, diff = "")
    elif diff.len > 0:
      result.add diffBytesSkippingFirst(diff)
    else:
      result.add toolResultBytes(act.kind, res, code, idx, diff = "")
  of akPlan:
    result.add planTranscriptBytes(act)
  of akClear:
    result.add clearTranscriptBytes(act)
  of akError:
    result.add "✕ unknown tool: " & act.path & "\r\n"
  else:
    result.add toolTranscriptBytes(
      bannerFor(act), act.kind, res, code, idx, diff, elapsedS)

proc tokenLineLabel*(usage: Usage, window: int, elapsedS = -1): string =
  ## Pure label string for the bar / receipt: "○N%  ↑input  ↻cached
  ## ↓completion  Ts" (no styling, no leading spaces — caller wraps
  ## it in cyan-bright for the bar or cyan for the receipt). Empty
  ## when there's no usage to report.
  if usage.totalTokens <= 0: return ""
  let ctx = contextLabel(usage.promptTokens, window)
  var parts: seq[string]
  if ctx.len > 0: parts.add ctx
  let ts1 = tokenSlot("↑", usage.promptTokens)
  if ts1.len > 0: parts.add ts1
  let ts2 = tokenSlot("↻", usage.cachedTokens)
  if ts2.len > 0: parts.add ts2
  let ts3 = tokenSlot("↓", usage.completionTokens)
  if ts3.len > 0: parts.add ts3
  if elapsedS >= 0: parts.add $elapsedS & "s"
  result = parts.join("  ")

proc receiptBytes*(label: string): string =
  ## The single canonical styling for a token receipt row (two-space
  ## indent, cyan fg). Every receipt in the app, live or replay, goes
  ## through here so there is exactly one color for receipts. Returns
  ## "" for an empty label.
  if label.len == 0: return ""
  CyanFg & "  " & label & Reset

proc tokenLineBytes*(usage: Usage, window: int, elapsedS = -1): string =
  ## Pure-byte form of the **token receipt** row used by the *replay*
  ## path (saved sessions). The live path uses `emitUserSubmit` /
  ## `commitTranscriptBytes`, which paint the receipt in place of the
  ## previous turn's bar.
  ## Returns "" when there's no usage.
  let label = tokenLineLabel(usage, window, elapsedS)
  if label.len == 0: return ""
  result = receiptBytes(label) & "\n" & Reset

proc renderTokenLine*(usage: Usage, window: int, elapsedS = -1) =
  ## "○N%  ↑Nk  ↻Nk  ↓Nk  Ts": context glyph, fresh, cached, generated,
  ## optional duration. Two-space separation, no padding inside slots.
  ## Empty when usage has no totals. Live passes seconds; replay passes
  ## -1 to omit the duration.
  let bytes = tokenLineBytes(usage, window, elapsedS)
  if bytes.len > 0:
    stdout.write bytes

proc profileLinesS*(p: Profile; bold = false): string =
  ## String form of `showProfile`: provider/model/reasoning rows with
  ## bright-white values and default (or bold cyan) labels.
  if p.name == "": return
  let dot = p.name.find('.')
  let provider = if dot < 0: p.name else: p.name[0 ..< dot]
  let labelOn = if bold: "\x1b[36m\x1b[1m" else: ""
  let pad = if bold: "  " else: ""
  result.add labelOn & pad & "provider  " & ansiResetCode &
    BrightWhiteFg & provider & ansiResetCode & "\r\n"
  result.add labelOn & pad & "model     " & ansiResetCode &
    BrightWhiteFg & shortModel(p.model) & ansiResetCode & "\r\n"
  if p.reasoning != "":
    result.add labelOn & pad & "reasoning " & ansiResetCode &
      BrightWhiteFg & p.reasoning & ansiResetCode & "\r\n"

proc showProfile*(p: Profile; bold = false) =
  let s = profileLinesS(p, bold)
  if s.len > 0:
    stdout.write s
    stdout.flushFile

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

proc welcome*(p: Profile): minline.LineEditor =
  termui.setSteadyCursor()
  addExitProc(termui.restoreCursorStyle)
  stdout.write "\n"
  stdout.styledWriteLine fgCyan, styleBright, "  ╭─╮"
  stdout.styledWrite fgCyan, styleBright, "   ─┤  ", resetStyle, styleBright, "3code ", resetStyle, fgCyan, styleBright, "v" & Version, resetStyle
  subtleWriteLn(stdout, "   the economical coding agent")
  stdout.styledWriteLine fgCyan, styleBright, "  ╰─╯"
  stdout.write "\n"
  if p.name != "":
    showProfile(p, bold = true)
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
    let id = c.provider & "." & c.model
    if id.len > maxId: maxId = id.len
  for c in KnownGoodCombos:
    let id = c.provider & "." & c.model
    let v =
      if c.version.len > 0 and c.variant.len > 0: c.version & "." & c.variant
      elif c.version.len > 0: c.version
      else: c.variant
    let tag = if v.len > 0: c.family & " " & v else: c.family
    echo "  ", id.alignLeft(maxId), "  ", tag
  echo ""
  echo "pass any of these to --model, e.g. 3code --model ", KnownGoodCombos[0].provider,
       ".", KnownGoodCombos[0].model
  echo "other combos require --experimental."

const SessionListCap* = 20
  ## Newest sessions shown by `printSessionList` / `-l` / `:sessions`.
  ## Paths arrive newest-first from `listSessionPaths`, so the cap is a
  ## simple slice. Listing is directory-scoped by design; the full set
  ## lives under `sessionDir()` for anyone who needs it.

proc printSessionListS*(paths: seq[string], currentPath: string,
                        showCwd: bool): string =
  ## String form of the `:sessions` / `-l` listing.
  let shown = paths[0 ..< min(paths.len, SessionListCap)]
  for p in shown:
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
    result.add &"  {mark} " & id &
      &"   ({preview.msgCount} msg" & (if preview.msgCount == 1: "" else: "s") & ")" &
      cwdStr & snip & "\r\n"
  if paths.len > shown.len:
    let dir = collapseHome(sessionDir())
    result.add &"  …  {shown.len} of {paths.len}  (more in {dir})\r\n"

proc printSessionList*(paths: seq[string], currentPath: string, showCwd: bool) =
  stdout.write printSessionListS(paths, currentPath, showCwd)
  stdout.flushFile

proc replaySessionTail*(messages: JsonNode, toolLog: seq[ToolRecord],
                       window: int, family: string): Usage =
  ## Replay the whole conversation into scrollback so a resumed session drops
  ## the user back into the full prior context, reachable by scrolling up.
  ## The session file is already bounded by compaction to roughly one context
  ## window, so replaying it in full stays manageable. Renders via the same
  ## helpers the live path uses; usage is read from each assistant message's
  ## inline `usage` field (legacy sessions saved before the inline format
  ## simply skip the token line). The last assistant's inline receipt is
  ## suppressed and its usage is returned instead — the caller paints the
  ## live token bar with it, so the resumed shape matches the post-`endTurn`
  ## typing-ready state.
  if messages == nil or messages.kind != JArray or messages.len == 0: return
  # Start at the first non-system message: the `case` below discards the
  # system message anyway, but skipping it keeps the leading separator clean.
  var start = 0
  while start < messages.len and messages[start]{"role"}.getStr == "system":
    inc start
  if start >= messages.len: return
  var lastAssistant = -1
  for i in countdown(messages.len - 1, start):
    if messages[i]{"role"}.getStr == "assistant":
      lastAssistant = i
      break
  var toolIdx = 0
  for i in start ..< messages.len:
    let m = messages[i]
    case m{"role"}.getStr
    of "user":
      let c = stripPreamble(m{"content"}.getStr("")).strip
      if c.len == 0: continue
      let shown = if c.len > 400: c[0 ..< 400] & " …" else: c
      let userLines = shown.splitLines
      for idx, l in userLines:
        let prefix = if idx == 0: "❯ " else: "  "
        stdout.write prefix & l & "\n"
      stdout.write "\n"
    of "assistant":
      let c = m{"content"}.getStr("").strip
      if c.len > 0:
        renderAssistantContent(c)
      let u = usageFromJson(m{"usage"})
      if i == lastAssistant:
        result = u
      elif u.totalTokens > 0:
        renderTokenLine(u, window)
      stdout.write "\n"
      let tcs = m{"tool_calls"}
      let hasTools = tcs != nil and tcs.kind == JArray and tcs.len > 0
      if hasTools:
        for tc in tcs:
          inc toolIdx
          var banner = ""
          var code = 0
          var output = ""
          var kind = akBash
          var plan: seq[PlanItem] = @[]
          if toolIdx <= toolLog.len:
            let rec = toolLog[toolIdx - 1]
            banner = rec.banner
            code = rec.code
            output = rec.output
            kind = rec.kind
            plan = rec.plan
          else:
            let fn = tc{"function"}
            let name = if fn != nil: fn{"name"}.getStr else: "?"
            let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
            let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                       except CatchableError: newJObject()
            let act = toolCallToAction(family, name, args)
            banner = bannerFor(act)
            kind = act.kind
            plan = act.plan
          # Route through the SAME byte builders the live path uses
          # (toolTranscriptBytes / planTranscriptBytes) so a replayed tool
          # looks byte-identical to how it rendered live. The banner is the
          # stored one (or bannerFor for the no-toolLog fallback); the body
          # comes from the shared per-kind renderer.
          if kind == akPlan and plan.len > 0:
            let act = Action(kind: akPlan, plan: plan)
            stdout.write planTranscriptBytes(act)
          else:
            stdout.write toolTranscriptBytes(
              banner, kind, output, code, toolIdx)
          stdout.write "\n"
    of "tool":
      # Result already rendered alongside the assistant's tool_call via
      # toolLog; nothing to do here.
      discard
    else: discard
  stdout.flushFile

proc showToolS*(arg: string, toolLog: seq[ToolRecord]): string =
  ## String form of the `:show` body (same byte builders as the live path).
  if toolLog.len == 0:
    return hintLnS("no tool calls yet")
  var n = toolLog.len
  if arg != "":
    try: n = parseInt(arg)
    except ValueError:
      return errLnS("show: not a number: " & arg)
  if n < 1 or n > toolLog.len:
    return errLnS(&"show: T{n} out of range (1..{toolLog.len})")
  let rec = toolLog[n-1]
  result = &"── T{n}  " & rec.banner & "\r\n"
  if rec.kind == akPlan and rec.plan.len > 0:
    result.add planResultBytes(rec.plan)
  else:
    result.add toolResultBytes(rec.kind, rec.output, rec.code, n)

proc showTool*(arg: string, toolLog: seq[ToolRecord]) =
  stdout.write showToolS(arg, toolLog)
  stdout.flushFile

proc listToolsS*(toolLog: seq[ToolRecord]): string =
  ## String form of the `:log` body.
  if toolLog.len == 0:
    return hintLnS("no tool calls yet")
  for i, rec in toolLog:
    let tag = &"T{i+1}"
    let lines = rec.output.splitLines.len
    let mark = if rec.code == 0: "✓" else: "✗"
    let colorOn = if rec.code == 0: "\x1b[32m" else: ""
    result.add &"  {tag:>4}  " & colorOn & mark & ansiResetCode & " " &
      rec.banner &
      &"   ({lines} line" & (if lines == 1: "" else: "s") & ")" & "\r\n"

proc listTools*(toolLog: seq[ToolRecord]) =
  stdout.write listToolsS(toolLog)
  stdout.flushFile
