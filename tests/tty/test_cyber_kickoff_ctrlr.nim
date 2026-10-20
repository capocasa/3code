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
    tty.expectInHistory "cybernetic.md written; starting toward it now"
    # The arm receipt carries the task counts...
    tty.expectInHistory "auto: cybernetic armed - starting toward cybernetic.md (1 task, 0 done)"
    # ...and so does the kickoff marker: title, counts, next task.
    tty.expectInHistory "\u25ce make the stub say PLAN_WORK_DONE - 1 task, 0 done; next: make the stub say PLAN_WORK_DONE"
    # The kickoff turn runs with no further keystroke.
    tty.expectInHistory "PLAN_WORK_DONE"
    # Turn end: detection receipt, then the verifier confirms and the
    # plan retires.
    tty.expectInHistory "cybernetic mode: cybernetic.md detected"
    tty.expectInHistory "cybernetic confirmed (cybernetic.md renamed to cybernetic-confirmed.md)"
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
    tty.expectInHistory "auto: cybernetic armed - starting toward cybernetic.md (1 task, 0 done)"
    tty.expectInHistory "\u25ce Plan - 1 task, 0 done; next: make the stub say PLAN_WORK_DONE"
    tty.expectInHistory "PLAN_WORK_DONE"
    tty.expectInHistory "cybernetic confirmed"
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
    tty.expectInHistory "auto: goal armed - starting toward goal.md"
    tty.expectInHistory "cybernetic.md is also on disk but goal mode is active; harness modes are mutually exclusive (:goal! cancels goal mode, then :cyber arms the plan)"
    tty.expectInHistory "GOAL_DONE"
    tty.expectInHistory "goal confirmed"
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
    tty.expectInHistory "cybernetic.md replaced; starting toward it now"
    tty.expectInHistory "auto: cybernetic armed - starting toward cybernetic.md (1 task, 0 done)"
    tty.expectInHistory "PLAN_WORK_DONE"
    tty.expectInHistory "cybernetic confirmed"
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
    # Startup detection kicks goal work off; Ctrl-C mid-stream pauses it.
    tty.expectInHistory "auto: goal armed - starting toward goal.md"
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
    tty.expectInHistory "cybernetic.md written; starting toward it now"
    tty.expectInHistory "PLAN_WORK_DONE"
    tty.expectInHistory "cybernetic confirmed"
    tty.drain(300)
    check fileExists(root / "run" / "cybernetic-confirmed.md")
    tty.expectAlive()
