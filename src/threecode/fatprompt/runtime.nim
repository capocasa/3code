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
  ../signals, ../terminal as termui, ../session
import ../engine as termengine
import rendering
from ../api import ApiStreamHooks, requestTurnInterrupt, requestQuietShutdown,
  setApiStreamHooks, setInterrupted, QuietTooLongMs, clearNetworkQuiet


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
  ##      **token receipt** — the repaint of the previous bar's row
  ##      in the same cyan tone, leaving the receipt in scroll history
  ##      while a fresh bar (at zeros) takes its place at the new bottom.
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

var spinnerStop: Atomic[bool]
var spinnerFramePainted: Atomic[bool]
var spinnerThread: Thread[string]
var bufferedSubmitTurn: Atomic[bool]
var quietStop: Atomic[bool]
var quietThread: Thread[void]
var quietRunning = false
var lastProviderActivity: Atomic[int]

var barTickStop: Atomic[bool]
var commandStatusActive: Atomic[bool]
var barTickThread: Thread[void]
var barTickRunning = false
var barTickStart: float
var barTickBase: string
var barTickLock: Lock
barTickLock.initLock()

var apiCancelWatcherStarted = false

# --- Prompt draft flusher: snapshots the editor text to a draft sidecar on a
#     debounce so an unexpected shutdown never loses a half-typed prompt. It
#     reads the module-level editor/session globals under inputStateLock (the
#     same model as the bar-tick thread) instead of capturing them in a
#     closure. It is signaled to stop but never joined on cleanup (see below).
var draftDirty: Atomic[bool]
var draftFlusherStop: Atomic[bool]
var draftFlusherThread: Thread[void]
var draftFlusherRunning = false

var inputState*: InputState
var inputStateLock*: Lock
initLock(inputStateLock)
var inputTurnActive: Atomic[bool]
var inputEditorReady: Atomic[bool]
var inputIdleLinePending: Atomic[bool]
  ## Set by the input thread after an idle Enter; cleared by the controller
  ## when it drains the event or when beginTurn starts the next turn.
  ## The input thread's getCh returns -1 while this is set, parking the
  ## editor so keystrokes don't append to an uncleared prompt.
var inputThread: Thread[void]
var inputThreadRunning* = false

# The input thread owns the only code path that puts stdin into raw mode
# for sustained periods (the cancel watcher is transient). Its saved
# termios snapshot is kept here as module-level state so cleanup can
# restore stdin from any thread on exit, regardless of whether the input
# thread has unwound. `inputOrigTermiosValid` gates the restore.
when defined(posix):
  var inputOrigTermios: Termios
  var inputOrigTermiosValid = false

proc restoreInputTermios*() {.noconv.} =
  ## Restore stdin's termios to the snapshot the input thread captured
  ## before putting it in raw mode. Safe to call from any thread and
  ## idempotent; a no-op when no snapshot exists.
  when defined(posix):
    if inputOrigTermiosValid:
      discard tcSetAttr(STDIN_FILENO.cint, TCSADRAIN, addr inputOrigTermios)
      inputOrigTermiosValid = false
var spinnerRunning = false  # only mutated by main thread
var inputEditor*: ptr minline.LineEditor
var inputProfile*: ptr Profile
var inputSession*: ptr Session
var inputMessages*: ptr JsonNode
var activeCommandHook*: proc(cmd: string) {.gcsafe.}

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
  testSpinnerRequested: Atomic[int]
  testSpinnerPainted: Atomic[int]
  testTickerControlStarted: Atomic[bool]
  testTickerControlThread: Thread[void]
spinLabelLock.initLock()

proc testFrameMode(): bool =
  getEnv("THREECODE_TEST_FRAME_FD").len > 0

proc requestTestSpinnerFrame() =
  if not testFrameMode() or not spinnerRunning:
    return
  let requested = testSpinnerRequested.fetchAdd(1, moRelease) + 1
  while spinnerRunning and testSpinnerPainted.load(moAcquire) < requested:
    sleep 1

proc testTickerControlLoop() {.thread.} =
  when defined(posix):
    let fdText = getEnv("THREECODE_TEST_TICKER_FD")
    let ackText = getEnv("THREECODE_TEST_TICKER_ACK_FD")
    if fdText.len == 0:
      return
    let fd = try: cint(parseInt(fdText)) except CatchableError: return
    let ackFd =
      if ackText.len > 0:
        try: cint(parseInt(ackText)) except CatchableError: cint(-1)
      else:
        cint(-1)
    while true:
      var ch: array[1, char]
      let n = posix.read(fd, addr ch[0], 1)
      if n <= 0:
        break
      if ch[0] == 't':
        requestTestSpinnerFrame()
      if ackFd >= 0:
        var ack = 'a'
        discard posix.write(ackFd, addr ack, 1)

proc ensureTestTickerControlStarted() =
  if not testFrameMode():
    return
  if testTickerControlStarted.exchange(true, moAcquire):
    return
  createThread(testTickerControlThread, testTickerControlLoop)

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

proc currentSpinnerFooterFrame(): FooterFrame {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire spinLabelLock
    result = spinnerFooterFrame(
      if spinFrameShared.len > 0: spinFrameShared else: "○",
      spinLabelShared,
      spinTickerShared,
      spinElapsedShared)
    release spinLabelLock

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

proc liveEditorFooterAnchored*(): bool =
  ## True when we can pin the live turn editor to absolute terminal rows.
  ## This is the production/PTY path. Pipe-backed unit tests and redirected
  ## output keep the older relative cursor contract because there is no real
  ## terminal floor to anchor to.
  inputThreadRunning and inputEditor != nil and terminalHeight() > 0 and
    stdout.isatty

proc pushInputEvent*(ev: InputEvent) =
  ## Called by the input thread to queue a completed line/command/interrupt.
  acquire inputStateLock
  try:
    inputState.eventQueue.add ev
  finally:
    release inputStateLock

proc pollInputEvent*(): InputEvent =
  ## Called by the controller to drain the next queued event. Returns
  ## `ieNone` when the queue is empty. Does NOT unpark the input thread:
  ## the consuming controller path must clear the editor first, then call
  ## ``releaseIdleSubmittedInput`` (idle) or ``beginTurn`` (turn). Unparking
  ## here races the editor clear and lets the next keystrokes merge into
  ## stale editor text.
  acquire inputStateLock
  try:
    if inputState.eventQueue.len > 0:
      result = inputState.eventQueue[0]
      inputState.eventQueue.delete(0)
    else:
      result = InputEvent(kind: ieNone)
  finally:
    release inputStateLock

proc hasQueuedAutosend*(): bool =
  ## True when the queue has at least one ieLine event — the background
  ## editor has accepted Enter and the text is waiting.
  acquire inputStateLock
  try:
    for ev in inputState.eventQueue:
      if ev.kind == ieLine:
        return true
  finally:
    release inputStateLock

proc consumeQueuedInput*(line: var string; echoRows: var int;
                         cmdWasQuit: var bool;
                         wasInterrupt: var bool): bool =
  ## Drain the next line, command, interrupt, or quit event from the queue.
  ## Returns true when a line or command was consumed. ``wasInterrupt`` is
  ## set when an idle Ctrl-C / ESC was handled entirely by the input thread
  ## (the editor already repainted the empty prompt in place), so the caller
  ## must skip the empty-line walk-back.
  let ev = pollInputEvent()
  case ev.kind
  of ieLine:
    line = ev.text
    echoRows = ev.echoRows
    return true
  of ieCommand:
    line = ev.text
    echoRows = ev.echoRows
    return true
  of ieQuit:
    cmdWasQuit = true
  of ieInterrupt:
    wasInterrupt = true
  of ieNone:
    discard

proc setActiveCommandHook*(hook: proc(cmd: string) {.gcsafe.}) =
  activeCommandHook = hook

proc releaseIdleSubmittedInput*() =
  ## Let the persistent editor leave the submitted-line state after an idle
  ## controller path has consumed and committed the line. Model turns use
  ## ``beginTurn`` for the same acknowledgement.
  inputIdleLinePending.store(false, moRelease)

proc reserveEditorFooterForRedraw(ed: var minline.LineEditor) =
  ## Called by the editor before every redraw while a turn is active.
  ## The reserved footer height follows the editor's live rendered height
  ## (wraps, multiline input, history navigation, submit suffix). Cursor
  ## out: top row of the editor area. The subsequent editor redraw is the
  ## only code allowed to paint those rows.
  if not liveEditorFooterAnchored():
    return
  let frameModel =
    if spinnerRunning and spinnerStop.load(moRelaxed) == false:
      var frame: string
      var label: string
      var ticker: string
      var elapsed: int
      acquire spinLabelLock
      frame = spinFrameShared
      label = spinLabelShared
      ticker = spinTickerShared
      elapsed = spinElapsedShared
      release spinLabelLock
      spinnerFooterFrame(if frame.len > 0: frame else: "○", label, ticker,
                         elapsed)
    elif barTickRunning:
      var base: string
      acquire barTickLock
      base = barTickBase
      release barTickLock
      let elapsed = (epochTime() - barTickStart).int
      let label =
        if base.hasElapsedSuffix: base
        else: base & "  " & $elapsed & "s"
      tokenBarFrame(label)
  else:
    footerFrame(fatPromptState)
  termengine.beginEditorRedraw(ed, inputEditorReady.load(moAcquire),
                               frameModel)

var foregroundRedrawWrapped {.threadvar.}: bool
var foregroundRedrawEditor {.threadvar.}: ptr minline.LineEditor

proc beginForegroundEditorRedraw*(ed: var minline.LineEditor) =
  ## Foreground readline must redraw through the same footer wrapper as the
  ## buffered editor whenever a token bar is visible; otherwise standalone
  ## editor redraws can leave a stale partial prompt above a later bar repaint.
  foregroundRedrawWrapped = false
  if currentBarLabel.len == 0:
    return
  termengine.beginEditorRedraw(ed, true, footerFrame(fatPromptState))
  foregroundRedrawWrapped = true
  foregroundRedrawEditor = addr ed

proc finishForegroundEditorRedraw*() =
  if foregroundRedrawWrapped:
    foregroundRedrawWrapped = false
    if foregroundRedrawEditor != nil:
      termengine.finishEditorRedraw(foregroundRedrawEditor[])
      foregroundRedrawEditor = nil
    else:
      termui.finishEditorRedraw()

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

proc paintBarPrompt*(label: string) =
  ## Write bar + prompt at the cursor's current row, parking cursor
  ## at col 0 of the bar row. Caches `label` so a later
  ## `repaintBarPrompt` knows what to draw. Clears `currentBarHasGap`
  ## — during streaming the bar slides flush with content; only
  ## `endTurn` paints a gap.
  debugOut "paintBarPrompt label=" & label[0..min(30, label.len-1)]
  emitFatPromptEvent setBarEvent(label)
  if liveEditorFooterAnchored():
    termengine.renderFooter(footerFrame(fatPromptState),
                             inputThreadRunning, inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(hideRealCaretBytes() & barFooterBytes(label, currentTermW()))

proc setBarPromptState*(label: string) =
  ## Update the logical bar label without painting immediately. Used when a
  ## completed response still needs to be committed to scrollback first; the
  ## subsequent transcript append repaints the footer with this final label.
  emitFatPromptEvent setBarEvent(label)

proc paintBarBelow*(label: string) =
  ## Paint bar + prompt one and two rows below the cursor, restoring
  ## the cursor to its original (likely mid-line) position. Used
  ## during streaming to keep the bar visible while content is being
  ## accumulated in memory and the cursor stays put.
  emitFatPromptEvent setBarEvent(label)
  if liveEditorFooterAnchored():
    termengine.renderFooter(footerFrame(fatPromptState),
                             inputThreadRunning, inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(barFooterBelowBytes(label, currentTermW()))

proc paintBarBelowAtCol(label: string; col: int) =
  emitFatPromptEvent setBarEvent(label)
  if liveEditorFooterAnchored():
    termengine.renderFooter(footerFrame(fatPromptState),
                             inputThreadRunning, inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(barFooterBelowAtColBytes(label, col, currentTermW()))

proc clearBarBelowAtCol(col: int) =
  if liveEditorFooterAnchored():
    termengine.renderFooter(clearFooterFrame(), inputThreadRunning,
                             inputEditor)
  else:
    termengine.syncWrite(clearBarBelowAtColBytes(col))

proc repaintBarPrompt*() =
  ## Re-emit the bar+prompt at the cursor's current row using the
  ## cached `currentBarLabel`. Used by `writeTranscriptWithFatPrompt` to put the bar
  ## back after a content write.
  if currentBarLabel.len == 0: return
  if liveEditorFooterAnchored():
    termengine.renderFooter(footerFrame(fatPromptState),
                             inputThreadRunning, inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(hideRealCaretBytes() &
      barFooterBytes(currentBarLabel, currentTermW()))

proc clearBarPrompt*() =
  ## Erase the bar + prompt rows in place. Cursor parks at col 0 of
  ## the bar row so the caller can write content there (which then
  ## pushes the next `repaintBarPrompt` one row down).
  if liveEditorFooterAnchored():
    termengine.renderFooter(clearFooterFrame(), inputThreadRunning,
                             inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(ClearBarPromptBytes)

proc paintPromptOnly*()

proc enterPromptInput*() =
  ## Prepare the physical cursor for either immediate input or buffered
  ## input during a running turn. In bar mode, repaint the shared
  ## bar+prompt footer and park on the prompt row. In prompt-only mode,
  ## clear the prompt row in place. The line editor writes its own prompt
  ## glyph after this, so the prepainted glyph is only a stable visual
  ## placeholder.
  if currentBarLabel.len > 0:
    if currentBarHasGap and pendingHint.active:
      termengine.syncWrite(clearPromptAfterPendingReceiptBytes())
    else:
      clearBarPrompt()
    termui.enterPromptInput(
      true,
      barFooterBytes(currentBarLabel, currentTermW()),
      "")
  else:
    termui.enterPromptInput(
      false,
      "",
      promptOnlyBytes())

proc resetPromptInputAfterEmpty*(echoRows: int) =
  ## Empty submission should leave the prompt/footer at the same visual
  ## floor instead of drifting downward. `echoRows` is the editor's visual
  ## input height, including wraps.
  let n = max(1, echoRows)
  if currentBarLabel.len == 0:
    termui.resetPromptInputAfterEmpty(
      false,
      n,
      promptOnlyResetBytes(),
      "")
    emitFatPromptEvent clearBarEvent()
  else:
    termui.resetPromptInputAfterEmpty(
      true,
      n,
      "",
      hideRealCaretBytes() &
        barFooterBytes(currentBarLabel, currentTermW()))

proc resetEditorRowModel(ed: ptr minline.LineEditor) =
  ## Clear the live editor's text and row geometry so it presents as a single
  ## empty row. The submit path calls this inside the terminal-write lock,
  ## atomically with the transcript append, so background repainters cannot
  ## observe a stale multi-row editor after a prompt is committed as scrollback.
  if ed == nil: return
  ed[].line = minline.Line(text: "", position: 0)
  ed[].renderSuffix = ""
  ed[].renderSuffixCursor = false
  ed[].renderRow = 0
  ed[].echoRows = 0

proc commitTranscriptBytes*(transcriptBytes: string; restoreEditor = true;
                            beforeRepaint: proc() = nil;
                            reserveFooter = true;
                            transcriptOwnsSpacing = false) =
  ## Commit transcript output while preserving the volatile footer.
  ## The controller owns the transcript bytes and item spacing. This proc owns
  ## the terminal mechanics: clear the volatile footer, append the bytes as
  ## scrollback, then repaint whatever footer state remains. ``beforeRepaint``
  ## runs after transcript bytes are known but before repaint bytes are
  ## computed, so a controller can convert a live bar into a receipt and clear
  ## it without fatprompt reintroducing stale chrome.
  debugOut &"writeTranscriptWithFatPrompt enter barLabel={currentBarLabel.len}"
  let oldFooter = footerFrame(fatPromptState)
  if receiptTouchesNextResponse and transcriptBytes.hasNonNewlineBytes:
    receiptTouchesNextResponse = false
  if beforeRepaint != nil:
    beforeRepaint()
  let newFooter = footerFrame(fatPromptState)
  # The submit path (restoreEditor=false) commits the prompt as scrollback and
  # then drops the editor chrome. Reset the editor's row model inside the same
  # terminal-write critical section as the transcript append: without this,
  # there is a window between appendTranscript (which reads the editor's
  # pre-submit row model) and the controller's later reset where a background
  # repainter (spinner/bar-tick) can observe a stale multi-row editor and
  # over-walk its clear into the just-committed scrollback rows.
  if not restoreEditor and inputEditor != nil:
    withTerminalWriteLock:
      termengine.appendTranscript(
        transcriptBytes,
        liveEditorFooterAnchored(),
        inputThreadRunning,
        inputEditor,
        oldFooter,
        newFooter,
        0,
        restoreEditor,
        reserveFooter,
        transcriptOwnsSpacing)
      resetEditorRowModel(inputEditor)
  else:
    termengine.appendTranscript(
      transcriptBytes,
      liveEditorFooterAnchored(),
      inputThreadRunning,
      inputEditor,
      oldFooter,
      newFooter,
      0,
      restoreEditor,
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
  ## Spinner footer rooted at the cursor row:
  ##   row N     optional reasoning ticker when reasoning streams
  ##   row N+1   spinner frame + token-slot bar
  ##   row N+2   prompt editor row when live buffered typing is active
  ## The ticker is a real fat-prompt row, not a scrollback overlay.
  ## See `spinnerFooterBytes` for the byte sequence each frame writes.
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  var lastTicker = ""
  var observedTestTick = testSpinnerPainted.load(moAcquire)
  while not spinnerStop.load(moRelaxed):
    let elapsed =
      if testFrameMode():
        while not spinnerStop.load(moRelaxed) and
            testSpinnerRequested.load(moAcquire) <= observedTestTick:
          sleep 1
        if spinnerStop.load(moRelaxed):
          break
        observedTestTick = testSpinnerRequested.load(moAcquire)
        0.0
      else:
        epochTime() - start
    let label = getSpinLabel()
    let ticker = getSpinTicker()
    lastTicker = ticker
    try:
      let frame = frames[i mod frames.len]
      setSpinFrame(frame, elapsed.int)
      termengine.renderFooter(
        spinnerFooterFrame(frame, label, ticker, elapsed.int),
        inputThreadRunning,
        inputEditor,
        currentTermW())
      spinnerFramePainted.store(true, moRelaxed)
      if testFrameMode():
        testSpinnerPainted.store(observedTestTick, moRelease)
    except CatchableError: discard
    if not testFrameMode():
      sleep 80
    inc i
  try:
    let termW = try: terminalWidth() except CatchableError: 80
    if not inputThreadRunning:
      # gap+bar is always 2 rows; a wrapping ticker may add more.
      let tickerRows =
        if lastTicker.len == 0: 1
        else: max(1, (visibleWidth(lastTicker) + max(1, termW) - 1) div max(1, termW))
      termengine.syncWrite(spinnerCleanupBytes(1 + tickerRows))
  except CatchableError: discard

proc liveLabel*(base: string, slurped: int): string =
  ## Spinner label whose token slots match the per-call summary's shape:
  ## icon hugs value. ↑/↻ read as `0` until
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
  if parts.len == 2 and parts[1].startsWith("↓"):
    parts.join(" ")
  else:
    parts.join("  ")

proc paintInitialBar*(p: Profile) =
  ## Welcome-time paint: one blank gap row, then bar+prompt at zero
  ## values *with* a `○ 0%` context indicator (the empty-circle glyph
  ## is the same one a populated bar carries — at startup we just
  ## haven't sent a request yet, so promptTokens is 0). Bright cyan
  ## prompt — typing-ready. Sets `currentBarHasGap = true` to match
  ## `endTurn`'s shape between turns.
  termengine.writeRaw("\n")
  let window = contextWindowFor(p)
  let baseLabel = contextLabel(0, window)
  paintBarPrompt(liveLabel(baseLabel, 0))
  emitFatPromptEvent setBarEvent(currentBarLabel, hasGap = true)

proc paintPromptOnly*() =
  ## Paint just the prompt ❯ at the cursor's current row, no token
  ## bar above. Used in the pre-first-turn startup state where we have
  ## no real token values yet — the bar stays hidden until the first
  ## model response brings them. Cursor parks at col 0 of the prompt
  ## row.
  ##
  ## Leaves `currentBarLabel = ""` and `currentBarHasGap = false` —
  ## the signals `readInput`, `emitUserSubmit`, and the slash-command
  ## repaint use to detect prompt-only mode.
  termengine.writeRaw(promptOnlyResetBytes())
  emitFatPromptEvent clearBarEvent()

proc paintInitialPrompt*(p: Profile) =
  ## Welcome-time paint when starting fresh. The first prompt is intentionally
  ## prompt-only; the token bar appears after the first response has real usage
  ## to display.
  paintPromptOnly()


# --- Bar tick: repaints the token bar with an incrementing elapsed counter
#     during tool execution. Bash tool viewports can also attach a compact
#     command-status row below the live output.

# Currency symbols rotated by the bar-tick thread while a bash command runs.
# The classic |/\-+timer command-status line lived here; the live bullet now
# carries the rotation instead.
var commandSymbolIndex: Atomic[int]

proc nextCommandSymbol*(): string =
  const symbols = ["$", "€", "£", "¥"]
  symbols[commandSymbolIndex.load(moAcquire) mod symbols.len]

proc barTickLoop() {.thread.} =
  var observedTick = testSpinnerPainted.load(moAcquire)
  while not barTickStop.load(moRelaxed):
    var base: string
    {.cast(gcsafe).}:
      acquire barTickLock
      base = barTickBase
      release barTickLock
    let elapsedMs = int((epochTime() - barTickStart) * 1000.0)
    let elapsed = elapsedMs div 1000
    let label =
      if base.hasElapsedSuffix: base
      else: base & "  " & $elapsed & "s"
    if commandStatusActive.load(moRelaxed):
      var advance = false
      if testFrameMode():
        let painted = testSpinnerPainted.load(moAcquire)
        if painted > observedTick:
          observedTick = painted
          advance = true
      else:
        advance = true
      if advance:
        discard commandSymbolIndex.fetchAdd(1, moRelease)
        termengine.updateToolViewportSymbol(nextCommandSymbol())
    # Re-assert hide-cursor each tick — same rationale as
    # `spinnerFooterBytes`: some terminals transiently re-show the
    # caret on cursor movement, and beginTurn's one-shot `?25l`
    # isn't enough to keep it hidden over a long-running tool.
    termengine.renderFooter(tokenBarFrame(label), inputThreadRunning,
                            inputEditor, currentTermW())
    sleep 250

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
  commandStatusActive.store(false, moRelaxed)
  return elapsed

# --- Prompt draft flusher loop -------------------------------------------
#
# The editor's `onMutate` only sets a dirty flag (it runs on the input thread
# and must stay fast). This thread owns the actual disk write. It sleeps on a
# short debounce and, when the flag is set, snapshots the live editor/session
# under inputStateLock — the same access pattern the bar-tick thread uses.
#
# Like the other background threads, it is NOT joined from cleanup: a signal
# may be delivered to this thread, and a thread joining itself deadlocks.
# cleanup() calls flushDraftNow() for a final synchronous save instead, and
# exit() tears the thread down. The stop flag lets the loop wind down promptly
# on a graceful shutdown regardless.

proc snapshotAndSaveDraft() =
  ## Take a consistent (session path, editor text) snapshot under the input
  ## lock and persist it as a draft. Called from the flusher thread and the
  ## synchronous final flush. Uses tryAcquire so a flush triggered from a
  ## signal handler (cleanup) can never block on a lock the input thread holds.
  var sessionPtr: ptr Session = nil
  var text = ""
  if tryAcquire(inputStateLock):
    try:
      sessionPtr = inputSession
      if inputEditor != nil:
        text = inputEditor[].line.text
    finally:
      release inputStateLock
  if sessionPtr != nil and sessionPtr[].savePath != "":
    saveDraft(sessionPtr[], text)

proc draftFlusherLoop() {.thread.} =
  while not draftFlusherStop.load(moRelaxed):
    if draftDirty.load(moAcquire):
      draftDirty.store(false, moRelease)
      {.cast(gcsafe).}:
        try: snapshotAndSaveDraft()
        except CatchableError: discard
    sleep 250

proc ensureDraftFlusherStarted*() =
  ## Start the background draft flusher once. Idempotent. Started alongside
  ## the persistent input thread so it is alive for the whole editing session.
  if draftFlusherRunning: return
  draftFlusherStop.store(false, moRelaxed)
  createThread(draftFlusherThread, draftFlusherLoop)
  draftFlusherRunning = true

proc stopDraftFlusher*() =
  ## Signal the flusher thread to stop (non-blocking; does not join). Safe to
  ## call from any thread, including the flusher thread itself, since it never
  ## waits on the thread. The loop checks the flag and exits within one sleep.
  draftFlusherStop.store(true, moRelaxed)

proc flushDraftNow*() =
  ## Persist the current draft synchronously. Called from cleanup as the last
  ## reliable save before teardown. No-op when no session path exists yet;
  ## otherwise writes unconditionally — we are shutting down, so a redundant
  ## write is cheap insurance against losing the in-flight prompt.
  draftDirty.store(false, moRelease)
  {.cast(gcsafe).}:
    try: snapshotAndSaveDraft()
    except CatchableError: discard

proc setCommandStatusActive*(active: bool) =
  commandSymbolIndex.store(0, moRelease)
  commandStatusActive.store(active, moRelaxed)

proc startSpinner*(label: string) =
  debugOut "startSpinner"
  if spinnerRunning: return
  ensureTestTickerControlStarted()
  if label.len > 0: setSpinLabel(label)
  let frame = "⠋"
  setSpinFrame(frame, 0)
  var initialLabel: string
  var initialTicker: string
  {.cast(gcsafe).}:
    acquire spinLabelLock
    initialLabel = spinLabelShared
    initialTicker = spinTickerShared
    release spinLabelLock
  termengine.renderFooter(
    spinnerFooterFrame(frame, initialLabel, initialTicker, 0),
    inputThreadRunning,
    inputEditor,
    currentTermW())
  spinnerFramePainted.store(true, moRelaxed)
  testSpinnerRequested.store(0, moRelease)
  testSpinnerPainted.store(0, moRelease)
  spinnerStop.store(false, moRelaxed)
  createThread(spinnerThread, spinnerLoop, "")
  spinnerRunning = true

proc stopSpinner*(clearLiveFooter = true) =
  debugOut "stopSpinner"
  if not spinnerRunning: return
  spinnerStop.store(true, moRelaxed)
  joinThread(spinnerThread)
  spinnerRunning = false
  if clearLiveFooter and inputThreadRunning and inputEditor != nil and
      spinnerFramePainted.load(moRelaxed):
    # The spinner footer is always gap+bar (2 rows) now that the ticker row
    # is permanently reserved.
    termengine.renderFooter(clearFooterFrame(2),
                            inputThreadRunning,
                            inputEditor,
                            currentTermW())

proc nowMs(): int =
  int(epochTime() * 1000.0)

proc markProviderActivity*() =
  lastProviderActivity.store(nowMs(), moRelaxed)

proc quietWatchLoop() {.thread.} =
  var lastFiredMs = 0
  while not quietStop.load(moRelaxed):
    let idleMs = nowMs() - lastProviderActivity.load(moRelaxed)
    if idleMs >= QuietTooLongMs:
      # No data for the full window: the provider has gone silent. Wake the
      # blocking recv and mark the connection dead. Deliberately does NOT
      # call `requestTurnInterrupt` — that would set `interruptedFlag` and
      # cause `callModel` to retry the error as "interrupted by user during
      # backoff", masking the real timeout. Instead the stream loop checks
      # `isNetworkQuiet()` directly and surfaces a dedicated error.
      # Re-fires periodically (via shutdown) in case a stale `SSL_read`
      # returned buffered data on the first wake and the main thread
      # re-entered a blocking read.
      let now = nowMs()
      if now - lastFiredMs > 10_000:  # Don't hammer shutdown every 500ms
        lastFiredMs = now
        requestQuietShutdown()
    sleep 500

proc startQuietWatch() =
  if quietRunning: return
  markProviderActivity()
  clearNetworkQuiet()
  quietStop.store(false, moRelaxed)
  createThread(quietThread, quietWatchLoop)
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
  let hadSpinnerFrame = spinnerFramePainted.load(moRelaxed)
  let oldFooter =
    if hadSpinnerFrame:
      currentSpinnerFooterFrame()
    else:
      footerFrame(fatPromptState)
  setSpinTicker("")
  let hadBufferedSubmit = bufferedSubmitTurn.load(moRelaxed)
  bufferedSubmitTurn.store(false, moRelaxed)
  stopSpinner(clearLiveFooter = false)
  ## Pause the bar-tick thread across the footer teardown + content start so it
  ## can't repaint the footer between prepareAssistantContentStart (which erases
  ## the footer area) and writeAssistantBullet/paintBarBelow (which anchor the
  ## new content).  A stray repaint in that window leaves a gap row in
  ## scrollback.
  let barTicks = stopBarTick()
  termengine.prepareAssistantContentStart(
    inputThreadRunning,
    inputEditor,
    oldFooter,
    hadBufferedSubmit,
    flush = false)
  termui.withTerminalWriteLock:
    writeAssistantBullet()
    s.started = true
    paintBarBelow(s.currentLabel(slurpedNow))
    s.liveBarBelow = true
  if barTicks > 0:
    startBarTick(s.baseLabel)

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
        paintBarPrompt(s.currentLabel(slurpedNow))
        s.liveBarAtCursor = true
      inc i
    else:
      let start = i
      while i < bytes.len and bytes[i] != '\n':
        inc i
      s.writeLiveSegment(bytes[start ..< i])
  if s.started:
    if s.liveBarAtCursor:
      paintBarPrompt(s.currentLabel(slurpedNow))
    else:
      paintBarBelowAtCol(s.currentLabel(slurpedNow), s.liveCol)
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
        let rendered = assistantTextBytes(s.captureMd(s.pendingLine))
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
    let rendered = assistantTextBytes(s.captureMd(s.pendingLine))
    s.pendingLine = ""
    s.writeRendered(rendered, slurpedNow)
  let tail = assistantTextBytes(s.captureMd("", finish = true))
  s.writeRendered(tail, slurpedNow)
  if s.started and s.liveBarBelow:
    paintBarPrompt(s.currentLabel(slurpedNow))
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
  setSpinTicker("")
  let startsAfterReceipt = followupStartsAfterReceipt
  followupStartsAfterReceipt = false
  termui.withTerminalWriteLock:
    if not startsAfterReceipt and not liveEditorFooterAnchored():
      stdout.write "\x1b[?25l\n"
      stdout.flushFile
  setSpinLabel(liveLabel(baseLabel, 0))
  startSpinner("")
  startQuietWatch()
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

proc apiReasoningDelta*(reasoning, baseLabel: string; slurped: int;
                        contentStarted: bool) =
  let termW = try: terminalWidth() except CatchableError: 80
  let budget = max(20, termW - 6)
  let tail =
    if reasoning.len > budget: reasoning[reasoning.len - budget .. ^1]
    else: reasoning
  var flat = newStringOfCap(tail.len)
  for ch in tail:
    flat.add(if ch == '\n' or ch == '\r': ' ' else: ch)
  setSpinTicker("  … " & flat)
  requestTestSpinnerFrame()

proc apiContentDelta*(chunk, baseLabel: string; slurped: int): bool =
  apiLiveStream.feedContent(chunk, slurped)
  requestTestSpinnerFrame()
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
        termengine.writeRaw(ClearBarBelowBytes)
        apiLiveStream.liveBarBelow = false
      termui.eraseRowsAbove(trailingNl - 1)
      paintBarPrompt(apiLiveStream.currentLabel(slurped))

proc apiAfterLiveContent*(baseLabel: string; slurped: int) =
  if apiLiveStream.liveBarBelow:
    termengine.syncWrite(moveToBarBelowBytes())
  setSpinLabel(liveLabel(baseLabel, slurped))
  startSpinner("")

proc apiFinalUsage*(usage: Usage; window, elapsed: int;
                    assistantContent: string; streamedLive: bool) =
  let label = tokenLineLabel(usage, window, elapsed)
  let hadTicker = fatPromptState.footer.ticker.len > 0
  setSpinTicker("")
  if streamedLive or assistantContent.strip.len == 0:
    emitFatPromptEvent clearTickerEvent()
    emitFatPromptEvent setBarEvent(label)
    if liveEditorFooterAnchored():
      termengine.renderFooter(footerFrame(fatPromptState),
                              inputThreadRunning, inputEditor,
                              currentTermW())
    else:
      let clearTicker =
        if hadTicker: "\r\x1b[1A\x1b[2K\r\n"
        else: ""
      termengine.syncWrite(clearTicker & hideRealCaretBytes() &
        barFooterBytes(label, currentTermW()))
  else:
    if hadTicker:
      emitFatPromptEvent clearTickerEvent()
    setBarPromptState(label)
  emitFatPromptEvent setPendingHintEvent(usage, window, elapsed)
  if window > 0 and usage.promptTokens.float > 0.7 * window.float and
     usage.promptTokens.float <= SummarizeThresholdFrac * window.float:
    writeTranscriptWithFatPrompt:
      subtleWriteLn(stdout,
        &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-summarization will fire near {humanTokens(int(SummarizeThresholdFrac * window.float))}; :summarize to act now")

proc apiNoUsage*(elapsed: int) =
  writeTranscriptWithFatPrompt:
    hint &"  · {elapsed}s", resetStyle, "\n"

proc apiRetryNotice*(msg: string) =
  ## Controller-side retry notice committed as a harness line: non-bold
  ## magenta, no indent, no bullet. Same scrollback contract as
  ## `interrupted by user`: one ordinary line, fat prompt preserved, not
  ## persisted to the `.3log` (it is not a conversation message).
  writeTranscriptWithFatPrompt:
    stdout.styledWrite(fgMagenta, msg, resetStyle)
    stdout.write "\r\n"

proc installApiStreamHooks*() =
  setApiStreamHooks(ApiStreamHooks(
    beforeCall: apiBeforeCall,
    afterCall: apiAfterCall,
    progress: apiProgress,
    setStatusLabel: apiSetStatusLabel,
    startSpinner: startSpinner,
    stopSpinner: proc() = stopSpinner(clearLiveFooter = false),
    providerActivity: apiProviderActivity,
    reasoningDelta: apiReasoningDelta,
    contentDelta: apiContentDelta,
    contentFinished: apiContentFinished,
    trimTrailingContent: apiTrimTrailingContent,
    afterLiveContent: apiAfterLiveContent,
    finalUsage: apiFinalUsage,
    noUsage: apiNoUsage,
    retryNotice: apiRetryNotice))
proc inputThreadProc() {.thread.} =
  ## Runs readline for the UI lifetime. Completed text is queued for the
  ## controller; during active turns the same editor keeps accepting buffered
  ## input for autosend.
  {.cast(gcsafe).}:
    if inputEditor == nil:
      return
    let edPtr = inputEditor
    proc inputRunning(): bool =
      acquire inputStateLock
      try:
        result = not inputState.shutdown
      finally:
        release inputStateLock
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
        while inputRunning():
          if inputIdleLinePending.load(moAcquire):
            sleep(5)
            continue
          if pendingInput.len > 0 or fillPending(200.cint):
            result = pendingInput[0]
            pendingInput.delete(0)
            return
          # SIGWINCH is caught with SA_RESTART, so poll() is restarted
          # rather than returning EINTR. Detect the resize via the shared
          # flag on each poll cycle and surface it as IOError so readLineWith
          # redraws the editor and footer at the new geometry.
          if consumeResizePending():
            markResizePending()
            raise newException(IOError, "terminal resized")
          if errno == EINTR:
            continue
        -1
      let hasPendingInput: minline.HasPendingInputProc = proc(): bool =
        # Peek-aware: only report a pending tail when the next buffered byte
        # is a valid escape-sequence continuation. A printable byte (the
        # user's next keystroke right after pressing Escape) stays in the
        # buffer for normal processing, so ESC + typing cancels instead of
        # swallowing the first typed character.
        if pendingInput.len == 0:
          discard fillPending(minline.EscapeTailPollMs.cint)
        pendingInput.len > 0 and minline.isEscapeTailByte(pendingInput[0])
    else:
      let getCh: minline.GetChProc = proc(): int =
        while inputRunning():
          if inputIdleLinePending.load(moAcquire):
            sleep(5)
            continue
          return getchr().int
        -1
      let hasPendingInput: minline.HasPendingInputProc = nil

    let writeProc: minline.WriteProc = proc(s: string) =
      termengine.writeRaw(s)

    edPtr[].onMutate = proc(ed: var minline.LineEditor) =
      acquire inputStateLock
      try:
        discard
      finally:
        release inputStateLock
      # Mark the prompt draft dirty so the flusher thread persists the current
      # editor text on its debounce. No I/O here — the input thread stays fast.
      draftDirty.store(true, moRelease)
    edPtr[].onCancelDeferredSubmit = proc(ed: var minline.LineEditor) =
      # The user resumed typing after a queued submit: drop the matching
      # ieLine events from the queue so the next Enter re-queues the edited
      # text rather than submitting a stale copy.
      acquire inputStateLock
      try:
        var i = inputState.eventQueue.high
        while i >= 0:
          if inputState.eventQueue[i].kind == ieLine and
             inputState.eventQueue[i].text == ed.line.text:
            inputState.eventQueue.delete(i)
          dec i
      finally:
        release inputStateLock
    edPtr[].onSubmit = proc(ed: var minline.LineEditor) =
      if inputTurnActive.load(moAcquire) and ed.line.text.startsWith(":"):
        let cmd = ed.line.text
        let rows = minline.totalRows(ed.line.text, ed.promptW, ed.contPromptW,
                                     max(2, ed.width))
        pushInputEvent(InputEvent(kind: ieCommand, text: cmd, echoRows: rows))
        ed.line = minline.Line(text: "", position: 0)
        ed.renderSuffix = ""
        ed.renderSuffixCursor = false
        ed.renderRow = 0
        ed.echoRows = 0
        if activeCommandHook != nil:
          activeCommandHook(cmd)
        return
      let rows = minline.totalRows(ed.line.text, ed.promptW, ed.contPromptW,
                                    max(2, ed.width))
      let hasText = ed.line.text.len > 0
      if hasText:
        pushInputEvent(InputEvent(kind: ieLine, text: ed.line.text,
                                   echoRows: rows))
      if inputTurnActive.load(moAcquire) and hasText:
        ed.pendingCaret = true
      else:
        ed.line.position = ed.line.text.len
        # Park the input thread so keystrokes don't append to the
        # uncleared editor before the controller drains this event.
        if hasText:
          inputIdleLinePending.store(true, moRelease)
      ed.renderSuffix =
        if inputTurnActive.load(moAcquire) and hasText:
          " " & DeferredSubmitMarker
        else: ""
      ed.renderSuffixCursor = false
    edPtr[].preRedraw = proc(ed: var minline.LineEditor) =
      reserveEditorFooterForRedraw(ed)
    edPtr[].postRedraw = proc(ed: var minline.LineEditor) =
      termengine.finishEditorRedraw(ed, showCaret = not ed.pendingCaret)
      inputEditorReady.store(true, moRelease)

    when defined(posix):
      if isatty(fd) != 0 and fd.tcGetAttr(addr inputOrigTermios) == 0:
        inputOrigTermiosValid = true
        var rawMode = inputOrigTermios
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
    while inputRunning():
      try:
        let text = minline.readLineWith(edPtr[],
                                        EditorPromptBytes,
                                        getCh, writeProc,
                                        hasPendingInput = hasPendingInput)
        # onSubmit already pushed the event and called activeCommandHook.
        # This path fires only when deferSubmit is false (idle Enter),
        # which never happens in practice; still handle it defensively.
        if text.len == 0:
          continue
        if text[0] == ':':
          # idle colon commands: push a line event since there's no
          # activeCommandHook wired for idle mode; the controller handles it.
          pushInputEvent(InputEvent(kind: ieLine, text: text,
                                     echoRows: edPtr[].echoRows))
        else:
          pushInputEvent(InputEvent(kind: ieLine, text: text,
                                     echoRows: edPtr[].echoRows))
        edPtr[].line = minline.Line(text: "", position: 0)
        edPtr[].renderSuffix = ""
        edPtr[].renderSuffixCursor = false
        edPtr[].renderRow = 0
        edPtr[].echoRows = 0
      except minline.InputCancelled:
        if inputTurnActive.load(moAcquire):
          requestTurnInterrupt()
          edPtr[].line = minline.Line(text: "", position: 0)
          edPtr[].renderSuffix = ""
          edPtr[].renderSuffixCursor = false
          edPtr[].renderRow = 0
          continue
        # At idle: clear the draft in place and signal an interrupt. The
        # editor's renderRow still tracks the cursor's visual row from the
        # last typing repaint, so fullRedraw walks up to the draft's top row,
        # erases to end (clearing every wrapped row), and repaints an empty
        # prompt there. The cursor lands on that single row, so the next
        # readLineWith's resetForRead + fullRedraw (renderRow = 0) repaints at
        # the same spot. Do NOT fake an empty ieLine: the controller would
        # then run resetPromptInputAfterEmpty, whose walk-up assumes the
        # cursor sits at the bottom of the just-cleared region; after this
        # in-place repaint the cursor is at the top, so the walk-up would
        # erase real scrollback above the prompt. Push ieInterrupt so the
        # controller drains and continues with no walk-back of its own.
        edPtr[].line = minline.Line(text: "", position: 0)
        edPtr[].renderSuffix = ""
        edPtr[].renderSuffixCursor = false
        edPtr[].echoRows = 0
        # readLineWith's defer nilled ed.write when it raised, so restore it
        # for this in-place repaint. renderRow still tracks the cursor's
        # visual row from the last typing repaint, so fullRedraw walks up to
        # the draft's top row, erases to end (clearing every wrapped row),
        # and repaints an empty prompt there.
        edPtr[].write = writeProc
        minline.fullRedraw(edPtr[])
        edPtr[].write = nil
        pushInputEvent(InputEvent(kind: ieInterrupt))
        continue
      except EOFError:
        if inputTurnActive.load(moAcquire) and edPtr[].line.text.len == 0:
          requestTurnInterrupt()
          continue
        # A pending idle line means the controller hasn't consumed the
        # submit yet; getCh returned -1 for backpressure, not because
        # stdin closed. Don't push ieQuit—wait for the controller.
        if not inputTurnActive.load(moAcquire) and
           inputIdleLinePending.load(moAcquire):
          continue
        pushInputEvent(InputEvent(kind: ieQuit))
        break
      except CatchableError:
        # A transient error (pty write backpressure, etc.) must not kill the
        # input thread: a dead thread leaves the prompt painted but frozen
        # — caret never moves, keystrokes silently dropped. Reset the editor
        # state and retry the loop while we are still running.
        edPtr[].line = minline.Line(text: "", position: 0)
        edPtr[].renderSuffix = ""
        edPtr[].renderSuffixCursor = false
        edPtr[].renderRow = 0
        edPtr[].deferSubmit = false
        sleep 10
        continue

    restoreInputTermios()
    edPtr[].onMutate = nil
    edPtr[].onSubmit = nil
    edPtr[].onCancelDeferredSubmit = nil
    edPtr[].preRedraw = nil
    edPtr[].postRedraw = nil
    edPtr[].deferSubmit = false
    edPtr[].renderSuffix = ""
    edPtr[].renderSuffixCursor = false
    edPtr[].getCh = nil
    edPtr[].write = nil
    edPtr[].getWidth = nil
    edPtr[].hasPendingInput = nil

proc ensureInputThreadStarted*() =
  if inputEditor != nil and not inputThreadRunning:
    acquire inputStateLock
    try:
      inputState.shutdown = false
    finally:
      release inputStateLock
    inputEditorReady.store(false, moRelease)
    createThread(inputThread, inputThreadProc)
    inputThreadRunning = true
    ensureDraftFlusherStarted()
    let deadline = epochTime() + 0.5
    while not inputEditorReady.load(moAcquire) and epochTime() < deadline:
      sleep 5
    inputEditorReady.store(true, moRelease)

proc beginTurn*() =
  ## Hide the physical terminal caret for the duration of the turn. The
  ## prompt glyph stays visible as the stable visual anchor.
  ensureInputThreadStarted()
  termui.hideCaret()
  emitFatPromptEvent setPromptModeEvent(pmTurnRunning)
  acquire inputStateLock
  try:
    inputState.turnActive = true
  finally:
    release inputStateLock
  inputTurnActive.store(true, moRelease)
  inputIdleLinePending.store(false, moRelease)

proc stopTurnInputForFinalRender*() =
  ## Mark the persistent input thread as idle before final assistant text is
  ## committed. The thread itself remains alive so idle and active prompt input
  ## keep the same editor path.
  if inputThreadRunning:
    acquire inputStateLock
    try:
      inputState.turnActive = false
    finally:
      release inputStateLock
    inputTurnActive.store(false, moRelease)

proc endTurn*(repaintPrompt = true) =
  ## Transition to typing-ready state: clear the bar at its current
  ## row, advance one row to leave a blank "gap" between the last
  ## content row and the bar, repaint bar+prompt, and show the terminal
  ## caret. The gap is
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
  let oldFooter = footerFrame(fatPromptState)
  stopTurnInputForFinalRender()
  let hadTicker = fatPromptState.footer.ticker.len > 0
  if hadTicker:
    emitFatPromptEvent clearTickerEvent()
  let hadBar = currentBarLabel.len > 0
  var bytes = ""
  var label = ""
  if hadBar:
    label = currentBarLabel
    let gapAlready =
      if hadInputThread: currentBarHasGap
      else: false
    bytes = endTurnBytes(label, repaintPrompt, currentTermW(), gapAlready)
  else:
    bytes = endTurnBytes("", repaintPrompt)
  termengine.endTurn(
    hadInputThread,
    inputEditor,
    oldFooter,
    bytes)
  if currentBarLabel.len > 0:
    if repaintPrompt:
      emitFatPromptEvent setBarEvent(label, hasGap = true)
    else:
      emitFatPromptEvent clearBarEvent()
  if repaintPrompt:
    emitFatPromptEvent setPromptModeEvent(pmIdle)

proc endTurnAfterTranscriptAppend*() =
  ## Complete a turn after the controller has already appended the final
  ## assistant transcript item and repainted the live footer. Do not walk
  ## upward or repaint prompt chrome here; this proc only finalizes terminal
  ## mode/state so no transient prompt-only or duplicate-token frame appears.
  discard stopBarTick()
  stopSpinner()
  let hadTicker = fatPromptState.footer.ticker.len > 0
  if hadTicker:
    emitFatPromptEvent clearTickerEvent()
  let label = currentBarLabel
  termengine.writeRaw("\x1b[?25h")
  if label.len > 0:
    emitFatPromptEvent setBarEvent(label, hasGap = true)
  emitFatPromptEvent setPromptModeEvent(pmIdle)

proc emitUserSubmit*(line: string) =
  ## Append the submitted prompt as transcript and clear the volatile editor
  ## area. The editor text itself is data; the on-screen prompt is chrome.
  let receiptLabel =
    if pendingHint.active:
      tokenLineLabel(pendingHint.usage, pendingHint.window, pendingHint.elapsed)
    else: ""
  var bytes = ""
  if receiptLabel.len > 0:
    bytes.add receiptBytes(receiptLabel)
    bytes.add "\r\n\r\n"
  # The prompt echo is the last scrollback block before the turn's footer
  # takes over. The footer (spinner on submit, idle bar otherwise) opens with
  # its own cleared gap/ticker row, which is the visible separator. Ending
  # with a full "\r\n\r\n" would strand that gap as a second, redundant
  # blank row between the prompt and the bar. End the line only.
  bytes.add formatUserPromptItem(line)
  bytes.add "\r\n"
  proc clearSubmittedFooterState() =
    emitFatPromptEvent clearPendingHintEvent()
    emitFatPromptEvent clearBarEvent()
    emitFatPromptEvent clearTickerEvent()
  receiptTouchesNextResponse = true
  commitTranscriptBytes(
    bytes,
    restoreEditor = false,
    beforeRepaint = clearSubmittedFooterState,
    reserveFooter = false,
    transcriptOwnsSpacing = true)
