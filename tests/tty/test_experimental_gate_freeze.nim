discard """
  # See docs/windows-testing.md. The tty_expect harness uses openpty/fork/
  # execv (POSIX only). A ConPTY port is the path to re-enable on Windows.
  disabled: "win"
  # Hangs deterministically on macOS (wall-clock polling starves under the
  # OSX scheduler; see plan-flakiness.md).
  disabled: "osx"
"""
## Targeted regression: submitting a prompt against a profile that fails the
## experimental gate must not freeze the editor. Before the fix,
## `runTurnsInteractive` checked `gateExperimental` *after* the controller had
## already run `emitUserSubmit`, which parks the input thread on
## `inputIdleLinePending` until the turn starts. A normal turn unparks via
## `beginTurn`; the gate-fail bail-out returned without ever reaching it, so
## the input thread spun forever in `sleep(5)` and no further keystroke was
## echoed. The only exit was kill -9.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeExperimentalProvider(root: string) =
  ## A provider/model pair that is NOT in KnownGoodCombos, so the
  ## experimental gate fires and the turn is refused (no `-x` passed).
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
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

suite "experimental gate freeze regression":
  test "gate refusal leaves the editor responsive":
    let root = newFixture("experimental_gate_freeze")
    writeExperimentalProvider(root)
    let stub = ensureStubBinary()
    # No -x: the (stub, stub-model) combo is not known-good, so the turn is
    # refused by gateExperimental.
    let tty = newTtySession(stub,
                            args = ["-i"],
                            cwd = root / "run",
                            env = stubEnv(root),
                            keepHistory = true)
    defer:
      tty.close()

    # Idle prompt is up.
    tty.expect "\u276f"

    # Submit a prompt against the non-known-good combo.
    for ch in "hello":
      tty.send($ch)
      tty.drain(10)
    tty.send "\n"

    # The experimental gate must refuse the turn with this hint.
    tty.expect "is experimental"

    # The real regression: the editor must still accept typing. Before the
    # fix the input thread was parked on inputIdleLinePending and never
    # unparked, so this text never appeared on the cursor row.
    tty.send "again"
    tty.expectTypedAtPrompt "again"

    # Process must still be alive (not exited, not hung in a sleep loop).
    tty.expectAlive()

    echo "  PASS: experimental gate refusal did not freeze the editor"
