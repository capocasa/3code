## Flail detector: windowed repetition + a no-progress signal catch agentic
## doom loops (identical-consecutive, A-B-A-B cycles, and re-tried no-op
## mutations), escalate twice, then abort the turn; genuinely novel calls
## reset the ladder.

import std/[strutils, unittest]
import threecode/turns

suite "flail detector":
  test "first call is fine":
    var det: FlailDetector
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvOk

  test "identical repeat escalates once, then twice, then aborts":
    var det: FlailDetector
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvOk
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvEscalate
    check det.escalations == 1
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvEscalate
    check det.escalations == 2
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvAbort
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvAbort

  test "novel call resets the ladder":
    var det: FlailDetector
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvOk
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvEscalate
    check det.observeCall("bash", "{\"command\":\"ls -la\"}") == fvOk
    check det.escalations == 0
    # Repeating the new call starts the ladder fresh.
    check det.observeCall("bash", "{\"command\":\"ls -la\"}") == fvEscalate
    check det.escalations == 1

  test "different tool name resets the ladder":
    var det: FlailDetector
    check det.observeCall("bash", "{}") == fvOk
    check det.observeCall("bash", "{}") == fvEscalate
    check det.observeCall("read", "{}") == fvOk
    check det.escalations == 0

  test "name alone does not collide: separator keeps args distinct":
    var det: FlailDetector
    # Without a separator, ("ba", "sh{}") and ("bash", "{}") would
    # fingerprint identically.
    check det.observeCall("ba", "sh{}") == fvOk
    check det.observeCall("bash", "{}") == fvOk

  test "alternating distinct calls never escalates (legitimate poll)":
    var det: FlailDetector
    # A-B-A-B of distinct, successful calls (re-run a test, re-check output)
    # is a deliberate poll, not a stuck loop: progress distinguishes it, so
    # it is never flagged no matter how long it alternates.
    for _ in 1 .. 8:
      check det.observeCall("bash", "{\"command\":\"ls\"}") == fvOk
      check det.observeCall("bash", "{\"command\":\"pwd\"}") == fvOk
    check det.escalations == 0

  test "identical calls separated by one different call are not consecutive":
    var det: FlailDetector
    # bash(X), read(Y), bash(X): the two bash(X) calls are spaced, not
    # consecutive, and neither signals no-progress, so no loop is flagged.
    check det.observeCall("bash", "X") == fvOk
    check det.observeCall("read", "Y") == fvOk
    check det.observeCall("bash", "X") == fvOk
    check det.escalations == 0

  test "re-trying a no-op mutation flags on first repeat":
    var det: FlailDetector
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    # The patch failed (made no change), arming the no-progress signal.
    det.noteResult("patch", madeChange = false)
    check det.lastNoProgress
    # Re-trying that same no-op patch is a strong stuck signal: escalate
    # immediately even though it's only the second occurrence.
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvEscalate
    check det.escalations == 1

  test "successful mutation does not arm the no-progress signal":
    var det: FlailDetector
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    det.noteResult("patch", madeChange = true)
    check not det.lastNoProgress
    # A spaced second occurrence of a successful patch is not flagged on the
    # no-progress path (it would need 2 prior sightings like any repeat).
    check det.observeCall("read", "Z") == fvOk
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk

  test "read-only tools never arm the no-progress signal":
    var det: FlailDetector
    check det.observeCall("read", "Z") == fvOk
    # Even a "failure" result on a read does not arm the signal.
    det.noteResult("read", madeChange = false)
    check not det.lastNoProgress

  test "window is bounded at FlailWindowSize":
    var det: FlailDetector
    for i in 0 ..< FlailWindowSize + 4:
      discard det.observeCall("bash", "{\"command\":\"cmd" & $i & "\"}")
    check det.window.len <= FlailWindowSize

  test "escalation messages: hint first, final warning second":
    let hint = flailEscalationMessage(1)
    let warn = flailEscalationMessage(2)
    check "Loop detected" in hint
    check "Final warning" in warn
    check "aborted" in warn
