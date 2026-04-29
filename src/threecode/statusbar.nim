## Status bar: two rows reserved at the bottom of the terminal.
##
## DORMANT as of 0.2.7. `enable()` is no longer called from `welcome`,
## so `isActive()` is permanently false and every call site falls
## through to the inline path. Apple Terminal handles DECSTBM +
## `\x1b[s`/`\x1b[u` save-restore-cursor differently enough that
## streamed content landed on the bar row and got clobbered by the
## next bar repaint, leaving the LLM reply invisible (token receipts
## still rendered, since they fire after the spinner/bar lifecycle
## ends). Linux terminals (gnome-terminal, kitty, alacritty, iTerm2)
## handle the combo cleanly. Kept around in case we want to revisit
## with a more portable approach (`\e7`/`\e8`, or gating on
## `TERM_PROGRAM != "Apple_Terminal"`).
##
##   row H-1  token bar  (always visible; while reasoning is streaming
##                        the spinner thread overlays the bar with the
##                        reasoning ticker, then snaps back to token
##                        slots once content starts)
##   row H    prompt     (always visible; bright when input is active)
##
## Content scrolls in rows 1..H-2 via DECSTBM (`\x1b[1;Nr`). Bar/prompt
## writes save the cursor (`\x1b[s`), absolute-position to the target
## row, write, then restore (`\x1b[u`), so they never disturb the
## scroll-region cursor.
##
## The reasoning ticker is routed through the same bar slot rather
## than reserving a third row — that way the bar's space is the only
## status overhead, and the ticker "appears on top of" the token slots
## for the duration of thinking, falling back to slots when reasoning
## ends. Restoring the underlying token slots is automatic: the next
## spinner frame after `setSpinTicker("")` writes them back.
##
## Disabled gracefully when the terminal is shorter than 5 rows or when
## stdout isn't a TTY (the typical pipe-to-cat case): writes fall through
## inline. Detected once at `enable()`; resize is not handled (yet).

import std/[exitprocs, terminal]

var
  enabled* = false
  termH = 0
  barRow = 0
  promptRow = 0

proc isActive*(): bool = enabled
proc tHeight*(): int = termH
proc rBar*(): int = barRow
proc rPrompt*(): int = promptRow

proc clearRow(row: int) =
  stdout.write "\x1b[" & $row & ";1H\x1b[2K"

proc disable*() {.noconv.} =
  if not enabled: return
  # Reset scroll region, wipe reserved rows, leave cursor at the very
  # bottom so the shell prompt lands cleanly when the program exits.
  # Also re-show the cursor in case we hid it for a streaming turn.
  try:
    stdout.write "\x1b[r"
    clearRow(barRow)
    clearRow(promptRow)
    stdout.write "\x1b[?25h"
    stdout.write "\x1b[" & $termH & ";1H"
    stdout.flushFile
  except IOError: discard
  enabled = false

proc enable*() =
  if enabled: return
  if not isatty(stdout): return
  termH = try: terminalHeight() except CatchableError: 0
  if termH < 5: return
  barRow = termH - 1
  promptRow = termH
  # Reserve the bottom 2 rows: scroll happens in rows 1..H-2. The
  # thinking ticker no longer has its own row — it overlays the bar
  # row while reasoning streams, then the next spinner frame paints
  # the token slots back over it.
  stdout.write "\x1b[1;" & $(termH - 2) & "r"
  # Wipe whatever the shell left on the bottom two rows so the prior
  # prompt or output doesn't bleed through. Paint an empty prompt
  # row so the input area is visible before the first `readInput`.
  clearRow(barRow)
  stdout.write "\x1b[" & $promptRow & ";1H\x1b[2K\x1b[37m❯ \x1b[0m"
  # DECSTBM moves the cursor to (1,1); push it to the bottom of the
  # scroll region so the first write feels like "appending" rather than
  # filling from the top.
  stdout.write "\x1b[" & $(termH - 2) & ";1H"
  stdout.flushFile
  enabled = true
  addExitProc(disable)

proc atRow(row: int, payload: string) =
  ## Atomic: save cursor, jump to `row`, clear it, write `payload`,
  ## restore cursor. Caller's `payload` carries any ANSI styling and
  ## must NOT contain a trailing `\n` (the slot is one line).
  if not enabled:
    stdout.write payload
    stdout.flushFile
    return
  stdout.write "\x1b[s"
  clearRow(row)
  stdout.write payload
  stdout.write "\x1b[u"
  stdout.flushFile

proc writeAtBar*(payload: string) =
  ## Token bar row (H-1).
  if not enabled:
    stdout.write payload
    stdout.flushFile
    return
  atRow(barRow, payload)

proc clearBar*() =
  if not enabled: return
  stdout.write "\x1b[s"
  clearRow(barRow)
  stdout.write "\x1b[u"
  stdout.flushFile

proc writeAtPrompt*(payload: string) =
  ## Prompt row (H). The full row content (prefix + any input echo)
  ## is the caller's responsibility; this just paints the row.
  if not enabled:
    stdout.write payload
    stdout.flushFile
    return
  atRow(promptRow, payload)

proc moveCursorToPrompt*(col: int = 1) =
  ## Park the cursor on the prompt row at `col` (1-based). Used by
  ## the input path before handing off to minline so keystrokes echo
  ## on row H instead of inside the scroll region. After the line is
  ## submitted the caller must reposition the cursor back into the
  ## scroll region (use `parkInScroll`).
  if not enabled: return
  stdout.write "\x1b[" & $promptRow & ";" & $col & "H"
  stdout.flushFile

proc parkInScroll*() =
  ## Place the cursor at the bottom of the scroll region so the next
  ## write appends naturally.
  if not enabled: return
  stdout.write "\x1b[" & $(termH - 2) & ";1H"
  stdout.flushFile

proc hideCursor*() =
  ## DECTCEM off: hide the terminal cursor. Used while the model is
  ## thinking / streaming so the steady-block cursor doesn't blink in
  ## the middle of the scroll region (the cursor parks there for
  ## content writes, and the bar/thinking writes save/restore back to
  ## it). Paired with `showCursor` at the next input boundary.
  if not enabled: return
  stdout.write "\x1b[?25l"
  stdout.flushFile

proc showCursor*() =
  if not enabled: return
  stdout.write "\x1b[?25h"
  stdout.flushFile
