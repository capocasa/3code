discard """
  disabled: "win"
  ## tty tests are POSIX-only by convention (ConPTY timing); the mid-turn
  ## receipt has to be observed while the stub still holds the reply.
"""
## The commands that are pure chrome — `:notify`, `:tab-title` — are
## orthogonal to a running turn: they touch no conversation, session or
## profile state, so they run the moment Enter is pressed, turn or no turn.
## Their one side effect that is NOT orthogonal is the config write:
## `writeConfigFile` re-parses the file and briefly swaps the settings
## globals a running turn reads, so mid-turn the in-memory switch flips at
## once and the write waits for the rest.
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

proc heldReply(text: string; holdMs: int): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": holdMs,
     "content": text, "contentChunks": [text],
     "usage": {"promptTokens": 100, "completionTokens": 5,
               "totalTokens": 105, "cachedTokens": 0}}

suite "chrome settings during a turn":
  test ":notify and :tab-title run mid-turn; the config write waits":
    let root = newFixture("settings_midturn")
    writeConfiguredProvider(root)
    let configFile = root / "xdg" / "3code" / "config"
    writeFile(root / "run" / "stub_responses.json", $(%*[
      heldReply("main reply", 2500)
    ]))
    let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root,
                              root / "run" / "stub_responses.json"))
    defer: tty.close()
    tty.expect "❯"

    tty.send "hello"
    tty.send "\n"
    tty.drain(400)
    tty.expectNo "main reply", settleMs = 100

    # Both switches flip at once, receipts in scrollback, no hourglass
    # queue item (a deferred command would echo as `⧖` instead).
    tty.send ":notify off"
    tty.send "\n"
    tty.expectInHistory "notify: off"
    tty.send ":tab-title off"
    tty.send "\n"
    tty.expectInHistory "tab title: off"
    tty.expectNo "⧖", settleMs = 100
    # The turn still holds the prompt: nothing has been written.
    check "notify" notin readFile(configFile)
    check "tab-title" notin readFile(configFile)
    tty.expectAlive()

    # The rest writes what the running turn made wait. The write is
    # ordered with the turn's finalize, not with the prompt repaint, so
    # wait for the file instead of reading it the moment the prompt
    # shows (the prompt repaint can come first).
    tty.expectInHistory "main reply", timeoutMs = 8000
    tty.expectPromptLive()
    proc savedBoth(): bool =
      try:
        let s = readFile(configFile)
        "notify = \"off\"" in s and "tab-title = \"off\"" in s
      except IOError:
        false
    tty.waitUntil(proc(t: TtySession): bool = savedBoth(), timeoutMs = 8000)
    let saved = readFile(configFile)
    check "notify = \"off\"" in saved
    check "tab-title = \"off\"" in saved
    tty.send ":q\n"
    tty.expectExit(0)
