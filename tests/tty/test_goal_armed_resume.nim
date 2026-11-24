discard """
  disabled: "win"
"""
## Closing 3code while a goal is armed (before completion) and resuming
## with `3code -r` must land on an empty prompt when the editor was
## empty at quit: the goal's autosends must never leak into the draft
## sidecar that resume prefills from.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getTempDir() / "3code_tty_fixture" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")
  createDir(result / "xdg" / "3code")

proc writeConfiguredProvider(root: string) =
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
    (key: "test.stub_responses", val: responsesPath),
  ]

proc draftPathForDir(root: string): string =
  let base = root / "xdg" / "3code" / "drafts"
  let pendingDir = base / "pending"
  if dirExists(pendingDir):
    for kind, path in walkDir(pendingDir):
      if kind == pcFile and path.endsWith(".prompt"):
        return path
  if dirExists(base):
    for kind, path in walkDir(base):
      if kind == pcFile and path.endsWith(".prompt"):
        return path
  pendingDir / "missing.prompt"

suite "armed goal leaves an empty resume prompt":
  test "FEEDBACK continuation then quit; resume prompt is empty":
    let root = newFixture("goal_armed_resume")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "WORK_ONE", "contentChunks": ["WORK_ONE"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "not yet\nVERDICT: FEEDBACK: do more",
       "contentChunks": ["not yet\nVERDICT: FEEDBACK: do more"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}},
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "WORK_TWO", "contentChunks": ["WORK_TWO"],
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
    tty.expect "\u276f"
    tty.send ":goal keep working"
    tty.send "\n"
    tty.expectInHistory "\u2691 keep working"
    tty.expectInHistory "WORK_ONE"
    tty.expectInHistory "\u2717"
    # FEEDBACK sends the agent back in on its own; the second work turn
    # streams with no prompt sent.
    tty.expectInHistory "WORK_TWO"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check not fileExists(draftPathForDir(root))
    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 8000)
    check not fileExists(draftPathForDir(root))

    # Phase 2: resume. The prompt must be empty.
    let tty2 = newTtySession(stub,
                             args = ["-r", "-x", "-i"],
                             cwd = root / "run",
                             env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty2.close()
    tty2.expect "\u276f"
    check not fileExists(draftPathForDir(root))
    tty2.send "\x04"
    tty2.expectExit(0, timeoutMs = 5000)
