## Terminal cell width per rune, for cursor math and wrapping.
##
## Combining marks (general categories ``Mn`` / ``Me``) occupy no cell.
## East-Asian Wide / Fullwidth runes occupy two cells. Everything else
## (Ambiguous treated as narrow, Half, Narrow, Neutral) is one cell.
import std/unicode
import unicodedb/widths
import unicodedb/properties

proc runeCellWidth*(r: Rune): int {.inline.} =
  let cat = unicodeCategory(r)
  if cat == ctgMn or cat == ctgMe:
    return 0
  let w = unicodeWidth(r)
  if w == uwdtWide or w == uwdtFull:
    2
  else:
    1
