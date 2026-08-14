discard """
  disabled: "win"
"""
## Regression: inside the `:provider` wizard, a terminal resize followed by
## typing used to duplicate the wizard's prompt line on every keystroke —
## each keypress repainted `models [...]  : ...` one row higher, leaving an
## expanding stack of clones above the live entry line.
##
## Root cause: after a resize the terminal reflows the wizard's long
## wrapped prompt line into more screen rows than the editor's tracked
## `renderRow`, so the redraw's relative cursor-up walk lands in scrollback
## and the erase+repaint pushes a fresh copy below each time. The idle
## prompt survives the same resize because its short `❯` line never wraps.
import std/[os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "run")

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
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
  ]

proc startTty(root: string): TtySession =
  let stub = ensureStubBinary()
  newTtySession(stub,
                args = ["-x", "-i"],
                cwd = root / "run",
                env = stubEnv(root),
                keepHistory = false)

proc countRowsContaining(screen, needle: string): int =
  for row in screen.splitLines():
    if needle in row: inc result

suite "provider wizard resize":
  test "resize during wizard edit does not duplicate the entry line":
    let root = newFixture("wizard_resize_dup")
    writeConfiguredProvider(root)
    let tty = startTty(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    # Edit flow reaches the models field with a long prefilled prompt that
    # wraps at 80 cols.
    tty.send ":provider edit stub"
    tty.send "\r"
    tty.expect "name [stub]"
    tty.send "\r"            # keep name
    tty.expect "api key"
    tty.send "\r"            # keep key
    tty.expect "models [stub-model]"

    # Narrow the terminal: the wrapped models prompt reflows.
    tty.resize(40, 24)
    tty.drain(300)

    # Type after the resize: each keystroke must repaint the single entry
    # line in place, not stack a new copy above it.
    tty.send "x"
    tty.drain(150)
    tty.send "y"
    tty.drain(150)
    tty.send "z"
    tty.drain(300)

    let screen = tty.screenText()
    check screen.countRowsContaining("models [stub-model]") <= 2
    check "models [stub-model]  : xyz" in screen.replace("\r", "")

    # Leave the wizard cleanly: ctrl+c, then :q must still work.
    tty.send "\x03"
    tty.drain(300)
    tty.expect "❯"
    tty.send ":q\r"
    tty.expectExit(0, timeoutMs = 5000)

    echo "  PASS: wizard resize does not duplicate the entry line"
