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
import ./terminaldbg
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
    liveContentHasGap: bool  # separator row above live content, matching committed scrollback spacing
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

var engineOutputEnabled* = true
  ## Master gate for terminal painting. When false (library/headless use),
  ## every global wrapper in this module becomes a no-op on stdout while
  ## still mutating `defaultEngine` state so the geometry model stays
  ## consistent if output is re-enabled. Set once at session start; not
  ## meant to be toggled mid-frame.

var headlessTranscriptHook*: proc(bytes: string) {.closure.}
  ## When set (library mode), `appendTranscript` forwards the committed
  ## transcript bytes here instead of painting them. Bytes carry ANSI
  ## styling; stripping is the consumer's job (library.nim owns that).

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

proc liveContentGapRows(e: TerminalEngine): int {.inline.} =
  if e.liveContentHasGap and e.liveContentRows.len > 0: 1 else: 0

proc walkUp(e: var TerminalEngine; ed: var minline.LineEditor): int =
  ## Rows from the cursor to the top of the volatile region (ticker row).
  ## Always derived from live editor + footer state. This is the number of
  ## rows to move up before erasing the volatile region.
  editorRowsAboveCursor(ed) + e.paintedFooterRows +
    e.viewportGapRows + e.toolViewportRows.len +
    e.liveContentGapRows + e.liveContentRows.len

proc noteFooterPainted(e: var TerminalEngine; footerRowsAboveEditor: int) =
  e.paintedFooterRows = max(0, footerRowsAboveEditor)

proc noteNoFooter(e: var TerminalEngine) =
  e.paintedFooterRows = 0

proc eraseUp(e: var TerminalEngine; ed: var minline.LineEditor;
             width, footerRowsAboveEditor: int): int =
  ## Rows to move up before erasing the volatile region. Normally this is the
  ## plain walkUp (editor rows + the previously-painted footer height +
  ## viewport/live rows). But after a terminal resize the bar/label re-wraps:
  ## paintedFooterRows still holds the pre-resize count while the rows
  ## actually on screen may be taller (or shorter). Erasing only the stale
  ## count leaves the extra wrapped rows behind in scrollback. On a width
  ## change, erase the larger of the old and new footer heights so the whole
  ## volatile region, old and new geometry alike, is cleared in one pass.
  result = editorRowsAboveCursor(ed) + e.viewportGapRows +
    e.toolViewportRows.len + e.liveContentGapRows + e.liveContentRows.len
  if width > 0 and e.lastPaintedWidth > 0 and width != e.lastPaintedWidth:
    result += max(e.paintedFooterRows, footerRowsAboveEditor)
  else:
    result += e.paintedFooterRows

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

# Write the live-content rows with a leading separator row when the live
# region sits below committed scrollback, so the gap is present during
# streaming and commit does not push the item down (mirrors
# `writeToolViewportRows`).
proc writeLiveContentRows(e: TerminalEngine) =
  if e.liveContentRows.len == 0: return
  if e.liveContentHasGap:
    stdout.write "\r\n"
  for row in e.liveContentRows:
    stdout.write row
    stdout.write "\r\n"

proc syncWrite*(e: var TerminalEngine; bytes: string) =
  termio.syncWrite(bytes)

proc syncWrite*(bytes: string) {.gcsafe.} =
  if not engineOutputEnabled: return
  {.cast(gcsafe).}:
    defaultEngine.syncWrite(bytes)

proc writeRaw*(e: var TerminalEngine; bytes: string) =
  termio.writeRaw(bytes)

proc writeRaw*(bytes: string) {.gcsafe.} =
  if not engineOutputEnabled: return
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
  if not engineOutputEnabled: return
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
  if not engineOutputEnabled: return
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
      let width = if termW > 0: termW else:
        try: terminalWidth() except CatchableError: 0
      let bytes = frame.footerFrameBytes(width)
      let footerRowsAboveEditor = frame.rowsAboveEditor(width)
      if not (inputRunning and editor != nil):
        stdout.write termio.SyncBegin
        stdout.write bytes
        e.noteNoFooter()
        stdout.write termio.SyncEnd
        stdout.flushFile
        e.lastPaintedWidth = width
        return
      let edPtr = editor
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      refreshEditorWidth(edPtr[])
      let up = eraseUp(e, edPtr[], width, footerRowsAboveEditor)
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
      e.lastPaintedWidth = width

proc renderFooter*(frame: FooterFrame; inputRunning: bool;
                   editor: ptr minline.LineEditor;
                   termW = 0) {.gcsafe.} =
  if not engineOutputEnabled: return
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
      if not (inputRunning and editor != nil):
        stdout.write termio.SyncBegin
        stdout.write "\x1b[?25l"
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
        return
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
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
            e.liveContentGapRows +
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
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd
      stdout.flushFile

proc renderToolViewport*(rows: openArray[string]; frame: FooterFrame;
                         inputRunning: bool; editor: ptr minline.LineEditor;
                         termW = 0; bannerRows = 1) {.gcsafe.} =
  if not engineOutputEnabled: return
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
  if not engineOutputEnabled: return
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
      if not (inputRunning and editor != nil):
        stdout.write termio.SyncBegin
        stdout.write "\x1b[?25l"
        e.liveContentHasGap = e.hasScrollback
        e.liveContentRows = @rows
        e.writeLiveContentRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
        e.lastPaintedWidth = width
        stdout.write termio.SyncEnd
        stdout.flushFile
        return
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      refreshEditorWidth(editor[])
      let up = eraseUp(e, editor[], width, footerRowsAboveEditor)
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
      stdout.write "\x1b[J"
      e.liveContentHasGap = e.hasScrollback
      e.liveContentRows = @rows
      e.writeLiveContentRows()
      if bytes.len > 0:
        stdout.write bytes
        stdout.write "\r\n"
      editor[].renderRow = 0
      stdout.write editor[].redrawBytes(synchronized = false)
      # Restore the caret to whatever the editor's pendingCaret dictates,
      # matching `renderFooter` and the input thread's postRedraw. During
      # buffered typing (pendingCaret == false) the caret must stay visible
      # so the GUI thread's 80ms streaming repaint does not fight the
      # input thread's keystroke redraw and flicker it on and off. Only a
      # deferred-submit hourglass (pendingCaret == true) keeps it hidden.
      if not editor[].pendingCaret:
        stdout.write "\x1b[?25h"
      if frame.kind == ffClear:
        e.noteNoFooter()
      else:
        e.noteFooterPainted(footerRowsAboveEditor)
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd
      stdout.flushFile

proc renderLiveContent*(rows: openArray[string]; frame: FooterFrame;
                        inputRunning: bool; editor: ptr minline.LineEditor;
                        termW = 0) {.gcsafe.} =
  if not engineOutputEnabled: return
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
      e.liveContentHasGap = false

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
      if not (inputRunning and editor != nil):
        stdout.write termio.SyncBegin
        stdout.write "\x1b[?25l"
        e.writeLiveContentRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
        e.lastPaintedWidth = width
        stdout.write termio.SyncEnd
        stdout.flushFile
        return
      stdout.write termio.SyncBegin
      stdout.write "\x1b[?25l"
      refreshEditorWidth(editor[])
      let up = eraseUp(e, editor[], width, footerRowsAboveEditor)
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
      stdout.write "\x1b[J"
      e.writeLiveContentRows()
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
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd
      stdout.flushFile

proc repaintLiveContent*(frame: FooterFrame; inputRunning: bool;
                         editor: ptr minline.LineEditor;
                         termW = 0) {.gcsafe.} =
  if not engineOutputEnabled: return
  {.cast(gcsafe).}:
    defaultEngine.repaintLiveContent(frame, inputRunning, editor, termW)

proc liveContentRowCount*(e: TerminalEngine): int {.gcsafe.} =
  e.liveContentRows.len

proc liveContentRowCount*(): int {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.liveContentRows.len

proc paintedFooterRowCount*(e: TerminalEngine): int {.gcsafe.} =
  e.paintedFooterRows

# Commit the transcript blob as real scrollback, with the one blank
# separator row owned here (see `appendTranscript` for the contract).
proc writeTranscriptItem(e: var TerminalEngine; transcript: string) =
  if transcript.len == 0: return
  if e.hasScrollback:
    stdout.write "\r\n"
  stdout.write transcript
  stdout.write "\r\n"
  e.hasScrollback = true

proc appendTranscriptLiveAnchored(e: var TerminalEngine; transcript: string;
                                  edPtr: ptr minline.LineEditor;
                                  footerBytes: string;
                                  footerRowsAboveEditor: int;
                                  compactRowsAboveFooter: int;
                                  restoreEditor: bool;
                                  reserveFooter: bool) =
  refreshEditorWidth(edPtr[])
  # Probe BEFORE SyncBegin: the DSR reply must not be swallowed by a
  # terminal that buffers synchronized-output frames. The input thread is
  # parked across this commit (restoreEditor=false on submit), so stdin is
  # the controller's to query.
  terminaldbg.probeDetail("commit.liveAnchored",
    max(0, e.walkUp(edPtr[]) + max(0, compactRowsAboveFooter)),
    editorRowsAboveCursor(edPtr[]), e.paintedFooterRows,
    e.toolViewportRows.len + e.viewportGapRows,
    e.liveContentRows.len + e.liveContentGapRows)
  stdout.write termio.SyncBegin
  stdout.write "\x1b[?25l\r"
  let up = max(0, e.walkUp(edPtr[]) + max(0, compactRowsAboveFooter))
  if up > 0:
    stdout.write "\x1b[" & $up & "A"
  stdout.write "\x1b[J"
  e.toolViewportRows = @[]
  e.writeTranscriptItem(transcript)
  if not reserveFooter:
    e.noteNoFooter()
  else:
    if footerBytes.len > 0:
      stdout.write footerBytes
      stdout.write "\r\n"
    if restoreEditor:
      edPtr[].renderRow = 0
      # Already inside SyncBegin: a nested 2026 frame would emit a
      # doubled ?2026l, which 2026-honoring terminals (foot, ghostty)
      # can batch/drop differently than the row model expects.
      stdout.write edPtr[].redrawBytes(synchronized = false)
      if not edPtr[].pendingCaret:
        stdout.write "\x1b[?25h"
      e.noteFooterPainted(footerRowsAboveEditor)
    elif footerBytes.len > 0:
      e.noteFooterPainted(max(1, footerRowsAboveEditor))
    else:
      e.noteNoFooter()
  stdout.write termio.SyncEnd
  stdout.flushFile

proc appendTranscriptFloating(e: var TerminalEngine; transcript: string;
                              inputRunning: bool;
                              editor: ptr minline.LineEditor;
                              footerBytes: string;
                              footerRowsAboveEditor: int;
                              compactRowsAboveFooter: int;
                              restoreEditor: bool;
                              reserveFooter: bool) =
  let editing = inputRunning and editor != nil
  if editing:
    terminaldbg.probeErase("commit.floating", max(0, e.walkUp(editor[])))
  stdout.write termio.SyncBegin
  if editing:
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
  e.writeTranscriptItem(transcript)
  if not reserveFooter:
    e.noteNoFooter()
  else:
    if footerBytes.len > 0:
      stdout.write footerBytes
      if editing and restoreEditor:
        stdout.write "\x1b[1B"
    if editing and restoreEditor:
      editor[].renderRow = 0
      stdout.write editor[].redrawBytes(synchronized = false)
      if not editor[].pendingCaret:
        stdout.write "\x1b[?25h"
      e.noteFooterPainted(footerRowsAboveEditor)
    elif footerBytes.len > 0:
      e.noteFooterPainted(max(1, footerRowsAboveEditor))
    else:
      e.noteNoFooter()
  stdout.write termio.SyncEnd
  stdout.flushFile

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
      if editor == nil: return
      e.appendTranscriptLiveAnchored(transcript, editor, footerBytes,
                                     footerRowsAboveEditor,
                                     compactRowsAboveFooter,
                                     restoreEditor, reserveFooter)
    else:
      e.appendTranscriptFloating(transcript, inputRunning, editor,
                                 footerBytes, footerRowsAboveEditor,
                                 compactRowsAboveFooter,
                                 restoreEditor, reserveFooter)

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
      terminaldbg.probeErase("assistantContentStart", max(0, e.walkUp(editor[])))
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
  if not engineOutputEnabled: return
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
  if not engineOutputEnabled: return
  defaultEngine.endTurn(inputRunning, editor, oldFooter, bytes)

proc appendTranscript*(transcriptBytes: string;
                       liveAnchored: bool;
                       inputRunning: bool;
                       editor: ptr minline.LineEditor;
                       oldFooter, newFooter: FooterFrame;
                       compactRowsAboveFooter = 0;
                       restoreEditor = true;
                       reserveFooter = true) =
  if not engineOutputEnabled:
    if headlessTranscriptHook != nil and transcriptBytes.len > 0:
      headlessTranscriptHook(transcriptBytes)
    return
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
