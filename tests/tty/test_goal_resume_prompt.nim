discard """
  disabled: "win"
"""
## After a completed :goal, closing 3code and resuming with `3code -r`
## must land on an empty prompt: nothing the goal run did may leak into
## the draft sidecar that resume prefills from.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

when defined(posix):
  import posix except SocketHandle

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

proc sessionLogText(root: string): string =
  let dir = root / "xdg" / "3code" / "sessions"
  if not dirExists(dir): return ""
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".3log"):
      result.add readFile(path)
      result.add "\n"

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

suite "goal completion leaves an empty resume prompt":
  test "goal retires; resume prompt is empty":
    let root = newFixture("goal_resume_prompt")
    writeConfiguredProvider(root)
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
    tty.expect "\u276f"
    tty.send ":goal make the stub say the word"
    tty.send "\n"
    tty.expectInHistory "\u2691 make the stub say the word"
    tty.expectInHistory "GOAL_WORK_DONE"
    tty.expectInHistory "\u2713"
    tty.drain(300)
    check "goal_check verdict=satisfied" in sessionLogText(root)
    check not fileExists(draftPathForDir(root))
    # Clean exit, editor empty: no draft sidecar may survive.
    tty.send ":q\n"
    tty.expectExit(0, timeoutMs = 5000)
    check not fileExists(draftPathForDir(root))

    # Phase 2: resume. The prompt must be empty.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 50,
       "content": "RESUMED_OK", "contentChunks": ["RESUMED_OK"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ]))
    let tty2 = newTtySession(stub,
                             args = ["-r", "-x", "-i"],
                             cwd = root / "run",
                             env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty2.close()
    tty2.expect "\u276f"
    check not fileExists(draftPathForDir(root))
    # The editor is empty when Ctrl-D (quit-if-empty) exits cleanly.
    tty2.send "\x04"
    tty2.expectExit(0, timeoutMs = 5000)

  test "stray whitespace in the editor never becomes a resume draft":
    # The teardown flush saves the editor buffer unconditionally, so a stray
    # space left in the prompt used to survive as a sidecar and prefill an
    # invisible character into the next `3code -r`.
    let root = newFixture("goal_whitespace_draft")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"))
    tty.expect "\u276f"
    tty.send " "
    tty.drain(100)
    # SIGTERM: the exit-proc teardown flush is the unconditional last word,
    # so this is exactly the path that leaked the whitespace.
    when defined(posix):
      discard posix.kill(tty.pid, posix.SIGTERM)
    tty.expectExit(143, timeoutMs = 8000)
    check not fileExists(draftPathForDir(root))
    let tty2 = newTtySession(stub,
                             args = ["-x", "-i"],
                             cwd = root / "run",
                             env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty2.close()
    tty2.expect "\u276f"
    tty2.send "\x04"
    tty2.expectExit(0, timeoutMs = 5000)
