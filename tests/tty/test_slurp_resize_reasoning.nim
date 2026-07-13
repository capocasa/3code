discard """
  # The tty_expect harness uses openpty/fork/execv (POSIX only).
  disabled: "win"
  disabled: "osx"
"""
## Reproduction for the "line slurp" bug: scrollback lines vanish one at a
## time, roughly one per 80ms GUI-tick, while the spinner is animating after a
## terminal resize. The slurp branch's single-GUI-thread refactor did NOT kill
## this; it surfaces against live reasoning providers (hy3, glm-5.x) and was
## first reported around the flake/test-flakiness refactor.
##
## Root cause: `beginEditorRedraw` (engine.nim) walked up one extra row
## for a 400ms window after every SIGWINCH via `resizeRecent()`. The comment
## claimed the extra row "sits inside the volatile region (the always-reserved
## ticker/gap row)," but the footer's `rowsAboveEditor` ALREADY includes the
## gap row (1 + barWrapRows), so +1 walked above the gap into committed
## scrollback. Each 80ms spinner tick during the resize window erased one
## more committed line. The same +1 was in `walkUp`; both are removed.
##
## This test fires repeated SIGWINCH during a reasoning burst (spinner active)
## and asserts no committed scrollback line is wiped in place across any
## consecutive frame pair.
import std/[json, os, strutils, unittest]
import tty_expect, stub_helpers

const VisualOutputRoot = "testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

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

proc writeStubResponses(root: string; responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc startStub(root: string; cols = DefaultTtyCols; rows = DefaultTtyRows): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                cols = cols, rows = rows)

const Reasoning = "Pondering the repository layout and weighing every " &
  "possible approach before responding carefully now end."

suite "line slurp on resize during reasoning":
  test "repeated SIGWINCH during spinner never wipes committed scrollback":
    let root = newFixture("slurp_resize_reasoning")
    writeConfiguredProvider(root)
    # A reasoning burst with a long preStreamDelay keeps the spinner animating
    # (each advanceTicker is one 80ms GUI frame) so SIGWINCH lands while the
    # spinner footer is the active painter. Content is multi-line so there is
    # tall committed scrollback to watch for in-place wipes.
    writeStubResponses(root, %*[
      {
        "reasoning_content": Reasoning,
        "reasoningChunks": [
          "Pondering the repository layout and weighing ",
          "every possible approach before responding ",
          "carefully now end."
        ],
        "preStreamDelayMs": 1500,
        "content": "Line one of the answer.\nLine two.\nLine three.\n" &
                   "Line four.\nLine five.\nLine six done.",
        "contentChunks": [
          "Line one of the answer.\nLine two.\nLine three.\n" &
          "Line four.\nLine five.\nLine six done."
        ],
        "usage": {
          "promptTokens": 42, "completionTokens": 20,
          "totalTokens": 62, "cachedTokens": 0
        }
      }
    ])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "go\n"
    # Let the spinner animate a few frames.
    tty.advanceTicker()
    tty.advanceTicker()

    # Hammer SIGWINCH every tick while the spinner is live. Each resize arms
    # resizeRecent()'s +1 erase row for 400ms; the repeated fire keeps it
    # armed across many 80ms GUI ticks — exactly the slurp window.
    for i in 0 ..< 10:
      if i mod 2 == 0:
        tty.resize(70, 24)
      else:
        tty.resize(80, 24)
      tty.advanceTicker()

    # Let the content land and the turn settle.
    tty.drain(600)
    tty.expectInHistory "Line six done."

    # Walk consecutive frame pairs. A wipe is a committed scrollback row that
    # is non-blank in the earlier frame, blank in the later frame, while the
    # row directly above it is byte-identical (so it was not a scroll-off).
    const committedMarkers = [
      "Line one", "Line two", "Line three",
      "Line four", "Line five", "Line six",
      "❯ go"
    ]
    proc isCommitted(row: string): bool =
      for m in committedMarkers:
        if m in row: return true
      false
    var wipeAt = -1
    var wipeDetail = ""
    for i in 1 ..< tty.frames.len:
      let prev = tty.frames[i - 1].rows
      let cur = tty.frames[i].rows
      for r in 1 ..< min(prev.len, cur.len):
        let prevRow = prev[r]
        let curRow = cur[r]
        if not prevRow.isCommitted: continue
        if curRow.strip.len > 0: continue
        if prev[r - 1] == cur[r - 1]:
          wipeAt = i
          wipeDetail = "frame " & $i & " row " & $r &
            ": \"" & prevRow & "\" -> blank, row above unchanged (\"" &
            prev[r - 1] & "\")"
          break
      if wipeAt >= 0: break
    doAssert wipeAt < 0, "spinner slurped a scrollback line in place: " &
      wipeDetail & "\n" & tty.dumpFramesAround("")

    tty.send "\x03"
    tty.drain(200)
    tty.send ":q\n"
    tty.expectExit 0
