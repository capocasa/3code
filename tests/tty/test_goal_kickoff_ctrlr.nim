discard """
  disabled: "win"
"""
## Interactive coverage for the two controller-level features that unit
## suites cannot reach (they live behind the input thread and the idle
## REPL loop):
##
## - Ctrl+R retry: the keystroke must travel input thread ->
##   `onRetryRequest` -> `requestTurnRetry`, and the retry backoff must
##   break immediately when it lands (the transport-level contract is
##   covered by tests/stream; this is the wiring).
## - Goal kickoff: `:goal TEXT` at the idle prompt must start goal
##   achievement immediately (a harness-autosent turn, no second prompt),
##   and the turn-end verifier must then confirm and retire goal.md.
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

suite "ctrl-r retry and goal kickoff (interactive)":
  test "ctrl-r during a 429 backoff retries immediately":
    let root = newFixture("ctrl_r_backoff")
    writeConfiguredProvider(root)
    # A 429 whose backoff is 6000ms, then a normal reply. Ctrl+R pressed
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
    # Ctrl+R (raw 0x12) mid-backoff: the wait breaks and the resend runs.
    tty.send "\x12"
    let t0 = epochTime()
    check tty.expectInHistory("recovered", timeoutMs = 4000)
    let elapsed = epochTime() - t0
    check elapsed < 5.0
    tty.expectAlive()

  test ":goal TEXT kicks off goal work immediately, verifier confirms":
    let root = newFixture("goal_kickoff")
    writeConfiguredProvider(root)
    check not fileExists(root / "run" / "goal.md")
    # Response 1 goes to the kickoff turn; response 2 is the turn-end
    # verifier side call (satisfied verdict retires goal.md).
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
    tty.send ":goal make the stub say GOAL_WORK_DONE"
    tty.expect ":goal make the stub say GOAL_WORK_DONE"
    tty.send "\n"
    # The command receipt says work starts now...
    tty.expectInHistory "starting toward it now"
    # ...and the kickoff turn runs without any further keystroke: the
    # harness-autosent receipt lands and the stub's first reply streams.
    tty.expectInHistory "auto: goal armed - starting toward goal.md"
    tty.expectInHistory "GOAL_WORK_DONE"
    # Turn end: the verifier side call answers SATISFIED and retires the
    # file. The session idles with the confirmed record on disk.
    tty.expectInHistory "goal confirmed"
    tty.drain(300)
    check fileExists(root / "run" / "goal-confirmed.md")
    check not fileExists(root / "run" / "goal.md")
    tty.expectAlive()

  test "verifier steps land in scrollback; keys typed during the check survive":
    let root = newFixture("goal_verify_steps")
    writeConfiguredProvider(root)
    # Round 1: the kickoff reply. Round 2: a fast verifier bash whose
    # step row lands in scrollback immediately (ARMING). Round 3: a slow
    # verifier bash; keystrokes typed right after ARMING land inside its
    # run. Round 4: the satisfied verdict. Round 5: the reply to the
    # user's next prompt, submitted AFTER the check: the text typed
    # mid-check must still be in the editor, proving the side call's
    # bash runs never ate the keys (the tool stdin watcher used to arm
    # for them and swallow everything).
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "v1", "type": "function",
         "function": {"name": "bash",
           "arguments": "{\"command\":\"echo ARMING\"}"}}],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "v2", "type": "function",
         "function": {"name": "bash",
           "arguments": "{\"command\":\"sleep 3; echo VERIFY_RAN\"}"}}],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
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
    tty.send ":goal make the tree say VERIFY_RAN"
    tty.send "\n"
    tty.expectInHistory "starting toward it now"
    tty.expectInHistory "GOAL_WORK_DONE"
    # The receipt commits before the side call; the verifier's bash round
    # is running by the moment it lands, so these keystrokes must ride
    # out the whole check in the editor buffer.
    tty.expectInHistory "goal mode: goal.md detected"
    # ARMING's step row means the verifier's next bash is the sleep:
    # keystrokes sent now are inside the watcher's old arming window.
    tty.expectInHistory "ARMING"
    # The tier marker itself: dim, indented `· verify`, never flush-left
    # agent items.
    tty.expectInHistory "· verify"
    tty.send "SURVIVED_KEYS"
    tty.drain(300)
    # The check shows its work: each step row and its result head are in
    # scrollback, dim and indented, before the verdict lands.
    tty.expectInHistory "VERIFY_RAN"
    tty.expectInHistory "goal confirmed"
    check fileExists(root / "run" / "goal-confirmed.md")
    check not fileExists(root / "run" / "goal.md")
    # Submit the buffer that lived through the check: the echoed prompt
    # only appears if every keystroke survived the side call's bash runs.
    tty.send "\n"
    tty.expectInHistory "SURVIVED_KEYS"
    tty.expectInHistory "NEXT_TURN_OK"
    tty.expectAlive()

  test "ctrl-c during the verifier round interrupts the check, goal stays":
    let root = newFixture("goal_verify_interrupt")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "GOAL_WORK_DONE", "contentChunks": ["GOAL_WORK_DONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "v1", "type": "function",
         "function": {"name": "bash",
           "arguments": "{\"command\":\"sleep 8\"}"}}],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
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
    tty.expectInHistory "GOAL_WORK_DONE"
    tty.expectInHistory "goal mode: goal.md detected"
    # Ctrl-C while the verifier's bash runs: with the watcher disarmed
    # the key reaches the editor, interrupts the turn, kills the tool
    # child, and skips the satisfaction check. goal.md survives.
    tty.drain(400)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.drain(300)
    check fileExists(root / "run" / "goal.md")
    check not fileExists(root / "run" / "goal-confirmed.md")
    tty.expectAlive()
