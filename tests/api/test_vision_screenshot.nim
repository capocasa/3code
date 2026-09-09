discard """
  targets: "c"
  matrix: "; -d:providerStub"
"""
## Computer use, end to end against the stub provider: the config line
## arms it, the first turn probes the backend and appends the activation
## note, the scripted model calls `screenshot`, and the follow-up user
## message carries the image as a content block while the tool result
## stays a text receipt. The capture is faked via THREECODE_SCREENSHOT_SRC
## so no real screen content is needed; the activation probe still checks
## the live X11 environment and skips headless.

import std/[base64, json, os, sequtils, strutils, unittest]
import threecode/[actions, api, library, prompts, screen, session, types]

const stubbed = defined(providerStub)

proc x11Ready(): bool =
  getEnv("DISPLAY").len > 0 and findExe("xdotool").len > 0 and
    ["import", "maim", "scrot"].anyIt(findExe(it).len > 0)

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_cushot_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")

proc isolateEnv(root: string) =
  putEnv("XDG_CONFIG_HOME", root / "xdg")
  putEnv("XDG_DATA_HOME", root / "data")
  putEnv("TMPDIR", root / "tmp")
  createDir(root / "tmp")

proc writeConfig(root: string) =
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
computer = "on"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"

[params]
provider = "stub"
model = "stub-model"
vision = "on"
""")

when not stubbed:
  suite "computer use gating (no stub)":
    setup:
      computerUseEnabled = false
      screen.shotHomeDir = ""
    teardown:
      computerUseEnabled = false
      screen.shotHomeDir = ""

    test "screenshot action without :computer is a plain error":
      let (outp, code, _) = runAction(Action(kind: akScreenshot))
      check code == 1
      check ":computer on" in outp

    test "schema offered only when armed, vision-capable and probed":
      let prof = Profile(family: "glm", vision: true)
      check not screenshotOffered(prof)
      let base = activeTools(prof).len
      computerUseEnabled = true
      # backend not probed yet → still not offered
      check not screenshotOffered(prof)
      if x11Ready():
        check screen.ensureComputerUse("gating").ok
        check screenshotOffered(prof)
        let tools = activeTools(prof)
        check tools.len == base + 1
        check tools[^1]{"function"}{"name"}.getStr == "screenshot"
        check screen.shotHomeDir.len > 0
      else:
        let (ok, err) = screen.ensureComputerUse("gating")
        check not ok
        check err.len > 0

    test "non-vision profile never gets the schema":
      computerUseEnabled = true
      check screen.ensureComputerUse("gating2").ok or not x11Ready()
      let prof = Profile(family: "glm", vision: false)
      check not screenshotOffered(prof)
else:
  suite "computer use (stub e2e)":
    setup:
      computerUseEnabled = false
      screen.shotHomeDir = ""
    teardown:
      computerUseEnabled = false
      screen.shotHomeDir = ""
      putEnv("THREECODE_SCREENSHOT_SRC", "")

    test "model screenshot -> receipt + image block on the next message":
      if not x11Ready(): skip()
      let root = newFixture("shot")
      writeConfig(root)
      isolateEnv(root)
      copyFile("testdata/images/tiny.png", root / "run" / "tiny.png")
      putEnv("THREECODE_SCREENSHOT_SRC", root / "run" / "tiny.png")
      writeFile(root / "run" / "stub_responses.json", $(%*[
        %*{"content": "", "tool_calls": [{
          "id": "call_1",
          "type": "function",
          "function": {"name": "screenshot", "arguments": "{}"}}]},
        %*{"content": "screen seen"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()

      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check s.prompt("look at the screen") == "screen seen"

      # Activation: one-time note in the conversation, shot script on disk.
      var note = ""
      for m in s.messages:
        if m{"role"}.getStr == "user" and
            m{"content"}.getStr.startsWith("[computer use on]"):
          note = m{"content"}.getStr
      check note.len > 0
      let sid = sessionIdFromPath(s.state.savePath)
      check note.contains(shotScriptPath(sid))
      check fileExists(shotScriptPath(sid))

      # Tool result: text receipt, no base64.
      var receipt = ""
      for m in s.messages:
        if m{"role"}.getStr == "tool":
          receipt = m{"content"}.getStr
      check receipt.startsWith("screenshot 16x12 -> delivered")
      check "; shot attached below" in receipt
      check "base64" notin receipt

      # Follow-up user message: screenshot-labeled text + image block that
      # embeds the exact delivered bytes from disk (cache parity).
      var imageMsg: JsonNode = nil
      for m in s.messages:
        if m{"role"}.getStr == "user" and m{"content"}.kind == JArray:
          imageMsg = m
      require imageMsg != nil
      let blocks = imageMsg{"content"}
      check blocks.len == 2
      check "attached: shot 1 16x12 -> " in blocks[0]{"text"}.getStr
      check "(screenshot)" in blocks[0]{"text"}.getStr
      check blocks[1]{"type"}.getStr == "image_url"
      let uri = blocks[1]{"image_url"}{"url"}.getStr
      check uri.startsWith("data:image/")
      let imgDir = sessionImageDir(s.state.savePath)
      check fileExists(imgDir / "001.jpeg")
      check uri.endsWith(encode(readFile(imgDir / "001.jpeg")))

      # Frame state binds the delivered raster for `shot`.
      let st = readFile(shotDir(sid) / "state")
      check st.contains("native=16x12")
      check st.contains("delivered=16x12")
      s.close()

