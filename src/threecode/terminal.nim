## Terminal rendering for normal-terminal writes.
##
## This deliberately uses direct terminal operations, not a fullscreen diff.
## Scrollback content is appended once as ordinary terminal output; only the
## volatile fat-prompt region is cleared and repainted around those appends.

import std/[locks, terminal]
import minline

var terminalLock*: Lock
initLock(terminalLock)
var terminalLockDepth {.threadvar.}: int

type
  TerminalState = object
    barPayload: string

var terminalState: TerminalState

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

proc trimTrailingNewlines(s: string): string =
  result = s
  while result.len > 0 and result[^1] in {'\r', '\n'}:
    result.setLen(result.len - 1)

proc syncWrite*(bytes, syncBegin, syncEnd: string) =
  ## Write one synchronized terminal update.
  withTerminalWriteLock:
    stdout.write syncBegin
    stdout.write bytes
    stdout.write syncEnd
    stdout.flushFile

proc writeRaw*(bytes: string) =
  ## Direct terminal write owned by the terminal renderer.
  withTerminalWriteLock:
    stdout.write bytes
    stdout.flushFile

proc setFooterBar*(barPayload: string) =
  ## Remember the latest complete token-bar payload. Editor redraws use this
  ## terminal state instead of trusting a caller-local view of the footer.
  withTerminalWriteLock:
    terminalState.barPayload = barPayload

proc clearFooterBar*() =
  ## Clear the terminal token-bar payload. Used only for true prompt-only states.
  withTerminalWriteLock:
    terminalState.barPayload = ""

proc currentFooterBar(): string =
  terminalState.barPayload

proc hideCaret*() =
  ## Hide the physical terminal caret while the prompt is in turn-running mode.
  writeRaw("\x1b[?25l")

proc beginEditorRedraw*(ed: var minline.LineEditor; ready: bool;
                        syncBegin: string) =
  ## Start an atomic live-editor redraw frame. The caller must finish with
  ## `finishEditorRedraw` after minline has emitted the editor bytes.
  acquireTerminalWrite()
  refreshEditorWidth(ed)
  stdout.write syncBegin
  stdout.write "\x1b[?25l\r"
  if ready:
    stdout.write "\x1b[" & $(ed.renderRow + 1) & "A"
  stdout.write "\x1b[J"
  let bar = currentFooterBar()
  if bar.len > 0:
    stdout.write bar
  else:
    stdout.write "\r\x1b[2K"
  stdout.write "\r\n"
  ed.renderRow = 0

proc finishEditorRedraw*(syncEnd: string) =
  ## Finish the live-editor redraw frame opened by `beginEditorRedraw`.
  try:
    stdout.write "\x1b[?25h"
    stdout.write syncEnd
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

proc setToolViewport*(enter: bool; scrollBottom, barRow: int;
                      liveAnchored: bool) =
  ## Install or clear the bounded tool-output viewport.
  withTerminalWriteLock:
    if enter:
      stdout.write "\x1b[1;" & $max(1, scrollBottom) & "r"
      stdout.write "\x1b[" & $max(1, scrollBottom) & ";1H"
    else:
      stdout.write "\x1b[r"
      if not liveAnchored:
        stdout.write "\x1b[" & $max(1, barRow) & ";1H"
    stdout.flushFile

proc endTurn*(hadInputThread: bool; editor: ptr minline.LineEditor;
              hasBar: bool; bytes: string; tickerActive: bool;
              tickerClearBytes: string) =
  ## Render the transition from running turn to idle prompt.
  withTerminalWriteLock:
    if hadInputThread and editor != nil:
      let up =
        if hasBar: editor[].renderRow + 1
        else: editor[].renderRow
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
    if tickerActive:
      stdout.write tickerClearBytes
    stdout.write bytes
    stdout.flushFile

proc submitUser*(bytes: string) =
  ## Echo a normal foreground user submit and clear live footer state.
  writeRaw(bytes)

proc submitBufferedUser*(editorRows: int; hasBar: bool; bytes: string) =
  ## Echo a prompt queued by the background editor during a running turn.
  withTerminalWriteLock:
    stdout.write "\r"
    if hasBar:
      let up = max(0, editorRows - 1)
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
    stdout.write bytes
    stdout.flushFile

proc renderFooterFrame*(bytes: string; inputRunning: bool;
                        editor: ptr minline.LineEditor;
                        syncBegin, syncEnd: string) {.gcsafe.} =
  ## Render a fat-prompt chrome update. If the background editor is active,
  ## repaint the token bar and editor in the same synchronized tick so the
  ## cursor returns to the editor instead of the bar.
  {.cast(gcsafe).}:
    withTerminalWriteLock:
      if bytes.len > 0 and bytes != "\r\x1b[2K" and
          '\n' notin bytes and '\r' in bytes:
        terminalState.barPayload = bytes
      if inputRunning and editor != nil:
        let edPtr = editor
        stdout.write syncBegin
        stdout.write "\x1b[?25l"
        refreshEditorWidth(edPtr[])
        let up = edPtr[].renderRow + 1
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write bytes
        stdout.write "\r\n"
        edPtr[].renderRow = 0
        stdout.write edPtr[].redrawBytes()
        if edPtr[].postRedraw != nil:
          edPtr[].postRedraw(edPtr[])
        stdout.write syncEnd
        stdout.flushFile
      else:
        stdout.write syncBegin
        stdout.write bytes
        stdout.write syncEnd
        stdout.flushFile

proc appendTranscriptWithFooter*(transcriptBytes: string; liveAnchored: bool;
                                 inputRunning: bool;
                                 editor: ptr minline.LineEditor;
                                 clearBytes, repaintBytes: string;
                                 syncBegin, syncEnd: string;
                                 compactRowsAboveFooter = 0) =
  ## Append transcript bytes as real scrollback while preserving the terminal's
  ## fat-prompt area. The terminal decides when and where footer bytes are
  ## emitted.
  withTerminalWriteLock:
    let transcript = trimTrailingNewlines(transcriptBytes)
    if liveAnchored:
      let edPtr = editor
      if edPtr == nil:
        return
      refreshEditorWidth(edPtr[])
      stdout.write syncBegin
      stdout.write "\x1b[?25l\r"
      stdout.write "\x1b[" & $(edPtr[].renderRow + 1 +
        max(0, compactRowsAboveFooter)) & "A"
      stdout.write "\x1b[J"
      if transcript.len > 0:
        stdout.write transcript
        stdout.write "\r\n\r\n"
      stdout.write currentFooterBar()
      stdout.write "\r\n"
      edPtr[].renderRow = 0
      stdout.write edPtr[].redrawBytes()
      stdout.write syncEnd
      stdout.flushFile
    else:
      if inputRunning and editor != nil:
        let up = editor[].renderRow + 1
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
      if compactRowsAboveFooter > 0:
        stdout.write "\x1b[" & $compactRowsAboveFooter & "A"
      stdout.write clearBytes
      if transcript.len > 0:
        stdout.write transcript
        stdout.write "\r\n\r\n"
      stdout.write repaintBytes
      if inputRunning and editor != nil:
        stdout.write "\x1b[1B"
        stdout.write editor[].redrawBytes()
      stdout.flushFile
