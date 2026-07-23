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
## Stress test: repeatedly enter `:provider edit`, accept defaults,
## Ctrl-C on the api-key prompt, then issue a non-modal `:show`
## command. If the wizard RPC (`wizardReadLine` in
## `src/threecode/fatprompt/runtime.nim`) ever leaves the input
## thread in a bad state (e.g. `inputModalActive` stuck true,
## `inputIdleLinePending` stuck true, or `wizardRequestPosted`
## stuck true), the second iteration's `:provider edit stub\r`
## will fail to enter the wizard.
##
## The four subtests in `test_provider_wizard_cancel.nim` cover
## single-cancel + double-cancel; this test is the regression
## barrier against any future refactor that breaks the
## idle <-> modal <-> idle state transitions under load.
import std/[os, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
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

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
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

suite "provider wizard cancel stress":
  const iterations = 20

  test "20x (wizard entry, accept defaults, cancel, :show) keeps the input thread clean":
    let root = newFixture("wizard_cancel_stress")
    writeConfiguredProvider(root)
    let tty = startTty(root)
    defer: tty.close()

    tty.expect "\u276f"

    for i in 1 .. iterations:
      # Enter the wizard.
      tty.send ":provider edit stub"
      tty.send "\r"
      tty.drain(200)
      tty.expect "name [stub]"

      # Accept the default name.
      tty.send "\r"
      tty.expect "url ["
      tty.send "\r"
      tty.expect "api key [keep existing]"

      # Cancel on the api-key prompt. Pre-fix this would leave
      # the cursor on `api key [keep existing] :` and the next
      # iteration's `:provider edit` would either fail to enter
      # the wizard (if the input thread was wedged) or enter it
      # twice (if the queue / flags were corrupted).
      tty.send "\x03"
      tty.drain(300)
      tty.expect "\u276f"

      # Issue a non-modal command between cancels. `:show` on an
      # empty tool log produces a single `no tool calls yet` line,
      # which the main loop commits to the transcript. This
      # exercises the same hook call sites the wizard branches
      # touch (postRedraw, onSubmit, completionCallback) without
      # any modal state.
      tty.send ":show"
      tty.send "\r"
      tty.drain(300)
      tty.expect "no tool calls yet"
      tty.expect "\u276f"

    # Final clean exit. A SIGSEGV anywhere in the loop would
    # have killed the process with a non-zero status; a clean
    # exit code 0 proves the input thread survived all 20
    # iterations of the wizard -> cancel -> non-modal cycle.
    tty.send ":q"
    tty.send "\r"
    tty.drain(300)
    tty.expectExit(0, timeoutMs = 5000)

    echo "  PASS: " & $iterations & "x (wizard -> cancel -> :show) cycles did not wedge the input thread"