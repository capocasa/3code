## Fat-prompt state, visual model, and byte templates.
##
## This module owns the policy for prompt chrome: prompt rows, token bar,
## thinking ticker state, spacing, receipts, and the visual frame model used by
## tests. It may construct ANSI byte templates for those prompt frames, but it
## does not write them. `terminal.nim` is the only module that serializes those
## bytes to the terminal.

import std/[strformat, strutils, terminal, unicode]
import ../types, ../util
import ../unicodewidth

type
  PromptMode* = enum
    pmIdle,
    pmTurnRunning,
    pmBufferedInput

  PendingHint* = object
    active*: bool
    usage*: Usage
    window*: int
    elapsed*: int

  FooterState* = object
    promptMode*: PromptMode
    barLabel*: string
    hasGap*: bool
    ticker*: string
    pendingHint*: PendingHint

  FatPromptState* = object
    footer*: FooterState

  FatPromptEventKind* = enum
    fpeSetPromptMode,
    fpeSetBar,
    fpeClearBar,
    fpeSetTicker,
    fpeClearTicker,
    fpeSetPendingHint,
    fpeClearPendingHint

  FatPromptEvent* = object
    case kind*: FatPromptEventKind
    of fpeSetPromptMode:
      promptMode*: PromptMode
    of fpeSetBar:
      barLabel*: string
      barHasGap*: bool
    of fpeSetTicker:
      ticker*: string
    of fpeSetPendingHint:
      usage*: Usage
      window*: int
      elapsed*: int
    of fpeClearBar, fpeClearTicker, fpeClearPendingHint:
      discard

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

  FatPromptGeometry* = object
    ## Width-aware size of the volatile fat-prompt area.
    tickerRows*: int
    hasBar*: bool
    barRows*: int
    editorRows*: int
    reservedRows*: int

  FooterFrameKind* = enum
    ffNone,
    ffClear,
    ffTokenBar,
    ffSpinner

  FooterFrame* = object
    ## Semantic footer view. Runtime code constructs this value; the terminal
    ## engine is responsible for lowering it to terminal bytes and using the
    ## same value for geometry.
    kind*: FooterFrameKind
    ticker*: string
    label*: string
    spinner*: string
    elapsed*: int
    clearRows*: int

const
  DefaultWidth* = 80
  DefaultHeight* = 24
  DefaultBashMaxLines* = 8
  EditorPromptBytes* = "❯ "
  DeferredSubmitMarker* = "⧖"

proc initFatPromptState*(): FatPromptState =
  FatPromptState(footer: FooterState(promptMode: pmIdle))

proc setPromptModeEvent*(mode: PromptMode): FatPromptEvent =
  FatPromptEvent(kind: fpeSetPromptMode, promptMode: mode)

proc setBarEvent*(label: string; hasGap = false): FatPromptEvent =
  FatPromptEvent(kind: fpeSetBar, barLabel: label, barHasGap: hasGap)

proc clearBarEvent*(): FatPromptEvent =
  FatPromptEvent(kind: fpeClearBar)

proc setTickerEvent*(ticker: string): FatPromptEvent =
  FatPromptEvent(kind: fpeSetTicker, ticker: ticker)

proc clearTickerEvent*(): FatPromptEvent =
  FatPromptEvent(kind: fpeClearTicker)

proc setPendingHintEvent*(usage: Usage; window, elapsed: int): FatPromptEvent =
  FatPromptEvent(kind: fpeSetPendingHint, usage: usage, window: window,
                 elapsed: elapsed)

proc clearPendingHintEvent*(): FatPromptEvent =
  FatPromptEvent(kind: fpeClearPendingHint)

proc apply*(s: var FatPromptState; ev: FatPromptEvent) =
  case ev.kind
  of fpeSetPromptMode:
    s.footer.promptMode = ev.promptMode
  of fpeSetBar:
    s.footer.barLabel = ev.barLabel
    s.footer.hasGap = ev.barHasGap
  of fpeClearBar:
    s.footer.barLabel = ""
    s.footer.hasGap = false
  of fpeSetTicker:
    s.footer.ticker = ev.ticker
  of fpeClearTicker:
    s.footer.ticker = ""
  of fpeSetPendingHint:
    s.footer.pendingHint = PendingHint(active: true, usage: ev.usage,
                                       window: ev.window,
                                       elapsed: ev.elapsed)
  of fpeClearPendingHint:
    s.footer.pendingHint = PendingHint()

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
    while i < line.len and cells + runeCellWidth(line.runeAt(i)) <= w:
      cells += runeCellWidth(line.runeAt(i))
      i += max(1, runeLenAt(line, i))
    if i == start:  # single rune wider than w: emit it anyway
      i += max(1, runeLenAt(line, i))
    result.add line[start ..< i]

proc cellWidth(s: string): int =
  var i = 0
  while i < s.len:
    inc result, runeCellWidth(s.runeAt(i))
    i += max(1, runeLenAt(s, i))

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
  let input = tokenSlot("↑", state.usage.promptTokens)
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

proc hasNonNewlineBytes*(s: string): bool =
  for ch in s:
    if ch notin {'\r', '\n'}:
      return true

proc hasElapsedSuffix*(label: string): bool =
  var i = label.len - 1
  if i < 0 or label[i] != 's':
    return false
  dec i
  if i < 0 or not label[i].isDigit:
    return false
  while i >= 0 and label[i].isDigit:
    dec i
  i >= 0 and label[i] == ' '

proc spinnerBarBytes*(frame, label: string, elapsed: int): string =
  let timedLabel =
    if label.hasElapsedSuffix: label
    else: label & " " & $elapsed & "s"
  CyanFg & BoldOn & frame & Reset & CyanFg & BoldOn & " " &
    timedLabel & Reset

proc liveBarBytes*(label: string): string =
  CyanFg & BoldOn & "  " & label & Reset

proc labelCells*(label: string): int =
  var i = 0
  while i < label.len:
    let rl = max(1, runeLenAt(label, i))
    inc result
    i += rl

proc barWrapRows*(visibleCells, termW: int): int =
  if termW <= 0 or visibleCells <= 0: return 1
  result = (visibleCells + termW - 1) div termW
  if result < 1: result = 1

proc noFooterFrame*(): FooterFrame =
  FooterFrame(kind: ffNone)

proc clearFooterFrame*(rows = 1): FooterFrame =
  FooterFrame(kind: ffClear, clearRows: max(1, rows))

proc tokenBarFrame*(label: string; ticker = ""): FooterFrame =
  if label.len == 0:
    noFooterFrame()
  else:
    FooterFrame(kind: ffTokenBar, label: label, ticker: ticker)

proc spinnerFooterFrame*(spinner, label, ticker: string; elapsed: int): FooterFrame =
  FooterFrame(kind: ffSpinner, spinner: spinner, label: label,
              ticker: ticker, elapsed: elapsed)

proc footerFrame*(s: FatPromptState): FooterFrame =
  tokenBarFrame(s.footer.barLabel, s.footer.ticker)

proc rowsAboveEditor*(frame: FooterFrame; termW = 0): int =
  case frame.kind
  of ffNone:
    result = 0
  of ffClear:
    result = max(1, frame.clearRows)
  of ffTokenBar:
    result = barWrapRows(2 + labelCells(frame.label), termW)
    if frame.ticker.len > 0:
      inc result
  of ffSpinner:
    let elapsedTextLen = if frame.elapsed >= 0: ($frame.elapsed).len else: 1
    result = barWrapRows(labelCells(frame.label) + 4 + elapsedTextLen, termW)
    if frame.ticker.len > 0:
      inc result

proc spinnerFooterBytes*(frame, label, ticker: string, elapsed: int,
                         termW = 0): string =
  let barCells = labelCells(label) + 4 + ($elapsed).len
  let barRows = barWrapRows(barCells, termW)
  result = "\x1b[?25l\r\x1b[2K"
  if ticker.len > 0:
    result.add GreyFg
    result.add ticker
    result.add Reset
  result.add "\r\n\x1b[2K"
  result.add spinnerBarBytes(frame, label, elapsed)
  result.add "\r\n\x1b[2K" & EditorPromptBytes
  result.add "\r\x1b[" & $barRows & "A"

proc liveEditorSpinnerBarBytes*(frame, label: string, elapsed: int): string =
  "\r\x1b[2K" & spinnerBarBytes(frame, label, elapsed)

proc spinnerCleanupBytes*(tickerRows = 1): string =
  let rows = max(1, tickerRows)
  "\r\x1b[" & $rows & "A\x1b[J\n"

proc paintBarBytes*(label: string): string =
  "\r\x1b[2K" & liveBarBytes(label)

proc barFooterBytes*(label: string, termW = 0): string =
  let barRows = barWrapRows(2 + labelCells(label), termW)
  paintBarBytes(label) &
    "\r\n\x1b[2K" & EditorPromptBytes &
    "\r\x1b[" & $barRows & "A"

const ClearBarPromptBytes* = "\r\x1b[J"

proc barFooterBelowAtColBytes*(label: string; col: int; termW = 0): string =
  let barRows = barWrapRows(2 + labelCells(label), termW)
  "\r\n\x1b[2K" & liveBarBytes(label) &
    "\r\n\x1b[2K" & EditorPromptBytes &
    "\x1b[" & $(barRows + 1) & "A\x1b[" & $(max(0, col) + 1) & "G"

proc barFooterBelowBytes*(label: string; termW = 0): string =
  barFooterBelowAtColBytes(label, 2, termW)

proc clearBarBelowAtColBytes*(col: int): string =
  "\n\r\x1b[J\x1b[1A\x1b[" & $(max(0, col) + 1) & "G"

const ClearBarBelowBytes* = "\n\r\x1b[J\x1b[1A\x1b[3G"

proc receiptBarBytes*(label: string): string =
  if label.len == 0: return ""
  CyanFg & "  " & label & Reset

proc clampToWidth*(s: string; width: int): string =
  ## Truncate `s` (which may contain ANSI CSI escapes) so its visible
  ## width fits in `width` cells. Escapes are preserved; once the
  ## accumulated visible width reaches `width` the remainder is dropped.
  if width <= 0:
    return ""
  var vis = 0
  var i = 0
  while i < s.len and vis < width:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      let escStart = i
      i += 2
      while i < s.len and s[i] notin {'A'..'Z', 'a'..'z'}:
        inc i
      if i < s.len: inc i
      result.add s[escStart ..< i]
      continue
    let rl = max(1, runeLenAt(s, i))
    let cw = runeCellWidth(s.runeAt(i))
    if vis + cw > width:
      break
    result.add s[i ..< i + rl]
    inc vis, cw
    inc i, rl

proc liveEditorSpinnerFooterBytes*(frame, label, ticker: string;
                                   elapsed: int; termW = 0): string =
  if ticker.len > 0:
    let shown = if termW > 0: clampToWidth(ticker, termW) else: ticker
    result.add "\r\x1b[2K"
    result.add GreyFg
    result.add shown
    result.add Reset
    result.add "\r\n"
  result.add liveEditorSpinnerBarBytes(frame, label, elapsed)

proc clearSpinnerFooterBytes*(hadTicker: bool): string =
  if hadTicker:
    "\r\x1b[2K\r\n\x1b[2K"
  else:
    "\r\x1b[2K"

proc footerFrameBytes*(frame: FooterFrame; termW = 0): string =
  case frame.kind
  of ffNone:
    result = ""
  of ffClear:
    result = "\r\x1b[2K"
    for _ in 1 ..< max(1, frame.clearRows):
      result.add "\r\n\x1b[2K"
  of ffTokenBar:
    if frame.ticker.len == 0:
      result = paintBarBytes(frame.label)
    else:
      let shown = if termW > 0: clampToWidth(frame.ticker, termW) else: frame.ticker
      result = "\r\x1b[2K" & GreyFg & shown & Reset & "\r\n" &
        paintBarBytes(frame.label)
  of ffSpinner:
    result = liveEditorSpinnerFooterBytes(frame.spinner, frame.label,
                                          frame.ticker, frame.elapsed, termW)

proc addUserEcho(result: var string, line: string; trailingNewline = true) =
  let termW = try: terminalWidth() except CatchableError: 0
  let lines = line.splitLines
  for idx, l in lines:
    let prefix = if idx == 0: "❯ " else: "  "
    result.add prefix
    if termW <= 0:
      result.add l
    else:
      var col = 2
      var i = 0
      while i < l.len:
        let rl = max(1, runeLenAt(l, i))
        let w = runeCellWidth(l.runeAt(i))
        if col + w > termW:
          result.add "\r\n  "
          col = 2
        result.add l[i ..< i + rl]
        inc col, w
        i += rl
    if trailingNewline or idx < lines.high:
      result.add "\r\n"

proc formatUserPromptItem*(line: string): string =
  ## Format a user prompt as a scrollback item body. No trailing separator is
  ## included; the controller/transcript emitter owns inter-item spacing.
  result.addUserEcho(line, trailingNewline = false)

proc promptOnlyBytes*(): string =
  "\r\x1b[2K" & EditorPromptBytes & "\r"

proc promptOnlyResetBytes*(): string =
  "\x1b[2K" & EditorPromptBytes & "\r"

proc clearPromptAfterPendingReceiptBytes*(): string =
  "\r\x1b[1A\x1b[J"

proc clearBarRowBytes*(): string =
  "\r\x1b[2K"

proc footerRowsAboveEditor*(s: FatPromptState): int =
  if s.footer.barLabel.len == 0:
    return 0
  result = 1
  if s.footer.ticker.len > 0:
    inc result

proc tokenBarRows*(s: FatPromptState; termW = 0): int =
  ## Number of terminal rows occupied by the current token bar.
  if s.footer.barLabel.len == 0: 0
  else: barWrapRows(2 + labelCells(s.footer.barLabel), termW)

proc footerGeometry*(s: FatPromptState; editorRows: int; termW = 0): FatPromptGeometry =
  ## Size of the reserved fat-prompt area: ticker, token bar, and editor rows.
  let barRows = tokenBarRows(s, termW)
  # Always reserve the ticker row to match frameRows: an empty gap between
  # scrollback and the token bar reads better than flush adjacency, whether or
  # not a thinking ticker is active.
  let tickerRows = 1
  result = FatPromptGeometry(
    tickerRows: tickerRows,
    hasBar: barRows > 0,
    barRows: barRows,
    editorRows: max(1, editorRows))
  result.reservedRows = result.tickerRows + result.barRows + result.editorRows

proc footerFrameBytes*(s: FatPromptState; termW = 0): string =
  ## Complete token-bar + prompt placeholder frame for the current state.
  if s.footer.barLabel.len == 0: ""
  else: barFooterBytes(s.footer.barLabel, termW)

proc hideRealCaretBytes*(): string =
  "\x1b[?25l"

proc endTurnBytes*(label: string; repaintPrompt: bool,
                   termW = 0; gapAlready = false): string =
  if label.len > 0:
    result.add ClearBarPromptBytes
    if repaintPrompt:
      if not gapAlready:
        result.add "\n"
      result.add barFooterBytes(label, termW)
      let rows = barWrapRows(2 + labelCells(label), termW)
      result.add "\x1b[" & $rows & "B"
  result.add "\x1b[?25h"

proc liveEditorBarTickFrame*(label: string): string =
  paintBarBytes(label)

proc absoluteBarTickFrame*(row: int; label: string; activeEditor: bool;
                           termW = 0): string =
  let pos = "\x1b[" & $row & ";1H"
  if activeEditor:
    "\x1b[?25l" & pos & paintBarBytes(label)
  else:
    "\x1b[?25l" & pos & barFooterBytes(label, termW)

proc moveToBarBelowBytes*(): string =
  "\x1b[1B"

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
  # Always reserve the ticker row, even when no thinking ticker is active.
  # Scrollback sitting flush against the token bar never reads well; the gap
  # the ticker normally provides is wanted whether or not a ticker is running.
  let tickerRows = 1
  let reserved = tickerRows + 1 + editor.len
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
  result.add if p.ticker.len > 0: p.ticker else: ""
  result.add bar
  for row in editor:
    result.add row
  while result.len < p.height:
    result.insert("", 0)
  if result.len > p.height:
    result = result[result.len - p.height ..< result.len]

proc frameText*(p: FatPrompt): string =
  p.frameRows().join("\n")
