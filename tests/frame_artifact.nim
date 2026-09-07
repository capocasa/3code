## Versioned, lossless frame interchange shared by recorder, comparator and viewer.
import std/[json, jsonutils, strutils, strformat, unicode]
import ttty/grid

proc `==`*(a, b: SgrAttr): bool = uint16(a) == uint16(b)

type VisualFrame* = object
  id*: string
  ms*, width*, height*: int
  cells*: seq[seq[Cell]]
  cursorRow*, cursorCol*: int
  cursorHidden*, pendingWrap*: bool

proc frameJson*(f: VisualFrame): JsonNode = %*{
  "format": "3code-frame-v1", "frame": toJson(f)}

proc parseVisualFrame*(line: string): VisualFrame =
  let node = parseJson(line)
  if node["format"].getStr != "3code-frame-v1":
    raise newException(ValueError, "unsupported frame format")
  jsonTo(node["frame"], VisualFrame)

proc cellText(cell: Cell): string =
  if cell.text.len > 0: cell.text else: $cell.rune

proc displayRows*(f: VisualFrame; cursor = true): seq[string] =
  for r, row in f.cells:
    var text = ""
    for c, cell in row:
      if cell.width == 0: continue
      if cursor and not f.cursorHidden and r == f.cursorRow and
          f.cursorCol >= c and f.cursorCol < c + cell.width:
        text.add "█" & repeat(" ", cell.width - 1)
      else:
        text.add cell.cellText
    if cursor and not f.cursorHidden and r == f.cursorRow and f.cursorCol >= row.len:
      text.add repeat(" ", f.cursorCol - row.len) & "█"
    result.add text

proc ansiRows*(f: VisualFrame): seq[string] =
  ## Emit modeled SGR state. ttty currently discards truecolor components.
  for r, row in f.cells:
    var text = ""
    for c, cell in row:
      if cell.width == 0: continue
      var sgr = @["0"]
      for bit, code in [1, 2, 3, 4, 5, 7, 9]:
        if cell.attrs.hasAttr(bit): sgr.add $code
      for bg in [false, true]:
        let color = if bg: cell.bgColor else: cell.fgColor
        let idx = if bg: cell.bgColorIdx else: cell.fgColorIdx
        let base = if bg: 40 else: 30
        case color
        of colDefault: discard
        of colBlack .. colWhite: sgr.add $(base + ord(color) - ord(colBlack))
        of colBrightBlack .. colBrightWhite: sgr.add $(base + 60 + ord(color) - ord(colBrightBlack))
        of col256: sgr.add $(base + 8) & ";5;" & $idx
        of colRgb: discard
      text.add "\e[" & sgr.join(";") & "m" & cell.cellText
    text.add "\e[0m"
    if not f.cursorHidden and r == f.cursorRow:
      text.add "\e[" & $(f.cursorCol + 1) & "G\e[7m█\e[0m"
    result.add text

proc redactCells*(f: var VisualFrame; row, first, count: int) =
  ## Explicit physical-cell mask: retains widths, attributes and row boundaries.
  doAssert row >= 0 and row < f.cells.len
  doAssert first >= 0 and count >= 0 and first + count <= f.cells[row].len
  for c in first ..< first + count:
    if f.cells[row][c].width > 0:
      f.cells[row][c].rune = Rune('x')
      f.cells[row][c].text = repeat("x", f.cells[row][c].width)

proc firstDifference*(expected, actual: VisualFrame): string =
  if expected.id != actual.id: return "checkpoint identity differs: " & expected.id & " / " & actual.id
  if (expected.width, expected.height) != (actual.width, actual.height):
    return "frame geometry differs"
  if (expected.cursorRow, expected.cursorCol, expected.cursorHidden, expected.pendingWrap) !=
      (actual.cursorRow, actual.cursorCol, actual.cursorHidden, actual.pendingWrap):
    return &"cursor differs (zero-based): expected ({expected.cursorRow},{expected.cursorCol}) hidden={expected.cursorHidden} wrap={expected.pendingWrap}; actual ({actual.cursorRow},{actual.cursorCol}) hidden={actual.cursorHidden} wrap={actual.pendingWrap}"
  if expected.cells.len != actual.cells.len: return "row count differs"
  for r in 0 ..< expected.cells.len:
    if expected.cells[r].len != actual.cells[r].len: return &"row {r} cell count differs"
    for c in 0 ..< expected.cells[r].len:
      if expected.cells[r][c] != actual.cells[r][c]:
        result = &"first cell difference (zero-based) row={r} col={c}\n"
        let er = expected.displayRows(false)
        let ar = actual.displayRows(false)
        for i in max(0, r - 1) .. min(er.high, r + 1):
          result.add &"expected {i}: {er[i]}\nactual   {i}: {ar[i]}\n"
        result.add "expected cell: " & $toJson(expected.cells[r][c]) & "\nactual cell: " & $toJson(actual.cells[r][c])
        return

proc compareArtifacts*(expected, actual: string): string =
  let e = strutils.strip(expected).splitLines
  let a = strutils.strip(actual).splitLines
  for i in 0 ..< min(e.len, a.len):
    let diff = firstDifference(parseVisualFrame(e[i]), parseVisualFrame(a[i]))
    if diff.len > 0: return &"frame {i}: {diff}"
  if e.len != a.len: return &"frame count differs: expected {e.len}, actual {a.len}"
