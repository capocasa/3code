## Repro probe: "the last line of a multiline comment gets deleted on
## sending the turn". Drives the real stub binary under a PTY through
## several multiline-submit variants, snapshots the screen after submit,
## and checks the persisted session log for the exact submitted text.

import std/[json, os, posix, strutils]
import tty_expect, stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata" / "output" / "tty" /
    (name & "_" & $getCurrentProcessId())
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
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc rawSend(s: TtySession; text: string) =
  if text.len == 0: return
  discard posix.write(s.masterFd, text[0].unsafeAddr, text.len)

proc snapshot(s: TtySession; label: string) =
  s.drain(80, recordFrame = true)
  let f = s.frames[^1]
  echo "=== [", label, "] caret row=", f.cursorRow, " col=", f.cursorCol, " ==="
  for i, row in f.rows:
    let mark = if i == f.cursorRow: " <CARET" else: ""
    echo align($i, 2), " |", row, "|", mark
  echo "=== end ==="

proc sessionUserMsgs(root: string): seq[string] =
  ## .3log records: header at col 0 (role ...), body lines indented 2.
  let dir = root / "data" / "3code" / "sessions"
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".3log"):
      var cur = -1
      for line in readFile(path).splitLines:
        if line.startsWith("  "):
          if cur >= 0:
            result[cur].add line[2 ..^ 1]
            result[cur].add '\n'
        elif line.len > 0:
          cur = -1
          if line.startsWith("user"):
            result.add ""
            cur = result.high
      if cur >= 0 and result[cur].len > 0:
        result[cur].setLen(result[cur].len - 1)  # one trailing \n max

proc runScenario(name: string; draft: string; submitKey = "\n";
                 lastLine = ""; cols = 0; rows = 0) =
  echo "\n################ ", name, " ################"
  let root = newFixture("mlsubmit_" & name)
  writeConfiguredProvider(root)
  let reply = "ack reply for " & name
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": reply, "contentChunks": %*[reply],
     "usage": {"promptTokens": 20, "completionTokens": 5,
               "totalTokens": 25, "cachedTokens": 0}}
  ]))
  let stub = ensureStubBinary()
  let tty = newTtySession(stub,
                          args = ["-x", "-i"],
                          cwd = root / "run",
                          env = stubEnv(root, root / "run" / "stub_responses.json"))
  if cols > 0 or rows > 0:
    tty.resize(if cols > 0: cols else: 80, if rows > 0: rows else: 28)
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()

  tty.expect "❯"
  rawSend(tty, draft)
  snapshot(tty, "draft")
  rawSend(tty, submitKey)
  snapshot(tty, "just after submit")
  discard tty.expect(reply, timeoutMs = 5000)
  snapshot(tty, "after reply")

  let want = if lastLine.len > 0: lastLine else: draft.splitLines[^1]
  let echoed = tty.frames[^1].rows.join("\n")
  echo "last draft line: ", escape(want)
  echo "echoed in final screen: ", want in echoed
  let msgs = sessionUserMsgs(root)
  echo "session user msgs: ", msgs.len
  for m in msgs:
    echo "  msg: ", escape(m)
  if msgs.len > 0:
    echo "last line in session log: ", want in msgs[^1]

const shiftEnter = "\x1b[13;2u"
const altEnter = "\x1b\r"
const xmodNewline = "\x1b[27;2;13~"

proc main() =
  # 1: typed shift-enter lines (what the existing passing test does)
  runScenario("typed",
    "first line" & shiftEnter & "second line" & shiftEnter &
    "third line ends here", lastLine = "third line ends here")
  # 2: bracketed paste of a 3-line comment, then Enter
  runScenario("paste",
    "\x1b[200~# comment line one\n# comment line two\n# comment line three\x1b[201~",
    lastLine = "# comment line three")
  # 3: paste with a trailing newline, then Enter
  runScenario("paste_trailing_nl",
    "\x1b[200~# comment line one\n# comment line two\n\x1b[201~",
    lastLine = "# comment line two")
  # 4: tall draft, more lines than a few rows
  var tall = ""
  for i in 1 .. 12:
    if i > 1: tall.add shiftEnter
    tall.add "tall draft line number " & $i
  runScenario("tall", tall, lastLine = "tall draft line number 12")
  # 5: last line longer than the width (wraps)
  runScenario("wrapped",
    "short first" & shiftEnter &
    "a final line that is long enough to wrap across the 80 column " &
    "terminal width boundary for sure",
    lastLine = "terminal width boundary for sure")
  # 6: caret parked on an earlier line when Enter is pressed
  runScenario("caret_mid", "alpha line" & shiftEnter & "beta line" & shiftEnter &
    "gamma line" & "\x1b[A", lastLine = "gamma line")
  # 7: Alt+Enter (ESC CR) as the newline key
  runScenario("alt_enter",
    "first line" & altEnter & "second line" & altEnter &
    "third line ends here", lastLine = "third line ends here")
  # 8: xterm modifyOtherKeys Shift+Enter
  runScenario("xmod_enter",
    "first line" & xmodNewline & "second line" & xmodNewline &
    "third line ends here", lastLine = "third line ends here")
  # 9: submit with CR instead of LF
  runScenario("cr_submit",
    "first line" & shiftEnter & "second line" & shiftEnter &
    "third line ends here", submitKey = "\r",
    lastLine = "third line ends here")
  # 10: draft taller than the viewport
  var huge = ""
  for i in 1 .. 40:
    if i > 1: huge.add shiftEnter
    huge.add "huge draft line number " & $i
  runScenario("huge", huge, lastLine = "huge draft line number 40")
  # 11: narrow width, wrapped multiline
  runScenario("narrow",
    "first line wraps a little here" & shiftEnter &
    "second line wraps a little here too", cols = 40,
    lastLine = "second line wraps a little here too")
  # 12: wide-and-tall geometry
  runScenario("wide",
    "first line" & shiftEnter & "second line" & shiftEnter &
    "third line ends here", cols = 199, rows = 50,
    lastLine = "third line ends here")
  # 13: narrow-and-tall geometry
  runScenario("tall",
    "first line" & shiftEnter & "second line" & shiftEnter &
    "third line ends here", cols = 80, rows = 55,
    lastLine = "third line ends here")

proc runQueuedScenario() =
  echo "\n################ queued_midturn ################"
  let root = newFixture("mlsubmit_queued")
  writeConfiguredProvider(root)
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"role": "assistant", "waitForTestContinue": true,
     "content": "first turn reply", "contentChunks": %*["first turn reply"],
     "usage": {"promptTokens": 10, "completionTokens": 3,
               "totalTokens": 13, "cachedTokens": 0}},
    {"role": "assistant",
     "content": "second turn reply", "contentChunks": %*["second turn reply"],
     "usage": {"promptTokens": 10, "completionTokens": 3,
               "totalTokens": 13, "cachedTokens": 0}}
  ]))
  let stub = ensureStubBinary()
  let tty = newTtySession(stub, args = ["-x", "-i"], cwd = root / "run",
    env = stubEnv(root, root / "run" / "stub_responses.json"))
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()
  tty.expect "❯"
  tty.send "start the turn"
  tty.send "\n"
  tty.send "queued line one"
  tty.send shiftEnter
  tty.send "queued line two"
  tty.send shiftEnter
  tty.send "queued line three"
  tty.expect "queued line three"
  tty.send "\n"
  tty.advanceTicker()
  tty.continueStubApi()
  discard tty.expect("second turn reply", timeoutMs = 5000)
  snapshot(tty, "after queued turn completes")
  let msgs = sessionUserMsgs(root)
  echo "session user msgs: ", msgs.len
  for m in msgs:
    echo "  msg: ", escape(m)
  echo "queued msg keeps last line: ",
    msgs.len == 2 and "queued line three" in msgs[1]

when isMainModule:
  main()
  runQueuedScenario()