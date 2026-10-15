## `@image` attach: inlineAtFiles skips text-inlining images, and
## buildUserMessage returns a content array (text block first, image blocks
## after) for vision profiles — a plain string otherwise, with a hint naming
## a vision model when the profile can't see.

discard """
  action: compile
"""

import std/[base64, json, os, strutils, unittest]
import threecode/images
import threecode/ui

template withTempCwd(body: untyped) =
  block:
    let prev = try: getCurrentDir() except OSError: "/"
    let root = getTempDir() / ("attach_test_" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer:
      try: setCurrentDir(prev) except OSError: discard
      removeDir(root)
    copyFile("testdata/images/tiny.png", root / "tiny.png")
    writeFile(root / "notes.md", "hello notes")
    body

suite "buildUserMessage: @image attach":
  test "vision profile: content array, no binary blob":
    withTempCwd:
      let imgDir = getTempDir() / "attach-img-1"
      removeDir(imgDir)
      let c = buildUserMessage(%*[], "@tiny.png describe this",
                                vision = true, imgDir = imgDir)
      require c.kind == JArray
      check c.len == 2
      check c[0]{"type"}.getStr == "text"
      check "@tiny.png describe this" in c[0]{"text"}.getStr
      check "=== tiny.png ===" notin c[0]{"text"}.getStr
      check c[1]{"type"}.getStr == "image_url"
      let uri = c[1]{"image_url"}{"url"}.getStr
      check uri.startsWith("data:image/")
      # The block embeds the exact delivered bytes written under imgDir.
      var delivered = ""
      for f in walkFiles(imgDir / "*"):
        if f.extractFilename.split('.')[0] == "001": delivered = f
      require delivered.len > 0
      check uri.endsWith(encode(readFile(delivered)))
      check imageAttachEcho() == " [image attached]"
      removeDir(imgDir)

  test "non-vision profile: string with the hint, image dropped":
    withTempCwd:
      let m = buildUserMessage(%*[], "@tiny.png describe this", vision = false,
                               imgDir = "")
      check m.kind == JString
      let text = m.getStr
      check "@tiny.png describe this" in text
      check "[image ignored: tiny.png" in text
      check "glm-5.3-flash" in text
      check "zai" in text
      check "=== tiny.png ===" notin text
      check "base64" notin text
      check imageAttachEcho() == ""

  test "text files keep inlining alongside an image":
    withTempCwd:
      let imgDir = getTempDir() / "attach-img-2"
      removeDir(imgDir)
      let m = buildUserMessage(
        %*[%*{"role": "user", "content": "earlier"}],
        "@tiny.png and @notes.md", vision = true, imgDir = imgDir)
      require m.kind == JArray
      check m.len == 2
      let text = m[0]{"text"}.getStr
      check "=== notes.md ===" in text
      check "hello notes" in text
      # Not the first user message: no session preamble rides along.
      check not text.startsWith("<session_context>")
      removeDir(imgDir)

  test "first message keeps the preamble, then the image block":
    withTempCwd:
      let imgDir = getTempDir() / "attach-img-3"
      removeDir(imgDir)
      let m = buildUserMessage(%*[], "@tiny.png go", vision = true,
                               imgDir = imgDir)
      require m.kind == JArray
      check m[0]{"text"}.getStr.startsWith("<session_context>")
      check m[1]{"type"}.getStr == "image_url"
      removeDir(imgDir)

  test "no images at all: plain string, echo empty":
    withTempCwd:
      let m = buildUserMessage(%*[], "@notes.md summarize", vision = true,
                               imgDir = "")
      check m.kind == JString
      check "=== notes.md ===" in m.getStr
      check imageAttachEcho() == ""

  test "encode failure degrades to a text note":
    withTempCwd:
      writeFile("broken.png", "not really a png")
      let m = buildUserMessage(%*[], "@broken.png look", vision = true,
                               imgDir = "")
      check m.kind == JString
      check "not a recognized image" in m.getStr
      check imageAttachEcho() == ""
