## Bash tool-output viewport model and transcript formatting.
##
## The live viewport is semantic state: command banner, streamed lines, cutoff
## policy, and final exit code. Terminal placement belongs to engine.

import std/[strformat, strutils, terminal]
import util

const
  StreamMaxLines* = 8

proc subtleWriteLn*(outFile: File, body: string) =
  outFile.write GreyFg
  outFile.write body
  outFile.write Reset
  outFile.write "\r\n"

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
    banner*: string
    exitCode*: int
    symbol*: string
    buf*: seq[string]

proc initStreamingView*(maxLines = StreamMaxLines, idx = 0;
                        banner = ""): StreamingView =
  StreamingView(maxLines: maxLines, idx: idx, banner: banner,
                exitCode: -1, symbol: "$", buf: @[])

proc omittedLine(v: StreamingView): string =
  let hidden = max(0, v.total - (v.maxLines - 1))
  let show =
    if v.idx > 0: " :show " & $v.idx & " for full"
    else: ""
  &"... {hidden} line" & (if hidden == 1: "" else: "s") &
    " omitted" & show

proc commandIcon(v: StreamingView): string =
  if v.exitCode > 0: "Ø" else: v.symbol

proc setSymbol*(v: var StreamingView; symbol: string) =
  v.symbol = symbol

proc setExitCode*(v: var StreamingView; code: int) =
  v.exitCode = code

proc wrappedRows(line: string): seq[string] =
  let termW = try: terminalWidth() except CatchableError: 80
  let bodyW = max(20, termW - 3)
  for chunk in charWrapAnsi(line, bodyW):
    result.add "  " & chunk

proc visibleOutputLines(v: StreamingView): seq[string] =
  var logical: seq[string]
  if v.buf.len <= v.maxLines:
    logical = v.buf
  else:
    logical.add v.omittedLine()
    let tailLines = max(0, v.maxLines - 1)
    let start = max(0, v.buf.len - tailLines)
    for i in start..<v.buf.len:
      logical.add v.buf[i]
  logical

proc viewportRows*(v: StreamingView): seq[string] =
  let termW = try: terminalWidth() except CatchableError: 80
  for row in bannerWrapRows(v.commandIcon & " ", v.banner, termW):
    result.add row
  for line in v.visibleOutputLines():
    for row in wrappedRows(line):
      result.add row

proc bannerRowCount*(v: StreamingView): int =
  let termW = try: terminalWidth() except CatchableError: 80
  bannerWrapRows(v.commandIcon & " ", v.banner, termW).len

proc finalTranscriptRows*(banner: string; code: int; lines: openArray[string];
                          idx: int; maxLines = StreamMaxLines): seq[string] =
  var v = initStreamingView(maxLines, idx, banner)
  v.exitCode = code
  for line in lines:
    v.buf.add line
    inc v.total
  v.viewportRows()

proc addLine*(v: var StreamingView; line: string) =
  inc v.total
  v.buf.add line

proc printBashScroll*(res: string, idx: int, maxLines = StreamMaxLines) =
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
