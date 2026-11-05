discard """
  disabled: "win"
  ## posix-only: the ask gate's one-key answers are diverted from the
  ## input thread on a real tty. The stub binary normally skips sandbox
  ## init (REPL tests want the pre-sandbox timing); THREECODE_STUB_
  ## SANDBOX=1 opts this suite back in so the ask rules are enforced
  ## for real. `:! CMD` rides the same runBashWithViewport ask gate a
  ## model bash call takes, without stubbing the model turn.
"""
import std/[os, posix, strutils, times, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" /
    ("sandbox_ask_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run" / "vault")
  createDir(result / "run" / "locked")
  writeFile(result / "run" / ".sandbox",
    "deny /\nallow ./\nask ./vault\ndeny ./locked\n")

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

proc askEnv(root: string; askTimeoutMs: int): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_SANDBOX", val: "1"),
    (key: "THREECODE_ASK_TIMEOUT_MS", val: $askTimeoutMs),
  ]

proc startAskSession(root: string; askTimeoutMs: int): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = askEnv(root, askTimeoutMs), keepHistory = false)

proc typeText(s: TtySession; text: string) =
  for ch in text:
    s.send($ch)
    s.drain(10)

proc sendAskKey(s: TtySession; key: char) =
  ## The ask gate consumes the byte before the editor sees it, so there
  ## is no echo; write it raw like a control chord.
  var buf: array[1, char] = [key]
  discard posix.write(s.masterFd, addr buf[0], 1)
  s.drain(30)

proc runShellCmd(s: TtySession; cmd: string) =
  s.typeText ":! " & cmd
  s.send "\n"
  s.drain(200)

proc waitForFileContent(path, want: string; timeoutMs = 10_000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if fileExists(path):
      try:
        if readFile(path) == want: return true
      except CatchableError: discard
    sleep(50)
  false

suite "sandbox ask prompt":
  test "f allows the ask root and the retry lands":
    let root = newFixture("allow")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, "echo granted > vault/out.txt")

    tty.expectInHistory "sandbox ask:"
    tty.expectInHistory "is ask-protected"
    tty.expectInHistory "[n]o"

    tty.sendAskKey 'f'
    tty.expectInHistory "allowed ./vault - retrying"
    check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
    tty.expectInHistory "[sandbox ask: user allowed ./vault; command retried]"
    tty.expect "\u276f"
    echo "  PASS: f allows and retries"

  test "n keeps the denial, no retry":
    let root = newFixture("deny")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, "echo nope > vault/out.txt")

    tty.expectInHistory "sandbox ask:"
    tty.sendAskKey 'n'
    tty.expectInHistory "declined by user; not retried"
    tty.drain(500)
    check not fileExists(root / "run" / "vault" / "out.txt")
    tty.expect "\u276f"
    echo "  PASS: n declines"

  test "timeout keeps the denial":
    let root = newFixture("timeout")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 300)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, "echo late > vault/out.txt")

    tty.expectInHistory "sandbox ask:"
    tty.expectInHistory "no answer before timeout; not retried", 10_000
    tty.drain(300)
    check not fileExists(root / "run" / "vault" / "out.txt")
    tty.expect "\u276f"
    echo "  PASS: timeout declines"

  test "hard deny never asks":
    let root = newFixture("harddeny")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, "echo x > locked/out.txt")

    tty.expectInHistory "Permission denied"
    tty.expectNo "sandbox ask:"
    tty.drain(300)
    check not fileExists(root / "run" / "locked" / "out.txt")
    tty.expect "\u276f"
    echo "  PASS: hard deny asks nothing"
