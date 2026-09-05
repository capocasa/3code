discard """
  disabled: "win"
  ## Hangs under ConPTY: the long retry-backoff window + continuous typing
  ## stress hits a ConPTY output-pipe buffer-full deadlock that doesn't
  ## manifest on POSIX (POSIX PTY writes don't block the writer the same
  ## way). Not a product bug; a harness/ConPTY throughput limitation.
"""
## Stress: type continuously into the buffered editor while the spinner is
## running through a 429 retry backoff. The spinner thread repaints the live
## editor (via renderFooter -> redrawBytes) while the input thread mutates the
## same LineEditor (typing). Without synchronization this is a data race that
## corrupts the heap and crashes with SIGSEGV in the allocator. Repeated
## runs across many backoff windows surface the crash reliably.
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

suite "spinner runs through backoff while typing":
  test "no SIGSEGV when typing during backoff backoff":
    for iteration in 1 .. 20:
      let root = newFixture("spinner_race_" & $iteration)
      writeConfiguredProvider(root)
      var responses = newJArray()
      # Several 429s so the backoff window is long enough to type into.
      for _ in 0 ..< 3:
        responses.add %*{"failure": "429", "body": "{\"error\":\"rate limit\"}"}
      responses.add %*{"role": "assistant", "preStreamDelayMs": 50,
                      "content": "recovered", "contentChunks": ["recovered"],
                      "usage": {"promptTokens": 5, "completionTokens": 1,
                                "totalTokens": 6, "cachedTokens": 0}}
      writeFile(root / "run" / "stub_responses.json", $responses)
      let stub = ensureStubBinary(extraDefines = "-d:fastStubRetries")
      let tty = newTtySession(stub,
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json"))
      defer:
        tty.close()
      tty.expect "\u276f"
      tty.send "go"
      tty.expect "go"
      tty.send "\n"
      tty.expectInHistory("429", timeoutMs = 15_000)
      # Hammer the buffered editor with keystrokes throughout the backoff.
      for burst in 1 .. 40:
        tty.send "abcdefghij"
        tty.advanceTicker()
        tty.drain(5, recordFrame = false)
      tty.expectAlive()
      tty.send "\x03"
      tty.drain(200)
      # The child must survive the backoff without crashing.
      tty.expectAlive()
    echo "  PASS: spinner + typing during backoff did not crash"
