discard """
  disabled: "win"
"""
## Interactive coverage for the two controller-level features that unit
## suites cannot reach (they live behind the input thread and the idle
## REPL loop):
##
## - `:retry` retry: the command must travel the idle REPL loop ->
##   `requestTurnRetry`, and the retry backoff must break immediately
##   when it lands (the transport-level contract is covered by
##   tests/stream; this is the wiring).
## - Goal mode wiring: the file is the whole mode, and work starts the
##   moment it exists. `:goal TEXT` runs the kickoff turn at once; a
##   goal.md already on disk at startup does the same before any prompt.
##   The arm announces with the kickoff item alone - the `⚑` flag plus
##   the goal text, no echoed command line, no receipt, no hint line,
##   no `Goal armed:` scaffold - and the stanza is fed exactly once per
##   arming: a
##   resumed session never re-feeds it. Each turn end runs the verifier
##   whose reply is the whole display - a quote block led by the green
##   `✓` or red `✗` icon, no notice before or after it. An unmet
##   verdict sends the agent back in under the `⚑` marker and the next
##   turn starts on its own; a satisfied one retires goal.md to
##   achieved.md.
import std/[json, os, strutils, unittest, times]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" / (name & "_" & $getCurrentProcessId())
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
  let data = root / "data"
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

proc reply(content: string; delayMs = 50): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": delayMs,
     "content": content, "contentChunks": [content],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}

proc toolReply(name, argsJson: string; content = ""): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": 50, "content": content,
     "tool_calls": [{"id": "c" & $epochTime(), "type": "function",
       "function": {"name": name, "arguments": argsJson}}],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}

suite ":retry and goal mode (interactive)":
  test ":retry during a 429 backoff retries immediately":
    let root = newFixture("ctrl_r_backoff")
    writeConfiguredProvider(root)
    # A 429 whose backoff is 6000ms, then a normal reply. `:retry` sent
    # during the wait must skip the remaining backoff and resend; the
    # reply can then only appear long before the full 6s wait. Without
    # the skip the expect times out (nothing else can produce the text).
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}",
       "delayMs": 6000},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "recovered", "contentChunks": ["recovered"],
       "usage": {"promptTokens": 5, "completionTokens": 1,
                  "totalTokens": 6, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    tty.expectNoticeRow("429")
    tty.drain(100)
    # `:retry` mid-backoff: the wait breaks and the resend runs.
    tty.send ":retry\n"
    let t0 = epochTime()
    check tty.expectInHistory("recovered", timeoutMs = 4000)
    let elapsed = epochTime() - t0
    check elapsed < 5.0
    tty.expectAlive()

  test ":goal TEXT arms; the kickoff turn runs at once":
    let root = newFixture("goal_kickoff")
    writeConfiguredProvider(root)
    check not fileExists(root / "run" / ".3code" / "goal")
    # Response 1 goes to the kickoff turn the arm starts; response 2 is
    # its turn-end verifier side call (satisfied verdict retires
    # goal.md).
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "all done\nVERDICT: SATISFIED",
       "contentChunks": ["all done\nVERDICT: SATISFIED"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    # Verb error paths at the live prompt first: bare status with no
    # goal, cancel with no goal, and usage-less new all refuse cleanly
    # and leave the prompt usable.
    tty.send ":goal"
    tty.send "\n"
    tty.expect "no goal active"
    tty.send ":goal cancel"
    tty.send "\n"
    tty.expect "no goal active"
    tty.send ":goal new"
    tty.send "\n"
    tty.expect "usage"
    tty.drain(100)
    tty.send ":goal make the stub say the word"
    tty.expect ":goal make the stub say the word"
    tty.send "\n"
    tty.drain(100)
    # The arm announces with the ⚑ kickoff item alone: no echoed
    # command line (it would repeat the goal text), no receipt. The
    # kickoff turn starts on its own - no prompt is sent, and the reply
    # streams anyway.
    tty.expectNeverInHistory "goal armed"
    # No hint line - the kickoff item is the whole announcement: the
    # flag plus the goal text alone, scaffold dropped.
    tty.expectNeverInHistory "detected implementing"
    tty.expectInHistory "⚑ make the stub say the word"
    tty.expectNeverInHistory "Goal armed:"
    tty.expectInHistory "GOAL_WORK_DONE"
    # Turn end: the verifier's reply renders as a dim quote block led by
    # the green ✓ icon (verdict line stripped) - the whole display, with
    # no notice around it - and the retirement lands on disk.
    tty.expectInHistory "all done"
    tty.expectNeverInHistory "VERDICT"
    tty.expectInHistory "\u2713"
    tty.expectNeverInHistory "verifying"
    tty.expectNeverInHistory "verification"
    tty.drain(300)
    check fileExists(root / "run" / ".3code" / "achieved")
    check not fileExists(root / "run" / ".3code" / "goal")
    tty.expectAlive()

  test "goal.md present at startup starts the kickoff turn at once":
    let root = newFixture("goal_startup_kickoff")
    writeConfiguredProvider(root)
    # goal.md is written before the session starts - how a user (or any
    # other tool) arms a goal without ever touching :goal. Startup must
    # treat it exactly like a `:goal` arm: the detection hint, then the
    # kickoff turn, no prompt required.
    writeFile(root / "run" / "goal.md", "make the stub say GOAL_WORK_DONE\n")
    # Response 1 goes to the startup kickoff turn; response 2 is its
    # turn-end verifier side call (satisfied verdict retires goal.md);
    # response 3 answers the follow-up prompt that proves the session
    # idles normally afterwards.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "all done\nVERDICT: SATISFIED",
       "contentChunks": ["all done\nVERDICT: SATISFIED"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "NEXT_TURN_OK", "contentChunks": ["NEXT_TURN_OK"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    # Nothing is typed: the kickoff turn runs on its own, before any
    # prompt - the flag-led goal item is the whole announcement.
    tty.expectNeverInHistory "detected implementing"
    tty.expectInHistory "⚑ make the stub say GOAL_WORK_DONE"
    tty.expectNeverInHistory "Goal armed:"
    tty.expectInHistory "GOAL_WORK_DONE"
    check fileExists(root / "run" / "goal.md")
    # The kickoff turn's end runs the check - the verifier's ✓ icon row
    # is the whole display, and the retirement to achieved.md hangs off
    # that boundary.
    tty.expectInHistory "\u2713"
    tty.expectNeverInHistory "verifying"
    tty.expectNeverInHistory "verification"
    tty.drain(300)
    check fileExists(root / "run" / "achieved.md")
    check not fileExists(root / "run" / "goal.md")
    # The session is back to an ordinary idle prompt: a typed prompt
    # answers normally, and no second turn fires on its own.
    tty.send "still here"
    tty.expect "still here"
    tty.send "\n"
    tty.expectInHistory "NEXT_TURN_OK"
    tty.expectAlive()

  test "verifier reply lands in scrollback; keys typed during the check survive":
    let root = newFixture("goal_verify_reply")
    writeConfiguredProvider(root)
    # Response 1: the first turn's reply. Response 2: a slow toolless
    # verifier call (one reply, no tool rounds) whose prose lands as a
    # dim quote block in scrollback; keystrokes typed right after the
    # turn receipt ride out the whole check in the editor. Response 3:
    # the reply to the user's next prompt, submitted AFTER the check:
    # the text typed mid-check must still be in the editor, proving the
    # side call never ate keys (the tool stdin watcher used to arm for
    # its bash rounds and swallow everything).
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 1500,
       "content": "checked the tree.\nVERDICT: SATISFIED",
       "contentChunks": ["checked the tree.\nVERDICT: SATISFIED"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "NEXT_TURN_OK", "contentChunks": ["NEXT_TURN_OK"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send ":goal make the stub say the word"
    tty.send "\n"
    tty.drain(100)
    tty.expectInHistory "⚑ make the stub say the word"
    # The kickoff turn runs on its own; its reply lands without any
    # prompt being sent.
    tty.expectInHistory "GOAL_WORK_DONE"
    # The turn has ended and the verifier's slow model call (1500ms
    # delay) is already running, so these keystrokes must ride out the
    # whole check in the editor buffer.
    tty.send "SURVIVED_KEYS"
    tty.drain(300)
    # The check shows its work: the verifier's reply prose lands as a
    # ✓-led dim quote block (verdict line stripped) before the verdict
    # is honored.
    tty.expectInHistory "checked the tree."
    tty.expectNeverInHistory "VERDICT: SATISFIED"
    tty.expectInHistory "\u2713"
    check fileExists(root / "run" / ".3code" / "achieved")
    check not fileExists(root / "run" / ".3code" / "goal")
    # Submit the buffer that lived through the check: the echoed prompt
    # only appears if every keystroke survived the side call.
    tty.send "\n"
    tty.expectInHistory "SURVIVED_KEYS"
    tty.expectInHistory "NEXT_TURN_OK"
    tty.expectAlive()

  test "ctrl-c during the verifier call interrupts the check, goal stays":
    let root = newFixture("goal_verify_interrupt")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 8000,
       "content": "never reached\nVERDICT: SATISFIED",
       "contentChunks": ["never reached\nVERDICT: SATISFIED"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send ":goal work toward it"
    tty.send "\n"
    tty.drain(100)
    tty.expectInHistory "⚑ work toward it"
    # The kickoff turn runs on its own and its reply lands; the
    # turn-end verifier's slow model call (8000ms delay) then runs.
    tty.expectInHistory "GOAL_WORK_DONE"
    tty.expectNeverInHistory "detected implementing"
    # Ctrl-C while the verifier's slow model call runs: the interrupt is
    # honored after the side call returns, skips the satisfaction check,
    # and ends the turn. goal.md survives.
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    check fileExists(root / "run" / ".3code" / "goal")
    check not fileExists(root / "run" / ".3code" / "achieved")
    tty.expectAlive()

  test "unmet verdict shows the evaluation, then just continues":
    let root = newFixture("goal_feedback_continue")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "goal.md", "make the stub do two turns\n")
    # Response 1: the kickoff turn's reply. Response 2: an unmet verdict.
    # Response 3: the continuation turn's reply, which must start on its
    # own - no prompt is sent at any point. Response 4: the satisfied
    # verdict that retires the mode.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("WORK_TURN_ONE"),
      reply("tests were not run\nVERDICT: FEEDBACK: run the tests"),
      reply("WORK_TURN_TWO"),
      reply("all good\nVERDICT: SATISFIED"),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.expectInHistory "⚑ make the stub do two turns"
    tty.expectNeverInHistory "Goal armed:"
    tty.expectInHistory "WORK_TURN_ONE"
    # The unmet evaluation: the red ✗ quote row is the whole display.
    # The feedback rides the ⚑ continuation item and the next turn
    # starts by itself - no verdict notice, no continuing receipt.
    tty.expectInHistory "tests were not run"
    tty.expectInHistory "\u2717"
    tty.expectNeverInHistory "VERDICT"
    tty.expectNeverInHistory "verifying"
    tty.expectNeverInHistory "verification"
    tty.expectNeverInHistory "auto: goal check"
    tty.expectInHistory "⚑ run the tests"
    tty.expectInHistory "WORK_TURN_TWO"
    tty.expectNeverInHistory "\u276f run"   # nothing ever echoed a prompt
    # The continuation turn's satisfied check retires the goal.
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "achieved.md")
    check not fileExists(root / "run" / "goal.md")
    tty.expectAlive()

  test "inline verdict ending the verifier's prose line is honored":
    let root = newFixture("goal_inline_verdict")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "goal.md", "make the stub do one turn\n")
    # The shape a live verifier produced: the contract words terminate
    # the prose line instead of owning one. The reply's last words are
    # still the verdict, so the check must honor them - a red-x row
    # quoting `VERDICT: SATISFIED` it refuses is the bug.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("GOAL_WORK_DONE"),
      reply("The work is done and recorded. VERDICT: SATISFIED"),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.expectInHistory "\u2691 make the stub do one turn"
    tty.expectInHistory "GOAL_WORK_DONE"
    # The icon row honors the inline verdict: green check, contract
    # words stripped from the prose, goal retired.
    tty.expectInHistory "The work is done and recorded."
    tty.expectInHistory "\u2713"
    tty.expectNeverInHistory "VERDICT"
    tty.drain(300)
    check fileExists(root / "run" / "achieved.md")
    check not fileExists(root / "run" / "goal.md")
    tty.expectAlive()

suite "goal mode mid-turn detection (interactive)":
  test "goal.md written during a turn kicks off at the turn's end":
    let root = newFixture("goal_midturn_detect")
    writeConfiguredProvider(root)
    # The agent writes goal.md as part of an ordinary turn. That turn's
    # end is a DETECTION, not a check: the work just finished was never
    # aimed at the goal, so the boundary prints the detection hint and
    # runs the kickoff turn right there - the same immediate start a
    # startup detection and a `:goal` arm take. Only the kickoff turn's
    # own end runs the verifier.
    # Response 1: the write tool call. Response 2: the turn's final
    # reply. Response 3: the kickoff turn's reply. Response 4: the
    # kickoff turn's verifier (SATISFIED retires goal.md).
    writeFile(root / "run" / "stub_responses.json", $(%*[
      toolReply("write",
        """{"path": "goal.md", "body": "make the stub say GOAL_WORK_DONE"}"""),
      reply("GOAL_WRITTEN"),
      reply("GOAL_WORK_DONE"),
      reply("all done\nVERDICT: SATISFIED"),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    # The turn writes the file and finishes; no verifier judges that
    # turn - the kickoff's flag-led goal item lands instead (no hint
    # line), and the kickoff turn runs without any prompt.
    tty.expectInHistory "GOAL_WRITTEN"
    tty.expectNeverInHistory "detected implementing"
    tty.expectInHistory "⚑ make the stub say GOAL_WORK_DONE"
    tty.expectNeverInHistory "Goal armed:"
    tty.expectInHistory "GOAL_WORK_DONE"
    # The kickoff turn's end is the first check.
    tty.expectInHistory "\u2713"
    tty.expectNeverInHistory "verifying"
    tty.expectNeverInHistory "verification"
    tty.drain(300)
    check fileExists(root / "run" / "achieved.md")
    check not fileExists(root / "run" / "goal.md")
    tty.expectAlive()

  test "a goal queued mid-turn arms with the ⚑ item alone at the drain":
    let root = newFixture("goal_queued_midturn")
    writeConfiguredProvider(root)
    # `:goal TEXT` typed while a turn runs queues with the hourglass
    # echo like any line. At the drain the arm runs: the queue-time echo
    # is dropped instead of committed (the ⚑ kickoff item shows the goal
    # text, so the committed command line would repeat it), no receipt
    # lands, and the kickoff turn starts at once.
    # Response 1: the held-open first turn. Response 2: the kickoff
    # turn's reply. Response 3: its verifier.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "waitForTestContinue": true,
       "content": "FIRST_TURN_DONE", "contentChunks": ["FIRST_TURN_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      reply("GOAL_WORK_DONE"),
      reply("all done\nVERDICT: SATISFIED"),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start the turn\n"
    # Queue the arm mid-turn: the queue-time hourglass echo paints at
    # once (the queue's waiting-room display), pinned below the turn.
    tty.send ":goal make the stub say GOAL_WORK_DONE"
    tty.expect ":goal make the stub say GOAL_WORK_DONE"
    tty.send "\n"
    tty.expectInHistory "⧖"
    # Release the held reply; the drain arms the goal at the boundary.
    tty.continueStubApi()
    tty.expectInHistory "FIRST_TURN_DONE"
    # The committed record is the ⚑ item alone: the echo never commits
    # (the committed form has no hourglass) and no receipt lands.
    tty.expectInHistory "⚑ make the stub say GOAL_WORK_DONE"
    tty.expectNeverInHistory "goal armed"
    tty.expectNeverInHistory "Goal armed:"
    tty.expectInHistory "GOAL_WORK_DONE"
    # The kickoff turn's end runs the check; SATISFIED retires the file.
    tty.expectInHistory "\u2713"
    tty.drain(300)
    # The dropped echo never reaches the committed record: not on the
    # settled screen, where the ⚑ item is the only goal announcement.
    check tty.rowContaining("❯ :goal make the stub") == -1
    check tty.rowContaining("goal armed") == -1
    check tty.rowContaining("⚑ make the stub say GOAL_WORK_DONE") >= 0
    check fileExists(root / "run" / ".3code" / "achieved")
    check not fileExists(root / "run" / ".3code" / "goal")
    tty.expectAlive()

suite "goal mode resume (interactive)":
  test "a resumed session never re-feeds the kickoff stanza":
    let root = newFixture("goal_resume_no_refeed")
    writeConfiguredProvider(root)
    # Phase 1 arms the goal and leaves the mode live: the kickoff turn
    # answers, the turn-end verifier is Ctrl-C'd mid-call (the check is
    # skipped, goal.md stays), and the session exits with the kickoff
    # stanza already in the conversation.
    createDir(root / "run" / ".3code")
    writeFile(root / "run" / ".3code" / "goal",
      "keep working after resume\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("WORK_TURN_ONE"),
      reply("never reached\nVERDICT: SATISFIED", delayMs = 8000),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    tty.expect "\u276f"
    tty.expectInHistory "⚑ keep working after resume"
    tty.expectInHistory "WORK_TURN_ONE"
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    tty.ctrlD()
    tty.expectExit(0, timeoutMs = 5000)
    check fileExists(root / "run" / ".3code" / "goal")
    # Phase 2 resumes. The stub queue holds exactly two replies: the
    # answer to the typed prompt, then its turn-end verifier. If the
    # kickoff stanza were re-fed, it would consume the first reply and
    # every later assertion falls apart - the re-feed itself is what
    # the never-assertions catch.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("NEXT_AFTER_RESUME"),
      reply("all good\nVERDICT: SATISFIED"),
    ]))
    let tty2 = newTtySession(stub,
                            args = ["-x", "-i", "-r"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty2.writeFrameArtifact(root / "frames.txt")
      tty2.close()
    tty2.expectIdleCaret(timeoutMs = 8000)
    tty2.drain(300)
    # The replayed kickoff renders as the flag plus the goal text (old
    # sessions too), and nothing announces again: no stanza, no hint.
    tty2.expectInHistory "⚑ keep working after resume"
    tty2.expectNeverInHistory "Goal armed:"
    tty2.expectNeverInHistory "detected implementing"
    # The prompt answers with the first queued reply - proof no kickoff
    # turn burned it - and its turn-end check retires the goal.
    tty2.send "hello again"
    tty2.expect "hello again"
    tty2.send "\n"
    tty2.expectInHistory "NEXT_AFTER_RESUME"
    tty2.expectInHistory "\u2713"
    tty2.drain(300)
    check fileExists(root / "run" / ".3code" / "achieved")
    check not fileExists(root / "run" / ".3code" / "goal")
    tty2.expectAlive()
