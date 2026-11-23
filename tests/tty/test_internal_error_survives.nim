discard """
  disabled: "win"
  ## PTY timing per the tty category's POSIX-only convention; the release
  ## net's survival contract is what is under test, and debug builds
  ## deliberately re-raise for developers.
"""
## Regression: an unexpected internal exception mid-turn must not end the
## program. The release-build last-resort net in `runTurnsInteractive`
## used to `quit()` on any `CatchableError` that escaped the turn loop
## (the turn-loop itself only catches `ApiError`), so one bad turn — say,
## a crash while committing a tool result built from child output — took
## 3code down. The fix saves the session, reports the failed turn on
## stderr, and returns to the prompt.
##
## The stub's `{"crash": "..."}` response shape raises a plain
## `ValueError` out of the transport: neither an ApiError (retry/steer
## paths) nor an interrupt, so it lands in exactly that net. The test
## asserts the process survives the failed turn, the notice is on
## screen, and the very next prompt runs a normal turn.
import std/[json, os, strutils, unittest]
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

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "test.stub_responses", val: responsesPath),
  ]

proc sendLine(tty: TtySession; text: string) =
  for ch in text:
    tty.send($ch)
    tty.drain(10)
  tty.send "\n"

suite "internal error mid-turn survives":
  test "turn loop exception reports, saves, and returns to the prompt":
    let root = newFixture("internal_error_survives")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"crash": "boom from the stub"},
      {"role": "assistant", "content": "recovered.",
       "contentChunks": ["recovered."]}
    ]))
    # Release build: debug binaries re-raise in the last-resort net on
    # purpose (developer visibility), so the survival contract is only
    # observable on the release path users actually run.
    let stub = ensureStubBinary("-d:release")
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"),
                            keepHistory = false)
    defer: tty.close()

    tty.expect "\u276f"
    sendLine(tty, "crash the turn")
    tty.expect "internal error during turn"
    tty.expect "boom from the stub"
    # The program is still up and the prompt came back.
    tty.expectAlive()
    tty.drain(300)
    tty.expect "\u276f"

    # The next turn runs normally on the saved session.
    sendLine(tty, "and now recover")
    tty.expectInHistory "recovered."
    tty.drain(300)
    tty.expect "\u276f"
    tty.expectAlive()
    tty.close()
