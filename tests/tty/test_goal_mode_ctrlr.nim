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
## - Goal mode wiring: the file is the whole mode. `:goal TEXT` writes
##   goal.md and answers with the arm receipt - no turn runs - and the
##   turn-end verifier then confirms and retires goal.md to achieved.md.
##   A goal.md already on disk at startup must do nothing at all: the
##   first prompt is the first turn, and only its end runs the check.
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

  test ":goal TEXT arms; the next turn's end confirms and retires":
    let root = newFixture("goal_kickoff")
    writeConfiguredProvider(root)
    check not fileExists(root / "run" / "goal.md")
    # Response 1 goes to the user's first prompt; response 2 is the
    # turn-end verifier side call (satisfied verdict retires goal.md).
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
    # The arm is the file plus one receipt line - no turn runs, the
    # proof being that no model reply streams before a prompt is sent.
    tty.expectInHistory "goal armed (goal.md)"
    tty.expectNeverInHistory "GOAL_WORK_DONE"
    tty.send "go"
    tty.send "\n"
    tty.expectInHistory "GOAL_WORK_DONE"
    # Turn end: detection receipt, then the verifier's reply renders as
    # a dim quote block led by the green ✓ icon (verdict line stripped);
    # that ✓ is the confirmation, no 'goal confirmed' receipt. The
    # session idles with the achieved record on disk.
    tty.expectInHistory "goal mode: goal.md detected"
    tty.expectInHistory "all done"
    tty.expectNeverInHistory "VERDICT"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check fileExists(root / "run" / "achieved.md")
    check not fileExists(root / "run" / "goal.md")
    tty.expectAlive()

  test "goal.md present at startup does nothing until work runs":
    let root = newFixture("goal_startup_inert")
    writeConfiguredProvider(root)
    # goal.md is written before the session starts - how a user (or any
    # other tool) arms a goal without ever touching :goal. Startup must
    # leave it inert: no turn runs, the file just sits armed.
    writeFile(root / "run" / "goal.md", "make the stub say GOAL_WORK_DONE\n")
    # Response 1 goes to the user's first prompt; response 2 is the
    # turn-end verifier side call (satisfied verdict retires goal.md);
    # response 3 answers the follow-up prompt that proves the session
    # idles normally.
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
    # Nothing is typed yet and nothing happens: no kickoff turn, no
    # detection receipt, no model call. The armed file alone is inert.
    tty.drain(400)
    tty.expectNeverInHistory "GOAL_WORK_DONE"
    tty.expectNeverInHistory "goal mode: goal.md detected"
    check fileExists(root / "run" / "goal.md")
    # The first prompt is the first turn; its end is what arms the
    # check - detection receipt, verifier, and the retirement to
    # achieved.md all hang off that boundary.
    tty.send "go"
    tty.expect "go"
    tty.send "\n"
    tty.expectInHistory "GOAL_WORK_DONE"
    tty.expectInHistory "goal mode: goal.md detected"
    tty.expectInHistory "\u2713"
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
    tty.expectInHistory "goal armed (goal.md)"
    tty.expectNeverInHistory "GOAL_WORK_DONE"
    tty.send "go"
    tty.send "\n"
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
    check fileExists(root / "run" / "achieved.md")
    check not fileExists(root / "run" / "goal.md")
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
    tty.expectInHistory "goal armed (goal.md)"
    tty.send "go"
    tty.send "\n"
    tty.expectInHistory "GOAL_WORK_DONE"
    tty.expectInHistory "goal mode: goal.md detected"
    # Ctrl-C while the verifier's slow model call runs: the interrupt is
    # honored after the side call returns, skips the satisfaction check,
    # and ends the turn. goal.md survives.
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    check fileExists(root / "run" / "goal.md")
    check not fileExists(root / "run" / "achieved.md")
    tty.expectAlive()
