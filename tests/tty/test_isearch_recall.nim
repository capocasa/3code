discard """
  disabled: "win"
"""
## Ctrl-R recall accepts on arrow keys, the way the command line does:
## readline terminates an incremental search on any unowned control key
## (ENDSRCH_CHAR) keeping the found line, then runs the key as a command.
## Right during the search must load the recalled prompt for editing —
## not snap back to the latest prompt draft. C-g keeps its abort.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  # Outside the checkout, like every other tty fixture: config discovery
  # walks up from the child's cwd, and a developer's own repo-root
  # `.3code/config` pin would beat the fixture's provider (the arm64 run
  # hit it; test_acp's fixture isolates for the same reason).
  result = tempDir() / "3code_tty_fixture" / (name & "_" & $getCurrentProcessId())
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

proc reply(content: string): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": 50,
     "content": content, "contentChunks": [content],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}

suite "ctrl+r recall accepts on arrow keys":
  test "right during ctrl+r loads the match for editing":
    let root = newFixture("isearch_right_recall")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("APPLE_TURN_OK"),
      reply("BANANA_TURN_OK"),
      reply("EDITED_TURN_OK"),
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
    # Two prompts in the log so the search has an older match to find.
    tty.send "the apple prompt"
    tty.expect "the apple prompt"
    tty.send "\n"
    tty.expectInHistory "APPLE_TURN_OK"
    tty.send "the banana prompt"
    tty.expect "the banana prompt"
    tty.send "\n"
    tty.expectInHistory "BANANA_TURN_OK"
    tty.drain(200)
    # A fresh draft at the prompt: the bug recalled THIS instead of the
    # match when Right ended the search.
    tty.send "fresh draft"
    tty.expectTypedAtPrompt "fresh draft"
    tty.send "\x12"          # Ctrl-R
    tty.drain(200)
    tty.send "apple"
    tty.drain(300)
    tty.expect "reverse-i-search)`apple'"
    tty.send "\x1b[C"        # Right: select the match for editing
    tty.drain(300)
    # The match is live on the caret row; the draft is gone from the
    # screen, and the search banner is no longer the prompt.
    tty.expectTypedAtPrompt "the apple prompt"
    check "fresh draft" notin tty.screenText()
    check "reverse-i-search" notin tty.screenText()
    # Editing proceeds on the recalled prompt and submits it.
    tty.send "\x05"          # Ctrl-E: end of line
    tty.drain(100)
    tty.send " again"
    tty.drain(200)
    tty.send "\n"
    tty.expectInHistory "EDITED_TURN_OK"
    let hist = readFile(root / "xdg" / "3code" / "history")
    check "the apple prompt again" in hist
    check "fresh draft" notin hist
    tty.expectAlive()

  test "ctrl+g during ctrl+r still restores the draft":
    let root = newFixture("isearch_abort_still_works")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      reply("APPLE_TURN_OK"),
      reply("DRAFT_TURN_OK"),
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
    tty.send "the apple prompt"
    tty.expect "the apple prompt"
    tty.send "\n"
    tty.expectInHistory "APPLE_TURN_OK"
    tty.drain(200)
    tty.send "fresh draft"
    tty.expectTypedAtPrompt "fresh draft"
    tty.send "\x12"          # Ctrl-R
    tty.drain(200)
    tty.send "apple"
    tty.drain(300)
    tty.expect "reverse-i-search)`apple'"
    tty.send "\a"            # C-g aborts: the draft comes back
    tty.drain(300)
    tty.expectTypedAtPrompt "fresh draft"
    tty.send "\n"
    tty.expectInHistory "DRAFT_TURN_OK"
    tty.expectAlive()
