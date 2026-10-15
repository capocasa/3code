import std/[base64, json, os, osproc, strformat, strutils, unittest]
import threecode/images

const Images = "testdata/images"

suite "images: dimension sniffing":
  test "fixtures parse (png, jpeg, gif, webp)":
    check imageDimensions(Images / "tiny.png") == (16, 12)
    check imageDimensions(Images / "tiny.jpg") == (16, 12)
    check imageDimensions(Images / "tiny.gif") == (16, 12)
    check imageDimensions(Images / "tiny.webp") == (16, 12)

  test "missing and non-image files are (0, 0)":
    check imageDimensions(Images / "nope.png") == (0, 0)
    check imageDimensions("tests/core/test_images.nim") == (0, 0)

  test "isImagePath by extension, case-insensitive":
    check isImagePath("shot.png")
    check isImagePath("photo.JPG")
    check isImagePath("a/b/c.jpeg")
    check isImagePath("x.webp") and isImagePath("x.gif") and isImagePath("x.bmp")
    check not isImagePath("readme.md")
    check not isImagePath("noext")

suite "images: encodeForVision":
  let hasResizer = findExe("magick").len > 0 or
    findExe("convert").len > 0 or findExe("sips").len > 0
  let work = getTempDir() / "3code-images-" & $getCurrentProcessId()
  setup:
    createDir(work)
  teardown:
    removeDir(work)

  test "fits 1280 box and budget":
    if not hasResizer: skip()
    let big = work / "big.png"
    discard execCmdEx(&"magick -size 2000x1200 gradient:red-blue {quoteShell(big)}")
    let (info, err) = encodeForVision(big, work / "out", 1)
    check err == ""
    check info.format == "jpeg"
    check info.width == 2000 and info.height == 1200
    check max(info.deliveredWidth, info.deliveredHeight) <= 1280
    check info.deliveredWidth > 0 and info.deliveredHeight > 0
    let size = getFileSize(info.path)
    check ((size + 2) div 3) * 4 <= 190 * 1024

  test "budget ladder fires on incompressible input":
    if not hasResizer: skip()
    # Random noise defeats JPEG compression, forcing the quality/downscale
    # ladder to actually run.
    let noise = work / "noise.png"
    discard execCmdEx(
      &"magick -size 1600x1200 xc:gray +noise Random {quoteShell(noise)}")
    let (info, err) = encodeForVision(noise, work / "out", 7)
    check err == ""
    check max(info.deliveredWidth, info.deliveredHeight) <= 1280
    let size = getFileSize(info.path)
    check ((size + 2) div 3) * 4 <= 190 * 1024

  test "deterministic: same source, same flags, same bytes":
    if not hasResizer: skip()
    let big = work / "big.png"
    discard execCmdEx(&"magick -size 1800x900 gradient:green-blue {quoteShell(big)}")
    let (a, ea) = encodeForVision(big, work / "a", 3)
    let (b, eb) = encodeForVision(big, work / "b", 3)
    check ea == "" and eb == ""
    check a.path != b.path
    check readFile(a.path) == readFile(b.path)

  test "fidelity delivers png":
    if not hasResizer: skip()
    let big = work / "big.png"
    discard execCmdEx(&"magick -size 2000x1200 gradient:red-blue {quoteShell(big)}")
    let (info, err) = encodeForVision(big, work / "out", 2, fidelity = true)
    check err == ""
    check info.format == "png"
    check info.path.endsWith(".png")
    check max(info.deliveredWidth, info.deliveredHeight) <= 1280

  test "unreadable image errors, not crashes":
    let (info, err) = encodeForVision(work / "garbage.png", work / "out", 1)
    check err.len > 0
    check info.path == ""

suite "images: no resizer installed":
  test "small originals pass through, big ones name the missing tool":
    let work = getTempDir() / "3code-images-norez-" & $getCurrentProcessId()
    createDir(work)
    defer: removeDir(work)
    let big = work / "big.png"
    discard execCmdEx(
      &"magick -size 1400x1400 xc:gray +noise Random {quoteShell(big)}")
    let savedPath = getEnv("PATH")
    putEnv("PATH", "")
    defer: putEnv("PATH", savedPath)
    let small = work / "small.png"
    copyFile(Images / "tiny.png", small)
    let (pass, perr) = encodeForVision(small, work / "out", 1)
    check perr == ""
    check pass.format == "png"
    check (pass.deliveredWidth, pass.deliveredHeight) == (16, 12)
    check readFile(pass.path) == readFile(small)
    let (fail, ferr) = encodeForVision(big, work / "out", 1)
    check ferr.len > 0
    check "ImageMagick" in ferr

suite "images: message blocks":
  test "golden shape: text first, then image_url data URIs":
    let (info, err) = encodeForVision(Images / "tiny.png", getTempDir() / "3code-images-msg", 5)
    check err == ""
    let m = imageUserMessage("describe this", @[info])
    check m{"role"}.getStr == "user"
    let c = m{"content"}
    check c.kind == JArray
    check c.len == 2
    check c[0]{"type"}.getStr == "text"
    check c[0]{"text"}.getStr == "describe this"
    check c[1]{"type"}.getStr == "image_url"
    let uri = c[1]{"image_url"}{"url"}.getStr
    check uri.startsWith("data:image/jpeg;base64,")

  test "more than three images: first three attach, rest noted by name":
    var infos: seq[ImageInfo]
    for i in 1..5:
      let (info, err) = encodeForVision(Images / "tiny.png", getTempDir() / "3code-images-msg", i)
      check err == ""
      infos.add info
    let c = imageContentBlocks("hello", infos)
    check c.len == 4 # text + 3 images
    var imageBlocks = 0
    for b in c.getElems:
      if b{"type"}.getStr == "image_url": inc imageBlocks
    check imageBlocks == 3
    check "[2 more image(s) not attached:" in c[0]{"text"}.getStr

  test "userTextContent: string passes through, array joins blocks":
    check userTextContent(%*{"role": "user", "content": "plain"}) == "plain"
    check userTextContent(%*{"role": "user"}) == ""
    let m = %*{"role": "user", "content": [
      {"type": "text", "text": "line one"},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64," &
        encode(readFile(Images / "tiny.png"))}},
      {"type": "text", "text": "line two"}]}
    let text = userTextContent(m)
    check "line one" in text and "line two" in text
    check "[image 16x12]" in text
    check "base64" notin text

suite "images: read receipt and banner":
  test "receipt format and banner round-trip":
    let info = ImageInfo(width: 1920, height: 1080,
      deliveredWidth: 1280, deliveredHeight: 720, format: "jpeg",
      path: "/x/001.jpeg", name: "logo.png")
    let r = imageReceipt("logo.png", info)
    check r == "image logo.png 1920x1080 PNG -> delivered 1280x720 JPEG; " &
      "attached below"
    check isImageReceipt(r)
    check imageReadBanner(r) == "· read img logo.png 1920x1080 -> 1280x720"
    check not isImageReceipt("plain text that starts with image-ish words")
    let noted = imageReceipt("shot.jpg", info,
      "offset/limit ignored for images")
    check isImageReceipt(noted)
    check imageReadBanner(noted) == "· read img shot.jpg 1920x1080 -> 1280x720"
    check noted.endsWith("; offset/limit ignored for images")

  test "banner degrades gracefully on unknown shapes":
    check imageReadBanner("image") == "image"

  test "nextImageIndex allocates past existing files":
    let work = getTempDir() / "3code-images-idx-" & $getCurrentProcessId()
    removeDir(work)
    createDir(work)
    defer: removeDir(work)
    check nextImageIndex(work) == 1
    writeFile(work / "001.jpeg", "x")
    writeFile(work / "002.jpeg", "x")
    check nextImageIndex(work) == 3
    writeFile(work / "007.png", "x")
    check nextImageIndex(work) == 8
    writeFile(work / "notes.txt", "x")
    check nextImageIndex(work) == 8
