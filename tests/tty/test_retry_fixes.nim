discard """
  disabled: "win"
  ## Same ConPTY throughput class as the other backoff-wait tests.
"""
## The three `:retry` fixes in one interactive pass:
##
## 1. The error message survives the retry. The retry notice lives on the
##    volatile notice row; a `:retry` that cuts the wait used to erase it
##    as the next attempt started, so a resend that succeeded left no
##    trace of what went wrong. The cut must commit the error detail to
##    scrollback first.
## 2. `:retry` (and every other system command submitted mid-turn) lands
##    in the prompt log (the history file behind Up / Ctrl+R). The
##    command hook's commit cleared the editor before readLineWith's own
##    historyAdd ran, so mid-turn commands were never recorded.
## 3. Ctrl+Shift+R (the kitty keyboard protocol's distinct form; Ctrl+R
##    stays history search) retries with the same hint line the command
##    prints — without clearing a half-typed draft.
import std/[json, os, strutils, times, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getTempDir() / "3code_tty_fixture" / (name & "_" & $getCurrentProcessId())
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

proc recoveryReply(): JsonNode =
  %*{"role": "assistant", "preStreamDelayMs": 50,
     "content": "recovered", "contentChunks": ["recovered"],
     "usage": {"promptTokens": 5, "completionTokens": 1,
                "totalTokens": 6, "cachedTokens": 0}}

const CtrlShiftR = "\x1b[114;6u"
  ## kitty keyboard protocol: CSI 114;6 u (ctrl+shift+r, mods 5|1)

suite "retry fixes":
  test ":retry mid-backoff keeps the error and lands in the prompt log":
    let root = newFixture("retry_fix_cut")
    writeConfiguredProvider(root)
    # One 429 with a 30s backoff (retryAfter), then a normal reply. The
    # `:retry` sent mid-wait must skip the remaining backoff, so the
    # reply can only arrive early if the cut worked.
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}",
       "retryAfter": "30"},
      recoveryReply()
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
    # `:retry` mid-backoff: the wait breaks and the resend runs.
    tty.send ":retry\n"
    tty.expectInHistory "instant retry requested"
    # The cut actually skipped the 30s backoff.
    let t0 = epochTime()
    check tty.expectInHistory("recovered", timeoutMs = 8000)
    check epochTime() - t0 < 15.0
    tty.expectAlive()
    tty.drain(300)
    # Fix 1: the error that justified the wait is committed to scrollback
    # by the cut — it must still be on screen after the turn recovered
    # and the footer moved on. Before the fix the volatile notice row was
    # the error's only home and the cut erased it for good.
    check "429 from stub" in tty.screenText()
    check "rate limit" in tty.screenText()
    # Fix 2: the command is in the prompt log (the history file), so it
    # recalls with Up / Ctrl+R like any typed prompt.
    let hist = readFile(root / "xdg" / "3code" / "history")
    check ":retry" in hist

  test "idle commands reach the prompt log too":
    let root = newFixture("retry_fix_idle_hist")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[recoveryReply()]))
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

  test "ctrl+shift+r retries without eating the draft":
    let root = newFixture("retry_fix_key")
    writeConfiguredProvider(root)
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"failure": "429", "body": "{\"error\":\"rate limit\"}",
       "retryAfter": "30"},
      recoveryReply()
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
    # A half-typed follow-up must survive the shortcut (a command submit
    # clears the line; a key must not).
    tty.send "next prompt"
    tty.expect "next prompt"
    tty.send CtrlShiftR
    tty.expectInHistory "instant retry requested"
    let t0 = epochTime()
    check tty.expectInHistory("recovered", timeoutMs = 8000)
    check epochTime() - t0 < 15.0
    tty.drain(300)
    # The committed error line survives the cut here too.
    check "429 from stub" in tty.screenText()
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
