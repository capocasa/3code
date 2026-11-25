discard """
  disabled: "win"
  ## tty tests are POSIX-only by convention (ConPTY timing); the aside's
  ## delivery timing assertions need a real PTY's frame cadence.
"""
## `:btw` never blocks the prompt (the dev-guidelines rule): the command
## returns at once, the typed line landing in scrollback as the `?`-led
## question item (the command name dropped), the side-question meta-call
## runs on a worker thread, and the answer lands in scrollback afterwards
## — dim, led by the `!` icon, with its burned tokens added onto the
## token bar so the resting bar is the SUM of the turn's request and the
## aside's.
## Neither the question nor the answer ever enters the conversation: the
## next prompt's turn runs as if the aside never happened.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getTempDir() / "3code_tty_fixture" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

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
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
  ]

proc assistantReply(text: string; usage: JsonNode;
                    preStreamDelayMs = 50): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": preStreamDelayMs,
     "content": text, "contentChunks": [text], "usage": usage}

suite ":btw is async":
  test "? question at once, dim ! answer later, bar shows the sum":
    let root = newFixture("btw_async")
    writeConfiguredProvider(root)
    # Turn 1 spends 6000/5; the aside (held 900ms so the test can see the
    # command return before the answer exists) spends 40/6; turn 2 spends
    # 6100/4 on the history as it stood — the aside never widened it.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      assistantReply("main reply", %*{"promptTokens": 6000,
        "completionTokens": 5, "totalTokens": 6005, "cachedTokens": 0}),
      assistantReply("a side answer", %*{"promptTokens": 40,
        "completionTokens": 6, "totalTokens": 46, "cachedTokens": 0},
        preStreamDelayMs = 900),
      assistantReply("second reply", %*{"promptTokens": 6100,
        "completionTokens": 4, "totalTokens": 6104, "cachedTokens": 0})
    ]))
    # btw_trace: the rest-loop ledger diagnostic (config.nim's testTrace).
    # The dump below lands in the .run.log parallel_tty prints whole for a
    # failing test, so a CI-side ledger failure names its step.
    let tracePath = root / "btw_trace.log"
    var env = stubEnv(root, root / "run" / "stub_responses.json")
    env.add (key: "test.btw_trace", val: tracePath)
    let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                            cwd = root / "run",
                            env = env)
    defer:
      tty.close()
      if fileExists(tracePath):
        echo "---- btw trace ----"
        echo readFile(tracePath)
    tty.expect "❯"

    # Turn 1: the turn's own request lands on the bar.
    tty.send "hello"
    tty.send "\n"
    tty.expectInHistory "main reply"
    tty.expectTokenBar(["◑", "↑6.0k", "↓5"])
    tty.drain(300)

    # The aside: the command returns while its answer is still being
    # held by the stub — the question is already in history as the `?`
    # item in place of the echoed command line, the answer is not, and
    # the idle prompt is alive (nothing blocked).
    tty.send ":btw what did I say?"
    tty.send "\n"
    tty.expectInHistory "? what did I say?"
    tty.expectPromptLive()
    tty.expectNo "a side answer", settleMs = 400

    # Then the answer lands: the aside's own `!` icon, dim, in history.
    tty.expectInHistory "a side answer"
    tty.expectInHistory "! │"
    tty.drain(300)

    # The bar rests on the SUM of both requests: 6000+40 in, 5+6 out.
    # (The resting repaint carries no trailing turn clock, so this is a
    # history-row assert, not expectTokenBar.)
    tty.expectInHistory "↓11"

    # The aside never entered the conversation: the next turn runs a
    # normal prompt against the history as it stood.
    tty.send "again"
    tty.send "\n"
    tty.expectInHistory "second reply"
    tty.expectTokenBar(["◑", "↑6.1k", "↓4"])
    tty.send ":q\n"
    tty.expectExit(0)

  test "typed while the turn runs: receipt, answer and ledger all land":
    # A `:btw` is orthogonal to a running turn, so it must not queue for
    # the next boundary like a mutating command. The stub holds the main
    # reply for 2.5s; the aside is typed inside that window and must fire
    # at once (the controller services it on the stream's poll beat), land
    # its answer WHILE the turn is still running, and join the bar only
    # once the turn rests — the running turn owns the bar until then.
    let root = newFixture("btw_midturn")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      assistantReply("main reply", %*{"promptTokens": 6000,
        "completionTokens": 5, "totalTokens": 6005, "cachedTokens": 0},
        preStreamDelayMs = 3000),
      assistantReply("midturn answer", %*{"promptTokens": 40,
        "completionTokens": 6, "totalTokens": 46, "cachedTokens": 0})
    ]))
    let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root,
                              root / "run" / "stub_responses.json"))
    defer: tty.close()
    tty.expect "❯"

    # The turn starts and is held by the stub before any content exists.
    tty.send "hello"
    tty.send "\n"
    tty.drain(400)
    tty.expectNo "main reply", settleMs = 100

    # The aside, typed mid-turn: the question row commits at once (the
    # `?`-led item IS the receipt; the answer lands below when it
    # arrives).
    tty.send ":btw what is happening?"
    tty.send "\n"
    tty.expectInHistory "? what is happening?"

    # The answer lands while the turn is still running — before the
    # model's own reply, which the stub is holding.
    tty.expectInHistory "midturn answer", timeoutMs = 2000
    # The answer renders as the dim `!`-led quote block, not the old
    # 💬 emoji row.
    tty.expectInHistory "! │"
    tty.expectNo "main reply", settleMs = 100
    tty.expectAlive()

    # The turn finishes; the rest ledgers the aside onto the same bar:
    # 6000+40 in, 5+6 out (ledgered only now, never mid-turn: the running
    # turn owns the bar until it rests).
    tty.expectInHistory "main reply", timeoutMs = 8000
    # The rest-ledger lands with the turn finalize; on the 3-core macos
    # runner the stream drip and the join repaint run seconds behind the
    # committed reply (the reply assert above passed while the bar still
    # showed mid-turn partials). 12s keeps the contract (the ledger does
    # land) without measuring the runner's scheduler.
    tty.expectInHistory "↓11", timeoutMs = 12000
    tty.expectPromptLive()
    tty.send ":q\n"
    tty.expectExit(0)
