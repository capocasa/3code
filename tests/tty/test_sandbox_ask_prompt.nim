discard """
  ## The ask gate's answers are submitted commands on a real tty (posix
  ## PTY or Windows ConPTY): typing stays in the editor while an ask
  ## waits, and `:a` / `:d` submitted mid-turn answer it. The card is
  ## one line - ":a to allow <path>, :d or wait Ns to deny" - with the
  ## deadline counting down on it; allow and deny (explicit or timeout)
  ## both persist a rule, flipping an identical ask rule in place, and
  ## the `[sandbox ask: ...]` marker in the tool output records the
  ## decision for the model. The stub binary normally skips sandbox
  ## init (REPL tests want the pre-sandbox timing);
  ## test.stub_sandbox=1 opts this suite back in so the ask rules are
  ## enforced for real. `:! CMD` rides the same runBashWithViewport ask
  ## gate a model bash call takes, without stubbing the model turn; the
  ## write-tool tests pin the file-tool dispatch hook with a stubbed
  ## one-write model turn. The bash legs need kernel enforcement of
  ## bash children, so they probe the backend once and skip where it is
  ## absent (Windows CI has no sandwall fence; a proven host runs them
  ## for real); the tool legs are policy-driven in-process and run
  ## everywhere. The card rides the live tool viewport and the item
  ## commit folds it away, so the durable assertions are the policy
  ## file, the retry's effect on disk, and the marker the session
  ## records.
"""
import std/[json, os, osproc, strutils, times, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getTempDir() / "3code_tty_fixture" /
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
    (key: "test.stub_sandbox", val: "1"),
    (key: "settings.ask_timeout_ms", val: $askTimeoutMs),
  ]
  if responses.len > 0:
    result.add (key: "test.stub_responses", val: responses)

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

proc answerAsk(s: TtySession; ans: string) =
  ## The answer is a submitted command (`:a` / `:d`), not a diverted
  ## key: type it and press Enter while the ask waits. The pre-send
  ## drain keeps the submit from outrunning the gate arming (the card's
  ## last line paints microseconds before the ask arms); an early
  ## submit would queue behind the turn instead of answering it.
  s.drain(80)
  s.typeText ans
  s.send "\n"
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

proc waitForSessionText(tty: TtySession; root, want: string;
    timeoutMs = 10_000): bool =
  ## Wait until the saved session records `want`. Write tool items paint
  ## only the diff on screen, so the model-visible ask marker and denial
  ## must be asserted where they actually land: the tool message content.
  ## `tty` pumps the frame-ack handshake while waiting: the grant path
  ## emits a render boundary between the policy write and the retry, and
  ## a wait that never drained would stall the child until the timeout.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    for f in walkFiles(root / "data" / "3code" / "sessions" / "*.3log"):
      try:
        if want in readFile(f): return true
      except CatchableError: discard
    if tty != nil: tty.drain(0)
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

proc waitForFileContent(tty: TtySession; path, want: string;
    timeoutMs = 10_000): bool =
  ## Same frame-ack pumping as waitForSessionText: the retry runs after
  ## the grant's render boundary is acknowledged.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if fileExists(path):
      try:
        if readFile(path) == want: return true
      except CatchableError: discard
    if tty != nil: tty.drain(0)
    sleep(50)
  false

suite "sandbox ask prompt":
  test ":a allows the denied file and persists the allow":
    if bashSandboxWorks():
      let root = newFixture("allow")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      let tty = startAskSession(root, 20_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo granted > vault/out.txt")

      tty.expectInHistory "? echo granted > vault/out.txt", 30_000
      tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
      tty.answerAsk ":a"
      tty.expectInHistory "allowed ./vault/out.txt - retrying", 30_000
      tty.expectInHistory "[sandbox ask: sandbox allow ./vault/out.txt; command retried]", 30_000
      # The ask rule covers more than the denied file: changing it would
      # rewrite a rule the user aimed at other paths, so the allow lands
      # after every existing rule instead (last-match-wins puts it above
      # the ask rule for this file only). Whether the bash retry then
      # lands is backend business (the Linux mount mask survives a
      # subpath allow); this leg pins the policy file shape and marker.
      check policyLines(root) ==
        @["deny /", "allow ./", "ask ./vault", "deny ./locked",
          "allow ./vault/out.txt"]
      tty.expect "\u276f"
      echo "  PASS: :a allows and retries"

    else:
      skip()

  test ":d denies and persists the denial":
    if bashSandboxWorks():
      let root = newFixture("deny")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      let tty = startAskSession(root, 20_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo nope > vault/out.txt")

      tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
      tty.answerAsk ":d"
      tty.expectInHistory "denied; not retried", 30_000
      tty.expectInHistory "[sandbox ask: sandbox deny ./vault/out.txt; not retried]", 30_000
      tty.drain(500)
      check not fileExists(root / "run" / "vault" / "out.txt")
      check policyLines(root) ==
        @["deny /", "allow ./", "ask ./vault", "deny ./locked",
          "deny ./vault/out.txt"]
      tty.expect "\u276f"
      echo "  PASS: :d denies"

  test ":a flips an exact file ask rule in place and the retry lands":
    # The ask rule names the denied file itself: allow is the rule
    # changing, not a new rule, so it takes the ask line's position -
    # and lifts the ask subtree's fence for the retry. The file is
    # planted first: the Linux backend enforces an ask with a bind
    # mask, and a mask can only mount over a target that exists, so a
    # not-yet-created file is the one shape bash cannot be fenced for
    # (the write-tool legs cover that side in-process).
    if bashSandboxWorks():
      let root = newFixture("allow_exact")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      writeFile(root / "run" / "vault" / "out.txt", "")
      writeFile(root / "run" / ".sandbox",
        "deny /\nallow ./\nask ./vault/out.txt\ndeny ./locked\n")
      let tty = startAskSession(root, 20_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo granted > vault/out.txt")

      tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
      tty.answerAsk ":a"
      tty.expectInHistory "allowed ./vault/out.txt - retrying", 30_000
      check waitForFileContent(tty, root / "run" / "vault" / "out.txt", "granted\n")
      tty.expectInHistory "[sandbox ask: sandbox allow ./vault/out.txt; command retried]", 30_000
      check policyLines(root) ==
        @["deny /", "allow ./", "allow ./vault/out.txt", "deny ./locked"]
      tty.expect "\u276f"
      echo "  PASS: :a flips an exact file ask in place"

    else:
      skip()

  test "timeout denies and persists the denial":
    if bashSandboxWorks():
      let root = newFixture("timeout")
      defer: removeDir(root)
      writeConfiguredProvider(root)
      let tty = startAskSession(root, 2_000)
      defer: tty.close()

      tty.expect "\u276f"
      runShellCmd(tty, "echo late > vault/out.txt")

      tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 2s to deny", 30_000
      tty.expectInHistory "denied (timeout); not retried", 10_000
      tty.expectInHistory "[sandbox ask: sandbox deny ./vault/out.txt; not retried (no answer before timeout)]", 10_000
      tty.drain(300)
      check not fileExists(root / "run" / "vault" / "out.txt")
      # No answer is an answer: the timeout persists the same explicit
      # deny rule a typed :d would have.
      check policyLines(root) ==
        @["deny /", "allow ./", "ask ./vault", "deny ./locked",
          "deny ./vault/out.txt"]
      tty.expect "\u276f"
      echo "  PASS: timeout denies"

    else:
      skip()

  test "scripted denial shows the one-line card with a live countdown":
    # Runs on every host (no kernel backend needed): the card's shape,
    # the countdown ticking on its own line, and the viewport takeover
    # are pure policy and viewport work.
    let root = newFixture("card")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, scriptedDenial())

    tty.expectInHistory "? sh -c \"echo ./vault/out.txt: Permission denied; exit 13\"", 30_000
    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    # The deadline counts down on the card's own line: the next whole
    # second replaces 20s with 19s.
    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 19s to deny", 30_000
    tty.answerAsk ":d"
    tty.expectInHistory "denied; not retried", 30_000
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "deny ./vault/out.txt"]
    tty.expect "\u276f"
    echo "  PASS: scripted denial shows the card"

  test "scripted Windows-shape denial shows the card":
    # cmd.exe and native Windows tools print "Access is denied"; the
    # gate must scrape that shape exactly like the POSIX one. Runs on
    # every host: bash echoes the line verbatim, no backend needed.
    let root = newFixture("card_win")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty,
      "sh -c \"echo ./vault/out.txt: Access is denied.; exit 5\"")

    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":d"
    tty.expectInHistory "denied; not retried", 30_000
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "deny ./vault/out.txt"]
    tty.expect "\u276f"
    echo "  PASS: scripted Windows-shape denial shows the card"

  test "scripted denial :a flips an exact file ask rule in place":
    let root = newFixture("card_exact")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeFile(root / "run" / ".sandbox",
      "deny /\nallow ./\nask ./vault/out.txt\ndeny ./locked\n")
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, scriptedDenial())

    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    tty.expectInHistory "allowed ./vault/out.txt - retrying", 30_000
    # The retry is a second bash spawn; a loaded 2-core Windows runner has
    # run it past 30s twice (a healthy run finishes the whole file in 45s).
    tty.expectInHistory "[sandbox ask: sandbox allow ./vault/out.txt; command retried]", 60_000
    check policyLines(root) ==
      @["deny /", "allow ./", "allow ./vault/out.txt", "deny ./locked"]
    tty.expect "\u276f"
    echo "  PASS: scripted :a flips an exact file ask"

  test "scripted denial :a on a folder ask appends at the end":
    let root = newFixture("card_append")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    let tty = startAskSession(root, 20_000)
    defer: tty.close()

    tty.expect "\u276f"
    runShellCmd(tty, scriptedDenial())

    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    tty.expectInHistory "[sandbox ask: sandbox allow ./vault/out.txt; command retried]", 60_000
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/out.txt"]
    tty.expect "\u276f"
    echo "  PASS: scripted :a appends under a folder ask"

  test ":sandbox off lifts the fence live, :sandbox on restores it":
    # The mid-session toggle is enforcement, not bookkeeping: a write the
    # baseline denies lands cleanly while disarmed and denies again after
    # the re-arm (same session, no restart). The denied target is outside
    # the policy's only writable root, never the ask dir: a live ask gate
    # would sit and wait for an answer this test never sends.
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
      check waitForFileContent(tty, root / "outside" / "lifted.txt", "lifted\n")
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

  test "model write tool asks; :a grants and the write lands":
    let root = newFixture("tool_allow")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeTurnResponses(root, "vault/out.txt", "granted\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "save it\n"
    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    check waitForFileContent(tty, root / "run" / "vault" / "out.txt", "granted\n")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox allow ./vault/out.txt; tool retried]")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/out.txt"]
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: write tool :a grants and retries"

  test "model write tool :a flips an exact file ask rule in place":
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
    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    check waitForFileContent(tty, root / "run" / "vault" / "out.txt", "granted\n")
    check policyLines(root) ==
      @["deny /", "allow ./", "allow ./vault/out.txt", "deny ./locked"]
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: write tool :a flips an exact file ask"

  test "model read tool asks; :a grants the read":
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
    tty.expectInHistory ":a to allow ./vault/ro.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    check waitForSessionText(tty, root, "readable")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox allow ./vault/ro.txt; tool retried]")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/ro.txt"]
    tty.expectInHistory "done"
    tty.expect "\u276f"
    echo "  PASS: read tool :a grants the read"

  test "model write tool asks; :d keeps the denial":
    let root = newFixture("tool_deny")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeTurnResponses(root, "vault/out.txt", "nope\n")
    let tty = startAskSession(root, 20_000,
                              responses = root / "run" / "stub_responses.json")
    defer: tty.close()

    tty.expect "\u276f"
    tty.send "save it\n"
    tty.expectInHistory ":a to allow ./vault/out.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":d"
    check waitForSessionText(tty, root, "is denied by the policy")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox deny ./vault/out.txt; not retried]")
    tty.drain(300)
    check not fileExists(root / "run" / "vault" / "out.txt")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "deny ./vault/out.txt"]
    tty.expect "\u276f"
    echo "  PASS: write tool :d declines"

  test "model apply_patch asks; :a grants and the add lands":
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
    tty.expectInHistory ":a to allow ./vault/ap.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    check waitForFileContent(tty, root / "run" / "vault" / "ap.txt", "granted\n")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox allow ./vault/ap.txt; tool retried]")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "allow ./vault/ap.txt"]
    tty.expectInHistory "saved"
    tty.expect "\u276f"
    echo "  PASS: apply_patch :a grants and the add lands"

  test "model apply_patch mixed ops; :d denies only the ask root":
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
    tty.expectInHistory ":a to allow ./vault/ap_a.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":d"
    check waitForFileContent(tty, root / "run" / "open_b.txt", "yes\n")
    tty.drain(300)
    check not fileExists(root / "run" / "vault" / "ap_a.txt")
    check waitForSessionText(tty, root, "vault/ap_a.txt")
    check waitForSessionText(tty, root, "is denied by the policy")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox deny ./vault/ap_a.txt; not retried]")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "deny ./vault/ap_a.txt"]
    tty.expect "\u276f"
    echo "  PASS: apply_patch :d denies only the ask root"

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
    tty.expectInHistory ":a to allow ./vault/ap1.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":a"
    tty.expectInHistory ":a to allow ./vault2/ap2.txt, :d or wait 20s to deny", 30_000
    tty.answerAsk ":d"
    check waitForFileContent(tty, root / "run" / "vault" / "ap1.txt", "one\n")
    tty.drain(300)
    check not fileExists(root / "run" / "vault2" / "ap2.txt")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox allow ./vault/ap1.txt; tool retried]")
    check waitForSessionText(tty, root,
      "[sandbox ask: sandbox deny ./vault2/ap2.txt; not retried]")
    check policyLines(root) ==
      @["deny /", "allow ./", "ask ./vault", "deny ./locked",
        "ask ./vault2", "allow ./vault/ap1.txt", "deny ./vault2/ap2.txt"]
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
      tty.expectNo ":a to allow"
      tty.drain(300)
      check not fileExists(root / "run" / "locked" / "out.txt")
      tty.expect "\u276f"
      echo "  PASS: hard deny asks nothing"

    else:
      skip()
