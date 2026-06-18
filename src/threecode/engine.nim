## Stateful terminal layout engine.
##
## Controllers append transcript bytes and mutate fat-prompt state; this module
## owns the cursor geometry needed to clear/repaint the volatile footer around
## those appends. Scrollback bytes are append-only once emitted.

import std/[terminal, unicode]
import minline
import ./terminal as termio
import ./util
import ./fatprompt/rendering

type
  TerminalEngine* = object
    ## Rows from the current cursor row to the top of the last painted volatile
    ## footer. Zero means no footer geometry is currently known.
    rowsAboveCursorToFooterTop: int
    footerRowsAboveEditor: int
    footerHasLeadingGap: bool
    footerNeedsLeadingGap: bool
    toolViewportRows: seq[string]
    editorRedrawPending: bool
    editorRedrawFooterRows: int

var defaultEngine*: TerminalEngine

proc refreshEditorWidth(ed: var minline.LineEditor) =
  let w = try: terminalWidth() except CatchableError: 0
  if w > 0:
    ed.width = w

proc trimTrailingNewlines(s: string): string =
  result = s
  while result.len > 0 and result[^1] in {'\r', '\n'}:
    result.setLen(result.len - 1)

proc hasNonNewlineBytes(s: string): bool =
  for ch in s:
    if ch != '\r' and ch != '\n':
      return true

proc editorRowsAboveCursor(ed: var minline.LineEditor): int =
  refreshEditorWidth(ed)
  min(ed.renderRow, max(1, minline.renderedRows(ed)) - 1)

proc rowsToFooterTop(ed: var minline.LineEditor;
                     footerRowsAboveEditor: int): int =
  editorRowsAboveCursor(ed) + max(0, footerRowsAboveEditor)

proc noteFooterPainted(e: var TerminalEngine; ed: var minline.LineEditor;
                       footerRowsAboveEditor: int) =
  let rows = max(0, footerRowsAboveEditor)
  e.rowsAboveCursorToFooterTop = rowsToFooterTop(ed, rows)
  e.footerRowsAboveEditor = rows

proc noteNoFooter(e: var TerminalEngine) =
  e.rowsAboveCursorToFooterTop = 0
  e.footerRowsAboveEditor = 0
  e.footerHasLeadingGap = false

proc writeViewportRows(rows: openArray[string]) =
  for row in rows:
    stdout.write row
    stdout.write "\r\n"

proc toolViewportHeight(e: TerminalEngine): int =
  e.toolViewportRows.len

proc writeToolViewportRows(e: TerminalEngine) =
  writeViewportRows(e.toolViewportRows)

proc updateToolViewportSymbol*(symbol: string) {.gcsafe.} =
  ## Rewrite the leading glyph of the cached command banner row. The bar-tick
  ## thread calls this each tick to rotate the currency marker ($/€/£/¥); the
  ## next `renderFooter` repaint writes the updated row in one locked pass.
  {.cast(gcsafe).}:
    if defaultEngine.toolViewportRows.len > 0:
      let row = defaultEngine.toolViewportRows[0]
      if row.len > 0:
        let firstLen = runeLenAt(row, 0)
        if firstLen > 0:
          defaultEngine.toolViewportRows[0] = symbol & row.substr(firstLen)

proc syncWrite*(e: var TerminalEngine; bytes: string) =
  ## Synchronized screen write for legacy frame helpers that have not yet been
  ## decomposed into footer model mutations.
  termio.syncWrite(bytes)

proc syncWrite*(bytes: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.syncWrite(bytes)

proc writeRaw*(e: var TerminalEngine; bytes: string) =
  ## Raw screen write owned by the engine boundary.
  termio.writeRaw(bytes)

proc writeRaw*(bytes: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.writeRaw(bytes)

proc beginEditorRedraw*(e: var TerminalEngine; ed: var minline.LineEditor;
                        ready: bool; frame: FooterFrame) =
  let termW = try: terminalWidth() except CatchableError: 0
  let rows = frame.rowsAboveEditor(termW)
  termio.beginEditorRedraw(ed, ready, frame.footerFrameBytes(termW),
                           rows)
  e.editorRedrawPending = true
  e.editorRedrawFooterRows = rows

proc beginEditorRedraw*(ed: var minline.LineEditor; ready: bool;
                        frame: FooterFrame) =
  defaultEngine.beginEditorRedraw(ed, ready, frame)

proc finishEditorRedraw*(e: var TerminalEngine; ed: var minline.LineEditor;
                         showCaret = true) =
  if e.editorRedrawPending:
    if e.editorRedrawFooterRows > 0:
      e.noteFooterPainted(ed, e.editorRedrawFooterRows)
    else:
      e.noteNoFooter()
    e.editorRedrawPending = false
    e.editorRedrawFooterRows = 0
  termio.finishEditorRedraw(showCaret)

proc finishEditorRedraw*(ed: var minline.LineEditor; showCaret = true) =
  defaultEngine.finishEditorRedraw(ed, showCaret)

proc renderFooter*(e: var TerminalEngine; frame: FooterFrame; inputRunning: bool;
                   editor: ptr minline.LineEditor;
                   termW = 0) {.gcsafe.} =
  ## Replace the volatile footer and repaint the editor in one synchronized
  ## frame. ``footerRowsAboveEditor`` is model geometry from the fat prompt,
  ## not a one-off cursor fix from a controller.
  {.cast(gcsafe).}:
    termio.withTerminalWriteLock:
      let bytes = frame.footerFrameBytes(termW)
      let footerRowsAboveEditor = frame.rowsAboveEditor(termW)
      if inputRunning and editor != nil:
        let edPtr = editor
        stdout.write termio.SyncBegin
        stdout.write "\x1b[?25l"
        refreshEditorWidth(edPtr[])
        let hasLeadingGap =
          bytes.len > 0 and frame.kind notin {ffNone, ffClear} and
          (e.footerNeedsLeadingGap or e.footerHasLeadingGap)
        let growth =
          if e.footerRowsAboveEditor > 0:
            max(0, footerRowsAboveEditor - e.footerRowsAboveEditor)
          else:
            0
        let up = e.rowsAboveCursorToFooterTop + e.toolViewportHeight + growth
        let rewriteLeadingGap =
          hasLeadingGap and (up == 0 or (growth > 0 and e.footerHasLeadingGap))
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write "\x1b[J"
        if rewriteLeadingGap:
          stdout.write "\r\n"
        e.footerNeedsLeadingGap = false
        e.writeToolViewportRows()
        stdout.write bytes
        stdout.write "\r\n"
        edPtr[].renderRow = 0
        stdout.write edPtr[].redrawBytes(synchronized = false)
        if not edPtr[].pendingCaret:
          stdout.write "\x1b[?25h"
        if frame.kind == ffClear:
          e.noteNoFooter()
        else:
          e.noteFooterPainted(edPtr[], footerRowsAboveEditor)
          e.footerHasLeadingGap = hasLeadingGap
        stdout.write termio.SyncEnd
        stdout.flushFile
      else:
        stdout.write termio.SyncBegin
        if e.footerNeedsLeadingGap and bytes.len > 0:
          stdout.write "\r\n"
          e.footerNeedsLeadingGap = false
        stdout.write bytes
        e.noteNoFooter()
        stdout.write termio.SyncEnd
        stdout.flushFile

proc renderFooter*(frame: FooterFrame; inputRunning: bool;
                   editor: ptr minline.LineEditor;
                   termW = 0) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.renderFooter(frame, inputRunning, editor, termW)

proc renderToolViewport*(e: var TerminalEngine; rows: openArray[string];
                         frame: FooterFrame; inputRunning: bool;
                         editor: ptr minline.LineEditor;
                         termW = 0) {.gcsafe.} =
  ## Replace the volatile bash viewport and repaint footer/editor in one
  ## synchronized frame. The viewport is live chrome: it is not transcript
  ## scrollback, and the controller commits final output separately.
  {.cast(gcsafe).}:
    termio.withTerminalWriteLock:
      let width = if termW > 0: termW else:
        try: terminalWidth() except CatchableError: 0
      let bytes = frame.footerFrameBytes(width)
      let footerRowsAboveEditor = frame.rowsAboveEditor(width)
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      if inputRunning and editor != nil:
        refreshEditorWidth(editor[])
        let growth =
          if e.footerRowsAboveEditor > 0:
            max(0, footerRowsAboveEditor - e.footerRowsAboveEditor)
          else:
            0
        let rowsToFooter =
          if e.rowsAboveCursorToFooterTop > 0:
            e.rowsAboveCursorToFooterTop
          else:
            rowsToFooterTop(editor[], footerRowsAboveEditor)
        let up = rowsToFooter + e.toolViewportHeight + growth
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write "\x1b[J"
        e.toolViewportRows = @rows
        e.writeToolViewportRows()
        if bytes.len > 0:
          stdout.write bytes
          stdout.write "\r\n"
        editor[].renderRow = 0
        stdout.write editor[].redrawBytes(synchronized = false)
        if not editor[].pendingCaret:
          stdout.write "\x1b[?25h"
        if frame.kind == ffClear:
          e.noteNoFooter()
        else:
          e.noteFooterPainted(editor[], footerRowsAboveEditor)
      else:
        e.toolViewportRows = @rows
        e.writeToolViewportRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
      stdout.write termio.SyncEnd
      stdout.flushFile

proc renderToolViewport*(rows: openArray[string]; frame: FooterFrame;
                         inputRunning: bool; editor: ptr minline.LineEditor;
                         termW = 0) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.renderToolViewport(rows, frame, inputRunning, editor, termW)

proc clearToolViewport*(e: var TerminalEngine; frame: FooterFrame;
                        inputRunning: bool; editor: ptr minline.LineEditor;
                        termW = 0) {.gcsafe.} =
  if e.toolViewportRows.len == 0:
    e.renderFooter(frame, inputRunning, editor, termW)
  else:
    e.renderToolViewport([], frame, inputRunning, editor, termW)

proc clearToolViewport*(frame: FooterFrame; inputRunning: bool;
                        editor: ptr minline.LineEditor; termW = 0)
    {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.clearToolViewport(frame, inputRunning, editor, termW)

proc appendTranscript*(e: var TerminalEngine; transcriptBytes: string;
                       liveAnchored: bool;
                       inputRunning: bool;
                       editor: ptr minline.LineEditor;
                       oldFooter, newFooter: FooterFrame;
                       compactRowsAboveFooter = 0;
                       restoreEditor = true;
                       reserveFooter = true;
                       transcriptOwnsSpacing = false) =
  ## Append transcript bytes as real scrollback while preserving or clearing
  ## the volatile footer. The engine computes cursor geometry from remembered
  ## footer state plus the current editor model; callers do not pass per-commit
  ## cursor movement values.
  termio.withTerminalWriteLock:
    let termW = try: terminalWidth() except CatchableError: 0
    let footerRowsAboveEditor = oldFooter.rowsAboveEditor(termW)
    let footerBarBytes = newFooter.footerFrameBytes(termW)
    let repaintBytes = footerBarBytes
    let transcript =
      if transcriptOwnsSpacing: transcriptBytes
      else: trimTrailingNewlines(transcriptBytes)
    if liveAnchored:
      let edPtr = editor
      if edPtr == nil:
        return
      refreshEditorWidth(edPtr[])
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l\r"
      let rowsToFooter =
        if e.rowsAboveCursorToFooterTop > 0:
          e.rowsAboveCursorToFooterTop
        elif e.footerNeedsLeadingGap:
          0
        else:
          rowsToFooterTop(edPtr[], footerRowsAboveEditor)
      let rowsUp = rowsToFooter + max(0, compactRowsAboveFooter)
      if rowsUp > 0:
        stdout.write "\x1b[" & $rowsUp & "A"
      stdout.write "\x1b[J"
      if transcript.len > 0:
        stdout.write transcript
        if reserveFooter and not transcriptOwnsSpacing:
          stdout.write "\r\n\r\n"
      if reserveFooter:
        if footerBarBytes.len > 0:
          stdout.write footerBarBytes
          stdout.write "\r\n"
        if restoreEditor:
          edPtr[].renderRow = 0
          stdout.write edPtr[].redrawBytes()
          if not edPtr[].pendingCaret:
            stdout.write "\x1b[?25h"
          e.noteFooterPainted(edPtr[], footerRowsAboveEditor)
        else:
          e.rowsAboveCursorToFooterTop =
            if footerBarBytes.len > 0: max(1, footerRowsAboveEditor)
            else: 0
      else:
        e.footerNeedsLeadingGap = transcript.hasNonNewlineBytes
        e.noteNoFooter()
      stdout.write termio.SyncEnd
      stdout.flushFile
    else:
      if inputRunning and editor != nil:
        let up =
          if e.rowsAboveCursorToFooterTop > 0:
            e.rowsAboveCursorToFooterTop
          elif e.footerNeedsLeadingGap:
            0
          else:
            rowsToFooterTop(editor[], footerRowsAboveEditor)
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
      if compactRowsAboveFooter > 0:
        stdout.write "\x1b[" & $compactRowsAboveFooter & "A"
      stdout.write "\r\x1b[J"
      if transcript.len > 0:
        stdout.write transcript
        if reserveFooter and not transcriptOwnsSpacing:
          stdout.write "\r\n\r\n"
      if reserveFooter:
        if footerBarBytes.len > 0:
          stdout.write repaintBytes
          if inputRunning and editor != nil and restoreEditor:
            stdout.write "\x1b[1B"
        if inputRunning and editor != nil and restoreEditor:
          editor[].renderRow = 0
          stdout.write editor[].redrawBytes()
          if not editor[].pendingCaret:
            stdout.write "\x1b[?25h"
          e.noteFooterPainted(editor[], footerRowsAboveEditor)
        else:
          e.rowsAboveCursorToFooterTop =
            if footerBarBytes.len > 0: max(1, footerRowsAboveEditor)
            else: 0
      else:
        e.footerNeedsLeadingGap = transcript.hasNonNewlineBytes
        e.noteNoFooter()
      stdout.flushFile

proc prepareAssistantContentStart*(e: var TerminalEngine;
                                   inputRunning: bool;
                                   editor: ptr minline.LineEditor;
                                   oldFooter: FooterFrame;
                                   hadBufferedSubmit: bool;
                                   flush = true) =
  ## Clear volatile footer chrome so live assistant content can begin as
  ## ordinary transcript output. The clear geometry comes from the engine's
  ## remembered footer state, falling back to the supplied semantic footer.
  termio.withTerminalWriteLock:
    let termW = try: terminalWidth() except CatchableError: 0
    if inputRunning and editor != nil:
      refreshEditorWidth(editor[])
      let footerRows = oldFooter.rowsAboveEditor(termW)
      let up =
        if e.rowsAboveCursorToFooterTop > 0:
          e.rowsAboveCursorToFooterTop
        else:
          rowsToFooterTop(editor[], footerRows)
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
      stdout.write "\x1b[J"
      e.noteNoFooter()
    elif oldFooter.kind != ffNone and not hadBufferedSubmit:
      stdout.write oldFooter.footerFrameBytes(termW)
      e.noteNoFooter()
    if flush:
      stdout.flushFile

proc prepareAssistantContentStart*(inputRunning: bool;
                                   editor: ptr minline.LineEditor;
                                   oldFooter: FooterFrame;
                                   hadBufferedSubmit: bool;
                                   flush = true) =
  defaultEngine.prepareAssistantContentStart(
    inputRunning, editor, oldFooter, hadBufferedSubmit, flush)

proc endTurn*(e: var TerminalEngine; inputRunning: bool;
              editor: ptr minline.LineEditor; oldFooter: FooterFrame;
              bytes: string) =
  ## Render the transition from running turn to idle prompt. The visual
  ## transition bytes are still produced by the fat-prompt renderer; cursor
  ## geometry is owned by the engine.
  termio.withTerminalWriteLock:
    let termW = try: terminalWidth() except CatchableError: 0
    if inputRunning and editor != nil:
      refreshEditorWidth(editor[])
      let footerRows = oldFooter.rowsAboveEditor(termW)
      let up =
        if e.rowsAboveCursorToFooterTop > 0:
          e.rowsAboveCursorToFooterTop
        else:
          rowsToFooterTop(editor[], footerRows)
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
    stdout.write bytes
    e.noteNoFooter()
    stdout.flushFile

proc endTurn*(inputRunning: bool; editor: ptr minline.LineEditor;
              oldFooter: FooterFrame; bytes: string) =
  defaultEngine.endTurn(inputRunning, editor, oldFooter, bytes)

proc appendTranscript*(transcriptBytes: string;
                       liveAnchored: bool;
                       inputRunning: bool;
                       editor: ptr minline.LineEditor;
                       oldFooter, newFooter: FooterFrame;
                       compactRowsAboveFooter = 0;
                       restoreEditor = true;
                       reserveFooter = true;
                       transcriptOwnsSpacing = false) =
  defaultEngine.appendTranscript(
    transcriptBytes,
    liveAnchored,
    inputRunning,
    editor,
    oldFooter,
    newFooter,
    compactRowsAboveFooter,
    restoreEditor,
    reserveFooter,
    transcriptOwnsSpacing)
