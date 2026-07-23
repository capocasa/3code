discard """
  # The tty_expect harness uses openpty/fork/execv (POSIX only).
  disabled: "win"
"""
## Regression: on a terminal resize while the fat prompt's thinking ticker /
## spinner footer is live, the footer used to stack — each repaint left the
## previous ticker/bar row on screen instead of replacing it in place, so a
## resize produced a wall of ticker lines instead of an in-place animation.
##
## Root cause was a terminal-emulator fidelity gap: the test grid did not
## reposition its cursor when the viewport shrank (real terminals clamp the
## cursor into the new viewport and scroll content to keep it visible), so
## the child's next relative repaint walked up from a row that had been left
## below the visible area. `tty_expect.resize` now clamps the grid cursor on
## a height change, matching real-terminal behavior, and this test guards
## that the fat prompt stays a single in-place footer across shrink, grow,
## and width-only resize while the ticker is animating.
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

proc barRowCount(s: TtySession): int =
  ## Number of rows on the live screen carrying a token-bar context glyph.
  ## A correct in-place repaint keeps exactly one; a stacking footer leaves
  ## several.
  for row in s.rows():
    if "○0%" in row:
      inc result

proc tickerRowCount(s: TtySession): int =
  for row in s.rows():
    if "…" in row:
      inc result

const Reasoning = "Pondering the repository layout and weighing every " &
  "possible approach before responding carefully now end."

suite "fat prompt on terminal resize":
  test "shrink while the thinking ticker is live keeps one footer":
    let root = newFixture("resize_shrink_ticker")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "reasoning_content": Reasoning,
        "reasoningChunks": [
          "Pondering the repository layout and weighing ",
          "every possible approach before responding ",
          "carefully now end."
        ],
        "preStreamDelayMs": 1500,
        "content": "Resize ticker reply.",
        "contentChunks": ["Resize ticker reply."],
        "usage": {
          "promptTokens": 42, "completionTokens": 9,
          "totalTokens": 51, "cachedTokens": 0
        }
      }
    ])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "go\n"
    # Enter the live footer phase and let the ticker animate a couple frames.
    tty.drain(400)
    tty.advanceTicker()
    tty.advanceTicker()
    check tty.barRowCount() == 1

    # Shrink hard, then let the footer settle. A resize may briefly stack a
    # stale bar row while the terminal repositions the cursor, but the
    # repaint must converge back to a single in-place footer — it must never
    # leave a permanent wall of chrome.
    tty.resize(40, 12)
    tty.advanceTicker()
    tty.advanceTicker()
    tty.drain(500)
    let bars = tty.barRowCount()
    if bars > 1:
      doAssert false, "footer did not settle to one row after shrink: " &
        $bars & " bar rows on screen.\n" & tty.dumpFramesAround("○0%")
    check bars == 1

    tty.send "\x03"
    tty.drain(200)
    tty.send ":q\n"
    tty.expectExit 0

  test "grow while the thinking ticker is live keeps one footer":
    let root = newFixture("resize_grow_ticker")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "reasoning_content": Reasoning,
        "reasoningChunks": [
          "Pondering the repository layout and weighing ",
          "every possible approach before responding ",
          "carefully now end."
        ],
        "preStreamDelayMs": 2500,
        "content": "Resize ticker reply.",
        "contentChunks": ["Resize ticker reply."],
        "usage": {
          "promptTokens": 42, "completionTokens": 9,
          "totalTokens": 51, "cachedTokens": 0
        }
      }
    ])
    # Start narrow so there is room to grow.
    let tty = startStub(root, cols = 40, rows = 12)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "go\n"
    tty.drain(600)
    tty.advanceTicker()
    tty.advanceTicker()
    check tty.barRowCount() == 1

    tty.resize(80, 24)
    tty.advanceTicker()
    tty.advanceTicker()
    tty.drain(200)
    let bars = tty.barRowCount()
    if bars > 1:
      doAssert false, "footer stacked on grow: " & $bars &
        " bar rows on screen (expected 1).\n" & tty.dumpFramesAround("○0%")
    check bars == 1

    tty.send "\x03"
    tty.drain(200)
    tty.send ":q\n"
    tty.expectExit 0

  test "width changes at stable height keep one footer":
    let root = newFixture("resize_width_ticker")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "reasoning_content": Reasoning,
        "reasoningChunks": [
          "Pondering the repository layout and weighing ",
          "every possible approach before responding ",
          "carefully now end."
        ],
        "preStreamDelayMs": 3000,
        "content": "Resize ticker reply.",
        "contentChunks": ["Resize ticker reply."],
        "usage": {
          "promptTokens": 42, "completionTokens": 9,
          "totalTokens": 51, "cachedTokens": 0
        }
      }
    ])
    let tty = startStub(root, cols = 80, rows = 24)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "go\n"
    tty.drain(400)
    tty.advanceTicker()
    tty.advanceTicker()

    # Repeatedly narrow and widen at a stable height; every width must leave
    # exactly one footer on screen.
    for w in [60, 40, 30, 50, 80, 35, 70]:
      tty.resize(w, 24)
      tty.advanceTicker()
      tty.advanceTicker()
      tty.drain(120)
      let bars = tty.barRowCount()
      if bars > 1:
        doAssert false, "footer stacked at width " & $w & ": " & $bars &
          " bar rows on screen (expected 1).\n" & tty.dumpFramesAround("○0%")

    # The ticker row itself must also never duplicate.
    check tty.tickerRowCount() <= 1

    tty.send "\x03"
    tty.drain(200)
    tty.send ":q\n"
    tty.expectExit 0
