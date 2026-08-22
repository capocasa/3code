import std/[os, strutils, times, unittest]
import tty_expect
import stub_helpers

const VisualOutputRoot = "testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
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

proc startStub(root: string; cols = 80; rows = 24): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                cols = cols, rows = rows)

suite "startup: stray up-arrow must not surface history":
  test "Up pressed during startup leaves the prompt empty":
    # Bug report: the last history item sometimes appears in the prompt on
    # startup. Reproduction path: the user presses Up while the app is
    # still booting (before the first prompt is fully painted); the
    # buffered `ESC [ A` then reaches the first readLineWith, whose
    # historyPrevious pulls entries[^1] into the editor. The prompt must
    # stay empty regardless: arrow keys before the first keystroke are
    # input noise, not a history navigation request.
    let root = newFixture("startup_up_arrow")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", "[]")
    # Seed a history file with a distinctive last entry.
    createDir(root / "data" / "3code")
    writeFile(root / "data" / "3code" / "history", "old prompt one\nSTALE-HISTORY-MARKER")
    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()
    # Fire the Up arrow immediately, racing the startup sequence; then
    # give the prompt time to settle.
    tty.send "\x1b[A"
    tty.expect "❯"
    tty.drain(400)
    # The marker must never reach the live grid (screen) as prompt text.
    check "STALE-HISTORY-MARKER" notin tty.screenText()
    tty.expectAlive()
    # The editor must still be usable: typing echoes and submits normally.
    tty.send "fresh prompt"
    tty.expect "fresh prompt"
    tty.expectAlive()
