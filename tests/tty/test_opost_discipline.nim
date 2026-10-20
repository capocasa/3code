## Reproduction (gh #54): a parent shell can hand 3code a tty with `OPOST`
## off (a crashed CLI, `stty -opost`, a multiplexer relay). With OPOST off
## ONLCR is inert, so every bare `\n` 3code writes keeps the previous row's
## column and the startup screen drifts right — the box art lands mid-row,
## the `provider`/`model` rows start wherever the previous row ended.
##
## 3code must own the output discipline instead of inheriting it: turn
## `OPOST|ONLCR` back on before the first paint, and never clear OPOST in
## its own raw-mode switches. Then every row renders at column 0 even when
## the pty started `-opost`, and no bare LF reaches the terminal.

import std/[os, strutils, unittest]
import tty_expect
import stub_helpers

const VisualOutputRoot = "tests/testdata" / "output" / "tty"

proc newFixture(name: string): string =
  result = getCurrentDir() / VisualOutputRoot / (name & "_" & $getCurrentProcessId())
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

proc stubEnv(root: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
  ]

proc screenRows(s: TtySession): seq[string] =
  for row in s.screenText().splitLines():
    if row.strip.len > 0:
      result.add row

proc rowStartingWith(s: TtySession; prefix: string): bool =
  ## True when some rendered row begins with `prefix` at column 0. With the
  ## bug, these rows instead begin with the previous row's leftover columns
  ## (or its trailing text), so the exact-prefix match fails.
  for row in s.screenRows():
    if row.startsWith(prefix):
      return true
  false

proc hasBareLinefeed(raw: string): bool =
  ## Any LF the kernel did not translate to CRLF (OPOST|ONLCR off at the
  ## time of the write) shows up as a bare `\n` in the master-side stream.
  var i = 0
  while i < raw.len:
    if raw[i] == '\n' and (i == 0 or raw[i - 1] != '\r'):
      return true
    inc i
  false

suite "output discipline: inherited -opost tty (gh #54)":
  test "startup rows render at column 0 on a -opost pty":
    let root = newFixture("opost_discipline")
    writeConfiguredProvider(root)
    let tty = newTtySession(ensureStubBinary(), args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root),
                            cols = 100, rows = 24,
                            slaveNoOpost = true)
    defer:
      tty.writeFrameArtifact(root / "frames.txt")
      tty.close()
    tty.expect "type a prompt"
    tty.drain(400)
    # The welcome box closes at the same indent it opens with, and the
    # profile block starts its rows at column 0 (leading layout spaces
    # only) instead of drifting right by the previous row's end column.
    check tty.rowStartingWith("  ╰─╯")
    check tty.rowStartingWith("  provider  stub")
    check tty.rowStartingWith("  model     stub-model")
    # No bare LF may reach the pty: 3code re-enabled OPOST|ONLCR before
    # the first paint, so the kernel translates every line ending.
    check not tty.raw.hasBareLinefeed()
    tty.expectAlive()
