## Stateful terminal layout engine.
##
## Controllers append transcript bytes and mutate fat-prompt state; this module
## owns the cursor geometry needed to clear/repaint the volatile footer around
## those appends. Scrollback bytes are append-only once emitted.
##
## Layout (bottom → top):
##   editor rows (variable, cursor somewhere within)
##   bar row(s)
##   ticker row (always reserved, even when blank)
##   separator row (blank, always part of scrollback)
##   scrollback content …
##
## Every transcript commit writes `content + \r\n\r\n`. The first \r\n ends
## the content; the second is the separator. The footer is always painted
## starting at the ticker row directly below the separator.
##
## The walk-up from cursor to the top of the volatile region is always derived
## from live state, never cached:
##
##   walkUp(ed) = editorRowsAboveCursor(ed) + paintedFooterRows + viewportHeight
##
## `paintedFooterRows` is the bar+ticker row count of whatever footer is
## currently on screen (zero if none). It changes only on explicit footer
## transitions (renderFooter, appendTranscript's reserve/clear paths). The
## editor's row-above-cursor (`renderRow`) changes on every keystroke, so it
## must be read live — caching it leads to stale walk-ups that walk into
## committed scrollback.

import std/[terminal, times]
import minline
import ./terminal as termio
import ./fatprompt/rendering
import ./util

type
  TerminalEngine* = object
    ## Bar+ticker rows of the footer currently painted on screen. Zero when
    ## no footer chrome is live. Updated by every footer paint/clear path.
    ## The editor's own rows are NOT included here; they are read live from
    ## the editor's `renderRow` at each walk-up.
    paintedFooterRows: int
    toolViewportRows: seq[string]
    ## Volatile in-progress assistant content above the footer during live
    ## streaming. Like the tool viewport it is erased and rewritten each
    ## frame; committed lines go to real scrollback via `appendTranscript`.
    liveContentRows: seq[string]
    editorRedrawPending: bool
    editorRedrawFooterRows: int
    ## When true, the gap row at the top of the footer is committed
    ## scrollback (the previous item's trailing `\r\n\r\n`), not volatile
    ## chrome. Walk-up codepaths stop one row short to preserve it.
    gapIsSeparator: bool
    ## Wall-clock ms of the most recent SIGWINCH, or 0. While `resizeRecent`
    ## is true, footer repaints walk up one extra row before erasing: a
    ## reflow can leave a stale footer row one above the recomputed footer
    ## top (the spinner→content handoff changes the footer height at the same
    ## moment the cursor is moving), and the normal walk-up — derived from
    ## the NEW footer height — misses it. The extra row sits inside the
    ## volatile region (the always-reserved ticker/gap row), so it never
    ## reaches committed scrollback.
    resizeAtMs: int64

var defaultEngine*: TerminalEngine

proc noteResize*(e: var TerminalEngine) =
  e.resizeAtMs = int64(epochTime() * 1000.0)

proc noteResize*() {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.noteResize()

proc resizeRecent*(e: var TerminalEngine): bool =
  ## True within a short window after the last SIGWINCH. Expires the record
  ## once the window passes so the extra erase row stops.
  if e.resizeAtMs == 0:
    return false
  if int64(epochTime() * 1000.0) - e.resizeAtMs > 400:
    e.resizeAtMs = 0
    return false
  true

proc refreshEditorWidth(ed: var minline.LineEditor) =
  let w = try: terminalWidth() except CatchableError: 0
  if w > 0:
    ed.width = w

proc trimTrailingNewlines(s: string): string =
  result = s
  while result.len > 0 and result[^1] in {'\r', '\n'}:
    result.setLen(result.len - 1)

proc editorRowsAboveCursor(ed: var minline.LineEditor): int =
  refreshEditorWidth(ed)
  min(ed.renderRow, max(1, minline.renderedRows(ed)) - 1)

proc walkUp(e: var TerminalEngine; ed: var minline.LineEditor): int =
  ## Rows from the cursor to the top of the volatile region (ticker row).
  ## Always derived from live editor + footer state. This is the number of
  ## rows to move up before erasing the volatile region.
  ## When gapIsSeparator is set, the gap row at the top of the footer is
  ## committed scrollback (not chrome), so the walk-up stops one row short
  ## to preserve it.
  ## Right after a resize, walk one row higher: a reflow can strand a stale
  ## footer row one above the recomputed footer top (the footer height
  ## changes at the spinner→content handoff at the same moment the cursor is
  ## moving), and the erase derived from the NEW height misses it. The extra
  ## row sits inside the volatile region (the always-reserved ticker/gap
  ## row), so it never reaches committed scrollback.
  let gap = if e.gapIsSeparator: 1 else: 0
  let extra = if e.resizeRecent(): 1 else: 0
  editorRowsAboveCursor(ed) + e.paintedFooterRows + e.toolViewportRows.len +
    e.liveContentRows.len - gap + extra

proc noteFooterPainted(e: var TerminalEngine; footerRowsAboveEditor: int) =
  e.paintedFooterRows = max(0, footerRowsAboveEditor)
  e.gapIsSeparator = false

proc noteNoFooter(e: var TerminalEngine) =
  e.paintedFooterRows = 0
  e.gapIsSeparator = false

proc writeViewportRows(rows: openArray[string]) =
  for row in rows:
    stdout.write row
    stdout.write "\r\n"

# Row 0 is the tool banner (command line); the rest is streaming bash
# output. Color them at the write boundary so the semantic rows held in
# `toolViewportRows` stay plain — the unit tests assert the raw text.
# OffWhiteFg = nonbright white for the command; GreyFg = light grey for
# the output. Both honor the mode-aware `[colors]` config.
proc writeToolViewportRows(e: TerminalEngine) =
  if e.toolViewportRows.len == 0: return
  stdout.write OffWhiteFg
  stdout.write e.toolViewportRows[0]
  stdout.write Reset
  stdout.write "\r\n"
  for i in 1 ..< e.toolViewportRows.len:
    stdout.write GreyFg
    stdout.write e.toolViewportRows[i]
    stdout.write Reset
    stdout.write "\r\n"

proc syncWrite*(e: var TerminalEngine; bytes: string) =
  termio.syncWrite(bytes)

proc syncWrite*(bytes: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.syncWrite(bytes)

proc writeRaw*(e: var TerminalEngine; bytes: string) =
  termio.writeRaw(bytes)

proc writeRaw*(bytes: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.writeRaw(bytes)

proc beginEditorRedraw*(e: var TerminalEngine; ed: var minline.LineEditor;
                        ready: bool; frame: FooterFrame) =
  let termW = try: terminalWidth() except CatchableError: 0
  let rows = frame.rowsAboveEditor(termW)
  let extra = if e.resizeRecent(): 1 else: 0
  termio.beginEditorRedraw(ed, ready, frame.footerFrameBytes(termW),
                           rows + extra)
  e.editorRedrawPending = true
  e.editorRedrawFooterRows = rows

proc beginEditorRedraw*(ed: var minline.LineEditor; ready: bool;
                        frame: FooterFrame) =
  defaultEngine.beginEditorRedraw(ed, ready, frame)

proc finishEditorRedraw*(e: var TerminalEngine; ed: var minline.LineEditor;
                         showCaret = true) =
  if e.editorRedrawPending:
    if e.editorRedrawFooterRows > 0:
      e.noteFooterPainted(e.editorRedrawFooterRows)
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
  ## frame. The walk-up is derived from the currently-painted footer height
  ## (e.paintedFooterRows) and the editor's live renderRow, so it always
  ## matches reality regardless of what changed since the last paint.
  {.cast(gcsafe).}:
    termio.withTerminalWriteLock:
      let bytes = if e.gapIsSeparator:
        frame.footerBarOnlyBytes(termW)
      else:
        frame.footerFrameBytes(termW)
      let footerRowsAboveEditor = frame.rowsAboveEditor(termW)
      if inputRunning and editor != nil:
        let edPtr = editor
        stdout.write termio.SyncBegin
        stdout.write "\x1b[?25l"
        refreshEditorWidth(edPtr[])
        let up = max(0, e.walkUp(edPtr[]))
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write "\x1b[J"
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
          e.noteFooterPainted(footerRowsAboveEditor)
        stdout.write termio.SyncEnd
        stdout.flushFile
      else:
        stdout.write termio.SyncBegin
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
      let bytes = if e.gapIsSeparator:
        frame.footerBarOnlyBytes(width)
      else:
        frame.footerFrameBytes(width)
      let footerRowsAboveEditor = frame.rowsAboveEditor(width)
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      if inputRunning and editor != nil:
        refreshEditorWidth(editor[])
        let up = max(0, e.walkUp(editor[]))
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
          e.noteFooterPainted(footerRowsAboveEditor)
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

proc renderLiveContent*(e: var TerminalEngine; rows: openArray[string];
                        frame: FooterFrame; inputRunning: bool;
                        editor: ptr minline.LineEditor;
                        termW = 0) {.gcsafe.} =
  ## Replace the volatile in-progress assistant content (plus the footer)
  ## in one synchronized frame. The partial content rows are live chrome,
  ## erased and rewritten on each streaming chunk; committed lines are sent
  ## to real scrollback via `appendTranscript`. Mirrors `renderToolViewport`
  ## but draws below committed scrollback, above the token bar.
  {.cast(gcsafe).}:
    termio.withTerminalWriteLock:
      let width = if termW > 0: termW else:
        try: terminalWidth() except CatchableError: 0
      let bytes = if e.gapIsSeparator:
        frame.footerBarOnlyBytes(width)
      else:
        frame.footerFrameBytes(width)
      let footerRowsAboveEditor = frame.rowsAboveEditor(width)
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      if inputRunning and editor != nil:
        refreshEditorWidth(editor[])
        let up = max(0, e.walkUp(editor[]))
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write "\x1b[J"
        e.liveContentRows = @rows
        for row in rows:
          stdout.write row
          stdout.write "\r\n"
        if bytes.len > 0:
          stdout.write bytes
          stdout.write "\r\n"
        editor[].renderRow = 0
        stdout.write editor[].redrawBytes(synchronized = false)
        # Keep the caret hidden for the whole turn (beginTurn hid it). The
        # streaming partial repaint must not re-show it, otherwise the
        # visible-caret signal can't distinguish a live partial from idle.
        if frame.kind == ffClear:
          e.noteNoFooter()
        else:
          e.noteFooterPainted(footerRowsAboveEditor)
      else:
        e.liveContentRows = @rows
        for row in rows:
          stdout.write row
          stdout.write "\r\n"
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
      stdout.write termio.SyncEnd
      stdout.flushFile

proc renderLiveContent*(rows: openArray[string]; frame: FooterFrame;
                        inputRunning: bool; editor: ptr minline.LineEditor;
                        termW = 0) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.renderLiveContent(rows, frame, inputRunning, editor, termW)

proc clearLiveContent*(e: var TerminalEngine) {.gcsafe.} =
  ## Drop the tracked volatile live-content rows without painting. Called
  ## after a line is committed to real scrollback so the next partial starts
  ## fresh and the walk-up no longer counts the just-committed rows.
  {.cast(gcsafe).}:
    # Mutates shared engine state: serialize with the render threads that
    # read/replace `liveContentRows` under the same lock.
    termio.withTerminalWriteLock:
      e.liveContentRows = @[]

proc clearLiveContent*() {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.clearLiveContent()

proc liveContentRowCount*(e: TerminalEngine): int {.gcsafe.} =
  e.liveContentRows.len

proc paintedFooterRowCount*(e: TerminalEngine): int {.gcsafe.} =
  e.paintedFooterRows

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
  ## the volatile footer. The engine always appends a trailing separator row
  ## (`\r\n\r\n`) so the volatile footer's ticker row never collides with
  ## committed content. Callers provide content without trailing spacing;
  ## trailing \r/\n bytes are trimmed unless ``transcriptOwnsSpacing`` is set.
  termio.withTerminalWriteLock:
    let termW = try: terminalWidth() except CatchableError: 0
    let footerBytes = newFooter.footerFrameBytes(termW)
    let footerRowsAboveEditor = newFooter.rowsAboveEditor(termW)
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
      let up = max(0, e.walkUp(edPtr[]) + max(0, compactRowsAboveFooter))
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
      stdout.write "\x1b[J"
      e.toolViewportRows = @[]
      if transcript.len > 0:
        stdout.write transcript
        if reserveFooter and not transcriptOwnsSpacing:
          stdout.write "\r\n\r\n"
      if reserveFooter:
        if footerBytes.len > 0:
          stdout.write footerBytes
          stdout.write "\r\n"
        if restoreEditor:
          edPtr[].renderRow = 0
          stdout.write edPtr[].redrawBytes()
          if not edPtr[].pendingCaret:
            stdout.write "\x1b[?25h"
          e.noteFooterPainted(footerRowsAboveEditor)
        else:
          if footerBytes.len > 0:
            e.noteFooterPainted(max(1, footerRowsAboveEditor))
          else:
            e.noteNoFooter()
      else:
        e.noteNoFooter()
      if transcriptOwnsSpacing and transcript.len > 0 and reserveFooter and footerBytes.len > 0:
        e.gapIsSeparator = true
      stdout.write termio.SyncEnd
      stdout.flushFile
    else:
      if inputRunning and editor != nil:
        let up = max(0, e.walkUp(editor[]))
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
      if e.toolViewportRows.len > 0:
        stdout.write "\x1b[" & $e.toolViewportRows.len & "A"
      if compactRowsAboveFooter > 0:
        stdout.write "\x1b[" & $compactRowsAboveFooter & "A"
      stdout.write "\r\x1b[J"
      e.toolViewportRows = @[]
      if transcript.len > 0:
        stdout.write transcript
        if reserveFooter and not transcriptOwnsSpacing:
          stdout.write "\r\n\r\n"
      if reserveFooter:
        if footerBytes.len > 0:
          stdout.write footerBytes
          if inputRunning and editor != nil and restoreEditor:
            stdout.write "\x1b[1B"
        if inputRunning and editor != nil and restoreEditor:
          editor[].renderRow = 0
          stdout.write editor[].redrawBytes()
          if not editor[].pendingCaret:
            stdout.write "\x1b[?25h"
          e.noteFooterPainted(footerRowsAboveEditor)
        else:
          if footerBytes.len > 0:
            e.noteFooterPainted(max(1, footerRowsAboveEditor))
          else:
            e.noteNoFooter()
      else:
        e.noteNoFooter()
      if transcriptOwnsSpacing and transcript.len > 0 and reserveFooter and footerBytes.len > 0:
        e.gapIsSeparator = true
      stdout.flushFile

proc prepareAssistantContentStart*(e: var TerminalEngine;
                                   inputRunning: bool;
                                   editor: ptr minline.LineEditor;
                                   oldFooter: FooterFrame;
                                   hadBufferedSubmit: bool;
                                   flush = true) =
  ## Clear volatile footer chrome so live assistant content can begin as
  ## ordinary transcript output. Walk-up is derived from live state.
  termio.withTerminalWriteLock:
    let termW = try: terminalWidth() except CatchableError: 0
    if inputRunning and editor != nil:
      refreshEditorWidth(editor[])
      let up = max(0, e.walkUp(editor[]))
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
  ## transition bytes are produced by the fat-prompt renderer; cursor
  ## geometry uses the engine's live footer state.
  termio.withTerminalWriteLock:
    if inputRunning and editor != nil:
      refreshEditorWidth(editor[])
      let up = max(0, e.walkUp(editor[]))
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
