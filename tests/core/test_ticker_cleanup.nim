## Regression test for the ticker cleanup over-erase.
##
## The spinner thread's exit cleanup (non-interactive / redirected stdout)
## used to walk up `1 + tickerRows` rows, computing `tickerRows` from the
## raw ticker width as if it wrapped. The ticker is clamped to one row on
## render, so this walked past the reserved gap row into committed
## scrollback and erased a real line — even with no ticker (1+1=2). The
## render path overwrites the ticker in place every frame, so cleanup owes
## no compensating removal: it must walk up exactly one row.

import std/[os, strutils, times, unittest]
import threecode/[fatprompt, terminal as termui]
import ttty/grid

proc waitForGuiPaint(timeoutMs = 5000): bool =
  ## Block until the gui thread has painted at least one frame (see
  ## test_spinner_join.nim; a fixed sleep here flakes under parallel load).
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if guiPaintCount() > 0: return true
    sleep 1
  false

suite "ticker cleanup":
  # This test captures the spinner's stdout by redirecting the global
  # `stdout` File. On Windows MinGW `stdout` is a macro
  # (`(&__iob_func()[1])`), so any `var File` operation on it (reopen,
  # open, or `stdout = f`) fails to compile with
  # `error: lvalue required as ...`. OS-level fd redirection (dup2 /
  # SetStdHandle) does not capture the C runtime's buffered FILE* on
  # Windows either, so the only portable option is to gate the capture
  # test. The regression it guards (cleanup cursor-up count) is
  # platform-independent, so Linux/macOS coverage is sufficient. See
  # docs/windows-testing.md.
  when not defined(windows):
    test "spinner cleanup walks up exactly one row (no ticker over-erase)":
      let outPath = getTempDir() / ("3code_ticker_out_" & $getCurrentProcessId())
      let savedFd = getOsFileHandle(stdout)
      doAssert reopen(stdout, outPath, fmWrite)
      try:
        startSpinner("test")
        doAssert waitForGuiPaint()
        stopSpinner(clearLiveFooter = false)
        stdout.flushFile
      finally:
        # Restore stdout to its original OS file handle. The earlier form
        # (`stdout = f`) reassigns the File variable, which on Windows/MinGW
        # expands to a non-lvalue C macro and fails to compile, so the
        # whole test (and the Windows CI job) could not build at all.
        discard open(stdout, savedFd, fmWrite)

      let raw = readFile(outPath)
      removeFile(outPath)
      # Assert the visible end state on a rendered grid, not the raw byte
      # stream: seed one committed scrollback line above the cursor (what a
      # real screen looks like when the spinner runs), replay the captured
      # spinner session, and verify cleanup leaves the committed line
      # intact and no spinner/ticker remnant behind. The over-erase
      # regression walked one row too far up and blanked the committed
      # line; a surviving line plus a clean grid is the effect-level
      # invariant.
      let g = newGrid()
      g.feed "committed scrollback line\r\n"
      g.feed raw
      var committedSeen = false
      for r in 0 ..< g.rows.len:
        let text = g.rowText(r)
        if "committed scrollback line" in text:
          committedSeen = true
        check "test" notin text
      check committedSeen
