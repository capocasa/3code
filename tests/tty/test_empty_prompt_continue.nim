discard """
  disabled: "win"
  ## The continuation assertion keys on the stub's response order and the
  ## `.3log` record headers; both are deterministic, but the suite keeps
  ## tty tests POSIX-only (ConPTY timing) per the category's convention.
"""
## Empty prompt = continue the ongoing session. An Enter on the empty
## editor runs a turn on the messages exactly as they stand: the second
## stub response streams back, and the `.3log` gains an assistant record
## but no user record — nothing was added to the session. With
## `allow-empty-prompt = off` in [settings] the same Enter is a no-op
## again (the pre-continuation behavior).
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string; allowEmpty = true) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
""" &
  (if allowEmpty: "" else: "allow-empty-prompt = off\n") & """

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

proc assistantReply(text: string): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": 100,
     "content": text, "contentChunks": [text],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}

proc sessionLogRecords(root: string): seq[string] =
  ## Column-0 record headers of the fixture's single `.3log`
  ## (`user`, `assistant`, `tokens`, ...), body lines excluded.
  let dir = root / "xdg" / "3code" / "sessions"
  if not dirExists(dir): return @[]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".3log"):
      for line in readFile(path).splitLines():
        if line.len > 0 and line[0] != ' ' and not line.startsWith("  "):
          result.add line.split(' ')[0]
      break

proc countRole(records: seq[string]; role: string): int =
  for r in records:
    if r == role: inc result

proc sendLine(tty: TtySession; text: string) =
  for ch in text:
    tty.send($ch)
    tty.drain(10)
  tty.send "\n"

suite "empty prompt continues the session":
  test "empty Enter runs a continuation turn, no message added":
    let root = newFixture("empty_prompt_continue")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      assistantReply("first reply."),
      assistantReply("continuation without a prompt.")
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"),
                            keepHistory = false)
    defer: tty.close()

    tty.expect "\u276f"
    sendLine(tty, "hello model")
    tty.expectInHistory "first reply."
    # Settle past the turn end (the streamed text is in history before the
    # turn is over; an Enter that lands mid-turn must stay inert).
    tty.drain(300)
    tty.expect "\u276f"

    # The empty prompt: nothing typed, just Enter.
    tty.send "\n"
    tty.expectInHistory "continuation without a prompt."

    # Prompt must be back and alive after the continuation turn.
    tty.drain(200)
    tty.expect "\u276f"

    tty.expectAlive()
    tty.close()
    let records = sessionLogRecords(root)
    check countRole(records, "user") == 1
    check countRole(records, "assistant") == 2
    echo "  PASS: empty Enter continued the session without a user message"

  test "allow-empty-prompt = off keeps empty Enter a no-op":
    let root = newFixture("empty_prompt_disabled")
    writeConfiguredProvider(root, allowEmpty = false)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      assistantReply("first reply."),
      assistantReply("must not stream.")
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"),
                            keepHistory = false)
    defer: tty.close()

    tty.expect "\u276f"
    sendLine(tty, "hello model")
    tty.expectInHistory "first reply."
    tty.drain(200)
    tty.expect "\u276f"

    tty.send "\n"
    tty.drain(300)
    # No continuation turn: the second response never streams.
    tty.expectNeverInHistory "must not stream."
    tty.expect "\u276f"

    tty.expectAlive()
    tty.close()
    let records = sessionLogRecords(root)
    check countRole(records, "user") == 1
    check countRole(records, "assistant") == 1
    echo "  PASS: allow-empty-prompt = off restored the no-op"
