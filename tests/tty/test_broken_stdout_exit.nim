discard """
  # This test reproduces a broken-stdout pipe via bash + python3 and asserts
  # on the POSIX broken-pipe exit semantics. It does not use the ConPTY
  # harness (it drives the binary through execCmdEx + a bash pipeline whose
  # reader is python3). python3 is not guaranteed on the Windows runner and
  # the pipe-break + pipefail contract is POSIX-specific, so it stays
  # disabled on Windows pending a Windows-native broken-conpty reproduction.
  disabled: "win"
"""
## Regression for the "3code silently exits mid-turn" bug.
##
## Root cause: when the process's stdout becomes unwritable mid-turn
## (closed pipe, ssh disconnect, terminal hang-up, broken tty), the next
## stdout write inside the turn loop raised `IOError(EBADF)`/`IOError(EPIPE)`.
## `runTurnsInteractive` only caught `ApiError` and `OSError`, so the
## `IOError` propagated out of `main` and killed the process with no message
## and no graceful prompt restore — exactly the "3code just exits during a
## turn" report.
##
## Fix (commit 2440e75): `runTurnsInteractive` and `main` now catch
## `IOError` (and a `CatchableError` safety net) and report the condition on
## stderr instead of dying silently.
##
## This test reproduces the failure deterministically without a PTY: it
## runs the stub binary once-shot against a stub provider whose response
## streams many small content chunks, and pipes stdout to a reader that
## takes the first few KB then exits. The next stdout write inside the turn
## loop then hits the closed pipe. Before the fix the process crashed with
## an unhandled `IOError` (no friendly message); after the fix it exits 0
## and prints "3code: output stream broken (...)".

import std/[json, os, osproc, strutils, strtabs, times, unittest]
import stub_helpers, tty_expect

const StubResponses = """
[
  {
    "content": "STORY",
    "contentChunks": [
      "AAAA", "BBBB", "CCCC", "DDDD", "EEEE", "FFFF", "GGGG", "HHHH",
      "IIII", "JJJJ", "KKKK", "LLLL", "MMMM", "NNNN", "OOOO", "PPPP",
      "QQQQ", "RRRR", "SSSS", "TTTT", "UUUU", "VVVV", "WWWW", "XXXX",
      "YYYY", "ZZZZ", "1111", "2222", "3333", "4444", "5555", "6666",
      "7777", "8888", "9999", "0000"
    ]
  }
]
"""

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")
  createDir(result / "xdg" / "3code")
  writeFile(result / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")
  writeFile(result / "data" / "stub_responses.json", StubResponses)

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

let stubBin = ensureStubBinary()

suite "silent exit on broken stdout mid-turn":
  test "process exits cleanly (not a crash) when stdout breaks mid-turn":
    let root = newFixture("broken_stdout_exit")
    let responsesPath = root / "data" / "stub_responses.json"
    # Reader takes the first few KB of streamed output then exits, breaking
    # the pipe so the next stdout write inside the turn raises IOError.
    let reader = "python3 -c 'import sys; sys.stdin.buffer.read(2048); " &
                 "sys.exit(0)'"
    # pipefail makes the pipeline's exit code reflect 3code's, not the
    # reader's. Before the fix 3code dies with a non-zero (crash) exit; the
    # fix returns 0. Use bash explicitly: dash (the default /bin/sh on many
    # CI images) rejects `set -o pipefail`, which would otherwise make the
    # pipeline fail before 3code even runs. Write the pipeline to a script
    # so the reader's own single quotes can't break the outer quoting.
    let script = root / "run" / "broken_stdout.sh"
    writeFile(script, "set -o pipefail\n" & stubBin.quoteShell &
              " -x tell me a story | " & reader & "\n")
    let cmd = "bash " & script.quoteShell
    let (outp, exitCode) = execCmdEx(
      cmd,
      {poStdErrToStdOut, poUsePath, poDaemon},
      env = stubEnv(root, responsesPath).newStringTable,
      workingDir = root / "run")
    # execCmdEx blocks until the pipeline finishes, so 3code has already hit
    # the broken pipe and exited by now.
    check "3code: output stream broken" in outp
    check not outp.contains("unhandled exception")
    check exitCode == 0
