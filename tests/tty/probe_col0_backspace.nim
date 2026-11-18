## Repro probe: backspace at column 0 of a multiline draft renders wrong
## (lines not in the correct position after the join).
import std/[json, os, posix, strutils]
import tty_expect, stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata" / "output" / "tty" /
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

proc dumpRaw(s: TtySession; since: int; label: string) =
  let chunk = s.raw[since ..< s.raw.len]
  echo "=== raw [", label, "] len=", chunk.len, " ==="
  echo escape(chunk)

proc snapshot(s: TtySession; label: string) =
  s.drain(120, recordFrame = true)
  let f = s.frames[^1]
  echo "=== [", label, "] caret row=", f.cursorRow, " col=", f.cursorCol,
       " hidden=", f.cursorHidden, " ==="
  for i, row in f.rows:
    let mark = if i == f.cursorRow: " <CARET" else: ""
    echo align($i, 2), " |", row, "|", mark
  echo "=== end ==="

proc runScenario(name: string; draftLines: seq[string]; joinIndex: int) =
  echo "\n######## ", name, " ########"
  let root = newFixture("col0bs_" & name)
  writeConfiguredProvider(root)
  let reply = "ack"
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
  defer:
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()
  tty.expect "❯"
  const shiftEnter = "\x1b[13;2u"
  for i, ln in draftLines:
    if i > 0: rawSend(tty, shiftEnter)
    rawSend(tty, ln)
  tty.drain(300)
  snapshot(tty, "draft")
  # walk up to joinIndex row (0-based), Home to column 0, backspace
  for i in 0 ..< (draftLines.len - 1 - joinIndex):
    rawSend(tty, "\x1b[A")
    tty.drain(150)
  rawSend(tty, "\x1b[H")     # Home: column 0
  tty.drain(150)
  snapshot(tty, "home at col 0")
  let rawBefore = tty.raw.len
  rawSend(tty, "\x7f")       # backspace: join
  tty.drain(300)
  dumpRaw(tty, rawBefore, "col-0 backspace bytes")
  snapshot(tty, "after col-0 backspace")

proc main() =
  runScenario("mid", @["line one", "line two", "line three"], 1)
  runScenario("second", @["alpha", "beta"], 1)
  runScenario("third", @["one", "two", "three", "four"], 2)
  runScenario("wrapped", @["a fairly long first line that will certainly wrap past eighty columns of terminal width yes", "second line", "third line"], 1)

when isMainModule:
  main()
