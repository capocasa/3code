discard """
  disabled: "win"
  ## posix-only: the Alt+E / Ctrl+X Ctrl+E editor tests script a $VISUAL
  ## helper and send raw control bytes via the PTY master.
"""
## Feature tests: `:! CMD` runs a shell command through the tool executor
## (banner + output in scrollback, never to the model), and Alt+E /
## Ctrl+X Ctrl+E edit the prompt buffer in $VISUAL/$EDITOR.
import std/[json, os, posix, strutils, times, unittest]
import tty_expect
import stub_helpers

const Root = "tests/testdata/output/tty/shell_and_editor"

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" / (name & "_" & $getCurrentProcessId())
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

  test ":! streams output live, not only at completion":
    let root = newFixture("shell_stream")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let tty = startStub(root, "")
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText ":! sh -c 'echo ST\"\"REAM\"\"ONE; sleep 2; echo ST\"\"REAM\"\"TWO'"
    tty.send "\n"

    # The command sleeps 2s after its first line: only a streaming
    # executor can put STREAMONE on screen before completion. Output
    # buffered until exit misses this deadline. The quoted-string split
    # (ST""REAM) keeps the marker out of the typed line, which is echoed
    # on submit and would otherwise satisfy the wait immediately.
    require tty.waitForText("STREAMONE", 1200)

    tty.expectInHistory "$ sh -c"
    tty.expectInHistory "STREAMTWO"
    tty.drain(200)
    tty.expect "\u276f"
    # The final commit folds the live viewport into one scrollback item;
    # the banner must appear exactly once, not again below itself.
    require tty.screenText().count("$ sh -c") == 1
    echo "  PASS: :! streams live"

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

  test "Cmd+E edits the buffer in $VISUAL (kitty protocol)":
    let root = newFixture("cmd_e_editor")
    writeConfiguredProvider(root)
    # Cmd bindings are opt-in, not defaults.
    let cfg = root / "xdg" / "3code" / "config"
    writeFile(cfg, readFile(cfg) & "\n[shortcuts]\nedit-in-editor = CmdE\n")
    writeStubResponses(root)
    let marker = root / "cmde_marker"
    let editor = editorScript(root, marker)
    let tty = startStub(root, editor)
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText "base text"
    tty.drain(100)
    # Cmd+E on a kitty-protocol terminal: CSI 101;9 u (super modifier)
    tty.sendBytes "\x1b[101;9u"

    require waitForFile(marker)
    tty.drain(300)
    tty.expectInHistory "edited line"

    tty.send "\n"
    tty.expectInHistory "ok."
    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: Cmd+E edit-in-editor"

  test "Cmd+A selects the whole buffer (kitty protocol, #57)":
    let root = newFixture("cmd_a_select_all")
    writeConfiguredProvider(root)
    # Cmd bindings are opt-in: the mac select-all gesture is a config
    # line, exactly what issue #57 asks for.
    let cfg = root / "xdg" / "3code" / "config"
    writeFile(cfg, readFile(cfg) & "\n[shortcuts]\nselect-all = CmdA\n")
    writeStubResponses(root)
    let tty = startStub(root, "")
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText "hello world"
    tty.drain(100)
    # Cmd+A on a kitty-protocol terminal: CSI 97;9 u (super modifier).
    # The repaint must carry the reverse-video selection SGR around the
    # whole buffer - checked on the raw bytes the app emits, not on a
    # re-modelled grid.
    let repaintFrom = tty.raw.len
    tty.sendBytes "\x1b[97;9u"
    tty.drain(200)
    let repaint = tty.raw[repaintFrom ..^ 1]
    check "\x1b[7mhello world" in repaint

    # Typing replaces the selection, the mac Cmd-A meaning.
    tty.typeText "Z"
    tty.drain(100)
    tty.send "\n"

    tty.expectInHistory "Z"
    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: Cmd+A select-all"

  test ":help lists the live bindings, unbound commands included (#57)":
    let root = newFixture("help_bindings")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let tty = startStub(root, "")
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText ":help"
    tty.send "\n"
    tty.drain(300)
    # The static help never mentioned select-all (it has no default
    # key), so a user could not discover the command to bind Cmd-A to.
    # The live table lists it, marked unbound.
    tty.expectInHistory "bindings in effect"
    tty.expectInHistory "select-all"
    tty.expectInHistory "(unbound)"
    tty.drain(200)
    tty.expect "\u276f"

    # With the binding configured, the same table shows the live keys.
    let root2 = newFixture("help_bindings_cmda")
    writeConfiguredProvider(root2)
    let cfg2 = root2 / "xdg" / "3code" / "config"
    writeFile(cfg2, readFile(cfg2) & "\n[shortcuts]\nselect-all = CmdA\n")
    writeStubResponses(root2)
    let tty2 = startStub(root2, "")
    defer: tty2.close()

    tty2.expect "\u276f"
    tty2.typeText ":help"
    tty2.send "\n"
    tty2.drain(300)
    tty2.expectInHistory "bindings in effect"
    tty2.expectInHistory "CmdA"
    tty2.drain(200)
    tty2.expect "\u276f"
    echo "  PASS: :help live bindings"

  test "plain Ctrl+E is end-of-line, not the editor":
    let root = newFixture("ctrl_e_alone")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    let marker = root / "ce_marker"
    let editor = editorScript(root, marker)
    let tty = startStub(root, editor)
    defer: tty.close()

    tty.expect "\u276f"

    tty.typeText "ab"
    tty.drain(100)
    tty.sendBytes "\x01"   # Ctrl+A -> start
    tty.drain(50)
    tty.typeText "X"        # -> "Xab"
    tty.drain(50)
    tty.sendBytes "\x05"   # Ctrl+E -> end
    tty.drain(50)
    tty.typeText "Y"        # -> "XabY"
    tty.drain(50)
    tty.send "\n"

    tty.expectInHistory "XabY"
    require not waitForFile(marker, 1500)
    tty.drain(200)
    tty.expect "\u276f"
    echo "  PASS: plain Ctrl+E end-of-line"

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
