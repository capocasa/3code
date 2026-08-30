## Live fat-prompt runtime.
##
## This module owns the prompt/footer/editor/spinner side effects used while a
## turn is running. The turn controller calls these helpers directly and also
## registers them as API stream hooks. `api.nim` must not import this module.

import std/[atomics, json, locks, os, osproc, strformat, strutils, terminal,
  times, unicode]
when defined(posix):
  import std/posix except SocketHandle
  import posix/termios
when defined(windows):
  import std/winlean
  const
    ENABLE_PROCESSED_INPUT = 0x0001'i32
    ENABLE_LINE_INPUT = 0x0002'i32
    ENABLE_ECHO_INPUT = 0x0004'i32
    CTRL_C_EVENT = 0'i32
    CTRL_BREAK_EVENT = 1'i32
  proc getConsoleMode(h: Handle; mode: ptr int32): int32 {.stdcall,
      dynlib: "kernel32", importc: "GetConsoleMode".}
  proc setConsoleMode(h: Handle; mode: int32): int32 {.stdcall,
      dynlib: "kernel32", importc: "SetConsoleMode".}
  proc setConsoleCtrlHandler(handlerRoutine: pointer; add: WinBool):
      WinBool {.stdcall, dynlib: "kernel32",
      importc: "SetConsoleCtrlHandler".}
  proc conioKbhit(): cint {.header: "<conio.h>", importc: "_kbhit".}
import ../types, ../util, ../compact, ../display, ../minline,
  ../signals, ../terminal as termui, ../session
import ../engine as termengine
import rendering
from ../toolstream import StreamMaxLines, initStreamingView, addLine,
  viewportRowsAt, bannerRowCountAt
from ../api import ApiStreamHooks, requestTurnInterrupt, requestQuietShutdown,
  setApiStreamHooks, setInterrupted, QuietTooLongMs, clearNetworkQuiet


when defined(windows):
  proc consoleCtrlHandler(ctrlType: int32): WinBool {.stdcall, gcsafe.} =
    if ctrlType == CTRL_C_EVENT or ctrlType == CTRL_BREAK_EVENT:
      try: requestTurnInterrupt()
      except CatchableError: discard
      return 1.WinBool
    0.WinBool

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
  ## while the user reads). Cleared by every bar repaint
  ## (during streaming, the bar slides flush with
  ## content — no gap mid-turn). Read by `emitUserSubmit` so the
  ## receipt repaints the gap row in place — overwriting the blank,
  ## leaving the receipt flush below the LLM content with no
  ## permanent gap in scroll history.

var spinnerFramePainted: Atomic[bool]
var bufferedSubmitTurn: Atomic[bool]
var quietStop: Atomic[bool]
var quietThread: Thread[void]
var quietRunning = false
var lastProviderActivity: Atomic[int]

var commandStatusActive: Atomic[bool]
var barTickStart: float
var commandSymbolIndex: Atomic[int]
  ## Currency-symbol rotation index for the bash tool viewport's command
  ## row, advanced by the GUI thread while a bash command runs.

proc nextCommandSymbol*(): string =
  const symbols = ["$", "€", "£", "¥"]
  symbols[commandSymbolIndex.load(moAcquire) mod symbols.len]

# --- Single GUI animation thread: the sole background painter of
#     `renderFooter`. Replaces the two-thread `spinnerLoop` (80ms) /
#     `barTickLoop` (250ms) design that both repainted the footer region
#     independently. The controller sets `frameModelShared.mode` to pick
#     what to paint and signals the thread (dirty); height-transition
#     paths (`startContent`, `endTurn`) `stopGui` before reading
#     `paintedFooterRows`, so no stale repaint can survive a transition.
var guiStop: Atomic[bool]
var guiRunning = false
var guiThread: Thread[string]

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
  ## Set by the persistent prompt's `onSubmit` after an idle Enter;
  ## cleared by `wizardReadLine` once the modal returns. The
  ## persistent prompt's `getCh` parks while this is true (and
  ## `inputModalActive == false`) so the controller has a chance
  ## to drain the event; the wizard's `getCh` deliberately ignores
  ## it. See the wizard protocol header above `wizardRequest`.
var inputModalActive*: Atomic[bool]
  ## Held for the lifetime of a modal wizard, including the gaps
  ## between `wizardReadLine` calls while the wizard's caller does
  ## post-processing (verify round-trip, status lines, ledger
  ## writes). The input thread's editor hooks consult this flag and
  ## skip their work while it is set, so the wizard owns the
  ## terminal without racing the hook bodies. A torn read of a
  ## closure field (one word zero, the other the prior value) is a
  ## SIGSEGV when the input thread calls the torn closure, so all
  ## hook bodies must check this flag instead of relying on the
  ## modal to nil the field.
  ##
  ## Successful submits keep the flag held: the wizard's caller may
  ## still be writing to stdout (the verifier line and
  ## `added <name>` status both land after the last prompt submits).
  ## The controller calls `wizardFinish` once the entire sequence,
  ## including caller post-writes, has flushed. Cancel and EOF
  ## release it inline because there is nothing left to race and the
  ## cancel handler's in-place `fullRedraw` already anchors the
  ## prompt.

# --- Modal wizard RPC. The controller (main thread) blocks in
#     `wizardReadLine` while the input thread runs a one-shot
#     `readLineWith` for the wizard prompt. The input thread is the
#     only owner of stdin and the termios raw mode, so routing the
#     wizard through it eliminates the dual-`posix.read` race that
#     caused flaky cancel + SIGSEGV on `:provider edit`/`:provider add`.
#
#     ## Protocol (one round-trip)
#
#     1. Main thread (caller of `wizardReadLine`): fills
#        `wizardRequest` under `wizardRequestLock`, then sets
#        `wizardRequestPosted = true`. The lock is for the request
#        struct only — the posted/response flags are atomic and
#        lock-free.
#     2. Input thread (running `inputThreadProc`): the persistent
#        `readLineWith`'s `getCh` sees `wizardRequestPosted == true`
#        and returns the `wizardSentinel` (-2). `readLineWith`
#        raises `WizardSwitched`; the outer loop's `except
#        minline.WizardSwitched` branch clears the editor and
#        `continue`s to the top.
#     3. Input thread (top of outer loop): sees
#        `wizardRequestPosted == true`, clears the flag, sets
#        `inputModalActive = true` (gates the hook bodies so the
#        wizard owns the terminal), reads the request, sets
#        `deferSubmit = false` + `submitIcon = ""` (the wizard's
#        values; the persistent prompt is parked, so no save
#        needed), and runs a one-shot `minline.readLineWith` with
#        the same `getCh` / `writeProc` / `hasPendingInput`
#        closures the persistent prompt uses.
#     4. The wizard's `readLineWith` returns (Enter → submit,
#        Ctrl-C / ESC → `InputCancelled`, Ctrl-D on empty →
#        `EOFError`). The input thread's `except` branches build a
#        `WizardReadResponse`, `finally` restores
#        `deferSubmit`/`submitIcon`, the unified publish path
#        stores the response and sets `wizardResponsePosted = true`.
#        On cancel / EOF the flag also clears `inputModalActive`
#        immediately; on a successful submit the flag stays held
#        until the controller calls `wizardFinish`, so the input
#        thread does not race the wizard caller's post-processing
#        (verify round-trip, status lines, ledger writes) by
#        repainting the persistent prompt on the row the wizard
#        just left. The input thread `continue`s back to the outer
#        loop, where it parks in `inputModalActive` (or exits to
#        the persistent `readLineWith` when the controller finally
#        releases the flag).
#     5. Main thread: wakes up, reads the response under the lock,
#        resets the editor fields, clears `inputIdleLinePending`,
#        and either returns the line or raises `InputCancelled` /
#        `EOFError`. The successful-submit path leaves
#        `inputModalActive` held; the controller must call
#        `wizardFinish` after the wizard's caller has fully
#        processed the response and flushed its terminal output, so
#        the input thread can repaint the persistent prompt on a
#        fresh row.
#
#     ## Why not a condvar
#
#     We match the existing `releaseIdleSubmittedInput` /
#     `consumeQueuedInput` idiom: an atomic flag + 5ms `sleep`
#     poll. The wizard prompts are interactive (user typing speed)
#     so 5ms latency is invisible. A condvar would shave the
#     wakeup latency but would not simplify the code (we'd still
#     need the lock for the request/response structs, and the
#     persistent prompt's `getCh` already needs the
#     `wizardRequestPosted` flag for its own yield check).
#
#     ## Call sites covered
#
#     All production modal prompts go through `wizardReadLine` via
#     `ui.readRequired` / `ui.readOptional`. The standalone
#     `minline.readLine` is test-only (sets its own termios raw
#     mode, no input thread). `api.conn.readLine` is the HTTP read,
#     not a UI prompt. No production code uses `editor.readLine`
#     directly. Audited 2026-01; no exceptions found.
var wizardRequest: WizardReadRequest
var wizardResponse: WizardReadResponse
var wizardRequestPosted: Atomic[bool]
  ## Set by `wizardReadLine` (main thread) when a wizard prompt is
  ## pending. The input thread's `getCh` returns the wizard sentinel
  ## when this is true, so the persistent `readLineWith` yields. The
  ## input thread clears this when it picks the request up at the
  ## top of its outer loop.
var wizardResponsePosted: Atomic[bool]
  ## Set by the input thread when it has published a response; cleared
  ## by `wizardReadLine` after it consumes the response. The
  ## handshake is: main thread sets request, input thread clears
  ## request + sets response, main thread clears response.
var wizardRequestLock: Lock
initLock(wizardRequestLock)

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
when defined(windows):
  var inputOrigConsoleMode: int32 = 0
  var inputOrigConsoleModeValid = false

proc restoreInputTermios*() {.noconv.} =
  ## Restore stdin's termios to the snapshot the input thread captured
  ## before putting it in raw mode. Safe to call from any thread and
  ## idempotent; a no-op when no snapshot exists.
  when defined(posix):
    if inputOrigTermiosValid:
      discard tcSetAttr(STDIN_FILENO.cint, TCSADRAIN, addr inputOrigTermios)
      inputOrigTermiosValid = false
  when defined(windows):
    if inputOrigConsoleModeValid:
      let h = getStdHandle(STD_INPUT_HANDLE)
      discard setConsoleMode(h, inputOrigConsoleMode)
      inputOrigConsoleModeValid = false
var inputEditor*: ptr minline.LineEditor
var inputProfile*: ptr Profile
var inputSession*: ptr Session
var inputMessages*: ptr JsonNode
var activeCommandHook*: proc(cmd: string) {.gcsafe.}

# Shared mutable animation state. All footers are built from the unified
# `frameModelShared` (under `frameModelLock`); the legacy per-field spin
# vars are gone. `testSpinnerRequested`/`testSpinnerPainted` are the tty
# test harness's deterministic-frame handshake: the GUI thread blocks until
# a request arrives, paints one frame, then stores the ack.
var
  testSpinnerRequested: Atomic[int]
  testSpinnerPainted: Atomic[int]
  viewportPaintRequested: Atomic[int]
  viewportPainted: Atomic[int]
  testTickerControlStarted: Atomic[bool]
  testTickerControlThread: Thread[void]

var
  frameModelLock: Lock
  frameModelShared: FrameModel
frameModelLock.initLock()

proc setFrameModel*(m: FrameModel) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared = m
    release frameModelLock

proc getFrameModel*(): FrameModel {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    result = frameModelShared
    release frameModelLock

proc setAnimMode*(mode: AnimationMode) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.mode = mode
    release frameModelLock

proc setAnimLabel*(label: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.label = label
    release frameModelLock

proc setAnimTicker*(ticker: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.ticker = ticker
    release frameModelLock

proc setAnimSpinner*(spinner: string; elapsed: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.spinner = spinner
    frameModelShared.elapsed = elapsed
    release frameModelLock

proc setAnimViewport*(banner: string; lines: openArray[string];
                      exitCode = -1; idx = 0;
                      maxLines = StreamMaxLines) {.gcsafe.} =
  ## Push a snapshot of the bash tool viewport's raw inputs into the shared
  ## model. During `amBarTick` the GUI thread owns the viewport+footer
  ## composite: it re-derives the wrapped rows from this snapshot at the
  ## live terminal width each tick (so a resize re-wraps instead of
  ## replaying stale pre-wrap rows), applies the rotating command symbol,
  ## and paints the whole composite via `renderToolViewport`. The
  ## controller calls this instead of rendering the viewport directly,
  ## removing the two-writer race on `engine.toolViewportRows`.
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.viewport = ViewportSnapshot(
      active: true, banner: banner, lines: @lines,
      exitCode: exitCode, idx: idx, maxLines: maxLines)
    release frameModelLock

proc clearAnimViewport*() {.gcsafe.} =
  ## Mark the viewport snapshot inactive (no live bash tool viewport).
  {.cast(gcsafe).}:
    acquire frameModelLock
    frameModelShared.viewport = ViewportSnapshot(active: false)
    release frameModelLock

proc currentFrameFromModel*(): FooterFrame {.gcsafe.} =
  ## Build the live `FooterFrame` from the unified `frameModelShared`.
  ## The animation threads and the input thread's editor redraw both use
  ## this so they can never observe a torn spinner-vs-barTick state.
  let m = getFrameModel()
  {.cast(gcsafe).}:
    case m.mode
    of amSpinner:
      spinnerFooterFrame(
        if m.spinner.len > 0: m.spinner else: "○",
        m.label, m.ticker, m.elapsed)
    of amBarTick:
      tokenBarFrame(m.label, m.ticker)
    of amIdle:
      footerFrame(fatPromptState)

proc testFrameMode(): bool =
  getEnv("THREECODE_TEST_FRAME_FD").len > 0

proc requestTestSpinnerFrame() =
  if not testFrameMode() or not guiRunning:
    return
  let requested = testSpinnerRequested.fetchAdd(1, moRelease) + 1
  while guiRunning and testSpinnerPainted.load(moAcquire) < requested:
    sleep 1

proc requestViewportPaint*() =
  ## In test mode, request one viewport composite paint from the GUI thread
  ## and block until it acknowledges. `runBashWithViewport.renderView` uses
  ## this to guarantee the pushed viewport rows are on screen before it
  ## emits a frame event, so the tty harness captures each streamed line as
  ## a discrete frame (no stale frame committed before the paint). A no-op
  ## outside test mode — the GUI thread's 80ms cadence paints the rows.
  if not testFrameMode() or not guiRunning:
    return
  let requested = viewportPaintRequested.fetchAdd(1, moRelease) + 1
  while guiRunning and viewportPainted.load(moAcquire) < requested:
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
  partialActive: bool
  partialStartCol: int
  ## Trailing-newline coalescing. A bare `\n` with an empty pending
  ## line marks a paragraph break; we defer committing it as a blank
  ## row until a non-empty line follows. Trailing breaks (stream ends
  ## before another line arrives) are dropped at `finishContent`, so the
  ## live stream never commits blank rows the receipt/separator would
  ## then have to delete. Interior breaks are flushed the moment real
  ## content resumes. This mirrors `splitLines` + `trimTranscriptTail`
  ## in the batch path.
  pendingBlank: bool

var apiLiveStream: LiveMarkdownStream

proc setSpinLabel(s: string) {.gcsafe.} =
  setAnimLabel(s)

proc getSpinLabel(): string {.gcsafe.} =
  getFrameModel().label

proc setSpinTicker(s: string) {.gcsafe.} =
  setAnimTicker(s)
  {.cast(gcsafe).}:
    if s.len == 0:
      emitFatPromptEvent clearTickerEvent()
    else:
      emitFatPromptEvent setTickerEvent(s)

proc getSpinTicker(): string {.gcsafe.} =
  getFrameModel().ticker

proc setSpinFrame(frame: string; elapsed: int) {.gcsafe.} =
  setAnimSpinner(frame, elapsed)

proc currentSpinnerFooterFrame(): FooterFrame {.gcsafe.} =
  let m = getFrameModel()
  spinnerFooterFrame(
    if m.spinner.len > 0: m.spinner else: "○",
    m.label, m.ticker, m.elapsed)

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
  ## Clear the persistent-prompt idle-submit flag. Called by
  ## `wizardReadLine` after a modal returns; the protocol comment
  ## above `wizardRequest` explains why the input thread is the
  ## single owner of this flag's lifecycle.
  inputIdleLinePending.store(false, moRelease)

proc reserveEditorFooterForRedraw(ed: var minline.LineEditor) =
  ## Called by the editor before every redraw while a turn is active.
  ## The reserved footer height follows the editor's live rendered height
  ## (wraps, multiline input, history navigation, submit suffix). Cursor
  ## out: top row of the editor area. The subsequent editor redraw is the
  ## only code allowed to paint those rows.
  if inputModalActive.load(moAcquire):
    return
  if not liveEditorFooterAnchored():
    return
  let m = getFrameModel()
  let frameModel =
    case m.mode
    of amSpinner:
      spinnerFooterFrame(
        if m.spinner.len > 0: m.spinner else: "○",
        m.label, m.ticker, m.elapsed)
    of amBarTick:
      # The elapsed suffix is ephemeral (changes every tick); recompute it
      # locally from the model's base label. The single GUI thread does the
      # same computation when painting bar-tick frames.
      let elapsed = (epochTime() - barTickStart).int
      let label =
        if m.label.hasElapsedSuffix: m.label
        else: m.label & "  " & $elapsed & "s"
      tokenBarFrame(label)
    of amIdle:
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

# ---------- Bar+prompt state helpers ----------

proc paintBarPrompt(label: string) =
  ## Paint bar + prompt at the cursor's current row, parking cursor
  ## at col 0 of the bar row. Caches `label` in the frame model so
  ## later repaints draw the same content. Clears `currentBarHasGap`
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

proc clearBarPrompt() =
  ## Erase the bar + prompt rows in place. Cursor parks at col 0 of
  ## the bar row so the caller can write content there (which then
  ## pushes the next bar repaint one row down).
  if liveEditorFooterAnchored():
    termengine.renderFooter(clearFooterFrame(), inputThreadRunning,
                             inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(ClearBarPromptBytes)

proc resetEditorRowModel*(ed: ptr minline.LineEditor) =
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
                            reserveFooter = true) =
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
        reserveFooter)
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
      reserveFooter)
  if reserveFooter and transcriptBytes.hasNonNewlineBytes and currentBarLabel.len > 0:
    emitFatPromptEvent setBarEvent(currentBarLabel, hasGap = true)
  debugOut "writeTranscriptWithFatPrompt exit"

proc guiLoop(unused: string) {.thread.} =
  ## The single background painter of `renderFooter`. Replaces the two-
  ## thread `spinnerLoop` (80ms) / `barTickLoop` (250ms) design: both
  ## repainted the same footer region on their own schedules with no
  ## coordination, leaving `paintedFooterRows` stale across the
  ## controller's height transitions. With one writer, the transition
  ## paths (`startContent`, `endTurn`) `stopGui` before reading
  ## `paintedFooterRows`, so no stale repaint can survive.
  ##
  ## Cadence: 80ms in normal mode (covers spinner glyph rotation and the
  ## bar-tick's whole-second counter — 250ms vs 80ms makes no visible
  ## difference since the counter shows whole seconds). In test frame
  ## mode, blocks on the `testSpinnerRequested`/`testSpinnerPainted`
  ## handshake so the tty harness can capture deterministic frames.
  const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  let start = epochTime()
  var i = 0
  var observedTestTick = testSpinnerPainted.load(moAcquire)
  var observedViewportTick = viewportPainted.load(moAcquire)
  while not guiStop.load(moRelaxed):
    let elapsed =
      if testFrameMode():
        # Wait for either a spinner frame request or a viewport paint
        # request. Both are controller-driven deterministic paint triggers
        # (the spinner via advanceTicker, the viewport via the
        # renderView() → requestViewportPaint handshake).
        while not guiStop.load(moRelaxed):
          if testSpinnerRequested.load(moAcquire) > observedTestTick: break
          if viewportPaintRequested.load(moAcquire) > observedViewportTick: break
          sleep 1
        if guiStop.load(moRelaxed): break
        observedTestTick = testSpinnerRequested.load(moAcquire)
        observedViewportTick = viewportPaintRequested.load(moAcquire)
        0.0
      else:
        epochTime() - start
    let m = getFrameModel()
    var paintedViewport = false
    try:
      case m.mode
      of amSpinner:
        let glyph = frames[i mod frames.len]
        setSpinFrame(glyph, elapsed.int)
        let frame = currentFrameFromModel()
        # When assistant content is streaming, the controller has painted
        # volatile partial rows into the engine. A bare `renderFooter` would
        # erase them (`\x1b[J`) and repaint only the footer, clobbering the
        # streaming partial. Instead paint the tracked live rows + the
        # animated footer as one composite (the same shape
        # `renderLiveContent` produces), so the spinner keeps rotating
        # without destroying the partial.
        if termengine.liveContentRowCount() > 0:
          termengine.repaintLiveContent(frame,
                                        inputThreadRunning, inputEditor,
                                        currentTermW())
        else:
          termengine.renderFooter(frame,
                                  inputThreadRunning, inputEditor,
                                  currentTermW())
        spinnerFramePainted.store(true, moRelaxed)
      of amBarTick:
        let secs = (epochTime() - barTickStart).int
        let label =
          if m.label.hasElapsedSuffix: m.label
          else: m.label & "  " & $secs & "s"
        let frame = tokenBarFrame(label)
        let snap = m.viewport
        if snap.active:
          # Re-derive the wrapped rows from the snapshot at the live
          # terminal width each tick. Pre-wrap rows frozen at an old width
          # stacked fragments into scrollback after a resize (the erase
          # walk-up lagged the rows the terminal actually held); re-wrapping
          # here keeps the painted rows and the engine's erase bookkeeping in
          # sync with the current geometry.
          let termW = currentTermW()
          var view = initStreamingView(
            snap.maxLines, snap.idx, snap.banner)
          view.exitCode = snap.exitCode
          # Apply the rotating command symbol (starts at `$`, index 0) for
          # the live "currency ticker" effect during bash execution. The
          # viewport repaints every 80ms; advance the index only every 4th
          # frame (~320ms/symbol) so it reads as a slow ticker, not a blur.
          # In test mode the index never advances so every captured frame
          # shows `$`, matching the golden fixtures. Skip once exitCode > 0:
          # `commandIcon` bakes the terminal `Ø` then.
          if commandStatusActive.load(moRelaxed) and snap.exitCode <= 0:
            if not testFrameMode() and i mod 4 == 0:
              discard commandSymbolIndex.fetchAdd(1, moRelease)
            view.symbol = nextCommandSymbol()
          for line in snap.lines:
            addLine(view, line)
          let bannerRows = bannerRowCountAt(view, termW)
          let rows = viewportRowsAt(view, termW)
          termengine.renderToolViewport(rows, frame,
                                        inputThreadRunning, inputEditor,
                                        termW, bannerRows)
        else:
          termengine.renderFooter(frame, inputThreadRunning, inputEditor,
                                  currentTermW())
        paintedViewport = true
      of amIdle:
        discard  # nothing to animate; the controller paints idle frames
      if testFrameMode():
        testSpinnerPainted.store(observedTestTick, moRelease)
        if paintedViewport:
          viewportPainted.store(observedViewportTick, moRelease)
    except CatchableError: discard
    if not testFrameMode():
      sleep 80
    inc i
  try:
    if not inputThreadRunning:
      # The ticker is always one row (clamped to width on render), so the
      # spinner footer is gap(1) + bar. Walk up one row to the gap and
      # erase down. Computing a wrapping row count from the raw ticker text
      # over-erased into committed scrollback — the render path already
      # overwrites the ticker in place, so no compensating removal is owed.
      termengine.syncWrite(spinnerCleanupBytes(1))
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

proc paintInitialPrompt*(p: Profile) =
  ## Welcome-time paint when starting fresh: gap row + token bar at zero
  ## usage + idle prompt, the same typing-ready shape `endTurn` and the
  ## resume path leave behind. The bar always shows the context percentage
  ## (design contract), so it is primed at `○0%` rather than hidden until
  ## the first response; `pendingHint` is primed with zeroed usage so the
  ## first user submit converts the bar into a receipt row exactly like
  ## every later turn.
  ##
  ## Paints through the engine's frame model when the live editor is
  ## anchored so `paintedFooterRows` tracks the chrome; the
  ## pre-input-thread path (no editor yet) falls back to a raw paint,
  ## cleared later by the walk-up's erase.
  let window = contextWindowFor(p)
  emitFatPromptEvent setBarEvent(contextLabel(0, window),
                                 hasGap = true)
  emitFatPromptEvent setPendingHintEvent(Usage(), window, -1)
  # The gap row between the welcome's last line and the bar: the same
  # blank row `endTurn` and the resume path leave above the bar. Without
  # it the bar paints flush against the hint line, and the first
  # keystroke's walk-up (sized from paintedFooterRows) erases the hint
  # instead of the gap.
  termengine.syncWrite("\r\n")
  if liveEditorFooterAnchored():
    termengine.renderFooter(footerFrame(fatPromptState),
                             inputThreadRunning, inputEditor,
                             currentTermW())
  else:
    # Raw gap + bar + prompt. Register the reserved rows so the first
    # later walk-up (spinner/bar paint, submit erase) does not under-count
    # and overwrite the line above the prompt.
    termengine.syncWrite(hideRealCaretBytes() &
      barPromptStartupBytes(fatPromptState.footer.barLabel, currentTermW()))
    termengine.noteFooterPainted(
      footerRowsAboveEditor(fatPromptState, currentTermW()))

proc paintResumedBarPrompt*(label: string) =
  ## Startup paint for --resume with prior usage: bar + idle prompt in the
  ## typing-ready shape `endTurn` leaves behind, carrying the resumed
  ## session's last usage. The caller (threecode.nim) has already primed
  ## `pendingHint` and the bar label in the frame model; this proc only
  ## paints. The input thread is not running yet, so unlike
  ## `paintBarPrompt` there is no anchored editor to repaint through the
  ## engine: paint the raw bytes and register their height so the first
  ## editor redraw's walk-up (renderRow + paintedFooterRows from the prompt
  ## row `barPromptStartupBytes` parks on) erases exactly this chrome and
  ## repaints in place instead of stacking a duplicate bar row per
  ## keystroke.
  if liveEditorFooterAnchored():
    termengine.renderFooter(footerFrame(fatPromptState),
                             inputThreadRunning, inputEditor,
                             currentTermW())
  else:
    termengine.syncWrite(hideRealCaretBytes() &
      barPromptStartupBytes(label, currentTermW()))
    termengine.noteFooterPainted(
      footerRowsAboveEditor(fatPromptState, currentTermW()))

# --- Bar tick: repaints the token bar with an incrementing elapsed counter
#     during tool execution. Bash tool viewports can also attach a compact
#     command-status row below the live output.

proc ensureGuiStarted() =
  ## Start the single GUI animation thread if it isn't running. Idempotent.
  ## The thread paints whatever `frameModelShared.mode` says; the controller
  ## switches modes via `startSpinner`/`startBarTick` without touching the
  ## thread itself. Headless (library) sessions never paint: the thread
  ## stays down and all rendering calls are engine-gated no-ops.
  if guiRunning: return
  if not termengine.engineOutputEnabled: return
  ensureTestTickerControlStarted()
  guiStop.store(false, moRelaxed)
  testSpinnerRequested.store(0, moRelease)
  testSpinnerPainted.store(0, moRelease)
  viewportPaintRequested.store(0, moRelease)
  viewportPainted.store(0, moRelease)
  createThread(guiThread, guiLoop, "")
  guiRunning = true

proc stopGui() =
  ## Signal the GUI thread to stop and join it. Joins with the terminal
  ## write lock dropped — the thread needs the lock to finish its current
  ## render frame and observe `guiStop`; joining while we hold the lock
  ## is a guaranteed deadlock.
  if not guiRunning: return
  guiStop.store(true, moRelaxed)
  termui.withTerminalLockDroppedForJoin:
    joinThread(guiThread)
  guiRunning = false

proc startBarTick*(base: string): bool =
  ## Returns true if this call started a new tick, false if one was
  ## already running (idempotent). Lets `withBarTick` know whether it
  ## owns the tick and must stop it on scope exit.
  debugOut "startBarTick"
  if getFrameModel().mode == amBarTick: return false
  setAnimLabel(base)
  setAnimMode(amBarTick)
  barTickStart = epochTime()
  ensureGuiStarted()
  return true

template withBarTick*(label: string; body: untyped) =
  ## RAII-style bar tick: starts the tick before `body`, stops it after,
  ## on any exit (normal, exception, return). Like withFile: the stop
  ## can't be forgotten because it's inherent to the scope. Returns true
  ## if a tick was started by this call (so callers can gate side effects
  ## like `prefixBoundary`).
  let barTickStarted = startBarTick(label)
  try:
    body
  finally:
    if barTickStarted:
      discard stopBarTick()

proc stopBarTick*(): int =
  ## Stops the bar tick, stops the GUI thread, and returns elapsed seconds.
  debugOut "stopBarTick"
  let m = getFrameModel()
  if m.mode != amBarTick: return 0
  let elapsed = (epochTime() - barTickStart).int
  clearAnimViewport()
  stopGui()
  commandStatusActive.store(false, moRelaxed)
  setAnimMode(amIdle)
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
  if label.len > 0: setSpinLabel(label)
  setSpinFrame("⠋", 0)
  setAnimMode(amSpinner)
  spinnerFramePainted.store(false, moRelaxed)
  ensureGuiStarted()
  # Paint one immediate frame so the spinner appears instantly (matches the
  # old startSpinner which rendered before createThread).
  termengine.renderFooter(currentFrameFromModel(),
                          inputThreadRunning, inputEditor,
                          currentTermW())
  spinnerFramePainted.store(true, moRelaxed)

proc stopSpinner*(clearLiveFooter = true) =
  debugOut "stopSpinner"
  if not guiRunning:
    setAnimMode(amIdle)
    return
  stopGui()
  setAnimMode(amIdle)
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
    # Sleep in short increments so the loop notices `quietStop` promptly and
    # `stopQuietWatch`'s joinThread returns without a long stall. A single
    # long nanosleep can leave the thread unscheduled past the join window
    # under heavy GC pressure from concurrent streaming allocations.
    var slept = 0
    while slept < 500 and not quietStop.load(moRelaxed):
      sleep 50
      slept += 50

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
  let path = tempDir() / "3code_live_md_" & $getCurrentProcessId()
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
  # Quiesce the GUI thread across the footer teardown + content start so it
  # can't repaint the footer between prepareAssistantContentStart (which
  # erases the footer area) and the first `renderLiveContent` (which anchors
  # the partial + new footer). A stray repaint in that window leaves a gap
  # row in scrollback. With one thread, this is the race closure: only the
  # GUI thread paints `renderFooter`, and it is stopped here, so
  # `prepareAssistantContentStart`'s `walkUp` reads a `paintedFooterRows`
  # no background thread can mutate.
  discard stopBarTick()
  termengine.prepareAssistantContentStart(
    inputThreadRunning,
    inputEditor,
    oldFooter,
    hadBufferedSubmit,
    flush = false)
  s.started = true
  # Restart the spinner so it keeps twirling through the streaming phase.
  # The guiLoop's amSpinner paint path paints the tracked live-content rows
  # + the animated footer as one composite (repaintLiveContent), so it can
  # no longer clobber the streaming partial the controller wrote. This
  # closes the mid-stream-stall gap: a provider that pauses between chunks
  # still shows a rotating spinner, instead of a frozen static bar.
  startSpinner("")

proc advanceLiveCol(s: var LiveMarkdownStream, text: string) =
  let termW = max(1, try: terminalWidth() except CatchableError: 80)
  s.liveCol += visibleWidth(text)
  while s.liveCol >= termW:
    s.liveCol -= termW

proc writeLiveSegment(s: var LiveMarkdownStream, text: string) =
  if text.len == 0: return
  if s.liveBarAtCursor:
    if liveEditorFooterAnchored():
      termengine.renderFooter(clearFooterFrame(), inputThreadRunning,
                              inputEditor, currentTermW())
    else:
      termengine.syncWrite(ClearBarPromptBytes)
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
  ## Streaming assistant text writes to the scrollback area while the live
  ## editor occupies the fat-prompt rows below. Both are serialized by the
  ## terminal write lock, and the caret is hidden for the whole turn, so the
  ## only real conflict would be an editor redraw landing on a content row.
  ## The redraw path (`reserveEditorFooterForRedraw` + `renderFooter`) paints
  ## only the reserved footer rows, never the scrollback, so streaming is safe
  ## alongside a live editor. Returning false unconditionally lets every
  ## provider's content flow to the screen as it arrives instead of being
  ## held back and dumped at end of turn.
  false

proc partialContentRows(s: LiveMarkdownStream): seq[string] =
  ## The volatile row(s) for the in-progress line: the bullet on the first
  ## emitted line, then the inline-markdown-rendered pending text wrapped to
  ## the terminal width. These rows are live chrome (erased/rewritten each
  ## chunk) until a newline commits them to real scrollback.
  let termW = max(1, try: terminalWidth() except CatchableError: 80)
  let bodyW = max(1, termW - 2)
  let styled = assistantTextBytes(applyInlineMd(s.pendingLine))
  if s.md.firstEmit:
    let chunks = wrapAnsi(styled, bodyW)
    if chunks.len == 0:
      result.add "\u25CF "
    else:
      for k, chunk in chunks:
        if k == 0:
          result.add AssistantTextStyle & "\u25CF " & Reset & chunk
        else:
          result.add "  " & chunk
  else:
    let chunks = wrapAnsi(styled, bodyW)
    if chunks.len == 0:
      result.add "  "
    else:
      for chunk in chunks:
        result.add "  " & chunk

proc renderPendingPartial(s: var LiveMarkdownStream, slurpedNow: int) =
  ## Paint the accumulating `pendingLine` as volatile live content so text
  ## flows as fast as chunks arrive, instead of being held back until a
  ## newline. The partial rows are erased and rewritten each chunk (they are
  ## live chrome, not scrollback); at a newline `commitPendingLine` sends the
  ## line through the block-level markdown renderer to real scrollback, so
  ## fences/tables/word-wrap match replay exactly.
  s.startContent(slurpedNow)
  emitFatPromptEvent setBarEvent(s.currentLabel(slurpedNow))
  # Use currentFrameFromModel() (not footerFrame(fatPromptState)) so the
  # footer the controller paints matches the one the guiLoop's amSpinner
  # path repaints every 80ms. During streaming the model is in amSpinner
  # mode; footerFrame(fatPromptState) would produce a static token-bar frame
  # (no glyph), which flickers against the guiLoop's animated spinner frame.
  termengine.renderLiveContent(s.partialContentRows(),
    currentFrameFromModel(), inputThreadRunning, inputEditor,
    currentTermW())
  s.partialActive = true

proc commitBlankLine(s: var LiveMarkdownStream) =
  ## Commit one blank paragraph-break row to real scrollback.
  commitTranscriptBytes(assistantTextBytes(""))
  termengine.clearLiveContent()
  s.partialActive = false

proc commitPendingLine(s: var LiveMarkdownStream, slurpedNow: int) =
  ## Commit the accumulated `pendingLine` to real scrollback through the
  ## block-level markdown renderer. `appendTranscript` walks up past the
  ## volatile partial (still tracked in the engine) to erase it, writes the
  ## committed render, and re-anchors the footer; then the partial tracking
  ## is cleared so the next line starts fresh. A deferred paragraph break
  ## (`pendingBlank`) is flushed first so interior blank rows land in order.
  if s.pendingBlank:
    s.pendingBlank = false
    s.commitBlankLine()
  let isFirstLine = s.md.firstEmit
  let body = s.captureMd(s.pendingLine)
  s.pendingLine = ""
  let rendered =
    if isFirstLine and body.len > 0:
      assistantTextBytes(AssistantTextStyle & "\u25CF " & Reset & body)
    else:
      assistantTextBytes(body)
  commitTranscriptBytes(rendered)
  termengine.clearLiveContent()
  s.partialActive = false

proc feedContent*(s: var LiveMarkdownStream, chunk: string, slurpedNow: int) =
  if chunk.len == 0: return
  if suppressLiveAssistantStream(): return
  termui.withTerminalWriteLock:
    # Drop leading blank lines before the first real content so model
    # padding never renders as blank rows above the answer. Once content
    # has started, blank lines are paragraph breaks handled by the
    # `pendingBlank` coalescing below (interior breaks commit, trailing
    # breaks are dropped at `finishContent`).
    var chunk = chunk
    if s.md.firstEmit:
      while chunk.len > 0 and (chunk[0] == '\n' or chunk[0] == '\r'):
        chunk.delete 0 .. 0
    var data = s.utf8Pending & chunk
    s.utf8Pending = ""
    var i = 0
    while i < data.len:
      if data[i] == '\n':
        if s.pendingLine.len == 0 and not s.md.firstEmit:
          # Bare newline with no accumulated text: a paragraph break.
          # Defer it as `pendingBlank` rather than committing at once,
          # so a trailing run of newlines never commits blank rows that
          # the receipt/separator would then have to delete. The break
          # is flushed by the next `commitPendingLine` (real content) or
          # dropped at `finishContent`.
          s.pendingBlank = true
        else:
          s.commitPendingLine(slurpedNow)
        inc i
      else:
        let charLen = utf8LenAt(data, i)
        if i + charLen > data.len:
          s.utf8Pending = data[i .. ^1]
          break
        s.pendingLine.add data[i ..< i + charLen]
        i += charLen
    if s.pendingLine.len > 0:
      s.renderPendingPartial(slurpedNow)
    stdout.flushFile()

proc finishContent*(s: var LiveMarkdownStream, slurpedNow: int) =
  if suppressLiveAssistantStream(): return
  if s.utf8Pending.len > 0:
    s.pendingLine.add s.utf8Pending
    s.utf8Pending = ""
  if s.pendingLine.len > 0:
    s.commitPendingLine(slurpedNow)
  # Drop a deferred trailing paragraph break: it was only meaningful if
  # more content followed. Keeping it would commit a blank row the
  # receipt/separator would have to compensate for.
  s.pendingBlank = false
  discard s.captureMd("", finish = true)
  if s.partialActive:
    termengine.clearLiveContent()
    s.partialActive = false

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

proc installWizardVerifyCancel*(jobDone: proc(): bool {.closure.};
                                cancelJob: proc() {.closure.}): bool =
  ## Watch stdin for Ctrl-C / ESC while a wizard runs a background job
  ## (provider verification). Between a wizard's `wizardReadLine` calls
  ## the input thread is parked on the wizard protocol, so without this
  ## watcher a blocking network probe swallows cancel keys (and echoes
  ## them into the next prompt). Mirrors `startCancelWatcher`: raw
  ## stdin, poll for 0x03/0x1b, cancel via `cancelJob`, drain + restore
  ## on the way out. Returns true when cancelled.
  when defined(posix):
    if isatty(0.cint) != 0:
      var orig, raw: Termios
      if tcGetAttr(0.cint, addr raw) == 0:
        orig = raw
        raw.c_lflag = raw.c_lflag and not Cflag(ICANON or ECHO or ISIG)
        raw.c_cc[VMIN] = 0.char
        raw.c_cc[VTIME] = 0.char
        if tcSetAttr(0.cint, TCSANOW, addr raw) == 0:
          defer:
            drainCancelInput()
            discard tcSetAttr(0.cint, TCSANOW, addr orig)
          while not jobDone():
            var pfd: TPollfd
            pfd.fd = 0.cint
            pfd.events = POLLIN
            let r = poll(addr pfd, 1.Tnfds, 50.cint)
            if r > 0 and (pfd.revents and POLLIN) != 0:
              var buf: array[64, char]
              let n = posix.read(0.cint, addr buf[0], buf.len)
              if n > 0:
                for i in 0 ..< n.int:
                  let b = buf[i].uint8
                  if b == 0x03 or b == 0x1b:
                    cancelJob()
                    return true
          return false
proc apiBeforeCall*(lastPromptTokens, window: int): string =
  let baseLabel = contextLabel(lastPromptTokens, window)
  result = baseLabel
  apiLiveStream = initLiveMarkdownStream(baseLabel)
  contentStreamedLive = false
  # A turn can end without `finishContent` clearing the volatile live-content
  # rows (interrupt before any content, a thrown error). Reset the engine's
  # tracker so a leftover from the previous turn can't corrupt this turn's
  # walk-up.
  termengine.clearLiveContent()
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
  ## Append-only: the scrollback is never edited after commit. Earlier
  ## code deleted trailing blank rows that the live stream had already
  ## committed (`eraseRowsAbove`) to compensate for the model emitting
  ## `\n\n` at the end of its reply. That violated the append-only
  ## scrollback contract. Trailing blank lines are now suppressed at
  ## the source in `feedContent`/`finishContent`, so there is nothing
  ## to retract here.
  discard

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
    commitTranscriptBytes(
      GreyFg &
        &"  · context at {humanTokens(usage.promptTokens)}/{humanTokens(window)} — auto-summarization will fire near {humanTokens(int(SummarizeThresholdFrac * window.float))}; :summarize to act now" &
        Reset & "\r\n", true)

proc apiNoUsage*(elapsed: int) =
  commitTranscriptBytes(&"  · {elapsed}s\r\n", true)

proc apiRetryNotice*(msg: string) =
  ## Controller-side retry notice committed as a harness line: non-bold
  ## magenta, no indent, no bullet, one line separated from surrounding
  ## items by exactly one blank row like every other transcript item.
  commitTranscriptBytes(errS(msg), true)

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

# ---------- Headless (library) stream hooks ----------
#
# A library session drives `runTurns` with no terminal: engine output is
# gated off (termengine.engineOutputEnabled = false) and these hooks replace
# the terminal rendering with plain callbacks. Lifecycle rendering still
# flows through `commitTranscriptBytes`, which termengine forwards to
# `headlessTranscriptHook` when output is disabled, so tool results and
# notices reach the embedder through one channel.

type
  HeadlessStreamHooks* = object
    ## Callbacks a library frontend provides. All optional; nil means the
    ## event is dropped. `contentFinished` returns the full assistant text
    ## of the model call; `finalUsage` carries per-call token usage.
    contentDelta*: proc(chunk: string) {.closure.}
    reasoningDelta*: proc(text: string) {.closure.}
    contentFinished*: proc(fullContent: string) {.closure.}
    finalUsage*: proc(usage: Usage; elapsed: int) {.closure.}
    retryNotice*: proc(msg: string) {.closure.}

var headlessStreamHooks*: HeadlessStreamHooks

proc installApiHeadlessHooks*(hooks: HeadlessStreamHooks) =
  ## Swap the terminal-bound api stream hooks for headless callbacks.
  ## Pair with `termengine.engineOutputEnabled = false`. Restoring the
  ## terminal path is `installApiStreamHooks()` + re-enabling output.
  headlessStreamHooks = hooks
  setApiStreamHooks(ApiStreamHooks(
    beforeCall: proc(lastPromptTokens, window: int): string =
      contextLabel(lastPromptTokens, window),
    afterCall: nil,
    progress: nil,
    setStatusLabel: nil,
    startSpinner: nil,
    stopSpinner: nil,
    providerActivity: markProviderActivity,
    reasoningDelta: proc(reasoning, baseLabel: string; slurped: int;
                         contentStarted: bool) =
      (if headlessStreamHooks.reasoningDelta != nil:
        headlessStreamHooks.reasoningDelta(reasoning)),
    contentDelta: proc(chunk, baseLabel: string; slurped: int): bool =
      (if headlessStreamHooks.contentDelta != nil:
        headlessStreamHooks.contentDelta(chunk)
       true),
    contentFinished: proc(fullContent, baseLabel: string;
                          slurped: int): bool =
      (if headlessStreamHooks.contentFinished != nil:
        headlessStreamHooks.contentFinished(fullContent)
       # Report "not streamed live" so runTurns commits the final text
       # through the transcript hook (the terminal path returns true here
       # only when its live renderer already painted every byte; a nil
       # contentDelta consumer would otherwise lose the reply entirely).
       headlessStreamHooks.contentDelta != nil),
    trimTrailingContent: nil,
    afterLiveContent: nil,
    finalUsage: proc(usage: Usage; window, elapsed: int;
                     assistantContent: string; streamedLive: bool) =
      (if headlessStreamHooks.finalUsage != nil:
        headlessStreamHooks.finalUsage(usage, elapsed)),
    noUsage: nil,
    retryNotice: proc(msg: string) =
      (if headlessStreamHooks.retryNotice != nil:
        headlessStreamHooks.retryNotice(msg))))
proc editBufferInExternalEditor(ed: var minline.LineEditor) =
  ## Alt+E / Ctrl+X Ctrl+E: copy the prompt buffer to a temp file, hand the
  ## terminal back to $VISUAL/$EDITOR, then replace the buffer with the
  ## edited text. The editor string is passed through the shell unquoted,
  ## like git: `VISUAL="code -w"` must reach the shell as flags.
  let tmpFile = tempDir() / ("3code_edit_" & $getCurrentProcessId())
  writeFile(tmpFile, ed.line.text)
  defer: removeFile(tmpFile)
  let editor = getEnv("VISUAL", getEnv("EDITOR",
    when defined(windows): "notepad" else: "vi"))
  when defined(posix):
    discard chmod(tmpFile, 0o600)
    # Suspend raw mode so the editor sees a cooked terminal: snapshot the
    # current (raw) mode, restore the cooked original, run the editor,
    # then re-apply the raw snapshot.
    var raw: Termios
    discard tcGetAttr(STDIN_FILENO.cint, addr raw)
    restoreInputTermios()
    termui.writeRaw("\x1b[?2004l\x1b[?25h")
    discard execShellCmd(editor & " " & quoteShell(tmpFile))
    discard tcSetAttr(STDIN_FILENO.cint, TCSADRAIN, addr raw)
    inputOrigTermios = raw
    inputOrigTermiosValid = true
    recordRawMode()
    termui.writeRaw("\x1b[?2004h")
  else:
    let h = getStdHandle(STD_INPUT_HANDLE)
    var rawMode: int32 = 0
    discard getConsoleMode(h, addr rawMode)
    restoreInputTermios()
    discard execShellCmd(editor & " " & quoteShell(tmpFile))
    discard setConsoleMode(h, rawMode and not
      (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT))
    inputOrigConsoleMode = rawMode
    inputOrigConsoleModeValid = true
  let edited = try: readFile(tmpFile) except CatchableError: ""
  var text = edited
  if text.endsWith("\n"):
    text.setLen(text.len - 1)
  if text != ed.line.text:
    ed.line.text = text
    ed.line.position = text.len
  minline.fullRedraw(ed)

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
      var stdinEof = false
      var startupDrainDone = false
      proc fillPending(waitMs: cint): bool =
        if pendingInput.len > 0:
          return true
        if stdinEof:
          return false
        var pfd: Tpollfd
        pfd.fd = STDIN_FILENO
        pfd.events = POLLIN
        let r = poll(addr pfd, 1.Tnfds, waitMs)
        # A closed write-end of a pipe (e.g. the stdin pipe `execCmdEx`
        # hands a spawned `3code`) reports POLLHUP without POLLIN on some
        # kernels, so checking POLLIN alone skips the read and busy-loops.
        # Treat any readiness (POLLIN, POLLHUP, POLLERR) as "try to read";
        # read() itself disambiguates data from EOF (0) vs error (-1).
        if r <= 0 or (pfd.revents and (POLLIN or POLLHUP or POLLERR)) == 0:
          return false
        var ch: char
        let n = posix.read(fd, addr ch, 1)
        if n == 1:
          pendingInput.add ch.ord.int
        elif n == 0:
          # poll() reports a closed/EOF fd (e.g. `/dev/null` stdin, a
          # daemonized process, or a closed PTY) as perpetually readable,
          # so without this latch `getCh` busy-loops on poll→read(0)
          # forever and never returns the -1 that signals EOF. Latch it:
          # stdin is at EOF for the process lifetime, so every later
          # `getCh` returns -1 and `readLineWith` raises EOFError.
          stdinEof = true
        result = pendingInput.len > 0

      let getCh: minline.GetChProc = proc(): int =
        while inputRunning():
          # Yield to a modal wizard if one is pending AND the wizard
          # hasn't actually started yet (i.e. the persistent prompt
          # is the active reader). The wizard's own readLineWith
          # sets `inputModalActive` and then runs under the same
          # `getCh` closure; we must NOT return the sentinel from
          # that inner call, or the wizard would cancel itself
          # before the user typed a thing.
          # Yield the persistent prompt while a wizard is pending.
          # The wizard branch at the top of the outer loop will run
          # its readLineWith; once it has picked the request up,
          # `wizardRequestPosted` is cleared and `inputModalActive`
          # is set, so the wizard's own getCh calls stop returning
          # the sentinel and the user can type into the wizard.
          if wizardRequestPosted.load(moAcquire):
            return minline.wizardSentinel
          # Drop escape sequences queued before the first readline
          # settled (an arrow pressed while the app was booting, or a
          # late terminal reply fragment). Without this drain a buffered
          # `ESC [ A` surfaces as historyPrevious and paints the last
          # history entry into the fresh prompt. The drain ends at the
          # first printable byte (real typed input is kept) or after
          # 500ms, so a user who intentionally holds an arrow at boot
          # still gets history recall once the prompt is live.
          if not startupDrainDone:
            let drainDeadline = epochTime() + 0.5
            while epochTime() < drainDeadline:
              if pendingInput.len == 0:
                discard fillPending(25.cint)
              if pendingInput.len == 0: break
              if pendingInput[0] == 27:
                # Drop ESC; structural tail bytes are consumed below.
                pendingInput.delete(0)
                continue
              # Structural tail bytes of CSI / OSC replies that can land
              # before the first prompt: `ESC [ A` (arrow), `ESC [ 6 n`
              # (DSR), `ESC ] 11 ; rgb:..BEL` (a late OSC 11 background
              # reply). The OSC charset adds `]`, the `rgb:` label, the
              # `/` separators, hex letters, and the BEL terminator, so
              # the whole reply drains here (the ESC was dropped above)
              # instead of surfacing as a ghost `]11;rgb:...` prompt.
              if pendingInput[0] in {'['.ord, 'O'.ord, ']'.ord} or
                 pendingInput[0] in {'0'.ord..'9'.ord} or
                 pendingInput[0] in {'a'.ord..'f'.ord, 'A'.ord..'F'.ord} or
                 pendingInput[0] in {';'.ord, '?'.ord, '~'.ord, ':'.ord,
                   '/'.ord, 7.ord} or
                 pendingInput[0] in {'H'.ord, 'R'.ord, 'c'.ord, 'Z'.ord,
                   'r'.ord, 'g'.ord, 'b'.ord}:
                pendingInput.delete(0)
                continue
              break
            startupDrainDone = true
          # Park the persistent prompt (not the wizard) on a stale
          # idle-submit; see the protocol header for the lifecycle.
          if inputIdleLinePending.load(moAcquire) and
             not inputModalActive.load(moAcquire):
            sleep(5)
            continue
          if pendingInput.len > 0 or fillPending(200.cint):
            result = pendingInput[0]
            pendingInput.delete(0)
            return
          # fillPending returned false. If stdin hit EOF, surface it as
          # -1 so readLineWith raises EOFError; otherwise it was just a
          # poll timeout / SIGWINCH, so keep looping.
          if stdinEof:
            return -1
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
        # Peek-aware: report a pending tail when the next buffered byte is
        # a valid escape-sequence continuation. Printable letters count as
        # tails (Alt-chord halves, e.g. ESC f = Alt+F); a bare Escape has
        # no tail within the EscapeTailPollMs window, so it cancels.
        # `handleEscape` dispatches bound Alt chords and cancels+putbacks
        # unbound ones, so ESC-then-typing still interrupts cleanly.
        if pendingInput.len == 0:
          discard fillPending(minline.EscapeTailPollMs.cint)
        pendingInput.len > 0 and minline.isEscapeTailByte(pendingInput[0])
    else:
      var startupDrainDone = false
      var drainedChar = -1
      let getCh: minline.GetChProc = proc(): int =
        while inputRunning():
          if wizardRequestPosted.load(moAcquire):
            return minline.wizardSentinel
          # Drop keys queued before the first readline settled (an arrow
          # pressed while the app was booting); see the posix branch above
          # for the full rationale. Console keys arrive as two-byte
          # `<prefix>, <key>` pairs via `_getch`, so whole pairs are
          # drained; a real typed byte ends the drain and is kept.
          if not startupDrainDone:
            let drainDeadline = epochTime() + 0.5
            while epochTime() < drainDeadline and conioKbhit() != 0:
              let first = getchr().int
              if first in minline.ESCAPES:
                # The pair's tail can trail its prefix by a scheduler
                # tick; without the wait a lone tail byte would surface
                # as a ghost character in the fresh prompt.
                let tailDeadline = epochTime() + 0.05
                while epochTime() < tailDeadline and conioKbhit() == 0:
                  sleep(1)
                if conioKbhit() != 0:
                  discard getchr()
                continue
              drainedChar = first
              break
            startupDrainDone = true
          if inputIdleLinePending.load(moAcquire) and
             not inputModalActive.load(moAcquire):
            sleep(5)
            continue
          if drainedChar != -1:
            result = drainedChar
            drainedChar = -1
            return result
          return getchr().int
        -1
      let hasPendingInput: minline.HasPendingInputProc = nil

    let writeProc: minline.WriteProc = proc(s: string) =
      termengine.writeRaw(s)

    # Dedicated writer for the modal wizard branch. The
    # implementation is identical to `writeProc`; the seam exists
    # so a future terminal recorder (or footer-suppression) can
    # pattern-match on which closure is installed without having to
    # thread `inputModalActive` through every layer of
    # `termengine`. The wizard's own `bracketed-paste` enable /
    # disable (`\x1b[?2004h` / `\x1b[?2004l`) and the
    # `redrawBytes(...)` frame flow through this writer, not the
    # persistent prompt's `writeProc`.
    let wizardWriteProc: minline.WriteProc = proc(s: string) =
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
      let modal = inputModalActive.load(moAcquire)
      if inputTurnActive.load(moAcquire) and ed.line.text.startsWith(":") and not modal:
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
      if hasText and not modal:
        # A modal wizard owns the editor; bytes the input thread steals
        # from the wizard's readline must not surface as controller
        # events or the controller will treat them as the next prompt.
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
      if inputModalActive.load(moAcquire):
        # The modal wizard owns the terminal during its prompts; the
        # input thread must not paint the footer or signal editor-ready,
        # or it will overwrite the wizard's UI.
        return
      termengine.finishEditorRedraw(ed, showCaret = not ed.pendingCaret)
      inputEditorReady.store(true, moRelease)
    # Hold the terminal write lock across editor mutation + redraw so the
    # background render threads (spinner/barTick) that read the same editor
    # state under this lock can never observe a half-mutated or freed buffer.
    edPtr[].preMutate = proc(ed: var minline.LineEditor) =
      termui.acquireTerminalWrite()
    edPtr[].postMutate = proc(ed: var minline.LineEditor) =
      termui.releaseTerminalWrite()
    edPtr[].editInEditor = proc(ed: var minline.LineEditor) =
      if inputModalActive.load(moAcquire): return
      editBufferInExternalEditor(ed)

    when defined(posix):
      if isatty(fd) != 0 and fd.tcGetAttr(addr inputOrigTermios) == 0:
        inputOrigTermiosValid = true
        # Capture the cooked mode once, before entering raw mode, so Ctrl-Z
        # can hand the terminal back to the shell in a readable state.
        recordCookedMode()
        var rawMode = inputOrigTermios
        rawMode.c_iflag = rawMode.c_iflag and not Cflag(BRKINT or ICRNL or
          INPCK or ISTRIP or IXON)
        rawMode.c_cflag = (rawMode.c_cflag and not Cflag(CSIZE or PARENB)) or CS8
        rawMode.c_lflag = rawMode.c_lflag and not Cflag(ECHO or ICANON or
          IEXTEN or ISIG)
        rawMode.c_cc[VMIN] = 1.char
        rawMode.c_cc[VTIME] = 0.char
        discard fd.tcSetAttr(TCSANOW, addr rawMode)
        # Feed the process-wide suspend/resume snapshot so Ctrl-Z can restore
        # this exact mode on resume. The runtime keeps its own copy
        # (inputOrigTermios) for exit cleanup; this one is for SIGTSTP.
        recordRawMode()
        # Enable bracketed paste for the process lifetime. `readLineWith`
        # used to enable/disable around every read; the toggle was
        # idempotent noise, and a per-read disable let the host shell
        # briefly see a paste before the next read re-enabled. The
        # disable on process exit is handled by `minline.restoreTerminal`
        # (registered as an exit proc), so the host shell is left in
        # its original state on clean exit. Hosts that don't support
        # bracketed paste (older `xterm`, some `screen` configs)
        # ignore the sequence silently.
        termui.writeRaw("\x1b[?2004h")

    when defined(windows):
      # Raw input: clear line/echo so keystrokes (including Ctrl-D 0x04)
      # are delivered to `_getch` unedited/unechoed. `ENABLE_PROCESSED_INPUT`
      # is kept so that in a real Windows console Ctrl-C raises
      # `CTRL_C_EVENT`, caught by `consoleCtrlHandler` below. Under the
      # ConPTY test harness conhost consumes 0x03 without forwarding it and
      # without raising the event, so the tty harness sends 0x04 instead
      # (see `tty_expect.ctrlC`). Restore on exit via `restoreInputTermios`.
      let h = getStdHandle(STD_INPUT_HANDLE)
      var mode: int32 = 0
      if getConsoleMode(h, addr mode) != 0:
        inputOrigConsoleMode = mode
        inputOrigConsoleModeValid = true
        discard setConsoleMode(h, mode and not
          (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT))
      # Route Ctrl-C / Ctrl-Break (real console) straight to the turn-
      # interrupt path via the console control handler.
      discard setConsoleCtrlHandler(
        cast[pointer](consoleCtrlHandler), 1.WinBool)

    edPtr[].deferSubmit = true
    edPtr[].submitIcon = DeferredSubmitMarker
    while inputRunning():
      if wizardRequestPosted.load(moAcquire):
        # A modal wizard is parked on the main thread waiting for a
        # response. Run a one-shot `readLineWith` for it, then publish
        # the result. The persistent prompt's `readLineWith` raised
        # `WizardSwitched` to land us here; its editor state was
        # already cleared by its own defer and the cancel/submit
        # handlers, so we only need to repaint the wizard's prompt.
        # Clear `wizardRequestPosted` up front so the persistent
        # loop's `getCh` no longer parks us on the sentinel during
        # the wizard's own readLineWith; the main thread's caller
        # The persistent prompt's getCh sees `wizardRequestPosted`
        # stay false from here on (we just cleared it above) and
        # stops returning the sentinel, so the persistent prompt is
        # ready to repaint as soon as the wizard's readLineWith
        # returns.
        wizardRequestPosted.store(false, moRelease)
        inputModalActive.store(true, moRelease)
        var req: WizardReadRequest
        var resp = WizardReadResponse(kind: wrSubmitted, text: "")
        acquire wizardRequestLock
        try:
          req = wizardRequest
        finally:
          release wizardRequestLock
        # Park deferSubmit so the wizard's Enter submits directly
        # (the wizard owns the response, not the queue). The
        # persistent prompt is the only other writer of these two
        # fields, and it is parked while `inputModalActive == true`,
        # so a `try/finally` around the wizard's readLineWith is
        # enough to bracket the field change — no per-call save
        # needed.
        edPtr[].deferSubmit = false
        edPtr[].submitIcon = ""
        # Flag the editor as wizard-owned so ctrl+c/ctrl+d/esc behave as
        # the provider wizard wants (clear line vs abort; ctrl+d ignored).
        edPtr[].wizardMode = true
        # The wizard runs on the main prompt's editor, whose Up/Down
        # history navigation is global state. Reset the nav view so
        # arrow keys never leak prompt history into wizard fields
        # (api keys, urls, model names). Wizard submissions themselves
        # already skip `historyAdd` via `noHistory`.
        edPtr[].historyResetNav()
        try:
          let text = minline.readLineWith(edPtr[],
                                          req.prompt,
                                          getCh, wizardWriteProc,
                                          hidechars = req.hidechars,
                                          noHistory = req.noHistory,
                                          hasPendingInput = hasPendingInput)
          resp = WizardReadResponse(kind: wrSubmitted, text: text)
        except minline.WizardSwitched:
          # The wizard's own `getCh` should never see the sentinel
          # because the main thread blocks on the previous response
          # before publishing the next request. If it ever does,
          # treat it as a cancellation so the parked caller unblocks
          # instead of hanging forever.
          resp = WizardReadResponse(kind: wrCancelled, text: "")
        except minline.InputCancelled:
          # Repaint the persistent prompt so the next iteration of
          # the outer loop starts from a clean state. `fullRedraw`
          # runs here (with the wizard's empty `submitIcon`); the
          # deferred-submit marker is irrelevant for an empty line
          # and the persistent prompt's next readLineWith repaints
          # with the restored marker via the `finally` below.
          edPtr[].line = minline.Line(text: "", position: 0)
          edPtr[].renderSuffix = ""
          edPtr[].renderSuffixCursor = false
          edPtr[].echoRows = 0
          edPtr[].write = writeProc
          minline.fullRedraw(edPtr[])
          resp = WizardReadResponse(kind: wrCancelled, text: "")
        except EOFError:
          resp = WizardReadResponse(kind: wrEof, text: "")
        except CatchableError:
          resp = WizardReadResponse(kind: wrEof, text: "")
        finally:
          edPtr[].deferSubmit = true
          edPtr[].submitIcon = DeferredSubmitMarker
          edPtr[].wizardMode = false
          # The wizard paints its field prompts flush at the cursor with
          # no reserved gap row, so the persistent prompt's gap count
          # (noteFooterPainted(1) from startup / command commits) is a
          # lie while the wizard owns the terminal: a transcript commit
          # that trusts it walks up one row too many and erases the
          # wizard's last status line (`verifying... ok`). Restore the
          # persistent prompt string as well so a mid-hold repaint can
          # never flash the stale field prompt.
          edPtr[].prompt = EditorPromptBytes
          edPtr[].promptW = visualCols(EditorPromptBytes)
          termengine.noteNoFooter()
        acquire wizardRequestLock
        try:
          wizardResponse = resp
          wizardResponsePosted.store(true, moRelease)
        finally:
          release wizardRequestLock
        # Hold the wizard branch open until the controller releases
        # `inputModalActive` (`wizardFinish`) OR the wizard posts a
        # follow-up prompt. Falling through to the persistent prompt
        # immediately would let it paint `❯ ` at the cursor row the
        # wizard just left; the caller's verify round-trip and
        # post-writes then race that paint, garbling frames and
        # leaving the main prompt overlapping the verifier line. A
        # fresh `wizardRequestPosted` means the same wizard issued
        # another `wizardReadLine` and we should pick it up; the
        # release means the wizard is truly done and the persistent
        # prompt is safe to repaint.
        while inputModalActive.load(moAcquire) and
              not wizardRequestPosted.load(moAcquire) and
              inputThreadRunning:
          sleep 5
        continue
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
      except minline.WizardSwitched:
        # `getCh` returned the wizard sentinel because a modal
        # wizard is waiting. Drop any text the user typed in the
        # persistent prompt before the wizard arrived and loop
        # back to the top of the outer loop, where the wizard
        # branch runs the wizard's `readLineWith` and publishes
        # the result. The editor's defer + cancel/submit handlers
        # have already cleaned up the persistent readLineWith's
        # own state; we only clear our outer-loop residue.
        edPtr[].line = minline.Line(text: "", position: 0)
        edPtr[].renderSuffix = ""
        edPtr[].renderSuffixCursor = false
        edPtr[].renderRow = 0
        edPtr[].echoRows = 0
        continue
      except minline.InputCancelled:
        if inputTurnActive.load(moAcquire):
          requestTurnInterrupt()
          # Preserve any text the user typed into the buffered editor so the
          # prompt that comes back after the cancel lands with the same text
          # (and cursor position) the user had before pressing Ctrl-C. The
          # outer loop's next readLineWith calls resetForRead, which would
          # otherwise wipe the line; stashing it in prefillText keeps it
          # alive across that reset. Without this, every keystroke the user
          # made during the spinner / retry backoff is silently dropped —
          # the visual cursor lands on an empty `❯ ` and the user has to
          # retype the whole follow-up.
          if edPtr[].line.text.len > 0:
            edPtr[].prefillText = edPtr[].line.text
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
        # then run an empty-submit footer repaint whose walk-up assumes
        # the cursor sits at the bottom of the just-cleared region; after
        # this in-place repaint the cursor is at the top, so the walk-up
        # would erase real scrollback above the prompt. Push ieInterrupt
        # so the controller drains and continues with no walk-back of its
        # own.
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
        # Leave ed.write set; the next readLineWith restores it and
        # nilling here would race with a concurrent fullRedraw in the
        # other thread.
        pushInputEvent(InputEvent(kind: ieInterrupt))
        continue
      except EOFError:
        # EOFError means the user asked to quit (Ctrl-D on an empty
        # line, or real stdin EOF). It never interrupts a turn; that is
        # Ctrl-C / ESC's job.
        # A pending idle line means the controller hasn't consumed the
        # submit yet; getCh returned -1 for backpressure, not because
        # stdin closed. Don't push ieQuit—wait for the controller.
        if not inputTurnActive.load(moAcquire) and
           inputIdleLinePending.load(moAcquire):
          continue
        # Clear the idle-park flag so the quit path doesn't wait on a
        # parked getCh that will never be released.
        inputIdleLinePending.store(false, moRelease)
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
    edPtr[].editInEditor = nil
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

proc wizardReadLine*(editor: var minline.LineEditor, prompt: string,
                     hidechars = false, noHistory = true): string =
  ## Run a wizard prompt on the input thread. The main thread parks
  ## here until the user submits, cancels, or EOFs. The input thread
  ## is the only reader of stdin, so there is no race with the
  ## persistent prompt.
  ##
  ## Returns the submitted line. Raises `minline.InputCancelled` on
  ## ESC / Ctrl-C and `IOError` on EOF. Callers that want a stripped
  ## line should call `.strip` on the result (matches the old
  ## `editor.readLine` contract).
  ##
  ## On successful submit the modal-active flag stays held: the
  ## wizard may issue follow-up prompts or do post-processing
  ## (verify round-trip, ledger write) that races the input thread.
  ## The controller must call `wizardFinish` after the entire wizard
  ## sequence — including all caller post-writes — has flushed to
  ## the terminal, so the persistent prompt paints on a fresh row
  ## instead of sharing a row with the wizard's last message. Cancel
  ## and EOF clear the flag inline because there is nothing left to
  ## race and the cancel handler's own `fullRedraw` already anchors
  ## the prompt.
  # Post the request BEFORE starting the input thread. If the thread
  # starts first, its persistent `getCh` may consume real input or hit
  # EOF and exit the persistent readLineWith before the wizard sentinel
  # is visible — leaving this caller parked forever waiting for a
  # response that never comes. With the request posted up front, the
  # thread's first `getCh` sees `wizardRequestPosted` and returns the
  # sentinel, so the wizard branch runs instead of the persistent prompt.
  acquire wizardRequestLock
  try:
    wizardRequest = WizardReadRequest(prompt: prompt, hidechars: hidechars,
                                      noHistory: noHistory)
    wizardRequestPosted.store(true, moRelease)
    # The input thread's persistent `getCh` returns the wizard
    # sentinel while `wizardRequestPosted` is true. That sentinel
    # propagates up the persistent `readLineWith` as `WizardSwitched`,
    # which the input thread's outer loop catches to run the wizard
    # branch. Once the wizard branch has picked the request up, it
    # clears `wizardRequestPosted` and sets `inputModalActive`; the
    # persistent getCh no longer returns the sentinel, and the
    # wizard's own getCh can read user input normally.
  finally:
    release wizardRequestLock
  ensureInputThreadStarted()
  while not wizardResponsePosted.load(moAcquire):
    if not inputThreadRunning:
      raise newException(IOError, "input thread stopped")
    sleep 5
  acquire wizardRequestLock
  try:
    result = wizardResponse.text
    let kind = wizardResponse.kind
    wizardResponsePosted.store(false, moRelease)
    # Clear the editor's draft so the persistent prompt repaints
    # cleanly on its next readLineWith.
    editor.line = minline.Line(text: "", position: 0)
    editor.renderSuffix = ""
    editor.renderSuffixCursor = false
    editor.renderRow = 0
    editor.echoRows = 0
    # The persistent prompt's `onSubmit` set this flag before the
    # wizard took over. The wizard's `getCh` deliberately ignored
    # it while `inputModalActive == true`; now that the modal is
    # done and the persistent prompt's `getCh` is about to run
    # again, the park would deadlock the next keystroke. Clear it
    # here so the input thread is the single owner of the modal
    # lifecycle (the main loop's `cdModal` branch used to do this).
    inputIdleLinePending.store(false, moRelease)
    case kind
    of wrSubmitted: discard
    of wrCancelled:
      # Cancel has no follow-up writes; clear the flag now so the
      # input thread can re-enter the persistent prompt and the
      # cancel handler's in-place `fullRedraw` lands cleanly.
      inputModalActive.store(false, moRelease)
      raise newException(minline.InputCancelled, "")
    of wrEof:
      inputModalActive.store(false, moRelease)
      raise newException(EOFError, "")
  finally:
    release wizardRequestLock

proc wizardFinish*() =
  ## Release the modal-active hold that `wizardReadLine` keeps across
  ## successful submits. The controller calls this once after the
  ## wizard's caller has done all post-processing and flushed its
  ## terminal output: at that point the input thread can re-enter the
  ## persistent `readLineWith` and paint `❯ ` on a fresh row below
  ## the wizard's last message.
  ##
  ## Without this gate the input thread would exit the wizard branch
  ## the moment `wizardResponsePosted` was set, repaint the persistent
  ## prompt at the row the wizard last occupied, and then run a tight
  ## race against the wizard's caller writing its verifier output —
  ## leaving `❯ ` and `verifying... ok` on the same line.
  stdout.flushFile
  inputModalActive.store(false, moRelease)
  # A cdModal command may bail out on a usage error before any wizard
  # prompt runs (e.g. `:provider add foo`). Its submit already parked
  # the input thread on `inputIdleLinePending`; with no `wizardReadLine`
  # to clear it, the thread stays parked and the prompt freezes. Every
  # cdModal exit routes through `wizardFinish`, so clear it here.
  inputIdleLinePending.store(false, moRelease)

proc beginTurn*() =
  ## Hide the physical terminal caret for the duration of the turn. The
  ## prompt glyph stays visible as the stable visual anchor.
  ## Headless (library) sessions skip the input thread and caret: there is
  ## no tty to read from or paint on.
  if termengine.engineOutputEnabled:
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
  # path leaked the GUI thread (e.g. an uncaught exception past the
  # per-tool stopBarTick), the thread would otherwise keep painting the
  # bottom row with a ticking seconds counter forever. Idempotent — these
  # are no-ops when the thread isn't running. With one thread, both calls
  # stop it: stopBarTick stops + sets amIdle, then stopSpinner is a no-op.
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
    # Every committed scrollback item owns its trailing \r\n\r\n separator,
    # so the gap between the last content row and the bar is already in
    # scrollback. Never add a second volatile gap row here.
    bytes = endTurnBytes(label, repaintPrompt, currentTermW(), gapAlready = true)
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
    bytes.add "\r\n"
  # The inter-item separator is owned by `appendTranscript` (one blank row
  # prepended before every item after the first). Items carry bare content;
  # the receipt sits flush above the prompt with a single \r\n joiner.
  bytes.add formatUserPromptItem(line)
  proc clearSubmittedFooterState() =
    emitFatPromptEvent clearPendingHintEvent()
    emitFatPromptEvent clearBarEvent()
    emitFatPromptEvent clearTickerEvent()
  receiptTouchesNextResponse = true
  commitTranscriptBytes(
    bytes,
    restoreEditor = false,
    beforeRepaint = clearSubmittedFooterState,
    reserveFooter = false)
