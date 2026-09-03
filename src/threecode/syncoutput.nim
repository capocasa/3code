## DEC 2026 synchronized-output gating.
##
## Historically every volatile repaint (keystroke redraw, footer tick,
## transcript commit) was wrapped in `CSI ? 2026 h` / `CSI ? 2026 l` so the
## terminal would apply the frame atomically and not tear. In practice the
## 2026-wrapped frame that walks the cursor up and erases only part of the
## screen (the volatile fat-prompt repaint / submit commit) corrupts real
## terminals — the "row lost on submit" bug — while rendering correctly in
## emulator models that implement 2026 as a pure atomic-batch (ttty, pyte).
## Upstream ghostty discussions #11002 / #12062 document the same paint
## pattern corrupting ghostty, and the user reproduces the row loss on real
## xterm as well. The corruption is in how real terminals reconcile a
## sync-buffered incremental cursor-positioned erase against scrollback, so
## the safe thing is to not wrap these frames at all: modern renderers are
## fast enough that an unsynced frame does not visibly tear, and every
## terminal applies an unsynced erase the same way.
##
## Sync output is therefore OFF by default everywhere. Set
## `THREECODE_FORCE_SYNC_OUTPUT=1` to re-enable it (tear-free frames on
## terminals whose 2026 handling is correct). `THREECODE_DISABLE_SYNC_OUTPUT`
## is accepted as a no-op alias for documentation muscle-memory.
##
## Leaf module (no imports from the renderer) so both `terminal.nim` and
## `minline.nim` can use it without an import cycle.

import std/os

const
  SyncBeginSeq* = "\x1b[?2026h"
  SyncEndSeq* = "\x1b[?2026l"

proc syncOutputEnabled*(): bool =
  ## False by default (see module doc). FORCE re-enables sync.
  if getEnv("THREECODE_FORCE_SYNC_OUTPUT") == "1": return true
  false

proc SyncBegin*(): string =
  if syncOutputEnabled(): SyncBeginSeq else: ""

proc SyncEnd*(): string =
  if syncOutputEnabled(): SyncEndSeq else: ""
