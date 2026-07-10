discard """
  # Same POSIX/PTY constraints as the other tty tests.
  disabled: "win"
  disabled: "osx"
"""
## Reproduction for the "pause" problem: during long phases of a turn, no
## activity indicator is visible. The expected indicator depends on the phase:
##   - during an API call (connect, pre-stream wait, retry backoff) the braille
##     spinner (⠋ ⠙ ⠹ ...) must twirl on the token-bar row.
##   - during tool execution the token bar must tick seconds (and, for bash
##     commands with streaming output, the $/€/£/¥ currency symbol must rotate
##     on the tool viewport).
##
## This file exercises the retry-backoff window, where earlier code stopped the
## spinner before entering the sleep and only restarted it after the sleep
## returned, leaving the whole backoff gap with a frozen bar and no animation.
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
search-url = "http://127.0.0.1:1/?q="

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
    tty.expectInHistory "429"
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
