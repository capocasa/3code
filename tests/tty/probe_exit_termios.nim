## Interactive repro scratchpad for the exit-termios audit (goal item 1).
## The regression coverage now lives in test_quit_signals.nim's "abnormal
## exit restores the terminal" suite (:q, SIGTERM/SIGHUP mid-turn, SIGSEGV/
## SIGABRT crash exits). This probe keeps the two shapes that suite does
## not cover: SIGTERM while a streamed :! tool runs (tool cancel watcher
## active) and SIGTERM while Ctrl-Z-suspended. Both restored echo+icanon
## when last driven; rerun here if a new report names either shape.
import std/[os, termios]
import posix
import tty_expect, stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" /
    (name & "_" & $getCurrentProcessId())
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
    (key: "THREECODE_STUB_RESPONSES", val: root / "run" / "stub_responses.json"),
  ]

proc startStub(root: string): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root))

proc echoState(s: TtySession): string =
  var t: Termios
  if tcgetattr(s.masterFd.cint, addr t) != 0:
    return "tcgetattr failed: " & $errno
  let echo = (t.c_lflag and ECHO) != 0
  let canon = (t.c_lflag and ICANON) != 0
  if echo and canon: "echo+icanon"
  elif not echo: "NO-ECHO (bug)"
  else: "flags echo=" & $echo & " icanon=" & $canon

proc report(name: string; tty: TtySession) =
  tty.drain(1500)
  echo name, ": exited=", tty.exited, " code=", tty.exitCode,
    " tty=", echoState(tty)

let root = newFixture("exit_termios_probe")
writeConfiguredProvider(root)

let tool = startStub(root)
tool.expect "\u276f"
tool.send ":! sleep 10\n"
tool.drain(1000)
discard posix.kill(tool.pid, posix.SIGTERM)
report("SIGTERM during :! tool", tool)
tool.close()

let stopped = startStub(root)
stopped.expect "\u276f"
stopped.send "\x1a"                    # Ctrl-Z: requestBackground
stopped.drain(800)
discard posix.kill(stopped.pid, posix.SIGTERM)
report("SIGTERM while stopped", stopped)
stopped.close()
