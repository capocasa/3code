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
##   - the content-streaming window, where the first content chunk killed the
##     GUI thread (so its rotating glyph could not clobber the streaming
##     partial), and the controller's per-chunk repaint used a static label
##     with no glyph at all. A provider that stalls mid-stream (slow second
##     chunk) therefore showed a frozen bar and no spinner, identical to the
##     backoff bug from the user's point of view.
import std/[json, os, strutils, unittest]
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
  test "braille spinner is animating during the retry backoff":
    let root = newFixture("pause_backoff_spinner")
    writeConfiguredProvider(root)
    # First response 429 (rate, 1s backoff at level 0 with -d:fastStubRetries
    # that caps attempts at 2). The retry-notice line lands immediately, but
    # the spinner must keep twirling through the whole backoff sleep that
    # follows it.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "429", "delayMs": 0, "body": "{\"error\":\"rate limit\"}"},
      {"role": "assistant", "preStreamDelayMs": 50,
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
    # Retry notice lands in scrollback. The backoff sleep follows.
    tty.expectInHistory("429", timeoutMs = 15_000)
    # Sample the live screen repeatedly across the backoff window. The
    # spinner repaints every 80ms, so a 250ms settle captures at least one
    # animated frame with high probability. We ask the harness to advance
    # spinner frames deterministically via the ticker fd so the test does
    # not depend on wall-clock luck.
    tty.drain(50)
    tty.advanceTicker()
    tty.drain(50)
    let sawBrailleDuringBackoff = tty.screenHasBraille()
    check sawBrailleDuringBackoff
    tty.expectInHistory "ok after retry"

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
    tty.expectInHistory("first", timeoutMs = 12000)
    # Now we are inside the contentChunkDelayMs gap: content has started,
    # but the second chunk will not arrive for seconds. Sample the live
    # screen through the gap.
    tty.drain(50)
    tty.advanceTicker()
    tty.drain(50)
    let sawBrailleDuringGap = tty.screenHasBraille()
    check sawBrailleDuringGap
    tty.expectInHistory("second", timeoutMs = 12000)
