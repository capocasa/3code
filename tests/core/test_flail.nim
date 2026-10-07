## Flail detector: windowed repetition + per-fingerprint no-progress signals
## catch agentic doom loops (identical-consecutive, A-B-A-B cycles of failing
## calls, and re-tried no-op mutations), run three graduated recovery
## attempts, then abort the turn; genuinely novel calls reset the ladder.

import std/[json, sequtils, sets, strutils, unittest]
import threecode/turns

const doomGreps = [
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
    # No fake role prefix: the tool-result slot already marks the text as
    # harness-authored, and the same bytes render under the magenta `»`.
    for m in [hint, shape, warn]:
      check "SYSTEM" notin m
    # Recovery steps must push the model back to work, never to the user;
    # these messages persist in context and GLM generalizes any "tell the
    # user" into a habit of asking for guidance instead of acting.
    for m in [hint, shape]:
      check "tell the user" notin m
      check "blocking you" notin m
    check "tell the user what is blocking you" in warn

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

  test "varied probes sharing one keyword never trip the streak signal":
    # The false-positive class from 20260909T213716-2ICaadgQ: a long run of
    # novel fingerprints that all grep for one symbol (execCmdEx, verbatim
    # from the recorded mergepdf doom loop 20260903T214207.3log). Sharing a
    # keyword is not mostly-same: varied probes must stay quiet no matter
    # how long the run. This deliberately gives up detection of the pure
    # keyword-sharing doom loop; the near-duplicate cluster test below
    # covers its tight-repeat endgame.
    var det: FlailDetector
    for i in 0 ..< FlailStreakArm + FlailStreakMin + 3:
      let g = doomGreps[i mod 8]
      check det.observeCall("bash", "{\"command\":" & escapeJson(g) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(g) & "}", true)
    check det.escalations == 0

  test "stuck streak of near-duplicate calls escalates, then aborts":
    # The tight-repeat endgame of the recorded doom loop: calls so similar
    # (cosmetic spacing/echo variants of one grep) that the ring holds a
    # near-duplicate cluster. Signals 1-3 stay quiet (novel fingerprints,
    # all exit 0); the streak signal flags and the ladder runs to abort.
    var det: FlailDetector
    let greps = doomGreps[8 ..^ 1]
    # Cycle the near-duplicates so the run passes the arm gate and fills
    # the ring; cycling distinct fingerprints keeps signals 1-3 quiet so
    # only the streak signal can fire.
    var verdicts: seq[FlailVerdict]
    for i in 0 ..< FlailStreakArm + FlailStreakMin + 3:
      let g = greps[i mod greps.len]
      verdicts.add det.observeCall("bash", "{\"command\":" & escapeJson(g) & "}")
      det.noteResult("bash", "{\"command\":" & escapeJson(g) & "}", true)
    # The run is quiet until the ring fills: arming takes FlailStreakArm
    # calls (index FlailStreakArm-1), a full ring FlailStreakMin more.
    const firstFire = FlailStreakArm + FlailStreakMin - 2
    for v in verdicts[0 ..< firstFire]:
      check v == fvOk
    check verdicts[firstFire] == fvEscalate
    check fvAbort in verdicts[verdicts.len - 3 .. ^1]

  test "a genuinely different call purges the streak ring":
    var det: FlailDetector
    for i in 1 .. FlailStreakArm:
      let c = "sed -n '" & $i & ",30p' src/module" & $i & ".nim; wc -l src/module" & $i & ".nim"
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
    # The odd call shares no distinctive token with the ring's consensus
    # (a compile, not a file read), so the subject changed: the ring
    # empties instead of absorbing it. The evidence restarts, it is not
    # disarmed - an uninterrupted near-duplicate run refills the ring from
    # the next call and still fires, so a doom loop that deviates once
    # only delays the flag.
    let other = "nim c -o:tool tools/thing.nim"
    check det.observeCall("bash", "{\"command\":" & escapeJson(other) & "}") == fvOk
    check det.streakTokens.len == 0
    let variants = [
      "rg -n \"deadline\" src/engine.nim | head -20",
      "rg -n \"deadline\" src/engine.nim | head -40",
      "rg -n \"deadline\" src/engine.nim | tail -20"]
    for i in 1 .. FlailStreakMin:
      let v = det.observeCall("bash", "{\"command\":" & escapeJson(variants[(i - 1) mod 3]) & "}")
      if i < FlailStreakMin:
        check v == fvOk
      else:
        check v == fvEscalate

  test "short burst of same-prefix command variants does not flag":
    # Regression from 20260905T000324.3log: while debugging an image
    # pipeline the model ran 11 novel bash calls that all share the fixed
    # prefix tokens (magick, -colorspace Gray -resize 60x -dither
    # FloydSteinberg -remap pattern:gray50) and vary only the tail. The
    # streak signal flagged call #9; healthy iterative work, not a loop.
    # The arm gate keeps runs shorter than FlailStreakArm from ever
    # filling the ring.
    var det: FlailDetector
    let variants = [
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | sed -n '2p'",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | sed -n '2p;300p'",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | sed -n '2p;300p;900p'",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 && $2+0<100 {c++} END {print c, \"dark of\", NR-1}'",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x txt:/dev/stdout 2>/dev/null | sed -n '2p;900p'; echo ---; magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | sed -n '2p;900p'",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 {print $3}' | sort | uniq -c",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 {printf \"%s\", ($3 ~ /black/) ? \"#\" : \" \"}' | fold -w 60",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 {printf \"%s\", ($3 ~ /black/) ? \"#\" : \" \"}' | head -c 200 | od -c | head",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 {printf \"%s\", ($3 ~ /black/) ? \"#\" : \" \"}' > /tmp/bst-raw; wc -c /tmp/bst-raw; head -c 120 /tmp/bst-raw | od -c | head -8",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 {printf \"%s\", ($3 ~ /black/) ? \"#\" : \" \"}' | head -c 200 | od -c | head -4",
      "magick /tmp/bst-test.png -colorspace Gray -resize 60x -dither FloydSteinberg -remap pattern:gray50 txt:/dev/stdout 2>/dev/null | awk -F'[,:]' 'NR>1 {printf \"%s\", ($3 ~ /black/) ? \"#\" : \" \"}' | head -c 100 | od -c | head -4; echo done"]
    for v in variants:
      check det.observeCall("bash", "{\"command\":" & escapeJson(v) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(v) & "}", true)
    check det.escalations == 0
    check det.streakTokens.len == 0

  test "sequential file inspection never trips the streak signal":
    # Regression, verbatim from the 20260921 stefani session (the harness's
    # own turn): reading successive sections of one transcript with sed.
    # Digit normalization turned every range token into the same
    # `##,###p` filler, so four *different* sed calls over one file read
    # as a tight near-duplicate cluster and the guard warned, then
    # aborted the turn mid-investigation. Addresses are not intent.
    var det: FlailDetector
    let probes = [
      "export PATH=/opt/osxcross/bin:$PATH && cd /tmp/3code-osx-bundle && cp ~/p/3code/osx/3code-macos-x86_64 ./3code && x86_64-apple-darwin24.5-otool -L libssl.3.dylib | head -4 && ls -la",
      "scp -q /tmp/3code-osx-bundle.tar.gz /tmp/drive.py carlo@stefani:/tmp/ && timeout 30 ssh -o BatchMode=yes carlo@stefani 'rm -rf ~/3code-bundle && mkdir ~/3code-bundle && cd ~/3code-bundle && tar xzf /tmp/3code-osx-bundle.tar.gz'",
      "timeout 20 ssh -o BatchMode=yes carlo@stefani 'cd ~/3code-osx-test && ~/3code-bundle/3code --help 2>&1 | head -30'",
      "timeout 90 ssh -o BatchMode=yes carlo@stefani 'cd ~/3code-osx-test && time ~/3code-bundle/3code \"reply with exactly: TLS-OK\"' 2>&1 | tail -8",
      "timeout 20 ssh -o BatchMode=yes carlo@stefani 'cd ~/3code-osx-test && rm -f tf.nim; nohup python3 /tmp/drive.py /tmp/3code-drive.log ~/3code-osx-test /Users/carlo/3code-bundle/3code > /tmp/drive.out 2>&1 & sleep 1; pgrep -fl drive.py'",
      "sleep 90; timeout 25 ssh -o BatchMode=yes carlo@stefani 'ls -la ~/3code-osx-test/ 2>/dev/null; wc -c /tmp/3code-drive.log; tail -c 400 /tmp/3code-drive.log | cat -v | tail -6'",
      "sleep 120; timeout 25 ssh -o BatchMode=yes carlo@stefani 'pgrep -fl drive.py >/dev/null && echo DRIVER-RUNNING || echo DRIVER-DONE; ls -la ~/3code-osx-test/'",
      "for i in 1 2 3 4 5 6 7 8; do sleep 60; s=$(timeout 15 ssh -o BatchMode=yes carlo@stefani 'pgrep -fl drive.py >/dev/null && echo RUNNING || echo DONE'); echo \"$i: $s\"; [ \"$s\" = DONE ] && break; done",
      "timeout 30 ssh -o BatchMode=yes carlo@stefani 'cat ~/3code-osx-test/tf.nim; echo ===; ls -t ~/.config/3code/sessions | head -3'",
      "timeout 30 scp -q carlo@stefani:/tmp/3code-drive.log /tmp/3code-drive.log && ls -la /tmp/3code-drive.log",
      "timeout 30 ssh -o BatchMode=yes carlo@stefani 'printf \"the quick brown fox jumps over the lazy dog\\n\" | /tmp/tf --width=20; echo ---; printf \"supercalifragilisticexpialidocious-and-more-letters-past-thirty\\n\" | /tmp/tf --width=10'",
      "timeout 30 ssh -o BatchMode=yes carlo@stefani 'ls -t ~/.config/3code/sessions/*.3log | head -2'",
      "timeout 30 scp -q carlo@stefani:~/.config/3code/sessions/20260921T203146.3log /tmp/session.3log && wc -l /tmp/session.3log && head -40 /tmp/session.3log",
      "sed -n '40,140p' /tmp/session.3log",
      "grep -n \"denied\\|deny\\|sandbox\\|seatbelt\\|error\\|fail\\|refus\\|timeout\\|panic\\|Trace\" /tmp/session.3log | head -20; echo ===TOOLCOUNT; grep -c \"^tool_use\" /tmp/session.3log",
      "sed -n '140,260p' /tmp/session.3log",
      "sed -n '260,400p' /tmp/session.3log",
      "sed -n '400,520p' /tmp/session.3log",
      "sed -n '780,994p' /tmp/session.3log | grep -v \"^  \" | head -60; echo ====; tail -60 /tmp/session.3log",
      "awk 'index($0,\"SYSTEM\"){print NR\": \"substr($0,1,140)}' /tmp/session.3log; echo ===LAST-ASSISTANT; awk '/^assistant/{n=NR} END{print n}' /tmp/session.3log"]
    for p in probes:
      check det.observeCall("bash", "{\"command\":" & escapeJson(p) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(p) & "}", true)
    check det.escalations == 0

  test "three-variant near-duplicate cycle escalates and aborts":
    # The balance burner: GLM 5.3-class flails that cycle three cosmetic
    # variants of one probe (digits and tails differ, intent identical).
    # Every variant carries >= 2 distinctive tokens, so the ring reads
    # near-duplicate overlap and the ladder runs to the abort.
    var det: FlailDetector
    let variants = [
      "rg -n \"deadline\" src/engine.nim | head -20",
      "rg -n \"deadline\" src/engine.nim | head -40",
      "rg -n \"deadline\" src/engine.nim | tail -20"]
    var verdicts: seq[FlailVerdict]
    for i in 0 ..< FlailStreakArm + FlailStreakMin + 3:
      let v = variants[i mod variants.len]
      verdicts.add det.observeCall("bash", "{\"command\":" & escapeJson(v) & "}")
      det.noteResult("bash", "{\"command\":" & escapeJson(v) & "}", true)
    const firstFire = FlailStreakArm + FlailStreakMin - 2
    for v in verdicts[0 ..< firstFire]:
      check v == fvOk
    check verdicts[firstFire] == fvEscalate
    check fvAbort in verdicts[^3 .. ^1]

  test "windowed scan with a fixed query never trips the streak signal":
    # Regression, verbatim from the 20261007T100839 mistral session (both
    # false positives in one run): a fixed grep pattern walked over
    # successive sed/awk windows of one file. Every call tokenizes
    # identically (the ranges are pure digits, dropped as addresses), so
    # the ring read a near-duplicate cluster and aborted the turn
    # mid-scan - while every fingerprint was novel and every window
    # delivered fresh lines. Scans are progress: the staleness arm keeps
    # them quiet no matter how many windows they cover.
    var det: FlailDetector
    let scans = [
      "grep -n \"mistral\" src/threecode/prompts.nim | awk -F: '$1 > 900 && $1 < 1000'",
      "sed -n '945,955p' src/threecode/prompts.nim",
      "sed -n '935,955p' src/threecode/prompts.nim",
      "grep -n \"experimental\\|Experimental\" src/threecode/prompts.nim | head -20",
      "sed -n '680,710p' src/threecode/prompts.nim",
      "grep -n \"mistral\" src/threecode/prompts.nim | awk -F: '$1 > 1000'",
      "grep -n \"mistral\" src/threecode/prompts.nim | awk -F: '$1 > 300 && $1 < 1000'",
      "grep -n \"mistral\" src/threecode/prompts.nim | awk -F: '$1 > 1000 && $1 < 1840'",
      "grep -n \"mistral\" src/threecode/prompts.nim | awk -F: '{print $1}' | tr '\\n' ' '",
      "sed -n '900,930p' src/threecode/prompts.nim",
      "sed -n '2389,2432p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '2434,2481p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1215,1287p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1141,1213p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '2483,2586p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1372,1468p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1470,1605p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1607,1711p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1728,1820p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1923,2098p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '2676,2778p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '2780,2859p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '2147,2387p' src/threecode/prompts.nim | grep -c \"^-\"",
      "sed -n '1843,1921p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\"",
      "sed -n '1289,1370p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\"",
      "sed -n '2588,2674p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\"",
      "sed -n '2940,3009p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\"",
      "sed -n '3010,3057p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\""]
    for i, c in scans:
      # Each window's grep returns its own lines: fresh letters per call,
      # so digit normalization cannot fake or erase novelty.
      let tag = $char(ord('a') + i div 26) & $char(ord('a') + i mod 26)
      let shown = "3:# window " & tag & " has its own text\n" &
        "9:# and a second distinct line " & tag
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true, shown)
    check det.escalations == 0

  test "near-duplicate streak re-delivering the same output still flags":
    # The other side of the staleness arm, same commands as the scan above:
    # when the ring fills with near-duplicate calls whose results repeat
    # what the model has already seen (the cosmetic-variant endgame of the
    # recorded doom loops), the streak still escalates to the abort.
    var det: FlailDetector
    let probes = [
      "sed -n '1289,1370p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\"",
      "sed -n '2588,2674p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\"",
      "sed -n '2940,3009p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\"",
      "sed -n '3010,3057p' src/threecode/prompts.nim | grep -n \"Instruction hierarchy\\|Critical\\|Blast radius\\|3CODE.md\\|AGENTS.md\""]
    const firstFire = FlailStreakArm + FlailStreakMin - 2
    var verdicts: seq[FlailVerdict]
    for i in 0 ..< firstFire + 4:
      let c = probes[i mod probes.len]
      # Same probe, same answer every time: stale from the second cycle on.
      let shown = "5:`3CODE.md` / `AGENTS.md` (when present) override this prompt.\n" &
        "46:`rg` first, then targeted `read` with offset/limit."
      verdicts.add det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}")
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true, shown)
    for v in verdicts[0 ..< firstFire]:
      check v == fvOk
    check verdicts[firstFire] == fvEscalate
    check fvAbort in verdicts[firstFire .. ^1]

  test "capture-retry verification with interleaved reads stays quiet":
    # Regression, the shape of the 20260930 astropy session (report.md):
    # a long bash run retrying one pytest command with cycling capture
    # tails - the varying part (tail -2 vs tail -3 vs tail -8) is under
    # the 6-char token minimum, so every retry tokenizes to the same
    # subject set - interleaved with reads of a different file. The
    # interleaved reads change the subject, so the ring keeps restarting
    # and the converging retries never read as an emission-stuck loop.
    var det: FlailDetector
    template bashCmd(c: string) =
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
    bashCmd "cd /tmp/asttest && timeout 300 /tmp/venvtest-310/bin/pip install --quiet -e . 2>&1 | tail -2; echo \"exit: $?\""
    bashCmd "cd /tmp/asttest && /tmp/venvtest-310/bin/pip install --quiet numpy pytest pytest-doctestplus 2>&1 | tail -1"
    const tails = [
      " 2>&1 | tail -3",
      " 2>&1 | grep -E \"passed|failed|error\" | tail -2",
      " 2>&1 | tail -8",
      " 2>&1 | grep -E \"^[0-9]+ (passed|failed)\" | tail -2",
      " > /tmp/asttest_out.txt 2>&1; echo \"rc=$?\"; wc -l /tmp/asttest_out.txt; tail -5 /tmp/asttest_out.txt"]
    for i in 0 ..< 15:
      bashCmd "cd /tmp/asttest && timeout 180 /tmp/venvtest-310/bin/python -m pytest astropy/units/tests/test_format.py -q" &
        tails[i mod tails.len]
      if (i + 1) mod 4 == 0:
        bashCmd "git describe --tags 2>&1 | head -1; ls astropy/version.py && head -15 astropy/version.py"
    check det.escalations == 0

  test "narration does not extend the ring's subject":
    # The other half of the astropy fix: the interleaved `git describe`
    # call carried a prose comment about version detection. Against the
    # union of all ring tokens that prose would have bridged the subject
    # change; only tokens the ring's majority carries count as its
    # subject, so the call still purges the ring.
    var det: FlailDetector
    template bashCmd(c: string) =
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
    for i in 1 .. FlailStreakArm + 3:
      bashCmd "cd /tmp/asttest && timeout 180 /tmp/venvtest-310/bin/python -m pytest astropy/units/tests/test_format.py -q 2>&1 | tail -" & $i
    bashCmd "cd /tmp/asttest && # astropy's version comes from git tags, which the ref strip deletes\ngit describe --tags 2>&1 | head -1; ls astropy/version.py && head -15 astropy/version.py"
    check det.streakTokens.len == 0

  test "ssh session with varied remote commands never trips the streak signal":
    # Mirrors the false positive from session 20260909T213716-2ICaadgQ:
    # a long run of ssh calls to one host, every one a novel fingerprint
    # probing a different fact. The host token (digits normalized to
    # root@##.#.#.#) was the only thing all calls shared, so the streak
    # signal read connection boilerplate as a theme and flagged call #24,
    # then cascaded to an abort on three genuinely different follow-ups.
    var det: FlailDetector
    template sshCmd(c: string) =
      check det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}") == fvOk
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
    sshCmd "ssh root@10.0.7.1 'ls -ld /home/carlo/3 2>/dev/null; which nim nimble choosenim 2>/dev/null; cat /etc/os-release | head -2'"
    sshCmd "ssh root@10.0.7.1 '/opt/nim/bin/nim --version; apt-get install -y libsass-dev sqlite3 2>&1 | tail -2'"
    sshCmd "ssh root@10.0.7.1 'sudo -u carlo bash -c \"cd ~/3 && git clone --recursive https://github.com/nim-lang/nimforum 2>&1 | tail -2\"'"
    sshCmd "ssh root@10.0.7.1 'sudo -u carlo bash -c \"export PATH=/opt/nim/bin:$PATH; cd ~/3/nimforum && nimble build -d:release -y 2>&1 | tail -15\"'"
    sshCmd "ssh root@10.0.7.1 'grep -n \"loadConfig\" -A40 /home/carlo/3/nimforum/src/utils.nim | head -70'"
    sshCmd "ssh root@10.0.7.1 'grep -n \"public\\|staticDir\\|getEnv\" /home/carlo/3/nimforum/src/forum.nim | head -20'"
    sshCmd "ssh root@10.0.7.1 'grep -n \"blankdb\\|devdb\" -A3 /home/carlo/3/nimforum/nimforum.nimble'"
    sshCmd "ssh root@10.0.7.1 'sudo -u carlo bash -c \"export PATH=/opt/nim/bin:$PATH; cd ~/3/nimforum && nimble blankdb -y 2>&1 | tail -3\"'"
    sshCmd "ssh root@10.0.7.1 'sed -n 20,60p /home/carlo/3/nimforum/src/setup_nimforum.nim'"
    sshCmd "ssh root@10.0.7.1 'sed -n 370,395p /home/carlo/3/nimforum/src/setup_nimforum.nim'"
    sshCmd "ssh root@10.0.7.1 'grep -rn \"Rank.Admin\\|rank == Rank\" /home/carlo/3/nimforum/src/forum.nim | head'"
    sshCmd "ssh root@10.0.7.1 'grep -rn \"registerUser\\|Rank.Moderator\\|firstUser\" /home/carlo/3/nimforum/src/forum.nim | head -10'"
    sshCmd "ssh root@10.0.7.1 'grep -rn \"Admin\" /home/carlo/3/nimforum/src/forum.nim | head -8'"
    sshCmd "ssh root@10.0.7.1 'grep -rn \"Admin\" /home/carlo/3/nimforum/src/ --include=\"*.nim\" -l'"
    check det.escalations == 0

  test "ssh-wrapped doom loop still flags on the shared probe token":
    # The ssh prefix strip must remove only the connection boilerplate, not
    # blind the streak signal: 12+ ssh calls all grepping one symbol still
    # share that symbol and must flag.
    var det: FlailDetector
    # Ring fills at arm (12) plus FlailStreakMin (9) calls: flags on #20.
    for i in 1 .. 21:
      let c = "ssh root@10.0.7.1 'grep -rn \"execCmdEx\" /opt/nim/lib/pure/os" & $i & ".nim | head -3'"
      let args = "{\"command\":" & escapeJson(c) & "}"
      if i < 20:
        check det.observeCall("bash", args) == fvOk
      else:
        check det.observeCall("bash", args) == fvEscalate
      det.noteResult("bash", args, true)

  test "same-prefix burst that turns into a real loop still flags":
    # The other side of the arm gate: keep the shared-prefix variants
    # going past FlailStreakArm + FlailStreakMin and the signal must
    # still fire. The prefix survives cd trimming, so this also covers
    # the `cd <dir> &&` case from the report.
    var det: FlailDetector
    for i in 0 ..< FlailStreakArm + FlailStreakMin:
      let c = "cd /home/carlo/.local/bin && nim c -d:release --opt:speed -o:bst-ocr bst.nim 2>&1 | tail -" & $i
      let v = det.observeCall("bash", "{\"command\":" & escapeJson(c) & "}")
      if i < FlailStreakArm + FlailStreakMin - 2:
        check v == fvOk
      else:
        check v == fvEscalate
      det.noteResult("bash", "{\"command\":" & escapeJson(c) & "}", true)
