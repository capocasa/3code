discard """
  action: run
  disabled: "win"
"""
## A oneshot prompt must reach the .3log before the first model response.
## The submit paths used to persist only after callModel returned: a kill
## during the first call (job teardown of a detached run, power loss) left
## a 0-byte session file, and a CLI prompt never passes through the draft
## sidecar, so the prompt vanished without a trace. Reproduced with a stub
## response stuck in preStreamDelayMs: the session file must already hold
## the user message while the turn is still waiting for the provider.
import std/[json, os, osproc, strtabs, strutils, unittest]
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/core" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")
  createDir(result / "tmp")

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

suite "oneshot prompt persistence":
  test "prompt is in the .3log before the first response arrives":
    let root = newFixture("oneshot_prompt_persist")
    defer: removeDir(root)
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"role": "assistant", "preStreamDelayMs": 60000,
       "content": "never arrives in this test",
       "contentChunks": ["never arrives in this test"],
       "usage": {"promptTokens": 5, "completionTokens": 1,
                 "totalTokens": 6, "cachedTokens": 0}}
    ]))
    let stub = ensureStubBinary()
    let env = newStringTable()
    env["XDG_DATA_HOME"] = root / "xdg"
    env["XDG_CONFIG_HOME"] = root / "xdg"
    env["XDG_CACHE_HOME"] = root / "xdg" / "cache"
    env["TMPDIR"] = root / "tmp"
    env["HOME"] = root
    env["TERM"] = "dumb"
    env["THREECODE_STUB_RESPONSES"] = root / "run" / "stub_responses.json"
    # Shell-wrap only for the >out 2>err redirects: the binary's TUI bytes
    # must never sit in an unread osproc pipe (64KiB buffer = deadlock).
    let cmdline = "exec " & stub.quoteShell & " -x " &
      "build a castle and report back".quoteShell &
      " > " & (root / "run" / "out.txt").quoteShell &
      " 2> " & (root / "run" / "err.txt").quoteShell
    let po = startProcess("/bin/sh", args = ["-c", cmdline], env = env,
                          options = {})
    defer:
      if po.running: kill(po)
      discard waitForExit(po)

    # Wait for the submit-time save: the prompt must be on disk while the
    # stub is still parked in its pre-stream delay (no assistant content).
    let sessionsDir = root / "xdg" / "3code" / "sessions"
    var saved = ""
    for i in 1 .. 150:
      sleep 100
      if dirExists(sessionsDir):
        for f in walkFiles(sessionsDir / "*.3log"):
          if "build a castle" in readFile(f):
            saved = f
            break
      if saved.len > 0: break
    check saved.len > 0
    if saved.len > 0:
      let text = readFile(saved)
      check "build a castle and report back" in text
      # Still mid-turn: the stalled response must not be in the file yet.
      check "never arrives" notin text
