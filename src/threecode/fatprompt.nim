## Pure frame model for the terminal fat prompt.
##
## This module owns no terminal file descriptors and emits no ANSI. It models
## the complete visible screen after a render tick: append-only scrollback plus
## the live prompt chrome reserved below it. Production terminal code should
## eventually become a byte backend for this state rather than issuing
## independent cursor movement from feature modules.

import std/[strformat, strutils, unicode]
import types, util

type
  PromptMarker* = enum
    pmUser, pmAssistant, pmBash, pmRead, pmWrite, pmPatch, pmOther

  TokenBarState* = object
    usage*: Usage
    window*: int
    apiActive*: bool
    spinner*: string
    elapsedS*: int

  BashViewport* = object
    active*: bool
    idx*: int
    lines*: seq[string]
    maxLines*: int

  FatPrompt* = object
    width*: int
    height*: int
    scrollback*: seq[string]
    editorText*: string
    editorCursor*: int
    tokenBar*: TokenBarState
    ticker*: string
    bash*: BashViewport

const
  DefaultWidth* = 80
  DefaultHeight* = 24
  DefaultBashMaxLines* = 8

proc initFatPrompt*(width = DefaultWidth, height = DefaultHeight,
                    window = 0): FatPrompt =
  FatPrompt(
    width: max(2, width),
    height: max(3, height),
    editorCursor: 0,
    tokenBar: TokenBarState(window: window, elapsedS: -1),
    bash: BashViewport(maxLines: DefaultBashMaxLines))

proc markerText(marker: PromptMarker): string =
  case marker
  of pmUser: "❯"
  of pmAssistant: "●"
  of pmBash: "$"
  of pmRead: "r"
  of pmWrite: "w"
  of pmPatch: "p"
  of pmOther: "·"

proc splitLogicalLines(s: string): seq[string] =
  result = s.splitLines()
  if s.len > 0 and s[^1] == '\n':
    result.add ""
  if result.len == 0:
    result.add ""

proc wrapPlain(line: string, width: int): seq[string] =
  let w = max(1, width)
  if line.len == 0:
    return @[""]
  var i = 0
  while i < line.len:
    let start = i
    var cells = 0
    while i < line.len and cells < w:
      i += max(1, runeLenAt(line, i))
      inc cells
    result.add line[start ..< i]

proc cellWidth(s: string): int =
  var i = 0
  while i < s.len:
    i += max(1, runeLenAt(s, i))
    inc result

proc wrapMarked(marker, body: string, width: int): seq[string] =
  let firstPrefix = marker & " "
  let contPrefix = repeat(" ", cellWidth(firstPrefix))
  let firstWidth = max(1, width - cellWidth(firstPrefix))
  let contWidth = max(1, width - cellWidth(contPrefix))
  var first = true
  for logical in splitLogicalLines(body):
    let chunks = wrapPlain(logical, if first: firstWidth else: contWidth)
    for chunk in chunks:
      if first:
        result.add firstPrefix & chunk
        first = false
      else:
        result.add contPrefix & chunk
  if result.len == 0:
    result.add firstPrefix

proc addTranscriptItem*(p: var FatPrompt; marker: PromptMarker;
                        body: string; receipt = "") =
  ## Append one transcript item using the spacing contract. There is exactly
  ## one blank visual row between items, and no blank row between body and
  ## token receipt.
  if p.scrollback.len > 0 and p.scrollback[^1] != "":
    p.scrollback.add ""
  for row in wrapMarked(markerText(marker), body, p.width):
    p.scrollback.add row
  if receipt.len > 0:
    for row in wrapPlain(receipt, p.width):
      p.scrollback.add row

proc addScrollLine*(p: var FatPrompt; line: string) =
  p.scrollback.add line

proc setEditor*(p: var FatPrompt; text: string; cursor = -1) =
  p.editorText = text
  if cursor < 0:
    p.editorCursor = text.len
  else:
    p.editorCursor = clamp(cursor, 0, text.len)

proc setTicker*(p: var FatPrompt; ticker: string) =
  p.ticker = ticker

proc setTokenBar*(p: var FatPrompt; usage: Usage; window: int;
                  apiActive = false; spinner = ""; elapsedS = -1) =
  p.tokenBar = TokenBarState(usage: usage, window: window,
                             apiActive: apiActive, spinner: spinner,
                             elapsedS: elapsedS)

proc contextPart(usage: Usage; window: int): string =
  if window <= 0:
    return ""
  let pct = int(usage.promptTokens.float / window.float * 100.0)
  let glyph =
    if pct < 20: "○"
    elif pct < 40: "◔"
    elif pct < 60: "◑"
    elif pct < 80: "◕"
    else: "●"
  &"{glyph}{pct}%"

proc tokenBarText*(state: TokenBarState): string =
  var parts: seq[string]
  if state.apiActive:
    parts.add if state.spinner.len > 0: state.spinner else: "○"
  let ctx = contextPart(state.usage, state.window)
  if ctx.len > 0:
    parts.add ctx
  let fresh = max(0, state.usage.promptTokens - state.usage.cachedTokens)
  let input = tokenSlot("↑", fresh)
  if input.len > 0:
    parts.add input
  let cache = tokenSlot("↻", state.usage.cachedTokens)
  if cache.len > 0:
    parts.add cache
  let output = tokenSlot("↓", state.usage.completionTokens)
  if output.len > 0:
    parts.add output
  if state.apiActive and state.elapsedS >= 0:
    parts.add $state.elapsedS & "s"
  parts.join("  ")

proc editorRows*(p: FatPrompt): seq[string] =
  wrapMarked("❯", p.editorText, p.width)

proc editorHeight*(p: FatPrompt): int =
  p.editorRows.len

proc beginBash*(p: var FatPrompt; idx = 0; maxLines = DefaultBashMaxLines) =
  p.bash = BashViewport(active: true, idx: idx, maxLines: max(1, maxLines))

proc pushBashOutput*(p: var FatPrompt; line: string) =
  if not p.bash.active:
    p.beginBash()
  p.bash.lines.add line

proc bashVisibleRows*(p: FatPrompt): seq[string] =
  if not p.bash.active:
    return @[]
  let maxLines = max(1, p.bash.maxLines)
  if p.bash.lines.len <= maxLines:
    for line in p.bash.lines:
      result.add "$ " & line
  else:
    let tailLen = max(0, maxLines - 1)
    let hidden = p.bash.lines.len - tailLen
    let show = if p.bash.idx > 0: &" :show {p.bash.idx} for full" else: ""
    result.add &"$ ... {hidden} line" &
      (if hidden == 1: "" else: "s") & " omitted" & show
    for i in p.bash.lines.len - tailLen ..< p.bash.lines.len:
      result.add "$ " & p.bash.lines[i]

proc finishBash*(p: var FatPrompt; code = 0; elapsedS = -1) =
  ## Commit the final bash tool item exactly once, replacing the live viewport.
  if not p.bash.active:
    return
  var body = p.bash.lines.join("\n")
  if code != 0:
    if body.len > 0:
      body.add "\n"
    body.add "[exit " & $code & "]"
  let suffix = if elapsedS >= 1: &"  ({elapsedS}s)" else: ""
  p.addTranscriptItem(pmBash, body & suffix)
  p.bash = BashViewport(maxLines: DefaultBashMaxLines)

proc frameRows*(p: FatPrompt): seq[string] =
  ## Return the complete visible screen for one render tick.
  let editor = p.editorRows()
  let bar = tokenBarText(p.tokenBar)
  let reserved = 1 + editor.len
  let scrollRows = max(0, p.height - reserved)
  var content = p.scrollback
  let bashRows = p.bashVisibleRows()
  if bashRows.len > 0:
    if content.len > 0 and content[^1] != "":
      content.add ""
    content.add bashRows
  if content.len > 0 and content[^1] != "":
    content.add ""
  let start = max(0, content.len - scrollRows)
  result = content[start ..< content.len]
  while result.len < scrollRows:
    result.insert("", 0)
  if p.ticker.len > 0 and scrollRows > 0:
    result[scrollRows - 1] = p.ticker
  result.add bar
  for row in editor:
    result.add row
  while result.len < p.height:
    result.insert("", 0)
  if result.len > p.height:
    result = result[result.len - p.height ..< result.len]

proc frameText*(p: FatPrompt): string =
  p.frameRows().join("\n")
