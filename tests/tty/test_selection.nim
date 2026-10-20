discard """
  ## Runs on Windows too: with ENABLE_VIRTUAL_TERMINAL_INPUT the editor
  ## reads raw VT sequences (ReadFile) from the ConPTY, so the same CSI
  ## modifier bytes drive selection there. Verified live on Windows 11;
  ## the legacy pair-code path is covered in
  ## tests/core/test_windows_keys.nim.
"""
## Keyboard selection end-to-end: Shift+Arrow extends a reverse-video
## selection in the real binary's prompt, Ctrl+X cuts it, and the cut
## text reaches the model (submitted line loses the selected range).
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers
import ttty/grid

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata/output/tty" /
    (name & "_" & $getCurrentProcessId())
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

proc writeStubResponses(root: string) =
  writeFile(root / "run" / "stub_responses.json", $(%*[
    {"role": "assistant", "preStreamDelayMs": 100,
     "content": "ok.", "contentChunks": ["ok."],
     "usage": {"promptTokens": 5, "completionTokens": 2,
                "totalTokens": 7, "cachedTokens": 0}}
  ]))

proc startStub(root: string): TtySession =
  newTtySession(ensureStubBinary(), args = ["-x", "-i"], cwd = root / "run",
                env = stubEnv(root, root / "run" / "stub_responses.json"),
                keepHistory = false)

proc reverseCells*(g: Grid): int =
  ## Reverse-video cells anywhere on the live screen (selection highlight).
  for r in 0 ..< g.rows.len:
    for c in 0 ..< g.width:
      if g.cellAttr(r, c).hasAttr(saReverse): inc result

suite "keyboard selection":
  test "shift+arrows select, ctrl+x cuts, submit sends the cut line":
    let root = newFixture("selection")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    var s = startStub(root)
    defer: s.close()
    s.expect("❯", timeoutMs = 15000)
    s.send("hello world")
    s.expectTypedAtPrompt("hello world")
    # Six Shift+Left extend the selection over " world".
    for i in 0 ..< 6:
      s.send("\e[1;2D")
      sleep(80)
    check reverseCells(s.grid) >= 6
    # Ctrl+X cuts the selection; only "hello" remains at the prompt.
    # A loaded CI runner can lag the cut's repaint well past any fixed
    # sleep (the cut itself provably ran: selection active, ctrl+x
    # dispatched), so poll for the settled screen instead.
    s.send("\x18")
    var cutSettled = false
    for _ in 0 ..< 30:
      s.drain(100)
      var probe = ""
      for r in 0 ..< s.grid.rows.len:
        let t = s.grid.rowText(r)
        if "hello" in t: probe = t
      if "world" notin probe:
        cutSettled = true
        break
    check cutSettled
    var cutRow = ""
    for r in 0 ..< s.grid.rows.len:
      let t = s.grid.rowText(r)
      if "hello" in t: cutRow = t
    check "hello" in cutRow
    check "world" notin cutRow
    # Submit: the model sees the cut line, the reply lands in history.
    s.send("\r")
    s.expectInHistory("hello", timeoutMs = 10000)
    s.expectInHistory("ok.", timeoutMs = 10000)

  test "cmd+a selects all (kitty protocol); typing replaces the buffer":
    let root = newFixture("selectall")
    writeConfiguredProvider(root)
    writeStubResponses(root)
    var s = startStub(root)
    defer: s.close()
    s.expect("❯", timeoutMs = 15000)
    s.send("hello world")
    s.expectTypedAtPrompt("hello world")
    # Cmd+A arrives as CSI 97;9 u under the kitty keyboard protocol.
    s.send("\e[97;9u")
    sleep(80)
    check reverseCells(s.grid) >= 11
    # Typing replaces the whole selected buffer with one character.
    s.send("X")
    var replaced = false
    for _ in 0 ..< 30:
      s.drain(100)
      for r in 0 ..< s.grid.rows.len:
        let t = s.grid.rowText(r)
        if "❯ X" in t and "hello" notin t:
          replaced = true
          break
      if replaced: break
    check replaced
    s.send("\r")
    s.expectInHistory("❯ X", timeoutMs = 10000)
    s.expectInHistory("ok.", timeoutMs = 10000)
