## Reproduction probe: the ghostty capture showed that when a multi-row
## draft sits in the buffered editor during an active turn (typed or
## history-recalled), the turn's answer commit repaints its volatile block
## anchored several rows too high and overwrites the tail rows of the
## just-committed prompt echo: "the line above the prompt is deleted".
##
## Usage: probe_history_recall_eat [typing-delay]

import std/[json, os, strutils]
import tty_expect, stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata" / "output" / "tty" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
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
    (key: "THREECODE_GEOMETRY_AUDIT", val: getEnv("THREECODE_GEOMETRY_AUDIT", "")),
  ]

proc main() =
  let root = newFixture("recall_eat")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $ %*[
    {"role": "assistant", "content": "first reply marker one",
     "contentChunks": ["first reply marker one"],
     "usage": {"promptTokens": 10, "completionTokens": 5,
               "totalTokens": 15, "cachedTokens": 0}},
    {"role": "assistant", "waitForTestContinue": true,
     "content": "second reply marker two",
     "contentChunks": ["second ", "reply ", "marker ", "two"],
     "contentChunkDelayMs": 80,
     "usage": {"promptTokens": 12, "completionTokens": 6,
               "totalTokens": 18, "cachedTokens": 0}}
  ])
  let bin = ensureStubBinary()
  let tty = newTtySession(bin, args = ["-x", "-i"], cwd = root / "run",
      env = stubEnv(root, root / "run" / "stub_responses.json"),
      cols = 100, rows = 40)
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    writeFile(root / "raw.bytes", tty.raw)
    tty.close()

  tty.expect "❯"
  # Turn 1: arms the resting bar with usage.
  tty.send "warm up turn"; tty.expect "warm up turn"; tty.send "\n"
  tty.expectInHistory "first reply marker one"
  tty.expectTokenBar(["○", "↑10"])
  tty.drain(300)

  # Turn 2: a prompt long enough to wrap to several rows at 100 cols.
  var prompt = "recall me alpha"
  while prompt.len < 330: prompt.add " br"
  prompt.add " omega"
  for ch in prompt:
    tty.send $ch
    tty.drain(1)
  tty.expect "omega"
  tty.send "\n"
  tty.expectInHistory "recall me alpha"

  # The turn is held open (waitForTestContinue). Recall the long prompt
  # into the buffered mid-turn editor, growing it to a multi-row block.
  tty.drain(200)
  tty.send "\x1b[A"
  tty.drain(500)
  let rowsAfterRecall = tty.rows()
  var editorTop = -1
  for i, r in rowsAfterRecall:
    if r.startsWith("❯ recall me alpha"): editorTop = i
  echo "recalled draft visible: ", editorTop >= 0

  # Release the answer: it streams and commits while the multi-row draft
  # still occupies the buffered editor.
  tty.continueStubApi()
  tty.expectInHistory "second reply marker two"
  tty.expectIdleCaret()
  tty.drain(400)

  # The committed echo of turn 2 must survive whole: scan up from the
  # answer row - blank separator, then the echo's wrapped rows with no
  # blank inside, up to its `❯` first row. A count short of the full
  # wrap (or a blank inside it) is the eaten-tail bug.
  let rows = tty.rows()
  var answerRow = -1
  for i, r in rows:
    if r.startsWith("● second reply"): answerRow = i
  doAssert answerRow >= 2, "answer row missing\n" & tty.dumpFramesAround("second reply")
  doAssert rows[answerRow - 1].strip.len == 0,
    "no blank between echo and answer (row above = '" &
    rows[answerRow - 1] & "')\n" & tty.dumpFramesAround("second reply")
  var i2 = answerRow - 2
  var echoTail = 0
  while i2 >= 0 and rows[i2].len > 0 and not rows[i2].startsWith("❯"):
    inc echoTail
    dec i2
  doAssert i2 >= 0 and rows[i2].startsWith("❯ recall me alpha"),
    "echo first row not found above its tail\n" &
    tty.dumpFramesAround("recall me alpha")
  # "recall me alpha ... omega" wraps to 4 rows at 100 cols: 1 head + 3 tail.
  echo "echo tail rows: ", echoTail
  for i, r in rows:
    echo align($i, 2), " |", r, "|"
  doAssert echoTail == 3,
    "committed echo lost " & $(3 - echoTail) & " tail row(s) to the " &
    "answer commit\n" & tty.dumpFramesAround("recall me alpha")

main()
