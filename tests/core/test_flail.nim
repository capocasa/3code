## Flail detector: windowed repetition + per-fingerprint no-progress signals
## catch agentic doom loops (identical-consecutive, A-B-A-B cycles of failing
## calls, and re-tried no-op mutations), run three graduated recovery
## attempts, then abort the turn; genuinely novel calls reset the ladder.

import std/[json, sequtils, sets, strutils, unittest]
import threecode/turns

suite "flail detector":
  test "first call is fine":
    var det: FlailDetector
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvOk

  test "identical repeat escalates three times, then aborts":
    var det: FlailDetector
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvOk
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvEscalate
    check det.escalations == 1
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvEscalate
    check det.escalations == 2
    check det.observeCall("bash", "{\"command\":\"ls\"}") == fvEscalate
    check det.escalations == 3
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
    # fingerprint identically. Note the first args string is not JSON and
    # must fall back to raw comparison without crashing.
    check det.observeCall("ba", "sh{}") == fvOk
    check det.observeCall("bash", "{}") == fvOk

  test "key-order variants of one call fingerprint identically":
    var det: FlailDetector
    check det.observeCall("write", "{\"a\":1,\"b\":2}") == fvOk
    # Same call, keys reshuffled: canonicalization must see through it.
    check det.observeCall("write", "{\"b\":2,\"a\":1}") == fvEscalate
    check det.escalations == 1

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
    # consecutive, and neither has failed, so no loop is flagged.
    check det.observeCall("bash", "X") == fvOk
    check det.observeCall("read", "Y") == fvOk
    check det.observeCall("bash", "X") == fvOk
    check det.escalations == 0

  test "re-trying a no-op mutation flags on first repeat":
    var det: FlailDetector
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    # The patch failed (made no change), arming the no-progress signal.
    det.noteResult("patch", "{\"path\":\"a\"}", madeChange = false)
    check det.lastNoProgress
    # Re-trying that same no-op patch is a strong stuck signal: escalate
    # immediately even though it's only the second occurrence.
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvEscalate
    check det.escalations == 1

  test "successful mutation does not arm the no-progress signal":
    var det: FlailDetector
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    det.noteResult("patch", "{\"path\":\"a\"}", madeChange = true)
    check not det.lastNoProgress
    # Spaced repeats of a successful patch are not flagged on the
    # no-progress path at all.
    check det.observeCall("read", "Z") == fvOk
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    check det.observeCall("read", "Z") == fvOk
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    check det.escalations == 0

  test "read-only tools never arm the consecutive no-progress signal":
    var det: FlailDetector
    check det.observeCall("read", "Z") == fvOk
    # Even a "failure" result on a read does not arm the immediate signal.
    det.noteResult("read", "Z", madeChange = false)
    check not det.lastNoProgress

  test "spaced failing repeats flag on third sighting (A-B-A-B cycle)":
    var det: FlailDetector
    # The model ping-pongs between two calls, both failing. Signal 1 never
    # fires (nothing identical back-to-back), but the per-fingerprint
    # failure record flags the third sighting of each.
    check det.observeCall("bash", "X") == fvOk
    det.noteResult("bash", "X", madeChange = false)
    check det.observeCall("bash", "Y") == fvOk
    det.noteResult("bash", "Y", madeChange = false)
    check det.observeCall("bash", "X") == fvOk   # 2nd sighting: tolerated
    det.noteResult("bash", "X", madeChange = false)
    check det.observeCall("bash", "Y") == fvOk   # 2nd sighting: tolerated
    det.noteResult("bash", "Y", madeChange = false)
    check det.observeCall("bash", "X") == fvEscalate  # 3rd: stuck cycle
    check det.escalations == 1

  test "spaced failing read-only repeats also flag on third sighting":
    var det: FlailDetector
    # A failing grep re-tried in rotation is as stuck as a failing bash.
    check det.observeCall("read", "Z") == fvOk
    det.noteResult("read", "Z", madeChange = false)
    check det.observeCall("read", "W") == fvOk
    det.noteResult("read", "W", madeChange = false)
    check det.observeCall("read", "Z") == fvOk
    det.noteResult("read", "Z", madeChange = false)
    check det.observeCall("read", "W") == fvOk
    det.noteResult("read", "W", madeChange = false)
    check det.observeCall("read", "Z") == fvEscalate
    check det.escalations == 1

  test "success after failure clears the failing record":
    var det: FlailDetector
    check det.observeCall("bash", "X") == fvOk
    det.noteResult("bash", "X", madeChange = false)
    check det.observeCall("read", "Y") == fvOk
    det.noteResult("read", "Y", madeChange = true)
    check det.observeCall("bash", "X") == fvOk   # 2nd sighting of failure
    det.noteResult("bash", "X", madeChange = true)  # now it worked
    check det.observeCall("read", "Y") == fvOk
    check det.observeCall("bash", "X") == fvOk   # 3rd sighting, but record cleared
    check det.escalations == 0

  test "window is bounded at FlailWindowSize":
    var det: FlailDetector
    for i in 0 ..< FlailWindowSize + 4:
      discard det.observeCall("bash", "{\"command\":\"cmd" & $i & "\"}")
    check det.window.len <= FlailWindowSize

  test "escalation messages: hint, forced shape change, final warning":
    let hint = flailEscalationMessage(1)
    let shape = flailEscalationMessage(2)
    let warn = flailEscalationMessage(3)
    check "Loop detected" in hint
    check "prose" in shape
    check "structurally different" in shape
    check "Final warning" in warn
    check "aborted" in warn

  test "healthy varied work never trips the streak signal":
    # Mirrors the successful parts of the recorded mergepdf session:
    # short same-tool runs whose shared tokens change as work moves on
    # (build, then a help lookup, then tests), interleaved with writes
    # and patches. Nothing reaches FlailStreakMin with a shared token.
    var det: FlailDetector
    template bashCmd(c: string) =
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
    bashCmd "nim c -o:mergepdf mergepdf.nim"
    bashCmd "cd /tmp && mergepdf a.pdf b.pdf -o out.pdf && qpdf --check out.pdf"
    bashCmd "qpdf --help=page-selection | head -30"
    bashCmd "cd /tmp && mergepdf a.pdf b.pdf c.pdf -o out.pdf && qpdf --show-npages out.pdf"
    check det.observeCall("patch", "{\"path\":\"a\"}") == fvOk
    det.noteResult("patch", "{\"path\":\"a\"}", true)
    bashCmd "cd /tmp && rm -f out.pdf && mergepdf a.pdf -o out.pdf && qpdf --check out.pdf"
    check det.escalations == 0

  test "stuck streak of same-tool novel calls escalates, then aborts":
    # The recorded doom loop: 25 consecutive bash calls, every one a novel
    # fingerprint (cosmetic grep variations), all exit 0. Signals 1-3 stay
    # quiet; only the streak signal sees the run sharing one distinctive
    # token (execCmdEx).
    var det: FlailDetector
    # Verbatim tail of the recorded doom loop (20260903T214207.3log,
    # calls #52-#63): every call a novel fingerprint, all exit 0, all
    # grepping for execCmdEx.
    let greps = [
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/os.nim | head -3; grep -rn \"proc execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/os*.nim",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/std/*.nim 2>/dev/null | grep proc; grep -rn \"cmdline\\|execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/std/private/*.nim | grep proc | head",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/ --include='*.nim' | grep -v '##\\|html' | grep -v osproc.nim",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -n \"1[0-9][0-9][0-9]\"; awk 'NR>=1522 && NR<=1535' ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | head -2; grep -rn \"args: openArray[string]\\|seq[string]\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/os.nim; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/std/*.nim | grep -v '##'",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/ --include='*.nim' -l; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/system/*.nim 2>/dev/null | head -3",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##'; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | wc -l",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '  ##'; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -c '##'",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' ; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' | wc -l",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' ; echo ---; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' | wc -l; echo ---",
      "grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' ; echo ---; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' | wc -l; echo ---; grep -rn \"execCmdEx\" ~/.choosenim/toolchains/nim-2.2.10/lib/pure/osproc.nim | grep -v '##' | tail -2"]
    var verdicts: seq[FlailVerdict]
    for g in greps:
      verdicts.add det.observeCall("bash", "{\"command\":" & escapeJson(g) & "}")
      det.noteResult("bash", "{\"command\":" & escapeJson(g) & "}", true)
    # First FlailStreakMin-1 calls pass; the run then climbs the ladder.
    for v in verdicts[0 ..< FlailStreakMin - 1]:
      check v == fvOk
    check fvEscalate in verdicts
    check fvAbort in verdicts[verdicts.len - 3 .. ^1]

  test "a genuinely different call breaks the streak":
    var det: FlailDetector
    for i in 1 ..< FlailStreakMin:
      let c = "sed -n '" & $i & ",30p' src/module" & $i & ".nim; wc -l src/module" & $i & ".nim"
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
    # A call sharing no distinctive token with the rest of the ring means
    # the full-ring intersection is empty: the signal is disarmed and 8
    # more on-theme calls would be needed to re-arm it.
    let other = "nim c -o:tool tools/thing.nim"
    check det.observeCall("bash", "{\"command\":" & escapeJson(other) & "}") == fvOk
    check "src/module#.nim" notin det.streakTokens[^1]
    check "o:tool" in det.streakTokens[^1]
