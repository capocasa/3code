discard """
  disabled: "win"
"""
## Interactive coverage for the controller-level features that unit
## suites cannot reach (they live behind the input thread and the idle
## REPL loop):
##
## - Goal mode wiring: the conversation is the whole mode. `:goal TEXT`
##   appends the kickoff and runs the turn at once; a goal.md left on
##   disk (the upgrade case) arms nothing. The arm announces with the
##   kickoff item alone - the `⚑` flag plus the goal text, no echoed
##   command line, no receipt, no hint line, no `Goal armed:` scaffold -
##   and the stanza is fed exactly once per arming: a resumed session
##   never re-feeds it, it just derives goal mode from the .3log. Each
##   turn end runs the verifier whose reply is the whole display - a
##   quote block led by the green `✓` or red `✗` icon, no notice
##   before or after it. An unmet verdict sends the agent back in under
##   the `⚑` marker and the next turn starts on its own; a satisfied
##   one retires the goal in the .3log (a `goal_check verdict=satisfied`
##   record), and a new `:goal` arms the next one.
import std/[json, os, strutils, unittest, times]
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

proc sessionLogHas(root, want: string): bool =
  ## True once some session file in the fixture's data root carries
  ## `want`: the .3log is where the goal's retirement record lands now
  ## that no file on disk ever holds goal state.
  for f in walkFiles(root / "xdg" / "3code" / "sessions" / "*.3log"):
    try:
      if want in readFile(f): return true
    except CatchableError: discard
  false

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  let data = root / "data"
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "test.stub_responses", val: responsesPath),
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

suite "goal mode (interactive)":
  test ":goal TEXT arms; the kickoff turn runs at once":
    let root = newFixture("goal_kickoff")
    writeConfiguredProvider(root)
    # Response 1 goes to the kickoff turn the arm starts; response 2 is
    # its turn-end verifier side call (a satisfied verdict retires the
    # goal into the .3log).
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
    # The retirement record is the satisfied goal_check in the .3log;
    # nothing on disk holds goal state.
    check sessionLogHas(root, "goal_check verdict=satisfied")
    check not fileExists(root / "run" / "goal.md")
    tty.expectAlive()

  test "a goal.md left on disk arms nothing":
    let root = newFixture("goal_startup_kickoff")
    writeConfiguredProvider(root)
    # The upgrade scenario: a goal.md left in the project root by an
    # older 3code (or written by hand). The file is no longer the
    # protocol - startup must not arm goal mode, no kickoff runs, and
    # an ordinary prompt answers with the FIRST queued reply (a kickoff
    # turn would burn it), with no verifier call behind it.
    writeFile(root / "run" / "goal.md", "make the stub say GOAL_WORK_DONE\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("NEXT_TURN_OK"),
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
    tty.drain(300)
    # No kickoff item, no self-started turn, nothing armed.
    tty.expectNeverInHistory "\u2691"
    tty.expectNeverInHistory "Goal armed:"
    tty.expectNeverInHistory "GOAL_WORK_DONE"
    tty.send "still here"
    tty.expect "still here"
    tty.send "\n"
    tty.expectInHistory "NEXT_TURN_OK"
    tty.drain(300)
    # No verifier side call ever fired and no retirement record exists;
    # the stale file itself stays untouched.
    check not sessionLogHas(root, "goal_check")
    check fileExists(root / "run" / "goal.md")
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
    # The check's tokens are accounted like a main call's: the resting
    # bar adds them onto the turn's own numbers (stub replies carry
    # 5 up / 2 down each, so turn + check = 10/4) instead of being
    # replaced by the check's 5/2.
    tty.drain(200)
    tty.expectInHistory "↑10  ↓4"
    check sessionLogHas(root, "goal_check verdict=satisfied")
    # Submit the buffer that lived through the check: the echoed prompt
    # only appears if every keystroke survived the side call.
    tty.send "\n"
    tty.expectInHistory "SURVIVED_KEYS"
    tty.expectInHistory "NEXT_TURN_OK"
    tty.expectAlive()

  test "the bar sums every side call at one rest, not just the latest":
    let root = newFixture("goal_side_sum")
    writeConfiguredProvider(root)
    # Response 1: the kickoff turn (5/2). Response 2: its turn-end
    # verifier check (5/2, satisfied - the goal retires and the session
    # idles on turn+check = 10/4). Response 3: a :btw aside asked while
    # idle at that rest (4/1): its answer must add onto the bar the
    # check already fed, landing on 14/5 - the second side call may
    # never replace the first one's contribution.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "checked.\nVERDICT: SATISFIED",
       "contentChunks": ["checked.\nVERDICT: SATISFIED"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "SIDE_ANSWER", "contentChunks": ["SIDE_ANSWER"],
       "usage": {"promptTokens": 4, "completionTokens": 1,
                  "totalTokens": 5, "cachedTokens": 0}}
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
    tty.expectInHistory "GOAL_WORK_DONE"
    tty.expectInHistory "\u2713"
    # The rest after the check: turn + check on the bar.
    tty.drain(200)
    tty.expectInHistory "↑10  ↓4"
    # An aside at the same rest: its answer adds onto the running total.
    tty.send ":btw what did the check cost?"
    tty.send "\n"
    tty.expectInHistory "SIDE_ANSWER"
    tty.drain(300)
    tty.expectInHistory "↑14  ↓5"
    tty.expectAlive()

  test "ctrl-c during the verifier call cancels the goal":
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
    # Ctrl-C while the verifier's slow model call runs: the interrupt
    # ends the mode itself - the user overrides - with the same ⊘
    # retirement record a bare `:goal!` writes.
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.expectInHistory "goal cancelled"
    tty.drain(300)
    check sessionLogHas(root, "goal_check verdict=cancelled")
    # The verb reports no live goal.
    tty.send ":goal"
    tty.expect ":goal"
    tty.send "\n"
    tty.expect "no goal active"
    tty.drain(200)
    tty.expectAlive()

  test "unmet verdict shows the evaluation, then just continues":
    let root = newFixture("goal_feedback_continue")
    writeConfiguredProvider(root)
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
    tty.send ":goal make the stub do two turns"
    tty.send "\n"
    tty.drain(100)
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
    check sessionLogHas(root, "goal_check verdict=satisfied")
    tty.expectAlive()

  test "inline verdict ending the verifier's prose line is honored":
    let root = newFixture("goal_inline_verdict")
    writeConfiguredProvider(root)
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
    tty.send ":goal make the stub do one turn"
    tty.send "\n"
    tty.drain(100)
    tty.expectInHistory "\u2691 make the stub do one turn"
    tty.expectInHistory "GOAL_WORK_DONE"
    # The icon row honors the inline verdict: green check, contract
    # words stripped from the prose, goal retired.
    tty.expectInHistory "The work is done and recorded."
    tty.expectInHistory "\u2713"
    tty.expectNeverInHistory "VERDICT"
    tty.drain(300)
    check sessionLogHas(root, "goal_check verdict=satisfied")
    tty.expectAlive()

suite "goal mode mid-turn detection (interactive)":
  test "the agent writing goal.md arms nothing":
    let root = newFixture("goal_midturn_file_inert")
    writeConfiguredProvider(root)
    # The agent writes goal.md as part of an ordinary turn. The file is
    # no longer the protocol, so the turn's end is an ordinary end: no
    # detection, no kickoff turn, no verifier - the session idles and
    # the next queued reply belongs to the user's next prompt.
    # Response 1: the write tool call. Response 2: the turn's final
    # reply. Response 3: the next prompt's reply.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      toolReply("write",
        """{"path": "goal.md", "body": "make the stub say GOAL_WORK_DONE"}"""),
      reply("GOAL_WRITTEN"),
      reply("NEXT_TURN_OK"),
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
    tty.expectInHistory "GOAL_WRITTEN"
    tty.drain(300)
    # No kickoff, no self-started turn, no check. (The goal text itself
    # does appear - the write tool's echo shows the file body - so the
    # assertions watch the mode's own surfaces, not the text.)
    tty.expectNeverInHistory "\u2691"
    tty.expectNeverInHistory "Goal armed:"
    check not sessionLogHas(root, "goal_check")
    check fileExists(root / "run" / "goal.md")
    tty.send "next"
    tty.expect "next"
    tty.send "\n"
    tty.expectInHistory "NEXT_TURN_OK"
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
    check sessionLogHas(root, "goal_check verdict=satisfied")
    tty.expectAlive()

suite "goal mode resume (interactive)":
  test "a resumed session never re-feeds the kickoff stanza":
    let root = newFixture("goal_resume_no_refeed")
    writeConfiguredProvider(root)
    # Phase 1 arms the goal and leaves the mode live: the kickoff turn
    # is Ctrl-C'd mid-call (an interrupt mid-call never reaches the
    # end-call boundary, so the mode stays armed), and the session exits
    # with the kickoff stanza already in the conversation.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("WORK_TURN_ONE", delayMs = 8000),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    tty.expect "\u276f"
    tty.send ":goal keep working after resume"
    tty.send "\n"
    tty.drain(100)
    tty.expectInHistory "⚑ keep working after resume"
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    tty.ctrlD()
    tty.expectExit(0, timeoutMs = 5000)
    check not sessionLogHas(root, "verdict=satisfied")
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
    check sessionLogHas(root, "goal_check verdict=satisfied")
    tty2.expectAlive()

  test "a resumed session replays the verifier's verdict row":
    # The goal verify itself must survive loading scrollback from disk:
    # the verdict row a live session painted (the ✗ quote block after
    # the turn's reply) replays on `-r` between that reply and the ⚑
    # continuation it sent, not just the continuation's embedded
    # feedback text.
    let root = newFixture("goal_resume_verify_row")
    writeConfiguredProvider(root)
    # Phase 1: the kickoff turn answers, its verifier replies FEEDBACK
    # with a prose marker, and the turn the feedback starts is
    # interrupted mid-call so the mode stays armed for phase 2.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("WORK_TURN_ONE"),
      reply("VERIFY_PROSE_MARKER\nVERDICT: FEEDBACK: FEEDBACK_MARKER_NEXT"),
      reply("WORK_TURN_TWO", delayMs = 8000),
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    tty.expect "\u276f"
    tty.send ":goal keep working after resume"
    tty.send "\n"
    tty.drain(100)
    tty.expectInHistory "⚑ keep working after resume"
    tty.expectInHistory "WORK_TURN_ONE"
    # The live verdict row: the verifier's prose as a quoted step.
    tty.expectInHistory "VERIFY_PROSE_MARKER"
    tty.drain(300)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    tty.ctrlD()
    tty.expectExit(0, timeoutMs = 5000)
    # Phase 2: resume. The replayed scrollback keeps the verdict row at
    # its position: after WORK_TURN_ONE, before the ⚑ goal-check
    # continuation.
    let tty2 = newTtySession(stub,
                            args = ["-x", "-i", "-r"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty2.writeFrameArtifact(root / "frames.txt")
      tty2.close()
    tty2.expectIdleCaret(timeoutMs = 8000)
    tty2.drain(300)
    tty2.expectInHistory "VERIFY_PROSE_MARKER"
    let hist = tty2.cleanRaw()
    check hist.find("VERIFY_PROSE_MARKER") > hist.find("WORK_TURN_ONE")
    check hist.find("VERIFY_PROSE_MARKER") <
        hist.find("Verifier feedback:")
    tty2.expectAlive()
