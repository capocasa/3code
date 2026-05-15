## Single owner for normal-terminal writes.
##
## This deliberately uses direct terminal operations, not a fullscreen diff.
## Scrollback content is appended once as ordinary terminal output; only the
## volatile fat-prompt region is cleared and repainted around those appends.

import std/[locks, terminal]
import minline

var terminalLock*: Lock
initLock(terminalLock)
var terminalLockDepth {.threadvar.}: int

template withTerminalWriteLock*(body: untyped) =
  ## Serialize all terminal writes. Reentrant for helpers that compose other
  ## owner operations within one render tick.
  if terminalLockDepth > 0:
    body
  else:
    acquire terminalLock
    inc terminalLockDepth
    try:
      body
    finally:
      dec terminalLockDepth
      release terminalLock

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

proc renderFooterFrame*(bytes: string; inputRunning: bool;
                        editor: ptr minline.LineEditor;
                        syncBegin, syncEnd: string) {.gcsafe.} =
  ## Render a fat-prompt chrome update. If the background editor is active,
  ## repaint the token bar and editor in the same synchronized tick so the
  ## cursor returns to the editor instead of the bar.
  {.cast(gcsafe).}:
    withTerminalWriteLock:
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
                                 barBytes, clearBytes, repaintBytes: string;
                                 syncBegin, syncEnd: string) =
  ## Append transcript bytes as real scrollback while preserving the owned
  ## fat-prompt area. The caller supplies already-formatted footer bytes; this
  ## owner decides when and where they are emitted.
  withTerminalWriteLock:
    let transcript = trimTrailingNewlines(transcriptBytes)
    if liveAnchored:
      let edPtr = editor
      if edPtr == nil:
        return
      refreshEditorWidth(edPtr[])
      stdout.write syncBegin
      stdout.write "\x1b[?25l\r"
      stdout.write "\x1b[" & $(edPtr[].renderRow + 1) & "A"
      stdout.write "\x1b[J"
      if transcript.len > 0:
        stdout.write transcript
        stdout.write "\r\n\r\n"
      stdout.write barBytes
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
      stdout.write clearBytes
      if transcript.len > 0:
        stdout.write transcript
        stdout.write "\r\n\r\n"
      stdout.write repaintBytes
      if inputRunning and editor != nil:
        stdout.write "\x1b[1B"
        stdout.write editor[].redrawBytes()
      stdout.flushFile
