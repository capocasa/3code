## Replay a captured terminal byte stream through a ttty Grid at the
## capture's real width/height (a scratch replay at a hardcoded 80 invents
## or hides wrap/scroll geometry bugs) and print the visible rows as
## `NN |text|` lines. Used by the real-emulator repro drivers to build the
## model side of the screenshot-vs-model differential.
##
##   replay_ttty <bytes-file> <width> <height>
import std/[os, strutils]
import ttty/grid

proc main() =
  if paramCount() < 3:
    stderr.writeLine "usage: replay_ttty <bytes-file> <width> <height>"
    quit 2
  let bytes = readFile(paramStr(1))
  let width = parseInt(paramStr(2))
  let height = parseInt(paramStr(3))
  var g = newGrid()
  g.resize(width, height)
  g.feed(bytes)
  let first = max(0, g.rows.len - height)
  for r in first ..< g.rows.len:
    echo align($r, 2), " |", g.rowText(r), "|"

main()
