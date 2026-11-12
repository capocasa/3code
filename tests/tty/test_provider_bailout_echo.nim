## Regression: a `:provider` command that bails out before any wizard
## field ran (`update`/`edit`/`rm` on an unknown name, usage errors, the
## read-only `new` report) must commit like every ordinary command: the
## typed line echoed as scrollback, the body below it, the editor cleared
## to a fresh `❯`, and the line recallable with the history keys. Before
## the fix the cdModal path swallowed the echo, kept the typed text live
## in the editor (one Enter away from an accidental resubmit), and left
## the command unreachable from history.
##
## Expected layout after the bail-out settles:
##   ❯ :provider update chatpgt
##   <blank>
##   unknown provider: chatpgt
##   <blank>
##   ❯                       <- fresh, empty prompt
##
## Buggy layout: the typed row erased to blank, the error one row high,
## and `❯ :provider update chatpgt` still live in the editor below.

import std/[os, strutils, sequtils, unittest]
import tty_expect
import stub_helpers

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

proc stubEnv(root: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
  ]

proc rowIndex(rows: seq[string]; exact: string): int =
  ## First row whose visible text equals `exact` (whitespace-insensitive).
  for i, row in rows:
    if row.strip() == exact: return i
  return -1

const Command = ":provider update chatpgt"

suite "provider pre-wizard bailout commits as an ordinary command":
  test "unknown provider error echoes, clears the editor, recalls from history":
    let root = newFixture("provider_bailout_echo")
    writeConfiguredProvider(root)
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root),
                            keepHistory = true)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    # Idle prompt is up.
    tty.expect "❯"

    # Type the doomed command, then submit.
    tty.send Command
    tty.expectTypedAtPrompt Command
    tty.frames.setLen(0)
    tty.send "\n"
    tty.expect "unknown provider: chatpgt"
    tty.drain(400)

    # The echo row committed exactly once, never erased-and-redrawn.
    tty.expectRowAppearsOnce "❯ " & Command

    # Layout: echo, blank, error, blank, fresh empty prompt. No stranded
    # blank where the typed line was (the modal greeting newline must be
    # consumed by the commit's walk-up, not left as scrollback), and no
    # live `❯ <command>` editor row below the error (the old bug kept the
    # typed text in the editor, invisible to the history keys).
    let rows = tty.rows()
    let echoIdx = rows.rowIndex("❯ " & Command)
    check echoIdx > 0
    check rows[echoIdx + 1].strip() == ""
    check rows[echoIdx + 2].strip() == "unknown provider: chatpgt"
    check rows[echoIdx + 3].strip() == ""
    check rows[^1].strip() == "❯"
    for i in echoIdx + 1 ..< rows.len:
      check rows[i].strip() != "❯ " & Command

    # The command must be repeatable through the normal history keys,
    # which only works if the editor cleared on submit.
    tty.send "\x1b[A"
    tty.expectTypedAtPrompt Command
    tty.expectAlive()

    # And the recalled line still executes.
    tty.send "\n"
    tty.expect "unknown provider: chatpgt"
    tty.drain(400)
    tty.expectAlive()
