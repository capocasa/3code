discard """
  disabled: "win"
"""
## Interactive coverage for the cybernetic mode surfaces that unit suites
## cannot reach (they live behind the input thread and the idle REPL
## loop): the `:cyber` verb at the live prompt (skeleton write, bare
## status, usage errors, force replace), the plan-aware kickoff marker
## and receipts with task counts, startup detection of a cybernetic.md
## that was already on disk, retirement to cybernetic-confirmed.md, and
## the mutual-exclusivity refusal when both mode files exist.
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

suite "cyber mode surfaces (interactive)":
  test ":cyber TEXT arms a plan skeleton and kicks off with counts":
    let root = newFixture("cyber_kickoff")
    writeConfiguredProvider(root)
    check not fileExists(root / "run" / "cybernetic.md")
    # Response 1 goes to the kickoff turn; response 2 is the turn-end
    # verifier side call (satisfied verdict retires cybernetic.md).
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("PLAN_WORK_DONE"),
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
    # Verb error paths at the live prompt: bare status with no plan,
    # cancel with no plan, usage-less new, and the prefix form :cy.
    tty.send ":cyber"
    tty.send "\n"
    tty.expect "no cybernetic active"
    tty.send ":cyber cancel"
    tty.send "\n"
    tty.expect "no cybernetic active"
    tty.send ":cy new"
    tty.send "\n"
    tty.expect "usage"
    tty.drain(100)
    tty.send ":cyber make the stub say PLAN_WORK_DONE"
    tty.expect ":cyber make the stub say PLAN_WORK_DONE"
    tty.send "\n"
    tty.drain(100)
    # The arm is quiet (the echoed command says it), so the streamed
    # reply is the proof the kickoff turn ran with no further keystroke.
    tty.expectInHistory "PLAN_WORK_DONE"
    # Turn end: detection receipt, then the verifier's green ✓ item - no
    # confirmed receipt - and the plan retires on disk.
    tty.expectInHistory "cybernetic mode: cybernetic.md detected"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    check not fileExists(root / "run" / "cybernetic.md")
    tty.expectAlive()

  test "cybernetic.md present at startup kicks off with no keystroke":
    let root = newFixture("cyber_startup_kickoff")
    writeConfiguredProvider(root)
    # A cybernetic.md written before the session starts arms exactly like
    # `:cyber` did: startup detection loads it and sends the agent off.
    writeFile(root / "run" / "cybernetic.md",
      "# Plan\n\n- [ ] make the stub say PLAN_WORK_DONE\n\n" &
      "## Current state\n\nNot begun.\n")
    # Response 1: kickoff turn. Response 2: verifier (SATISFIED retires
    # the plan). Response 3: the follow-up prompt proving idle.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("PLAN_WORK_DONE"),
      reply("all done\nVERDICT: SATISFIED"),
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
    # Quiet startup kickoff like goal mode's; the reply is the proof.
    tty.expectInHistory "PLAN_WORK_DONE"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    check not fileExists(root / "run" / "cybernetic.md")
    # Back to an ordinary idle prompt, no second kickoff.
    tty.send "still here"
    tty.expect "still here"
    tty.send "\n"
    tty.expectInHistory "NEXT_TURN_OK"
    tty.expectAlive()

  test "both mode files on disk: first entry wins, refusal is said out loud":
    let root = newFixture("cyber_exclusive")
    writeConfiguredProvider(root)
    # goal.md AND cybernetic.md on disk at startup: goal mode (registry
    # entry #1) arms, the conflict receipt teaches instead of silently
    # dropping the plan. Responses: goal kickoff, goal verifier
    # (SATISFIED retires goal.md), then :cyber! replaces the stale plan
    # and ITS kickoff + verifier run.
    writeFile(root / "run" / "goal.md", "say GOAL_DONE\n")
    writeFile(root / "run" / "cybernetic.md",
      "- [ ] stale hand-written plan\n\n## Current state\n\ns\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("GOAL_DONE"),
      reply("all done\nVERDICT: SATISFIED"),
      reply("PLAN_WORK_DONE"),
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
    # goal mode wins the registry walk; the refusal names both verbs.
    tty.expectInHistory "GOAL_DONE"
    tty.expectInHistory "cybernetic.md is also on disk but goal mode is active; harness modes are mutually exclusive (:goal! cancels goal mode, then :cyber arms the plan)"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    # goal.md is retired; the stale cybernetic.md is now the live plan
    # and bare :cyber shows it.
    tty.send ":cyber"
    tty.send "\n"
    tty.expect "stale hand-written plan"
    tty.drain(100)
    # Force replace through the verb, then the plan runs to completion.
    tty.send ":cyber! make the stub say PLAN_WORK_DONE"
    tty.expect ":cyber! make the stub say PLAN_WORK_DONE"
    tty.send "\n"
    tty.expectInHistory "PLAN_WORK_DONE"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check not fileExists(root / "run" / "goal.md")
    check not fileExists(root / "run" / "cybernetic.md")
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    tty.expectAlive()

  test ":cyber balks while goal mode is live, with the teaching error":
    let root = newFixture("cyber_verb_exclusive")
    writeConfiguredProvider(root)
    # The one idle window where goal.md is still live: interrupt. The
    # startup kickoff turn is Ctrl-C'd mid-stream (the check is skipped,
    # goal stays armed), and at the idle prompt :cyber must refuse with
    # the teaching error instead of arming a second mode. Responses: the
    # slow aborted kickoff (consumed at selection), then the :cyber
    # kickoff and its verifier.
    writeFile(root / "run" / "goal.md", "say GOAL_DONE\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("never streams", delayMs = 8000),
      reply("PLAN_WORK_DONE"),
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
    # Startup detection kicks goal work off; Ctrl-C mid-stream pauses
    # it. The kickoff is quiet, so wait out the pre-stream delay's start
    # before interrupting.
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    check fileExists(root / "run" / "goal.md")
    # goal mode is live at the idle prompt: :cyber refuses, naming the
    # live mode's file and its exit.
    tty.send ":cyber arm my plan"
    tty.expect ":cyber arm my plan"
    tty.send "\n"
    tty.expectInHistory "goal.md (goal mode) is already active; harness modes are mutually exclusive - cancel it first with :goal!"
    tty.drain(200)
    check not fileExists(root / "run" / "cybernetic.md")
    # Cancel goal, then the same verb arms cleanly and runs to done.
    tty.send ":goal!"
    tty.send "\n"
    tty.expectInHistory "goal cancelled (goal.md renamed to goal-cancelled.md)"
    tty.drain(200)
    tty.send ":cyber arm my plan"
    tty.expect ":cyber arm my plan"
    tty.send "\n"
    tty.expectInHistory "PLAN_WORK_DONE"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    tty.expectAlive()

proc toolReply(name, argsJson: string; content = ""): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": 50, "content": content,
     "tool_calls": [{"id": "c" & $epochTime(), "type": "function",
       "function": {"name": name, "arguments": argsJson}}],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}

suite "cyber mode direction machinery (interactive)":
  test "update discipline: work without a plan update gets the mechanical note":
    let root = newFixture("cyber_discipline")
    writeConfiguredProvider(root)
    # The model does real work (a bash tool call) but never touches
    # cybernetic.md. The first check must merge the verifier's FEEDBACK
    # with the mechanical update note; after the model finally checks
    # the box, no note rides and the verifier confirms.
    writeFile(root / "run" / "cybernetic.md",
      "# Plan\n\n- [ ] make the stub say DONE\n\n" &
      "## Current state\n\nNot begun.\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      toolReply("bash", """{"command": "echo real work > work.txt"}"""),
      reply("I did the work"),
      reply("the task is not checked off\nVERDICT: FEEDBACK: check the box"),
      toolReply("write",
        """{"path": "cybernetic.md", "body": "# Plan\n\n- [x] make the stub say DONE\n\n## Current state\n\nWork done for real.\n"}"""),
      reply("plan updated"),
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
    # Kickoff turn: a real mutation runs (the bash output lands in the
    # session change log too, powering work-happened), the plan file
    # stays untouched. A reads-only turn would owe no update note.
    tty.expectInHistory "real work"
    # Turn end: FEEDBACK from the verifier AND the discipline note, one
    # continuation carrying both.
    tty.expectInHistory "cybernetic check: feedback"
    tty.expectInHistory "check the box"
    tty.expectInHistory "cybernetic.md is unchanged"
    # The model updates the plan; the next check has no note to add and
    # the verifier confirms against the checked plan.
    tty.expectInHistory "plan updated"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    check not fileExists(root / "run" / "cybernetic.md")
    tty.expectAlive()

  test "structure loss mid-run: restore continuation, mode stays latched":
    let root = newFixture("cyber_structure_loss")
    writeConfiguredProvider(root)
    # The model destroys the plan format (a prose-only rewrite). The
    # boundary must refuse to run the verifier, say the structure was
    # lost, and send the agent back to restore - the mode stays armed.
    # After the restore, the verifier runs normally and confirms.
    writeFile(root / "run" / "cybernetic.md",
      "# Plan\n\n- [ ] keep the format\n\n" &
      "## Current state\n\nNot begun.\n")
    writeFile(root / "run" / "stub_responses.json", $(%*[
      toolReply("write",
        """{"path": "cybernetic.md", "body": "just prose now, no tasks, no sections\n"}"""),
      reply("rewrote it"),
      toolReply("write",
        """{"path": "cybernetic.md", "body": "# Plan\n\n- [x] keep the format\n\n## Current state\n\nRestored.\n"}"""),
      reply("restored the plan"),
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
    # The rewrite lands; the boundary catches the broken format before
    # any verifier call.
    tty.expectInHistory "rewrote it"
    tty.expectInHistory "cybernetic check: plan structure lost"
    tty.expectInHistory "at least one task item"
    # The mode never dropped: the restore turn runs, then the verifier
    # judges the restored plan and confirms.
    tty.expectInHistory "restored the plan"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    check not fileExists(root / "run" / "cybernetic.md")
    tty.expectAlive()

suite "cyber mode rollover (interactive)":
  test "context collapse at the pressure threshold hands off to the plan":
    let root = newFixture("cyber_rollover")
    writeConfiguredProvider(root)
    # Six tool rounds cross decideContextAction's message floor (12 =
    # system + kickoff + 5 pairs + the 6th reply); the 6th reply's usage
    # crosses the token threshold (11k of the stub's 12k window), so the
    # harness collapses - and the summarizer meta-call is served from the
    # same canned queue (stubNextSummarizerReply). The rollover handoff
    # must follow the tool results (pairing settles first), then the
    # session recovers and the verifier confirms.
    writeFile(root / "run" / "cybernetic.md",
      "# Plan\n\n- [x] first done\n- [ ] make the stub say RECOVERED\n\n" &
      "## Current state\n\nPhase 3 merged. Rollover is next.\n")
    var responses = newJArray()
    for i in 1 .. 6:
      let big = i == 6
      responses.add %*{"role": "assistant", "preStreamDelayMs": 50,
        "content": "", "tool_calls": [{"id": "c" & $i, "type": "function",
          "function": {"name": "bash",
            "arguments": "{\"command\": \"echo work " & $i & "\"}"}}],
        "usage": {"promptTokens": (if big: 11000 else: 500),
                   "completionTokens": 2, "totalTokens": 7,
                   "cachedTokens": 0}}
    # The summarizer meta-call's reply (consumed by the stub queue):
    responses.add reply("did several steps of plan work")
    # The post-collapse model reply and the turn-end verifier:
    responses.add reply("RECOVERED")
    responses.add reply("all done\nVERDICT: SATISFIED")
    writeFile(root / "run" / "stub_responses.json", $responses)
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    # Six tool rounds run; the sixth crosses the threshold.
    tty.expectInHistory "work 6"
    # The collapse receipt, then the rollover: receipted like every
    # harness act, with the plan's counts.
    tty.expectInHistory "summarized"
    tty.expectInHistory "auto: cybernetic rollover - plan at cybernetic.md (2 tasks, 1 done)"
    # The handoff itself lands as a `»` continuation: re-anchoring at
    # the plan file, next task by name, Current state quoted.
    tty.expectInHistory "Context rollover:"
    tty.expectInHistory "Next unchecked task:"
    tty.expectInHistory "Current state from the plan:"
    tty.expectInHistory "Phase 3 merged. Rollover is next."
    # The fresh context answers and the verifier confirms.
    tty.expectInHistory "RECOVERED"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    check not fileExists(root / "run" / "cybernetic.md")
    tty.expectAlive()
