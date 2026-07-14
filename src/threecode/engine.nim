## Stateful terminal layout engine.
##
## Controllers append transcript bytes and mutate fat-prompt state; this module
## owns the cursor geometry needed to clear/repaint the volatile footer around
## those appends. Scrollback bytes are append-only once emitted.
##
## Layout (bottom → top):
##   editor rows (variable, cursor somewhere within)
##   bar row(s)
##   ticker row (always reserved, even when blank) — volatile breathing room
##   scrollback content …
##
## One blank row separates every pair of scrollback items. The separator is
## owned by a single emission point (`appendTranscript`): it prepends `\r\n`
## before every item after the first (gated by `hasScrollback`) and
## terminates each item's line with `\r\n`. No item carries its own trailing
## separator. The footer's ticker row is separate volatile breathing room
## below the last item, so the two never stack.
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

import std/terminal
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
    toolViewportBannerRows: int  # leading rows that are banner (white), not output (grey)
    toolViewportHasGap: bool  # separator row above the viewport, matching committed scrollback spacing
    ## Volatile in-progress assistant content above the footer during live
    ## streaming. Like the tool viewport it is erased and rewritten each
    ## frame; committed lines go to real scrollback via `appendTranscript`.
    liveContentRows: seq[string]
    editorRedrawPending: bool
    editorRedrawFooterRows: int
    ## True once any non-empty transcript content has been committed. Gates
    ## the inter-item separator: `appendTranscript` prepends `\r\n\r\n`
    ## before every item after the first, so the separator is owned by one
    ## emission point rather than carried by each item.
    hasScrollback: bool
    ## Terminal width at the last paint. A width change means the terminal
    ## reflowed already-painted rows (a wide banner wraps to more rows, a
    ## narrow one to fewer), so the relative walk-up from the stale
    ## `toolViewportRows.len` no longer reaches the reflowed stale content.
    ## On a change the erase inflates to clear the worst case.
    lastPaintedWidth: int

var defaultEngine*: TerminalEngine

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

proc viewportGapRows(e: TerminalEngine): int {.inline.} =
  if e.toolViewportHasGap and e.toolViewportRows.len > 0: 1 else: 0

proc walkUp(e: var TerminalEngine; ed: var minline.LineEditor): int =
  ## Rows from the cursor to the top of the volatile region (ticker row).
  ## Always derived from live editor + footer state. This is the number of
  ## rows to move up before erasing the volatile region.
  editorRowsAboveCursor(ed) + e.paintedFooterRows +
    e.viewportGapRows + e.toolViewportRows.len + e.liveContentRows.len

proc noteFooterPainted(e: var TerminalEngine; footerRowsAboveEditor: int) =
  e.paintedFooterRows = max(0, footerRowsAboveEditor)

proc noteNoFooter(e: var TerminalEngine) =
  e.paintedFooterRows = 0

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
  if e.toolViewportHasGap:
    stdout.write "\r\n"
  for i, row in e.toolViewportRows:
    if i < e.toolViewportBannerRows:
      stdout.write OffWhiteFg
    else:
      stdout.write GreyFg
    stdout.write row
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
      let bytes = frame.footerFrameBytes(termW)
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
                         termW = 0; bannerRows = 1) {.gcsafe.} =
  ## Replace the volatile bash viewport and repaint footer/editor in one
  ## synchronized frame. The viewport is live chrome: it is not transcript
  ## scrollback, and the controller commits final output separately.
  ## `bannerRows` is the count of leading rows that are banner (white),
  ## not output (grey).
  {.cast(gcsafe).}:
    termio.withTerminalWriteLock:
      let width = if termW > 0: termW else:
        try: terminalWidth() except CatchableError: 0
      let bytes = frame.footerFrameBytes(width)
      let footerRowsAboveEditor = frame.rowsAboveEditor(width)
      let reflowed = e.lastPaintedWidth > 0 and width > 0 and
        width != e.lastPaintedWidth
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      if inputRunning and editor != nil:
        refreshEditorWidth(editor[])
        # A width change reflowed the already-painted volatile rows: a wide
        # banner/output wraps to more rows (or fewer) on screen, but the
        # stored `toolViewportRows.len` still holds the pre-reflow count, so a
        # plain walkUp would fall short and leave stale fragments. Inflate the
        # erase to clear the whole volatile region — bounded by the terminal
        # height, which always covers the reflowed stale content.
        let up = if reflowed:
            max(0, editorRowsAboveCursor(editor[]) +
              e.paintedFooterRows + e.viewportGapRows + e.liveContentRows.len +
              (try: terminalHeight() except CatchableError: 24))
          else:
            max(0, e.walkUp(editor[]))
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write "\x1b[J"
        e.toolViewportHasGap = e.hasScrollback
        e.toolViewportRows = @rows
        e.toolViewportBannerRows = bannerRows
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
        e.toolViewportHasGap = e.hasScrollback
        e.toolViewportRows = @rows
        e.toolViewportBannerRows = bannerRows
        e.writeToolViewportRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd
      stdout.flushFile

proc renderToolViewport*(rows: openArray[string]; frame: FooterFrame;
                         inputRunning: bool; editor: ptr minline.LineEditor;
                         termW = 0; bannerRows = 1) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.renderToolViewport(rows, frame, inputRunning, editor, termW,
                                     bannerRows)

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
      let bytes = frame.footerFrameBytes(width)
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

proc repaintLiveContent*(e: var TerminalEngine; frame: FooterFrame;
                         inputRunning: bool;
                         editor: ptr minline.LineEditor;
                         termW = 0) {.gcsafe.} =
  ## Repaint the currently-tracked live content rows together with a new
  ## footer frame, in one synchronized frame. Unlike `renderLiveContent`
  ## (which the controller calls with fresh rows on each chunk), this reads
  ## the rows already stored in `e.liveContentRows` and only swaps the
  ## footer. It is the GUI thread's spinner animation path: when content is
  ## streaming the spinner must keep rotating, but the footer repaint must
  ## not erase the volatile partial the controller wrote. Painting the
  ## stored rows + the animated footer as one composite (the same shape
  ## `renderLiveContent` produces) keeps the partial intact.
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
        let up = max(0, e.walkUp(editor[]))
        stdout.write "\r"
        if up > 0:
          stdout.write "\x1b[" & $up & "A"
        stdout.write "\x1b[J"
        for row in e.liveContentRows:
          stdout.write row
          stdout.write "\r\n"
        if bytes.len > 0:
          stdout.write bytes
          stdout.write "\r\n"
        editor[].renderRow = 0
        stdout.write editor[].redrawBytes(synchronized = false)
        if frame.kind == ffClear:
          e.noteNoFooter()
        else:
          e.noteFooterPainted(footerRowsAboveEditor)
      else:
        for row in e.liveContentRows:
          stdout.write row
          stdout.write "\r\n"
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
      stdout.write termio.SyncEnd
      stdout.flushFile

proc repaintLiveContent*(frame: FooterFrame; inputRunning: bool;
                         editor: ptr minline.LineEditor;
                         termW = 0) {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.repaintLiveContent(frame, inputRunning, editor, termW)

proc liveContentRowCount*(e: TerminalEngine): int {.gcsafe.} =
  e.liveContentRows.len

proc liveContentRowCount*(): int {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.liveContentRows.len

proc paintedFooterRowCount*(e: TerminalEngine): int {.gcsafe.} =
  e.paintedFooterRows

proc appendTranscript*(e: var TerminalEngine; transcriptBytes: string;
                       liveAnchored: bool;
                       inputRunning: bool;
                       editor: ptr minline.LineEditor;
                       oldFooter, newFooter: FooterFrame;
                       compactRowsAboveFooter = 0;
                       restoreEditor = true;
                       reserveFooter = true) =
  ## Append transcript bytes as real scrollback while preserving or clearing
  ## the volatile footer. One blank row separates every pair of items, owned
  ## by one place: here. Before every item after the first, `\r\n` is
  ## prepended (one blank row); content is bare (trailing \r/\n trimmed
  ## before the write — append-only-safe) and terminated with a single `\r\n`
  ## so the cursor advances past it. The footer's ticker row is separate
  ## volatile breathing room below the last item, so the two never stack.
  termio.withTerminalWriteLock:
    let termW = try: terminalWidth() except CatchableError: 0
    let footerBytes = newFooter.footerFrameBytes(termW)
    let footerRowsAboveEditor = newFooter.rowsAboveEditor(termW)
    let transcript = trimTrailingNewlines(transcriptBytes)
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
        if e.hasScrollback:
          stdout.write "\r\n"
        stdout.write transcript
        stdout.write "\r\n"
        e.hasScrollback = true
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
      stdout.write termio.SyncEnd
      stdout.flushFile
    else:
      stdout.write termio.SyncBegin
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
        if e.hasScrollback:
          stdout.write "\r\n"
        stdout.write transcript
        stdout.write "\r\n"
        e.hasScrollback = true
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
      stdout.write termio.SyncEnd
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
      stdout.write termio.SyncBegin
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
      stdout.write "\x1b[J"
      e.noteNoFooter()
      stdout.write termio.SyncEnd
      if flush:
        stdout.flushFile
    elif oldFooter.kind != ffNone and not hadBufferedSubmit:
      stdout.write termio.SyncBegin
      stdout.write oldFooter.footerFrameBytes(termW)
      e.noteNoFooter()
      stdout.write termio.SyncEnd
      if flush:
        stdout.flushFile
    elif flush:
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
    stdout.write termio.SyncBegin
    if inputRunning and editor != nil:
      refreshEditorWidth(editor[])
      let up = max(0, e.walkUp(editor[]))
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
    stdout.write bytes
    e.noteNoFooter()
    stdout.write termio.SyncEnd
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
                       reserveFooter = true) =
  defaultEngine.appendTranscript(
    transcriptBytes,
    liveAnchored,
    inputRunning,
    editor,
    oldFooter,
    newFooter,
    compactRowsAboveFooter,
    restoreEditor,
    reserveFooter)
