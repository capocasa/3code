discard """
  disabled: "win"
  ## Flaky under ConPTY: the braille-spinner frame capture is timing-
  ## sensitive and intermittently misses the spinner frame under ConPTY's
  ## output latency, especially when run in the full testament suite (other
  ## tests warm the ConPTY output pipe). Passes in isolation.
"""
## Reproduction for the "pause" problem: during long phases of a turn, no
## activity indicator is visible. The expected indicator depends on the phase:
##   - during an API call (connect, pre-stream wait, retry backoff) the braille
##     spinner (⠋ ⠙ ⠹ ...) must twirl on the token-bar row.
##   - during tool execution the token bar must tick seconds (and, for bash
##     commands with streaming output, the $/€/£/¥ currency symbol must rotate
##     on the tool viewport).
##
## This file exercises every turn phase that can outlive a single render
## tick. Two windows are covered:
##   - the retry-backoff window, where earlier code stopped the spinner before
##     entering the sleep and only restarted it after the sleep returned,
##     leaving the whole backoff gap with a frozen bar and no animation.
##     Braille is strictly the in-flight-request indicator: during the
##     backoff the bar carries the hourglass ⧗ instead, the notice row
##     above it counts down, and the count-up turn timer keeps running
##     (a turn spans many requests); when the next attempt connects the
##     notice clears, the row above the bar returns to the empty spacer,
##     and the braille returns.
##   - the content-streaming window, where the first content chunk killed the
##     GUI thread (so its rotating glyph could not clobber the streaming
##     partial), and the controller's per-chunk repaint used a static label
##     with no glyph at all. A provider that stalls mid-stream (slow second
##     chunk) therefore showed a frozen bar and no spinner, identical to the
##     backoff bug from the user's point of view.
import std/[json, os, strutils, times, unittest]
import tty_expect
import stub_helpers

const Braille = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

proc screenHasBraille(s: TtySession): bool =
  let txt = s.screenText()
  for b in Braille:
    if b in txt: return true
  false

suite "activity indicator covers every turn phase":
  test "retry backoff shows the hourglass; braille is strictly in-flight":
    let root = newFixture("pause_backoff_spinner")
    writeConfiguredProvider(root)
    # First response: transport-level DNS failure ("server" category, 1s
    # backoff at level 0 with -d:fastStubRetries that caps attempts at 2).
    # The retry notice lands on the notice row immediately; through the whole
    # backoff sleep the bar must show the hourglass, never braille. The
    # recovered reply starts with a 4s pre-stream delay so the next
    # attempt's in-flight window (braille, notice cleared, empty spacer
    # above the bar) is observable before any content lands.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "dns", "delayMs": 0},
      {"role": "assistant", "preStreamDelayMs": 4000,
       "content": "ok after retry", "contentChunks": ["ok after retry"],
       "usage": {"promptTokens": 5, "completionTokens": 1,
                 "totalTokens": 6, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary(extraDefines = "-d:fastStubRetries")
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # The retry notice paints on the live notice row; the backoff sleep
    # follows it.
    tty.expectNoticeRow("is not responding")
    # Sample the live screen across the backoff window. We ask the harness
    # to advance spinner frames deterministically via the ticker fd so the
    # test does not depend on wall-clock luck.
    tty.drain(50)
    tty.advanceTicker()
    tty.drain(50)
    # Mid-backoff: no request is in flight, so the bar shows the hourglass
    # and no braille phase may appear anywhere on screen.
    let waitTxt = tty.screenText()
    check "\u29d7" in waitTxt
    check(not tty.screenHasBraille())
    let barRow = tty.rowContaining("\u29d7")
    doAssert barRow > 0, "hourglass not on a bar row: " & waitTxt
    check "\u25cb0%" in tty.rows[barRow]
    # The notice is boxed by a blank spacer row above the bar, so it
    # sits two rows up, not directly on top of the bar.
    check tty.rows[barRow - 1].strip().len == 0
    check "is not responding (name or service not known)" in tty.rows[barRow - 2]
    check "retry 2/2" in tty.rows[barRow - 2]
    # Wait out the 1s backoff, then sample the second attempt's
    # in-flight window (4s pre-stream delay): the notice is gone, the row
    # above the bar is the empty spacer again, and the braille spinner is
    # back. Wait for that STATE, not for a wall-clock duration: the
    # backoff sleep steps in 100ms slices, so a starved CI runner
    # stretches it well past 1s and a fixed drain(1600) samples
    # mid-backoff. A long wait is harmless either way: a slow child also
    # stretches the pre-stream delay, so the in-flight window only grows.
    let inFlightAt = epochTime() + 10.0
    while epochTime() < inFlightAt and not tty.exited:
      tty.advanceTicker()
      tty.drain(100)
      if "is not responding" notin tty.screenText() and tty.screenHasBraille():
        break
    tty.advanceTicker()
    tty.drain(50)
    let flightTxt = tty.screenText()
    check "is not responding" notin flightTxt
    check "\u29d7" notin flightTxt
    check tty.screenHasBraille()
    let liveBar = tty.rowContaining("\u25cb0%")
    doAssert liveBar > 0, "token bar not on screen: " & flightTxt
    doAssert tty.rows[liveBar - 1].strip().len == 0,
      "REGRESSION: row above the bar must return to the empty spacer, " &
        "got: '" & tty.rows[liveBar - 1] & "'"
    tty.expectInHistory("ok after retry", timeoutMs = 12000)

  test "braille spinner is animating during a mid-stream content gap":
    let root = newFixture("pause_stream_spinner")
    writeConfiguredProvider(root)
    # Content arrives in two chunks with a long gap between them. The first
    # chunk starts live streaming (which used to kill the GUI thread); the
    # second chunk arrives only after `waitForTestContinue`, so there is a
    # guaranteed window where content has started but nothing is arriving.
    # The spinner must keep twirling through that gap, exactly as it does
    # during the pre-stream wait and the retry backoff.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "stream": true,
       "content": "first then second",
       "contentChunks": ["first", "second"],
       "contentChunkDelayMs": 4000,
       "usage": {"promptTokens": 5, "completionTokens": 2,
                 "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # First chunk lands in scrollback. The stub injects a 4s
    # contentChunkDelayMs before the first chunk, so give the wait
    # headroom over the delay plus slower-CI startup.
    tty.expectInHistory("first", timeoutMs = 30000)
    # Now we are inside the contentChunkDelayMs gap: content has started,
    # but the second chunk will not arrive for seconds. Sample the live
    # screen through the gap.
    tty.drain(50)
    tty.advanceTicker()
    tty.drain(50)
    let sawBrailleDuringGap = tty.screenHasBraille()
    check sawBrailleDuringGap
    tty.expectInHistory("second", timeoutMs = 30000)
