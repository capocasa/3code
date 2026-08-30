discard """
  disabled: "win"
  ## posix-only: the Alt+E / Ctrl+X Ctrl+E editor tests script a $VISUAL
  ## helper and send raw control bytes via the PTY master.
"""
## Feature tests: `:! CMD` runs a shell command through the tool executor
## (banner + output in scrollback, never to the model), and Alt+E /
## Ctrl+X Ctrl+E edit the prompt buffer in $VISUAL/$EDITOR.
import std/[json, os, posix, times, unittest]
import tty_expect
import stub_helpers

const Root = "testdata/output/tty/shell_and_editor"

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

proc stubEnv(root, responsesPath, editor: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "VISUAL", val: editor),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc writeStubResponses(root: string) =
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"role": "assistant", "preStreamDelayMs": 100,
     "content": "ok.", "contentChunks": ["ok."],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}
  ]))

proc startStub(root, editor: string): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json", editor),
                keepHistory = false)

proc sendAltChord(s: TtySession; letter: char) =
  ## ESC + letter as one burst; an Alt chord doesn't echo, so `send`'s
  ## printable-echo wait would stall.
  var buf: array[2, char] = ['\x1b', letter]
  discard posix.write(s.masterFd, addr buf[0], 2)
  s.drain(30)

proc sendBytes(s: TtySession; bytes: string) =
  ## Raw control bytes: no echo to wait on.
  if bytes.len > 0:
    discard posix.write(s.masterFd, unsafeAddr bytes[0], bytes.len)
  s.drain(30)

proc typeText(s: TtySession; text: string) =
  for ch in text:
    s.send($ch)
    s.drain(10)

proc waitForFile(path: string; timeoutMs = 5000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if fileExists(path): return true
    sleep(50)
  fileExists(path)

proc editorScript(root, marker: string): string =
  ## A $VISUAL stand-in: appends a line to the buffer file and touches a
  ## marker so the test can tell the editor actually ran.
  result = root / "editor.sh"
  writeFile(result, "#!/bin/sh\necho \"edited line\" >> \"$1\"\ntouch " & marker & "\n")
  discard chmod(result, 0o755)

suite "shell command and edit-in-editor":
  test ":! echo runs the command and returns to the prompt":
    let root = newFixture("shell_command")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let tty = startStub(root, "")
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText ":! echo hello"
    tty.send "\n"
    tty.drain(300)

    tty.expectInHistory "$ echo hello"
    tty.expectInHistory "hello"

    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: :! echo hello"

  test ":! alone prints usage":
    let root = newFixture("shell_usage")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let tty = startStub(root, "")
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText ":!"
    tty.send "\n"
    tty.drain(300)

    tty.expectInHistory "usage: :!"
    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: :! usage"

  test "Alt+E edits the buffer in $VISUAL":
    let root = newFixture("alt_e_editor")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let marker = root / "alt_marker"
    let editor = editorScript(root, marker)
    let tty = startStub(root, editor)
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText "base text"
    tty.drain(100)
    tty.sendAltChord('e')

    require waitForFile(marker)
    tty.drain(300)
    tty.expectInHistory "edited line"

    tty.send "\n"
    tty.expectInHistory "ok."
    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: Alt+E edit-in-editor"

  test "Ctrl+X Ctrl+E edits the buffer in $VISUAL":
    let root = newFixture("ctrlxe_editor")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let marker = root / "cx_marker"
    let editor = editorScript(root, marker)
    let tty = startStub(root, editor)
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText "cx"
    tty.drain(100)
    tty.sendBytes "\x18"
    tty.sendBytes "\x05"

    require waitForFile(marker)
    tty.drain(300)
    tty.expectInHistory "edited line"

    tty.send "\n"
    tty.expectInHistory "ok."
    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: Ctrl+X Ctrl+E edit-in-editor"
