## Terminal tab title: the `3` brand plus a live activity glyph.
##
## A terminal re-renders its tab on every title change, so writing OSC 0
## escapes from the GUI tick animates the tab without touching what the
## program prints on the screen. The title is the brand, the glyph, and the
## project label (the cwd tail): the two leading cells are what stay visible
## when a tab strip runs out of room, which is the whole point: the `3`
## says "this tab is a 3code session" and the glyph says whether it is still
## working. While a turn runs the glyph is the same braille/hourglass the
## footer spinner shows; when the turn ends it settles to ✓ (or ✗ when the
## user cancelled).
##
## Writes ride the engine's synchronized write, so an OSC 0 can never tear
## against a footer frame, and they are dropped when output is disabled
## (headless library sessions) or stdout is not a terminal (piped oneshot
## runs must not leak escape bytes into the captured output).
##
## Idle (fresh session, no turn yet) is brand + label with no glyph: no
## outcome mark is claimed that never happened.

import std/os

import types
import engine as termengine

when defined(posix):
  import std/posix
else:
  proc c_isatty(fd: cint): cint {.header: "<io.h>", importc: "_isatty".}

const Brand = "3"
  ## What the tab calls a 3code session, whatever it is doing.

var projectLabel: string
  ## The label after brand+glyph: the directory the session runs in.
  ## Written once at startup, before the GUI thread exists, and read-only
  ## afterwards.

proc isATty(): bool =
  when defined(posix):
    isatty(1.cint) == 1
  else:
    c_isatty(1.cint) != 0

proc tabTitle(glyph, label: string): string =
  ## Brand, glyph, label. The label is decoration for wide tabs; the two
  ## leading cells carry the meaning.
  if label == "":
    Brand & " " & glyph
  else:
    Brand & " " & glyph & " " & label

proc idleTabTitle(label: string): string =
  ## The tab title while nothing is running and nothing has finished:
  ## just the brand, so no outcome mark is claimed that never happened.
  if label == "": Brand else: Brand & " " & label

proc writeTabTitle(title: string) =
  if not tabTitleEnabled or not isATty(): return
  termengine.syncWrite("\x1b]0;" & title & "\x07")

proc setTabTitleLabel*(dir: string) =
  projectLabel = dir.extractFilename

proc paintTabTitleIdle*() =
  writeTabTitle(idleTabTitle(projectLabel))

proc paintTabTitleWorking*(glyph: string) {.gcsafe.} =
  ## The tab title while a turn runs: brand, the live spinner glyph, label.
  ## Called from the GUI tick, which owns the glyph the footer shows.
  {.cast(gcsafe).}:
    writeTabTitle(tabTitle(glyph, projectLabel))

proc settleTabTitle*(ok: bool) =
  ## The tab title once the turn has stopped. The spinner is replaced by
  ## what it was spinning for; the brand stays.
  writeTabTitle(tabTitle(if ok: "✓" else: "✗", projectLabel))
