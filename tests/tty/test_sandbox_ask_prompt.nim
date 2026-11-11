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
  ## is no echo; send exactly one byte, no newline. The pre-send drain
  ## keeps the byte from outrunning the gate arming (the card's last
  ## line paints microseconds before requestAskKey blocks): a key that
  ## lands while the editor still owns stdin would leak into the draft
  ## instead of answering the ask.
  s.drain(80)
  s.send($key)
  s.drain(30)

var bashBackendCache = -1
var restrictBaselineCache = -1

proc restrictBaselineBites(): bool =
  ## Whether the toggle leg's denial bites on this host: it comes from
  ## the restrict baseline (the policy's one writable root is the only
  ## writable path), not from the user-namespace mount masks that
  ## bashSandboxWorks probes — so container hosts without unprivileged
  ## userns still run it. The probe reproduces the leg's exact
  ## dependency: a policy-driven restrict with an ask rule, a write
  ## outside the writable root, and a denial in the output. Mirrors the
  ## probe pattern of bashSandboxWorks.
  if restrictBaselineCache >= 0: return restrictBaselineCache == 1
  let tmp = getTempDir() / ("restrict_baseline_" & $getCurrentProcessId())
  try: removeDir(tmp) except CatchableError: discard
  createDir(tmp / "proj")
  writeFile(tmp / ".sandbox", "deny /\nallow ./\nask ./proj/vault\n")
  let probe = getTempDir() / ("restrict_out_" & $getCurrentProcessId())
  try: removeFile(probe) except CatchableError: discard
  when defined(windows):
    let cmd = "cmd /c echo x > " & probe.quoteShell
  else:
    let cmd = "sh -c " & ("echo x > " & probe).quoteShell
  let quoted = "\"" & ensureStubBinary() & "\" sandbox --policy " &
    (tmp / ".sandbox").quoteShell & " restrict -- " & cmd
  try:
    let r = execCmdEx(quoted)
    restrictBaselineCache =
      if r.exitCode != 0 and not fileExists(probe) and
          "denied" in r.output.toLowerAscii: 1 else: 0
  except CatchableError:
    restrictBaselineCache = 0
  try:
    removeDir(tmp)
    removeFile(probe)
  except CatchableError: discard
  restrictBaselineCache == 1

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

proc policyLines(root: string): seq[string] =
  ## The active repo policy file, line by line: rule order and position
  ## are what the grant semantics are about.
  readFile(root / "run" / ".sandbox").strip.splitLines

proc scriptedDenial(): string =
  ## A bash command that fails with a denial-shaped line naming an
  ## ask-covered path, without needing the kernel backend: the gate
  ## scrapes the error line the same way it scrapes a real EACCES.
  "sh -c \"echo ./vault/out.txt: Permission denied; exit 13\""

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

      tty.expectInHistory "? echo granted > vault/out.txt", 30_000
      tty.expectInHistory "allow write access to ./vault/out.txt?"
      tty.expectInHistory "(a) allow"
      tty.expectInHistory "(f) allow the entire folder"
      tty.expectInHistory "(d) deny in 20s"
      tty.expectNeverInHistory "sandbox ask:"
      tty.expectNeverInHistory "is ask-protected"

      tty.sendAskKey 'f'
      tty.expectInHistory "allowed ./vault - retrying"
      check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
      tty.expectInHistory "[sandbox ask: user allowed ./vault; command retried]"
      # The folder offer flips the ask rule itself: same line position,
      # same neighbors, no stacked duplicate.
      check policyLines(root) ==
        @["deny /", "allow ./", "allow ./vault", "deny ./locked"]
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

      tty.expectInHistory "(d) deny in 20s"
      tty.sendAskKey 'n'
      tty.expectInHistory "declined by user; not retried"
      tty.drain(500)
      check not fileExists(root / "run" / "vault" / "out.txt")
      tty.expect "\u276f"
      echo "  PASS: n declines"

  test "a flips an exact file ask rule in place and the retry lands":
    # The ask rule names the denied file itself: allow is the rule
    # changing, not a new rule, so it takes the ask line's position -
    # and lifts the ask subtree's fence for the retry.
    if bashSandboxWorks():
      let root = newFixture("allow_exact")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      writeFile(root / "run" / ".sandbox",
        "deny /\nallow ./\nask ./vault/out.txt\ndeny ./locked\n")
      let tty = startAskSession(root, 20_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo granted > vault/out.txt")

      tty.expectInHistory "allow write access to ./vault/out.txt?", 30_000
      tty.sendAskKey 'a'
      tty.expectInHistory "allowed ./vault/out.txt - retrying"
      check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
      check policyLines(root) ==
        @["deny /", "allow ./", "allow ./vault/out.txt", "deny ./locked"]
      tty.expect "\u276f"
      echo "  PASS: a flips an exact file ask in place"

    else:
      skip()

  test "a on a folder ask appends the file allow at the end":
    # The ask rule covers more than the denied file: changing it would
    # rewrite a rule the user aimed at other paths, so the allow lands
    # after every existing rule instead (last-match-wins puts it above
    # the ask rule for this file only). Whether the bash retry then
    # lands is backend business (the Linux mount mask survives a
    # subpath allow); this leg pins the policy file shape.
    if bashSandboxWorks():
      let root = newFixture("allow_append")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      let tty = startAskSession(root, 20_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo granted > vault/out.txt")

      tty.expectInHistory "allow write access to ./vault/out.txt?", 30_000
      tty.sendAskKey 'a'
      tty.expectInHistory "allowed ./vault/out.txt - retrying"
      tty.expectInHistory "[sandbox ask: user allowed ./vault/out.txt; command retried]"
      check policyLines(root) ==
        @["deny /", "allow ./", "ask ./vault", "deny ./locked",
          "allow ./vault/out.txt"]
      tty.expect "\u276f"
      echo "  PASS: a appends a non-exact allow"

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

      tty.expectInHistory "(a) allow"
      tty.expectInHistory "no answer before timeout; not retried", 10_000
      tty.drain(300)
      check not fileExists(root / "run" / "vault" / "out.txt")
      tty.expect "\u276f"
      echo "  PASS: timeout declines"

    else:
      skip()

  test "scripted denial shows the card":
    # Runs on every host (no kernel backend needed): the card's shape
    # and the viewport takeover are pure policy and viewport work.
    let root = newFixture("card")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, scriptedDenial())

    tty.expectInHistory "? sh -c \"echo ./vault/out.txt: Permission denied; exit 13\"", 30_000
    tty.expectInHistory "allow read access to ./vault/out.txt?"
    tty.expectInHistory "(f) allow the entire folder"
    tty.expectInHistory "(d) deny in 20s"
    tty.sendAskKey 'd'
    tty.expectInHistory "declined by user; not retried"
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked"]
    tty.expect "\u276f"
    echo "  PASS: scripted denial shows the card"

  test "scripted denial a flips an exact file ask rule in place":
    let root = newFixture("card_exact")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeFile(root / "run" / ".sandbox",
      "deny /\nallow ./\nask ./vault/out.txt\ndeny ./locked\n")
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, scriptedDenial())

    tty.expectInHistory "allow read access to ./vault/out.txt?", 30_000
    tty.sendAskKey 'a'
    tty.expectInHistory "allowed ./vault/out.txt - retrying"
    tty.expectInHistory "[sandbox ask: user allowed ./vault/out.txt; command retried]"
    check policyLines(root) ==
      @["deny /", "allow ./", "allow ./vault/out.txt", "deny ./locked"]
    tty.expect "\u276f"
    echo "  PASS: scripted a flips an exact file ask"

  test "scripted denial a on a folder ask appends at the end":
    let root = newFixture("card_append")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, scriptedDenial())

    tty.expectInHistory "allow read access to ./vault/out.txt?", 30_000
    tty.sendAskKey 'a'
    tty.expectInHistory "[sandbox ask: user allowed ./vault/out.txt; command retried]"
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/out.txt"]
    tty.expect "\u276f"
    echo "  PASS: scripted a appends under a folder ask"
  test ":sandbox off lifts the fence live, :sandbox on restores it":
    # The mid-session toggle is enforcement, not bookkeeping: a write the
    # baseline denies lands cleanly while disarmed and denies again after
    # the re-arm (same session, no restart). The denied target is outside
    # the policy's only writable root, never the ask dir: a live ask gate
    # would sit and wait for a key this test never sends.
    if restrictBaselineBites():
      let root = newFixture("toggle")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      createDir(root / "outside")
      let tty = startAskSession(root, 20_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo x > ../outside/armed.txt")
      tty.expectInHistory "Permission denied", 10_000
      tty.drain(300)
      check not fileExists(root / "outside" / "armed.txt")

      tty.send ":sandbox off\n"
      tty.expectInHistory "sandbox: off  (this session runs unconfined)", 10_000
      runShellCmd(tty, "echo lifted > ../outside/lifted.txt")
      check waitForFileContent(root / "outside" / "lifted.txt", "lifted\n")
      tty.expect "\u276f"

      tty.send ":sandbox on\n"
      tty.expectInHistory "sandbox: on  (this session enforces", 10_000
      runShellCmd(tty, "echo x > ../outside/rearmed.txt")
      tty.expectInHistory "Permission denied", 10_000
      tty.drain(300)
      check not fileExists(root / "outside" / "rearmed.txt")
      tty.expect "\u276f"
      echo "  PASS: mid-session off lifts, on re-arms"

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

        tty.expectInHistory "allow write access to ./vault/fenced.txt?", 30_000
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
    tty.expectInHistory "? write vault/out.txt", 30_000
    tty.expectInHistory "allow write access to ./vault/out.txt?"
    tty.expectInHistory "(f) allow the entire folder"

    tty.sendAskKey 'f'
    tty.expectInHistory "allowed ./vault - retrying", 10_000
    check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
    check waitForSessionText(root,
      "[sandbox ask: user allowed ./vault; tool retried]")
    check policyLines(root) ==
      @["deny /", "allow ./", "allow ./vault", "deny ./locked"]
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: write tool f grants and retries"

  test "model write tool a flips an exact file ask rule in place":
    let root = newFixture("tool_allow_exact")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeFile(root / "run" / ".sandbox",
      "deny /\nallow ./\nask ./vault/out.txt\ndeny ./locked\n")
    writeTurnResponses(root, "vault/out.txt", "granted\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "save it\n"
    tty.expectInHistory "allow write access to ./vault/out.txt?", 30_000
    tty.sendAskKey 'a'
    check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
    check policyLines(root) ==
      @["deny /", "allow ./", "allow ./vault/out.txt", "deny ./locked"]
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: write tool a flips an exact file ask"

  test "model write tool a under a folder ask appends at the end":
    let root = newFixture("tool_allow_append")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeTurnResponses(root, "vault/out.txt", "granted\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "save it\n"
    tty.expectInHistory "allow write access to ./vault/out.txt?", 30_000
    tty.sendAskKey 'a'
    check waitForFileContent(root / "run" / "vault" / "out.txt", "granted\n")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/out.txt"]
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: write tool a appends under a folder ask"

  test "model read tool asks; a grants the read":
    let root = newFixture("tool_read")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeFile(root / "run" / "vault" / "ro.txt", "readable\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"content": "", "tool_calls": [{
        "id": "call_1", "type": "function",
        "function": {"name": "read",
                     "arguments": $(%*{"path": "vault/ro.txt"})}}]},
      {"content": "done"}
    ]))
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "show it\n"
    tty.expectInHistory "? read vault/ro.txt", 30_000
    tty.expectInHistory "allow read access to ./vault/ro.txt?"
    tty.sendAskKey 'a'
    check waitForSessionText(root, "readable")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/ro.txt"]
    tty.expectInHistory "done"
    tty.expect "\u276f"
    echo "  PASS: read tool a grants the read"

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
    tty.expectInHistory "allow write access to ./vault/out.txt?", 30_000
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
    tty.expectInHistory "? apply_patch vault/ap.txt", 30_000
    tty.expectInHistory "allow write access to ./vault/ap.txt?"
    tty.expectInHistory "(f) allow the entire folder"

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
    tty.expectInHistory "allow write access to ./vault/ap_a.txt?", 30_000
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
    tty.expectInHistory "allow write access to ./vault/ap1.txt?", 30_000
    tty.sendAskKey 'f'
    tty.expectInHistory "allowed ./vault - retrying", 10_000
    tty.expectInHistory "allow write access to ./vault2/ap2.txt?", 10_000
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
      tty.expectNo "allow write access"
      tty.drain(300)
      check not fileExists(root / "run" / "locked" / "out.txt")
      tty.expect "\u276f"
      echo "  PASS: hard deny asks nothing"

    else:
      skip()