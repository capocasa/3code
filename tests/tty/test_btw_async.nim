discard """
  disabled: "win"
  ## tty tests are POSIX-only by convention (ConPTY timing); the aside's
  ## delivery timing assertions need a real PTY's frame cadence.
"""
## `:btw` never blocks the prompt (the dev-guidelines rule): the command
## returns its receipt at once, the side-question meta-call runs on a
## worker thread, and the answer lands in scrollback afterwards — dim,
## led by the 💬 icon, with its burned tokens added onto the token bar so
## the resting bar is the SUM of the turn's request and the aside's.
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
  test "receipt at once, dim 💬 answer later, bar shows the sum":
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
    let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root,
                              root / "run" / "stub_responses.json"))
    defer: tty.close()
    tty.expect "❯"

    # Turn 1: the turn's own request lands on the bar.
    tty.send "hello"
    tty.send "\n"
    tty.expectInHistory "main reply"
    tty.expectTokenBar(["◑", "↑6.0k", "↓5"])
    tty.drain(300)

    # The aside: the command returns while its answer is still being
    # held by the stub — the receipt is already in history, the answer
    # is not, and the idle prompt is alive (nothing blocked).
    tty.send ":btw what did I say?"
    tty.send "\n"
    tty.expectInHistory "asked"
    tty.expectPromptLive()
    tty.expectNo "a side answer", settleMs = 400

    # Then the answer lands: the aside's own icon, dim, in history.
    tty.expectInHistory "a side answer"
    tty.expectInHistory "💬"
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
