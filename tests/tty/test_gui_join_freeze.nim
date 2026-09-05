discard """
  disabled: "win"
  ## PTY stress with timing-sensitive expect loops; ConPTY output latency
  ## makes the turn-completion waits unreliable. POSIX-only regression.
"""
## Regression stress: rapid spinner/bar-tick start-stop cycling with
## concurrent input. The GUI animation thread used to hold frameModelLock
## across its entire render tick; `stopGui` joins the thread from controller
## paths that can hold inputStateLock (consumeQueuedInput -> stopSpinner)
## while the tick's render also needs locks the join path holds: caller
## waits for join, tick waits for the lock, hard freeze. Expect timeouts
## trip the freeze.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
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

suite "spinner/bar-tick churn with concurrent input does not freeze":
  test "rapid turn + interrupt cycling stays responsive":
    let root = newFixture("gui_join_freeze")
    writeConfiguredProvider(root)
    var responses = newJArray()
    # Cycle three turn shapes: slow (interrupt mid-spinner), fast (full
    # spinner start/stop), bash tool (bar-tick start/stop). 45 turns of
    # gui-thread churn.
    for i in 1 .. 45:
      case i mod 3
      of 1:
        responses.add %*{"role": "assistant", "preStreamDelayMs": 1500,
                        "content": "slow reply " & $i,
                        "contentChunks": ["slow reply " & $i],
                        "usage": {"promptTokens": 5, "completionTokens": 2,
                                  "totalTokens": 7, "cachedTokens": 0}}
      of 2:
        responses.add %*{"role": "assistant", "preStreamDelayMs": 30,
                        "content": "fast reply " & $i,
                        "contentChunks": ["fast reply " & $i],
                        "usage": {"promptTokens": 5, "completionTokens": 2,
                                  "totalTokens": 7, "cachedTokens": 0}}
      else:
        responses.add %*{"role": "assistant",
          "tool_calls": [{
            "id": "call_" & $i, "type": "function",
            "function": {"name": "bash",
              "arguments": $(%*{"command": "printf 'tool line\\n'"})},
            "stub": {"stream": ["tool line"], "output": "tool line\n",
                      "code": 0}
          }],
          "usage": {"promptTokens": 5, "completionTokens": 2,
                    "totalTokens": 7, "cachedTokens": 0}}
        responses.add %*{"role": "assistant", "preStreamDelayMs": 30,
                        "content": "after tool " & $i,
                        "contentChunks": ["after tool " & $i],
                        "usage": {"promptTokens": 5, "completionTokens": 2,
                                  "totalTokens": 7, "cachedTokens": 0}}
    writeFile(root / "run" / "stub_responses.json", $responses)
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.close()
    tty.expect "\u276f"
    for i in 1 .. 45:
      tty.send "turn " & $i
      tty.send "\n"
      case i mod 3
      of 1:
        # Slow turn: let the spinner paint a few frames, type into the live
        # editor while it repaints, then interrupt mid-spinner.
        tty.drain(120)
        tty.send "typing during spinner"
        tty.drain(60)
        # The interrupt line recurs every third turn; an occurrence-count
        # snapshot stops an earlier turn's copy from satisfying the wait
        # before THIS turn's interrupt has landed (the OSX race).
        let seenInterrupts = tty.countInHistory("interrupted by user")
        tty.send "\x1b"  # ESC: cancel the in-flight turn
        tty.expectNewInHistory("interrupted by user", seenInterrupts)
        tty.expectIdleCaret()
      of 2:
        # Fast turn: full spinner start -> content -> stop cycle.
        tty.expectInHistory "fast reply " & $i
        tty.expectIdleCaret()
      else:
        # Bash tool turn: bar-tick start -> tool viewport -> stop cycle.
        tty.expectInHistory "after tool " & $i
        tty.expectIdleCaret()
      tty.expectAlive()
    echo "  PASS: 45 turns of spinner/bar-tick churn + interrupts did not freeze"
