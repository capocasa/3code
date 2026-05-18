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

var terminalLock*: Lock
initLock(terminalLock)
var terminalLockDepth {.threadvar.}: int

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
    let rows = ed.renderRow + max(1, footerRowsAboveEditor)
    stdout.write "\x1b[" & $rows & "A"
  elif ready:
    stdout.write "\x1b[" & $(ed.renderRow + 1) & "A"
  stdout.write "\x1b[J"
  if footerBarBytes.len > 0:
    stdout.write footerBarBytes
  else:
    stdout.write "\r\x1b[2K"
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

proc renderToolOverlay*(top, height, restoreRow: int; rows: openArray[string]) =
  ## Paint the bounded live tool-output overlay with absolute cursor moves.
  ## This does not install a terminal scroll region; only the declared overlay
  ## rows are touched, and the cursor is parked back at the footer afterwards.
  withTerminalWriteLock:
    stdout.write SyncBegin
    stdout.write "\x1b[?25l"
    let h = max(0, height)
    for i in 0 ..< h:
      stdout.write "\x1b[" & $(max(1, top + i)) & ";1H\x1b[2K"
      if i < rows.len:
        stdout.write rows[i]
    stdout.write "\x1b[" & $max(1, restoreRow) & ";1H"
    stdout.write SyncEnd
    stdout.flushFile

proc clearToolOverlay*(top, height, restoreRow: int) =
  ## Clear the bounded live tool-output overlay and park at the footer.
  withTerminalWriteLock:
    stdout.write SyncBegin
    stdout.write "\x1b[?25l"
    for i in 0 ..< max(0, height):
      stdout.write "\x1b[" & $(max(1, top + i)) & ";1H\x1b[2K"
    stdout.write "\x1b[" & $max(1, restoreRow) & ";1H"
    stdout.write SyncEnd
    stdout.flushFile

proc eraseRowsAbove*(rows: int) =
  ## Erase rows immediately above the current cursor.
  withTerminalWriteLock:
    for _ in 0 ..< max(0, rows):
      stdout.write "\x1b[1A\x1b[2K"
    stdout.flushFile
