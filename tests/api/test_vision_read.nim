discard """
  targets: "c"
  matrix: "; -d:providerStub"
"""
## Read-on-image, end to end against the stub provider: the scripted model
## calls `read` on a fixture image and the next request must carry the
## image as a user-message content block, with the tool result staying a
## text receipt. Compiled twice by the matrix; the plain variant only
## checks the non-vision error path (no stub needed for the unit part, the
## e2e needs the stub).

import std/[base64, json, os, strutils, unittest]
import threecode/[api, actions, library, session, types]

const stubbed = defined(providerStub)

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_visionread_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")

proc writeConfig(root: string, vision: bool) =
  var cfg = """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
"""
  if vision:
    cfg.add("""
[params]
provider = "stub"
model = "stub-model"
vision = "on"
""")
  writeFile(root / "xdg" / "3code" / "config", cfg)

proc isolateEnv(root: string) =
  putEnv("XDG_CONFIG_HOME", root / "xdg")
  putEnv("XDG_DATA_HOME", root / "data")
  putEnv("TMPDIR", root / "tmp")
  createDir(root / "tmp")

proc readCallJson(path: string): string =
  $(%*{"content": "",
    "tool_calls": [{
      "id": "call_1",
      "type": "function",
      "function": {"name": "read",
                   "arguments": $(%*{"path": path})}}]})

when not stubbed:
  suite "read on image (no stub)":
    test "non-vision read of an image names a vision model":
      let act = Action(kind: akRead, path: "testdata/images/tiny.png")
      let (outp, code, _) = runAction(act)
      check code == 1
      check "cannot see" in outp
      check "glm-5.3-flash" in outp
      check "zai" in outp
else:
  suite "read on image (stub e2e)":
    test "vision profile: receipt tool result, image on the next request":
      let root = newFixture("vision")
      writeConfig(root, vision = true)
      isolateEnv(root)
      copyFile("testdata/images/tiny.png", root / "run" / "tiny.png")
      writeFile(root / "run" / "stub_responses.json", $(%*[
        parseJson(readCallJson(root / "run" / "tiny.png")),
        %*{"content": "a tiny 16x12 image"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()

      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check s.prompt("what is in tiny.png?") == "a tiny 16x12 image"

      # Tool result: text receipt, no base64.
      var receipt = ""
      var imageMsg: JsonNode = nil
      for m in s.messages:
        if m{"role"}.getStr == "tool":
          receipt = m{"content"}.getStr
        if m{"role"}.getStr == "user" and m{"content"}.kind == JArray:
          imageMsg = m
      require receipt.startsWith("image tiny.png 16x12")
      check "; attached below" in receipt
      check "base64" notin receipt

      # Follow-up user message: text block first, then the image block the
      # next request carries verbatim.
      require imageMsg != nil
      let blocks = imageMsg{"content"}
      check blocks.len == 2
      check blocks[0]{"type"}.getStr == "text"
      check "attached: tiny.png (image read)" in blocks[0]{"text"}.getStr
      check blocks[1]{"type"}.getStr == "image_url"
      let uri = blocks[1]{"image_url"}{"url"}.getStr
      check uri.startsWith("data:image/")
      # The block embeds the exact delivered bytes from disk (cache parity).
      let imgDir = sessionImageDir(s.state.savePath)
      var delivered = ""
      for f in walkFiles(imgDir / "*"):
        if f.extractFilename.split('.')[0] == "001": delivered = f
      require delivered.len > 0
      check uri.endsWith(encode(readFile(delivered)))
      # The delivered file sits in the per-session image dir.
      check imgDir.startsWith(parentDir(s.state.savePath))
      s.close()

    test "@attach rides the user message for a vision profile":
      let root = newFixture("attach")
      writeConfig(root, vision = true)
      isolateEnv(root)
      copyFile("testdata/images/tiny.png", root / "run" / "tiny.png")
      writeFile(root / "run" / "stub_responses.json",
        $(%*[{"content": "a tiny image, 16x12"}]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()

      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check s.prompt("@" & (root / "run" / "tiny.png") &
                     " describe") == "a tiny image, 16x12"
      # The submitted user message is a content array: text block with the
      # @token visible, then the image block.
      var attachMsg: JsonNode = nil
      for m in s.messages:
        if m{"role"}.getStr == "user" and m{"content"}.kind == JArray:
          attachMsg = m
      if attachMsg == nil:
        checkpoint("no image attach message in history")
        for m in s.messages:
          checkpoint("  " & m{"role"}.getStr & ": " &
            (if m{"content"}.kind == JString: m{"content"}.getStr[0 ..< min(60, m{"content"}.getStr.len)] else: "<array>"))
        fail()
      else:
        let blocks = attachMsg{"content"}
        check blocks.len == 2
        check "@" & (root / "run" / "tiny.png") in blocks[0]{"text"}.getStr
        check blocks[1]{"type"}.getStr == "image_url"
        check blocks[1]{"image_url"}{"url"}.getStr.startsWith("data:image/")
      s.close()

    test "save/resume re-embeds identical image bytes":
      let root = newFixture("resumeimg")
      writeConfig(root, vision = true)
      isolateEnv(root)
      copyFile("testdata/images/tiny.png", root / "run" / "tiny.png")
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "first reply"},
        {"content": "second reply"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()

      let s1 = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      discard s1.prompt("@" & (root / "run" / "tiny.png") & " describe")
      var liveUri = ""
      for m in s1.messages:
        if m{"content"}.kind == JArray:
          liveUri = m{"content"}[1]{"image_url"}{"url"}.getStr
      require liveUri.len > 0
      let savePath = s1.state.savePath
      s1.close()

      # Session file: image records by path, never base64.
      let text = readFile(savePath)
      check "image path=" in text
      check "base64" notin text

      let s2 = initAgentSession(AgentOptions(cwd: root / "run", resume: true,
                                             experimental: true))
      var resumedUri = ""
      for m in s2.messages:
        if m{"content"}.kind == JArray:
          resumedUri = m{"content"}[1]{"image_url"}{"url"}.getStr
      check resumedUri == liveUri
      check s2.prompt("again") == "second reply"
      s2.close()

    test "non-vision profile: code-1 error, no image message":
      let root = newFixture("plain")
      writeConfig(root, vision = false)
      isolateEnv(root)
      copyFile("testdata/images/tiny.png", root / "run" / "tiny.png")
      writeFile(root / "run" / "stub_responses.json", $(%*[
        parseJson(readCallJson(root / "run" / "tiny.png")),
        %*{"content": "cannot see it"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      resetStubResponses()

      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      check s.prompt("what is in tiny.png?") == "cannot see it"
      var sawArray = false
      for m in s.messages:
        if m{"content"}.kind == JArray: sawArray = true
        if m{"role"}.getStr == "tool":
          check "glm-5.3-flash" in m{"content"}.getStr
          check "cannot see" in m{"content"}.getStr
      check not sawArray
      s.close()
