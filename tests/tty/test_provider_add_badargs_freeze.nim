## Regression: `:provider add foo bar` (a modal-classified command that
## bails out on a usage error before any wizard runs) must not freeze the input
## thread. `classifyCommand` returns ckModal for `:provider add`, so the
## controller takes the cdModal path and on the way out calls
## `wizardFinish()`, which clears `inputModalActive`. But the input thread's
## onSubmit had already parked on `inputIdleLinePending` when the Enter was
## queued; nothing in the usage-error path runs `wizardReadLine`, so that
## flag was never cleared. The main thread idle-polls readInput forever and
## the input thread stays parked in getCh on the stale flag: frozen prompt,
## only exit is kill -9. The fix clears `inputIdleLinePending` inside
## `wizardFinish()` so every cdModal exit unparks the prompt.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

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

proc stubEnv(root: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
  ]

suite "provider add bad-args freeze regression":
  test ":provider add <extra-arg> leaves the editor responsive":
    let root = newFixture("provider_add_badargs_freeze")
    writeConfiguredProvider(root)
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root),
                            keepHistory = true)
    defer:
      tty.close()

    # Idle prompt is up.
    tty.expect "\u276f"

    # Submit a modal-classified command that bails out before the wizard
    # (`:provider add` takes at most one entry argument since the wizard
    # learned to prefill its first field from the command line).
    for ch in ":provider add foo bar":
      tty.send($ch)
      tty.drain(10)
    tty.send "\n"

    # Usage error must be printed.
    tty.expect "usage: :provider add"

    # Wait for the cdModal path to release, then confirm the prompt repainted.
    tty.drain(300)
    tty.expect "\u276f"

    # The real regression: typing must still work. Before the fix the input
    # thread was parked on inputIdleLinePending and never unparked, so this
    # text never reached the cursor row.
    tty.send "again"
    tty.expectTypedAtPrompt "again"

    # Idle Ctrl-C must clear the draft (not quit, not wedge). The
    # interrupt path owns the in-place repaint on the same live editor.
    tty.send "\x03"
    tty.drain(300)
    tty.expectAlive()
    tty.expectIdleCaret()

    # Process must still be alive (not exited, not hung in a sleep loop).
    tty.expectAlive()

    echo "  PASS: :provider add <extra-arg> did not freeze the editor"
