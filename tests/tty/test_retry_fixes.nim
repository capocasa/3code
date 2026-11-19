discard """
  disabled: "win"
  ## Same ConPTY throughput class as the other backoff-wait tests.
"""
## `:retry` is the empty submit: the command queues exactly the event
## Enter on an empty buffer queues, and the controller answers it with a
## turn that sends the current conversation state as a request. The old
## "instant retry requested" hint is gone, a backoff in flight is no
## longer cut short (the queued submit runs once the turn yields), and
## Ctrl+Shift+R is the same gesture as a key — without eating a
## half-typed draft. Commands still land in the prompt log (the history
## file behind Up / Ctrl+R) whether typed at idle or mid-turn.
import std/[json, os, strutils, times, unittest]
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
     "usage": {"promptTokens": 5, "completionTokens": 1,
                "totalTokens": 6, "cachedTokens": 0}}

const CtrlShiftR = "\x1b[114;6u"
  ## kitty keyboard protocol: CSI 114;6 u (ctrl+shift+r, mods 5|1)

suite ":retry as empty submit":
  test "idle :retry sends the current state as a request, no hint line":
    let root = newFixture("retry_empty_submit")
    writeConfiguredProvider(root)
    # Response 1 answers the typed prompt; response 2 answers the empty
    # submit `:retry` queues — a fresh request on the conversation as it
    # stands, no user message appended.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("FIRST_TURN"), reply("SECOND_TURN")
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
    tty.expectInHistory "FIRST_TURN"
    tty.drain(200)
    tty.send ":retry\n"
    # No hint line: the turn it starts is the whole announcement.
    tty.expectNeverInHistory "instant retry requested"
    tty.expectInHistory "SECOND_TURN"
    tty.expectAlive()
    tty.drain(300)
    # The command is prompt-log content: it recalls with Up / Ctrl+R.
    check ":retry" in readFile(root / "xdg" / "3code" / "history")

  test "mid-backoff :retry queues a submit instead of cutting the wait":
    let root = newFixture("retry_backoff_queue")
    writeConfiguredProvider(root)
    # A 429 with a 2s backoff (retryAfter), then two normal replies: one
    # for the original turn's resend, one for the empty submit `:retry`
    # queued during the wait. The wait must NOT be cut — recovery can
    # only appear after the full 2s — and the queued submit runs as its
    # own turn once the first yields.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}",
       "retryAfter": "2"},
      reply("recovered"),
      reply("AFTER_QUEUED_SUBMIT")
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
    # `:retry` mid-backoff: no hint, no cut, one queued submit.
    tty.send ":retry\n"
    tty.expectNeverInHistory "instant retry requested"
    let t0 = epochTime()
    check tty.expectInHistory("recovered", timeoutMs = 8000)
    check epochTime() - t0 >= 1.5
    check tty.expectInHistory("AFTER_QUEUED_SUBMIT", timeoutMs = 8000)
    tty.expectAlive()
    tty.drain(300)
    # The mid-turn command still reaches the prompt log.
    check ":retry" in readFile(root / "xdg" / "3code" / "history")

  test "idle :retry list still works and reaches the prompt log":
    let root = newFixture("retry_idle_hist")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[reply("unused")]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    tty.send ":retry list"
    tty.expect ":retry list"
    tty.send "\n"
    tty.expectInHistory "patient retry"
    tty.drain(200)
    let hist = readFile(root / "xdg" / "3code" / "history")
    check ":retry list" in hist

  test "ctrl+shift+r is the same submit without eating the draft":
    let root = newFixture("retry_key")
    writeConfiguredProvider(root)
    # Response 1 is slow (1.5s) so the draft and the key press land
    # mid-turn; response 2 answers the empty submit the key queues.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("FIRST_TURN", delayMs = 1500), reply("SECOND_TURN")
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
    # A half-typed follow-up must survive the shortcut (a command submit
    # clears the line; the key keeps the draft riding the turns).
    tty.send "next prompt"
    tty.expect "next prompt"
    tty.send CtrlShiftR
    tty.expectNeverInHistory "instant retry requested"
    tty.expectInHistory "FIRST_TURN"
    tty.expectInHistory "SECOND_TURN"
    tty.drain(300)
    tty.expectTypedAtPrompt "next prompt"
    tty.expectAlive()
    # The shortcut is not a typed line: it must NOT enter the prompt log.
    check ":retry" notin readFile(root / "xdg" / "3code" / "history")
    # Ctrl+R alone stays history search (the isearch banner paints in
    # place of the prompt row).
    tty.send "\x12"
    tty.expect "reverse-i-search"
    tty.send "\x1b"
    tty.drain(200)
