discard """
  targets: "c"
  matrix: "; -d:providerStub"
"""
## Library API end-to-end: init a headless AgentSession against the stub
## provider, run a blocking prompt (with a tool call), collect callback
## events, run a colon command, close, and resume the saved session.
##
## Compiled twice by the matrix: the plain variant only exercises the
## init-failure path (no stub provider available); the `-d:providerStub`
## variant runs the full suite. XDG roots redirect config/data into a
## per-test fixture so nothing touches the developer's real 3code state.

import std/[json, os, strutils, atomics, unittest]
import threecode/[api, library, types, util, sandbox, dirsettings, session]

const stubbed = defined(providerStub)

# One startup snapshot: isolateEnv re-points TMPDIR per fixture, and
# getTempDir reads it fresh on every call, so fixtures computed after the
# first isolateEnv would nest inside the previous fixture's tmp dir until
# the mangled dir-lock name blows past the filesystem limit.
let baseTmp = getTempDir()

proc newFixture(name: string): string =
  result = baseTmp / ("3code_libtest_" & name & "_" & $getCurrentProcessId())
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

    test "a refused store disable survives a session reopen":
      # The authority rule is not startup-only: close the session and
      # reopen in the same directory, the project store's `sandbox =
      # off` is refused again and the session stays confined. A failed
      # or previous session leaves no weakened global behind.
      let root = newFixture("authority")
      writeConfig(root)
      writeFile(root / "xdg" / "3code" / "config", """
[settings]
sandbox = "on"
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")
      createDir(root / "run" / ".3code")
      writeFile(root / "run" / ".3code" / "config",
        "[settings]\nsandbox = \"off\"\n")
      isolateEnv(root)
      # isolateEnv re-points TMPDIR at the fixture; the suite's later
      # fixtures must not nest under it, so hand the suite value back.
      defer: putEnv("TMPDIR", stableTmp)
      dirsettings.dirConfigLocation = "project"
      let a = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check sandboxEnabled
      a.close()
      let b = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check sandboxEnabled
      b.close()

    test "a tightened sandbox never leaks into a later session":
      # Session A runs where a project store tightens the sandbox on
      # over a user-config off. After close, session B in a clean
      # directory sees the user's off again: the tighten is A's
      # overlay, not a global the next session inherits.
      let root = newFixture("tighten")
      writeConfig(root)
      writeFile(root / "xdg" / "3code" / "config", """
[settings]
sandbox = "off"
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")
      createDir(root / "run" / ".3code")
      writeFile(root / "run" / ".3code" / "config",
        "[settings]\nsandbox = \"on\"\n")
      isolateEnv(root)
      defer: putEnv("TMPDIR", stableTmp)
      dirsettings.dirConfigLocation = "project"
      let a = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check sandboxEnabled
      a.close()
      let clean = root / "clean"
      createDir(clean)
      let b = initAgentSession(AgentOptions(cwd: clean,
                                            experimental: true))
      check not sandboxEnabled
      b.close()

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

    test "closed session refuses turns and commands; close is idempotent":
      let root = newFixture("closed")
      writeConfig(root)
      isolateEnv(root)
      # The second response exists so a pre-fix regression (a turn running
      # against the closed session) completes instead of killing the test
      # process on an exhausted stub queue.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "before close"}, {"content": "after close"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check s.prompt("go") == "before close"
      let msgCount = s.messages.len
      s.close()
      expect AgentError:
        discard s.prompt("again")
      expect AgentError:
        discard s.promptAsync("again")
      expect AgentError:
        discard s.command(":tokens")
      # The refusal happened before any model call: no user message, no
      # reply appended.
      check s.messages.len == msgCount
      s.close()
      s.close()

    test "a second submission is refused while a turn runs":
      let root = newFixture("busy")
      writeConfig(root)
      isolateEnv(root)
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "first", "preStreamDelayMs": 300},
        {"content": "second"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      var probed = false
      s.onEvent = proc(ev: AgentEvent) =
        # Fires on the turn's own thread mid-stream: the turn slot is held,
        # and the lifecycle lock is not, so a nested admission attempt is
        # safe and must be refused.
        if ev.kind == aevDelta and not probed:
          probed = true
          expect AgentError:
            discard s.prompt("mid-turn")
          expect AgentError:
            discard s.command(":tokens")
      check s.prompt("go") == "first"
      check probed
      # The slot was released: the next turn admits normally.
      check s.prompt("go") == "second"
      s.close()

    test "promptAsync reserves the slot against blocking and async calls":
      let root = newFixture("asyncbusy")
      writeConfig(root)
      isolateEnv(root)
      # Chunks with inter-chunk delays: the first delta fires while the
      # turn still has ~500ms of stream left, so the main thread probes a
      # genuinely in-flight turn, not its corpse.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "slow still streaming",
         "contentChunks": ["slow ", "still ", "streaming"],
         "contentChunkDelayMs": 250},
        {"content": "after async"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      var deltaSeen: Atomic[bool]
      s.onEvent = proc(ev: AgentEvent) =
        if ev.kind == aevDelta: deltaSeen.store(true)
      let t = s.promptAsync("slow")
      var waited = 0
      while not deltaSeen.load and waited < 5000:
        sleep 20
        inc waited, 20
      check deltaSeen.load  # the worker's turn is genuinely in flight
      expect AgentError:
        discard s.prompt("blocking second")
      expect AgentError:
        discard s.promptAsync("async second")
      joinTurn(t)
      check s.prompt("after") == "after async"
      s.close()

    test "close during a running turn is refused and the session survives":
      let root = newFixture("closebusy")
      writeConfig(root)
      isolateEnv(root)
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "still running", "preStreamDelayMs": 300}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      var probed = false
      s.onEvent = proc(ev: AgentEvent) =
        # The close refusal surfaces right here in the callback: no
        # teardown mid-turn, no deadlock, and the turn carries on to its
        # normal end.
        if ev.kind == aevDelta and not probed:
          probed = true
          expect AgentError:
            s.close()
      check s.prompt("go") == "still running"
      check probed
      s.close()
      # the refused close left a healthy session: reopen the directory
      let s2 = initAgentSession(AgentOptions(cwd: root / "run",
                                             experimental: true))
      s2.close()

    test "save failure on close still releases ownership and allows reopen":
      let root = newFixture("savefail")
      writeConfig(root)
      isolateEnv(root)
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "kept"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check s.prompt("go") == "kept"
      let savePath = s.state.savePath
      let before = readFile(savePath)
      # Fault the close-time save at the last point before the commit:
      # close reports, never raises, and releases ownership either way.
      saveFaultHook = proc(p: SaveFaultPhase) {.gcsafe, raises: [CatchableError].} =
        if p == sfpBeforeReplace:
          raise newException(IOError, "injected replace failure")
      s.close()
      saveFaultHook = nil
      check readFile(savePath) == before
      # The directory and session locks are gone, so the same directory
      # opens again right away.
      let s2 = initAgentSession(AgentOptions(cwd: root / "run",
                                             experimental: true))
      s2.close()

    test "failed init releases the locks it had acquired":
      let root = newFixture("rollback")
      writeConfig(root)
      isolateEnv(root)
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "x"}
      ]))
      let target = root / "run" / "held.3log"
      acquireSessionLock(target)
      # The init takes the directory lock, then dies on the session lock:
      # rollback must give the directory back.
      expect AgentError:
        discard initAgentSession(AgentOptions(cwd: root / "run",
                                              sessionPath: target,
                                              experimental: true))
      releaseSessionLock(target)
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      s.close()

    test "a failed transcript save surfaces from prompt; close still releases":
      # Blocking library calls must observe persistence failure, not a
      # normal reply. The save target's parent is a regular file, so no
      # transcript can ever commit there.
      # Re-anchor TMPDIR first: newFixture picks up the current TMPDIR,
      # and one isolateEnv per test deepens the lock path until it
      # overflows NAME_MAX.
      putEnv("TMPDIR", stableTmp)
      let root = newFixture("savefail")
      writeConfig(root)
      isolateEnv(root)
      writeFile(root / "blocker", "x")
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "lost reply"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()
      let s = initAgentSession(AgentOptions(
        cwd: root / "run",
        sessionPath: root / "blocker" / "lost.3log",
        experimental: true))
      expect SessionSaveError:
        discard s.prompt("go")
      check not fileExists(root / "blocker" / "lost.3log")
      # close()'s shutdown save is best-effort but never raises, and the
      # ownership release happens either way: a fresh session can open.
      s.close()
      let again = initAgentSession(AgentOptions(cwd: root / "run",
                                                experimental: true))
      again.close()

