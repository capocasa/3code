## Regression test for the ticker cleanup over-erase.
##
## The spinner thread's exit cleanup (non-interactive / redirected stdout)
## used to walk up `1 + tickerRows` rows, computing `tickerRows` from the
## raw ticker width as if it wrapped. The ticker is clamped to one row on
## render, so this walked past the reserved gap row into committed
## scrollback and erased a real line — even with no ticker (1+1=2). The
## render path overwrites the ticker in place every frame, so cleanup owes
## no compensating removal: it must walk up exactly one row.

import std/[os, strutils, unittest]
import threecode/[fatprompt, terminal as termui]

suite "ticker cleanup":
  test "spinner cleanup walks up exactly one row (no ticker over-erase)":
    let outPath = getTempDir() / ("3code_ticker_out_" & $getCurrentProcessId())
    let saved = stdout
    let f = open(outPath, fmWrite)
    stdout = f
    try:
      startSpinner("test")
      sleep 200
      stopSpinner(clearLiveFooter = false)
      stdout.flushFile
    finally:
      stdout = saved
      close(f)

    let raw = readFile(outPath)
    removeFile(outPath)
    # The cleanup is the final erase-to-end (`\x1b[J`) the spinner emits as
    # it exits. It must be preceded by a cursor-up of exactly one row — the
    # gap/ticker row directly above the bar. Two or more reaches committed
    # scrollback.
    let cleanupIdx = raw.rfind("\x1b[J\n")
    check cleanupIdx >= 0
    let before = raw[0 ..< cleanupIdx]
    let upIdx = before.rfind("\x1b[")
    check upIdx >= 0
    let esc = before[upIdx ..< before.len]
    check "1A" in esc
    check "2A" notin esc
