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
## before every item after the first and terminates each item's line with
## `\r\n`. The CLI always paints the welcome banner before the first item,
## so a committed item always sits below existing scrollback and the
## separator is unconditional. No item carries its own trailing separator.
## The footer's ticker row is separate volatile breathing room below the
## last item, so the two never stack.
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
import std/os
import std/strutils except toUpperAscii, toLowerAscii
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
    ## Terminal width at the last paint. A width change means the terminal
    ## reflowed already-painted rows (a wide banner wraps to more rows, a
    ## narrow one to fewer), so the relative walk-up from the stale
    ## `toolViewportRows.len` no longer reaches the reflowed stale content.
    ## On a change the erase inflates to clear the worst case.
    lastPaintedWidth: int
    ## Signature of the last painted composite frame. When a render entry
    ## point is asked to paint bytes identical to the last tick (same footer
    ## bytes, same volatile rows, same editor state, same width, same footer
    ## height), the erase+repaint is skipped entirely: the screen already
    ## shows exactly those bytes. Any path that repaints the screen out of
    ## band (transcript commit, assistant-content start, end turn, modal
    ## chrome) resets the signature via `noteFooterPainted`/`noteNoFooter`
    ## so the next render always paints.
    lastPaintSig: string
    ## On-screen content of the volatile block as last painted: bar + ticker
    ## rows (indices >= 0) and editor visual rows (indices < 0, -1 is the
    ## editor's top row). The viewport/live-content rows have their own
    ## tracked model (`toolViewportRows`/`liveContentRows`) and join the diff
    ## at paint time. The diff painter rewrites only rows whose content
    ## changed, so a ticking footer no longer repaints the whole volatile
    ## block every 80ms.
    lastVolatileRows: seq[string]

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

# Test-mode geometry audit. Under the PTY harness (frame fd set), every
# footer paint/clear logs the model's footer-row count so a test can fail
# loudly when painted rows and the frame model drift, instead of a later
# walk-up silently erasing into (or stranding rows above) scrollback.
var geometryAuditPath {.threadvar.}: string
var geometryAuditInit {.threadvar.}: bool

proc geometryAuditActive(): bool =
  if not geometryAuditInit:
    geometryAuditInit = true
    if getEnv("THREECODE_TEST_FRAME_FD").len > 0:
      geometryAuditPath = getEnv("THREECODE_GEOMETRY_AUDIT")
  geometryAuditPath.len > 0

proc geometryAudit(tag: string; rows: int) =
  if not geometryAuditActive(): return
  try:
    let f = open(geometryAuditPath, fmAppend)
    f.writeLine tag & " rows=" & $rows
    f.close()
  except IOError:
    discard

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
  ## Commit a footer height painted out of band (startup raw paint,
  ## resume registration). Callers that repaint footer/editor bytes
  ## out of band must sync the row model with what they painted (see
  ## `beginEditorRedraw` and `repaintVolatileAfterCommit`); this proc
  ## only records the height, so it wipes the model and lets the next
  ## diff paint rewrite every row.
  e.paintedFooterRows = max(0, footerRowsAboveEditor)
  e.lastPaintSig = ""
  e.lastVolatileRows = @[]
  geometryAudit("footerPainted", e.paintedFooterRows)

proc noteNoFooter(e: var TerminalEngine) =
  e.paintedFooterRows = 0
  e.lastPaintSig = ""
  e.lastVolatileRows = @[]
  geometryAudit("footerCleared", 0)

proc noteFooterPaintedKeepRows(e: var TerminalEngine;
                               footerRowsAboveEditor: int) =
  ## Commit the painted footer height after a diff paint: the row model
  ## the painter just stored stays valid for the next diff, unlike the
  ## out-of-band `noteFooterPainted` which must invalidate it.
  e.paintedFooterRows = max(0, footerRowsAboveEditor)
  e.lastPaintSig = ""
  geometryAudit("footerPainted", e.paintedFooterRows)

proc viewportSig(e: TerminalEngine): string =
  ## The volatile tool-viewport rows as last painted, including the gap
  ## row and banner split, so a skip decision knows the erase would be a
  ## no-op.
  $e.toolViewportHasGap & "\x1f" & $e.toolViewportBannerRows & "\x1f" &
    join(e.toolViewportRows, "\x1e")

proc editorSig(ed: var minline.LineEditor): string =
  ## Everything the embedded editor repaint depends on: buffer, cursor,
  ## transient suffix, caret mode, prompts, width. A keystroke between two
  ## identical-footer ticks must still repaint, so this joins the skip
  ## signature of every footer paint.
  ed.line.text & "\x1f" & $ed.line.position & "\x1f" & ed.renderSuffix &
    "\x1f" & $ed.renderSuffixCursor & "\x1f" & $ed.pendingCaret & "\x1f" &
    ed.prompt & "\x1f" & ed.contPrompt & "\x1f" & $ed.width

type
  VolatileRowKind* = enum
    vrkText,       # one painted row, compared by content
    vrkEditorSpan  # the editor's visual rows, compared via minline's own
                   # row model so both sides share the wrap geometry

  VolatileRow* = object
    case kind*: VolatileRowKind
    of vrkText:
      text*: string
    of vrkEditorSpan:
      discard

proc vrText*(text: string): VolatileRow =
  VolatileRow(kind: vrkText, text: text)

const vrEditor* = VolatileRow(kind: vrkEditorSpan)

proc diffRowBytes(text, prevText: string; width: int): string =
  ## Rewrite of one volatile row: `\r` + row text + `\x1b[K`. The EL
  ## clears to end of line without touching the next row: padding to the
  ## full width would put the cursor on the last cell, which a following
  ## `\n` (or the terminal's pending wrap) turns into an extra row shift.
  result = "\r" & text & "\x1b[K"

proc paintVolatileRegion*(e: var TerminalEngine; width: int;
                          sections: openArray[VolatileRow];
                          edPtr: ptr minline.LineEditor;
                          footerRowsAboveEditor: int;
                          newLiveRows, newViewportRows: seq[string];
                          newLiveGap, newViewportGap: bool;
                          newViewportBannerRows: int;
                          prevPaintedFooterRows = -1) =
  ## Shared repaint of the whole volatile block (live-content rows, tool
  ## viewport, footer bar+ticker, editor): walk up the currently-painted
  ## block, then rewrite only the rows whose painted content changed. The
  ## fat prompt has diffed via `lastPaintSig` for a long time; this is the
  ## same idea one level down: a ticking footer rewrites the changed bar
  ## row instead of erase-repainting the whole block every 80ms.
  ##
  ## `sections` is the block below the live/viewport content, top-down;
  ## the tracked gap rows above live/viewport content are added here so
  ## callers do not spell them out. The editor's cursor ends at its
  ## tracked visual row, or the block's bottom when there is no editor
  ## span.
  let resized = e.lastPaintedWidth > 0 and width > 0 and
    width != e.lastPaintedWidth

  if resized:
    # The terminal reflowed the painted rows; the tracked model no
    # longer matches the screen. Repaint from scratch: walk up the
    # larger of the pre/post-reflow block heights (the stale rows
    # occupy at most the pre-reflow count, the fresh paint the
    # post-reflow count), erase down, and diff against an empty model
    # so every row is rewritten.
    let prevEdRows = if edPtr != nil: max(1, minline.renderedRows(edPtr[])) else: 0
    let prevTotal = e.paintedFooterRows + e.toolViewportRows.len +
      e.viewportGapRows + e.liveContentRows.len + e.liveContentGapRows +
      prevEdRows
    var newTotal = newLiveRows.len + newViewportRows.len + sections.len +
      (if newLiveRows.len > 0 and newLiveGap: 1 else: 0) +
      (if newViewportRows.len > 0 and newViewportGap: 1 else: 0)
    if edPtr != nil:
      newTotal += prevEdRows
    let upErase = max(0, max(prevTotal, newTotal) - 1)
    if upErase > 0:
      stdout.write "\x1b[" & $upErase & "A"
    stdout.write "\r\x1b[J"
    e.lastVolatileRows = @[]
    e.lastPaintSig = ""
    e.paintedFooterRows = 0
    e.toolViewportRows = @[]
    e.toolViewportHasGap = false
    e.liveContentRows = @[]
    e.liveContentHasGap = false
  let prevBarCount = (if prevPaintedFooterRows >= 0:
      prevPaintedFooterRows else: e.paintedFooterRows)


  # Previous on-screen block, top-down: the tracked gap rows, live
  # content, viewport, then `lastVolatileRows` (bar+ticker, editor).
  # Volatile repaints never commit, so the new block shifts this one
  # only at the bottom; both share the same block bottom row.
  var prevRows: seq[string]
  if e.liveContentRows.len > 0 and e.liveContentHasGap:
    prevRows.add ""
  prevRows.add e.liveContentRows
  if e.toolViewportRows.len > 0 and e.toolViewportHasGap:
    prevRows.add ""
  prevRows.add e.toolViewportRows
  prevRows.add e.lastVolatileRows
  let prevEditorRows =
    if e.lastVolatileRows.len > prevBarCount:
      e.lastVolatileRows[prevBarCount ..< e.lastVolatileRows.len]
    else: @[]
  # Physical height of the on-screen block above the cursor: the same
  # walk-up geometry the old full-erase path used, NOT the (possibly
  # wiped) row model. Out-of-band commits clear `liveContentRows` /
  # `lastVolatileRows` while their erase leaves more rows on screen than
  # the post-commit paint produced; counting from the model under-walks
  # and strands those rows (the lingering `○0% ↓13` bar). The model seqs
  # stay the diff's content source; `prevH` is the physical row count.
  # Editor rows come from the editor's own live geometry (a wiped model
  # holds none), the rest from the tracked seqs and `paintedFooterRows`.
  let physEd = if edPtr != nil: max(1, minline.renderedRows(edPtr[])) else: 0
  let prevPhysEdRows = max(prevEditorRows.len, physEd)
  let walkH =
    (if edPtr != nil: physEd else: 0) +
    max(e.paintedFooterRows, prevBarCount) +
    e.viewportGapRows + e.toolViewportRows.len +
    e.liveContentGapRows + e.liveContentRows.len
  let physH = max(walkH, prevRows.len - prevEditorRows.len + prevPhysEdRows)
  var prevH = physH
  # New block, top-down.
  var cur: seq[VolatileRow]
  if newLiveRows.len > 0 and newLiveGap:
    cur.add vrText("")
  for row in newLiveRows:
    cur.add vrText(row)
  if newViewportRows.len > 0 and newViewportGap:
    cur.add vrText("")
  for row in newViewportRows:
    cur.add vrText(row)
  cur.add sections
  var newEdModel: seq[string]
  var caretRow = -1
  var caretCol = 0
  if edPtr != nil:
    for i, row in cur:
      if row.kind == vrkEditorSpan:
        newEdModel = edPtr[].renderRowSpans()
        cur.delete(i)
        for _ in newEdModel:
          cur.insert(vrEditor, i)
        caretRow = i + min(max(1, newEdModel.len) - 1, edPtr[].renderRow)
        # The diff painter rewrites whole rows, never the caret column:
        # position the caret exactly like `redrawBytes` does, or the
        # on-screen cursor rests at column 0 between keystrokes (the
        # harness's frames show a blank editor row instead of `❯ █`).
        let renderedText = edPtr[].line.text & edPtr[].renderSuffix
        let cursorText =
          if edPtr[].renderSuffixCursor: renderedText
          else: edPtr[].line.text
        let cursorPos =
          if edPtr[].renderSuffixCursor: renderedText.len
          else: edPtr[].line.position
        let pw = edPtr[].promptW
        let cw = edPtr[].contPromptW
        let (vrow, vcol) = minline.cursorVisual(cursorText, cursorPos,
          pw, cw, max(2, edPtr[].width))
        caretCol = vcol
        caretRow = i + min(max(1, newEdModel.len) - 1, vrow)
        break
  let blockH = max(cur.len, 1)
  # The cursor sits at the block's bottom, which the erase always left as
  # a live row. A growing block must claim its extra rows from scrollback
  # first (the old erase created them by clearing rows below the walk-up
  # target); without the scroll the first rewrite of a row at the
  # terminal's bottom edge would push the block instead of replacing it.
  if blockH > prevH:
    for _ in 0 ..< blockH - prevH:
      stdout.write "\r\n"
    prevH = blockH
  let anchor = if caretRow >= 0: caretRow else: blockH - 1
  let edTop = if newEdModel.len > 0: blockH - newEdModel.len else: -1
  # Walk up from the cursor (block bottom) to the block's top.
  let up = max(0, prevH - 1)

  if up > 0:
    stdout.write "\x1b[" & $up & "A"
  # When the previous block was taller at the top (a commit consumed
  # content rows out of band), the cursor's walk-up reaches the stale
  # top rows while the anchor-aligned row loop only covers the new
  # block below them. Blank that stale head explicitly, then step back
  # down to the new block's top. (ED-0 would be shorter, but terminal
  # models that implement it as "drop the rows below" shift anything
  # underneath up into the block.)
  let staleHead = max(0, prevH - blockH)
  if staleHead > 0:
    var headBuf = ""
    for _ in 0 ..< staleHead:
      headBuf.add "\r\x1b[2K"
      headBuf.add "\x1b[1B"
    headBuf.add "\x1b[" & $staleHead & "A"
    stdout.write headBuf
  # Top-down rewrite: rows compare against the previous block aligned
  # at the bottom. The editor sections align at their cursor rows (the
  # caret does not move during a volatile repaint); rows before the
  # previous block ever existed compare against a sentinel.
  var buf = "\r"
  # Editor-row indexing uses the physical editor count: after an
  # out-of-band wipe `prevEditorRows` is empty while the screen still
  # holds the editor's rows, so treating the count as zero would compare
  # the fresh editor rows against stale model rows (or nothing) and skip
  # repainting them.
  let prevEdTop = prevH - prevPhysEdRows
  let prevAnchor = prevH - 1 - (blockH - 1 - anchor)
  const Missing = "\x01MISSING"
  for i in 0 ..< blockH:
    let text =
      if i < cur.len and cur[i].kind == vrkText: cur[i].text
      elif edTop >= 0 and i >= edTop and i - edTop < newEdModel.len:
        newEdModel[i - edTop]
      else: ""
    var p = Missing
    if prevPhysEdRows > 0 and i >= edTop:
      # Current editor row: compare to the previous editor row the same
      # distance from the cursor. Rows the model no longer holds (wiped
      # out of band) compare against the sentinel and repaint.
      let k = prevAnchor + (i - anchor) - prevEdTop
      p = (if k >= 0 and k < prevEditorRows.len: prevEditorRows[k]
           else: Missing)
    else:
      # The previous block's top shifted by the same amount its cursor
      # row moved (the caret does not move during a volatile repaint;
      # sections below the cursor are rewritten each tick). Anchor-align
      # both blocks so unchanged rows compare to themselves.
      let j = prevAnchor + (i - anchor)
      if (prevPhysEdRows == 0 or j < prevEdTop) and
          j >= 0 and j < min(prevRows.len, prevH):
        p = prevRows[j]
    if p == Missing or resized or text != p:
      buf.add diffRowBytes(text, if p == Missing: "" else: p, width)
    if i < blockH - 1:
      # A pending wrap from a full row below (a viewport bar padded to
      # the width, or a row that filled its last cell) would wrap this
      # newline into a double row advance; `\r` disarms it first.
      buf.add "\r\n"
  # Reposition to the anchor row (editor cursor row or block bottom).
  let down = blockH - 1 - anchor
  if down > 0:
    buf.add "\x1b[" & $down & "A"
  buf.add "\r"
  if caretCol > 0:
    buf.add "\x1b[" & $caretCol & "C"
  if blockH < prevH:
    # The block shrank: the rows below the new bottom still hold stale
    # content the row loop never visits (it stops at the new bottom).
    # Blank them explicitly. (Erase-to-end-of-screen would be shorter,
    # but terminal models that implement ED-0 as "drop the rows below"
    # shift anything underneath — real scrollback in the grid — up into
    # the block and duplicate it.)
    for _ in 0 ..< prevH - blockH:
      buf.add "\x1b[B\x1b[2K"
    buf.add "\x1b[" & $(prevH - blockH) & "A"
  stdout.write buf
  # Store the model for the next diff: bar+ticker and editor rows only
  # (live/viewport rows are tracked by their own seqs).
  e.lastVolatileRows = @[]
  let footerTop = blockH - footerRowsAboveEditor
  let barEnd = if edTop >= 0: edTop else: blockH
  for i in max(0, footerTop) ..< min(barEnd, cur.len):
    e.lastVolatileRows.add (if cur[i].kind == vrkText: cur[i].text else: "")
  e.lastVolatileRows.add newEdModel
  e.liveContentRows = newLiveRows
  e.liveContentHasGap = newLiveGap
  e.toolViewportRows = newViewportRows
  e.toolViewportHasGap = newViewportGap
  e.toolViewportBannerRows = newViewportBannerRows


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
  var rows = frame.rowsAboveEditor(termW)
  # The reserved rows may only be walked up when they are actually live
  # chrome. After a reserveFooter=false commit (initial-prompt submit,
  # oneshot clear) the cursor sits flush below the committed item: no gap
  # row exists yet, and walking up `rows` here would erase the committed
  # line above. Paint in place instead; the next footer paint creates the
  # gap in the editor row's place.
  if rows > e.paintedFooterRows:
    rows = e.paintedFooterRows
  termio.beginEditorRedraw(ed, ready, frame.footerFrameBytes(termW),
                           rows)
  e.editorRedrawPending = true
  e.editorRedrawFooterRows = rows
  # The upcoming editor redraw rewrites the clamped footer rows and the
  # editor rows wholesale (`\x1b[J` + fresh bytes). Sync the diff model
  # with exactly what lands on screen so the next volatile repaint can
  # still diff (wiping it would full-repaint the block on every
  # keystroke). Rows the clamp did not cover keep their old content; the
  # erase below clears them, so mirror that with blanks.
  e.lastVolatileRows = @[]
  let texts = footerRowTexts(frame, termW)
  for i in 0 ..< max(rows, e.paintedFooterRows):
    e.lastVolatileRows.add (if i < rows and i < texts.len: texts[i] else: "")
  e.lastVolatileRows.add ed.renderRowSpans()

proc beginEditorRedraw*(ed: var minline.LineEditor; ready: bool;
                        frame: FooterFrame) =
  if not engineOutputEnabled: return
  defaultEngine.beginEditorRedraw(ed, ready, frame)

proc finishEditorRedraw*(e: var TerminalEngine; ed: var minline.LineEditor;
                         showCaret = true) =
  if e.editorRedrawPending:
    if e.editorRedrawFooterRows > 0:
      # beginEditorRedraw already synced the row model with the bytes
      # this redraw paints; keep it.
      e.noteFooterPaintedKeepRows(e.editorRedrawFooterRows)
    elif e.paintedFooterRows > 0:
      # A bare editor redraw (no footer bytes) must not wipe a nonzero
      # painted-footer count left by the ffNone commit path: that path
      # reserves the one-row gap below the last item as live chrome, and
      # the count is what makes the next commit's walk-up erase it.
      discard
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
        let sig = "F\x1f" & $footerRowsAboveEditor & "\x1f" & bytes &
          "\x1f\x1f\x1f" & $width
        if sig == e.lastPaintSig:
          return
        stdout.write termio.SyncBegin()
        stdout.write bytes
        # Gap-only ffNone has empty bytes but still reserves one row. Keep
        # the row model honest so the next walk-up does not under-count.
        if frame.kind == ffClear:
          e.noteNoFooter()
        else:
          e.noteFooterPainted(footerRowsAboveEditor)
        e.lastPaintSig = sig
        stdout.write termio.SyncEnd()
        stdout.flushFile
        e.lastPaintedWidth = width
        return
      let edPtr = editor
      refreshEditorWidth(edPtr[])
      let sig = "F\x1f" & $footerRowsAboveEditor & "\x1f" &
        e.viewportSig() & "\x1f" & bytes & "\x1f" & editorSig(edPtr[]) &
        "\x1f" & $width
      if sig == e.lastPaintSig:
        return
      stdout.write termio.SyncBegin()
      stdout.write "\x1b[?25l"
      # The diff painter rewrites only rows whose content changed: a
      # ticking bar no longer erase-repaints the whole volatile block
      # every 80ms, so streaming live content and the tool viewport
      # survive a footer-only repaint untouched.
      let prevFooterRows = e.paintedFooterRows
      var vrows: seq[VolatileRow]
      for row in footerRowTexts(frame, width):
        vrows.add vrText(row)
      vrows.add vrEditor
      e.paintVolatileRegion(width, vrows, edPtr, footerRowsAboveEditor,
        e.liveContentRows, e.toolViewportRows,
        e.liveContentHasGap, e.toolViewportHasGap,
        e.toolViewportBannerRows,
        prevPaintedFooterRows = prevFooterRows)
      if not edPtr[].pendingCaret:
        stdout.write "\x1b[?25h"
      if frame.kind == ffClear:
        e.noteNoFooter()
      else:
        e.noteFooterPaintedKeepRows(footerRowsAboveEditor)
      e.lastPaintSig = sig
      stdout.write termio.SyncEnd()
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
      if not (inputRunning and editor != nil):
        # No editor below: paint without a walk-up. Do NOT touch
        # `lastPaintedWidth` here — a resize must stay pending for the
        # full repaint path below, whose inflated one-shot erase is the
        # only thing that clears the reflowed stale rows. Consuming the
        # width change here made the next full repaint fall short and
        # left stale banner fragments stacking in scrollback.
        let sig = "V\x1f" & join(rows, "\x1e") &
          "\x1f" & $bannerRows & "\x1f" & bytes & "\x1f\x1f" & $width
        if sig == e.lastPaintSig:
          return
        stdout.write termio.SyncBegin()
        stdout.write "\x1b[?25l"
        e.toolViewportHasGap = true
        e.toolViewportRows = @rows
        e.toolViewportBannerRows = bannerRows
        e.writeToolViewportRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
        e.lastPaintSig = sig
        stdout.write termio.SyncEnd()
        stdout.flushFile
        return
      refreshEditorWidth(editor[])
      let sig = "V\x1f" & join(rows, "\x1e") &
        "\x1f" & $bannerRows & "\x1f" & bytes & "\x1f" &
        editorSig(editor[]) & "\x1f" & $width
      if sig == e.lastPaintSig:
        return
      stdout.write termio.SyncBegin()
      stdout.write "\x1b[?25l"
      let prevFooterRows = e.paintedFooterRows
      let newGap = true
      var vrows: seq[VolatileRow]
      for row in footerRowTexts(frame, width):
        vrows.add vrText(row)
      vrows.add vrEditor
      e.paintVolatileRegion(width, vrows, editor, footerRowsAboveEditor,
        e.liveContentRows, @rows,
        e.liveContentHasGap, newGap, bannerRows,
        prevPaintedFooterRows = prevFooterRows)
      if not editor[].pendingCaret:
        stdout.write "\x1b[?25h"
      if frame.kind == ffClear:
        e.noteNoFooter()
      else:
        e.noteFooterPaintedKeepRows(footerRowsAboveEditor)
      e.lastPaintSig = sig
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd()
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
        let sig = "L\x1f" &
          join(rows, "\x1e") & "\x1f" & bytes & "\x1f\x1f" & $width
        if sig == e.lastPaintSig:
          return
        stdout.write termio.SyncBegin()
        stdout.write "\x1b[?25l"
        e.liveContentHasGap = true
        e.liveContentRows = @rows
        e.writeLiveContentRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
        e.lastPaintSig = sig
        e.lastPaintedWidth = width
        stdout.write termio.SyncEnd()
        stdout.flushFile
        return
      refreshEditorWidth(editor[])
      let sig = "L\x1f" & join(rows, "\x1e") &
        "\x1f" & bytes & "\x1f" & editorSig(editor[]) & "\x1f" & $width
      if sig == e.lastPaintSig:
        return
      stdout.write termio.SyncBegin()
      stdout.write "\x1b[?25l"
      let prevFooterRows = e.paintedFooterRows
      var vrows: seq[VolatileRow]
      for row in footerRowTexts(frame, width):
        vrows.add vrText(row)
      vrows.add vrEditor
      e.paintVolatileRegion(width, vrows, editor, footerRowsAboveEditor,
        @rows, e.toolViewportRows,
        true, e.toolViewportHasGap,
        e.toolViewportBannerRows,
        prevPaintedFooterRows = prevFooterRows)
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
        e.noteFooterPaintedKeepRows(footerRowsAboveEditor)
      e.lastPaintSig = sig
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd()
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
        let sig = "R\x1f" & $e.liveContentHasGap & "\x1f" & bytes &
          "\x1f\x1f" & $width
        if sig == e.lastPaintSig:
          return
        stdout.write termio.SyncBegin()
        stdout.write "\x1b[?25l"
        e.writeLiveContentRows()
        if bytes.len > 0:
          stdout.write bytes
        e.noteNoFooter()
        e.lastPaintSig = sig
        e.lastPaintedWidth = width
        stdout.write termio.SyncEnd()
        stdout.flushFile
        return
      refreshEditorWidth(editor[])
      let sig = "R\x1f" & $e.liveContentHasGap & "\x1f" & bytes &
        "\x1f" & editorSig(editor[]) & "\x1f" & $width
      if sig == e.lastPaintSig:
        return
      stdout.write termio.SyncBegin()
      stdout.write "\x1b[?25l"
      let prevFooterRows = e.paintedFooterRows
      var vrows: seq[VolatileRow]
      for row in footerRowTexts(frame, width):
        vrows.add vrText(row)
      vrows.add vrEditor
      e.paintVolatileRegion(width, vrows, editor, footerRowsAboveEditor,
        e.liveContentRows, e.toolViewportRows,
        e.liveContentHasGap, e.toolViewportHasGap,
        e.toolViewportBannerRows,
        prevPaintedFooterRows = prevFooterRows)
      if not editor[].pendingCaret:
        stdout.write "\x1b[?25h"
      if frame.kind == ffClear:
        e.noteNoFooter()
      else:
        e.noteFooterPaintedKeepRows(footerRowsAboveEditor)
      e.lastPaintSig = sig
      e.lastPaintedWidth = width
      stdout.write termio.SyncEnd()
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

proc paintedFooterRowCount*(): int {.gcsafe.} =
  {.cast(gcsafe).}:
    defaultEngine.paintedFooterRows

proc noteFooterPainted*(footerRowsAboveEditor: int) {.gcsafe.} =
  ## Register the currently-painted footer height without repainting.
  ## Used by the prompt-only startup path, which paints the gap+prompt via
  ## raw bytes before the input thread is up, so the first walk-up still
  ## knows the reserved gap row is live chrome.
  {.cast(gcsafe).}:
    defaultEngine.noteFooterPainted(footerRowsAboveEditor)

proc noteNoFooter*() {.gcsafe.} =
  ## Register that no footer rows are live chrome right now. Used by the
  ## modal wizard, which paints its field prompts flush at the cursor with
  ## none of the persistent prompt's reserved gap row; leaving the stale
  ## count in place makes the next transcript commit erase a scrollback row.
  {.cast(gcsafe).}:
    defaultEngine.noteNoFooter()

# Commit the transcript blob as real scrollback, with the one blank
# separator row owned here (see `appendTranscript` for the contract). The
# CLI always paints the welcome banner before the first commit, so the
# separator is unconditional. `flushWithPrevious` skips it for a blob
# that continues the item above it (a receipt joining the streamed
# answer it caps).
proc writeTranscriptItem(e: var TerminalEngine; transcript: string;
                         flushWithPrevious = false) =
  if transcript.len == 0: return
  if not flushWithPrevious:
    stdout.write "\r\n"
  stdout.write transcript
  stdout.write "\r\n"

proc repaintVolatileAfterCommit(e: var TerminalEngine;
                                edPtr: ptr minline.LineEditor;
                                footerBytes: string;
                                footerRowsAboveEditor: var int;
                                restoreEditor: bool;
                                reserveFooter: bool) =
  ## Second half of a transcript commit: the erase consumed the volatile
  ## region, the item is committed scrollback; now rebuild the live chrome
  ## below it. `edPtr` is nil (or restoreEditor false) when no editor is
  ## being restored (submit path, wizard).
  if not reserveFooter:
    e.noteNoFooter()
    return
  let editing = edPtr != nil and restoreEditor
  if editing and footerRowsAboveEditor == 0 and footerBytes.len == 0:
    # Defensive: ffNone's rowsAboveEditor is 1 (the reserved gap). If a
    # caller still hands us 0, force the gap into both the bytes and the
    # row model so the next walk-up cannot leave a stray blank scrollback
    # row (the extra-line bug).
    stdout.write "\r\n"
    stdout.write "\x1b[1A"
    footerRowsAboveEditor = 1
  if footerBytes.len > 0:
    # The row model and the emitted bytes must agree on the footer's
    # height: the bar+ticker bytes are exactly footerRowsAboveEditor rows
    # by construction (see `rowsAboveEditor`). If that invariant ever
    # breaks the walk-up lands on committed scrollback, so say so here
    # where the two numbers meet rather than at the erase.
    stdout.write footerBytes
    # One trailing advance past the footer's last row: the editor paints
    # on the row below it.
    stdout.write "\r\n"
  elif editing:
    # No footer to preserve (ffNone): the gap row the editor normally
    # sits below is the previous footer's volatile ticker row, and the
    # erase just consumed it. Paint one blank row so the prompt keeps
    # its one-row distance from the last committed item, matching the
    # bar+prompt `endTurn` gap.
    stdout.write "\r\n"
  if editing:
    edPtr[].renderRow = 0
    # Already inside SyncBegin at every call site: a nested 2026 frame
    # would emit a doubled ?2026l, which 2026-honoring terminals (foot,
    # ghostty) can batch/drop differently than the row model expects.
    stdout.write edPtr[].redrawBytes(synchronized = false)
    if not edPtr[].pendingCaret:
      stdout.write "\x1b[?25h"
    e.noteFooterPainted(footerRowsAboveEditor)
    # Do NOT sync the diff model here: the submit path clears the
    # editor buffer right after this repaint, and the next volatile
    # paint would compare its fresh editor rows against the stale spans
    # captured now and skip repainting them. The wiped model forces a
    # full rewrite of the chrome rows once, which is exactly what the
    # screen needs after a commit.
  elif footerBytes.len > 0:
    e.noteFooterPainted(max(1, footerRowsAboveEditor))
  else:
    e.noteNoFooter()

proc commitTranscriptItem(e: var TerminalEngine; transcript: string;
                          inputRunning: bool;
                          edPtr: ptr minline.LineEditor;
                          footerBytes: string;
                          footerRowsAboveEditor: int;
                          compactRowsAboveFooter: int;
                          restoreEditor: bool;
                          reserveFooter: bool;
                          flushWithPrevious = false) =
  ## The single commit-repaint path for both anchored and floating state:
  ## walk from the cursor to the top of the volatile region, erase it,
  ## commit the item as scrollback, rebuild the chrome. One proc owns the
  ## geometry rules (full-region walk-up, no-footer gap row) so a rule
  ## change cannot land in only one of two near-identical copies.
  let editing = inputRunning and edPtr != nil
  if editing:
    # Probe BEFORE SyncBegin: the DSR reply must not be swallowed by a
    # terminal that buffers synchronized-output frames. The input thread
    # is parked across this commit (restoreEditor=false on submit), so
    # stdin is the controller's to query.
    terminaldbg.probeDetail("commit",
      max(0, e.walkUp(edPtr[]) + max(0, compactRowsAboveFooter)),
      editorRowsAboveCursor(edPtr[]), e.paintedFooterRows,
      e.toolViewportRows.len + e.viewportGapRows,
      e.liveContentRows.len + e.liveContentGapRows)
  stdout.write termio.SyncBegin()
  if editing:
    stdout.write "\x1b[?25l\r"
  let up =
    if editing:
      max(0, e.walkUp(edPtr[]) + max(0, compactRowsAboveFooter))
    else:
      # Floating (non-editing) commits must also consume registered footer
      # chrome: the resume-with-usage startup paint registers its bar rows
      # while no editor exists yet, and a commit that ignored them would
      # leave the bar stranded in scrollback as a duplicated line.
      e.paintedFooterRows +
        max(0, e.toolViewportRows.len + max(0, compactRowsAboveFooter))
  if up > 0:
    stdout.write "\x1b[" & $up & "A"
  stdout.write "\r\x1b[J"
  e.toolViewportRows = @[]
  # The erase just consumed the volatile live-content rows (the streaming
  # partial this commit writes to scrollback). Clear them inside the same
  # write-lock critical section, not in the controller's later
  # `clearLiveContent` call: a guiLoop spinner repaint firing in that window
  # would read the stale row count and over-walk its own erase into the
  # just-committed scrollback above (erasing the echo/welcome lines).
  e.liveContentRows = @[]
  e.liveContentHasGap = false
  e.writeTranscriptItem(transcript, flushWithPrevious)
  let restoreTo = if editing: edPtr else: nil
  var newFooterRows = footerRowsAboveEditor
  e.repaintVolatileAfterCommit(restoreTo, footerBytes,
                               newFooterRows,
                               restoreEditor, reserveFooter)
  stdout.write termio.SyncEnd()
  stdout.flushFile

proc appendTranscript*(e: var TerminalEngine; transcriptBytes: string;
                       liveAnchored: bool;
                       inputRunning: bool;
                       editor: ptr minline.LineEditor;
                       oldFooter, newFooter: FooterFrame;
                       compactRowsAboveFooter = 0;
                       restoreEditor = true;
                       reserveFooter = true;
                       flushWithPrevious = false) =
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
    if liveAnchored and editor == nil: return
    e.commitTranscriptItem(transcript, inputRunning, editor,
                           footerBytes, footerRowsAboveEditor,
                           compactRowsAboveFooter,
                           restoreEditor, reserveFooter, flushWithPrevious)

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
      stdout.write termio.SyncBegin()
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
      stdout.write "\x1b[J"
      e.noteNoFooter()
      stdout.write termio.SyncEnd()
      if flush:
        stdout.flushFile
    elif oldFooter.kind != ffNone and not hadBufferedSubmit:
      stdout.write termio.SyncBegin()
      stdout.write oldFooter.footerFrameBytes(termW)
      e.noteNoFooter()
      stdout.write termio.SyncEnd()
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
    stdout.write termio.SyncBegin()
    if inputRunning and editor != nil:
      refreshEditorWidth(editor[])
      let up = max(0, e.walkUp(editor[]))
      stdout.write "\r"
      if up > 0:
        stdout.write "\x1b[" & $up & "A"
    stdout.write bytes
    e.noteNoFooter()
    stdout.write termio.SyncEnd()
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
                       reserveFooter = true;
                       flushWithPrevious = false) =
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
    reserveFooter,
    flushWithPrevious)
