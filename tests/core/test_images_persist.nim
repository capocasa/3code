## Image message persistence: save writes the text plus `image path=... sha1=...`
## records (never base64); resume re-embeds the exact delivered bytes when the
## file still matches its sha1, and folds a stale note into the text when it
## does not. The summarizer payload collapses image blocks to text stand-ins.

discard """
  action: compile
"""

import std/[json, os, strutils, unittest]
import threecode/[compact, images, session, types]

const Images = "testdata/images"

suite "session: image persistence":
  var root = ""
  var savedXdg = ""

  setup:
    root = getTempDir() / ("3code-imgpersist-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "data")
    savedXdg = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", root / "data")

  teardown:
    putEnv("XDG_DATA_HOME", savedXdg)
    removeDir(root)

  proc imageMessages(): tuple[imgs: seq[ImageInfo], messages: JsonNode] =
    let scratch = root / "scratch"
    let (info, err) = encodeForVision(Images / "tiny.png", scratch, 1)
    doAssert err == ""
    var msgs = %*[
      %*{"role": "system", "content": "sys"},
      %*{"role": "user",
         "content": imageContentBlocks("attached: tiny.png (image read)", @[info])},
      %*{"role": "assistant", "content": "it is tiny"},
    ]
    (@[info], msgs)

  test "save writes path+sha1 records, not base64":
    let (_, msgs) = imageMessages()
    var sess = Session(savePath: root / "s.3log", cwd: root)
    saveSession(sess, msgs)
    let text = readFile(root / "s.3log")
    check "image path=" in text
    check "sha1=" in text
    check "base64" notin text

  test "resume re-embeds byte-identical blocks":
    let (imgs, msgs) = imageMessages()
    var sess = Session(savePath: root / "s.3log", cwd: root)
    saveSession(sess, msgs)
    # The persistence copy of the delivered bytes survives even if the
    # original NNN encode output is gone.
    removeFile(imgs[0].path)
    let (sess2, msgs2) = loadSessionFile(root / "s.3log")
    check sess2.savePath == root / "s.3log"
    let um = msgs2[1]
    check um{"role"}.getStr == "user"
    let c = um{"content"}
    require c.kind == JArray
    check c.len == 2
    check c[0]{"type"}.getStr == "text"
    check c[0]{"text"}.getStr == "attached: tiny.png (image read)"
    check c[1]{"type"}.getStr == "image_url"
    check c[1]{"image_url"}{"url"}.getStr ==
          msgs[1]{"content"}[1]{"image_url"}{"url"}.getStr
    # History shape is otherwise untouched.
    check msgs2.len == 3
    check msgs2[2]{"content"}.getStr == "it is tiny"

  test "missing or changed file folds a stale note":
    let (_, msgs) = imageMessages()
    var sess = Session(savePath: root / "s.3log", cwd: root)
    saveSession(sess, msgs)
    # Overwrite every delivered byte under the session image dir.
    let imgDir = sessionImageDir(root / "s.3log")
    for f in walkFiles(imgDir / "*"): removeFile(f)
    let (_, msgs2) = loadSessionFile(root / "s.3log")
    let um = msgs2[1]
    check um{"content"}.kind == JString
    check "attached: tiny.png (image read)" in um{"content"}.getStr
    check "[image stale:" in um{"content"}.getStr

suite "compact: image blocks collapse for the summarizer":
  test "no image_url block survives into the summarizer payload":
    let (info, err) = encodeForVision(Images / "tiny.png",
      getTempDir() / "3code-imgcompact-" & $getCurrentProcessId(), 1)
    doAssert err == ""
    let payload = %*[
      %*{"role": "system", "content": "summarizer"},
      %*{"role": "user", "content": imageContentBlocks("look at this", @[info])},
      %*{"role": "assistant", "content": "noted", "reasoning_content": ""},
    ]
    let collapsed = collapseForSummary(payload)
    var sawImageBlock = false
    for m in collapsed:
      if m{"content"}.kind == JArray: sawImageBlock = true
    check not sawImageBlock
    check collapsed[1]{"content"}.kind == JString
    check "look at this" in collapsed[1]{"content"}.getStr
    check "[image 16x12]" in collapsed[1]{"content"}.getStr
    # The live history is not mutated by the collapse.
    check payload[1]{"content"}.kind == JArray
