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
import ../minline

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

  AnimationMode* = enum
    amIdle,     # nothing animating (no spinner, no bar-tick)
    amSpinner,  # spinner running (reasoning / waiting for first content)
    amBarTick   # bar-tick running (tool executing)

  ViewportSnapshot* = object
    ## Raw inputs needed to re-wrap the bash tool viewport at the live
    ## terminal width. The controller pushes a snapshot; the GUI thread
    ## re-derives `viewportRows` from it each tick so a resize between
    ## output lines re-wraps instead of replaying stale pre-wrap rows.
    ## `active` is false when no viewport is live.
    active*: bool
    banner*: string
    lines*: seq[string]
    exitCode*: int
    idx*: int
    maxLines*: int

  FrameModel* = object
    ## Single source of truth for what the GUI animation thread paints.
    ## The controller writes it under `frameModelLock`; the animation thread
    ## reads it to build a `FooterFrame` each tick. Centralizing this state
    ## (previously scattered across `spinLabelLock` vars, `barTickLock`
    ## vars, and loose atomics) is the prerequisite to merging the two
    ## render threads into one — it removes the torn-read window where a
    ## spinner frame and a bar-tick frame disagree about footer height.
    mode*: AnimationMode
    spinner*: string   # braille glyph
    label*: string     # token-slot label (shared by spinner + bar tick)
    ticker*: string    # reasoning ticker tail text
    elapsed*: int      # seconds (spinner) or whole-second bar-tick count
    clearRows*: int    # for ffClear frames at teardown
    viewport*: ViewportSnapshot

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

func markerText(marker: PromptMarker): string =
  case marker
  of pmUser: "❯"
  of pmAssistant: "●"
  of pmBash: "$"
  of pmRead: "r"
  of pmWrite: "w"
  of pmPatch: "p"
  of pmOther: "·"

func splitLogicalLines(s: string): seq[string] =
  result = s.splitLines()
  if s.len > 0 and s[^1] == '\n':
    result.add ""
  if result.len == 0:
    result.add ""

func wrapPlain*(line: string, width: int): seq[string] =
  ## Word-wrap on whitespace; char-wrap words longer than the width. Shares
  ## the single wrap algorithm in ``minline.lineSpans`` (called with no
  ## prompt/continuation indent) so the transcript display wraps identically
  ## to the editor's cursor geometry; the two can never drift and re-trigger
  ## the typed-character-then-erased echo bug.
  for sp in lineSpans(line, 0, 0, max(1, width)):
    result.add line[sp.start ..< sp.stop]

func cellWidth(s: string): int =
  var i = 0
  while i < s.len:
    inc result, runeCellWidth(s.runeAt(i))
    i += max(1, runeLenAt(s, i))

func wrapMarked(marker, body: string, width: int): seq[string] =
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

func hasNonNewlineBytes*(s: string): bool =
  for ch in s:
    if ch notin {'\r', '\n'}:
      return true

func hasElapsedSuffix*(label: string): bool =
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

func labelCells(label: string): int =
  var i = 0
  while i < label.len:
    let rl = max(1, runeLenAt(label, i))
    inc result
    i += rl

func barWrapRows(visibleCells, termW: int): int =
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

type
  FooterLayout* = object
    ## A frame's geometry and paint bytes derived in one pass, so the
    ## volatile-row count the engine's walk-up trusts and the bytes that
    ## occupy those rows can never drift. `rowsAboveEditor` counts the
    ## rows from the footer's top to the editor; `bytes` paints exactly
    ## that many rows and (for bar/spinner) leaves the cursor on the
    ## bar's first row.
    rowsAboveEditor*: int
    bytes*: string

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

func clampToWidth*(s: string; width: int): string =
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


proc footerLayout*(frame: FooterFrame; termW = 0): FooterLayout =
  ## The first row is always a gap (blank unless a thinking ticker fills
  ## it): this makes the footer height invariant to the ticker appearing
  ## or clearing, so the engine's walk-up to the footer top never lands
  ## on committed scrollback.
  case frame.kind
  of ffNone:
    # Prompt-only chrome still reserves the gap/ticker row above the editor.
    # Startup intentionally hides the token bar until the first response has
    # real usage, but the gap stays so scrollback never sits flush against the
    # prompt and so walk-up/erase math matches the row that is actually on
    # screen. Counting this as 0 made the first spinner/bar paint under-walk
    # and overwrite the line above the prompt.
    result.rowsAboveEditor = 1
  of ffClear:
    result.rowsAboveEditor = max(1, frame.clearRows)
    result.bytes = "\r\x1b[2K"
    for _ in 1 ..< result.rowsAboveEditor:
      result.bytes.add "\r\n\x1b[2K"
  of ffTokenBar:
    result.rowsAboveEditor = 1 + barWrapRows(2 + labelCells(frame.label), termW)
    result.bytes = "\r\x1b[2K"
    if frame.ticker.len > 0:
      let shown = if termW > 0: clampToWidth(frame.ticker, termW) else: frame.ticker
      result.bytes.add GreyFg & shown & Reset
    result.bytes.add "\r\n" & paintBarBytes(frame.label)
  of ffSpinner:
    let elapsedTextLen = if frame.elapsed >= 0: ($frame.elapsed).len else: 1
    let barRows = barWrapRows(labelCells(frame.label) + 4 + elapsedTextLen, termW)
    result.rowsAboveEditor = 1 + barRows
    result.bytes = "\x1b[?25l\r\x1b[2K"
    if frame.ticker.len > 0:
      result.bytes.add GreyFg
      result.bytes.add frame.ticker
      result.bytes.add Reset
    result.bytes.add "\r\n\x1b[2K"
    result.bytes.add spinnerBarBytes(frame.spinner, frame.label, frame.elapsed)
    result.bytes.add "\r\n\x1b[2K" & EditorPromptBytes
    result.bytes.add "\r\x1b[" & $barRows & "A"

proc rowsAboveEditor*(frame: FooterFrame; termW = 0): int =
  frame.footerLayout(termW).rowsAboveEditor

proc spinnerFooterBytes*(frame, label, ticker: string; elapsed: int,
                         termW = 0): string =
  spinnerFooterFrame(frame, label, ticker, elapsed).footerLayout(termW).bytes

proc liveEditorSpinnerFooterBytes*(frame, label, ticker: string;
                                   elapsed: int; termW = 0): string =
  result.add "\r\x1b[2K"
  if ticker.len > 0:
    let shown = if termW > 0: clampToWidth(ticker, termW) else: ticker
    result.add GreyFg & shown & Reset
  result.add "\r\n"
  result.add liveEditorSpinnerBarBytes(frame, label, elapsed)

proc clearSpinnerFooterBytes*(hadTicker: bool): string =
  if hadTicker:
    "\r\x1b[2K\r\n\x1b[2K"
  else:
    "\r\x1b[2K"

proc footerFrameBytes*(frame: FooterFrame; termW = 0): string =
  case frame.kind
  of ffSpinner:
    # Live-editor variant: the editor is already on screen, so only the
    # ticker+bar rows paint (see liveEditorSpinnerFooterBytes). This is
    # not the standalone layout's full footer, which includes the editor
    # prompt and a cursor park.
    result = liveEditorSpinnerFooterBytes(frame.spinner, frame.label,
                                          frame.ticker, frame.elapsed, termW)
  else:
    result = frame.footerLayout(termW).bytes

proc addUserEcho(result: var string, line: string; trailingNewline = true) =
  let termW = try: terminalWidth() except CatchableError: 0
  let lines = line.splitLines
  for idx, l in lines:
    let prefix = if idx == 0: "❯ " else: "  "
    result.add prefix
    if termW <= 0:
      result.add l
    else:
      let chunks = wrapPlain(l, max(1, termW - 2))
      result.add chunks[0]
      for chunk in chunks[1 ..< chunks.len]:
        result.add "\r\n  " & chunk
    if trailingNewline or idx < lines.high:
      result.add "\r\n"

proc formatUserPromptItem*(line: string): string =
  ## Format a user prompt as a scrollback item body. No trailing separator is
  ## included; the controller/transcript emitter owns inter-item spacing.
  result.addUserEcho(line, trailingNewline = false)

proc promptOnlyBytes*(): string =
  "\r\x1b[2K" & EditorPromptBytes

proc promptOnlyResetBytes*(): string =
  "\x1b[2K" & EditorPromptBytes

proc clearPromptAfterPendingReceiptBytes*(): string =
  "\r\x1b[1A\x1b[J"

proc clearBarRowBytes*(): string =
  "\r\x1b[2K"

proc tokenBarRows*(s: FatPromptState; termW = 0): int =
  ## Number of terminal rows occupied by the current token bar.
  if s.footer.barLabel.len == 0: 0
  else: barWrapRows(2 + labelCells(s.footer.barLabel), termW)

proc footerRowsAboveEditor*(s: FatPromptState; termW = 0): int =
  ## Rows above the editor for the live footer state. The gap/ticker row is
  ## always reserved (prompt-only startup included); the token bar adds its
  ## own wrapped height when present. Matches `footerLayout` / `rowsAboveEditor`.
  result = 1
  if s.footer.barLabel.len > 0:
    result += tokenBarRows(s, termW)

proc footerGeometry*(s: FatPromptState; editorRows: int; termW = 0): FatPromptGeometry =
  ## Size of the reserved fat-prompt area: ticker/gap, optional token bar, and
  ## editor rows. Prompt-only startup (no bar yet) still reserves the gap row.
  let barRows = tokenBarRows(s, termW)
  # Always reserve the ticker/gap row: scrollback flush against the prompt or
  # bar never reads well, whether or not a thinking ticker or token bar is
  # active. This matches `footerLayout` for ffNone and ffTokenBar/ffSpinner.
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

func editorRows*(p: FatPrompt): seq[string] =
  wrapMarked("❯", p.editorText, p.width)

func editorHeight*(p: FatPrompt): int =
  p.editorRows.len

proc beginBash*(p: var FatPrompt; idx = 0; maxLines = DefaultBashMaxLines) =
  p.bash = BashViewport(active: true, idx: idx, maxLines: max(1, maxLines))

proc pushBashOutput*(p: var FatPrompt; line: string) =
  if not p.bash.active:
    p.beginBash()
  p.bash.lines.add line

func bashVisibleRows*(p: FatPrompt): seq[string] =
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

func frameRows*(p: FatPrompt): seq[string] =
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

func frameText*(p: FatPrompt): string =
  p.frameRows().join("\n")
