discard """
  disabled: "win"
  ## posix-only: the `:goal edit` tests script a $VISUAL stand-in that
  ## reads stdin the way an editor does and sends raw control bytes via
  ## the PTY master.
"""
## Feature tests: `:goal edit` hands the terminal to $VISUAL/$EDITOR.
## The editor must open at once whether a turn is running or not, must
## find a cooked terminal (echo, line buffering - and no 3code thread
## taking its keys or painting over its screen), and must leave 3code in
## its raw mode and with its running turn intact when it exits.
import std/[json, os, posix, strutils, times, unittest]
import posix/termios
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getTempDir() / "3code_tty_fixture" / (name & "_" & $getCurrentProcessId())
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
  result = @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "VISUAL", val: editor),
    (key: "test.stub_responses", val: responsesPath),
  ]

proc usage(): JsonNode =
  %*{"promptTokens": 5, "completionTokens": 2,
     "totalTokens": 7, "cachedTokens": 0}

proc reply(content: string): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": 50,
     "content": content, "contentChunks": [content], "usage": usage()}

proc heldReply(content: string): JsonNode =
  ## A reply the stub holds open until `continueStubApi`.
  %*{"role": "assistant", "waitForTestContinue": true,
     "content": content, "contentChunks": [content], "usage": usage()}

const Verdict = "all done\nVERDICT: SATISFIED"

proc startStub(root: string; responses: JsonNode; editor = ""): TtySession =
  writeFile(root / "run" / "stub_responses.json", $responses)
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json",
                              if editor == "": root / "editor.sh" else: editor))

proc writeEditor(root: string) =
  ## A $VISUAL stand-in shaped like an editor: records the tty flags it
  ## inherited, signals that it is up, reads ONE line of input the way an
  ## editor reads keys (from the terminal), writes that line into the
  ## buffer file, and signals that it is done.
  writeFile(root / "editor.sh", """#!/bin/sh
R='""" & root & """'
stty -a | tr ' ' '\n' | grep -x 'icanon\|-icanon\|echo\|-echo' > "$R/tty-flags.txt"
touch "$R/editor-open"
IFS= read -r line
printf '%s\n' "$line" > "$1"
touch "$R/editor-done"
""")
  discard chmod(root / "editor.sh", 0o755)

proc sendBytes(s: TtySession; bytes: string) =
  ## Raw control bytes: no echo to wait on.
  if bytes.len > 0:
    discard posix.write(s.masterFd, unsafeAddr bytes[0], bytes.len)
  s.drain(30)

proc waitForFile(path: string; timeoutMs = 5000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if fileExists(path): return true
    sleep(20)
  fileExists(path)

proc ptyLflag(s: TtySession): Cflag =
  var t: Termios
  if tcGetAttr(s.masterFd.cint, addr t) != 0:
    return 0.Cflag
  t.c_lflag

proc ptyIsRaw(s: TtySession): bool =
  ## 3code's own input mode: no echo, no line buffering.
  let l = s.ptyLflag
  (l and Cflag(ECHO or ICANON)) == 0.Cflag

proc typeText(s: TtySession; text: string) =
  for ch in text:
    s.send($ch)
    s.drain(10)

suite ":goal edit (external editor handoff)":
  test "typed mid-turn, the editor opens at once on a cooked terminal; the drain re-arms":
    let root = newFixture("goal_edit_midturn")
    writeConfiguredProvider(root)
    writeEditor(root)
    # Response 1: the held-open kickoff turn of the first goal. Response
    # 2: its verifier (satisfied, so the goal retires). Responses 3/4:
    # the kickoff turn of the goal the edit arms, and its verifier.
    let tty = startStub(root, %*[
      heldReply("KICKOFF_HELD"), reply(Verdict),
      reply("EDITED_TURN_DONE"), reply(Verdict)])
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    check ptyIsRaw(tty)
    tty.send ":goal the original goal"
    tty.expect ":goal the original goal"
    tty.send "\n"
    tty.expectInHistory "\u2691 the original goal"
    tty.drain(200)
    check not tty.exited

    # Mid-turn: the editor must be up while the kickoff turn is still
    # held open - the turn boundary is not what opens it.
    tty.send ":goal edit"
    tty.expect ":goal edit"
    tty.send "\n"
    if not waitForFile(root / "editor-open"):
      tty.continueStubApi()
      check false
    tty.drain(100)
    # The terminal the editor inherited: cooked (echo + line buffering on).
    let flags = readFile(root / "tty-flags.txt")
    check flags.strip().splitLines() == @["icanon", "echo"]
    # The keys go to the editor alone: it reads the line, writes the
    # buffer, exits.
    check not fileExists(root / "editor-done")
    tty.typeText "edited goal text"
    tty.send "\n"
    require waitForFile(root / "editor-done")
    tty.drain(100)
    check not tty.exited
    # 3code's raw mode is back the moment the editor is gone.
    check ptyIsRaw(tty)

    # Release the kickoff turn: its reply lands, the drain runs the
    # queued `:goal edit` over the file the editor left, and the new
    # goal's kickoff runs at once.
    tty.continueStubApi()
    tty.expectInHistory "KICKOFF_HELD"
    tty.expectInHistory "\u2691 edited goal text"
    tty.expectNeverInHistory "editor exited with status"
    tty.expectInHistory "EDITED_TURN_DONE"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    tty.expect "\u276f"
    check ptyIsRaw(tty)
    tty.expectAlive()
    echo "  PASS: :goal edit mid-turn"

  test "typed at the prompt, the editor owns the terminal until it exits":
    let root = newFixture("goal_edit_idle")
    writeConfiguredProvider(root)
    writeEditor(root)
    # 1: the kickoff turn of the goal the edit arms. 2: its verifier.
    let tty = startStub(root, %*[reply("FRESH_TURN_DONE"), reply(Verdict)])
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send ":goal edit"
    tty.expect ":goal edit"
    tty.send "\n"
    require waitForFile(root / "editor-open")
    tty.drain(100)
    check readFile(root / "tty-flags.txt").strip().splitLines() ==
      @["icanon", "echo"]
    check not fileExists(root / "editor-done")
    tty.typeText "a fresh goal"
    tty.send "\n"
    require waitForFile(root / "editor-done")
    tty.expectInHistory "\u2691 a fresh goal"
    tty.expectNeverInHistory "editor exited with status"
    tty.expectInHistory "FRESH_TURN_DONE"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    tty.expect "\u276f"
    check ptyIsRaw(tty)
    tty.expectAlive()
    echo "  PASS: :goal edit at the prompt"

  test "Ctrl-C inside the editor is the editor's, not a 3code interrupt":
    let root = newFixture("goal_edit_ctrlc")
    writeConfiguredProvider(root)
    writeEditor(root)
    # The stand-in dies on SIGINT like any editor interrupted mid-read
    # (`read` is interrupted and the shell exits 130); a plain reply is
    # on hand in case 3code wrongly ran a turn afterwards.
    let tty = startStub(root, %*[reply("NO_TURN_EXPECTED")])
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send ":goal edit"
    tty.expect ":goal edit"
    tty.send "\n"
    require waitForFile(root / "editor-open")
    tty.drain(100)
    # Cooked tty: the line discipline turns the byte into SIGINT for the
    # whole foreground process group, 3code included.
    tty.sendBytes "\x03"
    tty.expectInHistory "editor exited with status 130"
    tty.drain(500)
    # Neither the idle-exit nor a cancelled turn: the prompt is back,
    # raw, alive, and no turn ran.
    tty.expect "\u276f"
    check ptyIsRaw(tty)
    tty.expectAlive("REGRESSION: a Ctrl-C inside the editor reached " &
      "3code's interrupt hook and exited at the prompt.")
    tty.expectNeverInHistory "NO_TURN_EXPECTED"
    tty.expectNeverInHistory "\u2691"
    echo "  PASS: Ctrl-C in the editor"
