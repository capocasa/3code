discard """
  targets: "c"
  matrix: "; -d:providerStub; -d:providerStub -d:sessionSaveTestHooks"
"""
## Library API end-to-end: init a headless AgentSession against the stub
## provider, run a blocking prompt (with a tool call), collect callback
## events, run a colon command, close, and resume the saved session.
##
## Compiled twice by the matrix: the plain variant only exercises the
## init-failure path (no stub provider available); the `-d:providerStub`
## variant runs the full suite. XDG roots redirect config/data into a
## per-test fixture so nothing touches the developer's real 3code state.

import std/[json, os, strutils, unittest]
import threecode/[api, library, session, types, util]

const stubbed = defined(providerStub)

proc agentErrMsg(op: proc (): string): string =
  ## The AgentError message from a call expected to be rejected. Fails the
  ## running test when no AgentError is raised (unittest's expect cannot
  ## capture the exception object on this Nim version).
  try:
    let v = op()
    raise newException(AssertionDefect,
      "expected AgentError, none was raised (returned: " & v & ")")
  except AgentError as e:
    result = e.msg

proc expectAgentErr(op: proc ()) =
  try:
    op()
    raise newException(AssertionDefect,
      "expected AgentError, none was raised")
  except AgentError:
    discard

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_libtest_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")

proc writeConfig(root: string) =
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

proc isolateEnv(root: string) =
  # TMPDIR too: session locks live in $TMPDIR/3code/lock, shared with every
  # other test process on the machine. Testament runs categories in
  # parallel, so without this a leaked or still-held lock from another
  # test's 3code process blocks initAgentSession the moment the
  # second-granularity session ids collide.
  putEnv("XDG_CONFIG_HOME", root / "xdg")
  putEnv("XDG_DATA_HOME", root / "data")
  putEnv("TMPDIR", root / "tmp")
  createDir(root / "tmp")

suite "library: AgentSession":
  let stableTmp = getTempDir()  # isolateEnv re-points TMPDIR per fixture
  when not stubbed:
    test "init without a config raises AgentError":
      let root = newFixture("noconfig")
      isolateEnv(root)
      for attempt in 0..1:
        expect AgentError:
          discard initAgentSession(AgentOptions(cwd: root / "run"))
      for path in walkDirRec(root / "data"):
        check not path.endsWith(".3log")
  else:
    test "second open is rejected without disturbing first; close permits reinit":
      let root = newFixture("ownership")
      writeConfig(root)
      isolateEnv(root)
      let first = initAgentSession(AgentOptions(cwd: root / "run"))
      expect AgentError:
        discard initAgentSession(AgentOptions(cwd: root / "missing"))
      let before = first.command(":tokens")
      check before.len > 0
      check first.command(":tokens") == before
      first.close()
      let second = initAgentSession(AgentOptions(cwd: root / "run"))
      first.close() # an old handle must not release the new owner
      expect AgentError:
        discard initAgentSession(AgentOptions(cwd: root / "run"))
      second.close()

    test "blocking prompt runs tools and returns the reply":
      let root = newFixture("prompt")
      writeConfig(root)
      isolateEnv(root)
      # Response 1: the model asks for a bash tool call. Response 2: after
      # the tool result lands, the model closes with prose.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "",
         "tool_calls": [{
           "id": "call_1",
           "type": "function",
           "function": {"name": "bash",
                        "arguments": $(%*{"command": "echo hello-from-tool"})}}]},
        {"content": "tool says hello-from-tool",
         "contentChunks": ["tool says ", "hello-from-tool"]}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")

      var deltas, tools, retries, notices: seq[string]
      var dones: seq[Usage]
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))

      # Callback surface wired up: deltas stream, tool results and turn
      # notices flow as aevTool/aevNotice (ANSI-free), aevDone carries the
      # per-call usage.
      s.onEvent = proc(ev: AgentEvent) =
        case ev.kind
        of aevDelta: deltas.add ev.text
        of aevTool: tools.add ev.text
        of aevRetry: retries.add ev.text
        of aevNotice: notices.add ev.text
        of aevDone: dones.add ev.usage
        else: discard

      check s.prompt("say hi with a tool") == "tool says hello-from-tool"
      check deltas.join("") == "tool says hello-from-tool"
      check dones.len >= 1
      check dones[^1].totalTokens > 0
      check tools.join("\n").contains("hello-from-tool")
      check s.usage.totalTokens > 0

      # Colon command round-trips through the same handler as the REPL.
      let toks = s.command(":tokens")
      check toks.contains("total")

      # Modal commands are refused, not deadlocked.
      check s.command(":provider add").contains("interactive")

      s.close()

    test "close persists a resumable session":
      let root = newFixture("resume")
      writeConfig(root)
      isolateEnv(root)
      # The stub provider's response index is process-global; pad the file
      # with the two entries the first test consumed so the pointer lands
      # on this test's replies.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "pad"}, {"content": "pad"},
        {"content": "first reply"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")

      let s1 = initAgentSession(AgentOptions(cwd: root / "run",
                                             experimental: true))
      check s1.prompt("first") == "first reply"
      let savePath = s1.state.savePath
      s1.close()
      check fileExists(savePath)

      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "pad"}, {"content": "pad"}, {"content": "pad"},
        {"content": "second reply"}
      ]))
      let s2 = initAgentSession(AgentOptions(cwd: root / "run", resume: true,
                                             experimental: true))
      # History came back: system + user + assistant from the first session.
      check s2.messages.len >= 3
      check s2.prompt("second") == "second reply"
      s2.close()

    test "resumed session re-sends byte-identical wire history":
      # The cache-parity contract end to end: a turn driven live and the
      # same turn driven through save/close/resume must produce the exact
      # same request bytes. Both fixtures share ONE xdg root (the prompt
      # embeds skill paths under $XDG_DATA_HOME, so distinct roots would
      # make the prefixes differ for fixture reasons, not app ones).
      # Turn one includes a tool call (update_plan: deterministic output,
      # no path-bearing result) plus reasoning; turn two is the parity-
      # checked continuation.
      let root = newFixture("parity")
      writeConfig(root)
      isolateEnv(root)
      # One shared run dir: the session preamble embeds the session cwd,
      # so separate live/res dirs would make the first user message differ
      # for fixture reasons, not app ones.
      let run = root / "run"
      createDir(run)

      block live:
        resetStubResponses()
        writeFile(run / "stub_responses.json", $(%*[
          {"role": "assistant", "content": "", "reasoning_content": "",
           "tool_calls": [{
            "id": "call_p1", "type": "function",
            "function": {"name": "update_plan",
                         "arguments": $(%*{"items": [
                           {"text": "one", "status": "pending"}]})}}]},
          {"role": "assistant", "content": "ran it",
           "reasoning_content": "thought briefly"},
          {"role": "assistant", "content": "turn two live",
           "reasoning_content": ""}
        ]))
        putEnv("THREECODE_STUB_RESPONSES", run / "stub_responses.json")
        let s = initAgentSession(AgentOptions(cwd: run,
                                              experimental: true))
        discard s.prompt("run a tool")
        discard s.prompt("continue")
        writeFile(stableTmp / "3code-parity-live.txt",
                  $repairToolCallPairing(stripInternalFields(s.messages)))
        s.close()

      block resumed:
        resetStubResponses()
        writeFile(run / "stub_responses.json", $(%*[
          {"role": "assistant", "content": "", "reasoning_content": "",
           "tool_calls": [{
            "id": "call_p1", "type": "function",
            "function": {"name": "update_plan",
                         "arguments": $(%*{"items": [
                           {"text": "one", "status": "pending"}]})}}]},
          {"role": "assistant", "content": "ran it",
           "reasoning_content": "thought briefly"}
        ]))
        putEnv("THREECODE_STUB_RESPONSES", run / "stub_responses.json")
        let s1 = initAgentSession(AgentOptions(cwd: run,
                                               experimental: true))
        discard s1.prompt("run a tool")
        s1.close()

        writeFile(run / "stub_responses.json", $(%*[
          {"role": "assistant", "content": "unused"},
          {"role": "assistant", "content": "unused"},
          {"role": "assistant", "content": "turn two live",
           "reasoning_content": ""}
        ]))
        let s2 = initAgentSession(AgentOptions(cwd: run, resume: true,
                                               experimental: true))
        discard s2.prompt("continue")
        writeFile(stableTmp / "3code-parity-resume.txt",
                  $repairToolCallPairing(stripInternalFields(s2.messages)))
        s2.close()

      check readFile(stableTmp / "3code-parity-live.txt") ==
            readFile(stableTmp / "3code-parity-resume.txt")
      removeFile(stableTmp / "3code-parity-live.txt")
      removeFile(stableTmp / "3code-parity-resume.txt")

    test "unknown model raises AgentError":
      let root = newFixture("badmodel")
      writeConfig(root)
      isolateEnv(root)
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      expect AgentError:
        discard initAgentSession(AgentOptions(cwd: root / "run",
                                              model: "stub.nonexistent",
                                              experimental: true))

    test "empty prompt continues the turn without adding a user message":
      let root = newFixture("emptycontinue")
      writeConfig(root)
      isolateEnv(root)
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "first reply"},
        {"content": "continued reply"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      proc userRoles(): int =
        for m in s.messages:
          if m{"role"}.getStr == "user": inc result
      check s.prompt("go") == "first reply"
      let before = s.messages.len
      check userRoles() == 1
      # The empty prompt is a continue: a turn runs on the messages as
      # they stand, only the model's reply is appended.
      check s.prompt("") == "continued reply"
      check s.messages.len == before + 1
      check userRoles() == 1
      s.close()

      # Nothing to continue yet: an empty prompt on a fresh session is an
      # error, not a turn on a system-only conversation. Same fixture (the
      # lock dir nests per isolateEnv call; a second root would deepen it).
      createDir(root / "fresh")
      let s2 = initAgentSession(AgentOptions(cwd: root / "fresh",
                                             experimental: true))
      expect AgentError:
        discard s2.prompt("")
      s2.close()

    test "closed session rejects turns, commands, and accessors; close is idempotent":
      # Fresh TMPDIR roots: nesting under the earlier fixtures' isolateEnv
      # chains would push the mangled dir-lock name past NAME_MAX.
      putEnv("TMPDIR", stableTmp / ("a4t_closed_" & $getCurrentProcessId()))
      let root = newFixture("closed")
      writeConfig(root)
      isolateEnv(root)
      # Padding keeps a pre-fix run from stub-quitting (index out of
      # range) while it wrongly runs turns on the closed session.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "reply"}, {"content": "pad"}, {"content": "pad"},
        {"content": "pad"}]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                           experimental: true))
      s.close()
      # Same stable rejection every time, not a fresh crash per attempt.
      check agentErrMsg(proc(): string = s.prompt("one")) ==
            agentErrMsg(proc(): string = s.prompt("two"))
      expectAgentErr(proc() = discard s.command(":tokens"))
      expectAgentErr(proc() = discard s.usage())
      expectAgentErr(proc() = discard s.profileLabel())
      # Repeated close after actual closure is a no-op: it must not touch
      # locks, hooks, or plugin teardown again.
      s.close()
      s.close()

    test "a busy session admits exactly one turn; close during a turn is rejected":
      putEnv("TMPDIR", stableTmp / ("a4t_busy_" & $getCurrentProcessId()))
      let root = newFixture("busy")
      writeConfig(root)
      isolateEnv(root)
      # Padding keeps a pre-fix run from stub-quitting while it wrongly
      # admits the second and third submission.
      # Non-empty content: an empty model reply triggers the length-retry
      # escalation, not a clean turn that parks in the stub delay.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "working", "preStreamDelayMs": 900},
        {"content": "turn finished"}, {"content": "pad"},
        {"content": "pad"}, {"content": "pad"}]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                           experimental: true))
      # A close arriving from inside an event callback lands on a running
      # session: refused with the same stable error, no deadlock (the
      # lifecycle gate is never held while callbacks fire).
      var callbackErr = ""
      s.onEvent = proc(ev: AgentEvent) =
        if callbackErr.len == 0 and ev.kind == aevDelta:
          try:
            s.close()
          except AgentError as e:
            callbackErr = e.msg
      s.promptAsync("go")
      # The turn reservation is taken before the worker spawns, so a
      # second submission - async or blocking - is rejected without
      # touching hooks, files, model state, or tools.
      expect AgentError:
        s.promptAsync("second")
      check agentErrMsg(proc(): string = s.prompt("blocking")) ==
            agentErrMsg(proc(): string = s.prompt("blocking again"))
      expectAgentErr(proc() = s.close())
      s.joinTurn()
      check callbackErr.len > 0
      check s.prompt("") == "turn finished"
      s.close()

    test "an interrupted async turn releases the reservation, saves, and admits the next turn":
      # Cross-boundary: cancel a turn behind the AgentSession lifecycle gate
      # (the mechanism rpc /session/cancel and acp session/cancel drive) and
      # require the whole chain: the worker surfaces the interruption as
      # aevError, the turn reservation is released so a later turn is
      # admitted, the interrupted turn persisted its user message, and the
      # retired worker cannot interfere with the follow-up turn.
      putEnv("TMPDIR", stableTmp / ("a7t_interrupt_" & $getCurrentProcessId()))
      let root = newFixture("interrupt")
      writeConfig(root)
      isolateEnv(root)
      # The marker file appears when the stub selects this response, before
      # the pre-stream delay parks the turn: deterministic cancel timing.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "late reply", "preStreamDelayMs": 30000,
         "markerPath": root / "run" / "in_flight"},
        {"content": "after interrupt"}]))
      putEnv("THREECODE_STUB_RESPONSES",
             root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                           experimental: true))
      var errText = ""
      s.onEvent = proc(ev: AgentEvent) =
        if ev.kind == aevError: errText = ev.text
      s.promptAsync("go")
      var inFlight = false
      for i in 0 ..< 500:
        if fileExists(root / "run" / "in_flight"):
          inFlight = true
          break
        sleep(20)
      check inFlight
      s.interrupt()
      s.joinTurn()
      check errText == InterruptedByUserMsg
      # Persistence policy: the interrupted turn saved what it had.
      check "go" in readFile(s.state.savePath)
      # The reservation is gone: the very next submission is admitted and
      # runs to completion with no interference from the retired worker.
      check s.prompt("") == "after interrupt"
      s.close()

    when defined(sessionSaveTestHooks):
      test "save failure on close still releases ownership and allows reopen":
        putEnv("TMPDIR", stableTmp / ("a4t_savefail_" & $getCurrentProcessId()))
        let root = newFixture("closesavefail")
        writeConfig(root)
        isolateEnv(root)
        writeFile(root / "run" / "stub_responses.json", $(%*[
          {"content": "saved"}, {"content": "saved again"}]))
        putEnv("THREECODE_STUB_RESPONSES",
               root / "run" / "stub_responses.json")
        resetStubResponses()
        let s = initAgentSession(AgentOptions(cwd: root / "run",
                                             experimental: true))
        discard s.prompt("hello")
        let savePath = s.state.savePath
        let before = readFile(savePath)
        saveFaultHook = proc(phase: SavePhase): bool {.gcsafe.} =
          phase == spWrite
        s.close()  # reports on stderr; must not raise, must not leak
        saveFaultHook = nil
        check readFile(savePath) == before
        let s2 = initAgentSession(AgentOptions(cwd: root / "run",
                                               experimental: true))
        check s2.prompt("again") == "saved again"
        s2.close()
