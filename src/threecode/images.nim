## Image support for vision-capable models: header-only dimension sniffing,
## a budget-driven encoder backed by platform tools (ImageMagick / sips), and
## wire helpers for content-array user messages. No image library; the
## delivered bytes are deterministic (same source + flags, same output) so
## providers' prompt caches see stable re-sends on resume.

import std/[base64, json, os, osproc, sequtils, strformat, strutils]

const
  ImageB64Budget = 190 * 1024   ## max base64 chars of a delivered image
  MaxLongEdge = 1280            ## delivered images fit inside this box
  MinDeliveredEdge = 320        ## shrink-ladder floor
  JpegLadder = [85, 70, 55, 40]
  ImageShrinkStep = 0.8
  MaxAttachPerMessage* = 3
  MaxImagesPerTurn* = 4           ## read-on-image cost cap; extras are noted, not attached

type
  ImageInfo* = object
    width*, height*: int            ## source pixels
    deliveredWidth*, deliveredHeight*: int
    format*: string                 ## delivered subtype for the data URI
    path*: string                   ## delivered file on disk
    name*: string                   ## source basename, for receipts and notes

func u8(d: string, i: int): int {.inline.} = int(uint8(d[i]))

func be16(d: string, i: int): int {.inline.} = (u8(d, i) shl 8) or u8(d, i + 1)

func le16(d: string, i: int): int {.inline.} = u8(d, i) or (u8(d, i + 1) shl 8)

func be32(d: string, i: int): int {.inline.} =
  (u8(d, i) shl 24) or (u8(d, i + 1) shl 16) or (u8(d, i + 2) shl 8) or u8(d, i + 3)

func le32(d: string, i: int): int {.inline.} =
  u8(d, i) or (u8(d, i + 1) shl 8) or (u8(d, i + 2) shl 16) or (u8(d, i + 3) shl 24)

func pngDims(d: string): (int, int) =
  if d.len >= 24 and d[0] == '\x89' and d[1] == 'P' and d[2] == 'N' and
      d[3] == 'G' and d[12] == 'I' and d[13] == 'H' and d[14] == 'D' and d[15] == 'R':
    (be32(d, 16), be32(d, 20))
  else:
    (0, 0)

func jpegDims(d: string): (int, int) =
  if d.len < 4 or u8(d, 0) != 0xFF or u8(d, 1) != 0xD8: return (0, 0)
  var i = 2
  while i + 9 < d.len:
    if u8(d, i) != 0xFF: return (0, 0)
    let m = u8(d, i + 1)
    if m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7):
      inc i, 2
      continue
    if i + 4 > d.len: break
    let seglen = be16(d, i + 2)
    if m in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
             0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
      return (be16(d, i + 7), be16(d, i + 5)) # width, height
    if seglen < 2: return (0, 0)
    i += 2 + seglen
  (0, 0)

func gifDims(d: string): (int, int) =
  if d.len >= 10 and d.startsWith("GIF8"):
    (le16(d, 6), le16(d, 8))
  else:
    (0, 0)

func webpDims(d: string): (int, int) =
  if d.len < 30 or not d.startsWith("RIFF") or d[8] != 'W' or d[9] != 'E' or
      d[10] != 'B' or d[11] != 'P': return (0, 0)
  # The fourcc chunk type differs in its last byte: "VP8 ", "VP8L", "VP8X".
  case d[15]
  of ' ':
    # "VP8 ": frame tag (3) + sync code 9D 01 2A, then 14-bit LE w/h.
    if u8(d, 23) == 0x9D and u8(d, 24) == 0x01 and u8(d, 25) == 0x2A:
      (le16(d, 26) and 0x3FFF, le16(d, 28) and 0x3FFF)
    else:
      (0, 0)
  of 'L':
    # "VP8L": 0x2F signature, then LSB-first bitstream: 14 bits w-1, 14 bits h-1.
    if u8(d, 20) == 0x2F:
      let bits = le32(d, 21)
      ((bits and 0x3FFF) + 1, ((bits shr 14) and 0x3FFF) + 1)
    else:
      (0, 0)
  of 'X':
    # "VP8X": flags (4), then 24-bit LE canvas w-1 / h-1.
    ((u8(d, 24) or (u8(d, 25) shl 8) or (u8(d, 26) shl 16)) + 1,
     (u8(d, 27) or (u8(d, 28) shl 8) or (u8(d, 29) shl 16)) + 1)
  else:
    (0, 0)

func imageDimensionsFromData*(d: string): (int, int) {.raises: [].} =
  let r = pngDims(d)
  if r[0] > 0: return r
  let j = jpegDims(d)
  if j[0] > 0: return j
  let g = gifDims(d)
  if g[0] > 0: return g
  webpDims(d)

proc imageDimensions*(path: string): (int, int) {.raises: [].} =
  try:
    imageDimensionsFromData(readFile(path))
  except CatchableError:
    (0, 0)

func isImagePath*(path: string): bool =
  case path.splitFile.ext.toLowerAscii
  of ".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp": true
  else: false

type Resizer = enum
  rkNone
  rkMagick
  rkSips

proc findResizer(): Resizer =
  if findExe("magick").len > 0 or findExe("convert").len > 0: rkMagick
  elif findExe("sips").len > 0: rkSips
  else: rkNone

proc magickBinary(): string =
  if findExe("magick").len > 0: "magick" else: "convert"

proc fitsBudget(path: string): bool =
  let size = try: getFileSize(path)
             except CatchableError: return false
  ((size + 2) div 3) * 4 <= ImageB64Budget

func shellJoin(args: seq[string]): string =
  # execCmdEx goes through a shell; every arg must be quoted or geometry
  # like `1280x720>` becomes a redirection.
  args.map(quoteShell).join(" ")

proc runEncode(rk: Resizer, src, dst: string, boxW, boxH, quality: int,
               jpeg: bool): tuple[ok: bool, err: string] =
  case rk
  of rkMagick:
    var args = @[magickBinary(), src, "-auto-orient"]
    if boxW > 0 and boxH > 0:
      args.add ["-resize", &"{boxW}x{boxH}>"]
    if jpeg:
      args.add ["-quality", $quality]
    else:
      args.add ["-define", "png:exclude-chunk=date,time"]
    args.add dst
    let (outp, code) = execCmdEx(shellJoin(args))
    if code == 0 and fileExists(dst): (true, "")
    else: (false, &"image encode failed: {outp.strip}")
  of rkSips:
    var args = @["sips"]
    if boxW > 0 and boxH > 0:
      args.add ["-Z", $max(boxW, boxH)]
    args.add ["-s", "format", if jpeg: "jpeg" else: "png"]
    if jpeg:
      args.add ["-s", "formatOptions", $quality]
    args.add @[src, "--out", dst]
    let (outp, code) = execCmdEx(shellJoin(args))
    if code == 0 and fileExists(dst): (true, "")
    else: (false, &"image encode failed: {outp.strip}")
  of rkNone:
    (false, "no image tool")

proc encodeForVision*(src, destDir: string, idx: int,
    fidelity = false): tuple[info: ImageInfo, err: string] =
  ## Encodes `src` into `destDir/NNN.jpeg` (or `.png` when fidelity is set)
  ## inside the delivery budget: long edge capped at 1280, then quality
  ## ladder (JPEG only) and 0.8x downscale to a 320px floor until the
  ## base64 fits. Same inputs give the same delivered bytes.
  if not fileExists(src):
    return (ImageInfo(), &"error: {src} does not exist")
  let (w, h) = imageDimensions(src)
  if w <= 0 or h <= 0:
    return (ImageInfo(),
      &"error: not a recognized image (png/jpeg/gif/webp): {src}")
  createDir(destDir)
  let jpeg = not fidelity
  let ext = if jpeg: "jpeg" else: "png"
  let dst = destDir / &"{idx:03d}.{ext}"
  result = (ImageInfo(width: w, height: h, format: if jpeg: "jpeg" else: "png",
                      path: dst, name: src.extractFilename), "")
  let rk = findResizer()
  if rk == rkNone:
    # Last resort: deliver the original bytes when they already fit; the
    # format follows the source file so the data URI stays honest.
    let data = try: readFile(src)
               except CatchableError as e:
                 return (ImageInfo(), &"error: read {src}: {e.msg}")
    if ((data.len + 2) div 3) * 4 > ImageB64Budget:
      return (ImageInfo(),
        "error: image over the vision budget and no image tool installed " &
        "(install ImageMagick)")
    try: writeFile(dst, data)
    except CatchableError as e:
      return (ImageInfo(), &"error: write {dst}: {e.msg}")
    result[0].format =
      case src.splitFile.ext.toLowerAscii
      of ".jpg": "jpeg"
      of ".png": "png"
      of ".webp": "webp"
      of ".gif": "gif"
      of ".bmp": "bmp"
      else: "jpeg"
    result[0].deliveredWidth = w
    result[0].deliveredHeight = h
    return result
  # Target box: fit the long edge, aspect preserved (the '>' resize guard
  # makes the box an upper bound, never an upscale).
  var cw = w
  var ch = h
  if max(w, h) > MaxLongEdge:
    cw = w * MaxLongEdge div max(w, h)
    ch = h * MaxLongEdge div max(w, h)
  var lastErr = ""
  while true:
    let qualities = if jpeg: @JpegLadder else: @[0]
    for q in qualities:
      let (ok, err) = runEncode(rk, src, dst, cw, ch, q, jpeg)
      if not ok:
        return (ImageInfo(), err)
      lastErr = ""
      if fitsBudget(dst):
        let (dw, dh) = imageDimensions(dst)
        result[0].deliveredWidth = if dw > 0: dw else: cw
        result[0].deliveredHeight = if dh > 0: dh else: ch
        return result
      lastErr = "over budget"
    if min(cw, ch) <= MinDeliveredEdge:
      break
    let nw = max(MinDeliveredEdge, int(float(cw) * ImageShrinkStep))
    let nh = max(MinDeliveredEdge, int(float(ch) * ImageShrinkStep))
    if nw == cw and nh == ch:
      break
    cw = nw
    ch = nh
  # Shrunk to the floor and still over budget: deliver the last attempt.
  if lastErr.len > 0 and not fitsBudget(dst):
    let (dw, dh) = imageDimensions(dst)
    result[0].deliveredWidth = if dw > 0: dw else: cw
    result[0].deliveredHeight = if dh > 0: dh else: ch

proc imageContentBlocks*(text: string, imgs: seq[ImageInfo]): JsonNode =
  ## Content array for a user message: text block first, then one image_url
  ## block per image (first MaxAttachPerMessage; the rest noted by name).
  var body = text
  if imgs.len > MaxAttachPerMessage:
    let rest = imgs[MaxAttachPerMessage..^1].mapIt(it.path.extractFilename)
    body.add &"\n[{rest.len} more image(s) not attached: {rest.join(\", \")}]"
  result = newJArray()
  result.add %*{"type": "text", "text": body}
  for img in imgs[0 ..< min(imgs.len, MaxAttachPerMessage)]:
    let uri = "data:image/" & img.format & ";base64," &
      encode(try: readFile(img.path) except CatchableError: "")
    result.add %*{"type": "image_url", "image_url": {"url": uri}}

proc nextImageIndex*(destDir: string): int =
  ## One past the highest NNN.* already in `destDir`, so re-reads never
  ## overwrite earlier delivered bytes (resume re-embeds them by path).
  for f in walkFiles(destDir / "*"):
    try:
      let n = parseInt(f.extractFilename.split('.')[0])
      if n >= result: result = n + 1
    except CatchableError: discard
  max(result, 1)

func srcFormatName*(path: string): string =
  case path.splitFile.ext.toLowerAscii
  of ".jpg": "JPEG"
  of ".png": "PNG"
  of ".webp": "WEBP"
  of ".gif": "GIF"
  of ".bmp": "BMP"
  else: ""

func imageReceipt*(name: string, info: ImageInfo, note = ""): string =
  ## Text receipt for a `read` of an image: what was read, what will be
  ## delivered. `imageReadBanner` parses this shape — change one, change
  ## both.
  result = &"image {name} {info.width}x{info.height} {srcFormatName(name)} -> " &
    &"delivered {info.deliveredWidth}x{info.deliveredHeight} " &
    info.format.toUpperAscii & "; attached below"
  if note.len > 0: result.add "; " & note

func isImageReceipt*(res: string): bool =
  res.startsWith("image ") and "; attached below" in res

func imageReadBanner*(receipt: string): string =
  ## The one-line transcript form of a receipt:
  ## `image logo.png 1920x1080 PNG -> delivered 1280x720 JPEG; ...`
  ## becomes `· read img logo.png 1920x1080 -> 1280x720`.
  let semi = receipt.find(';')
  let toks = (if semi > 0: receipt[0 ..< semi] else: receipt).split(' ')
  if toks.len >= 8: &"· read img {toks[1]} {toks[2]} -> {toks[6]}" else: receipt

proc imageUserMessage*(text: string, imgs: seq[ImageInfo]): JsonNode =
  %*{"role": "user", "content": imageContentBlocks(text, imgs)}

func dataUriDimensions(uri: string): (int, int) =
  ## Header-only decode: dimensions live in the first bytes, so rounding
  ## the payload prefix down to a base64 quad boundary is enough.
  let comma = uri.find(',')
  if comma < 0: return (0, 0)
  let payload = uri[comma + 1 .. ^1]
  let n = min(payload.len - (payload.len mod 4), 8192)
  if n <= 0: return (0, 0)
  try:
    imageDimensionsFromData(decode(payload[0 ..< n]))
  except CatchableError:
    (0, 0)

func userTextBlocks*(c: JsonNode): string =
  ## Text blocks of a content array joined with newlines; image blocks
  ## contribute nothing (persistence re-derives them from image records,
  ## so their stand-in notes must not leak into the saved text).
  ## String content passes through unchanged.
  if c == nil or c.kind != JArray: return c.getStr
  var parts: seq[string]
  for b in c.getElems:
    if b{"type"}.getStr == "text": parts.add b{"text"}.getStr
  parts.join("\n")

proc imageRefFromUri*(uri: string): tuple[fmt, data: string, w, h: int] =
  ## Persistence view of an image block's data URI: delivered subtype,
  ## raw bytes, delivered dimensions.
  let comma = uri.find(',')
  if comma < 0 or not uri.startsWith("data:image/"): return ("", "", 0, 0)
  let semi = uri.find(';', 5)
  result.fmt = uri[11 ..< (if semi > 0: semi else: comma)]
  try:
    result.data = decode(uri[comma + 1 .. ^1])
  except CatchableError:
    return ("", "", 0, 0)
  (result.w, result.h) = imageDimensionsFromData(result.data)

proc imageDataUri*(path, fmt: string): string =
  ## The wire block URI for a delivered file on disk. Reading the exact
  ## bytes back (never a re-encode) is what keeps resumed re-sends
  ## byte-identical for providers' prompt caches.
  "data:image/" & fmt & ";base64," &
    encode(try: readFile(path) except CatchableError: "")

proc userTextContent*(m: JsonNode): string =
  ## The one text accessor for a message: string content passes through; a
  ## content array joins its text blocks and stands image blocks in as
  ## `[image WxH]`. Never stringifies the array (base64 stays out of logs,
  ## token estimates, and the transcript).
  let c = m{"content"}
  if c == nil or c.kind != JArray: return c.getStr
  var parts: seq[string]
  for b in c.getElems:
    if b{"type"}.getStr == "text":
      parts.add b{"text"}.getStr
    elif b{"type"}.getStr == "image_url":
      let (w, h) = dataUriDimensions(b{"image_url"}{"url"}.getStr)
      parts.add if w > 0: &"[image {w}x{h}]" else: "[image]"
  parts.join("\n")
