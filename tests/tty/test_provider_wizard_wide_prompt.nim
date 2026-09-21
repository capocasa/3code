discard """
  disabled: "win"
"""
## Regression: `:provider edit` on a provider whose model list makes the
## `models [...]` prompt wider than the terminal used to duplicate that
## prompt on every keystroke — each keypress repainted the entry line one
## wrapped-prompt-block too low, leaving an expanding stack of stale
## copies above the live one (reported against the chatgpt signup flow,
## whose 24-model prompt spans ~250 cols).
##
## Root cause: `minline` counted the prompt as a fixed column offset
## (`promptW`) on row 0, but the prompt bytes wrap physically over
## `promptW div width` full rows before the buffer text begins. The
## model under-counted those rows, so every redraw walked up too few
## rows and painted a fresh block below the stale one.
import std/[os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "run")

# The chatgpt signup flow's model roster: enough short ids that the
# `  models [...]  : ` prompt spans ~250 cols, past every common width.
const ManyModels = "gpt-oss-120b gpt-oss-20b o1 o1-mini o3 o3-mini " &
  "o4-mini gpt-4.1 gpt-4.1-mini gpt-4.1-nano gpt-4o gpt-4o-mini gpt-5 " &
  "gpt-5-mini gpt-5-nano gpt-5.4 gpt-5.4-mini gpt-5.4-nano gpt-5.5 " &
  "gpt-5.5-pro gpt-5.6 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna"

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config",
    "[settings]\n" &
    "current = \"stub.gpt-5.6-luna\"\n\n" &
    "[provider]\n" &
    "name = \"stub\"\n" &
    "url = \"stub://provider\"\n" &
    "key = \"stub\"\n" &
    "family = \"glm\"\n" &
    "models = \"" & ManyModels & "\"\n")

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

suite "provider wizard wrapped prompt":
  test "typing under a prompt wider than the terminal does not duplicate it":
    let root = newFixture("wizard_wide_prompt_dup")
    writeConfiguredProvider(root)
    let tty = startTty(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send ":provider edit stub"
    tty.send "\r"
    tty.expect "name [stub]"
    tty.send "\r"            # keep name
    tty.expect "url ["
    tty.send "\r"            # keep url
    tty.expect "api key [keep existing]"
    tty.send "\r"            # keep key
    tty.drain(400)
    # The models prompt with the full roster is wider than 120 cols; it
    # wraps over several physical rows. Type per keystroke like a user.
    for ch in "xyz":
      tty.send $ch
      tty.drain(150)
    tty.drain(300)

    let screen = tty.screenText()
    # Exactly one live entry line; pre-fix each keystroke stacked another
    # wrapped `models [...]` block above it.
    check screen.countRowsContaining("models [") == 1
    # The closing bracket keeps the header's `model gpt-5.6-luna` status
    # row out of the count; only the wrapped roster's tail row matches.
    check countRowsContaining(screen, "gpt-5.6-luna]") == 1
    check "xyz" in screen.replace("\r", "")

    # Leave the wizard cleanly and prove the app still works.
    tty.send "\x03"
    tty.drain(200)
    tty.send "\x03"
    tty.drain(300)
    tty.expect "❯"
    tty.send ":q\r"
    tty.expectExit(0, timeoutMs = 5000)

    echo "  PASS: wide wizard prompt does not duplicate while typing"
