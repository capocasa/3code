discard """
  # See docs/windows-testing.md. The tty_expect harness uses openpty/fork/
  # execv (POSIX only). A ConPTY port is the path to re-enable on Windows.
  disabled: "win"
  # On macOS the harness compiles but hangs deterministically: the expect*
  # procs poll on wall-clock deadlines (plan-flakiness.md) and starve under
  # the OSX runner's scheduler, so a subtest never returns. Re-enable after
  # the frame-event sync rewrite lands.
  disabled: "osx"
"""
## Regression: a first run with no config file crashes with
## `Error: unhandled exception: input thread stopped [IOError]` the
## moment the bootstrap provider wizard tries to read the api key.
##
## Root cause: `main()` set the module-global `inputEditor` pointer
## *after* calling `bootstrapProvider`. The wizard's `wizardReadLine`
## calls `ensureInputThreadStarted`, whose guard is
## `if inputEditor != nil and not inputThreadRunning:` — with
## `inputEditor == nil` the input thread never started, so the wizard's
## response-poll loop immediately saw `inputThreadRunning == false` and
## raised `IOError("input thread stopped")`.
##
## The fix sets `inputEditor` (and the other input-thread pointers)
## before `bootstrapProvider`, so the wizard can drive the real input
## thread on the very first run.
import std/[os, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "run")

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  # Note: NO config file is written under xdg/3code, so the binary
  # falls through to the bootstrap provider wizard on startup.
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

proc startTty(root: string): TtySession =
  let stub = ensureStubBinary()
  result = newTtySession(stub,
                         args = ["-x", "-i"],
                         cwd = root / "run",
                         env = stubEnv(root, ""),
                         keepHistory = false)

suite "no-config bootstrap":
  test "first run with no config enters wizard and accepts a provider":
    let root = newFixture("no_config")
    let tty = startTty(root)
    defer: tty.close()

    # The bootstrap banner must appear, then the wizard's first prompt.
    tty.expect "let's add one"
    tty.expect "api key"

    # Pre-fix this crashed here with "input thread stopped" before the
    # user could type anything. Drive the wizard to completion: the
    # stub key "stub" is detected as the stub provider, which has a
    # single model so the model prompt offers it as the default.
    tty.send "stub"
    tty.send "\r"
    tty.drain(300)
    tty.expect "models"

    # Enter the stub model and submit.
    tty.send "stub-model"
    tty.send "\r"
    tty.drain(300)
    tty.expect "ok"
    tty.expect "saved to"

    # The wizard verifies the profile and writes the config; the main
    # prompt must come up and accept a clean :q exit.
    tty.expect "\u276f"
    tty.send ":q"
    tty.send "\r"
    tty.drain(300)
    tty.expectExit(0, timeoutMs = 5000)

    echo "  PASS: no-config bootstrap wizard completes and reaches prompt"
