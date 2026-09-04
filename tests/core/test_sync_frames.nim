## Regression guard for the foot/ghostty line-math bugs: the engine's
## transcript-commit paths must never emit a nested DEC 2026
## synchronized-output frame. `appendTranscript*` runs inside an outer
## `SyncBegin`; a `redrawBytes()` with the default `synchronized=true`
## produced `?2026h ... ?2026l ... ?2026l` — a doubled sync-end that
## 2026-honoring terminals batch/drop differently than the row model
## expects (erased scrollback line / prompt jump on submit). xterm
## ignores 2026, which is why it never showed there.

import std/[os, strutils, unittest]
import threecode/engine
import threecode/minline
import threecode/fatprompt/rendering

# Sync output is off by default now (see syncoutput.nim); the guard only
# means something with 2026 emission live, so force it on for this suite.
putEnv("THREECODE_FORCE_SYNC_OUTPUT", "1")

proc count(s, sub: string): int =
  var i = 0
  while true:
    let j = s.find(sub, i)
    if j < 0: return result
    inc result
    i = j + sub.len

proc captureStdout(body: proc()): string =
  ## Swap the `stdout` var for a temp file around the call (same pattern
  ## as test_display.nim).
  let outPath = getTempDir() / "threecode_sync_guard_" & $getCurrentProcessId() & ".txt"
  let saved = stdout
  let f = open(outPath, fmWrite)
  stdout = f
  try:
    body()
    stdout.flushFile()
  finally:
    stdout = saved
    close(f)
  result = readFile(outPath)
  removeFile(outPath)

suite "engine transcript commits: balanced DEC 2026 frames":
  test "liveAnchored commit emits exactly one sync frame":
    var e: TerminalEngine
    var ed = initEditor(historyFile = "")
    ed.width = 80
    ed.line.text = "hi"
    ed.line.position = 2
    let bytes = captureStdout(proc() =
      e.appendTranscript("item", liveAnchored = true, inputRunning = true,
        editor = addr ed, oldFooter = noFooterFrame(),
        newFooter = noFooterFrame(), restoreEditor = true))
    check bytes.count("\x1b[?2026h") == 1
    check bytes.count("\x1b[?2026l") == 1

  test "floating commit emits exactly one sync frame":
    var e: TerminalEngine
    var ed = initEditor(historyFile = "")
    ed.width = 80
    ed.line.text = "hi"
    ed.line.position = 2
    let bytes = captureStdout(proc() =
      e.appendTranscript("item", liveAnchored = false, inputRunning = true,
        editor = addr ed, oldFooter = noFooterFrame(),
        newFooter = noFooterFrame(), restoreEditor = true))
    check bytes.count("\x1b[?2026h") == 1
    check bytes.count("\x1b[?2026l") == 1

suite "engine footer geometry: prompt-only gap":
  test "ffNone rowsAboveEditor is the reserved gap row":
    check noFooterFrame().rowsAboveEditor() == 1
    check noFooterFrame().footerFrameBytes().len == 0

  test "renderFooter registers gap-only painted rows without an editor":
    var e: TerminalEngine
    discard captureStdout(proc() =
      e.renderFooter(noFooterFrame(), inputRunning = false, editor = nil))
    check e.paintedFooterRowCount() == 1
