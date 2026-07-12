## Terminal rendering for normal-terminal writes.
##
## This deliberately uses direct terminal operations, not a fullscreen diff.
## Scrollback content is appended once as ordinary terminal output; only the
## volatile fat-prompt region is cleared and repainted around those appends.

import std/[locks, terminal]
import minline

const
  SyncBegin* = "\x1b[?2026h"
  SyncEnd* = "\x1b[?2026l"

## Terminal write serialization lock.
##
## Invariant: a thread holding this lock must never join (or otherwise block
## on) a background thread that renders via `renderFooter` (spinner, barTick).
## Those threads need the lock to finish their current frame and exit, so
## joining them while holding it is a guaranteed deadlock: the holder waits
## for the render thread to exit, the render thread waits for the lock the
## holder holds. Any join of such a thread must go through
## `withTerminalLockDroppedForJoin`, which releases the lock around the join.
var terminalLock*: Lock
initLock(terminalLock)
var terminalLockDepth* {.threadvar.}: int

proc acquireTerminalWrite*() =
  ## Enter the single terminal-writer critical section. Reentrant so editor
  ## redraw callbacks can hold the frame while minline performs nested writes.
  if terminalLockDepth == 0:
    acquire terminalLock
  inc terminalLockDepth

proc releaseTerminalWrite*() =
  ## Leave the terminal-writer critical section acquired by
  ## `acquireTerminalWrite`.
  if terminalLockDepth <= 0:
    return
  dec terminalLockDepth
  if terminalLockDepth == 0:
    release terminalLock

proc releaseTerminalWriteFully*(): int =
  ## Drop the terminal write lock completely regardless of reentrant depth,
  ## returning the depth so it can be restored by `restoreTerminalWriteDepth`.
  ## Used around `joinThread` of a render thread (spinner/barTick): those
  ## threads need the lock to finish their current frame and exit, so joining
  ## them while the caller holds the lock deadlocks (caller waits for the
  ## thread; thread waits for the lock the caller holds). Releasing fully
  ## around the join lets the render thread drain and exit. Returns 0 when
  ## the caller did not hold the lock (no restore needed).
  result = terminalLockDepth
  if result > 0:
    terminalLockDepth = 0
    release terminalLock

proc restoreTerminalWriteDepth*(depth: int) =
  ## Restore a terminal write lock depth previously dropped by
  ## `releaseTerminalWriteFully`. Re-acquires the underlying lock and resets
  ## the reentrant counter so the caller's later `releaseTerminalWrite`
  ## calls stay balanced.
  if depth <= 0: return
  acquire terminalLock
  terminalLockDepth = depth

template withTerminalLockDroppedForJoin*(joinStmt: untyped) =
  ## Run a `joinThread` of a terminal-rendering background thread
  ## (spinner/barTick) with the calling thread's terminal write lock
  ## temporarily fully released, restoring it afterward regardless of how
  ## the join resolves. Those threads need the lock to finish their current
  ## render frame and observe their stop flag; joining them while the caller
  ## holds the lock is a guaranteed deadlock (caller waits for the thread to
  ## exit; thread waits for the lock the caller holds). Scoping the drop
  ## around the join statement makes the restore mandatory by syntax, like
  ## a `withFile` block, so a future caller cannot forget to restore.
  let savedDepth = releaseTerminalWriteFully()
  try:
    joinStmt
  finally:
    restoreTerminalWriteDepth(savedDepth)

template withTerminalWriteLock*(body: untyped) =
  ## Serialize all terminal writes. Reentrant for helpers that compose other
  ## terminal operations within one render tick.
  acquireTerminalWrite()
  try:
    body
  finally:
    releaseTerminalWrite()

proc refreshEditorWidth(ed: var minline.LineEditor) =
  let w = try: terminalWidth() except CatchableError: 0
  if w > 0:
    ed.width = w

proc syncWrite*(bytes: string) =
  ## Write one synchronized terminal update.
  withTerminalWriteLock:
    stdout.write SyncBegin
    stdout.write bytes
    stdout.write SyncEnd
    stdout.flushFile

proc writeRaw*(bytes: string) =
  ## Direct terminal write owned by the terminal renderer.
  withTerminalWriteLock:
    stdout.write bytes
    stdout.flushFile

proc hideCaret*() =
  ## Hide the physical terminal caret while the prompt is in turn-running mode.
  writeRaw("\x1b[?25l")

proc setSteadyCursor*() =
  ## Use a steady block cursor while 3code is active.
  writeRaw("\x1b[2 q")

proc restoreCursorStyle*() {.noconv.} =
  try:
    writeRaw("\x1b[0 q")
  except IOError:
    discard

proc beginEditorRedraw*(ed: var minline.LineEditor; ready: bool;
                        footerBarBytes: string;
                        footerRowsAboveEditor = 1) =
  ## Start an atomic live-editor redraw frame. The caller must finish with
  ## `finishEditorRedraw` after minline has emitted the editor bytes.
  acquireTerminalWrite()
  refreshEditorWidth(ed)
  stdout.write SyncBegin
  stdout.write "\x1b[?25l\r"
  ed.redrawWrappedExternally = true
  if footerBarBytes.len > 0:
    # Reserve the bar's own row(s) above the editor, then walk back up to
    # the editor's current top so the erase lands on the editor, not the bar.
    let rows = ed.renderRow + max(1, footerRowsAboveEditor)
    stdout.write "\x1b[" & $rows & "A"
  elif ready and ed.renderRow > 0:
    # A previously-painted multi-row editor sits above us: walk up to its
    # top row and redraw in place. Net cursor movement is zero (up N, then
    # the trailing newline steps back down N), so this never orphans a line.
    stdout.write "\x1b[" & $(ed.renderRow + 1) & "A"
  # Only advance to a fresh row when we had reserved chrome above us
  # (a bar, or a previously-walked-up editor). On the very first bar-less
  # paint the editor is already on the current row — a bare newline would
  # strand the `❯ ` that `paintInitialPrompt`/a finished wizard just
  # wrote on a blank line. Redraw in place instead.
  stdout.write "\x1b[J"
  if footerBarBytes.len > 0:
    stdout.write footerBarBytes
  else:
    stdout.write "\r\x1b[2K"
  if footerBarBytes.len > 0 or (ready and ed.renderRow > 0):
    stdout.write "\r\n"
  ed.renderRow = 0

proc finishEditorRedraw*(showCaret = true) =
  ## Finish the live-editor redraw frame opened by `beginEditorRedraw`.
  try:
    if showCaret:
      stdout.write "\x1b[?25h"
    stdout.write SyncEnd
    stdout.flushFile()
  finally:
    releaseTerminalWrite()

proc enterPromptInput*(hasBar: bool; barFooterBytes, promptOnlyBytes: string) =
  ## Prepare the cursor for the line editor. In bar mode, the caller has
  ## already cleared the reserved prompt region and supplies the repaint bytes.
  withTerminalWriteLock:
    if hasBar:
      stdout.write barFooterBytes
      stdout.write "\x1b[1B"
    else:
      stdout.write promptOnlyBytes
    stdout.flushFile

proc resetPromptInputAfterEmpty*(hasBar: bool; rows: int;
                                 promptOnlyBytes, repaintBytes: string) =
  ## Empty submission should keep the prompt/footer on the same floor.
  withTerminalWriteLock:
    let n = max(1, rows)
    if hasBar:
      stdout.write "\x1b[" & $(n + 1) & "A\r\x1b[J"
      stdout.write repaintBytes
    else:
      stdout.write "\x1b[" & $n & "A\r\x1b[J"
      stdout.write promptOnlyBytes
    stdout.flushFile
