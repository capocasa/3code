## DEC 2026 synchronized-output gating.
##
## Every volatile repaint (keystroke redraw, footer tick, transcript commit)
## is wrapped in `CSI ? 2026 h` / `CSI ? 2026 l` so the terminal applies the
## frame atomically and does not tear. Ghostty mishandles 2026-wrapped frames
## that move the cursor and erase only part of the screen (walk-up + ED/EL to
## the bottom rows): its sync buffer applies the incremental cursor-positioned
## update against stale row state and progressively corrupts scrollback —
## the "row lost on submit" bug. Upstream: ghostty discussions #11002 and
## #12062, both reproducing with Claude Code's identical paint pattern; both
## confirm "sync OFF + incremental updates" renders correctly while "sync ON
## + incremental updates" garbles. Ghostty's Metal renderer is fast enough
## that the unsynced frame does not tear, so on ghostty the frame bytes are
## emitted bare.
##
## Leaf module (no imports from the renderer) so both `terminal.nim` and
## `minline.nim` can use it without an import cycle.

import std/[os, strutils]

const
  SyncBeginSeq* = "\x1b[?2026h"
  SyncEndSeq* = "\x1b[?2026l"

proc syncOutputEnabled*(): bool =
  ## False on ghostty (see module doc), true elsewhere. Overridable for
  ## testing: FORCE forces sync on, DISABLE forces it off.
  if getEnv("THREECODE_FORCE_SYNC_OUTPUT") == "1": return true
  if getEnv("THREECODE_DISABLE_SYNC_OUTPUT") == "1": return false
  if getEnv("TERM_PROGRAM").toLowerAscii == "ghostty": return false
  if "ghostty" in getEnv("TERM").toLowerAscii: return false
  true

proc SyncBegin*(): string =
  if syncOutputEnabled(): SyncBeginSeq else: ""

proc SyncEnd*(): string =
  if syncOutputEnabled(): SyncEndSeq else: ""
