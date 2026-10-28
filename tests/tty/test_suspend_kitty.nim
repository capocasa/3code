discard """
  disabled: "win"
  ## Ctrl-Z must suspend from every key encoding. The interactive app
  ## pushes the kitty keyboard protocol at startup, so on kitty-protocol
  ## terminals Ctrl-Z arrives as `CSI 122;5u`, not the legacy 0x1a byte.
  ## The kitty decoder only consults the command dispatch table, which
  ## had no `suspend` entry on POSIX (the legacy 0x1a path fell back to
  ## a KEYMAP entry), so Ctrl-Z did nothing on those terminals.
  ##
  ## Resume must also repaint: after SIGCONT the prompt has to come back
  ## before the next keystroke, or the shell's job-control output is the
  ## last thing on screen.
"""
import std/[json, os, strutils, unittest]
when defined(posix):
  import posix except SocketHandle
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

suite "ctrl-z suspends from every key encoding and repaints on resume":
  test "kitty-encoded ctrl-z suspends and the prompt repaints after SIGCONT":
    when defined(posix):
      let root = newFixture("suspend_kitty")
      writeConfiguredProvider(root)
      writeFile(root / "run" / "stub_responses.json", $ %*[
        {"role": "assistant", "content": "after kitty suspend",
         "contentChunks": ["after kitty suspend"],
         "usage": {"promptTokens": 16, "completionTokens": 4,
                   "totalTokens": 20, "cachedTokens": 0}}
      ])
      let stub = ensureStubBinary()
      let tty = newTtySession(stub,
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json"))
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.close()

      tty.expect "\u276f"
      tty.send "hello"
      tty.expect "hello"

      # Ctrl-Z as a kitty-protocol terminal sends it: CSI 122;5u. The
      # suspend handler must run: it pops the kitty flags (`CSI < 1 u`)
      # and disables bracketed paste before handing the terminal over.
      # The harness pty makes the child an orphaned process group (its
      # SIGTSTP is ignored, no stop is observable), so drive the resume
      # directly with SIGCONT like the legacy-byte tests do.
      tty.send "\x1b[122;5u"
      discard tty.waitForOutput()
      check "\x1b[<1u" in tty.raw

      # Settle, then mark the raw stream so only post-resume bytes count.
      tty.drain(150)
      tty.advanceRawMark()

      discard kill(tty.pid, SIGCONT)
      tty.drain(400)

      # Resume repaints without waiting for a keystroke: the volatile
      # block (bar + prompt) must be written again after SIGCONT. The
      # row-diffing painter used to skip this as a no-op because no
      # editor state changed, leaving the shell's job-control output as
      # the last thing on screen. The kitty flags are pushed again too.
      check "\x1b[>1u" in tty.freshRaw()
      check "\u276f" in cleanRaw(tty.freshRaw())
      check "\u276f" in tty.screenText()

      # The editor stays usable after the round trip.
      tty.send "x"
      tty.expect "hellox"
      tty.expectAlive()

  test "legacy-byte ctrl-z runs the same suspend handler":
    when defined(posix):
      let root = newFixture("suspend_legacy")
      writeConfiguredProvider(root)
      writeFile(root / "run" / "stub_responses.json", $ %*[
        {"role": "assistant", "content": "after legacy suspend",
         "contentChunks": ["after legacy suspend"],
         "usage": {"promptTokens": 16, "completionTokens": 4,
                   "totalTokens": 20, "cachedTokens": 0}}
      ])
      let stub = ensureStubBinary()
      let tty = newTtySession(stub,
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json"))
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.close()

      tty.expect "\u276f"
      # The 0x1a byte is what a terminal without the kitty protocol
      # sends. It must run the suspend handler (kitty flags popped),
      # not fall through as a no-op: the command-table dispatch owns
      # the key now, and a missing `suspend` registration there is what
      # killed Ctrl-Z.
      tty.send "\x1a"
      discard tty.waitForOutput()
      check "\x1b[<1u" in tty.raw
      tty.drain(150)
      tty.advanceRawMark()
      discard kill(tty.pid, SIGCONT)
      tty.drain(400)
      check "\x1b[>1u" in tty.freshRaw()
      check "\u276f" in cleanRaw(tty.freshRaw())

      tty.send "ok\n"
      tty.expectInHistory "after legacy suspend"
      tty.expect "\u276f"

  test "stale SIGCONT from an external resume does not break the next ctrl-z":
    when defined(posix):
      # An external suspend/resume (kill -TSTP elsewhere, then fg)
      # leaves SIGCONT queued because it is blocked process-wide. If a
      # later Ctrl-Z sigwait satisfied itself with that stale signal,
      # the handler would return before the process ever stopped and
      # Ctrl-Z would appear to freeze. The poller drains the stale
      # signal and repaints; requestBackground drains before killing.
      let root = newFixture("suspend_stale_cont")
      writeConfiguredProvider(root)
      writeFile(root / "run" / "stub_responses.json", $ %*[
        {"role": "assistant", "content": "after stale resume",
         "contentChunks": ["after stale resume"],
         "usage": {"promptTokens": 16, "completionTokens": 4,
                   "totalTokens": 20, "cachedTokens": 0}}
      ])
      let stub = ensureStubBinary()
      let tty = newTtySession(stub,
                              args = ["-x", "-i"],
                              cwd = root / "run",
                              env = stubEnv(root, root / "run" / "stub_responses.json"))
      defer:
        tty.writeFrameArtifact(root / "frames.txt")
        tty.close()

      tty.expect "\u276f"
      # External resume with no matching suspend: SIGCONT arrives out
      # of band and must be drained, not left queued for the next
      # sigwait. The drain also repaints (out-of-band screen change).
      tty.advanceRawMark()
      discard kill(tty.pid, SIGCONT)
      tty.drain(400)
      check "\u276f" in cleanRaw(tty.freshRaw())

      # A subsequent Ctrl-Z still suspends and resumes cleanly.
      tty.send "\x1a"
      discard tty.waitForOutput()
      check "\x1b[<1u" in tty.raw
      tty.drain(150)
      discard kill(tty.pid, SIGCONT)
      tty.drain(400)
      check "\x1b[>1u" in tty.freshRaw()

      tty.send "go\n"
      tty.expectInHistory "after stale resume"
      tty.expect "\u276f"
      tty.expectAlive()
