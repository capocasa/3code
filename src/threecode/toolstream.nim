## Live tool-output viewport.
##
## This module owns the bounded bash output view: show at most eight lines
## while a command streams, then render the same cutoff-plus-tail shape for
## completed bash output. It is not part of the fat prompt; callers render it
## through the terminal write lock so it cannot intrude into reserved prompt
## rows.

import std/[strformat, strutils, terminal]
import util
import terminal as termui

const StreamMaxLines* = 8

proc subtleWriteLn*(outFile: File, body: string) =
  outFile.write GreyFg
  outFile.write body
  outFile.write Reset
  outFile.write "\r\n"

proc eraseRows(n: int) =
  termui.eraseRowsAbove(n)

proc indentedRowCount(l: string): int =
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - 3)
  result = max(1, charWrapAnsi(l, bodyW).len)

proc trimTrailingBlank(lines: var seq[string]) =
  while lines.len > 0 and lines[^1].strip == "":
    lines.setLen lines.len - 1

proc writeWrappedLine(l: string) =
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - 3)
  for chunk in charWrapAnsi(l, bodyW):
    subtleWriteLn(stdout, "  " & chunk)

proc printLine*(l: string) =
  ## Print one wrapped tool-output line as an append-only transcript write.
  ## This is exported for display formatting; live viewport operations below
  ## take the terminal lock themselves.
  writeWrappedLine(l)

type
  StreamingView* = object
    maxLines*: int
    idx*: int
    total*: int
    onScreen*: int
    buf*: seq[string]

proc initStreamingView*(maxLines = StreamMaxLines, idx = 0): StreamingView =
  StreamingView(maxLines: maxLines, idx: idx, buf: @[])

proc omittedLine(v: StreamingView): string =
  let hidden = max(0, v.total - (v.maxLines - 1))
  let show =
    if v.idx > 0: " :show " & $v.idx & " for full"
    else: ""
  &"... {hidden} line" & (if hidden == 1: "" else: "s") &
    " omitted" & show

proc addLine*(v: var StreamingView, line: string) =
  termui.withTerminalWriteLock:
    inc v.total
    v.buf.add line
    if v.total <= v.maxLines:
      writeWrappedLine(line)
      v.onScreen += indentedRowCount(line)
    else:
      eraseRows(v.onScreen)
      v.onScreen = 0
      let mark = omittedLine(v)
      writeWrappedLine(mark)
      v.onScreen += indentedRowCount(mark)
      let tailLines = max(0, v.maxLines - 1)
      let start = max(0, v.buf.len - tailLines)
      for i in start..<v.buf.len:
        writeWrappedLine(v.buf[i])
        v.onScreen += indentedRowCount(v.buf[i])
      stdout.flushFile()

proc erase*(v: var StreamingView) =
  termui.withTerminalWriteLock:
    eraseRows(v.onScreen)
    v.onScreen = 0

proc printBashScroll*(res: string, idx: int, maxLines = StreamMaxLines) =
  termui.withTerminalWriteLock:
    var lines = res.splitLines
    trimTrailingBlank(lines)
    if lines.len <= maxLines:
      for l in lines: writeWrappedLine(l)
      return
    let tailLen = max(0, maxLines - 1)
    let hidden = lines.len - tailLen
    let show = if idx > 0: " :show " & $idx & " for full" else: ""
    subtleWriteLn(stdout,
      &"  ... {hidden} line" & (if hidden == 1: "" else: "s") &
      " omitted" & show)
    for i in lines.len - tailLen ..< lines.len:
      writeWrappedLine(lines[i])
