## `@image` attach + the `@.` `@>` `@!` `@$` `@?` prompt references:
## splice tokens replaced in place by the last model output / previous
## prompt / run command / its output / last `:btw` question and answer;
## token-exact, no re-expansion.

discard """
  action: compile
"""

import std/[base64, json, os, strutils, unittest]
import threecode/images
import threecode/types
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
    try: setCurrentDir(root) except OSError: discard
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
      check imageAttachEcho() == " " & ImageAttachMark
      removeDir(imgDir)

  test "non-vision profile: string with the hint, image dropped":
    withTempCwd:
      let m = buildUserMessage(%*[], "@tiny.png describe this", vision = false,
                               imgDir = "")
      check m.kind == JString
      let text = m.getStr
      check "@tiny.png describe this" in text
      check "[image ignored: tiny.png" in text
      check "glm-5.4" in text
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

suite "prompt reference tokens: @. @> @! @$ @? splice":
  let convo = %*[%*{"role": "user", "content": "earlier"}]

  test "@. splices the model's last output in place":
    withTempCwd:
      let m = buildUserMessage(convo, "why did @. fail", vision = false,
                               imgDir = "", lastLLM = "it compiled")
      require m.kind == JString
      check m.getStr == "why did it compiled fail"

  test "@> splices the previous prompt, token at end too":
    withTempCwd:
      let m = buildUserMessage(convo, "redo @>", vision = false, imgDir = "",
                               lastPrompt = "add tests for @path")
      require m.kind == JString
      check m.getStr == "redo add tests for @path"

  test "@! and @$ split the last bash run: command and output":
    withTempCwd:
      let m = buildUserMessage(convo, "run @! again, @! had @$",
                               vision = false, imgDir = "",
                               lastCmd = "nim c -d:release",
                               lastBashOut = "built ok")
      require m.kind == JString
      check m.getStr ==
        "run nim c -d:release again, nim c -d:release had built ok"

  test "@? splices the last :btw question and answer":
    withTempCwd:
      let m = buildUserMessage(convo, "expand on @?", vision = false,
                               imgDir = "",
                               lastBtw = lastBtwInclude("why nim?",
                                 "because it compiles fast"))
      require m.kind == JString
      check m.getStr ==
        "expand on why nim?\nbecause it compiles fast"

  test "no prior value: bracket notes in place of the tokens":
    withTempCwd:
      let m = buildUserMessage(convo, "@. @> @! @$ @?", vision = false,
                               imgDir = "")
      require m.kind == JString
      check m.getStr ==
        "[no model output yet] [no prompt yet] [no command yet: run :! <command>] " &
        "[no command output yet: run :! <command>] [no :btw answer yet]"

  test "token-exact: @.gitignore and @!rc stay file mentions":
    withTempCwd:
      writeFile(".gitignore", "build/")
      writeFile("!rc", "bang notes")
      let m = buildUserMessage(convo, "@.gitignore then @!rc", vision = false,
                               imgDir = "", lastLLM = "out",
                               lastCmd = "x")
      require m.kind == JString
      let text = m.getStr
      # `@.gitignore` is the ordinary mention of the dotfile; `@!rc` the
      # mention of the file literally named `!rc`. Neither is a splice.
      check text.startsWith "@.gitignore then @!rc"
      check "=== .gitignore ===\nbuild/" in text
      check "=== !rc ===\nbang notes" in text
      check "out" notin text

  test "mixed: file block still appended after the spliced message":
    withTempCwd:
      let m = buildUserMessage(convo, "see @notes.md and @>", vision = false,
                               imgDir = "", lastPrompt = "go")
      require m.kind == JString
      check m.getStr ==
        "see @notes.md and go\n\n=== notes.md ===\nhello notes"

  test "every occurrence spliced, adjacency still required":
    withTempCwd:
      let m = buildUserMessage(convo, "@> then @> but foo@> stays",
                               vision = false, imgDir = "",
                               lastPrompt = "p")
      require m.kind == JString
      check m.getStr == "p then p but foo@> stays"

  test "no re-expansion: a spliced @path mention does not inline":
    withTempCwd:
      let m = buildUserMessage(convo, "@> again", vision = false, imgDir = "",
                               lastPrompt = "read @notes.md please")
      require m.kind == JString
      check m.getStr == "read @notes.md please again"
      check "=== notes.md ===" notin m.getStr

  test "lastAssistantText: newest answer, markers stripped":
    let msgs = %*[
      %*{"role": "user", "content": "q1"},
      %*{"role": "assistant", "content": "[checkpoint 3]\nfirst"},
      %*{"role": "user", "content": "q2"},
      %*{"role": "assistant", "content": EmptyReplyMsg},
      %*{"role": "user", "content": "q3"},
      %*{"role": "assistant", "content": EmptyReplyMsg},
    ]
    # The newest answer is the empty-reply marker: no output to reference.
    check lastAssistantText(msgs) == ""
    let real = %*[
      %*{"role": "assistant", "content": "[checkpoint 3]\nfirst"},
      %*{"role": "user", "content": "q2"},
      %*{"role": "assistant", "content": "second"},
    ]
    check lastAssistantText(real) == "second"
    check lastAssistantText(%*[]) == ""

  test "lastAssistantText: capped at 64KB":
    let msgs = %*[%*{"role": "assistant",
                     "content": repeat('a', 70_000)}]
    let got = lastAssistantText(msgs)
    check got.startsWith "a"
    check got.endsWith "\n... [truncated; text is 70000 bytes]"
    check got.len == 64 * 1024 + "\n... [truncated; text is 70000 bytes]".len

  test "lastBashCommand / lastBashOutput: newest akBash wins, split":
    let log = @[
      ToolRecord(kind: akBash, command: "old", output: "old out"),
      ToolRecord(kind: akRead, output: "not bash"),
      ToolRecord(kind: akBash, command: "nim c", output: "built"),
    ]
    check lastBashCommand(log) == "nim c"
    check lastBashOutput(log) == "built"
    check lastBashCommand(@[]) == ""
    check lastBashOutput(@[]) == ""

  test "lastBashOutput: capped at 64KB":
    let log = @[ToolRecord(kind: akBash, command: "yes",
                           output: repeat('a', 70_000))]
    let got = lastBashOutput(log)
    check got.startsWith "a"
    check got.endsWith "\n... [truncated; text is 70000 bytes]"
    check got.len == 64 * 1024 + "\n... [truncated; text is 70000 bytes]".len

  test "lastBtwInclude: empty until question and answer both exist":
    check lastBtwInclude("", "answer") == ""
    check lastBtwInclude("q", "  ") == ""
    check lastBtwInclude("q", "a") == "q\na"
