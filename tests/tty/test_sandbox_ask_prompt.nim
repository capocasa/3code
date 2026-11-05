discard """
  ## The ask gate's one-key answers are diverted from the input thread
  ## on a real tty (posix PTY or Windows ConPTY). The stub binary
  ## normally skips sandbox init (REPL tests want the pre-sandbox
  ## timing); THREECODE_STUB_SANDBOX=1 opts this suite back in so the
  ## ask rules are enforced for real. `:! CMD` rides the same
  ## runBashWithViewport ask gate a model bash call takes, without
  ## stubbing the model turn; the write-tool tests pin the file-tool
  ## dispatch hook with a stubbed one-write model turn. The bash legs
  ## need kernel enforcement of bash children, so they probe the
  ## backend once and skip where it is absent (Windows CI has no
  ## sandwall fence; a proven host runs them for real); the tool legs
  ## are policy-driven in-process and run everywhere.
"""
import std/[json, os, osproc, strutils, times, unittest]
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

proc askEnv(root: string; askTimeoutMs: int; responses = ""): seq[EnvVar] =
  createDir(root / "tmp")
  result = @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_SANDBOX", val: "1"),
    (key: "THREECODE_ASK_TIMEOUT_MS", val: $askTimeoutMs),
  ]
  if responses.len > 0:
    result.add (key: "THREECODE_STUB_RESPONSES", val: responses)

proc writeTurnResponses(root: string; path, body: string) =
  ## A one-write model turn: the first stub response issues the write
  ## tool call, the second ends the turn with plain content.
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": "", "tool_calls": [{
      "id": "call_1", "type": "function",
      "function": {"name": "write",
                   "arguments": $(%*{"path": path, "body": body})}}]},
    {"content": "saved"}
  ]))

proc writeApplyPatchResponses(root: string; body: string) =
  ## A one-apply_patch model turn: the first stub response issues the
  ## apply_patch tool call (the glm family aliases it to akApplyPatch,
  ## the same dispatch a gpt-oss profile uses), the second ends the
  ## turn with plain content.
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"content": "", "tool_calls": [{
      "id": "call_1", "type": "function",
      "function": {"name": "apply_patch",
                   "arguments": $(%*{"input": body})}}]},
    {"content": "saved"}
  ]))

proc startAskSession(root: string; askTimeoutMs: int;
                      tmpDir = ""; responses = ""): TtySession =
  var env = askEnv(root, askTimeoutMs, responses)
  if tmpDir.len > 0:
    for i in 0 ..< env.len:
      if env[i].key == "TMPDIR": env[i].val = tmpDir
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = env, keepHistory = false)

proc typeText(s: TtySession; text: string) =
  for ch in text:
    s.send($ch)
    s.drain(10)

proc sendAskKey(s: TtySession; key: char) =
  ## The ask gate consumes the byte before the editor sees it, so there
  ## is no echo; send exactly one byte, no newline.
  s.send($key)
  s.drain(30)

var bashBackendCache = -1

proc bashSandboxWorks(): bool =
  ## Whether the ask enforcement the bash legs depend on actually bites
  ## on this host: their denial comes from the policy's ask rule, which
  ## on posix is a user-namespace mount mask over the ask subtree - and
  ## hosts without unprivileged userns (CI containers, hardened boxes)
  ## print a warning and continue WITHOUT sub-path deny enforcement, so
  ## the write succeeds and the legs would fail on the missing EACCES
  ## instead of skipping. The probe therefore reproduces the legs'
  ## exact dependency: a policy-driven restrict with an ask rule, a
  ## write into the ask dir, and a denial in the output. Mirrors the
  ## probe pattern of the `box` suite in test_cli_args.
  if bashBackendCache >= 0: return bashBackendCache == 1
  let tmp = getTempDir() / ("ask_backend_" & $getCurrentProcessId())
  try: removeDir(tmp) except CatchableError: discard
  createDir(tmp / "vault")
  writeFile(tmp / ".sandbox", "deny /\nallow ./\nask ./vault\n")
  let probe = tmp / "vault" / "confine_probe_out"
  when defined(windows):
    let cmd = "cmd /c echo x > " & probe.quoteShell
  else:
    let cmd = "sh -c " & ("echo x > " & probe).quoteShell
  let quoted = "\"" & ensureStubBinary() & "\" sandbox --policy " &
    (tmp / ".sandbox").quoteShell & " restrict -- " & cmd
  try:
    let r = execCmdEx(quoted)
    # "denied" separates a real confinement denial (posix "Permission
    # denied"/"Operation not permitted", windows "Access is denied")
    # from a restrict that failed to launch the child at all.
    bashBackendCache =
      if r.exitCode != 0 and not fileExists(probe) and
          "denied" in r.output.toLowerAscii: 1 else: 0
  except CatchableError:
    bashBackendCache = 0
  try: removeDir(tmp) except CatchableError: discard
  bashBackendCache == 1

proc runShellCmd(s: TtySession; cmd: string) =
  s.typeText ":! " & cmd
  s.send "\n"
  s.drain(200)

proc waitForSessionText(root, want: string; timeoutMs = 10_000): bool =
  ## Wait until the saved session records `want`. Write tool items paint
  ## only the diff on screen, so the model-visible ask marker and denial
  ## must be asserted where they actually land: the tool message content.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    for f in walkFiles(root / "data" / "3code" / "sessions" / "*.3log"):
      try:
        if want in readFile(f): return true
      except CatchableError: discard
    sleep(50)
  false

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
    if bashSandboxWorks():
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

    else:
      skip()
  test "n keeps the denial, no retry":
    if bashSandboxWorks():
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

    else:
      skip()
  test "timeout keeps the denial":
    if bashSandboxWorks():
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

    else:
      skip()
  when defined(posix):
    test "f grant works with the network wall active (host rule in policy)":
      if bashSandboxWorks():
        let root = newFixture("fenced")
        defer: removeDir(root)
        writeConfiguredProvider(root)
        # A host rule turns on the network wall (per-run proxy): the exact
        # configuration whose ask grant crashed before the sync guard (the
        # proxy policy file lived under the deleted per-run bash dir).
        let sf = root / "run" / ".sandbox"
        writeFile(sf, readFile(sf) & "deny evil.example\n")
        # The wall proxy binds an AF_UNIX socket under TMPDIR; the fixture's
        # deep tests/testdata path overflows sockaddr_un's 108 bytes, so the
        # fenced launch dies before any denial. A short /tmp TMPDIR keeps the
        # socket path legal.
        let shortTmp = getTempDir() / ("3code_askfence_" & $getCurrentProcessId())
        if dirExists(shortTmp): removeDir(shortTmp)
        createDir(shortTmp)
        let tty = startAskSession(root, 20_000, shortTmp)
        defer: tty.close()

        tty.expect "\u276f"
        runShellCmd(tty, "echo granted > vault/fenced.txt")

        tty.expectInHistory "sandbox ask:", 30_000
        tty.sendAskKey 'f'
        tty.expectInHistory "allowed ./vault - retrying", 30_000
        check waitForFileContent(root / "run" / "vault" / "fenced.txt", "granted\n")
        tty.expect "\u276f"
        echo "  PASS: f grant under the network wall"
      else:
        skip()

  test "model write tool asks; f grants and the write lands":
    let root = newFixture("tool_allow")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeTurnResponses(root, "vault/out.txt", "granted\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "save it\n"
    tty.expectInHistory "sandbox ask:", 30_000
    tty.expectInHistory "is ask-protected"
    tty.expectInHistory "[n]o"

    tty.sendAskKey 'f'
    tty.expectInHistory "allowed ./vault - retrying", 10_000
    check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
    check waitForSessionText(root,
      "[sandbox ask: user allowed ./vault; tool retried]")
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: write tool f grants and retries"

  test "model write tool asks; n keeps the denial":
    let root = newFixture("tool_deny")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeTurnResponses(root, "vault/out.txt", "nope\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "save it\n"
    tty.expectInHistory "sandbox ask:", 30_000
    tty.sendAskKey 'n'
    tty.expectInHistory "declined by user; not retried", 10_000
    check waitForSessionText(root, "is denied by the policy")
    check waitForSessionText(root,
      "[sandbox ask: declined by user; not retried]")
    tty.drain(300)
    check not fileExists(root / "run" / "vault" / "out.txt")
    tty.expect "\u276f"
    echo "  PASS: write tool n declines"

  test "model apply_patch asks; f grants and the add lands":
    let root = newFixture("tool_apply_allow")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeApplyPatchResponses(root, "*** Begin Patch\n" &
      "*** Add File: vault/ap.txt\n+granted\n*** End Patch\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "patch it\n"
    tty.expectInHistory "sandbox ask:", 30_000
    tty.expectInHistory "is ask-protected"
    tty.expectInHistory "[n]o"

    tty.sendAskKey 'f'
    tty.expectInHistory "allowed ./vault - retrying", 10_000
    check waitForFileContent(root / "run" / "vault" / "ap.txt", "granted\n")
    check waitForSessionText(root,
      "[sandbox ask: user allowed ./vault; tool retried]")
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: apply_patch f grants and the add lands"

  test "model apply_patch mixed ops; n denies only the ask root":
    let root = newFixture("tool_apply_deny")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeApplyPatchResponses(root, "*** Begin Patch\n" &
      "*** Add File: vault/ap_a.txt\n+nope\n" &
      "*** Add File: open_b.txt\n+yes\n*** End Patch\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "patch it\n"
    tty.expectInHistory "sandbox ask:", 30_000
    tty.sendAskKey 'n'
    tty.expectInHistory "declined by user; not retried", 10_000
    check waitForFileContent(root / "run" / "open_b.txt", "yes\n")
    tty.drain(300)
    check not fileExists(root / "run" / "vault" / "ap_a.txt")
    check waitForSessionText(root, "vault/ap_a.txt")
    check waitForSessionText(root, "is denied by the policy")
    check waitForSessionText(root,
      "[sandbox ask: declined by user; not retried]")
    tty.expect "\u276f"
    echo "  PASS: apply_patch n denies only the ask root"

  test "model apply_patch two ask roots ask sequentially":
    let root = newFixture("tool_apply_multi")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    createDir(root / "run" / "vault2")
    let sf = root / "run" / ".sandbox"
    writeFile(sf, readFile(sf) & "ask ./vault2\n")
    writeApplyPatchResponses(root, "*** Begin Patch\n" &
      "*** Add File: vault/ap1.txt\n+one\n" &
      "*** Add File: vault2/ap2.txt\n+two\n*** End Patch\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "patch it\n"
    tty.expectInHistory "vault/ap1.txt is ask-protected", 30_000
    tty.sendAskKey 'f'
    tty.expectInHistory "allowed ./vault - retrying", 10_000
    tty.expectInHistory "vault2/ap2.txt is ask-protected", 10_000
    tty.sendAskKey 'n'
    tty.expectInHistory "declined by user; not retried", 10_000
    check waitForFileContent(root / "run" / "vault" / "ap1.txt", "one\n")
    tty.drain(300)
    check not fileExists(root / "run" / "vault2" / "ap2.txt")
    check waitForSessionText(root,
      "[sandbox ask: user allowed ./vault; tool retried]")
    check waitForSessionText(root,
      "[sandbox ask: declined by user; not retried]")
    tty.expect "\u276f"
    echo "  PASS: apply_patch two roots ask sequentially"

  test "hard deny never asks":
    if bashSandboxWorks():
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

    else:
      skip()