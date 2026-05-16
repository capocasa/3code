## Live fat-prompt runtime.
##
## This module owns the prompt/footer/editor/spinner side effects used while a
## turn is running. The turn controller calls these helpers directly and also
## registers them as API stream hooks. `api.nim` must not import this module.

import std/[atomics, json, locks, os, strformat, strutils, terminal, times, unicode]
when defined(posix):
  import std/posix except SocketHandle
  import posix/termios
import ../types, ../util, ../compact, ../display, ../minline,
  ../terminal as termui
import rendering
from ../api import ApiStreamHooks, requestTurnInterrupt, setApiStreamHooks,
  setInterrupted


var contentStreamedLive*: bool = false
  ## Set by `callModel` when the assistant's text content has been streamed
  ## to stdout chunk-by-chunk during the SSE read; read (and reset) by
  ## `runTurns` so the same content isn't redrawn a second time at the end
  ## of the turn.

var followupStartsAfterReceipt*: bool = false
var receiptTouchesNextResponse*: bool = false

var fatPromptState* = rendering.initFatPromptState()
  ## Explicit state for the normal scrollback transcript's volatile footer.
  ## Rendering still happens in this module, but prompt/bar/ticker data now
  ## has one home instead of separate process-level globals.

template pendingHint*(): untyped = fatPromptState.footer.pendingHint
  ## Carries the latest iteration's accurate usage forward. Two roles:
  ##   1. After each `callModel` iteration, used to repaint the **token
  ##      bar** with accurate values (replacing the live rough ones).
  ##   2. On user submit (next turn), the saved values become the
  ##      **token receipt** — the dim repaint of the previous bar's
  ##      row, leaving the receipt in scroll history while a fresh
  ##      bar (at zeros) takes its place at the new bottom.
  ## See `## Token UI` in `CLAUDE.md` for the full lifecycle.

template currentBarLabel*(): untyped = fatPromptState.footer.barLabel
  ## What's currently shown in the live bar. Updated by every paint
  ## (live during streaming, accurate after `callModel` parses usage,
  ## zero on first turn). Used by `writeTranscriptWithFatPrompt` to repaint the bar
  ## with the same label after a content write hides it.

template currentBarHasGap*(): untyped = fatPromptState.footer.hasGap
  ## Whether there's a one-row blank "gap" between the bar and the
  ## row above it. Set by `endTurn` (typing-ready state — the gap
  ## sits between the last LLM line and the bar, breathing room
  ## while the user reads). Cleared by every `paintBarPrompt` /
  ## `paintBarBelow` (during streaming, the bar slides flush with
  ## content — no gap mid-turn). Read by `emitUserSubmit` so the
  ## receipt repaints the gap row in place — overwriting the blank,
  ## leaving the receipt flush below the LLM content with no
  ## permanent gap in scroll history.

var showThinking*: bool = true
  ## When true, reasoning_content deltas from the provider are rendered as
  ## a one-line ticker embedded in the spinner label. Flipped by `:think on`
  ## / `:think off`. Has no effect if the provider doesn't emit reasoning.

var spinnerStop: Atomic[bool]
var spinnerFramePainted: Atomic[bool]
var spinnerThread: Thread[string]
var bufferedSubmitTurn: Atomic[bool]
var quietStop: Atomic[bool]
var quietThread: Thread[string]
var quietRunning = false
var lastProviderActivity: Atomic[int]

var barTickStop: Atomic[bool]
var barTickThread: Thread[void]
var barTickRunning = false
var barTickStart: float
var barTickBase: string
var barTickLock: Lock
barTickLock.initLock()

var apiCancelWatcherStarted = false
var apiLastTickerUpdate = 0.0

var inputState*: InputState
var inputStateLock*: Lock
initLock(inputStateLock)
var inputTurnActive: Atomic[bool]
var inputEditorReady: Atomic[bool]
var inputThread: Thread[void]
var inputThreadRunning* = false
var inputEditor*: ptr minline.LineEditor
var inputProfile*: ptr Profile
var inputSession*: ptr Session
var inputMessages*: ptr JsonNode
var turnHandleCommand*: proc(cmd: string): bool

# Shared mutable spinner state. The spinner thread reads these every frame;
# the main thread updates them as chunks arrive. Two separate lines:
#   line 1 = the classic spinner (frame + label + elapsed seconds)
#   line 2 = the reasoning ticker, dim, empty when no thinking is streaming
# Both fields live under one lock for simplicity — writes are infrequent.
var
  spinLabelLock: Lock
  spinLabelShared: string
  spinTickerShared: string
  spinFrameShared: string
  spinElapsedShared: int
spinLabelLock.initLock()

proc emitFatPromptEvent*(ev: FatPromptEvent) =
  ## Single state transition entry point for the volatile footer model.
  ## Terminal bytes are still rendered by the helpers below, but all
  ## production state changes flow through this event reducer.
  fatPromptState.apply ev

type LiveMarkdownStream* = object
  ## Incremental renderer for assistant content during provider streaming.
  ## It buffers input until markdown line/block boundaries, renders through
  ## the same MarkdownState used by replay, and keeps the token footer sliding
  ## below whatever rendered bytes are emitted.
  baseLabel: string
  started: bool
  md: MarkdownState
  pendingLine: string
  utf8Pending: string
  streamT0: float
  liveBarAtCursor: bool
  liveBarBelow: bool
  liveLineEmitted: bool
  liveCol: int

var apiLiveStream: LiveMarkdownStream

proc setSpinLabel(s: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    spinLabelShared = s
    release spinLabelLock

proc getSpinLabel(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    result = spinLabelShared
    release spinLabelLock

proc setSpinTicker(s: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    spinTickerShared = s
    release spinLabelLock
    if s.len == 0:
      emitFatPromptEvent clearTickerEvent()
    else:
      emitFatPromptEvent setTickerEvent(s)

proc getSpinTicker(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    result = spinTickerShared
    release spinLabelLock

proc setSpinFrame(frame: string; elapsed: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    spinFrameShared = frame
    spinElapsedShared = elapsed
    release spinLabelLock

proc getSpinBarBytes(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    let frame = if spinFrameShared.len > 0: spinFrameShared else: "○"
    let label = spinLabelShared
    let elapsed = spinElapsedShared
    release spinLabelLock
    if label.len > 0:
      result = liveEditorSpinnerBarBytes(frame, label, elapsed)

proc refreshEditorWidth(ed: var minline.LineEditor) =
  let w = try: terminalWidth() except CatchableError: 0
  if w > 0:
    ed.width = w

proc liveEditorRows(): int =
  if inputThreadRunning and inputEditor != nil:
    refreshEditorWidth(inputEditor[])
    max(1, minline.renderedRows(inputEditor[]))
  else:
    1

proc currentTermW(): int =
  ## Best-effort terminal column count for width-aware fat-prompt geometry.
  ## Returns 0 when stdout is not a tty (test harnesses, redirected runs) so
  ## emitters fall back to their single-row default instead of guessing.
  try: terminalWidth() except CatchableError: 0

proc liveFatPromptGeometry(): FatPromptGeometry {.gcsafe.} =
  {.cast(gcsafe).}:
    result = fatPromptState.footerGeometry(liveEditorRows(), currentTermW())

proc liveFooterTopRow(termH: int): int {.gcsafe.} =
  ## 1-based top row for the volatile footer. When a token bar is visible this
  ## is the bar row; in prompt-only mode it is the editor row.
  let g = liveFatPromptGeometry()
  max(1, termH - g.reservedRows + 1)

proc liveEditorFooterAnchored*(): bool =
  ## True when we can pin the live turn editor to absolute terminal rows.
  ## This is the production/PTY path. Pipe-backed unit tests and redirected
  ## output keep the older relative cursor contract because there is no real
  ## terminal floor to anchor to.
  inputThreadRunning and inputEditor != nil and terminalHeight() > 0 and
    stdout.isatty

proc hasQueuedAutosend*(): bool =
  ## True once the background editor has accepted Enter and the text is
  ## waiting for the outer REPL to echo as transcript. At that point it must
  ## not be restored as live editor chrome after transcript appends.
  acquire inputStateLock
  try:
    result = inputState.autoSend and inputState.queuedText.len > 0
  finally:
    release inputStateLock

proc promoteQueuedAutosendFromEditor*() =
  ## If typing continued after an autosend marker was shown, the live editor
  ## may contain the full multiline prompt while queuedText still holds the
  ## earlier prefix. Promote the fuller editor text before the outer loop
  ## drains the queued prompt.
  if inputEditor == nil:
    return
  acquire inputStateLock
  try:
    if inputState.autoSend and inputState.queuedText.len > 0:
      let editorText = inputEditor[].line.text
      if editorText.len > inputState.queuedText.len and
          editorText.startsWith(inputState.queuedText):
        inputState.queuedText = editorText
  finally:
    release inputStateLock

proc reserveEditorFooterForRedraw(ed: var minline.LineEditor) =
  ## Called by the editor before every redraw while a turn is active.
  ## The reserved footer height follows the editor's live rendered height
  ## (wraps, multiline input, history navigation, submit suffix). Cursor
  ## out: top row of the editor area. The subsequent editor redraw is the
  ## only code allowed to paint those rows.
  if not liveEditorFooterAnchored():
    return
  let footerBarBytes =
    if spinnerStop.load(moRelaxed) == false and spinnerFramePainted.load(moRelaxed):
      getSpinBarBytes()
    elif barTickRunning:
      var base: string
      acquire barTickLock
      base = barTickBase
      release barTickLock
      let elapsed = (epochTime() - barTickStart).int
      let label =
        if base.hasElapsedSuffix: base
        else: base & "  " & $elapsed & "s"
      paintBarBytes(label)
  else:
    currentFooterBarBytes(fatPromptState)
  termui.beginEditorRedraw(
    ed,
    inputEditorReady.load(moAcquire),
    footerBarBytes)

template captureStdoutWrites*(body: untyped): string =
  ## Run a transcript formatter against a temporary stdout target and return
  ## the produced bytes. `writeTranscriptWithFatPrompt` uses this to make formatter
  ## flushes invisible until the footer can be restored in the same render
  ## tick.
  block:
    var captured = ""
    when defined(posix):
      let path = getTempDir() / "3code_transcript_" & $getCurrentProcessId() &
                 "_" & $(epochTime() * 1000.0).int
      flushFile(stdout)
      let saved = dup(1)
      if saved < 0:
        body
      else:
        let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
        if fd < 0:
          discard close(saved)
          body
        else:
          doAssert dup2(fd, 1) >= 0
          discard close(fd)
          try:
            body
            flushFile(stdout)
          finally:
            discard dup2(saved, 1)
            discard close(saved)
          try:
            captured = readFile(path)
            removeFile(path)
          except OSError:
            discard
    else:
      body
    captured

# ---------- Bar+prompt runtime helpers ----------
#
# The bar and prompt are *always visible*. These helpers hide them
# just long enough for a content write that would otherwise advance
# into them, and repaint them immediately below. Each helper also
# updates `currentBarLabel` so subsequent repaints (after a tool
# write, after an iteration end, etc.) use the same content.

proc paintBarPrompt*(label, promptColor: string) =
  ## Write bar + prompt at the cursor's current row, parking cursor
  ## at col 0 of the bar row. Caches `label` so a later
  ## `repaintBarPrompt` knows what to draw. Clears `currentBarHasGap`
  ## — during streaming the bar slides flush with content; only
  ## `endTurn` paints a gap.
  debugOut "paintBarPrompt label=" & label[0..min(30, label.len-1)]
  emitFatPromptEvent setBarEvent(label)
  if liveEditorFooterAnchored():
    termui.renderFooterFrame(paintBarBytes(label), inputThreadRunning,
                                     inputEditor)
  else:
    termui.syncWrite(cursorForPromptColor(promptColor) &
      barFooterBytes(label, promptColor, currentTermW()))

proc setBarPromptState*(label: string) =
  ## Update the logical bar label without painting immediately. Used when a
  ## completed response still needs to be committed to scrollback first; the
  ## subsequent transcript append repaints the footer with this final label.
  emitFatPromptEvent setBarEvent(label)

proc paintBarBelow*(label, promptColor: string) =
  ## Paint bar + prompt one and two rows below the cursor, restoring
  ## the cursor to its original (likely mid-line) position. Used
  ## during streaming to keep the bar visible while content is being
  ## accumulated in memory and the cursor stays put.
  emitFatPromptEvent setBarEvent(label)
  if liveEditorFooterAnchored():
    termui.renderFooterFrame(paintBarBytes(label), inputThreadRunning,
                                     inputEditor)
  else:
    termui.syncWrite(barFooterBelowBytes(label, promptColor,
                                         currentTermW()))

proc paintBarBelowAtCol(label, promptColor: string, col: int) =
  emitFatPromptEvent setBarEvent(label)
  if liveEditorFooterAnchored():
    termui.renderFooterFrame(paintBarBytes(label), inputThreadRunning,
                                     inputEditor)
  else:
    termui.syncWrite(barFooterBelowAtColBytes(label, promptColor, col,
                                              currentTermW()))

proc clearBarBelowAtCol(col: int) =
  if liveEditorFooterAnchored():
    termui.renderFooterFrame(clearBarRowBytes(), inputThreadRunning,
                             inputEditor)
  else:
    termui.syncWrite(clearBarBelowAtColBytes(col))

proc repaintBarPrompt*(promptColor = DimPromptColor) =
  ## Re-emit the bar+prompt at the cursor's current row using the
  ## cached `currentBarLabel`. Used by `writeTranscriptWithFatPrompt` to put the bar
  ## back after a content write.
  if currentBarLabel.len == 0: return
  if liveEditorFooterAnchored():
    termui.renderFooterFrame(paintBarBytes(currentBarLabel),
                                     inputThreadRunning, inputEditor)
  else:
    termui.syncWrite(cursorForPromptColor(promptColor) &
      barFooterBytes(currentBarLabel, promptColor, currentTermW()))

proc clearBarPrompt*() =
  ## Erase the bar + prompt rows in place. Cursor parks at col 0 of
  ## the bar row so the caller can write content there (which then
  ## pushes the next `repaintBarPrompt` one row down).
  if liveEditorFooterAnchored():
    termui.renderFooterFrame(clearBarRowBytes(), inputThreadRunning,
                                     inputEditor)
  else:
    termui.syncWrite(ClearBarPromptBytes)

proc paintPromptOnly*(promptColor: string)

proc enterPromptInput*(promptColor: string) =
  ## Prepare the physical cursor for either immediate input or buffered
  ## input during a running turn. In bar mode, repaint the shared
  ## bar+prompt footer and park on the prompt row. In prompt-only mode,
  ## clear the prompt row in place. The line editor writes its own prompt
  ## glyph after this, so the prepainted glyph is only a stable visual
  ## placeholder.
  if currentBarLabel.len > 0:
    if currentBarHasGap and pendingHint.active:
      termui.syncWrite(clearPromptAfterPendingReceiptBytes())
    else:
      clearBarPrompt()
    termui.enterPromptInput(
      true,
      barFooterBytes(currentBarLabel, promptColor, currentTermW()),
      "")
  else:
    termui.enterPromptInput(
      false,
      "",
      promptOnlyBytes(promptColor))

proc resetPromptInputAfterEmpty*(echoRows: int; promptColor: string) =
  ## Empty submission should leave the prompt/footer at the same visual
  ## floor instead of drifting downward. `echoRows` is the editor's visual
  ## input height, including wraps.
  let n = max(1, echoRows)
  if currentBarLabel.len == 0:
    termui.resetPromptInputAfterEmpty(
      false,
      n,
      promptOnlyResetBytes(promptColor),
      "")
    emitFatPromptEvent clearBarEvent()
  else:
    termui.resetPromptInputAfterEmpty(
      true,
      n,
      "",
      cursorForPromptColor(promptColor) &
        barFooterBytes(currentBarLabel, promptColor, currentTermW()))

proc toolOverlayGeometry*(termH: int; maxRows = 8):
    tuple[top, height, footerTop: int] =
  ## Absolute rows available to the bounded live tool-output overlay. The
  ## overlay sits immediately above the volatile fat prompt and is the only
  ## non-append area, aside from the optional thinking ticker.
  let footerTop = liveFooterTopRow(termH)
  let h = min(max(1, maxRows + 1), max(1, footerTop - 1))
  (top: max(1, footerTop - h), height: h, footerTop: footerTop)

proc commitTranscriptBytes*(transcriptBytes: string; restoreEditor = true;
                            beforeRepaint: proc() = nil;
                            clearFooterAboveCursor = false;
                            reserveFooter = true;
                            footerRowsAboveCursor = -1;
                            transcriptOwnsSpacing = false) =
  ## Commit transcript output while preserving the volatile footer.
  ## The controller owns the transcript bytes and item spacing. This proc owns
  ## the terminal mechanics: clear the volatile footer, append the bytes as
  ## scrollback, then repaint whatever footer state remains. ``beforeRepaint``
  ## runs after transcript bytes are known but before repaint bytes are
  ## computed, so a controller can convert a live bar into a receipt and clear
  ## it without fatprompt reintroducing stale chrome.
  debugOut &"writeTranscriptWithFatPrompt enter barLabel={currentBarLabel.len}"
  let oldHadBar = currentBarLabel.len > 0
  let oldLiveAnchored = liveEditorFooterAnchored()
  let oldInputRunning = inputThreadRunning
  let editorFooterRowsAbove =
    if oldInputRunning and inputEditor != nil:
      let editorRows = max(1, minline.renderedRows(inputEditor[]))
      min(inputEditor[].renderRow, editorRows - 1) + (if oldHadBar: 1 else: 0)
    else:
      0
  if receiptTouchesNextResponse and transcriptBytes.hasNonNewlineBytes:
    receiptTouchesNextResponse = false
  if beforeRepaint != nil:
    beforeRepaint()
  let implicitFooterRowsAbove =
    if footerRowsAboveCursor >= 0:
      footerRowsAboveCursor
    elif oldInputRunning and inputEditor != nil:
      editorFooterRowsAbove
    elif clearFooterAboveCursor and oldHadBar and not oldLiveAnchored and
        not oldInputRunning:
      1
    else:
      0
  let repaint =
    if currentBarLabel.len > 0:
      barFooterBytes(currentBarLabel, DimPromptColor, currentTermW())
    else:
      clearBarRowBytes()
  termui.appendTranscriptWithFooter(
    transcriptBytes,
    liveEditorFooterAnchored(),
    inputThreadRunning,
    inputEditor,
    currentFooterBarBytes(fatPromptState),
    ClearBarPromptBytes,
    repaint,
    0,
    restoreEditor,
    implicitFooterRowsAbove,
    reserveFooter,
    transcriptOwnsSpacing)
  if reserveFooter and transcriptBytes.hasNonNewlineBytes and currentBarLabel.len > 0:
    emitFatPromptEvent setBarEvent(currentBarLabel, hasGap = true)
  debugOut "writeTranscriptWithFatPrompt exit"

template writeTranscriptWithFatPromptRestore*(restoreEditor: bool; body: untyped) =
  ## Capture formatter writes and commit them through the fat-prompt terminal
  ## preservation primitive. This is compatibility glue for older call sites;
  ## controller-owned transcript paths should prefer ``commitTranscriptBytes``.
  let transcriptBytes = captureStdoutWrites:
    body
  commitTranscriptBytes(transcriptBytes, restoreEditor)

template writeTranscriptWithFatPrompt*(body: untyped) =
  writeTranscriptWithFatPromptRestore(true):
    body

proc spinnerLoop(unused: string) {.thread.} =
  ## Three-line spinner footer rooted at the cursor row:
  ##   row N-1   reasoning ticker (overlay, dim) — shown only while
  ##             reasoning streams; the row above the bar is the
  ##             leading-`\n` scratch row callModel writes, so the
  ##             overlay always lands on a blank, and clearing the
  ##             row is a faithful restore.
  ##   row N     spinner frame + token-slot bar (cyan + bright)
  ##   row N+1   dim ❯ placeholder, the visible caret while typing
  ##             isn't possible.
  ## See `spinnerFooterBytes` for the byte sequence each frame writes.
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  var lastTicker = ""
  while not spinnerStop.load(moRelaxed):
    let elapsed = epochTime() - start
    let label = getSpinLabel()
    let ticker =
      if inputThreadRunning and inputEditor != nil: ""
      else: getSpinTicker()
    lastTicker = ticker
    try:
      if bufferedSubmitTurn.load(moRelaxed):
        sleep 80
        inc i
        continue
      if inputThreadRunning and inputEditor != nil:
        sleep 80
        inc i
        continue
      let frame = frames[i mod frames.len]
      setSpinFrame(frame, elapsed.int)
      termui.renderFooterFrame(
        spinnerFooterBytes(frame, label, ticker, elapsed.int, currentTermW()),
        inputThreadRunning, inputEditor)
      spinnerFramePainted.store(true, moRelaxed)
    except CatchableError: discard
    sleep 80
    inc i
  try:
    let termW = try: terminalWidth() except CatchableError: 80
    if not inputThreadRunning:
      let tickerRows =
        if lastTicker.len == 0: 1
        else: max(1, (visibleWidth(lastTicker) + max(1, termW) - 1) div max(1, termW))
      termui.syncWrite(spinnerCleanupBytes(tickerRows))
  except CatchableError: discard

proc liveLabel*(base: string, slurped: int): string =
  ## Spinner label whose token slots match the per-call summary's shape:
  ## icon hugs value, slots joined by two spaces. ↑/↻ read as `0` until
  ## the final usage event closes the response; the spinner thread
  ## renders this in fgCyan + styleBright.
  var parts: seq[string]
  if base.len > 0: parts.add base
  let up = tokenSlot("↑", 0)
  if up.len > 0: parts.add up
  let cached = tokenSlot("↻", 0)
  if cached.len > 0: parts.add cached
  let down = tokenSlot("↓", slurped div 4)
  if down.len > 0: parts.add down
  parts.join("  ")

proc paintInitialBar*(p: Profile) =
  ## Welcome-time paint: one blank gap row, then bar+prompt at zero
  ## values *with* a `○ 0%` context indicator (the empty-circle glyph
  ## is the same one a populated bar carries — at startup we just
  ## haven't sent a request yet, so promptTokens is 0). Bright cyan
  ## prompt — typing-ready. Sets `currentBarHasGap = true` to match
  ## `endTurn`'s shape between turns.
  termui.writeRaw("\n")
  let window = contextWindowFor(p.model)
  let baseLabel = contextLabel(0, window)
  paintBarPrompt(liveLabel(baseLabel, 0), BrightPromptColor)
  emitFatPromptEvent setBarEvent(currentBarLabel, hasGap = true)

proc paintPromptOnly*(promptColor: string) =
  ## Paint just the prompt ❯ at the cursor's current row, no token
  ## bar above. Used in the pre-first-turn startup state where we have
  ## no real token values yet — the bar stays hidden until the first
  ## model response brings them. Cursor parks at col 0 of the prompt
  ## row.
  ##
  ## Leaves `currentBarLabel = ""` and `currentBarHasGap = false` —
  ## the signals `readInput`, `emitUserSubmit`, and the slash-command
  ## repaint use to detect prompt-only mode.
  termui.writeRaw(promptOnlyResetBytes(promptColor))
  emitFatPromptEvent clearBarEvent()

proc paintInitialPrompt*(p: Profile) =
  ## Welcome-time paint when starting fresh. The first prompt is intentionally
  ## prompt-only; the token bar appears after the first response has real usage
  ## to display.
  paintPromptOnly(BrightPromptColor)


var spinnerRunning = false  # only mutated by main thread

# --- Bar tick: repaints the token bar with an incrementing elapsed counter
#     during tool execution. No spinner icon, just the bar label + time.

proc barTickLoop() {.thread.} =
  while not barTickStop.load(moRelaxed):
    var base: string
    {.cast(gcsafe).}:
      acquire barTickLock
      base = barTickBase
      release barTickLock
    let elapsed = (epochTime() - barTickStart).int
    if inputThreadRunning and inputEditor != nil:
      sleep 500
      continue
    let label =
      if base.hasElapsedSuffix: base
      else: base & "  " & $elapsed & "s"
    # Re-assert hide-cursor each tick — same rationale as
    # `spinnerFooterBytes`: some terminals transiently re-show the
    # caret on cursor movement, and beginTurn's one-shot `?25l`
    # isn't enough to keep it hidden over a long-running tool.
    let th = try: terminalHeight() except CatchableError: 24
    let row = liveFooterTopRow(th)
    let frame =
      if inputThreadRunning and inputEditor != nil:
        if liveEditorFooterAnchored():
          liveEditorBarTickFrame(label)
        else:
          absoluteBarTickFrame(row, label, activeEditor = true)
      else:
        absoluteBarTickFrame(row, label, activeEditor = false,
                             termW = currentTermW())
    termui.renderFooterFrame(frame, inputThreadRunning, inputEditor)
    sleep 500

proc startBarTick*(base: string) =
  debugOut "startBarTick"
  if barTickRunning: return
  {.cast(gcsafe).}:
    acquire barTickLock
    barTickBase = base
    release barTickLock
  barTickStart = epochTime()
  barTickStop.store(false, moRelaxed)
  createThread(barTickThread, barTickLoop)
  barTickRunning = true

proc stopBarTick*(): int =
  ## Stops the bar tick and returns elapsed seconds.
  debugOut "stopBarTick"
  if not barTickRunning: return 0
  let elapsed = (epochTime() - barTickStart).int
  barTickStop.store(true, moRelaxed)
  joinThread(barTickThread)
  barTickRunning = false
  return elapsed

proc startSpinner*(label: string) =
  debugOut "startSpinner"
  if spinnerRunning: return
  if label.len > 0: setSpinLabel(label)
  if inputThreadRunning and inputEditor != nil:
    setSpinFrame("⠋", 0)
    spinnerFramePainted.store(true, moRelaxed)
  else:
    spinnerFramePainted.store(false, moRelaxed)
  spinnerStop.store(false, moRelaxed)
  createThread(spinnerThread, spinnerLoop, "")
  spinnerRunning = true

proc stopSpinner*() =
  debugOut "stopSpinner"
  if not spinnerRunning: return
  spinnerStop.store(true, moRelaxed)
  joinThread(spinnerThread)
  spinnerRunning = false

proc nowMs(): int =
  int(epochTime() * 1000.0)

proc markProviderActivity*() =
  lastProviderActivity.store(nowMs(), moRelaxed)

proc quietWatchLoop(baseLabel: string) {.thread.} =
  var shown = false
  while not quietStop.load(moRelaxed):
    let idleMs = nowMs() - lastProviderActivity.load(moRelaxed)
    if idleMs >= 15_000:
      setSpinLabel("network quiet; still waiting")
      shown = true
    elif shown:
      setSpinLabel(baseLabel)
      shown = false
    sleep 500

proc startQuietWatch(baseLabel: string) =
  if quietRunning: return
  markProviderActivity()
  quietStop.store(false, moRelaxed)
  createThread(quietThread, quietWatchLoop, baseLabel)
  quietRunning = true

proc stopQuietWatch() =
  if not quietRunning: return
  quietStop.store(true, moRelaxed)
  joinThread(quietThread)
  quietRunning = false

proc initLiveMarkdownStream*(baseLabel: string): LiveMarkdownStream =
  LiveMarkdownStream(baseLabel: baseLabel, md: initMarkdownState(),
    streamT0: epochTime(), liveCol: 2)

proc currentLabel(s: LiveMarkdownStream, slurpedNow: int): string =
  liveLabel(s.baseLabel, slurpedNow)

proc utf8LenAt(s: string, i: int): int =
  let b = s[i].uint8
  if (b and 0x80'u8) == 0'u8: 1
  elif (b and 0xE0'u8) == 0xC0'u8: 2
  elif (b and 0xF0'u8) == 0xE0'u8: 3
  elif (b and 0xF8'u8) == 0xF0'u8: 4
  else: 1

proc captureMd(s: var LiveMarkdownStream, line: string,
               finish = false): string =
  let path = getTempDir() / "3code_live_md_" & $getCurrentProcessId()
  let f = open(path, fmWrite)
  defer:
    try: removeFile(path) except OSError: discard
  if finish:
    discard finishMd(s.md, f)
  else:
    discard handleMdLine(s.md, line, f)
  f.flushFile
  close(f)
  result = readFile(path)

proc startContent(s: var LiveMarkdownStream, slurpedNow: int) =
  if s.started: return
  setSpinTicker("")
  let hadSpinnerFrame = spinnerFramePainted.load(moRelaxed)
  let hadBufferedSubmit = bufferedSubmitTurn.load(moRelaxed)
  bufferedSubmitTurn.store(false, moRelaxed)
  stopSpinner()
  termui.prepareAssistantContentStart(
    inputThreadRunning,
    inputEditor,
    hadSpinnerFrame,
    hadBufferedSubmit,
    ClearBarPromptBytes)
  termui.withTerminalWriteLock:
    writeAssistantBullet()
    s.started = true
    paintBarBelow(s.currentLabel(slurpedNow), DimPromptColor)
    s.liveBarBelow = true

proc advanceLiveCol(s: var LiveMarkdownStream, text: string) =
  let termW = max(1, try: terminalWidth() except CatchableError: 80)
  s.liveCol += visibleWidth(text)
  while s.liveCol >= termW:
    s.liveCol -= termW

proc writeLiveSegment(s: var LiveMarkdownStream, text: string) =
  if text.len == 0: return
  if s.liveBarAtCursor:
    clearBarPrompt()
    s.liveBarAtCursor = false
  elif s.liveBarBelow:
    clearBarBelowAtCol(s.liveCol)
    s.liveBarBelow = false
  stdout.write text
  s.advanceLiveCol(text)
  s.liveLineEmitted = true

proc writeRendered(s: var LiveMarkdownStream, bytes: string,
                   slurpedNow: int) =
  if bytes.len == 0: return
  s.startContent(slurpedNow)
  var i = 0
  while i < bytes.len:
    if bytes[i] == '\n':
      if s.liveBarBelow:
        clearBarBelowAtCol(s.liveCol)
        s.liveBarBelow = false
      stdout.write "\n"
      s.liveCol = 0
      if s.liveLineEmitted:
        paintBarPrompt(s.currentLabel(slurpedNow), DimPromptColor)
        s.liveBarAtCursor = true
      inc i
    else:
      let start = i
      while i < bytes.len and bytes[i] != '\n':
        inc i
      s.writeLiveSegment(bytes[start ..< i])
  if s.started:
    if s.liveBarAtCursor:
      paintBarPrompt(s.currentLabel(slurpedNow), DimPromptColor)
    else:
      paintBarBelowAtCol(s.currentLabel(slurpedNow), DimPromptColor, s.liveCol)
      s.liveBarBelow = true

proc suppressLiveAssistantStream(): bool =
  ## Streaming assistant text and an always-live editor both need the terminal
  ## cursor. Prefer prompt stability: keep the spinner/bar live, then let the
  ## caller commit the completed assistant text through `writeTranscriptWithFatPrompt`.
  liveEditorFooterAnchored()

proc feedContent*(s: var LiveMarkdownStream, chunk: string, slurpedNow: int) =
  if chunk.len == 0: return
  if suppressLiveAssistantStream(): return
  termui.withTerminalWriteLock:
    var data = s.utf8Pending & chunk
    s.utf8Pending = ""
    var i = 0
    while i < data.len:
      if data[i] == '\n':
        let rendered = s.captureMd(s.pendingLine)
        s.pendingLine = ""
        s.writeRendered(rendered, slurpedNow)
        inc i
      else:
        let charLen = utf8LenAt(data, i)
        if i + charLen > data.len:
          s.utf8Pending = data[i .. ^1]
          break
        s.pendingLine.add data[i ..< i + charLen]
        i += charLen
    stdout.flushFile()

proc finishContent*(s: var LiveMarkdownStream, slurpedNow: int) =
  if suppressLiveAssistantStream(): return
  if s.utf8Pending.len > 0:
    s.pendingLine.add s.utf8Pending
    s.utf8Pending = ""
  if s.pendingLine.len > 0:
    let rendered = s.captureMd(s.pendingLine)
    s.pendingLine = ""
    s.writeRendered(rendered, slurpedNow)
  let tail = s.captureMd("", finish = true)
  s.writeRendered(tail, slurpedNow)
  if s.started and s.liveBarBelow:
    paintBarPrompt(s.currentLabel(slurpedNow), DimPromptColor)
    s.liveBarAtCursor = true
    s.liveBarBelow = false

when defined(posix):
  var
    cancelWatcherStop: Atomic[bool]
    cancelWatcherThread: Thread[void]
    cancelWatcherActive: bool
    cancelOrigTermios: Termios
    cancelOrigTermiosValid: bool

  proc restoreCancelTermios*() {.noconv, gcsafe.} =
    if cancelOrigTermiosValid:
      discard tcSetAttr(0.cint, TCSANOW, addr cancelOrigTermios)
      cancelOrigTermiosValid = false

  proc cancelWatcherLoop() {.thread, nimcall.} =
    while not cancelWatcherStop.load(moRelaxed):
      var pfd: TPollfd
      pfd.fd = 0.cint
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.Tnfds, 100.cint)
      if r > 0 and (pfd.revents and POLLIN) != 0:
        var buf: array[64, char]
        let n = posix.read(0.cint, addr buf[0], buf.len)
        if n > 0:
          for i in 0 ..< n.int:
            let b = buf[i].uint8
            if b == 0x03 or b == 0x1b:
              {.cast(gcsafe).}:
                requestTurnInterrupt()
                restoreCancelTermios()
              return

  proc drainCancelInput() =
    if isatty(0.cint) == 0: return
    while true:
      var pfd: TPollfd
      pfd.fd = 0.cint
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.Tnfds, 0.cint)
      if r <= 0 or (pfd.revents and POLLIN) == 0:
        break
      var buf: array[64, char]
      let n = posix.read(0.cint, addr buf[0], buf.len)
      if n <= 0:
        break

  proc startCancelWatcher() =
    if cancelWatcherActive: return
    if isatty(0.cint) == 0: return
    var t: Termios
    if tcGetAttr(0.cint, addr t) != 0: return
    cancelOrigTermios = t
    cancelOrigTermiosValid = true
    t.c_lflag = t.c_lflag and not Cflag(ICANON or ECHO or ISIG)
    t.c_cc[VMIN] = 0.char
    t.c_cc[VTIME] = 0.char
    if tcSetAttr(0.cint, TCSANOW, addr t) != 0:
      cancelOrigTermiosValid = false
      return
    cancelWatcherStop.store(false, moRelaxed)
    createThread(cancelWatcherThread, cancelWatcherLoop)
    cancelWatcherActive = true

  proc stopCancelWatcher() =
    if not cancelWatcherActive: return
    cancelWatcherStop.store(true, moRelaxed)
    joinThread(cancelWatcherThread)
    cancelWatcherActive = false
    drainCancelInput()
    if cancelOrigTermiosValid:
      restoreCancelTermios()
else:
  proc startCancelWatcher() = discard
  proc stopCancelWatcher() = discard
  proc restoreCancelTermios*() {.noconv.} = discard

proc apiBeforeCall*(lastPromptTokens, window: int): string =
  let baseLabel = contextLabel(lastPromptTokens, window)
  result = baseLabel
  apiLiveStream = initLiveMarkdownStream(baseLabel)
  contentStreamedLive = false
  apiLastTickerUpdate = 0.0
  let startsAfterReceipt = followupStartsAfterReceipt
  followupStartsAfterReceipt = false
  termui.withTerminalWriteLock:
    if not startsAfterReceipt:
      termui.writeRaw("\n")
  setSpinLabel(liveLabel(baseLabel, 0))
  startSpinner("")
  startQuietWatch(liveLabel(baseLabel, 0))
  apiCancelWatcherStarted = inputEditor == nil
  if apiCancelWatcherStarted:
    startCancelWatcher()

proc apiAfterCall*() =
  stopQuietWatch()
  if apiCancelWatcherStarted:
    stopCancelWatcher()
    apiCancelWatcherStarted = false

proc apiSetStatusLabel*(label: string) =
  setSpinLabel(label)

proc apiProgress*(baseLabel: string; slurped: int) =
  setSpinLabel(liveLabel(baseLabel, slurped))

proc apiProviderActivity*() =
  markProviderActivity()

proc apiShowThinking*(): bool =
  showThinking

proc apiReasoningDelta*(reasoning, baseLabel: string; slurped: int;
                        contentStarted: bool) =
  let now = epochTime()
  if now - apiLastTickerUpdate < 0.1: return
  apiLastTickerUpdate = now
  let termW = try: terminalWidth() except CatchableError: 80
  let budget = max(20, termW - 6)
  let tail =
    if reasoning.len > budget: reasoning[reasoning.len - budget .. ^1]
    else: reasoning
  var flat = newStringOfCap(tail.len)
  for ch in tail:
    flat.add(if ch == '\n' or ch == '\r': ' ' else: ch)
  setSpinTicker("  … " & flat)

proc apiContentDelta*(chunk, baseLabel: string; slurped: int): bool =
  apiLiveStream.feedContent(chunk, slurped)
  apiLiveStream.started

proc apiContentFinished*(fullContent, baseLabel: string; slurped: int): bool =
  apiLiveStream.finishContent(slurped)
  if apiLiveStream.started:
    contentStreamedLive = true
  contentStreamedLive

proc apiTrimTrailingContent*(fullContent, baseLabel: string; slurped: int) =
  var trailingNl = 0
  for i in countdown(fullContent.len - 1, 0):
    if fullContent[i] == '\n': inc trailingNl
    else: break
  if trailingNl > 1:
    termui.withTerminalWriteLock:
      if apiLiveStream.liveBarAtCursor:
        clearBarPrompt()
        apiLiveStream.liveBarAtCursor = false
      elif apiLiveStream.liveBarBelow:
        termui.writeRaw(ClearBarBelowBytes)
        apiLiveStream.liveBarBelow = false
      termui.eraseRowsAbove(trailingNl - 1)
      paintBarPrompt(apiLiveStream.currentLabel(slurped), DimPromptColor)

proc apiAfterLiveContent*(baseLabel: string; slurped: int) =
  if apiLiveStream.liveBarBelow:
    termui.syncWrite(moveToBarBelowBytes())
  termui.syncWrite(insertTickerRowBelowBytes())
  setSpinLabel(liveLabel(baseLabel, slurped))
  startSpinner("")

proc apiFinalUsage*(usage: Usage; window, elapsed: int;
                    assistantContent: string; streamedLive: bool) =
  let label = tokenLineLabel(usage, window, elapsed)
  if streamedLive:
    termui.syncWrite(removeTickerRowAboveBytes())
  if streamedLive or assistantContent.strip.len == 0:
    paintBarPrompt(label, DimPromptColor)
  else:
    setBarPromptState(label)
  emitFatPromptEvent setPendingHintEvent(usage, window, elapsed)
  if window > 0 and usage.promptTokens.float > 0.7 * window.float and
     usage.promptTokens.float <= CompactThresholdFrac * window.float:
    writeTranscriptWithFatPrompt:
      subtleWriteLn(stdout,
        &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-compaction will fire near {humanTokens(int(CompactThresholdFrac * window.float))}; :compact or :summarize to act now")

proc apiNoUsage*(elapsed: int) =
  writeTranscriptWithFatPrompt:
    hint &"  · {elapsed}s", resetStyle, "\n"

proc installApiStreamHooks*() =
  setApiStreamHooks(ApiStreamHooks(
    beforeCall: apiBeforeCall,
    afterCall: apiAfterCall,
    progress: apiProgress,
    setStatusLabel: apiSetStatusLabel,
    startSpinner: startSpinner,
    stopSpinner: stopSpinner,
    providerActivity: apiProviderActivity,
    showThinking: apiShowThinking,
    reasoningDelta: apiReasoningDelta,
    contentDelta: apiContentDelta,
    contentFinished: apiContentFinished,
    trimTrailingContent: apiTrimTrailingContent,
    afterLiveContent: apiAfterLiveContent,
    finalUsage: apiFinalUsage,
    noUsage: apiNoUsage))
proc inputThreadProc() {.thread.} =
  ## Runs readline while the model or a tool owns the turn. Completed text is
  ## queued for the outer REPL to send as soon as the current turn settles;
  ## partial text is handed back as the next prompt's prefill.
  {.cast(gcsafe).}:
    if inputEditor == nil:
      return
    let edPtr = inputEditor
    template turnActive(): bool =
      inputTurnActive.load(moAcquire)
    when defined(posix):
      let fd = STDIN_FILENO.cint
      var pendingInput: seq[int]
      proc fillPending(waitMs: cint): bool =
        if pendingInput.len > 0:
          return true
        var pfd: Tpollfd
        pfd.fd = STDIN_FILENO
        pfd.events = POLLIN
        let r = poll(addr pfd, 1.Tnfds, waitMs)
        if r <= 0 or (pfd.revents and POLLIN) == 0:
          return false
        var ch: char
        let n = posix.read(fd, addr ch, 1)
        if n == 1:
          pendingInput.add ch.ord.int
        pendingInput.len > 0

      let getCh: minline.GetChProc = proc(): int =
        while turnActive():
          if pendingInput.len > 0 or fillPending(200.cint):
            result = pendingInput[0]
            pendingInput.delete(0)
            return
          if errno == EINTR:
            continue
        -1
      let hasPendingInput: minline.HasPendingInputProc = proc(): bool =
        pendingInput.len > 0 or fillPending(minline.EscapeTailPollMs.cint)
    else:
      let getCh: minline.GetChProc = proc(): int =
        if turnActive(): getchr().int else: -1
      let hasPendingInput: minline.HasPendingInputProc = nil

    let writeProc: minline.WriteProc = proc(s: string) =
      termui.writeRaw(s)

    edPtr[].onMutate = proc(ed: var minline.LineEditor) =
      acquire inputStateLock
      try:
        if inputState.autoSend:
          let queued = inputState.queuedText
          if queued.len > 0 and ed.line.text.startsWith(queued) and
              ed.line.position > queued.len:
            let inserted = ed.line.text[queued.len .. ^1]
            ed.line.text = queued & "\n" & inserted
            ed.line.position = queued.len + 1 + inserted.len
          inputState.autoSend = false
          inputState.queuedText = ""
          inputState.queuedEchoRows = 0
          ed.renderSuffix = ""
          ed.renderSuffixCursor = false
        inputState.editorText = ed.line.text
      finally:
        release inputStateLock
    edPtr[].onSubmit = proc(ed: var minline.LineEditor) =
      acquire inputStateLock
      try:
        inputState.queuedText = ed.line.text
        inputState.queuedEchoRows = minline.totalRows(ed.line.text, ed.promptW,
                                                      ed.contPromptW,
                                                      max(2, ed.width))
        inputState.autoSend = ed.line.text.len > 0
        inputState.editorText = ed.line.text
      finally:
        release inputStateLock
      ed.line.position = ed.line.text.len
      ed.renderSuffix =
        if ed.line.text.len > 0: " " & DeferredSubmitMarker & "\n"
        else: ""
      ed.renderSuffixCursor = ed.renderSuffix.len > 0
    edPtr[].preRedraw = proc(ed: var minline.LineEditor) =
      reserveEditorFooterForRedraw(ed)
    edPtr[].postRedraw = proc(ed: var minline.LineEditor) =
      termui.finishEditorRedraw()
      inputEditorReady.store(true, moRelease)

    when defined(posix):
      var oldMode: Termios
      var haveOldMode = false
      if isatty(fd) != 0 and fd.tcGetAttr(addr oldMode) == 0:
        haveOldMode = true
        var rawMode = oldMode
        rawMode.c_iflag = rawMode.c_iflag and not Cflag(BRKINT or ICRNL or
          INPCK or ISTRIP or IXON)
        rawMode.c_cflag = (rawMode.c_cflag and not Cflag(CSIZE or PARENB)) or CS8
        rawMode.c_lflag = rawMode.c_lflag and not Cflag(ECHO or ICANON or
          IEXTEN or ISIG)
        rawMode.c_cc[VMIN] = 1.char
        rawMode.c_cc[VTIME] = 0.char
        discard fd.tcSetAttr(TCSANOW, addr rawMode)

    edPtr[].deferSubmit = true
    edPtr[].submitIcon = DeferredSubmitMarker
    while turnActive():
      try:
        let text = minline.readLineWith(edPtr[],
                                        TurnPromptColor & "❯ " & Reset,
                                        getCh, writeProc,
                                        hasPendingInput = hasPendingInput)
        if text.len == 0:
          continue
        if text[0] == ':':
          termui.withTerminalWriteLock:
            clearBarPrompt()
          if turnHandleCommand != nil:
            discard turnHandleCommand(text)
          termui.withTerminalWriteLock:
            enterPromptInput(TurnPromptColor)
            termui.writeRaw(edPtr[].redrawBytes())
            if edPtr[].postRedraw != nil:
              edPtr[].postRedraw(edPtr[])
          if text.strip in [":q", ":quit", ":exit"]:
            acquire inputStateLock
            try:
              inputState.cmdWasQuit = true
            finally:
              release inputStateLock
            setInterrupted(true)
            break
        else:
          termui.withTerminalWriteLock:
            acquire inputStateLock
            try:
              inputState.queuedText = text
              inputState.queuedEchoRows = edPtr[].echoRows
              inputState.autoSend = true
              inputState.editorText = text
            finally:
              release inputStateLock
            emitFatPromptEvent setPromptModeEvent(pmBufferedInput)
      except minline.InputCancelled:
        requestTurnInterrupt()
        break
      except EOFError:
        if turnActive() and edPtr[].line.text.len == 0:
          acquire inputStateLock
          try:
            inputState.cmdWasQuit = true
          finally:
            release inputStateLock
          requestTurnInterrupt()
        break
      except CatchableError:
        break

    when defined(posix):
      if haveOldMode:
        discard fd.tcSetAttr(TCSADRAIN, addr oldMode)
    acquire inputStateLock
    try:
      inputState.residualText = edPtr[].line.text
      inputState.editorText = edPtr[].line.text
      if inputState.autoSend and inputState.queuedText == inputState.residualText:
        inputState.residualText = ""
    finally:
      release inputStateLock
    edPtr[].onMutate = nil
    edPtr[].onSubmit = nil
    edPtr[].preRedraw = nil
    edPtr[].postRedraw = nil
    edPtr[].deferSubmit = false
    edPtr[].renderSuffix = ""
    edPtr[].renderSuffixCursor = false
    edPtr[].getCh = nil
    edPtr[].write = nil
    edPtr[].getWidth = nil
    edPtr[].hasPendingInput = nil

proc beginTurn*() =
  ## Hide the terminal caret for the duration of the turn — the dim
  ## ❯ glyph (still painted, just not blinking) is the only
  ## visible marker while typing isn't possible.
  termui.hideCaret()
  emitFatPromptEvent setPromptModeEvent(pmTurnRunning)
  if inputEditor != nil and not inputThreadRunning:
    acquire inputStateLock
    try:
      inputState = InputState(turnActive: true)
    finally:
      release inputStateLock
    inputTurnActive.store(true, moRelease)
    inputEditorReady.store(false, moRelease)
    createThread(inputThread, inputThreadProc)
    inputThreadRunning = true
    let deadline = epochTime() + 0.5
    while not inputEditorReady.load(moAcquire) and epochTime() < deadline:
      sleep 5
    inputEditorReady.store(true, moRelease)

proc stopTurnInputForFinalRender*() =
  ## Stop the buffered input thread before final assistant text is committed.
  ## This closes the tiny race where a typing-ready-looking token bar is
  ## visible while the turn thread still owns input, without painting anything.
  if inputThreadRunning:
    acquire inputStateLock
    try:
      inputState.turnActive = false
    finally:
      release inputStateLock
    inputTurnActive.store(false, moRelease)
    joinThread(inputThread)
    inputThreadRunning = false

proc endTurn*(repaintPrompt = true) =
  ## Transition to typing-ready state: clear the bar at its current
  ## row, advance one row to leave a blank "gap" between the last
  ## content row and the bar, repaint bar+prompt with the bright
  ## cyan prompt color. Show the terminal caret. The gap is
  ## one-shot — `emitUserSubmit` overwrites it with the receipt at
  ## next submit, so it never persists in scroll history.
  # Defensive: nothing should be animating between turns. If a tool
  # path leaked the bar-tick thread (e.g. an uncaught exception
  # past the per-tool stopBarTick), the thread would otherwise keep
  # painting the bottom row with a ticking seconds counter forever.
  # Idempotent — these are no-ops when the threads aren't running.
  discard stopBarTick()
  stopSpinner()
  let hadInputThread = inputThreadRunning
  stopTurnInputForFinalRender()
  let hadTicker = fatPromptState.footer.ticker.len > 0
  if hadTicker:
    emitFatPromptEvent clearTickerEvent()
  let hadBar = currentBarLabel.len > 0
  var bytes = ""
  var label = ""
  if hadBar:
    label = currentBarLabel
    bytes = endTurnBytes(label, BrightPromptColor, repaintPrompt, currentTermW(),
                         currentBarHasGap)
  else:
    bytes = endTurnBytes("", BrightPromptColor, repaintPrompt)
  termui.endTurn(
    hadInputThread,
    inputEditor,
    hadBar,
    bytes,
    hadTicker,
    clearTickerBytes())
  if currentBarLabel.len > 0:
    if repaintPrompt:
      emitFatPromptEvent setBarEvent(label, hasGap = true)
    else:
      emitFatPromptEvent clearBarEvent()
  if repaintPrompt:
    emitFatPromptEvent setPromptModeEvent(pmIdle)

proc emitUserSubmit*(line: string, echoRows = -1) =
  ## Run the user-submit transition described in `submitTransitionBytes`
  ## using the current `pendingHint`, `currentBarHasGap`, and
  ## `currentBarLabel` state. The receipt overwrites the gap (or the
  ## bar's row if no gap), echoes the user's input as scroll-history
  ## content, and parks the cursor ready for the next `callModel`'s
  ## leading `\n`. When `currentBarLabel` is empty (prompt-only
  ## startup state), the walk-back skips the (non-existent) bar row.
  ##
  ## ``echoRows`` should be the visual row count occupied by the
  ## rendered input (the editor exposes this via ``LineEditor.echoRows``)
  ## so wrap-affected logical lines are walked back over correctly. When
  ## negative, the legacy ``splitLines(line).len`` is used (still
  ## correct as long as no logical line wraps).
  let receiptLabel =
    if pendingHint.active:
      tokenLineLabel(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    else: ""
  let hadGap = currentBarHasGap
  let hasBar = currentBarLabel.len > 0
  termui.submitUser(
    submitTransitionBytes(line, pendingHint.active, hadGap, receiptLabel,
                          hasBar, echoRows))
  emitFatPromptEvent clearPendingHintEvent()
  emitFatPromptEvent clearBarEvent()

proc emitBufferedUserSubmit*(line: string) =
  ## Echo a prompt that was queued by the background input thread during
  ## a model/tool turn. See ``bufferedSubmitTransitionBytes`` for the
  ## cursor contract.
  let receiptLabel =
    if pendingHint.active:
      tokenLineLabel(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    else: ""
  let hadGap = currentBarHasGap
  let hasBar = currentBarLabel.len > 0
  let editorRows = max(1, minline.totalRows(line, 2, 2, currentTermW()))
  termui.submitBufferedUser(
    editorRows,
    hasBar,
    bufferedSubmitTransitionBytes(line, pendingHint.active, hadGap,
                                  receiptLabel, hasBar))
