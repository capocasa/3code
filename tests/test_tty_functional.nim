import std/[json, os, strutils, times, unicode, unittest]
import posix except SocketHandle
import tty_expect
import stub_helpers

const VisualOutputRoot = "tests" / "output" / "tty"
const SimpleVisualTestFrames = "tests" / "fixtures" / "tty" / "simple.txt"
const MultilineVisualTestFrames = "tests" / "fixtures" / "tty" / "multiline.txt"
const BashToolVisualTestFrames = "tests" / "fixtures" / "tty" / "bash_tool_visual_test.txt"
const OtherToolsVisualTestFrames = "tests" / "fixtures" / "tty" / "other_tools_visual_test.txt"
const ResizeStreamFrames = "tests" / "fixtures" / "tty" / "resize_stream_frames.txt"
const HarnessCommandFrames = "tests" / "fixtures" / "tty" / "harness_commands.txt"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc writeHarnessProviders(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model stub-large"

[provider]
name = "alt"
url = "stub://alt"
key = "alt"
family = "glm"
models = "alt-model alt-large"
""")

proc toolCall(id, name: string, args: JsonNode; stub: JsonNode = nil): JsonNode =
  result = %*{
    "id": id,
    "type": "function",
    "function": {
      "name": name,
      "arguments": $args
    }
  }
  if stub != nil:
    result["stub"] = stub

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc sessionLogText(root: string): string =
  let dir = root / "data" / "3code" / "sessions"
  if not dirExists(dir):
    return ""
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".3log"):
      result.add readFile(path)
      result.add "\n"

proc draftPathForDir(root: string): string =
  ## Path of the draft sidecar for the (single) session under a test root.
  ## Before the first turn a draft lives under the cwd-keyed pending path
  ## (drafts/pending/<hash>.prompt); after, under drafts/<id>.prompt. This
  ## resolves against the test's isolated XDG_DATA_HOME so it never touches the
  ## real draft store. Scans both locations, pending first.
  let base = root / "data" / "3code" / "drafts"
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

proc hardKillAndWait(tty: TtySession) =
  ## SIGTERM then SIGKILL the child and block until reaped. The harness's own
  ## exit polling can miss a signal death when the editor holds unsubmitted
  ## text, so this reaps directly via waitpid rather than relying on s.exited.
  if tty.pid <= 0: return
  discard kill(tty.pid, SIGTERM)
  var waited = 0
  var status: cint = 0
  while waitpid(tty.pid, status, WNOHANG) != tty.pid and waited < 30:
    sleep 50; inc waited
  if waitpid(tty.pid, status, WNOHANG) != tty.pid:
    discard kill(tty.pid, SIGKILL)
    discard waitpid(tty.pid, status, 0)
  tty.exited = true
  tty.exitCode = -1

proc discardClose(tty: TtySession) =
  ## Close the harness's file descriptors without the wait-for-exit logic in
  ## `close()`. Use after `hardKillAndWait`, which has already reaped the
  ## child, so there is nothing left to wait on.
  if tty.closed: return
  discard close(tty.masterFd)
  for fd in [tty.frameEventFd, tty.frameAckFd, tty.tickerCommandFd,
             tty.tickerAckFd, tty.apiContinueFd]:
    if fd > 0: discard close(fd)
  tty.frameEventFd = 0
  tty.frameAckFd = 0
  tty.tickerCommandFd = 0
  tty.tickerAckFd = 0
  tty.apiContinueFd = 0
  tty.closed = true

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  # Isolate TMPDIR per fixture so session lock files (TMPDIR/3code/lock,
  # keyed by a second-resolution session-id timestamp) cannot collide across
  # fixtures that happen to start in the same wall-clock second. The data
  # dirs are already isolated via XDG_DATA_HOME; the lock dir was the hole.
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc startStub(root: string; args: openArray[string] = ["-x", "-i"];
               cols = DefaultTtyCols; rows = DefaultTtyRows;
               responsesPath = ""): TtySession =
  let resp = if responsesPath.len > 0: responsesPath else: root / "run" / "stub_responses.json"
  newTtySession(ensureStubBinary(), args = args, cwd = root / "run",
                env = stubEnv(root, resp), cols = cols, rows = rows)

proc requireVisibleEditorCaret(s: TtySession; needle: string) =
  s.drain(20)
  require s.frames.len > 0
  let frame = s.frames[^1]
  check not frame.cursorHidden
  require frame.cursorRow >= 0 and frame.cursorRow < frame.rows.len
  check needle in frame.rows[frame.cursorRow]

suite "terminal visual contract":
  test "resumed session replays the full conversation into scrollback":
    # Regression: resume used to show only the last user turn, dropping every
    # earlier turn from scrollback. A resumed session must drop the user back
    # into the whole prior conversation, reachable by scrolling up.
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "resume_full_scrollback":
      check true
    else:
      let root = newFixture("resume_full_scrollback")
      writeConfiguredProvider(root)
      # Three turns, each with a distinctive marker so we can tell them apart
      # in scrollback after resume.
      writeStubResponses(root, %*[
        {
          "role": "assistant",
          "content": "first-turn-marker is here",
          "contentChunks": ["first-turn-marker is here"],
          "usage": {
            "promptTokens": 40,
            "completionTokens": 5,
            "totalTokens": 45,
            "cachedTokens": 0
          }
        },
        {
          "role": "assistant",
          "content": "second-turn-marker appears",
          "contentChunks": ["second-turn-marker appears"],
          "usage": {
            "promptTokens": 60,
            "completionTokens": 6,
            "totalTokens": 66,
            "cachedTokens": 0
          }
        },
        {
          "role": "assistant",
          "content": "third-turn-marker last",
          "contentChunks": ["third-turn-marker last"],
          "usage": {
            "promptTokens": 80,
            "completionTokens": 7,
            "totalTokens": 87,
            "cachedTokens": 0
          }
        }
      ])

      # --- phase 1: build a three-turn conversation ---
      # The session is saved incrementally after each turn, so it is already
      # on disk once phase 1 completes — no clean shutdown is required for
      # --resume to find it. We only confirm each reply landed via history
      # (timing-tolerant); the token-bar shape is asserted in phase 2.
      block phase1:
        let tty = startStub(root, rows = 24)
        defer:
          tty.close()
        tty.expect "❯"
        tty.send "turn one\n"
        tty.expectInHistory "first-turn-marker is here"
        tty.send "turn two\n"
        tty.expectInHistory "second-turn-marker appears"
        tty.send "turn three\n"
        tty.expectInHistory "third-turn-marker last"
        tty.drain(400)

      # The session must be on disk for --resume to find it.
      check root.sessionLogText().len > 0

      # --- phase 2: resume and inspect scrollback ---
      block phase2:
        let tty = startStub(root, args = ["-x", "-r"], rows = 24)
        defer:
          tty.writeFrameArtifact(root / "resume_frames.txt")
          tty.writeMeaningfulFrameArtifact(root / "resume_meaningful_frames.txt")
          tty.close()

        tty.expect "● resumed"
        # The most recent turn lands on-screen...
        tty.expectInHistory "third-turn-marker last"
        # ...and crucially, the earlier turns must also be present in
        # scrollback (the bug dropped these).
        tty.expectInHistory "turn one"
        tty.expectInHistory "first-turn-marker is here"
        tty.expectInHistory "turn two"
        tty.expectInHistory "second-turn-marker appears"
        # The resumed token bar carries the last turn's usage. The settled
        # typing-ready bar has no elapsed-seconds suffix, so it is matched via
        # history rather than tokenBarRows (which keys on the "s" suffix).
        tty.expectInHistory "↑80"
        tty.expectInHistory "↓7"

  test "active turn colon commands are controller handled":
    let root = newFixture("active_colon_commands")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "Active command turn complete.",
        "contentChunks": ["Active command turn complete."],
        "usage": {
          "promptTokens": 88,
          "completionTokens": 12,
          "totalTokens": 100,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start active command turn\n"
    tty.send ":tokens\n"
    tty.expect "no tokens used yet"
    tty.send ":provider add\n"
    tty.expect "cannot run :provider add while a turn is active"
    tty.continueStubApi()
    tty.expectInHistory "Active command turn complete."
    tty.drain(200)

    let log = sessionLogText(root)
    check "start active command turn" in log
    check ":tokens" notin log
    check ":provider add" notin log

  test "idle provider add wizard is visible and masks input":
    let root = newFixture("provider_add_wizard")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send ":provider add\n"
    tty.drain(200)
    check "api key" in tty.screenText()
    check "********************" notin tty.screenText()
    tty.send "nvapi-visible-secret"
    tty.expect "********************"
    tty.expectNo "nvapi-visible-secret"
    tty.send "\n"
    tty.expect "detected:"
    tty.expect "models"
    tty.expectNo "nvapi-visible-secret"
    tty.send "\x1b"
    tty.expect "cancelled"
    tty.expectNo "nvapi-visible-secret"

  test "harness commands are transcript items":
    let root = newFixture("harness_commands")
    writeHarnessProviders(root)
    writeStubResponses(root, %*[])
    check fileExists(HarnessCommandFrames)

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.frames.setLen(0)
    var firstCommand = true
    for commandCase in [
      (":help", ": help"),
      (":provider", ": providers"),
      (":model", ": models"),
      (":reasoning", ": reasoning"),
      (":model stub-large", "provider  stub"),
      (":reasoning high", "reasoning high"),
      (":provider alt", "provider  alt"),
      (":tokens", ": tokens"),
      (":clear", "═══"),
      (":sessions", ": sessions"),
      (":sessions all", ": sessions"),
      (":log", ": log"),
      (":show", ": show"),
      (":compact", "! command"),
      (":summarize", "! summarize"),
      (":prompt", ": prompt"),
      (":toknes", "! command")
    ]:
      let (command, marker) = commandCase
      tty.send command
      if firstCommand:
        tty.expect "❯ " & command
        tty.frames.setLen(0)
        firstCommand = false
      else:
        tty.drain(80)
      tty.send "\n"
      tty.expectInHistory "❯ " & command
      tty.expectInHistory marker
      tty.drain(120)
    tty.expectInHistory "unknown command: :toknes  did you mean :tokens?"
    tty.send "\x1b[A"
    tty.expect "❯ :toknes"
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      HarnessCommandFrames,
      root / "harness_commands_actual.txt")

  test "profile commands return to prompt and accept further input":
    let root = newFixture("profile_cmd_noexit")
    writeHarnessProviders(root)
    writeStubResponses(root, %*[
      {"role": "assistant", "preStreamDelayMs": 100,
       "content": "hello", "contentChunks": ["hello"],
       "usage": {"promptTokens": 5, "completionTokens": 2,
                  "totalTokens": 7, "cachedTokens": 0}}
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "\u276f"
    # Change provider
    tty.send ":provider alt"
    tty.send "\n"
    tty.drain(200)
    tty.expect "\u276f"  # prompt must return
    # Send a message — if the program exited this times out
    tty.send "hi"
    tty.expect "hi"
    tty.send "\n"
    tty.expectInHistory "hello"
    tty.expect "\u276f"
    # Change model
    tty.send ":model stub-large"
    tty.send "\n"
    tty.drain(200)
    tty.expect "\u276f"  # prompt must return
    tty.send "hey"
    tty.expect "hey"
    tty.send "\n"
    tty.expectInHistory "hello"

  test "simple one-turn prompt and reply":
    let root = newFixture("simple_visual_test")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "reasoning_content": "Thinking about the test prompt",
        "reasoningChunks": ["Thinking about the test prompt"],
        "preStreamDelayMs": 200,
        "content": "This is a test response.",
        "contentChunks": ["This is a test response."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 24,
          "totalTokens": 144,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "This is a test prompt"
    tty.expect "This is a test prompt"
    tty.send "\n"
    tty.expectInHistory "Thinking about the test prompt"
    tty.expectInHistory "This is a test response."
    tty.expectTokenBar(["○", "↑120", "↓24"])
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      SimpleVisualTestFrames,
      root / "simple_visual_test_actual.txt")

  test "api retry notice is a harness line in scrollback, not stderr noise":
    # Regression: the retry notice used to be `stderr.writeLine` from the
    # transport layer (api.nim). That bypassed fat-prompt preservation and
    # landed on the prompt row, scrolling it up. It must instead commit as
    # a harness line through the same transcript path as `interrupted by
    # user`: non-bold magenta, no indent, one scrollback line, fat prompt
    # preserved, and NOT persisted to the `.3log` (it is controller feedback,
    # not a conversation message).
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "api_retry_notice":
      check true
    else:
      let root = newFixture("api_retry_notice")
      writeConfiguredProvider(root)
      # First response is a 429 (retryable as 'rate', 1s backoff at level 0);
      # second succeeds. `delayMs: 0` keeps the failure path snappy.
      writeStubResponses(root, %*[
        {"failure": "429", "delayMs": 0,
          "body": "{\"error\":\"rate limit\"}"},
        {"role": "assistant",
          "content": "reply after retry",
          "contentChunks": ["reply after retry"],
          "usage": {"promptTokens": 10, "completionTokens": 3,
                     "totalTokens": 13, "cachedTokens": 0}}
      ])
      let tty = startStub(root)
      defer: tty.close()

      tty.expect "❯"
      tty.send "go"
      tty.send "\n"
      # The retry notice is visible in scrollback as ordinary history.
      tty.expectInHistory "3code: api 429; retry 2/8 in 1s"
      # ...and the retried reply reaches scrollback after the backoff.
      tty.expectInHistory "reply after retry"
      # The prompt is live again afterward (the footer was preserved, not
      # scrolled away by the raw stderr write).
      tty.expect "❯"
      # The notice is controller feedback, not a conversation message, so it
      # must never reach the persisted session transcript.
      check "api 429" notin root.sessionLogText()

  test "submitting a prompt survives the working directory being removed":
    # Regression: the process's cwd can be deleted out from under it (tmpfs
    # reaper, an editor dropping a workspace dir, etc.). Nim's getCurrentDir
    # raises OSError on the next cwd lookup, which used to crash the REPL
    # mid-turn. The turn must complete and the reply reach scrollback.
    let root = newFixture("cwd_removed_test")
    writeConfiguredProvider(root)
    # Responses live outside the cwd so deleting the cwd (the point of
    # this test) does not also delete the stub's responses.
    let responsesPath = root / "stub_responses.json"
    writeFile(responsesPath, $(%*[
      {
        "role": "assistant",
        "content": "reply after cwd removed",
        "contentChunks": ["reply after cwd removed"],
        "usage": {"promptTokens": 1, "completionTokens": 1,
                   "totalTokens": 2, "cachedTokens": 0}
      }
    ]))

    let tty = startStub(root, responsesPath = responsesPath)
    defer: tty.close()

    tty.expect "❯"
    removeDir(root / "run")
    doAssert not dirExists(root / "run"), "test cwd removal failed"
    tty.send "hello"
    tty.expect "hello"
    tty.send "\n"
    tty.expectInHistory "reply after cwd removed"
    # The reply reaching scrollback proves the turn completed with no crash;
    # :q + a shutdown drain hangs on frame-sync events, so rely on the
    # committed-history assertion (as simple one-turn does) rather than
    # asserting a clean exit here.

  test "prompt draft is restored after a killed process":
    # Regression: a half-typed prompt must survive an unexpected shutdown
    # (kill / power-off / Ctrl-C) so the work isn't lost. The editor's text is
    # continuously persisted to a draft sidecar and reloaded on resume.
    let root = newFixture("draft_restore")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[])

    # Phase 1: start an idle REPL and type a prompt WITHOUT submitting it.
    let draftText = "important unsent prompt"
    let tty1 = startStub(root)
    tty1.expect "❯"
    tty1.send draftText
    tty1.expect draftText
    # Wait past the 250ms flusher debounce so the draft reaches disk. No turn
    # has run, so this is the pre-first-turn case: the draft lands under the
    # cwd-keyed pending path and no .3log exists yet.
    sleep 800
    tty1.drain(100)
    let draftPath = draftPathForDir(root)
    check fileExists(draftPath)
    check readFile(draftPath) == draftText
    # No session transcript exists for a conversation that never had a turn.
    let sessDir = root / "data" / "3code" / "sessions"
    var any3log = false
    for kind, p in walkDir(sessDir):
      if kind == pcFile and p.endsWith(".3log"): any3log = true
    check not any3log

    # Phase 2: simulate an unexpected shutdown (kill / power-off / Ctrl-C).
    # SIGTERM triggers cleanup()'s final draft flush; SIGKILL is the fallback.
    tty1.hardKillAndWait()
    tty1.discardClose()

    # Phase 3: start a FRESH session in the same directory (no --resume — there
    # is nothing to resume). The pending draft is keyed by cwd, so the next
    # fresh session in this directory picks it up and restores it.
    let tty2 = startStub(root)
    defer: tty2.close()
    tty2.expect draftText

  # The quiet-watch thread now only fires a hard timeout; there is no
  # intermediate hourglass label. Wait briefly so the spinner is active
  # before exercising cancel.
  proc expectActiveSpinner(tty: TtySession) =
    tty.drain 200

  test "escape cancels during network-quiet":
    let root = newFixture("quiet_cancel_esc")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "should not appear",
        "contentChunks": ["should not appear"],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      },
      {
        "role": "assistant",
        "content": "second turn ok",
        "contentChunks": ["second turn ok"],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      }
    ])
    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()
    tty.expect "❯"
    tty.send "first turn"
    tty.send "\n"
    tty.expectActiveSpinner()
    tty.send "\x1b"
    tty.expectInHistory "interrupted by user"
    tty.expect "❯"
    tty.send "second"
    tty.send "\n"
    tty.expectInHistory "second turn ok"

  test "ctrl-c cancels during network-quiet":
    let root = newFixture("quiet_cancel_ctrlc")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "should not appear",
        "contentChunks": ["should not appear"],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      },
      {
        "role": "assistant",
        "content": "second turn ok",
        "contentChunks": ["second turn ok"],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      }
    ])
    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()
    tty.expect "❯"
    tty.send "first turn"
    tty.send "\n"
    tty.expectActiveSpinner()
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.expect "❯"
    tty.send "second"
    tty.send "\n"
    tty.expectInHistory "second turn ok"

  test "ctrl-c during bash tool then prompt accepts input":
    let root = newFixture("ctrlc_during_bash")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Running a slow tool.",
        "contentChunks": ["Running a slow tool."],
        "tool_calls": [
          toolCall("call_slow", "bash", %*{
            "command": "sleep 30"
          })
        ],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      },
      {
        "role": "assistant",
        "content": "After interrupt ok.",
        "contentChunks": ["After interrupt ok."],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      }
    ])
    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()
    tty.expect "❯"
    tty.send "run slow tool"
    tty.send "\n"
    tty.expectInHistory "Running a slow tool."
    tty.expectInHistory "$ sleep 30"
    tty.drain(300)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.expect "❯"
    # The regression: after interrupt the prompt must accept typing.
    tty.send "hello"
    tty.expectTypedAtPrompt("hello")
    tty.send "\n"
    tty.expectInHistory "After interrupt ok."

  test "ctrl-c during active api streaming then prompt accepts input":
    let root = newFixture("ctrlc_active_stream")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "streaming now",
        "contentChunks": ["streaming now"],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      },
      {
        "role": "assistant",
        "content": "after interrupt ok",
        "contentChunks": ["after interrupt ok"],
        "usage": {"promptTokens": 10, "completionTokens": 5,
                  "totalTokens": 15, "cachedTokens": 0}
      }
    ])
    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()
    tty.expect "❯"
    tty.send "go"
    tty.send "\n"
    # Interrupt before the network-quiet label appears (mid-stream).
    tty.drain(300)
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.expect "❯"
    tty.send "hello"
    tty.expectTypedAtPrompt("hello")
    tty.send "\n"
    tty.expectInHistory "after interrupt ok"

  test "multiline prompt and queued multiline autosend":
    let root = newFixture("multiline_visual_test")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "First multiline response.",
        "contentChunks": ["First multiline response."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 24,
          "totalTokens": 144,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Queued multiline response.",
        "contentChunks": ["Queued multiline response."],
        "usage": {
          "promptTokens": 180,
          "completionTokens": 32,
          "totalTokens": 212,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "first line"
    tty.send "\x1b[13;2u"
    tty.send "second line"
    tty.expect "second line"
    tty.send "\n"

    tty.send "queued line one"
    tty.send "\x1b[13;2u"
    tty.send "queued line two"
    tty.expect "queued line two"
    tty.advanceTicker()
    tty.requireVisibleEditorCaret("queued line two")
    tty.advanceTicker()
    tty.requireVisibleEditorCaret("queued line two")
    tty.advanceTicker()
    tty.requireVisibleEditorCaret("queued line two")
    tty.send "\n"
    tty.advanceTicker()
    tty.continueStubApi()

    tty.expectInHistory "❯ first line"
    tty.expectInHistory "  second line"
    tty.expectInHistory "First multiline response."
    tty.expectInHistory "❯ queued line one"
    tty.expectInHistory "  queued line two"
    tty.expectInHistory "Queued multiline response."
    tty.expectTokenBar(["○", "↑180", "↓32"])
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      MultilineVisualTestFrames,
      root / "multiline_visual_test_actual.txt")

  test "queued prompt survives a second submit during one turn":
    # After queuing a prompt mid-turn, the user can revise it: typing appends
    # to the buffered text (the queue is cancelled and the line kept), so a
    # second Enter re-queues the revised text. Only the revised prompt reaches
    # the conversation; the stale first queue is dropped, not merged in.
    let root = newFixture("two_queued")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "First reply.",
        "contentChunks": ["First reply."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 24,
          "totalTokens": 144,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Reply to revised prompt.",
        "contentChunks": ["Reply to revised prompt."],
        "usage": {
          "promptTokens": 150,
          "completionTokens": 20,
          "totalTokens": 170,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "initial prompt\n"
    tty.expect "initial prompt"
    # Turn is held open. Queue a prompt, then keep typing: the text appends to
    # the buffered line rather than starting fresh, and a second Enter re-queues
    # the whole revised text.
    tty.send "queued alpha\n"
    tty.expect "queued alpha"
    tty.drain 50
    tty.send " queued beta"
    tty.expect "queued alpha queued beta"
    tty.send "\n"
    tty.drain 50
    tty.advanceTicker()
    tty.continueStubApi()

    tty.expectInHistory "❯ initial prompt"
    tty.expectInHistory "First reply."
    tty.expectInHistory "❯ queued alpha queued beta"
    tty.expectInHistory "Reply to revised prompt."

  test "editing a queued prompt keeps the text instead of wiping it":
    # Regression: typing after a queued submit used to wipe the buffer and
    # start over. Now it cancels the queue and edits the existing text in
    # place, so the user can queue, change their mind, backspace, type, and
    # queue again. The edited text is what reaches scrollback at turn end.
    let root = newFixture("queued_prompt_edit")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "Holding turn open.",
        "contentChunks": ["Holding turn open."],
        "usage": {
          "promptTokens": 100,
          "completionTokens": 10,
          "totalTokens": 110,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Reply to edited prompt.",
        "contentChunks": ["Reply to edited prompt."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 8,
          "totalTokens": 128,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start turn\n"
    tty.expect "start turn"
    # Turn is held open. Type and queue a prompt, then change your mind:
    # backspace over the tail and retype an edited version. The hourglass
    # must clear and the edited text must survive, not be wiped.
    tty.send "hello world"
    tty.expect "hello world"
    tty.send "\n"
    tty.drain 50
    tty.send "\x7f"           # backspace: delete the 'd'
    tty.send " edited"         # buffer now reads "hello worl edited"
    tty.expect "hello worl edited"
    tty.requireVisibleEditorCaret("hello worl edited")
    tty.send "\n"             # re-queue the edited text
    tty.drain 50
    tty.advanceTicker()
    tty.continueStubApi()

    tty.expectInHistory "❯ start turn"
    tty.expectInHistory "❯ hello worl edited"
    tty.expectInHistory "Reply to edited prompt."
    # Regression guard for the old wipe behavior: backspacing and retyping
    # after the queue must build on the existing text, not start from empty.
    # With the bug, the buffer would have been wiped to " edited".
    tty.expectNeverInHistory "❯  edited"

  test "queued prompt typed during a turn keeps the line on a multi-row footer":
    # Regression: editing a queued mid-turn prompt. On a narrow terminal the
    # spinner label wraps to several rows, so cancelling the queue and typing
    # repaints a tall footer region each keystroke. The deferred-submit
    # suffix must clear and every typed char must stay visible, not flash and
    # vanish. Guards the cancel-path redraw so it paints exactly once per
    # keystroke (a double clear-and-repaint flashes on terminals without
    # DEC 2026 synchronized output).
    let root = newFixture("queued_narrow_footer")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "Holding turn open.",
        "contentChunks": ["Holding turn open."],
        "usage": {
          "promptTokens": 10,
          "completionTokens": 5,
          "totalTokens": 15,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root, cols = 18, rows = DefaultTtyRows)
    defer: tty.close()
    tty.expect "❯"
    tty.send "start turn\n"
    tty.expect "start turn"
    tty.drain(300)
    tty.send "hello"
    tty.requireVisibleEditorCaret("hello")
    tty.send "\n"
    tty.drain 50
    var acc = "hello"
    for ch in " world":
      acc.add ch
      tty.send $ch
      tty.drain(200)
      tty.requireVisibleEditorCaret(acc)
    tty.drain(400)
    tty.requireVisibleEditorCaret(acc)
    tty.continueStubApi()

  test "interrupt during a queued mid-turn prompt sends the queue next":
    # Design contract: a prompt queued during a turn shows the hourglass.
    # In that state, Ctrl-C (or Esc) cancelling the *current* turn must send
    # the queued turn immediately as the next user message. The queued prompt
    # is not discarded by the interrupt. If the user did not want it sent they
    # would delete the queued text first (typing after the queue cancels it
    # and lets them edit or clear the line before the interrupt lands).
    let root = newFixture("queued_interrupt")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "Holding turn open.",
        "contentChunks": ["Holding turn open."],
        "usage": {
          "promptTokens": 100,
          "completionTokens": 10,
          "totalTokens": 110,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Reply to queued prompt.",
        "contentChunks": ["Reply to queued prompt."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 8,
          "totalTokens": 128,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start turn\n"
    tty.expect "start turn"
    # Turn is held open. Queue a prompt and confirm the hourglass appears.
    tty.send "queued prompt"
    tty.expect "queued prompt"
    tty.send "\n"
    tty.drain 50
    # Interrupt the current turn. The queued prompt must survive and be sent
    # as the next user turn, not dropped.
    tty.send "\x03"
    tty.expectInHistory "interrupted by user"
    tty.expectInHistory "❯ queued prompt"
    tty.expectInHistory "Reply to queued prompt."

  test "bare escape during a queued mid-turn prompt sends the queue next":
    # Same contract as the Ctrl-C variant above, exercised with a bare Esc.
    # Esc is also the prefix of arrow-key sequences; a bare Esc (no tail byte
    # within the poll window) is a cancel, so the queued prompt survives and
    # is sent. An arrow key (Esc + tail) is editing intent and would drop the
    # queue instead (covered by the editing tests above).
    let root = newFixture("queued_interrupt_esc")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "waitForTestContinue": true,
        "content": "Holding turn open.",
        "contentChunks": ["Holding turn open."],
        "usage": {
          "promptTokens": 100,
          "completionTokens": 10,
          "totalTokens": 110,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Reply to queued prompt.",
        "contentChunks": ["Reply to queued prompt."],
        "usage": {
          "promptTokens": 120,
          "completionTokens": 8,
          "totalTokens": 128,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "start turn\n"
    tty.expect "start turn"
    tty.send "queued prompt"
    tty.expect "queued prompt"
    tty.send "\n"
    tty.drain 50
    # Bare Esc cancels the current turn. The queued prompt must survive and
    # be sent as the next user turn, not dropped.
    tty.send "\x1b"
    tty.expectInHistory "interrupted by user"
    tty.expectInHistory "❯ queued prompt"
    tty.expectInHistory "Reply to queued prompt."

  test "bash tool success and nonzero exit":
    let root = newFixture("bash_tool_visual_test")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Running bash checks.",
        "contentChunks": ["Running bash checks."],
        "tool_calls": [
          toolCall("call_success", "bash", %*{
            "command": "printf 'ok-one\\nok-two\\n'"
          }, %*{
            "stream": ["ok-one", "ok-two"],
            "output": "ok-one\nok-two\n",
            "code": 0
          }),
          toolCall("call_failure", "bash", %*{
            "command": "printf 'bad-one\\nbad-two\\nbad-three\\n'; exit 7"
          }, %*{
            "stream": ["bad-one", "bad-two", "bad-three"],
            "output": "bad-one\nbad-two\nbad-three\n",
            "code": 7
          }),
          toolCall("call_scroll", "bash", %*{
            "command": "printf 'scroll-1\\nscroll-2\\nscroll-3\\nscroll-4\\nscroll-5\\nscroll-6\\nscroll-7\\nscroll-8\\nscroll-9\\nscroll-10\\n'"
          }, %*{
            "stream": [
              "scroll-1",
              "scroll-2",
              "scroll-3",
              "scroll-4",
              "scroll-5",
              "scroll-6",
              "scroll-7",
              "scroll-8",
              "scroll-9",
              "scroll-10"
            ],
            "output": "scroll-1\nscroll-2\nscroll-3\nscroll-4\nscroll-5\nscroll-6\nscroll-7\nscroll-8\nscroll-9\nscroll-10\n",
            "code": 0
          }),
          toolCall("call_slow", "bash", %*{
            "command": "sleep 3; printf 'slow-done\\n'"
          })
        ],
        "usage": {
          "promptTokens": 130,
          "completionTokens": 18,
          "totalTokens": 148,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Bash checks complete.",
        "contentChunks": ["Bash checks complete."],
        "usage": {
          "promptTokens": 210,
          "completionTokens": 20,
          "totalTokens": 230,
          "cachedTokens": 0
        }
      }
    ])

    # 48 rows: the test content sits at the 40-row default boundary, and the
    # intentional prompt-echo separator blank (emitUserSubmit's \r\n\r\n,
    # transcriptOwnsSpacing=true) would scroll the `╭─╮` banner off the grid.
    # Headroom keeps the whole transcript visible. Per-test sizing is an
    # established pattern (see the cols=18 test above).
    let tty = startStub(root, rows = 48)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "run bash checks\n"
    tty.expectInHistory "Running bash checks."
    tty.expectInHistory "$ printf 'ok-one"
    tty.expectInHistory "ok-two"
    tty.expectInHistory "Ø printf 'bad-one"
    tty.expectInHistory "bad-three"
    tty.expectInHistory "$ printf 'scroll-1"
    tty.expectInHistory "scroll-10"
    tty.expectInHistory "$ sleep 3; printf 'slow-done"
    tty.expectInHistory "slow-done"
    tty.expectInHistory "Bash checks complete."
    tty.expectTokenBar(["○", "↑210", "↓20"])
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      BashToolVisualTestFrames,
      root / "bash_tool_visual_test_actual.txt")

  test "bash tool output does not flicker blank on commit":
    # Regression: when a streaming bash tool completed, the live viewport was
    # cleared in one synchronized frame and the final transcript committed in
    # a second. On a real terminal that produced a visible blank flash: the
    # output vanished then reappeared. The fix folds the viewport clear into
    # the same sync frame as the transcript append.
    #
    # The PTY harness batches reads, so the two old sync frames landed in one
    # grid snapshot and the flash was invisible there. The assertion is on
    # the raw byte stream instead: after the streamed output first appears,
    # no synchronized frame may erase the screen region without also carrying
    # the committed transcript text. Such an erase-only frame is exactly the
    # blank flash a human would see.
    let root = newFixture("bash_flicker")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Running one tool.",
        "contentChunks": ["Running one tool."],
        "tool_calls": [
          toolCall("call_marker", "bash", %*{
            "command": "printf 'flicker-marker\n'"
          }, %*{
            "stream": ["flicker-marker"],
            "output": "flicker-marker\n",
            "code": 0
          })
        ],
        "usage": {"promptTokens": 40, "completionTokens": 8,
                  "totalTokens": 48, "cachedTokens": 0}
      },
      {
        "role": "assistant",
        "content": "Done.",
        "contentChunks": ["Done."],
        "usage": {"promptTokens": 60, "completionTokens": 6,
                  "totalTokens": 66, "cachedTokens": 0}
      }
    ])

    let tty = startStub(root)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "run it\n"
    tty.expectInHistory "flicker-marker"
    tty.expectInHistory "Done."
    tty.drain(100)
    # Split the raw byte stream into synchronized-frame payloads (between
    # SyncBegin and SyncEnd). The flicker is an erase-then-redraw: a sync
    # frame that clears the viewport region (cursor-up + erase) without the
    # streamed text, immediately followed by a frame that rewrites that text
    # as committed scrollback. Assert no such erased-then-redrawn pair exists
    # for the streamed marker.
    const SyncBegin = "\x1b[?2026h"
    const SyncEnd = "\x1b[?2026l"
    var syncPayloads: seq[string]
    var pos = 0
    while true:
      let start = tty.raw.find(SyncBegin, pos)
      if start < 0: break
      let stop = tty.raw.find(SyncEnd, start + SyncBegin.len)
      if stop < 0: break
      syncPayloads.add tty.raw[start + SyncBegin.len ..< stop]
      pos = stop + SyncEnd.len
    var firstMarkerFrame = -1
    for i, p in syncPayloads:
      if "flicker-marker" in p:
        firstMarkerFrame = i
        break
    require firstMarkerFrame >= 0
    for i in firstMarkerFrame ..< syncPayloads.len - 1:
      if "\x1b[J" in syncPayloads[i] and
          "flicker-marker" notin syncPayloads[i] and
          "flicker-marker" in syncPayloads[i + 1]:
        check false
        break

  test "non-bash tool transcript shapes":
    let root = newFixture("other_tools_visual_test")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {
        "role": "assistant",
        "content": "Exercising non-bash tools.",
        "contentChunks": ["Exercising non-bash tools."],
        "tool_calls": [
          toolCall("call_read", "read", %*{
            "path": "notes.txt"
          }, %*{
            "output": "read-one\nread-two\nread-three\n",
            "code": 0
          }),
          toolCall("call_write", "write", %*{
            "path": "notes.txt",
            "body": "new notes\n"
          }, %*{
            "output": "wrote /tmp/notes.txt (10 bytes)",
            "code": 0,
            "diff": "--- /tmp/notes.txt\n+++ /tmp/notes.txt\n+new notes\n"
          }),
          toolCall("call_patch", "patch", %*{
            "path": "notes.txt",
            "edits": [
              {"search": "new notes", "replace": "patched notes"}
            ]
          }, %*{
            "output": "",
            "code": 0,
            "diff": "--- /tmp/notes.txt\n+++ /tmp/notes.txt\n-new notes\n+patched notes\n"
          }),
          toolCall("call_apply_patch", "apply_patch", %*{
            "input": "*** Begin Patch\n*** Add File: applied.txt\n+hello\n*** End Patch\n"
          }, %*{
            "output": "added /tmp/applied.txt (6 bytes)",
            "code": 0,
            "diff": "--- /tmp/applied.txt\n+++ /tmp/applied.txt\n+hello\n"
          }),
          toolCall("call_search", "web_search", %*{
            "query": "terminal rendering"
          }, %*{
            "output": "1. Terminal Rendering Guide\nhttps://example.test/rendering\nUseful result snippet.\n",
            "code": 0
          }),
          toolCall("call_fetch", "web_fetch", %*{
            "url": "https://example.test/rendering"
          }, %*{
            "output": "Fetched page title\nFetched page body line\n",
            "code": 0
          }),
          toolCall("call_plan", "update_plan", %*{
            "items": [
              {"text": "inspect", "status": "completed"},
              {"text": "adjust", "status": "in_progress"},
              {"text": "verify", "status": "pending"}
            ]
          }, %*{
            "output": "completed: inspect\nin_progress: adjust\npending: verify\n",
            "code": 0
          }),
          toolCall("call_unknown", "not_a_tool", %*{}, %*{
            "output": "Error: tool 'not_a_tool' is not available.",
            "code": 1
          }),
          toolCall("call_clear", "clear", %*{
            "prompt": "fresh context prompt"
          }, %*{
            "output": "",
            "code": 0
          })
        ],
        "usage": {
          "promptTokens": 300,
          "completionTokens": 44,
          "totalTokens": 344,
          "cachedTokens": 0
        }
      },
      {
        "role": "assistant",
        "content": "Clear completed.",
        "contentChunks": ["Clear completed."],
        "usage": {
          "promptTokens": 90,
          "completionTokens": 12,
          "totalTokens": 102,
          "cachedTokens": 0
        }
      }
    ])

    let tty = startStub(root, rows = 70)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
      tty.close()

    tty.expect "❯"
    tty.send "run other tool checks\n"
    tty.expectInHistory "Exercising non-bash tools."
    tty.expectInHistory "r notes.txt"
    tty.expectInHistory "read-three"
    tty.expectInHistory "w notes.txt"
    tty.expectInHistory "+new notes"
    tty.expectInHistory "p --- /tmp/notes.txt"
    tty.expectInHistory "+patched notes"
    tty.expectInHistory "p --- /tmp/applied.txt"
    tty.expectInHistory "⌕ terminal rendering"
    tty.expectInHistory "⇊ https://example.test/rendering"
    tty.expectInHistory "≡ ──────────"
    tty.expectInHistory "✕ unknown tool: not_a_tool"
    tty.expectInHistory "↻ fresh context prompt"
    tty.expectInHistory "fresh context prompt"
    tty.expectInHistory "Clear completed."
    tty.expectTokenBar(["○", "↑90", "↓12"])
    tty.drain(200)
    tty.expectMeaningfulFrameArtifact(
      OtherToolsVisualTestFrames,
      root / "other_tools_visual_test_actual.txt")

  test "consecutive turns never accumulate extra blank separator lines":
    # Regression for the intermittent extra-blank-line bug: the gap
    # between one scrollback entry and the next must be exactly one blank
    # row.  The bar-tick thread used to repaint the footer between
    # prepareAssistantContentStart and the content anchor, stranding a
    # gap row in scrollback.
    let root = newFixture("separators")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[
      {"role": "assistant", "content": "First reply line.",
       "contentChunks": ["First reply line."],
       "preStreamDelayMs": 600,
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}},
      {"role": "assistant", "content": "Second reply line.",
       "contentChunks": ["Second reply line."],
       "preStreamDelayMs": 600,
       "usage": {"promptTokens": 10, "completionTokens": 5,
                 "totalTokens": 15, "cachedTokens": 0}}
    ])
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    tty.send "hello one"; tty.expect "hello one"; tty.send "\n"
    tty.expectInHistory "First reply line."
    tty.expectTokenBar(["○", "↑10", "↓5"])
    tty.drain(300)
    tty.send "hello two"; tty.expect "hello two"; tty.send "\n"
    tty.expectInHistory "Second reply line."
    tty.expectTokenBar(["○", "↑10", "↓5"])
    tty.drain(300)
    # The token bar is only painted while the turn is active. Sample the
    # *stable idle* state — wait for the caret to reappear on the live `❯`
    # prompt — so frames[^1] is the idle repaint, not a transient spinner
    # tick that can sample a mid-turn frame and report a false maxRun>1.
    # The stranded-gap bug persists into the idle frame (it is committed
    # scrollback), so maxRun <= 1 still catches it.
    let idleDeadline = epochTime() + 5.0
    block waitForIdle:
      while epochTime() < idleDeadline:
        tty.drain(20)
        if tty.frames.len > 0:
          let f = tty.frames[^1]
          if not f.cursorHidden and f.cursorRow >= 0 and
              f.cursorRow < f.rows.len and "❯" in f.rows[f.cursorRow]:
            break waitForIdle
        sleep 10
    # The final frame must not have >1 consecutive blank rows anywhere in
    # scrollback: that is the visual symptom of the extra-line bug.
    let rows = if tty.frames.len > 0: tty.frames[^1].rows else: @[]
    var maxRun = 0
    var curRun = 0
    for r in rows:
      if r.strip.len == 0:
        inc curRun; maxRun = max(maxRun, curRun)
      else:
        curRun = 0
    check maxRun <= 1

  test "every prompt first line survives a reasoning-ticker to content transition":
    # Regression: when a thinking ticker clears at the start of streamed
    # content, a concurrent footer repaint could walk its erase one row too
    # far (the cached footer height still counted the ticker) and wipe the
    # just-echoed prompt's first line from scrollback, leaving a blank `❯`
    # row. Run several reasoning turns so the ticker appear/clear transition
    # is exercised repeatedly; every user prompt must remain intact in the
    # final scrollback.
    let root = newFixture("ticker_prompt_drop")
    writeConfiguredProvider(root)
    let prompts = ["alpha-marker", "beta-marker", "gamma-marker", "delta-marker"]
    var responses: seq[JsonNode] = @[]
    for p in prompts:
      responses.add %*{
        "reasoning_content": "thinking about " & p,
        "reasoningChunks": ["thinking about " & p],
        "preStreamDelayMs": 400,
        "content": "reply to " & p,
        "contentChunks": ["reply to " & p],
        "usage": {"promptTokens": 40, "completionTokens": 5,
                  "totalTokens": 45, "cachedTokens": 0}
      }
    writeStubResponses(root, %responses)
    let tty = startStub(root)
    defer: tty.close()
    tty.expect "❯"
    for p in prompts:
      tty.send p
      tty.expect p
      tty.send "\n"
      tty.expectInHistory "❯ " & p
      tty.expectInHistory "reply to " & p
      tty.expect "❯"
    # Re-assert every prompt survived into the committed scrollback. A
    # dropped first line would leave no `❯ <prompt>` row at all.
    # `screenText` returns the full grid (scrollback + visible), so this
    # catches a prompt that appeared while typing but was later erased from
    # the screen by a footer repaint, which `expectInHistory` (text that ever
    # appeared) would miss.
    tty.drain(300)
    let finalScreen = tty.screenText()
    for p in prompts:
      check ("❯ " & p) in finalScreen

  test "background and foreground restores raw mode and editor stays responsive":
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "bgfg_rawmode":
      check true
    else:
      # Regression: after Ctrl+Z (SIGTSTP) + fg (SIGCONT) the terminal was
      # left in cooked mode by the shell, and the editor's raw-mode-only read
      # loop saw no input until a full line was entered. The fix re-applies
      # raw mode after resume.
      when defined(posix):
        let root = newFixture("bgfg_rawmode")
        writeConfiguredProvider(root)
        writeStubResponses(root, %*[{
          "role": "assistant",
          "content": "reply after bg-fg",
          "contentChunks": ["reply after bg-fg"],
          "usage": {
            "promptTokens": 16,
            "completionTokens": 4,
            "totalTokens": 20,
            "cachedTokens": 0
          }
        }])
        let tty = startStub(root, rows = 16)
        defer:
          if not tty.exited:
            tty.hardKillAndWait()
            tty.discardClose()
          else:
            tty.close()

        tty.expect "❯"
        # Type a few characters to confirm the editor is alive.
        tty.send "hello"
        tty.expect "hello"

        # Simulate Ctrl+Z: the editor's handler sends SIGTSTP to itself.
        tty.send "\x1a"

        # Wait for the child to actually stop.
        var status: cint = 0
        var waitCount = 0
        while waitpid(tty.pid, status, WNOHANG or WUNTRACED) != tty.pid and
              waitCount < 50:
          sleep 10
          inc waitCount

        # Resume the child.
        discard kill(tty.pid, SIGCONT)
        tty.drain(100)

        # The editor should be responsive: send more text and submit.
        tty.send " world\n"
        tty.expectInHistory "reply after bg-fg"
        # After the turn, a new prompt appears. Type into it.
        tty.expect "❯"
        tty.send "still working"
        tty.expect "still working"

when false:
  suite "disabled terminal visual contract tests":
    test "stub provider streams bash output without replaying it later":
      if getEnv("THREECODE_TTY_ONLY") in ["", "stream_no_replay"]:
        let root = newFixture("stream_no_replay")
        writeConfiguredProvider(root)
        writeStubResponses(root, %*[
          {
            "role": "assistant",
            "content": "About to run one tool.",
            "tool_calls": [
              toolCall("call_once", "bash", %*{
                "command": "printf 'unique-stream-line\\n'; sleep 0.25"})
            ]
          },
          {
            "role": "assistant",
            "content": "Done.",
            "usage": {
              "promptTokens": 42,
              "completionTokens": 7,
              "totalTokens": 49,
              "cachedTokens": 0
            }
          }
        ])

      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
        tty.close()

      tty.expect "❯"
      tty.send "exercise one streamed tool\n"
      tty.expectInHistory "About to run one tool."
      tty.expectInHistory "$ printf 'unique-stream-line"
      tty.expectInHistory "unique-stream-line"
      tty.expectInHistory "Done."
      tty.drain(200)
      check tty.framePresenceRuns("unique-stream-line") == 1
      tty.send ":q\n"
      tty.expectExit 0

  test "resizing during a live stub stream does not truncate or retry":
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "resize_stream":
      check true
    else:
      let root = newFixture("resize_stream")
      writeConfiguredProvider(root)
      writeStubResponses(root, %*[
        {
          "role": "assistant",
          "content": "Resize stream part one. Resize stream part two. Resize stream complete.",
          "usage": {
            "promptTokens": 42,
            "completionTokens": 9,
            "totalTokens": 51,
            "cachedTokens": 0
          }
        }
      ])

      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
        tty.close()

      tty.expect "❯"
      tty.send "resize while streaming\n"
      tty.expectInHistory "Resize stream part one."
      tty.resizeMainThread(104, 34)
      tty.drain(80)
      tty.resizeMainThread(132, 38)
      tty.expectInHistory "Resize stream complete."
      tty.expectTokenBar(["○", "↑42", "↓9"])
      tty.expectMeaningfulFrameArtifact(
        ResizeStreamFrames,
        root / "resize_stream_actual.txt")

  proc dropRunes(s: string; n: int): string =
    var i = 0
    var cnt = 0
    while i < s.len and cnt < n:
      i += max(1, runeLenAt(s, i))
      inc cnt
    if i >= s.len: "" else: s[i..^1]

  test "resize at idle rewraps the editor prompt":
    if getEnv("THREECODE_TTY_ONLY") notin ["", "resize_idle"]:
      check true
    else:
      let root = newFixture("resize_idle")
      writeConfiguredProvider(root)
      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.close()
      tty.expect "❯"
      # Type text long enough to wrap at 80 cols, then resize narrower so it
      # rewraps, and verify the continuation rows appear.
      tty.send "this is a long enough line of idle text to wrap when narrowed"
      tty.drain(100)
      tty.resize(40, 12)
      tty.drain(300)
      let narrow = tty.screenText()
      # At 40 cols the single 80-col line rewraps onto multiple rows.
      check "this is a long enough line of idle" in narrow
      # Reassemble the editor rows (strip continuation prefix) and verify the
      # typed text survived the rewrap with no duplicated or dropped runes.
      var editorText = ""
      var inEditor = false
      for row in narrow.splitLines():
        if row.startsWith("❯ "):
          editorText.add row.dropRunes(2)
          inEditor = true
        elif inEditor and row.startsWith("  "):
          editorText.add row.dropRunes(2)
        elif inEditor and row.strip().len == 0:
          break
      check editorText == "this is a long enough line of idle text to wrap when narrowed"

  test "main visual test":
    if getEnv("THREECODE_TTY_ONLY").len > 0 and
        getEnv("THREECODE_TTY_ONLY") != "main_visual_test":
      check true
    else:
      let root = newFixture("main_visual_test")
      writeConfiguredProvider(root)
      createDir(root / "run" / "brpr.db")
      createDir(root / "run" / "tools")
      writeFile(root / "run" / "brpr.db" / "data.mdb", "")
      writeFile(root / "run" / "brpr.db" / "lock.mdb", "")
      writeStubResponses(root, %*[
        {
          "role": "assistant",
          "reasoning_content": "We should inspect the repository tree before identifying issues.",
          "reasoningChunks": [
            "We should inspect the repository tree before identifying issues."
          ],
          "content": "",
          "tool_calls": [
            toolCall("call_ls", "bash", %*{
              "command": "ls -R"},
              %*{
                "stream": ["brpr.db", "tools"],
                "output": "brpr.db\ntools\n",
                "code": 0
              })
          ]
        },
        {
          "role": "assistant",
          "reasoning_content": "We need to look at the repository layout after the ls tool call and decide what stands out.",
          "reasoningChunks": [
            "We need to look at the repository layout after the ls tool call and decide what stands out."
          ],
          "preStreamDelayMs": 900,
          "content": "I saw the main project directories.",
          "contentChunks": ["I saw the main project directories."],
          "usage": {
            "promptTokens": 5500,
            "completionTokens": 188,
            "totalTokens": 5688,
            "cachedTokens": 0
          }
        },
        {
          "role": "assistant",
          "reasoning_content": "thinking about visible ticker animation",
          "reasoningChunks": ["thinking about ", "visible ", "ticker ", "animation"],
          "content": "Streaming **markdown** before tools.",
          "contentChunks": ["Streaming **markdown** before tools."],
          "tool_calls": [
            toolCall("call_bash1", "bash", %*{
              "command": "printf 'bash-line-1\\nbash-line-2\\nbash-line-3\\nbash-line-4\\nbash-line-5\\nbash-line-6\\nbash-line-7\\nbash-line-8\\nbash-line-9\\nbash-line-10\\nbash-line-11\\nbash-line-12\\n'"},
              %*{
                "stream": [
                  "bash-line-1",
                  "bash-line-2",
                  "bash-line-3",
                  "bash-line-4",
                  "bash-line-5",
                  "bash-line-6",
                  "bash-line-7",
                  "bash-line-8",
                  "bash-line-9",
                  "bash-line-10",
                  "bash-line-11",
                  "bash-line-12"
                ],
                "output": "bash-line-1\nbash-line-2\nbash-line-3\nbash-line-4\nbash-line-5\nbash-line-6\nbash-line-7\nbash-line-8\nbash-line-9\nbash-line-10\nbash-line-11\nbash-line-12\n",
                "code": 0
              }),
            toolCall("call_bash2", "bash", %*{
              "command": "printf second-tool"},
              %*{
                "stream": ["second-tool"],
                "output": "second-tool\n",
                "code": 0
              })
          ]
        },
        {
          "role": "assistant",
          "content": "Buffered prompt answered.",
          "contentChunks": ["Buffered prompt answered."],
          "usage": {
            "promptTokens": 120,
            "completionTokens": 8,
            "totalTokens": 128,
            "cachedTokens": 32
          }
        },
        {
          "role": "assistant",
          "preStreamDelayMs": 1800,
          "content": "yes it is",
          "contentChunks": ["yes it is"],
          "usage": {
            "promptTokens": 16,
            "completionTokens": 36,
            "totalTokens": 52,
            "cachedTokens": 3200
          }
        },
        {
          "role": "assistant",
          "content": "Sure is. Let me know when you have a real task.",
          "contentChunks": ["Sure is. Let me know when you have a real task."],
          "usage": {
            "promptTokens": 31,
            "completionTokens": 31,
            "totalTokens": 62,
            "cachedTokens": 3200
          }
        }
      ])

      let tty = startStub(root)
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.writeMeaningfulFrameArtifact(root / "meaningful_frames.txt")
        tty.close()

      tty.expect "❯"
      tty.send "have a look around the codebase and identify any issues"
      tty.send "\n"
      tty.expectInHistory "$ ls -R"
      tty.expectInHistory "brpr.db"
      tty.expectInHistory "… We"
      tty.expectInHistory "I saw the main project directories."
      tty.expectTokenBar(["○", "↑5.5k", "↓188"])
      tty.send "exercise visual contract"
      tty.send "\n"
      tty.expect("thinking")
      tty.expectTokenBar(["○"])
      tty.expectInHistory "thinking about visible ticker animation"
      tty.send "buffered"
      tty.send "\x1b[27;2;13~"
      tty.send "prompt"
      tty.send "\n"
      tty.expectInHistory "Streaming markdown before tools."
      tty.expectInHistory "❯ buffered"
      tty.expectInHistory "  prompt"
      tty.expectInHistory "bash-line-9"
      tty.expectInHistory "second-tool"
      tty.expectInHistory "Buffered prompt answered."
      tty.expectTokenBar(["○", "↑120", "↻32", "↓8"])
      tty.send "this is..."
      tty.send "\x1b[13;2u"
      tty.send "a test!!!"
      tty.send "\n"
      tty.expectTokenBar(["○"])
      tty.send "and"
      tty.send "\x1b[13;2u"
      tty.send "another"
      tty.send "\n"
      tty.expectInHistory "yes it is"
      tty.expectInHistory "Sure is. Let me know when you have a real task."
      tty.expectMeaningfulFrameArtifact(
        MainVisualTestFrames,
        root / "main_visual_test_actual.txt")
